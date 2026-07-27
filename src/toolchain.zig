// -------------------------------------------------------------------
// Phase 2 -Dzig_payload wired.
//
// The compile-time gate (`zig_payload`, `zig_payload_len`,
// `has_payload`) is the same shape as Phase 1, but the bytes now
// flow through a `build_options` module attached by `build.zig`
// rather than a static `@embedFile`. `materializeZigToCache` and
// `tryMaterialize` are unchanged. main.zig's startup now consults
// `tryMaterialize` (Phase 1 follow-up that landed in the prior
// commit), so a build with `-Dzig_payload=<path>` round-trips
// end-to-end: `build.zig` reads the file at config time ->
// `build_options.zig_payload` -> `toolchain.zig`'s `pub const
// zig_payload` -> main runtime consultation -> `tryMaterialize` ->
// openat + write loop + fchmod at `zag_cache_zig_path` (or fall
// back to `zig_install_path` on the empty-payload default). The
// installer-script network fetch path remains the active fall-
// through for first-time installs with an empty sentinel.
// -------------------------------------------------------------------

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");

/// Vendor zig payload, supplied at build time via the `-Dzig_payload`
/// build option (default: `src/_zig_payload.empty` 0-byte sentinel).
///
/// Under the test module (`zig build test`) this const materialises
/// the test binary's own copy of the payload -- the test binary is
/// compiled when `src/tests/toolchain.zig`'s `_ =
/// @import("../toolchain.zig")` is reached from the test module
/// graph. The test binary is NOT installed (no `b.installArtifact`
/// call in build.zig for it), so the test binary's embed copy never
/// lands in `zig-out/bin/zag-<os>-<arch>`.
///
/// In the production binary, this module is NOT a transitive
/// dependency after the test-module split (main.zig no longer
/// pulls `src/tests/toolchain.zig` in via its trailing comptime
/// block). The production binary's payload view comes from
/// `src/main.zig`'s `pub const embedded_zig_payload`, which reads
/// the same `build_options.zig_payload` value (one storage
/// location).
///
/// KNOWN CAVEAT: under zig 0.16 the produced binary lands at
/// roughly 3.5x the embedded payload size because `pub const X:
/// []const u8 = ...` is duplicated under slice-inlining rules
/// (verified chunk-hash: every 4 MB chunk of the payload appears
/// exactly 2 times in the produced binary). The duplication is
/// structural to zig 0.16 and shows in BOTH this `addOption`
/// flow and an earlier `@embedFile` migration attempt (same ~3.5x
/// ratio). A future zig version that collapses inlined slices
/// could revisit; for now the for-loop pin in main.zig is the
/// minimum-cost workaround.
pub const zig_payload: []const u8 = build_options.zig_payload;

/// Comptime length of the embedded payload. Exposed as a const so it
/// folds in dead-code elimination: when 0, zig strips any payload-
/// branching code at compile time, so the empty-payload binary is
/// no larger than today's.
pub const zig_payload_len: usize = zig_payload.len;

/// True when the build was run with a non-empty payload. Folds to a
/// compile-time constant so call sites read like runtime checks but
/// don't survive into the binary when the payload is empty.
pub fn has_payload() bool {
    return zig_payload_len > 0;
}

/// Materialize the embedded zig payload to `dest_path` and chmod +x on
/// POSIX. Caller picks `dest_path` (typically `$ZAG_HOME/zig/zig`).
/// POSIX-only by design — main.zig is already Linux-scoped via
/// `std.os.linux.*` calls and Windows portability is staged for a
/// follow-up (install.ps1 has its own download path).
///
/// On success, `dest_path` is a runnable zig binary equivalent to the
/// on-disk release the build was staged with. Callers (main.zig)
/// should guard with `if (has_payload())` before calling — the
/// function does not check, so an empty payload would truncate
/// `dest_path` to 0 bytes.
pub fn materializeZigToCache(dest_path: []const u8) !void {
    // Open with O_WRONLY | O_CREAT | O_TRUNC, mode 0o755. The mode
    // applies on creation; umask may trim group/other bits. fchmodat
    // below normalizes after the write so the materialize result is
    // owner-rwx regardless of umask.
    const fd = try posix.openat(
        posix.AT.FDCWD,
        dest_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o755,
    );
    defer _ = std.os.linux.close(fd);

    // Loop-write the embedded bytes; partial writes return short-
    // count and we resume. Mirrors main.zig's writeFile so the
    // codebase has one consistent write pattern. n == 0 means
    // EOF-error (regular files don't return 0 unless the file is
    // truncated under us; we surface error.WriteFailed in that case).
    var written: usize = 0;
    while (written < zig_payload.len) {
        const n = std.os.linux.write(fd, zig_payload[written..].ptr, zig_payload.len - written);
        if (n == 0) return error.WriteFailed;
        written += n;
    }

    // chmod 0o755 via the open fd, propagating EPERM/EROFS so the
    // failure surfaces at the materialize step rather than as a
    // confusing execve-permission-denied later at startup. zig
    // 0.16's `std.os.linux.fchmod(fd, mode) usize` returns the raw
    // syscall value (0 success, ~err max on error) — we manually
    // decode it (matching the read-loop pattern in
    // tests/toolchain.zig) and surface `error.ChmodFailed` on any
    // non-zero rc.
    const rc_fchmod = std.os.linux.fchmod(fd, 0o755);
    if (rc_fchmod != 0) return error.ChmodFailed;
}

/// Convenience wrapper around `materializeZigToCache` that gates on
/// `has_payload()`. Returns `true` when the materialize ran, `false`
/// when there was nothing to materialize. Caller can use the bool to
/// decide whether to update `zig_path` to point at the new binary.
/// Today the function is unused by main.zig (the install path is
/// still active); wire-up lives in the Phase 1 follow-up.
pub fn tryMaterialize(dest_path: []const u8) !bool {
    if (!has_payload()) return false;
    try materializeZigToCache(dest_path);
    return true;
}
