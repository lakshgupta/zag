// Source-mirror test bucket for src/sys.zig — the compiler's shared
// syscall layer.
//
// These tests pin the two failure modes that motivated the module:
//
//   1. A raw syscall result must be decoded, never treated as a byte
//      count. `write(2)` returning an errno-encoded usize used to run
//      `writeFile`'s counter past the end of the buffer and exit the
//      loop looking like a clean finish — a failed write reported as
//      success.
//   2. EOF and a real errno must stay distinguishable, so a failed read
//      can never look like a short file.
//
// Registered in src/tests.zig (the `zig build test` root). sys.zig
// imports only `std`, so pulling it in adds no build_options/toolchain
// coupling to the test binary.

const std = @import("std");
const testing = std.testing;
const sys = @import("../sys.zig");

test "sys: isErr / errnoOfUsize decode the errno-encoded usize convention" {
    // Success values never look like failures.
    try testing.expect(!sys.isErr(0));
    try testing.expect(!sys.isErr(4096));
    try testing.expect(!sys.isErr(0x7FFFFFFFFFFFFFFF));

    // 2^64 - 2 == -2 == ENOENT
    try testing.expect(sys.isErr(0xFFFFFFFFFFFFFFFE));
    try testing.expectEqual(@as(isize, sys.ENOENT), sys.errnoOfUsize(0xFFFFFFFFFFFFFFFE));

    // 2^64 - 28 == -28 == ENOSPC
    try testing.expectEqual(@as(isize, sys.ENOSPC), sys.errnoOfUsize(0xFFFFFFFFFFFFFFE4));

    // The old bug in one line: a failed `write` returns 0xFFFF...FF,
    // which is a truthy `usize`. It must decode as EPERM, not as a
    // gigantic byte count.
    try testing.expectEqual(@as(isize, sys.EPERM), sys.errnoOfUsize(0xFFFFFFFFFFFFFFFF));
}

test "sys: errnoOfSigned / errnoName" {
    try testing.expectEqual(@as(isize, sys.ENOENT), sys.errnoOfSigned(-2));
    try testing.expectEqual(@as(isize, sys.ENOSPC), sys.errnoOfSigned(-28));
    try testing.expectEqual(@as(isize, 0), sys.errnoOfSigned(0));

    try testing.expect(std.mem.eql(u8, "ENOENT", sys.errnoName(sys.ENOENT)));
    try testing.expect(std.mem.eql(u8, "ENAMETOOLONG", sys.errnoName(sys.ENAMETOOLONG)));
    try testing.expect(std.mem.eql(u8, "none", sys.errnoName(0)));

    // An errno the table doesn't name keeps its number rather than
    // degrading to a bare "unknown".
    try testing.expect(std.mem.eql(u8, "errno 4094", sys.errnoName(4094)));
}

test "sys: writeFile round-trips through both durability modes" {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/zag_sys_write_{d}", .{std.os.linux.getpid()});

    var content: [2048]u8 = undefined;
    @memset(content[0..], 'z');

    // report_only: bytes handed to the kernel, no fsync.
    try sys.writeFile(path, content[0..], .report_only);
    const back = try sys.readFile(path);
    try testing.expectEqual(@as(usize, content.len), back.len);
    try testing.expectEqualSlices(u8, content[0..], back);

    // durable: same content, plus fsync + checked close on the way out.
    try sys.writeFile(path, content[0..], .durable);
    const back2 = try sys.readFile(path);
    try testing.expectEqualSlices(u8, content[0..], back2);
}

test "sys: a failed write is an error, never a silent success" {
    var content: [256]u8 = undefined;
    @memset(content[0..], 'x');

    // EBADF: the fd is not open. The old shape returned success here
    // because the errno-encoded usize is non-zero.
    try testing.expectError(error.WriteFailed, sys.writeFull(-1, content[0..]));
    try testing.expectEqual(@as(isize, sys.EBADF), sys.lastErrno());
    try testing.expect(std.mem.eql(u8, "EBADF", sys.lastErrnoName()));

    // Same for the whole-file path: an unwritable target is OpenFailed
    // with the errno preserved for the diagnostic.
    try testing.expectError(error.OpenFailed, sys.writeFile("/tmp/zag_absent_dir_xyz/f", "x", .report_only));
    try testing.expectEqual(@as(isize, sys.ENOENT), sys.lastErrno());
    try testing.expect(std.mem.eql(u8, "ENOENT", sys.lastErrnoName()));
}

