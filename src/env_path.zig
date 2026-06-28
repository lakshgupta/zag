// -------------------------------------------------------------------
// Shared env-pass + cache-dir resolution helpers.
//
// Lifted out of `src/main.zig` and `tests/smoke.zig` so any future
// bug fix or signature change happens once instead of in lockstep
// across both compilation units. The pre-lift pattern was inline-
// duplicate: each binary had its own copy of (1) `readEnviron` +
// `environ_buf` + `environ_entries` + `environ_count`,
// (2) `getenv`, and (3) `resolveZagCacheDir` -- byte-for-byte
// identical minus doc strings. The lift collapses three concerns
// into one self-contained `env_path` module that exposes the env-
// pass arrays as `pub var` so downstream `runCommand` (main.zig)
// and `runProgram` (smoke.zig) can build their fork+execve
// envp_z vectors from the same arrays that `getenv` consults.
//
// Build wiring (build.zig):
//   - registered via `b.addModule("env_path", ...)` with
//     `.root_source_file = b.path("src/env_path.zig")`
//   - `addImport("env_path", env_path_mod)` on both
//     `mod` (main.zig's `zag` root) and `smoke_runner_mod`
//     (tests/smoke.zig's `smoke-runner` root), so each binary's
//     `@import("env_path")` resolves to its own BSS-initialised
//     copy of the env-pass arrays (each binary reads
//     `/proc/self/environ` once at startup; no IPC / shared
//     state across binaries).
//   - NOTE: deliberately does NOT call `addOptions("build_options",
//     options)` here -- env_path.zig does not import build_options.
//     The Phase-3 no-env fallback (`build_options.z_install`) is
//     threaded in by each caller as `resolveZagCacheDir`'s 2nd
//     argument (`comptime_fallback`). The parameter-passing shape
//     was a deliberate fix for zig 0.16's
//     "file exists in modules 'build_options' and 'build_options0'"
//     collision, which fires when three `addOptions("build_options",
//     ...)` calls share the same key across `mod`/`env_path_mod`/
//     `smoke_runner_mod`. See `resolveZagCacheDir`'s body comment
//     for the rationale.
//
// State visibility:
//   - `environ_entries` and `environ_count` are `pub var` so the
//     envp_z consumers in main.zig's `runCommand` and smoke.zig's
//     `runProgram` can read them directly. `pub fn` accessors
//     would add API surface without encapsulation payoff (the
//     consumer already walks the `entries[0..count]` slice
//     verbatim); the pub vars are read-only in practice (only
//     `readEnviron` mutates them).
//   - `environ_buf` is module-private (not `pub var`) -- only
//     `readEnviron` populates it and only `readEnviron`/`getenv`
//     consume it (the latter via `environ_entries`'s sentinel-
//     terminated pointers, whose pointers reference bytes inside
//     `environ_buf`). envp_z consumers never need direct read
//     access to the byte buffer -- they consume the parsed
//     `environ_entries[0..environ_count]` slice -- so `pub` would
//     leak implementation detail for no gain. Encapsulation-by-
//     default keeps future refactors free to swap the backing
//     store (mmap'd region, staged read, etc.) without breaking
//     any caller.
//   - `readEnviron`, `getenv`, `resolveZagCacheDir` are public
//     entry points; called once at startup from each binary's
//     `main` (after `readEnviron`, before `resolveZagCacheDir`,
//     before any `mkdir`/`materialize`).
//
// zig 0.16 type-system notes:
//   - `getenv` materialises a `[]const u8` slice via
//     `std.mem.span(entry_ptr)` once at the top of the iteration
//     because `std.mem.indexOfScalar`/`std.mem.eql` require
//     `[]const T` slices, not the `[*:0]const u8` many-pointer
//     raw form. See `getenv`'s body comment for the rationale.
//   - `resolveZagCacheDir` returns `[]const u8` slices, with
//     `bufPrint` filling the caller-provided scratch only on
//     the `$XDG_CACHE_HOME`/`$HOME` branches; `$ZAG_HOME` and
//     the `build_options.z_install` comptime fallback pass
//     through unchanged.
// -------------------------------------------------------------------

const std = @import("std");

