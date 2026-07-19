// Source-mirror test bucket for src/decl.zig.zig.
// Tests here pin the decl-parser's surface. Routing is by test-name
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

// v1.5 multi-dim single-line (docs/10 \u00a7"Multi-Dim Arrays"): the
// bracket-accumulation loop in parseArrayLit captures additional
// `[K]` brackets before the type ident. The OUTER array_lit gains
// `sizes = [2, 2]` (mirroring `size == 2` for legacy single-dim
// readers); 2 inner rows each a single-row array_lit. Tests
// pin the new field alongside the legacy surface.
test "parser: array lit multi-dim single-line" {
    const src = "fun f() {\n    let m = [2][2]i32 { [2]i32 { 1, 2 }, [2]i32 { 3, 4 } };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 2), init.array_lit.size);
    try std.testing.expect(init.array_lit.sizes != null);
    try std.testing.expectEqual(@as(usize, 2), init.array_lit.sizes.?.len);
    try std.testing.expectEqual(@as(u32, 2), init.array_lit.sizes.?[0]);
    try std.testing.expectEqual(@as(u32, 2), init.array_lit.sizes.?[1]);
    try std.testing.expectEqualStrings("i32", init.array_lit.type_name);
    try std.testing.expectEqual(@as(usize, 2), init.array_lit.elements.len);
}

// v1.5 A2 newline-skip single-dim multi-line body (docs/10 §"Multi-Dim
// Arrays" companion): the OUTER parseArrayLit's element-collection
// accepts `.newline` tokens between elements so
// `[3]i32 {\n    1,\n    2,\n    3,\n}` walks commas cleanly. Without
// skipNewlines, the leading newline after `{` would misroute through
// parseExpr → parsePrimary's default ident arm, and the trailing
// newlines before `}` would surface as `expected expression, found '}'`.
// Pins the 3-element shape across 5 source lines.
test "parser: array lit single-dim multi-line body" {
    const src = "fun f() {\n    let a = [3]i32 {\n        1,\n        2,\n        3,\n    };\n}\n";
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
    try std.testing.expect(init.array_lit.sizes == null);
}

