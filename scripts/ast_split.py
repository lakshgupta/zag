#!/usr/bin/env python3
"""Split src/ast.zig into 5 sub-files + thin aggregator.

Architecture:

  - src/ast.zig             aggregator, ~50 lines (re-exports top-level types)
  - src/ast/top.zig         Loc + Program + Arena (with alloc/dupe/init methods)
  - src/ast/expr.zig        Expr union (with all nested pub consts INSIDE the
                            union body) + MatchArm + Pattern union (nested).
                            TemplateLitExpr / TemplatePart nested-inside-Expr
                            pub consts are REPLACED with re-export aliases
                            (`pub const X = @import("template.zig").X;`)
                            so `ast.Expr.TemplateLitExpr` keeps resolving.
  - src/ast/stmt.zig        Stmt union (with all nested pub consts INSIDE
                            the union body) + BindingKind + BindingPattern +
                            RestBinding
  - src/ast/decl.zig        FunDecl + StructField (+StructFieldKind nested)
                            + StructDecl + MethodParam + MethodDecl +
                            ImplBlock + EnumDecl + EnumVariant
  - src/ast/template.zig    TemplateLitExpr + TemplatePart (extracted out of
                            Expr union body, defined here as TOP-LEVEL types)

Top-level types stay at module scope (re-exported by the aggregator).
Nested union member types (BinaryOp, NewExpr, IfStmt, etc.) stay INSIDE
their parent union body so external callers using `ast.Expr.BinaryOp`,
`ast.Stmt.IfStmt`, etc. continue working with zero churn.

Cross-file import DAG (zig 0.16 rejects mutual cross-file VALUE-typed
struct embeds with "dependency loop with length 2"; slice and pointer
indirection DO break the cycle — empirically verified before this refactor):

  - top.zig       std only.
  - expr.zig      std + template.zig (Expr.template_lit field; re-export
                  alias for TemplateLitExpr/TemplatePart references
                  @import("template.zig").X).
  - stmt.zig      std + expr.zig (BindingStmt.init: Expr, match_stmt:
                  Expr.MatchExpr, ForStmt.pattern: Pattern).
  - decl.zig      std + expr.zig (MethodParam.default_value: ?*const Expr)
                  + stmt.zig (FunDecl.body / MethodDecl.body: []const Stmt).
  - template.zig  std + expr.zig (TemplatePart.expr: ?Expr).

Cross-file `value-typed Embed / pointer-or-slice Embed` pairings:
  - expr ↔ template:  expr has union variant `template_lit: TemplateLitExpr`;
                      template has `TemplatePart.expr: ?Expr` (value-embed).
                      Cycle broken by union-variant indirection (Test 9 pattern).
  - stmt → expr:      stmt has `BindingStmt.init: Expr` (value-embed).
                      expr → stmt via `ClosureExpr.body: []const Stmt`
                      (slice indirection — Test 5 pattern).
  - decl ↔ expr:      decl has `MethodParam.default_value: ?*const Expr`
                      (pointer); expr has `ClosureExpr.params:
                      []const MethodParam` (slice).
  - decl → stmt:      decl has `body: []const Stmt` (slice).
"""

import os
import re

SOURCE_PATH = 'src/ast.zig'
OUT_DIR = 'src/ast'

# ============================================================================
# Categorization
# ============================================================================
# Top-level `pub const X = ...` declarations, grouped by destination file.
# Nested `pub const` blocks INSIDE union bodies stay WITH their parent
# (extracted as one block — the brace-walking logic captures them).
#
# Special case: `TemplateLitExpr` and `TemplatePart` are NESTED inside the
# Expr union body (4-space-indented `pub const` lines). They're extracted
# out to `template.zig` as TOP-LEVEL types, and the nested slots inside
# Expr are replaced with `pub const X = @import("template.zig").X;` aliases
# so external callers using `ast.Expr.TemplateLitExpr` keep working (the
# alias is a property on the union namespace).
TOP_LEVEL_GROUPS = {
    'top.zig':      ['Loc', 'Program', 'Arena'],
    'expr.zig':     ['Expr', 'Pattern', 'MatchArm'],
    'stmt.zig':     ['BindingKind', 'BindingPattern', 'RestBinding', 'Stmt'],
    'decl.zig':     ['FunDecl', 'StructField', 'StructDecl', 'MethodParam',
                     'MethodDecl', 'ImplBlock', 'EnumDecl', 'EnumVariant'],
    'template.zig': [],   # populated dynamically from Expr union body
}

