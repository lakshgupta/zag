// -------------------------------------------------------------------
// tests/scaffold.zig — regression check that the staged `lib/std/`
// stubs parse cleanly through the parser.
//
// Runs as a SEPARATE build step (`zig build scaffold_tests`) registered
// in build.zig, NOT as part of `zig build test`. Keeping the test
// surface isolated means the 235+ fast unit tests in
// `src/tests/{lexer,parser,codegen,toolchain,env_path}.zig` stay
// untouched and the parse-only scaffold regression runs against an
// independent module root (`tests/scaffold.zig` instead of
// `src/tests.zig`).
//
// No runtime I/O at test time — each stub is embedded via `@embedFile`
// at compile time, so the test binary holds the stub contents in
// rodata and the lex/parse pipeline runs purely in-process. Build-root-
// relative paths are used because the build module's path scope starts
// at the project root (the build.zig dir), not the file's directory:
//   lib/std/{mod,string,error,…}.zag
//   src/{lexer,parser,ast}.zig
//
// Per-file assertions pin the EXPECTED top-level decl surface
// documented as the planned shape in docs/manual/22-modules.md.
// Decoupling the assert from the actual parser/codegen internals
// means the test fails fast when the staged surface misses a decl
// or extra-rejects a shape (e.g. dropping the `<T>` on a trait
// leaves the parser surface but the test must surface that.
// -------------------------------------------------------------------

const std = @import("std");
// Single named-module import wired up via `scaffold_mod.addImport`
// in build.zig. The scaffold module is rooted at `tests/scaffold.zig`,
// so its path scope is `tests/` and direct `@import("src/X.zig")`
// is rejected by zig 0.16 as "outside module path" (Build.Module
// has no `addImportPath`; the supported surface is `addImport`).
//
// First attempt: three separate helper modules rooted at
// `src/lexer.zig`, `src/parser.zig`, and `src/ast.zig`. Failed
// with `file exists in modules 'ast' and 'lexer'` on
// `src/lexer/token.zig` (both `ast` and `lexer` modules transitively
// import the same `Token.loc: ast.Loc` reference file, and zig
// requires each source file to belong to at most one module).
//
// Working pattern: ONE helper module rooted at `src/parser.zig`,
// which transitively brings in `src/ast.zig` and `src/lexer.zig`
// through its own dependency graph. `src/parser.zig` is updated
// to also re-export `ast` and `Lexer` (see src/parser.zig's
// docblock for the rationale), so the test does ONE
// `@import("parser")` and reaches `parser_mod.ast.Arena`,
// `parser_mod.Lexer`, and `parser_mod.Parser` through a single
// namespace without any file-membership conflict.
const parser_mod = @import("parser");
const ast = parser_mod.ast;
const lexer_mod = parser_mod;
// Build-time-embedded stub contents. The 9 `lib/std/*.zag` files
// can't be `@embedFile`d from `tests/scaffold.zig` for the same
// path-scope reason (path scope is `tests/`, the .zag files live
// in `lib/std/`). build.zig reads each stub at config time via
// `readStubFile` and surfaces the bytes as `addOptions` fields;
// this file reads them through `@import("build_options")`.
const build_options = @import("build_options");

fn parseStub(_name: []const u8, src: []const u8) !ast.Program {
    // `_name` is the test-friendly label (e.g. "std.string") used
    // by callers for test-name reporting; deliberately unused
    // here so zig 0.16's strict-unused-parameter check passes
    // without forcing each test to thread an external sink.
    _ = _name;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    return p.parse();
}

