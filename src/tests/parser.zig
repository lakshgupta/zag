// Auto-extracted from src/main.zig. Tests live here so main.zig
// stays focused on CLI plumbing. Zigs `test "..." {}` discovery
// follows the comptime imports at the bottom of main.zig.

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

test "parser: bool literal" {
    const src = "fun main() {\n    let on: bool = true;\n    let off: bool = false;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    const body = prog.functions[0].body;
    try std.testing.expect(body.len > 0 and body[0] == .let);
    try std.testing.expect(body[1] == .let);
}

test "parser: tuple literal" {
    const src = "fun main() {\n    let p = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    try std.testing.expect(body.len > 0 and body[0] == .let);
    const init = body[0].let.init.?;
    try std.testing.expect(init == .tuple_lit);
    try std.testing.expectEqual(@as(usize, 2), init.tuple_lit.len);
}

test "parser: empty tuple" {
    const src = "fun main() {\n    let u = ();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    const init = body[0].let.init.?;
    try std.testing.expect(init == .tuple_lit);
    try std.testing.expectEqual(@as(usize, 0), init.tuple_lit.len);
}

test "parser: single paren still groups" {
    const src = "fun main() {\n    let x = (42);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    const init = body[0].let.init.?;
    // (42) groups to int_lit, not a tuple
    try std.testing.expect(init == .int_lit);
}

test "parser: array lit explicit" {
    const src = "fun f() {\n    let a = [3]i32 { 1, 2, 3 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 3), init.array_lit.size);
    try std.testing.expectEqualStrings("i32", init.array_lit.type_name);
    try std.testing.expectEqual(@as(usize, 3), init.array_lit.elements.len);
    try std.testing.expect(!init.array_lit.fill);
    try std.testing.expect(!init.array_lit.progression);
}

test "parser: array lit fill" {
    const src = "fun f() {\n    let a = [5]i32 { 0 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 5), init.array_lit.size);
    try std.testing.expect(init.array_lit.fill);
    try std.testing.expect(!init.array_lit.progression);
    try std.testing.expectEqual(@as(usize, 1), init.array_lit.elements.len);
}

test "parser: array lit progression" {
    const src = "fun f() {\n    let a = [4]i32 { 1, 2 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 4), init.array_lit.size);
    try std.testing.expect(init.array_lit.progression);
    try std.testing.expectEqual(@as(usize, 2), init.array_lit.elements.len);
}

test "parser: string with braces becomes template_lit" {
    const src = "fun f() {\n    let msg = \"hello, {name}\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .template_lit);
    // 3 parts: "hello, " literal, name ident, "" trailing literal
    try std.testing.expectEqual(@as(usize, 3), init.template_lit.parts.len);
    try std.testing.expectEqualStrings("hello, ", init.template_lit.parts[0].literal.?);
    try std.testing.expectEqualStrings("name", init.template_lit.parts[1].expr.?.ident);
}

test "parser: plain string stays string_lit" {
    const src = "fun f() {\n    let s = \"plain\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .string_lit);
}

test "parser: let with type annotation" {
    // Pre-carve-out tests inadvertently regressed to bare `let x = 42` when
    // the static-typed-coercion migration commit landed (the carve-out makes
    // bare-form bindings legal, but the test was written when bare-form
    // auto-typed to `: i32`). An explicit `: T` source matches the assertion
    // (and is the same form the docs recommend now).
    const src = "fun f() {\n    let x: i32 = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expectEqualStrings("x", stmt.let.name);
    try std.testing.expectEqualStrings("i32", stmt.let.type_name.?);
    try std.testing.expect(stmt.let.init.? == .int_lit);
}

test "parser: let without type annotation" {
    const src = "fun f() {\n    let x = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expectEqualStrings("x", stmt.let.name);
    try std.testing.expect(stmt.let.type_name == null);
    try std.testing.expect(stmt.let.init.? == .int_lit);
}

test "parser: let with f64 annotation" {
    const src = "fun f() {\n    let speed: f64 = 1.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expectEqualStrings("speed", stmt.let.name);
    try std.testing.expectEqualStrings("f64", stmt.let.type_name.?);
}

test "parser: let with multiple lets each annotated" {
    const src = "fun f() {\n    let x: i32 = 1;\n    let y: f64 = 2.0;\n    let z = true;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqualStrings("i32", body[0].let.type_name.?);
    try std.testing.expectEqualStrings("f64", body[1].let.type_name.?);
    try std.testing.expect(body[2].let.type_name == null);
}

test "parser: simple binary add" {
    const src = "fun f() {\n    let z: i32 = 1 + 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .int_lit);
    try std.testing.expect(init.binary.rhs.* == .int_lit);
}

test "parser: precedence — mul binds tighter than add" {
    // 1 + 2 * 3 → 1 + (2 * 3) → binary(add, 1, binary(mul, 2, 3))
    const src = "fun f() {\n    let z: i32 = 1 + 2 * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .int_lit);
    try std.testing.expect(init.binary.rhs.* == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.binary.rhs.*.binary.op);
}

test "parser: precedence — parens override" {
    // (1 + 2) * 3 → binary(mul, binary(add, 1, 2), 3)
    const src = "fun f() {\n    let z: i32 = (1 + 2) * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.binary.op);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.binary.lhs.*.binary.op);
}

test "parser: left-associative chain" {
    // 1 - 2 - 3 → (1 - 2) - 3 → binary(sub, binary(sub, 1, 2), 3)
    const src = "fun f() {\n    let z: i32 = 1 - 2 - 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expectEqual(ast.Expr.BinaryOp.sub, init.binary.op);
    try std.testing.expectEqual(ast.Expr.BinaryOp.sub, init.binary.lhs.*.binary.op);
    try std.testing.expect(init.binary.lhs.*.binary.lhs.* == .int_lit);
}

