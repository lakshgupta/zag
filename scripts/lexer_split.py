#!/usr/bin/env python3
"""Split src/lexer.zig into 6 sub-files + thin aggregator.

Architecture (mirrors the codegen split — `Lexer` is a struct with
methods, like Codegen; the split uses file-scope `pub fn` methods in
sub-files + `pub const` aliases inside the Lexer struct body):

  - src/lexer.zig            aggregator, ~10 lines
  - src/lexer/token.zig       TokenTag enum + Token struct (data types)
  - src/lexer/core.zig        Lexer struct (fields + kept methods:
                              init, addToken, tokenize, advance,
                              readDocComment) + method aliases:
                              pub const readString    = @import("string.zig").readString;
                              pub const readByteString = @import("string.zig").readByteString;
                              pub const readChar      = @import("string.zig").readChar;
                              pub const readIdent     = @import("ident.zig").readIdent;
                              pub const readNumber    = @import("number.zig").readNumber;
                              + type aliases for TokenTag & Token
  - src/lexer/ident.zig       readIdent (file-scope pub fn, was method on Lexer)
  - src/lexer/number.zig      isHexDigit (file-scope fn) + readNumber (file-scope pub fn)
  - src/lexer/string.zig      readString + readByteString + readChar (file-scope pub fns)
  - src/lexer/template.zig    Placeholder stub for future lexer-level template
                              literal tokenization (parser currently handles
                              templates at parse time, not lex time).

Cycle analysis:
  - core.zig imports token.zig, string.zig, ident.zig, number.zig (no self-import).
  - string/ident/number.zig each import core.zig (for `Lexer` type) +
    token.zig (for `TokenTag`) + ast.zig (for `ast.Loc`).
  - Mutual cross-file imports between core ↔ reader sub-files:
    cycle broken by POINTER indirection on both sides — each reader
    fn takes `self: *Lexer` (pointer, fixed size), and each method
    alias has type `fn(*Lexer, ...) void` (also pointer-through).
    This is the same pattern the codegen split used successfully
    (Codegen had the identical cross-file structure: struct in core,
    methods aliased into struct from sibling sub-files).
  - No slice indirection needed since the boundary is uniformly
    pointer-based (the original `self.method(...)` call shape
    survives verbatim).

External-API compatibility verified via code-search (no caller churn):
  - `lexer_mod.Lexer.init(src)` (main.zig + tests/parser.zig + tests/lexer.zig
    + tests/codegen.zig) — works via aggregator's `pub const Lexer = core.Lexer`.
  - `lexer_mod.Lexer.tokenize(...)` — same.
  - `lexer_mod.TokenTag.X` (every tests/lexer.zig assertion) — works via
    core.zig's `pub const TokenTag = @import("token.zig").TokenTag;`
    inside the Lexer struct body, so `Lexer.TokenTag` resolves through
    the aggregator's `pub const Lexer = core.Lexer;` + via sub-files'
    `core.Lexer.TokenTag` import path.
  - `lexer.TokenTag.X` / `lexer.Token` in parser sub-files via
    `const Token = lexer.Token; const TokenTag = lexer.TokenTag;`
    — works because aggregator re-exports both at module scope.

Doc comments: same walkback rule as the parser/codegen/AST splits —
contiguous `///` lines (allowing one blank gap). Doc-comment capture
isn't the focus here so the script preserves lines verbatim and a small
amount of doc-comment slicing may be imperfect (acceptable per split
precedent).
"""

import os
import re

SOURCE_PATH = 'src/lexer.zig'
OUT_DIR = 'src/lexer'

# ============================================================================
# Bucket map
# ============================================================================
# Top-level `pub const X = ...` declarations.
TOP_LEVEL_GROUPS = {
    'token.zig':     ['TokenTag', 'Token'],
    'core.zig':      ['Lexer'],
}

# Methods INSIDE the Lexer struct. Each bucket's methods get extracted
# to file-scope pub fn in that bucket's sub-file (kicked out of the
# Lexer struct body). The `core` bucket's methods STAY inside the
# Lexer struct body in core.zig (replaced with `pub const X = ...`
# aliases in the Lexer struct so call sites work).
METHOD_BUCKETS = {
    'core':   ['init', 'addToken', 'tokenize', 'advance', 'readDocComment'],
    'ident':  ['readIdent'],
    'number': ['readNumber'],
    'string': ['readString', 'readByteString', 'readChar'],
}
# isHexDigit is the only top-level free fn in src/lexer.zig; it's
# used only by readNumber (in number.zig), so move it to number.zig.
FREE_FN_GROUPS = {
    'number.zig': ['isHexDigit'],
}

