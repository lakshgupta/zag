// Source-mirror test bucket for src/primary.zig.zig.
// Tests here pin the primary-codegen's surface. Routing is by test-name
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
    // Empty tuple `()` emits `.{ }` (the canonical zig 0.16 empty
    // tuple; bare `{}` is typed as `void` and rejected by
    // `@call(.auto, f, args)` at std.Thread spawn sites).
    try std.testing.expect(std.mem.indexOf(u8, zig, "= .{ };") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "(__blk_0: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __arr: [4]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __pat: [2]i32 = .{ 1, 2 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__pat[__i % 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :__blk_0 __arr") != null);
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

test "codegen: stack-allocated array with type annotation emits zig [N]T" {
    // let buf: [8]u8 = [8]u8{ ... } — stack-allocated fixed array.
    const src =
        \\fun f() {
        \\    let buf: [8]u8 = [8]u8 { 0, 1, 2, 3, 4, 5, 6, 7 };
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Stack allocation — no heap, no alloc()
    try std.testing.expect(std.mem.indexOf(u8, zig, "[8]u8 = [8]u8{ 0, 1, 2, 3, 4, 5, 6, 7 }") != null);
    // No page_allocator references — this is pure stack.
    // The preamble __zag_String uses page_allocator; check only user code.
    {
        const code_start = std.mem.indexOf(u8, zig, "pub fn main") orelse zig.len;
        try std.testing.expect(std.mem.indexOf(u8, zig[code_start..], "page_allocator") == null);
    }
}

test "codegen: stack-allocated fill array emits [1]T{val}**N on stack" {
    // let buf: [4096]u8 = [4096]u8 { 0 ... } — zero-filled stack buffer.
    const src =
        \\fun f() {
        \\    let buf: [4096]u8 = [4096]u8 { 0 ... };
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Fill array on stack — [1]u8{ 0 } ** 4096
    try std.testing.expect(std.mem.indexOf(u8, zig, "[1]u8{ 0 } ** 4096") != null);
    // No heap alloc in user code (preamble uses page_allocator for __zag_String)
    {
        const code_start = std.mem.indexOf(u8, zig, "pub fn main") orelse zig.len;
        try std.testing.expect(std.mem.indexOf(u8, zig[code_start..], "page_allocator") == null);
    }
}

test "codegen: SIMD vector type + positional literal map to @Vector" {
    // docs/manual/24-simd.md §"SIMD Vector Types" + §"SIMD
    // Literals": `f32x4 { 1.0, 2.0, ... }` (lowercase type name,
    // positional fields) maps onto zig 0.16's @Vector(4, f32)
    // literal form.
    const src = "fun f() {\n    let a: f32x4 = f32x4 { 1.0, 2.0, 3.0, 4.0 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const a: @Vector(4, f32) = @Vector(4, f32){ 1.0, 2.0, 3.0, 4.0 };") != null);
}

test "codegen: SIMD reductions rewrite to @reduce" {
    // docs/manual/24-simd.md §"SIMD Methods (v1)": .sum()/.max()/
    // .min()/.dot(x) on vector-typed receivers lower to @reduce
    // (@Vector has no methods in zig).
    const src =
        \\fun f() {
        \\    let c: f32x4 = f32x4 { 1.0, 2.0, 3.0, 4.0 };
        \\    let s: f32 = c.sum();
        \\    let m: f32 = c.max();
        \\    let n: f32 = c.min();
        \\    let d: f32 = c.dot(c);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "= @reduce(.Add, c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= @reduce(.Max, c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= @reduce(.Min, c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= @reduce(.Add, c * c);") != null);
}

test "codegen: dotted type annotations collect through collectCastType" {
    // Module-qualified types (`std.Thread` for the concurrent
    // thread-spawn handle) must round-trip through binding
    // annotations — the pre-fix collector truncated at the first
    // `.` ("expected equals, got '.'").
    const src = "fun f() {\n    let h: std.Thread = spawn(worker, ());\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const h: std.Thread = ") != null);
}

test "codegen: inline asm translates to zig asm with named operands" {
    // docs/manual/24-simd.md §"Inline Assembly": the zag spec
    // `("tpl" : {dst} = "=x"(out) : {src} = "x"(a) : )` translates
    // to zig's asm expression — `{name}` → `%[name]`, bindings →
    // `[name] "constraint" (expr)`, empty clobbers → `.{}`.
    const src =
        \\fun f() {
        \\    var out: f32 = 0.0;
        \\    let a: f32 = 1.0;
        \\    asm {
        \\        ("vfmadd231ps {dst}, {src}, {acc}"
        \\         : {dst} = "=x"(out)
        \\         : {src} = "x"(a), {acc} = "x"(a)
        \\         :
        \\        )
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "_ = (asm (\"vfmadd231ps %[dst], %[src], %[acc]\" : [dst] \"=x\" (out) : [src] \"x\" (a), [acc] \"x\" (a) : .{}))") != null);
}

test "codegen: inline asm clobbers map to the Clobbers struct" {
    const src =
        \\fun f() {
        \\    var out: i32 = 0;
        \\    asm {
        \\        ("mov {dst}, 42" : {dst} = "=r"(out) : : "memory")
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
    try std.testing.expect(std.mem.indexOf(u8, zig, ": .{ .memory = true }))") != null);
}

test "codegen: bare { ... } array literal emits .{ ... } for expected-type coercion" {
    // docs/manual/10 §"Inferred-element arrays": the element type
    // comes from the LHS annotation, so it is not repeated —
    // `let numbers: [5]i32 = { 10, 20, 30, 40, 50 };` emits
    // `.{ 10, 20, 30, 40, 50 }` (zig's anonymous-struct literal,
    // coerced to the expected array/slice/tuple type).
    const src = "fun f() {\n    let numbers: [5]i32 = { 10, 20, 30, 40, 50 };\n    let s: i32 = take({ 1, 2, 3 });\n    let typed: [3]i32 = [3]i32 { 4, 5, 6 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const numbers: [5]i32 = .{ 10, 20, 30, 40, 50 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "take(.{ 1, 2, 3 })") != null);
    // The typed form still works unchanged.
    try std.testing.expect(std.mem.indexOf(u8, zig, "[3]i32{ 4, 5, 6 }") != null);
}

test "codegen: { ... } with statement keywords stays a block expression" {
    // The bare-array pre-scan must not hijack blocks: statement-
    // leading keywords (let, if, ...) keep the labeled-block emit.
    const src = "fun f() {\n    let b: i32 = { let x: i32 = 7; x };\n    let c: i32 = { if true { 1 } else { 2 } };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__blk_0: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 7 }") == null);
}
