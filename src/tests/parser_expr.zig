// Source-mirror test bucket for src/expr.zig.zig.
// Tests here pin the expr-parser's surface. Routing is by test-name
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


test "parser: simple binary add" {
    const src = "fun f() {\n    let z: i32 = 1 + 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.payload.binary.op);
    try std.testing.expect(init.payload.binary.lhs.*.payload == .int_lit);
    try std.testing.expect(init.payload.binary.rhs.*.payload == .int_lit);
}

test "parser: precedence — mul binds tighter than add" {
    // 1 + 2 * 3 → 1 + (2 * 3) → binary(add, 1, binary(mul, 2, 3))
    const src = "fun f() {\n    let z: i32 = 1 + 2 * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.payload.binary.op);
    try std.testing.expect(init.payload.binary.lhs.*.payload == .int_lit);
    try std.testing.expect(init.payload.binary.rhs.*.payload == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.payload.binary.rhs.*.payload.binary.op);
}

test "parser: precedence — parens override" {
    // (1 + 2) * 3 → binary(mul, binary(add, 1, 2), 3)
    const src = "fun f() {\n    let z: i32 = (1 + 2) * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.payload.binary.op);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.payload.binary.lhs.*.payload.binary.op);
}

test "parser: left-associative chain" {
    // 1 - 2 - 3 → (1 - 2) - 3 → binary(sub, binary(sub, 1, 2), 3)
    const src = "fun f() {\n    let z: i32 = 1 - 2 - 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expectEqual(ast.Expr.BinaryOp.sub, init.payload.binary.op);
    try std.testing.expectEqual(ast.Expr.BinaryOp.sub, init.payload.binary.lhs.*.payload.binary.op);
    try std.testing.expect(init.payload.binary.lhs.*.payload.binary.lhs.*.payload == .int_lit);
}

test "parser: postfix dot chain produces member_access" {
    // `v.x` after a let-binding parses as `.member_access(target=ident(v),
    // name="x")`. Codegen's `.member_access` arm emits `v.x` verbatim.
    const src = "fun f() {\n    let v: f64 = 0.0;\n    let a: f64 = v.x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const a_init = prog.functions[0].body[1].payload.let.init.?;
    try std.testing.expect(a_init.payload == .member_access);
    try std.testing.expectEqualStrings("x", a_init.payload.member_access.name);
    try std.testing.expect(a_init.payload.member_access.target.*.payload == .ident);
    try std.testing.expectEqualStrings("v", a_init.payload.member_access.target.*.payload.ident);
}

test "parser: postfix dot chain produces method_call" {
    // `v.length()` (with parens) parses as `.method_call(target=ident(v),
    // name="length", args=[])`. The two shapes the postfix loop sees on
    // `.identifier` are distinguished entirely by what follows — `(`
    // binds to method-call, anything else binds to member-access.
    const src = "fun f() {\n    let len: f64 = v.length();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .method_call);
    try std.testing.expectEqualStrings("length", init.payload.method_call.name);
    try std.testing.expectEqual(@as(usize, 0), init.payload.method_call.args.len);
    try std.testing.expect(init.payload.method_call.target.*.payload == .ident);
    try std.testing.expectEqualStrings("v", init.payload.method_call.target.*.payload.ident);
}

test "parser: method_call with positional args parses correctly" {
    // `Vec3.new(1.0, 2.0, 3.0)` parses as `.method_call(target=ident
    // ("Vec3"), name="new", args=[3 floats])`. zig statically resolves
    // `Vec3.new` to a struct-member call (codegen nests impl methods
    // inside the struct decl).
    const src = "fun f() {\n    let p: Vec3 = Vec3.new(1.0, 2.0, 3.0);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .method_call);
    try std.testing.expectEqualStrings("Vec3", init.payload.method_call.target.*.payload.ident);
    try std.testing.expectEqualStrings("new", init.payload.method_call.name);
    try std.testing.expectEqual(@as(usize, 3), init.payload.method_call.args.len);
    try std.testing.expect(init.payload.method_call.args[0].payload == .float_lit);
}

test "parser: closure expression |x:T|->T{} produces Expr.closure" {
    const src = "fun main() {\n    let double = |x: i32| -> i32 { return x * 2; };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions.len == 1);
    try std.testing.expect(prog.functions[0].body.len == 1);
    const let_stmt = prog.functions[0].body[0].payload.let;
    try std.testing.expect(let_stmt.init.?.payload == .closure);
    try std.testing.expect(let_stmt.init.?.payload.closure.params.len == 1);
    try std.testing.expect(std.mem.eql(u8, let_stmt.init.?.payload.closure.params[0].name, "x"));
    try std.testing.expect(std.mem.eql(u8, let_stmt.init.?.payload.closure.return_type.?, "i32"));
}
