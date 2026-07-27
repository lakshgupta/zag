// =====================================================================
// tests/runtime_smoke.zig -- runtime correctness smoke for trait
// vtable dispatch.
//
// Why this exists
// ---------------
// The codegen-pinning tests in src/tests/codegen_decl.zig verify the
// emit SHAPE (the zigzag leaf contains `Drawer{ .ptr = @constCast(&btn),
// .vtable = ... }` etc.) but they don't prove the produced binary
// ACTUALLY RUNS the dispatch. A bug where zig's structured-pointer
// coercion silently drops during link, or where the vtable slot
// resolves to the wrong function pointer, would slip past codegen
// pins and surface only as wrong stdout at runtime.
//
// This smoke closes that gap: for each trait example, fork+execve
// `./zig-out/bin/zag run <example>`, capture stdout, and assert
// byte-for-byte equality against the pre-captured expected output.
//
// What it covers
// --------------
// Three positive cases + the negative compile-error path stays
// pinned by the existing compile-time test fixtures (so we don't
// re-test it here):
//
//   1. examples/traits/canonical_with.zag -- canonical single-trait
//      impl, exercises the docs/17 Stage 7 surface.
//   2. examples/traits/multi_trait.zag -- multi-trait single-block
//      with distinct method names, exercises trait-name-keyed
//      dispatch into separate vtables.
//   3. examples/traits/diamond_distinct.zag -- the disjoint-method
//      diamond case, exercises trait-name-keyed disambiguation at
//      per-trait vtable granularity.
//
// Expected stdout values were captured by running
// `./zig-out/bin/zag run <example>` against the freshly-built
// canonical_with.zag commit and are pinned by this test as the
// runtime-correctness contract. A regression that breaks the trait
// dispatch will surface as a captured-pipe-content mismatch on this
// test.
//
// The match itself is `std.mem.indexOf` (substring lookup), not
// byte-exact, because the pipe captures both stdout AND stderr from
// the spawned zag process (zig compile-time noise on fd 2 lands in
// the SAME pipe as the user example's stdout on fd 1). The substring
// match preserves the strongest correctness signal we care about
// -- "the trait dispatch bytes reached the user's stdout" -- while
// tolerating compiler-version-induced stderr dissonance.
//
// Negative case (`ambiguous_diamond.zag`)
// ---------------------------------------
// Stays pinned by the existing `parser/codegen/compile-only`
// fixtures because this is an in-process test that asserts exit-0;
// invoking `./zig-out/bin/zag run ambiguous_diamond.zag` would
// exit non-zero (compile error), so we don't run it here.
//
// Run it
// ------
// `zig build runtime_smoke`. The runner is registered as a separate
// `b.addExecutable` + `b.addRunArtifact` step parallel to
// `zig build smoke` and `zig build e2e`.
//
// Subprocess API
// --------------
// Mirrors tests/e2e.zig's `fork + posix.pipe + dup2 + execve +
// waitpid` shape exactly. zig 0.16's `std.ChildProcess` (now
// `std.process.Child`) requires a new `StdIo.pipe`/Io argument
// that is not empirically verified in this codebase; the raw
// POSIX surface has been the project's verified-working idiom
// across smoke + e2e and is the right choice here too.
//
// Skip semantics
// --------------
// If `./zig-out/bin/zag` is missing OR an example file is missing,
// the runner prints "SKIP: <reason>" to stderr and exits 0 -- no
// test failure on a partial checkout, matching the smoke-runner's
// "fixture-missing -> 0 exit" precedent.
// =====================================================================

const std = @import("std");
const builtin = @import("builtin");
const env_path = @import("env_path");

/// Path to the zag binary relative to the test runner's CWD. zig
/// build's convention is that CWD = build.zig's directory at
/// invocation time, so `./zig-out/bin/zag-${OS}-${ARCH}${EXE}`
/// resolves to the platform-suffixed artifact produced by
/// `b.addExecutable(.{ .name = b.fmt("zag-{s}-{s}", ...) })` in
/// build.zig (see `targetOsString` + `targetArchString` there for
/// the .macos->darwin + .aarch64->arm64 mapping rationale). This
/// MUST mirror build.zig's mapping exactly; the constants below are
/// duplicated locally rather than imported from build.zig because
/// zig's per-module file-membership rule prohibits a circular
/// graph-import of the build script's helpers into this test
/// runner. Compiled at comptime so `ZAG_BIN` stays `const` (no
/// runtime syscall, no allocation). `.exe` is auto-appended by
/// zig's builder on Windows targets, matching build.zig's omission.
const ZAG_BIN = "./zig-out/bin/zag" ++ comptimeOsArchSuffix();

fn comptimeOsArchSuffix() []const u8 {
    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "darwin",
        else => @tagName(builtin.os.tag),
    };
    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => @tagName(builtin.cpu.arch),
    };
    return std.fmt.comptimePrint("-{s}-{s}", .{ os_str, arch_str });
}

