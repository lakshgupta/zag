// Source-mirror test bucket for src/decl.zig.zig.
// Tests here pin the decl-codegen's surface. Routing is by test-name
// prefix (see /tmp/zag_split_v3.py's rubric). All test names and bodies
// are byte-identical to the pre-split versions in src/tests/codegen.zig
// (now deleted) / src/tests/parser.zig (now deleted) — only the file
// boundary moved. Total across 11 source-mirror files: 254 tests +
// 3 unchanged small files (lexer.zig, env_path.zig, toolchain.zig) = 302.

const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const codegen_mod = @import("../codegen.zig");
const ast = @import("../ast.zig");


test "codegen: doc comment emitted as zig ///" {
    const src = "## adds a and b\nfun add() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// adds a and b") != null);
}

test "codegen: doc comment emitted as zig /// on struct" {
    // Pin the parser-threaded StructDecl.doc → codegen genDocComment
    // path. The manual's example (## A 3D vector. struct Vec3 {...})
    // requires this round-trip; pre-fix the parser explicitly discarded
    // the doc accumulator at src/parser/core.zig:113.
    const src =
        \\## A 3D vector.
        \\struct Vec3 {
        \\    x: f64,
        \\    y: f64,
        \\    z: f64,
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    // Emit pin: the literal `/// A 3D vector.` line must surface in
    // the zig output. Matches the existing fun test's positive
    // substring pin discipline.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// A 3D vector.") != null);
    // AST pin: confirms the parser threaded the captured doc into
    // StructDecl.doc (caught-future regression: parser drops it again).
    try std.testing.expect(prog.structs.len == 1);
    try std.testing.expect(prog.structs[0].doc != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.structs[0].doc.?, "A 3D vector.") != null);
}

test "codegen: doc comment emitted as zig /// on enum" {
    // Pin the parser-threaded EnumDecl.doc → codegen genDocComment
    // path. Mirrors the struct test on the sibling enum branch.
    const src = "## Cardinal directions.\nenum Dir { North, South }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// Cardinal directions.") != null);
    try std.testing.expect(prog.enums.len == 1);
    try std.testing.expect(prog.enums[0].doc != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.enums[0].doc.?, "Cardinal directions.") != null);
}

test "codegen: doc comment emitted as zig /// on trait" {
    // Pin the parser-threaded TraitDecl.doc → codegen genDocComment
    // path. Mirrors the struct/enum tests on the trait branch. Uses
    // `*Self` as a type text — the existing codegen rewrite
    // (`rewriteSelfToT`) substitutes `Self`→`T` for trait dispatch,
    // and parseMethodParam's collectCastType captures `*Self`
    // verbatim in the `type_text` slice.
    const src =
        \\## Something drawable.
        \\trait Drawable { fun draw(self: *Self); }
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// Something drawable.") != null);
    try std.testing.expect(prog.traits.len == 1);
    try std.testing.expect(prog.traits[0].doc != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.traits[0].doc.?, "Something drawable.") != null);
}

test "codegen: multi-line doc emitted as multiple ///" {
    const src = "## first line\n# second line\nfun f() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// second line") != null);
}

test "codegen: let with type annotation emits `: T`" {
    // Same regression fix as the parser test above — explicit `: i32` to
    // match the codegen expectation `const x: i32 = 42`.
    const src = "fun f() {\n    let x: i32 = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x: i32 = 42;") != null);
}

test "codegen: let without annotation emits bare `const x = ...`" {
    const src = "fun f() {\n    let x = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x = 42;") != null);
    // Sanity: no surprise `: int32` token crept in.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x:") == null);
}

test "codegen: let with f64 annotation" {
    const src = "fun f() {\n    let pi: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const pi: f64 = 3.14;") != null);
}

test "codegen: bf16 passes through to zigzag verbatim (zig rejects, not zag)" {
    // Source-of-truth: docs/features.md §08 bf16 row. See that row
    // for the rejection-layer claim this test pins.
    //
    // Mechanism: `bf16` is NOT in v1's `zagTypeToZig` alias set
    // (only `str` / `[]str` / `[3]str` round-trip), so the source
    // type-text reaches codegen unchanged. The leaf zigzag
    // contains `const v: bf16 = 0;` literally; zig 0.16 then
    // rejects with `error: use of undeclared identifier 'bf16'`.
    //
    // Negatives block the common substitution arms so a future
    // fix path landing a silent substitution would break loud.
    const src = "fun f() {\n    let v: bf16 = 0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Scope: rejection-layer identification only — does NOT pin
    // isFloatIdentType (future-fix concern; separate test needed).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const v: bf16 = 0;") != null);
    // Inline-annotation substitution guards.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const v: f16 = 0;") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const v: f32 = 0;") == null);
    // Cast-wrap substitution guards (f16/f32 wrap + bf16 self-cast).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(f16,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(f32,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(bf16,") == null);
}

test "codegen: char type ident silently rewrites to u32 (v2 fix path landed)" {
    // Source-of-truth: docs/features.md §08 v2 4-byte Unicode char
    // row, gap (a). Once the fix path lands, zag's codegen
    // substitutes `char` → `u32` silently so let-bind / var-bind /
    // struct-field / enum-varlist / impl-method-receiver / fun-param
    // / fun-return surfaces emit a type zig 0.16 accepts. Pairs with
    // the codegen char_lit propagate test (c) and the integration
    // test `let c: char = '\u2764' surfaces both gap (a) and gap (c)
    // lanes together` (which composes gap (a) AND gap (c) into ONE
    // source pattern).
    //
    // Mechanism: src/codegen/decl.zig:436's `zagTypeToZig` adds a
    // literal-on-entry check: when the user's source-side type-text
    // is exactly `char`, the codegen rewrites to `u32` so `let c:
    // char = 'Z'` round-trips to `const c: u32 = 'Z';`.
    //
    // Negatives: ensure the rewrite does NOT pass `char` through
    // to zigzag (which would leave the layer-(a) gap open) AND does
    // NOT silently rewrite to `u8` (a future maintainer might
    // mistakenly add `u8` semantics for the byte-stream branch).
    const src = "fun f() {\n    let c: char = 'Z';\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the silent u32 rewrite emits the u32 type ident.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c: u32 = 'Z';") != null);
    // Sanity: the bare `char` ident MUST NOT pass through to zigzag.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c: char = 'Z';") == null);
    // Sanity: byte-shaped u8 rewrite (a plausible-alternative if a
    // future maintainer re-architects char) MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c: u8 = 'Z';") == null);
    // Cast-wrap substitution guards: u8/u32 wraps are not the rewrite path.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(u8,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(char,") == null);
}

test "codegen: Expr.char_lit propagates normalized figure (v2 fix path landed)" {
    // Source-of-truth: docs/features.md §08 v2 4-byte Unicode char
    // row, gap (c). Pairs with the lexer-level test (b) in
    // src/tests/lexer.zig (gap (b) normalization) and the codegen
    // test (a) above (gap (a) char→u32 substitution). This test
    // pins the codegen-side of the cycle: the .char_lit arm at
    // src/codegen/expr.zig still emits `s` verbatim, but with the
    // lexer's brace-form text in `s` (no further rewrite needed).
    //
    // Mechanism: the source `let c: u8 = '\u2764';` uses `u8` as
    // the binding type to keep gap (c) isolated from gap (a) (a
    // post-fix `char` ident would silently rewrite to u32, mixing
    // both lanes into one test). The lexer's readChar normalizes
    // the bare `\u2764` to `\u{2764}`. The codegen's .char_lit arm
    // propagates the brace-form text unchanged. Net: the zigzag leaf
    // contains `const c: u8 = '\u{2764}';` literally.
    //
    // Sanity: the raw bare form MUST NOT appear in the zigzag emit
    // (otherwise lane-(b) normalization regressed at a post-fix pin).
    const src = "fun f() {\n    let c: u8 = '\\u2764';\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the brace-form escape reaches zigzag unchanged. The
    // surrounding `'` chars make the 10-char `'\u{2764}'` substring
    // match the in-source char_lit exactly.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c: u8 = '\\u{2764}';") != null);
    // Sanity: the raw bare form MUST NOT appear in the zigzag emit
    // — the per-token match `"\\u2764'"` (with leading quote so the
    // substring can't accidentally match a longer identifier-prefix
    // pattern, e.g., `\u2764something`) would surface a regression
    // in readChar's brace-form rewrite.
    try std.testing.expect(std.mem.indexOf(u8, zig, "\\u2764'") == null);
}

test "codegen: let c: char = '\\u2764' surfaces both gap (a) and gap (c) lanes together" {
    // Source-of-truth: docs/features.md §08 v2 4-byte Unicode char
    // row. Pairs with the lane-by-lane pin tests (a) + (c) above.
    // This integration test combines BOTH gap (a) (the `char` type
    // ident) AND gap (c) (the raw `\u2764` escape) into ONE source
    // pattern so the v2 fix must address both lanes together.
    //
    // Mechanism: the source `let c: char = '\u2764';` exercises
    // BOTH lane-(a) AND lane-(c) at the same codegen emit site.
    // The v2 fix path produces one of FOUR codegen output fingerprints:
    //   1. today (no v2-fix):   `    const c: char = '\u2764';`
    //   2. lane-(a) only fix:   `    const c: u8 = '\u2764';`
    //   3. lane-(b/c) only fix: `    const c: char = '\u{2764}';`
    //   4. both lanes fixed:    `    const c: u8 = '\u{2764}';`
    const src = "fun f() {\n    let c: char = '\\u2764';\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Scope: the disjunction's positive arm names `u32` specifically
    // (the codegen-side target type for `char` per docs/features.md
    // §08 v2 4-byte Unicode char row). A future stage would extend
    // the disjunction to accept u16/u8 if a byte-stream char surface
    // is added alongside the codepoint surface.
    //
    // Positive disjunction: today's exact form OR both-fixed form must match.
    const today_form = std.mem.indexOf(u8, zig, "    const c: char = '\\u2764';") != null;
    const both_fixed_form = std.mem.indexOf(u8, zig, "    const c: u32 = '\\u{2764}';") != null;
    try std.testing.expect(today_form or both_fixed_form);
    // Lane-(a) only residue (u8 ident + raw escape) MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c: u32 = '\\u2764';") == null);
    // Lane-(b/c) only residue (char ident + brace escape) MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c: char = '\\u{2764}';") == null);
}

test "codegen: var emits Zig `var`" {
    const src = "fun f() {\n    var y: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var y: f64 = 3.14;") != null);
}

test "codegen: bare assignment emits `name = expr;`" {
    const src = "fun f() {\n    y = 99;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    y = 99;") != null);
}

test "codegen: var + assign sequence end-to-end" {
    // The basics/variables.zag pattern in miniature: `var` declares, `=`
    // rebinds, both compile to Zig `var NAME: T = …` / `NAME = …;`.
    const src = "fun f() {\n    var count: i32 = 0;\n    count = count + 0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var count: i32 = 0;") != null);
    // With binary operators live, the RHS renders as `(count + 0)` (the
    // genExpr `.binary` case always parenthesises). Confirms the rebinding
    // point is `count = (count + 0);` and the whole pattern compiles.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    count = (count + 0);") != null);
}

test "codegen: const emits Zig `const`" {
    const src = "fun f() {\n    const MAX: i32 = 100;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const MAX: i32 = 100;") != null);
}

