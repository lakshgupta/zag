//! Shared syscall layer for the compiler's own file IO.
//!
//! Raw `std.os.linux.*` calls report failure *inside the value* rather
//! than through an error union: a `usize`-returning call sets bit 63, an
//! `isize`-returning call returns a negative number. Deciding that by
//! hand at each call site is how the compiler came to have a `writeFile`
//! that **reported success on a failed write**:
//!
//!     var written: usize = 0;
//!     while (written < content.len) {
//!         const n = std.os.linux.write(fd, content[written..].ptr, content.len - written);
//!         if (n == 0) return error.WriteFailed;   // never taken: errno != 0
//!         written += n;                           // errno-encoded usize
//!     }                                           // counter runs away, loop exits, "OK"
//!
//! The same shape in `readFile` let the byte counter pass the end of the
//! buffer, so the returned slice could point past `file_buf`.
//!
//! This module is the one place that decodes those results, retries
//! EINTR, and loops over short transfers. Callers get a plain Zig error
//! union; a caller that needs the errno reads `lastErrnoName()`.
//!
//! `std.posix` is not an option for most of this in zig 0.16 — the
//! facade only binds `openat`/`openatZ`/`read`, and the project's
//! convention is raw `std.os.linux.*` for the primitives anyway
//! (AGENTS.md §Conventions, `## zig 0.16 pitfalls` §2).

const std = @import("std");

// ── errno vocabulary ─────────────────────────────────────────────────
//
// Named values so no call site compares against a bare literal.
pub const EPERM: isize = 1;
pub const ENOENT: isize = 2;
pub const EINTR: isize = 4;
pub const EIO: isize = 5;
pub const EBADF: isize = 9;
pub const ECHILD: isize = 10;
pub const EACCES: isize = 13;
pub const EEXIST: isize = 17;
pub const ENOTDIR: isize = 20;
pub const EISDIR: isize = 21;
pub const EINVAL: isize = 22;
pub const ENOSPC: isize = 28;
pub const EROFS: isize = 30;
pub const ENAMETOOLONG: isize = 36;
pub const EOVERFLOW: isize = 75;
pub const ENOTSUP: isize = 95;

/// Everything this layer can fail with. Deliberately coarse — the caller
/// that needs detail reads `lastErrno()` / `lastErrnoName()`.
pub const Error = error{
    PathTooLong,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    CloseFailed,
    MkdirFailed,
    WaitFailed,
};

/// errno of the most recent failure. The compiler's IO is single
/// threaded, so one slot is enough and keeps the helpers total.
var last_errno: isize = 0;

pub fn lastErrno() isize {
    return last_errno;
}

/// Name of the most recent failure's errno ("ENOENT", "EEXIST"), for a
/// diagnostic. Returns "errno <n>" for a number the table doesn't name.
pub fn lastErrnoName() []const u8 {
    return errnoName(last_errno);
}

var name_buf: [32]u8 = undefined;

pub fn errnoName(errno: isize) []const u8 {
    const n: []const u8 = switch (errno) {
        1 => "EPERM",
        2 => "ENOENT",
        4 => "EINTR",
        5 => "EIO",
        9 => "EBADF",
        10 => "ECHILD",
        13 => "EACCES",
        17 => "EEXIST",
        20 => "ENOTDIR",
        21 => "EISDIR",
        22 => "EINVAL",
        28 => "ENOSPC",
        30 => "EROFS",
        36 => "ENAMETOOLONG",
        75 => "EOVERFLOW",
        95 => "ENOTSUP",
        else => "",
    };
    // Not in the table: fall back to the number so a diagnostic never
    // degrades to a bare "unknown". errno 0 means "no failure recorded",
    // which every errnoName call site reads as "none".
    if (n.len != 0) return n;
    if (errno == 0) return "none";
    return std.fmt.bufPrint(&name_buf, "errno {d}", .{errno}) catch "errno";
}

// ── raw result decoding ──────────────────────────────────────────────

/// True when a `usize`-returning raw syscall reported failure — bit 63
/// is the kernel's sign bit for the errno-encoded return.
pub fn isErr(rc: usize) bool {
    return (rc & 0x8000000000000000) != 0;
}

/// The positive errno of a `usize`-returning raw syscall result.
/// `@bitCast`, never `@intCast`: the value has the high bit set, which
/// is exactly the case a checked cast would trap on.
pub fn errnoOfUsize(rc: usize) isize {
    const signed: isize = @bitCast(rc);
    return 0 -% signed;
}

/// The positive errno of an `isize`-returning raw syscall result.
pub fn errnoOfSigned(rc: isize) isize {
    return 0 -% rc;
}

/// Record `errno` and hand back the error, so a failure is never
/// returned without its cause.
fn fail(e: Error, errno: isize) Error {
    last_errno = errno;
    return e;
}