/// All runtime assertions in one place. The expected stdout values
/// are byte-exact captures from a manual `zag run <example>` against
/// the same source. Don't hand-edit these without re-running the
/// source and capturing fresh output -- the test will fail until
/// the staged expected stdout matches the post-fix runtime.
const TestCase = struct {
    name: []const u8,
    example: []const u8,
    expected: []const u8,
};

const cases = [_]TestCase{
    .{
        .name = "canonical_with: Drawable dispatch fires",
        .example = "examples/traits/canonical_with.zag",
        // v1.6 byte-slice widening: zig's `{any}` formatter used to
        // dump byte elements `{ 99, 108, ... }` here, but the v1.6
        // member_access widening (codegen/primary.zig's
        // typeAwareFmtSpecFromExpr helper) routes `self.label` (a
        // `label: str` field) through zig's `{s}` formatter, which
        // prints the slice as its string contents. The expected
        // stdout is now the human-readable string instead of the
        // byte-deferred `{ 99, 108, ... }` list.
        .expected =
            "button: click me\n",
    },
    .{
        .name = "multi_trait: Drawable + Clickable dispatch independently",
        .example = "examples/traits/multi_trait.zag",
        // Both `draw` and `click` print `self.label` (a `str` field).
        // v1.6 widening emits `{s}` for both call sites so the
        // expected stdout is `draw: ok` + newline + `click: ok` +
        // newline (instead of the legacy byte-deferred
        // `draw: { 111, 107 }` form). Confirms BOTH trait vtables
        // fire the same body and the bytes reach stdout intact.
        .expected =
            "draw: ok\n" ++
            "click: ok\n",
    },
    .{
        .name = "diamond_distinct: trait-name-keyed vtable pick",
        .example = "examples/traits/diamond_distinct.zag",
        // Display's `print` wraps the value in `<span>...</span>`;
        // Show's `render` wraps nothing. Two different vtable slots,
        // two different bodies, same input value ("ok"). v1.6
        // widening routes `self.label` through `{s}` for the raw
        // render AND for the HTML-escaped print, so the expected
        // stdout is `<span>ok</span>` + newline + `ok` + newline
        // (instead of the byte-deferred form).
        .expected =
            "<span>ok</span>\n" ++
            "ok\n",
    },
};

pub fn main() !u8 {
    // CRITICAL: read into env_path.environ_entries BEFORE any fork so
    // the spawned zag subprocess inherits a non-empty environment.
    // Without this, zig build-exe's child-zig invocation (which runs
    // internally whenever the top-level zag call invokes the embedded
    // cli.zag materialiser) gets $HOME/$PATH/$XDG_CACHE_HOME = unset,
    // and zig aborts with `error: zig build-exe failed for cli.zag
    // (exit 1)` because it can't initialise its global cache
    // directory. Mirrors tests/e2e.zig's `env_path.readEnviron()` call
    // at the top of `main` -- the same architectural rationale.
    env_path.readEnviron();

    if (try preflight()) {
        std.debug.print("runtime_smoke: pass 0 / 0\n", .{});
        return 0;
    }

    var pass_count: u32 = 0;
    var fail_count: u32 = 0;

    for (cases) |case| {
        const result = runOne(case) catch |err| {
            std.debug.print("runtime_smoke: FAIL '{s}' -- subprocess error: {s}\n", .{ case.name, @errorName(err) });
            fail_count += 1;
            continue;
        };
        switch (result) {
            .pass => {
                std.debug.print("runtime_smoke: PASS '{s}'\n", .{case.name});
                pass_count += 1;
            },
            .fail => |info| {
                std.debug.print(
                    "runtime_smoke: FAIL '{s}'\n" ++
                        "  expected ({d} bytes): {s}\n" ++
                        "  actual   ({d} bytes): {s}\n" ++
                        "  exit code: {d}\n",
                    .{
                        case.name,
                        case.expected.len,
                        case.expected,
                        info.actual.len,
                        info.actual,
                        info.exit_code,
                    },
                );
                fail_count += 1;
            },
        }
    }

    std.debug.print("runtime_smoke: pass {d} / fail {d}\n", .{ pass_count, fail_count });
    if (fail_count == 0) return 0;
    return 1;
}

/// Returns true if the runner should SKIP (a required binary or
/// example file is missing) -- and emitted the SKIP reason to
/// stderr directly. Returns false if preflight succeeded (the
/// caller proceeds into the test-case loop). Other preflight
/// errors propagate via the error union.
///
/// Note: zig's `++` string-concat operator requires BOTH operands to
/// be comptime-known compile-time string literals (`*const u8`
/// pointing at .rodata). Runtime slices from
/// `&ZAG_BIN`-component-static-paths or `case.example` cannot be
/// `++`-concat'd at compile time, so we instead delegate the
/// SKIP-line emission to `std.debug.print` with the runtime path
/// passed as a `{s}` format arg. This keeps the SKIP reason readable
/// without an extra allocation.
///
/// zig 0.16's std.posix.ACCMODE is a bit-mask enum that exposes
/// RDONLY/WRONLY/RDWR but NOT X_OK (per upstream zig install at
/// `<local-zig>`/lib/std/posix.zig). build.zig's proven
/// pattern for binary probing uses RDONLY + handle-the-missing-
/// fixture upstream; if you can read a file, the perms for a
/// subsequent execve are reasonable to assume. (If the binary lacks
/// exec perms the execve syscall surfaces its own errno -- no need
/// to gate that here.) Mirrors build.zig:detectVendorZig's RDONLY
/// gate.
fn preflight() !bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, ZAG_BIN, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("runtime_smoke: SKIP -- zag binary not found at {s}; run `zig build install` first\n", .{ZAG_BIN});
            return true;
        }
        return err;
    };
    _ = std.os.linux.close(fd);

    for (cases) |case| {
        const efd = std.posix.openat(std.posix.AT.FDCWD, case.example, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("runtime_smoke: SKIP -- example {s} not found (untracked file or stale checkout?)\n", .{case.example});
                return true;
            }
            return err;
        };
        _ = std.os.linux.close(efd);
    }

    return false;
}