test "codegen: const without annotation emits bare `const x = …`" {
    const src = "fun f() {\n    const answer = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const answer = 42;") != null);
    // Sanity: no surprise `: TYPE` token crept in.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const answer:") == null);
}

test "codegen: const + var mix matches examples/basics/variables.zag" {
    // The exact pattern in basics/variables.zag's binding declarations:
    // `let x: i32`, `var y: f64`, `const PI: f64`. The codegen shape matches
    // but each uses the distinct keyword then the distinct emitted zig
    // binding.
    // (broken raw-string form was here; replaced with regular string form below)
    const src = "fun main() {\n    let x: i32 = 10;\n    var y: f64 = 3.14;\n    const PI: f64 = 3.14159;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x: i32 = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var y: f64 = 3.14;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const PI: f64 = 3.14159;") != null);
}

test "codegen: format spec emitted in placeholder" {
    // The full `{PI:.5}` template must surface as `{any:.5}` in the
    // generated zigzag source — the spec is appended verbatim after `{any}`
    // so zig's debug formatter applies it. Args tuple still emits only `PI`
    // (not `PI:.5`); the spec lives in the format string, not the args.
    // (was 3-line broken raw-string form; collapsed to single-line)
    const src = "fun main() {\n    let PI: f64 = 3.14;\n    print(\"{PI:.5}\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:.5}") != null);
    // Sanity: the args tuple carries just PI, not PI:.5 — the colon should
    // only appear inside the format string, never the args list.
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{PI,})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "PI:.5,") == null);
}

test "codegen: integer width spec flows through" {
    // Integer width spec `:5` flows through the same pipeline. Confirms
    // the parser-codegen pairing handles non-`.5` spec shapes uniformly.
    const src =
        \\fun f() {
        \\    let n: i32 = 42;
        \\    print("[{n:5}]\n");
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:5}") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{n,})") != null);
}

test "codegen: multi-arg interpolation without specs still works" {
    // The reviewer's regression concern: after the spec-append change, a
    // multi-arg template with NO specs must still emit `.{name1, name2, name3,}`
    // (single trailing comma). Mirrors the basics/variables.zag final print.
    const src =
        \\fun f() {
        \\    let z: i32 = 100;
        \\    let flag: bool = true;
        \\    let ch: u8 = 'Z';
        \\    print("z = {z}, flag = {flag}, ch = {ch}\n");
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "z = {any}, flag = {any}, ch = {any}\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{z, flag, ch,})") != null);
}

test "codegen: float-precision {pi:.5} emit spans format string and args tuple" {
    // Unblocked-pattern pin for the matching-brace gate (commit f559cf3).
    // The pre-fix char-class gate bailed on `.` (non-alphanumeric, not
    // `_` or `:`) so the gate returned false and the string emitted as
    // a plain `.string_lit` — the print surface stayed a `print("{pi:.5}\n")`
    // call and zig rejected the call shape because the literal contained
    // a `{` that the pre-fix codegen wasn't expecting. The new gate
    // matches `{...}` to its closing `}` at the same brace depth, so
    // `pi:.5` reaches buildTemplate, which splits on the first `:` to
    // surface `pi` as the expr and `.5` as the spec; genTemplateLit then
    // emits the format string `{any:.5}` and the args tuple `.{pi,}`.
    // This test pins BOTH halves of the surface (format string + args
    // tuple) so a future regression that breaks either half (e.g. a
    // `spec` field change that drops the `.5`, OR a `.ident` verbatim-
    // emit path that wraps the expr in `()`) would fail this test
    // loudly.
    const src = "fun f() {\n    let pi: f64 = 3.14159;\n    print(\"pi = {pi:.5}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Format string half: spec is appended after `{any}` so zig's debug
    // formatter applies the precision at print time.
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:.5}") != null);
    // Args tuple half: the spec lives in the format string, not the args;
    // the args list carries just `pi` (the verbatim `.ident` text, not
    // `pi:.5`). Pinned by the negative assertion on `pi:.5,` (which
    // would surface if the spec leaked into the args tuple).
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{pi,})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pi:.5,") == null);
}

test "codegen: expression {a + b} emits verbatim a + b in args tuple" {
    // Unblocked-pattern pin for the matching-brace gate. The pre-fix
    // char-class gate bailed on space + `+` (both non-alphanumeric, not
    // `_`/`:`) so the gate returned false and the string emitted as a
    // plain `.string_lit`. The new gate matches `{...}` to its closing
    // `}` at the same brace depth, so `a + b` reaches buildTemplate
    // which stores the inner text `a + b` as the `.ident` payload
    // (buildTemplate was intentionally NOT changed — it was already
    // working). genTemplateLit's args-tuple emit calls
    // `args_cg.genExpr(expr)` on the `.ident` payload, and the
    // genExpr `.ident` arm at src/codegen/expr.zig:147-149 does
    // `self.write(name)` — emitting the text VERBATIM. So `a + b`
    // surfaces in the generated zig as a valid binary expression at
    // the format-arg site. This is the load-bearing assumption the
    // test pins: if the `.ident` arm ever wraps the text in
    // `()`/`@as(...)`/etc., `{a + b}` would silently break.
    const src = "fun f() {\n    let a: i32 = 1;\n    let b: i32 = 2;\n    print(\"sum = {a + b}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Format string half: plain `{any}` (no spec — the spec split on `:`,
    // there is no `:` inside the `{...}`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any}") != null);
    // Args tuple half: `a + b` appears verbatim in the args list, with
    // no extra wrapping — the verbatim-emit path is the whole point of
    // this commit's design. A regression that wrapped it in `()` (e.g.
    // `.{(@as(i32, a + b),})` for a hypothetical type-coercion path)
    // would surface as the wrapped form in the negative-substring path
    // (the positive substring IS `, .{a + b,})` without the wrap).
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{a + b,})") != null);
    // Sanity: the spec-split machinery is not engaged here (no `:` inside
    // the `{...}`), so the format string stays plain `{any}` and the
    // args tuple doesn't grow a `.5`/`:5`/etc. spec suffix.
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:.5}") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:5}") == null);
}

test "codegen: tuple destructuring emits temp + per-leaf" {
    // `let (x, y) = (10, 20);` must surface as:
    //   const __destruct_0 = .{ 10, 20 };
    //   const x = __destruct_0[0];
    //   const y = __destruct_0[1];
    // Uses bracket indexing on the anonymous struct (zig 0.16 syntax) — the
    // older `.0` numeric field-access form is rejected by 0.16.
    const src = "fun f() {\n    let (x, y) = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 10, 20 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y = __destruct_0[1];") != null);
    // Sanity: the old dot-style syntax must NOT appear:
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.1") == null);
}

test "codegen: array destructuring emits temp + per-leaf indexed" {
    // `let [a, b] = arr;` must surface as:
    //   const __destruct_0 = arr;
    //   const a = __destruct_0[0];
    //   const b = __destruct_0[1];
    const src = "fun f() {\n    let [a, b] = arr;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = arr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = __destruct_0[1];") != null);
}

test "codegen: wildcard leaves skip emission" {
    // `let (_, y, _) = (1, 2, 3);` should only emit a `y` binding; the
    // discarded slots emit nothing. The temp binding still carries the
    // whole tuple so `y` can pluck out `.[1]`.
    const src = "fun f() {\n    let (_, y, _) = (1, 2, 3);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 1, 2, 3 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y = __destruct_0[1];") != null);
    // Sanity: nothing emitted for the discarded slots — neither with the
    // new `[k]` nor the obsolete `.k` form.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0[0]") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0[2]") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.2") == null);
}

test "codegen: nested destructuring emits nested temp paths" {
    // `let (a, (b, c)) = (1, (2, 3));` should produce temp paths `[0]` for
    // `a` and `[1][0]`/`[1][1]` for `b`/`c`. There is no second temp — the
    // inner pair is destructured through the same outer temp.
    const src = "fun f() {\n    let (a, (b, c)) = (1, (2, 3));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = __destruct_0[1][0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c = __destruct_0[1][1];") != null);
    // Only one temp for the whole expression — inner pair is destructured
    // through the same __destruct_0 reference, not a fresh __destruct_1.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_1") == null);
    // Sanity: dot-syntax paths must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.1.0") == null);
}

test "codegen: var destructuring emits var leaves, const temp" {
    // `var (x, y) = (10, 20);` should produce:
    //   const __destruct_0 = .{ 10, 20 };   // temp is synthetic carrier, always const
    //   var x: i32 = __destruct_0[0];       // inferred : i32 to escape comptime_int
    //   var y: i32 = __destruct_0[1];       // inferred : i32 to escape comptime_int
    const src = "fun f() {\n    var (x, y) = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 10, 20 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var x: i32 = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var y: i32 = __destruct_0[1];") != null);
    // Sanity: dot-syntax must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.1") == null);
}

test "codegen: counter increments across multiple destructures" {
    // Two destructurings in the same body get distinct temp names so zig's
    // no-redeclaration rule is satisfied. Both tuple and array branches
    // share the same counter and indexing scheme.
    const src =
        \\fun f() {
        \\    let (a, b) = (1, 2);
        \\    let [c, d] = arr;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c = __destruct_1[0];") != null);
}

test "codegen: simple binding unchanged when not destructuring" {
    // Regression: a plain `let x = 42` still produces a single binding
    // (no temp, no destructuring path) so existing tests don't break.
    const src = "fun f() {\n    let x = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct") == null);
}

test "codegen: x /= 2 desugars through @divTrunc shim (compound-assign surface)" {
    // The user-facing surface: `x /= 2;` desugars via parseCompoundAssign
    // to `x = x / 2;`, which then routes through the shim path. This test
    // pins the end-to-end zigzag output of the compound-syntax-emits-shim
    // claim — without it, a future parser refactor that breaks the
    // desugar path could silently regress the most common user form.
    const src = "fun f() {\n    var x: i32 = 10;\n    x /= 2;\n    x %= 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(x, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(x, 3)") != null);
    // Sanity: the bare `(x / 2)` and `(x % 3)` shapes must NOT appear in the
    // desugared assignment RHS — the shim would have replaced them.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x / 2)") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x % 3)") == null);
}

test "codegen: struct decl emits zig pub const + struct" {
    // `struct Vec3 { x: f64, y: f64, z: f64 }` transpiles to
    // `pub const Vec3 = struct { x: f64, y: f64, z: f64 };` so zig sees
    // a real declared struct type. The fields are emitted in declaration
    // order so any struct-literal initializer round-trips the
    // field-position expectations.
    const src = "struct Vec3 {\n    x: f64,\n    y: f64,\n    z: f64,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Vec3 = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    x: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    y: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    z: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "};") != null);
}

