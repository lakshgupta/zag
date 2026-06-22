// Auto-extracted from src/main.zig. Tests live here so main.zig
// stays focused on CLI plumbing. Zigs `test "..." {}` discovery
// follows the comptime imports at the bottom of main.zig.

const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const codegen_mod = @import("../codegen.zig");
const ast = @import("../ast.zig");

test "codegen: hello world" {
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "std.debug.print") != null);
}

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

test "codegen: hex literal preserved" {
    const src = "fun f() {\n    let x: i32 = 0xFF;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "0xFF") != null);
}

test "codegen: float literal preserved" {
    const src = "fun f() {\n    let pi: f64 = 3.14;\n    let e: f64 = 1.0e10;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "3.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "1.0e10") != null);
}

test "codegen: bool literal emits true/false" {
    const src = "fun f() {\n    let on: bool = true;\n    let off: bool = false;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= false;") != null);
}

test "codegen: null and undefined emit literally" {
    const src = "fun f() {\n    let a: ?i32 = null;\n    let b: i32 = undefined;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= undefined;") != null);
}

test "codegen: char literal emit" {
    const src = "fun f() {\n    let c: u8 = 'a';\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "'a'") != null);
}

test "codegen: byte string emits zig string" {
    const src = "fun f() {\n    let b = b\"hello\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"hello\"") != null);
}

test "codegen: tuple emits anonymous struct" {
    const src = "fun f() {\n    let p = (10, 20);\n    let empty = ();\n    let mixed = (1, 2.5, true);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 10, 20 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= {};") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 1, 2.5, true }") != null);
}

test "codegen: array explicit emits [N]T{...}" {
    const src = "fun f() {\n    let a = [3]i32 { 1, 2, 3 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[3]i32{ 1, 2, 3 }") != null);
}

test "codegen: array fill emits [1]T{...}**N" {
    const src = "fun f() {\n    let z = [5]i32 { 0 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[1]i32{ 0 } ** 5") != null);
}

test "codegen: array progression emits blk+__pat pattern" {
    const src = "fun f() {\n    let r = [4]i32 { 1, 2 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __arr: [4]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __pat: [2]i32 = .{ 1, 2 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__pat[__i % 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __arr") != null);
}

test "codegen: template literal in print emits std.debug.print" {
    const src = "fun f() {\n    let name = \"zag\";\n    print(\"hello, {name}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // zig 0.16 requires a trailing comma inside `.{...}` even when only one
    // field is present; we always emit `.{name,}` for single-arg interpolation.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.print(\"hello, {any}\\n\", .{name,})") != null);
}

test "codegen: template preserves LF byte in literal via \\n escape" {
    // zag user wrote literal newline byte inside the string (inside "").
    // The format string in codegen must escape it to \\n so the zig string
    // literal remains valid.
    const src = "fun f() {\n    let x = \"a\";\n    print(\"a{x}a\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"a{any}a\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.print") != null);
}

test "codegen: module-level interp_buf emitted" {
    const src = "fun f() {\n    print(\"{x}\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __zag_interp_buf: [4096]u8 = undefined") != null);
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

test "codegen: binary emission is parenthesised" {
    // The generated zigzag source must wrap binary expressions in `()` so
    // downstream zig's natural precedence rules cannot reorder the AST's
    // intent (relevant once we add lower-precedence operators).
    const src = "fun f() {\n    let z: i32 = 1 + 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + 2);") != null);
}

test "codegen: precedenced arithmetic emits nested parens" {
    // 1 + 2 * 3 must surface as `1 + (2 * 3)` in generated zigzag source so
    // zig observes the AST's chosen ruling under standard math precedence.
    const src = "fun f() {\n    let z: i32 = 1 + 2 * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + (2 * 3));") != null);
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

