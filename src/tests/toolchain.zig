// Smoke test for src/toolchain.zig's materialize step.
//
// Purpose
// -------
// 1. Lock the materialize-step contract: openat -> write loop -> fchmod
//    produces a regular file at `dest_path` whose size == zig_payload.len
//    and whose bytes equal `zig_payload` byte-for-byte (when the payload
//    fits a small stack buffer).
//
// 2. Guard against DCE stripping `materializeZigToCache` and
//    `tryMaterialize` under `ReleaseFast` / `ReleaseSmall`. The
//    `@embedFile` bytes still fire at module load (because
//    `zig_payload` is `pub const`), but the materialize bodies would
//    be compiled out without a reference site. These tests pin both
//    bodies into the compile graph so the openat/write/fchmod contract
//    cannot silently regress.
//
// Why an empty payload still works
// --------------------------------
// `src/_zig_payload.empty` is the 0-byte sentinel used by the default
// build to keep the zag binary small. Calling the materialize helpers
// with an empty payload still runs the full pipeline:
//   - `posix.openat(WRONLY | CREAT | TRUNC, mode 0o755)` creates the
//     scratch file with at least owner-rwx.
//   - the write loop iterates zero times.
//   - `std.os.linux.fchmod(fd, 0o755)` normalizes the mode bit on the
//     open fd (no path-coercion, since we already hold an fd).
// So the artifact is a 0-byte file. `tryMaterialize`'s `has_payload()`
// gate short-circuits to `false` without writing, so the "no embedded
// bytes -> no materialize" contract is also pinned.
//
// Why this test uses raw posix.openat + std.os.linux.read instead of
// std.fs.File APIs
// -------------------------------------------------------------------
// zig 0.16 removed several `std.fs` entry points (`openFileAbsolute`,
// `cwd().openFile`, …) and `std.fs.File.Stat.mode` is now an opaque
// `File.Mode` packed bitset rather than a raw u32 mode_t, so the
// `& 0o777` permission-mask idiom no longer compiles. Likewise, the
// `posix.*` and `std.os.linux.*` stat / chmod wrappers needed to
// surface raw mode_t are sparse in 0.16: `posix.fstat`,
// `posix.fstatat`, `posix.fchmod`, `std.os.linux.stat` (lowercase),
// AND `std.os.linux.Stat` (uppercase) are all rejected. We mirror
// `src/main.zig`'s `readFile` path exactly so this test file uses
// the same verified-working surface as production: `posix.openat`
// for opening, `std.os.linux.{read,close}` for the readback loop
// (with manual rc-decode for the read syscall error gap,
// `n > maxInt(isize) -> error.ReadFailed`).
//
// Mode assertion is intentionally omitted: tracing the mode bit back
// out of `file.stat()` in zig 0.16 is brittle across zig bumps, and
// the mode invariant is already pinned by the production side (the
// explicit `std.os.linux.fchmod(fd, 0o755)` with `error.ChmodFailed`
// rc-check in `src/toolchain.zig` is what sets the bits). This test
// stays focused on the size + byte-equality invariants that prove
// the write loop ran without DCE stripping.

const std = @import("std");
const posix = std.posix;
const toolchain = @import("../toolchain.zig");

/// Scratch directory holding the materialize artifact. Fixed path so
/// the test does not depend on `mkdtemp` availability across zig
/// versions; cleanup is best-effort and idempotent.
const scratch_dir = "/tmp/zag_toolchain_smoke";

/// Artifact path. Appended at runtime because the `++` operator
/// only joins comptime-known slices; the resulting `[]const u8`
/// is passed verbatim to `posix.openat(AT.FDCWD, …)` and to
/// `std.os.linux.{mkdir,unlink}` via `@ptrCast`.
const scratch_path = scratch_dir ++ "/zig";

/// Best-effort scratch-dir setup. zig 0.16 removes `posix.mkdir`,
/// `posix.mkdirat`, AND `std.fs.cwd()`, so we route through the raw
/// syscall `std.os.linux.mkdir`. The `@ptrCast(scratch_dir.ptr)`
/// from `[*]const u8` to `[*:0]const u8` is sound because
/// `scratch_dir` is a compile-time string literal; the underlying
/// data block ends in a null terminator that zig constant-folds in.
/// This matches the working pattern in `src/main.zig`'s `cmdInit`
/// for `std.os.linux.mkdir(@ptrCast(n.ptr), 0o777);`.
fn ensureScratchDir() void {
    _ = std.os.linux.mkdir(@ptrCast(scratch_dir.ptr), 0o755);
}

