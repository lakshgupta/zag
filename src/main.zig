// -------------------------------------------------------------------
// src/main.zig -- zag CLI entry point.
//
// Two modes:
//   File mode:  `zag run <file.zag>`, `zag build <file.zag> [-o out]`
//   Project mode: `zag run`, `zag build` (no file arg → detect zag.toml)
//
// Project mode reads the project config from zag.toml, finds src/main.zag,
// transpiles to build/gen/, and emits the binary to build/bin/.
//
// ZAG_ZIG_PATH is read from the environment so child processes (zig
// compiler, leaf binary) locate zig without PATH lookup.
// -------------------------------------------------------------------

const std = @import("std");
const posix = std.posix;
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const codegen_mod = @import("codegen.zig");
const ast = @import("ast.zig");
const env_path = @import("env_path");
const project_mod = @import("project.zig");

var zig_install_path: []const u8 = "/home/lex/.local/zig/zig";

pub fn main() !void {
    env_path.readEnviron();
    if (env_path.getenv("ZAG_ZIG_PATH")) |zp| {
        zig_install_path = zp;
    }

    const args = try parseArgs();

    if (args.len >= 2 and std.mem.startsWith(u8, args[1], "--leaf-process=")) {
        const flag = args[1]["--leaf-process=".len..];
        try leafProcess(flag, if (args.len >= 3) args[2] else "", null, &.{});
        return;
    }

    if (args.len < 2) {
        usage();
        std.process.exit(1);
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        usage();
        return;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.debug.print("zag 0.1.0-dev\n", .{});
        return;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        if (args.len > 2) {
            try project_mod.createProject(args[2]);
        } else {
            try project_mod.createProject("");
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "run")) {
        return try cmdRun(args);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        return try cmdBuild(args);
    }
    if (std.mem.eql(u8, cmd, "check") or std.mem.eql(u8, cmd, "test")) {
        if (args.len >= 3 and hasZagExt(args[2])) {
            try leafProcess(cmd, args[2], null, &.{});
        } else if (try project_mod.detectProject("")) |cfg| {
            try projectCmd(cmd, cfg, &.{});
        } else {
            std.debug.print("error: missing file argument\n\n", .{});
            usage();
            std.process.exit(1);
        }
        return;
    }

    std.debug.print("error: unknown command '{s}'\n\n", .{cmd});
    usage();
    std.process.exit(1);
}

fn cmdRun(args: []const []const u8) !void {
    // Find -- separator to split zag args from program args
    const sep_idx = blk: {
        for (args, 0..) |a, i| {
            if (std.mem.eql(u8, a, "--")) break :blk i;
        }
        break :blk args.len;
    };

    // Extract extra args (after --)
    const extra_args = if (sep_idx < args.len) args[sep_idx + 1 ..] else &.{};

    // Determine mode: file specified before -- or after?
    // First non-flag arg after cmd is the file path (if any)
    const zag_file = blk: {
        if (args.len >= 3 and sep_idx >= 3 and hasZagExt(args[2])) {
            break :blk args[2];
        }
        if (sep_idx < args.len and args.len >= 3) {
            // Check if there's a file arg between cmd and --
            for (args[2..sep_idx], 2..) |a, i| {
                if (hasZagExt(a)) break :blk args[i];
            }
        }
        break :blk null;
    };

    if (zag_file) |file| {
        try leafProcess("run", file, null, extra_args);
    } else if (try project_mod.detectProject("")) |cfg| {
        try projectCmd("run", cfg, extra_args);
    } else {
        std.debug.print("error: missing file argument. Provide a .zag file or run from a project directory.\n\n", .{});
        usage();
        std.process.exit(1);
    }
}

fn cmdBuild(args: []const []const u8) !void {
    // Parse -o / --output
    var output_path: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            if (i + 1 < args.len) {
                output_path = args[i + 1];
                i += 1;
            } else {
                std.debug.print("error: -o/--output requires a path argument\n", .{});
                std.process.exit(1);
            }
        } else if (hasZagExt(a)) {
            file_arg = a;
        }
    }

    if (file_arg) |file| {
        const out = output_path orelse file[0..file.len - ".zag".len];
        try leafProcess("build", file, out, &.{});
    } else if (try project_mod.detectProject("")) |cfg| {
        try projectCmd("build", cfg, &.{});
    } else {
        std.debug.print("error: missing file argument. Provide a .zag file or run from a project directory.\n\n", .{});
        usage();
        std.process.exit(1);
    }
}