# Nested-in-Expr pub consts to MOVE out of Expr to template.zig.
NESTED_TEMPLATE_TYPES = ['TemplateLitExpr', 'TemplatePart']

# Cross-file imports for each sub-file. The `imports` text comes BEFORE the
# type declarations inside each sub-file. Each comment explains why the
# sibling file is needed (helps future readers trace the import graph).
# Cross-bucket module-local aliases are added at the top of each sub-file
# (using `const X = module.X`). This lets the type bodies in each sub-file
# reference cross-bucket types by their unqualified name (the way they
# appeared in the original src/ast.zig, before the split) without the
# script having to rewrite every qualified type reference.
SUBFILE_IMPORTS = {
    'top.zig':      ('const std = @import("std");\n'
                     '\n'
                     '// DECL: Program.functions/structs/impls/enums reference\n'
                     '// decl-side types.\n'
                     'const decl = @import("decl.zig");\n'
                     'const FunDecl = decl.FunDecl;\n'
                     'const StructDecl = decl.StructDecl;\n'
                     'const ImplBlock = decl.ImplBlock;\n'
                     'const EnumDecl = decl.EnumDecl;'),
    'expr.zig':     ('const std = @import("std");\n'
                     '\n'
                     '// TEMPLATE: Expr.template_lit field type, plus the\n'
                     '// re-export aliases `pub const TemplateLitExpr =\n'
                     '// @import("template.zig").TemplateLitExpr;` inside the\n'
                     '// Expr union body.\n'
                     'const template = @import("template.zig");\n'
                     '\n'
                     '// DECL: ClosureExpr.params: []const MethodParam.\n'
                     'const decl = @import("decl.zig");\n'
                     'const MethodParam = decl.MethodParam;\n'
                     '\n'
                     '// STMT: ClosureExpr.body: []const Stmt.\n'
                     'const stmt = @import("stmt.zig");\n'
                     'const Stmt = stmt.Stmt;'),
    'stmt.zig':     ('const std = @import("std");\n'
                     '\n'
                     '// EXPR: BindingStmt.init: Expr, match_stmt:\n'
                     '// Expr.MatchExpr, ForStmt.pattern: Pattern, plus\n'
                     '// several other Expr-typed fields across the Stmt\n'
                     '// union members. Module-local aliases let the bodies\n'
                     '// reference `Expr` / `Pattern` unqualified.\n'
                     'const expr = @import("expr.zig");\n'
                     'const Expr = expr.Expr;\n'
                     'const Pattern = expr.Pattern;'),
    'decl.zig':     ('const std = @import("std");\n'
                     '\n'
                     '// TOP: every decl has a `loc: Loc` field.\n'
                     'const top = @import("top.zig");\n'
                     'const Loc = top.Loc;\n'
                     '\n'
                     '// EXPR: MethodParam.default_value: ?*const Expr.\n'
                     'const expr = @import("expr.zig");\n'
                     'const Expr = expr.Expr;\n'
                     '\n'
                     '// STMT: FunDecl.body / MethodDecl.body: []const Stmt.\n'
                     'const stmt = @import("stmt.zig");\n'
                     'const Stmt = stmt.Stmt;'),
    'template.zig': ('const std = @import("std");\n'
                     '\n'
                     '// EXPR: TemplatePart.expr: ?Expr.\n'
                     'const expr = @import("expr.zig");\n'
                     'const Expr = expr.Expr;'),
}