test "parser: identifier operands" {
    const src = "fun f() {\n    let z: i32 = x * y;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.binary.op);
    try std.testing.expectEqualStrings("x", init.binary.lhs.*.ident);
    try std.testing.expectEqualStrings("y", init.binary.rhs.*.ident);
}

test "parser: var with type annotation" {
    const src = "fun f() {\n    var y: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .var_binding);
    try std.testing.expectEqualStrings("y", stmt.var_binding.name);
    try std.testing.expectEqualStrings("f64", stmt.var_binding.type_name.?);
    try std.testing.expect(stmt.var_binding.init.? == .float_lit);
}

test "parser: var without type annotation" {
    const src = "fun f() {\n    var n = 0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .var_binding);
    try std.testing.expect(stmt.var_binding.type_name == null);
}

test "parser: bare assignment is recognised as .assign" {
    const src = "fun f() {\n    y = 5;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .assign);
    try std.testing.expectEqualStrings("y", stmt.assign.name);
    try std.testing.expect(stmt.assign.value == .int_lit);
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
    try std.testing.expect(stmt == .expr_stmt);
    try std.testing.expect(stmt.expr_stmt == .ident);
    try std.testing.expectEqualStrings("y", stmt.expr_stmt.ident);
}

test "parser: const with type annotation" {
    const src = "fun f() {\n    const PI: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .const_binding);
    try std.testing.expectEqualStrings("PI", stmt.const_binding.name);
    try std.testing.expectEqualStrings("f64", stmt.const_binding.type_name.?);
    try std.testing.expect(stmt.const_binding.init.? == .float_lit);
}

test "parser: const without type annotation" {
    const src = "fun f() {\n    const k = 7;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .const_binding);
    try std.testing.expectEqualStrings("k", stmt.const_binding.name);
    try std.testing.expect(stmt.const_binding.type_name == null);
    try std.testing.expect(stmt.const_binding.init.? == .int_lit);
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
    const arg = print_stmt.expr_stmt.call.args[0];
    try std.testing.expect(arg == .template_lit);
    // source "{PI:.5}" has no leading text, so buildTemplate emits:
    //   parts[0] = { expr = ident "PI",  spec = ".5" }   (interpolation)
    //   parts[1] = { literal = "" }                       (trailing literal)
    try std.testing.expectEqual(@as(usize, 2), arg.template_lit.parts.len);
    try std.testing.expect(arg.template_lit.parts[0].literal == null);
    try std.testing.expect(arg.template_lit.parts[0].expr != null);
    try std.testing.expectEqualStrings("PI", arg.template_lit.parts[0].expr.?.ident);
    try std.testing.expect(arg.template_lit.parts[0].spec != null);
    try std.testing.expectEqualStrings(".5", arg.template_lit.parts[0].spec.?);
    try std.testing.expect(arg.template_lit.parts[1].literal != null);
    try std.testing.expectEqualStrings("", arg.template_lit.parts[1].literal.?);
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
    const arg = print_stmt.expr_stmt.call.args[0];
    try std.testing.expect(arg == .template_lit);
    // The single interpolation part has `spec == null`.
    for (arg.template_lit.parts) |part| {
        if (part.expr) |expr| {
            try std.testing.expectEqualStrings("name", expr.ident);
            try std.testing.expect(part.spec == null);
        }
    }
}

test "parser: tuple destructuring" {
    // `let (x, y) = (10, 20);` should split into a tuple pattern with two
    // name leaves. The legacy `name` field is the empty sentinel for
    // destructuring forms.
    const src = "fun f() {\n    let (x, y) = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.pattern != null);
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    try std.testing.expectEqual(@as(usize, 2), stmt.let.pattern.?.tuple.len);
    try std.testing.expectEqualStrings("x", stmt.let.pattern.?.tuple[0].name);
    try std.testing.expectEqualStrings("y", stmt.let.pattern.?.tuple[1].name);
    try std.testing.expectEqualStrings("", stmt.let.name);
    try std.testing.expect(stmt.let.type_name == null);
    try std.testing.expect(stmt.let.init.? == .tuple_lit);
}

test "parser: array destructuring" {
    // `let [a, b, c] = arr;` should split into an array pattern with three
    // name leaves. Same legacy-field-sentinel behaviour as tuple form.
    const src = "fun f() {\n    let [a, b, c] = arr;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.pattern != null);
    try std.testing.expect(stmt.let.pattern.? == .array);
    try std.testing.expectEqual(@as(usize, 3), stmt.let.pattern.?.array.len);
    try std.testing.expectEqualStrings("a", stmt.let.pattern.?.array[0].name);
    try std.testing.expectEqualStrings("b", stmt.let.pattern.?.array[1].name);
    try std.testing.expectEqualStrings("c", stmt.let.pattern.?.array[2].name);
    try std.testing.expect(stmt.let.init.? == .ident);
    try std.testing.expectEqualStrings("arr", stmt.let.init.?.ident);
}

test "parser: destructuring with wildcard discard" {
    // `let (_, y, _) = (1, 2, 3);` should split into a tuple of
    // [discard, name("y"), discard].
    const src = "fun f() {\n    let (_, y, _) = (1, 2, 3);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    try std.testing.expectEqual(@as(usize, 3), stmt.let.pattern.?.tuple.len);
    try std.testing.expect(stmt.let.pattern.?.tuple[0] == .discard);
    try std.testing.expectEqualStrings("y", stmt.let.pattern.?.tuple[1].name);
    try std.testing.expect(stmt.let.pattern.?.tuple[2] == .discard);
}

test "parser: top-level wildcard" {
    // `let _ = 42` should produce a discard-only pattern with no leaves.
    // The earlier `let _: i32 = 42` form regressed when the colon-on-pattern
    // rejection was added (parser now surfaces
    // "let pattern: per-leaf type annotations are not supported"); the bare
    // wildcard form is the canonical use.
    const src = "fun f() {\n    let _ = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.pattern != null);
    try std.testing.expect(stmt.let.pattern.? == .discard);
    try std.testing.expect(stmt.let.init.? == .int_lit);
}

