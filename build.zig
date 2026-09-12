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
    // `<local-zag>` path only worked on the original author's
    // machine, breaking anyone else's first build -- exactly the
    // failure mode this helper rewires). Order mirrors
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
    ) orelse defaultZInstall(b.allocator);

    const mod = b.addModule("zag", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "zig_payload", zig_payload_bytes);
    options.addOption([]const u8, "z_install", z_install_path);
    // The version string `zag version` prints -- read from build.zig.zon at
    // config time (see zonVersion above). Rides the SAME shared `options`
    // instance as zig_payload/z_install so every consumer module (zag main,
    // the tests module, smoke-runner, scaffold) sees one consistent value.
    options.addOption([]const u8, "zag_version", zonVersion(b));
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

    const exe_name = b.fmt("zag-{s}-{s}", .{
        targetOsString(target.result.os.tag),
        targetArchString(target.result.cpu.arch),
    });
    const exe = b.addExecutable(.{
        // v0.1 install-script alignment: produce a platform-suffixed
        // executable name so scripts/install-local.sh's
        // `LOCAL_BIN="$ZAG_BINS_DIR/zag-${OS}-${ARCH}${SUFFIX}"` resolves
        // without a manual `cp zig-out/bin/zag ...zig-${OS}-${ARCH}`
        // workaround. Maps zig's .macos->darwin + .aarch64->arm64 to
        // align with bash `uname` outputs expected by install-local.sh,
        // build.sh, and package.sh (zig follows the Darwin-kernel
        // naming convention; bash's uname -s reports "Darwin" but the
        // install scripts lowercase to "darwin"). The .exe suffix is
        // auto-appended by zig's `b.addExecutable` on Windows targets
        // (verified zig 0.16 std.Build behavior), so the format string
        // omits it; appending `.exe` here would produce
        // `zag-windows-x86_64.exe.exe`. See `targetOsString` +
        // `targetArchString` (bottom of this file) for the mapping
        // logic.
        .name = exe_name,
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
    // `zig build audit` -- the discarded-result regression check.
    //
    // The compiler's unused-value rule cannot catch this class of bug:
    // `_ = f.close();` is exactly how a hole gets (re-)opened silently,
    // and it is also a legitimate spelling when the close genuinely
    // cannot lose data. So the rule is not "never discard" but "name
    // the decision": every discard of an audited callee (close/sync +
    // the transfer family; see `isAuditedDiscardCallee`) must carry the
    // phrase `deliberate discard` in a comment on the same line.
    //
    // This is the P2 lesson made machine-checkable. P2 established that
    // write_file must not report success before the durability barrier,
    // and that a deferred write-back error surfaces only at close/fsync
    // time -- so a bare `_ = close(fd)` after a write is a silent
    // data-loss path. The audit cannot know which sites those are; it
    // can force a human (or a future agent) to say so per site, and it
    // fails the build when a new one appears unannounced.
    //
    // Scope: `lib/std/**/*.zag` AND `src/**/*.zig`. Both trees are
    // compliant as of P4's completion, which is what lets the step gate
    // them: `lib/std`'s eight sites are marked, and `src`'s discards are
    // either marked (read-only/probe fds) or gone (waitpid now goes
    // through `sys.waitPid`, the ELF patch rewrite through
    // `sys.writeFile`, the child-side dup2/close through
    // `childSetupOrExit`, the error-path closes through
    // `sys.closeOnErrorPath`).
    //
    // What the walk skips, so the gate is not read as broader than it is:
    //   - comment lines, and Zig multiline-string bodies (`\\    _ =
    //     std.os.linux.close(fd);` in `src/codegen/*.zig` is emitted Zag,
    //     not compiler code);
    //   - callees outside the set: `futex_*`/`nanosleep_retry`/
    //     `fetch_add`/`release`, `execve`, `mkdirat`/`mkdir`/`unlink`
    //     (see `isAuditedDiscardCallee` for each reason).
    //
    // `test` depends on it, so `zig build test` -- the project's fast
    // primary gate, the one AGENTS.md tells every contributor to run --
    // already covers it; the separate `audit` step is for running the
    // check alone.
    // -------------------------------------------------------------------
    const discard_audit_step = b.allocator.create(std.Build.Step) catch @panic("OOM allocating audit step");
    discard_audit_step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "audit",
        .owner = b,
        .makeFn = makeDiscardAuditStep,
    });
    const audit_step = b.step("audit", "Fail when a close/sync/read/write (or waitpid/lseek/dup2/ftruncate) result is discarded in lib/std or src without a `deliberate discard` marker");
    audit_step.dependOn(discard_audit_step);
    test_step.dependOn(discard_audit_step);

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
    // 10 staged `lib/std/*.zag` stubs lex+parse cleanly through the
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

    // -----------------------------------------------------------------
    // `zig build fs_smoke` -- end-to-end smoke for the v0.1 std.fs
    // .read_file migration (lib/std/fs.zag as a real .zag file backed
    // by the __zag_posix preamble family). Mirrors the SKIP-on-
    // missing-fixture pattern of tests/smoke.zig: the in-process
    // codegen-shape pin always runs (cheap, <1s), and the full
    // project-mode run-with-zag stage is staged for a follow-up once
    // a real `./zig-out/bin/zag` binary is available end-to-end.
    //
    // Located AFTER `scaffold_parser_helper_mod` is defined above so
    // the forward reference resolves at module-level const-init
    // (zig rejects forward refs to const-bound module identifiers;
    // see the review-round that caught the original placement under
    // the smoke_step block).
    //
    // Module wiring re-uses `scaffold_parser_helper_mod` (consolidated
    // at `src/parser.zig` -- the canonical one-module-for-lexer+parser
    // +ast pattern documented in the scaffold block above) and the
    // shared `env_path_mod` so fs_smoke's `@import("parser")` +
    // `@import("env_path")` resolve to the SAME compile-graph
    // modules as smoke + scaffold.
    //
    // Deliberately NOT calling `b.installArtifact` for fs-smoke-
    // runner -- the runner is a stage-side binary, not a production
    // artifact. `addRunArtifact` below runs from the build cache
    // without polluting zig-out/.
    // -----------------------------------------------------------------
    const fs_smoke_runner_mod = b.addModule("fs-smoke-runner", .{
        .root_source_file = b.path("tests/fs_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_smoke_runner_mod.addImport("parser", scaffold_parser_helper_mod);
    fs_smoke_runner_mod.addImport("env_path", env_path_mod);
    const fs_smoke_runner_exe = b.addExecutable(.{
        .name = "fs-smoke-runner",
        .root_module = fs_smoke_runner_mod,
    });
    const run_fs_smoke = b.addRunArtifact(fs_smoke_runner_exe);
    const fs_smoke_step = b.step("fs_smoke", "Run end-to-end fs.read_file smoke (SKIP-on-missing-zag-binary)");
    fs_smoke_step.dependOn(&run_fs_smoke.step);
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
    // std.fs joined the stub set with the P2 File rebuild: the module's
    // File surface (retained parent, Result-returning methods, the
    // *_or_panic twins, PAGE_SIZE/PARENT_CAP) is only reachable from
    // real code, and project mode never materializes fs.zag — so this
    // parse-only pin is where a rename gets caught.
    scaffold_options.addOption([]const u8, "stub_fs", readStubFile(b, "lib/std/fs.zag"));
    scaffold_options.addOption([]const u8, "stub_types", readStubFile(b, "lib/std/types/string.zag"));
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

    // -------------------------------------------------------------------
    // `zig build example_tests` -- run the `@[test]` blocks in the
    // example catalog.
    //
    // Neither existing gate covered them: `zig build test` is the
    // in-process Zig unit graph and never reads a `.zag` file, and
    // `examples/run_all.sh` executes each fixture's `main` while
    // deliberately filtering out `*/tests/*`. So the injected
    // EACCES/EISDIR/ENOSPC rows, the `File` contract, and the posix
    // `Result`-tier assertions were green only when a developer ran
    // `zag test <file>` by hand. This step makes that automatic.
    //
    // Discovery, not a hand-maintained list: `walkExampleDir` scans
    // `examples/` at config time and keeps every `.zag` file that opens
    // a line with `@[test]` -- the file-mode signal -- plus every file
    // that declares a `fun test_*`, the project-mode convention
    // (docs/manual/34-project-layout.md), so a new fixture is covered
    // the moment it lands. A `##` doc comment mention (`##   zag test
    // run tests (@[test] functions)`) is not a test block; see
    // `hasTestBlocks`.
    //
    // Each fixture is then classified FILE MODE or PROJECT MODE by
    // whether an ancestor directory holds a `zag.toml`. A file in a
    // project has to run in project mode, because its imports resolve
    // against the project root: `examples/project_layout/tests/parse.zag`
    // imports the project's `src/lib.zag`, which file mode cannot
    // resolve (`zag test <that file>` fails to compile). Project-mode
    // fixtures collapse to ONE step per project -- `zag test` from the
    // project root compiles the whole module graph and runs every test
    // in it -- so the dedupe keeps the step count at projects, not files.
    //
    // One `Run` step per fixture, spawned via `addSystemCommand` against
    // the installed binary rather than `addRunArtifact(exe)`. The why is
    // project mode: `zag` locates its stdlib mirror through
    // `resolveStdlibRoot`, whose exe-relative candidate is
    // `<exe_dir>/../../lib/std`, and that expression only lands on the
    // repository's `lib/std` when the binary sits in `zig-out/bin/`. A
    // cache artifact under `.zig-cache/o/<hash>/` has no `lib/std` two
    // levels up, so `addRunArtifact` worked for file mode (cwd = build
    // root, `./lib/std` hits first) but failed every project-mode 
    // fixture with `error: cannot locate lib/std`. The resolved path is
    // ABSOLUTE because the project-mode step changes the child's cwd, and
    // a relative program path is resolved against that new cwd.
    //
    // No output capture or platform-suffix duplication is needed either
    // way: `zag test` exits non-zero when a row fails, and the exit code
    // propagates and fails the build. There is consequently no SKIP path
    // here: unlike e2e/runtime_smoke, whose fixtures (a staged vendor/zig,
    // a pre-captured stdout) can legitimately be absent, this step's only
    // precondition is the compiler artifact it was just built from, which
    // `dependOn(b.getInstallStep())` guarantees. zig's build runner
    // schedules the steps against the machine's parallelism, so this does
    // not fork ~75 compilers at once.
    //
    // Caveat: a non-default `--prefix` moves the binary off
    // `zig-out/bin`, and `<exe>/../../lib/std` then points outside the
    // repository. File mode still resolves `./lib/std` from the build
    // root; project mode needs `ZAG_HOME=<repo>` (or the default prefix).
    //
    // `ZAG_ZIG_PATH` is pinned to the zig found on `$PATH` -- i.e. the
    // compiler running this very build. It is required, not defensive:
    // `zag test` resolves its toolchain as zag.toml -> $ZAG_ZIG_PATH ->
    // {/usr/bin/zig, /usr/local/bin/zig, $HOME/.local/zig/zig} -> the
    // embedded payload, and it does NOT search `$PATH`. A CI zig that
    // arrives only via `$PATH` (mlugg/setup-zig) matches none of those
    // tiers, so an unpinned `zig build example_tests` would fail with
    // `error: zig compiler not found` and exit 1. Setting it also keeps
    // this step on the same toolchain that produced the artifact.
    // `setCwd` pins the working directory -- the build root for file
    // mode, the project root for project mode -- so relative fixture
    // paths and `zag`'s `./lib/std` resolution tier agree no matter
    // where `zig build` was invoked from.
    // -------------------------------------------------------------------
    var example_fixtures = ExampleFixtures{};
    walkExampleDir(b, "examples", &example_fixtures);
    std.mem.sortUnstable(ExampleFixture, example_fixtures.items(), {}, exampleFixtureLessThan);

    const installed_zag = b.pathResolve(&.{b.getInstallPath(.bin, exe_name)});
    const example_tests_step = b.step("example_tests", "Run `zag test` over every example fixture with @[test] blocks (file mode; project mode for fixtures inside a zag.toml project)");
    // Resolved once, not per fixture, so the probe and its diagnostic
    // line appear a single time in the build log.
    const host_zig: ?[]const u8 = detectZigOnPath(b.allocator);
    var file_mode_count: usize = 0;
    var project_mode_count: usize = 0;
    var last_project: ?[]const u8 = null;
    for (example_fixtures.items()) |fixture| {
        if (fixture.project_root) |project_root| {
            // Iteration is sorted by path, and every file of a project
            // shares that project's prefix, so a project's fixtures are
            // contiguous and the previous root is enough to dedupe -- no
            // set needed.
            if (last_project != null and std.mem.eql(u8, last_project.?, project_root)) continue;
            last_project = project_root;
        }
        const run_example_test = b.addSystemCommand(&.{installed_zag});
        run_example_test.step.dependOn(b.getInstallStep());
        if (host_zig) |zig_path| {
            run_example_test.setEnvironmentVariable("ZAG_ZIG_PATH", zig_path);
        }
        if (fixture.project_root) |project_root| {
            run_example_test.setCwd(b.path(project_root));
            run_example_test.addArg("test");
            project_mode_count += 1;
        } else {
            run_example_test.setCwd(b.path("."));
            run_example_test.addArg("test");
            run_example_test.addArg(fixture.path);
            file_mode_count += 1;
        }
        example_tests_step.dependOn(&run_example_test.step);
    }
    std.debug.print(
        "example_tests: {d} file-mode fixture(s) + {d} project(s)\n",
        .{ file_mode_count, project_mode_count },
    );
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
/// Scan `env_bytes` (a NUL-separated /proc/self/environ snapshot)
/// for an entry of the form `key=value` and return the value as an
/// allocator-owned slice. Mirrors src/env_path.zig's readEnviron
/// parsing loop but returns one value rather than populating a
/// 512-entry array (the build-config call site consults 3 keys,
/// not the full env surface). Returns null when no matching key
/// exists OR when allocator.dupe fails (caller falls through to
/// the next priority tier).
fn readEnvVar(env_bytes: []const u8, key: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var i: usize = 0;
    while (i < env_bytes.len) {
        var entry_end: usize = i;
        while (entry_end < env_bytes.len and env_bytes[entry_end] != 0) : (entry_end += 1) {}
        const entry = env_bytes[i..entry_end];
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (eq == key.len and std.mem.eql(u8, entry[0..eq], key)) {
                // On dupe failure (vanishingly rare — only fires when the
                // build-arena can't satisfy a small allocation), fall to
                // the universal FALLBACK_ZINSTALL rather than returning
                // null. Returning null would silently cascade to the next
                // priority tier, incorrectly masking the env value as if
                // $ZAG_HOME hadn't been set; FALLBACK_ZINSTALL is the
                // correct universal fallback for any build-config failure.
                return allocator.dupe(u8, entry[eq + 1 ..]) catch FALLBACK_ZINSTALL;
            }
        }
        i = entry_end + 1;
    }
    return null;
}

/// Compute the default `-Dz_install` value at build-config time by
/// mirroring the runtime priority chain in `src/env_path.zig`'s
/// `resolveZagCacheDir`. Each tier reads at compile time via a
/// /proc/self/environ byte-walk -- NOT `std.c.getenv` (which the
/// codebase's zig 0.16 install rejects with "dependency on libc
/// must be explicitly specified in the build command") and NOT
/// `std.process.getEnvVarOwned` (which is missing from std.process
/// on this codebase's zig install). The /proc/self/environ raw
/// syscall surface -- posix.openat + std.os.linux.read -- is
/// verified-working in src/env_path.zig's readEnviron at line ~80,
/// so the same pattern is portable into build-config time.
///
/// Returns `[]const u8` either an allocator-owned env value or
/// a literal fallback string; lifetime is the build-arena's,
/// which spans the full build process -- the caller stores the
/// slice verbatim into `build_options.z_install`.
///
/// Priority chain (matches runtime `resolveZagCacheDir` exactly):
///   1. $ZAG_HOME verbatim          -- explicit user override
///   2. $XDG_CACHE_HOME/zag         -- freedesktop.org cache convention
///   3. $HOME/.cache/zag            -- POSIX $HOME fallback
///   4. `/tmp/zag-cache` literal    -- stripped-CI safety net
///
/// All three env reads use the SAME /proc/self/environ buffer
/// (one read per build invocation -- cheap, ~128 KB read into a
/// stack-allocated array). The literal fallback is only reached
/// on a fully-stripped CI container with no $HOME /
/// $XDG_CACHE_HOME / $ZAG_HOME -- main.zig's runtime `<dir>/zig`
/// materialize dir still has a writable cache in that case because
/// runtime-and-build resolve to the same path.
fn defaultZInstall(allocator: std.mem.Allocator) []const u8 {
    var buf: [131072]u8 = undefined;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return FALLBACK_ZINSTALL;
    defer _ = std.os.linux.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        if (n > std.math.maxInt(isize)) return FALLBACK_ZINSTALL;
        if (n == 0) break;
        total += n;
    }

    if (readEnvVar(buf[0..total], "ZAG_HOME", allocator)) |home| return home;
    if (readEnvVar(buf[0..total], "XDG_CACHE_HOME", allocator)) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/zag", .{xdg}) catch FALLBACK_ZINSTALL;
    }
    if (readEnvVar(buf[0..total], "HOME", allocator)) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.cache/zag", .{home}) catch FALLBACK_ZINSTALL;
    }
    return FALLBACK_ZINSTALL;
}