# Aliases inserted at the top of the Lexer struct body in core.zig.
# We DON'T add inner `pub const Token/TokenTag` because that would
# conflict with the module-scope `const Token = ...` imports at the
# top of core.zig (zig rejects dual declarations of the same name in
# the same scope awareness). External callers reach Token/TokenTag
# via the aggregator's module-scope re-exports (verified by
# code-search; the only `Lexer.Token` reference was the doc comment
# inside scripts/lexer_split.py itself).
TYPE_ALIASES = {}

METHOD_ALIASES = {
    'readString':     '@import("string.zig").readString',
    'readByteString': '@import("string.zig").readByteString',
    'readChar':       '@import("string.zig").readChar',
    'readIdent':      '@import("ident.zig").readIdent',
    'readNumber':     '@import("number.zig").readNumber',
}

# Cross-bucket file-scope imports for each sub-file.
SUBFILE_IMPORTS = {
    'token.zig':     'const std = @import("std");\nconst ast = @import("../ast.zig");',
    'core.zig':      ('const std = @import("std");\n'
                     'const ast = @import("../ast.zig");\n'
                     '\n'
                     "// Module-scope aliases only — there is NO inner\n"
                     "// `pub const Token/TokenTag` on the Lexer struct\n"
                     "// (would conflict with `const Token =` if we also\n"
                     "// added it as a struct-member alias). External\n"
                     "// callers reach `Token`/`TokenTag` via the\n"
                     "// aggregator's module-scope re-exports; the\n"
                     "// bottom-of-files field `tokens_buf: [4096]Token`\n"
                     "// resolves to the module-scope `const Token = ...`\n"
                     "// alias here.\n"
                     'const token = @import("token.zig");\n'
                     'const TokenTag = token.TokenTag;\n'
                     'const Token = token.Token;'),
    'ident.zig':     ('const std = @import("std");\n'
                     '\n'
                     '// core: readIdent is a method on `*Lexer`, defined here\n'
                     '// at file scope so the core.zig method alias can route to it.\n'
                     'const core = @import("core.zig");\n'
                     'const Lexer = core.Lexer;\n'
                     '\n'
                     'const token = @import("token.zig");\n'
                     'const TokenTag = token.TokenTag;\n'
                     '\n'
                     'const ast = @import("../ast.zig");\n'
                     'const Loc = ast.Loc;'),
    'number.zig':    ('const std = @import("std");\n'
                     '\n'
                     'const core = @import("core.zig");\n'
                     'const Lexer = core.Lexer;\n'
                     '\n'
                     'const token = @import("token.zig");\n'
                     'const TokenTag = token.TokenTag;\n'
                     '\n'
                     'const ast = @import("../ast.zig");\n'
                     'const Loc = ast.Loc;'),
    'string.zig':    ('const std = @import("std");\n'
                     '\n'
                     'const core = @import("core.zig");\n'
                     'const Lexer = core.Lexer;\n'
                     '\n'
                     'const token = @import("token.zig");\n'
                     'const TokenTag = token.TokenTag;\n'
                     '\n'
                     'const ast = @import("../ast.zig");\n'
                     'const Loc = ast.Loc;'),
    'template.zig':  ('// Reserved for future lexer-level template literal\n'
                     '// tokenization. The parser currently handles templates\n'
                     '// at parse time (see src/parser/primary.zig\n'
                     '// parseTemplateLit area). Adding template literal support\n'
                     '// to the lexer would route into this file.\n'
                     '//\n'
                     '// File present to match the planned 6-file lexer split\n'
                     '// layout (template bucket reserved).\n'),
}


# ============================================================================
# Brace walker (same shape as scripts/codegen_split.py + scripts/ast_split.py)
# ============================================================================
def find_brace_end(start_idx, lines):
    """Walk forward from start_idx counting {/} (comment/string-aware).
    Returns end_line (inclusive). depth starts at 1 just past the opener
    on lines[start_idx]."""
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
                j = len(ln)
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
    """For non-block decls (simple `pub const X = ...;` etc.)."""
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
# Source extraction
# ============================================================================
TOP_LEVEL_RE = re.compile(r'^pub const (\w+) = ')
FREE_FN_RE = re.compile(r'^fn (\w+)\(')