test "parser: nested destructuring" {
    // `let (a, (b, c)) = (1, (2, 3));` should produce a tuple containing
    // [name("a"), tuple([name("b"), name("c")])] — recursion works.
    const src = "fun f() {\n    let (a, (b, c)) = (1, (2, 3));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    try std.testing.expectEqual(@as(usize, 2), stmt.let.pattern.?.tuple.len);
    try std.testing.expectEqualStrings("a", stmt.let.pattern.?.tuple[0].name);
    try std.testing.expect(stmt.let.pattern.?.tuple[1] == .tuple);
    try std.testing.expectEqualStrings("b", stmt.let.pattern.?.tuple[1].tuple[0].name);
    try std.testing.expectEqualStrings("c", stmt.let.pattern.?.tuple[1].tuple[1].name);
}

test "parser: errdefer parses as Stmt.errdefer_stmt" {
    // Pattern 2 from docs/19-memory.md: `errdefer free(a)` runs only on the
    // `?`-propagation path. Parser pins the AST tag so the codegen surface
    // ({errdefer expr;}) is replayable by tests.
    //
    // The expression `print("cleanup\n")` parses as a `.call` node because
    // `"cleanup\n"` is a string-literal (no `{` markers) — the parser's
    // `.string_literal` arm only routes to `buildTemplate` when an
    // interpolation marker is present. Pre-existing test wrote this with
    // `.template_lit` based on an earlier codegen shape that no longer
    // applies; updated to match the current AST shape.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .errdefer_stmt);
    try std.testing.expect(stmt.errdefer_stmt.expr == .call);
    try std.testing.expectEqualStrings("print", stmt.errdefer_stmt.expr.call.name);
    try std.testing.expectEqual(@as(usize, 1), stmt.errdefer_stmt.expr.call.args.len);
    try std.testing.expectEqualStrings("cleanup\\n", stmt.errdefer_stmt.expr.call.args[0].string_lit);
}

test "parser: unsafe { } parses as Stmt.unsafe_block" {
    // Source-level audit block. The body statements live inside the union
    // payload as `[]const Stmt`; codegen emits them inside plain `{ … }`
    // with `// unsafe {` and `// }` markers for tooling.
    const src = "fun f() {\n    unsafe {\n        print(\"inside\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .unsafe_block);
    try std.testing.expectEqual(@as(usize, 1), stmt.unsafe_block.len);
    try std.testing.expect(stmt.unsafe_block[0] == .expr_stmt);
}

test "parser: x as Type parses as Expr.cast" {
    // `as` sits between unary and postfix in the ladder so `1 + x as i32`
    // parses as `1 + (x as i32)` (cast binds tighter than additive).
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .cast);
    try std.testing.expectEqualStrings("i32", init.cast.type_text);
    try std.testing.expect(init.cast.expr.* == .ident);
    try std.testing.expectEqualStrings("x", init.cast.expr.*.ident);
}

test "parser: p as *raw c_void captures multi-token type" {
    // The verbatim-source-text capture enables pointer casts where the
    // destination type includes the `*raw` modifier and a multi-token
    // tail like `c_void`. The capture joins `*`, `raw`, `c_void` into one
    // `type_text` slice that codegen can hand to zig's `as` operator.
    const src = "fun f() {\n    let p: *raw u8 = 0 as *raw u8;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .cast);
    try std.testing.expectEqualStrings("*raw u8", init.cast.type_text);
}

test "parser: new(<alloc>, T(v)) sugar sets allocator field" {
    // Pattern 3 from docs/19-memory.md: arena allocation. Parser pins the
    // allocator carrier so codegen emits `<arena>.create(T)` rather than
    // the global page allocator.
    const src = "fun f() {\n    let p = new(arena, i32(0));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena2 = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena2);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .new_expr);
    try std.testing.expectEqualStrings("i32", init.new_expr.type_name);
    try std.testing.expect(init.new_expr.allocator != null);
    try std.testing.expectEqualStrings("arena", init.new_expr.allocator.?);
}

test "parser: new T(v) keeps allocator null for global-heap shape" {
    // Sanity check on the simple form: allocator=null means codegen emits
    // `std.heap.page_allocator.create(T)` rather than a user-supplied
    // arena's `.create(T)`.
    const src = "fun f() {\n    let p = new i32(42);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena2 = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena2);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .new_expr);
    try std.testing.expect(init.new_expr.allocator == null);
    try std.testing.expectEqualStrings("i32", init.new_expr.type_name);
    try std.testing.expect(init.new_expr.value.* == .int_lit);
}

test "parser: struct decl produces StructDecl with named fields" {
    const src = "struct Vec3 {\n    x: f64,\n    y: f64,\n    z: f64,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqualStrings("Vec3", prog.structs[0].name);
    try std.testing.expectEqual(@as(usize, 3), prog.structs[0].fields.len);
    const xyz = prog.structs[0].fields;
    try std.testing.expect(xyz[0].kind == .named);
    try std.testing.expectEqualStrings("x", xyz[0].kind.named.name);
    try std.testing.expectEqualStrings("f64", xyz[0].kind.named.type_text);
    try std.testing.expectEqualStrings("y", xyz[1].kind.named.name);
    try std.testing.expectEqualStrings("z", xyz[2].kind.named.name);
}

