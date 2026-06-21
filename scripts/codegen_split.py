#!/usr/bin/env python3
"""Split src/codegen.zig into 5 sub-files + thin aggregator.

Architecture (mirrors the parser split):
  - 6 file-scope helpers (init, write, generate, isFloatIdentType,
    isFloatTypeName, isClosureBound) in core.zig, all `pub fn`.
  - 5 file-scope decl-emitter methods in decl.zig.
  - 8 file-scope stmt-emitter methods in stmt.zig.
  - 1 file-scope expr-emitter method in expr.zig.
  - 7 file-scope primary-emitter items (3 free fns + 4 methods)
    in primary.zig.
  - Codegen struct in core.zig holds only the 8 FIELDS + 24 method aliases.
  - Each sub-file (decl/stmt/expr/primary) re-exports the Codegen type
    from core plus any cross-bucket free helpers called unprefixed:
    stmt → primary {inferZigTypeFromExpr, getTopElements}; expr →
    primary {needsIntDivShim} (called unprefixed from genExpr's .binary arm).
  - TemplateCtx enum (originally INSIDE the Codegen struct body at L1805)
    moves to module-file scope in primary.zig and is re-exposed by the
    aggregator for backward compatibility.

Iteration 2 fixes:
  - Added `const Codegen = core.Codegen;` to all sub-file imports
    (was missing -> `use of undeclared identifier 'Codegen'` at all
    methods that mention `*Codegen` in their signature).
  - Added `const needsIntDivShim = @import("primary.zig").needsIntDivShim;`
    to expr.zig (genExpr calls it unprefixed in the .binary arm).
  - Fixed TemplateCtx extraction: it's a single-line const, no extra `}`.
"""

import os
import re

SOURCE_PATH = 'src/codegen.zig'
OUT_DIR = 'src/codegen'

# ============================================================================
# Categorization (verified by code_searcher: 27 fn decls total)
# ============================================================================
BUCKETS = {
    'core':    ['init', 'write', 'generate', 'isFloatIdentType',
                'isFloatTypeName', 'isClosureBound'],
    'decl':    ['genFreeMethod', 'genStructDecl', 'genMethod',
                'genEnumDecl', 'genFun'],
    'stmt':    ['collectTypedBindings', 'genDocComment', 'genStmt',
                'genBinding', 'genBindingLeaves', 'genElseBranch',
                'genMatchExpr', 'emitPatternCond'],
    'expr':    ['genExpr'],
    'primary': ['inferZigTypeFromExpr', 'getTopElements',
                'exprContainsFloat',  # free fn
                'needsIntDivShim', 'genPrintCall', 'genArrayLit',
                'genTemplateLit'],
}

# Method aliases on the Codegen struct (called via self.X or Codegen.METHOD()).
# Free fns (isFloatTypeName/inferZigTypeFromExpr/getTopElements/exprContainsFloat)
# are NOT aliased — called unprefixed from within their file only.
METHOD_ALIASES = {
    'init':                '@import("core.zig").init',
    'write':               '@import("core.zig").write',
    'generate':            '@import("core.zig").generate',
    'isFloatIdentType':    '@import("core.zig").isFloatIdentType',
    'isClosureBound':      '@import("core.zig").isClosureBound',
    'genFreeMethod':       '@import("decl.zig").genFreeMethod',
    'genStructDecl':       '@import("decl.zig").genStructDecl',
    'genMethod':           '@import("decl.zig").genMethod',
    'genEnumDecl':         '@import("decl.zig").genEnumDecl',
    'genFun':              '@import("decl.zig").genFun',
    'collectTypedBindings':'@import("stmt.zig").collectTypedBindings',
    'genDocComment':       '@import("stmt.zig").genDocComment',
    'genStmt':             '@import("stmt.zig").genStmt',
    'genBinding':          '@import("stmt.zig").genBinding',
    'genBindingLeaves':    '@import("stmt.zig").genBindingLeaves',
    'genElseBranch':       '@import("stmt.zig").genElseBranch',
    'genMatchExpr':        '@import("stmt.zig").genMatchExpr',
    'emitPatternCond':     '@import("stmt.zig").emitPatternCond',
    'genExpr':             '@import("expr.zig").genExpr',
    'needsIntDivShim':     '@import("primary.zig").needsIntDivShim',
    'genPrintCall':        '@import("primary.zig").genPrintCall',
    'genArrayLit':         '@import("primary.zig").genArrayLit',
    'genTemplateLit':      '@import("primary.zig").genTemplateLit',
}

