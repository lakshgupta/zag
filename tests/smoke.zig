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
const build_options = @import("build_options");

/// Default fixture path. Hardcoded at compile time: zig 0.16
/// removed `std.process.argsAlloc` from its surface map, so a CLI
/// override (e.g., `--fixture=<path>`) is staged until that surface
/// returns. To smoke a different path, edit this constant.
const fixture_default = "vendor/zig/zig.test";

/// Default materialize path. Threaded through `build_options.z_install`
/// (set by `zig build smoke -Dz_install=<dir>` in `build.zig`'s
/// `smoke_runner_mod.addOptions("build_options", options)` wiring) and
/// shaped as `<z_install>/zig` via comptime `++` to mirror
/// `src/main.zig`'s `zag_cache_zig_path` shape exactly. Without
/// `-Dz_install`, both default to `/home/lex/.local/zag/zig/zig` (the
/// pre-Phase-2 hardcode), so smoke's Step 4 (materialize-path exists)
/// + Step 6 (byte-equality fixture vs materialize) keep matching main
/// under the all-defaults build; with `-Dz_install=<dir>`, they
/// track the override together. Symmetry-by-construction: any
/// future zig version that relaxes the hardcode constraint can swap
/// only main.zig + smoke.zig in lockstep.
const materialize_default = build_options.z_install ++ "/zig";

/// Path to the produced (and pre-built) `zag` binary. Hardcoded
/// to the `b.installArtifact` destination.
const zig_install = "./zig-out/bin/zag";

/// Vendor-zig path. After `scripts/install.sh` runs inside a zag
/// source clone (detected by `build.zig` + `src/main.zig` presence),
/// the freshly-downloaded minimum-version zig is mirrored here so a
/// follow-up `zig build install -Dzig_payload=vendor/zig/zig` can
/// embed it as the production fetch path. The smoke's recursive
/// `zig build install` invocation prefers this over the dev-machine
/// `~/.local/zig/zig` whenever it is present at smoke-time.
const zig_vendor = "vendor/zig/zig";

/// Dev-machine zig fallback. The historical `src/main.zig`
/// `zig_install_path` style hardcode; used when no vendored zig is
/// available (i.e. the smoke is running on a machine where
/// `install.sh` was never invoked, or where the user's clone
/// predated the vendoring support).
const zig_dev_local = "/home/lex/.local/zig/zig";

/// Runtime-resolved zig path. `resolveZigPath` runs at smoke
/// startup and prefers the vendored zig if present, falling back to
/// the dev-machine install. The runtime check avoids baking the
/// wrong path into the smoke binary at compile-time when the user
/// has installed but also has a legacy dev-machine zig.
var zig_path: []const u8 = undefined;

/// Pick the runnable zig for the pre-build invocation: vendored (when
/// install.sh populated `vendor/zig/zig` during a clone-aware install)
/// first, dev-machine install (`~/.local/zig/zig`) as the legacy
/// fallback. The vendored path wins because that binary is the one the
/// user explicitly mirrored -- avoiding a stale dev-machine path can
/// mask regressions where the user's dev zig is older than the project
/// floor.
///
/// Why openat for the existence check instead of `std.fs.cwd().statFile`:
/// zig 0.16's sparse `std.fs.*` surface rejected those calls in earlier
/// rounds. `posix.openat` is the verified-working surface and already
/// used by `fileExists` elsewhere in this file.
///
/// One-line `smoke: zig resolved to ...` diagnostic so a CI failure
/// with the wrong zig picked (e.g., stale dev-machine fallback after
/// a fresh clone where vendor/zig/ is unpopulated) is bisectable by
/// grep without rerunning with extra logging flags attached.
fn resolveZigPath() []const u8 {
    if (fileExists(zig_vendor) catch false) {
        std.debug.print("smoke: zig resolved to {s} (vendor)\n", .{zig_vendor});
        return zig_vendor;
    }
    std.debug.print("smoke: zig resolved to {s} (dev fallback)\n", .{zig_dev_local});
    return zig_dev_local;
}