test "parser: struct decl accepts embed-form field" {
    // `Button { Widget, label: String }` mixes an embed row (`Widget,` —
    // no colon) with two regular named rows. Parser pins both shapes.
    const src = "struct Button {\n    Widget,\n    label: String,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 2), prog.structs[0].fields.len);
    try std.testing.expect(prog.structs[0].fields[0].kind == .embed);
    try std.testing.expectEqualStrings("Widget", prog.structs[0].fields[0].kind.embed.type_name);
    try std.testing.expect(prog.structs[0].fields[1].kind == .named);
    try std.testing.expectEqualStrings("label", prog.structs[0].fields[1].kind.named.name);
}

test "parser: impl block produces ImplBlock with methods" {
    // The canonical docs/12 method shape: `pub fun NAME(self: *const T)
    // -> RET { … }`. Parser pins the param is_self discrimination so
    // codegen can nest the method inside the matching struct decl as
    // zig's native struct-member function.
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
        \\    pub fun new(x: f64, y: f64, z: f64) -> Vec3 {
        \\        return Vec3 { x: 0.0, y: 0.0, z: 0.0 };
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqual(@as(usize, 1), prog.impls.len);
    try std.testing.expectEqualStrings("Vec3", prog.impls[0].target_type);
    try std.testing.expectEqual(@as(usize, 2), prog.impls[0].methods.len);
    try std.testing.expectEqualStrings("length", prog.impls[0].methods[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.impls[0].methods[0].params.len);
    try std.testing.expectEqualStrings("self", prog.impls[0].methods[0].params[0].name);
    try std.testing.expect(prog.impls[0].methods[0].params[0].is_self);
    try std.testing.expectEqualStrings("*const Vec3", prog.impls[0].methods[0].params[0].type_text);
    try std.testing.expectEqualStrings("f64", prog.impls[0].methods[0].return_type.?);
    // new() constructors have NO self param — the parser must set
    // is_self=false for the positional params.
    try std.testing.expectEqualStrings("new", prog.impls[0].methods[1].name);
    try std.testing.expectEqual(@as(usize, 3), prog.impls[0].methods[1].params.len);
    try std.testing.expect(!prog.impls[0].methods[1].params[0].is_self);
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
    const a_init = prog.functions[0].body[1].let.init.?;
    try std.testing.expect(a_init == .member_access);
    try std.testing.expectEqualStrings("x", a_init.member_access.name);
    try std.testing.expect(a_init.member_access.target.* == .ident);
    try std.testing.expectEqualStrings("v", a_init.member_access.target.*.ident);
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
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .method_call);
    try std.testing.expectEqualStrings("length", init.method_call.name);
    try std.testing.expectEqual(@as(usize, 0), init.method_call.args.len);
    try std.testing.expect(init.method_call.target.* == .ident);
    try std.testing.expectEqualStrings("v", init.method_call.target.*.ident);
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
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .method_call);
    try std.testing.expectEqualStrings("Vec3", init.method_call.target.*.ident);
    try std.testing.expectEqualStrings("new", init.method_call.name);
    try std.testing.expectEqual(@as(usize, 3), init.method_call.args.len);
    try std.testing.expect(init.method_call.args[0] == .float_lit);
}

test "parser: struct-literal produces Expr.struct_lit" {
    // `Vec3 { x: 1.0, y: 2.0, z: 3.0 }` parses as `.struct_lit(type_name
    // ="Vec3", inits=[3 FieldInit])`. Field-init order is preserved so
    // codegen's verbatim `.f = v` emission matches source order.
    const src = "fun f() {\n    let v = Vec3 { x: 1.0, y: 2.0, z: 3.0 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .struct_lit);
    try std.testing.expectEqualStrings("Vec3", init.struct_lit.type_name);
    try std.testing.expectEqual(@as(usize, 3), init.struct_lit.inits.len);
    try std.testing.expectEqualStrings("x", init.struct_lit.inits[0].name);
    try std.testing.expectEqualStrings("y", init.struct_lit.inits[1].name);
    try std.testing.expectEqualStrings("z", init.struct_lit.inits[2].name);
    try std.testing.expect(init.struct_lit.inits[0].value.* == .float_lit);
}

test "parser: parseFieldAssign triggers on name.field = value" {
    // The 3-token lookahead at parseStmt's identifier arm dispatches into
    // `.field_assign` when the pattern `ident . ident = ` is detected.
    // The receiver path here is the bare `v` ident; for complex LHSs
    // like `arr[i].field = ` the user can extract to a local first.
    const src = "fun f() {\n    v.x = 10.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .field_assign);
    try std.testing.expectEqualStrings("x", stmt.field_assign.field_name);
    try std.testing.expect(stmt.field_assign.target.* == .ident);
    try std.testing.expectEqualStrings("v", stmt.field_assign.target.*.ident);
    try std.testing.expect(stmt.field_assign.value == .float_lit);
}

test "parser: if-stmt parses as Stmt.if_stmt" {
    // The unconditional `if` branch surfaces as a Tagged-Stmt.if_stmt
    // (NOT `.if_expr`), confirming that the statement form is in place.
    // The cond captures the predicate expression and the body block
    // holds the inner statement list.
    const src = "fun f() {\n    if x > 0 {\n        print(\"positive\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .if_stmt);
    try std.testing.expect(stmt.if_stmt.cond == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.gt, stmt.if_stmt.cond.binary.op);
    try std.testing.expectEqual(@as(usize, 1), stmt.if_stmt.then_body.len);
    try std.testing.expect(stmt.if_stmt.then_body[0] == .expr_stmt);
    try std.testing.expect(stmt.if_stmt.else_kind == .none);
}

test "parser: if-stmt with else-if chain walks nested if_kind" {
    // An `else if …` chain should fold into the .if_chain arm of the
    // OUTER if_stmt's else_kind rather than creating a stmt-level
    // sibling — the chain lives structurally inside the first if so
    // codegen can emit it as a single `if/else if/else if` block.
    const src = "fun f() {\n    if a {\n        print(\"a\\n\");\n    } else if b {\n        print(\"b\\n\");\n    } else {\n        print(\"other\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .if_stmt);
    try std.testing.expect(stmt.if_stmt.else_kind == .if_chain);
    const mid = stmt.if_stmt.else_kind.if_chain;
    try std.testing.expect(mid.cond == .ident);
    try std.testing.expectEqualStrings("b", mid.cond.ident);
    try std.testing.expect(mid.else_kind == .block);
}