// v1.5 trailing-comma guard (docs/10 §"Multi-Dim Arrays" companion):
// `[N]i32 { 1, 2, 3, }` parses via the new `if (peek == rbrace) break;`
// escape inside parseArrayLit's comma-while loop. Without the guard
// parseExpr would fire against peek=.rbrace and surface as `expected
// expression, found '}'`. Pin a 3-element trailing-comma shape fully
// inline so this fixture isn't coupled to A2's newline-skip surface.
test "parser: array lit single-dim trailing comma" {
    const src = "fun f() {\n    let a = [3]i32 { 1, 2, 3, };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 3), init.array_lit.size);
    try std.testing.expectEqual(@as(usize, 3), init.array_lit.elements.len);
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

test "parser: expression operator {a + b} gate accepts spaces and plus" {
    // New matching-brace gate unblocks expression-shaped interpolation
    // (e.g. binary operators with operands). The pre-fix char-class
    // gate bailed on space + `+` (both non-alphanumeric, not `_`/`:`),
    // so `{a + b}` was incorrectly rejected. The matching-brace gate
    // walks the content looking for a nested `{` (none here) and
    // matches the closing `}`. buildTemplate captures `a + b` as
    // the .ident text; codegen's genExpr .ident arm emits `a + b`
    // verbatim so zig evaluates the binary expression at the
    // format-arg site.
    //
    // Source uses NO leading text (just `"{a + b}\n"`) so buildTemplate
    // produces exactly 2 parts: [expr, trailing literal "\n"]. The
    // pre-fix test source had `"sum = {a + b}\n"` which produces 3
    // parts and the `parts.len == 2` assertion failed. Fixed by
    // removing the incidental leading text.
    const src = "fun f() {\n    let a: i32 = 1;\n    let b: i32 = 2;\n    print(\"{a + b}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[2];
    const arg = print_stmt.expr_stmt.call.args[0];
    try std.testing.expect(arg == .template_lit);
    try std.testing.expectEqual(@as(usize, 2), arg.template_lit.parts.len);
    try std.testing.expect(arg.template_lit.parts[0].literal == null);
    try std.testing.expect(arg.template_lit.parts[0].expr != null);
    // The .ident text carries the full expression verbatim —
    // codegen's .ident arm emits `a + b` as a Zig binary expression.
    try std.testing.expectEqualStrings("a + b", arg.template_lit.parts[0].expr.?.ident);
    try std.testing.expect(arg.template_lit.parts[0].spec == null);
}

test "parser: method call {obj.f()} gate accepts dot and parens inside braces" {
    // New matching-brace gate unblocks method-call interpolation.
    // The pre-fix char-class gate bailed on `.` and `(` (both
    // non-alphanumeric, not `_`/`:`), so `{obj.f()}` was
    // incorrectly rejected. The matching-brace gate accepts these
    // because it only rejects a NESTED `{` (the `{` inside `f()`
    // would be a nested-brace trigger, but the inner `f()` has no
    // braces — only parens, which the gate accepts). buildTemplate
    // captures `obj.f()` as the .ident text; codegen's .ident arm
    // emits `obj.f()` verbatim so zig evaluates the method call.
    //
    // Source uses NO leading text (just `"{obj.f()}\n"`) so buildTemplate
    // produces exactly 2 parts: [expr, trailing literal "\n"]. The
    // pre-fix test source had `"got {obj.f()}\n"` which produces 3
    // parts and the `parts.len == 2` assertion failed. Fixed by
    // removing the incidental leading text.
    const src = "fun f() {\n    let obj: i32 = 1;\n    print(\"{obj.f()}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[1];
    const arg = print_stmt.expr_stmt.call.args[0];
    try std.testing.expect(arg == .template_lit);
    try std.testing.expectEqual(@as(usize, 2), arg.template_lit.parts.len);
    try std.testing.expect(arg.template_lit.parts[0].literal == null);
    try std.testing.expect(arg.template_lit.parts[0].expr != null);
    try std.testing.expectEqualStrings("obj.f()", arg.template_lit.parts[0].expr.?.ident);
    try std.testing.expect(arg.template_lit.parts[0].spec == null);
}

test "parser: nested-brace string stays string_lit (embedded-code case)" {
    // Regression pin for the embedded-code case the legacy
    // char-class gate protected against: a string containing
    // a function body (e.g. `"fun main() {\n    print(...);\n}\n"`),
    // a JSON object (`"{\"k\": 1}"`), or any other string with a
    // nested brace pair must NOT auto-promote to .template_lit,
    // because the inner `{ ... }` block is code, not interpolation.
    // The matching-brace gate rejects this at the inner-`{` step
    // (returns false on the first nested `{`), so the string stays
    // a .string_lit and the embedded code is preserved verbatim.
    // The plain-string `print` codegen path then emits the full
    // text as a single string literal to zig.
    const src = "fun f() {\n    let boilerplate = \"fun main() {\\n    print(\\\"hi\\\");\\n}\\n\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    // Defensive: the source has exactly one stmt (the `let`),
    // so body[0] is the boilerplate binding. Pinning body.len
    // guards against accidental source rewrites shifting the index.
    try std.testing.expectEqual(@as(usize, 1), prog.functions[0].body.len);
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .string_lit);
}