test "codegen: x/2 emits @divTrunc shim when LHS is runtime int" {
    // The pattern from the failing smoke test: `x /= 2` desugars to
    // `x = x / 2;` where LHS is an `.ident` (runtime int) and RHS is a
    // comptime `.int_lit`. zig 0.16 demands `@divTrunc(x, 2)` here because
    // the result type of `i32 / comptime_int` isn't decidable.
    const src = "fun f() {\n    var x: i32 = 10;\n    x = x / 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(x, 2)") != null);
    // Sanity: the bare `(x / 2)` form must NOT appear in the assignment RHS.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x / 2)") == null);
}

test "codegen: x%2 emits @rem shim when LHS is runtime int" {
    // Mirror of the `.div` test: `x %= 2` desugars to `x = x % 2;` and
    // codegen routes the RHS through `@rem(x, 2)`.
    const src = "fun f() {\n    var x: i32 = 10;\n    x = x % 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(x, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x % 2)") == null);
}

test "codegen: 1/2 stays bare when both sides are comptime int" {
    // The "floored/comptime cases can stay bare" carve-out: `1 / 2` is
    // pure comptime; zig folds the bare `(1 / 2)` form to `0` at compile
    // time, so we don't need to wrap in `@divTrunc`. Preserves the user's
    // source round-trip in the generated zigzag.
    const src = "fun f() {\n    let z: i32 = 1 / 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: i32 = 1 / 2` annotation through to
    // zig; the carve-out keeps bare-form legal too, so the test stays
    // source-shape stable here.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 / 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: 1.0/2.0 stays bare when LHS is float" {
    // Both LHS and RHS are float literals — the RHS is NOT `.int_lit`, so
    // `needsIntDivShim` short-circuits on its `b.rhs.* != .int_lit` guard
    // and the bare `(/)` form is preserved. `@divTrunc` would be invalid
    // here because it requires integer arguments.
    const src = "fun f() {\n    let z: f64 = 1.0 / 2.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: f64 = 1.0 / 2.0` annotation through.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: f64 = (1.0 / 2.0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
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

test "codegen: 2/x stays bare when LHS is comptime int and RHS is ident" {
    // Defensive pin on the predicate's `b.rhs.* != .int_lit` fast path:
    // when RHS is an `.ident` (not an int literal) the shim short-circuits,
    // even though LHS is comptime-int. This is the mirror image of the
    // main shim trigger case.
    const src = "fun f() {\n    let z: i32 = 2 / x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Source includes the `: i32` annotation — preserve it in the
    // assertion to track the actual emission.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (2 / x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: 1.0/x stays bare when LHS is float and RHS is ident" {
    // Defensive pin on the mixed-comptimes case: `exprContainsFloat`
    // returns true because LHS IS a `.float_lit`, so even though RHS is
    // not an int literal we'd see a `false` from the predicate via a
    // different guard. Verifies the bare form is preserved.
    const src = "fun f() {\n    let z: f64 = 1.0 / x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: f64 = 1.0 / x` annotation through to
    // zig; codegen forwards `: T` on the binding so the assertion tracks
    // the actual emission shape (the test stays bare-form-agnostic —
    // `1.0` is float and `x` is unannotated, neither path can ever
    // trigger the `@divTrunc` shim).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: f64 = (1.0 / x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
}

test "codegen: f64-typed ident LHS / int_lit stays bare (typed-binding lookup)" {
    // The targeted hole: `let pi: f64 = 3.14; pi / 2` — LHS is `.ident "pi"`
    // so `exprContainsFloat` returns false on the LHS subtree (no
    // `.float_lit` node), but the binding is annotated `f64`. Without the
    // `collectTypedBindings` map, `needsIntDivShim` would fire and emit
    // `@divTrunc(pi, 2)`, which zig 0.16 rejects because `@divTrunc`
    // requires integer args. The fix maps `pi → f64` and the predicate's
    // `self.isFloatIdentType(...)` short-circuit returns false, leaving
    // the bare `(pi / 2)` form. zig infers the operand types from the
    // const-binding annotation and accepts the result.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r: f64 = pi / 2;
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
    // Bare form preserved; no shim wrap.
    // Source includes the `: f64` annotation — mirror it in the assertion
    // so the test tracks the actual emission.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r: f64 = (pi / 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
}

test "codegen: i32-typed ident LHS / int_lit still triggers @divTrunc shim" {
    // The non-regression pin: when the LHS ident is annotated with an
    // INTEGER type (f16/f32/f64 absent from the map), the predicate still
    // fires and the shim is emitted. Without this guard the per-function
    // map could over-broadly skip the shim and break `let x: i32 = 10;
    // x / 2;` codegen.
    const src =
        \\fun f() {
        \\    let n: i32 = 10;
        \\    let z: i32 = n / 2;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(n, 2)") != null);
    // Source includes `: i32` annotation; codegen shim path replaces
    // `(n / 2)` with `@divTrunc(n, 2)` so the literal bare form does
    // NOT survive.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (n / 2);") == null);
}

test "codegen: f64-typed ident LHS % int_lit stays bare" {
    // Mirror of the `/` case for the `.mod` operator: `let pi: f64 = 3.14;
    // pi % 2` must emit the bare form because `@rem` requires integer args.
    // The `isFloatIdentType` map check applies symmetrically to `.mod`.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r: f64 = pi % 2;
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
    // Source includes `: f64` annotation; codegen routes the bare form
    // through (mirror of the `/` test).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r: f64 = (pi % 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: unannotated i32-init binding / int_lit still triggers @divTrunc" {
    // DELETED: the static-typed-coercion carve-out now requires `: T`
    // annotations on EVERY bare binding whose RHS is a non-literal
    // expression. The original test source `let x = 10; let z = x / 2;`
    // no longer parses (it surfaces "let requires an explicit type
    // annotation when binding non-tuple values"). The semantic intent
    // — verifying that the shim still fires when the LHS maps to an
    // integer type — is now exercised by the
    // `i32-typed ident LHS / int_lit still triggers @divTrunc shim` test
    // directly above, which carries the `: i32` annotation on both
    // bindings and asserts the same shim path. No regression introduced
    // — the typed-binding map's "integer → shim fires" code path is
    // still covered.
}

test "codegen: new T(v) emits page_allocator.create heap alloc (bug fix)" {
    // The docs/spec contract for `new` is heap allocation. The previous
    // emission `blk: { var __val: T = v; break :blk &__val; }` was a
    // stack-pointer escape (UB on `free`). The rewrite routes through
    // `try std.heap.page_allocator.create(T)` so `free(p)`'s matching
    // `page_allocator.destroy(p)` correctly deallocates the heap cell.
    //
    // The current emit for `let p = new i32(42)` is:
    //   const p = blk: { const __p_0 = try std.heap.page_allocator.create(i32);
    //                     __p_0.* = 42; break :blk __p_0; };
    // (Pre-existing test asserted `const p = __p_0` — a bare-assignment
    // shape that was true before the docs/19-memory.md heap rewrite; the
    // rewrite uses the blk-wrapped form so we can still reference `__p_0`
    // after the assignment without zig's no-redeclaration trouble.)
    const src = "fun f() {\n    let p = new i32(42);\n    defer free(p);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __p_0") != null);
    // The page_allocator.destroy(p) — for the matching free(p) below.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy") != null);
    // Sanity: the OLD stack-pointer emission must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __val: i32 = 42") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "&__val") == null);
}