/// Raw byte buffer holding `/proc/self/environ`'s NUL-separated
/// entries at startup. Sized for 131 KB / ~512 entries' worst
/// case (128 KB Linux default + a few KB headroom), matching the
/// pre-lift in-file buffer so a regression in the read-loop's
/// ceiling is caught as a smoke error rather than a silent
/// truncation. Module-private (not `pub var`) -- only
/// `readEnviron` directly reads/writes the byte array.
/// `getenv` consumes the parsed `environ_entries` slice and
/// runs `std.mem.span` over each entry's sentinel-terminated
/// pointer (whose bytes happen to live in `environ_buf`, but
/// `getenv` itself never indexes the byte array directly);
/// envp_z consumers (main.zig's `runCommand`, smoke.zig's
/// `runProgram`) read `environ_entries[0..environ_count]`
/// without touching the byte buffer at all. Direct access to
/// the byte buffer is an implementation detail.
var environ_buf: [131072]u8 = undefined;

/// Parsed-environment entries, NUL-terminated many-pointers
/// (`?:0]-style` so the envp_z consumers can pass them to
/// execve verbatim without re-allocating). `pub var` for direct
/// slice access by runCommand/runProgram. With `environ_count
/// == 0` (read failed) the array stays all-null, equivalent to
/// empty-envp behaviour -- matches the pre-lift file-scope var
/// contract in both callers.
pub var environ_entries: [512]?[*:0]const u8 = undefined;

/// Live entry count in `environ_entries[0..count]`. Updated by
/// `readEnviron` after each successful `/proc/self/environ` read.
/// `pub var` so envp_z consumers can bound their copy-loop:
/// `for (env_path.environ_entries[0..env_count])`.
pub var environ_count: usize = 0;

