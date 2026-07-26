// Source-mirror test bucket for src/primary.zig.zig.
// Tests here pin the primary-parser's surface. Routing is by test-name
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


test "parser: bool literal" {
    const src = "fun main() {\n    let on: bool = true;\n    let off: bool = false;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    const body = prog.functions[0].body;
    try std.testing.expect(body.len > 0 and body[0].payload == .let);
    try std.testing.expect(body[1].payload == .let);
}

test "parser: string with braces becomes template_lit" {
    const src = "fun f() {\n    let msg = \"hello, {name}\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .template_lit);
    // 3 parts: "hello, " literal, name ident, "" trailing literal
    try std.testing.expectEqual(@as(usize, 3), init.payload.template_lit.parts.len);
    try std.testing.expectEqualStrings("hello, ", init.payload.template_lit.parts[0].literal.?);
    try std.testing.expectEqualStrings("name", init.payload.template_lit.parts[1].expr.?.payload.ident);
}

test "parser: plain string stays string_lit" {
    const src = "fun f() {\n    let s = \"plain\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .string_lit);
}

test "parser: identifier operands" {
    const src = "fun f() {\n    let z: i32 = x * y;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.payload.binary.op);
    try std.testing.expectEqualStrings("x", init.payload.binary.lhs.*.payload.ident);
    try std.testing.expectEqualStrings("y", init.payload.binary.rhs.*.payload.ident);
}

test "parser: identifier expr without `=` stays `.expr_stmt`" {
    // Single ident with no follow-up `=` is treated as a free expression
    // statement, NOT an assignment; the lookahead at statement-scope is the
    // boundary between the two branches.
    const src = "fun f() {\n    y;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.payload == .expr_stmt);
    try std.testing.expect(stmt.payload.expr_stmt.payload == .ident);
    try std.testing.expectEqualStrings("y", stmt.payload.expr_stmt.payload.ident);
}

test "parser: format spec preserved on interpolation" {
    // `{PI:.5}` should split into expr="PI" and spec=".5" at the first `:`.
    // The expr stays a single `.ident` so zig can re-tokenise it; the spec
    // is preserved separately so codegen can append it to the placeholder.
    const src = "fun f() {\n    print(\"{PI:.5}\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[0];
    const arg = print_stmt.payload.expr_stmt.payload.call.args[0];
    try std.testing.expect(arg.payload == .template_lit);
    // source "{PI:.5}" has no leading text, so buildTemplate emits:
    //   parts[0] = { expr = ident "PI",  spec = ".5" }   (interpolation)
    //   parts[1] = { literal = "" }                       (trailing literal)
    try std.testing.expectEqual(@as(usize, 2), arg.payload.template_lit.parts.len);
    try std.testing.expect(arg.payload.template_lit.parts[0].literal == null);
    try std.testing.expect(arg.payload.template_lit.parts[0].expr != null);
    try std.testing.expectEqualStrings("PI", arg.payload.template_lit.parts[0].expr.?.payload.ident);
    try std.testing.expect(arg.payload.template_lit.parts[0].spec != null);
    try std.testing.expectEqualStrings(".5", arg.payload.template_lit.parts[0].spec.?);
    try std.testing.expect(arg.payload.template_lit.parts[1].literal != null);
    try std.testing.expectEqualStrings("", arg.payload.template_lit.parts[1].literal.?);
}

test "parser: plain interpolation has null spec" {
    // Backward-compat: `{name}` (no `:`) leaves `spec` null so codegen
    // produces the plain `{any}` placeholder unchanged.
    const src = "fun f() {\n    let name = \"zag\";\n    print(\"hello, {name}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[1];
    const arg = print_stmt.payload.expr_stmt.payload.call.args[0];
    try std.testing.expect(arg.payload == .template_lit);
    // The single interpolation part has `spec == null`.
    for (arg.payload.template_lit.parts) |part| {
        if (part.expr) |expr| {
            try std.testing.expectEqualStrings("name", expr.payload.ident);
            try std.testing.expect(part.spec == null);
        }
    }
}

test "parser: float precision {pi:.5} gate accepts dot inside braces" {
    // New matching-brace gate unblocks float-precision format specs.
    // The pre-fix char-class gate bailed on `.` (non-alphanumeric,
    // not `_` or `:`), so `{pi:.5}` was incorrectly rejected as a
    // template and emitted as a plain string_lit. The matching-brace
    // gate accepts any content (dots, spaces, operators) so the
    // interpolation now promotes to .template_lit with expr="pi"
    // and spec=".5". Codegen's genTemplateLit emits `{any:.5}` with
    // arg `pi`, and zig's debug formatter honours the precision.
    //
    // Source uses NO leading text (just `"{pi:.5}\n"`) so buildTemplate
    // produces exactly 2 parts: [expr+spec, trailing literal "\n"].
    // The pre-fix test source had `"pi = {pi:.5}\n"` which produces
    // 3 parts (leading "pi = ", expr+spec, trailing "\n") and the
    // `parts.len == 2` assertion failed. Fixed by removing the
    // incidental leading text so the assertion surface matches the
    // gate-pinning intent.
    const src = "fun f() {\n    let pi: f64 = 3.14159;\n    print(\"{pi:.5}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[1];
    const arg = print_stmt.payload.expr_stmt.payload.call.args[0];
    try std.testing.expect(arg.payload == .template_lit);
    try std.testing.expectEqual(@as(usize, 2), arg.payload.template_lit.parts.len);
    try std.testing.expect(arg.payload.template_lit.parts[0].literal == null);
    try std.testing.expect(arg.payload.template_lit.parts[0].expr != null);
    try std.testing.expectEqualStrings("pi", arg.payload.template_lit.parts[0].expr.?.payload.ident);
    try std.testing.expect(arg.payload.template_lit.parts[0].spec != null);
    try std.testing.expectEqualStrings(".5", arg.payload.template_lit.parts[0].spec.?);
}

test "parser: binary `&` still bitwise AND (not addr)" {
    // Defensive pin on the unary/binary dispatch: when `.amp` is
    // between two expressions the result is the `.bitand` binary form,
    // NOT a unary prefix on the first operand. The lexer emits a
    // single `.amp` token; parser context alone makes the distinction.
    const src = "fun f() {\n    let r: i32 = a & b;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].payload.let.init.?;
    try std.testing.expect(init.payload == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.bitand, init.payload.binary.op);
}
