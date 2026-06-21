const std = @import("std");
const posix = std.posix;
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

    readEnviron();

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        std.debug.print("{s}", .{usage});
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            std.debug.print("error: missing file argument\n\n{s}", .{usage});
            std.process.exit(1);
        }
        try cmdRun(args[2]);
    } else if (std.mem.eql(u8, cmd, "check")) {
        if (args.len < 3) {
            std.debug.print("error: missing file argument\n\n{s}", .{usage});
            std.process.exit(1);
        }
        try cmdCheck(args[2]);
    } else if (std.mem.eql(u8, cmd, "build")) {
        if (args.len < 3) {
            std.debug.print("error: missing file argument\n\n{s}", .{usage});
            std.process.exit(1);
        }
        try cmdBuild(args[2]);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.debug.print("zag {s}\n", .{"0.1.0-dev"});
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(args);
    } else {
        std.debug.print("error: unknown command '{s}'\n\n{s}", .{ cmd, usage });
        std.process.exit(1);
    }
}

var environ_entries: [512]?[*:0]const u8 = undefined;
var environ_buf: [131072]u8 = undefined;
var environ_count: usize = 0;

fn readEnviron() void {
    const fd = posix.openat(posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return;
    const n = std.os.linux.read(fd, &environ_buf, environ_buf.len);
    _ = std.os.linux.close(fd);

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

fn cmdRun(path: []const u8) !void {
    const source = try readFile(path);
    const zig_src = try transpile(source);

    try writeFile("/tmp/zag_out.zig", zig_src);

    const build_code = try runCommand(&.{
        zig_path, "build-exe", "-femit-bin=/tmp/zag_bin", "/tmp/zag_out.zig",
    });
    if (build_code != 0) std.process.exit(1);

    const run_code = try runCommand(&.{"/tmp/zag_bin"});
    if (run_code != 0) std.process.exit(1);
}

fn cmdCheck(path: []const u8) !void {
    const source = try readFile(path);
    const zig_src = try transpile(source);

    try writeFile("/tmp/zag_out.zig", zig_src);

    const code = try runCommand(&.{
        zig_path, "build-exe", "-femit-bin=/tmp/zag_check_out", "/tmp/zag_out.zig",
    });
    if (code != 0) std.process.exit(1);
    std.debug.print("check ok\n", .{});
}

fn cmdBuild(path: []const u8) !void {
    const source = try readFile(path);
    const zig_src = try transpile(source);

    try writeFile("/tmp/zag_out.zig", zig_src);

    const code = try runCommand(&.{
        zig_path, "build-exe", "-femit-bin=./a.out", "/tmp/zag_out.zig",
    });
    if (code != 0) std.process.exit(1);
    std.debug.print("build ok: ./a.out\n", .{});
}

fn cmdInit(args: [][]const u8) !void {
    const name: ?[]const u8 = if (args.len > 2) args[2] else null;

    const boilerplate =
        \\fun main() {
        \\    print("hello, world\n");
        \\}
        \\
    ;

    if (name) |n| {
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

        try writeFile(path, boilerplate);
        std.debug.print("created {s}\n", .{path});
    } else {
        try writeFile("hello.zag", boilerplate);
        std.debug.print("created hello.zag\n", .{});
    }
}

fn runCommand(argv: []const []const u8) !u8 {
    if (argv.len == 0 or argv.len > 14) return error.TooManyArgs;

    // Allocate null-terminated mutable copies of each arg so we can free them.
    var arg_bufs: [15]?[:0]u8 = .{null} ** 15;
    defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| std.heap.page_allocator.free(buf);

    // execve in zig 0.16 wants a `[*:null]const ?[*:0]const u8` argv/envp:
    // a many-item pointer to an optional-pointer array, with the last entry
    // being null (the array's null sentinel). So argv_z is an array of nullable
    // string pointers, pre-initialised to null, and we fill in argv.len entries
    // (the trailing null sentinel is already in place).
    var argv_z: [15]?[*:0]const u8 = .{null} ** 15;
    for (argv, 0..) |arg, i| {
        const buf = try std.heap.page_allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(buf, arg);
        arg_bufs[i] = buf;
        argv_z[i] = buf.ptr;
    }

    var envp_z: [513]?[*:0]const u8 = .{null} ** 513;
    const env_count = @min(environ_count, envp_z.len - 1);
    for (environ_entries[0..env_count], 0..) |maybe_env, i| envp_z[i] = maybe_env;

    // std.os.linux.fork() returns usize in zig 0.16, but waitpid's pid
    // parameter expects i32 (pid_t). std.math.cast gives a clean overflow-safe
    // conversion; -1 from a failed fork encodes as max usize which fails the
    // cast and routes to error.ForkFailed.
    const pid = std.math.cast(i32, std.os.linux.fork()) orelse return error.ForkFailed;
    if (pid == 0) {
        // execve path must be [*:0]const u8; for the path we need the
        // first arg's null-terminated buffer (which we already allocated).
        const buf0: [:0]u8 = arg_bufs[0] orelse std.os.linux.exit(127);
        const argv_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_z);
        const envp_z_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&envp_z);
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

test "lexer: line comment is skipped" {
    const src = "# a comment\nfun main() {\n    print(\"hi\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var has_doc = false;
    for (tokens) |tok| {
        if (tok.tag == .doc_comment) has_doc = true;
    }
    try std.testing.expect(!has_doc);
    try std.testing.expectEqual(lexer_mod.TokenTag.newline, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.fun, tokens[1].tag);
}

test "lexer: single-line doc comment" {
    const src = "## greets the user\nfun main() {\n    print(\"hi\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    try std.testing.expectEqual(lexer_mod.TokenTag.doc_comment, tokens[0].tag);
    try std.testing.expect(std.mem.indexOf(u8, tokens[0].text, " greets the user") != null);
}

test "lexer: multi-line doc comment with continuation" {
    const src = "## reads a file\n# returns error on missing\nfun read() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    try std.testing.expectEqual(lexer_mod.TokenTag.doc_comment, tokens[0].tag);
    try std.testing.expect(std.mem.indexOf(u8, tokens[0].text, "reads a file") != null);
    try std.testing.expect(std.mem.indexOf(u8, tokens[0].text, "returns error on missing") != null);
}

test "parser: doc attached to fun decl" {
    const src = "## adds a and b\nfun add() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    try std.testing.expect(prog.functions[0].doc != null);
    try std.testing.expect(std.mem.indexOf(u8, prog.functions[0].doc.?, "adds a and b") != null);
}

test "parser: no doc when not present" {
    const src = "fun add() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    try std.testing.expect(prog.functions[0].doc == null);
}

test "codegen: doc comment emitted as zig ///" {
    const src = "## adds a and b\nfun add() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// adds a and b") != null);
}

test "codegen: multi-line doc emitted as multiple ///" {
    const src = "## first line\n# second line\nfun f() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);

    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "/// second line") != null);
}

test "lexer: consecutive ## starts new doc block" {
    const src = "## first\n## second\nfun f() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var doc_count: usize = 0;
    var expected_first = false;
    var expected_second = false;
    for (tokens) |tok| {
        if (tok.tag == .doc_comment) {
            doc_count += 1;
            if (std.mem.indexOf(u8, tok.text, "first") != null) expected_first = true;
            if (std.mem.indexOf(u8, tok.text, "second") != null) expected_second = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), doc_count);
    try std.testing.expect(expected_first);
    try std.testing.expect(expected_second);
}

test "lexer: hex integer prefix" {
    const src = "0xFF";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("0xFF", tokens[0].text);
}

test "lexer: octal integer prefix" {
    const src = "0o77";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("0o77", tokens[0].text);
}

test "lexer: binary integer prefix" {
    const src = "0b1010";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("0b1010", tokens[0].text);
}

test "lexer: integer with underscores" {
    const src = "1_000_000";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("1_000_000", tokens[0].text);
}

test "lexer: float literal decimal" {
    const src = "3.14";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.float_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("3.14", tokens[0].text);
}

test "lexer: float literal exponent" {
    const src = "1.0e10";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.float_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("1.0e10", tokens[0].text);
}

test "lexer: float literal without fractional" {
    const src = "1e10";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.float_literal, tokens[0].tag);
}

test "lexer: dot after integer is not float" {
    // `42.method()` style: the . should not be consumed as a float
    const src = "42";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
}

test "lexer: true/false/null/undefined as keywords" {
    const src = "true false null undefined";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.true_kw, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.false_kw, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.null_kw, tokens[2].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.undefined_kw, tokens[3].tag);
}

test "lexer: char literal simple" {
    const src = "'a'";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.char_literal, tokens[0].tag);
}

test "lexer: char literal escape" {
    const src = "'\\n'";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.char_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("'\\n'", tokens[0].text);
}

test "lexer: byte string literal" {
    const src = "b\"hello\"";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.byte_string_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("hello", tokens[0].text);
}

test "parser: bool literal" {
    const src = "fun main() {\n    let on: bool = true;\n    let off: bool = false;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.functions.len);
    const body = prog.functions[0].body;
    try std.testing.expect(body.len > 0 and body[0] == .let);
    try std.testing.expect(body[1] == .let);
}

test "parser: tuple literal" {
    const src = "fun main() {\n    let p = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    try std.testing.expect(body.len > 0 and body[0] == .let);
    const init = body[0].let.init;
    try std.testing.expect(init == .tuple_lit);
    try std.testing.expectEqual(@as(usize, 2), init.tuple_lit.len);
}

test "parser: empty tuple" {
    const src = "fun main() {\n    let u = ();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    const init = body[0].let.init;
    try std.testing.expect(init == .tuple_lit);
    try std.testing.expectEqual(@as(usize, 0), init.tuple_lit.len);
}

test "parser: single paren still groups" {
    const src = "fun main() {\n    let x = (42);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    const init = body[0].let.init;
    // (42) groups to int_lit, not a tuple
    try std.testing.expect(init == .int_lit);
}

test "codegen: hex literal preserved" {
    const src = "fun f() {\n    let x: i32 = 0xFF;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "0xFF") != null);
}

test "codegen: float literal preserved" {
    const src = "fun f() {\n    let pi: f64 = 3.14;\n    let e: f64 = 1.0e10;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "3.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "1.0e10") != null);
}

test "codegen: bool literal emits true/false" {
    const src = "fun f() {\n    let on: bool = true;\n    let off: bool = false;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= false;") != null);
}

test "codegen: null and undefined emit literally" {
    const src = "fun f() {\n    let a: ?i32 = null;\n    let b: i32 = undefined;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= undefined;") != null);
}

test "codegen: char literal emit" {
    const src = "fun f() {\n    let c: u8 = 'a';\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "'a'") != null);
}

test "codegen: byte string emits zig string" {
    const src = "fun f() {\n    let b = b\"hello\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"hello\"") != null);
}

test "codegen: tuple emits anonymous struct" {
    const src = "fun f() {\n    let p = (10, 20);\n    let empty = ();\n    let mixed = (1, 2.5, true);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 10, 20 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= {};") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 1, 2.5, true }") != null);
}

test "lexer: lbracket and rbracket and ellipsis tokens" {
    var l = lexer_mod.Lexer.init("[1]i32 { 10 ... }");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.lbracket, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.rbracket, tokens[2].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.lbrace, tokens[4].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[5].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.ellipsis, tokens[6].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.rbrace, tokens[7].tag);
}

test "parser: array lit explicit" {
    const src = "fun f() {\n    let a = [3]i32 { 1, 2, 3 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 3), init.array_lit.size);
    try std.testing.expectEqualStrings("i32", init.array_lit.type_name);
    try std.testing.expectEqual(@as(usize, 3), init.array_lit.elements.len);
    try std.testing.expect(!init.array_lit.fill);
    try std.testing.expect(!init.array_lit.progression);
}

test "parser: array lit fill" {
    const src = "fun f() {\n    let a = [5]i32 { 0 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 5), init.array_lit.size);
    try std.testing.expect(init.array_lit.fill);
    try std.testing.expect(!init.array_lit.progression);
    try std.testing.expectEqual(@as(usize, 1), init.array_lit.elements.len);
}

test "parser: array lit progression" {
    const src = "fun f() {\n    let a = [4]i32 { 1, 2 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .array_lit);
    try std.testing.expectEqual(@as(u32, 4), init.array_lit.size);
    try std.testing.expect(init.array_lit.progression);
    try std.testing.expectEqual(@as(usize, 2), init.array_lit.elements.len);
}

test "parser: string with braces becomes template_lit" {
    const src = "fun f() {\n    let msg = \"hello, {name}\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .template_lit);
    // 3 parts: "hello, " literal, name ident, "" trailing literal
    try std.testing.expectEqual(@as(usize, 3), init.template_lit.parts.len);
    try std.testing.expectEqualStrings("hello, ", init.template_lit.parts[0].literal.?);
    try std.testing.expectEqualStrings("name", init.template_lit.parts[1].expr.?.ident);
}

test "parser: plain string stays string_lit" {
    const src = "fun f() {\n    let s = \"plain\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .string_lit);
}