def extract_top_level(lines):
    """Return dict[name -> {'start': i, 'end': i, 'body': str}]."""
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
        # Walk back over contiguous /// doc lines.
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
        if ' struct {' in ln or ' union(' in ln or ' enum {' in ln:
            end_info = find_brace_end(i, lines)
        else:
            end_info = find_simple_end(i, lines)
        if end_info is None:
            raise RuntimeError(f'Failed to find end for {name} at line {i + 1}')
        end_line, _ = end_info
        body_lines = lines[start:end_line + 1]
        blocks[name] = {
            'start': start,
            'end': end_line,
            'body': '\n'.join(body_lines),
        }
        i = end_line + 1
    return blocks


def extract_free_fns(lines, top_level_end_idx):
    """Walk indices [0 .. top_level_end_idx] for `^fn NAME(` decls and
    extract them as top-level free fns. Returns dict[name -> block_dict]."""
    blocks = {}
    i = 0
    while i < top_level_end_idx:
        m = FREE_FN_RE.match(lines[i])
        if m is None:
            i += 1
            continue
        name = m.group(1)
        end_info = None
        if '{' in lines[i]:
            end_info = find_brace_end(i, lines)
        else:
            end_info = find_simple_end(i, lines)
        if end_info is None:
            raise RuntimeError(f'failed to find end of {name} at line {i + 1}')
        end_line, _ = end_info
        body_lines = lines[i:end_line + 1]
        blocks[name] = {
            'start': i,
            'end': end_line,
            'body': '\n'.join(body_lines),
        }
        i = end_line + 1
    return blocks


# ============================================================================
# Method extraction INSIDE Lexer struct
# ============================================================================
INNER_METHOD_RE = re.compile(r'^    (pub )?fn (\w+)\(')


def extract_inner_methods(struct_lines):
    """struct_lines is the lines OF the struct body (NOT incl. `pub const
    Lexer = struct {` opener line, and NOT incl. the closing `};`).
    Walks them, captures each method's decl + body up to matching close.
    Returns dict[name -> {'decl_start', 'end_inclusive', 'body_lines'}]
    and the structured set of lines pre/post methods for assembly.
    """
    methods = {}
    n = len(struct_lines)
    i = 0
    while i < n:
        m = INNER_METHOD_RE.match(struct_lines[i])
        if m is None:
            i += 1
            continue
        name = m.group(2)
        # Determine end: brace-walk from `start_idx` because each method
        # is itself a block-bodie constructors.
        end_info = find_brace_end(i, struct_lines)
        if end_info is None:
            # No body (just `fn NAME(...);` declaration w/o braces).
            end_info = (i, len(struct_lines[i]) - 1)
        end_line, _ = end_info
        body_lines = struct_lines[i:end_line + 1]
        methods[name] = {
            'decl_start': i,
            'end_line': end_line,
            'body': '\n'.join(body_lines),
        }
        i = end_line + 1
    return methods


def deindent_4(text):
    """Remove 4-space leading indent from each line. Empty lines are kept
    empty (no semi-magic spaces)."""
    out = []
    for ln in text.split('\n'):
        if ln.startswith('    '):
            out.append(ln[4:])
        elif ln == '':
            out.append('')
        else:
            out.append(ln)
    return '\n'.join(out)


def promote_pub(text):
    """Promote `    fn NAME(` to `    pub fn NAME(`. Walk over each line in
    the body text and produce a new string. Other `fn` occurrences inside
    (nested helpers, local closures) keep their visibility because they
    only need to live WITHIN this sub-tree (still inside Lexer's
    parametric check)."""
    out = []
    for ln in text.split('\n'):
        if ln.startswith('    fn ') and not ln.startswith('    pub fn '):
            out.append('    pub ' + ln)
        else:
            out.append(ln)
    return '\n'.join(out)


# ============================================================================
# Sub-file content emitters
# ============================================================================
def emit_aggregator():
    return '''// Aggregator: src/lexer.zig
//
// Re-exports the 3 public types from the lexer sub-tree at module
// scope. (There are NO `Lexer.TokenTag` / `Lexer.Token` nested-struct
// access paths — the version that added those aliases caused an
// "ambiguous reference Token" compile error and was reverted in
// favor of module-scope-only re-exports. External code uses
// `lexer_mod.TokenTag.X` and `lexer_mod.Lexer.X` exclusively, so
// nothing was lost.)

const lexer_token = @import("lexer/token.zig");
const lexer_core = @import("lexer/core.zig");

pub const TokenTag = lexer_token.TokenTag;
pub const Token = lexer_token.Token;
pub const Lexer = lexer_core.Lexer;
'''