test "parser: if-expression parses as Expr.if_expr (RHS of let)" {
    // The expression form `let x = if cond { … } else { … }` lands in
    // Expr.if_expr (NOT .if_stmt) so codegen can emit it as a value-yielding
    // block. The two arms carry pointers (cycle-broken type, see
    // parseIfExpr in parser.zig).
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
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .if_expr);
    try std.testing.expect(init.if_expr.cond.* == .binary);
    try std.testing.expect(init.if_expr.then_expr.* == .int_lit);
    try std.testing.expectEqualStrings("1", init.if_expr.then_expr.*.int_lit);
    try std.testing.expect(init.if_expr.else_expr.* == .int_lit);
    try std.testing.expectEqualStrings("0", init.if_expr.else_expr.*.int_lit);
}

test "parser: while-stmt parses as Stmt.while_stmt" {
    // Standard while loop: cond captured as Expr, body as slice of Stmt.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .while_stmt);
    try std.testing.expect(stmt.while_stmt.cond == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.lt, stmt.while_stmt.cond.binary.op);
    try std.testing.expectEqual(@as(usize, 1), stmt.while_stmt.body.len);
}

test "parser: for-range parses as Stmt.for_stmt with RangeExpr iter" {
    // `for i in 0..10` should land on Stmt.for_stmt. The iter expression
    // should be an Expr.range (start=0, end=10, inclusive=false). The
    // pattern is a single .ident so the for-loop's capture-name comes
    // through verbatim.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .for_stmt);
    try std.testing.expect(stmt.for_stmt.iter == .range);
    try std.testing.expectEqualStrings("0", stmt.for_stmt.iter.range.start.*.int_lit);
    try std.testing.expectEqualStrings("10", stmt.for_stmt.iter.range.end.*.int_lit);
    try std.testing.expect(!stmt.for_stmt.iter.range.inclusive);
    try std.testing.expect(stmt.for_stmt.pattern == .ident);
    try std.testing.expectEqualStrings("i", stmt.for_stmt.pattern.ident);
}

test "parser: for-incl range sets inclusive flag" {
    // `...` (ellipsis) in zag maps to inclusive=true so codegen can add
    // 1 to make zig's half-open range iterate inclusively.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .for_stmt);
    try std.testing.expect(stmt.for_stmt.iter.range.inclusive);
}

test "parser: for-iter non-range parses with the user expression as iter" {
    // `for x in items()` carries the call expression as for_stmt.iter
    // (NOT as range) so codegen routes to verbatim emission rather than
    // the inline range rewrite.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .for_stmt);
    try std.testing.expect(stmt.for_stmt.iter == .call);
    try std.testing.expectEqualStrings("items", stmt.for_stmt.iter.call.name);
}

test "parser: match-stmt with literal arms parses as Stmt.match_stmt" {
    // The statement-position match lands on Stmt.match_stmt; the
    // scrutinee and arms are populated correctly. Each arm carries
    // `pat` + optional `guard` + arm-body expression.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .match_stmt);
    try std.testing.expect(stmt.match_stmt.scrutinee.* == .ident);
    try std.testing.expectEqualStrings("n", stmt.match_stmt.scrutinee.*.ident);
    try std.testing.expectEqual(@as(usize, 3), stmt.match_stmt.arms.len);

    try std.testing.expect(stmt.match_stmt.arms[0].pat == .literal);
    try std.testing.expectEqualStrings("1", stmt.match_stmt.arms[0].pat.literal.*.int_lit);
    try std.testing.expect(stmt.match_stmt.arms[0].guard == null);
    try std.testing.expectEqualStrings("one", stmt.match_stmt.arms[0].expr.*.string_lit);

    try std.testing.expect(stmt.match_stmt.arms[1].pat == .literal);
    try std.testing.expectEqualStrings("2", stmt.match_stmt.arms[1].pat.literal.*.int_lit);

    try std.testing.expect(stmt.match_stmt.arms[2].pat == .discard);
    try std.testing.expectEqualStrings("other", stmt.match_stmt.arms[2].expr.*.string_lit);
}

test "parser: match-stmt with range arm and guard" {
    // A range pattern captures both bounds + inclusive flag; a guard
    // (the `if cond` after the pattern) is recorded on the arm alongside
    // the pattern rather than baked into it.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .match_stmt);
    try std.testing.expect(stmt.match_stmt.arms[0].pat == .range);
    try std.testing.expectEqualStrings("0", stmt.match_stmt.arms[0].pat.range.start.*.int_lit);
    try std.testing.expectEqualStrings("10", stmt.match_stmt.arms[0].pat.range.end.*.int_lit);
    try std.testing.expect(!stmt.match_stmt.arms[0].pat.range.inclusive);
}

test "parser: match-stmt with ident-pattern arm binds name" {
    // An ident-pattern arm (`n => n + 1`) carries the binding name on
    // arm.pat so codegen can emit `const <name> = __m_<N>;` before the
    // arm body, giving the body access to the binding.
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
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .match_stmt);
    try std.testing.expect(stmt.match_stmt.arms[0].pat == .ident);
    try std.testing.expectEqualStrings("x", stmt.match_stmt.arms[0].pat.ident);
    try std.testing.expect(stmt.match_stmt.arms[0].expr.* == .binary);
}

