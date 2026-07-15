// -------------------------------------------------------------------
// Unit-test root for the zag `zig build test` binary.
//
// Lives outside `src/main.zig` as a separate zig module
// (root_source_file = `src/tests.zig`, registered in `build.zig` as
// `tests_mod`, wired into `b.addTest({ .root_module = tests_mod })`)
// so it does NOT pull `src/toolchain.zig` (which carries `pub const
// zig_payload: []const u8 = @import("build_options").zig_payload`)
// into the production zag binary.
//
// Without this fork, toolchain.zig was transitively imported into
// the production module via `_ = @import("tests/toolchain.zig")`
// in main.zig's trailing comptime block. The publisher reference
// `zig_payload` plus `addOption([]const u8, "zig_payload", ...)`
// plus `pub const embedded_zig_payload` plus the for-loop pin in
// `main()`'s runtime pinned 3-4× copies of the same ~172 MB slice
// in the binary's static data section, producing a 603 MB zag
// binary instead of the expected ~187 MB. The test binary's own
// copy of toolchain.zig is fine: it's not installed (no
// `b.installArtifact` call) and lives only in zig's build cache.
//
// Test discovery walks every `test "..."` block at file scope in
// each `src/tests/X.zig`. The comptime imports below make those
// files reachable from the test binary's source-file graph (zig
// runs every `test` block reachable from the module's
// root_source_file).
//
// `addOptions("build_options", options)` (wired in build.zig) makes
// `build_options.zig_payload` reachable when `src/toolchain.zig`
// is pulled in via `src/tests/toolchain.zig`'s
// `_ = @import("../toolchain.zig")` -- without that wiring the
// test file's compile graph would fail at `@import("build_options")`.
//
// `addImport("env_path", env_path_mod)` (also wired in build.zig)
// resolves `src/tests/env_path.zig`'s `@import("env_path")` to the
// same shared env-resolution module main.zig and smoke.zig both
// use; without that wiring the test file's lookup would fail with
// "no module named 'env_path'".
// -------------------------------------------------------------------

comptime {
    // `tests/...` paths resolve relative to this file's location
    // (src/tests.zig) -- zig's `@import` for file-system paths is
    // package-root-relative, not file-relative, so the names below
    // match the actual src/tests/X.zig paths.
    _ = @import("tests/lexer.zig");
    _ = @import("tests/toolchain.zig");
    _ = @import("tests/env_path.zig");
    _ = @import("tests/parser_core.zig");
    _ = @import("tests/parser_primary.zig");
    _ = @import("tests/parser_expr.zig");
    _ = @import("tests/parser_decl.zig");
    _ = @import("tests/parser_stmt.zig");
    _ = @import("tests/codegen_core.zig");
    _ = @import("tests/codegen_primary.zig");
    _ = @import("tests/codegen_expr.zig");
    _ = @import("tests/codegen_decl.zig");
    _ = @import("tests/codegen_stmt.zig");
    _ = @import("tests/codegen_builtins.zig");
}