/// Copy `path` into `dst` with a trailing NUL — the sentinel form every
/// `*Z`-suffixed raw syscall requires. Bounds-checked: the previous
/// unchecked `@memcpy` into a `[512]u8` was a buffer overrun waiting for
/// a long path.
fn pathZ(dst: []u8, path: []const u8) Error![:0]const u8 {
    if (path.len + 1 > dst.len) return fail(error.PathTooLong, ENAMETOOLONG);
    @memcpy(dst[0..path.len], path);
    dst[path.len] = 0;
    return dst[0..path.len :0];
}

// ── transfers ────────────────────────────────────────────────────────

/// One read(2), retrying EINTR only. `Ok(0)` is EOF; a short transfer
/// is normal for a pipe and is handed straight back. This is the form a
/// drain loop wants — a line reader or a stderr capture must return
/// after whatever one `read(2)` produced, not block until the buffer
/// fills.
pub fn readSome(fd: i32, buf: []u8) Error!usize {
    while (true) {
        const rc = std.os.linux.read(fd, buf.ptr, buf.len);
        if (isErr(rc)) {
            const e = errnoOfUsize(rc);
            if (e == EINTR) continue; // signal, no bytes moved: retry
            return fail(error.ReadFailed, e);
        }
        // A return larger than the request is outside read(2)'s contract
        // and no errno describes it; report EIO rather than letting the
        // caller's cursor run past the end of its buffer.
        if (rc > buf.len) return fail(error.ReadFailed, EIO);
        return rc;
    }
}

/// Read `buf.len` bytes or until EOF. Retries EINTR (a signal arriving
/// before any bytes moved is not a read failure) and loops over short
/// reads. Returns the byte count; `Ok(0)` means EOF. A real errno is
/// `error.ReadFailed` — never a truncated "success".
pub fn readFull(fd: i32, buf: []u8) Error!usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try readSome(fd, buf[total..]);
        if (n == 0) break; // EOF
        total += n;
    }
    return total;
}

/// Write all of `bytes`. Retries EINTR and loops over partial writes.
/// `Ok` means every byte landed; a failure is always an error, so a
/// failed or partial write can no longer read as success.
pub fn writeFull(fd: i32, bytes: []const u8) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[pos..].ptr, bytes.len - pos);
        if (isErr(rc)) {
            const e = errnoOfUsize(rc);
            if (e == EINTR) continue;
            return fail(error.WriteFailed, e);
        }
        // A 0-byte return for a non-zero request is outside POSIX's
        // contract and no errno describes it; report EIO rather than
        // inventing a code (and rather than looping forever).
        if (rc == 0) return fail(error.WriteFailed, EIO);
        if (rc > bytes.len - pos) return fail(error.WriteFailed, EIO);
        pos += rc;
    }
}

/// close(2) with its result checked. A deferred writeback error
/// (ENOSPC/EIO) can be reported *only* here, so discarding it makes a
/// failed flush look like a clean close.
pub fn closeChecked(fd: i32) Error!void {
    const rc = std.os.linux.close(fd);
    if (isErr(rc)) return fail(error.CloseFailed, errnoOfUsize(rc));
}

/// Close on a path that is already returning a failure.
///
/// The primary errno is what the caller needs, and a close error cannot
/// improve that report -- so the close is skipped rather than checked.
/// It is a *named* skip rather than a bare `catch {}` or `_ = close(fd)`
/// so the decision reads the same everywhere, is greppable, and cannot
/// be mistaken for an oversight by the discarded-result audit.
///
/// Never use this on a path that WROTE to the fd and then reports
/// success: that is exactly the deferred-writeback hole `closeChecked`
/// exists to close.
pub fn closeOnErrorPath(fd: i32) void {
    closeChecked(fd) catch {};
}

/// Reap `pid` and ignore the outcome.
///
/// For paths that are *already* returning a failure and only need to
/// avoid leaving a zombie: a wait error adds nothing to the error in
/// hand. Named so the ignore is a decision rather than a bare discard --
/// and only usable where success/failure of the wait is not the report.
pub fn waitPidOrIgnore(pid: i32) void {
    _ = waitPid(pid) catch return;
}

/// waitpid(2) with EINTR retried and the status word returned.
///
/// The previous shape discarded the result and read `status` straight
/// after, so a failed wait (`ECHILD`, or a signal delivered before the
/// child was reaped) left `status` at 0 -- which `W.IFEXITED` reads as
/// "exited normally with code 0", i.e. **a failed wait reported
/// success**. Now the failure is an error and the callers report it.
///
/// EINTR is retried rather than surfaced: the child still exists and the
/// wait is idempotent, so a signal must not turn into a bogus exit code.
pub fn waitPid(pid: i32) Error!u32 {
    while (true) {
        var status: u32 = 0;
        const rc = std.os.linux.waitpid(pid, &status, 0);
        if (!isErr(rc)) return status;
        const e = errnoOfUsize(rc);
        if (e == EINTR) continue; // signal, child still unreaped: retry
        return fail(error.WaitFailed, e);
    }
}

