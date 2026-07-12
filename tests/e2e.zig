// =====================================================================
// tests/e2e.zig -- end-to-end render+compile+run integration test.
//
// Purpose
// -------
// The unit tests in src/tests/{lexer,parser,codegen}.zig pin rendering
// shape at the AST + substring level. They prove the in-process
// pipeline STAYS in lockstep with the spec, but they CANNOT prove
// that the zig source we emit is what `zig run` actually accepts and
// runs to a working binary that prints the expected string.
//
// This E2E closes that loop:
//   pub fun main() -> void { print("hello, E2E\n"); }
//   ┌─────────────────────────────────────────────────────────────┐
//   │  1. lex                                  (in-process)        │
//   │  2. parse                                (in-process)        │
//   │  3. codegen                              (in-process)        │
//   │  4. scrub __zag_imported_<i> preamble    (in-process)        │
//   │  5. write /tmp/zag_e2e/hello.zig         (POSIX write)       │
//   │  6. fork+execve `zig run <path>`         (POSIX syscalls)    │
//   │  7. capture stdout via pipe              (POSIX pipe+dup2)   │
//   │  8. assert exit 0 + "hello, E2E" substring                    │
//   └─────────────────────────────────────────────────────────────┘
//
// Run it
// ------
// `zig build e2e`. The e2e runner is registered as a separate
// `b.addExecutable` + `b.addRunArtifact` step parallel to
// `zig build smoke` and `zig build scaffold_tests` -- mirroring the
// existing `tests/smoke.zig` pattern. Mirroring the existing
// "don't pollute `zig build test` with subprocess-driven tests"
// architecture: (a) keeps the fast in-process regression suite
// (~240 tests, <1s) free of fork overhead, and (b) prevents
// CI/CD sandboxes (hermetic containers blocking fork) from
// breaking a step orthogonal to the unit suite.
//
// Subprocess API choice (and why we degraded)
// -------------------------------------------
// User's original spec called for `std.ChildProcess` + 
// `std.io.fixedBufferStream` + `realpathAlloc` -- names current in
// an older zig version. zig 0.16's stdlib has substantially 
// reorganised:
//   - `std.ChildProcess` was renamed/split; the replacement 
//     `std.process.Child` at /home/lex/.local/zig/lib/std/process/
//     Child.zig requires a new StdIo.pipe-shape spawn config + a
//     new `Io` argument to `wait()` that is not empirically verified
//     in this codebase today.
//   - `std.io.fixedBufferStream` is not at its expected path in
//     this zig install.
//   - `realpathAlloc` is gated behind the new `Io` API.
//
// We use the project's VERIFIED-working surfaces instead: raw POSIX
// syscalls (`std.posix.openat`, `std.os.linux.{read,write,fork,
// execve,waitpid,dup2}`) and an inline `[65536]u8` byte buffer for
// scrubbing (mirrors `tests/scaffold.zig`'s `readStubFile` scratch
// shape). These compile cleanly today (same surface `tests/smoke.zig`
// already exercises hundreds of times via `zig build smoke`) and
// keep the e2e unblocked without a zig bump. The shapes are
// documented inline so a future stable zig can migrate either piece
// to the modern API without changing the assertion contract -- the
// public contract of this file is `pub fn main() !u8` returning 0
// on success.
// =====================================================================

const std = @import("std");
const env_path = @import("env_path");
const parser_mod = @import("parser");
const ast = parser_mod.ast;

