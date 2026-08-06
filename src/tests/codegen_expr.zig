// Source-mirror test bucket for src/expr.zig.zig.
// Tests here pin the expr-codegen's surface. Routing is by test-name
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


test "codegen: template literal in print emits __zag_print" {
    const src = "fun f() {\n    let name = \"zag\";\n    print(\"hello, {name}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // zig 0.16 requires a trailing comma inside `.{...}` even when only one
    // field is present; we always emit `.{...,}` for single-arg interpolation.
    // `name` is UNANNOTATED (`let name = "zag"` has no `: T`), so its type is
    // not statically known — the interpolation wraps it in `__zag_auto_fmt`
    // (with `{f}` spec, the runtime-comptime string-vs-{any} dispatch) instead
    // of the pre-gap byte-list `{any}` emit.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"hello, {f}\\n\", .{__zag_auto_fmt(name),})") != null);
}

test "codegen: template preserves LF byte in literal via \\n escape" {
    // zag user wrote literal newline byte inside the string (inside "").
    // The format string in codegen must escape it to \\n so the zig string
    // literal remains valid.
    const src = "fun f() {\n    let x = \"a\";\n    print(\"a{x}a\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // `x` is unannotated → type unknown → auto-fmt wrap (`{f}` spec) around
    // the byte-escape-preserving format string.
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"a{f}a\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"a{f}a\\n\", .{__zag_auto_fmt(x),})") != null);}


test "codegen: print(call returning str) wraps in __zag_auto_fmt" {
    // Gap closure: `fun get_name() -> str` + `print(get_name())` — the
    // arg is a `.call` whose return type codegen does NOT statically
    // resolve (no typed-binding lookup fires for call exprs). Pre-gap
    // this emitted `{any}` → the returned `[]const u8` printed as a byte
    // list `{ 103, 114, 101, 101, 116 }`. Now the unknown-typed arg
    // wraps in `__zag_auto_fmt(...)` with `{f}` spec — the wrapper's
    // format() comptime-checks the VALUE's runtime type and prints the
    // slice as text.
    const src =
        \\fun get_name() -> str {
        \\    return "greet";
        \\}
        \\fun f() {
        \\    print(get_name());
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{f}\", .{__zag_auto_fmt(get_name()),})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{any}\", .{get_name(),})") == null);
}

test "codegen: template interpolation of call result wraps in __zag_auto_fmt" {
    // Template-literal analogue: `print("name: {get_name()}")` — the
    // interpolated payload carries the call text `get_name()` which is
    // NOT a typed binding, so typeAwareFmtSpec reports the type as
    // unknown and the interpolation slot wraps it in `__zag_auto_fmt`
    // with the `{f}` spec.
    const src = "fun get_name() -> str {\n    return \"greet\";\n}\nfun f() {\n    print(\"name: {get_name()}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"name: {f}\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_auto_fmt(get_name())") != null);
}

test "codegen: template interpolation of binary expr wraps in __zag_auto_fmt" {
    // `{a + b}` interpolation — the payload is the raw text ident
    // `a + b` (buildTemplate stores the inner text verbatim), so no
    // typed-binding resolution fires; the auto-fmt wrap keeps the
    // byte-`{any}` fallback identical for numeric operands while
    // enabling string concat (`str + str`) to print as text.
    const src = "fun f() {\n    let a: i32 = 1;\n    let b: i32 = 2;\n    print(\"sum: {a + b}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"sum: {f}\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_auto_fmt(a + b)") != null);
}

test "codegen: print(call returning ?str) wraps optional in __zag_auto_fmt" {
    // `let maybe = maybe_name(); print(maybe)` where the callee returns
    // `?str` — a `.call` shape, so no static type resolution fires (the
    // ident isn't a typed binding). The auto-fmt wrapper handles the
    // optional at runtime: text payload via writeAll, "" for null.
    const src =
        \\fun maybe_name() -> ?str {
        \\    return null;
        \\}
        \\fun f() {
        \\    print(maybe_name());
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{f}\", .{__zag_auto_fmt(maybe_name()),})") != null);
}

test "codegen: binary emission is parenthesised" {
    // The generated zigzag source must wrap binary expressions in `()` so
    // downstream zig's natural precedence rules cannot reorder the AST's
    // intent (relevant once we add lower-precedence operators).
    const src = "fun f() {\n    let z: i32 = 1 + 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + 2);") != null);
}