test "sys: readSome returns one transfer and distinguishes EOF from errno" {
    var fds: [2]i32 = undefined;
    const prc = std.os.linux.pipe2(&fds, .{});
    try testing.expect(!sys.isErr(prc));
    defer _ = std.os.linux.close(fds[0]); // deliberate discard: read end of a test pipe

    const payload = "first transfer";
    try sys.writeFull(fds[1], payload);
    _ = std.os.linux.close(fds[1]); // deliberate discard: write end of a test pipe; close signals EOF on the drained read end

    var buf: [64]u8 = undefined;
    const n = try sys.readSome(fds[0], buf[0..]);
    try testing.expectEqual(payload.len, n);
    try testing.expectEqualSlices(u8, payload, buf[0..n]);

    // Now the write end is closed and the pipe is drained: 0 is EOF.
    try testing.expectEqual(@as(usize, 0), try sys.readSome(fds[0], buf[0..]));

    // A failed read is an error, never a 0-byte "EOF": EBADF here.
    try testing.expectError(error.ReadFailed, sys.readSome(-1, buf[0..]));
    try testing.expectEqual(@as(isize, sys.EBADF), sys.lastErrno());
}

test "sys: waitPid returns the real status and reports a failed wait" {
    // The failure mode this pins: the previous call shape discarded the
    // wait result and read the status word straight after, so a failed
    // wait left `status` at 0 -- and `W.IFEXITED(0)` is true with
    // `EXITSTATUS(0) == 0`, i.e. a failed wait reported "exited 0".
    const pid = std.os.linux.fork();
    try testing.expect(!sys.isErr(pid));
    if (pid == 0) std.os.linux.exit(7); // child

    const status = try sys.waitPid(@intCast(pid));
    try testing.expect(std.os.linux.W.IFEXITED(status));
    try testing.expectEqual(@as(u32, 7), std.os.linux.W.EXITSTATUS(status));

    // The status must come from the wait, not from a zero-initialised
    // local: an already-reaped pid fails with ECHILD rather than
    // handing back a clean-looking 0.
    try testing.expectError(error.WaitFailed, sys.waitPid(@intCast(pid)));
    try testing.expectEqual(@as(isize, sys.ECHILD), sys.lastErrno());
    try testing.expect(std.mem.eql(u8, "ECHILD", sys.lastErrnoName()));
}

test "sys: openReadOnly opens files and directories, and reports the errno" {
    // A directory opens normally with O_RDONLY — that is how the stdlib
    // walker gets its fd. Only the *read* on it fails (EISDIR).
    const dfd = try sys.openReadOnly("/tmp");
    try sys.closeChecked(dfd);

    try testing.expectError(error.OpenFailed, sys.openReadOnly("/tmp/zag_sys_absent_xyz"));
    try testing.expectEqual(@as(isize, sys.ENOENT), sys.lastErrno());

    var long_buf: [8192]u8 = undefined;
    @memset(long_buf[0..], 'a');
    try testing.expectError(error.PathTooLong, sys.openReadOnly(long_buf[0..]));
}

test "sys: dirEntries decodes errno instead of reading it as end-of-directory" {
    const dfd = try sys.openReadOnly("/tmp");
    defer _ = std.os.linux.close(dfd); // deliberate discard: read-only test directory fd

    var buf: [4096]u8 align(8) = undefined;
    const n = try sys.dirEntries(dfd, buf[0..]);
    // /tmp always has entries (at minimum "."/".."); the point is that a
    // non-zero batch arrives rather than a silent "exhausted".
    try testing.expect(n > 0);
    try testing.expect(n <= buf.len);

    // A regular file is not listable: ENOTDIR, not an empty directory.
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/zag_sys_dirlist_{d}", .{std.os.linux.getpid()});
    try sys.writeFile(path, "x", .report_only);
    const ffd = try sys.openReadOnly(path);
    defer _ = std.os.linux.close(ffd); // deliberate discard: read-only test file fd
    try testing.expectError(error.ReadFailed, sys.dirEntries(ffd, buf[0..]));
    try testing.expectEqual(@as(isize, sys.ENOTDIR), sys.lastErrno());
}