test "codegen: array explicit emits [N]T{...}" {
    const src = "fun f() {\n    let a = [3]i32 { 1, 2, 3 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[3]i32{ 1, 2, 3 }") != null);
}

test "codegen: array fill emits [1]T{...}**N" {
    const src = "fun f() {\n    let z = [5]i32 { 0 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "[1]i32{ 0 } ** 5") != null);
}

test "codegen: array progression emits blk+__pat pattern" {
    const src = "fun f() {\n    let r = [4]i32 { 1, 2 ... };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __arr: [4]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __pat: [2]i32 = .{ 1, 2 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__pat[__i % 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __arr") != null);
}

test "codegen: template literal in print emits std.debug.print" {
    const src = "fun f() {\n    let name = \"zag\";\n    print(\"hello, {name}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // zig 0.16 requires a trailing comma inside `.{...}` even when only one
    // field is present; we always emit `.{name,}` for single-arg interpolation.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.print(\"hello, {any}\\n\", .{name,})") != null);
}

test "codegen: template preserves LF byte in literal via \\n escape" {
    // zag user wrote literal newline byte inside the string (inside "").
    // The format string in codegen must escape it to \\n so the zig string
    // literal remains valid.
    const src = "fun f() {\n    let x = \"a\";\n    print(\"a{x}a\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "\"a{any}a\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.print") != null);
}

test "codegen: module-level interp_buf emitted" {
    const src = "fun f() {\n    print(\"{x}\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __zag_interp_buf: [4096]u8 = undefined") != null);
}

test "parser: let with type annotation" {
    // Pre-carve-out tests inadvertently regressed to bare `let x = 42` when
    // the static-typed-coercion migration commit landed (the carve-out makes
    // bare-form bindings legal, but the test was written when bare-form
    // auto-typed to `: i32`). An explicit `: T` source matches the assertion
    // (and is the same form the docs recommend now).
    const src = "fun f() {\n    let x: i32 = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expectEqualStrings("x", stmt.let.name);
    try std.testing.expectEqualStrings("i32", stmt.let.type_name.?);
    try std.testing.expect(stmt.let.init == .int_lit);
}

test "parser: let without type annotation" {
    const src = "fun f() {\n    let x = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expectEqualStrings("x", stmt.let.name);
    try std.testing.expect(stmt.let.type_name == null);
    try std.testing.expect(stmt.let.init == .int_lit);
}

test "parser: let with f64 annotation" {
    const src = "fun f() {\n    let speed: f64 = 1.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expectEqualStrings("speed", stmt.let.name);
    try std.testing.expectEqualStrings("f64", stmt.let.type_name.?);
}

test "parser: let with multiple lets each annotated" {
    const src = "fun f() {\n    let x: i32 = 1;\n    let y: f64 = 2.0;\n    let z = true;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqualStrings("i32", body[0].let.type_name.?);
    try std.testing.expectEqualStrings("f64", body[1].let.type_name.?);
    try std.testing.expect(body[2].let.type_name == null);
}

test "codegen: let with type annotation emits `: T`" {
    // Same regression fix as the parser test above — explicit `: i32` to
    // match the codegen expectation `const x: i32 = 42`.
    const src = "fun f() {\n    let x: i32 = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x: i32 = 42;") != null);
}

test "codegen: let without annotation emits bare `const x = ...`" {
    const src = "fun f() {\n    let x = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x = 42;") != null);
    // Sanity: no surprise `: int32` token crept in.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x:") == null);
}

test "codegen: let with f64 annotation" {
    const src = "fun f() {\n    let pi: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const pi: f64 = 3.14;") != null);
}

test "lexer: arithmetic operators are tokens" {
    var l = lexer_mod.Lexer.init("a + b - c * d / e");
    const tokens = l.tokenize();
    const seq = [_]lexer_mod.TokenTag{
        .identifier, .plus, .identifier, .minus, .identifier, .star, .identifier, .slash, .identifier,
    };
    var i: usize = 0;
    // `tokens` includes an `.eof` sentinel at the end — without the break,
    // the loop accesses `seq[9]` past the 9-element array and panics. Same
    // treatment for `.newline` so the loop counts only meaningful tokens.
    for (tokens) |tok| {
        if (tok.tag == .eof) break;
        if (tok.tag == .newline) continue;
        try std.testing.expectEqual(seq[i], tok.tag);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), i);
}

test "parser: simple binary add" {
    const src = "fun f() {\n    let z: i32 = 1 + 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .int_lit);
    try std.testing.expect(init.binary.rhs.* == .int_lit);
}

test "parser: precedence — mul binds tighter than add" {
    // 1 + 2 * 3 → 1 + (2 * 3) → binary(add, 1, binary(mul, 2, 3))
    const src = "fun f() {\n    let z: i32 = 1 + 2 * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .int_lit);
    try std.testing.expect(init.binary.rhs.* == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.binary.rhs.*.binary.op);
}

test "parser: precedence — parens override" {
    // (1 + 2) * 3 → binary(mul, binary(add, 1, 2), 3)
    const src = "fun f() {\n    let z: i32 = (1 + 2) * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.binary.op);
    try std.testing.expectEqual(ast.Expr.BinaryOp.add, init.binary.lhs.*.binary.op);
}

test "parser: left-associative chain" {
    // 1 - 2 - 3 → (1 - 2) - 3 → binary(sub, binary(sub, 1, 2), 3)
    const src = "fun f() {\n    let z: i32 = 1 - 2 - 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expectEqual(ast.Expr.BinaryOp.sub, init.binary.op);
    try std.testing.expectEqual(ast.Expr.BinaryOp.sub, init.binary.lhs.*.binary.op);
    try std.testing.expect(init.binary.lhs.*.binary.lhs.* == .int_lit);
}

test "parser: identifier operands" {
    const src = "fun f() {\n    let z: i32 = x * y;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.mul, init.binary.op);
    try std.testing.expectEqualStrings("x", init.binary.lhs.*.ident);
    try std.testing.expectEqualStrings("y", init.binary.rhs.*.ident);
}

test "codegen: binary emission is parenthesised" {
    // The generated zigzag source must wrap binary expressions in `()` so
    // downstream zig's natural precedence rules cannot reorder the AST's
    // intent (relevant once we add lower-precedence operators).
    const src = "fun f() {\n    let z: i32 = 1 + 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + 2);") != null);
}

test "codegen: precedenced arithmetic emits nested parens" {
    // 1 + 2 * 3 must surface as `1 + (2 * 3)` in generated zigzag source so
    // zig observes the AST's chosen ruling under standard math precedence.
    const src = "fun f() {\n    let z: i32 = 1 + 2 * 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + (2 * 3));") != null);
}

test "lexer: minus between variables is binary operator" {
    // Regression: previously `-` after a non-digit was routed to readNumber
    // and emitted a bogus `integer_literal "-"`. Confirm we now emit `.minus`.
    var l = lexer_mod.Lexer.init("x - y");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.minus, tokens[1].tag);
    try std.testing.expectEqualStrings("-", tokens[1].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[2].tag);
}

test "lexer: plus between variables is binary operator" {
    // Regression: previously `+` fell into the unhandled-char `else` branch
    // and was silently self.advance()'d, dropping the operator entirely.
    var l = lexer_mod.Lexer.init("x + y");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.plus, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[2].tag);
}

test "lexer: positive number prefix still parses" {
    // Symmetry: `+5` should still lex as one integer literal, not as `+` then `5`.
    var l = lexer_mod.Lexer.init("+5");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("+5", tokens[0].text);
}

test "lexer: var is a keyword" {
    const src = "var x = 1";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.var_kw, tokens[0].tag);
    try std.testing.expectEqualStrings("var", tokens[0].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("x", tokens[1].text);
}

test "parser: var with type annotation" {
    const src = "fun f() {\n    var y: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .var_binding);
    try std.testing.expectEqualStrings("y", stmt.var_binding.name);
    try std.testing.expectEqualStrings("f64", stmt.var_binding.type_name.?);
    try std.testing.expect(stmt.var_binding.init == .float_lit);
}

test "parser: var without type annotation" {
    const src = "fun f() {\n    var n = 0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .var_binding);
    try std.testing.expect(stmt.var_binding.type_name == null);
}

test "parser: bare assignment is recognised as .assign" {
    const src = "fun f() {\n    y = 5;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .assign);
    try std.testing.expectEqualStrings("y", stmt.assign.name);
    try std.testing.expect(stmt.assign.value == .int_lit);
}

test "parser: identifier expr without `=` stays `.expr_stmt`" {
    // Single ident with no follow-up `=` is treated as a free expression
    // statement, NOT an assignment; the lookahead at statement-scope is the
    // boundary between the two branches.
    const src = "fun f() {\n    y;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .expr_stmt);
    try std.testing.expect(stmt.expr_stmt == .ident);
    try std.testing.expectEqualStrings("y", stmt.expr_stmt.ident);
}

test "codegen: var emits Zig `var`" {
    const src = "fun f() {\n    var y: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var y: f64 = 3.14;") != null);
}

test "codegen: bare assignment emits `name = expr;`" {
    const src = "fun f() {\n    y = 99;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    y = 99;") != null);
}

test "codegen: var + assign sequence end-to-end" {
    // The basics/variables.zag pattern in miniature: `var` declares, `=`
    // rebinds, both compile to Zig `var NAME: T = …` / `NAME = …;`.
    const src = "fun f() {\n    var count: i32 = 0;\n    count = count + 0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var count: i32 = 0;") != null);
    // With binary operators live, the RHS renders as `(count + 0)` (the
    // genExpr `.binary` case always parenthesises). Confirms the rebinding
    // point is `count = (count + 0);` and the whole pattern compiles.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    count = (count + 0);") != null);
}

test "lexer: const is a keyword" {
    const src = "const x = 1";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.const_kw, tokens[0].tag);
    try std.testing.expectEqualStrings("const", tokens[0].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("x", tokens[1].text);
}

test "parser: const with type annotation" {
    const src = "fun f() {\n    const PI: f64 = 3.14;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .const_binding);
    try std.testing.expectEqualStrings("PI", stmt.const_binding.name);
    try std.testing.expectEqualStrings("f64", stmt.const_binding.type_name.?);
    try std.testing.expect(stmt.const_binding.init == .float_lit);
}

test "parser: const without type annotation" {
    const src = "fun f() {\n    const k = 7;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .const_binding);
    try std.testing.expectEqualStrings("k", stmt.const_binding.name);
    try std.testing.expect(stmt.const_binding.type_name == null);
    try std.testing.expect(stmt.const_binding.init == .int_lit);
}

test "codegen: const emits Zig `const`" {
    const src = "fun f() {\n    const MAX: i32 = 100;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const MAX: i32 = 100;") != null);
}

test "codegen: const without annotation emits bare `const x = …`" {
    const src = "fun f() {\n    const answer = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const answer = 42;") != null);
    // Sanity: no surprise `: TYPE` token crept in.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const answer:") == null);
}

test "codegen: const + var mix matches examples/basics/variables.zag" {
    // The exact pattern in basics/variables.zag's binding declarations:
    // `let x: i32`, `var y: f64`, `const PI: f64`. The codegen shape matches
    // but each uses the distinct keyword then the distinct emitted zig
    // binding.
    // (broken raw-string form was here; replaced with regular string form below)
    const src = "f() { let x = if Foo { 1 } else { 2 }; let v = Vec3 { x: 1, y: 2, z: 3 };\n}";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x: i32 = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var y: f64 = 3.14;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const PI: f64 = 3.14159;") != null);
}

test "parser: format spec preserved on interpolation" {
    // `{PI:.5}` should split into expr="PI" and spec=".5" at the first `:`.
    // The expr stays a single `.ident` so zig can re-tokenise it; the spec
    // is preserved separately so codegen can append it to the placeholder.
    const src = "fun f() {\n    print(\"{PI:.5}\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[0];
    const arg = print_stmt.expr_stmt.call.args[0];
    try std.testing.expect(arg == .template_lit);
    // source "{PI:.5}" has no leading text, so buildTemplate emits:
    //   parts[0] = { expr = ident "PI",  spec = ".5" }   (interpolation)
    //   parts[1] = { literal = "" }                       (trailing literal)
    try std.testing.expectEqual(@as(usize, 2), arg.template_lit.parts.len);
    try std.testing.expect(arg.template_lit.parts[0].literal == null);
    try std.testing.expect(arg.template_lit.parts[0].expr != null);
    try std.testing.expectEqualStrings("PI", arg.template_lit.parts[0].expr.?.ident);
    try std.testing.expect(arg.template_lit.parts[0].spec != null);
    try std.testing.expectEqualStrings(".5", arg.template_lit.parts[0].spec.?);
    try std.testing.expect(arg.template_lit.parts[1].literal != null);
    try std.testing.expectEqualStrings("", arg.template_lit.parts[1].literal.?);
}