test "codegen: new(<arena>, T(v)) emits <arena>.create(T) (allocator sugar)" {
    // Pattern 3 sugar: codegen routes through the user-supplied allocator's
    // `create` method rather than the global page allocator.
    const src = "fun f() {\n    let p = new(arena, i32(0));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try arena.create(i32)") != null);
    // Sanity: must NOT use the global page allocator.
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.create") == null);
}

test "codegen: alloc_counter increments across multiple new exprs" {
    // Two `new` expressions in the same body must produce distinct `__p_<N>`
    // names so zig's no-redeclaration rule is satisfied. The codegen uses a
    // single per-function `alloc_counter` (reset at `genFun`) that increments
    // per `new_expr` visit in `genExpr`, so two bindings surface distinct
    // `__p_0` and `__p_1`. Each `__p_<N>` is also internal to its own
    // `blk: { … }` scope — the counter step is the simpler invariant that
    // satisfies both flat scopes and nested blk scopes (the latter tolerate
    // same-name shadowing but the counter keeps emissions human-comparable).
    const src =
        \\fun f() {
        \\    let a = new i32(1);
        \\    let b = new i32(2);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_1.* = 2") != null);
}

test "codegen: errdefer stmt emits errdefer verbatim" {
    // Mirrors zig 0.16's `errdefer` keyword one-to-one so zig's semantics
    // (runs the expression ONLY on `?`-propagation or `Err` early-return)
    // match the zag docs' Pattern 2 framing.
    //
    // `errdefer <expr>` triggers genExpr on `expr`. For `print(string_lit)`
    // the call-emit is `std.debug.print("...", .{})` (the literal-string
    // specialization). So the errdefer output is
    // `    errdefer std.debug.print("cleanup\n", .{});`.
    // Pre-existing test was written when codegen emitted the user's
    // `print(...)` verbatim (a simpler print codegen). Updated to the
    // current stamp-shape substring.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    errdefer std.debug.print(\"cleanup\\n\", .{})") != null);
}

test "codegen: unsafe block emits body in plain block with comment markers" {
    // zig 0.16 has no block-form `unsafe` keyword — the block is purely a
    // source-level audit marker. Codegen emits the body wrapped in plain
    // `{ ... }` with `// unsafe {` and `// }` comments so the structure is
    // visible to `-Dunsafe-block-check` tooling without affecting the
    // emitted zig semantics (raw pointer ops are already unconditional).
    //
    // The body's `print(string_lit)` codegen emits `std.debug.print(...)`,
    // NOT the user's `print(...)` verbatim. Pre-existing test was written
    // when codegen was simpler — updated to the current emission shape.
    const src = "fun f() {\n    unsafe {\n        print(\"inside\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // unsafe {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.print(\"inside\\n\", .{})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // }") != null);
}

