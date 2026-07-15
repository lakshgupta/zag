// Source-mirror test bucket for src/core.zig.zig.
// Tests here pin the core-parser's surface. Routing is by test-name
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


test "parser: hello world" {
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    try std.testing.expectEqualStrings("main", prog.functions[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.functions[0].body.len);
}

test "parser: doc attached to fun decl" {
    const src = "## adds a and b\nfun add() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    try std.testing.expect(prog.functions[0].doc != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.functions[0].doc.?, "adds a and b") != null);
}

test "parser: no doc when not present" {
    const src = "fun add() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    try std.testing.expect(prog.functions[0].doc == null);
}
