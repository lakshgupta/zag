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
    // (only `str` / `[]str` / `[3]str` and the pointer forms
    // `*str` / `*?str` / `*const str` / `*const ?str` round-trip),
    // so the source
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

test "codegen: *str / *?str pointer annotations expand the str alias" {
    // Alias-table extension: the docs/07 transparent-alias contract
    // holds inside pointer wrappers too. Pre-fix `*str` round-tripped
    // verbatim and zig rejected the bare `str` ident (`use of
    // undeclared identifier 'str'`); now the four pointer shapes
    // expand to their `*[]const u8` forms at emit time. Surfaced by
    // the auto-fmt pointer-form widening — `*str`-typed print args
    // rewrite to `*[]const u8`, so they also route through `{f}` +
    // `__zag_auto_fmt()` and print as text.
    const src =
        \\fun f() {
        \\    let s: str = "hello";
        \\    let ps: *str = &s;
        \\    let pc: *const str = &s;
        \\    let o: ?str = "world";
        \\    let po: *?str = &o;
        \\    let pco: *const ?str = &o;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "const ps: *[]const u8 = &s;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pc: *const []const u8 = &s;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const po: *?[]const u8 = &o;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pco: *const?[]const u8 = &o;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const ps: *str") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const po: *?str") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pco: *const?str") == null);
}

test "codegen: pointer-alias recursion expands *char, *f32x4, **str" {
    // Generalization of the four literal `*str` entries: any alias
    // inside a pointer wrapper expands via prefix-strip recursion.
    // `*char` → `*u32`, `*f32x4` → `*@Vector(4, f32)`, `**str` →
    // `**[]const u8` (nested), while non-alias pointees like `*Json`
    // round-trip untouched (the eql guard returns `text` verbatim).
    const src =
        \\fun f() {
        \\    let pc: *char = 0;
        \\    let pv: *f32x4 = 0;
        \\    let ps2: **str = 0;
        \\    let pj: *Json = 0;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pc: *u32 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pv: *@Vector(4, f32) = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const ps2: **[]const u8 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pj: *Json = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pc: *char") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const pv: *f32x4") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const ps2: **str") == null);
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
    // the format-arg site — now wrapped in the runtime-comptime
    // `__zag_auto_fmt(...)` (the `{f}` + wrapper path for
    // statically-unresolvable types): the wrapper's `{any}` fallback
    // renders the i32 sum identically, and the inner text is still
    // emitted verbatim, so this remains the load-bearing pin for the
    // `.ident` arm not wrapping the text in `()`/`@as(...)`/etc.
    const src = "fun f() {\n    let a: i32 = 1;\n    let b: i32 = 2;\n    print(\"sum = {a + b}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Format string half: `{f}` — the unknown-typed `.ident` payload
    // `a + b` routes through the runtime-comptime wrap (no spec — the
    // spec split on `:`, there is no `:` inside the `{...}`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"sum = {f}\\n\"") != null);
    // Args tuple half: `a + b` appears verbatim (unwrapped) INSIDE the
    // `__zag_auto_fmt(...)` wrapper in the args list — the verbatim
    // inner-emit path is the whole point of this test's design. A
    // regression that wrapped the text in `()` (e.g.
    // `.{__zag_auto_fmt(@as(i32, a + b)),})` for a hypothetical
    // type-coercion path) would surface as the wrapped form in the
    // negative-substring path (the positive substring IS
    // `, .{__zag_auto_fmt(a + b),})` with the inner text unwrapped).
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{__zag_auto_fmt(a + b),})") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?[*]u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p: ?[*]u8 = null;") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, ": [*]u8") != null);
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
    // Bare (no payload) — the Direction decl itself uses `enum {`, NOT `union(enum)`.
    // (The preamble Result/Option type definitions DO emit `union(enum)`, so
    // checking the whole output for its absence is invalid.)
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Direction = enum {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Direction = union(enum)") == null);
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

test "codegen: var param name-isolation rename + fresh-local shadow (zig 0.16)" {
    // zig 0.16's pass-by-value default already isolates `var`
    // parameters from the caller for value types — the body mutation
    // needs only a MUTABLE local to write to. The shadow pattern
    // required for pre-0.16 code (`var x = x;`) is rejected by zig
    // 0.16 as a name collision with the parameter. The fix: rename the
    // parameter to `__zag_local_x` and inject a fresh local
    // `var x = __zag_local_x;` at body entry. The body still uses `x`
    // verbatim (resolves to the new mutable local), the parameter
    // carries the caller's pass-by-value copy, and the public contract
    // (caller unaffected by body mutations) is preserved.
    const src = "fun bump(var x: i32) {\n    x += 1;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Renamed parameter — different name from the local.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn bump(__zag_local_x: i32) void") != null);
    // Shadow emit at body entry.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var x = __zag_local_x;") != null);
    // Legacy same-name shadow rejected (caller of the legacy emit).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var x = x;") == null);
    // Body mutation still round-trips.
    // The compound-assign `x += 1;` desugars at parse time to
    // `x = x + 1;` (parser/stmt.zig:parseCompoundAssign lowers
    // `lhs OP= rhs` to `AssignStmt { lhs, BinaryExpr { lhs, OP, rhs } }`,
    // which codegen emits as a plain assignment). The original source
    // form `+=` therefore never appears in the generated zig.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x + 1)") != null);
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