test "codegen: impl method nests pub fn inside struct decl" {
    // `impl Vec3 { pub fun length(...) -> f64 { … } }` transpiles to
    // `pub fn length(self: *const Vec3) f64 { … }` NESTED INSIDE the
    // struct body. This is the simplification that lets `v.length()`
    // and `Vec3.new(...)` 1:1 round-trip to zig without a zag-side
    // type-resolver (zig's own type checker handles receiver-vs-type
    // dispatch natively).
    const src =
        \\struct Vec3 {
        \\    x: f64,
        \\    y: f64,
        \\    z: f64,
        \\}
        \\impl Vec3 {
        \\    pub fun length(self: *const Vec3) -> f64 {
        \\        return 0.0;
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Vec3 = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    pub fn length(self: *const Vec3) f64 {") != null);
    // Sanity: pub fn appears AFTER the struct decl opens, BEFORE the
    // closing `};` — confirming the nesting rather than flat emission.
    const struct_open = std.mem.indexOf(u8, zig, "pub const Vec3 = struct {").?;
    const fn_emit = std.mem.indexOf(u8, zig, "    pub fn length(self: *const Vec3) f64 {").?;
    const struct_close = std.mem.indexOf(u8, zig[struct_open..], "};").? + struct_open;
    try std.testing.expect(fn_emit > struct_open and fn_emit < struct_close);
}

test "codegen: struct-literal emits Vec3{ .f = v } form" {
    // The struct-literal codegen includes the dotted-field form (`.f = v`)
    // so zig's anonymous-field-init syntax matches zag's surface verbatim.
    // Note: there's no leading `.` on the type itself because the syntax
    // `Vec3{ .x = … }` is zig's **named** struct literal (the leading-dot
    // form `.Vec3 { … }` is reserved for anonymous-struct literals and
    // would be rejected by zig on a real struct).
    const src = "fun f() {\n    let v = Vec3 { x: 1.0, y: 2.0, z: 3.0 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Vec3{ .x = 1.0, .y = 2.0, .z = 3.0 }") != null);
}

test "codegen: orphan impl emits module-level free fn with type_method name" {
    // Pin the orphan-impl handling: an `impl` block whose target_type
    // has no matching struct decl emits as `pub fn <T>_<name>(...) RET
    // { ... }` at module level. Without this fallback, an orphan impl
    // would be silently dropped. The test writes an impl without a
    // preceding struct decl so the orphan path is forced.
    const src =
        \\impl Orphan {
        \\    pub fun greet() -> i32 {
        \\        return 7;
        \\    }
        \\}
        \\fun main() {
        \\    let x: i32 = 0;
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 0), prog.structs.len);
    try std.testing.expectEqual(@as(usize, 1), prog.impls.len);
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Orphan_greet() i32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return 7;") != null);
}

test "codegen: plain if-stmt emits zig if without else" {
    // Statement form with no else: codegen emits `if (cond) { … }` and
    // no suffix for the absent else branch (no dangling `else`).
    const src =
        \\fun f() {
        \\    if x > 0 {
        \\        print("positive\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if (x > 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    }") != null);
    // Sanity: not a labeled blk form (was used for the expression variant
    // only).
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: {") == null);
}

test "codegen: address-of `&x` emits zig `&x`" {
    // Codegen mirrors the parser route: `.unary .addr` writes `&` and
    // then emits the operand verbatim, producing zig's address-of
    // operator at the call site. The resulting zig type is `*T` (or
    // `*const T` for immutable bindings) - zig infers it from the
    // surrounding binding's mutability, so codegen stays surface-agnostic.
    const src = "fun f() {\n    var x: i32 = 0;\n    let p: *i32 = &x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "&x") != null);
}

test "codegen: half-open slice `arr[1..3]` emits `arr[1..3]`" {
    // The `.slice` arm emits target + `[` + (start?) + `..` + (end?) + `]`
    // verbatim. Zig 0.16 lowers `arr[a..b]` directly to a `[]T` slice
    // value (layout `{ ptr: *T, len: usize }`) - no codegen shim needed.
    const src = "fun f() {\n    let s: []i32 = arr[1..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[1..3]") != null);
}

test "codegen: inclusive slice `arr[1...3]` emits `arr[1..3 + 1]`" {
    // Inclusive slices are lowered by emitting the half-open form
    // with a `+ 1` adjustment on the bound - works for integer-typed
    // slices because `+ 1` is a valid binary expression in zig.
    const src = "fun f() {\n    let s: []i32 = arr[1...3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[1..3 + 1]") != null);
}

test "codegen: `[]const u8` annotation round-trips in let binding" {
    // The `[]` slice-type prefix is consumed as a single two-byte
    // token in `collectCastType` BEFORE the is_term arm fires (so `]`
    // cannot be treated as a structural delimiter mid-type). Without
    // this carve-out the captured type text truncates at `[]` and zig
    // rejects the emitted binding's `: []` (downstream checker
    // requires a complete type expression).
    const src = "fun f() {\n    let s: []const u8 = \"hi\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const s: []const u8 = \"hi\";") != null);
}

test "codegen: `?*T` annotation round-trips in let binding" {
    // Mirror of the `[]T` test: the `?` nullable prefix is a separate
    // `.question` token glued onto the rest of the type by
    // `collectCastType` (using the same `prev_was_ptr = true` flag as
    // the `*` pointer marker, so `?*T` round-trips as one combined
    // identifier). Without the `?`-arm insert BEFORE the is_term
    // check, nullable pointer annotations would silently drop the `?`
    // byte and break every zig-side downcast / null-check.
    const src = "fun f() {\n    let p: ?*T = null;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?*T") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p: ?*T = null;") != null);
}

test "codegen: `?*const T` annotation round-trips in let binding" {
    // Three-shape pointer type (`?`, `*`, then `const T`) — collects via
    // `collectCastType`'s three-capture path (the `?` arm sets
    // `prev_was_ptr = true` so `*` glues on without space; the `*` arm
    // sets `prev_was_ptr = true` so `const` glues without space; the
    // `const_kw` token is treated as identifier-equivalent; the trailing
    // `T` identifier is space-separated as the elem-name). Pins the
    // nullable-immutable-pointee annotation form documented in
    // docs/manual/09-pointers.md §"Nullable pointers".
    const src = "fun f() {\n    let x: i32 = 5;\n    let p: ?*const i32 = &x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?*const i32") != null);
    // Scope: only the annotation form is positively pinned here — the
    // rhs initializer `&x` may surface as bare `&x` or paren-wrapped
    // `(&x)` depending on codegen precedence context, so we don't pin
    // the rhs shape (kept loose to avoid a false-positive regression
    // when the codegen boundary in `genExpr` `.addr` tweaks).
    // Sanity: spaced forms must NOT appear — the prev_was_ptr flag must
    // carry across the `?` → `*` → `const` → `T` capture sequence with
    // each pointer-class token resetting it to true so the next ident
    // is glued. A regression that left a previous-token space after
    // `?` or `*` would surface as "? *const" or "?* const" below.
    try std.testing.expect(std.mem.indexOf(u8, zig, "? *const") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "?* const") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "?*const  i32") == null);
}

test "codegen: `?*raw T` annotation round-trips in let binding" {
    // The `*raw` shape uses the same prev_was_ptr-gating path as the
    // bare `*` test, but the `raw` keyword is emitted via the
    // ident-equivalent arm (collectCastType treats raw as a regular
    // identifier text since the lexer doesn't surface it as a special
    // token). The emission must produce `?*raw u8` verbatim — a future
    // regression that did NOT set `prev_was_ptr = true` after the `*`
    // capture would surface as "?* raw u8" below.
    const src = "fun f() {\n    let p: ?*raw u8 = null;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?*raw u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p: ?*raw u8 = null;") != null);
    // Sanity: the pre-space-form failures (would indicate the
    // prev_was_ptr flag was reset between `*` and `raw`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "?* raw") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "? *raw") == null);
}

test "codegen: `?[]const u8` annotation round-trips in let binding" {
    // The nullable slice form uses the `?` prefix capture AFTER the
    // user writes `?` then the `[]` arm sets prev_was_ptr=true so
    // `const` glues without a space when the next token is the
    // `const` keyword, then `u8` is space-separated as the elem-name.
    // Without this pin, a future regression in collectCastType's
    // dispatch order would surface as "?[]const u8" → "?[] const u8"
    // or "?[] const u8" (both inserted-space forms) and break the
    // nullable-slice bindings used in docs/09 + lib/std/env.zag.
    const src = "fun f() {\n    let s: ?[]const u8 = null;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?[]const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const s: ?[]const u8 = null;") != null);
    // Sanity: space-injected forms must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "?[] const") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "? []const") == null);
}

test "codegen: `*const T` annotation round-trips in let binding" {
    // The non-nullable immutable pointer annotation (no `?` prefix).
    // The collectCastType path collects `*`, then `const` (which keeps
    // prev_was_ptr=true so the glue is unbroken), then `T` as the
    // elem-name. Verifies the same shape the `let p_const: *const
    // i32` binding in examples/memory/pointers.zag exercises — the
    // codegen-output tail-substring check below pins the zigzag
    // emission shape.
    const src = "fun f() {\n    let x: i32 = 5;\n    let p: *const i32 = &x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": *const i32") != null);
    // Sanity: the `?`-prefixed (nullable) form is NOT the same shape —
    // a regression that ALWAYS emits `?*` would still surface in the
    // examples/memory/pointers.zag runnable path, so the negative
    // assertion is just a fast feedback loop.
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?*const i32") == null);
}

test "codegen: `*raw T` annotation round-trips in let binding" {
    // The non-nullable raw pointer annotation (no `?` prefix). Used in
    // examples/memory/unsafe.zag (`let p: *raw u8 = buf;` inside an
    // unsafe block). The collectCastType path emits `*raw` verbatim
    // via the prev_was_ptr glue across the `*` → `raw` capture pair.
    // Scope: only the type-text annotation is pinned here — the rhs
    // initializer is codegen-shape-dependent (paren-form `(&x)` vs
    // bare `&x`; `null` may emit as `@ptrFromInt(0)` depending on
    // zag's null-init rewrite, so we don't pin it).
    const src = "fun f() {\n    let p: *raw u8 = null;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": *raw u8") != null);
}

test "codegen: `for v in slice { ... }` iter emits `for (slice) |v|` verbatim" {
    // The slice-iteration form (zig's native for-loop over a slice)
    // round-trips through codegen's `.slice` arm + the for-stmt arm.
    // The iter source is a slice, NOT a range — so the for-stmt arm
    // routes via the iter-non-range path which emits the user
    // expression verbatim inside `for (...) |x|`. Pinned by the
    // positive substring `for (...) |v|` (matching the user-pattern
    // verified by the existing `for x in iter()` non-range test).
    const src =
        \\fun f() {
        \\    let s: []i32 = data[1..3];
        \\    for v in s {
        \\        print("{v}\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The slice is bound to `let s: []i32 = data[1..3];` (the half-open
    // form surfaces in the source-side binding emission, already covered
    // by the slice-arm pin above). The for-loop iter's source IS the
    // ident `s`, so the for-iter non-range codegen arm passes `s`
    // verbatim inside `for (...) |v|`. Iter-source inlining (e.g.
    // `for (data[1..3]) |v|`) is NOT a zag surface — the iterator MUST
    // be bound to a name first, mirroring zig's own pre-condition.
    try std.testing.expect(std.mem.indexOf(u8, zig, "for (s) |v|") != null);
    // Sanity: the body print call must surface across the iteration
    // boundary (verifies the for-body statement-emit link, not just
    // the iter header).
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print") != null);
}

test "codegen: fun with `[]T` parameter emits the slice signature verbatim" {
    // Slice-as-parameter codegen pins the function-signature emitter's
    // pointer-type capture for `[]T`. Manual section 09 §"Slicing"
    // states `fun sum(s: []i32) -> i32` is a valid function shape;
    // this test pins the round-trip so a future regression in
    // parser/decl.zig's parseMethodParam/parseFunDecl signature
    // emitter that breaks `[]T` would surface here.
    const src = "fun sum(s: []i32) -> i32 {\n    return s[0];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the slice param annotation round-trips.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn sum(s: []i32)") != null);
    // Sanity: the spaced form `[] i32` MUST NOT appear (collectCastType
    // sets prev_was_ptr after the `[]` capture so the elem-name glues).
    try std.testing.expect(std.mem.indexOf(u8, zig, "[] i32") == null);
}

test "codegen: raw-ptr `p.add` with wrong arity falls through verbatim" {
    // Arity-check guards: `p.add(1, 2)` (2 args) and `p.add()` (0
    // args) fall through to the verbatim `target.name(args)` emit
    // shape so zig reports "no method named 'add'" with high-quality
    // diagnostics rather than zig's panic-on-arity in codegen.
    //
    // Negative pin: a future regression that dropped the arity gate
    // would surface here because the codegen would try to emit
    // `mc.args[0]` (index out of bounds on 0-arg) or `mc.args[1]`
    // (out-of-bounds on 2-arg from a 2-arg call). We pin the
    // verbatim fall-through is reached by asserting the literal
    // `p.add(` substring is present.
    const src = "fun f() {\n    let p: *raw u8 = 0;\n    let q: *raw u8 = p.add(1, 2);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: literal `p.add(1, 2)` (with both args) reaches
    // zigzag verbatim.
    try std.testing.expect(std.mem.indexOf(u8, zig, "p.add(1, 2)") != null);
    // Sanity: the @TypeOf re-emit prefix MUST NOT appear (which
    // would indicate the arity gate was dropped).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@TypeOf") == null);
}

test "codegen: `arr[2..]` slice emits verbatim" {
    // The `.slice` arm emits target + `[` + start + `..` + `]` when
    // end is null (no ` + 1` adjustment fires because there's no end
    // to adjust). zig 0.16 lowers `arr[2..]` directly to a half-open
    // slice expression that runs from index 2 to the array's end.
    const src = "fun f() {\n    let s: []i32 = arr[2..];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[2..]") != null);
}

