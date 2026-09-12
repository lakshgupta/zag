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
    try std.testing.expect(std.mem.indexOf(u8, zig, "__blk_0: { const __p_0 = try std.heap.page_allocator.create(i32);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 42; break :__blk_0 __p_0;") != null);
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
    // The sink is a USER call, not `print`: `print`/`assert` are
    // non-retaining builtins (see below) and no longer make their
    // argument escape, so using one here would assert nothing about
    // the fixpoint.
    const er = analyzeFirstFn(
        \\fun f() {
        \\    var x: *i32 = null;
        \\    while (true) {
        \\        consume(x);
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

// ============================================================
// alloc / alloc_raw coverage (the slice-allocation widening)
// ============================================================
//
// Pre-widening, ONLY `.new_expr` produced a site, so every slice
// allocation was invisible to the compile-time warning: `let buf =
// alloc(n);` with no `free buf` produced nothing, and only the
// runtime ledger (std.bench.Counters) could see the leak.

test "escape: alloc without free is a leak" {
    const er = analyzeFirstFn("fun f() {\n    let buf: []u8 = alloc(64);\n    buf[0] = 1;\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(leaksBit(er, 0));
    // The site is labelled with its callee so the warning can name it.
    try std.testing.expectEqual(escape_mod.SiteKind.alloc_fn, er.sites[0].kind);
    try std.testing.expectEqualStrings("alloc", er.sites[0].fn_name);
}

test "escape: alloc_raw without release is a leak" {
    const er = analyzeFirstFn("fun f() {\n    let p: [*]u8 = alloc_raw(64);\n    p[0] = 1;\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(leaksBit(er, 0));
    try std.testing.expectEqual(escape_mod.SiteKind.alloc_fn, er.sites[0].kind);
    try std.testing.expectEqualStrings("alloc_raw", er.sites[0].fn_name);
}

test "escape: free clears the alloc leak verdict" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let buf: []u8 = alloc(64);
        \\    free(buf);
        \\}
        \\
    );
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: release clears the alloc_raw leak verdict" {
    // The raw tier's documented pairing. Without the `release`
    // special case the pointer would escape as an ordinary call
    // argument and the site would be silently exempt — which would
    // make the alloc_raw warning fire on correctly-written code.
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let p: [*]u8 = alloc_raw(64);
        \\    release(p, 64);
        \\}
        \\
    );
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: defer free clears the alloc leak verdict" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let p: [*]u8 = alloc_raw(64);
        \\    defer release(p, 64);
        \\}
        \\
    );
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: returned alloc is not a leak (ownership transfers)" {
    const er = analyzeFirstFn("fun f() -> []u8 {\n    return alloc(16);\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: alloc passed to a user call is not a leak" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let buf: []u8 = alloc(16);
        \\    consume(buf);
        \\}
        \\
    );
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: alloc stored into a field is not a leak" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let buf: []u8 = alloc(16);
        \\    g.buf = buf;
        \\}
        \\
    );
    try std.testing.expect(!leaksBit(er, 0));
}

test "escape: non-retaining builtins do not wash out an alloc leak" {
    // The whole point of the widening: the common shape is
    // allocate → report something about the buffer → never free.
    // `print`/`assert` retain nothing, so the site stays a leak.
    const printed = analyzeFirstFn("fun f() {\n    let buf: []u8 = alloc(64);\n    print(\"len {buf.len}\\n\");\n}\n");
    try std.testing.expectEqual(@as(u32, 1), printed.site_count);
    try std.testing.expect(leaksBit(printed, 0));

    const asserted = analyzeFirstFn("fun f() {\n    let buf: []u8 = alloc(64);\n    assert(buf.len == 64);\n}\n");
    try std.testing.expectEqual(@as(u32, 1), asserted.site_count);
    try std.testing.expect(leaksBit(asserted, 0));
}

test "escape: print does not hide a never-freed new either" {
    // Same rule, applied to the `new` family — the non-retaining
    // list is about the CALLEE, not the allocation kind.
    const er = analyzeFirstFn("fun f() {\n    let p = new i32(1);\n    print(\"p {p}\\n\");\n}\n");
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(leaksBit(er, 0));
    try std.testing.expectEqual(escape_mod.SiteKind.new_expr, er.sites[0].kind);
}

test "escape: a freed alloc alongside an unfreed new" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    let buf: []u8 = alloc(16);
        \\    buf[0] = 1;
        \\    free(buf);
        \\    let p = new i32(2);
        \\}
        \\
    );
    try std.testing.expectEqual(@as(u32, 2), er.site_count);
    // Site 0 is the alloc (freed), site 1 the `new` (never freed).
    try std.testing.expect(!leaksBit(er, 0));
    try std.testing.expect(leaksBit(er, 1));
}

test "escape: alloc site in a loop without a free is a leak" {
    const er = analyzeFirstFn(
        \\fun f() {
        \\    while (true) {
        \\        let buf: []u8 = alloc(32);
        \\        buf[0] = 1;
        \\    }
        \\}
        \\
    );
    try std.testing.expectEqual(@as(u32, 1), er.site_count);
    try std.testing.expect(leaksBit(er, 0));
}