/// Translate zig's `std.Target.Os.Tag` enum to the bash-uname-style
/// OS string expected by `scripts/install-local.sh`,
/// `scripts/build.sh`, and `scripts/package.sh` for the
/// `zag-${OS}-${ARCH}${SUFFIX}` suffix-name. zig follows the kernel
/// naming convention (macOS's BSD-derived `Darwin` kernel maps to
/// `.macos`, Linux to `.linux`, Windows NT to `.windows`). bash's
/// `uname -s` reports the same names uppercased ("Darwin", "Linux",
/// "_NT-..."); the install scripts lowercase for the suffix, so we
/// just need to feed the lowercase kernel-name match here. The only
/// real divergence is `macos`/`darwin`; everything else is identical
/// to `@tagName`.
///
/// Used by `pub fn build`'s `b.addExecutable(.{ .name = ... })` to
/// produce the platform-suffixed artifact the install script reads.
/// Lives in this file because the mapping is needed at build-config
/// time (where `target.result.os.tag` is resolved); the same
/// translation happens in `tests/runtime_smoke.zig` and
/// `tests/smoke.zig` against `builtin.os.tag` (running on the same
/// host they were compiled for), so the test files duplicate this
/// function locally rather than reach back to build.zig (which would
/// require a separate Module + circular-import gymnastics that zig's
/// per-module file-membership rule prohibits).
fn targetOsString(tag: std.Target.Os.Tag) []const u8 {
    return switch (tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "darwin",
        else => @tagName(tag),
    };
}

