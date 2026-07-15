// -------------------------------------------------------------------
// src/main.zig -- Phase 3 (CLI migration) bootstrap.
//
// The pre-Phase-3 shape was an inline-zig CLI dispatcher that parsed
// argv via /proc/self/cmdline and ran cmdRun / cmdCheck / cmdBuild /
// cmdInit directly with zig-side transpile + zig child-process
// invocation. Phase 3 collapses that surface to:
//
//   1. Read /proc/self/cmdline -> argv (defensive backup; zig's
//      start-of-day routine already populates std.os.argv but the
//      cmdline read is reliable even with freestanding zig 0.16 that
//      may not wire std.os.argv automatically -- matches the existing
//      pre-Phase-3 shape).
//   2. Inspect argv[1]:
//      - If argv[1] starts with "--leaf-process=", leaf-mode
//        lifecycle: read the user .zag source, transpile to zig
//        source, write /tmp/zag_leaf_<pid>.zig, fork+execve
//        `zig build-exe` to compile, then fork+execve the resulting
//        /tmp/zag_leaf_<pid>_bin. The leaf is what actually runs
//        user code; cli_bin never sees the user's source beyond the
//        file path it forwards.
//      - Otherwise (cli-mode): write the @embedFile'd lib/cli.zag
//        bytes to /tmp/zag_cli_<pid>.zag, transpile to /tmp/zag_cli_<pid>.zig,
//        fork+execve `zig build-exe` to /tmp/zag_cli_<pid>_bin, then
//        fork+execve cli_bin via `runCommand(f_bin, args)` so the
//        ORIGINAL user argv is preserved verbatim even though the
//        binary path has switched.
//
// Zag's runtime propagates ZAG_ZIG_PATH through runCommand's
// env-pass-extension so any child (zig compiler, leaf zap binary
// recursion) locates zig without depending on PATH lookup. PID-
// suffixing the temp filenames prevents two simultaneous `zag run`
// invocations from clobbering each other's /tmp artifacts.
// -------------------------------------------------------------------

const std = @import("std");
const posix = std.posix;
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const codegen_mod = @import("codegen.zig");
const ast = @import("ast.zig");
const env_path = @import("env_path");

/// Embedded `lib/cli.zag` source. The bootstrap copies these bytes
/// to /tmp/zag_cli_<pid>.zag at cli-mode startup, transpiles, then
/// compiles to /tmp/zag_cli_<pid>_bin. The runtime never reads
/// lib/cli.zag from disk, so a user change to lib/cli.zag requires
/// `zig build` to rebake the zag binary. That coupling is intentional
/// for v1: an @embedFile-based CLI source vs a runtime-FS-based CLI
/// source trade FLEXIBILITY (runtime change) for RELIABILITY (no
/// install-path discovery surface).
///
/// `@embedFile("../lib/cli.zag")` is evaluated relative to
/// build.zig's cwd -- the project root -- same path stage/main.zig
/// uses for its own vendor/ embeds.
// Mirror the zig_payload embed pattern: build.zig (@embedFile'd at
// the root package) reads lib/cli.zag via its own @embedFile, then
// routes the bytes through `build_options` via addOption. The
// src/main.zig read here is byte-equivalent to a direct @embedFile
// on ../lib/cli.zag, BUT src/* is a separate zig package in this
// repo's zig 0.16 build graph and @embedFile paths inside a
// subpackage cannot escape that package boundary. Routing through
// build.zig + build_options fixes the "embed of file outside
// package path" zig 0.16 error without changing the runtime API.
pub const embedded_cli_zag_source: []const u8 = @import("build_options").cli_zag_source;

/// User-installed zig runtime. v1 honors `$ZAG_ZIG_PATH` first (set
/// it to whatever zig path your machine has), falling back to the
/// dev-machine hardcode if unset. The hardcode is `/home/lex/.local/zig/zig`
/// because that is the maintainer's local path; users with zig
/// elsewhere set the env var (or override at install time).
var zig_install_path: []const u8 = "/home/lex/.local/zig/zig";