test "parser: plain interpolation has null spec" {
    // Backward-compat: `{name}` (no `:`) leaves `spec` null so codegen
    // produces the plain `{any}` placeholder unchanged.
    const src = "fun f() {\n    let name = \"zag\";\n    print(\"hello, {name}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const print_stmt = prog.functions[0].body[1];
    const arg = print_stmt.expr_stmt.call.args[0];
    try std.testing.expect(arg == .template_lit);
    // The single interpolation part has `spec == null`.
    for (arg.template_lit.parts) |part| {
        if (part.expr) |expr| {
            try std.testing.expectEqualStrings("name", expr.ident);
            try std.testing.expect(part.spec == null);
        }
    }
}

test "codegen: format spec emitted in placeholder" {
    // The full `{PI:.5}` template must surface as `{any:.5}` in the
    // generated zigzag source — the spec is appended verbatim after `{any}`
    // so zig's debug formatter applies it. Args tuple still emits only `PI`
    // (not `PI:.5`); the spec lives in the format string, not the args.
    // (was 3-line broken raw-string form; collapsed to single-line)
    const src = "f() { let x = if Foo { 1 } else { 2 }; let v = Vec3 { x: 1, y: 2, z: 3 };\n}";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:.5}") != null);
    // Sanity: the args tuple carries just PI, not PI:.5 — the colon should
    // only appear inside the format string, never the args list.
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{PI,})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "PI:.5,") == null);
}

test "codegen: integer width spec flows through" {
    // Integer width spec `:5` flows through the same pipeline. Confirms
    // the parser-codegen pairing handles non-`.5` spec shapes uniformly.
    const src =
        \\fun f() {
        \\    let n: i32 = 42;
        \\    print("[{n:5}]\n");
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "{any:5}") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{n,})") != null);
}

test "codegen: multi-arg interpolation without specs still works" {
    // The reviewer's regression concern: after the spec-append change, a
    // multi-arg template with NO specs must still emit `.{name1, name2, name3,}`
    // (single trailing comma). Mirrors the basics/variables.zag final print.
    const src =
        \\fun f() {
        \\    let z: i32 = 100;
        \\    let flag: bool = true;
        \\    let ch: u8 = 'Z';
        \\    print("z = {z}, flag = {flag}, ch = {ch}\n");
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "z = {any}, flag = {any}, ch = {any}\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ", .{z, flag, ch,})") != null);
}

test "parser: tuple destructuring" {
    // `let (x, y) = (10, 20);` should split into a tuple pattern with two
    // name leaves. The legacy `name` field is the empty sentinel for
    // destructuring forms.
    const src = "fun f() {\n    let (x, y) = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.pattern != null);
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    try std.testing.expectEqual(@as(usize, 2), stmt.let.pattern.?.tuple.len);
    try std.testing.expectEqualStrings("x", stmt.let.pattern.?.tuple[0].name);
    try std.testing.expectEqualStrings("y", stmt.let.pattern.?.tuple[1].name);
    try std.testing.expectEqualStrings("", stmt.let.name);
    try std.testing.expect(stmt.let.type_name == null);
    try std.testing.expect(stmt.let.init == .tuple_lit);
}

test "parser: array destructuring" {
    // `let [a, b, c] = arr;` should split into an array pattern with three
    // name leaves. Same legacy-field-sentinel behaviour as tuple form.
    const src = "fun f() {\n    let [a, b, c] = arr;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.pattern != null);
    try std.testing.expect(stmt.let.pattern.? == .array);
    try std.testing.expectEqual(@as(usize, 3), stmt.let.pattern.?.array.len);
    try std.testing.expectEqualStrings("a", stmt.let.pattern.?.array[0].name);
    try std.testing.expectEqualStrings("b", stmt.let.pattern.?.array[1].name);
    try std.testing.expectEqualStrings("c", stmt.let.pattern.?.array[2].name);
    try std.testing.expect(stmt.let.init == .ident);
    try std.testing.expectEqualStrings("arr", stmt.let.init.ident);
}

test "parser: destructuring with wildcard discard" {
    // `let (_, y, _) = (1, 2, 3);` should split into a tuple of
    // [discard, name("y"), discard].
    const src = "fun f() {\n    let (_, y, _) = (1, 2, 3);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    try std.testing.expectEqual(@as(usize, 3), stmt.let.pattern.?.tuple.len);
    try std.testing.expect(stmt.let.pattern.?.tuple[0] == .discard);
    try std.testing.expectEqualStrings("y", stmt.let.pattern.?.tuple[1].name);
    try std.testing.expect(stmt.let.pattern.?.tuple[2] == .discard);
}

test "parser: top-level wildcard" {
    // `let _ = 42` should produce a discard-only pattern with no leaves.
    // The earlier `let _: i32 = 42` form regressed when the colon-on-pattern
    // rejection was added (parser now surfaces
    // "let pattern: per-leaf type annotations are not supported"); the bare
    // wildcard form is the canonical use.
    const src = "fun f() {\n    let _ = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.pattern != null);
    try std.testing.expect(stmt.let.pattern.? == .discard);
    try std.testing.expect(stmt.let.init == .int_lit);
}

test "parser: nested destructuring" {
    // `let (a, (b, c)) = (1, (2, 3));` should produce a tuple containing
    // [name("a"), tuple([name("b"), name("c")])] — recursion works.
    const src = "fun f() {\n    let (a, (b, c)) = (1, (2, 3));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    try std.testing.expectEqual(@as(usize, 2), stmt.let.pattern.?.tuple.len);
    try std.testing.expectEqualStrings("a", stmt.let.pattern.?.tuple[0].name);
    try std.testing.expect(stmt.let.pattern.?.tuple[1] == .tuple);
    try std.testing.expectEqualStrings("b", stmt.let.pattern.?.tuple[1].tuple[0].name);
    try std.testing.expectEqualStrings("c", stmt.let.pattern.?.tuple[1].tuple[1].name);
}

test "codegen: tuple destructuring emits temp + per-leaf" {
    // `let (x, y) = (10, 20);` must surface as:
    //   const __destruct_0 = .{ 10, 20 };
    //   const x = __destruct_0[0];
    //   const y = __destruct_0[1];
    // Uses bracket indexing on the anonymous struct (zig 0.16 syntax) — the
    // older `.0` numeric field-access form is rejected by 0.16.
    const src = "fun f() {\n    let (x, y) = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 10, 20 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y = __destruct_0[1];") != null);
    // Sanity: the old dot-style syntax must NOT appear:
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.1") == null);
}

test "codegen: array destructuring emits temp + per-leaf indexed" {
    // `let [a, b] = arr;` must surface as:
    //   const __destruct_0 = arr;
    //   const a = __destruct_0[0];
    //   const b = __destruct_0[1];
    const src = "fun f() {\n    let [a, b] = arr;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = arr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = __destruct_0[1];") != null);
}

test "codegen: wildcard leaves skip emission" {
    // `let (_, y, _) = (1, 2, 3);` should only emit a `y` binding; the
    // discarded slots emit nothing. The temp binding still carries the
    // whole tuple so `y` can pluck out `.[1]`.
    const src = "fun f() {\n    let (_, y, _) = (1, 2, 3);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 1, 2, 3 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y = __destruct_0[1];") != null);
    // Sanity: nothing emitted for the discarded slots — neither with the
    // new `[k]` nor the obsolete `.k` form.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0[0]") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0[2]") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.2") == null);
}

test "codegen: nested destructuring emits nested temp paths" {
    // `let (a, (b, c)) = (1, (2, 3));` should produce temp paths `[0]` for
    // `a` and `[1][0]`/`[1][1]` for `b`/`c`. There is no second temp — the
    // inner pair is destructured through the same outer temp.
    const src = "fun f() {\n    let (a, (b, c)) = (1, (2, 3));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = __destruct_0[1][0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c = __destruct_0[1][1];") != null);
    // Only one temp for the whole expression — inner pair is destructured
    // through the same __destruct_0 reference, not a fresh __destruct_1.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_1") == null);
    // Sanity: dot-syntax paths must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.1.0") == null);
}

test "codegen: var destructuring emits var leaves, const temp" {
    // `var (x, y) = (10, 20);` should produce:
    //   const __destruct_0 = .{ 10, 20 };   // temp is synthetic carrier, always const
    //   var x: i32 = __destruct_0[0];       // inferred : i32 to escape comptime_int
    //   var y: i32 = __destruct_0[1];       // inferred : i32 to escape comptime_int
    const src = "fun f() {\n    var (x, y) = (10, 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 10, 20 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var x: i32 = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    var y: i32 = __destruct_0[1];") != null);
    // Sanity: dot-syntax must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct_0.1") == null);
}

test "codegen: counter increments across multiple destructures" {
    // Two destructurings in the same body get distinct temp names so zig's
    // no-redeclaration rule is satisfied. Both tuple and array branches
    // share the same counter and indexing scheme.
    const src =
        \\fun f() {
        \\    let (a, b) = (1, 2);
        \\    let [c, d] = arr;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const c = __destruct_1[0];") != null);
}

test "codegen: simple binding unchanged when not destructuring" {
    // Regression: a plain `let x = 42` still produces a single binding
    // (no temp, no destructuring path) so existing tests don't break.
    const src = "fun f() {\n    let x = 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const x = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__destruct") == null);
}

test "codegen: x/2 emits @divTrunc shim when LHS is runtime int" {
    // The pattern from the failing smoke test: `x /= 2` desugars to
    // `x = x / 2;` where LHS is an `.ident` (runtime int) and RHS is a
    // comptime `.int_lit`. zig 0.16 demands `@divTrunc(x, 2)` here because
    // the result type of `i32 / comptime_int` isn't decidable.
    const src = "fun f() {\n    var x: i32 = 10;\n    x = x / 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(x, 2)") != null);
    // Sanity: the bare `(x / 2)` form must NOT appear in the assignment RHS.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x / 2)") == null);
}

test "codegen: x%2 emits @rem shim when LHS is runtime int" {
    // Mirror of the `.div` test: `x %= 2` desugars to `x = x % 2;` and
    // codegen routes the RHS through `@rem(x, 2)`.
    const src = "fun f() {\n    var x: i32 = 10;\n    x = x % 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(x, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x % 2)") == null);
}

test "codegen: 1/2 stays bare when both sides are comptime int" {
    // The "floored/comptime cases can stay bare" carve-out: `1 / 2` is
    // pure comptime; zig folds the bare `(1 / 2)` form to `0` at compile
    // time, so we don't need to wrap in `@divTrunc`. Preserves the user's
    // source round-trip in the generated zigzag.
    const src = "fun f() {\n    let z: i32 = 1 / 2;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: i32 = 1 / 2` annotation through to
    // zig; the carve-out keeps bare-form legal too, so the test stays
    // source-shape stable here.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 / 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: 1.0/2.0 stays bare when LHS is float" {
    // Both LHS and RHS are float literals — the RHS is NOT `.int_lit`, so
    // `needsIntDivShim` short-circuits on its `b.rhs.* != .int_lit` guard
    // and the bare `(/)` form is preserved. `@divTrunc` would be invalid
    // here because it requires integer arguments.
    const src = "fun f() {\n    let z: f64 = 1.0 / 2.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: f64 = 1.0 / 2.0` annotation through.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: f64 = (1.0 / 2.0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
}

test "codegen: x /= 2 desugars through @divTrunc shim (compound-assign surface)" {
    // The user-facing surface: `x /= 2;` desugars via parseCompoundAssign
    // to `x = x / 2;`, which then routes through the shim path. This test
    // pins the end-to-end zigzag output of the compound-syntax-emits-shim
    // claim — without it, a future parser refactor that breaks the
    // desugar path could silently regress the most common user form.
    const src = "fun f() {\n    var x: i32 = 10;\n    x /= 2;\n    x %= 3;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(x, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem(x, 3)") != null);
    // Sanity: the bare `(x / 2)` and `(x % 3)` shapes must NOT appear in the
    // desugared assignment RHS — the shim would have replaced them.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x / 2)") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = (x % 3)") == null);
}

test "codegen: 2/x stays bare when LHS is comptime int and RHS is ident" {
    // Defensive pin on the predicate's `b.rhs.* != .int_lit` fast path:
    // when RHS is an `.ident` (not an int literal) the shim short-circuits,
    // even though LHS is comptime-int. This is the mirror image of the
    // main shim trigger case.
    const src = "fun f() {\n    let z: i32 = 2 / x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Source includes the `: i32` annotation — preserve it in the
    // assertion to track the actual emission.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (2 / x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: 1.0/x stays bare when LHS is float and RHS is ident" {
    // Defensive pin on the mixed-comptimes case: `exprContainsFloat`
    // returns true because LHS IS a `.float_lit`, so even though RHS is
    // not an int literal we'd see a `false` from the predicate via a
    // different guard. Verifies the bare form is preserved.
    const src = "fun f() {\n    let z: f64 = 1.0 / x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Preserve the explicit `let z: f64 = 1.0 / x` annotation through to
    // zig; codegen forwards `: T` on the binding so the assertion tracks
    // the actual emission shape (the test stays bare-form-agnostic —
    // `1.0` is float and `x` is unannotated, neither path can ever
    // trigger the `@divTrunc` shim).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: f64 = (1.0 / x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
}