/// Translate zig's `std.Target.Cpu.Arch` enum to the bash-uname-style
/// arch string expected by the install scripts. zig uses LLVM-style
/// arch names (`.x86_64`, `.aarch64`, ...); bash `uname -m` uses the
/// Linux-kernel-style names (`x86_64` happens to match, but
/// `aarch64`/zig vs `arm64`/bash is the canonical divergence on
/// Apple Silicon + AWS Graviton). Building the suffix-name from
/// this mapping rather than the raw `@tagName` keeps the
/// install/verify scripts coherent across platforms.
///
/// Non-matching archs (riscv64, wasm32, ...) fall through to
/// `@tagName` unchanged; the install scripts would need a parallel
/// update if a future zag build targets one of those.
fn targetArchString(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => @tagName(arch),
    };
}

/// One example fixture found by `walkExampleDir`: a `.zag` file whose
/// source opens a line with `@[test]`.
const ExampleFixture = struct {
    /// Path relative to the repository root, e.g.
    /// `examples/error-handling/posix_tier.zag`.
    path: []const u8,
    /// Non-null when an ancestor directory holds a `zag.toml`: the project
    /// root, relative to the repository root. Such a fixture runs in
    /// project mode (one step per project), not file mode, because its
    /// imports resolve against the project root.
    project_root: ?[]const u8,
};

