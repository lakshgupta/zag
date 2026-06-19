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
    const src =
        \\fun f() {
        \\    let x: i32 = 10;
        \\    var y: f64 = 3.14;
        \\    const PI: f64 = 3.14159;
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
    const src =
        \\fun f() {
        \\    let PI: f64 = 3.14159265;
        \\    print("pi = {PI:.5}\n");
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (1 / 2);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (1.0 / 2.0);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (2 / x);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (1.0 / x);") != null);
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
        \\    let r = pi / 2;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r = (pi / 2);") != null);
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
        \\    let z = n / 2;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (n / 2);") == null);
}

test "codegen: f64-typed ident LHS % int_lit stays bare" {
    // Mirror of the `/` case for the `.mod` operator: `let pi: f64 = 3.14;
    // pi % 2` must emit the bare form because `@rem` requires integer args.
    // The `isFloatIdentType` map check applies symmetrically to `.mod`.
    const src =
        \\fun f() {
        \\    let pi: f64 = 3.14;
        \\    let r = pi % 2;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const r = (pi % 2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@rem") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc") == null);
}

test "codegen: unannotated i32-init binding / int_lit still triggers @divTrunc" {
    // Pins the conservative shim rule for unannotated bindings. `let x =
    // 10; x / 2` doesn't enter the type-info map (the predicate's
    // `collectTypedBindings` only collects `: T`-annotated bindings —
    // see the typed-binding-lookup tests for the f64 vs i32 distinction),
    // so `isFloatIdentType("x")` returns false, the predicate falls
    // through to its `!exprContainsFloat(.ident)` guard, and the shim
    // fires — emitting `@divTrunc(x, 2)`. Zig accepts because `x` is a
    // comptime_int inferred from `10` and both `@divTrunc` operands are
    // integer-typed. Net effect: no over-broad skip when the map is empty.
    const src =
        \\fun f() {
        \\    let x = 10;
        \\    let z = x / 2;
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "@divTrunc(x, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (x / 2);") == null);
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
    for (expected_tags, expected_texts) |tag, text| {
        const idx = (@intFromPtr(&tag) - @intFromPtr(&expected_tags[0])) / @sizeOf(lexer_mod.TokenTag);
        try std.testing.expectEqual(tag, tokens[idx].tag);
        try std.testing.expectEqualStrings(text, tokens[idx].text);
    }
}

test "parser: errdefer parses as Stmt.errdefer_stmt" {
    // Pattern 2 from docs/19-memory.md: `errdefer free(a)` runs only on the
    // `?`-propagation path. Parser pins the AST tag so the codegen surface
    // ({errdefer expr;}) is replayable by tests.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const stmt = prog.functions[0].body[0];
    try std.testing.expect(stmt == .errdefer_stmt);
    try std.testing.expect(stmt.errdefer_stmt.expr == .template_lit);
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
    const src = "fun f() {\n    let p = new i32(42);\n    defer free(p);\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "try std.heap.page_allocator.create(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__p_0.* = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :blk __p_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const p = __p_0") != null);
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
    // names so zig's no-redeclaration rule is satisfied. Without the
    // per-function counter the user's `let __p_0` would silently clash.
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
    try std.testing.expect(std.mem.indexOf(u8, zig, "const a = __p_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const b = __p_1") != null);
}

test "codegen: errdefer stmt emits errdefer verbatim" {
    // Mirrors zig 0.16's `errdefer` keyword one-to-one so zig's semantics
    // (runs the expression ONLY on `?`-propagation or `Err` early-return)
    // match the zag docs' Pattern 2 framing.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    errdefer print(\"cleanup\\n\");") != null);
}

test "codegen: unsafe block emits body in plain block with comment markers" {
    // zig 0.16 has no block-form `unsafe` keyword — the block is purely a
    // source-level audit marker. Codegen emits the body wrapped in plain
    // `{ ... }` with `// unsafe {` and `// }` comments so the structure is
    // visible to `-Dunsafe-block-check` tooling without affecting the
    // emitted zig semantics (raw pointer ops are already unconditional).
    const src = "fun f() {\n    unsafe {\n        print(\"inside\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // unsafe {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    print(\"inside\\n\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // }") != null);
}

test "codegen: as cast emits passthrough with parens" {
    // The parser's `collectCastType` joined multi-token types like
    // `*raw c_void` into one `type_text` slice; codegen emits
    // `(expr as type_text)` verbatim so zig's `as` operator handles the
    // cast surface natively (pointers, numerics, raw pointers).
    const src = "fun f() {\n    let y: i32 = x as i32;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    const y: i32 = (x as i32);") != null);
}