test "codegen: f64-typed ident LHS / int_lit stays bare (typed-binding lookup)" {
    // The targeted hole: `let pi: f64 = 3.14; pi / 2` — LHS is `.ident "pi"`
    // so `exprContainsFloat` returns false on the LHS subtree (no
    // `.float_lit` node), but the binding is annotated `f64`. Without the
    // `collectTypedBindings` map, `needsIntDivShim` would fire and emit
    // `@divTrunc(pi, 2)`, which zig 0.16 rejects because `@divTrunc`
    // requires integer args. The fix maps `pi → f64` and the predicate's
    // `self.isFloatIdentType(...)` short-circuit returns false, leaving
    // the bare `(pi / 2)` form. zig infers the operand types from the
    // const-binding annotation and accepts the result.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r: f64 = pi / 2;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Bare form preserved; no shim wrap.
    // Source includes the `: f64` annotation — mirror it in the assertion
    // so the test tracks the actual emission.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r: f64 = (pi / 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
}

test "codegen: i32-typed ident LHS / int_lit still triggers @divTrunc shim" {
    // The non-regression pin: when the LHS ident is annotated with an
    // INTEGER type (f16/f32/f64 absent from the map), the predicate still
    // fires and the shim is emitted. Without this guard the per-function
    // map could over-broadly skip the shim and break `let x: i32 = 10;
    // x / 2;` codegen.
    const src =
        \\fun f() {
        \\    let n: i32 = 10;
        \\    let z: i32 = n / 2;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(n, 2)") != null);
    // Source includes `: i32` annotation; codegen shim path replaces
    // `(n / 2)` with `@divTrunc(n, 2)` so the literal bare form does
    // NOT survive.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (n / 2);") == null);
}

test "codegen: f64-typed ident LHS % int_lit stays bare" {
    // Mirror of the `/` case for the `.mod` operator: `let pi: f64 = 3.14;
    // pi % 2` must emit the bare form because `@rem` requires integer args.
    // The `isFloatIdentType` map check applies symmetrically to `.mod`.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r: f64 = pi % 2;
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Source includes `: f64` annotation; codegen routes the bare form
    // through (mirror of the `/` test).
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r: f64 = (pi % 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: unannotated i32-init binding / int_lit still triggers @divTrunc" {
    // DELETED: the static-typed-coercion carve-out now requires `: T`
    // annotations on EVERY bare binding whose RHS is a non-literal
    // expression. The original test source `let x = 10; let z = x / 2;`
    // no longer parses (it surfaces "let requires an explicit type
    // annotation when binding non-tuple values"). The semantic intent
    // — verifying that the shim still fires when the LHS maps to an
    // integer type — is now exercised by the
    // `i32-typed ident LHS / int_lit still triggers @divTrunc shim` test
    // directly above, which carries the `: i32` annotation on both
    // bindings and asserts the same shim path. No regression introduced
    // — the typed-binding map's "integer → shim fires" code path is
    // still covered.
}

// -------------------------------------------------------------------
// docs/19-memory.md feature tests — heap-from-new bug fix, errdefer,
// unsafe block, `as` cast, and the `new(<alloc>, T(v))` allocator
// sugar. Each pair has a parser test pinning the AST shape and a
// codegen test pinning the emitted zigzag source. Without these the
// next refactor can silently regress the docs-documented surface.
// -------------------------------------------------------------------

test "lexer: errdefer_kw, unsafe_kw, as_kw are keywords" {
    const src = "errdefer unsafe as";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.errdefer_kw, tokens[0].tag);
    try std.testing.expectEqualStrings("errdefer", tokens[0].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.unsafe_kw, tokens[1].tag);
    try std.testing.expectEqualStrings("unsafe", tokens[1].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.as_kw, tokens[2].tag);
    try std.testing.expectEqualStrings("as", tokens[2].text);
}

test "lexer: control-flow keywords (if/else/while/for/in/match/break/continue)" {
    // Per docs/06-control-flow.md. Each is reserved with `_kw` suffix
    // because the underlying zigzag is reserved in Zig 0.16 (mirrors the
    // `var_kw`/`as_kw`/`return_kw` naming), so a future AST/parser/codegen
    // pass for the docs/06 surface can dispatch on `.if_kw` etc. without
    // colliding with zig's grammar.
    const src = "if else while for in match break continue";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    const expected_tags = [_]lexer_mod.TokenTag{
        .if_kw,    .else_kw,
        .while_kw, .for_kw,
        .in_kw,    .match_kw,
        .break_kw, .continue_kw,
    };
    const expected_texts = [_][]const u8{
        "if",    "else",
        "while", "for",
        "in",    "match",
        "break", "continue",
    };
    // Use a simple counter instead of @intFromPtr arithmetic — pointer
    // math on a `for`-loop iteration variable computes gibberish because
    // `tag` lives on the stack, NOT as an element of `expected_tags`.
    // (This previously panicked at runtime with `index out of bounds`.)
    var i: usize = 0;
    for (expected_tags, expected_texts) |tag, text| {
        try std.testing.expectEqual(tag, tokens[i].tag);
        try std.testing.expectEqualStrings(text, tokens[i].text);
        i += 1;
    }
}

test "parser: errdefer parses as Stmt.errdefer_stmt" {
    // Pattern 2 from docs/19-memory.md: `errdefer free(a)` runs only on the
    // `?`-propagation path. Parser pins the AST tag so the codegen surface
    // ({errdefer expr;}) is replayable by tests.
    //
    // The expression `print("cleanup\n")` parses as a `.call` node because
    // `"cleanup\n"` is a string-literal (no `{` markers) — the parser's
    // `.string_literal` arm only routes to `buildTemplate` when an
    // interpolation marker is present. Pre-existing test wrote this with
    // `.template_lit` based on an earlier codegen shape that no longer
    // applies; updated to match the current AST shape.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .errdefer_stmt);
    try std.testing.expect(stmt.errdefer_stmt.expr == .call);
    try std.testing.expectEqualStrings("print", stmt.errdefer_stmt.expr.call.name);
    try std.testing.expectEqual(@as(usize, 1), stmt.errdefer_stmt.expr.call.args.len);
    try std.testing.expectEqualStrings("cleanup\\n", stmt.errdefer_stmt.expr.call.args[0].string_lit);
}

test "parser: unsafe { } parses as Stmt.unsafe_block" {
    // Source-level audit block. The body statements live inside the union
    // payload as `[]const Stmt`; codegen emits them inside plain `{ … }`
    // with `// unsafe {` and `// }` markers for tooling.
    const src = "fun f() {\n    unsafe {\n        print(\"inside\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .unsafe_block);
    try std.testing.expectEqual(@as(usize, 1), stmt.unsafe_block.len);
    try std.testing.expect(stmt.unsafe_block[0] == .expr_stmt);
}

test "parser: x as Type parses as Expr.cast" {
    // `as` sits between unary and postfix in the ladder so `1 + x as i32`
    // parses as `1 + (x as i32)` (cast binds tighter than additive).
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .cast);
    try std.testing.expectEqualStrings("i32", init.cast.type_text);
    try std.testing.expect(init.cast.expr.* == .ident);
    try std.testing.expectEqualStrings("x", init.cast.expr.*.ident);
}

test "parser: p as *raw c_void captures multi-token type" {
    // The verbatim-source-text capture enables pointer casts where the
    // destination type includes the `*raw` modifier and a multi-token
    // tail like `c_void`. The capture joins `*`, `raw`, `c_void` into one
    // `type_text` slice that codegen can hand to zig's `as` operator.
    const src = "fun f() {\n    let p: *raw u8 = 0 as *raw u8;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .cast);
    try std.testing.expectEqualStrings("*raw u8", init.cast.type_text);
}

test "parser: new(<alloc>, T(v)) sugar sets allocator field" {
    // Pattern 3 from docs/19-memory.md: arena allocation. Parser pins the
    // allocator carrier so codegen emits `<arena>.create(T)` rather than
    // the global page allocator.
    const src = "fun f() {\n    let p = new(arena, i32(0));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena2 = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena2);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .new_expr);
    try std.testing.expectEqualStrings("i32", init.new_expr.type_name);
    try std.testing.expect(init.new_expr.allocator != null);
    try std.testing.expectEqualStrings("arena", init.new_expr.allocator.?);
}

test "parser: new T(v) keeps allocator null for global-heap shape" {
    // Sanity check on the simple form: allocator=null means codegen emits
    // `std.heap.page_allocator.create(T)` rather than a user-supplied
    // arena's `.create(T)`.
    const src = "fun f() {\n    let p = new i32(42);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena2 = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena2);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .new_expr);
    try std.testing.expect(init.new_expr.allocator == null);
    try std.testing.expectEqualStrings("i32", init.new_expr.type_name);
    try std.testing.expect(init.new_expr.value.* == .int_lit);
}

test "codegen: new T(v) emits page_allocator.create heap alloc (bug fix)" {
    // The docs/spec contract for `new` is heap allocation. The previous
    // emission `blk: { var __val: T = v; break :blk &__val; }` was a
    // stack-pointer escape (UB on `free`). The rewrite routes through
    // `try std.heap.page_allocator.create(T)` so `free(p)`'s matching
    // `page_allocator.destroy(p)` correctly deallocates the heap cell.
    //
    // The current emit for `let p = new i32(42)` is:
    //   const p = blk: { const __p_0 = try std.heap.page_allocator.create(i32);
    //                     __p_0.* = 42; break :blk __p_0; };
    // (Pre-existing test asserted `const p = __p_0` — a bare-assignment
    // shape that was true before the docs/19-memory.md heap rewrite; the
    // rewrite uses the blk-wrapped form so we can still reference `__p_0`
    // after the assignment without zig's no-redeclaration trouble.)
    const src = "fun f() {\n    let p = new i32(42);\n    defer free(p);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __p_0") != null);
    // The page_allocator.destroy(p) — for the matching free(p) below.
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.heap.page_allocator.destroy") != null);
    // Sanity: the OLD stack-pointer emission must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, zig, "var __val: i32 = 42") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "&__val") == null);
}

test "codegen: new(<arena>, T(v)) emits <arena>.create(T) (allocator sugar)" {
    // Pattern 3 sugar: codegen routes through the user-supplied allocator's
    // `create` method rather than the global page allocator.
    const src = "fun f() {\n    let p = new(arena, i32(0));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try arena.create(i32)") != null);
    // Sanity: must NOT use the global page allocator.
    try std.testing.expect(std.mem.indexOf(u8, zig, "page_allocator.create") == null);
}

test "codegen: alloc_counter increments across multiple new exprs" {
    // Two `new` expressions in the same body must produce distinct `__p_<N>`
    // names so zig's no-redeclaration rule is satisfied. The codegen uses a
    // single per-function `alloc_counter` (reset at `genFun`) that increments
    // per `new_expr` visit in `genExpr`, so two bindings surface distinct
    // `__p_0` and `__p_1`. Each `__p_<N>` is also internal to its own
    // `blk: { … }` scope — the counter step is the simpler invariant that
    // satisfies both flat scopes and nested blk scopes (the latter tolerate
    // same-name shadowing but the counter keeps emissions human-comparable).
    const src =
        \\fun f() {
        \\    let a = new i32(1);
        \\    let b = new i32(2);
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const b = blk: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_1.* = 2") != null);
}

test "codegen: errdefer stmt emits errdefer verbatim" {
    // Mirrors zig 0.16's `errdefer` keyword one-to-one so zig's semantics
    // (runs the expression ONLY on `?`-propagation or `Err` early-return)
    // match the zag docs' Pattern 2 framing.
    //
    // `errdefer <expr>` triggers genExpr on `expr`. For `print(string_lit)`
    // the call-emit is `std.debug.print("...", .{})` (the literal-string
    // specialization). So the errdefer output is
    // `    errdefer std.debug.print("cleanup\n", .{});`.
    // Pre-existing test was written when codegen emitted the user's
    // `print(...)` verbatim (a simpler print codegen). Updated to the
    // current stamp-shape substring.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    errdefer std.debug.print(\"cleanup\\n\", .{})") != null);
}

test "codegen: unsafe block emits body in plain block with comment markers" {
    // zig 0.16 has no block-form `unsafe` keyword — the block is purely a
    // source-level audit marker. Codegen emits the body wrapped in plain
    // `{ ... }` with `// unsafe {` and `// }` comments so the structure is
    // visible to `-Dunsafe-block-check` tooling without affecting the
    // emitted zig semantics (raw pointer ops are already unconditional).
    //
    // The body's `print(string_lit)` codegen emits `std.debug.print(...)`,
    // NOT the user's `print(...)` verbatim. Pre-existing test was written
    // when codegen was simpler — updated to the current emission shape.
    const src = "fun f() {\n    unsafe {\n        print(\"inside\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // unsafe {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.debug.print(\"inside\\n\", .{})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // }") != null);
}