/// Path-ordered comparison, so the emitted step list -- and therefore the
/// build log -- is stable across runs; `getdents64` order is not.
fn exampleFixtureLessThan(_: void, lhs: ExampleFixture, rhs: ExampleFixture) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

/// Fixed-capacity list of repository-relative `.zag` paths, filled by
/// `collectZagPaths`. Same bounded-buffer rationale as `ExampleFixtures`:
/// a bound rather than a growable list keeps the scan free of the
/// deprecated `std.array_list.Managed` and of an allocation-failure path.
/// Sized for the larger of the two callers: `examples/` holds ~90 `.zag`
/// files and `lib/std/` ~50.
const MAX_ZAG_PATHS: usize = 512;

const PathList = struct {
    buf: [MAX_ZAG_PATHS][]const u8 = undefined,
    len: usize = 0,

    fn items(self: *PathList) [][]const u8 {
        return self.buf[0..self.len];
    }

    fn add(self: *PathList, path: []const u8) void {
        if (self.len == self.buf.len) {
            std.debug.print(
                "zag build: .zag path limit ({d}) reached; {s} was not scanned\n",
                .{ MAX_ZAG_PATHS, path },
            );
            return;
        }
        self.buf[self.len] = path;
        self.len += 1;
    }
};

/// Fixed-capacity fixture list. A bound rather than a growable list keeps
/// the discovery free of the deprecated `std.array_list.Managed` and of an
/// allocation-failure path; `add` reports overflow instead of dropping a
/// fixture silently, which is the point of this step existing at all.
const MAX_EXAMPLE_FIXTURES: usize = 512;