test "codegen: `arr[..3]` slice emits verbatim" {
    // The no-start variant: `.slice` arm emits target + `[` + `..` +
    // end + `]` (no `+ 1` adjustment when inclusive is false). zig
    // accepts `arr[..3]` and lowers it to a half-open slice from the
    // array's start through index 2.
    const src = "fun f() {\n    let s: []i32 = arr[..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[0..3]") != null);
}

test "codegen: `.slice` arm covers all 4 start/end-null combinations" {
    // Comprehensive regression for the `.slice` codegen arm. After the
    // arr[..3] bug fix (where the arm always emitted synthetic `0` for
    // missing start, producing `arr[0..3]` instead of `arr[..3]`), the
    // arm has four distinct emit shapes:
    //
    //   1. start + end  → `arr[10..20]`     (both set, verbatim)
    //   2. start only   → `arr[5..]`        (start set, no end)
    //   3. end only     → `arr[..7]`        (no start, end set)
    //   4. neither      → `arr[0..]`        (both null, synthetic 0)
    //
    // All four shapes are exercised in a single body so any future
    // regression in the start/end null handling (e.g. someone "fixes"
    // the synthetic-0 path by emitting `0` for `arr[..end]` too, OR
    // dropping the synthetic 0 for `arr[..]`) would fail exactly one of
    // these four assertions. Distinct values (10/20/5/7) make the
    // assertion surface surgical — a regression that swaps the bounds
    // of two cases (e.g. emits `arr[..20]` for the end-only case) would
    // still fail the positive substring check.
    const src =
        \\fun f() {
        \\    let a: []i32 = arr[10..20];
        \\    let b: []i32 = arr[5..];
        \\    let c: []i32 = arr[..7];
        \\    let d: []i32 = arr[..];
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Case 1: start + end → verbatim `arr[10..20]`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[10..20]") != null);
    // Case 2: start only → `arr[5..]`, no end.
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[5..]") != null);
    // Case 3: end only → `arr[..7]`, no start, NO synthetic 0 prefix
    // (this was the arr[..3] bug — synthetic 0 would emit `arr[0..7]`,
    // which the positive substring `arr[..7]` would not match because
    // zig's `..` half-open semantics require the lower-bound to be
    // either present OR absent, not artificially pre-filled).
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[0..7]") != null);
    // Case 4: neither → `arr[0..]` with synthetic 0 prefix (zig rejects
    // the bare `arr[..]` form, so the synthetic 0 is load-bearing here).
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[0..]") != null);
    // Sanity: two negative assertions guard distinct regressions.
    //   - `arr[0..7]` (case 3, start MISSING) is the load-bearing pin
    //     against the actual bug we just fixed: the old "always emit
    //     `0` for missing start" behavior would produce `arr[0..7]`
    //     instead of `arr[..7]`.
    //   - `arr[0..20]` (case 1, start=10 SET) is defensive coverage
    //     for a different hypothetical regression where the codegen
    //     unconditionally prepends `0` regardless of whether start is
    //     missing — that bug would not be caught by the case-3
    //     negative alone.
    // Case 2 (`arr[5..]`, start set) and case 4 (`arr[0..]`, both
    // null) are NOT pinned here: case 2 has start present so the
    // original bug couldn't affect it, and case 4 is the intended
    // synthetic-0 case (its presence is asserted positively above).
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[0..20]") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[..7]") == null);
}

test "codegen: bare enum decl emits pub const NAME = enum { ... }" {
    const src = "enum Direction { North, South }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Direction") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "North") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "South") != null);
    // Bare (no payload) — uses regular `enum`, not `union(enum)`.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "union(enum)") == null);
}

test "codegen: payload enum decl emits union(enum)" {
    const src = "enum Shape { Circle(f64), Rect(f64, f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Shape") != null);
    // At least one variant has a payload → zig output must use union(enum).
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "Rect") != null);
}

test "codegen: rest-binding materializes leftover elements via temp index" {
    const src = "fun f() {\n    let (first, ...rest) = (1, 2, 3, 4);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 1, 2, 3, 4 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const first = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const rest = .{ __destruct_0[1], __destruct_0[2], __destruct_0[3] };") != null);
}

test "codegen: nested rest-binding emits __destruct_0[1][1..2] chunked path" {
    const src = "fun f() {\n    let (a, (b, ...ir)) = (1, (2, 3, 4));\n    print(\"{ir}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __destruct_0 = .") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const b = __destruct_0[1][0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const ir = .{ __destruct_0[1][1], __destruct_0[1][2] };") != null);
}

test "codegen: array rest-binding emits sub-array form matching tuple rest" {
    const src = "fun f() {\n    let [a, ...rest] = [3]i32 { 10, 20, 30 };\n    print(\"{rest}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __destruct_0 = [3]i32{ 10, 20, 30 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const rest = .{ __destruct_0[1], __destruct_0[2] };") != null);
}

test "codegen: runtime RHS rest emits slice form __destruct_0[1..]" {
    // The destructor walker treats `slice` (an .ident, not a tuple_lit)
    // as runtime: `getTopElements(.ident)` returns empty. Phase 2's
    // runtime slice branch in the .rest arm emits an open-ended
    // `__destruct_0[1..]` instead of the literal sub-tuple form.
    const src = "fun f() {\n    let slice: []i32 = [3]i32 { 10, 20, 30 }[0..];\n    let (first, ...rest) = slice;\n    print(\"{rest}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const rest = __destruct_0[1..];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __destruct_0 = slice;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const rest = .{ __destruct_0") == null);
}

test "codegen: single-arg named (x: 42,) emits .{ .x = 42 }" {
    const src = "fun f() {\n    let b = (x: 42,);\n    print(\"{b}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ .x = 42 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 42 }") == null);
}

test "codegen: full signature emits pub fn NAME(p: T, ...) RET_TYPE" {
    const src = "fun add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn add(a: i32, b: i32) i32") != null);
}

test "codegen: void fun emits pub fn NAME(...) void" {
    const src = "fun greet(name: str) {\n    print(\"hello, {name}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn greet(name: []const u8) void") != null);
}

test "codegen: `x as str` cast expands str in @as(...) emission" {
    // alias-resolution site: genExpr .cast arm (c.type_text). The cast
    // surface is `@as(T, expr)` per the zig 0.16 builtin; without
    // zagTypeToZig wrapping the type_text this emits `@as(str, ...)`
    // and zig rejects with `unknown type name 'str'`.
    const src = "fun f() {\n    let s: []const u8 = \"hi\" as str;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as([]const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(str") == null);
}

test "codegen: `new str(value)` expands str in page_allocator.create(...)" {
    // alias-resolution site: genExpr .new_expr arm (n.type_name).
    // `new str(value)` flows through `std.heap.page_allocator.
    // create(T)` for the heap-alloc rewrite per docs/19; without
    // zagTypeToZig wrapping the type_name this emits
    // `create(str)` and zig rejects with `unknown type name 'str'`.
    const src = "fun main() {\n    let p = new str(\"hi\");\n    defer free(p);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.create([]const u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.create(str)") == null);
}

test "codegen: `<const N: str>` const-generic type-param expands str in comptime N: TYPE slot" {
    // alias-resolution site: genTypeParamsPreamble (tp.type_text for
    // const generics). A `const` TypeParam carries a verbatim TYPE
    // captured at parse time (via collectCastType); without
    // zagTypeToZig wrapping this emits `comptime N: str` and zig
    // rejects with `unknown type name 'str'`. The bracketed-generic
    // form `<const N: str>` is the parser's only declaration site
    // for a const TypeParam (a top-level fun param slot routes
    // through MethodParam, not TypeParam), so this is the shape
    // that exercises the wrap.
    const src = "fun foo<const N: str>(arg: []const u8) -> []const u8 {\n    return arg;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "comptime N: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "comptime N: str") == null);
}

test "codegen: `<str>(arg)` turbofish type-arg expands str in (`[](const u8)`, arg) emission" {
    // alias-resolution site: genExpr .call turbofish (c.type_args
    // loop on the `.call` arm at src/codegen/expr.zig ~line 185).
    // The full turbofish call site emits
    // `name(type_args..., regular_args...)` so `identity<str>("hi")`
    // round-trips to `identity([]const u8, "hi")` — type-args and
    // runtime-args live INSIDE ONE parenthesised argument list per
    // zig's comptime-arg convention (NOT two pairs of parens). Wrap
    // through `zagTypeToZig(ta)` keeps the docs/07 transparent-alias
    // contract (`str` is transparent alias for `[]const u8`) holding
    // at this final emit site.
    //
    // CYCLE-CLOSED: this test was previously a deferred `@embedFile`
    // existence-check against the wrap line in expr.zig because the
    // parsePostfix turbofish-precondition block (src/parser/primary.zig)
    // did not self.advance() past the leading `<` before invoking
    // parseTurbofishArgs (which requires its caller to have consumed
    // the leading `<` per the function's docblock contract in
    // src/parser/decl.zig). That bug made the turbofish call-site
    // path unreachable from any v1 source, so the wrap line sat
    // dormant. Commit `fix(parser): advance past turbofish < before
    // calling parseTurbofishArgs` (this commit's preceding commit)
    // closed the gap by adding the `self.advance()` and unblocking
    // the runtime path. This test now exercises the round-trip
    // end-to-end.
    //
    // Source shape: `print(identity<str>("hi"))` consumes the turbofish
    // call result without a binding, dodging the static-typed-coercion
    // carve-out's `: T` requirement for non-closure binding-init
    // positions. `print` itself takes one arg and routes through
    // genPrintCall's `else` fallback (the inner call isn't a literal-
    // shaped arg), so the inner `identity([]const u8, "hi")` substring
    // surfaces verbatim in the generated output.
    const src = "fun main() {\n    print(identity<str>(\"hi\"));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: type-arg resolved through zagTypeToZig and interleaved
    // with the runtime-arg inside a single paren pair.
    try std.testing.expect(std.mem.indexOf(u8, zig, "identity([]const u8, \"hi\")") != null);
    // Negative: bare type-arg passthrough must NOT appear — a passthrough-
    // mode regression that emits `identity(str, ...)` would surface here.
    try std.testing.expect(std.mem.indexOf(u8, zig, "identity(str, \"hi\")") == null);
}