const RunResult = union(enum) {
    pass,
    fail: FailInfo,
};

const FailInfo = struct {
    actual: []const u8,
    exit_code: u8,
};

/// Fork the zag binary against `case.example`; capture stdout (and
/// stderr -- routed through the same pipe to match tests/e2e.zig's
/// discipline); assert substring containment of `case.expected` in
/// the captured pipe. Mirrors tests/e2e.zig's exact subprocess
/// shape: fork-then-pipe-then-dup2-then-execve in the child;
/// waitpid-then-drain in the parent.
fn runOne(case: TestCase) !RunResult {
    var pipe_fds: [2]i32 = undefined;
    if (std.os.linux.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const pid = std.math.cast(i32, std.os.linux.fork()) orelse return error.ForkFailed;
    if (pid == 0) {
        _ = std.os.linux.dup2(pipe_fds[1], 1);
        _ = std.os.linux.dup2(pipe_fds[1], 2);
        _ = std.os.linux.close(pipe_fds[0]);
        _ = std.os.linux.close(pipe_fds[1]);

        const allocator = std.heap.page_allocator;
        var arg_bufs: [3]?[:0]u8 = .{ null } ** 3;
        defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| allocator.free(buf);

        const argv_inputs = [_][]const u8{ ZAG_BIN, "run", case.example };
        var argv_z: [4]?[*:0]const u8 = .{ null } ** 4;
        for (argv_inputs, 0..) |arg, i| {
            const buf = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(buf, arg);
            arg_bufs[i] = buf;
            argv_z[i] = buf.ptr;
        }

        // envp: copy env_path.environ_entries[0..environ_count] into a
        // local [513]?[*:0]const u8 array (mirrors tests/e2e.zig's exact
        // construction byte-for-byte). zig 0.16 doesn't expose
        // std.posix.environ at the expected path, so the env_path
        // module owns the /proc/self/environ -> sentinel-terminated-
        // pointer-array translation.
        var envp_z: [513]?[*:0]const u8 = .{ null } ** 513;
        const env_count = @min(env_path.environ_count, envp_z.len - 1);
        for (env_path.environ_entries[0..env_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;
        const argv_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_z);
        const envp_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_z);
        const argv0: [:0]u8 = arg_bufs[0] orelse std.os.linux.exit(127);
        _ = std.os.linux.execve(argv0.ptr, argv_z_ptr, envp_z_ptr);
        std.os.linux.exit(127);
    }

    _ = std.os.linux.close(pipe_fds[1]);

    var out: [4096]u8 = undefined;
    var out_total: usize = 0;
    while (out_total < out.len) {
        const n = std.os.linux.read(pipe_fds[0], out[out_total..].ptr, out.len - out_total);
        if (n > std.math.maxInt(isize)) return error.ReadSyscallFailed;
        if (n == 0) break;
        out_total += n;
    }
    _ = std.os.linux.close(pipe_fds[0]);

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid, &status, 0);

    if (!std.os.linux.W.IFEXITED(status)) {
        return RunResult{ .fail = .{ .actual = out[0..out_total], .exit_code = 99 } };
    }
    const exit_code: u8 = @intCast(std.os.linux.W.EXITSTATUS(status));
    if (exit_code != 0) {
        return RunResult{ .fail = .{ .actual = out[0..out_total], .exit_code = exit_code } };
    }

    // Substring (NOT byte-exact) match: the pipe captures both stdout
    // AND stderr from the spawned zag process (matches tests/e2e.zig's
    // fd1+fd2 dup2 discipline). zig's compile-time noise
    // (`compiling /tmp/zag_cli.zag...`, `compiling <user>.zag...`, link
    // banner, etc.) lands on stderr BEFORE the user example's stdout,
    // so byte-exact match against the captured pipe would flake on any
    // compiler-version-induced stderr dissonance. Substring match
    // preserves the strong correctness signal we care about -- "the
    // trait dispatch site fired and the expected bytes reached the
    // user's stdout" -- while tolerating compiler noise.
    if (std.mem.indexOf(u8, out[0..out_total], case.expected) != null) {
        return RunResult.pass;
    }
    return RunResult{ .fail = .{ .actual = out[0..out_total], .exit_code = 0 } };
}
