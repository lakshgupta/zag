// Source-mirror test bucket for src/builtins.zig.zig.
// Tests here pin the builtins-codegen's surface. Routing is by test-name
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


test "codegen: print(<str>, val1, val2) emits multi-arg __zag_print" {
    // Multi-arg print shape: codegen routes print(<str>, val1, val2, ...) through
    // genPrintCall's multi-arg arm (c.args.len >= 2). The zig emit is:
    //   __zag_print("<str>", .{val1, val2, ...,})
    // - first-arg-as-format-string, remaining args as the args tuple, with a
    // trailing comma inside the anonymous-struct literal (zig 0.16 single-field
    // `.{x}` requirement, mirroring the .template_lit single-arg arm).
    //
    // Pre-fix this multi-arg surface was only documented in the codegen docblock;
    // no positive-substring pin test existed. A future regression on the trailing
    // comma placement, the first-arg-as-format-string contract, or the N-args tuple
    // shape would fail this pin test loudly.
    //
    // The zag source `print("a", x, y)` round-trips to the canonical zig
    // `__zag_print("a", .{x, y,})` (verbatim first-arg, comma-separated remaining
    // args, trailing comma inside .{x, y,}).
    const src = "fun f() {\n    let x: i32 = 0;\n    let y: i32 = 0;\n    print(\"a\", x, y);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"a\", .{x, y,})") != null);
}

test "codegen: print() zero-args emits __zag_print with empty format string" {
    // Per `genPrintCall`'s `if (c.args.len == 0)` arm: bare `print()` codegens
    // to `__zag_print("", .{})` (empty format string + empty args tuple).
    // The no-args case does NOT emit a trailing comma inside `.{}` (zig 0.16
    // is happy with no-comma for zero-field args tuples), so the precise
    // `.{})` (no comma) shape is the unique fingerprint of this arm. The
    // codegen deliberately maps the zero-arity `print()` to the args-less
    // __zag_print shape rather than a special-case zig builtin — closes
    // the §3.1 Phase-3 audit gap on trivial formatting.
    const src = "fun main() {\n    print();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    // Tight pin: the literal `__zag_print("", .{})` substring (note the
    // TWO ADJACENT quote bytes — empty string — and the LACK of trailing
    // comma inside `.{})`) uniquely identifies the `c.args.len == 0` arm.
    // The `c.args.len >= 1` arms either include a string body (single-arg)
    // or a trailing comma when args present (multi-arg); only this arm
    // emits both markers together.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "__zag_print(\"\", .{})") != null);
}

test "codegen: new T(v) emits page_allocator.create heap alloc (bug fix)" {
    // The docs/spec contract for `new` is heap allocation. The previous
    // emission `blk: { var __val: T = v; break :blk &__val; }` was a
    // stack-pointer escape (UB on `free`). The rewrite routes through
    // `try std.heap.page_allocator.create(T)` so `free(p)`'s matching
    // `page_allocator.destroy(p)` correctly deallocates the heap cell.
    //
    // The current emit for `let p = new i32(42)` is:
    //   const p = blk: { const __p_0 = try std.heap.page_allocator.create(i32);
    //                     __p_0.* = 42; break :blk __p_0; };
    // (Pre-existing test asserted `const p = __p_0` — a bare-assignment
    // shape that was true before the docs/19-memory.md heap rewrite; the
    // rewrite uses the blk-wrapped form so we can still reference `__p_0`
    // after the assignment without zig's no-redeclaration trouble.)
    const src = "fun f() {\n    let p = new i32(42);\n    defer free(p);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __p_0") != null);
    // The page_allocator.destroy(p) — for the matching free(p) below.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy") != null);
    // Sanity: the OLD stack-pointer emission must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __val: i32 = 42") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "&__val") == null);
}

