// End-to-end integration smoke for the materialize step.
//
// Purpose
// -------
// Unit tests in `src/tests/toolchain.zig` pin the materialize
// contract (openat -> write loop -> fchmod) at the in-process
// level. This integration smoke proves the FULL pipeline works
// from the build's perspective:
//
//   build.zig -Dzig_payload=<fixture> ->
//       build_options.zig_payload ->
//       toolchain.zig_pub const zig_payload ->
//       main.zig startup consults tryMaterialize ->
//       openat + write loop + fchmod at materialize-path
//
// Run via `zig build smoke`.
//
// If the fixture (`vendor/zig/zig.test`) is not staged yet, the
// smoke is a graceful no-op (prints SKIP, exit 0). Once a real
// zig binary lands at the fixture path, the smoke runs the full
// assertion pipeline without code changes. The fixture path is
// hardcoded at the top of this file: zig 0.16 removed
// `std.process.argsAlloc` from its surface map, so a CLI override
// is staged until that surface stabilises. To smoke a different
// path, edit the relevant const at the top:
// `fixture_default`, `materialize_default`, `zig_install`, or
// `zig_path`.
//
// Assertions when the fixture IS staged
// -------------------------------------
// 1. Pre-build: `zig build install -Dzig_payload=<fixture>`
//    produces `./zig-out/bin/zag` with the payload embedded.
// 2. Child run: `./zig-out/bin/zag version` exits 0 -- proves
//    main.zig's startup is healthy end-to-end (parseArgs,
//    tryMaterialize gate, version print).
// 3. Materialize path exists (file-not-found check).
// 4. Materialize path's mode has the executable bit set
//    (`access(path, X_OK) == 0`).
// 5. Materialize path's bytes are byte-equal to the fixture
//    -- proves the openat+write loop didn't truncate or
//    corrupt the embedded payload end-to-end.
//
// Why access(X_OK) instead of stat-based mode == 0o755
// ----------------------------------------------------
// zig 0.16's stat-derived permission-bit surface is sparse:
// `posix.fstat`, `std.os.linux.stat` (lowercase), and
// `std.os.linux.Stat` (uppercase) are all rejected by the
// compiler. `access(path, X_OK)` is a direct syscall (raw
// `std.os.linux.access`) that returns 0 if any permission class
// has the executable bit, sidestepping the missing struct path.
// `access X_OK == 0` confirms mode & 0o111 != 0 (which is true
// for 0o755 and also for e.g. 0o711, 0o775, etc.) -- not strict
// `0o755` equality, but catches the most common regression where
// the chmod step is dropped entirely and the file becomes 0o644
// (then X_OK would fail).
//
// Exact-mode === 0o755 assertion is staged for the same zig
// follow-up that the deferred-mode TODO in src/tests/toolchain.zig
// already captures.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const env_path = @import("env_path");

/// Default fixture path. Hardcoded at compile time: zig 0.16
/// removed `std.process.argsAlloc` from its surface map, so a CLI
/// override (e.g., `--fixture=<path>`) is staged until that surface
/// returns. To smoke a different path, edit this constant.
const fixture_default = "vendor/zig/zig.test";

/// Comptime fallback for the materialize path. Initial value
/// for `materialize` (declared below) before `resolveZagCacheDir`
/// overrides it at smoke startup. Same shape + same `build_options`
/// source-of-truth as the main zag binary's `zag_cache_zig_path`,
/// so Phase 2's `-Dz_install=<dir>` wiring still threads through
/// unchanged on the env-var-fallback path.
///
/// See `src/main.zig`'s `zag_cache_dir` doc for the runtime
/// resolution chain (`$ZAG_HOME` > `$XDG_CACHE_HOME/zag` >
/// `$HOME/.cache/zag` > `build_options.z_install`). The smoke
/// mirrors that resolution at startup so smoke's paths track
/// main's paths under env-var overrides -- symmetry by
/// construction.
const materialize_default = build_options.z_install ++ "/zig";

