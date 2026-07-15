// Source-mirror test bucket for src/core.zig.zig.
// Tests here pin the core-codegen's surface. Routing is by test-name
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


test "codegen: hello world" {
    // zig 0.16 main-signature migration: the generated zig for a
    // source-side `fun main()` is `pub fn main(init: std.process.Init) !void`
    // (NOT the legacy `pub fn main() void`). The new signature is
    // required because `std.os.argv` / `std.posix.argv` were both
    // removed in zig 0.16 — the ONLY way to access argv at runtime
    // is via `init.minimal.args.toSlice(allocator)` at main entry.
    // The assertion matches the new signature's start (`pub fn main(`)
    // without being too tight on the parameter shape — any future
    // zig signature tweak wouldn't break this pin-test.
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    // Structural pins (existing): main emitted with zig 0.16's
    // `init: std.process.Init` signature, and the print call routed
    // through zig's `__zag_print`.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn main(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "std.process.Init") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "__zag_print(\"hello, world\\n\", .{})") != null);
    // Content pin (tightening): the LITERAL `"hello, world\n"` substring
    // (with `\`+`n` as two chars, NOT a LF byte) reaches codegen verbatim.
    // Catches a future regression that mangles string-literal contents
    // even though the print call SETUP would still satisfy the
    // structural pins above. Mirrors the established
    // `template preserves LF byte in literal via \n escape` test
    // (same substring-escape discipline) one section below.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "\"hello, world\\n\"") != null);
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

test "codegen: preamble emits exactly once and last preamble precedes last fun decl" {
    // Strengthens the basic positional pin test (which used
    // `indexOf` only and would not catch the misordered-duplicate
    // case `indexOf(preamble) < indexOf(fun)` still passes for).
    // This test asserts BOTH:
    //   (1) preamble emits EXACTLY ONCE (count pin)
    //   (2) the LAST preamble offset is at-or-before the LAST fun
    //       offset (lastIndexOf pair compare) -- catches any
    //       duplicate-preamble that misordered into or after a fun
    //       decl, even when the FIRST preamble is correctly placed
    //       before the FIRST fun.
    //
    // Counter-example the strengthened pin catches but the basic
    // one does not: emit order [preamble1, fun1, preamble2]
    //   - indexOf(preamble) = preamble1 offset < indexOf(fun) = fun1
    //     offset  -> BASIC pin passes  (BUG: duplicate preamble
    //     misordered past fun1)
    //   - count("const __zag_imported_") == 2  -> COUNT pin fails
    //   - lastIndexOf(preamble) = preamble2 offset >
    //     lastIndexOf(fun) = fun1 offset  -> LAST pin fails
    //
    // Combined, count + lastIndexOf pin guarantee that any emission
    // of `const __zag_imported_<i>` lines happens exactly at the
    // top, in a contiguous block, before any user fun decl appears.
    const src = "pub import std.string;\npub fun hello() -> void {\n    let unused: i32 = 1;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);

    const preamble_prefix = "const __zag_imported_0 = @import(\"";
    const fun_prefix = "pub fn hello(";

    // (1) Count pin -- a regression that emits the preamble twice
    // (or zero times) surfaces here regardless of ordering.
    const preamble_count = std.mem.count(u8, zig, "const __zag_imported_");
    try std.testing.expectEqual(@as(usize, 1), preamble_count);

    // (2) LastIndexOf pin -- the LAST preamble's offset must be
    // at-or-before the LAST fun decl's offset. This is the
    // semantically correct direction for a header-preamble +
    // ordered-fun-decl codegen: every preamble appears in the
    // contiguous header block before any fun body. (Operands
    // chosen as `<=` rather than `<` to also tolerate the (non-
    // constructively reachable but conceivable) case where the
    // last preamble offset and last fun offset are equal -- in
    // which case the count pin still enforces EXACTLY ONE
    // preamble emission.)
    const preamble_last = std.mem.lastIndexOf(u8, zig, preamble_prefix);
    try std.testing.expect(preamble_last != null);
    const fun_last = std.mem.lastIndexOf(u8, zig, fun_prefix);
    try std.testing.expect(fun_last != null);
    try std.testing.expect(preamble_last.? <= fun_last.?);
}