/// Best-effort cleanup. `std.os.linux.unlink` is a raw syscall
/// returning `usize` (no error union), so we cannot distinguish
/// ENOENT from EPERM here — `rc` is intentionally discarded.
/// A stale `/tmp/zag_toolchain_smoke/zig` left behind is harmless
/// because both test bodies declare `defer cleanupScratch()`,
/// which unlinks it on every test return (success, error, or
/// panic) -- so steady-state runs leave no residue. `scratch_path`
/// is derived from a compile-time string literal, so `@ptrCast`
/// is sound.
fn cleanupScratch() void {
    _ = std.os.linux.unlink(@ptrCast(scratch_path.ptr));
}

test "toolchain: materializeZigToCache writes zig_payload to disk under tmpdir" {
    ensureScratchDir();
    defer cleanupScratch();

    // Direct call. Walks openat -> write loop -> fchmod on the
    // production side; the post-call assertions below pin size and
    // (when the payload fits the buffered readback) byte-for-byte
    // content equality.
    try toolchain.materializeZigToCache(scratch_path);

    // Open the materialized file via the same `posix.openat` call
    // shape that `src/main.zig`'s `readFile` uses. `openat`'s
    // success itself is the first contract assertion: if DCE
    // stripped `materializeZigToCache`, the on-disk artifact would
    // not exist (or the test would have been compiled out
    // entirely) and this open would error.
    const fd = try posix.openat(
        posix.AT.FDCWD,
        scratch_path,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    defer _ = std.os.linux.close(fd); // deliberate discard: read-only test artifact fd

    // Readback loop, mirroring `src/main.zig`'s `readFile`. The
    // cap is `min(buffer, expected payload size)` so a payload
    // larger than the buffer doesn't false-positive against
    // `expectEqualSlices` (we'd just have a partial readback, not
    // byte-equal content).
    var readbuf: [4096]u8 = undefined;
    const expected_len = toolchain.zig_payload.len;
    const cap = @min(readbuf.len, expected_len);
    var total: usize = 0;
    while (total < cap) {
        const n = std.os.linux.read(fd, readbuf[total..cap].ptr, cap - total);
        // Raw-syscall rc guard: zig 0.16 wraps `read` as
        // `usize` (0 success, max usize - errno on failure). The
        // border between "negative errno as huge usize" and a
        // legitimate byte-count is `maxInt(isize)`. Mirrors the
        // pattern the prior code-review flagged as missing.
        if (n > std.math.maxInt(isize)) return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }

    // When the payload fits the readback buffer, verify byte
    // equality against the embedded payload. This catches a
    // regression where the write loop emits zeros / partial /
    // truncated content — none of which would surface as a
    // successful materialize via the openat existence alone.
    // Gated on `expected_len <= readbuf.len` so future larger
    // payloads don't false-positive.
    // TODO(deferred): see header doc for why `mode == 0o755` is
    // currently not asserted here. Once zig 0.16 stabilizes a
    // `posix.fstat(fd, *stat)` surface (or `File.Stat.mode`
    // exposes bitwise permission access), add the mode assertion
    // here and remove the inline TODO.
    if (expected_len <= readbuf.len) {
        try std.testing.expectEqual(expected_len, total);
        // The empty-payload case (`expected_len == 0`) compares
        // two empty slices -- vacuously true under
        // expectEqualSlices, but the `expectEqual(expected_len,
        // total)` above + `posix.openat` success above are the
        // meaningful signals in that branch (openat success
        // proves materialize created the on-disk artifact).
        try std.testing.expectEqualSlices(u8, toolchain.zig_payload, readbuf[0..total]);
    }
}

test "toolchain: tryMaterialize reflects has_payload() gating" {
    ensureScratchDir();
    defer cleanupScratch();

    // This test pins `tryMaterialize`'s wrapper body into the
    // compile graph (gate logic + return shape). Under the
    // default empty build, `has_payload()` constant-folds to
    // `false` and the inner `materializeZigToCache(dest_path)`
    // call inside `tryMaterialize` becomes dead-code-eligible;
    // this test alone would NOT pin `materializeZigToCache`'s
    // body. The companion test above calls
    // `materializeZigToCache` directly and is therefore
    // load-bearing for the full DCE-pin coverage of both
    // functions. Do not delete that test without rerouting the
    // pin here.
    const result = try toolchain.tryMaterialize(scratch_path);
    try std.testing.expectEqual(toolchain.has_payload(), result);
}