/// Path to the produced (and pre-built) `zag` binary. Hardcoded
/// to the `b.installArtifact` destination; the platform suffix is
/// derived at comptime from `builtin.os.tag` + `builtin.cpu.arch`
/// using the same `.macos`->`darwin` + `.aarch64`->`arm64` mapping
/// as build.zig's `targetOsString` / `targetArchString` (duplicated
/// locally because zig's module-graph rules forbid importing
/// build.zig's helpers here -- the build script lives outside this
/// runner's path scope).
const zig_install = "./zig-out/bin/zag" ++ comptimeOsArchSuffix();

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

/// Vendor-zig path. After `scripts/install.sh` runs inside a zag
/// source clone (detected by `build.zig` + `src/main.zig` presence),
/// the freshly-downloaded minimum-version zig is mirrored here so a
/// follow-up `zig build install -Dzig_payload=vendor/zig/zig` can
/// embed it as the production fetch path. The smoke's recursive
/// `zig build install` invocation prefers this over the dev-machine
/// `~/.local/zig/zig` whenever it is present at smoke-time.
const zig_vendor = "vendor/zig/zig";

/// Runtime-resolved zig path. `resolveZigPath` runs at smoke
/// startup and prefers the vendored zig if present, falling back to
/// `ZAG_ZIG_PATH`. The runtime check avoids baking the
/// wrong path into the smoke binary at compile-time.
var zig_path: []const u8 = undefined;

/// Phase 3 mirror of `src/main.zig`'s `zag_cache_dir` +
/// `zag_cache_zig_path` + scratch buffers. Initialised to
/// `build_options.z_install`-derived comptime fallback; overridden
/// at startup by `resolveZagCacheDir` after `readEnviron` populates
/// `environ_entries`. Tracking main.zig's resolution at runtime
/// (instead of statically `const`-baking at compile time) is what
/// keeps smoke's Step 4 + Step 6 byte-equality assertions coherent
/// with the main zag binary's materialize destination under any
/// env-var override.
var materialize_dir: []const u8 = build_options.z_install;
var materialize: []const u8 = materialize_default;
var materialize_dir_buf: [4096]u8 = undefined;
var materialize_buf: [4096]u8 = undefined;

/// Pick the runnable zig for the pre-build invocation: vendored (when
/// install.sh populated `vendor/zig/zig` during a clone-aware install)
/// first, then `ZAG_ZIG_PATH` env var.
fn resolveZigPath() []const u8 {
    if (fileExists(zig_vendor) catch false) {
        std.debug.print("smoke: zig resolved to {s} (vendor)\n", .{zig_vendor});
        return zig_vendor;
    }
    // zig 0.16 has no std.posix.getenv — the env_path module's
    // readEnviron()+getenv() pair is the codebase convention (this
    // binary already imports env_path for its fork+execve envp
    // propagation).
    env_path.readEnviron();
    if (env_path.getenv("ZAG_ZIG_PATH")) |zp| {
        std.debug.print("smoke: zig resolved to {s} (ZAG_ZIG_PATH)\n", .{zp});
        return zp;
    }
    @panic("zag smoke: zig not found. Set ZAG_ZIG_PATH or populate vendor/zig/zig with a real zig binary.");
}

// `readEnviron` / env-pass arrays / `getenv` / `resolveZagCacheDir`
// all live in `@import("env_path")` -- the lift that landed them
// in `src/env_path.zig` removed the byte-for-byte-identical copies
// that previously sat as file-scope globals in this smoke binary.
// `runProgram` reads `env_path.environ_count` + `env_path.environ_entries`
// for its fork+execve envp_z propagation. See `src/env_path.zig`'s
// top-of-file comment for the build-side wiring and the inherited
// rationale (Phase-1/2 env-pass followup + Phase-3 priority chain
// + dup-`readEnviron` cleanup -> single shared module).