fn projectCmd(mode: []const u8, cfg: project_mod.ProjectConfig, extra_args: []const []const u8) !void {
    const root = cfg.root_dir;

    // Ensure build/gen/ and build/bin/ exist
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);

    // build/gen/
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);

    // build/bin/
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/bin", 0o755);

    // Find src/main.zag
    const src_main = srcPath(root, "src/main.zag");
    const source = readFile(src_main) catch {
        std.debug.print("error: {s}/src/main.zag not found\n", .{if (root.len > 0) root else "."});
        std.process.exit(1);
    };

    const zig_src = try transpile(source);

    try writeFile("build/gen/main.zig", zig_src);

    var out_bin_buf: [128]u8 = undefined;
    const out_bin = std.fmt.bufPrint(&out_bin_buf, "build/bin/{s}", .{cfg.name}) catch "build/bin/out";

    var emit_buf: [256]u8 = undefined;
    const f_emit = std.fmt.bufPrint(&emit_buf, "-femit-bin={s}", .{out_bin}) catch "-femit-bin=build/bin/out";

    const build_code = try runCommand(null, &.{
        zig_install_path, "build-exe", f_emit, "build/gen/main.zig",
    });
    if (build_code != 0) {
        std.debug.print("error: zig build-exe failed for {s} (exit {d})\n", .{ src_main, build_code });
        std.process.exit(build_code);
    }

    if (std.mem.eql(u8, mode, "check")) {
        std.debug.print("check ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "build")) {
        std.debug.print("build ok: {s}\n", .{out_bin});
        return;
    }
    if (std.mem.eql(u8, mode, "run")) {
        const run_code = try runCommandWithArgs(out_bin, extra_args);
        std.process.exit(run_code);
    }
}

fn srcPath(root: []const u8, sub: []const u8) []const u8 {
    _ = root;
    return sub;
}

fn hasZagExt(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zag");
}

fn usage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  zag run [<file.zag>] [-- <args>]   Compile and run (file or project)\n", .{});
    std.debug.print("  zag check [<file.zag>]             Type-check a file or project\n", .{});
    std.debug.print("  zag build [<file.zag>] [-o <path>] Compile to binary\n", .{});
    std.debug.print("  zag test [<file.zag>]              Run tests in a file or project\n", .{});
    std.debug.print("  zag init [<dir>]                   Create a new Zag project\n", .{});
    std.debug.print("  zag version                        Print version information\n", .{});
    std.debug.print("  zag help                           Show this help message\n", .{});
}

fn leafProcess(flag: []const u8, src: []const u8, output_path: ?[]const u8, extra_args: []const []const u8) !void {
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
    const out_target = output_path orelse f_bin;
    const f_emit = std.fmt.bufPrint(&emit_buf, "-femit-bin={s}", .{out_target}) catch "-femit-bin=/tmp/zag_leaf_bin";

    const build_argv: []const []const u8 = &.{ zig_install_path, "build-exe", f_emit, f_zig };
    const build_code = try runCommand(null, build_argv);
    if (build_code != 0) {
        std.debug.print("error: zig build-exe failed for {s} (exit {d})\n", .{ src, build_code });
        std.process.exit(build_code);
    }

    if (std.mem.eql(u8, flag, "check")) {
        std.debug.print("check ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, flag, "build")) {
        std.debug.print("build ok: {s}\n", .{out_target});
        return;
    }
    if (std.mem.eql(u8, flag, "run")) {
        const run_code = try runCommandWithArgs(out_target, extra_args);
        std.process.exit(run_code);
    }
}

fn runCommandWithArgs(executable: []const u8, extra_args: []const []const u8) !u8 {
    const total_args = 1 + extra_args.len;
    if (total_args > 14) return error.TooManyArgs;

    var arg_bufs: [15]?[:0]u8 = .{ null } ** 15;
    defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| std.heap.page_allocator.free(buf);

    var argv_z: [15]?[*:0]const u8 = .{ null } ** 15;

    // executable as argv[0]
    {
        const buf = try std.heap.page_allocator.allocSentinel(u8, executable.len, 0);
        @memcpy(buf, executable);
        arg_bufs[0] = buf;
        argv_z[0] = buf.ptr;
    }

    for (extra_args, 1..) |arg, i| {
        const buf = try std.heap.page_allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(buf, arg);
        arg_bufs[i] = buf;
        argv_z[i] = buf.ptr;
    }

    var envp_z: [513]?[*:0]const u8 = .{ null } ** 513;
    const env_real_count = @min(env_path.environ_count, envp_z.len - 2);
    for (env_path.environ_entries[0..env_real_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;

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
        const exec_path_buf = std.heap.page_allocator.allocSentinel(u8, executable.len, 0) catch std.os.linux.exit(127);
        @memcpy(exec_path_buf, executable);
        const argv_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_z);
        const envp_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_z);
        _ = std.os.linux.execve(exec_path_buf, argv_z_ptr, envp_z_ptr);
        std.os.linux.exit(127);
    }

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid_fork, &status, 0);
    if (std.os.linux.W.IFEXITED(status)) {
        return std.os.linux.W.EXITSTATUS(status);
    }
    return 255;
}

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

    var envp_z: [513]?[*:0]const u8 = .{ null } ** 513;
    const env_real_count = @min(env_path.environ_count, envp_z.len - 2);
    for (env_path.environ_entries[0..env_real_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;

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