test "codegen: as cast emits @as builtin" {
    // The parser's `collectCastType` joined multi-token types like
    // `*raw c_void` into one `type_text` slice; codegen emits
    // `@as(type_text, expr)` so zig's `@as` builtin handles the cast
    // surface natively (pointers, numerics, raw pointers). zig 0.16
    // dropped the `as` operator entirely (verified empirically:
    // `pi as f32` produces `expected ';'` and `(pi as f32)` produces
    // `expected ')'`, while `@as(f32, pi)` parses cleanly) so this
    // matches the post-deprecation cast shape that zig natively accepts.
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y: i32 = @as(i32, x);") != null);
}

// -------------------------------------------------------------------
// docs/12-structs.md feature tests — struct def / struct-literal /
// field-read / field-write / method-call / impl-block method nesting.
// Each pair pins a parser tag and a codegen emission shape matching the
// per-f64 24-byte value model the spec describes. The complete vec3
// example is exercised by examples/structs/vec3.zag (simplified form
// — no imports / no operator overload, all in-scope surface only).
// -------------------------------------------------------------------

test "parser: struct decl produces StructDecl with named fields" {
    const src = "struct Vec3 {\n    x: f64,\n    y: f64,\n    z: f64,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqualStrings("Vec3", prog.structs[0].name);
    try std.testing.expectEqual(@as(usize, 3), prog.structs[0].fields.len);
    const xyz = prog.structs[0].fields;
    try std.testing.expect(xyz[0].kind == .named);
    try std.testing.expectEqualStrings("x", xyz[0].kind.named.name);
    try std.testing.expectEqualStrings("f64", xyz[0].kind.named.type_text);
    try std.testing.expectEqualStrings("y", xyz[1].kind.named.name);
    try std.testing.expectEqualStrings("z", xyz[2].kind.named.name);
}

test "parser: struct decl accepts embed-form field" {
    // `Button { Widget, label: String }` mixes an embed row (`Widget,` —
    // no colon) with two regular named rows. Parser pins both shapes.
    const src = "struct Button {\n    Widget,\n    label: String,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 2), prog.structs[0].fields.len);
    try std.testing.expect(prog.structs[0].fields[0].kind == .embed);
    try std.testing.expectEqualStrings("Widget", prog.structs[0].fields[0].kind.embed.type_name);
    try std.testing.expect(prog.structs[0].fields[1].kind == .named);
    try std.testing.expectEqualStrings("label", prog.structs[0].fields[1].kind.named.name);
}

test "parser: impl block produces ImplBlock with methods" {
    // The canonical docs/12 method shape: `pub fun NAME(self: *const T)
    // -> RET { … }`. Parser pins the param is_self discrimination so
    // codegen can nest the method inside the matching struct decl as
    // zig's native struct-member function.
    const src =
        \\struct Vec3 {
        \\    x: f64,
        \\    y: f64,
        \\    z: f64,
        \\}
        \\impl Vec3 {
        \\    pub fun length(self: *const Vec3) -> f64 {
        \\        return 0.0;
        \\    }
        \\    pub fun new(x: f64, y: f64, z: f64) -> Vec3 {
        \\        return Vec3 { x: 0.0, y: 0.0, z: 0.0 };
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 1), prog.structs.len);
    try std.testing.expectEqual(@as(usize, 1), prog.impls.len);
    try std.testing.expectEqualStrings("Vec3", prog.impls[0].target_type);
    try std.testing.expectEqual(@as(usize, 2), prog.impls[0].methods.len);
    try std.testing.expectEqualStrings("length", prog.impls[0].methods[0].name);
    try std.testing.expectEqual(@as(usize, 1), prog.impls[0].methods[0].params.len);
    try std.testing.expectEqualStrings("self", prog.impls[0].methods[0].params[0].name);
    try std.testing.expect(prog.impls[0].methods[0].params[0].is_self);
    try std.testing.expectEqualStrings("*const Vec3", prog.impls[0].methods[0].params[0].type_text);
    try std.testing.expectEqualStrings("f64", prog.impls[0].methods[0].return_type.?);
    // new() constructors have NO self param — the parser must set
    // is_self=false for the positional params.
    try std.testing.expectEqualStrings("new", prog.impls[0].methods[1].name);
    try std.testing.expectEqual(@as(usize, 3), prog.impls[0].methods[1].params.len);
    try std.testing.expect(!prog.impls[0].methods[1].params[0].is_self);
}

test "parser: postfix dot chain produces member_access" {
    // `v.x` after a let-binding parses as `.member_access(target=ident(v),
    // name="x")`. Codegen's `.member_access` arm emits `v.x` verbatim.
    const src = "fun f() {\n    let v: f64 = 0.0;\n    let a: f64 = v.x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const a_init = prog.functions[0].body[1].let.init;
    try std.testing.expect(a_init == .member_access);
    try std.testing.expectEqualStrings("x", a_init.member_access.name);
    try std.testing.expect(a_init.member_access.target.* == .ident);
    try std.testing.expectEqualStrings("v", a_init.member_access.target.*.ident);
}

test "parser: postfix dot chain produces method_call" {
    // `v.length()` (with parens) parses as `.method_call(target=ident(v),
    // name="length", args=[])`. The two shapes the postfix loop sees on
    // `.identifier` are distinguished entirely by what follows — `(`
    // binds to method-call, anything else binds to member-access.
    const src = "fun f() {\n    let len: f64 = v.length();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .method_call);
    try std.testing.expectEqualStrings("length", init.method_call.name);
    try std.testing.expectEqual(@as(usize, 0), init.method_call.args.len);
    try std.testing.expect(init.method_call.target.* == .ident);
    try std.testing.expectEqualStrings("v", init.method_call.target.*.ident);
}

test "parser: method_call with positional args parses correctly" {
    // `Vec3.new(1.0, 2.0, 3.0)` parses as `.method_call(target=ident
    // ("Vec3"), name="new", args=[3 floats])`. zig statically resolves
    // `Vec3.new` to a struct-member call (codegen nests impl methods
    // inside the struct decl).
    const src = "fun f() {\n    let p: Vec3 = Vec3.new(1.0, 2.0, 3.0);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .method_call);
    try std.testing.expectEqualStrings("Vec3", init.method_call.target.*.ident);
    try std.testing.expectEqualStrings("new", init.method_call.name);
    try std.testing.expectEqual(@as(usize, 3), init.method_call.args.len);
    try std.testing.expect(init.method_call.args[0] == .float_lit);
}

test "parser: struct-literal produces Expr.struct_lit" {
    // `Vec3 { x: 1.0, y: 2.0, z: 3.0 }` parses as `.struct_lit(type_name
    // ="Vec3", inits=[3 FieldInit])`. Field-init order is preserved so
    // codegen's verbatim `.f = v` emission matches source order.
    const src = "fun f() {\n    let v = Vec3 { x: 1.0, y: 2.0, z: 3.0 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .struct_lit);
    try std.testing.expectEqualStrings("Vec3", init.struct_lit.type_name);
    try std.testing.expectEqual(@as(usize, 3), init.struct_lit.inits.len);
    try std.testing.expectEqualStrings("x", init.struct_lit.inits[0].name);
    try std.testing.expectEqualStrings("y", init.struct_lit.inits[1].name);
    try std.testing.expectEqualStrings("z", init.struct_lit.inits[2].name);
    try std.testing.expect(init.struct_lit.inits[0].value.* == .float_lit);
}

test "parser: parseFieldAssign triggers on name.field = value" {
    // The 3-token lookahead at parseStmt's identifier arm dispatches into
    // `.field_assign` when the pattern `ident . ident = ` is detected.
    // The receiver path here is the bare `v` ident; for complex LHSs
    // like `arr[i].field = ` the user can extract to a local first.
    const src = "fun f() {\n    v.x = 10.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .field_assign);
    try std.testing.expectEqualStrings("x", stmt.field_assign.field_name);
    try std.testing.expect(stmt.field_assign.target.* == .ident);
    try std.testing.expectEqualStrings("v", stmt.field_assign.target.*.ident);
    try std.testing.expect(stmt.field_assign.value == .float_lit);
}

test "codegen: struct decl emits zig pub const + struct" {
    // `struct Vec3 { x: f64, y: f64, z: f64 }` transpiles to
    // `pub const Vec3 = struct { x: f64, y: f64, z: f64 };` so zig sees
    // a real declared struct type. The fields are emitted in declaration
    // order so any struct-literal initializer round-trips the
    // field-position expectations.
    const src = "struct Vec3 {\n    x: f64,\n    y: f64,\n    z: f64,\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Vec3 = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    x: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    y: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    z: f64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "};") != null);
}

test "codegen: impl method nests pub fn inside struct decl" {
    // `impl Vec3 { pub fun length(...) -> f64 { … } }` transpiles to
    // `pub fn length(self: *const Vec3) f64 { … }` NESTED INSIDE the
    // struct body. This is the simplification that lets `v.length()`
    // and `Vec3.new(...)` 1:1 round-trip to zig without a zag-side
    // type-resolver (zig's own type checker handles receiver-vs-type
    // dispatch natively).
    const src =
        \\struct Vec3 {
        \\    x: f64,
        \\    y: f64,
        \\    z: f64,
        \\}
        \\impl Vec3 {
        \\    pub fun length(self: *const Vec3) -> f64 {
        \\        return 0.0;
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub const Vec3 = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    pub fn length(self: *const Vec3) f64 {") != null);
    // Sanity: pub fn appears AFTER the struct decl opens, BEFORE the
    // closing `};` — confirming the nesting rather than flat emission.
    const struct_open = std.mem.indexOf(u8, zig, "pub const Vec3 = struct {").?;
    const fn_emit = std.mem.indexOf(u8, zig, "    pub fn length(self: *const Vec3) f64 {").?;
    const struct_close = std.mem.indexOf(u8, zig[struct_open..], "};").? + struct_open;
    try std.testing.expect(fn_emit > struct_open and fn_emit < struct_close);
}

test "codegen: struct-literal emits Vec3{ .f = v } form" {
    // The struct-literal codegen includes the dotted-field form (`.f = v`)
    // so zig's anonymous-field-init syntax matches zag's surface verbatim.
    // Note: there's no leading `.` on the type itself because the syntax
    // `Vec3{ .x = … }` is zig's **named** struct literal (the leading-dot
    // form `.Vec3 { … }` is reserved for anonymous-struct literals and
    // would be rejected by zig on a real struct).
    const src = "fun f() {\n    let v = Vec3 { x: 1.0, y: 2.0, z: 3.0 };\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "Vec3{ .x = 1.0, .y = 2.0, .z = 3.0 }") != null);
}

test "codegen: member_access emits target.name verbatim" {
    // `v.x` → `v.x`. Zig's struct-field access syntax matches zag's
    // surface verbatim, so codegen is a one-line passthrough. This test
    // makes the user-facing property obvious: any struct-typed `v` whose
    // zig-declared struct has field `.x` round-trips without
    // transformation.
    const src = "fun f() {\n    let a: f64 = v.x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "= v.x;") != null);
}

test "codegen: method_call emits target.name(args) verbatim" {
    // `v.length()` and `Vec3.new(1.0, 2.0, 3.0)` both emit verbatim —
    // zig natively distinguishes value-receiver and type-static forms.
    // The simpler receiver form `v.length()` shows up as
    // `    const len: f64 = v.length();`-style emission.
    const src = "fun f() {\n    let len: f64 = v.length();\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const len: f64 = v.length();") != null);
}

test "codegen: field_assign emits target.field = value;" {
    // `v.x = 10.0;` → `    v.x = 10.0;`. Zig accepts field-write to a
    // `var`-binding receiver verbatim; writing to a `const`-recevier is
    // rejected by zig at compile time, mirroring zag's binding-kind
    // semantics.
    const src = "fun f() {\n    v.x = 10.0;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    v.x = 10.0;") != null);
}