pub fn main() !u8 {
    const allocator = std.heap.page_allocator;

    // ---- Step 1+2+3: lex + parse + codegen in-process ----
    // The minimal source has no `pub import` decls, so the emitted
    // zig module's preamble contains only `const std = @import...`
    // + the print_fn helper + the __zag_interp_buf scratch -- no
    // `__zag_imported_<i>` lines for the scrubber to be non-trivial
    // on. The scrub STILL RUNS (unifies the e2e contract: a richer
    // future test source with `pub import std.X` decls automatically
    // gets its preamble scrubbed to a no-op struct impl). One-shot
    // binary: leak-tolerant `page_allocator` mirrors `tests/smoke.zig`'s
    // choice and sidesteps `std.testing.allocator`'s leak-check panic
    // over the child-process buffers we cannot reason about as
    // "either-allocated-or-freed" in this code.
    const src =
        \\pub fun main() -> void {
        \\    print("hello, E2E\n");
        \\}
        \\
    ;
    var l = parser_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = parser_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    // ---- Step 4: scrub __zag_imported_<i> preamble lines ----
    // Inline `[65536]u8` buffer + manual index walker. Mirrors
    // `tests/scaffold.zig`'s `readStubFile` scrub shape -- same
    // shape `tests/smoke.zig` and `src/main.zig` use for their
    // readback / preview loops. Sidesteps the
    // `std.io.fixedBufferStream` surface that's not at the
    // expected path in this zig install.
    var scrubbed: [65536]u8 = undefined;
    const scrub_len = try scrubImportLines(zig_src, &scrubbed);

    // ---- Step 5: ensure workdir + write scrubbed zig to disk ----
    const workdir_path = "/tmp/zag_e2e";
    // `ensureWorkdir` is a side-effect-only helper (void return) --
    // it discards `mkdir`'s rc because success (rc=0) and EEXIST
    // (already-there) both leave the workdir usable. Calling it
    // without `try` is correct: there's no error union to unwrap.
    ensureWorkdir(workdir_path);
    const hello_zig_path = try std.fmt.allocPrint(
        allocator,
        "{s}/hello.zig",
        .{workdir_path},
    );
    defer allocator.free(hello_zig_path);
    try writeZigFile(hello_zig_path, scrubbed[0..scrub_len]);

    // ---- Step 6+7: fork+execve `zig run <path>` with stdout piped ----
    // Mirrors `tests/smoke.zig`'s `runProgram` shape:
    //   1. readEnviron (via env_path module) -- populate the parent's
    //      env so execve can forward PATH/HOME/LANG to the forked
    //      zig subprocess (which in turn forwards PATH to its own
    //      recursive `cc`/`ld` children for the build).
    //   2. posix.pipe -- create [read_end, write_end] before fork
    //      so the fork copies the fds into the child's address
    //      space (a post-fork pipe() doesn't help -- child needs
    //      open fds).
    //   3. fork -- duplicates the parent's address space + open fds.
    //   4. child: dup2(write_end, STDOUT_FILENO=1), close read_end
    //      and write_end, execve `zig run <path>` with the parent's
    //      envp. execve does NOT do PATH lookup (POSIX);
    //      argv[0] is the absolute `zig_path` from resolveZigPath.
    //   5. parent: close write_end, read from read_end until EOF,
    //      waitpid for the forked child.
    // The 513-slot envp_z + 4-slot argv_z arrays + arg_bufs defer-
    // free match tests/smoke.zig's allocations verbatim, including
    // the trailing null sentinel at index 512.
    env_path.readEnviron();

    // zig 0.16's `std.posix.pipe` doesn't exist; the bare-syscall
    // surface is `std.os.linux.pipe(&[2]i32) usize` returning 0 on
    // success or a non-zero error code on failure (NOT an error
    // union -- no `try` indirection). Mirror smoke.zig's
    // low-level-syscall idiom: discard rc-style return codes that
    // we either don't need to inspect (success) or that we let
    // downstream calls surface (EACCES -> openat fails later).
    var pipe_fds: [2]i32 = undefined;
    if (std.os.linux.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const zig_path = try resolveZigPath(allocator);
    defer allocator.free(zig_path);

    const pid = std.math.cast(i32, std.os.linux.fork()) orelse return error.ForkFailed;
    if (pid == 0) {
        // child: redirect BOTH stdout AND stderr to the pipe write-end.
        // The codegen emits `std.debug.print("...\n", .{})` for `print(...)`
        // statements, and `std.debug.print` writes to STDERR (FD 2)
        // by default. Without redirecting FD 2 too, the produced
        // binary's output bypasses our pipe and lands back on the
        // e2e-runner's parental terminal via the inherited stderr
        // -- exactly what bit us on the first runtime trial. Pipe
        // capture must include BOTH channels so the assertion
        // envelope sees `hello, E2E\n` regardless of whether the
        // codegen chose stdout or stderr. STDIN (FD 0) is NOT
        // touched; zig run doesn't read from stdin for our
        // no-stdin test sources.
        _ = std.os.linux.dup2(pipe_fds[1], 1); // STDOUT_FILENO
        _ = std.os.linux.dup2(pipe_fds[1], 2); // STDERR_FILENO
        _ = std.os.linux.close(pipe_fds[0]);
        _ = std.os.linux.close(pipe_fds[1]);

        // argv = ["zig", "run", "<hello_zig_path>"]. allocSentinel
        // gives [:0]u8 null-terminated buffers; .ptr auto-coerces
        // to ?[*:0]const u8 inside the argv_z array.
        var arg_bufs: [3]?[:0]u8 = .{ null } ** 3;
        defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| allocator.free(buf);
        var argv_z: [4]?[*:0]const u8 = .{ null } ** 4;
        const argv_inputs = [_][]const u8{ zig_path, "run", hello_zig_path };
        for (argv_inputs, 0..) |arg, i| {
            const buf = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(buf, arg);
            arg_bufs[i] = buf;
            argv_z[i] = buf.ptr;
        }

        var envp_z: [513]?[*:0]const u8 = .{ null } ** 513;
        const env_count = @min(env_path.environ_count, envp_z.len - 1);
        for (env_path.environ_entries[0..env_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;
        const argv_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_z);
        const envp_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_z);
        const buf0: [:0]u8 = arg_bufs[0] orelse std.os.linux.exit(127);
        _ = std.os.linux.execve(buf0.ptr, argv_z_ptr, envp_z_ptr);
        // execve only returns on error (negative path); exit 127
        // is the conventional "command not found / not executable"
        // exit code that POSIX shells use.
        std.os.linux.exit(127);
    }

    // parent: close write-end, drain the pipe, waitpid.
    _ = std.os.linux.close(pipe_fds[1]);

    var out: [4096]u8 = undefined;
    var out_total: usize = 0;
    while (out_total < out.len) {
        // `std.os.linux.read` expects a many-pointer `[*]u8` (per
        // its signature at /home/lex/.local/zig/lib/std/os/linux.zig),
        // NOT a single-pointer `*u8`. Zig rejects `&out[out_total]`
        // with "a single pointer cannot cast into a many pointer".
        // The idiomatic shape is `out[out_total..].ptr` -- the slice's
        // many-pointer field, which is what smoke.zig's read loop
        // already uses (`buf[total..].ptr`). Same one-character fix
        // for the parent's stdout drain.
        const n = std.os.linux.read(pipe_fds[0], out[out_total..].ptr, out.len - out_total);
        // (the prior version used `&out[out_total]` here; that was a
        // single-pointer, rejected by zig: "a single pointer cannot
        // cast into a many pointer". `out[out_total..].ptr` matches
        // the verified shape used by `tests/smoke.zig`'s readAll loop.)
        if (n > std.math.maxInt(isize)) return error.ReadSyscallFailed;
        if (n == 0) break;
        out_total += n;
    }
    _ = std.os.linux.close(pipe_fds[0]);

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid, &status, 0);
    if (!std.os.linux.W.IFEXITED(status)) {
        std.debug.print("e2e FAIL -- child terminated by signal\n", .{});
        std.debug.print("captured stdout ({d} bytes):\n{s}\n", .{ out_total, out[0..out_total] });
        return 80;
    }
    const exit_code = std.os.linux.W.EXITSTATUS(status);
    if (exit_code != 0) {
        std.debug.print("e2e FAIL -- `zig run` exited {d}\n", .{exit_code});
        std.debug.print("captured stdout ({d} bytes):\n{s}\n", .{ out_total, out[0..out_total] });
        return exit_code;
    }
    if (std.mem.indexOf(u8, out[0..out_total], "hello, E2E") == null) {
        std.debug.print("e2e FAIL -- captured stdout does not contain 'hello, E2E'\n", .{});
        std.debug.print("captured stdout ({d} bytes):\n{s}\n", .{ out_total, out[0..out_total] });
        return 90;
    }
    std.debug.print("e2e PASS -- `zig run` produced 'hello, E2E' via {s}\n", .{zig_path});
    return 0;
}