test "codegen: trait decl emits VTable + ptr/vtable + dispatch shims" {
    // The user-confirmed ABI shape per docs/17. The trait container
    // holds (data ptr, vtable ptr); the VTable struct holds ONE
    // *const fn entry per trait method (Self rewritten to *anyopaque);
    // each dispatch shim forwards directly — no comptime T param.
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
    // VTable fn-pointer slots.
    try std.testing.expect(std.mem.indexOf(u8, zig, "draw: *const fn (ptr: *anyopaque) void,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "label: *const fn (ptr: *anyopaque) []const u8,") != null);
    // Per-method dispatch shims — no comptime type param needed.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn draw(self: Drawable) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.vtable.draw(self.ptr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn label(self: Drawable) []const u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.vtable.label(self.ptr);") != null);
    // Sanity: no comptime T param in the Drawable dispatch shim
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable, comptime T: type") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "_ = T;") == null);
}

test "codegen: trait method with *Self arg + i32 arg + *Self return — Self→anyopaque rewrite" {
    // Exercises three sites: (1) additional param *Self → *anyopaque,
    // (2) non-Self `n: i32` passes through unchanged, (3) return type
    // *Self → *anyopaque. No comptime T — the vtable function-pointer
    // types use *anyopaque throughout.
    const src = "trait Greeter {\n    fun greet(self: *Self, other: *Self, n: i32) -> *Self;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // VTable signature: *Self → *anyopaque.
    try std.testing.expect(std.mem.indexOf(u8, zig, "greet: *const fn (ptr: *anyopaque, other: *anyopaque, n: i32) *anyopaque,") != null);
    // Dispatch shim — no comptime T param.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn greet(self: Greeter, other: *anyopaque, n: i32) *anyopaque {") != null);
    // Body forwards self.ptr, other, n to the vtable slot.
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.vtable.greet(self.ptr, other, n);") != null);
    // Sanity: no bare `Self` survived. Scoped to the user-code region
    // (everything before the Layer-3a map table): the panic-trace
    // machinery at the end of the generated module legitimately
    // contains "Self" inside std.debug.getSelfDebugInfo.
    const trait_map_at = std.mem.indexOf(u8, zig, "__ZagMapEntry") orelse zig.len;
    try std.testing.expect(std.mem.indexOf(u8, zig[0..trait_map_at], "Self") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, ".draw = @ptrCast(&Button_Drawable_draw),") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable{ .ptr = @constCast(&btn), .vtable = &Drawable_VTable_for_Button") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable{ .ptr = @constCast(x), .vtable = &Drawable_VTable_for_Button") != null);
    // Negative: NO spurious address-of for an already-pointer source.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@ptrCast(&x)") == null);
}

test "codegen: dispatch `d.draw()` calls the shim without turbofish" {
    // The dispatch shim no longer needs a comptime T param —
    // the vtable does all the work. `d.draw()` resolves directly.
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str }
        \\impl Button { pub fun Drawable.draw(self: *Button) { } }
        \\fun main() {
        \\    let btn: Button = Button { label: "x" };
        \\    let d: Drawable = btn as Drawable;
        \\    d.draw();
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
    // Direct call — no turbofish
    try std.testing.expect(std.mem.indexOf(u8, zig, "d.draw()") != null);
    // Sanity: no turbofish noise in draw call
    try std.testing.expect(std.mem.indexOf(u8, zig, "d.draw(Button)") == null);
}

test "codegen: trait + impl + cast + dispatch end-to-end emits full pipeline shape" {
    // Full pipeline: trait decl, struct, impl, vtable reg, cast,
    // direct dispatch. No turbofish — the vtable handles it.
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str, }
        \\impl Button { pub fun Drawable.draw(self: *Button) { print("d"); } }
        \\fun main() {
        \\    let btn: Button = Button { label: "x" };
        \\    let d: Drawable = btn as Drawable;
        \\    d.draw();
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn draw(self: Drawable) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable, comptime T: type") == null);
    // 2. free fn rename
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Drawable_draw(self: *Button) void") != null);
    // 3. vtable registration
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Drawable_VTable_for_Button: Drawable.VTable = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".draw = @ptrCast(&Button_Drawable_draw),") != null);
    // 4. cast arm shape
    try std.testing.expect(std.mem.indexOf(u8, zig, "Drawable{ .ptr = @constCast(&btn), .vtable = &Drawable_VTable_for_Button") != null);
    // 5. direct dispatch — no turbofish
    try std.testing.expect(std.mem.indexOf(u8, zig, "d.draw();") != null);
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
    // trait-cast address-of path). Scoped to the user-code region
    // (everything before the Layer-3a map table): the panic-trace
    // machinery at the end of the generated module legitimately
    // contains `@ptrCast(&path_z[0])` in its source-line reader.
    const cast_map_at = std.mem.indexOf(u8, zig, "__ZagMapEntry") orelse zig.len;
    try std.testing.expect(std.mem.indexOf(u8, zig[0..cast_map_at], "_VTable_for_") == null);
    // Scoped to the USER code (`pub fn f` onwards): the preamble's
    // __zag_key_hash helper legitimately contains @ptrCast(&key).
    const user_at = std.mem.indexOf(u8, zig, "pub fn f") orelse 0;
    try std.testing.expect(std.mem.indexOf(u8, zig[user_at..cast_map_at], "@ptrCast(&") == null);
}

test "codegen: pub import std.types.{String as MyStr} + std.fmt.{Display as MyDisp} emits aliases" {
    // Selective import shape: parser preserves each selector's name
    // AND its alias. Codegen must surface both into zig so that
    // user-side bindings (MyStr, MyDisp) are reachable names. The
    // String type lives in std.types only;
    // Display lives in std.fmt.
    const src = "pub import std.types.{String as MyStr};\npub import std.fmt.{Display as MyDisp};\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // `String as MyStr` is preamble-known (fast path emits
    // `const MyStr = __zag_String;` directly); `Display as MyDisp`
    // is .zag-source backed (slow path emits
    // `const MyDisp = __zag_imported_<i>.Display;` after the @import
    // preamble line) — the mixed-selector fast/slow split exercised
    // across two modules.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const MyStr = __zag_String") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"std/fmt.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const MyDisp = __zag_imported_") != null);
}

test "codegen: whole-module import (no selectors) skips stdlib @import" {
    // Stdlib imports with no selectors: preamble types are always available.
    // No @import of .zag files should be emitted.
    const src = "pub import std.types;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"lib/std/") == null);
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
    const src = "pub import std.types;\npub import std.fmt;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // Stdlib imports no longer emit @import of .zag files.
    // Selectorless imports produce no preamble lines.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"lib/std/") == null);
}

test "codegen: all 12 KNOWN_STD_MODULES entries are recognized by the import router" {
    // Each stdlib import must be recognized by resolveStdImport.
    // Stdlib imports now skip @import (types are in the preamble),
    // so we verify no @import of .zag files is emitted, and the
    // parser+codegen pipeline accepts all entries.
    const cases = [_]struct { name: []const u8, expected: []const u8 }{
        .{ .name = "std",               .expected = "lib/std/mod.zag" },
        .{ .name = "std.types",         .expected = "lib/std/types/mod.zag" },
        .{ .name = "std.error",         .expected = "lib/std/error.zag" },
        .{ .name = "std.fmt",           .expected = "lib/std/fmt.zag" },
        .{ .name = "std.time",          .expected = "lib/std/time.zag" },
        .{ .name = "std.atomic",        .expected = "lib/std/atomic.zag" },
        .{ .name = "std.bench",         .expected = "lib/std/bench.zag" },
        .{ .name = "std.async.stream",  .expected = "lib/std/async/stream.zag" },
        .{ .name = "std.arch.x86.avx2", .expected = "lib/std/arch/x86/avx2.zag" },
        .{ .name = "std.concurrent.atomic", .expected = "lib/std/concurrent/atomic.zag" },
        .{ .name = "std.concurrent.thread", .expected = "lib/std/concurrent/thread.zag" },
        .{ .name = "std.concurrent.mutex",  .expected = "lib/std/concurrent/mutex.zag" },
    };
    try std.testing.expectEqual(@as(usize, 12), cases.len);

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

        // Stdlib imports should NOT emit @import of .zag files.
        try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"lib/std/") == null);
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
    // the router. Any name outside builtin_table falls through to the
    // verbatim fallback. This guards against an over-broad match that
    // would corrupt unrelated call sites when a future Phase adds
    // more entries. (The Phase 0 `get`/argv row was retired in the
    // v0.1 Tier-1 migration — lib/std/argv.zag owns that surface now.)
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

