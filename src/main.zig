const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const codegen_mod = @import("codegen.zig");
const ast = @import("ast.zig");

var zig_path: []const u8 = undefined;

const usage =
    \\zag — a small, fast systems language
    \\
    \\Usage:
    \\  zag run <file.zag>     Compile and run a Zag file
    \\  zag check <file.zag>   Type-check a Zag file (compile to Zig only)
    \\  zag build <file.zag>   Compile a Zag file to a binary
    \\  zag init [name]        Create a new Zag project
    \\  zag version            Print version information
    \\  zag help               Show this help message
    \\
;

pub fn main() !void {
    zig_path = "/home/lex/.local/zig/zig";

    const args = try parseArgs();

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

    var threaded = Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = .{ .slice = readEnviron() } },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        std.debug.print("{s}", .{usage});
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            std.debug.print("error: missing file argument\n\n{s}", .{usage});
            std.process.exit(1);
        }
        try cmdRun(io, args[2]);
    } else if (std.mem.eql(u8, cmd, "check")) {
        if (args.len < 3) {
            std.debug.print("error: missing file argument\n\n{s}", .{usage});
            std.process.exit(1);
        }
        try cmdCheck(io, args[2]);
    } else if (std.mem.eql(u8, cmd, "build")) {
        if (args.len < 3) {
            std.debug.print("error: missing file argument\n\n{s}", .{usage});
            std.process.exit(1);
        }
        try cmdBuild(io, args[2]);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.debug.print("zag {s}\n", .{"0.1.0-dev"});
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(io, args);
    } else {
        std.debug.print("error: unknown command '{s}'\n\n{s}", .{ cmd, usage });
        std.process.exit(1);
    }
}

var environ_entries: [512]?[*:0]const u8 = undefined;
var environ_buf: [131072]u8 = undefined;

fn readEnviron() [:null]const ?[*:0]const u8 {
    const fd = posix.openat(posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return &.{};
    const n = posix.read(fd, &environ_buf) catch return &.{};

    var count: usize = 0;
    var i: usize = 0;
    while (i < n and count < 512) : (count += 1) {
        const start = i;
        while (i < n and environ_buf[i] != 0) : (i += 1) {}
        environ_entries[count] = environ_buf[start..i :0];
        i += 1;
    }
    environ_entries[count] = null;
    return environ_entries[0..count :null];
}

fn cmdRun(io: Io, path: []const u8) !void {
    const source = try readFile(path);
    const zig_src = try transpile(source);

    const out_path = "/tmp/zag_out.zig";
    try writeFile(io, out_path, zig_src);

    var child = try std.process.spawn(io, .{
        .argv = &.{ zig_path, "build-exe", "-femit-bin=/tmp/zag_bin", out_path },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.process.exit(1);
    }

    var run_child = try std.process.spawn(io, .{
        .argv = &.{"/tmp/zag_bin"},
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const run_term = try run_child.wait(io);
    if (run_term != .exited or run_term.exited != 0) {
        std.process.exit(1);
    }
}

fn cmdCheck(io: Io, path: []const u8) !void {
    const source = try readFile(path);
    const zig_src = try transpile(source);

    const out_path = "/tmp/zag_out.zig";
    try writeFile(io, out_path, zig_src);

    const result = try std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ zig_path, "build-exe", "-femit-bin=/tmp/zag_check_out", out_path },
    });
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        std.process.exit(1);
    }
    std.debug.print("check ok\n", .{});
}

fn cmdBuild(io: Io, path: []const u8) !void {
    const source = try readFile(path);
    const zig_src = try transpile(source);

    const out_path = "/tmp/zag_out.zig";
    try writeFile(io, out_path, zig_src);

    const result = try std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ zig_path, "build-exe", "-femit-bin=./a.out", out_path },
    });
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        std.process.exit(1);
    }
    std.debug.print("build ok: ./a.out\n", .{});
}

fn cmdInit(io: Io, args: [][]const u8) !void {
    const name: ?[]const u8 = if (args.len > 2) args[2] else null;

    const boilerplate =
        \\fun main() {
        \\    print("hello, world\n");
        \\}
        \\
    ;

    if (name) |n| {
        // Attempt to create the directory; ignore errors since writeFile
        // will fail with a clear message if the directory is unusable.
        _ = std.os.linux.mkdir(@ptrCast(n.ptr), 0o777);

        const suffix = "/hello.zag";
        if (n.len + suffix.len > 255) {
            std.debug.print("error: project name too long\n", .{});
            std.process.exit(1);
        }

        var path_buf: [256]u8 = undefined;
        var i: usize = 0;
        for (n) |c| {
            path_buf[i] = c;
            i += 1;
        }
        for (suffix) |c| {
            path_buf[i] = c;
            i += 1;
        }
        const path = path_buf[0..i];

        try writeFile(io, path, boilerplate);
        std.debug.print("created {s}\n", .{path});
    } else {
        try writeFile(io, "hello.zag", boilerplate);
        std.debug.print("created hello.zag\n", .{});
    }
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

var file_buf: [1024 * 1024]u8 = undefined;

fn readFile(path: []const u8) ![]const u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    var total: usize = 0;
    while (total < file_buf.len) {
        const n = try posix.read(fd, file_buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return file_buf[0..total];
}

fn writeFile(io: Io, path: []const u8, content: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

var cmdline_buf: [4096]u8 = undefined;
var cmdline_args: [64][]const u8 = undefined;

fn parseArgs() ![][]const u8 {
    const fd = try posix.openat(posix.AT.FDCWD, "/proc/self/cmdline", .{ .ACCMODE = .RDONLY }, 0);
    const n = try posix.read(fd, &cmdline_buf);

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

test "lexer: hello world" {
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var count: usize = 0;
    for (tokens) |tok| {
        if (tok.tag != .newline) count += 1;
    }

    try std.testing.expectEqual(@as(usize, 11), count);
    try std.testing.expectEqual(lexer_mod.TokenTag.fun, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.lparen, tokens[2].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.rparen, tokens[3].tag);
}

test "parser: hello world" {
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    try std.testing.expectEqualStrings("main", prog.functions[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.functions[0].body.len);
}

test "codegen: hello world" {
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "std.debug.print") != null);
}