test "codegen: precedenced arithmetic emits nested parens" {
    // 1 + 2 * 3 must surface as `1 + (2 * 3)` in generated zigzag source so
    // zig observes the AST's chosen ruling under standard math precedence.
    const src = "fun f() {\n    let z: i32 = 1 + 2 * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + (2 * 3));") != null);
}

test "codegen: method-call {obj.f()} emits verbatim obj.f() in args tuple" {
    // Unblocked-pattern pin for the matching-brace gate. The pre-fix
    // char-class gate bailed on `.` and `(` (both non-alphanumeric, not
    // `_`/`:`) so the gate returned false. The new gate accepts these
    // because it only rejects a NESTED `{` — the inner `f()` has no
    // braces (only parens, which the gate accepts). buildTemplate
    // stores the inner text `obj.f()` as the `.ident` payload, and the
    // genExpr `.ident` arm at src/codegen/expr.zig:147-149 emits it
    // verbatim. So `obj.f()` surfaces in the generated zig as a valid
    // method-call expression at the format-arg site. This is the second
    // load-bearing assumption the test pins (after `{a + b}` above):
    // if the `.ident` arm ever wraps the text in `(blk: { ... })` /
    // `try obj.f()` / etc., `{obj.f()}` would silently break. Since
    // the interpolation type is unknown (`obj.f()` isn't a typed
    // binding), the auto-fmt wrap (`__zag_auto_fmt(obj.f())`) is now
    // applied around it — `obj.f()` still appears verbatim INSIDE the
    // wrapper, so the verbatim-emit contract is preserved.
    const src = "fun f() {\n    let obj: i32 = 42;\n    print(\"got {obj.f()}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Format string half: `{f}` (auto-fmt dispatch spec — no `:`).
    try std.testing.expect(std.mem.indexOf(u8, zig, "{f}") != null);
    // Args tuple half: `obj.f()` appears verbatim (inside the auto-fmt
    // wrapper) in the args list. A regression that wrapped it in a
    // try-block or labeled-blk (e.g. `, .{try obj.f(),}` or
    // `, .{(blk: { return obj.f(); }),}`) would surface here.
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{__zag_auto_fmt(obj.f()),})") != null);
    // Sanity: the inner `f()` parens don't surface as a separate token
    // group (which would happen if codegen split on `(` first). The full
    // text `obj.f()` is one contiguous substring in the args list.
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{obj., .f(),})") == null);
}

test "codegen: x/2 emits @divTrunc shim when LHS is runtime int" {
    // The pattern from the failing smoke test: `x /= 2` desugars to
    // `x = x / 2;` where LHS is an `.ident` (runtime int) and RHS is a
    // comptime `.int_lit`. zig 0.16 demands `@divTrunc(x, 2)` here because
    // the result type of `i32 / comptime_int` isn't decidable.
    const src = "fun f() {\n    var x: i32 = 10;\n    x = x / 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(x, 2)") != null);
    // Sanity: the bare `(x / 2)` form must NOT appear in the assignment RHS.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x / 2)") == null);
}

test "codegen: x%2 emits @rem shim when LHS is runtime int" {
    // Mirror of the `.div` test: `x %= 2` desugars to `x = x % 2;` and
    // codegen routes the RHS through `@rem(x, 2)`.
    const src = "fun f() {\n    var x: i32 = 10;\n    x = x % 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(x, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x % 2)") == null);
}

test "codegen: 1/2 stays bare when both sides are comptime int" {
    // The "floored/comptime cases can stay bare" carve-out: `1 / 2` is
    // pure comptime; zig folds the bare `(1 / 2)` form to `0` at compile
    // time, so we don't need to wrap in `@divTrunc`. Preserves the user's
    // source round-trip in the generated zigzag.
    const src = "fun f() {\n    let z: i32 = 1 / 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: i32 = 1 / 2` annotation through to
    // zig; the carve-out keeps bare-form legal too, so the test stays
    // source-shape stable here.
    if (std.mem.indexOf(u8, zig, "    const z: i32 = (1 / 2);") == null) {
        var si: usize = 0;
        while (si < zig.len) {
            if (zig[si] == '\n') std.debug.print("\n", .{}) else std.debug.print("{c}", .{zig[si]});
            si += 1;
        }
        std.debug.print("\n", .{});
    }
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 / 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@divTrunc") == null);
}