test "parser: match-expression parses as Expr.match_expr" {
    // Mirroring of the statement form: when `match` sits in expression
    // position (e.g. RHS of a let binding) it lands on Expr.match_expr
    // so codegen can emit it as a value-yielding block.
    const src =
        \\fun f() {
        \\    let label: i32 = match n {
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
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .match_expr);
    try std.testing.expectEqualStrings("n", init.match_expr.scrutinee.*.ident);
    try std.testing.expectEqual(@as(usize, 2), init.match_expr.arms.len);
}

test "parser: break-stmt parses as Stmt.break_stmt" {
    // Statement-only break per the user-confirmed shape: no value form,
    // no label. The stmt has no payload (the parser materialises the
    // union case with empty data).
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
    const stmt = prog.functions[0].body[0].while_stmt.body[0];
    try std.testing.expect(stmt == .break_stmt);
}

test "parser: continue-stmt parses as Stmt.continue_stmt" {
    // Continue is a bare statements emitted by codegen verbatim.
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
    const stmt = prog.functions[0].body[0].for_stmt.body[0];
    try std.testing.expect(stmt == .continue_stmt);
}

test "parser: return-stmt with value parses as Stmt.return_stmt with expr" {
    // `return expr;` carries the value expression on the stmt so codegen
    // can emit `return <expr>;` verbatim.
    const src = "fun f() {\n    return 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .return_stmt);
    try std.testing.expect(stmt.return_stmt.value != null);
    try std.testing.expectEqualStrings("42", stmt.return_stmt.value.?.int_lit);
}

test "parser: bare return parses as Stmt.return_stmt with null value" {
    // Bare `return;` (no value) populates `value` with null so codegen
    // emits `return;` (no expression after).
    const src = "fun f() {\n    return;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .return_stmt);
    try std.testing.expect(stmt.return_stmt.value == null);
}

test "parser: unary `&x` parses as Expr.unary with UnaryOp.addr" {
    // The unary-vs-binary dispatch on `.amp`: in prefix position the
    // (otherwise-shared) `.amp` TokenTag routes to `.addr` rather than
    // `.bitand`, mirroring how `-x` (unary) vs `a - b` (binary) share
    // the `.minus` token. The operand lives inside a pointer-typed
    // field of `Expr.UnaryExpr` so the AST follows the existing `*Expr`
    // cycle-breaker convention.
    const src = "fun f() {\n    var x: i32 = 0;\n    let p: *i32 = &x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    // body[1] is `let p = &x` (body[0] is `var x: i32 = 0`).
    const init = body[1].let.init.?;
    try std.testing.expect(init == .unary);
    try std.testing.expectEqual(ast.Expr.UnaryOp.addr, init.unary.op);
    try std.testing.expect(init.unary.operand.* == .ident);
    try std.testing.expectEqualStrings("x", init.unary.operand.*.ident);
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
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.bitand, init.binary.op);
}

test "parser: slicing `arr[1..3]` produces Expr.slice with explicit bounds" {
    // The postfix chain dispatch detects slice form by lookahead ON
    // the inside of `[`: when range/ellipsis follows the bound
    // expression (or appears immediately as the empty-start form),
    // `.slice` is built instead of `.index`. `start`/`end` carry the
    // lifted-expr payloads via the `*Expr` slot convention so the
    // bounds stay on the AST after the parsing function returns.
    const src = "fun f() {\n    let s: []i32 = arr[1..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .slice);
    try std.testing.expect(!init.slice.inclusive);
    try std.testing.expect(init.slice.start != null);
    try std.testing.expect(init.slice.end != null);
    try std.testing.expect(init.slice.start.?.* == .int_lit);
    try std.testing.expectEqualStrings("1", init.slice.start.?.*.int_lit);
    try std.testing.expect(init.slice.end.?.* == .int_lit);
    try std.testing.expectEqualStrings("3", init.slice.end.?.*.int_lit);
}

test "parser: no-bound slice `arr[..]` produces SliceExpr with null bounds" {
    // `..` with no start OR end signals "whole-array view". The
    // nullable `start`/`end` AST fields are both null so codegen
    // emits just `arr[..]` (zig's native full-view slice syntax).
    const src = "fun f() {\n    let s: []i32 = arr[..];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .slice);
    try std.testing.expect(init.slice.start == null);
    try std.testing.expect(init.slice.end == null);
    try std.testing.expect(!init.slice.inclusive);
}

test "parser: `arr[i]` stays as Expr.index (slice form does not eat single index)" {
    // The non-slice shape must keep parsing as `.index` so existing
    // tests for `arr[N]` access (and the `[N]T { ... }` array-literal
    // parser) keep working. The postfix loop's `.rbracket` peek after
    // a single bound expression routes to `.index` regardless of
    // what came before inside `[`.
    const src = "fun f() {\n    let v: i32 = arr[2];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .index);
}

test "parser: slicing `arr[2..]` produces SliceExpr with end null" {
    // The "start explicit, no end" form: peek after the start bound is
    // `.range`/`.ellipsis` (slice form fires), end-side peek is
    // `.rbracket` (no end expression parsed, so `end` stays null).
    // Verifies the postfix extension handles the trailing `..` correctly
    // without leaving the end-bound parser to over-consume `]`.
    const src = "fun f() {\n    let s: []i32 = arr[2..];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .slice);
    try std.testing.expect(!init.slice.inclusive);
    try std.testing.expect(init.slice.start != null);
    try std.testing.expect(init.slice.start.?.* == .int_lit);
    try std.testing.expectEqualStrings("2", init.slice.start.?.*.int_lit);
    try std.testing.expect(init.slice.end == null);
}

test "parser: slicing `arr[..3]` produces SliceExpr with start null" {
    // The "no start, end explicit" form: peek after `[` is `.range`/
    // `.ellipsis` immediately (empty-start slice fires), end-bound is
    // parsed via parseAdditive. `start` stays null.
    const src = "fun f() {\n    let s: []i32 = arr[..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .slice);
    try std.testing.expect(!init.slice.inclusive);
    try std.testing.expect(init.slice.start == null);
    try std.testing.expect(init.slice.end != null);
    try std.testing.expect(init.slice.end.?.* == .int_lit);
    try std.testing.expectEqualStrings("3", init.slice.end.?.*.int_lit);
}