pub fn main() !u8 {
    // One-shot smoke binary; leaked allocations are reclaimed by
    // the OS at process exit. zig 0.16 removed both
    // `std.heap.GeneralPurposeAllocator` and
    // `std.process.argsAlloc` from its surface map (multiple
    // cascading "root source file struct X has no member named Y"
    // compile errors), so we use the leak-tolerant `page_allocator`
    // global AND hardcode the fixture / materialize paths at the
    // top of this file (no runtime CLI override). Once zig 0.16
    // stabilises the sparse std surfaces, the paths can revert to
    // CLI-overridable form.
    const allocator = std.heap.page_allocator;

    // Paths hardcoded for zig 0.16 stdsurface compatibility. Override
    // by editing `fixture_default` / `materialize_default` / etc --
    // CLI override is staged until `std.process.argsAlloc` returns
    // to zig's surface map.
    const fixture = fixture_default;

    // Resolve the runnable zig for the pre-build invocation: prefer
    // `vendor/zig/zig` (populated by `scripts/install.sh` on
    // clone-aware installs) over the dev-machine `~/.local/zig/zig`
    // fallback. The resolution runs at smoke-time, not compile-time,
    // so the same binary works both before and after install.sh has
    // populated the vendored path.
    zig_path = resolveZigPath();

    // Phase 3 followup: resolve `materialize` from $ZAG_HOME /
    // $XDG_CACHE_HOME / $HOME (mirrors src/main.zig) so the smoke's
    // Step 4 + Step 6 byte-equality assertions track the main
    // binary's materialize destination under any env-var override.
    // Resolved path goes through the same 4096-byte scratch buffer
    // shape as main.zig so the two stay coherent at startup.
    // `readEnviron()` is called immediately after to populate the
    // env arrays consulted by `getenv` (called transitively via
    // `resolveZagCacheDir`).
    env_path.readEnviron();
    materialize_dir = env_path.resolveZagCacheDir(&materialize_dir_buf, build_options.z_install);
    materialize = std.fmt.bufPrint(&materialize_buf, "{s}/zig", .{materialize_dir}) catch materialize_default;

    // The `readEnviron()` call itself fired above (alongside
    // `resolveZagCacheDir` + `bufPrint`) so `getenv` saw a
    // populated env-pass array at startup. This comment block
    // stays to document the env-pass / runProgram semantics
    // referenced elsewhere:
    //
    // `runProgram` consumes `environ_entries` via its `envp_z`
    // and forwards to execve, so the forked zig-build-install
    // child gets the parent's PATH/HOME/LANG -- important for
    // its recursive grandchildren (cc, `ld`, etc) which DO need
    // PATH. execve itself does NOT do PATH lookup;
    // `pre_build_argv[0]` is the absolute `zig_path` from
    // `resolveZigPath`, so the immediate execve doesn't depend
    // on env. (Phase-2-env-pass followup confirmed the historical
    // "execve ENOENT despite env read" was a POSIX `execve(2)`
    // semantics misunderstanding, not an env-pass bug --
    // execve(2) never did PATH lookup; that's `execvpe(3)`'s
    // domain.)
    //
    // Note: the SKIP branch (Step 1's early-return on missing
    // fixture) fires on every smoke invocation today -- the
    // fixture is not yet staged in this repo's working tree, so
    // `zig build smoke` always SKIPs and always pays this read.
    // Once a real zig binary lands at `vendor/zig/zig.test`, the
    // SKIP branch becomes rare in normal dev/CI runs (any time
    // the fixture is missing -- fresh checkouts before staging,
    // temporary debug-removal, manual deletion -- hits it).
    // Either way, the read is a single `openat`-`read`-`close`
    // triple (<1ms), and "read once at startup" is worth more
    // than per-branch early-exit savings.

    // Self-cleanup: unlink the materialize path on every exit path
    // (success, skip, failure mid-assertion). Mirrors `src/tests/toolchain.zig`'s
    // `cleanupScratch` shape (`@ptrCast + std.os.linux.unlink + rc discarded`).
    // The materialize cache is regenerated by each `zag version` run
    // (openat WRONLY|CREAT|TRUNC + write + fchmod), so an exit-time
    // unlink keeps CI clean for the next run and protects against
    // false-green passes from a stale prior artifact. ENOENT vanishes
    // in the discarded rc.
    defer _ = std.os.linux.unlink(@ptrCast(materialize.ptr));

    // ----- Step 1: fixture presence. If absent, graceful skip. -----
    if (!(try fileExists(fixture))) {
        std.debug.print("smoke: SKIP -- fixture {s} not found\n", .{fixture});
        std.debug.print("hint: stage a real zig binary at {s} to enable end-to-end test.\n", .{fixture});
        return 0;
    }

    // ----- Step 2: pre-build zag with the override, producing -----
    // `zig-out/bin/zag` whose embedded payload is the fixture.
    // `dp_arg_buf` is runtime-alloc'd via `allocPrint` because
    // the comptime-`++` of a literal prefix against the
    // file-scope fixture slice may produce a `*const [N:0]u8`-
    // shaped sentinel-terminated-pointer type whose array-
    // literal-coercibility into the `[_][]const u8` initializer
    // slot in zig 0.16 was not exercised in our tests -- so
    // runtime-`allocPrint` sidesteps that uncertainty by
    // returning a guaranteed `[]const u8`.
    const dp_arg_buf: []u8 = try std.fmt.allocPrint(allocator, "-Dzig_payload={s}", .{fixture});
    defer allocator.free(dp_arg_buf);
    const dp_arg: []const u8 = dp_arg_buf;
    const pre_build_argv = [_][]const u8{
        zig_path, "build", "install",
        dp_arg,
    };
    const pre_build_rc = runProgram(allocator, &pre_build_argv) catch |err| {
        std.debug.print("smoke: FAIL -- pre-build fork/exec error: {s}\n", .{@errorName(err)});
        return 11;
    };
    if (pre_build_rc != 0) {
        std.debug.print("smoke: FAIL -- `zig build install -Dzig_payload={s}` exited {d}\n", .{ fixture, pre_build_rc });
        return 10;
    }

    // ----- Step 3: child run `./zig-out/bin/zag version`. -----
    // Triggers main.zig's startup path: tryMaterialize gates on
    // build_options.zig_payload (non-empty), openat+write+fchmod
    // land bytes at `materialize`.
    const zag_version_argv = [_][]const u8{ zig_install, "version" };
    const zag_version_rc = runProgram(allocator, &zag_version_argv) catch |err| {
        std.debug.print("smoke: FAIL -- zag-version fork/exec error: {s}\n", .{@errorName(err)});
        return 21;
    };
    if (zag_version_rc != 0) {
        std.debug.print("smoke: FAIL -- `{s} version` exited {d}\n", .{ zig_install, zag_version_rc });
        return @intCast(zag_version_rc);
    }

    // ----- Step 4: materialize path exists. -----
    if (!(try fileExists(materialize))) {
        std.debug.print("smoke: FAIL -- materialize path {s} missing after zag version\n", .{materialize});
        std.debug.print("hint: did main.zig's tryMaterialize run? expected it to surface {s}\n", .{fixture});
        return 3;
    }

    // ----- Step 5: executable bit (access X_OK == 0). -----
    if (!try isExecutable(materialize)) {
        std.debug.print("smoke: FAIL -- materialize path {s} lacks +x bit on disk\n", .{materialize});
        return 4;
    }

    // ----- Step 6: byte-equality fixture vs materialize. -----
    const bytes_match = bytesEqual(allocator, fixture, materialize) catch |err| {
        std.debug.print("smoke: FAIL -- byte-equality read error: {s}\n", .{@errorName(err)});
        return 5;
    };
    if (!bytes_match) {
        std.debug.print("smoke: FAIL -- on-disk bytes at {s} differ from fixture {s}\n", .{ materialize, fixture });
        return 6;
    }

    std.debug.print("smoke: PASS -- {s} == bytes of {s}, executable, exists\n", .{ materialize, fixture });
    return 0;
}