test "codegen: 1.0/2.0 stays bare when LHS is float" {
    // Both LHS and RHS are float literals — the RHS is NOT `.int_lit`, so
    // `needsIntDivShim` short-circuits on its `b.rhs.* != .int_lit` guard
    // and the bare `(/)` form is preserved. `@divTrunc` would be invalid
    // here because it requires integer arguments.
    const src = "fun f() {\n    let z: f64 = 1.0 / 2.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: f64 = 1.0 / 2.0` annotation through.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: f64 = (1.0 / 2.0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@rem") == null);
}

test "codegen: 2/x stays bare when LHS is comptime int and RHS is ident" {
    // Defensive pin on the predicate's `b.rhs.* != .int_lit` fast path:
    // when RHS is an `.ident` (not an int literal) the shim short-circuits,
    // even though LHS is comptime-int. This is the mirror image of the
    // main shim trigger case.
    const src = "fun f() {\n    let z: i32 = 2 / x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Source includes the `: i32` annotation — preserve it in the
    // assertion to track the actual emission.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (2 / x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@divTrunc") == null);
}

test "codegen: 1.0/x stays bare when LHS is float and RHS is ident" {
    // Defensive pin on the mixed-comptimes case: `exprContainsFloat`
    // returns true because LHS IS a `.float_lit`, so even though RHS is
    // not an int literal we'd see a `false` from the predicate via a
    // different guard. Verifies the bare form is preserved.
    const src = "fun f() {\n    let z: f64 = 1.0 / x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: f64 = 1.0 / x` annotation through to
    // zig; codegen forwards `: T` on the binding so the assertion tracks
    // the actual emission shape (the test stays bare-form-agnostic —
    // `1.0` is float and `x` is unannotated, neither path can ever
    // trigger the `@divTrunc` shim).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: f64 = (1.0 / x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@rem") == null);
}

test "codegen: f64-typed ident LHS / int_lit stays bare (typed-binding lookup)" {
    // The targeted hole: `let pi: f64 = 3.14; pi / 2` — LHS is `.ident "pi"`
    // so `exprContainsFloat` returns false on the LHS subtree (no
    // `.float_lit` node), but the binding is annotated `f64`. Without the
    // `collectTypedBindings` map, `needsIntDivShim` would fire and emit
    // `@divTrunc(pi, 2)`, which zig 0.16 rejects because `@divTrunc`
    // requires integer args. The fix maps `pi → f64` and the predicate's
    // `self.isFloatIdentType(...)` short-circuit returns false, leaving
    // the bare `(pi / 2)` form. zig infers the operand types from the
    // const-binding annotation and accepts the result.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r: f64 = pi / 2;
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
    // Bare form preserved; no shim wrap.
    // Source includes the `: f64` annotation — mirror it in the assertion
    // so the test tracks the actual emission.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r: f64 = (pi / 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@rem") == null);
}