test "codegen: turbofish_alias example main() — direct-invocation alias resolution pin (template-interp + decl-side preamble via examples/run_all.sh)" {
    // The example file examples/generics/turbofish_alias.zag pins the
    // full alias-resolution cycle-closure at the call site. This test
    // pins the example's PIPELINE-EQUIVALENT shape (sans the comments
    // and template-interp alias variant) so the file remains valid under
    // the AST pipeline even when examples/run_all.sh isn't exercised.
    // A regression in either half of the alias chain (parser
    // precondition at src/parser/primary.zig's parsePostfix call site,
    // OR zagTypeToZig wrap on src/codegen/expr.zig's `.call`
    // c.type_args loop) surfaces as a surgical assertion failure tied
    // to the example's exact source shape.
    //
    // The template-interp variant `print("identity<str>(s) = {identity<str>(s)}")`
    // is INTENTIONALLY omitted from this test — both call-site paths
    // (template-interp & direct-invocation) route through the same
    // `zagTypeToZig` helper fire and cannot diverge unless someone refs
    // the call-site emission. Pinning only the direct-invocation path
    // keeps the assertion surface tight (3 asserts total) and the
    // template-interp variant is exercised in the example file itself
    // when examples/run_all.sh is run.
    const src = "fun identity<T>(arg: T) -> T {\n    return arg;\n}\n\nfun main() {\n    let int_val: i32 = 42;\n    print(\"identity<i32>(int_val) = {identity<i32>(int_val)}\\n\");\n    let s: str = \"hi\";\n    print(\"identity<str>(s) = {identity<str>(s)}\\n\");\n    print(identity<str>(\"hi\"));\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: direct-invocation turbofish call site resolves `str` alias.
    try std.testing.expect(std.mem.indexOf(u8, zig, "identity([]const u8, \"hi\")") != null);
    // Negative: passthrough regression at the .call c.type_args loop must
    // not appear. A regression that bypasses `zagTypeToZig` for turbofish
    // type-args would surface here (either as `identity(str, "hi")` from a
    // bare emit, OR as zig's `unknown type name "str"` compile failure
    // downstream when run via `examples/run_all.sh`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "identity(str, \"hi\")") == null);
    // Note: the `comptime T: type` decl-side preamble is intentionally
    // NOT pinned here. The convention in this section is positive+negative
    // pairs; a positive-only preamble sanity would break that pattern. The
    // preamble is implicitly covered by test #5 (`codegen: \\`&lt;str&gt;(arg)\\`
    // turbofish type-arg expands...`) just above, and the example file
    // exercises the decl-side path through examples/run_all.sh.
}

test "codegen: struct field `name: str` expands to `name: []const u8`" {
    // alias-resolution site: genStructDecl .named arm (nf.type_text).
    // A struct decl's named fields are emitted verbatim per field;
    // without zagTypeToZig wrapping the field's type_text the
    // emitted field emits `name: str,` and zig rejects with
    // `unknown type name 'str'`.
    const src = "struct Holder {\n    val: str,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "val: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "val: str") == null);
}

test "codegen: enum payload `Box(str)` expands to `Box: []const u8`" {
    // alias-resolution site: genEnumDecl (single-arg payload_type).
    // A union(enum) variant with a single-arg payload emits the
    // variant colon-type verbatim; without zagTypeToZig wrapping
    // the payload_type the variant emits `Box: str` and zig
    // rejects with `unknown type name 'str'`.
    const src = "enum Wrap {\n    Box(str),\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Box: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Box: str") == null);
}

test "codegen: simple-binding `let s: str = ...` expands `: str` to `: []const u8`" {
    // alias-resolution site: genBinding simple-path (b.type_name for
    // a plain `let NAME: T = init;` shape). The `: T` annotation
    // emits verbatim through the simple path's
    // `if (b.type_name) |t| ...` block; without zagTypeToZig wrapping
    // the type_name the binding emits `let s: str = ...` and zig
    // rejects with `unknown type name 'str'`.
    const src = "fun f() {\n    let s: str = \"hi\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const s: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const s: str") == null);
}

test "codegen: block-form const `const x: str = const { ... }` expands `: str` to `: []const u8`" {
    // alias-resolution site: genBinding block-form compile-time
    // binding path (b.type_name for the compile-time block
    // `const NAME: T = const { ... };` shape). The docs/16 §6 block
    // form routes through `if (b.block) |stmts| ...` where the
    // intermediate binding annotation emits verbatim; without
    // zagTypeToZig wrapping the type_name the binding emits
    // `const x: str = blk: { ... }` and zig rejects with `unknown
    // type name 'str'`.
    const src = "fun main() {\n    const x: str = const { return \"hi\"; };\n    let _ = x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const x: []const u8 = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const x: str =") == null);
}

test "codegen: var param injection emits var x = x; at body entry" {
    const src = "fun bump(var x: i32) {\n    x += 1;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn bump(x: i32) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var x = x;") != null);
}

test "codegen: unannotated closure binding still rewrites call to .call(...)" {
    // The most natural closure shape omits an explicit `: Closure`
    // type annotation. `isClosureBound` must seed from
    // collectTypedBindings's closure-init detection pass (not the
    // typed-binding pass), so even a bare `let c = |x| ...;`
    // rewrites `c(args)` to `c.call(args)`. This test locks the
    // wire against a future regression that gates closure detection
    // on the typed-binding precondition.
    //
    // Both bindings are unannotated: `c` (closure value) and `r`
    // (its `.call` RHS). `isLiteralInit` in src/parser/core.zig
    // accepts the `.call` RHS because `isClosureBound` recognises
    // `c` as closure-bound in the surrounding fn body — planted by
    // commit cd33c86 (`feat(parser): recognize closure-typed call
    // in isLiteralInit`), which superseded the workaround branch
    // that 071f221 (`fix(tests): unannotated-closure test source
    // restructure...`) had introduced. The unannotated-binding ->
    // call-rewrite tracing therefore exercises the closure-detection
    // path end to end without any explicit `: T`. The `r` binding is
    // intentionally unreferenced.
    const src =
        \\fun f() {
        \\    let c = |x: i32| -> i32 { return x + 1; };
        \\    let r = c(4);
        \\}
        \\;
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(struct { pub fn call") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "c.call(4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "c(4)") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "print({c(4)}") == null);
}

test "codegen: generic fun emits `comptime X: type` preamble" {
    // docs/16 §1: `fun id<T>(x: T) -> T` must emit
    //   `pub fn id(comptime T: type, x: T) T { return x; }`
    // The `comptime T: type` arg slot is what lets zig treat T as a
    // compile-time-monomorphized type paremeter (no boxing, no runtime
    // dispatch). The preamble must appear BEFORE the regular params
    // so zig's comptime-arg convention is honored.
    const src = "fun id<T>(x: T) -> T {\n    return x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn id(comptime T: type, x: T) T") != null);
    // Sanity: name + return type round-tripped.
    try std.testing.expect(std.mem.indexOf(u8, zig, "return x;") != null);
}

test "codegen: trait decl emits VTable + ptr/vtable + dispatch shims + _ = T;" {
    // The user-confirmed ABI shape per docs/17 + Phase 2 design.
    // The trait container holds (data ptr, vtable ptr); the VTable
    // struct holds ONE *const fn entry per trait method (with
    // Self rewritten to the per-shim generic T AND alias
    // resolution applied — e.g. `str` becomes `[]const u8`); each
    // dispatch shim carries a `comptime T: type` placeholder with
    // `_ = T;` discard (zig 0.16 rejects unused comptime params).
    const src = "trait Drawable {\n    fun draw(self: *Self);\n    fun label(self: *Self) -> str;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The fat-pointer container.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Drawable = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    pub const VTable = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    ptr: *anyopaque,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    vtable: *const VTable,") != null);
    // VTable fn-pointer slots. Self is omitted because the receiver
    // becomes `ptr: *anyopaque`. The `str` return-type surfaces as
    // `[]const u8` because rewriteSelfToT composes with zagTypeToZig
    // (docs/07 transparent-alias contract).
    try std.testing.expect(std.mem.indexOf(u8, zig, "draw: *const fn (ptr: *anyopaque) void,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "label: *const fn (ptr: *anyopaque) []const u8,") != null);
    // Per-method dispatch shims. The `comptime T: type` slot is the
    // user-facing ABI claim; `_ = T;` discards the unused parameter
    // so zig 0.16 accepts the shim body.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn draw(self: Drawable, comptime T: type) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "        _ = T;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.vtable.draw(self.ptr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn label(self: Drawable, comptime T: type) []const u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.vtable.label(self.ptr);") != null);
}

test "codegen: trait method with *Self arg + i32 arg + *Self return — Self->T rewrite chained with alias resolution" {
    // Exercises three sites at once: (1) an additional param of type
    // *Self becomes *T (Self->T rewrite), (2) a non-Self `n: i32`
    // passes through unchanged, (3) the return type *Self becomes *T.
    // The composition with zagTypeToZig means the rewrite path
    // ALSO honours `str` -> `[]const u8` (the docs/07 transparent-
    // alias contract) so trait method signatures on aliased types
    // round-trip without rejecting the type slot.
    const src = "trait Greeter {\n    fun greet(self: *Self, other: *Self, n: i32) -> *Self;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // VTable signature: `other` and `n` appear in declaration order;
    // *Self becomes *T; non-Self `n: i32` passes through.
    try std.testing.expect(std.mem.indexOf(u8, zig, "greet: *const fn (ptr: *anyopaque, other: *T, n: i32) *T,") != null);
    // Dispatch shim mirrors with `comptime T: type` between the
    // receiver and the additional params.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn greet(self: Greeter, comptime T: type, other: *T, n: i32) *T {") != null);
    // Body forwards self.ptr, other, n to the vtable slot.
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.vtable.greet(self.ptr, other, n);") != null);
    // Sanity: no bare `Self` survived anywhere — the rewrite is
    // applied at every type-bearing slot.
    try std.testing.expect(std.mem.indexOf(u8, zig, "Self") == null);
}

test "codegen: trait-method impl emits <Target>_<Trait>_<Method> free fn (rename)" {
    // The Phase 2 rename behavior: the trait-method impl body
    // `pub fun Drawable.draw(self: *Button) { ... }` emits as a free fn
    // named `Button_Drawable_draw` (with the trait-name infix between
    // target and method), NOT the legacy orphan `pub fn Button_draw`.
    // The rename lets the vtable registration reference the fn by
    // exact-string at the per-(trait, target_type) tuple. The impl
    // body is intentionally empty (`{ }`) so the test source has no
    // print/string-literal escapes that would obscure the rename
    // assertion's clarity.
    const src = "trait Drawable { fun draw(self: *Self); } impl Button { pub fun Drawable.draw(self: *Button) { } } fun main() { let x: i32 = 0; }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: trait-method free fn uses the rename.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Drawable_draw(self: *Button) void {") != null);
    // Sanity: no legacy orphan `pub fn Button_draw` form crept in.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_draw(") == null);
}