# ============================================================================
# Brace walker / simple-walker (top-level captures)
# ============================================================================
def find_brace_end(start_idx, lines):
    """Walk forward from start_idx counting {/} (comment/string-aware)
    until depth returns to 0. Returns (end_line, end_col). end_line
    is the line on which the matching closer `}` is found.

    Precondition: `lines[start_idx]` contains an opening `{` (typically
    a `struct {` or `union(...) {` decl line). depth starts at 1 just
    past that opener; we decrement on each `}` and stop at depth 0.
    """
    depth = 0
    state = 'NORMAL'
    saw_open = False
    opened_now = True
    i = start_idx
    line = lines[i]
    first_open = line.find('{')
    if first_open < 0:
        return None
    depth = 1
    saw_open = True
    j = first_open + 1

    while i < len(lines):
        ln = lines[i]
        if not opened_now:
            j = 0
        opened_now = False
        while j < len(ln):
            ch = ln[j]
            if state == 'NORMAL':
                if ch == '/' and j + 1 < len(ln) and ln[j + 1] == '/':
                    state = 'LINE'
                    j += 2
                    continue
                if ch == '/' and j + 1 < len(ln) and ln[j + 1] == '*':
                    state = 'BLOCK'
                    j += 2
                    continue
                if ch == '"':
                    state = 'STRING'
                    j += 1
                    continue
                if ch == "'":
                    state = 'CHAR'
                    j += 1
                    continue
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                    if depth == 0 and saw_open:
                        return (i, j)
                j += 1
            elif state == 'LINE':
                j = len(ln)  # end-of-line resets state
                state = 'NORMAL'
                break
            elif state == 'BLOCK':
                if ch == '*' and j + 1 < len(ln) and ln[j + 1] == '/':
                    state = 'NORMAL'
                    j += 2
                else:
                    j += 1
            elif state == 'STRING':
                if ch == '\\':
                    j += 2
                    continue
                if ch == '"':
                    state = 'NORMAL'
                j += 1
            elif state == 'CHAR':
                if ch == '\\':
                    j += 2
                    continue
                if ch == "'":
                    state = 'NORMAL'
                j += 1
        i += 1
    return None


def find_simple_end(start_idx, lines):
    """For `pub const X = ...;` decls that don't open a `{` block.
    Walks forward until the matching `;` at depth 0."""
    depth = 0
    state = 'NORMAL'
    i = start_idx
    while i < len(lines):
        ln = lines[i]
        j = 0
        while j < len(ln):
            ch = ln[j]
            if state == 'NORMAL':
                if ch == '/' and j + 1 < len(ln) and ln[j + 1] == '/':
                    state = 'LINE'
                    j += 2
                    continue
                if ch == '"':
                    state = 'STRING'
                    j += 1
                    continue
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                elif ch == ';' and depth == 0:
                    return (i, j)
                j += 1
            elif state == 'LINE':
                j = len(ln)
                state = 'NORMAL'
                break
            elif state == 'STRING':
                if ch == '\\':
                    j += 2
                    continue
                if ch == '"':
                    state = 'NORMAL'
                j += 1
        i += 1
    return None


# ============================================================================
# Top-level type extractor
# ============================================================================
TOP_LEVEL_RE = re.compile(r'^pub const (\w+) = ')


def extract_top_level_types(lines):
    """Walk src/ast.zig and return dict[name -> {start, end, body}].

    For block-bodied decls (`struct { ... };`, `union(...) { ... };`,
    `enum { ... };`), captures the entire block from the OPTIONAL
    preceding doc-comment group through to the closing `};`.
    """
    blocks = {}
    i = 0
    n = len(lines)
    while i < n:
        ln = lines[i]
        m = TOP_LEVEL_RE.match(ln)
        if m is None:
            i += 1
            continue
        name = m.group(1)

        # Walk back over contiguous doc-comment lines.
        start = i
        k = i - 1
        while k >= 0:
            stripped = lines[k].lstrip()
            if stripped.startswith('///') or stripped.startswith('//!'):
                k -= 1
            elif stripped == '':
                if k > 0 and (lines[k - 1].lstrip().startswith('///')
                              or lines[k - 1].lstrip().startswith('//!')):
                    k -= 1
                else:
                    break
            else:
                break
        start = k + 1

        end_info = None
        if (' struct {' in ln or ' union(' in ln or ' union(enum)' in ln
                or ' enum {' in ln):
            end_info = find_brace_end(i, lines)
        else:
            end_info = find_simple_end(i, lines)

        if end_info is None:
            raise RuntimeError(f'Failed to find end for {name} at line {i + 1}')

        end_line, _ = end_info
        body_lines = lines[start:end_line + 1]
        body_lines.append('')  # trailing blank line for spacing
        body_text = '\n'.join(body_lines)
        blocks[name] = {
            'start': start,
            'end': end_line,
            'body': body_text,
        }
        i = end_line + 1
    return blocks