pub fn main() !void {
    env_path.readEnviron();
    if (env_path.getenv("ZAG_ZIG_PATH")) |zp| {
        zig_install_path = zp;
    }

    const args = try parseArgs();

    // Detect leaf-process mode: cli.zag's run/check/build handlers
    // each recurse into zag binary with `--leaf-process=<mode>` flag.
    // The bootstrap catches it and goes straight to the transpile+
    // compile+exec pipeline (avoiding the cli-mode bootstrap shape
    // which would re-write cli.zag, re-compile, exec cli_bin infinite
    // times).
    if (args.len >= 2 and std.mem.startsWith(u8, args[1], "--leaf-process=")) {
        const flag = args[1]["--leaf-process=".len..];
        try leafProcess(flag, if (args.len >= 3) args[2] else "");
        return;
    }

    try cliMode(args);
}

/// CLI-mode lifecycle. Writes `embedded_cli_zag_source` to
/// /tmp/zag_cli_<pid>.zag, transpiles, writes the zig-side
/// transpilation to /tmp/zag_cli_<pid>.zig, fork+execves `zig
/// build-exe` to produce /tmp/zag_cli_<pid>_bin, fork+execves
/// cli_bin via `runCommand(f_bin, args)` so the ORIGINAL user
/// argv is preserved verbatim.
fn cliMode(args: []const []const u8) !void {
    const pid_num = std.os.linux.getpid();

    var path_cli_zag: [64]u8 = undefined;
    var path_cli_zig: [64]u8 = undefined;
    var path_cli_bin: [64]u8 = undefined;
    const f_zag = std.fmt.bufPrint(&path_cli_zag, "/tmp/zag_cli_{d}.zag", .{pid_num}) catch "/tmp/zag_cli.zag";
    const f_zig = std.fmt.bufPrint(&path_cli_zig, "/tmp/zag_cli_{d}.zig", .{pid_num}) catch "/tmp/zag_cli.zig";
    const f_bin = std.fmt.bufPrint(&path_cli_bin, "/tmp/zag_cli_{d}_bin", .{pid_num}) catch "/tmp/zag_cli_bin";

    try writeFile(f_zag, embedded_cli_zag_source);
    const cli_source = try readFile(f_zag);
    const cli_zig_src = try transpile(cli_source);
    try writeFile(f_zig, cli_zig_src);

    var emit_buf: [128]u8 = undefined;
    const f_emit = std.fmt.bufPrint(&emit_buf, "-femit-bin={s}", .{f_bin}) catch "-femit-bin=/tmp/zag_cli_bin";

    const build_code = try runCommand(null, &.{
        zig_install_path, "build-exe", f_emit, f_zig,
    });
    if (build_code != 0) {
        std.debug.print("error: zig build-exe failed for cli.zag (exit {d})\n", .{build_code});
        std.process.exit(1);
    }

    // Pass f_bin as the executable override so the bootstrap execs
    // /tmp/zag_cli_<pid>_bin (NOT the original argv[0] which was
    // the zag binary path). cli_zag's `get()[0]` reads the
    // preserved argv[0]=zag-binary, so the leaf recursion
    // (argv0 --leaf-process=...) finds the correct zag binary.
    const run_code = try runCommand(f_bin, args);
    std.process.exit(run_code);
}