/// Read /proc/self/environ into `environ_buf` and split on null
/// terminators into `environ_entries`. Best-effort: any
/// openat/read error leaves `environ_count == 0` (= empty envp,
/// equivalent to a detached child).
///
/// Note: downstream `runCommand`/`runProgram` consume
/// `environ_entries` via their envp_z and forward to execve, so
/// the forked child gets a copy of the parent's
/// PATH/HOME/LANG/etc. execve itself does NOT do PATH lookup;
/// the *immediate* execve uses an absolute `zig_path` argv[0]
/// so it does not depend on env at that level. env-pass matters
/// for the recursive build's children (cc, `ld`, etc), which
/// DO need PATH resolution.
///
/// Defensive OOB paint: BSS-`undefined` Debug/ReleaseSafe
/// memory is 0xaa, not 0. POSIX /proc/self/environ ends with a
/// final NUL terminator and the kernel returns it in `n`, so the
/// loop normally terminates cleanly. But for a really-large env
/// where the read consumed exactly N bytes whose last byte is
/// non-NUL, the byte right after the kernel-returned bytes
/// (`environ_buf[n]`) is BSS-junk and the last entry's `:0`
/// sentinel would be a lie. Paint 0 here as a safety net.
pub fn readEnviron() void {
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

/// Walk `environ_entries` (populated by `readEnviron`) for an
/// entry whose key matches `name`. Returns the value slice
/// (everything after the first `=`) if found, else `null`. Empty
/// values (e.g. `FOO=`) are returned as an empty slice -- callers
/// can distinguish via `entry.len == 0` if they need to.
pub fn getenv(name: []const u8) ?[]const u8 {
    for (environ_entries[0..environ_count]) |maybe_entry| {
        const entry_ptr = maybe_entry orelse continue;
        // `entry_ptr` is a many-pointer [*:0]const u8; zig 0.16's
        // `std.mem.indexOfScalar` and `std.mem.eql` both require
        // `[]const T` slices (not pointers), so we materialise a
        // `[]const u8` from the NUL sentinel up-front.
        const entry_slice = std.mem.span(entry_ptr);
        const sep = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
        if (sep == name.len and std.mem.eql(u8, entry_slice[0..sep], name)) {
            return entry_slice[sep + 1..];
        }
    }
    return null;
}

/// Resolve the zag-managed cache directory at runtime per the
/// Phase 3 priority chain:
///
///   1. `$ZAG_HOME` if set (explicit user override; wins,
///      populated verbatim, trailing-slash tolerant via fs calls
///      that ignore double slashes)
///   2. `$XDG_CACHE_HOME/zag` if set (freedesktop.org cache
///      convention -- semantically correct for a reproducible
///      binary payload that can be re-materialized at any time)
///   3. `$HOME/.cache/zag` if neither above is set (POSIX-friendly
///      HOME fallback that honours XDG_CACHE_HOME's `~/.cache`
///      convention)
///   4. `comptime_fallback` (no-env fallback; callers pass
///      `build_options.z_install` from their own build-options
///      wiring). A stripped-CI container with no $ZAG_HOME /
///      $XDG_CACHE_HOME / $HOME still materialises at the
///      configured compile-time path.
///
/// Writes `$XDG_CACHE_HOME/zag` and `$HOME/.cache/zag` results
/// into `buf` (via `bufPrint`); `$ZAG_HOME` and the
/// `comptime_fallback` branches return their comptime slice
/// values without touching `buf`. `buf` should be at least
/// `PATH_MAX`-ish; both call sites use a 4096-byte scratch with
/// headroom over the typical 4 KB PATH_MAX / `PATH=...` length.
/// bufPrint failure (paths > 4096 bytes) is captured and the
/// `comptime_fallback` is returned instead, keeping the binary
/// panic-free.
///
/// Why the fallback is a parameter rather than `@import`-ing
/// `build_options` here: env_path.zig is registered as its own
/// Module in build.zig; if it independently imports
/// `build_options`, zig 0.16 generates a third `addOptions` call
/// sharing the same `"build_options"` key with `mod` (zag main)
/// and `smoke_runner_mod`, which auto-numbers the sub-modules
/// to `build_options`/`build_options0`/... and triggers a
/// "file exists in modules X and Y" conflict when env_path.zig's
/// `@import("build_options")` resolves. Threading the
/// comptime-default through `comptime_fallback` keeps env_path
/// free of `build_options` entirely; main.zig / smoke.zig pass
/// `build_options.z_install` from their own options wiring.
pub fn resolveZagCacheDir(buf: []u8, comptime_fallback: []const u8) []const u8 {
    if (getenv("ZAG_HOME")) |home| return home;
    if (getenv("XDG_CACHE_HOME")) |cache| {
        return std.fmt.bufPrint(buf, "{s}/zag", .{cache}) catch comptime_fallback;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.cache/zag", .{home}) catch comptime_fallback;
    }
    return comptime_fallback;
}

/// Test-only helper. Resets `environ_count` and populates
/// `environ_entries` from `entries` literally: each entry's bytes
/// (including its trailing NUL sentinel) is written into the
/// caller-provided `backing` buffer, and `environ_entries[i]` is set
/// to a sentinel-terminated slice pointing into `backing`. Tests
/// typically pass a stack-allocated byte buffer sized for a handful
/// of entries -- production code never calls this fn, so the test-
/// only shape stays localised at the bottom of the module.
///
/// Why `backing` is caller-provided rather than writing into the
/// module-private `environ_buf`: the (c) cleanup that tightened
/// `environ_buf`'s visibility to module-private (no `pub`) is
/// preserved by letting tests bring their own backing bytes. Prod
/// code still writes to `environ_buf`'s 131 KB reserve at startup
/// via `readEnviron`; tests routinely use a much smaller stack-
/// allocated scratch (e.g. 4 KB suffices for ~30 short entries).
///
/// Coercion walkthrough (the zig 0.16 slice-to-many-pointer shape
/// `readEnviron` already exercises): `backing[offset.. :0]` produces
/// a sentinel-terminated slice typed `[]const u8` with the `:0`
/// sentinel byte at index `offset + entry.len` (i.e. `backing[offset
/// + entry.len] == 0`). Subscripting `[0..entry.len]` narrows to
/// the entry's payload, dropping the sentinel byte from the slice's
/// length (the sentinel byte still lives in `backing` and is what
/// zig reads when a future call runs `std.mem.span(entry_ptr)`).
/// The `?[*:0]const u8` slot auto-wraps the slice as `Some(...)` on
/// assignment.
pub fn setEnvironForTesting(entries: []const []const u8, backing: []u8) void {
    environ_count = 0;
    var offset: usize = 0;
    for (entries) |entry| {
        if (environ_count >= environ_entries.len) break;
        const total = entry.len + 1;
        if (offset + total > backing.len) break;
        @memcpy(backing[offset..][0..entry.len], entry);
        backing[offset + entry.len] = 0;
        // Subscript first, then `:0` annotate at the tail -- mirrors
        // `readEnviron`'s `environ_buf[start..i :0]` shape verbatim so
        // the subscript order matches zig's `[a..b :0]` coercion path.
        // The reverse ordering `[a.. :0][0..n]` would yield a plain
        // `[]const u8` (sentinel annotation lost) that fails to coerce
        // into the `?[*:0]const u8` slot under zig 0.16's stricter
        // pointer-type rules.
        environ_entries[environ_count] = backing[offset..][0..entry.len :0];
        offset += total;
        environ_count += 1;
    }
}