const ExampleFixtures = struct {
    buf: [MAX_EXAMPLE_FIXTURES]ExampleFixture = undefined,
    len: usize = 0,

    fn items(self: *ExampleFixtures) []ExampleFixture {
        return self.buf[0..self.len];
    }

    fn add(self: *ExampleFixtures, fixture: ExampleFixture) void {
        if (self.len == self.buf.len) {
            std.debug.print(
                "example_tests: fixture limit ({d}) reached; {s} will not be tested\n",
                .{ MAX_EXAMPLE_FIXTURES, fixture.path },
            );
            return;
        }
        self.buf[self.len] = fixture;
        self.len += 1;
    }
};

/// True when `bytes` opens a line with `@[test]` (leading whitespace
/// allowed). A plain substring search is not enough: several fixtures
/// *document* the attribute inside a `##` comment (`##   zag test  run
/// tests (@[test] functions)`), and a file that only mentions it has no
/// tests to run. Requiring the attribute to open the line excludes those
/// comment mentions without needing Zag's lexer at build-config time.
///
/// This is the ONLY signal that counts in file mode: `zag test <file>`
/// collects `@[test]` functions and nothing else, so a lone `fun test_*`
/// in a standalone file runs zero cases.
fn hasTestBlocks(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "@[test]")) return true;
    }
    return false;
}

/// True when `bytes` declares a `fun test_*`. That is the PROJECT-mode
/// convention (docs/manual/34-project-layout.md): `zag test` from a
/// project root walks `tests/` and treats every top-level `fun test_*` as
/// a case with no `@[test]` annotation needed. It is checked in addition
/// to `hasTestBlocks` when deciding whether a *project* has tests, so a
/// suite that uses only the naming convention still pulls its project
/// into the step.
fn hasTestFunctions(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "fun test_")) return true;
    }
    return false;
}

/// Read `path` (repository-root-relative) into a build-arena slice, or
/// null when it cannot be read. Unlike `readStubFile`, a miss is not
/// fatal: the discovery walk probes every `.zag` under `examples/`, and
/// one unreadable file should not fail the whole build step.
fn readFileBytes(b: *std.Build, path: []const u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    var buf: [262144]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        if (n > std.math.maxInt(isize)) return null;
        if (n == 0) break;
        total += n;
    }

    const result = b.allocator.alloc(u8, total) catch return null;
    @memcpy(result, buf[0..total]);
    return result;
}

/// Extract `.version = "..."` from `build.zig.zon` and surface it as the
/// `zag_version` build option so `zag version` (src/main.zig) prints the
/// same version string the package metadata carries.
///
/// HISTORY: the version was hardcoded in main.zig ("zag 0.1.0-dev\n") and
/// had to be bumped in lockstep with build.zig.zon by hand -- a
/// two-sources-of-truth drift where a tag on a half-bumped tree shipped
/// binaries reporting the old number. The bump is now a one-line
/// `build.zig.zon` edit; main.zig reads it via `build_options.zag_version`.
///
/// Single-pass scan, no regex: look for the `.version` key, skip the
/// `=` and whitespace, then take the bytes between the next pair of
/// double quotes. Tolerates a trailing comma after the closing quote
/// (the canonical build.zig.zon formatting) and any key ordering.
/// A miss is a HARD build error (unlike readFileBytes' soft null): the
/// version string is a release invariant, and silently printing "dev"
/// in published binaries is worse than failing the build that would
/// have shipped them.
fn zonVersion(b: *std.Build) []const u8 {
    const bytes = readFileBytes(b, "build.zig.zon") orelse
        @panic("build.zig.zon unreadable: cannot extract .version");
    const key = ".version";
    const idx = std.mem.indexOf(u8, bytes, key) orelse
        @panic("build.zig.zon has no .version key");
    var pos = idx + key.len;
    while (pos < bytes.len and (bytes[pos] == ' ' or bytes[pos] == '\t' or bytes[pos] == '=')) pos += 1;
    if (pos >= bytes.len or bytes[pos] != '"')
        @panic("build.zig.zon .version is not a quoted string");
    pos += 1;
    const end = std.mem.indexOfScalarPos(u8, bytes, pos, '"') orelse
        @panic("build.zig.zon .version string is unterminated");
    return b.allocator.dupe(u8, bytes[pos..end]) catch
        @panic("OOM extracting build.zig.zon .version");
}