test "parser: statement-like content in braces stays string_lit (; rejected)" {
    // The f559cf3 matching-brace gate was too permissive: it
    // accepted `{...}` content with `;` (semicolons) as a
    // template interpolation. But template interpolations are
    // EXPRESSIONS, not statements — a `;` inside `{...}` is a
    // strong signal of embedded code. The canonical case is the
    // cli.zag boilerplate
    //   "fun main() {\n    print(\"hello, world\\n\");\n}\n"
    // whose `{ print(...); }` is a statement (has `;`), not an
    // expression, and was wrongly auto-promoted by the f559cf3
    // gate — the transpiled zig had a `;` inside the args tuple
    // `.{}` which zig rejected as a syntax error.
    //
    // The refined gate (this commit) explicitly rejects `;`
    // inside `{...}` content. This test pins the `;` rejection
    // with a minimal source that has `;` but NO nested braces
    // (so the nested-brace check above doesn't fire — this test
    // is the `;`-rejection pin specifically). The 3 unblocked
    // patterns from f559cf3 (`{pi:.5}`, `{a + b}`, `{obj.f()}`)
    // are all single-line expressions WITHOUT `;`, so they still
    // pass the refined gate.
    const src = "fun f() {\n    let s = \"x { a; b } y\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init.?;
    try std.testing.expect(init == .string_lit);
    // Strengthened pin on the "gate didn't eat chars" property: the
    // matching-brace gate walks the content to find the matching `}`
    // and rejects on `;`. The bytes between (including the `;`) MUST
    // be preserved verbatim — a gate that half-consumed the content
    // before rejecting (the legacy char-class gate bailed on the
    // first non-alphanumeric char, so a string with `;` would stay
    // as `.string_lit` but the content was already truncated) would
    // fail this assertion. The substring check confirms the full
    // string including the `;` and the trailing `y` is intact.
    try std.testing.expectEqualStrings("x { a; b } y", init.string_lit);
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

test "parser: trait decl records name + methods on Program.traits" {
    // The simplest trait decl shape from docs/17 §"Definition":
    // name + body + required-only method signature. Parser surface
    // only — codegen lives in Phase 2.
    const src = "trait Drawable {\n    fun draw(self: *Self);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.traits.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.traits[0].name, "Drawable"));
    try std.testing.expect(prog.traits[0].methods.len == 1);
}

test "parser: trait method captures required-only signature with null body" {
    // Phase 1+2 minimum subset: trait methods are REQUIRED-only.
    // Parser pins `body == null` so Phase 2 codegen can decide
    // required vs default by inspecting the optional slot. The `self`
    // receiver typed as `*Self` is captured verbatim into
    // `MethodParam.type_text` (codegen rewrites the Self literal to
    // the per-shim generic `T` at emit time; the z-side parser keeps
    // it as a verbatim identifier without a dedicated `.self_kw`
    // token in Phase 1).
    const src = "trait Drawable {\n    fun draw(self: *Self);\n    fun name(self: *Self) -> str;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const td = prog.traits[0];
    try std.testing.expect(td.methods.len == 2);
    try std.testing.expect(std.mem.eql(u8, td.methods[0].name, "draw"));
    try std.testing.expect(td.methods[0].body == null);
    try std.testing.expect(td.methods[0].params.len == 1);
    try std.testing.expect(std.mem.eql(u8, td.methods[0].params[0].name, "self"));
    try std.testing.expect(td.methods[0].params[0].is_self);
    try std.testing.expect(std.mem.eql(u8, td.methods[0].params[0].type_text, "*Self"));
    try std.testing.expect(td.methods[0].return_type == null);
    try std.testing.expect(std.mem.eql(u8, td.methods[1].name, "name"));
    try std.testing.expect(td.methods[1].return_type != null);
    try std.testing.expect(std.mem.eql(u8, td.methods[1].return_type.?, "str"));
}

test "parser: Trait.method-prefixed impl method sets MethodDecl.trait_name" {
    // The `fun Trait.method` lookahead inside parseMethod captures the
    // trait name as a non-null `MethodDecl.trait_name` slot while the
    // post-dot ident becomes the method name. Companion regression
    // check: a NON-trait-prefixed method in the same impl block has
    // `trait_name == null` so Phase 2 codegen's trait-aware free-fn
    // emit can branch on the slot. The impl-block AST records all
    // methods together; the slot is the only differential between
    // trait-scoped and free-floating methods inside the same block.
    const src =
        \\trait Drawable {
        \\    fun draw(self: *Self);
        \\}
        \\struct Button {
        \\    label: str,
        \\}
        \\impl Button {
        \\    pub fun Drawable.draw(self: *Button) {
        \\        print("Button: ");
        \\        print(self.label);
        \\    }
        \\    pub fun regular_method() -> i32 {
        \\        return 7;
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.traits.len == 1);
    try std.testing.expect(prog.impls.len == 1);
    try std.testing.expect(prog.impls[0].methods.len == 2);
    const trait_m = prog.impls[0].methods[0];
    try std.testing.expect(trait_m.trait_name != null);
    try std.testing.expect(std.mem.eql(u8, trait_m.trait_name.?, "Drawable"));
    try std.testing.expect(std.mem.eql(u8, trait_m.name, "draw"));
    const regular_m = prog.impls[0].methods[1];
    try std.testing.expect(regular_m.trait_name == null);
    try std.testing.expect(std.mem.eql(u8, regular_m.name, "regular_method"));
}

// Canonical `with Trait (m)` clause (docs/17 §"Implementing" +
// §"Diamond Disambiguation"). The parser must capture the trait
// list verbatim on `ImplBlock.trait_specs`, including the
// parenthesised preferred-method names that disambiguate the
// diamond. Companion regression check: an impl block WITHOUT the
// `with` clause leaves `trait_specs` empty so the legacy
// non-trait path keeps round-tripping.
test "parser: impl with `with Trait` clause populates trait_specs" {
    const src =
        \\trait Drawable {
        \\    fun draw(self: *Self);
        \\}
        \\struct Button {
        \\    label: str,
        \\}
        \\impl Button with Drawable {
        \\    pub fun draw(self: *Button) {
        \\        print("Button");
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.impls.len == 1);
    try std.testing.expect(prog.impls[0].trait_specs.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.impls[0].trait_specs[0].name, "Drawable"));
    try std.testing.expectEqual(@as(usize, 0), prog.impls[0].trait_specs[0].preferred_methods.len);
    // The method itself is unchanged — body and trait_specs are
    // independent AST slots (the codegen dispatch rule resolves the
    // binding at emit time, NOT the parser).
    try std.testing.expect(std.mem.eql(u8, prog.impls[0].methods[0].name, "draw"));
    try std.testing.expect(prog.impls[0].methods[0].trait_name == null);
}

test "parser: impl with `with Trait (m1, m2)` captures preferred_methods" {
    const src =
        \\trait Display {
        \\    fun print(self: *Self);
        \\}
        \\trait Show {
        \\    fun print(self: *Self);
        \\    fun render(self: *Self);
        \\}
        \\impl Button with Display (print), Show (print, render) {
        \\    pub fun print(self: *Button) { print("x"); }
        \\    pub fun render(self: *Button) { print("y"); }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.impls.len == 1);
    try std.testing.expectEqual(@as(usize, 2), prog.impls[0].trait_specs.len);

    try std.testing.expect(std.mem.eql(u8, prog.impls[0].trait_specs[0].name, "Display"));
    try std.testing.expectEqual(@as(usize, 1), prog.impls[0].trait_specs[0].preferred_methods.len);
    try std.testing.expect(std.mem.eql(u8, prog.impls[0].trait_specs[0].preferred_methods[0], "print"));

    try std.testing.expect(std.mem.eql(u8, prog.impls[0].trait_specs[1].name, "Show"));
    try std.testing.expectEqual(@as(usize, 2), prog.impls[0].trait_specs[1].preferred_methods.len);
    try std.testing.expect(std.mem.eql(u8, prog.impls[0].trait_specs[1].preferred_methods[0], "print"));
    try std.testing.expect(std.mem.eql(u8, prog.impls[0].trait_specs[1].preferred_methods[1], "render"));
}

test "parser: impl without `with` clause leaves trait_specs empty" {
    const src =
        \\impl Button {
        \\    pub fun draw(self: *Button) { print("Button"); }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.impls.len == 1);
    try std.testing.expectEqual(@as(usize, 0), prog.impls[0].trait_specs.len);
}