test "codegen: i32-typed ident LHS / int_lit still triggers @divTrunc shim" {
    // The non-regression pin: when the LHS ident is annotated with an
    // INTEGER type (f16/f32/f64 absent from the map), the predicate still
    // fires and the shim is emitted. Without this guard the per-function
    // map could over-broadly skip the shim and break `let x: i32 = 10;
    // x / 2;` codegen.
    const src =
        \\fun f() {
        \\    let n: i32 = 10;
        \\    let z: i32 = n / 2;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(n, 2)") != null);
    // Source includes `: i32` annotation; codegen shim path replaces
    // `(n / 2)` with `@divTrunc(n, 2)` so the literal bare form does
    // NOT survive.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (n / 2);") == null);
}

test "codegen: f64-typed ident LHS % int_lit stays bare" {
    // Mirror of the `/` case for the `.mod` operator: `let pi: f64 = 3.14;
    // pi % 2` must emit the bare form because `@rem` requires integer args.
    // The `isFloatIdentType` map check applies symmetrically to `.mod`.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r: f64 = pi % 2;
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
    // Source includes `: f64` annotation; codegen routes the bare form
    // through (mirror of the `/` test).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r: f64 = (pi % 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@rem") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig[std.mem.indexOf(u8, zig, "pub fn f") orelse 0 ..], "@divTrunc") == null);
}

test "codegen: unannotated i32-init binding / int_lit still triggers @divTrunc" {
    // DELETED: the static-typed-coercion carve-out now requires `: T`
    // annotations on EVERY bare binding whose RHS is a non-literal
    // expression. The original test source `let x = 10; let z = x / 2;`
    // no longer parses (it surfaces "let requires an explicit type
    // annotation when binding non-tuple values"). The semantic intent
    // — verifying that the shim still fires when the LHS maps to an
    // integer type — is now exercised by the
    // `i32-typed ident LHS / int_lit still triggers @divTrunc shim` test
    // directly above, which carries the `: i32` annotation on both
    // bindings and asserts the same shim path. No regression introduced
    // — the typed-binding map's "integer → shim fires" code path is
    // still covered.
}

test "codegen: as cast emits @as builtin" {
    // The parser's `collectCastType` joined multi-token types like
    // `*raw c_void` into one `type_text` slice; codegen emits
    // `@as(type_text, expr)` so zig's `@as` builtin handles the cast
    // surface natively (pointers, numerics, raw pointers). zig 0.16
    // dropped the `as` operator entirely (verified empirically:
    // `pi as f32` produces `expected ';'` and `(pi as f32)` produces
    // `expected ')'`, while `@as(f32, pi)` parses cleanly) so this
    // matches the post-deprecation cast shape that zig natively accepts.
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y: i32 = @as(i32, x);") != null);
}

test "codegen: member_access emits target.name verbatim" {
    // `v.x` → `v.x`. Zig's struct-field access syntax matches zag's
    // surface verbatim, so codegen is a one-line passthrough. This test
    // makes the user-facing property obvious: any struct-typed `v` whose
    // zig-declared struct has field `.x` round-trips without
    // transformation.
    const src = "fun f() {\n    let a: f64 = v.x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= v.x;") != null);
}

test "codegen: method_call emits target.name(args) verbatim" {
    // `v.length()` and `Vec3.new(1.0, 2.0, 3.0)` both emit verbatim —
    // zig natively distinguishes value-receiver and type-static forms.
    // The simpler receiver form `v.length()` shows up as
    // `    const len: f64 = v.length();`-style emission.
    const src = "fun f() {\n    let len: f64 = v.length();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const len: f64 = v.length();") != null);
}