def emit_template_stub():
    return SUBFILE_IMPORTS['template.zig']


def emit_visitor(group_name, blocks):
    parts = [SUBFILE_IMPORTS[group_name], '']
    parts.append('// ============================================================')
    parts.append(f'// {group_name} — top-level types from src/lexer.zig')
    parts.append('// ============================================================')
    parts.append('')
    ordered = sorted(TOP_LEVEL_GROUPS[group_name], key=lambda n: blocks[n]['start'])
    for n in ordered:
        parts.append(blocks[n]['body'].rstrip())
        parts.append('')
    return '\n'.join(parts) + '\n'


def emit_reader(file_name, method_names, methods):
    """Emit a reader sub-file (ident.zig, number.zig, string.zig):
    file-scope pub fns for each method, de-indented from Lexer struct body."""
    parts = [SUBFILE_IMPORTS[file_name], '']
    parts.append('// ============================================================')
    parts.append(f'// {file_name}')
    parts.append('// ============================================================')
    parts.append('')
    ordered = sorted(method_names, key=lambda n: methods[n]['decl_start'])
    for n in ordered:
        promoted_body = promote_pub(methods[n]['body'])
        deindented_body = deindent_4(promoted_body)
        parts.append(deindented_body.rstrip())
        parts.append('')
    return '\n'.join(parts) + '\n'