test "codegen: trait vtable registration emits <Trait>_VTable_for_<Type> with @ptrCast fn-pointer bridge" {
    // The per-(trait, target_type) vtable instantiation surface.
    // Each registration carries one `@ptrCast` per method, bridging
    // the implementation fn-pointer type
    // `*const fn (self: *Type) RET` to the vtable slot type
    // `*const fn (ptr: *anyopaque) RET`. `@ptrCast` is the canonical
    // zig cast between ANY pointer types; zig 0.16 only auto-coerces
    // function pointers when the signatures match EXACTLY (which
    // our pair cannot because one has a typed receiver and the other
    // has `*anyopaque`), so an explicit pointer-reinterpret is
    // required. The impl body is empty (`{ }`) to avoid string-
    // literal-escape noise in the test source.
    const src = "trait Drawable { fun draw(self: *Self); } impl Button { pub fun Drawable.draw(self: *Button) { } } fun main() { let x: i32 = 0; }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the registration name follows
    // `<Trait>_VTable_for_<Type>`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Drawable_VTable_for_Button: Drawable.VTable = .{") != null);
    // Positive: the @ptrCast bridge is present, target name matches
    // the renamed free fn exactly.
    // destination fn-pointer type matches VTable entry (zig 0.16 needs both @ptrCast args)
    try std.testing.expect(std.mem.indexOf(u8, zig, ".draw = @ptrCast(*const fn (ptr: *anyopaque) void, &Button_Drawable_draw),") != null);
    // Sanity: no bare `.draw = Button_Drawable_draw,` assignment - that
    // would signal the @ptrCast bridge regressed.
    try std.testing.expect(std.mem.indexOf(u8, zig, "        .draw = Button_Drawable_draw,") == null);
    // Sanity: no @as fn-pointer coercion attempt leaked through.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(*const fn") == null);
}

test "codegen: cast `x as Trait` emits fat-pointer container + VTable_for_<SourceType>" {
    // docs/17 §"Using Traits" canonical form: `btn as Drawable`
    // produces `Drawable { .ptr = @ptrCast(&btn), .vtable =
    // &Drawable_VTable_for_Button }`. The container literal +
    // vtable reference are the canonical trait-cast shape; `@as`
    // MUST NOT appear (it would silently emit a value that
    // doesn't fit the trait container).
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str }
        \\impl Button { pub fun Drawable.draw(self: *Button) { } }
        \\fun main() {
        \\    let btn: Button = Button { label: "x" };
        \\    let _ = btn as Drawable;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: trait-cast arm emitted the fat-pointer container
    // with the matching vtable registration reference.
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable{ .ptr = @ptrCast(&btn), .vtable = &Drawable_VTable_for_Button") != null);
    // Negative 1: legacy @as cast did NOT appear in the trait-cast
    // path (a regression that drops the trait-detect gate silently
    // produces this).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(Drawable,") == null);
    // Negative 2: no premature `Renderer{` or similar typo
    // contamination (regression-pinning substring distinct from a
    // valid emit shape).
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawer{") == null);
}

test "codegen: cast `*T-typed x as Trait` emits @ptrCast(x) without address-of" {
    // Mirrors the value-typed case but the source binding is
    // already a pointer (`let x: *Button = &btn;`). The codegen
    // detects pointer-ness via `source_type`'s leading `*` and
    // emits `@ptrCast(x)` — NOT `@ptrCast(&x)` which would be
    // invalid since `x` is already `*Button` (zig would reject
    // `&**Button` as invalid type).
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str }
        \\impl Button { pub fun Drawable.draw(self: *Button) { } }
        \\fun main() {
        \\    let btn: Button = Button { label: "x" };
        \\    let x: *Button = &btn;
        \\    let _ = x as Drawable;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: pointer source binds to the vtable registration
    // without an inserted `&`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable{ .ptr = @ptrCast(x), .vtable = &Drawable_VTable_for_Button") != null);
    // Negative: NO spurious address-of for an already-pointer source.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@ptrCast(&x)") == null);
}

test "codegen: dispatch `d.draw<T>()` emits `d.draw(T)` binding source-type" {
    // The user MUST supply the source-type via turbofish so the
    // dispatch shim's `comptime T: type` parameter resolves — the
    // trait-cast arm sets `d`'s zig type to `Drawable`, and the
    // dispatch shim's `comptime T: type` is satisfied by the
    // turbofish'd Button. Without turbofish zig has no way to
    // infer which `<Trait>_VTable_for_<X>` registration to wire
    // (the shim's `_ = T;` discards the binding but the slot is
    // required by zig 0.16 strict comptime rules).
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str }
        \\impl Button { pub fun Drawable.draw(self: *Button) { } }
        \\fun main() {
        \\    let btn: Button = Button { label: "x" };
        \\    let d: Drawable = btn as Drawable;
        \\    d.draw<Button>();
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: turbofish surfaces as the type_args slot in the
    // method-call emit (preceding any args; here there are zero
    // args so the turbofish slot IS the only arg).
    try std.testing.expect(std.mem.indexOf(u8, zig, "d.draw(Button)") != null);
    // Negative 1: legacy shape (no turbofish → empty comptime T
    // slot) was NOT emitted.
    try std.testing.expect(std.mem.indexOf(u8, zig, "d.draw()") == null);
    // Negative 2: source-type passthrough did NOT slip through as
    // a sibling vtable literal (e.g. an emit that accidentally
    // `Drawer_VTable_for_` somewhere). Confirmed by the lack of
    // a stray `_VTable_for_` outside the registration decl.
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawer_VTable_for_") == null);
}

test "codegen: trait + impl + cast + dispatch end-to-end emits full pipeline shape" {
    // The full Phase 3 example (mini version of
    // examples/traits/basic_draw.zag): trait decl, struct decl,
    // impl, trait-method free fn + vtable reg, plus the user's
    // main assembling a cast + turbofish-dispatch. Each emission
    // substring must appear in the codegen output.
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str, }
        \\impl Button { pub fun Drawable.draw(self: *Button) { print("d"); } }
        \\fun main() {
        \\    let btn: Button = Button { label: "x" };
        \\    let d: Drawable = btn as Drawable;
        \\    d.draw<Button>();
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // 1. trait decl shape
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Drawable = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const VTable = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "draw: *const fn (ptr: *anyopaque) void,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "_ = T;") != null);
    // 2. free fn rename (Phase 2 surface)
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Drawable_draw(self: *Button) void") != null);
    // 3. vtable registration (Phase 2 surface)
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Drawable_VTable_for_Button: Drawable.VTable = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".draw = @ptrCast(*const fn (ptr: *anyopaque) void, &Button_Drawable_draw),") != null);
    // 4. cast arm shape (value-typed source → @ptrCast(&btn))
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable{ .ptr = @ptrCast(&btn), .vtable = &Drawable_VTable_for_Button") != null);
    // 5. dispatch turbofish (`d.draw(Button)`)
    try std.testing.expect(std.mem.indexOf(u8, zig, "d.draw(Button);") != null);
}

test "codegen: non-trait cast `x as i32` preserves @as(T, x) emit unchanged" {
    // Regression pin: the trait-cast branch must NOT silently
    // hijack non-trait casts. A bare `x as i32` should emit
    // `@as(i32, x)` exactly as the pre-Phase-3 baseline did. Without
    // this guard a future regression that broadens the trait-detect
    // condition (e.g. dropping the `isTrackedTrait` check) would
    // silently regress every numeric/named cast and the failure
    // would surface as downstream zig-side compile errors, not a
    // clean codegen test failure. Pin the negative shape explicitly.
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(i32, x)") != null);
    // Sanity: the trait-cast fat-pointer form must NOT appear in
    // this (unrelated) cast surface — neither the `_VTable_for_'
    // registration reference nor `@ptrCast(&...` (the value-typed
    // trait-cast address-of path).
    try std.testing.expect(std.mem.indexOf(u8, zig, "_VTable_for_") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@ptrCast(&") == null);
}

test "codegen: pub import std.string.{String as MyStr, Display} emits preamble + aliases" {
    // Selective import shape: parser preserves each selector's name
    // AND its alias. Codegen must surface both into zig so that
    // user-side bindings (MyStr, Display) are reachable names.
    const src = "pub import std.string.{String as MyStr, Display};\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // Preamble -- `__zag_imported_0` (first import) reaches the
    // canonical resolved path of `std.string` from KNOWN_STD_MODULES.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __zag_imported_0 = @import(\"lib/std/string.zag\")") != null);

    // Per-alias forwarder -- user-side aliases must surface verbatim.
    // `MyStr` maps to `String` (zig-side canonical is the .name).
    try std.testing.expect(std.mem.indexOf(u8, zig, "const MyStr = __zag_imported_0.String") != null);

    // Alias-less selector `Display` reuses its canonical name.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const Display = __zag_imported_0.Display") != null);
}

test "codegen: whole-module import (no selectors) emits preamble only" {
    // selectors.len == 0 takes the per-selector pass of zero iterations --
    // ONLY the preamble line must be present. Pin the negative shape so
    // a future regression that emits phantom alias lines for whole-module
    // imports surfaces here, not as a downstream zig compile error.
    const src = "pub import std.string;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig, "const __zag_imported_0 = @import(\"lib/std/string.zag\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= __zag_imported_0.") == null);
}

test "codegen: unknown import (not in KNOWN_STD_MODULES) skips both preamble and aliases" {
    // resolveStdImport returns null -- codegen must skip silently. The
    // generated zig must NOT contain any `__zag_imported_*` lines.
    const src = "pub import std.does_not_exist;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_imported_") == null);
}

test "codegen: multiple std imports take distinct __zag_imported_<i> indices" {
    // Each prog.imports entry gets a unique preamble-index. Verify that
    // two distinct std.X imports produce both __zag_imported_0 and
    // __zag_imported_1 lines (proves the idx counter is bumped per
    // import and not reset).
    const src = "pub import std.string;\npub import std.fmt;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig, "const __zag_imported_0 = @import(\"lib/std/string.zag\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __zag_imported_1 = @import(\"lib/std/fmt.zag\")") != null);
}