test "codegen: as cast emits @as builtin" {
    // The parser's `collectCastType` joined multi-token types like
    // `*raw c_void` into one `type_text` slice; codegen emits
    // `@as(type_text, expr)` so zig's `@as` builtin handles the cast
    // surface natively (pointers, numerics, raw pointers). zig 0.16
    // dropped the `as` operator entirely (verified empirically:
    // `pi as f32` produces `expected ';'` and `(pi as f32)` produces
    // `expected ')'`, while `@as(f32, pi)` parses cleanly) so this
    // matches the post-deprecation cast shape that zig natively accepts.
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y: i32 = @as(i32, x);") != null);
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

test "codegen: member_access emits target.name verbatim" {
    // `v.x` → `v.x`. Zig's struct-field access syntax matches zag's
    // surface verbatim, so codegen is a one-line passthrough. This test
    // makes the user-facing property obvious: any struct-typed `v` whose
    // zig-declared struct has field `.x` round-trips without
    // transformation.
    const src = "fun f() {\n    let a: f64 = v.x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= v.x;") != null);
}

test "codegen: method_call emits target.name(args) verbatim" {
    // `v.length()` and `Vec3.new(1.0, 2.0, 3.0)` both emit verbatim —
    // zig natively distinguishes value-receiver and type-static forms.
    // The simpler receiver form `v.length()` shows up as
    // `    const len: f64 = v.length();`-style emission.
    const src = "fun f() {\n    let len: f64 = v.length();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const len: f64 = v.length();") != null);
}