/// The nearest ancestor directory of `file_path` holding a `zag.toml`, or
/// null for a standalone fixture. That directory is the one `zag test`
/// must run from -- a file inside a project cannot be tested in file mode
/// because its imports resolve against the project root (e.g.
/// `examples/project_layout/tests/parse.zag` imports the project's
/// `src/lib.zag`).
fn projectRootOf(b: *std.Build, file_path: []const u8) ?[]const u8 {
    var dir = file_path[0..(std.mem.lastIndexOfScalar(u8, file_path, '/') orelse return null)];
    while (true) {
        const toml = std.fmt.allocPrint(b.allocator, "{s}/zag.toml", .{dir}) catch return null;
        if (readFileBytes(b, toml) != null) return dir;
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        dir = dir[0..slash];
    }
}

/// Depth-first scan of `rel_dir`, collecting every file whose name ends
/// with `suffix` (`.zag` for the example catalog, `.zig` for the
/// discarded-result audit's `src/` pass).
///
/// Generated output is skipped: `build/` (and any dot-directory, which
/// covers `.zig-cache`) holds a large transpiled tree neither caller has
/// any business reading, and the project-mode step recreates it anyway.
///
/// Shared by the `example_tests` discovery and the discarded-result
/// audit, so one traversal discipline covers both.
///
/// Uses the same `getdents64` + `d_reclen` discipline as `src/main.zig`'s
/// `materializeWalk`, including the `align(8)` on the batch buffer: the
/// dirent stream is 8-byte-aligned, so an unaligned base makes the
/// `@alignCast` below trip in Debug mode.
fn collectZagPaths(b: *std.Build, rel_dir: []const u8, suffix: []const u8, out: *PathList) void {
    const dir_fd = std.posix.openat(std.posix.AT.FDCWD, rel_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return;
    defer _ = std.os.linux.close(dir_fd);

    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = std.os.linux.getdents64(dir_fd, buf[0..].ptr, buf.len);
        if (n > std.math.maxInt(isize)) return;
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n) {
            const entry: *const std.os.linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += entry.reclen;

            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const name = name_z[0..name_z.len];
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name[0] == '.') continue;
            if (std.mem.eql(u8, name, "build")) continue;

            const child = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ rel_dir, name }) catch return;
            if (entry.type == std.os.linux.DT.DIR) {
                collectZagPaths(b, child, suffix, out);
            } else if (entry.type == std.os.linux.DT.REG and std.mem.endsWith(u8, name, suffix)) {
                out.add(child);
            }
        }
    }
}

/// Fill `out` with every test-bearing `.zag` file under `rel_dir`
/// (`examples/`), tagged with the project root it belongs to (or null for
/// a standalone fixture).
///
/// Two signals count, matching Zag's two documented test conventions:
///   - `@[test]` opening a line -- the file-mode signal, and the ONLY one
///     `zag test <file>` collects;
///   - a top-level `fun test_*` -- the project-mode convention
///     (docs/manual/34-project-layout.md), where `zag test` from the
///     project root picks up every `fun test_*` with no annotation.
///
/// A standalone file is selected on `@[test]` alone: a lone `fun test_*`
/// at file scope runs zero cases, because file mode does not use the
/// naming convention. A file inside a project is selected on either
/// signal -- the project's step runs the whole module graph, so one
/// `fun test_*` anywhere in it is enough to make the project worth
/// testing, and files with no tests at all are skipped.
fn walkExampleDir(b: *std.Build, rel_dir: []const u8, out: *ExampleFixtures) void {
    var paths = PathList{};
    collectZagPaths(b, rel_dir, ".zag", &paths);
    for (paths.items()) |path| {
        const bytes = readFileBytes(b, path) orelse continue;
        const has_block = hasTestBlocks(bytes);
        const project_root = projectRootOf(b, path);
        const selected = if (project_root == null)
            has_block
        else
            has_block or hasTestFunctions(bytes);
        if (!selected) continue;
        out.add(.{ .path = path, .project_root = project_root });
    }
}

/// Marker phrase that turns a discarded result into a *named* decision.
/// A site is compliant only when the same line carries this phrase in a
/// comment, e.g. `_ = close(fd); # deliberate discard: read-only fd, no
/// buffered write to report`. Matching is case-insensitive so the
/// sentence-cased form already used in several lib/std comments
/// ("Deliberate discard.") counts without a rewrite.
const discard_marker = "deliberate discard";