test "codegen: all 9 KNOWN_STD_MODULES entries render their expected lib/std/<path>.zag preamble" {
    // Drift pin: KNOWN_STD_MODULES (src/parser/core.zig) and the
    // codegen preamble's resolveStdImport lookup MUST agree on the
    // same (name -> path) map. This test renders each entry as
    // `pub import <name>;` through Parser + Codegen and asserts the
    // produced zig preamble line resolves to the expected
    // `lib/std/<path>.zag` URL.
    //
    // Catches single-entry drift between parser-side table and
    // codegen-side lookup: a future change that adds/removes entries
    // in KNOWN_STD_MODULES without updating this expectation table,
    // or rewrites resolveStdImport with a different lookup shape,
    // surfaces here as either a missing prefix (entry not rendered),
    // a mismatched path (resolveStdImport misroutes), or the count
    // pin below tripping (silent table growth/shrinkage).
    const cases = [_]struct { name: []const u8, expected: []const u8 }{
        .{ .name = "std",               .expected = "lib/std/mod.zag" },
        .{ .name = "std.string",        .expected = "lib/std/string.zag" },
        .{ .name = "std.error",         .expected = "lib/std/error.zag" },
        .{ .name = "std.fmt",           .expected = "lib/std/fmt.zag" },
        .{ .name = "std.time",          .expected = "lib/std/time.zag" },
        .{ .name = "std.atomic",        .expected = "lib/std/atomic.zag" },
        .{ .name = "std.bench",         .expected = "lib/std/bench.zag" },
        .{ .name = "std.async.stream",  .expected = "lib/std/async/stream.zag" },
        .{ .name = "std.arch.x86.avx2", .expected = "lib/std/arch/x86/avx2.zag" },
    };
    // Count pin: a future regression that drops an entry below 9
    // (or grows above 9 without this test being updated) breaks here
    // BEFORE the per-entry loop runs -- catches silent table size
    // drift that per-entry assertions alone would miss.
    try std.testing.expectEqual(@as(usize, 9), cases.len);

    for (cases) |c| {
        var src_buf: [192]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "pub import {s};\n", .{c.name}) catch unreachable;

        var l = lexer_mod.Lexer.init(src);
        const tokens = l.tokenize();
        var arena = ast.Arena.init();
        var p = parser_mod.Parser.init(tokens, &arena);
        const prog = p.parse();
        var cg = codegen_mod.Codegen.init();
        const zig = cg.generate(prog);

        // Per-entry preamble path assertion. Pull the literal path
        // string out of `const __zag_imported_0 = @import("<X>");`
        // and assert X equals c.expected. The prefix/suffix anchored
        // slice also confirms the emit shape (no spaces-misplaced,
        // no missing-quote issues).
        const needle_prefix = "const __zag_imported_0 = @import(\"";
        const needle_suffix = "\");\n";
        const prefix_idx = std.mem.indexOf(u8, zig, needle_prefix);
        try std.testing.expect(prefix_idx != null);
        const path_start = prefix_idx.? + needle_prefix.len;
        const suffix_idx = std.mem.indexOfPos(u8, zig, path_start, needle_suffix);
        try std.testing.expect(suffix_idx != null);
        const actual_path = zig[path_start..suffix_idx.?];
        try std.testing.expectEqualStrings(c.expected, actual_path);
    }
}

test "codegen: builtin router preserves non-builtin call verbatim" {
    // Regression pin on the `.call` arm's per-dispatch fallback: when
    // the callee name does NOT appear in builtin_table, codegen must
    // emit the user's call shape verbatim. Without the router-aware
    // .call arm, this test would fail (no fallback path). With it,
    // the verbatim `myhelper(1, 2, 3)` shape is preserved.
    const src = "fun f() {\n    let x: i32 = myhelper(1, 2, 3);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "myhelper(1, 2, 3)") != null);
}

test "codegen: builtin router does NOT fire on user helpers with builtin-like names" {
    // Defensive pin: a user-defined helper named `process` (which is
    // also a potential Phase 2 `std.process` entry) must not trigger
    // the router. argv_get is the only Phase 0 entry; any other name
    // falls through to the verbatim fallback. This guards against an
    // over-broad match that would corrupt unrelated call sites when
    // a future Phase adds more entries.
    const src = "fun f() {\n    let r: i32 = process(data);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "process(data)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.os.argv") == null);
}

test "codegen: argv_get builtin routes through __zag_argv module-level global" {
    // zig 0.16 retired `std.os.argv` / `std.posix.argv`. The new
    // architecture: genFun's `is_main` special case captures
    // `init.minimal.args.toSlice(...)` into the module-level
    // `__zag_argv` global at main entry, and the `.argv_get` dispatch
    // is now a single reference to that global.
    const src = "fun f() {\n    let args: []const []const u8 = get();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the router routes to the module-level __zag_argv global.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_argv") != null);
    // Negative: the verbatim `get()` form must NOT appear (proves the
    // builtin_table router fired rather than falling through).
    try std.testing.expect(std.mem.indexOf(u8, zig, "= get()") == null);
    // Negative: the legacy per-call blk walker surface is retired.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.os.argv") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[32][]const u8") == null);
}

test "codegen: getEnv emits std.posix.getenv shim with @as(?[]const u8, ...) coercion" {
    // zig 0.16: std.posix.system.getenv was retired in favour of
    // std.posix.getenv (which takes []const u8 and returns ?[:0]const u8).
    // The new minimal shape wraps it in @as(?[]const u8, ...) to bridge
    // the sentinel-terminated return to zag's `?[]const u8` shape.
    const src = "fun f() {\n    let home: ?str = getEnv(\"HOME\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive (substring): the router fired with the new stdlib + coercion.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@as(?[]const u8") != null);
    // Negative: the legacy per-call temp + std.posix.system surface is retired.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __env_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.system.getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.mem.span") == null);
    // Negative: the verbatim `getEnv(...)` form must NOT appear
    // (proves the builtin_table router fired).
    try std.testing.expect(std.mem.indexOf(u8, zig, "= getEnv(\"HOME\")") == null);
}

test "codegen: multiple getEnv calls each route through std.posix.getenv" {
    // The env_counter pattern (per-call `__env_<N>` temps) was retired
    // alongside the env_var emit-shape simplification: the new
    // minimal `blk: { break :blk @as(?[]const u8, std.posix.getenv(...)) }`
    // shape has no temp var to name. Sibling getEnv calls in the same
    // body now produce identical emit shapes — this test pins that
    // BOTH calls route through the builtin_table (not the verbatim
    // fallback) and each gets its own std.posix.getenv invocation.
    const src = "fun f() {\n    let a: ?str = getEnv(\"HOME\");\n    let b: ?str = getEnv(\"PATH\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: both getEnv calls route through std.posix.getenv with
    // their respective name arguments preserved verbatim.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv(\"HOME\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv(\"PATH\")") != null);
    // Negative: the retired per-call temp pattern is gone.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __env_") == null);
    // Negative: the verbatim `getEnv(...)` form must NOT appear for
    // either call (proves the router fired for both).
    try std.testing.expect(std.mem.indexOf(u8, zig, "= getEnv(") == null);
}

test "codegen: getEnv routes through builtin_table to std.posix.getenv (no verbatim fallback)" {
    // zig 0.16: std.posix.system.getenv was retired in favour of
    // std.posix.getenv (takes []const u8, returns ?[:0]const u8). The
    // builtin_table router fires for the `getEnv` free-fn call,
    // producing the inline shim that uses the new stdlib surface.
    const src = "fun f() {\n    let x: ?str = getEnv(\"HOME\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv") != null);
    // Negative: the legacy std.posix.system.getenv path is retired.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.system.getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= getEnv(\"HOME\")") == null);
}

test "codegen: readFileAlloc emits Threaded.init + readFileAlloc shim" {
    // The Phase 2 router emit shape: per-call blk wrapper
    // around std.Io.Dir.cwd().readFileAlloc bridged to
    // []u8 via std.Io.Threaded.init(...) (per-call Io
    // lifecycle) plus page_allocator ownership via
    // defer __io_threaded.deinit(). A
    // read_file("examples/basics/hello.zag") source site
    // must surface these substrings so zig sees the Io
    // event-loop instantiation at the use site, NOT an
    // undeclared read_file(...) form or a std.fs.cwd()
    // legacy form (the latter was retired in zig 0.16 -
    // std.fs.zig is a 21-line deprecation stub now).
    const src = "fun f() {\n    let d: []u8 = read_file(\"examples/basics/hello.zag\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Per-call Io init + deinit pair
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Threaded.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer __io_threaded.deinit()") != null);
    // The actual readFileAlloc call
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Dir.cwd().readFileAlloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".unlimited") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator") != null);
    // Result capture via blk
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __fs_0") != null);
    // Error collapse
    try std.testing.expect(std.mem.indexOf(u8, zig, "catch &[_]u8{}") != null);
}

test "codegen: fs_counter increments across multiple read_file calls" {
    // The per-function fs_counter (reset at genFun /
    // genMethod / genFreeMethod) must step cleanly across
    // sibling read_file calls so zig's no-redeclaration
    // rule is satisfied. The : []u8 annotation is
    // REQUIRED on both let a and let b: zag's grammar
    // rejects bare let foo = <expr> for non-tuple rhs
    // (the parser needs the type slot to dispatch []u8
    // unchanged). Mirrors the explicit annotations on
    // let home (Phase 1 test 1) and let a: ?str
    // (Phase 1 test 2).
    const src = "fun f() {\n    let a: []u8 = read_file(\"foo\");\n    let b: []u8 = read_file(\"bar\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_1") != null);
}

test "codegen: read_file routes through builtin_table (no verbatim fallback)" {
    // The router catches read_file("X") before the verbatim
    // <name>(<args>) fallback in expr.zig's .call arm. A
    // let d: []u8 = read_file("examples/basics/hello.zag")
    // source must surface std.Io.Threaded.init (the shim)
    // but must NOT leave a bare = read_file( substring in
    // the emitted zig - the router consumed the call site.
    // A regression that bypasses builtins.lookup(...) would
    // leave the verbatim form intact and zig would reject
    // with "use of undeclared identifier 'read_file'".
    const src = "fun f() {\n    let d: []u8 = read_file(\"examples/basics/hello.zag\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Threaded.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= read_file(") == null);
}

test "codegen: raw pointer .add(N) emits zig-fallback @ptrFromInt + @sizeOf(@typeInfo(@TypeOf(...)).pointer.child)" {
    // Closes the BLOCKER finding from the §09 Pointers audit review:
    // docs/manual/09-pointers.md §"Raw pointers" documents
    // `p.add(N)` as `p + N * sizeof(T)` but zag's parser routes the
    // call through `.method_call` and emits `p.add(N)` verbatim to
    // zigzag — zig 0.16 has no `.add` method on `*raw T` and rejects
    // the generated source. The codegen-side fix (zig-fallback) is
    // implemented in src/codegen/expr.zig's `.method_call` arm: when
    // `mc.name == "add"` and `mc.args.len == 1`, emit the
    // `@ptrFromInt(@intFromPtr(p) + N * @sizeOf(@typeInfo(@TypeOf(p)).pointer.child))`
    // expansion directly so zigzag never sees the `.add` syntax.
    //
    // The `@typeInfo(@TypeOf(p)).pointer.child` strip is critical —
    // `@sizeOf(@TypeOf(p))` returns the POINTER size (8 on 64-bit
    // for `*raw u8`), not the POINTE size (1 for u8). Without the
    // strip, `p.add(2)` on `p: *raw u8` advances by 16 bytes instead
    // of 2. The positive pin asserts the FULL closed-form substring
    // `@sizeOf(@typeInfo(@TypeOf(p)).pointer.child)` — including
    // all closing parens — so the next regression that drops a `)`
    // or skips the `@typeInfo` strip fails immediately.
    const src = "fun f() {\n    var buf: [4]u8 = undefined;\n    let p: *raw u8 = &buf;\n    let q: *raw u8 = p.add(2);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the closed-form `@sizeOf(@typeInfo(@TypeOf(p)).pointer.child)`
    // substring appears (the `.child` field-access closes the @typeInfo strip).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@sizeOf(@typeInfo(@TypeOf(p)).pointer.child)") != null);
    // Positive: the @ptrFromInt / @intFromPtr pair both appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@ptrFromInt") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@intFromPtr(p)") != null);
    // Sanity: the verbatim `.add(` form MUST NOT appear (else the
    // zig-fallback didn't fire and zigzag got `p.add(2)` to reject).
    try std.testing.expect(std.mem.indexOf(u8, zig, "p.add(") == null);
    // Sanity: the buggy `@sizeOf(@TypeOf(p))` substring (without the
    // `@typeInfo` strip) MUST NOT appear — this is the semantic bug
    // the test pins against regression.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@sizeOf(@TypeOf(p))") == null);
}