/// Leaf-process lifecycle. Reads the user .zag source, transpiles,
/// fork+execves `zig build-exe -femit-bin=/tmp/zag_leaf_<pid>_bin`,
/// then forks and execs the leaf binary (run-path) or prints
/// check/build-success and exits (check/build paths).
fn leafProcess(flag: []const u8, src: []const u8) !void {
    if (src.len == 0) {
        std.debug.print("error: --leaf-process=<mode> missing src argument\n", .{});
        std.process.exit(1);
    }

    const pid_num = std.os.linux.getpid();
    var path_leaf_zig: [64]u8 = undefined;
    var path_leaf_bin: [64]u8 = undefined;
    const f_zig = std.fmt.bufPrint(&path_leaf_zig, "/tmp/zag_leaf_{d}.zig", .{pid_num}) catch "/tmp/zag_leaf.zig";
    const f_bin = std.fmt.bufPrint(&path_leaf_bin, "/tmp/zag_leaf_{d}_bin", .{pid_num}) catch "/tmp/zag_leaf_bin";

    const source = try readFile(src);
    const zig_src = try transpile(source);
    try writeFile(f_zig, zig_src);

    // `zig test` does compile+run in one step — no separate build-exe.
    // The user-facing `zag test <file.zag>` subcommand routes here
    // (cli.zag's cmd_test recurses with --leaf-process=test). The
    // exit code from the chosen zig subcommand (0 = all pass /
    // successful run, non-zero = some failed / runtime error)
    // propagates verbatim so the user's shell sees the correct
    // status. zig's test/program output goes to stderr via the
    // inherited fd (runCommand's fork+execve preserves the child's
    // stderr), so failures are visible to the user.
    //
    // Dispatch: `zig test` only runs `test "..." {}` blocks; it
    // does NOT invoke `pub fn main()`. The canonical zag
    // `fun main() { ... }` form transpiles to a `pub fn main()
    // !void { ... }` that `zig test` would silently skip (or error
    // with "no tests found" depending on zig version). Detect
    // which shape the generated source has and route to the right
    // zig subcommand:
    //
    //   - has `test "` blocks → `zig test` (run the test blocks)
    //   - has `pub fn main(` only → `zig run` (run the program)
    //   - neither → error with a helpful message
    //
    // The detection is a substring check on the generated zig
    // source (`zig_src` is already in memory from the transpile
    // call above). A substring false-positive on a print statement
    // that prints the literal text `test "` is acceptable for v1 —
    // the user can use a different test-block shape, and the
    // heuristic is forward-compatible with zig's own test-block
    // detection (zig accepts any `test "<name>" { ... }` block
    // shape at any indentation level).
    if (std.mem.eql(u8, flag, "test")) {
        const has_test_block = std.mem.indexOf(u8, zig_src, "test \"") != null;
        const has_main = std.mem.indexOf(u8, zig_src, "pub fn main(") != null;
        if (has_test_block) {
            const test_code = try runCommand(null, &.{ zig_install_path, "test", f_zig });
            std.process.exit(test_code);
        } else if (has_main) {
            const run_code = try runCommand(null, &.{ zig_install_path, "run", f_zig });
            std.process.exit(run_code);
        } else {
            std.debug.print("error: {s} has no test blocks or main function — `zag test` requires test \"...\" {{}} blocks; use `zag run` for main() programs\n", .{src});
            std.process.exit(1);
        }
    }

    var emit_buf: [128]u8 = undefined;
    const f_emit_leaf = std.fmt.bufPrint(&emit_buf, "-femit-bin={s}", .{f_bin}) catch "-femit-bin=/tmp/zag_leaf_bin";

    // run/check fork+execve `zig build-exe` -- same `runCommand` so
    // child sees ZAG_ZIG_PATH.  build writes to ./a.out (the
    // pre-Phase-3 convention); run/check writes to /tmp/zag_leaf_<pid>_bin.
    const build_argv: []const []const u8 = if (std.mem.eql(u8, flag, "build"))
        &.{ zig_install_path, "build-exe", "-femit-bin=./a.out", f_zig }
    else
        &.{ zig_install_path, "build-exe", f_emit_leaf, f_zig };
    const build_code = try runCommand(null, build_argv);
    if (build_code != 0) {
        // Diagnostic mirror of cliMode's "error: zig build-exe
        // failed for cli.zag" print (src/main.zig:88-92): the leaf
        // path was previously silent because std.process.exit just
        // propagates build_code without surfacing zig's diagnostic
        // (the leaf's capture path doesn't re-print zig's stderr
        // when it gets disconnected). Mirrors the CLI path so user
        // failures point at the sourceline + exit status; zig's own
        // diagnostics live on stderr via fork+execve inheritance
        // (see `fork+execve preserves the child's stderr` comment
        // on the test-flag branch above).
        std.debug.print("error: zig build-exe failed for {s} (exit {d})\n", .{ src, build_code });
        std.process.exit(build_code);
    }

    if (std.mem.eql(u8, flag, "check")) {
        std.debug.print("check ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, flag, "build")) {
        std.debug.print("build ok: ./a.out\n", .{});
        return;
    }
    const run_code = try runCommand(null, &.{f_bin});
    std.process.exit(run_code);
}

/// Per-build helper. Forks+execves the given argv (`executable`
/// optionally overrides argv[0] as the binary path so cliMode can
/// fork `/tmp/zag_cli_<pid>_bin` while preserving the original user
/// argv). Inject `ZAG_ZIG_PATH=<zig_install_path>` into the env-pass
/// array so child processes (zig compiler, recursively-invoked
/// zap binary) locate zig without needing PATH lookup. Returns
/// the child's exit code (255 on parent fork failure or signal
/// kill, 127 on child execve failure).
fn runCommand(executable: ?[]const u8, argv: []const []const u8) !u8 {
    if (argv.len == 0 or argv.len > 14) return error.TooManyArgs;

    var arg_bufs: [15]?[:0]u8 = .{ null } ** 15;
    defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| std.heap.page_allocator.free(buf);

    var argv_z: [15]?[*:0]const u8 = .{ null } ** 15;
    for (argv, 0..) |arg, i| {
        const buf = try std.heap.page_allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(buf, arg);
        arg_bufs[i] = buf;
        argv_z[i] = buf.ptr;
    }

    // env-pass assembly. Reserve envp_z[len - 2] for ZAG_ZIG_PATH
    // entry + envp_z[len - 1] for the sentinel-null terminus.
    var envp_z: [513]?[*:0]const u8 = .{ null } ** 513;
    const env_real_count = @min(env_path.environ_count, envp_z.len - 2);
    for (env_path.environ_entries[0..env_real_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;

    // zig 0.16's allocPrintSentinel returns Error!T (NOT ?T like the
    // pre-0.16 allocPrintZ did). `catch null` coerces the
    // error-union to an optional so the if-let downstream can
    // succeed-or-skip identically to the pre-Phase-3 shape. Failure
    // (OOM) silently downgrades to no ZAG_ZIG_PATH injection -- the
    // child then uses PATH-lookup via the inherited env.
    const zig_env_opt: ?[:0]u8 = std.fmt.allocPrintSentinel(std.heap.page_allocator, "ZAG_ZIG_PATH={s}", .{zig_install_path}, 0) catch null;
    defer if (zig_env_opt) |ze| std.heap.page_allocator.free(ze);
    if (zig_env_opt) |ze| {
        envp_z[env_real_count] = @constCast(ze.ptr);
        envp_z[env_real_count + 1] = null;
    } else {
        envp_z[env_real_count] = null;
    }

    const pid_fork = std.math.cast(i32, std.os.linux.fork()) orelse return error.ForkFailed;
    if (pid_fork == 0) {
        const exec_path: [*:0]const u8 = blk: {
            if (executable) |ex| {
                const e_buf = std.heap.page_allocator.allocSentinel(u8, ex.len, 0) catch std.os.linux.exit(127);
                @memcpy(e_buf, ex);
                break :blk e_buf.ptr;
            }
            break :blk (arg_bufs[0] orelse std.os.linux.exit(127)).ptr;
        };
        const argv_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_z);
        const envp_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_z);
        _ = std.os.linux.execve(exec_path, argv_z_ptr, envp_z_ptr);
        std.os.linux.exit(127);
    }

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid_fork, &status, 0);
    if (std.os.linux.W.IFEXITED(status)) {
        return std.os.linux.W.EXITSTATUS(status);
    }
    return 255;
}

var file_buf: [1024 * 1024]u8 = undefined;

fn readFile(path: []const u8) ![]const u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);
    var total: usize = 0;
    while (total < file_buf.len) {
        const n = std.os.linux.read(fd, file_buf[total..].ptr, file_buf.len - total);
        if (n == 0) break;
        total += n;
    }
    return file_buf[0..total];
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const fd = try posix.openat(
        posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = std.os.linux.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = std.os.linux.write(fd, content[written..].ptr, content.len - written);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

var cmdline_buf: [4096]u8 = undefined;
var cmdline_args: [64][]const u8 = undefined;

fn parseArgs() ![][]const u8 {
    const fd = try posix.openat(posix.AT.FDCWD, "/proc/self/cmdline", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, &cmdline_buf, cmdline_buf.len);

    var count: usize = 0;
    var i: usize = 0;
    while (i < n and count < 64) : (count += 1) {
        const start = i;
        while (i < n and cmdline_buf[i] != 0) {
            i += 1;
        }
        cmdline_args[count] = cmdline_buf[start..i];
        i += 1;
    }
    return cmdline_args[0..count];
}

fn transpile(source: []const u8) ![]const u8 {
    var l = lexer_mod.Lexer.init(source);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    return cg.generate(prog);
}