// ============================================================================
// helpers

/// Walk `src` line-by-line, applying two scrub rules:
///
/// Rule 1 (preamble): any line of the form
///     `const __zag_imported_<i> = @import("<path>");`
/// becomes
///     `const __zag_imported_<i> = struct{};`
/// without touching any other content on the line. The `>>struct{}<<`
/// stub has no fields, so any later `__zag_imported_<i>.<field>`
/// reference (alias line — Rule 2) would also need scrubbing.
///
/// Rule 2 (alias): any line containing the substring
///     `= __zag_imported_<i>`
/// (the codegen emits these AFTER the preamble for each selector
/// declared in a `pub import std.X { A as B }` decl, e.g.
///     `const MyStr = __zag_imported_0.String;`
/// ) gets its RHS replaced with
///     ` struct{};`
/// preserving the LHS ident verbatim. Without this rule the alias
/// would compile-fail on `<scrubbed>.String` (struct{} has no
/// `.String` field).
///
/// Per-line iteration rather than byte-by-byte: each iteration
/// computes `line_end` once at the top, applies Rule 1's literal-
/// prefix check, then iterates the line looking for Rule 2's
/// RHS marker, then falls through to whole-line passthrough if
/// neither rule matches. Cleaner + faster than the prior
/// byte-walker shape.
///
/// Inline byte buffer + manual index; mirrors `tests/scaffold.zig`'s
/// `[65536]u8` readStubFile scratch shape. Sidesteps the
/// `std.io.fixedBufferStream` surface that's not at the expected
/// path in this zig install.
fn scrubImportLines(src: []const u8, dst: *[65536]u8) !usize {
    const prefix = "const __zag_imported_";
    const rhs_marker = "= __zag_imported_";
    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (src_i < src.len) {
        // Compute this line's end (LF byte or src.len).
        var line_end: usize = src_i;
        while (line_end < src.len and src[line_end] != '\n') : (line_end += 1) {}

        var matched: bool = false;

        // Rule 1: preamble line begins with `const __zag_imported_`
        // AND the line contains an `=` (else the form is malformed
        // and we fall through to passthrough).
        if (src_i + prefix.len <= line_end and
            std.mem.eql(u8, src[src_i..][0..prefix.len], prefix))
        {
            var eq_i: usize = src_i;
            while (eq_i < line_end and src[eq_i] != '=') : (eq_i += 1) {}
            if (eq_i < line_end and src[eq_i] == '=') {
                const copy_len = eq_i + 1 - src_i; // includes '='
                if (dst_i + copy_len > dst.len) return error.ScrubBufferOverflow;
                @memcpy(dst[dst_i..][0..copy_len], src[src_i..][0..copy_len]);
                dst_i += copy_len;
                const tail = " struct{};";
                if (dst_i + tail.len > dst.len) return error.ScrubBufferOverflow;
                @memcpy(dst[dst_i..][0..tail.len], tail);
                dst_i += tail.len;
                matched = true;
            }
        }

        // Rule 2: alias RHS marker present on the line. The marker
        // literally begins with `=`, so the `=` byte IS at `rhs_pos`
        // -- no separate post-check needed (the rhs_marker prefix is
        // self-attesting). Copy from line start through `=` inclusive,
        // then append ` struct{};` so the alias becomes
        // `const <LHS> = struct{};`. Optimistically bail after the
        // first marker hit (one physical line holds only one alias
        // in the codegen's emit shape). The `__zag_` identifier
        // family is reserved against user identifiers per
        // src/codegen/core.zig's preamble comment so users cannot
        // accidentally collide on this rule -- CAVEAT: this protects
        // identifiers but NOT arbitrary string-literal content; a
        // future e2e source containing the literal substring
        // `= __zag_imported_` inside a zag string would have that
        // string mangled. Out of scope for v1 (no such string);
        // revisit if a richer future source declares one.
        if (!matched) {
            var rhs_pos: usize = src_i;
            var hit: bool = false;
            while (rhs_pos + rhs_marker.len <= line_end) {
                if (std.mem.eql(u8, src[rhs_pos..][0..rhs_marker.len], rhs_marker)) {
                    hit = true;
                    break;
                }
                rhs_pos += 1;
            }
            if (hit) {
                // Truncate at `=` (rhs_pos inclusive). This is the
                // SAME shape as Rule 1's `eq_i + 1 - src_i`: copy
                // through the `=` byte, then append the tail. The
                // earlier copy_len-via-marker-end shape was incorrect
                // -- it left `__zag_imported_` literal bytes dangling
                // in the output, producing `const MyStr = __zag_imported_ struct{};`
                // which is not valid zig.
                const copy_len = rhs_pos + 1 - src_i;
                if (dst_i + copy_len > dst.len) return error.ScrubBufferOverflow;
                @memcpy(dst[dst_i..][0..copy_len], src[src_i..][0..copy_len]);
                dst_i += copy_len;
                const tail = " struct{};";
                if (dst_i + tail.len > dst.len) return error.ScrubBufferOverflow;
                @memcpy(dst[dst_i..][0..tail.len], tail);
                dst_i += tail.len;
                matched = true;
            }
        }

        if (matched) {
            // Preserve the LF if the line had one.
            if (line_end < src.len) {
                if (dst_i >= dst.len) return error.ScrubBufferOverflow;
                dst[dst_i] = '\n';
                dst_i += 1;
                src_i = line_end + 1;
            } else {
                src_i = line_end;
            }
            continue;
        }

        // Passthrough: copy entire line in one shot. Tight fits
        // (`dst_i + line_len == dst.len`) succeed because
        // `@memcpy` writes positions [dst_i, dst.len-1] inclusive;
        // the boundary `>` (NOT `>=`) is what lets that case
        // through. `==` would over-reject by one byte.
        const line_len = line_end - src_i;
        if (dst_i + line_len > dst.len) return error.ScrubBufferOverflow;
        @memcpy(dst[dst_i..][0..line_len], src[src_i..][0..line_len]);
        dst_i += line_len;
        if (line_end < src.len) {
            if (dst_i >= dst.len) return error.ScrubBufferOverflow;
            dst[dst_i] = '\n';
            dst_i += 1;
            src_i = line_end + 1;
        } else {
            src_i = line_end;
        }
    }
    return dst_i;
}