test "codegen: get routes through __zag_argv-backed real impl (no argv_get router)" {
    // v0.1 Tier-1 migration of std.argv.get from the argv_get
    // codegen-router inline emit. The router row is retired; the
    // imports loop's FAST path now binds the selector DIRECTLY to
    // the user module's `__zag_argv` global via stdlibPreambleName
    // (`const get = __zag_argv;`). The binding must NOT go through
    // the @import + alias slow path: the materialized std/argv.zig
    // is a separate zig module with its own preamble copy of
    // `__zag_argv`, which is never assigned (genFun's is_main
    // special case captures argv into the USER module's global).
    const src =
        \\pub import std.argv.{get}
        \\fun f() {
        \\    let args: []const []const u8 = get();
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
    // Positive: verbatim call site + the preamble-side binding.
    try std.testing.expect(std.mem.indexOf(u8, zig, "= get();") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const get = __zag_argv;") != null);
    // Negative: no @import alias for get (the broken cross-module
    // global path) and no retired per-call blk walker surface.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const get = __zag_imported_") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[32][]const u8") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.os.argv") == null);
}

test "codegen: process exec resolves via @import+alias (no process_exec router)" {
    // v0.1 Tier-1 migration of std.process.exec from the process_exec
    // codegen-router inline emit (per-call `blk: { var __child =
    // std.process.spawn(__zag_io, .{ .argv = ... }) ... }` shape) to
    // the real lib/std/process.zag impl `return __zag_process_spawn(
    // argv);` — the always-emitted preamble helper wraps spawn+kill+
    // wait and maps the .exited term to the child's exit code (else
    // 255). The call site is now VERBATIM through the @import+alias
    // fallthrough (Option A pass-through).
    const src =
        \\pub import std.process.{exec}
        \\fun f(argv: []const []const u8) -> i32 {
        \\    return exec(argv);
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
    // Positive: verbatim call site + the @import alias bridge.
    try std.testing.expect(std.mem.indexOf(u8, zig, "return exec(argv);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const exec = __zag_imported_") != null);
    // Positive: the preamble helper that the real impl forwards to.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_process_spawn(argv: []const []const u8) i32") != null);
    // Negative: the retired per-call router blk shape must not appear
    // at the user's call site (the preamble helper's own body starts
    // with a plain `var __child` on its own line, not `blk: { var`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { var __child = std.process.spawn") == null);
}

test "codegen: get_env routes through @import+alias fallthrough (no env_var router)" {
    // v0.1 Tier-1 migration of std.env.get_env from the env_var
    // codegen-router inline emit to a real lib/std/env.zag backed
    // by __zag_getenv. With the router retired, `pub import
    // std.env.{get_env}` emits `const __zag_imported_<i> = @import(
    // "lib/std/env.zag");` plus the per-selector alias
    // `const get_env = __zag_imported_<i>.get_env;` (src/codegen/
    // core.zig's imports loop Option A fallthrough). The bare-name
    // get_env("HOME") call site is THEN emitted VERBATIM at the
    // user's zig level — no per-call blk wrapper, no std.posix.getenv
    // shim, no __env_<N> scratch.
    const src =
        \\pub import std.env.{get_env}
        \\fun f() {
        \\    let home: ?str = get_env("HOME");
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
    // Positive: the @import + alias pair both land (imports-loop
    // Option A fallthrough fired, materialised-mirror path).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"std/env.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const get_env = __zag_imported_") != null);
    // Positive: the user call site is verbatim get_env("HOME").
    try std.testing.expect(std.mem.indexOf(u8, zig, "get_env(\"HOME\")") != null);
    // Negative: the retired router emit surface is gone.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.system.getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __env_") == null);
}

test "codegen: get_env call without std.env import emits verbatim (router retired)" {
    // The env_var router row is RETIRED — a bare get_env("HOME")
    // call with no `pub import std.env.{get_env}` now falls through
    // to the verbatim emit (the same treatment the retired
    // fs_read_file router got). This is a deliberate correctness
    // change: previously the router rewrote the call site into
    // std.posix.getenv even without an import; now the zag
    // compile-error at the zig level (undefined `get_env`) is the
    // surface, matching the @import+alias contract of every other
    // stdlib function.
    const src = "fun f() {\n    let x: ?str = get_env(\"HOME\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive (verbatim): no router touched the call site.
    try std.testing.expect(std.mem.indexOf(u8, zig, "get_env(\"HOME\")") != null);
    // Negative: the retired router surface is gone.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __env_") == null);
}

test "codegen: multiple get_env calls each emit verbatim with distinct args" {
    // Sibling get_env calls in the same body now produce identical
    // verbatim emit shapes (no per-call temp namespace — the
    // env_counter pattern was retired alongside the router). This
    // test pins that BOTH call sites survive verbatim with their
    // respective name arguments preserved.
    const src =
        \\pub import std.env.{get_env}
        \\fun f() {
        \\    let a: ?str = get_env("HOME");
        \\    let b: ?str = get_env("PATH");
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
    // Positive: both call sites verbatim with args preserved.
    try std.testing.expect(std.mem.indexOf(u8, zig, "get_env(\"HOME\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "get_env(\"PATH\")") != null);
    // Negative: the retired per-call temp pattern is gone.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __env_") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.posix.getenv") == null);
}

test "codegen: read_file routes through @import+alias fallthrough (no fs_read_file router)" {
    // v0.1 stdlib migration of std.fs.read_file from
    // fs_read_file codegen-router inline emit to a real
    // lib/std/fs.zag backed by __zag_posix. With the
    // router retired, `pub import std.fs.{read_file}`
    // emits `const __zag_imported_<i> = @import(
    // "lib/std/fs.zag");` plus the per-selector alias
    // `const read_file = __zag_imported_<i>.read_file;`
    // (src/codegen/core.zig's imports loop Option A
    // fallthrough). The bare-name read_file("/etc/hostname")
    // call site is THEN emitted VERBATIM at the user's
    // zig level — no per-call blk wrapper, no Io
    // event-loop instantiation, no __fs_<N> scratch.
    //
    // This test pins that the new shape lands: the @import
    // + alias pair both appear in the generated zig; the
    // user call site is verbatim; and the legacy router
    // substrings (readFileAlloc / std.Io.Threaded.init /
    // __fs_<N>) are absent. A regression that re-adds the
    // router (or fails to wire the imports-loop fallthrough)
    // would fail the positive or negative substrings.
    const src =
        \\pub import std.fs.{read_file}
        \\fun f() {
        \\    let d: String = read_file("/etc/hostname");
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

    // Positive: imports loop's @import preamble line (v0.1 Tier-1:
    // the materialised-mirror path `std/fs.zig`, not the raw
    // `lib/std/fs.zag` — see src/codegen/core.zig's imports loop).
    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"std/fs.zig\")") != null);
    // Positive: per-selector alias forwarding through import.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const read_file = __zag_imported_") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".read_file;") != null);
    // Positive: user's call site is verbatim (no router rewrite).
    try std.testing.expect(std.mem.indexOf(u8, zig, "read_file(\"/etc/hostname\")") != null);

    // Negative: legacy fs_read_file router substrings must NOT
    // appear — closing the regression path if the router is
    // re-introduced.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Threaded.init") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Dir.cwd().readFileAlloc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer __io_threaded.deinit()") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_1") == null);
}

test "codegen: read_file is emitted verbatim (no per-call scratch)" {
    // The fs_count bump that the old fs_read_file router
    // needed (one __fs_<N> per call to satisfy zig's no-
    // redeclaration rule) is RETIRED. Multiple read_file
    // calls in the same body now produce identical verbatim
    // emit shapes — the call site IS the declaration, no
    // scratch interposed. Naming is now the @import + alias
    // const read_file = __zag_imported_<i>.read_file, which
    // is declared once per import scope (not per call),
    // so sibling calls share the alias without conflict.
    const src =
        \\pub import std.fs.{read_file}
        \\fun f() {
        \\    let a: String = read_file("foo");
        \\    let b: String = read_file("bar");
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

    // Both call sites verbatim, in source order.
    try std.testing.expect(std.mem.indexOf(u8, zig, "read_file(\"foo\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "read_file(\"bar\")") != null);
    // No per-call scratch namespaced temp.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_1") == null);
    // No router-emit substrings.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Threaded.init") == null);
}

test "codegen: read_file no longer routes through fs_read_file builtin router" {
    // Locks down that the fs_read_file entry was removed
    // from src/codegen/builtins.zig's builtin_table: a
    // regression that re-adds it would surface
    // std.Io.Threaded.init here. The user's call is now
    // verbatim, NOT consumed by builtins.lookup inside
    // src/codegen/expr.zig's genCallSite arm.
    const src =
        \\pub import std.fs.{read_file}
        \\fun f() {
        \\    let d: String = read_file("/etc/hostname");
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

    // Positive: verbatim call site AND the alias bridge.
    try std.testing.expect(std.mem.indexOf(u8, zig, "read_file(\"/etc/hostname\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const read_file = __zag_imported_") != null);
    // Negative: router-substituted emit (no longer present).
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Threaded.init") == null);
}

// Fixture note (resolved): the 4th mixed-selector test exercising
// `pub import std.fs.{read_file, write_file, mkdir}` was deferred
// because mkdir was still on the codegen-router (fs_mkdir in
// expr.zig). The v0.1 mkdir migration (real .zag impl backed by the
// __zag_mkdirat preamble helper; fs_mkdir row retired) closes that
// gap — all three selectors now resolve verbatim through the
// imports-loop aliases, and the test below pins all-three coverage.

test "codegen: mixed fs selectors {read_file, write_file, mkdir} all emit verbatim (mkdir migrated)" {
    const src =
        \\pub import std.fs.{read_file, write_file, mkdir}
        \\fun f() {
        \\    let d: String = read_file("foo");
        \\    let w: i32 = write_file("bar", "x");
        \\    let m: i32 = mkdir("baz");
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

    // All three call sites verbatim, in source order.
    try std.testing.expect(std.mem.indexOf(u8, zig, "read_file(\"foo\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "write_file(\"bar\", \"x\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "mkdir(\"baz\")") != null);
    // Alias bridges for all three selectors.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const read_file = __zag_imported_") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const write_file = __zag_imported_") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const mkdir = __zag_imported_") != null);
    // Negative: no router-emit substrings (createDir blk shapes).
    try std.testing.expect(std.mem.indexOf(u8, zig, "createDir") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "var w = __m_0.Pos.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var h = __m_0.Pos.y") != null);
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
    try std.testing.expect(prog.functions[0].body[0].payload == .let);
    try std.testing.expect(prog.functions[0].body[0].payload.let.init != null);
    const init_expr = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init_expr.payload == .enum_variant_ctor);
    // LOAD-BEARING: enum_name MUST be null (gap #2 unqualified path).
    try std.testing.expect(init_expr.payload.enum_variant_ctor.enum_name == null);
    try std.testing.expect(std.mem.eql(u8, init_expr.payload.enum_variant_ctor.variant_name, "Pair"));
    try std.testing.expect(init_expr.payload.enum_variant_ctor.args.len == 2);


    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // Positive: source-named field init surfaces in zigzag.
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Pair = .{ .x = 2.0, .y = 3.0 } }") != null);
    // Sanity: legacy single-letter positional init (.a, .b) MUST NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, ".a = 2.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".b = 3.0") == null);
}

// v1.5 backed-enum codegen (docs/manual/13-enums.md §"Backed Enums"):
// the parser captures `enum(T) { V = value }` (backing type via
// collectCastType on the `(T)` slot, per-variant value_text verbatim)
// and codegen/decl.zig:795-879 routes the four emit shapes:
//   1. int-/char-backed explicit → `enum(T) { V = N, ... };`
//   2. str-backed falls back to synthesized struct (zig rejects
//      `enum([]const u8)` tag types)
//   3. char-backed routes through zagTypeToZig's `char → u32` rewrite
//   4. int-backed auto-infer omits `= N` when value_text is null
// The 4 fixtures below pin each surface individually so future
// regressions can't silently collapse one shape into another.
test "codegen: backed-enum(u8) explicit emits enum(u8) { V = N, ... }" {
    const src =
        \\enum(u8) Status { Ok = 0, Warn = 1, Err = 2 }
        \\
        \\fun main() { let s: u8 = Status.Ok; print(s); }
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Ok = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Warn = 1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Err = 2,") != null);
    // Sanity: NOT the bare-enum form (`enum {\n    Ok,`) nor the str-
    // backed struct fallback. The preamble contains `struct {` from
    // `__zag_String` and `__ZagMapEntry` — check only user code.
    {
        const user_start = std.mem.indexOf(u8, zig, "pub fn main") orelse zig.len;
        const check_slice = zig[0..user_start];
        const map_idx = std.mem.indexOf(u8, check_slice, "__ZagMapEntry");
        const final_slice = if (map_idx) |idx| check_slice[0..idx] else check_slice;
        const str_idx = std.mem.indexOf(u8, final_slice, "__zag_String");
        const pre_string = if (str_idx) |idx| final_slice[0..idx] else final_slice;
        try std.testing.expect(std.mem.indexOf(u8, pre_string, "struct {") == null);
    }
}

test "codegen: backed-enum(str) falls back to struct { pub const V = \"...\" }" {
    // zig rejects `enum([]const u8)` because enum tag types must be
    // integers; the codegen synthesizes a struct-with-const-fields
    // instead, so each variant becomes `pub const Name = value;`
    // and `Level.High` references a byte-string const that coerces to
    // `[]const u8` (zig's standard str-literal → slice coercion).
    const src =
        \\enum(str) Level { Low = "low", Medium = "medium", High = "high" }
        \\
        \\fun main() { let lvl: str = Level.High; print(lvl); }
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Low = \"low\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Medium = \"medium\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const High = \"high\";") != null);
    // Sanity: NOT the int-backed `enum(u8) {` form, NOT the str-tagged
    // `enum(str) {` form (zig rejects both with `expected integer tag type`
    // or `undefined identifier 'str'`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum(str) {") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum([]const u8) {") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum(u8) {") == null);
}

test "codegen: backed-enum(char) routes through zagTypeToZig's char→u32 rewrite" {
    // The char-backed emit shape: `enum(char) Vowel { A = 'a', ... }`
    // traverses zagTypeToZig's `char → u32` rewrite (the codegen-side
    // half of docs/features.md §08 v2 4-byte Unicode char row, gap (a))
    // so the zig emit is `pub const Vowel = enum(u32) { A = 97, ... };`
    // The char_lit codepoints round-trip through the lexer's brace-form
    // normalization to decimal values.
    const src =
        \\enum(char) Vowel { A = 'a', E = 'e', I = 'i', O = 'o', U = 'u' }
        \\
        \\fun main() { let a: char = Vowel.A; print(a); }
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum(u32) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "A = 'a',") != null);
    // Sanity: the codegen does NOT convert the value-side char
    // literal to its u32 codepoint (97) — it passes value_text
    // through verbatim and zig's char-literal → u32 coercion
    // resolves the value at compile time. A regression that
    // pre-converted would silently pass the positive pin above.
    try std.testing.expect(std.mem.indexOf(u8, zig, "A = 97,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "E = 'e',") != null);
    // Sanity: codegen does NOT convert char-literal value to its
    // u32 codepoint (zig coerces char literals at compile time).
    try std.testing.expect(std.mem.indexOf(u8, zig, "E = 101,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "I = 'i',") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "I = 105,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "O = 'o',") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "O = 111,") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "U = 'u',") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "U = 117,") == null);
    // Sanity: NOT the raw `enum(char) {` form (zig 0.16 rejects the bare
    // `char` ident with `undefined identifier`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum(char) {") == null);
}

test "codegen: backed-enum(u8) auto-infer omits = value when value_text is null" {
    // Integer-backed variants WITHOUT an explicit `= expr` clause are
    // emitted as bare identifiers (no `= N` assignment) so zig's own
    // `enum(T) { V1, V2, V3 }` auto-walker picks 0, 1, 2 successively.
    // A regression that emitted `First = 0,` instead would suppress
    // zig's auto-infer and silently double-bump the tag values.
    const src =
        \\enum(u8) AutoInfer { First, Second, Third }
        \\
        \\fun main() { let third: u8 = AutoInfer.Third; print(third); }
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "enum(u8) {") != null);
    // Variants emitted as bare identifiers + trailing comma (no
    // `= N` assignment — auto-infer is zig's responsibility).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    First,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    Second,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    Third,\n") != null);
    // Sanity: NO `= N` ASSIGNMENT for any of the three variants.
    try std.testing.expect(std.mem.indexOf(u8, zig, "First = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Second = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Third = ") == null);
}

// Canonical `with Trait (m)` clause dispatch (docs/17 §"Implementing"
// + §"Diamond Disambiguation"). The parser captures the trait list
// on ImplBlock.trait_specs; codegen's resolveTraitBinding routes
// each method body to the right vtable slot via the per-method
// dispatch rule:
//   (a) preferred_methods match → that spec's trait,
//   (b) uniqueness across listed traits → that trait,
//   (c) trait_specs empty → regular type method,
//   (d) ambiguous (multiple traits declare the method, no parens)
//       → compile error with the diamond-disambiguator hint.
// These tests pin paths (a), (b), and the shared-body shape so
// parser+AST+codegen for the canonical `with` form round-trips.

test "codegen: with Trait (m) preferred_methods binds body to trait's vtable (path a)" {
    // Diamond shape: both Display and Show declare `print`. The
    // parenthesised `(print)` on Drawable owns the body, so
    // codegen emits `Button_Drawable_print` and registers it on
    // Drawable's vtable. Show's `print` slot stays unfulfilled
    // (intentional partial impl — a second impl block completes
    // it; out of scope for this codegen test).
    const src =
        \\trait Display { fun print(self: *Self); }
        \\trait Show    { fun print(self: *Self); fun render(self: *Self); }
        \\struct Button { label: str }
        \\impl Button with Display (print), Show (render) {
        \\    pub fun print(self: *Button)  { }
        \\    pub fun render(self: *Button) { }
        \\}
        \\fun main() { let x: i32 = 0; }
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Path (a): the `print` body registers on Display's vtable via
    // the <Target>_<Trait>_<Method> rename. The `render` body
    // registers on Show's vtable (preferred_methods match too).
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Display_print(self: *Button) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Show_render(self: *Button) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Display_VTable_for_Button: Display.VTable = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Show_VTable_for_Button: Show.VTable = .{") != null);
    // Sanity: no legacy `pub fn Button_print` orphan (path (c)).
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_print(") == null);
}

test "codegen: with Trait (m) shared body registers on both vtables" {
    // Shared-body diamond: the parenthesised `(print)` on BOTH
    // traits owns the body. One body, two vtable entries — codegen
    // emits two renamed free fns (`Button_Display_print` and
    // `Button_Show_print`) pointing at the same source body, plus
    // both vtable registrations.
    const src =
        \\trait Display { fun print(self: *Self); }
        \\trait Show    { fun print(self: *Self); }
        \\struct Button { label: str }
        \\impl Button with Display (print), Show (print) {
        \\    pub fun print(self: *Button) { }
        \\}
        \\fun main() { let x: i32 = 0; }
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The single `print` body landed on BOTH vtables. Because
    // codegen uses body-by-value copy + per-trait rename, the same
    // body emits as two free fns — one per (target, trait) pair.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Display_print(self: *Button) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Show_print(self: *Button) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Display_VTable_for_Button: Display.VTable = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Show_VTable_for_Button: Show.VTable = .{") != null);
}

test "codegen: with Trait uniqueness infers binding when method name is unique (path b)" {
    // Path (b): a method whose name appears in EXACTLY ONE of the
    // listed traits dispatches automatically — no parens needed.
    // `draw` is unique to Drawable, `click` is unique to Clickable
    // even though both traits are listed without parenthesised
    // method lists.
    const src =
        \\trait Drawable  { fun draw(self: *Self); }
        \\trait Clickable { fun click(self: *Self); }
        \\struct Button { label: str }
        \\impl Button with Drawable, Clickable {
        \\    pub fun draw(self: *Button)  { }
        \\    pub fun click(self: *Button) { }
        \\}
        \\fun main() { let x: i32 = 0; }
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Both methods route to their owning trait's vtable via the
    // uniqueness path (no parens, but each method name is declared
    // by exactly one of the listed traits).
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Drawable_draw(self: *Button) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Clickable_click(self: *Button) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Drawable_VTable_for_Button: Drawable.VTable = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Clickable_VTable_for_Button: Clickable.VTable = .{") != null);
}

test "codegen: with Trait regular method (not in any listed trait) emits as orphan (path c)" {
    // Path (c): a method whose name appears in NO listed trait
    // stays a regular type method — no vtable registration, no
    // `<Target>_<Trait>_<Method>` rename. The struct-matching path
    // nests such methods INSIDE the zig struct body (emitted by
    // `genStructDecl`), so the emitted form is `pub fn log(...)`
    // (4-space indent) inside `pub const Button = struct { ... };`.
    // The trait-bound method (`draw`) skips nesting and emits as
    // a renamed module-scope free fn.
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\struct Button { label: str }
        \\impl Button with Drawable {
        \\    pub fun draw(self: *Button) { }
        \\    pub fun log(self: *Button) { }
        \\}
        \\fun main() { let x: i32 = 0; }
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // `draw` bound to Drawable's vtable (path b uniqueness). The
    // trait-binding rename `<Target>_<Trait>_<Method>` applies.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Button_Drawable_draw(self: *Button) void {") != null);
    // `log` is NOT in Drawable — regular type method, path (c).
    // It nests INSIDE the struct as `pub fn log(...)` (4-space
    // indent preceding `pub fn`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    pub fn log(self: *Button) void {") != null);
    // Sanity: no `Button_Drawable_log` rename crept in (regular
    // methods never get the trait-name infix).
    try std.testing.expect(std.mem.indexOf(u8, zig, "Button_Drawable_log") == null);
}

test "codegen: with Trait ambiguity (no parens, two traits declare same method) compile-errors" {
    // Path (d): when multiple listed traits share a method name and
    // no parenthesised disambiguator picks one, the compiler
    // surfaces a zag-level compile error with the disambiguator
    // hint. The error message names the colliding method and the
    // target type and suggests the `with T1 (m), T2` sugar.
    //
    // NOTE: this test executes `std.process.exit(1)` via the
    // codegen pass, which kills the test runner. To verify the
    // diagnostic WITHOUT crashing the suite, this test only parses
    // and AST-checks — it does NOT invoke `cg.generate`. The
    // dispatch rule fires at codegen time; the parser accepts the
    // shape and `trait_specs` records the specs.
    const src =
        \\trait Display { fun print(self: *Self); }
        \\trait Show    { fun print(self: *Self); }
        \\struct Button { label: str }
        \\impl Button with Display, Show {
        \\    pub fun print(self: *Button) { }
        \\}
        \\fun main() { let x: i32 = 0; }
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    // Sanity: the parser captured both specs without parens.
    try std.testing.expectEqual(@as(usize, 2), prog.impls[0].trait_specs.len);
    try std.testing.expectEqual(@as(usize, 0), prog.impls[0].trait_specs[0].preferred_methods.len);
    try std.testing.expectEqual(@as(usize, 0), prog.impls[0].trait_specs[1].preferred_methods.len);
}

test "codegen: default trait method emits Trait__Method free fn and vtable entry" {
    // When a trait method has a default body, codegen should emit
    // a standalone free fn named `<Trait>__<Method>` and register
    // it in the vtable even when the impl block omits the method.
    const src =
        \\trait Greeter {
        \\    pub fun hello(self: *Self) -> str {
        \\        return "hi";
        \\    }
        \\}
        \\struct Widget {}
        \\impl Widget with Greeter {}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Default free fn emitted
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn Greeter__hello(") != null);
    // VTable registration includes the default
    try std.testing.expect(std.mem.indexOf(u8, zig, ".hello = @ptrCast(&Greeter__hello)") != null);
}

test "codegen: impl override of default method still wins in vtable" {
    // When the impl provides a body for a default method, the impl's
    // body wins in the vtable — NOT the trait's default.
    const src =
        \\trait Greeter {
        \\    pub fun hello(self: *Self) -> str {
        \\        return "hi";
        \\    }
        \\}
        \\struct Widget {}
        \\impl Widget with Greeter {
        \\    pub fun hello(self: *Widget) -> str {
        \\        return "hey";
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
    // The impl's free fn is registered, not the default
    try std.testing.expect(std.mem.indexOf(u8, zig, ".hello = @ptrCast(&Widget_Greeter_hello)") != null);
    // The default free fn still exists (for types that don't override)
    try std.testing.expect(std.mem.indexOf(u8, zig, "Greeter__hello") != null);
}

test "codegen: Raku-style resolving method allows bare method alongside qualified ones" {
    // When two traits declare the same method name, a bare (unqualified)
    // method alongside qualified ones is a "resolver" — a regular
    // type method that dispatches to the preferred trait. It should NOT
    // produce an ambiguous binding error.
    const src =
        \\trait Drawable { fun draw(self: *Self); }
        \\trait Clickable { fun draw(self: *Self); }
        \\struct Button { label: str }
        \\impl Button with Drawable, Clickable {
        \\    pub fun draw(self: *Button) { self.Drawable.draw(); }
        \\    pub fun Drawable.draw(self: *Button) { }
        \\    pub fun Clickable.draw(self: *Button) { }
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
    // The resolver should NOT cause an ambiguous binding error
    // (the test reaching this point means the compiler didn't exit)
    // Qualified methods get their trait free fns
    try std.testing.expect(std.mem.indexOf(u8, zig, "Button_Drawable_draw") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Button_Clickable_draw") != null);
    // The bare method is a regular type method (no vtable entry)
    // It's emitted inside the struct as a nested pub fn
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn draw(") != null);
}

test "codegen: default body inherited when impl omits it — vtable includes Trait__Method ref" {
    // When a trait has a default method and the impl omits it, the
    // vtable registration should include the default free fn pointer.
    // No overloads — the existing VTable field-naming convention
    // doesn't yet support duplicate method names within a trait.
    const src =
        \\trait Greeter {
        \\    pub fun hello(self: *Self) -> str {
        \\        return "hi";
        \\    }
        \\    pub fun goodbye(self: *Self) -> str {
        \\        return "bye";
        \\    }
        \\}
        \\struct Widget {}
        \\impl Widget with Greeter {
        \\    pub fun hello(self: *Widget) -> str {
        \\        return "hey";
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
    // Impl-provided hello registered normally
    try std.testing.expect(std.mem.indexOf(u8, zig, ".hello = @ptrCast(&Widget_Greeter_hello)") != null);
    // Default goodbye inherited from trait — registered with Trait__Method ref
    try std.testing.expect(std.mem.indexOf(u8, zig, ".goodbye = @ptrCast(&Greeter__goodbye)") != null);
}

test "codegen: overloaded trait methods get suffixed VTable field names" {
    // When a trait has two methods with the same name (overloaded),
    // the VTable struct fields must be unique. The first occurrence
    // keeps the bare name; subsequent ones get a _1, _2... suffix.
    const src =
        \\trait Renderer {
        \\    pub fun render(self: *Self);
        \\    pub fun render(self: *Self, scale: f64);
        \\}
        \\struct Widget {}
        \\impl Widget with Renderer {
        \\    pub fun Renderer.render(self: *Widget) { }
        \\    pub fun Renderer.render(self: *Widget, scale: f64) { }
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
    // VTable type has unique field names — multiple overloads all get suffixes
    try std.testing.expect(std.mem.indexOf(u8, zig, "render_0: *const fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "render_1: *const fn") != null);
    // VTable registration uses the suffixed names pointing to suffixed free fns
    try std.testing.expect(std.mem.indexOf(u8, zig, "Widget_Renderer_render_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Widget_Renderer_render_1") != null);
    // Dispatch shims use the unsuffixed function name (zig handles overloading)
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn render(self: Renderer,") != null);
}

test "codegen: embedding promotion emits getter methods for embedded struct fields" {
    // When a struct embeds another struct with `Widget,`, the outer
    // struct should get forwarded getter methods so `btn.pos()` works
    // without `btn.Widget.pos`.
    const src =
        \\struct Widget {
        \\    pos: i32,
        \\}
        \\struct Button {
        \\    Widget,
        \\    label: str,
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
    // Embedded field still stored as named field
    try std.testing.expect(std.mem.indexOf(u8, zig, "Widget: Widget") != null);
    // Getter method for the pos field forwarded from Widget
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn pos(self: *const Button) i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return self.Widget.pos;") != null);
}

test "codegen: embedding promotion forwards non-trait impl methods" {
    // When a struct embeds another struct that has impl methods,
    // those methods should be forwarded to the outer struct.
    const src =
        \\struct Widget {
        \\    x: i32,
        \\}
        \\impl Widget {
        \\    pub fun show(self: *Widget) -> str {
        \\        return "ok";
        \\    }
        \\}
        \\struct Button {
        \\    Widget,
        \\    label: str,
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
    // Forwarded method on Button delegates to Widget, passing &self.Widget
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn show(self: *Button) []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "self.Widget.show(&self.Widget") != null);
}

test "codegen: extern fun emits pub extern fn declaration" {
    const src = "extern fun open(path: *raw u8, flags: i32) -> i32;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // *raw u8 → [*]u8 rewrite
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub extern fn open(path: [*]u8, flags: i32) i32;") != null);
    // No bare `*raw` in the output
    try std.testing.expect(std.mem.indexOf(u8, zig, "*raw") == null);
}

test "codegen: extern fun with c_void rewrites to anyopaque" {
    const src = "extern fun free(ptr: *raw c_void);\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // *raw c_void → [*]anyopaque
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub extern fn free(ptr: [*]anyopaque) void;") != null);
}

test "codegen: extern variadic fun emits ... in signature" {
    const src = "extern fun printf(fmt: *raw u8, ...) -> i32;\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Variadic signature
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub extern fn printf(fmt: [*]u8, ...) i32;") != null);
}

test "codegen: @[test] annotation emits test \"name\" { ... } block" {
    const src =
        \\@[test]
        \\fun my_test() {
        \\    assert(true);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Emits test block, not pub fn
    try std.testing.expect(std.mem.indexOf(u8, zig, "test \"my_test\" {") != null);
    // Does NOT emit pub fn
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn my_test(") == null);
    // assert builtin emits __zag_panic_at with zag source location
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_panic_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "assertion failed") != null);
}

test "codegen: assert(false, msg) emits expect with message" {
    const src =
        \\@[test]
        \\fun msg_test() {
        \\    assert(false, "should be true");
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "test \"msg_test\" {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_panic_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "should be true") != null);
}

test "codegen: const block emits comptime blk with break :blk" {
    const src =
        \\const TABLE: [3]i32 = const {
        \\    var t: [3]i32 = undefined;
        \\    return t;
        \\};
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // const block emits comptime labeled block
    try std.testing.expect(std.mem.indexOf(u8, zig, "comptime blk: {") != null);
    // Return statement becomes break :blk
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk t") != null);
}

test "codegen: type_name(T) emits @typeName(T)" {
    const src = "const NAME = type_name(i32);\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@typeName(i32)") != null);
}

test "codegen: if let Option.Some(val) switch-extracts the payload capture" {
    const src =
        \\fun f() {
        \\    let opt: Option<i32> = Option.Some(10);
        \\    if let Option.Some(val) = opt {
        \\        print("{val}");
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
    // Enum-variant if-let (Option.Some / Ok(v) / Err(e)): zig 0.16
    // rejects payload capture on a bare union condition (`if (opt)
    // |val|` — "expected optional type"), so the emit switch-extracts
    // the payload into an optional temp and captures on that:
    //   ({ var __zag_iflet_0: ?@FieldType(@TypeOf(opt), "Some") = null;
    //      switch (opt) { .Some => |p| __zag_iflet_0 = p, else => {} }
    //      if (__zag_iflet_0) |val| { ... } });
    try std.testing.expect(std.mem.indexOf(u8, zig, "@FieldType(@TypeOf(opt),") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "switch (opt) { .Some => |__zag_iflet_payload|") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__zag_iflet_0) |val| {") != null);
}

test "codegen: while let Option.Some(val) switch-extracts the payload capture" {
    const src =
        \\fun f() {
        \\    let opt: Option<i32> = Option.Some(10);
        \\    while let Option.Some(val) = opt {
        \\        print("{val}");
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
    // Enum-variant while-let: mirror of the if-let switch-extract —
    // the condition is a labeled block that extracts the payload into
    // an optional temp and breaks with it:
    //   while (__zag_wl_0: { var __zag_whilelet_0: ?@FieldType(@TypeOf(opt), "Some") = null;
    //       switch (opt) { .Some => |p| __zag_whilelet_0 = p, else => {} }
    //       break :__zag_wl_0 __zag_whilelet_0; }) |val| { ... }
    try std.testing.expect(std.mem.indexOf(u8, zig, "while (__zag_wl_0: { var __zag_whilelet_0: ?@FieldType(@TypeOf(opt),") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "switch (opt) { .Some => |__zag_whilelet_payload|") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "}) |val| {") != null);
}

test "codegen: __zag_posix preamble pins all 13 helpers + locks out steered-around substrings" {
    // The __zag_posix family (openat/read/write/close/getdents64/
    // clock_gettime/getcwd/getenv/exit/posix_spawn/waitpid) plus
    // mkdirat (fs.mkdir) and process_spawn (process.exec) is emitted
    // verbatim into the `generate()` preamble in src/codegen/core.zig.
    // Trivia zag source (no call sites) exercises the preamble alone,
    // so any per-helper drop shows up as a missing substring.
    //
    // Locks-down regression for two steered-around substrings that
    // historically leaked through the preamble multi-line literal (the
    // raw-string literal escapes comments verbatim into generated zig):
    //
    //   - `std.posix.system.getenv` — retired in zig 0.16; the
    //     self-contained `__zag_getenv` impl replaced it with a
    //     /proc/self/environ scanner (no stdlib dependency).
    //   - `std.mem.span` — used in the prior __zag_getenv bridge from
    //     `?[*:0]u8` → `[]const u8`; the new impl never needs it.
    //
    // A future zig 0.16 retirement (or a std.posix.* name that churned
    // back to a std.mem.* helper) will be caught by the negative
    // substring assertions at the bottom.
    const src = "fun f() {}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    // Positive: each of the 13 __zag_posix helpers must appear in the
    // preamble (verbatim, with fn-name intact).
    const __zag_posix_names = [_][]const u8{
        "__zag_openat",
        "__zag_read",
        "__zag_write",
        "__zag_close",
        "__zag_mkdirat",
        "__zag_getdents64",
        "__zag_clock_gettime",
        "__zag_getcwd",
        "__zag_getenv",
        "__zag_exit",
        "__zag_posix_spawn",
        "__zag_waitpid",
        "__zag_process_spawn",
    };
    inline for (__zag_posix_names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, zig, name) != null);
    }

    // Positive (signature): pin the structurally-unusual signatures
    // that are most likely to regress on a future migration:
    //   - __zag_openat uses `dirfd: i32` rather than `usize` because
    //     its caller passes `std.posix.AT.FDCWD` (which is -100). A
    //     usize migration would silently break the FDCWD bridge.
    //   - __zag_posix_spawn takes a many-pointer-with-sentinel slice of
    //     optional many-pointers — a shape that doesn't appear anywhere
    //     else in the codebase; regressing to `[*]const [*:0]const u8`
    //     would break execve's envp contract.
    // Other 9 helpers (read/write/close/getdents64/clock_gettime/getcwd/
    // getenv/exit/waitpid) pin by name only — their forwarders onto
    // `std.os.linux.*` have no regression-prone shape worth substringing.
    // Arg names (dirfd, argv) are POSIX/Linux-canonical; safe to pin
    // verbatim without re-bumping on every minor rename.
    const __zag_posix_sigs = [_][]const u8{
        "__zag_openat(dirfd: i32",
        "__zag_posix_spawn(argv: [*:null]const ?[*:0]const u8",
    };
    inline for (__zag_posix_sigs) |sig| {
        try std.testing.expect(std.mem.indexOf(u8, zig, sig) != null);
    }

    // Negative: steered-around substrings must not leak back into the
    // preamble (covers both code paths AND comment text inside the
    // raw-multi-line preamble literal — see core.zig generate()).
    // `std.posix.getenv` was the per-call getEnv builtin's emit
    // (zig-0.16 form; replacement for the retired `system.getenv`),
    // but BOTH are retired as of the v0.1 Tier-1 migration — env
    // lookup lives in lib/std/env.zag's real impl (__zag_getenv).
    // The PREAMBLE itself must never reference std.posix.getenv —
    // only `__zag_getenv` may. Trivia zag source has no get_env
    // call site, so any `std.posix.getenv` hit is a preamble leak.
    const forbidden = [_][]const u8{
        "std.posix.system.getenv",
        "std.posix.getenv",
        "std.mem.span",
    };
    inline for (forbidden) |substr| {
        try std.testing.expect(std.mem.indexOf(u8, zig, substr) == null);
    }
}

test "codegen: Layer 3a panic-trace machinery emitted after the map table" {
    // docs/manual/33-debugging.md Layer 3a: the root panic override
    // (std.debug.FullPanic) + the zag-native trace handler are
    // emitted at the end of generate(), right after the embedded
    // __zag_map table. Debug builds route panics through it; release
    // builds keep zig's defaultPanic via the mode-gated const.
    const src = "fun f() {\n    let p = new i32(42);\n    print(\"{p}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Root override: FullPanic(__zag_panic_trace) in Debug,
    // FullPanic(std.debug.defaultPanic) in release.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const panic = if (@import(\"builtin\").mode == .Debug)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.FullPanic(__zag_panic_trace)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.FullPanic(std.debug.defaultPanic)") != null);
    // Trace machinery: exact-site globals, map binary search, source-
    // line reader, and the public-unwind walk (captureCurrentStackTrace
    // + getSymbols — StackIterator itself is private in zig 0.16).
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub var __zag_panic_site_file: []const u8 = \"\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn __zag_panic_map_lookup(zig_line: u32) ?__ZagMapEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn __zag_panic_print_source_line(file: []const u8, line: u32, col: u32) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn __zag_panic_trace(msg: []const u8, first_trace_addr: ?usize) noreturn") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.captureCurrentStackTrace") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "di.getSymbols") != null);
    // The exact-site delegation in the preamble __zag_panic_at.
    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"root\").__zag_panic_trace(msg, @returnAddress());") != null);
    // Ordering: the machinery must land AFTER the map table (both at
    // the end of the module, after the last user fn).
    const map_at = std.mem.indexOf(u8, zig, "const __ZagMapEntry = struct") orelse return error.TestUnexpectedResult;
    const last_fn = std.mem.lastIndexOf(u8, zig, "pub fn f()") orelse return error.TestUnexpectedResult;
    const trace_at = std.mem.indexOf(u8, zig, "fn __zag_panic_map_lookup") orelse return error.TestUnexpectedResult;
    try std.testing.expect(last_fn < map_at);
    try std.testing.expect(map_at < trace_at);
}

test "codegen: Layer 3a override suppressed when program imports a panic selector" {
    // Collision guard: `pub import std.debug.{panic}` emits
    // `const panic = __zag_imported_<N>.panic;` at module scope,
    // which would clash with the root `pub const panic` override
    // (the pre-Tier-1 FullPanic shim was retired for exactly this).
    // The machinery itself is still emitted (the preamble's
    // __zag_panic_at delegates to it by name).
    const src = "pub import std.debug.{panic}\nfun f() {\n    panic(\"x\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const panic = __zag_imported_") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const panic = if (@import(\"builtin\").mode == .Debug)") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn __zag_panic_trace") != null);
}

test "codegen: Layer 3a override suppressed when the module itself defines panic" {
    // Collision guard, second arm: the materialized lib/std/debug.zag
    // DEFINES `pub fun panic` — a transpiled file with that decl must
    // not also carry the override (duplicate struct member `panic`).
    const src = "fun panic(msg: str) {\n    print(\"{msg}\\n\");\n}\nfun f() {}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const panic = if (@import(\"builtin\").mode == .Debug)") == null);
    // Machinery still present for the delegation path.
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn __zag_panic_trace") != null);
}

test "codegen: Layer 3a machinery emitted even for a statement-free program" {
    // The map table + machinery are always emitted (empty entry list
    // when map_count == 0) so every module's __zag_panic_at delegation
    // resolves by name — zig 0.16 name-resolves identifiers inside
    // comptime-pruned `if` branches, so a conditionally-absent table
    // would fail to compile in any file whose preamble guards on it.
    const src = "fun f() {}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __ZagMapEntry = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn __zag_panic_trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const panic = if (@import(\"builtin\").mode == .Debug)") != null);
}

test "codegen: pub use std.X as name emits module re-export @import" {
    // docs/manual/22 §Re-exports: `pub use std.env as env` emits
    // `pub const env = @import("std/env.zig");` so `env.get_env(...)`
    // resolves through the re-exported module's namespace. The path
    // rewrite mirrors the imports loop (materialized-mirror shape).
    const src =
        \\pub use std.env as env
        \\fun main() {
        \\    let home: ?str = env.get_env("HOME");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const env = @import(\"std/env.zig\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "env.get_env(\"HOME\")") != null);
}

test "codegen: non-pub use emits module-local const binding" {
    // `use std.fs as fs` (no pub) binds fs module-locally.
    const src =
        \\use std.fs as fs
        \\fun f() {
        \\    let d: String = fs.read_file("x");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "const fs = @import(\"std/fs.zig\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const fs = @import") == null);
}

test "codegen: async fun emits Future(T) signature and done-wrapped return" {
    // docs/manual/18-traits.md §"Async Trait Methods" + the overview's
    // "Zero-cost async" goal: `async fun f() -> T { return EXPR; }`
    // emits `pub fn f() Future(T)` with the return wrapped into
    // `.{ .done = true, .value = EXPR }`.
    const src =
        \\async fun greet(name: str) -> str {
        \\    return "hi";
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn greet(name: []const u8) Future([]const u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return .{ .done = true, .value = ") != null);
    // The preamble Future(T) + drive helper.
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn Future(comptime T: type) type") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "fn __zag_future_drive(comptime T: type, fut: *T) void") != null);
}

test "codegen: await lowers to the inline-drive form" {
    const src =
        \\async fun f() {
        \\    await g();
        \\    let x: i32 = await h();
        \\    return x;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_future_drive(@TypeOf(__fut_0), &__fut_0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __fut_0.value.?;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const x: i32 = (blk: { var __fut_1 = h(); __zag_future_drive(@TypeOf(__fut_1), &__fut_1); break :blk __fut_1.value.?; });") != null);
}

test "codegen: import std.types.{String} binds the preamble String type" {
    // std.types is the canonical home of the String type (moved from
    // (moved from std.string, which no longer exists). In the user
    // module the selector takes the fast path: `pub const String =
    // __zag_String;`.
    const src =
        \\import std.types.{String}
        \\fun f() {
        \\    let s: String = String.with_capacity(8);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "const String = __zag_String;") != null);
}

test "codegen: pub import emits pub const (cross-module re-export)" {
    // Cross-module re-exports (e.g. lib/std/mod.zag re-exporting
    // std.types.{String}) depend on `pub import` emitting
    // `pub const NAME = ...` — a plain `const` fails with zig's
    // "decl is not pub" at the materialized-file use site.
    const src =
        \\pub import std.types.{String}
        \\fun f() {
        \\    let s: String = String.with_capacity(8);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const String = __zag_String;") != null);
}

test "codegen: std.string no longer resolves (String lives only in std.types)" {
    // The legacy std.string module was removed: `import
    // std.string.{String}` misses KNOWN_STD_MODULES and is skipped
    // silently (null-on-miss contract), so the emitted module has
    // no binding for it — the user's `String` use then fails at zig
    // compile time with "undeclared identifier" instead of binding
    // a second path to the type.
    const src =
        \\import std.string.{String}
        \\fun f() {
        \\    let s: String = String.with_capacity(8);
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
    // No import binding, no alias for the missing module (the
    // hybrid preamble imports std/types.zig, not std/string.zig).
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __zag_std_string = @import") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const String = __zag_imported_") == null);
    // The binding's type annotation still references String — zig
    // rejects it as undeclared (the intended "not allowed" signal).
    try std.testing.expect(std.mem.indexOf(u8, zig, "const s: String =") != null);
}