// ── paths ────────────────────────────────────────────────────────────

/// How much durability a write owes its caller. Build artifacts are
/// regenerable and use `.report_only`; user-visible artifacts (a
/// lockfile, `zag init` scaffolding) use `.durable`.
pub const Durability = enum { report_only, durable };

/// Report an over-long path from a caller that does its own bounds
/// check, so the failure carries a real errno like every other one.
pub fn pathTooLong() Error {
    return fail(error.PathTooLong, ENAMETOOLONG);
}

/// openat(O_RDONLY) with the path bounds-checked — the only open mode
/// the compiler's read paths use (a directory opens the same way).
pub fn openReadOnly(path: []const u8) Error!i32 {
    var buf: [4096]u8 = undefined;
    const pz = try pathZ(&buf, path);
    const rc = std.os.linux.openat(std.os.linux.AT.FDCWD, pz.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (isErr(rc)) return fail(error.OpenFailed, errnoOfUsize(rc));
    return @intCast(rc);
}

/// One `getdents64` batch. `Ok(0)` means the directory is exhausted.
/// The previous walker compared the raw `usize` against
/// `maxInt(isize)`, so an errno-encoded return read as "end of
/// directory" — a failed listing silently materialised a partial
/// stdlib mirror.
pub fn dirEntries(fd: i32, buf: []u8) Error!usize {
    const rc = std.os.linux.getdents64(fd, buf.ptr, buf.len);
    if (isErr(rc)) return fail(error.ReadFailed, errnoOfUsize(rc));
    if (rc > buf.len) return fail(error.ReadFailed, EIO);
    return rc;
}

/// `mkdir -p`-ish: create `path`, treating EEXIST as success. Every
/// other errno is a real failure — the previous version discarded the
/// result entirely, so EACCES and ENOENT were indistinguishable from
/// "already there".
pub fn mkdirPath(path: []const u8) Error!void {
    var buf: [4096]u8 = undefined;
    const pz = try pathZ(&buf, path);
    const rc = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, pz.ptr, 0o755);
    if (!isErr(rc)) return;
    const e = errnoOfUsize(rc);
    if (e == EEXIST) return;
    return fail(error.MkdirFailed, e);
}

/// Write `content` to `path` (O_WRONLY|O_CREAT|O_TRUNC, mode 0644).
/// `Ok` means the bytes were handed to the kernel — with `.durable` it
/// also means they reached stable storage. Every failure path closes the
/// fd, so a failure cannot leak it.
pub fn writeFile(path: []const u8, content: []const u8, durability: Durability) Error!void {
    var buf: [4096]u8 = undefined;
    const pz = try pathZ(&buf, path);
    const orc = std.os.linux.openat(
        std.os.linux.AT.FDCWD,
        pz.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    if (isErr(orc)) return fail(error.OpenFailed, errnoOfUsize(orc));
    const fd: i32 = @intCast(orc);

    // Both failure paths close through `closeOnErrorPath` (named, not a
    // bare discard): the write/fsync errno being returned is the primary
    // failure and a close error cannot improve it.
    writeFull(fd, content) catch |e| {
        closeOnErrorPath(fd);
        return e;
    };

    if (durability == .durable) {
        // A buffered write can return full length while the real failure
        // (ENOSPC/EIO) only surfaces at fsync time.
        const frc = std.os.linux.fsync(fd);
        if (isErr(frc)) {
            closeOnErrorPath(fd);
            return fail(error.WriteFailed, errnoOfUsize(frc));
        }
    }

    const crc = std.os.linux.close(fd);
    if (isErr(crc)) return fail(error.CloseFailed, errnoOfUsize(crc));
}

/// Module-private read buffer (1 MiB, same cap the previous per-caller
/// version used). Returned slices alias it, so the next `readFile`
/// overwrites them — the compiler consumes each result before reading
/// the next file.
var read_buf: [1024 * 1024]u8 = undefined;

/// Read a whole file. `Ok(slice)` is the content; a short file is a
/// short slice (never a bogus one), and an over-long path is
/// `error.PathTooLong` rather than an overrun.
pub fn readFile(path: []const u8) Error![]const u8 {
    const fd = try openReadOnly(path);

    const n = readFull(fd, &read_buf) catch |e| {
        // Read-only fd and a real read error already in hand: nothing
        // for close(2) to add.
        closeOnErrorPath(fd);
        return e;
    };
    // read-only fd: nothing was written through this handle, so close(2)
    // has no buffered write-back to report.
    _ = std.os.linux.close(fd); // deliberate discard: read-only fd
    return read_buf[0..n];
}