/// Mirror `tests/smoke.zig`'s `resolveZigPath` shape: prefer
/// `vendor/zig/zig` (populated by `scripts/install.sh`) over the
/// dev-machine fallback at `/home/lex/.local/zig/zig`. Returns a
/// heap-allocated absolute path the caller frees (mirrors the
/// smoke-runner's `resolveZigPath` return shape but `dupe[u8]`
/// here since smoke was `[]const u8` from a file-scope const).
///
/// Why ELF-magic check (vs smoke's plain `fileExists`):
/// this project's `vendor/zig/zig` is a 100-byte STUB placeholder
/// in some checkout states -- it's +x and exists, but it is NOT
/// a real zig binary. Plain existence + x-bit check would have
/// execve-failed in our child (exit 127 -- matches the basher's
/// first e2e fail). Reading the first 4 bytes and matching the
/// ELF magic `\x7fELF` is the cheapest reliable gate: rejects
/// stubs, shell scripts, zero-byte files, and short garbage, all
/// in one read. Real zig binaries are ~50MB ELF executables.
fn resolveZigPath(allocator: std.mem.Allocator) ![]u8 {
    const vendor = "vendor/zig/zig";
    const dev = "/home/lex/.local/zig/zig";
    if (isRunnableZig(vendor)) {
        std.debug.print("e2e: zig resolved to {s} (vendor)\n", .{vendor});
        return try allocator.dupe(u8, vendor);
    }
    std.debug.print("e2e: zig resolved to {s} (dev fallback)\n", .{dev});
    return try allocator.dupe(u8, dev);
}