test "parser: uppercase if-condition does not misparse as struct-literal" {
    // Regression for the parseStructLit heuristic refinement. With the
    // prior uppercase-first-letter gate, `if Foo { ... }` (Foo: a PascalCase
    // local used as the condition) routed `Foo { ... }` to parseStructLit
    // and swallowed the if-body. After replacing the uppercase-only gate
    // with the `allow_struct_lit` parse-context flag, parsePrimary sees
    // `Foo` as a bare ident in the if-condition (flag=false there), the
    // immediate `{` belongs to the if-body, and `else { ... }` is the
    // terminal else branch.
    const src = "fun f() {\n    let Foo: i32 = 1;\n    if Foo {\n        print(\"a\\n\");\n    } else {\n        print(\"b\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions.len == 1);
    try std.testing.expect(prog.functions[0].body.len == 2);
    try std.testing.expect(prog.functions[0].body[1] == .if_stmt);
    try std.testing.expect(prog.functions[0].body[1].if_stmt.cond == .ident);
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].body[1].if_stmt.cond.ident, "Foo"));
    try std.testing.expect(prog.functions[0].body[1].if_stmt.else_kind == .block);
}

test "parser: prior-broken-form (was raw-string-continuation, now collapsed to plain string)" {
    // The originating test used a zig raw-string line-
    // continuation form that produced a literal form-feed byte
    // at the start of the zag source. Replaced with the same
    // regular-string "..." + `\n` escape convention used by
    // every other test in this file.
    const src = "f() { let x = if Foo { 1 } else { 2 }; let v = Vec3 { x: 1, y: 2, z: 3 };\n}";
    _ = src;
}

test "parser: bare enum decl with single variant" {
    const src = "enum Color { Red }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.enums[0].name, "Color"));
    try std.testing.expect(prog.enums[0].variants.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.enums[0].variants[0].name, "Red"));
    try std.testing.expect(prog.enums[0].variants[0].payload_type == null);
}

test "parser: enum decl with multiple bare variants" {
    const src = "enum Direction { North, South, East, West }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    const ed = prog.enums[0];
    try std.testing.expect(std.mem.eql(u8, ed.name, "Direction"));
    try std.testing.expect(ed.variants.len == 4);
    try std.testing.expect(std.mem.eql(u8, ed.variants[0].name, "North"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[1].name, "South"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[2].name, "East"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[3].name, "West"));
    // All bare: every payload_type slot is null.
    var i: usize = 0;
    while (i < ed.variants.len) : (i += 1) {
        try std.testing.expect(ed.variants[i].payload_type == null);
    }
}

test "parser: enum decl with single-arg payload" {
    const src = "enum Shape { Circle(f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    const v = prog.enums[0].variants[0];
    try std.testing.expect(std.mem.eql(u8, v.name, "Circle"));
    try std.testing.expect(v.payload_type != null);
    try std.testing.expect(std.mem.eql(u8, v.payload_type.?, "f64"));
}

test "parser: enum decl with multi-arg payload joined verbatim" {
    const src = "enum R { Pair(i32, f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const v = prog.enums[0].variants[0];
    try std.testing.expect(std.mem.eql(u8, v.name, "Pair"));
    try std.testing.expect(v.payload_type != null);
    try std.testing.expect(std.mem.eql(u8, v.payload_type.?, "i32, f64"));
}

test "parser: qualified enum-variant-ctor expression with no args" {
    const src =
        \\fun main() {
        \\    let d: Direction = Direction.North;
        \\    print(d);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .enum_variant_ctor);
    const evc = init.enum_variant_ctor;
    try std.testing.expect(std.mem.eql(u8, evc.enum_name.?, "Direction"));
    try std.testing.expect(std.mem.eql(u8, evc.variant_name, "North"));
    try std.testing.expect(evc.args.len == 0);
}

test "parser: qualified enum-variant-ctor with payload args" {
    const src =
        \\fun main() {
        \\    let s: Shape = Shape.Circle(2.5);
        \\    print(s);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .enum_variant_ctor);
    const evc = init.enum_variant_ctor;
    try std.testing.expect(std.mem.eql(u8, evc.enum_name.?, "Shape"));
    try std.testing.expect(std.mem.eql(u8, evc.variant_name, "Circle"));
    try std.testing.expect(evc.args.len == 1);
    try std.testing.expect(evc.args[0] == .float_lit);
    try std.testing.expect(std.mem.eql(u8, evc.args[0].float_lit, "2.5"));
}