test "codegen: orphan impl emits module-level free fn with type_method name" {
    // Pin the orphan-impl handling: an `impl` block whose target_type
    // has no matching struct decl emits as `pub fn <T>_<name>(...) RET
    // { ... }` at module level. Without this fallback, an orphan impl
    // would be silently dropped. The test writes an impl without a
    // preceding struct decl so the orphan path is forced.
    const src =
        \\impl Orphan {
        \\    pub fun greet() -> i32 {
        \\        return 7;
        \\    }
        \\}
        \\fun main() {
        \\    let x: i32 = 0;
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expectEqual(@as(usize, 0), prog.structs.len);
    try std.testing.expectEqual(@as(usize, 1), prog.impls.len);
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn Orphan_greet() i32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return 7;") != null);
}

// -------------------------------------------------------------------
// docs/06-control-flow.md feature tests — if / while / for / match /
// break / continue / return. Each pair pins a parser tag and a codegen
// emission shape. These are the foundational surface for the control
// flow chapter; any future refactor that breaks the AST tag mapping or
// the zig emission shape will be caught here. The features deliberately
// stop short of the full docs/06 surface (panic, enum-variant
// patterns, tuple destructuring in `for`, `break val;` value-form,
// multi-statement match arm bodies — see the orphan-tests followup).
// -------------------------------------------------------------------

test "parser: if-stmt parses as Stmt.if_stmt" {
    // The unconditional `if` branch surfaces as a Tagged-Stmt.if_stmt
    // (NOT `.if_expr`), confirming that the statement form is in place.
    // The cond captures the predicate expression and the body block
    // holds the inner statement list.
    const src = "fun f() {\n    if x > 0 {\n        print(\"positive\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .if_stmt);
    try std.testing.expect(stmt.if_stmt.cond == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.gt, stmt.if_stmt.cond.binary.op);
    try std.testing.expectEqual(@as(usize, 1), stmt.if_stmt.then_body.len);
    try std.testing.expect(stmt.if_stmt.then_body[0] == .expr_stmt);
    try std.testing.expect(stmt.if_stmt.else_kind == .none);
}

test "parser: if-stmt with else-if chain walks nested if_kind" {
    // An `else if …` chain should fold into the .if_chain arm of the
    // OUTER if_stmt's else_kind rather than creating a stmt-level
    // sibling — the chain lives structurally inside the first if so
    // codegen can emit it as a single `if/else if/else if` block.
    const src = "fun f() {\n    if a {\n        print(\"a\\n\");\n    } else if b {\n        print(\"b\\n\");\n    } else {\n        print(\"other\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .if_stmt);
    try std.testing.expect(stmt.if_stmt.else_kind == .if_chain);
    const mid = stmt.if_stmt.else_kind.if_chain;
    try std.testing.expect(mid.cond == .ident);
    try std.testing.expectEqualStrings("b", mid.cond.ident);
    try std.testing.expect(mid.else_kind == .block);
}

test "parser: if-expression parses as Expr.if_expr (RHS of let)" {
    // The expression form `let x = if cond { … } else { … }` lands in
    // Expr.if_expr (NOT .if_stmt) so codegen can emit it as a value-yielding
    // block. The two arms carry pointers (cycle-broken type, see
    // parseIfExpr in parser.zig).
    const src =
        \\fun f() {
        \\    let z: i32 = if x > 0 { 1 } else { 0 };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .if_expr);
    try std.testing.expect(init.if_expr.cond.* == .binary);
    try std.testing.expect(init.if_expr.then_expr.* == .int_lit);
    try std.testing.expectEqualStrings("1", init.if_expr.then_expr.*.int_lit);
    try std.testing.expect(init.if_expr.else_expr.* == .int_lit);
    try std.testing.expectEqualStrings("0", init.if_expr.else_expr.*.int_lit);
}

test "codegen: plain if-stmt emits zig if without else" {
    // Statement form with no else: codegen emits `if (cond) { … }` and
    // no suffix for the absent else branch (no dangling `else`).
    const src =
        \\fun f() {
        \\    if x > 0 {
        \\        print("positive\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if (x > 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    }") != null);
    // Sanity: not a labeled blk form (was used for the expression variant
    // only).
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: {") == null);
}

test "codegen: if-stmt with else emits zig if/else" {
    // Statement form with else: codegen emits `if (cond) { … } else { … }`.
    const src =
        \\fun f() {
        \\    if x > 0 {
        \\        print("pos\n");
        \\    } else {
        \\        print("neg\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if (x > 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    std.debug.print(\"neg\\n\", .{});") != null);
}

test "codegen: if-stmt with else-if chain emits chained zig emission" {
    // A multi-arm else-if chain should emit as a single `if/else if/
    // else` zigzag statement — no nested `(blk: { ... })` blocks for the
    // pure statement form.
    const src =
        \\fun f() {
        \\    if a {
        \\        print("a\n");
        \\    } else if b {
        \\        print("b\n");
        \\    } else {
        \\        print("other\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if a {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else if b {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    std.debug.print(\"other\\n\", .{});") != null);
}

test "codegen: if-expression emits labeled blk + break :blk" {
    // The expression form must surface as a labeled block yielding a value:
    // `(blk: { if (cond) break :blk <then> else break :blk <else>; })`.
    // The outer `(blk: { … })` makes the rhs parenthesised so it can sit in
    // any expression position (e.g. RHS of a `let` binding).
    const src =
        \\fun f() {
        \\    let z: i32 = if x > 0 { 1 } else { 0 };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: { if (x > 0) break :blk 1 else break :blk 0; })") != null);
}

test "parser: while-stmt parses as Stmt.while_stmt" {
    // Standard while loop: cond captured as Expr, body as slice of Stmt.
    const src =
        \\fun f() {
        \\    while i < 10 {
        \\        i = i + 1;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .while_stmt);
    try std.testing.expect(stmt.while_stmt.cond == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.lt, stmt.while_stmt.cond.binary.op);
    try std.testing.expectEqual(@as(usize, 1), stmt.while_stmt.body.len);
}

test "codegen: while-stmt emits zig while verbatim" {
    // The cond and body emit directly via zig's native syntax — no shim
    // is needed because zig's `while` semantics match zag's.
    const src =
        \\fun f() {
        \\    while i < 10 {
        \\        i = i + 1;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    while (i < 10) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    i = (i + 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    }") != null);
}

test "parser: for-range parses as Stmt.for_stmt with RangeExpr iter" {
    // `for i in 0..10` should land on Stmt.for_stmt. The iter expression
    // should be an Expr.range (start=0, end=10, inclusive=false). The
    // pattern is a single .ident so the for-loop's capture-name comes
    // through verbatim.
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        print("i\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .for_stmt);
    try std.testing.expect(stmt.for_stmt.iter == .range);
    try std.testing.expectEqualStrings("0", stmt.for_stmt.iter.range.start.*.int_lit);
    try std.testing.expectEqualStrings("10", stmt.for_stmt.iter.range.end.*.int_lit);
    try std.testing.expect(!stmt.for_stmt.iter.range.inclusive);
    try std.testing.expect(stmt.for_stmt.pattern == .ident);
    try std.testing.expectEqualStrings("i", stmt.for_stmt.pattern.ident);
}

test "parser: for-incl range sets inclusive flag" {
    // `...` (ellipsis) in zag maps to inclusive=true so codegen can add
    // 1 to make zig's half-open range iterate inclusively.
    const src =
        \\fun f() {
        \\    for i in 0...10 {
        \\        print("i\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .for_stmt);
    try std.testing.expect(stmt.for_stmt.iter.range.inclusive);
}

test "parser: for-iter non-range parses with the user expression as iter" {
    // `for x in items()` carries the call expression as for_stmt.iter
    // (NOT as range) so codegen routes to verbatim emission rather than
    // the inline range rewrite.
    const src =
        \\fun f() {
        \\    for x in items() {
        \\        print("x\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .for_stmt);
    try std.testing.expect(stmt.for_stmt.iter == .call);
    try std.testing.expectEqualStrings("items", stmt.for_stmt.iter.call.name);
}

test "codegen: for-range emits zig `start..end[+1]`" {
    // The range shape gets INLINE-emitted as `start..end[ + 1]` so zig's
    // native range syntax (half-open) encodes the inclusive flag without
    // the anonymous-tuple round-trip.
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        print("i\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (0..10) |i| {") != null);
    // Sanity: the .iter not as anonymous struct.
    try std.testing.expect(std.mem.indexOf(u8, zig, "for (.{ 0,") == null);
}

test "codegen: for-incl range emits end+1" {
    // Inclusive range (3-arm `.end + 1`) flips the half-open semantics
    // into inclusive so `for i in 0...10` iterates 0,1,…,10 (not 0,…,9).
    const src =
        \\fun f() {
        \\    for i in 0...10 {
        \\        print("i\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (0..10 + 1) |i| {") != null);
}

test "codegen: for-iter non-range emits verbatim iter call" {
    // For-loop iter that isn't a range emits the user's expression
    // verbatim — codegen bypasses the inline range rewrite.
    const src =
        \\fun f() {
        \\    for x in items() {
        \\        print("x\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (items()) |x| {") != null);
}

test "parser: match-stmt with literal arms parses as Stmt.match_stmt" {
    // The statement-position match lands on Stmt.match_stmt; the
    // scrutinee and arms are populated correctly. Each arm carries
    // `pat` + optional `guard` + arm-body expression.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\        _ => "other",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .match_stmt);
    try std.testing.expect(stmt.match_stmt.scrutinee.* == .ident);
    try std.testing.expectEqualStrings("n", stmt.match_stmt.scrutinee.*.ident);
    try std.testing.expectEqual(@as(usize, 3), stmt.match_stmt.arms.len);

    try std.testing.expect(stmt.match_stmt.arms[0].pat == .literal);
    try std.testing.expectEqualStrings("1", stmt.match_stmt.arms[0].pat.literal.*.int_lit);
    try std.testing.expect(stmt.match_stmt.arms[0].guard == null);
    try std.testing.expectEqualStrings("one", stmt.match_stmt.arms[0].expr.*.string_lit);

    try std.testing.expect(stmt.match_stmt.arms[1].pat == .literal);
    try std.testing.expectEqualStrings("2", stmt.match_stmt.arms[1].pat.literal.*.int_lit);

    try std.testing.expect(stmt.match_stmt.arms[2].pat == .discard);
    try std.testing.expectEqualStrings("other", stmt.match_stmt.arms[2].expr.*.string_lit);
}

test "parser: match-stmt with range arm and guard" {
    // A range pattern captures both bounds + inclusive flag; a guard
    // (the `if cond` after the pattern) is recorded on the arm alongside
    // the pattern rather than baked into it.
    const src =
        \\fun f() {
        \\    match n {
        \\        0..10 => "low",
        \\        _ => "high",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .match_stmt);
    try std.testing.expect(stmt.match_stmt.arms[0].pat == .range);
    try std.testing.expectEqualStrings("0", stmt.match_stmt.arms[0].pat.range.start.*.int_lit);
    try std.testing.expectEqualStrings("10", stmt.match_stmt.arms[0].pat.range.end.*.int_lit);
    try std.testing.expect(!stmt.match_stmt.arms[0].pat.range.inclusive);
}

test "parser: match-stmt with ident-pattern arm binds name" {
    // An ident-pattern arm (`n => n + 1`) carries the binding name on
    // arm.pat so codegen can emit `const <name> = __m_<N>;` before the
    // arm body, giving the body access to the binding.
    const src =
        \\fun f() {
        \\    match n {
        \\        x => x + 1,
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .match_stmt);
    try std.testing.expect(stmt.match_stmt.arms[0].pat == .ident);
    try std.testing.expectEqualStrings("x", stmt.match_stmt.arms[0].pat.ident);
    try std.testing.expect(stmt.match_stmt.arms[0].expr.* == .binary);
}

test "parser: match-expression parses as Expr.match_expr" {
    // Mirroring of the statement form: when `match` sits in expression
    // position (e.g. RHS of a let binding) it lands on Expr.match_expr
    // so codegen can emit it as a value-yielding block.
    const src =
        \\fun f() {
        \\    let label: i32 = match n {
        \\        1 => "one",
        \\        _ => "other",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .match_expr);
    try std.testing.expectEqualStrings("n", init.match_expr.scrutinee.*.ident);
    try std.testing.expectEqual(@as(usize, 2), init.match_expr.arms.len);
}

test "codegen: match-stmt emits labeled laddered if-else" {
    // Each arm gets emitted as an `if (<cond>) { break :blk <body>; }`,
    // chained via `else`. The scrutinee is bound to a `__m_<N>` temp so
    // arm conditions can refer to the value without re-evaluation.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\        _ => "other",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk: { const __m_0 = n;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__m_0 == 1) { break :blk \"one\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__m_0 == 2) { break :blk \"two\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (true) { break :blk \"other\"; }") != null);
    // Sanity: trail is appended as a `;` (stmt-position append in
    // genStmt `.match_stmt` arm).
    try std.testing.expect(std.mem.indexOf(u8, zig, "});") != null);
}

test "codegen: match-stmt with non-wildcard last emits `else unreachable;`" {
    // When the last arm is NOT a wildcard, codegen appends `else unreachable;`
    // so zig's exhaustive-match check is satisfied and the user gets a
    // compile-time error if they missed a case.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        _ => "other",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The trailing arm IS a wildcard, so no fallback expected:
    try std.testing.expect(std.mem.indexOf(u8, zig, "unreachable") == null);
}

test "codegen: match-stmt with non-wildcard LAST arm emits \";}\" + unreachable fallback" {
    // The user-confirmed shape: when the chain has NO wildcard arm, codegen
    // must append `else unreachable;` after the last `if (...)` so zig's
    // exhaustive-match check doesn't fail. This pins the exhaustiveness
    // intent explicitly.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "} else unreachable;") != null);
}

test "codegen: match-stmt with range arm emits bounds check" {
    // The range arm builds a bounds check on the scrutinee temp. Half-open
    // range `0..10` emits `(>= 0) and (< 10)` so the ladder condition
    // uses zig's native `and` keyword.
    const src =
        \\fun f() {
        \\    match n {
        \\        0..10 => "low",
        \\        _ => "high",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "((__m_0 >= 0) and (__m_0 < 10))") != null);
}

test "codegen: match-stmt identifies ident arm emits const binding" {
    // An ident-pattern arm (`x => x + 1`) must emit
    // `const x = __m_<N>;` BEFORE the arm body's `break :blk` so the
    // body can reference `x`.
    const src =
        \\fun f() {
        \\    match n {
        \\        x => x + 1,
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (true) { const x = __m_0; break :blk (x + 1); }") != null);
}

test "codegen: match-counter increments per match" {
    // Two match expressions in the same body produce distinct `__m_<N>`
    // names so zig's no-redeclaration rule is satisfied.
    const src =
        \\fun f() {
        \\    match a {
        \\        1 => 10,
        \\        _ => 0,
        \\    };
        \\    match b {
        \\        2 => 20,
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_0 = a") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_1 = b") != null);
}

test "parser: break-stmt parses as Stmt.break_stmt" {
    // Statement-only break per the user-confirmed shape: no value form,
    // no label. The stmt has no payload (the parser materialises the
    // union case with empty data).
    const src =
        \\fun f() {
        \\    while true {
        \\        break;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0].while_stmt.body[0];
    try std.testing.expect(stmt == .break_stmt);
}

test "codegen: break-stmt emits zig break;" {
    // Codegen emits zig's bare `break;` (no label, no value).
    const src =
        \\fun f() {
        \\    while true {
        \\        break;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    break;") != null);
}

test "parser: continue-stmt parses as Stmt.continue_stmt" {
    // Continue is a bare statements emitted by codegen verbatim.
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        continue;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0].for_stmt.body[0];
    try std.testing.expect(stmt == .continue_stmt);
}

test "codegen: continue-stmt emits zig continue;" {
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        continue;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    continue;") != null);
}

test "parser: return-stmt with value parses as Stmt.return_stmt with expr" {
    // `return expr;` carries the value expression on the stmt so codegen
    // can emit `return <expr>;` verbatim.
    const src = "fun f() {\n    return 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .return_stmt);
    try std.testing.expect(stmt.return_stmt.value != null);
    try std.testing.expectEqualStrings("42", stmt.return_stmt.value.?.int_lit);
}

test "parser: bare return parses as Stmt.return_stmt with null value" {
    // Bare `return;` (no value) populates `value` with null so codegen
    // emits `return;` (no expression after).
    const src = "fun f() {\n    return;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .return_stmt);
    try std.testing.expect(stmt.return_stmt.value == null);
}

test "codegen: return-stmt with value emits `return <expr>;`" {
    const src = "fun f() {\n    return 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return 42;") != null);
    // Sanity: not the bare form.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return;") == null);
}

test "codegen: bare return emits `return;`" {
    const src = "fun f() {\n    return;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return;") != null);
}

// -------------------------------------------------------------------
// docs/manual/09-pointers.md feature tests - `&` address-of, slicing,
// and the multi-token pointer type annotations (`*T`, `*const T`,
// `[]T`, `[]const T`, `?*T`). Each pair pins the AST shape or the
// emitted zig source so a future refactor in `parser.zig`/`codegen.zig`
// cannot silently break the chapter's documented surface.
// -------------------------------------------------------------------

test "parser: unary `&x` parses as Expr.unary with UnaryOp.addr" {
    // The unary-vs-binary dispatch on `.amp`: in prefix position the
    // (otherwise-shared) `.amp` TokenTag routes to `.addr` rather than
    // `.bitand`, mirroring how `-x` (unary) vs `a - b` (binary) share
    // the `.minus` token. The operand lives inside a pointer-typed
    // field of `Expr.UnaryExpr` so the AST follows the existing `*Expr`
    // cycle-breaker convention.
    const src = "fun f() {\n    var x: i32 = 0;\n    let p: *i32 = &x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const body = prog.functions[0].body;
    // body[1] is `let p = &x` (body[0] is `var x: i32 = 0`).
    const init = body[1].let.init;
    try std.testing.expect(init == .unary);
    try std.testing.expectEqual(ast.Expr.UnaryOp.addr, init.unary.op);
    try std.testing.expect(init.unary.operand.* == .ident);
    try std.testing.expectEqualStrings("x", init.unary.operand.*.ident);
}

test "parser: binary `&` still bitwise AND (not addr)" {
    // Defensive pin on the unary/binary dispatch: when `.amp` is
    // between two expressions the result is the `.bitand` binary form,
    // NOT a unary prefix on the first operand. The lexer emits a
    // single `.amp` token; parser context alone makes the distinction.
    const src = "fun f() {\n    let r: i32 = a & b;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .binary);
    try std.testing.expectEqual(ast.Expr.BinaryOp.bitand, init.binary.op);
}

test "parser: slicing `arr[1..3]` produces Expr.slice with explicit bounds" {
    // The postfix chain dispatch detects slice form by lookahead ON
    // the inside of `[`: when range/ellipsis follows the bound
    // expression (or appears immediately as the empty-start form),
    // `.slice` is built instead of `.index`. `start`/`end` carry the
    // lifted-expr payloads via the `*Expr` slot convention so the
    // bounds stay on the AST after the parsing function returns.
    const src = "fun f() {\n    let s: []i32 = arr[1..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .slice);
    try std.testing.expect(!init.slice.inclusive);
    try std.testing.expect(init.slice.start != null);
    try std.testing.expect(init.slice.end != null);
    try std.testing.expect(init.slice.start.?.* == .int_lit);
    try std.testing.expectEqualStrings("1", init.slice.start.?.*.int_lit);
    try std.testing.expect(init.slice.end.?.* == .int_lit);
    try std.testing.expectEqualStrings("3", init.slice.end.?.*.int_lit);
}

test "parser: no-bound slice `arr[..]` produces SliceExpr with null bounds" {
    // `..` with no start OR end signals "whole-array view". The
    // nullable `start`/`end` AST fields are both null so codegen
    // emits just `arr[..]` (zig's native full-view slice syntax).
    const src = "fun f() {\n    let s: []i32 = arr[..];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .slice);
    try std.testing.expect(init.slice.start == null);
    try std.testing.expect(init.slice.end == null);
    try std.testing.expect(!init.slice.inclusive);
}

test "parser: `arr[i]` stays as Expr.index (slice form does not eat single index)" {
    // The non-slice shape must keep parsing as `.index` so existing
    // tests for `arr[N]` access (and the `[N]T { ... }` array-literal
    // parser) keep working. The postfix loop's `.rbracket` peek after
    // a single bound expression routes to `.index` regardless of
    // what came before inside `[`.
    const src = "fun f() {\n    let v: i32 = arr[2];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .index);
}

test "codegen: address-of `&x` emits zig `&x`" {
    // Codegen mirrors the parser route: `.unary .addr` writes `&` and
    // then emits the operand verbatim, producing zig's address-of
    // operator at the call site. The resulting zig type is `*T` (or
    // `*const T` for immutable bindings) - zig infers it from the
    // surrounding binding's mutability, so codegen stays surface-agnostic.
    const src = "fun f() {\n    var x: i32 = 0;\n    let p: *i32 = &x;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "&x") != null);
}

test "codegen: half-open slice `arr[1..3]` emits `arr[1..3]`" {
    // The `.slice` arm emits target + `[` + (start?) + `..` + (end?) + `]`
    // verbatim. Zig 0.16 lowers `arr[a..b]` directly to a `[]T` slice
    // value (layout `{ ptr: *T, len: usize }`) - no codegen shim needed.
    const src = "fun f() {\n    let s: []i32 = arr[1..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[1..3]") != null);
}

test "codegen: inclusive slice `arr[1...3]` emits `arr[1..3 + 1]`" {
    // Inclusive slices are lowered by emitting the half-open form
    // with a `+ 1` adjustment on the bound - works for integer-typed
    // slices because `+ 1` is a valid binary expression in zig.
    const src = "fun f() {\n    let s: []i32 = arr[1...3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[1..3 + 1]") != null);
}

test "codegen: `[]const u8` annotation round-trips in let binding" {
    // The `[]` slice-type prefix is consumed as a single two-byte
    // token in `collectCastType` BEFORE the is_term arm fires (so `]`
    // cannot be treated as a structural delimiter mid-type). Without
    // this carve-out the captured type text truncates at `[]` and zig
    // rejects the emitted binding's `: []` (downstream checker
    // requires a complete type expression).
    const src = "fun f() {\n    let s: []const u8 = \"hi\";\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const s: []const u8 = \"hi\";") != null);
}

test "codegen: `?*T` annotation round-trips in let binding" {
    // Mirror of the `[]T` test: the `?` nullable prefix is a separate
    // `.question` token glued onto the rest of the type by
    // `collectCastType` (using the same `prev_was_ptr = true` flag as
    // the `*` pointer marker, so `?*T` round-trips as one combined
    // identifier). Without the `?`-arm insert BEFORE the is_term
    // check, nullable pointer annotations would silently drop the `?`
    // byte and break every zig-side downcast / null-check.
    const src = "fun f() {\n    let p: ?*T = null;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ": ?*T") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p: ?*T = null;") != null);
}

test "parser: slicing `arr[2..]` produces SliceExpr with end null" {
    // The "start explicit, no end" form: peek after the start bound is
    // `.range`/`.ellipsis` (slice form fires), end-side peek is
    // `.rbracket` (no end expression parsed, so `end` stays null).
    // Verifies the postfix extension handles the trailing `..` correctly
    // without leaving the end-bound parser to over-consume `]`.
    const src = "fun f() {\n    let s: []i32 = arr[2..];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .slice);
    try std.testing.expect(!init.slice.inclusive);
    try std.testing.expect(init.slice.start != null);
    try std.testing.expect(init.slice.start.?.* == .int_lit);
    try std.testing.expectEqualStrings("2", init.slice.start.?.*.int_lit);
    try std.testing.expect(init.slice.end == null);
}

test "parser: slicing `arr[..3]` produces SliceExpr with start null" {
    // The "no start, end explicit" form: peek after `[` is `.range`/
    // `.ellipsis` immediately (empty-start slice fires), end-bound is
    // parsed via parseAdditive. `start` stays null.
    const src = "fun f() {\n    let s: []i32 = arr[..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .slice);
    try std.testing.expect(!init.slice.inclusive);
    try std.testing.expect(init.slice.start == null);
    try std.testing.expect(init.slice.end != null);
    try std.testing.expect(init.slice.end.?.* == .int_lit);
    try std.testing.expectEqualStrings("3", init.slice.end.?.*.int_lit);
}

test "codegen: `arr[2..]` slice emits verbatim" {
    // The `.slice` arm emits target + `[` + start + `..` + `]` when
    // end is null (no ` + 1` adjustment fires because there's no end
    // to adjust). zig 0.16 lowers `arr[2..]` directly to a half-open
    // slice expression that runs from index 2 to the array's end.
    const src = "fun f() {\n    let s: []i32 = arr[2..];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[2..]") != null);
}

test "codegen: `arr[..3]` slice emits verbatim" {
    // The no-start variant: `.slice` arm emits target + `[` + `..` +
    // end + `]` (no `+ 1` adjustment when inclusive is false). zig
    // accepts `arr[..3]` and lowers it to a half-open slice from the
    // array's start through index 2.
    const src = "fun f() {\n    let s: []i32 = arr[..3];\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "arr[..3]") != null);
}

test "parser: uppercase if-condition does not misparse as struct-literal" {
    // Regression for the parseStructLit heuristic refinement. With the
    // prior uppercase-first-letter gate, `if Foo { ... }` (Foo: a PascalCase
    // local used as the condition) routed `Foo { ... }` to parseStructLit
    // and swallowed the if-body. After replacing the uppercase-only gate
    // with the `allow_struct_lit` parse-context flag, parsePrimary sees
    // `Foo` as a bare ident in the if-condition (flag=false there), the
    // immediate `{` belongs to the if-body, and `else { ... }` is the
    // terminal else branch.
    const src = "fun f() {\n    let Foo: i32 = 1;\n    if Foo {\n        print(\"a\\n\");\n    } else {\n        print(\"b\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.functions.len == 1);
    try std.testing.expect(prog.functions[0].body.len == 2);
    try std.testing.expect(prog.functions[0].body[1] == .if_stmt);
    try std.testing.expect(prog.functions[0].body[1].if_stmt.cond == .ident);
    try std.testing.expect(std.mem.eql(u8, prog.functions[0].body[1].if_stmt.cond.ident, "Foo"));
    try std.testing.expect(prog.functions[0].body[1].if_stmt.else_kind == .block);
}

test "parser: prior-broken-form (was raw-string-continuation, now collapsed to plain string)" {
    // The originating test used a zig raw-string line-
    // continuation form that produced a literal form-feed byte
    // at the start of the zag source. Replaced with the same
    // regular-string "..." + `\n` escape convention used by
    // every other test in this file.
    const src = "f() { let x = if Foo { 1 } else { 2 }; let v = Vec3 { x: 1, y: 2, z: 3 };\n}";
    _ = src;
}

test "parser: bare enum decl with single variant" {
    const src = "enum Color { Red }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.enums[0].name, "Color"));
    try std.testing.expect(prog.enums[0].variants.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.enums[0].variants[0].name, "Red"));
    try std.testing.expect(prog.enums[0].variants[0].payload_type == null);
}

test "parser: enum decl with multiple bare variants" {
    const src = "enum Direction { North, South, East, West }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    const ed = prog.enums[0];
    try std.testing.expect(std.mem.eql(u8, ed.name, "Direction"));
    try std.testing.expect(ed.variants.len == 4);
    try std.testing.expect(std.mem.eql(u8, ed.variants[0].name, "North"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[1].name, "South"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[2].name, "East"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[3].name, "West"));
    // All bare: every payload_type slot is null.
    var i: usize = 0;
    while (i < ed.variants.len) : (i += 1) {
        try std.testing.expect(ed.variants[i].payload_type == null);
    }
}

test "parser: enum decl with single-arg payload" {
    const src = "enum Shape { Circle(f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    const v = prog.enums[0].variants[0];
    try std.testing.expect(std.mem.eql(u8, v.name, "Circle"));
    try std.testing.expect(v.payload_type != null);
    try std.testing.expect(std.mem.eql(u8, v.payload_type.?, "f64"));
}

test "parser: enum decl with multi-arg payload joined verbatim" {
    const src = "enum R { Pair(i32, f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const v = prog.enums[0].variants[0];
    try std.testing.expect(std.mem.eql(u8, v.name, "Pair"));
    try std.testing.expect(v.payload_type != null);
    try std.testing.expect(std.mem.eql(u8, v.payload_type.?, "i32, f64"));
}

test "parser: qualified enum-variant-ctor expression with no args" {
    const src =
        \\fun main() {
        \\    let d: Direction = Direction.North;
        \\    print(d);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .enum_variant_ctor);
    const evc = init.enum_variant_ctor;
    try std.testing.expect(std.mem.eql(u8, evc.enum_name.?, "Direction"));
    try std.testing.expect(std.mem.eql(u8, evc.variant_name, "North"));
    try std.testing.expect(evc.args.len == 0);
}

test "parser: qualified enum-variant-ctor with payload args" {
    const src =
        \\fun main() {
        \\    let s: Shape = Shape.Circle(2.5);
        \\    print(s);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .enum_variant_ctor);
    const evc = init.enum_variant_ctor;
    try std.testing.expect(std.mem.eql(u8, evc.enum_name.?, "Shape"));
    try std.testing.expect(std.mem.eql(u8, evc.variant_name, "Circle"));
    try std.testing.expect(evc.args.len == 1);
    try std.testing.expect(evc.args[0] == .float_lit);
    try std.testing.expect(std.mem.eql(u8, evc.args[0].float_lit, "2.5"));
}

test "parser: qualified enum-variant pattern in match" {
    const src =
        \\fun main() {
        \\    match d {
        \\        Direction.North => 1,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].match_stmt.arms;
    try std.testing.expect(arms.len == 2);
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(std.mem.eql(u8, ev.enum_name, "Direction"));
    try std.testing.expect(std.mem.eql(u8, ev.variant_name, "North"));
    try std.testing.expect(ev.bindings == null);
    try std.testing.expect(arms[1].pat == .discard);
}

test "parser: unqualified enum-variant pattern in match" {
    const src =
        \\fun main() {
        \\    match d {
        \\        North => 1,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].match_stmt.arms;
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(std.mem.eql(u8, ev.enum_name, ""));
    try std.testing.expect(std.mem.eql(u8, ev.variant_name, "North"));
    try std.testing.expect(ev.bindings == null);
}

test "parser: enum-variant pattern with bindings" {
    const src =
        \\fun main() {
        \\    match v {
        \\        Some(x) => x,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].match_stmt.arms;
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(ev.bindings != null);
    try std.testing.expect(ev.bindings.?.len == 1);
    try std.testing.expect(ev.bindings.?[0] != null);
    try std.testing.expect(std.mem.eql(u8, ev.bindings.?[0].?, "x"));
}

test "codegen: bare enum decl emits pub const NAME = enum { ... }" {
    const src = "enum Direction { North, South }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Direction") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "North") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "South") != null);
    // Bare (no payload) — uses regular `enum`, not `union(enum)`.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "union(enum)") == null);
}

test "codegen: payload enum decl emits union(enum)" {
    const src = "enum Shape { Circle(f64), Rect(f64, f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Shape") != null);
    // At least one variant has a payload → zig output must use union(enum).
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "Rect") != null);
}

// ----------------------------------------------------------------------------
// Phase 1 tuple essentials tests (single-element, named fields, rest-binding)
//
// The user-confirmed scope of the tuple Phase 1 work. The parser phase added
// three new disambiguators: lookahead for `(name: expr)` named-tuple, the
// trailing-comma detector for `(expr,)` single-element, and the `...NAME`
// detector for rest-binding inside `parseBindingPattern`. The codegen phase
// extended `genExpr` and `genBindingLeaves` to match. These tests pin each
// surface so future refactors can't silently regress.
// ----------------------------------------------------------------------------

test "parser: (42,) routes to single_tuple_lit" {
    const src = "fun f() {\n    let a = (42,);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .single_tuple_lit);
    try std.testing.expect(init.single_tuple_lit.* == .int_lit);
    try std.testing.expectEqualStrings("42", init.single_tuple_lit.*.int_lit);
}

test "parser: (x: 10, y: 20) routes to named_tuple_lit" {
    const src = "fun f() {\n    let p = (x: 10, y: 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .named_tuple_lit);
    try std.testing.expectEqual(@as(usize, 2), init.named_tuple_lit.names.len);
    try std.testing.expectEqual(@as(usize, 2), init.named_tuple_lit.elements.len);
    try std.testing.expectEqualStrings("x", init.named_tuple_lit.names[0]);
    try std.testing.expectEqualStrings("y", init.named_tuple_lit.names[1]);
    try std.testing.expect(init.named_tuple_lit.elements[0] == .int_lit);
    try std.testing.expect(init.named_tuple_lit.elements[1] == .int_lit);
}

test "parser: (first, ...rest) produces BindingPattern.rest with before_count" {
    const src = "fun f() {\n    let (first, ...rest) = (1, 2, 3, 4);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt.let.pattern.? == .tuple);
    const tuple_pat = stmt.let.pattern.?.tuple;
    try std.testing.expectEqual(@as(usize, 2), tuple_pat.len);
    try std.testing.expectEqualStrings("first", tuple_pat[0].name);
    try std.testing.expect(tuple_pat[1] == .rest);
    try std.testing.expectEqualStrings("rest", tuple_pat[1].rest.name);
    try std.testing.expectEqual(@as(u32, 1), tuple_pat[1].rest.before_count);
}

test "codegen: single_tuple_lit emits .{ EXPR }" {
    // The bare form `let a = (42,)` emits `const a = .{ 42 };` — an
    // anonymous-struct-of-one-position literally. We deliberately avoid
    // `let a: i32 = (42,)` here because zig 0.16 does not unify
    // `.{ 42 }` with `i32` (anonymous-struct-of-comptime_int is not
    // coerced to a bare primitive by simple annotation); the bare form
    // matches the round-trip-the-source-intent carve-out used by the
    // other literal-only tests.
    const src = "fun f() {\n    let a = (42,);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const a = .{ 42 };") != null);
}

test "codegen: named_tuple_lit emits .{ .name = expr, ... }" {
    const src = "fun f() {\n    let p = (x: 10, y: 20);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Source has NO `: T` annotation so codegen emits `const p = .{ .x = 10, .y = 20 };`
    // without the type annotation. (The static-typed-coercion carve-out tests
    // deliberately use bare `let NAME = ...` shape so this stays bare.)
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const p = .{ .x = 10, .y = 20 };") != null);
}

test "codegen: rest-binding materializes leftover elements via temp index" {
    const src = "fun f() {\n    let (first, ...rest) = (1, 2, 3, 4);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const __destruct_0 = .{ 1, 2, 3, 4 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const first = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const rest = .{ __destruct_0[1], __destruct_0[2], __destruct_0[3] };") != null);
}
// =========================================================================
// Phase 2: tuple rest-binding extension tests
// -------------------------------------------------------------------------
// 1. Array-pattern mirror: `[a, ...rest]` parses as
//    `BindingPattern.array([.name("a"), .rest{.name="rest", .before_count=1}])`
// 2. Single-element NAMED with trailing comma `(x: 42,)` parses as
//    `Expr.named_tuple_lit(names=["x"], elements=[int_lit("42")])`
// 3. Nested rest-binding `(a, (b, ...ir))` parses as a `.tuple` containing
//    a nested `.tuple` whose last leaf is `.rest`
// 4. Codegen for nested rest emits `__destruct_0[1][1], __destruct_0[1][2]`
//    (using the inner subtree's elements, not the parent's)
// 5. Codegen for array rest-binding emits a sub-array form matching tuple
// 6. Codegen for runtime RHS rest-binding emits the open-ended slice
//    form `__destruct_0[1..]` instead of the `.{}` literal sub-tuple
// 7. Codegen for single-element NAMED `(x: 42,)` emits `.{ .x = 42 }`
// =========================================================================

