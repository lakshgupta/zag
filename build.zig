const std = @import("std");

const MAX_PAYLOAD_BYTES: usize = 256 * 1024 * 1024;

// Stripped-CI safety net for defaultZInstall's no-env fallback.
const FALLBACK_ZINSTALL: []const u8 = "/tmp/zag-cache";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------
    // -Dzig_payload wiring with vendor/zig auto-detect.
    //
    // Read the file pointed at by `-Dzig_payload=<path>` (default
    // auto-detect `vendor/zig/zig`, falling back to the empty
    // sentinel `src/_zig_payload.empty`) at config time and forward
    // the bytes through a `build_options` module attached to the
    // `zag` Module. `src/toolchain.zig` then reads them via
    // `@import("build_options")` and exposes `pub const zig_payload`
    // to the rest of the program.
    //
    // Auto-detect makes "embed the vendored zig compiler" the zero-
    // friction path: a developer who has run `scripts/install.sh`
    // (which mirrors the resolved zig install into `vendor/zig/` via
    // `mirror_zig_into_vendor`) gets the binary auto-embedded with
    // no extra `-Dzig_payload` flag. Fresh clones without
    // `vendor/zig/` fall back to the empty sentinel and produce a
    // small (~15 MB) default binary. Both search candidates
    // (`vendor/zig/zig` and `vendor/zig/zig.exe`) are unconditional;
    // whichever openat succeeds on wins. ENOENT and EACCES are both
    // treated as "not present" so a transient perm issue doesn't
    // break the build -- the user can pass `-Dzig_payload`
    // explicitly for a hard override.
    //
    // "Only the compiler": `-Dzig_payload` reads a single file
    // (`vendor/zig/zig`), not the entire `vendor/zig/` tree. The
    // sibling `lib/`, `std/`, `builtin.zig` etc. that
    // `mirror_zig_into_vendor` also places stay on disk (where they
    // belong for direct invocations of `vendor/zig/zig build ...`)
    // and are NOT embedded into the zag binary.
    //
    // HISTORY: a previous commit tried `@embedFile` + staging to
    //  break the 2-copy duplication; chunk-hash sweep showed the
    //  same ~3.7x ratio (372 MB with 100 MB synthetic; ~603 MB with
    //  the real vendor). The duplication is structural to zig
    //  0.16's slice-inlining, not to addOption mechanics. Do NOT
    //  attempt another embed-mechanism migration on this zig
    //  version -- it will not reduce the binary. A zig bump is
    //  the only reliable fixpath.
    // -------------------------------------------------------------------
    const zig_payload_path = b.option(
        []const u8,
        "zig_payload",
        "Path to a file whose bytes get embedded as the zig payload (default: vendor/zig/zig if staged, else src/_zig_payload.empty 0-byte sentinel)",
    ) orelse detectVendorZig() orelse "src/_zig_payload.empty";
    // No explicit path resolution here: zig build's convention is that
    // CWD equals build.zig's directory, so a relative -Dzig_payload
    // path resolves correctly against it. Absolute paths pass through
    // unchanged. (`b.pathResolve` in zig 0.16 expects `[]const u8`
    // slices but `b.build_root` is a `Build.Cache.Directory` struct;
    // resolving via that API is staged for a zig-bump follow-up.)
    const zig_payload_bytes = readPayloadFile(b, zig_payload_path);

    // -------------------------------------------------------------------
    // Phase 2 -Dz_install wiring.
    //
    // Override the zag-managed zig cache directory at build time. The
    // materialize destination `zag_cache_zig_path` in src/main.zig
    // is parameterized as `<z_install_path>/zig` via comptime `++`
    // -- keeping the override at the directory level (rather than
    // full-path) so the runtime `std.os.linux.mkdir` on the cache
    // parent in main.zig stays verbatim and the bytes-on-disk layout
    // (`<dir>/zig`) users can `ls` is unchanged.
    //
    // The default is computed by `defaultZInstall` from the build-
    // time env so any developer can run `zig build` on a fresh
    // checkout without passing `-Dz_install` (the prior hardcoded
    // `/home/lex/.local/zag` only worked on the original author's
    // machine, breaking anyone else's first build). Order mirrors
    // the runtime priority chain in `src/env_path.zig`'s
    // `resolveZagCacheDir`: $ZAG_HOME > $XDG_CACHE_HOME/zag >
    // $HOME/.cache/zag > /tmp/zag-cache.
    // -------------------------------------------------------------------
    // Phase 3 (delivered): the runtime in `src/main.zig` (and its
    // mirror in `tests/smoke.zig`'s `resolveZagCacheDir`) consults
    // `$ZAG_HOME` > `$XDG_CACHE_HOME/zag` > `$HOME/.cache/zag`
    // AT RUNTIME, superseding this build-time default. The runtime
    // env resolution wins when `$ZAG_HOME` is set; this build-time
    // default acts as the no-env fallback (e.g. when running on a
    // stripped CI container, or for projects that pin the cache to a
    // non-standard path). See `src/env_path.zig`'s `resolveZagCacheDir`
    // for the full priority chain and reasoning.
    // -------------------------------------------------------------------
    const z_install_path = b.option(
        []const u8,
        "z_install",
        "Path to the zag-managed zig cache directory (default: $ZAG_HOME > $XDG_CACHE_HOME/zag > $HOME/.cache/zag > /tmp/zag-cache)",
    ) orelse defaultZInstall();

    const mod = b.addModule("zag", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "zig_payload", zig_payload_bytes);
    options.addOption([]const u8, "z_install", z_install_path);
    mod.addOptions("build_options", options);

    // -------------------------------------------------------------------
    // Shared `env_path` module: lift of inline-duplicated getenv +
    // resolveZagCacheDir + readEnviron + env-array globals from
    // src/main.zig and tests/smoke.zig.
    //
    // Registered as an independent Module so it can be `addImport`-ed
    // into both main.zig's `zag` root (via `mod.addImport("env_path",
    // env_path_mod)` below) AND tests/smoke.zig's `smoke-runner` root
    // (further down). build_options is wired in here too --
    // `resolveZagCacheDir`'s no-env branch returns
    // `build_options.z_install`, so the env_path module needs its own
    // `addOptions("build_options", options)` call. Sharing the same
    // `options` instance across `mod` (zag main) + `env_path_mod` +
    // `smoke_runner_mod` keeps the three binaries on the same compile-
    // time `-Dz_install` value so main.zig's `zag_cache_dir` (Phase 2
    // wiring) and env_path's resolveZagCacheDir fallback never diverge.
    // Without this wiring, smoke and main could disagree on the
    // no-env fallback path under non-default -Dz_install.
    // -------------------------------------------------------------------
    const env_path_mod = b.addModule("env_path", .{
        .root_source_file = b.path("src/env_path.zig"),
        .target = target,
        .optimize = optimize,
    });
    // env_path_mod.addOptions removed -- see comment block above (env_path.zig uses comptime_fallback parameter instead)
    mod.addImport("env_path", env_path_mod);

    const exe = b.addExecutable(.{
        .name = "zag",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zig compiler");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // zag-tests module: unit-test root for `zig build test`.
    //
    // Fork of the previously-inlined `comptime { _ = @import("tests/...") }`
    // block at the bottom of `src/main.zig`. Lives in its own zig module
    // (root_source_file = `src/tests.zig`) so that `src/tests/toolchain.zig`'s
    // `_ = @import("../toolchain.zig")` does NOT transitively pull
    // `src/toolchain.zig` (with its `pub const zig_payload =
    // build_options.zig_payload`) into the production zag module.
    //
    // The transitive pull was producing a ~603 MB produced binary
    // (3-4× duplication of the ~172 MB embedded zig payload: one
    // copy held by `pub const embedded_zig_payload` in main.zig,
    // one by toolchain.zig's `pub const zig_payload`, one by the
    // `addOptions("build_options", ...)` storage itself, plus
    // possibly one more copy in the linker data section under
    // zig 0.16's slice-inlining). Splitting the tests out gives
    // the production binary exactly one copy of `build_options.zig_payload`
    // (~187 MB with vendor/zig/zig staged, ~15 MB under the empty
    // sentinel default).
    //
    // The test binary itself still pulls toolchain.zig in (it's
    // needed by `src/tests/toolchain.zig` to exercise
    // `materializeZigToCache` / `tryMaterialize` / `has_payload`)
    // and therefore has its own embed copy in its build-cache
    // binary, but that binary is NEVER installed (no
    // `b.installArtifact` call below) and never ships to users.
    //
    // `tests_mod.addOptions("build_options", options)` makes
    // `build_options.zig_payload` reachable when toolchain.zig is
    // pulled in via the test file -- without this wiring the test
    // binary's compile graph would fail at toolchain.zig's
    // `@import("build_options")` with "no module named 'build_options'".
    //
    // `tests_mod.addImport("env_path", env_path_mod)` resolves
    // `src/tests/env_path.zig`'s bare `@import("env_path")` lookup
    // to the same shared env-resolution module main.zig and smoke.zig
    // both use -- the test file's lookup needs the same registered
    // import shape as the smoke-runner's `@import("env_path")`.
    //
    // Test discovery: zig's test runner walks every `test "..."` block
    // at file scope in any source reachable from the module's
    // root_source_file. The five `comptime { _ = @import(...) }` imports
    // in `src/tests.zig` make `src/tests/{lexer,parser,codegen,toolchain,env_path}.zig`
    // reachable, so all ~hundred test blocks across those files run.
    // -------------------------------------------------------------------
    const tests_mod = b.addModule("zag-tests", .{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addOptions("build_options", options);
    tests_mod.addImport("env_path", env_path_mod);

    const unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // -------------------------------------------------------------------
    // End-to-end integration smoke (opt-in via `zig build smoke`).
    //
    // Stage `vendor/zig/zig.test` (a real zig binary) to enable the
    // full assertion pipeline: pre-build with -Dzig_payload=<fixture>,
    // run ./zig-out/bin/zag version, assert materialize-path exists +
    // is executable + byte-matches the fixture. Until the fixture is
    // staged, smoke-runner prints a SKIP message and exits 0 so the
    // step is safe to invoke in CI environments where the fixture
    // isn't mounted. See tests/smoke.zig for the assertion details.
    //
    // We deliberately do NOT make `zig build` (the default step)
    // depend on `smoke_step` -- the smoke is opt-in so the default
    // `zig build install` flow stays focused on producing ./zig-out
    // without a recursive build invocations or child-process forks.
    // -------------------------------------------------------------------
    const smoke_runner_mod = b.addModule("smoke-runner", .{
        .root_source_file = b.path("tests/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Wire build_options into the smoke-runner module so `tests/smoke.zig`
    // can read the same `build_options.z_install` value the main zag
    // module reads. Without this, smoke's `materialize_default` would
    // diverge from main's `zag_cache_zig_path` under any non-default
    // `-Dz_install=<dir>` -- the produced zag binary writes to
    // `<dir>/zig` while a hardcoded smoke check would stay pointing
    // at any obsolete install default, breaking Step 4 + Step 6 of
    // the assertion pipeline. Sharing the same `options` instance
    // keeps the smoke binary coherent with the main binary at compile
    // time (one fewer invariant to keep in sync across phases).
    smoke_runner_mod.addOptions("build_options", options);
    // Share the same `env_path` module instance with the smoke-runner
    // binary so smoke's @import("env_path") resolves to the SAME
    // priority chain (and falls back to the SAME `build_options.z_install`
    // value via the shared `options` instance) as main.zig. Mirrors
    // the `mod.addImport("env_path", env_path_mod)` line above; the
    // `smoke_runner_mod.addOptions("build_options", options)` already
    // ensures build_options transitive reachability, so smoke's
    // `materialize_default = build_options.z_install ++ "/zig"` keeps
    // tracking main.zig's compile-time fallback.
    smoke_runner_mod.addImport("env_path", env_path_mod);
    const smoke_runner_exe = b.addExecutable(.{
        .name = "smoke-runner",
        .root_module = smoke_runner_mod,
    });

    // Deliberately NOT calling `b.installArtifact` for the smoke
    // runner -- it's a build-time-only test artifact; users running
    // a plain `zig build install` shouldn't see a smoke-runner in
    // `./zig-out/bin/` alongside `zag`. `addRunArtifact` below runs
    // the smoke runner from zig's build-cache directly, no install
    // needed.
    const run_smoke = b.addRunArtifact(smoke_runner_exe);
    const smoke_step = b.step("smoke", "Run end-to-end integration smoke (pre-condition: stage vendor/zig/zig.test)");
    smoke_step.dependOn(&run_smoke.step);

    // -------------------------------------------------------------------
    // `zig build scaffold_tests` — parse-only regression check that the
    // 9 staged `lib/std/*.zag` stubs lex+parse cleanly through the
    // parser. Stubs are embedded at compile time via
    // `@embedFile("../lib/std/X.zag")` inside `tests/scaffold.zig` —
    // no runtime I/O, runs purely in-process, takes <1s. Each test
    // block in scaffold.zig pins the expected top-level decl surface
    // (struct/enum/trait/fun count + names) so the Layering-table
    // "Zag-source library" row's stub claim becomes regressable.
    //
    // Deliberately separate from `zig build test` because:
    //   - The 235+ fast unit tests stay fast (scaffold adds <1s; either
    //     step is fast enough in isolation, but isolation keeps the
    //     scaffold compile path debuggable as a separate zig module).
    //   - The scaffold module owns NO toolchain/env_path imports — it's
    //     a pure parser-only smoke — so it doesn't transitively pull
    //     toolchain.zig's `pub const zig_payload` (avoiding the binary
    //     duplication issue the zag-tests module fork solved; see
    //     the `tests_mod` block above for the canonical pattern).
    //
    // Adding a new stub to lib/std/ requires:
    //   1. Drop the .zag file at `lib/std/<name>.zag` (or subpath).
    //   2. Append `.{ .name = "std.<name>", .path = "lib/std/<name>.zag" }`
    //      to KNOWN_STD_MODULES in src/parser/core.zig.
    //   3. Add a new `test "scaffold: std.<name> parses with ..."`
    //      block in tests/scaffold.zig pinning the expected surface.
    //   4. Run `zig build scaffold_tests` — exit 0 confirms the stub
    //      parses; non-zero with a stack trace pinpoints which surface
    //      the parser rejected.
    // -------------------------------------------------------------------
    const scaffold_mod = b.addModule("scaffold-tests", .{
        .root_source_file = b.path("tests/scaffold.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Path-scope wiring for the scaffold module. zig 0.16's
    // `Build.Module` does NOT expose an `addImportPath`; the
    // supported surface for cross-directory source sharing is
    // `addImport(name, module)`. The scaffold module is rooted at
    // `tests/scaffold.zig`, so its path scope is `tests/` and
    // direct `@import("src/X.zig")` is rejected as "outside
    // module path".
    //
    // First attempt: three separate helper modules rooted at
    // `src/lexer.zig`, `src/parser.zig`, and `src/ast.zig`. Failed
    // with `src/lexer/token.zig: file exists in modules 'ast' and
    // 'lexer'` — both the `ast` module and the `lexer` module
    // transitively import `src/lexer/token.zig` (for the
    // `Token.loc: ast.Loc` field reference), and zig requires
    // each source file to belong to at most one module. The
    // cross-import cycle makes "three modules" infeasible.
    //
    // The working pattern is to consolidate to ONE helper module
    // rooted at `src/parser.zig` (which already transitively
    // imports both `src/ast.zig` and `src/lexer.zig` through
    // `src/parser/core.zig`'s own imports). `src/parser.zig` is
    // updated to also re-export `ast` and `Lexer` (see the file's
    // docblock), so the test does ONE `@import("parser")` and
    // reaches both `parser_mod.ast.Arena`, `parser_mod.Lexer`,
    // and `parser_mod.Parser` through a single namespace.
    const scaffold_parser_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    scaffold_mod.addImport("parser", scaffold_parser_helper_mod);
    // Stub content embedding. The 9 `lib/std/*.zag` files can't be
    // `@embedFile`d from inside `tests/scaffold.zig` for the same
    // path-scope reason (path scope is `tests/`, the .zag files are
    // in `lib/std/`). We read them at build-config time using the
    // same `posix.openat + std.os.linux.read` surface the zig-payload
    // reader uses, and surface the contents as build_options.
    // tests/scaffold.zig does `@import("build_options")` and reads
    // each stub by name. This is a more invasive wiring than
    // `@embedFile` but it's the right pattern when the source file
    // and the file being embedded are in different path scopes.
    const scaffold_options = b.addOptions();
    scaffold_options.addOption([]const u8, "stub_mod", readStubFile(b, "lib/std/mod.zag"));
    scaffold_options.addOption([]const u8, "stub_string", readStubFile(b, "lib/std/string.zag"));
    scaffold_options.addOption([]const u8, "stub_error", readStubFile(b, "lib/std/error.zag"));
    scaffold_options.addOption([]const u8, "stub_fmt", readStubFile(b, "lib/std/fmt.zag"));
    scaffold_options.addOption([]const u8, "stub_time", readStubFile(b, "lib/std/time.zag"));
    scaffold_options.addOption([]const u8, "stub_atomic", readStubFile(b, "lib/std/atomic.zag"));
    scaffold_options.addOption([]const u8, "stub_bench", readStubFile(b, "lib/std/bench.zag"));
    scaffold_options.addOption([]const u8, "stub_async_stream", readStubFile(b, "lib/std/async/stream.zag"));
    scaffold_options.addOption([]const u8, "stub_arch_x86_avx2", readStubFile(b, "lib/std/arch/x86/avx2.zag"));
    scaffold_mod.addOptions("build_options", scaffold_options);
    const scaffold_tests = b.addTest(.{ .root_module = scaffold_mod });
    const run_scaffold_tests = b.addRunArtifact(scaffold_tests);
    const scaffold_step = b.step("scaffold_tests", "Parse-only regression check on lib/std/*.zag stubs (embedded at compile time)");
    scaffold_step.dependOn(&run_scaffold_tests.step);

    // -------------------------------------------------------------------
    // `zig build e2e` -- render+compile+run end-to-end integration test.
    //
    // Mirrors the `zig build smoke` + `zig build scaffold_tests`
    // architecture: a SEPARATE zig module rooted at `tests/e2e.zig`
    // wired through its own `b.addExecutable` + `b.addRunArtifact`
    // step, NOT a `b.addTest` step. This keeps the e2e binary out of
    // the fast in-process `zig build test` (~240 tests, <1s) and
    // isolates its ~500ms subprocess cost to an EXPLICITLY-invoked
    // step that can be skipped from CI sandboxes that block fork.
    //
    // Why share scaffold_parser_helper_mod (rooted at src/parser.zig)
    // instead of adding a new codegen helper module:
    //
    // The e2e runner needs parser/Lexer/ast (already exposed by the
    // shared helper) PLUS Codegen (to run the in-process
    // lex+parse+codegen hop). Adding a SECOND helper module rooted
    // at `src/codegen.zig` would create a file-membership collision
    // on `src/lexer/token.zig`: `src/codegen/core.zig` transitively
    // imports `src/parser.zig` which transitively imports
    // `src/lexer/token.zig` -- which the existing scaffold helper
    // ALREADY pulls in. zig's at-most-one-module-per-source-file rule
    // would reject the second pull with "file exists in modules X
    // and Y".
    //
    // The fix: src/parser.zig was updated (one-line addition) to also
    // re-export `Codegen` from `src/codegen.zig`. The e2e then uses
    // `parser_mod.Codegen.init()` from the SAME helper module, no
    // file-membership collision. The first attempt to add a separate
    // codegen module failed with the predicted collision; the fix is
    // documented in src/parser.zig's own re-export block.
    //
    // Env-path: e2e.zig's `fork+execve` envp_z builder needs PATH
    // /HOME/LANG propagated to the zig subprocess (and its recursive
    // cc/ld grandchildren). Sharing the same `env_path_mod` instance
    // with main.zig + smoke-runner keeps the three binaries coherent
    // -- a future env-pass change has one fewer invariant to keep in
    // sync across files (same architectural one-liner as the parser
    // helper sharing above).
    //
    // Deliberately NOT calling `b.installArtifact` for the e2e
    // runner -- same reasoning as smoke-runner above; a plain
    // `zig build install` shouldn't surface an e2e-runner in
    // `./zig-out/bin/` alongside `zag`.
    // -------------------------------------------------------------------
    const e2e_tests_mod = b.addModule("e2e-tests", .{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_tests_mod.addImport("parser", scaffold_parser_helper_mod);
    e2e_tests_mod.addImport("env_path", env_path_mod);
    const e2e_runner_exe = b.addExecutable(.{
        .name = "e2e-runner",
        .root_module = e2e_tests_mod,
    });
    const run_e2e = b.addRunArtifact(e2e_runner_exe);
    const e2e_step = b.step("e2e", "End-to-end render+compile+run integration test (spawns `zig run` subprocess; opt-in to avoid forking CI sandboxes)");
    e2e_step.dependOn(&run_e2e.step);

    // -------------------------------------------------------------------
    // `zig build runtime_smoke` -- runtime-correctness smoke for trait
    // vtable dispatch against the doc/17 trait examples.
    //
    // Mirrors the `zig build e2e` / `zig build smoke` / `zig build
    // scaffold_tests` architecture: a SEPARATE zig module rooted at
    // `tests/runtime_smoke.zig` wired through its own `b.addExecutable`
    // + `b.addRunArtifact` step, NOT a `b.addTest` step. Same one-
    // liner rationale: keeps the fast in-process `zig build test`
    // (~240 tests, <1s) free of fork overhead and isolates the
    // ~500ms-2s subprocess cost to an EXPLICITLY-invoked step that
    // CI sandboxes blocking fork can omit.
    //
    // The runtime smoke covers what e2e cannot: it actually RUNS the
    // compiled zag binary against the doc/17 trait examples
    // (canonical_with.zag, multi_trait.zag, diamond_distinct.zag) and
    // asserts byte-for-byte equality between stdout and the pre-
    // captured runtime output. e2e's pipe+execve-of-`zig run` for a
    // single in-process generated source string only proves the
    // pipeline reaches `zig run`; it does NOT prove the trait dispatch
    // site fires through and reaches stdout intact after the
    // zig-vtable-construction pass. runtime_smoke closes that gap by
    // shelling out to the installed zag binary against the published
    // example .zag files.
    //
    // Path resolution: the runtime smoke binary is built and run by
    // `addRunArtifact`, with CWD = build.zig's directory (zig build's
    // documented convention). `./zig-out/bin/zag` and
    // `examples/traits/*.zag` are relative paths from project root,
    // so they resolve correctly without absolute-path resolution.
    //
    // Skip semantics: the runner probes `./zig-out/bin/zag` via
    // posix_openat on entry; ENOENT gets a graceful SKIP-to-stderr
    // + exit-0 so a fresh checkout (before `zig build install`)
    // doesn't trigger a hard test failure. Same architectural
    // precedent as tests/smoke.zig's "fixture missing → SKIP" exit-0.
    //
    // Deliberately NOT calling `b.installArtifact` -- same reasoning
    // as e2e/smoke above; a plain `zig build install` shouldn't
    // surface a runtime-smoke-runner in `./zig-out/bin/` alongside
    // `zag`. The runner is a build-time-only verification artifact.
    //
    // No `parser` or `env_path` imports needed: the runtime smoke
    // does NOT in-process lex+parse+codegen (e2e owns that lane).
    // It only shells out to the installed zag binary, so the module
    // stays lightweight and avoids the file-membership-collision
    // trap documented on the `e2e_tests_mod` wiring above.
    // -------------------------------------------------------------------
    const runtime_smoke_mod = b.addModule("runtime_smoke-tests", .{
        .root_source_file = b.path("tests/runtime_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    // tests/runtime_smoke.zig uses `@import("env_path").readEnviron`
    // for envp_z construction (mirroring tests/e2e.zig's exact
    // pattern: zig 0.16 doesn't expose std.posix.environ at the
    // expected path, so the env_path module owns the
    // /proc/self/environ -> sentinel-terminated-pointer-array
    // translation). The runtime smoke must import env_path via
    // addImport (NOT @import-the-file directly) because file
    // resolution across the tests/ -> src/ directory boundary is
    // forbidden in zig's per-module path scope.
    //
    // Deliberately NOT call addOptions("build_options", options) on
    // runtime_smoke_mod: env_path.zig itself doesn't transitively
    // import build_options, and threading build_options through a
    // third module would trigger zig 0.16's auto-numbering rename to
    // `build_options0` + the file-membership-collision diagnostic
    // documented on the env_path_mod addImport block above. The
    // runtime smoke doesn't need a compile-time `-Dz_install`
    // because it doesn't reach the zag-cache code path; it only
    // shells out to the installed zag binary which has its own
    // already-baked build_options snapshot.
    runtime_smoke_mod.addImport("env_path", env_path_mod);
    const runtime_smoke_exe = b.addExecutable(.{
        .name = "runtime_smoke-runner",
        .root_module = runtime_smoke_mod,
    });
    const run_runtime_smoke = b.addRunArtifact(runtime_smoke_exe);
    const runtime_smoke_step = b.step("runtime_smoke", "Runtime smoke for trait vtable dispatch -- spawns `./zig-out/bin/zag run <example>` per trait example and asserts stdout matches the pre-captured runtime output (opt-in like e2e)");
    runtime_smoke_step.dependOn(&run_runtime_smoke.step);
}

/// Compute the default `-Dz_install` value at build-config time by
/// mirroring the runtime priority chain in `src/env_path.zig`'s
/// `resolveZagCacheDir`. Each tier reads at compile time via
/// `std.posix.getenv` -- the verified-working env-read surface in
/// this codebase (this is the first build-time env read in
/// build.zig, so we deliberately avoid `std.process.getEnvVarOwned`
/// whose zig 0.16 shape has not been empirically verified here).
///
/// Returns `[]const u8` either an arena-copied env value or a
/// literal fallback string; lifetime is the build-arena's, which
/// spans the full build process -- the caller stores the slice
/// verbatim into `build_options.z_install`.
///
/// Priority chain (matches runtime `resolveZagCacheDir` exactly):
///   1. $ZAG_HOME verbatim          -- explicit user override
///   2. $XDG_CACHE_HOME/zag         -- freedesktop.org cache convention
///   3. $HOME/.cache/zag            -- POSIX $HOME fallback
///   4. `/tmp/zag-cache` literal    -- stripped-CI safety net
///
/// The literal fallback is only reached on a fully-stripped CI
/// container with no $HOME / $XDG_CACHE_HOME / $ZAG_HOME -- main.zig's
/// runtime `<dir>/zig` materialize dir still has a writable cache
/// in that case because runtime-and-build resolve to the same path.
fn defaultZInstall() []const u8 {
    // Build-time env reads via std.c.getenv (libc shim). Returns
    // `?[*:0]u8` -- a sentinel-terminated pointer into libc-managed
    // env storage -- coerced via std.mem.span into []const u8.
    // Zero-copy (no allocator dance), matching the verified
    // pointer-to-span idiom in src/env_path.zig line 115
    // (`std.mem.span(entry_ptr)`). The build host is zig itself,
    // a regular Linux executable that links against libc, so
    // std.c bindings are available without explicit -lc directives.
    //
    // Priority chain (mirrors runtime env_path.zig's resolveZagCacheDir):
    //   1. $ZAG_HOME verbatim (zero-copy libc pointer)
    //   2. $XDG_CACHE_HOME/zag (one allocPrint, freedesktop convention)
    //   3. $HOME/.cache/zag (one allocPrint, POSIX $HOME fallback)
    //   4. FALLBACK_ZINSTALL literal (stripped-CI safety net)
    if (std.c.getenv("ZAG_HOME")) |ptr| return std.mem.span(@ptrCast(ptr));
    if (std.c.getenv("XDG_CACHE_HOME")) |ptr| {
        const xdg = std.mem.span(@ptrCast(ptr));
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}/zag", .{xdg}) catch FALLBACK_ZINSTALL;
    }
    if (std.c.getenv("HOME")) |ptr| {
        const home = std.mem.span(@ptrCast(ptr));
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}/.cache/zag", .{home}) catch FALLBACK_ZINSTALL;
    }
    return FALLBACK_ZINSTALL;
}

/// openat(2) probe to detect `vendor/zig/zig` (or
/// `vendor/zig/zig.exe` on Windows) at build-config time. Returns
/// the path that openat succeeded on (so the caller can embed that
/// path's bytes), or null if neither exists. Best-effort: ENOENT
/// and EACCES both fall through to null so a transient perm issue
/// doesn't break the build -- the user can pass `-Dzig_payload`
/// explicitly if they need a hard override.
///
/// Probe order is `vendor/zig/zig` first, then `vendor/zig/zig.exe`
/// (Windows); whichever openat returns a valid fd for wins. The
/// build's CWD is build.zig's directory (per zig build's
/// convention), so a relative path resolves correctly against the
/// source clone root -- no `b.pathResolve` dance needed.
///
/// Mirrors `tests/smoke.zig`'s `resolveZigPath` shape: smoke picks
/// `vendor/zig/zig` first then dev fallback; this helper picks
/// `vendor/zig/zig` first then sentinel. Keeping the two
/// resolutions in lockstep means a developer who runs
/// `scripts/install.sh` gets both the build's embedded payload AND
/// the smoke's pre-build driver pointed at the same vendored
/// binary -- no "the smoke is invoking a different zig than the
/// build embedded" skew.
///
/// Diagnostic output (`detectVendorZig: found <path>` on hit,
/// `detectVendorZig: not found -- using empty sentinel` on miss)
/// surfaces the auto-detect decision in the build log so a stale
/// or perm-blocked vendor/zig/zig is bisectable by grep without
/// re-running with -Dverbose.
fn detectVendorZig() ?[]const u8 {
    const candidates = [_][]const u8{ "vendor/zig/zig", "vendor/zig/zig.exe" };
    for (candidates) |candidate| {
        const fd = std.posix.openat(std.posix.AT.FDCWD, candidate, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            std.debug.print("detectVendorZig: openat({s}) failed: {s}; trying next candidate\n", .{ candidate, @errorName(err) });
            continue;
        };
        _ = std.os.linux.close(fd);
        std.debug.print("detectVendorZig: found {s}\n", .{candidate});
        return candidate;
    }
    std.debug.print("detectVendorZig: not found -- using empty sentinel\n", .{});
    return null;
}

/// Read the file at `path` (the caller already resolved the path,
/// see `-Dzig_payload` chain above) into a freshly-allocated buffer.
/// Returns a `[]const u8` view into the build-arena memory -- safe to
/// leak at the end of the build process (the build reclaims its
/// arena in bulk).
///
/// zig 0.16's `std.fs.cwd` and `std.fs.openFileAbsolute` are both
/// rejected by the host compiler (full set of `std.fs.*` sparse-
/// surface findings from earlier rounds still applies in build.zig's
/// host std). We route through `posix.openat + std.os.linux.read`,
/// the same verified-working surface `src/tests/toolchain.zig`
/// already uses for its readback loop. Size comes from the EOF
/// return (n==0), so we don't depend on the missing `posix.fstat` /
/// `File.stat.size`-via-FS path-coercion surface either.
fn readPayloadFile(b: *std.Build, path: []const u8) []const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        std.debug.print("error: -Dzig_payload={s} open failed: {s}\n", .{
            path,
            @errorName(err),
        });
        std.debug.print("hint: pass -Dzig_payload=<path-to-file>, or omit for the empty sentinel.\n", .{});
        std.process.exit(1);
    };
    defer _ = std.os.linux.close(fd);

    // Allocate MAX+1 byte probe so a file of EXACTLY MAX bytes reads
    // cleanly without tripping the size cap. Real zig binaries are
    // ~50 MB; the empty sentinel is 0; 256 MB gives headroom for
    // future debug-zig builds and a clean panic for pathological
    // inputs. The +1 probe byte is consumed only when the file is
    // strictly over MAX -- in which case `total > MAX` after the
    // loop and we panic.
    const buf = b.allocator.alloc(u8, MAX_PAYLOAD_BYTES + 1) catch @panic("OOM allocating zig-payload read buffer");

    var total: usize = 0;
    const cap = buf.len;
    while (total < cap) {
        const n = std.os.linux.read(fd, buf[total..].ptr, cap - total);
        // `std.os.linux.read` returns raw syscall bytes -- 0 on EOF,
        // max usize - errno on failure. `maxInt(isize)` is the size
        // boundary between a legitimate byte-count and a syscall-
        // error sentinel.
        if (n > std.math.maxInt(isize)) {
            std.debug.print("error: -Dzig_payload={s} read failed\n", .{path});
            std.process.exit(1);
        }
        if (n == 0) break;
        total += n;
    }
    if (total > MAX_PAYLOAD_BYTES) {
        std.debug.print("error: -Dzig_payload={s} exceeds 256 MB ceiling\n", .{path});
        std.process.exit(1);
    }

    // Slice into the build arena (no need to free; the build process
    // reclaims its arena in bulk).
    const result: []const u8 = buf[0..total];
    return result;
}

/// Read the file at `path` (relative to build.zig's directory) into a
/// freshly-allocated buffer and return a `[]const u8` view into the
/// build-arena memory. Used by the scaffold module to embed the
/// `lib/std/*.zag` stub contents into the test binary (the test
/// binary's path scope doesn't reach `lib/std/` because it's rooted
/// at `tests/scaffold.zig`, so `@embedFile` is rejected as
/// "outside module path"). The contents are exposed via
/// `addOptions("build_options", ...)` rather than `@embedFile` so
/// the test reads them through `@import("build_options").stub_X`
/// without needing direct path-scope access to `lib/std/`.
/// Stays within the existing posix.openat + std.os.linux.read
/// surface so no new `std.fs.*` dependencies are introduced
/// (the host std surface in build.zig has been sparse on
/// `std.fs.cwd` / `std.fs.openFileAbsolute` per the
/// `readPayloadFile` docblock above).
fn readStubFile(b: *std.Build, path: []const u8) []const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        std.debug.print("error: scaffold stub read '{s}' open failed: {s}\n", .{ path, @errorName(err) });
        std.debug.print("hint: ensure lib/std/X.zag exists on disk relative to build.zig's directory.\n", .{});
        std.process.exit(1);
    };
    defer _ = std.os.linux.close(fd);

    // Read into a generously-sized scratch buffer; the lib/std stubs
    // are small (~50-200 bytes each, max ~300 for the doc-heavy
    // ones). 64 KB is enough headroom for any single stub while
    // keeping the allocation tiny. Loop until EOF (n == 0) so partial
    // reads assemble correctly.
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        if (n > std.math.maxInt(isize)) {
            std.debug.print("error: scaffold stub read '{s}' read failed\n", .{path});
            std.process.exit(1);
        }
        if (n == 0) break;
        total += n;
    }

    // Allocate a fresh build-arena copy of the read bytes so the
    // returned slice outlives the local `buf` (which goes out of
    // scope when this function returns).
    const result = b.allocator.alloc(u8, total) catch @panic("OOM allocating scaffold stub read buffer");
    @memcpy(result, buf[0..total]);
    return result;
}