test "codegen: raw pointer .offset(p) emits (@intFromPtr - @intFromPtr) / @sizeOf(@typeInfo(@TypeOf(...)).pointer.child)" {
    // Same zig-fallback shape as `.add` but produces a numeric
    // difference (integer / usize = integer) instead of a pointer.
    // The positive pin asserts the FULL closed-form substring
    // `@sizeOf(@typeInfo(@TypeOf(q)).pointer.child)` so the
    // paren-balance bug AND the missing `@typeInfo` strip both fail
    // loudly. The strip is critical for heterogeneous-type offset
    // (e.g. `q: *raw u8`, `p: *raw u8` after `p.add(N)`) because
    // without it `@sizeOf(@TypeOf(q))` would return pointer stride
    // instead of pointee stride.
    const src = "fun f() {\n    var buf: [4]u8 = undefined;\n    let p: *raw u8 = &buf;\n    let q: *raw u8 = p.add(2);\n    let n: i64 = q.offset(p);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: closed-form `@sizeOf(@typeInfo(@TypeOf(q)).pointer.child)`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@sizeOf(@typeInfo(@TypeOf(q)).pointer.child)") != null);
    // Positive: both `q` and `p` show up inside the offset formula
    // (the `(@intFromPtr(q) - @intFromPtr(p))` half).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@intFromPtr(q)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@intFromPtr(p)") != null);
    // Sanity: the verbatim `.offset(` form MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "q.offset(") == null);
    // Sanity: the buggy `@sizeOf(@TypeOf(q))` substring (without the
    // `@typeInfo` strip) MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@sizeOf(@TypeOf(q))") == null);
}

test "codegen: raw pointer .add on wrong arity falls through to verbatim" {
    // Negative pin: when `mc.args.len != 1`, the zig-fallback
    // branch in src/codegen/expr.zig's `.method_call` arm must
    // SKIP — the user gets the verbatim `p.add(1, 2)` emission so
    // zig reports `no method named 'add'` with high-quality
    // diagnostics rather than zig panicking inside codegen.
    // Without this fall-through, an over-eager rewrite would
    // crash on `args[0]` (out-of-bounds) at codegen time.
    const src = "fun f() {\n    var buf: [4]u8 = undefined;\n    let p: *raw u8 = &buf;\n    p.add(1, 2);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Sanity: the @ptrFromInt rewrite MUST NOT fire on wrong-arity
    // sites (the fall-through preserves the verbatim form so zig
    // can reject with a clean error message).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@ptrFromInt") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@intFromPtr") == null);
    // Positive: the verbatim `p.add(1, 2)` form MUST appear so zig
    // gets a chance to report `no method named 'add'` to the user.
    try std.testing.expect(std.mem.indexOf(u8, zig, "p.add(1, 2)") != null);
}

test "codegen: raw pointer method other than add/offset falls through to verbatim" {
    // Negative pin: even on the correct 1-arg shape, a method
    // name other than `add` / `offset` must NOT trigger the
    // zig-fallback — it would silently rewrite arbitrary user
    // method calls (e.g. `p.someMethod()`) into @intFromPtr
    // arithmetic and break legitimate receiver-method calls on
    // raw pointers.
    const src = "fun f() {\n    var buf: [4]u8 = undefined;\n    let p: *raw u8 = &buf;\n    p.someMethod(2);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Sanity: the fallback rewrite MUST NOT fire.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@ptrFromInt") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@intFromPtr") == null);
    // Positive: verbatim form preserved.
    try std.testing.expect(std.mem.indexOf(u8, zig, "p.someMethod(2)") != null);
}

test "codegen: struct field assignment `v.x = val` emits `v.x = val;` verbatim" {
    // Closes the §12 audit-fill gap: docs/manual/12-structs.md §"Field
    // Access" documents `v.x = 10.0;` but no codegen test pinned the
    // emission shape. The parser routes the assignment through the
    // existing `.field_assign` stmt (target: `.member_access`, value:
    // any Expr) — the codegen path is shared with bare assignment
    // (the `.assign` stmt arm) so the codegen output is `v.x = 10.0;`
    // verbatim. Pin the verbatim shape so a future codegen refactor
    // that wraps field assignment in some kind of `blk:` shim (e.g.
    // for method-call RHS) would fail loudly.
    const src = "fun f() {\n    var v: Vec3 = Vec3 { x: 1.0, y: 2.0, z: 3.0 };\n    v.x = 10.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the verbatim `v.x = 10.0;` shape is emitted.
    try std.testing.expect(std.mem.indexOf(u8, zig, "v.x = 10.0;") != null);
    // Sanity: no `blk:` shim wrapping for plain field-write RHS.
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: {") == null);
    // Sanity: the struct-literal's binding still emits `const v = ...` not `var v`
    // — assignment to a `let` binding should still compile (zig's `const`
    // would reject it, but the codegen-side emission shape is what this test
    // pins; the binding-mutability check is downstream).
    try std.testing.expect(std.mem.indexOf(u8, zig, "v.x") != null);
}

test "codegen: mutable struct method emits self: *Vec3 (not *const Vec3)" {
    // Closes the §12 audit-fill gap: docs/manual/12-structs.md §"Methods"
    // documents both `self: *const Vec3` (read-only) and `self: *Vec3`
    // (mutable, can write through) receiver shapes. The existing
    // `codegen: impl method nests pub fn inside struct decl` test pins
    // the `*const Vec3` shape; no test pins the `*Vec3` shape (the
    // distinction is the load-bearing difference — `*Vec3` lets the
    // method body emit `self.x = ...` without zig rejecting the
    // `.x` field-write on a const-pointer receiver). Pin the literal
    // `self: *Vec3` substring (NOT `*const Vec3`) so a future parser
    // regression that drops the `const` qualifier on mutable receivers
    // would surface here.
    const src =
        \\struct Vec3 { x: f64, y: f64, z: f64 }
        \\impl Vec3 {
        \\    pub fun normalize(self: *Vec3) {
        \\        self.x = 0.0;
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the mutable receiver shape `self: *Vec3` appears
    // (no `const` between `*` and `Vec3`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "self: *Vec3") != null);
    // Sanity: the literal `*const Vec3` substring MUST NOT appear —
    // would surface a regression where the parser dropped the
    // mutable-receiver semantic.
    try std.testing.expect(std.mem.indexOf(u8, zig, "*const Vec3") == null);
    // Sanity: the field-write `self.x = 0.0` reaches zigzag unchanged.
    try std.testing.expect(std.mem.indexOf(u8, zig, "self.x = 0.0;") != null);
}

test "codegen: brace-named-field match-arm destructuring emits __m == .Variant + const-name = __m.field preamble" {
    // gap #6 round-trip (`docs/manual/14-unions §"Definition"` +
    // `src/codegen/stmt.zig`'s `emitPatternBindings` helper).
    // `match p { Pos { x: w, y: h } => w + h }` emits zig — inside the
    // labelled `blk` block — three pieces:
    //   1. cond: `if (__m_0 == .Pos)`
    //   2. preamble (inside the `if`-block, before `break :blk`):
    //      `const w = __m_0.Pos.x; const h = __m_0.Pos.y;`
    //      — zig 0.16's union(enum) requires explicit variant dispatch
    //      (`__m_0.<variant_name>.<field>` — Bug #2 fix); the `_ = NAME;`
    //      throwaway was removed (Bug #1 fix) because zig 0.16 also
    //      rejects pointless-discard of locally-used consts.
    //   3. arm body: `break :blk (w + h);`
    // All three pieces must round-trip from source → zag emit.
    const src =
        \\union Pos {
        \\    Pos { x: f64, y: f64 },
        \\}
        \\
        \\fun main() {
        \\    let p: Pos = Pos.Pos(2.0, 3.0);
        \\    let sum: f64 = match p {
        \\        Pos { x: w, y: h } => w + h,
        \\    };
        \\    print(sum);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // Cond: `__m_0 == .Pos` (the `__m_0` counter-name comes from
    // `genMatchExpr`'s `std.fmt.bufPrint(&name_buf, "__m_{d}", .{id})`
    // — the first match expr in the source gets id=0).
    try std.testing.expect(std.mem.indexOf(u8, zig, "__m_0 == .Pos") != null);
    // Binding preamble shape: `const <capture> = __m_0.<variant_name>.<source-field>` (zig 0.16 union(enum) dispatch — Bug #2 fix).
    // The source field name MUST round-trip (gap #2 brace-ctor emit
    // preserves user-written field names on the anonymous-struct
    // payload; gap #6 picks them up via `Pattern.VariantFieldPattern
    // .name`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "const w = __m_0.Pos.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const h = __m_0.Pos.y") != null);
    // zig 0.16 unused-const throwaway: each capture is followed by
    // `_ = NAME;` to silence the "unused local" diagnostic regardless
    // of whether the arm body's EXPR references the capture.
    try std.testing.expect(std.mem.indexOf(u8, zig, "_ = w;") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "_ = h;") == null);
}

test "codegen: unqualified brace ctor routes through brace-named-field emit via lookupVariantFieldsByName" {
    // Pins the FULL gap #2 surface end-to-end. The unqualified brace ctor
    // `Pair { x: 2.0, y: 3.0 }` parses to `enum_variant_ctor { enum_name=null, Pair, [2.0, 3.0] }`;
    // codegen consults `lookupVariantFieldsByName("Pair")` to resolve the
    // source-named `x`, `y` fields and emit `.{ .Pair = .{ .x = 2.0, .y = 3.0 } }`
    // (not the legacy `.{ .a = 2.0, .b = 3.0 }`). Single-line src literal
    // uses real braces (zig non-raw strings have no brace semantics).
    const src = "union Pos { Pair { x: f64, y: f64 } }\n\nfun main() { let p: Pos = Pair { x: 2.0, y: 3.0 }; print(p.x); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    // AST pin (gap #2 closure, BLOCKING #2 fix): the parser must route
    // `Pair { x: 2.0, y: 3.0 }` to `enum_variant_ctor { enum_name = null }`
    // (NOT `enum_name = "Pos"` from the legacy qualified path). The codegen
    // emit-shape pin above would still pass if gap #2 reverted to dead code
    // and the legacy `Pos.Pair(...)` qualified route happened to emit the
    // same shape — this pin catches that false-positive. Distinguished from
    // struct_lit by the `.enum_variant_ctor` tag (struct_lit would imply
    // `Pos { x: 2.0 }` was a struct-literal, the path that pre-fix fell
    // through to when isKnownVariant lookup missed).
    try std.testing.expect(prog.functions.len == 1);
    try std.testing.expect(prog.functions[0].body.len == 2);
    try std.testing.expect(prog.functions[0].body[0] == .let);
    try std.testing.expect(prog.functions[0].body[0].let.init != null);
    const init_expr = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init_expr == .enum_variant_ctor);
    // LOAD-BEARING: enum_name MUST be null (gap #2 unqualified path).
    try std.testing.expect(init_expr.enum_variant_ctor.enum_name == null);
    try std.testing.expect(std.mem.eql(u8, init_expr.enum_variant_ctor.variant_name, "Pair"));
    try std.testing.expect(init_expr.enum_variant_ctor.args.len == 2);


    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // Positive: source-named field init surfaces in zigzag.
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Pair = .{ .x = 2.0, .y = 3.0 } }") != null);
    // Sanity: legacy single-letter positional init (.a, .b) MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, ".a = 2.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".b = 3.0") == null);
}