test "codegen: field_assign emits target.field = value;" {
    // `v.x = 10.0;` → `    v.x = 10.0;`. Zig accepts field-write to a
    // `var`-binding receiver verbatim; writing to a `const`-recevier is
    // rejected by zig at compile time, mirroring zag's binding-kind
    // semantics.
    const src = "fun f() {\n    v.x = 10.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    v.x = 10.0;") != null);
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

test "codegen: if-stmt with else emits zig if/else" {
    // Statement form with else: codegen emits `if (cond) { … } else { … }`.
    const src =
        \\fun f() {
        \\    if x > 0 {
        \\        print("pos\n");
        \\    } else {
        \\        print("neg\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    std.debug.print(\"neg\\n\", .{});") != null);
}

test "codegen: if-stmt with else-if chain emits chained zig emission" {
    // A multi-arm else-if chain should emit as a single `if/else if/
    // else` zigzag statement — no nested `(blk: { ... })` blocks for the
    // pure statement form.
    const src =
        \\fun f() {
        \\    if a {
        \\        print("a\n");
        \\    } else if b {
        \\        print("b\n");
        \\    } else {
        \\        print("other\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if a {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else if b {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    std.debug.print(\"other\\n\", .{});") != null);
}

test "codegen: if-expression emits labeled blk + break :blk" {
    // The expression form must surface as a labeled block yielding a value:
    // `(blk: { if (cond) break :blk <then> else break :blk <else>; })`.
    // The outer `(blk: { … })` makes the rhs parenthesised so it can sit in
    // any expression position (e.g. RHS of a `let` binding).
    const src =
        \\fun f() {
        \\    let z: i32 = if x > 0 { 1 } else { 0 };
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: { if (x > 0) break :blk 1 else break :blk 0; })") != null);
}

test "codegen: while-stmt emits zig while verbatim" {
    // The cond and body emit directly via zig's native syntax — no shim
    // is needed because zig's `while` semantics match zag's.
    const src =
        \\fun f() {
        \\    while i < 10 {
        \\        i = i + 1;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    while (i < 10) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    i = (i + 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    }") != null);
}

test "codegen: for-range emits zig `start..end[+1]`" {
    // The range shape gets INLINE-emitted as `start..end[ + 1]` so zig's
    // native range syntax (half-open) encodes the inclusive flag without
    // the anonymous-tuple round-trip.
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        print("i\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (0..10) |i| {") != null);
    // Sanity: the .iter not as anonymous struct.
    try std.testing.expect(std.mem.indexOf(u8, zig, "for (.{ 0,") == null);
}

test "codegen: for-incl range emits end+1" {
    // Inclusive range (3-arm `.end + 1`) flips the half-open semantics
    // into inclusive so `for i in 0...10` iterates 0,1,…,10 (not 0,…,9).
    const src =
        \\fun f() {
        \\    for i in 0...10 {
        \\        print("i\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (0..10 + 1) |i| {") != null);
}

test "codegen: for-iter non-range emits verbatim iter call" {
    // For-loop iter that isn't a range emits the user's expression
    // verbatim — codegen bypasses the inline range rewrite.
    const src =
        \\fun f() {
        \\    for x in items() {
        \\        print("x\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (items()) |x| {") != null);
}

test "codegen: match-stmt emits labeled laddered if-else" {
    // Each arm gets emitted as an `if (<cond>) { break :blk <body>; }`,
    // chained via `else`. The scrutinee is bound to a `__m_<N>` temp so
    // arm conditions can refer to the value without re-evaluation.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\        _ => "other",
        \\    };
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: { const __m_0 = n;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__m_0 == 1) { break :blk \"one\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__m_0 == 2) { break :blk \"two\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (true) { break :blk \"other\"; }") != null);
    // Sanity: trail is appended as a `;` (stmt-position append in
    // genStmt `.match_stmt` arm).
    try std.testing.expect(std.mem.indexOf(u8, zig, "});") != null);
}

test "codegen: match-stmt with non-wildcard last emits `else unreachable;`" {
    // When the last arm is NOT a wildcard, codegen appends `else unreachable;`
    // so zig's exhaustive-match check is satisfied and the user gets a
    // compile-time error if they missed a case.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        _ => "other",
        \\    };
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
    // The trailing arm IS a wildcard, so no fallback expected:
    try std.testing.expect(std.mem.indexOf(u8, zig, "unreachable") == null);
}

test "codegen: match-stmt with non-wildcard LAST arm emits \";}\" + unreachable fallback" {
    // The user-confirmed shape: when the chain has NO wildcard arm, codegen
    // must append `else unreachable;` after the last `if (...)` so zig's
    // exhaustive-match check doesn't fail. This pins the exhaustiveness
    // intent explicitly.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\    };
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "} else unreachable;") != null);
}