# ============================================================================
# Nested-template-pub-const extractor (INSIDE Expr union body)
# ============================================================================
NESTED_RE = re.compile(r'^    pub const (\w+) = ')


def find_nested_pub_const_block(union_body_lines, name):
    """Find (doc_start, end_inclusive) of a 4-space-indented pub const
    inside the Expr union body (NOT top-level). Walks back for doc comments.
    """
    target_re = re.compile(r'^    pub const ' + re.escape(name) + r' = ')
    for i, ln in enumerate(union_body_lines):
        if not target_re.match(ln):
            continue
        # Walk back for doc comments (4-space-indented `///`).
        doc_start = i
        k = i - 1
        while k >= 0:
            stripped = union_body_lines[k].lstrip()
            if stripped.startswith('///') or stripped.startswith('//!'):
                k -= 1
            elif stripped == '':
                if k > 0 and (union_body_lines[k - 1].lstrip().startswith('///')
                              or union_body_lines[k - 1].lstrip().startswith('//!')):
                    k -= 1
                else:
                    break
            else:
                break
        doc_start = k + 1
        end_info = find_brace_end(i, union_body_lines)
        if end_info is None:
            raise RuntimeError(f'Failed to find end of nested {name}')
        return (doc_start, end_info[0])
    return None


def deindent4(text):
    """Remove leading 4-space indent from each line (so a nested pub
    const becomes a top-level one in template.zig)."""
    out_lines = []
    for ln in text.split('\n'):
        if ln.startswith('    '):
            out_lines.append(ln[4:])
        elif ln == '':
            out_lines.append('')
        else:
            out_lines.append(ln)
    return '\n'.join(out_lines)


# ============================================================================
# Sub-file writer
# ============================================================================
def write_subfile(group_name, type_names, blocks):
    parts = [SUBFILE_IMPORTS[group_name], '']
    parts.append('// ============================================================')
    parts.append(f'// {group_name} — top-level types from src/ast.zig')
    parts.append('// ============================================================')
    parts.append('')

    ordered = sorted(type_names, key=lambda n: blocks[n]['start'])
    for n in ordered:
        parts.append(blocks[n]['body'].rstrip())
        parts.append('')
    return '\n'.join(parts) + '\n'


def write_template_zig(expr_blocks_extracted):
    """expr_blocks_extracted is list of (name, indented_text) tuples
    in source order."""
    parts = [SUBFILE_IMPORTS['template.zig'], '']
    parts.append('// ============================================================')
    parts.append('// template.zig — template-literal types extracted from the')
    parts.append('// Expr union body. Each type lives at TOP-LEVEL here; the')
    parts.append('// original nested `pub const` inside Expr is replaced with')
    parts.append('// a re-export alias so `ast.Expr.TemplateLitExpr` and')
    parts.append('// `ast.TemplateLitExpr` resolve to the same struct type.')
    parts.append('// ============================================================')
    parts.append('')
    for name, indented_text in expr_blocks_extracted:
        parts.append(deindent4(indented_text).rstrip())
        parts.append('')
    return '\n'.join(parts) + '\n'