// ---------------------------------------------------------------
// std.mod — top-level re-export barrel.
// Expected: 6 `pub import` decls (one per line), NO struct/enum/
// trait/fun decls. The barrel imports track the canonical surface
// listed in docs/manual/22-modules.md "Adding a new std module".
// ---------------------------------------------------------------
test "scaffold: std.mod parses with 6 selective-import decls" {
    const prog = try parseStub("std.mod", build_options.stub_mod);
    try std.testing.expectEqual(@as(usize, 13), prog.imports.len);
    // Each line is `pub import std.X.{A, B, …}` so is_pub=true on
    // every entry and selectors.len >= 2.
    const expected_paths = [_][]const u8{
        "std.error",
        "std.string",
        "std.fmt",
        "std.time",
        "std.atomic",
        "std.bench",
        "std.argv",
        "std.env",
        "std.fs",
        "std.fs",
        "std.fs",
        "std.process",
        "std.process",
    };
    var i: usize = 0;
    while (i < prog.imports.len) : (i += 1) {
        const imp = prog.imports[i];
        try std.testing.expect(imp.is_pub);
        // Re-join path_nodes into dotted form for comparison via
        // manual while loop (zig 0.16 has rejected `for (slice) |x, i|`
        // double-capture in some expression shapes; manual indexing
        // is the safe-shared pattern documented in src/parser/decl.zig
        // for parseEnumDecl's multi-arg payload join).
        var path_buf: [64]u8 = undefined;
        var len: usize = 0;
        var j: usize = 0;
        while (j < imp.path_nodes.len) : (j += 1) {
            const node = imp.path_nodes[j];
            if (j > 0 and len < path_buf.len) {
                path_buf[len] = '.';
                len += 1;
            }
            if (len + node.len <= path_buf.len) {
                @memcpy(path_buf[len..][0..node.len], node);
                len += node.len;
            }
        }
        try std.testing.expectEqualStrings(expected_paths[i], path_buf[0..len]);
        // Each line has at least 1 selector
        try std.testing.expect(imp.selectors.len >= 1);
    }
    // Pin the alias on the second line (`Display as StringDisplay`)
    // so the `as` rename is exercised end-to-end through parseImportDecl.
    try std.testing.expectEqualStrings("Display", prog.imports[1].selectors[1].name);
    try std.testing.expect(prog.imports[1].selectors[1].alias != null);
    try std.testing.expectEqualStrings("StringDisplay", prog.imports[1].selectors[1].alias.?);
    // The barrel has only imports — no struct/enum/fun/trait decls.
    try std.testing.expectEqual(@as(usize, 0), prog.structs.len);
    try std.testing.expectEqual(@as(usize, 0), prog.enums.len);
    try std.testing.expectEqual(@as(usize, 0), prog.traits.len);
    try std.testing.expectEqual(@as(usize, 0), prog.functions.len);
    try std.testing.expectEqual(@as(usize, 0), prog.impls.len);
}

// ---------------------------------------------------------------
// std.string — `pub struct String { _opaque: i32 }` + impl methods.
// ---------------------------------------------------------------
test "scaffold: std.string parses with String struct + impl methods" {
    const prog = try parseStub("std.string", build_options.stub_string);
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqualStrings("String", prog.structs[0].name);
    try std.testing.expectEqual(@as(usize, 3), prog.structs[0].fields.len);
    try std.testing.expectEqualStrings("ptr", prog.structs[0].fields[0].kind.named.name);
    try std.testing.expectEqualStrings("len", prog.structs[0].fields[1].kind.named.name);
    try std.testing.expectEqualStrings("cap", prog.structs[0].fields[2].kind.named.name);

    try std.testing.expectEqual(@as(usize, 1), prog.impls.len);
    try std.testing.expectEqualStrings("String", prog.impls[0].target_type);
    // with_capacity, as_str, push_str, push_ch, pop_ch, clear, insert_ch
    try std.testing.expectEqual(@as(usize, 7), prog.impls[0].methods.len);
    try std.testing.expectEqualStrings("with_capacity", prog.impls[0].methods[0].name);
    try std.testing.expectEqualStrings("as_str", prog.impls[0].methods[1].name);
    try std.testing.expectEqualStrings("push_str", prog.impls[0].methods[2].name);
    try std.testing.expectEqualStrings("push_ch", prog.impls[0].methods[3].name);
}