test "codegen: new(<arena>, T(v)) emits <arena>.create(T) (allocator sugar)" {
    // Pattern 3 sugar: codegen routes through the user-supplied allocator's
    // `create` method rather than the global page allocator.
    const src = "fun f() {\n    let p = new(arena, i32(0));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try arena.create(i32)") != null);
    // Sanity: must NOT use the global page allocator.
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.create") == null);
}

test "codegen: alloc_counter increments across multiple new exprs" {
    // Two `new` expressions in the same body must produce distinct `__p_<N>`
    // names so zig's no-redeclaration rule is satisfied. The codegen uses a
    // single per-function `alloc_counter` (reset at `genFun`) that increments
    // per `new_expr` visit in `genExpr`, so two bindings surface distinct
    // `__p_0` and `__p_1`. Each `__p_<N>` is also internal to its own
    // `blk: { … }` scope — the counter step is the simpler invariant that
    // satisfies both flat scopes and nested blk scopes (the latter tolerate
    // same-name shadowing but the counter keeps emissions human-comparable).
    const src =
        \\fun f() {
        \\    let a = new i32(1);
        \\    let b = new i32(2);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_1.* = 2") != null);
}

test "codegen: free of []u8 ident emits page_allocator.free (slice overload)" {
    // Phase 2.1 closure: `let s: []u8 = read_file("path"); defer free s;`
    // must surface as `defer std.heap.page_allocator.free(s);` instead of
    // `destroy(s)`. The discriminator consults `type_info_buf` (populated
    // by collectTypedBindings at fn entry); the leading `[]` in the source
    // type annotation routes the free site to the slice overload.
    //
    // The RHS uses `read_file(...)` because (a) it's the canonical
    // Phase 2 surface this Phase 2.1 widening was designed for, and
    // (b) its emit shape (`blk: { ... break :blk __fs_<N>; }`) keeps the
    // free-discriminator's substring assertions stable.
    const src =
        \\fun f() {
        \\    let s: []u8 = read_file("path");
        \\    defer free s;
        \\}
        \\;
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the slice overload fires.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.free(s)") != null);
    // Negative: the pointer overload (destroy) must NOT appear for `s`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy(s)") == null);
}

test "codegen: free of *i32 ident still emits page_allocator.destroy (pointer regression guard)" {
    // Phase 2.1 regression guard: the existing v1 pointer-typed
    // `new T(v)` path must keep emitting `destroy`. Without this test,
    // a future Phase widening that flips the discriminator default
    // could silently switch pointer-typed frees to the slice overload
    // (calling `free(*T)` is unsafe — `free` expects a `[]u8` slice,
    // not a `*T`). Source mirrors the existing allocation.zag pattern;
    // the prior `new T(v) emits page_allocator.create heap alloc` test
    // already exercises the create side, this test pins the destroy
    // side under the Phase 2.1 widening.
    const src =
        \\fun f() {
        \\    let p = new i32(42);
        \\    defer free(p);
        \\}
        \\;
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the pointer overload fires for the unnamed `p` binding
    // (the bare `let p = new i32(42)` lacks a `: T` annotation, so
    // type_info_buf has no entry, so the discriminator falls through
    // to the pointer overload).
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy(p)") != null);
    // Negative: the slice overload must NOT appear for `p`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.free(p)") == null);
}

test "codegen: free of call expr falls back to page_allocator.destroy (non-ident target)" {
    // Phase 2.1 fall-back pin: when the free target is a `.call` (NOT a
    // bare `.ident`), the discriminator's first guard
    // `const t = f.target.*; if (t != .ident) break :blk false;` short-
    // circuits the lookup and the pointer overload fires. Without this
    // test, a future refactor that promotes non-ident operands to a
    // type-resolver pass could silently route `free read_file("p")` to
    // `page_allocator.readFileAlloc(...)` (wrong call entirely). The
    // assertion pins the conservative fall-back for the common
    // no-binding-discriminator case.
    // (The generated zig would FAIL to execute — `destroy([]u8)` is a
    // type error — but codegen tests pin the emit, not the runtime.)
    const src = "fun f() {\n    defer free 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Positive: the call-expr gets the page_allocator.destroy(<call>)
    // fall-back. The call site's outer parens + arg list make the
    // substring a stable assertion target.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy(42)") != null);
    // Sanity: the sliced-overload form must NOT appear for the call
    // target (would route through `page_allocator.free(...)` and miss
    // the call's argument emission entirely).
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.free(42)") == null);
}

test "codegen: alloc(N) emits page_allocator.alloc(u8, N) with OOM catch" {
    const src = "fun main() { let buf: []u8 = alloc(1024); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Emits page_allocator.alloc with OOM panic
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.alloc(u8, 1024)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@panic(\"OOM\")") != null);
}

