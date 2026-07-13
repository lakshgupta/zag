// ============================================================
// Phase 0 codegen-router pin tests (src/codegen/builtins.zig + the
// .call / .method_call arms in src/codegen/expr.zig + genBuiltinCall
// helper + per-function argv_counter resets in decl.zig). Each test
// pins a separate surface so a future regression at one site fails
// only the relevant test (surgical diagnostic).
//
// Phase 0 ships with builtin_table populated with ONE entry: argv_get
// (selective-import form `pub import std.argv.{get}` surfaces as a
// bare `get(...)` call). The first two tests pin the no-op passthrough
// for non-builtin names; the third pins the full argv_get emit shape
// (blk wrapper + std.os.argv walk + 32-cap array + __argv_0 temp).
// ============================================================

test "codegen: builtin router preserves non-builtin call verbatim" {
    // Regression pin on the `.call` arm's per-dispatch fallback: when
    // the callee name does NOT appear in builtin_table, codegen must
    // emit the user's call shape verbatim. Without the router-aware
    // .call arm, this test would fail (no fallback path). With it,
    // the verbatim `myhelper(1, 2, 3)` shape is preserved.
    const src = "fun f() {\n    let x = myhelper(1, 2, 3);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "myhelper(1, 2, 3)") != null);
}

test "codegen: builtin router does NOT fire on user helpers with builtin-like names" {
    // Defensive pin: a user-defined helper named `process` (which is
    // also a potential Phase 2 `std.process` entry) must not trigger
    // the router. argv_get is the only Phase 0 entry; any other name
    // falls through to the verbatim fallback. This guards against an
    // over-broad match that would corrupt unrelated call sites when
    // a future Phase adds more entries.
    const src = "fun f() {\n    let r = process(data);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "process(data)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.os.argv") == null);
}

test "codegen: argv_get builtin emits per-call blk + std.os.argv walk" {
    // End-to-end pin on the argv_get dispatch path. The router fires
    // when `c.name == "get"` and `c.args.len == 0` (builtin's
    // arity-wildcard match in `lookup`). genBuiltinCall emits:
    //
    //     blk: {
    //         var __argv_0: [32][]const u8 = undefined;
    //         var __argv_0_n: usize = 0;
    //         for (std.os.argv, 0..) |a, i| {
    //             if (i >= 32) break;
    //             __argv_0[i] = std.mem.span(a orelse "");
    //             __argv_0_n = i + 1;
    //         }
    //         break :blk __argv_0[0..__argv_0_n];
    //     }
    //
    // Each substring below pins a distinct emit shape required by
    // std.os.argv's stack-allocated capture + span handling.
    const src = "fun f() {\n    let args: []const []const u8 = get();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "blk: {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[32][]const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.os.argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__argv_0[0..__argv_0_n]") != null);
    // std.os.argv's Linux element type is `[*:0]const u8` (non-
    // optional sentinel-terminated pointer). span() coerces it to
    // `[]const u8` directly — NO `orelse ""` unwrap (would have
    // hard-errored on non-optional types and silently inverted the
    // goal of the surface). Pin the explicit `std.mem.span(a)`
    // substring so any future regression that re-adds the orelse
    // is caught at build/test time.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.mem.span(a)") != null);
    // Sanity: the orelse-arg fallback must NOT appear (portability
    // footgun — non-optional types reject `orelse` at compile time).
    try std.testing.expect(std.mem.indexOf(u8, zig, "orelse") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= get()") == null);
}

test "codegen: argv_get counter increments across multiple calls in the same body" {
    // The per-function argv_counter ensures two argv_get calls in the
    // same body produce distinct __argv_<N> names (zig's no-
    // redeclaration rule would reject a clash). Confirm the steps
    // 0 -> 1 across two consecutive call sites.
    const src = "fun f() {\n    let a = get();\n    let b = get();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__argv_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__argv_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__argv_2") == null);
}

test "codegen: argv_counter resets across sibling pub fn boundaries" {
    // Sibling pub fn bodies each start fresh at __argv_0 (the
    // per-function counter resets in genFun entrance). Without the
    // reset, two sibling fns using argv_get would share same-names
    // and zig's module-level redecl-check would reject the
    // collision (the temps are nested inside per-fn blk scopes so
    // this only manifests if the temps escape to module scope, but
    // the reset is the documented contract).
    const src =
        \\fun g() {
        \\    let x = get();
        \\}
        \\fun h() {
        \\    let y = get();
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
    const argv_0_count = std.mem.count(u8, zig, "__argv_0");
    const argv_1_count = std.mem.count(u8, zig, "__argv_1");
    try std.testing.expect(argv_0_count >= 2);
    try std.testing.expect(argv_1_count <= 1);
}