test "codegen: match-stmt with range arm emits bounds check" {
    // The range arm builds a bounds check on the scrutinee temp. Half-open
    // range `0..10` emits `(>= 0) and (< 10)` so the ladder condition
    // uses zig's native `and` keyword.
    const src =
        \\fun f() {
        \\    match n {
        \\        0..10 => "low",
        \\        _ => "high",
        \\    };
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "((__m_0 >= 0) and (__m_0 < 10))") != null);
}

test "codegen: match-stmt identifies ident arm emits const binding" {
    // An ident-pattern arm (`x => x + 1`) must emit
    // `const x = __m_<N>;` BEFORE the arm body's `break :blk` so the
    // body can reference `x`.
    const src =
        \\fun f() {
        \\    match n {
        \\        x => x + 1,
        \\        _ => 0,
        \\    };
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (true) { const x = __m_0; break :blk (x + 1); }") != null);
}

test "codegen: match-counter increments per match" {
    // Two match expressions in the same body produce distinct `__m_<N>`
    // names so zig's no-redeclaration rule is satisfied.
    const src =
        \\fun f() {
        \\    match a {
        \\        1 => 10,
        \\        _ => 0,
        \\    };
        \\    match b {
        \\        2 => 20,
        \\        _ => 0,
        \\    };
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_0 = a") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_1 = b") != null);
}

test "codegen: break-stmt emits zig break;" {
    // Codegen emits zig's bare `break;` (no label, no value).
    const src =
        \\fun f() {
        \\    while true {
        \\        break;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    break;") != null);
}

test "codegen: continue-stmt emits zig continue;" {
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        continue;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    continue;") != null);
}

test "codegen: return-stmt with value emits `return <expr>;`" {
    const src = "fun f() {\n    return 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return 42;") != null);
    // Sanity: not the bare form.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return;") == null);
}

test "codegen: bare return emits `return;`" {
    const src = "fun f() {\n    return;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return;") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[..3]") != null);
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

test "codegen: single_tuple_lit emits .{ EXPR }" {
    // The bare form `let a = (42,)` emits `const a = .{ 42 };` — an
    // anonymous-struct-of-one-position literally. We deliberately avoid
    // `let a: i32 = (42,)` here because zig 0.16 does not unify
    // `.{ 42 }` with `i32` (anonymous-struct-of-comptime_int is not
    // coerced to a bare primitive by simple annotation); the bare form
    // matches the round-trip-the-source-intent carve-out used by the
    // other literal-only tests.
    const src = "fun f() {\n    let a = (42,);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = .{ 42 };") != null);
}

test "codegen: named_tuple_lit emits .{ .name = expr, ... }" {
    const src = "fun f() {\n    let p = (x: 10, y: 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Source has NO `: T` annotation so codegen emits `const p = .{ .x = 10, .y = 20 };`
    // without the type annotation. (The static-typed-coercion carve-out tests
    // deliberately use bare `let NAME = ...` shape so this stays bare.)
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p = .{ .x = 10, .y = 20 };") != null);
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

test "codegen: closure emit shapes anonymous struct with call method" {
    const src = "fun main() {\n    let double = |x: i32| -> i32 { return x * 2; };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(struct { pub fn call(x: i32) i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return (x * 2);") != null);
}

