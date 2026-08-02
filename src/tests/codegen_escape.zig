// Source-mirror test bucket for src/codegen/escape.zig — the
// June-style escape/lifetime analysis under zag's MANUAL memory
// model (zig-style, docs/19-memory.md).
//
// The pass is a DIAGNOSTIC: it classifies every `new` site as
// escaping / explicitly-freed / arena-backed / LEAK (never escapes
// the function, never freed, page allocator) and codegen emits
// compile-time warnings for the leak set. It never changes the
// emitted code — every `new` always emits the inline
// `blk: { const __p_N = try ...create(T); ... }` form, and `free`
// is always the user's explicit call.
//
// Tests below pin (a) the emitted shapes (no hoisted prologue, no
// inserted defers) and (b) the leak-verdict classification via
// direct calls to escape.analyze (the same entry the codegen uses).

const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const codegen_mod = @import("../codegen.zig");
const ast = @import("../ast.zig");
const escape_mod = @import("../codegen/escape.zig");

fn gen(src: []const u8) []const u8 {
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    return cg.generate(prog);
}

/// Parse `src` (a single top-level fn) and run the escape analysis
/// the same way genFun does. Returns the verdict table.
fn analyzeFirstFn(src: []const u8) escape_mod.Result {
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    return escape_mod.analyze(prog.functions[0].params, prog.functions[0].body, false);
}

fn leaksBit(er: escape_mod.Result, idx: u32) bool {
    if (idx >= 128) return false;
    return (er.leaks >> @intCast(idx)) & 1 != 0;
}

test "escape: every new emits the inline create form (manual model)" {
    // No hoisted prologue, no inserted defers — the manual model
    // never changes the emitted code; freeing is the user's job.
    const zig = gen("fun f() {\n    let p = new i32(42);\n    print(\"done\\n\");\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try std.heap.page_allocator.create(i32);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 42; break :blk __p_0;") != null);
    // Negative: no hoisted prologue, no compiler-inserted defers.
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer __zag_bench_free(@sizeOf(i32))") == null);
}

test "escape: never-freed Local site is flagged as a leak" {
    const er = analyzeFirstFn("fun f() {\n    let p = new i32(42);\n    print(\"done\\n\");\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(leaksBit(er, 0));
}

test "escape: explicit free clears the leak verdict" {
    const er = analyzeFirstFn("fun f() {\n    let p = new i32(42);\n    defer free(p);\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: returned new is not a leak (manual ownership transfers)" {
    const er = analyzeFirstFn("fun f() -> *i32 {\n    return new i32(5);\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: return through a var is not a leak" {
    const er = analyzeFirstFn("fun f() -> *i32 {\n    let p = new i32(1);\n    return p;\n}\n");
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: call-arg site is not a leak (callee owns it)" {
    const er = analyzeFirstFn("fun f() {\n    let p = new i32(1);\n    consume(p);\n}\n");
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: arena-sugar new is never flagged" {
    const er = analyzeFirstFn("fun f() {\n    let p = new(arena, i32(0));\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: closure-body new is not a leak (escapes via the call)" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let g = |x: i32| -> i32 {
        \\        let p = new i32(1);
        \\        return x;
        \\    };
        \\}
        \\
    );
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: fixpoint — loop-carried flow escapes (no leak)" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    var x: *i32 = null;
        \\    while (true) {
        \\        print(x);
        \\        x = new i32(1);
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: discarded expr-stmt new is a leak" {
    const er = analyzeFirstFn("fun f() {\n    new i32(9);\n}\n");
    try std.testing.expect(leaksBit(er, 0));
}

test "escape: mixed sites — freed site clean, unfreed local flagged" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let a = new i32(1);
        \\    let b = new i32(2);
        \\    free(a);
        \\}
        \\
    );
    try std.testing.expectEqual(@as(u32, 2), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
    try std.testing.expect(leaksBit(er, 1));
}

test "escape: nested new sites number in codegen order (parity)" {
    // Site numbering parity with the alloc_counter walk: `new
    // Box(new i32(1))` — site 0 is the Box, site 1 the inner i32.
    const er = analyzeFirstFn(
        \\struct Box { v: i32 }
        \\fun f() {
        \\    let b = new Box(new i32(1));
        \\}
        \\
    );
    try std.testing.expectEqual(@as(u32, 2), er.site_count);
    // Both are unfreed locals → both flagged.
    try std.testing.expect(leaksBit(er, 0));
    try std.testing.expect(leaksBit(er, 1));
}