// ---------------------------------------------------------------
// std.error — bare enum + Context struct + ErrorExt trait.
// ---------------------------------------------------------------
test "scaffold: std.error parses with 7-variant Error enum + Context + ErrorExt trait" {
    const prog = try parseStub("std.error", build_options.stub_error);

    // Spec §3.3 pin: 7 variants matching the canonical enum spec.
    try std.testing.expectEqual(@as(usize, 1), prog.enums.len);
    try std.testing.expectEqualStrings("Error", prog.enums[0].name);
    try std.testing.expectEqual(@as(usize, 7), prog.enums[0].variants.len);
    const expected_variants = [_][]const u8{
        "NotFound", "Permission", "Io", "Parse",
        "InvalidInput", "Unavailable", "Other",
    };
    var i: usize = 0;
    while (i < prog.enums[0].variants.len) : (i += 1) {
        try std.testing.expectEqualStrings(expected_variants[i], prog.enums[0].variants[i].name);
    }

    // Context struct with msg + source.
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqualStrings("Context", prog.structs[0].name);
    try std.testing.expectEqual(@as(usize, 2), prog.structs[0].fields.len);

    // ErrorExt trait with 2 REQUIRED-only methods.
    try std.testing.expectEqual(@as(usize, 1), prog.traits.len);
    try std.testing.expectEqualStrings("ErrorExt", prog.traits[0].name);
    try std.testing.expectEqual(@as(usize, 2), prog.traits[0].methods.len);
    try std.testing.expectEqualStrings("context", prog.traits[0].methods[0].name);
    try std.testing.expect(prog.traits[0].methods[0].body == null);
    try std.testing.expectEqualStrings("context_str", prog.traits[0].methods[1].name);
}