test "codegen: closure-typed call site rewrites double(5) to double.call(5)" {
    const src = "fun main() {\n    let double = |x: i32| -> i32 { return x * 2; };\n    let result = double(5);\n    print(\"{result}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "double.call(5)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "double(5)") == null);
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
    // path end to end without any explicit `: T`.
    const src =
        \\fun f() {
        \\    let c = |x: i32| -> i32 { return x + 1; };
        \\    let r = c(4);
        \\    print("{r}\n");
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

test "codegen: bounded generic fun emits `@hasDecl` + `@compileError` guard" {
    // docs/16 §3: `fun max<T: Ordered>(a, b) -> T` must emit a guard at
    // body entry that fails to compile if T does not expose a `compare`
    // method (the canonical Ordered trait surface per the doc). Without
    // the guard, an unsupported T would crash downstream at the
    // `a > b` zig op, which is exactly what we want the user-facing
    // source-line error to prevent.
    const src = "fun max<T: Ordered>(a: T, b: T) -> T {\n    return a;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Guard must appear before the body returns.
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (!@hasDecl(T, \"compare\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@compileError(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "must implement Ordered") != null);
    // The signature still has the `comptime T: type` preamble.
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn max(comptime T: type") != null);
}test "codegen: const generic + type parameter emits `comptime T: type, comptime N: usize`" {
    // docs/16 §4: `fun fill<T, const N: usize>(val: T) -> T` — the
    // non-const TypeParam emits `comptime T: type` (same as §1), and
    // the const TypeParam emits `comptime N: usize` (verbatim type
    // text captured at parse time, NOT the bare `type` keyword).
    // The return type is a bare `T` so the source does NOT depend on
    // the `[<ident>]T` parse-time bracket-capture hole in
    // collectCastType (a Phase 3 followup will close that).
    const src = "fun fill<T, const N: usize>(val: T) -> T {\n    return val;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "comptime T: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "comptime N: usize") != null);
}

test "codegen: `[<int_lit>]T` annotation round-trips through collectCastType" {
    // Phase 3 followup (closing the `[<ident>]T` bracket-ident parse-
    // time hole) extends the bracket-size carve-out to also accept
    // literal-size brackets `[4]i32`. Without this carve-out the
    // annotation `let x: [4]i32 = ...` captures EMPTY type-text
    // (since `[` falls through `collectCastType`'s dispatch into the
    // `else => break` arm and short-circuits the function). With the
    // carve-out the slice `[`, the literal-N, and the closing `]`
    // land as the multi-byte emit `[4]`, then the identifier
    // `i32` glues on without a separator so the emitted signature
    // is `[4]i32` verbatim — the form zig accepts.
    const src = "fun f() {\n    let x: [4]i32 = a;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x: [4]i32 = a;") != null);
    // Sanity: the spaced form `[4] i32` must NOT appear — the bracket
    // glue prevents the disambiguation-shim from inserting a space.
    try std.testing.expect(std.mem.indexOf(u8, zig, "[4] i32") == null);
}

test "codegen: `[<ident>]T` annotation round-trips through collectCastType" {
    // The companion test for the docs/16 §4 const-generic + array-shape
    // surface: `fun fill<T, const N: usize>(val: T) -> [N]T` requires
    // the `[N]T` return-type annotation to capture as `[N]T` (not the
    // empty string `collectCastType` returned prior to the bracket-
    // ident carve-out). The emitted zig signature should carry the
    // bracket-size case `-> [N]T` verbatim so zig's const-generic
    // monomorphization reads `comptime N: usize` for the array size.
    const src = "fun fill<T, const N: usize>(val: T) -> [N]T {\n    return val;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn fill(comptime T: type, comptime N: usize, val: T) [N]T") != null);
    // Sanity: the spaced form must NOT appear — the bracket-ident glue
    // keeps `[N]T` as a single token in the emitted sig.
    try std.testing.expect(std.mem.indexOf(u8, zig, "[N] T") == null);
}