/// Cheap file-existence check via openat for RDONLY. ENOENT returns
/// false; other open errors propagate. Matches the `if (try
/// fileExists(...))` pattern in `src/tests/toolchain.zig`'s
/// ensureScratchDir (but inverted: here we care about the file
/// existing, not the parent dir).
fn fileExists(path: []const u8) !bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    _ = std.os.linux.close(fd);
    return true;
}

/// `access(path, X_OK)` via raw syscall. `std.os.linux.access`
/// returns 0 on success (any permission class has +x), max usize -
/// errno on failure. maxInt(isize) is the size boundary between a
/// legitimate 0 return and an errno-encoded value. `X_OK = 1`
/// per linux `<unistd.h>`; we pass the literal rather than
/// importing `std.os.linux.X_OK` (which zig 0.16 doesn't expose
/// in its surface map). A `/* X_OK */` comment here is parsed by
/// the zig 0.16 lexer as a binary `/` operator -- hence the `//`
/// trailing comment instead.
fn isExecutable(path: []const u8) !bool {
    const rc = std.os.linux.access(@ptrCast(path.ptr), 1);
    if (rc > std.math.maxInt(isize)) return error.AccessSyscallFailed;
    return rc == 0;
}

/// Read the entire contents of `path` into a heap buffer. Mirrors
/// `src/main.zig`'s readFile pattern (`posix.openat` + raw
/// `std.os.linux.read` loop with manual rc-decode).
/// Caller owns the returned buffer.
fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);

    var buf_size: usize = 64 * 1024;
    var buf = try allocator.alloc(u8, buf_size);
    errdefer allocator.free(buf);

    var total: usize = 0;
    while (true) {
        if (total == buf.len) {
            buf_size *= 2;
            buf = try allocator.realloc(buf, buf_size);
        }
        const n = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        if (n > std.math.maxInt(isize)) return error.ReadSyscallFailed;
        if (n == 0) break;
        total += n;
    }

    return buf[0..total];
}