# ============================================================================
# Aggregator
# ============================================================================
AGGREGATOR_TEMPLATE = '''// Aggregator: src/ast.zig
//
// Re-exports all top-level types from the 5 sub-files. Nested union
// member types (e.g. ast.Expr.BinaryOp, ast.Stmt.IfStmt, ast.StructField
// .StructFieldKind.NamedField) remain accessible via the parent union
// or struct's NAMESPACE — no per-type re-export needed because they're
// already on the qualified type.

const ast_top = @import("ast/top.zig");
const ast_expr = @import("ast/expr.zig");
const ast_stmt = @import("ast/stmt.zig");
const ast_decl = @import("ast/decl.zig");
const ast_template = @import("ast/template.zig");

// Loc + Arena + Program (top-file utility types).
pub const Loc = ast_top.Loc;
pub const Arena = ast_top.Arena;
pub const Program = ast_top.Program;

// Expr union + Expr's nested member types stay on `ast.Expr.*` —
// External callers using `ast.Expr.BinaryOp`, `ast.Expr.NewExpr`,
// `ast.Expr.MatchArm` (sic, MatchExpr actually — re-exports below),
// etc. resolve via the Expr namespace.
// For top-level types also referenced outside Expr namespace:
pub const Expr = ast_expr.Expr;
pub const Pattern = ast_expr.Pattern;
// MatchArm is a TOP-LEVEL type (in expr.zig, not nested in Expr).
pub const MatchArm = ast_expr.MatchArm;

// Stmt union + its nested type aliases stay on `ast.Stmt.*`.
pub const Stmt = ast_stmt.Stmt;
// BindingKind / BindingPattern / RestBinding are top-level.
pub const BindingKind = ast_stmt.BindingKind;
pub const BindingPattern = ast_stmt.BindingPattern;
pub const RestBinding = ast_stmt.RestBinding;

// Decl-side types (all top-level).
pub const FunDecl = ast_decl.FunDecl;
pub const StructField = ast_decl.StructField;
pub const StructDecl = ast_decl.StructDecl;
pub const MethodParam = ast_decl.MethodParam;
pub const MethodDecl = ast_decl.MethodDecl;
pub const ImplBlock = ast_decl.ImplBlock;
pub const EnumDecl = ast_decl.EnumDecl;
pub const EnumVariant = ast_decl.EnumVariant;

// Template-literal types (extracted from Expr union body, now top-level).
pub const TemplateLitExpr = ast_template.TemplateLitExpr;
pub const TemplatePart = ast_template.TemplatePart;
'''


# ============================================================================
# Tool that rewrites Expr union body: replaces nested TemplateLitExpr/
# TemplatePart pub consts with re-export aliases.
# ============================================================================
def rewrite_expr_with_template_aliases(expr_body_text):
    """Walk the Expr union body lines. Replace nested-pub-const blocks
    for TemplateLitExpr and TemplatePart with re-export aliases."""
    lines = expr_body_text.split('\n')
    nested = []  # list of (name, doc_start, end_inclusive, block_lines)
    for n in NESTED_TEMPLATE_TYPES:
        info = find_nested_pub_const_block(lines, n)
        if info is None:
            print(f'!! Could not find nested pub const {n} in Expr')
            continue
        doc_start, end_inc = info
        block_text = '\n'.join(lines[doc_start:end_inc + 1])
        nested.append((n, doc_start, end_inc, block_text))
    nested.sort(key=lambda x: x[1])  # by doc_start ascending

    # Build replacement mask + replacement lines.
    new_lines = []
    i = 0
    skip_until = -1
    for (name, ds, ee, block_text) in nested:
        # Append lines from i to ds (exclusive).
        for k in range(i, ds):
            new_lines.append(lines[k])
        # Append re-export alias (kept inside Expr union body so
        # `ast.Expr.TemplateLitExpr` still resolves).
        new_lines.append(f'    // {name}: source of truth moved to template.zig;')
        new_lines.append(f'    // this alias keeps `ast.Expr.{name}` resolving.')
        new_lines.append(f'    pub const {name} = @import("template.zig").{name};')
        i = ee + 1
    # Append remaining lines.
    for k in range(i, len(lines)):
        new_lines.append(lines[k])

    # Extract the indented block texts (for template.zig as top-level
    # versions).
    extracted = []
    for (name, ds, ee, block_text) in nested:
        extracted.append((name, block_text))

    return ('\n'.join(new_lines), extracted)