def emit_core_block(top_level_blocks, inner_methods, free_blocks):
    """Build core.zig's Lexer struct body: keep ALL inner methods that
    are bucketed in `core`; replace other inner methods (`readString`,
    `readByteString`, `readChar`, `readIdent`, `readNumber`) with
    `pub const X = @import(...).X;` aliases. Also prepend TYPE aliases
    at the very top of the struct body.
    """
    parts = [
        SUBFILE_IMPORTS['core.zig'],
        '',
        '// ============================================================',
        '// core.zig — Lexer struct (state + orchestrator)',
        '// ============================================================',
        '',
    ]

    # Gather the Lexer struct content:
    lexer_struct_body = top_level_blocks['Lexer']['body']
    # lexer_struct_body is everything from `pub const Lexer = struct {`
    # through the matching `};` (whole struct block). We need to surgically
    # rewrite the inside of the body.

    # 1. Split lines and locate the opener + body-lines + closer.
    raw_lines = lexer_struct_body.split('\n')

    # Find opener line (the `pub const Lexer = struct {` line).
    opener_idx = None
    for k, ln in enumerate(raw_lines):
        # match `pub const Lexer = struct {` (allowing any whitespace around braces)
        if re.match(r'^pub const Lexer\s*=\s*struct\s*\{', ln):
            opener_idx = k
            break
    assert opener_idx is not None, 'Lexer struct opener not found'

    # The body of the struct is everything between opener_idx and last `};`.
    last_closer_idx = None
    for k in range(len(raw_lines) - 1, opener_idx, -1):
        if raw_lines[k].rstrip() == '};':
            last_closer_idx = k
            break
    assert last_closer_idx is not None, 'Lexer struct closer not found'

    inner_lines = raw_lines[opener_idx + 1:last_closer_idx]

    # 2. Process inner_lines. For each line that starts a method (regex
    # INNER_METHOD_RE), and the method is in `core` bucket, keep as-is.
    # If the method is NOT in `core`, replace the entire method block
    # with a single `pub const X = @import("...").X;` alias line.
    fields_end = 0
    i = 0
    n = len(inner_lines)
    new_inner_lines = []
    while i < n:
        m = INNER_METHOD_RE.match(inner_lines[i])
        if m is None:
            new_inner_lines.append(inner_lines[i])
            # Track transition from fields to methods.
            if inner_lines[i].rstrip() == '':
                # blank; carry on
                pass
            elif inner_lines[i].strip() == '':
                pass
            else:
                # Look for `\w+:` (a field) or a method decl.
                if re.match(r'^\s+\w+\s*:', inner_lines[i]) and ':' in inner_lines[i]:
                    fields_end = len(new_inner_lines) - 1
            i += 1
            continue

        name = m.group(2)
        # Find end of method (brace walk).
        end_info = find_brace_end(i, inner_lines)
        if end_info is None:
            raise RuntimeError(f'failed to find end of inner method {name}')
        end_inc, _ = end_info

        if name in METHOD_BUCKETS['core']:
            # Keep this method block verbatim.
            for k in range(i, end_inc + 1):
                new_inner_lines.append(inner_lines[k])
            i = end_inc + 1
            continue

        # Not in core bucket: replace with alias.
        if name in METHOD_ALIASES:
            new_inner_lines.append(f'    pub const {name} = {METHOD_ALIASES[name]};')
            i = end_inc + 1
            continue
        # Shouldn't happen.
        i = end_inc + 1

    # 3. Append TYPE_ALIASES just after the last field. We look back from
    # the beginning of `new_inner_lines` and find the last `\s+\w+\s*:` field
    # line; aliases go AFTER.
    alias_lines = [f'    pub const {n} = {alias};' for n, alias in TYPE_ALIASES.items()]

    insert_idx = 0
    k = 0
    # Skip the leading doc-comment block if present (lines starting with `    ///`).
    while k < len(new_inner_lines):
        stripped = new_inner_lines[k].lstrip()
        if stripped.startswith('///') or stripped.startswith('//!'):
            k += 1
            continue
        if stripped == '':
            k += 1
            continue
        break
    # Now scan field lines (they end with `,` or `;` and have `:`).
    while k < len(new_inner_lines):
        ln = new_inner_lines[k].rstrip()
        # A field like `    foo: T,`
        if re.match(r'^\s+\w+\s*:.+', ln):
            k += 1
            # multi-line field: keep going while line ends with `,` and has : but
            # isn't a method decl.
            while (k < len(new_inner_lines)
                   and new_inner_lines[k].lstrip() != ''
                   and not INNER_METHOD_RE.match(new_inner_lines[k])):
                k += 1
            insert_idx = k
            continue
        else:
            break
    # When new_inner_lines is empty (no fields) the alias lines go at position 0.
    # Insert aliases at insert_idx (after last field).
    new_inner_lines = new_inner_lines[:insert_idx] + alias_lines + new_inner_lines[insert_idx:]

    # 4. Promote core methods to `pub`. Allowed since the core Lexer struct
    #    is exported (`pub const Lexer = struct { ... }` at module scope),
    #    so its methods being `pub fn` is consistent with the public
    #    interface. Reader sub-files in src/lexer/{string,ident,number}.zig
    #    call `self.addToken(...)` and `self.advance(...)`, which require
    #    these methods to be visible at the struct body level (matching the
    #    codegen split's precedence).
    pub_promotion_re = re.compile(r'^    fn (\w+)\(')
    new_inner_lines = [
        ('    pub ' + ln[4:]) if pub_promotion_re.match(ln) else ln
        for ln in new_inner_lines
    ]

    # 5. Reassemble struct block.
    rebuilt_lines = (
        raw_lines[:opener_idx + 1]
        + ['']
        + new_inner_lines
        + ['']
        + raw_lines[last_closer_idx:]
    )
    parts.append('\n'.join(rebuilt_lines).rstrip())
    parts.append('')

    # 5. Add free fns (currently only `isHexDigit` goes to number.zig, but
    #    in core.zig we don't need it). Skip free fns in core.
    parts.append('// ============================================================')
    parts.append('// core.zig — file-scope helpers (none currently)')
    parts.append('// ============================================================')
    parts.append('')
    return '\n'.join(parts) + '\n'