/// Callee names whose discarded result the audit treats as a potential
/// silent-failure hole: the close/sync + transfer family. These are the
/// calls whose error a caller cannot see any other way -- a deferred
/// write-back error (ENOSPC/EIO) reported only by close(2)/fsync(2), or
/// a short transfer that a bare `_ =` would report as success.
///
/// Deliberately NOT in the set:
///   - `futex_wait`/`futex_wake`: `futex_wait` legitimately returns
///     EAGAIN on a spurious wakeup, so every call site must discard or
///     re-check -- a per-site marker would be noise, not judgement.
///   - `nanosleep_retry`, `fetch_add`, `release`: not the transfer
///     family this audit exists for.
///   - `execve`: returns only on failure and is immediately followed by
///     `exit(127)`; the discard IS the control flow.
///   - `mkdirat`/`mkdir`/`unlink`: EEXIST/ENOENT are the expected results.
///
/// The second group is what the `src/` pass needed: `waitpid` (a
/// discarded result left `status` at 0, which `W.IFEXITED` reads as
/// "exited 0", so a failed wait reported success), `dup2` (a failed
/// redirect silently sends captured output to the terminal), and
/// `lseek`/`ftruncate` (an unchecked seek/cursor in the DWARF patch path
/// wrote at the wrong offset).
fn isAuditedDiscardCallee(callee: []const u8) bool {
    const names = [_][]const u8{
        "close",     "sync",       "fsync",      "fdatasync", "datasync",
        "write",     "write_full", "write_at",   "write_block", "append",
        "pwrite",    "pwrite_full", "read",      "read_full", "read_some",
        "read_at",   "read_block", "pread",      "pread_full",
        "waitpid",   "wait4",      "lseek",      "ftruncate", "truncate",
        "dup2",
    };
    for (names) |name| {
        if (std.mem.eql(u8, callee, name)) return true;
    }
    return false;
}

/// Case-insensitive search for the deliberate-discard marker.
fn namesDeliberateDiscard(line: []const u8) bool {
    if (line.len < discard_marker.len) return false;
    var i: usize = 0;
    while (i + discard_marker.len <= line.len) : (i += 1) {
        var k: usize = 0;
        while (k < discard_marker.len and std.ascii.toLower(line[i + k]) == discard_marker[k]) k += 1;
        if (k == discard_marker.len) return true;
    }
    return false;
}

/// The callee of the first *audited* result discard on `line`, or null.
///
/// Recognises the project's discard spelling `_ = <path>(...)` wherever
/// it starts (so `defer _ = close(fd);` matches too). The callee's last
/// `.`-segment is what the audit compares, which is what makes
/// `f.close()`, `std.posix.close(fd)`, and `close(fd)` the same call.
///
/// Non-call discards are skipped rather than treated as a match, so a
/// line like `_ = futex_wait(w);` does not hide a later audited discard
/// on the same line (there is no such line today; the loop is here so
/// the scanner cannot be fooled by one).
fn auditedDiscardedCallee(line: []const u8) ?[]const u8 {
    const needle = "_ = ";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, needle)) |idx| {
        const rest = line[idx + needle.len ..];
        var end: usize = 0;
        while (end < rest.len and
            (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_' or rest[end] == '.')) end += 1;
        if (end < rest.len and rest[end] == '(') {
            const full = rest[0..end];
            const callee = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot|
                full[dot + 1 ..]
            else
                full;
            if (isAuditedDiscardCallee(callee)) return callee;
        }
        from = idx + needle.len;
    }
    return null;
}

/// True when `line` is a comment or a multiline-string continuation, and
/// therefore cannot be code. `#` and `//` cover Zag and Zig comments;
/// `\\` covers a Zig multiline string literal's body line, which is how
/// the codegen's emitted-Zag templates appear (`src/codegen/*.zig` holds
/// literal `_ = std.os.linux.close(fd);` text that is generated code,
/// not compiler code, and must not be judged as a discard).
fn isCommentOrStringLine(trimmed: []const u8) bool {
    if (trimmed.len == 0) return true;
    if (trimmed[0] == '#') return true;
    if (std.mem.startsWith(u8, trimmed, "//")) return true;
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return true;
    return false;
}

/// Scan every source file under `rel_root` (`.zag` under `lib/std`,
/// `.zig` under `src`) for an audited discard with no marker, print each
/// violation with its path and line, and return the count.
///
/// A file that cannot be read is itself a finding, not a skip: the walk
/// just listed it, so a read failure means the audit's own coverage is
/// incomplete, and a silently-skipped file is exactly the kind of hole
/// this step exists to prevent. (In practice the only failure is the
/// 256 KB `readFileBytes` ceiling; lib/std's largest file is ~40 KB.)
fn auditDiscardedResults(b: *std.Build, rel_root: []const u8, suffix: []const u8) usize {
    var paths = PathList{};
    collectZagPaths(b, rel_root, suffix, &paths);

    var violations: usize = 0;
    var sites: usize = 0;
    // A walk that found nothing is a broken gate, not a pass. This is not
    // hypothetical: the first version of this function hardcoded `.zag`
    // for both roots, so the `src` pass silently scanned zero files and
    // reported "0 violation(s)" -- identical to a clean tree.
    if (paths.len == 0) {
        std.debug.print("audit: no {s} file found under {s}; the scan did not run\n", .{ suffix, rel_root });
        return 1;
    }
    for (paths.items()) |path| {
        const bytes = readFileBytes(b, path) orelse {
            std.debug.print("audit: could not read {s}; its discards were NOT scanned\n", .{path});
            violations += 1;
            continue;
        };
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (isCommentOrStringLine(trimmed)) continue;
            const callee = auditedDiscardedCallee(line) orelse continue;
            sites += 1;
            if (namesDeliberateDiscard(line)) continue;
            std.debug.print(
                "audit: {s}:{d}: discarded `{s}` result is not a named decision\n  {s}\n",
                .{ path, line_no, callee, trimmed },
            );
            violations += 1;
        }
    }
    std.debug.print(
        "audit: {d} file(s), {d} audited discard(s) in {s}, {d} violation(s)\n",
        .{ paths.len, sites, rel_root, violations },
    );
    return violations;
}