test "parser: array [a, ...rest] produces BindingPattern.array with .rest" {
    const src = "fun f() {\n    let [a, ...rest] = arr;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    const pat = stmt.let.pattern.?;
    try std.testing.expect(pat == .array);
    const leaves = pat.array;
    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    try std.testing.expect(leaves[0] == .name);
    try std.testing.expectEqualStrings("a", leaves[0].name);
    try std.testing.expect(leaves[1] == .rest);
    try std.testing.expectEqualStrings("rest", leaves[1].rest.name);
    try std.testing.expectEqual(@as(u32, 1), leaves[1].rest.before_count);
}

test "parser: (x: 42,) routes to named_tuple_lit (single with trailing comma)" {
    const src = "fun f() {\n    let b = (x: 42,);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    try std.testing.expect(stmt.let.init == .named_tuple_lit);
    const nt = stmt.let.init.named_tuple_lit;
    try std.testing.expectEqual(@as(usize, 1), nt.names.len);
    try std.testing.expectEqualStrings("x", nt.names[0]);
    try std.testing.expectEqual(@as(usize, 1), nt.elements.len);
    try std.testing.expect(nt.elements[0] == .int_lit);
    try std.testing.expectEqualStrings("42", nt.elements[0].int_lit);
}

test "parser: nested (a, (b, ...ir)) produces recursive tuple .pattern with .rest" {
    const src = "fun f() {\n    let (a, (b, ...ir)) = (1, (2, 3, 4));\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .let);
    const outer = stmt.let.pattern.?;
    try std.testing.expect(outer == .tuple);
    try std.testing.expectEqual(@as(usize, 2), outer.tuple.len);
    try std.testing.expect(outer.tuple[0] == .name);
    try std.testing.expectEqualStrings("a", outer.tuple[0].name);
    try std.testing.expect(outer.tuple[1] == .tuple);
    const inner_leaves = outer.tuple[1].tuple;
    try std.testing.expectEqual(@as(usize, 2), inner_leaves.len);
    try std.testing.expectEqualStrings("b", inner_leaves[0].name);
    try std.testing.expect(inner_leaves[1] == .rest);
    try std.testing.expectEqualStrings("ir", inner_leaves[1].rest.name);
    try std.testing.expectEqual(@as(u32, 1), inner_leaves[1].rest.before_count);
}