/// ELF-magic + ELF-header-class + X_OK gate: open `path` for read
/// after an `access(path, X_OK)` syscall, read the first 8 bytes
/// (magic + EI_CLASS + EI_DATA + EI_VERSION), return true iff
/// every byte is in the valid ELF range.
///
/// Why 8 bytes (not just 4): an earlier version of this gate read
/// only the first 4 bytes and matched `\x7fELF`. `vendor/zig/zig`
/// in this project is a 100-byte stub whose first 4 bytes ARE
/// `\x7fELF` (followed by 'X' padding) — it satisfies the 4-byte
/// gate but fails execve with "Exec format error" because its
/// EI_CLASS byte is 0x58 ('X', invalid) rather than 1 (32-bit) or
/// 2 (64-bit). Reading the next 4 bytes (EI_CLASS, EI_DATA,
/// EI_VERSION, EI_OSABI) and verifying EI_CLASS is 1 or 2 plus
/// EI_DATA is 1 or 2 plus EI_VERSION is 1 catches any
/// hand-crafted stub whose magic happens to be `\x7fELF` but
/// whose remaining header is garbage.
///
/// Same shape as `tests/smoke.zig`'s `isExecutable` (raw
/// `std.os.linux.access(_,1)` syscall) plus a 8-byte ELF-header
/// sanity check. Uses `posix.openat` + `std.os.linux.read` loop
/// for the byte read.
fn isRunnableZig(path: []const u8) bool {
    // X_OK=1 per linux <unistd.h>; pass the literal rather than
    // importing std.os.linux.X_OK which zig 0.16 doesn't expose.
    const access_rc = std.os.linux.access(@ptrCast(path.ptr), 1);
    if (access_rc > std.math.maxInt(isize)) return false; // errno-encoded failure
    if (access_rc != 0) return false; // not executable
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    defer _ = std.os.linux.close(fd);
    var header: [8]u8 = undefined;
    var total: usize = 0;
    while (total < header.len) {
        // std.os.linux.read expects [*]u8 (many-pointer), so use
        // `header[total..].ptr` -- not `&header[total]` (single-
        // pointer rejected by zig: "a single pointer cannot cast
        // into a many pointer"). Same idiom as smoke.zig's readAll
        // loop.
        const n = std.os.linux.read(fd, header[total..].ptr, header.len - total);
        if (n > std.math.maxInt(isize)) return false;
        if (n == 0) return false;
        total += n;
    }
    // 1. ELF magic (4 bytes).
    if (!std.mem.eql(u8, header[0..4], "\x7fELF")) return false;
    // 2. EI_CLASS byte (4): 1=32-bit or 2=64-bit. Real zig
    //    binaries are 64-bit (class=2). Stubs tend to use 0xFF or
    //    ASCII padding in this slot -- rejected here.
    if (header[4] != 1 and header[4] != 2) return false;
    // 3. EI_DATA byte (5): 1=little-endian or 2=big-endian.
    //    zig compiles to little-endian (Linux).
    if (header[5] != 1 and header[5] != 2) return false;
    // 4. EI_VERSION byte (6): must be 1 (current).
    if (header[6] != 1) return false;
    // EI_OSABI (byte 7) is intentionally NOT checked -- it's a
    // quality-of-implementation marker with multiple legitimate
    // values (0=SystemV, 3=Linux, 9=FreeBSD, etc.) and real zig
    // binaries land on SystemV (0). Stub would likely have a
    // garbage byte here too, but we'd over-restrict by rejecting
    // valid Linux-ABI zig binaries. Skipped.
    return true;
}

/// `mkdir -p` for the e2e workdir. Discarded return: on a fresh
/// run mkdir succeeds (rc == 0); on a retry mkdir returns EEXIST
/// (the dir is already there). Both leave the workdir usable. Any
/// other errno (EACCES etc.) would propagate downstream from the
/// `writeZigFile` call below.
fn ensureWorkdir(path: []const u8) void {
    _ = std.os.linux.mkdir(@ptrCast(path.ptr), 0o755);
}

/// Write full contents to `path` (truncate-or-create). Same shape
/// as `src/main.zig`'s `writeFile`: posix.openat with WRONLY+CREAT+
/// TRUNC, raw `std.os.linux.write` loop until done, close on defer.
/// Sidesteps the `std.fs.cwd().writeFile` surface that's not at the
/// expected path in this zig install.
fn writeZigFile(path: []const u8, content: []const u8) !void {
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = std.os.linux.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = std.os.linux.write(fd, content[written..].ptr, content.len - written);
        if (n > std.math.maxInt(isize)) return error.WriteSyscallFailed;
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}