test "parser: qualified enum-variant pattern in match" {
    const src =
        \\fun main() {
        \\    match d {
        \\        Direction.North => 1,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].match_stmt.arms;
    try std.testing.expect(arms.len == 2);
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(std.mem.eql(u8, ev.enum_name, "Direction"));
    try std.testing.expect(std.mem.eql(u8, ev.variant_name, "North"));
    try std.testing.expect(ev.bindings == null);
    try std.testing.expect(arms[1].pat == .discard);
}

test "parser: unqualified enum-variant pattern in match" {
    const src =
        \\fun main() {
        \\    match d {
        \\        North => 1,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].match_stmt.arms;
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(std.mem.eql(u8, ev.enum_name, ""));
    try std.testing.expect(std.mem.eql(u8, ev.variant_name, "North"));
    try std.testing.expect(ev.bindings == null);
}

test "parser: enum-variant pattern with bindings" {
    const src =
        \\fun main() {
        \\    match v {
        \\        Some(x) => x,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].match_stmt.arms;
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(ev.bindings != null);
    try std.testing.expect(ev.bindings.?.len == 1);
    try std.testing.expect(ev.bindings.?[0] != null);
    try std.testing.expect(std.mem.eql(u8, ev.bindings.?[0].?, "x"));
}

test "parser: (42,) routes to single_tuple_lit" {
    const src = "fun f() {\n    let a = (42,);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .single_tuple_lit);
    try std.testing.expect(init.single_tuple_lit.* == .int_lit);
    try std.testing.expectEqualStrings("42", init.single_tuple_lit.*.int_lit);
}

test "parser: (x: 10, y: 20) routes to named_tuple_lit" {
    const src = "fun f() {\n    let p = (x: 10, y: 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .named_tuple_lit);
    try std.testing.expectEqual(@as(usize, 2), init.named_tuple_lit.names.len);
    try std.testing.expectEqual(@as(usize, 2), init.named_tuple_lit.elements.len);
    try std.testing.expectEqualStrings("x", init.named_tuple_lit.names[0]);
    try std.testing.expectEqualStrings("y", init.named_tuple_lit.names[1]);
    try std.testing.expect(init.named_tuple_lit.elements[0] == .int_lit);
    try std.testing.expect(init.named_tuple_lit.elements[1] == .int_lit);
}

test "parser: (first, ...rest) produces BindingPattern.rest with before_count" {
    const src = "fun f() {\n    let (first, ...rest) = (1, 2, 3, 4);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    const tuple_pat = stmt.let.pattern.?.tuple;
    try std.testing.expectEqual(@as(usize, 2), tuple_pat.len);
    try std.testing.expectEqualStrings("first", tuple_pat[0].name);
    try std.testing.expect(tuple_pat[1] == .rest);
    try std.testing.expectEqualStrings("rest", tuple_pat[1].rest.name);
    try std.testing.expectEqual(@as(u32, 1), tuple_pat[1].rest.before_count);
}

test "parser: array [a, ...rest] produces BindingPattern.array with .rest" {
    const src = "fun f() {\n    let [a, ...rest] = arr;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    const pat = stmt.let.pattern.?;
    try std.testing.expect(pat == .array);
    const leaves = pat.array;
    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    try std.testing.expect(leaves[0] == .name);
    try std.testing.expectEqualStrings("a", leaves[0].name);
    try std.testing.expect(leaves[1] == .rest);
    try std.testing.expectEqualStrings("rest", leaves[1].rest.name);
    try std.testing.expectEqual(@as(u32, 1), leaves[1].rest.before_count);
}

test "parser: (x: 42,) routes to named_tuple_lit (single with trailing comma)" {
    const src = "fun f() {\n    let b = (x: 42,);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.init.? == .named_tuple_lit);
    const nt = stmt.let.init.?.named_tuple_lit;
    try std.testing.expectEqual(@as(usize, 1), nt.names.len);
    try std.testing.expectEqualStrings("x", nt.names[0]);
    try std.testing.expectEqual(@as(usize, 1), nt.elements.len);
    try std.testing.expect(nt.elements[0] == .int_lit);
    try std.testing.expectEqualStrings("42", nt.elements[0].int_lit);
}

test "parser: nested (a, (b, ...ir)) produces recursive tuple .pattern with .rest" {
    const src = "fun f() {\n    let (a, (b, ...ir)) = (1, (2, 3, 4));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    const outer = stmt.let.pattern.?;
    try std.testing.expect(outer == .tuple);
    try std.testing.expectEqual(@as(usize, 2), outer.tuple.len);
    try std.testing.expect(outer.tuple[0] == .name);
    try std.testing.expectEqualStrings("a", outer.tuple[0].name);
    try std.testing.expect(outer.tuple[1] == .tuple);
    const inner_leaves = outer.tuple[1].tuple;
    try std.testing.expectEqual(@as(usize, 2), inner_leaves.len);
    try std.testing.expectEqualStrings("b", inner_leaves[0].name);
    try std.testing.expect(inner_leaves[1] == .rest);
    try std.testing.expectEqualStrings("ir", inner_leaves[1].rest.name);
    try std.testing.expectEqual(@as(u32, 1), inner_leaves[1].rest.before_count);
}

test "parser: fun NAME(params) -> RET_TYPE captures full signature" {
    const src = "fun add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].name, "add"));
    try std.testing.expect(prog.functions[0].params.len == 2);
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].params[0].name, "a"));
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].params[0].type_text, "i32"));
    try std.testing.expect(prog.functions[0].params[0].is_var == false);
    try std.testing.expect(prog.functions[0].params[1].is_var == false);
    try std.testing.expect(prog.functions[0].return_type != null);
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].return_type.?, "i32"));
}

test "parser: var prefix on parameter sets is_var flag" {
    const src = "fun bump(var x: i32) {\n    x += 1;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions.len == 1);
    try std.testing.expect(prog.functions[0].params.len == 1);
    try std.testing.expect(prog.functions[0].params[0].is_var == true);
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].params[0].type_text, "i32"));
}

test "parser: variadic ... suffix sets is_variadic flag" {
    const src = "fun sum(values: i32...) -> i32 {\n    return 0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions[0].params.len == 1);
    try std.testing.expect(prog.functions[0].params[0].is_variadic == true);
}

test "parser: default value = expr captures default_value" {
    const src = "fun connect(host: str, port: u16 = 8080) {\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions[0].params.len == 2);
    try std.testing.expect(prog.functions[0].params[1].default_value != null);
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
    const let_stmt = prog.functions[0].body[0].let;
    try std.testing.expect(let_stmt.init.? == .closure);
    try std.testing.expect(let_stmt.init.?.closure.params.len == 1);
    try std.testing.expect(std.mem.eql(u8, let_stmt.init.?.closure.params[0].name, "x"));
    try std.testing.expect(std.mem.eql(u8, let_stmt.init.?.closure.return_type.?, "i32"));
}