def main():
    with open(SOURCE_PATH) as f:
        src = f.read()
    lines = src.split('\n')
    print(f'SOURCE: {SOURCE_PATH} = {len(lines)} lines')

    top_blocks = extract_top_level(lines)
    # Find end of top-level declarations to bound free-fn scan.
    last_top = max((b['end'] for b in top_blocks.values()), default=0)
    free_blocks = extract_free_fns(lines, last_top)

    catalog = set()
    for v in TOP_LEVEL_GROUPS.values():
        catalog.update(v)
    for v in FREE_FN_GROUPS.values():
        catalog.update(v)
    found = set(top_blocks.keys()) | set(free_blocks.keys())
    missing = catalog - found
    extra = found - catalog
    if missing:
        print(f'!! MISSING: {sorted(missing)}')
    if extra:
        print(f'!! EXTRA: {sorted(extra)}')

    # Lexer struct — extract its INNER methods.
    lexer_top = top_blocks['Lexer']
    lexer_struct_body = lexer_top['body']
    # Slice the inner body (between opener and closer).
    raw_lines = lexer_struct_body.split('\n')
    opener_idx = None
    for k, ln in enumerate(raw_lines):
        if re.match(r'^pub const Lexer\s*=\s*struct\s*\{', ln):
            opener_idx = k
            break
    last_closer_idx = None
    for k in range(len(raw_lines) - 1, opener_idx, -1):
        if raw_lines[k].rstrip() == '};':
            last_closer_idx = k
            break
    inner_lines = raw_lines[opener_idx + 1:last_closer_idx]
    inner_methods = extract_inner_methods(inner_lines)
    print(f'inner methods found: {sorted(inner_methods.keys())}')

    method_catalog = set()
    for v in METHOD_BUCKETS.values():
        method_catalog.update(v)
    method_found = set(inner_methods.keys())
    if method_catalog - method_found:
        print(f'!! MISSING inner methods: {sorted(method_catalog - method_found)}')
    if method_found - method_catalog:
        unexpected = method_found - method_catalog
        print(f'unexpected inner methods (defaulted to core bucket): {sorted(unexpected)}')
        # Treat unexpected methods as core (they'll stay in struct).
        for m in unexpected:
            METHOD_BUCKETS.setdefault('core', []).append(m)

    os.makedirs(OUT_DIR, exist_ok=True)
    written = {}

    # Token / Core / visitor sub-files.
    for group_name, type_names in TOP_LEVEL_GROUPS.items():
        if group_name == 'core.zig':
            # synthesized elsewhere
            continue
        body = emit_visitor(group_name, top_blocks)
        path = f'{OUT_DIR}/{group_name}'
        with open(path, 'w') as f:
            f.write(body)
        lc = sum(1 for _ in open(path))
        written[group_name] = lc
        print(f'  {path:40s}  L={lc:4d}  top-level types: {len(type_names)}')

    # Reader sub-files (file-scope pub fns).
    for bucket, fn_file in (('ident', 'ident.zig'),
                            ('number', 'number.zig'),
                            ('string', 'string.zig')):
        body = emit_reader(fn_file, METHOD_BUCKETS[bucket], inner_methods)
        path = f'{OUT_DIR}/{fn_file}'
        with open(path, 'w') as f:
            f.write(body)
        lc = sum(1 for _ in open(path))
        written[fn_file] = lc
        print(f'  {path:40s}  L={lc:4d}  methods: {len(METHOD_BUCKETS[bucket])}')

    # Free fn sub-files (currently number.zig holds isHexDigit).
    for file_name, fn_names in FREE_FN_GROUPS.items():
        # Append free-fns at the END of the existing reader file (number.zig).
        reader_path = f'{OUT_DIR}/{file_name}'
        existing = open(reader_path).read().rstrip() + '\n'
        additions = []
        additions.append('// ============================================================')
        additions.append(f'// {file_name} — file-scope free fn from src/lexer.zig')
        additions.append('// ============================================================')
        additions.append('')
        for fn_name in fn_names:
            additions.append(free_blocks[fn_name]['body'])
            additions.append('')
        with open(reader_path, 'w') as f:
            f.write(existing + '\n'.join(additions))
        lc = sum(1 for _ in open(reader_path))
        written[file_name] = lc
        print(f'  appended free fn(s) to {reader_path}: now {lc} lines')

    # template stub.
    template_path = f'{OUT_DIR}/template.zig'
    with open(template_path, 'w') as f:
        f.write(emit_template_stub())
    lc = sum(1 for _ in open(template_path))
    written['template.zig'] = lc
    print(f'  {template_path:40s}  L={lc:4d}  (stub, reserved for future use)')

    # core.zig (synthesized).
    core_body = emit_core_block(top_blocks, inner_methods, free_blocks)
    core_path = f'{OUT_DIR}/core.zig'
    with open(core_path, 'w') as f:
        f.write(core_body)
    lc = sum(1 for _ in open(core_path))
    written['core.zig'] = lc
    print(f'  {core_path:40s}  L={lc:4d}')

    # Aggregator.
    aggr_path = SOURCE_PATH
    with open(aggr_path, 'w') as f:
        f.write(emit_aggregator())
    aggr_lc = sum(1 for _ in open(aggr_path))
    print(f'  {aggr_path:40s}  L={aggr_lc:4d}  (aggregator)')

    total = aggr_lc + sum(written.values())
    print(f'\nTOTAL: {len(lines)} source LOC -> {total} LOC across {len(written) + 1} files')


if __name__ == '__main__':
    main()