test "codegen: member call on union value dispatches to orphan free fn" {
    // `hover.is_action()` — union impl methods flatten to module-scope
    // free fns (`ClickEvent_is_action`) because zig 0.16 rejects
    // methods nested inside `union(enum)` (the orphan-impl loop in
    // generate()), so the member call must rewrite to the orphan fn
    // with the receiver as the first argument. The receiver is a VALUE
    // binding (`hover: ClickEvent`) and the impl receiver is a value
    // param (`e: ClickEvent`) — passed verbatim, no `&`.
    const src =
        \\union ClickEvent {
        \\    Hover,
        \\    Press(i32),
        \\}
        \\
        \\impl ClickEvent {
        \\    pub fun is_action(e: ClickEvent) -> bool {
        \\        return false;
        \\    }
        \\}
        \\
        \\fun f() {
        \\    let hover: ClickEvent = ClickEvent.Hover;
        \\    let b: bool = hover.is_action();
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "ClickEvent_is_action(hover)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "hover.is_action()") == null);
}

test "codegen: qualified union method call dispatches to orphan free fn" {
    // `ClickEvent.is_action(hover)` — the qualified static form routes
    // to the same orphan free fn, with the args passed verbatim (no
    // synthetic receiver). Previously emitted verbatim and rejected by
    // zig (`union 'ClickEvent' has no member named 'is_action'`,
    // surfaced by examples/types/union_demo.zag).
    const src =
        \\union ClickEvent {
        \\    Hover,
        \\    Press(i32),
        \\}
        \\
        \\impl ClickEvent {
        \\    pub fun is_action(e: ClickEvent) -> bool {
        \\        return false;
        \\    }
        \\}
        \\
        \\fun f() {
        \\    let hover: ClickEvent = ClickEvent.Hover;
        \\    let b: bool = ClickEvent.is_action(hover);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "ClickEvent_is_action(hover)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "ClickEvent.is_action(hover)") == null);
}

test "codegen: union member call with pointer receiver adds address-of" {
    // `jv.get("k")` where the impl receiver is a pointer
    // (`get(self: *Json, key: str)`) and the binding is a value
    // (`jv: Json`) — the orphan dispatch passes `&jv` (mirroring zig's
    // own method-call sugar: `jv.get(...)` auto-addresses a `*self`
    // method). Same-module union, so no @import prefix.
    const src =
        \\union Json {
        \\    Null,
        \\    Str(str),
        \\}
        \\
        \\impl Json {
        \\    pub fun get(self: *Json, key: str) -> bool {
        \\        return false;
        \\    }
        \\}
        \\
        \\fun f() {
        \\    let jv: Json = Json.Null;
        \\    let b: bool = jv.get("k");
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
    // `jv` is a const binding, so `&jv` would be `*const Json` — the
    // dispatch wraps the address in @constCast (no-op on mutable
    // bindings, required for const captures) so the `*Json` orphan
    // receiver accepts it.
    try std.testing.expect(std.mem.indexOf(u8, zig, "Json_get(@constCast(&jv), \"k\")") != null);
}

test "codegen: union KNOWN table pins stdlib Json routing" {
    // KNOWN-table sync guard (review): the union-dispatch tables in
    // core.zig must not silently drift from lib/std. `Json` resolves
    // to the materialized std/json.zig module, and `get` is the one
    // stdlib union method with a pointer receiver. A fresh Codegen
    // (no prog decls, no source_path) consults the tables directly.
    var cg = codegen_mod.Codegen.init();
    try std.testing.expect(std.mem.eql(u8, cg.unionModulePath("Json") orelse "", "std/json.zig"));
    try std.testing.expect(cg.unionModulePath("NotAUnion") == null);
    try std.testing.expect(cg.unionMethodReceiverIsPointer("Json", "get") == true);
    try std.testing.expect(cg.unionMethodReceiverIsPointer("Json", "stringify") == null);
    try std.testing.expect(cg.unionMethodReceiverIsPointer("NotAUnion", "get") == null);
}

test "codegen: local struct named like stdlib union is NOT hijacked" {
    // Shadowing guard (review): a user module declaring its own
    // `struct Json` must win over the KNOWN stdlib-union table — a
    // local struct's methods stay nested and dispatch natively, so
    // `Json.get(jv)` must emit VERBATIM, not rewrite to
    // `@import("std/json.zig").Json_get(jv)`. The pre-fix ordering
    // (KNOWN table consulted before prog.structs) hijacked local
    // types sharing a stdlib union name.
    const src =
        \\struct Json {
        \\    value: str,
        \\}
        \\
        \\impl Json {
        \\    pub fun get(self: *Json, key: str) -> bool {
        \\        return false;
        \\    }
        \\}
        \\
        \\fun f() {
        \\    let b: bool = Json.get(jv);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "Json.get(jv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Json_get(") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std/json.zig") == null);
}

test "codegen: turbofish Result capture seeds union member dispatch" {
    // Turbofish-scrutinee guard (review): `parsed: Result<Json, str>`
    // uses the angle-bracket spelling. getSourceTypeName returns the
    // VERBATIM source annotation, so preambleVariantPayloadType must
    // accept both `Result(...)` and `Result<...>` forms — otherwise
    // the `Ok(v)` capture stays unseeded and `v.get("k")` falls back
    // to verbatim (broken emission for a union payload).
    const src =
        \\union Json {
        \\    Null,
        \\    Str(str),
        \\}
        \\
        \\impl Json {
        \\    pub fun get(self: *Json, key: str) -> bool {
        \\        return false;
        \\    }
        \\}
        \\
        \\fun f() {
        \\    let parsed: Result<Json, str> = Ok(Json.Null);
        \\    if let Ok(v) = parsed {
        \\        let b: bool = v.get("k");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "Json_get(@constCast(&v), \"k\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "v.get(\"k\")") == null);
}

test "codegen: field_assign emits target.field = value;" {
    // `v.x = 10.0;` → `    v.x = 10.0;`. Zig accepts field-write to a
    // `var`-binding receiver verbatim; writing to a `const`-recevier is
    // rejected by zig at compile time, mirroring zag's binding-kind
    // semantics.
    const src = "fun f() {\n    v.x = 10.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    v.x = 10.0;") != null);
}

test "codegen: closure-literal |x: str| -> str expands str in pub fn call(...)" {
    // alias-resolution site: genExpr .closure arm (params + return).
    // The closure emit is `(struct { pub fn call(arg: T) RET { ... } }){}`
    // — without zagTypeToZig wrapping the param's type_text AND the
    // closure's return_type, zig rejects with `unknown type name 'str'`
    // at the anonymous-struct-of-str field-position.
    const src = "fun f() {\n    let g = |x: str| -> str { return x; };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Phase 2 (zig 0.16 closure-as-method dispatch): the `call` method
    // now carries `_:` as a self-shaped but unused first parameter so
    // zig recognizes it as a member function bound to the struct
    // instance (otherwise `instance.call(...)` dispatch fails with
    // `no field or member function named 'call'`). The fix prepends
    // `_: @This()` to the closure-literal's signature emit in
    // src/codegen/expr.zig's `.closure` arm.
    try std.testing.expect(std.mem.indexOf(u8, zig, "(struct { pub fn call(_: @This(), x: []const u8) []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(struct { pub fn call(x: str") == null);
}

test "codegen: closure emit shapes anonymous struct with call method" {
    const src = "fun main() {\n    let double = |x: i32| -> i32 { return x * 2; };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Phase 2 (zig 0.16 closure-as-method dispatch): same `_:` prepend
    // as the closure-literal test above.
    try std.testing.expect(std.mem.indexOf(u8, zig, "(struct { pub fn call(_: @This(), x: i32) i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return (x * 2);") != null);
}test "codegen: closure-typed call site rewrites double(5) to double.call(5)" {
	const src = "fun main() {\n    let double = |x: i32| -> i32 { return x * 2; };\n    let result = double(5);\n    print(\"{result}\\n\");\n}\n";
	var l = lexer_mod.Lexer.init(src);
	const tokens = l.tokenize();
	var arena = ast.Arena.init();
	var p = parser_mod.Parser.init(tokens, &arena);
	const prog = p.parse();
	var cg = codegen_mod.Codegen.init();
	const zig = cg.generate(prog);
	try std.testing.expect(std.mem.indexOf(u8, zig, "double.call(5)") != null);
	try std.testing.expect(std.mem.indexOf(u8, zig, "double(5)") == null);
}

test "codegen: print(self.byte_slice_field) widens to {s} on impl-block member_access" {
	// v1.6 byte-slice widening, gap-closure over gap #6 .ident-only
	// widening (per codegen/primary.zig's typeAwareFmtSpecFromExpr
	// helper). The pre-fix emit `__zag_print("{any}", .{self.label,})`
	// round-tripped as a byte-element list `{ 104, 101, ... }` at
	// runtime, breaking `examples/traits/canonical_with.zag`'s
	// expected stdout. The widening now fires because the receiver
	// (struct Button via `current_receiver_struct_name` setter on
	// impl-block method entry) has a `label: str` field whose
	// `zagTypeToZig` rewrite contains `[]const u8`.
	//
	// Positive pin: the format spec widens to `{s}`, the args tuple
	// preserves `self.label` as the bare ident (no `blk: { ... }`
	// wrap, no manual `.? orelse ""` -- non-optional byte-slice).
	//
	// Negative pin: `{any}` for byte-slice fields must NOT appear
	// (would be the pre-fix regression). A future rework that
	// silently flips back to `{any}` would surface as a substring
	// match here, protecting the v1.6 contract.
	//
	// MIRRORS `tests/runtime_smoke.zig`'s canonical_with case --
	// the runtime-level pin is at the canonical_with binary's
	// stdout; this unit-level pin is at the codegen-emit shape.
	// Both are required: runtime protects end-to-end correctness,
	// codegen protects future-refactor safety.
	const src =
		\\struct Button { label: str, }
		\\impl Button {
		\\    pub fun show(self: *Button) {
		\\        print(self.label);
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
	try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{s}\", .{self.label,})") != null);
	try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{any}\", .{self.label,})") == null);
}