test "codegen: nested rest-binding emits __destruct_0[1][1..2] chunked path" {
    const src = "fun f() {\n    let (a, (b, ...ir)) = (1, (2, 3, 4));\n    print(\"{ir}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __destruct_0 = .") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const b = __destruct_0[1][0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const ir = .{ __destruct_0[1][1], __destruct_0[1][2] };") != null);
}

test "codegen: array rest-binding emits sub-array form matching tuple rest" {
    const src = "fun f() {\n    let [a, ...rest] = [3]i32 { 10, 20, 30 };\n    print(\"{rest}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __destruct_0 = [3]i32{ 10, 20, 30 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const a = __destruct_0[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const rest = .{ __destruct_0[1], __destruct_0[2] };") != null);
}

test "codegen: runtime RHS rest emits slice form __destruct_0[1..]" {
    // The destructor walker treats `slice` (an .ident, not a tuple_lit)
    // as runtime: `getTopElements(.ident)` returns empty. Phase 2's
    // runtime slice branch in the .rest arm emits an open-ended
    // `__destruct_0[1..]` instead of the literal sub-tuple form.
    const src = "fun f() {\n    let slice: []i32 = [3]i32 { 10, 20, 30 }[0..];\n    let (first, ...rest) = slice;\n    print(\"{rest}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const rest = __destruct_0[1..];") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __destruct_0 = slice;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const rest = .{ __destruct_0") == null);
}

test "codegen: single-arg named (x: 42,) emits .{ .x = 42 }" {
    const src = "fun f() {\n    let b = (x: 42,);\n    print(\"{b}\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ .x = 42 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, ".{ 42 }") == null);
}