test "sys: reading a directory fd is EISDIR, not a 0-byte empty file" {
    // `openat` on a directory SUCCEEDS; only the read fails. That is the
    // exact shape that used to be indistinguishable from EOF.
    const dfd = try std.posix.openat(std.posix.AT.FDCWD, "/tmp", .{ .ACCMODE = .RDONLY }, 0);
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.ReadFailed, sys.readFull(dfd, scratch[0..]));
    try testing.expectEqual(@as(isize, sys.EISDIR), sys.lastErrno());
    try sys.closeChecked(dfd);
}

test "sys: readFile reports a real errno instead of returning a bogus slice" {
    try testing.expectError(error.OpenFailed, sys.readFile("/tmp/zag_sys_definitely_absent_xyz"));
    try testing.expectEqual(@as(isize, sys.ENOENT), sys.lastErrno());
    try testing.expect(std.mem.eql(u8, "ENOENT", sys.lastErrnoName()));
}

test "sys: an over-long path is PathTooLong, not a buffer overrun" {
    // The previous mkPath did an unchecked @memcpy into a [512]u8.
    var long_buf: [8192]u8 = undefined;
    @memset(long_buf[0..], 'a');

    try testing.expectError(error.PathTooLong, sys.readFile(long_buf[0..]));
    try testing.expectError(error.PathTooLong, sys.writeFile(long_buf[0..], "x", .report_only));
    try testing.expectError(error.PathTooLong, sys.mkdirPath(long_buf[0..]));
    try testing.expectEqual(@as(isize, sys.ENAMETOOLONG), sys.lastErrno());
    try testing.expect(std.mem.eql(u8, "ENAMETOOLONG", sys.lastErrnoName()));
}

test "sys: mkdirPath treats EEXIST as success and reports everything else" {
    var path_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&path_buf, "/tmp/zag_sys_mkdir_{d}", .{std.os.linux.getpid()});

    // Fresh create succeeds, and a second create is EEXIST — still
    // success, matching the `mkdir -p` semantics the caller wants.
    try sys.mkdirPath(base);
    try sys.mkdirPath(base);

    // The nested sequence main.zig's remap-walker setup uses
    // (`<root>/build/gen`), which is a level deeper than one call.
    // Paths are assembled with bufPrint: `base` has a runtime length, so
    // `base ++ "/build"` is not a comptime value.
    var build_buf: [300]u8 = undefined;
    const build_dir = try std.fmt.bufPrint(&build_buf, "{s}/build", .{base});
    try sys.mkdirPath(build_dir);
    var gen_buf: [320]u8 = undefined;
    const gen_dir = try std.fmt.bufPrint(&gen_buf, "{s}/build/gen", .{base});
    try sys.mkdirPath(gen_dir);
    var map_buf: [360]u8 = undefined;
    const map_path = try std.fmt.bufPrint(&map_buf, "{s}/build/gen/probe.zag.map", .{base});
    try sys.writeFile(map_path, "1\t1\t1\tsym\tsrc/x.zag\n", .report_only);
    const map = try sys.readFile(map_path);
    try testing.expect(std.mem.indexOf(u8, map, "src/x.zag") != null);

    // A missing parent is a real failure, not "already there": this is
    // the distinction the old mkPath could not make, because it threw
    // the mkdirat result away entirely.
    var child_buf: [300]u8 = undefined;
    const child = try std.fmt.bufPrint(&child_buf, "{s}/nope/deeper", .{base});
    try testing.expectError(error.MkdirFailed, sys.mkdirPath(child));
    try testing.expectEqual(@as(isize, sys.ENOENT), sys.lastErrno());
    try testing.expect(std.mem.eql(u8, "ENOENT", sys.lastErrnoName()));
}