/// `make` body of the `audit` step: run the discarded-result scan and
/// fail the build when it finds anything. A step rather than a call in
/// `build()` so the scan runs only when `audit` (or `test`, which depends
/// on it) is scheduled -- config-time failure would fail `zig build
/// --help` too.
fn makeDiscardAuditStep(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options; // Nothing to report to the progress bar.
    const b = step.owner;
    // Both trees: `lib/std` is Zag source, `src` is the compiler's own
    // Zig. The `src` pass is what turned the P4 "remaining" list into
    // work -- see `auditDiscardedResults` for what the walk skips.
    const roots = [_]struct { root: []const u8, suffix: []const u8 }{
        .{ .root = "lib/std", .suffix = ".zag" },
        .{ .root = "src", .suffix = ".zig" },
    };
    var violations: usize = 0;
    for (roots) |r| violations += auditDiscardedResults(b, r.root, r.suffix);
    if (violations == 0) return;
    try step.result_error_msgs.append(
        b.allocator,
        b.fmt(
            "{d} discarded result(s) in lib/std or src lack a `deliberate discard` marker; " ++
                "either check the result or name the decision in a comment",
            .{violations},
        ),
    );
    return error.MakeFailed;
}

/// Locate the `zig` compiler on `$PATH` at build-config time. Used by
/// the `example_tests` step to pin `ZAG_ZIG_PATH` for each spawned
/// `zag test`: the resolution chain documented by `zag` on a miss
/// (zag.toml -> `$ZAG_ZIG_PATH` -> a three-path auto-detect -> the
/// embedded payload) contains no `$PATH` tier, so a `zig` that is
/// reachable only via `$PATH` -- which is exactly what a CI
/// `mlugg/setup-zig` install produces -- would otherwise be invisible
/// to the spawned compiler.
///
/// Returns null (leaving `ZAG_ZIG_PATH` unset, so `zag`'s own tiers
/// decide) when `$PATH` is empty/absent or no directory on it holds a
/// readable `zig`. The probe mirrors `detectVendorZig`'s
/// `posix.openat(RDONLY)` shape because zig 0.16's `std.fs.*` surface
/// is too sparse for a `stat`-style existence check (AGENTS.md
/// "Build-system quirks"); readability is the same proxy both this
/// file and `tests/*.zig` use. Diagnostics are printed so a miss is
/// visible in the build log rather than silent.
fn detectZigOnPath(allocator: std.mem.Allocator) ?[]const u8 {
    // The /proc/self/environ route `defaultZInstall` + `readEnvVar`
    // already use. It is the codebase's verified build-time env read:
    // zig 0.16 exposes no `std.process.getEnvMap`/`getEnvVarOwned` and
    // the build runner does not link libc, so `std.c.getenv` is not an
    // option (error: dependency on libc must be explicitly specified).
    // Non-Linux hosts have no /proc, so the probe returns null there and
    // the step falls back to `zag`'s own tiers; the diagnostic below
    // names the remedy.
    var buf: [131072]u8 = undefined;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch {
        std.debug.print("detectZigOnPath: no /proc/self/environ; set ZAG_ZIG_PATH=$(which zig) if `zig build example_tests` cannot find a toolchain\n", .{});
        return null;
    };
    defer _ = std.os.linux.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        if (n > std.math.maxInt(isize)) return null;
        if (n == 0) break;
        total += n;
    }

    const path_env = readEnvVar(buf[0..total], "PATH", allocator) orelse {
        std.debug.print("detectZigOnPath: no $PATH in environ; leaving ZAG_ZIG_PATH unset\n", .{});
        return null;
    };
    // tokenizeScalar already skips the empty entries a `::` in $PATH
    // produces, so no `dir.len == 0` guard is needed here.
    var dirs = std.mem.tokenizeScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        for ([_][]const u8{ "zig", "zig.exe" }) |exe| {
            const candidate = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, exe }) catch return null;
            const zig_fd = std.posix.openat(std.posix.AT.FDCWD, candidate, .{ .ACCMODE = .RDONLY }, 0) catch continue;
            _ = std.os.linux.close(zig_fd);
            std.debug.print("detectZigOnPath: found {s}\n", .{candidate});
            return candidate;
        }
    }
    std.debug.print("detectZigOnPath: no zig on $PATH; leaving ZAG_ZIG_PATH unset (set it explicitly if `zig build example_tests` cannot find a toolchain)\n", .{});
    return null;
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