test "codegen: size_of(T) emits @sizeOf(T)" {
    const src = "fun main() { let s: usize = size_of(i32); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@sizeOf(i32)") != null);
}

test "codegen: align_of(T) emits @alignOf(T)" {
    const src = "fun main() { let a: usize = align_of(f64); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@alignOf(f64)") != null);
}

test "codegen: panic(msg) emits __zag_panic_at" {
    const src = "fun main() { panic(\"boom\"); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    cg.source_path = "test.zag";
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_panic_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "test.zag") != null);
}

test "codegen: sourcemap emitted when expression has location" {
    const src = "fun main() { let x: i32 = 42; }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    cg.source_path = "src/test.zag";
    const zig = cg.generate(prog);
    // The map table should contain entries with the source path
    try std.testing.expect(std.mem.indexOf(u8, zig, "__ZagMapEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_map") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "src/test.zag") != null);
}

test "codegen: sourcemap tracks expression-level lines" {
    const src =
        \\fun main() {
        \\    let x: i32 = 1 + 2;
        \\    let y: i32 = 3 * 4;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    cg.source_path = "test.zag";
    const zig = cg.generate(prog);
    // Both let bindings should have map entries
    try std.testing.expect(std.mem.indexOf(u8, zig, "test.zag") != null);
    // The map should reference lines 2 and 3 (1-based)
    try std.testing.expect(std.mem.indexOf(u8, zig, "zag_line = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "zag_line = 3") != null);
}

test "codegen: buildMapText produces tab-separated side-file format" {
    const src =
        \\fun main() {
        \\    let x: i32 = 42;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    cg.source_path = "test.zag";
    _ = cg.generate(prog);
    cg.buildMapText();
    const map_text = cg.getMapText();
    try std.testing.expect(map_text.len > 0);
    // Tab-separated format: zig_line\tzag_line\tzag_col\tsymbol\tfile\n
    try std.testing.expect(std.mem.indexOf(u8, map_text, "\ttest.zag\n") != null);
    // Should contain a row with zag_line = 2 (the let binding is on line 2)
    try std.testing.expect(std.mem.indexOf(u8, map_text, "\t2\t") != null);
    // Symbol should be "main" (the enclosing function name)
    try std.testing.expect(std.mem.indexOf(u8, map_text, "\tmain\ttest.zag\n") != null);
}

test "codegen: String.with_capacity emits __zag_String call" {
    const src = "fun main() { let s: String = String.with_capacity(10); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_String.withCapacity") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "10") != null);
}

test "codegen: String.as_str instance method emits zig-native call" {
    const src =
        \\fun main() {
        \\    let s: String = String.with_capacity(10);
        \\    let view: str = s.as_str();
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
    // as_str() instance method should emit s.asStr()
    try std.testing.expect(std.mem.indexOf(u8, zig, ".asStr()") != null);
}

test "codegen: String type annotation maps to __zag_String" {
    const src = "fun main() { let s: String = String.with_capacity(10); }\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The type annotation `: String` should map to `: __zag_String`
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_String") != null);
    // And the initializer should call withCapacity
    try std.testing.expect(std.mem.indexOf(u8, zig, "withCapacity") != null);
}
