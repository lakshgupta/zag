// Source-mirror test bucket for src/codegen/escape.zig — the
// June-style escape/lifetime analysis (docs/19 auto-free).
//
// These tests pin the codegen contract of the pass:
//   - LOCAL sites (never escape, not explicitly freed, page
//     allocator) get a hoisted `const __p_N = try
//     std.heap.page_allocator.create(T);` + `defer
//     std.heap.page_allocator.destroy(__p_N);` prologue, and the
//     site itself emits ONLY the value-store
//     (`blk: { __p_N.* = <v>; break :blk __p_N; }`).
//   - ESCAPING sites (returned, passed to a call, stored through
//     a pointer, assigned to a global/param, allocated inside a
//     closure/comptime block, tail-returned via match) keep the
//     legacy inline `blk: { const __p_N = try ...create(T); ... }`
//     form byte-identical — the caller owns the lifecycle.
//   - EXPLICITLY FREED and ARENA-backed sites keep the inline form.
//
// Site numbering parity (analysis vs codegen alloc_counter) is
// exercised by the multi-site tests below.

const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const codegen_mod = @import("../codegen.zig");
const ast = @import("../ast.zig");

fn gen(src: []const u8) []const u8 {
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    return cg.generate(prog);
}

test "escape: local new gets hoisted alloc + deferred destroy prologue" {
    const zig = gen("fun f() {\n    let p = new i32(42);\n    print(\"done\\n\");\n}\n");
    // Hoisted prologue: allocation at function entry ...
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __p_0 = try std.heap.page_allocator.create(i32);") != null);
    // ... and the matching function-scope deferred destroy.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    defer std.heap.page_allocator.destroy(__p_0);") != null);
    // The site itself emits ONLY the value-store (no re-alloc).
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { __p_0.* = 42; break :blk __p_0; }") != null);
    // Negative: the legacy inline-alloc shape must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") == null);
}

test "escape: returned new keeps inline alloc (no hoist, no auto-free)" {
    const zig = gen("fun f() -> *i32 {\n    return new i32(5);\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try std.heap.page_allocator.create(i32);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: return through a var (use-def flow) keeps inline alloc" {
    const zig = gen("fun f() -> *i32 {\n    let p = new i32(1);\n    return p;\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: explicit free(p) suppresses auto-free (inline form preserved)" {
    const zig = gen("fun f() {\n    let p = new i32(42);\n    defer free(p);\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy(p)") != null);
}

test "escape: mixed sites — escaping site inline, local site hoisted" {
    // `a` is returned (escapes → inline), `b` stays local (hoisted).
    const zig = gen(
        \\fun f() -> *i32 {
        \\    let a = new i32(1);
        \\    let b = new i32(2);
        \\    return a;
        \\}
        \\
    );
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __p_1 = try std.heap.page_allocator.create(i32);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: call-arg site escapes (unknown callee may retain it)" {
    const zig = gen("fun f() {\n    let p = new i32(1);\n    consume(p);\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: arena-sugar new never auto-freed" {
    const zig = gen("fun f() {\n    let p = new(arena, i32(0));\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "try arena.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.create") == null);
}

test "escape: field store through pointer escapes" {
    const zig = gen(
        \\struct Box { v: *i32 }
        \\fun f(b: *Box) {
        \\    b.v = new i32(7);
        \\}
        \\
    );
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: fixpoint — loop-carried flow escapes (use before textual assign)" {
    // print(x) precedes x = new textually; only the fixed-point
    // re-walk propagates the site into x before the call-arg sink.
    const zig = gen(
        \\fun f() {
        \\    var x: *i32 = null;
        \\    while (true) {
        \\        print(x);
        \\        x = new i32(1);
        \\    }
        \\}
        \\
    );
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: closure-body new escapes (call may return it)" {
    const zig = gen(
        \\fun f() {
        \\    let g = |x: i32| -> i32 {
        \\        let p = new i32(1);
        \\        return x;
        \\    };
        \\}
        \\
    );
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: tail-position match in value-returning method escapes arm flows" {
    // The method's last statement is a match and the method returns
    // a value: genStmt emits `return (blk: {...});` so the arm's `p`
    // leaves the function → no auto-free.
    const zig = gen(
        \\struct Box { v: i32 }
        \\impl Box {
        \\    fun get(self: *Box) -> *i32 {
        \\        let p = new i32(1);
        \\        match 1 { _ => p }
        \\    }
        \\}
        \\
    );
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { const __p_0 = try") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0)") == null);
}

test "escape: multiple local sites hoist in site order with distinct temps" {
    const zig = gen(
        \\fun f() {
        \\    let a = new i32(1);
        \\    let b = new i32(2);
        \\}
        \\
    );
    // Prologue order: __p_0 then __p_1, each with its own defer.
    const p0 = std.mem.indexOf(u8, zig, "const __p_0 = try std.heap.page_allocator.create(i32);") orelse return error.TestUnexpectedResult;
    const p1 = std.mem.indexOf(u8, zig, "const __p_1 = try std.heap.page_allocator.create(i32);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(p0 < p1);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_1);") != null);
    // Stores stay at the original sites.
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { __p_0.* = 1; break :blk __p_0; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { __p_1.* = 2; break :blk __p_1; }") != null);
}

test "escape: nested new sites number in codegen order (parity)" {
    // `new Box(new i32(1))`: site 0 is the Box, site 1 is the inner
    // i32 (codegen visits the outer new first, then its value).
    // Both are local → both hoisted, and the outer store references
    // the inner temp — proving the analysis and the alloc_counter
    // walk agree on site numbering.
    const zig = gen(
        \\struct Box { v: i32 }
        \\fun f() {
        \\    let b = new Box(new i32(1));
        \\}
        \\
    );
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __p_0 = try std.heap.page_allocator.create(Box);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __p_1 = try std.heap.page_allocator.create(i32);") != null);
    // Inner store emitted at its own site; outer store wraps it.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_1.* = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = blk: { __p_1.* = 1; break :blk __p_1; }") != null);
}

test "escape: discarded expr-stmt new is local (auto-free fixes the leak)" {
    const zig = gen("fun f() {\n    new i32(9);\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __p_0 = try std.heap.page_allocator.create(i32);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "defer std.heap.page_allocator.destroy(__p_0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: { __p_0.* = 9; break :blk __p_0; }") != null);
}
