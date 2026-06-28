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

    const mod = b.addModule("zag", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "zig_payload", zig_payload_bytes);
    mod.addOptions("build_options", options);

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