test "codegen: print(self.i32_field) stays at {any} on impl-block member_access" {
	// Negative counterpart: when the field's type is NOT a byte-slice
	// family (i32 in this case), the widening must NOT fire. This
	// protects against false-positive widenings in impl-block
	// methods where `print(self.x)` could silently flip from
	// `{any}` to `{s}` (and zig would reject `i32` against the
	// strictly-typed `{s}` formatter).
	const src =
		\\struct Box { count: i32, }
		\\impl Box {
		\\    pub fun show(self: *Box) {
		\\        print(self.count);
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
	try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{any}\", .{self.count,})") != null);
	try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{s}\", .{self.count,})") == null);
}

test "codegen: print(label) for non-method body stays at {any}" {
	// Cross-fn leak guard: after an impl-block method body emit
	// ends, `current_receiver_struct_name` is reset to null so a
	// subsequent top-level `pub fun` declaration does NOT inherit
	// the prior impl's receiver. The `label` ident here would
	// resolve as a free binding with no struct context, so it is
	// NOT widened to `{s}` — as an unknown-typed arg it routes
	// through the auto-fmt wrap (`{f}` + `__zag_auto_fmt(label)`)
	// instead. This test pins the genFun body-entry reset path.
	const src =
		\\struct Box { label: str, }
		\\impl Box {
		\\    pub fun show(self: *Box) {
		\\        print(self.label);
		\\    }
		\\}
		\\fun main() {
		\\    print(label);
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
	// First, the impl-block pattern DOES widen (positive pin from
	// the previous test, reproduced inline for context here):
	try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{s}\", .{self.label,})") != null);
	// Second, the top-level `print(label)` line does NOT widen to
	// `{s}` — no current-receiver context carries over into main.
	// As an unknown-typed arg it wraps in `__zag_auto_fmt` (with
	// `{f}` spec). We pin that exact shape:
	try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"{f}\", .{__zag_auto_fmt(label),})") != null);
}