# Cross-bucket file-scope re-exports per sub-file. Two kinds:
#   - `const Codegen = core.Codegen;` because receiver-type file-scope fns
#     (e.g. `pub fn (self: *Codegen) NAME(...)` at file scope) mention
#     `*Codegen` in their signatures (5+1+1+4 = 11 sub-file methods do).
#   - Free-helper re-exports for unprefixed file-scope calls where the
#     target lives in another sub-file (no `self.` routing possible).
CROSS_BUCKET_REEXPORTS = {
    'decl': [
        'const Codegen = core.Codegen;',
    ],
    'stmt': [
        'const Codegen = core.Codegen;',
        'const inferZigTypeFromExpr = @import("primary.zig").inferZigTypeFromExpr;',
        'const getTopElements = @import("primary.zig").getTopElements;',
    ],
    'expr': [
        'const Codegen = core.Codegen;',
        'const needsIntDivShim = @import("primary.zig").needsIntDivShim;',
    ],
    'primary': [
        'const Codegen = core.Codegen;',
    ],
}


# ============================================================================
# Source parsing
# ============================================================================
def find_brace_end(start_idx, lines, opener='{', closer='}'):
    """Walk forward from start_idx, counting {/} (with comment/string awareness)
    until depth returns to 0. Returns (end_line, end_col)."""
    depth = 0
    state = 'NORMAL'
    saw_open = False
    i = start_idx
    while i < len(lines):
        ln = lines[i]
        j = 0
        if i == start_idx:
            j = ln.find(opener) + 1
            depth = 1
            saw_open = True
            if j <= 0:
                i += 1
                continue
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
                if ch == opener:
                    depth += 1
                elif ch == closer:
                    depth -= 1
                    if depth == 0 and saw_open:
                        return (i, j)
                j += 1
            elif state == 'LINE':
                j += 1
                if j >= len(ln):
                    state = 'NORMAL'
                    break
            elif state == 'BLOCK':
                j += 1
                if j + 1 < len(ln) and ln[j] == '*' and ln[j + 1] == '/':
                    state = 'NORMAL'
                    j += 2
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