/// Compare two files byte-for-byte. Reads both into buffers,
/// `std.mem.eql` on the slices. The 50 MB zig-binary case hits
/// the grow path; smaller fixtures stay in the initial 64 KB.
fn bytesEqual(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const a_bytes = try readAll(allocator, a);
    defer allocator.free(a_bytes);
    const b_bytes = try readAll(allocator, b);
    defer allocator.free(b_bytes);
    return std.mem.eql(u8, a_bytes, b_bytes);
}

/// Generic fork+execve-and-wait. Mirrors `src/main.zig`'s
/// `runCommand` shape including env-propagation via the file-scope
/// `environ_entries` (read at smoke startup from
/// `/proc/self/environ`). Slimmed from `main.zig` only by the
/// hardcoded `zig_path` (no runtime PATH lookup -- the pre-build
/// forked child uses an absolute path so execve never has to
/// resolve "zig"). The env-pass IS active: `envp_z` (populated
/// from `environ_entries` below) is passed to execve, so the
/// recursive zig-build-install child's grandchildren (cc, `ld`,
/// etc) can PATH-resolve naturally. execve itself doesn't do PATH
/// lookup -- the immediate execve uses the absolute `zig_path`
/// argv[0]. Returns the child's exit code (or 255 if killed by
/// signal).
fn runProgram(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len == 0) return error.NoArgs;
    if (argv.len > 14) return error.TooManyArgs;

    var arg_bufs: [15]?[:0]u8 = .{ null } ** 15;
    defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| allocator.free(buf);

    var argv_z: [15]?[*:0]const u8 = .{ null } ** 15;
    for (argv, 0..) |arg, i| {
        const buf = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(buf, arg);
        arg_bufs[i] = buf;
        argv_z[i] = buf.ptr;
    }

    // Inherit parent's environ (read at smoke startup from
    // /proc/self/environ) for the staged env-pass follow-up. The
    // 513-slot envp_z mirrors `src/main.zig` exactly -- including
    // the trailing null sentinel at index 512 -- so a future
    // re-aim that re-activates the envpass has one fewer
    // invariant to debug against cross-file changes. With
    // environ_count == 0 (read failed) the array stays all-null,
    // equivalent to empty-envp behaviour.
    var envp_z: [513]?[*:0]const u8 = .{ null } ** 513;
    const env_count = @min(env_path.environ_count, envp_z.len - 1);
    for (env_path.environ_entries[0..env_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;
    const argv_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_z);
    const envp_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_z);

    const pid = std.math.cast(i32, std.os.linux.fork()) orelse return error.ForkFailed;
    if (pid == 0) {
        const buf0: [:0]u8 = arg_bufs[0] orelse std.os.linux.exit(127);
        _ = std.os.linux.execve(buf0.ptr, argv_z_ptr, envp_z_ptr);
        std.os.linux.exit(127);
    }

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid, &status, 0);
    if (std.os.linux.W.IFEXITED(status)) {
        return std.os.linux.W.EXITSTATUS(status);
    }
    return 255;
}
