const std = @import("std");

const MAX_PAYLOAD_BYTES: usize = 256 * 1024 * 1024;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------
    // Phase 2 -Dzig_payload wiring.
    //
    // Read the file pointed at by `-Dzig_payload=<path>` (default:
    // `src/_zig_payload.empty`, the 0-byte sentinel that keeps the
    // default zag binary small) at config time, and forward the bytes
    // through a `build_options` module attached to the `zag` Module.
    // `src/toolchain.zig` then reads them via `@import("build_options")`
    // and exposes `pub const zig_payload` to the rest of the
    // program.
    //
    // Without this wiring the embedded compile-time gate
    // `has_payload()` folds to false on the empty sentinel, and
    // `tryMaterialize` no-ops. With `-Dzig_payload=<path-to-zig>`
    // ~50 MB of binary data flows through the build step and into
    // the produced zag binary's static data section.
    // -------------------------------------------------------------------
    const zig_payload_path = b.option(
        []const u8,
        "zig_payload",
        "Path to a file whose bytes get embedded as the zig payload (default: src/_zig_payload.empty 0-byte sentinel)",
    ) orelse "src/_zig_payload.empty";
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
    // The user-installed zig at `zig_install_path` (the dev-machine
    // fallback) is unchanged and remains the no-payload / materialize-
    // failure path. Default `/home/lex/.local/zag` matches the
    // pre-Phase-2 hardcode so an unoption'd build behaves identically.
    // -------------------------------------------------------------------
    // Phase 3 (delivered): the runtime in `src/main.zig` (and its
    // mirror in `tests/smoke.zig`'s `resolveZagCacheDir`) consults
    // `$ZAG_HOME` > `$XDG_CACHE_HOME/zag` > `$HOME/.cache/zag`
    // BEFORE this build-time default. This `-Dz_install` only acts
    // as the no-env fallback (e.g. when running on a stripped CI
    // container, or for projects that pin the cache to a non-
    // standard path). See `src/env_path.zig`'s `resolveZagCacheDir`
    // for the full priority chain and reasoning.
    // -------------------------------------------------------------------
    const z_install_path = b.option(
        []const u8,
        "z_install",
        "Path to the zag-managed zig cache directory (default: /home/lex/.local/zag)",
    ) orelse "/home/lex/.local/zag";

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

    const unit_tests = b.addTest(.{
        .root_module = mod,
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
    // `<dir>/zig` while smoke's check stays hardcoded at
    // `/home/lex/.local/zag/zig/zig`, breaking Step 4 + Step 6 of
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
}

/// Read the file at `path` (relative to b.build_root is fine -- the
/// caller already resolves via `b.pathResolve`) into a freshly-allocated
/// buffer. Returns a `[]const u8` view into the build-arena memory --
/// safe to leak at the end of the build process.
///
/// zig 0.16's `std.fs.cwd` and `std.fs.openFileAbsolute` are both
/// rejected by the host compiler (full set of `std.fs.*` sparse-surface
/// findings from earlier rounds still applies in build.zig's host std).
/// We route through `posix.openat + std.os.linux.read`, the same
/// verified-working surface `src/tests/toolchain.zig` already uses for
/// its readback loop. size comes from the EOF return (n==0), so we
/// don't depend on the missing `posix.fstat` / `File.stat.size`-via-FS
/// path-coercion surface either.
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