/// `readEnviron` infrastructure (currently unused, retained for the
/// zig-0.16-stabilisation followup). When the smoke was first wired,
/// `runProgram` empty-envp caused the forked `zig build install`
/// child to exit 127 (execve could not resolve the PATH-only `zig`
/// name). We added this machinery — read `/proc/self/environ` at
/// startup, parse NUL-separated entries into `[:0]u8` slices, pass
/// them through `runProgram`'s `envp_z` — mirroring `src/main.zig`'s
/// verified-working `readEnviron` pattern. Empirically, the env was
/// read correctly into `environ_entries` (PATH was present and pointed
/// at the right directory), but execve from the forked child still
/// returned ENOENT. The exact root cause was not isolated (the
/// plausible candidates are zig 0.16 fork+execve surface interactions
/// around sentinel-terminated BSS slices and the envp-many-pointer
/// coercion, but a controlled binary-search diagnostic was not run
/// before pivoting). The pragmatic mitigation was to hardcode
/// `zig_path` to the absolute path of the user's zig install, which
/// sidesteps execve's PATH lookup entirely. The infrastructure stays
/// in place so a future followup can re-investigate the env-pass
/// approach (refine the read, swap to `execvpe`, or trim if
/// unneeded); buffer sizes match `src/main.zig`'s so the same 131 KB /
/// 512-entries upper bounds apply if the followup reactivates the read.
var environ_buf: [131072]u8 = undefined;
var environ_entries: [512]?[*:0]const u8 = undefined;
var environ_count: usize = 0;

/// Read /proc/self/environ into `environ_buf` and split on null
/// terminators into `environ_entries`. Best-effort: any
/// openat/read error leaves `environ_count == 0` (= empty envp,
/// equivalent to a detached child).
///
/// Note: `runProgram` consumes `environ_entries` via its `envp_z`
/// and forwards to execve, so the forked zig-build-install child
/// gets a copy of the parent's PATH/HOME/LANG/etc. execve itself
/// does NOT do PATH lookup; the *immediate* execve uses the
/// absolute `zig_path` argv[0] from `resolveZigPath` so it does
/// not depend on env at that level. env-pass matters for the
/// recursive build's children (cc, `ld`, etc), which DO need
/// PATH resolution.
///
/// Defensive OOB paint: BSS-`undefined` Debug/ReleaseSafe
/// memory is 0xaa, not 0. POSIX /proc/self/environ ends with a
/// final NUL terminator and the kernel returns it in `n`, so
/// the loop normally terminates cleanly. But for a really-large
/// env where the read consumed exactly N bytes whose last byte
/// is non-NUL, the byte right after the kernel-returned bytes
/// (`environ_buf[n]`) is BSS-junk and the last entry's `:0`
/// sentinel would be a lie. Paint 0 here as a safety net.
fn readEnviron() void {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return;
    const n = std.os.linux.read(fd, &environ_buf, environ_buf.len);
    _ = std.os.linux.close(fd);
    if (n < environ_buf.len) environ_buf[n] = 0;

    environ_count = 0;
    var i: usize = 0;
    while (i < n and environ_count < 512) {
        const start = i;
        while (i < n and environ_buf[i] != 0) : (i += 1) {}
        environ_entries[environ_count] = environ_buf[start..i :0];
        environ_count += 1;
        i += 1;
    }
}

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
    // by editing these constants -- CLI override is staged until
    // `std.process.argsAlloc` returns to zig's surface map.
    const fixture = fixture_default;
    const materialize = materialize_default;

    // Resolve the runnable zig for the pre-build invocation: prefer
    // `vendor/zig/zig` (populated by `scripts/install.sh` on
    // clone-aware installs) over the dev-machine `~/.local/zig/zig`
    // fallback. The resolution runs at smoke-time, not compile-time,
    // so the same binary works both before and after install.sh has
    // populated the vendored path.
    zig_path = resolveZigPath();

    // Read /proc/self/environ into the file-scope env-pass arrays.
    // `runProgram` consumes them via `envp_z` and forwards to
    // execve, so the forked zig-build-install child gets the
    // parent's PATH/HOME/LANG -- important for its recursive
    // grandchildren (cc, `ld`, etc) which DO need PATH. execve
    // itself does NOT do PATH lookup; `pre_build_argv[0]` is the
    // absolute `zig_path` from `resolveZigPath`, so the immediate
    // execve doesn't depend on env. (Phase-2-env-pass followup
    // confirmed the historical "execve ENOENT despite env read"
    // was a POSIX `execve(2)` semantics misunderstanding, not an
    // env-pass bug -- execve(2) never did PATH lookup; that's
    // `execvpe(3)`'s domain.)
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
    readEnviron();

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
    const env_count = @min(environ_count, envp_z.len - 1);
    for (environ_entries[0..env_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;
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