def main():
    with open(SOURCE_PATH) as f:
        src = f.read()
    lines = src.split('\n')
    print(f'SOURCE: {SOURCE_PATH} = {len(lines)} lines')

    blocks = extract_top_level_types(lines)
    catalog = set()
    for v in TOP_LEVEL_GROUPS.values():
        catalog.update(v)
    found = set(blocks.keys())
    missing = catalog - found
    extra = found - catalog
    if missing:
        print(f'!! MISSING from blocks: {sorted(missing)} (these should be auto-populated from Expr body)')
    if extra:
        print(f'!! EXTRA in blocks (not in groups): {sorted(extra)}')

    # Special-case: TemplateLitExpr + TemplatePart live nested inside Expr.
    # Rewrite Expr body to replace nested pub consts with aliases.
    expr_body_text = blocks['Expr']['body']
    new_expr_body, extracted_template_blocks = rewrite_expr_with_template_aliases(
        expr_body_text)
    blocks['Expr']['body'] = new_expr_body
    name_set = set(TOP_LEVEL_GROUPS['template.zig'])
    for name, _ in extracted_template_blocks:
        if name not in name_set:
            print(f'!! Extracted template type {name} not added to template.zig group')
        else:
            # Make sure it's treated as top-level for downstream validation
            # (catalog comparison).
            catalog.add(name)
    TOP_LEVEL_GROUPS['template.zig'] = [n for n, _ in extracted_template_blocks]
    # Inject extractor-output blocks as "blocks" entries so the writer
    # iterates them uniformly. Use a synthesized start index based on
    # creation order.
    synth_start_base = max(b['end'] for b in blocks.values()) + 100
    for idx, (name, block_text) in enumerate(extracted_template_blocks):
        blocks[name] = {
            'start': synth_start_base + idx,
            'end': synth_start_base + idx,
            'body': block_text,
        }

    missing = set()
    for v in TOP_LEVEL_GROUPS.values():
        for n in v:
            if n not in blocks:
                missing.add(n)
    if missing:
        print(f'!! Still MISSING: {sorted(missing)}')

    os.makedirs(OUT_DIR, exist_ok=True)
    for group_name, type_names in TOP_LEVEL_GROUPS.items():
        if not type_names:
            # Skip empty groups; template.zig has its own writer.
            continue
        body = write_subfile(group_name, type_names, blocks)
        path = f'{OUT_DIR}/{group_name}'
        with open(path, 'w') as f:
            f.write(body)
        lc = sum(1 for _ in open(path))
        print(f'  {path}: {lc} lines (top-level: {len(type_names)})')

    # Write template.zig via its dedicated writer.
    template_body = write_template_zig(extracted_template_blocks)
    template_path = f'{OUT_DIR}/template.zig'
    with open(template_path, 'w') as f:
        f.write(template_body)
    lc = sum(1 for _ in open(template_path))
    print(f'  {template_path}: {lc} lines (extracted: {len(extracted_template_blocks)})')

    # Aggregator.
    with open(SOURCE_PATH, 'w') as f:
        f.write(AGGREGATOR_TEMPLATE)
    aggr_lines = sum(1 for _ in open(SOURCE_PATH))
    print(f'  {SOURCE_PATH}: {aggr_lines} lines (aggregator)')

    total_after = aggr_lines + sum(
        sum(1 for _ in open(f'{OUT_DIR}/{g}'))
        for g in ('top.zig', 'expr.zig', 'stmt.zig', 'decl.zig', 'template.zig')
    )
    print(f'TOTAL: {len(lines)} → {total_after} lines across '
          f'{1 + 5} files (was 938 LOC in one file)')


if __name__ == '__main__':
    main()