test "codegen: ? postfix try-operator unwraps Result with label-block" {
    // Using ? after an expression should emit a labeled block
    // with @hasField discriminator for Result (Ok/Err).
    const src =
        \\fun helper() -> Result<i32, str> {
        \\    return Ok(5);
        \\}
        \\fun f() -> Result<i32, str> {
        \\    let x: i32 = helper()?;
        \\    return Ok(x);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The ? emits a blk label with @hasField discriminator
    try std.testing.expect(std.mem.indexOf(u8, zig, "@hasField(@TypeOf(__try), \"Ok\")") != null);
    // On Ok, break with unwrapped value (label is __blk_N)
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Ok => |__v| break :__blk_") != null);
    // On Err, return the error
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Err => |__e| return") != null);
}

test "codegen: catch expression emits fallback with @hasField discriminator" {
    const src =
        \\fun helper() -> Result<i32, str> {
        \\    return Err("fail");
        \\}
        \\fun f() -> i32 {
        \\    return helper() catch 0;
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // catch emits @hasField discriminator
    try std.testing.expect(std.mem.indexOf(u8, zig, "@hasField(@TypeOf(__cgt), \"Ok\")") != null);
    // On Ok, break with unwrapped value (label is __blk_N)
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Ok => |__v| break :__blk_") != null);
    // On Err, break with the handler value (fallback) — label is __blk_N
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :__blk_") != null);
}

test "codegen: catch with error binding emits err variable in handler" {
    const src =
        \\fun helper() -> Result<i32, str> {
        \\    return Err("fail");
        \\}
        \\fun f() -> i32 {
        \\    return helper() catch |msg| 0;
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // err_binding |msg| should appear in the Err arm
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Err => |msg|") != null);
}

test "codegen: block expression emits labeled blk with break :blk" {
    const src =
        \\fun f() -> i32 {
        \\    return { let x: i32 = 5; x };
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Block expression emits labeled block
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: {") != null);
    // Last expression broken with :blk
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk") != null);
}

test "codegen: catch with block handler emits break :blk for handler body" {
    // catch |err| { stmts } should work with a block body.
    // The block handler emits a labeled blk + break :blk.
    const src =
        \\fun helper() -> Result<i32, str> {
        \\    return Err("fail");
        \\}
        \\fun f() -> i32 {
        \\    return helper() catch |msg| {
        \\        let result: i32 = 0;
        \\        result
        \\    };
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // catch with block handler: the handler should contain a labeled block
    try std.testing.expect(std.mem.indexOf(u8, zig, ".Err => |msg| break :__blk_") != null);
}