def main():
    with open(SOURCE_PATH) as f:
        src = f.read()
    lines = src.split('\n')
    print(f'TOTAL LINES: {len(lines)}')

    struct_open = None
    for i, ln in enumerate(lines):
        if 'pub const Codegen = struct {' in ln:
            struct_open = i
            break
    assert struct_open is not None, 'Codegen struct not found'

    struct_close_line, _ = find_brace_end(struct_open, lines)
    assert struct_close_line is not None, 'Codegen struct close not found'

    # `TemplateCtx` is a SINGLE-LINE const inside the struct body (L1805).
    template_ctx_text = None
    for i, ln in enumerate(lines):
        if 'const TemplateCtx = enum {' in ln:
            template_ctx_text = ln
            break
    assert template_ctx_text is not None, 'TemplateCtx const not found'

    # Enumerate all method decls inside the struct.
    decl_re = re.compile(r'^    (pub )?fn (\w+)\(')
    method_decls = {}
    for li in range(struct_open + 1, struct_close_line):
        m = decl_re.match(lines[li])
        if m:
            name = m.group(2)
            if name not in method_decls:
                method_decls[name] = li

    catalog = set()
    for v in BUCKETS.values():
        catalog.update(v)
    print(f'struct_open L{struct_open + 1}, struct_close L{struct_close_line + 1}')
    print(f'decls found: {len(method_decls)}; catalog: {len(catalog)}')
    missing = catalog - set(method_decls.keys())
    extra = set(method_decls.keys()) - catalog
    if missing:
        print(f'!! MISSING: {sorted(missing)}')
    if extra:
        print(f'!! EXTRA: {sorted(extra)}')

    # Extract each method's body (incl. decl signature line through closing `}`).
    # CRITICAL: promote `fn NAME(` → `pub fn NAME(` on the FIRST line of the
    # extracted body. zig 0.16's cross-module visibility rule: a method
    # defined `fn NAME` in core.zig can only be aliased by sibling files
    # (decl/stmt/expr/primary) if it's marked `pub`. The parser split
    # hit the same compile error and resolves it identically. We only
    # touch the declaration line — INNER `fn` definitions inside the body
    # (e.g. nested helpers, local closures) keep their original visibility
    # because they don't need to cross module boundaries.
    bodies = {}
    for name, decl in method_decls.items():
        end_line, _ = find_brace_end(decl, lines)
        assert end_line is not None, f'body not found for {name}'
        body_lines = lines[decl:end_line + 1]
        first = body_lines[0]
        # Match `    fn NAME(` → `    pub fn NAME(`; leave `    pub fn ...` alone.
        if first.startswith('    fn ') and not first.startswith('    pub fn '):
            body_lines[0] = '    pub ' + first
        bodies[name] = '\n'.join(body_lines)

    assert len(bodies) == len(method_decls)

    # Fields block: from struct_open+1 to first decl - 1.
    first_decl = min(method_decls.values())
    fields_text = '\n'.join(lines[struct_open + 1:first_decl])

    # ============================================================================
    # Generate sub-files
    # ============================================================================
    os.makedirs(OUT_DIR, exist_ok=True)

    # ---- core.zig ----
    # CRITICAL: emit `pub const NAME = ...` (NOT `NAME: ...,`) so the
    # alias is publicly visible AND a true compile-time constant rather
    # than a struct field. `pub const` matches the parser split's
    # pattern (verified in src/parser/core.zig). Without this, zig 0.16
    # treats the entry as a private struct field with the wrong shape and
    # `Codegen.init()` (called 51+ times across main + tests) fails with
    # "struct 'codegen.core.Codegen' has no member named 'init'".
    core_aliases_text = '\n'.join(
        f'    pub const {n} = {alias};' for n, alias in sorted(METHOD_ALIASES.items())
    )
    core_zig_parts = [
        'const std = @import("std");',
        'const ast = @import("../ast.zig");',
        '',
        '/// Lightweight per-function type-info map entry. Lives next to',
        '/// `Codegen` rather than in `ast.zig` because the caller has no',
        '/// use for the map after compilation — only the shim predicates',
        '/// consume its lifetime.',
        'const BindingTypeInfo = struct {',
        '    name: []const u8,',
        '    type_name: []const u8,',
        '    is_closure: bool = false,',
        '};',
        '',
        'pub const Codegen = struct {',
        fields_text,
        '',
        core_aliases_text,
        '};',
        '',
        '// ============================================================',
        '// FILE-SCOPE methods (CORE_INLINE bucket)',
        '// ============================================================',
    ]
    for n in BUCKETS['core']:
        core_zig_parts.append('')
        core_zig_parts.append(bodies[n])
    core_zig = '\n'.join(core_zig_parts) + '\n'
    with open(f'{OUT_DIR}/core.zig', 'w') as f:
        f.write(core_zig)

    # ---- decl.zig ----
    decl_parts = [
        'const std = @import("std");',
        'const ast = @import("../ast.zig");',
        'const core = @import("core.zig");',
        '',
        '// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in',
        '// the extraction script for rationale.',
    ]
    for line in CROSS_BUCKET_REEXPORTS['decl']:
        decl_parts.append(line)
    decl_parts.extend([
        '',
        '// ============================================================',
        '// FILE-SCOPE methods (DECL bucket)',
        '// ============================================================',
    ])
    for n in BUCKETS['decl']:
        decl_parts.append('')
        decl_parts.append(bodies[n])
    with open(f'{OUT_DIR}/decl.zig', 'w') as f:
        f.write('\n'.join(decl_parts) + '\n')

    # ---- stmt.zig ----
    stmt_parts = [
        'const std = @import("std");',
        'const ast = @import("../ast.zig");',
        'const core = @import("core.zig");',
        '',
        '// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in',
        '// the extraction script for rationale.',
    ]
    for line in CROSS_BUCKET_REEXPORTS['stmt']:
        stmt_parts.append(line)
    stmt_parts.extend([
        '',
        '// ============================================================',
        '// FILE-SCOPE methods (STMT bucket)',
        '// ============================================================',
    ])
    for n in BUCKETS['stmt']:
        stmt_parts.append('')
        stmt_parts.append(bodies[n])
    with open(f'{OUT_DIR}/stmt.zig', 'w') as f:
        f.write('\n'.join(stmt_parts) + '\n')

    # ---- expr.zig ----
    expr_parts = [
        'const std = @import("std");',
        'const ast = @import("../ast.zig");',
        'const core = @import("core.zig");',
        '',
        '// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in',
        '// the extraction script for rationale.',
    ]
    for line in CROSS_BUCKET_REEXPORTS['expr']:
        expr_parts.append(line)
    expr_parts.extend([
        '',
        '// ============================================================',
        '// FILE-SCOPE methods (EXPR bucket)',
        '// ============================================================',
    ])
    for n in BUCKETS['expr']:
        expr_parts.append('')
        expr_parts.append(bodies[n])
    with open(f'{OUT_DIR}/expr.zig', 'w') as f:
        f.write('\n'.join(expr_parts) + '\n')

    # ---- primary.zig ----
    primary_parts = [
        'const std = @import("std");',
        'const ast = @import("../ast.zig");',
        'const core = @import("core.zig");',
        '',
        '// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in',
        '// the extraction script for rationale.',
    ]
    for line in CROSS_BUCKET_REEXPORTS['primary']:
        primary_parts.append(line)
    primary_parts.extend([
        '',
        template_ctx_text,
        '',
        '// ============================================================',
        '// FILE-SCOPE methods and free helpers (PRIMARY bucket)',
        '// ============================================================',
    ])
    for n in BUCKETS['primary']:
        primary_parts.append('')
        primary_parts.append(bodies[n])
    with open(f'{OUT_DIR}/primary.zig', 'w') as f:
        f.write('\n'.join(primary_parts) + '\n')

    # ---- aggregator: src/codegen.zig ----
    aggr = '''const codegen_core = @import("codegen/core.zig");
const codegen_primary = @import("codegen/primary.zig");

pub const Codegen = codegen_core.Codegen;
pub const BindingTypeInfo = codegen_core.BindingTypeInfo;
pub const TemplateCtx = codegen_primary.TemplateCtx;
'''
    with open(SOURCE_PATH, 'w') as f:
        f.write(aggr)

    # Summary
    for sub in ('core', 'decl', 'stmt', 'expr', 'primary'):
        path = f'{OUT_DIR}/{sub}.zig'
        lc = sum(1 for _ in open(path))
        pub_fn = sum(1 for ln in open(path) if ln.startswith('pub fn '))
        nb_methods = len(BUCKETS[sub])
        print(f'{path}: {lc} lines, {pub_fn} pub fn ({nb_methods} methods)')
    lc = sum(1 for _ in open(SOURCE_PATH))
    print(f'{SOURCE_PATH}: {lc} lines (aggregator)')


if __name__ == '__main__':
    main()