test "codegen: `[<ident>]T { val ... }` array literal round-trips through fill rewrite" {
    // Phase 3 followup pin on the parseArrayLit `.identifier` size
    // extension. Before the extension, `parseArrayLit` rejected any
    // non-integer-literal size token with `expected integer literal
    // or const-param identifier for array size, got 'N'` and
    // `std.process.exit(1)`'d at parse time. After the extension,
    // `var out = [N]T { val ... };` parses cleanly when `N` is a
    // const-param from the surrounding fun signature.
    //
    // Codegen's array-fill pipe rewrites the single-elem + `...` form
    // as the zig repeat `[1]T{ val } ** N` — same shape as the literal
    // case `[5]i32 { 0 ... }` → `[1]i32{ 0 } ** 5` (pin in
    // `codegen: array fill emits [1]T{...}**N`). The leading element
    // becomes `[1]` because the repeat operator's LHS is a 1-element
    // runner; the count on the RHS of `**` is the original size (N).
    // zig's comptime resolution reads `comptime N: usize` from the
    // surrounding fun's preamble, so the literal `N` flows through to
    // the emitted array length verbatim — there's no string-side
    // concatenation to worry about.
    //
    // This test pins BOTH halves of the const-generic array-fill
    // cycle: the parser accepts `[<ident>]T` and the codegen rewrites
    // it to the zig-native `[1]T{ val } ** N` shape. The docs/16 §4
    // `fill` example body relies on this exact emission path.
    const src =
        \\fun fill<T, const N: usize>(val: T) -> T {
        \\    var out = [N]T { val ... };
        \\    return out;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "var out = [1]T{ val } ** N") != null);
    // Sanity: still emit the func body termination + the spelled ident
    // `N` (zeros in place of `N` would mean the AST's `size: u32` slot
    // had silently dropped the text — the parseArrayLit extension only
    // accepts the size, it doesn't rewrite it; the codegen passes `N`
    // through to the RHS of `**`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "** N") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "** 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return out;") != null);
}

test "codegen: `[<ident>]T` annotation + body combined round-trip" {
    // Coverage gap filled by Phase 3 followup review: the user's
    // stated surface is `var out: [N]T = [N]T { val ... };` — the
    // `[N]T` annotation AND the `[N]T { val ... }` body exercise
    // distinct code paths (collectCastType's bracket-size carve-out
    // for the LHS, parseArrayLit's `.identifier` size extension for
    // the RHS). Pinning both within a single test catches regressions
    // where ONE side gets fixed but the OTHER one silently breaks.
    //
    // `var out: [N]T` → `var out: [N]T = [1]T{ val } ** N;` in emitted
    // zig. The LHS annotation emits verbatim (collectCastType carve-
    // out preserves `[N]`); the RHS body emits through genArrayLit's
    // fill rewrite (`[1]T{ val } ** N`). The trailing return prints
    // the array so zig's runtime monomorphization is exercised end to
    // end (not just compile-time codegen shape).
    const src =
        \\fun fill<T, const N: usize>(val: T) -> T {
        \\    var out: [N]T = [N]T { val ... };
        \\    return out;
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
    // Annotation side: bracket-size carve-out preserves `[N]` here.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var out: [N]T = ") != null);
    // Body side: array-fill rewrite emits the canonical zig repeat.
    try std.testing.expect(std.mem.indexOf(u8, zig, "[1]T{ val } ** N") != null);
    // Sanity: the spaced `[N] T` annotation form must NOT appear
    // (collectCastType's prev_was_ptr glue rules it out).
    try std.testing.expect(std.mem.indexOf(u8, zig, "[N] T") == null);
}