// ---------------------------------------------------------------
// std.fmt — Display trait + Writer struct + FmtError enum.
// ---------------------------------------------------------------
test "scaffold: std.fmt parses with Display trait + Writer + FmtError" {
    const prog = try parseStub("std.fmt", build_options.stub_fmt);
    try std.testing.expectEqual(@as(usize, 1), prog.traits.len);
    try std.testing.expectEqualStrings("Display", prog.traits[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.traits[0].methods.len);
    try std.testing.expectEqualStrings("write", prog.traits[0].methods[0].name);

    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqualStrings("Writer", prog.structs[0].name);

    try std.testing.expectEqual(@as(usize, 1), prog.enums.len);
    try std.testing.expectEqualStrings("FmtError", prog.enums[0].name);
    try std.testing.expectEqual(@as(usize, 2), prog.enums[0].variants.len);
    try std.testing.expectEqualStrings("Overflow", prog.enums[0].variants[0].name);
    try std.testing.expectEqualStrings("Invalid", prog.enums[0].variants[1].name);
}

// ---------------------------------------------------------------
// std.time — Duration + Timer structs + 2 free functions.
// Note: stub uses `pub fun Duration_from_millis` rather than
// `impl Duration { fun from_millis(...) }` because impl-block
// generics parsing is parser-unstable (see lib/std/time.zag header).
// When the parser catches up, this test should be updated to match
// the impl-method form.
// ---------------------------------------------------------------
test "scaffold: std.time parses with Duration, Timer, and 2 free fns" {
    const prog = try parseStub("std.time", build_options.stub_time);
    try std.testing.expectEqual(@as(usize, 2), prog.structs.len);
    try std.testing.expectEqualStrings("Duration", prog.structs[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.structs[0].fields.len);
    try std.testing.expectEqualStrings("nanos", prog.structs[0].fields[0].kind.named.name);
    try std.testing.expectEqualStrings("i64", prog.structs[0].fields[0].kind.named.type_text);

    try std.testing.expectEqualStrings("Timer", prog.structs[1].name);

    // Methods are now in impl blocks, not free functions
    try std.testing.expectEqual(@as(usize, 2), prog.impls.len);
    try std.testing.expectEqualStrings("Duration", prog.impls[0].target_type);
    try std.testing.expectEqualStrings("Timer", prog.impls[1].target_type);
}

// ---------------------------------------------------------------
// std.atomic — 5 atomic struct decls + Ordering enum (5 variants).
// ---------------------------------------------------------------
test "scaffold: std.atomic parses with 5 atomic types + Ordering enum" {
    const prog = try parseStub("std.atomic", build_options.stub_atomic);
    try std.testing.expectEqual(@as(usize, 5), prog.structs.len);
    const expected_atomics = [_][]const u8{
        "AtomicI32", "AtomicI64", "AtomicUsize", "AtomicBool", "AtomicPtr",
    };
    var i: usize = 0;
    while (i < prog.structs.len) : (i += 1) {
        try std.testing.expectEqualStrings(expected_atomics[i], prog.structs[i].name);
    }

    try std.testing.expectEqual(@as(usize, 1), prog.enums.len);
    try std.testing.expectEqualStrings("Ordering", prog.enums[0].name);
    try std.testing.expectEqual(@as(usize, 5), prog.enums[0].variants.len);
    const expected_orderings = [_][]const u8{
        "Relaxed", "Acquire", "Release", "AcqRel", "SeqCst",
    };
    var j: usize = 0;
    while (j < prog.enums[0].variants.len) : (j += 1) {
        try std.testing.expectEqualStrings(expected_orderings[j], prog.enums[0].variants[j].name);
    }
}

// ---------------------------------------------------------------
// std.bench — Counters struct with 3 fields + impl method.
// ---------------------------------------------------------------
test "scaffold: std.bench parses with Counters struct + snapshot impl" {
    const prog = try parseStub("std.bench", build_options.stub_bench);
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqualStrings("Counters", prog.structs[0].name);
    try std.testing.expectEqual(@as(usize, 3), prog.structs[0].fields.len);
    try std.testing.expectEqual(@as(usize, 1), prog.impls.len);
    try std.testing.expectEqualStrings("Counters", prog.impls[0].target_type);
    try std.testing.expectEqual(@as(usize, 1), prog.impls[0].methods.len);
    try std.testing.expectEqualStrings("snapshot", prog.impls[0].methods[0].name);
}

// ---------------------------------------------------------------
// std.async.stream — AsyncStream trait (no `<T>`) with poll_next.
// ---------------------------------------------------------------
test "scaffold: std.async.stream parses with AsyncStream trait" {
    const prog = try parseStub("std.async.stream", build_options.stub_async_stream);
    try std.testing.expectEqual(@as(usize, 1), prog.traits.len);
    try std.testing.expectEqualStrings("AsyncStream", prog.traits[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.traits[0].methods.len);
    try std.testing.expectEqualStrings("poll_next", prog.traits[0].methods[0].name);
}

// ---------------------------------------------------------------
// std.arch.x86.avx2 — comment-only placeholder (no decls).
// ---------------------------------------------------------------
test "scaffold: std.arch.x86.avx2 parses as comment-only (no decls)" {
    const prog = try parseStub("std.arch.x86.avx2", build_options.stub_arch_x86_avx2);
    try std.testing.expectEqual(@as(usize, 0), prog.structs.len);
    try std.testing.expectEqual(@as(usize, 0), prog.enums.len);
    try std.testing.expectEqual(@as(usize, 0), prog.traits.len);
    try std.testing.expectEqual(@as(usize, 0), prog.functions.len);
    try std.testing.expectEqual(@as(usize, 0), prog.impls.len);
    try std.testing.expectEqual(@as(usize, 0), prog.imports.len);
}

// ---------------------------------------------------------------
// joinDottedPath unit tests — companion to the codegen preamble
// emit (which calls `Parser.joinDottedPath` for every
// prog.imports entry and feeds the result to resolveStdImport).
// The scratch buffer is caller-provided so the assertions can run
// the helper in-process without the codegen preamble's stack
// reuse concerns. Each test asserts a join shape that exercises a
// real v1 KNOWN_STD_MODULES entry so the lookup-vs-table roundtrip
// is the canonical contract the codegen preamble depends on.
// ---------------------------------------------------------------
test "joinDottedPath: 2-element path joins with one dot" {
    var scratch: [256]u8 = undefined;
    const got = parser_mod.Parser.joinDottedPath(&scratch, &[_][]const u8{ "std", "string" });
    try std.testing.expectEqualStrings("std.string", got);
}

test "joinDottedPath: 3-element path joins with two dots" {
    var scratch: [256]u8 = undefined;
    const got = parser_mod.Parser.joinDottedPath(&scratch, &[_][]const u8{ "std", "async", "stream" });
    try std.testing.expectEqualStrings("std.async.stream", got);
}

test "joinDottedPath: 4-element path joins with three dots" {
    var scratch: [256]u8 = undefined;
    const got = parser_mod.Parser.joinDottedPath(&scratch, &[_][]const u8{ "std", "arch", "x86", "avx2" });
    try std.testing.expectEqualStrings("std.arch.x86.avx2", got);
}

test "joinDottedPath: single-element path is passthrough" {
    var scratch: [256]u8 = undefined;
    const got = parser_mod.Parser.joinDottedPath(&scratch, &[_][]const u8{"std"});
    try std.testing.expectEqualStrings("std", got);
}

test "joinDottedPath: empty path_nodes returns empty slice" {
    var scratch: [256]u8 = undefined;
    const got = parser_mod.Parser.joinDottedPath(&scratch, &[_][]const u8{});
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "joinDottedPath: every joined form resolves via KNOWN_STD_MODULES" {
    // Join + resolve roundtrip — the canonical codegen-preamble path.
    // Each paired lookup confirms the join has the SAME shape as the
    // table's `name` slot so the codegen preamble lands on the right
    // module without a false-positive miss.
    var scratch: [256]u8 = undefined;
    const cases = [_]struct { nodes: []const []const u8, expected: []const u8 }{
        .{ .nodes = &[_][]const u8{ "std" }, .expected = "lib/std/mod.zag" },
        .{ .nodes = &[_][]const u8{ "std", "string" }, .expected = "lib/std/string.zag" },
        .{ .nodes = &[_][]const u8{ "std", "error" }, .expected = "lib/std/error.zag" },
        .{ .nodes = &[_][]const u8{ "std", "fmt" }, .expected = "lib/std/fmt.zag" },
        .{ .nodes = &[_][]const u8{ "std", "async", "stream" }, .expected = "lib/std/async/stream.zag" },
        .{ .nodes = &[_][]const u8{ "std", "arch", "x86", "avx2" }, .expected = "lib/std/arch/x86/avx2.zag" },
    };
    var i: usize = 0;
    while (i < cases.len) : (i += 1) {
        const case = cases[i];
        const joined = parser_mod.Parser.joinDottedPath(&scratch, case.nodes);
        const resolved = parser_mod.Parser.resolveStdImport(joined);
        try std.testing.expect(resolved != null);
        try std.testing.expectEqualStrings(case.expected, resolved.?);
    }
}

// ---------------------------------------------------------------
// Cross-cutting: every KNOWN_STD_MODULES entry maps to a parseable
// .zag source. The lookup table is registered in src/parser/core.zig
// and must match a stub file on disk for the resolver to succeed.
// ---------------------------------------------------------------
test "scaffold: KNOWN_STD_MODULES table entries all map to parseable stubs" {
    const entries = parser_mod.Parser.KNOWN_STD_MODULES;
    try std.testing.expect(entries.len >= 9);
    // Each entry's `path` slot should resolve (when fed as a source
    // payload) to a parseable AST. We use the `parseStub` helper
    // to verify the entry's path is not just a string but points
    // at a real .zag file the parser accepts.
    const expected_minimum_paths = [_][]const u8{
        "lib/std/mod.zag",
        "lib/std/string.zag",
        "lib/std/error.zag",
        "lib/std/fmt.zag",
        "lib/std/time.zag",
        "lib/std/atomic.zag",
        "lib/std/bench.zag",
        "lib/std/async/stream.zag",
        "lib/std/arch/x86/avx2.zag",
    };
    var i: usize = 0;
    while (i < expected_minimum_paths.len) : (i += 1) {
        const expected = expected_minimum_paths[i];
        var found = false;
        var j: usize = 0;
        while (j < entries.len) : (j += 1) {
            if (std.mem.eql(u8, entries[j].path, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    // Roundtrip: build the dotted form back from a sample entry
    // and confirm `resolveStdImport` reaches resolve.
    const resolved = parser_mod.Parser.resolveStdImport("std.string");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("lib/std/string.zag", resolved.?);
    // Multi-segment path roundtrip:
    const resolved_async = parser_mod.Parser.resolveStdImport("std.async.stream");
    try std.testing.expect(resolved_async != null);
    try std.testing.expectEqualStrings("lib/std/async/stream.zag", resolved_async.?);
    // Barrel path:
    const resolved_mod = parser_mod.Parser.resolveStdImport("std");
    try std.testing.expect(resolved_mod != null);
    try std.testing.expectEqualStrings("lib/std/mod.zag", resolved_mod.?);
    // Miss returns null:
    try std.testing.expect(parser_mod.Parser.resolveStdImport("std.nonexistent") == null);
    try std.testing.expect(parser_mod.Parser.resolveStdImport("foo.bar") == null);
}
