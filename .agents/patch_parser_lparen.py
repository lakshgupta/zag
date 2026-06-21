#!/usr/bin/env python3
"""Surgical edits to src/parser.zig's .lparen arm.

1. Insert named-tuple `(name: expr, ...)` lookahead before "Parse first expression".
2. Detect single-element `(expr,)` and route to .single_tuple_lit.
"""
import sys

path = 'src/parser.zig'
text = open(path, 'r').read()
EM = '\u2014'  # actual em-dash char used in source comments

# ===== Change 1: named-tuple lookahead before "Parse first expression" =====
old1 = (
    '                // Parse first expression ' + EM + ' delegate via the top of the\n'
    '                // precedence ladder so `(1 + 2)` is parsed as a full\n'
    '                // binary expression rather than just a primary.'
)
if old1 not in text:
    print('CHANGE 1 FAILED: anchor not found')
    # Diagnostic: find parts of anchor
    for piece in ['// Parse first expression', 'delegate via the top', 'binary expression rather']:
        idx = text.find(piece)
        if idx >= 0:
            print(f'  found "{piece[:40]}..." at byte {idx}: "{text[idx:idx+60]}"')
    sys.exit(1)

new1 = '''                // Lookahead: named tuple `(name: expr, ...)`. Two-token
                // discriminator: identifier followed by COLON. Distinct
                // from struct-lit (which uses `{`) and from positional
                // / single-element (which starts with a non-ident or an
                // ident NOT followed by colon). Rust / Python tuple
                // syntax convention.
                if (self.peek().tag == .identifier and
                    self.pos + 1 < self.tokens.len and
                    self.tokens[self.pos + 1].tag == .colon)
                {
                    var names_buf: [32][]const u8 = undefined;
                    var named_elems_buf: [32]Expr = undefined;
                    var named_count: usize = 0;
                    while (self.peek().tag != .rparen and !self.eof()) {
                        names_buf[named_count] = self.expectIdent();
                        self.expect(.colon);
                        named_elems_buf[named_count] = self.parseExpr();
                        named_count += 1;
                        if (self.peek().tag == .comma) {
                            self.advance();
                            // Allow trailing comma `(x: 10, y: 20,)`.
                            if (self.peek().tag == .rparen) break;
                        } else break;
                    }
                    self.expect(.rparen);
                    const names_alloc = self.arena.alloc([]const u8, named_count);
                    @memcpy(names_alloc, names_buf[0..named_count]);
                    const elements_alloc = self.arena.alloc(Expr, named_count);
                    @memcpy(elements_alloc, named_elems_buf[0..named_count]);
                    return .{ .named_tuple_lit = .{ .names = names_alloc, .elements = elements_alloc } };
                }
                // Parse first expression ''' + EM + ''' delegate via the top of the
                // precedence ladder so `(1 + 2)` is parsed as a full
                // binary expression rather than just a primary.'''

text = text.replace(old1, new1, 1)
print('CHANGE 1 OK: inserted named-tuple lookahead before "Parse first expression"')

# ===== Change 2: single-element detection in comma-follows block =====
# Anchor: unique predecessor "If a comma follows, this is a tuple literal" + 1 line
old2_anchor = '                // If a comma follows, this is a tuple literal\n'
old2_block_start = '                if (self.peek().tag == .comma) {\n                    self.advance();\n                    elements_buf[element_count] = self.parseExpr();\n                    element_count += 1;'

old2_full = old2_anchor + old2_block_start
if old2_full not in text:
    # Try without the comment (just the if-block)
    if old2_block_start not in text:
        print('CHANGE 2 FAILED: anchor not found')
        sys.exit(1)
    # Do partial replace using just the block
    old2_full = old2_block_start

new2_full = (
    '                // If a comma follows, this is a tuple literal\n'
    '                // (multi-element or single-element `(expr,)`).\n'
    '                // The single-element form is captured via the\n'
    '                // dedicated `.single_tuple_lit` variant so codegen\n'
    '                // and downstream tests can distinguish it from\n'
    '                // paren-grouping `(expr)` at the AST level. The\n'
    '                // trailing-comma disambiguator follows Rust /\n'
    '                // Python tuple syntax conventions.\n'
    + (
        '                if (self.peek().tag == .comma) {\n'
        '                    self.advance();\n'
        '                    // Single-element `(expr,)` — distinguishing\n'
        '                    // from `()` (empty tuple) and `(expr)`\n'
        '                    // (paren-group) is the trailing comma,\n'
        '                    // surfacing in zig as `.{ expr }` (one-field\n'
        '                    // anonymous struct).\n'
        '                    if (self.peek().tag == .rparen) {\n'
        '                        self.advance();\n'
        '                        const single = self.arena.alloc(Expr, 1);\n'
        '                        single[0] = elements_buf[0];\n'
        '                        return .{ .single_tuple_lit = &single[0] };\n'
        '                    }\n'
        '                    elements_buf[element_count] = self.parseExpr();\n'
        '                    element_count += 1;'
    )
)

text = text.replace(old2_full, new2_full, 1)
print('CHANGE 2 OK: inserted single-element detection in comma-follows block')

open(path, 'w').write(text)

# Verify both new variants are now present
import subprocess
print()
print('=== verify named_tuple_lit present ===')
print(subprocess.run(['grep', '-c', 'named_tuple_lit', path], capture_output=True, text=True).stdout.strip())
print('=== verify single_tuple_lit present ===')
print(subprocess.run(['grep', '-c', 'single_tuple_lit', path], capture_output=True, text=True).stdout.strip())
print('=== show the named-tuple detection block ===')
subprocess.run(['grep', '-A', '20', 'Lookahead: named tuple', path])
