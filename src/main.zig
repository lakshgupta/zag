const std = @import("std");
const posix = std.posix;
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const codegen_mod = @import("codegen.zig");
const ast = @import("ast.zig");
const toolchain = @import("toolchain.zig");
const build_options = @import("build_options");

var zig_path: []const u8 = undefined;

/// Zag-managed zig cache directory. The materialize destination
/// `zag_cache_zig_path` is parameterized as `<zag_cache_dir>/zig`
/// so the runtime `std.os.linux.mkdir` on the cache parent stays
/// verbatim and the bytes-on-disk layout users can `ls` is
/// unchanged (one file, named `zig`, inside the dir).
///
/// Resolution (Phase 3 -- order matters):
///   1. `$ZAG_HOME` if set (explicit user override; wins,
///      populated verbatim, trailing-slash tolerant via fs calls
///      that ignore double slashes)
///   2. `$XDG_CACHE_HOME/zag` if set (freedesktop.org cache
///      convention -- semantically correct for a reproducible
///      binary payload that can be re-materialized at any time)
///   3. `$HOME/.cache/zag` if neither above is set (POSIX-friendly
///      HOME fallback that honours XDG_CACHE_HOME's `~/.cache`
///      convention)
///   4. `build_options.z_install` (compile-time `-Dz_install=<dir>`
///      default, `/home/lex/.local/zag` out of the box)
///
/// Stored as `var` because env-pass + resolution happen at
/// startup in `main()` (between `readEnviron` and the `mkdir`+
/// materialize steps). The comptime `++ "/zig"` shape is preserved
/// as the initial value so the runtime fallback to
/// `options.z_install` still produces a syntactically correct
/// `<dir>/zig` materialize path without an extra format step.
///
/// The user-installed zig at `zig_install_path` is unchanged and
/// remains the no-payload / materialize-failure fallback -- a
/// separate concern from the zag-managed cache dir this overrides.
var zag_cache_dir: []const u8 = build_options.z_install;
var zag_cache_zig_path: []const u8 = build_options.z_install ++ "/zig";
var zag_cache_dir_buf: [4096]u8 = undefined;
var zag_cache_zig_path_buf: [4096]u8 = undefined;

/// User-installed zig runtime -- the fallback `zig_path` used
/// when `toolchain.tryMaterialize` is a no-op (default empty-
/// payload build, where `has_payload()` folds to false at
/// comptime) OR when it returns a labelled-block catch error
/// (write-permission issue on a read-only HOME, etc.).
/// TODO(env-var indirection): see TODO on `zag_cache_dir` above.
const zig_install_path = "/home/lex/.local/zig/zig";

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
    // Phase 1 followup: zig_path is resolved by the materialize
    // block below -- the embedded payload at `zag_cache_zig_path`
    // if `tryMaterialize` succeeded (when `build_options.zig_payload`
    // is non-empty), or the user's installed fallback at
    // /home/lex/.local/zig/zig otherwise. The empty sentinel
    // folds `has_payload()` to false at comptime and
    // `tryMaterialize` early-returns without touching disk, so
    // the fallback path stays active under the default build.

    // Phase 3 followup: read /proc/self/environ FIRST so the
    // env-pass arrays consulted by `runCommand` (later) AND
    // `resolveZagCacheDir` (right after) are populated. The order
    // matters: `getenv` walks `environ_entries`, so resolveZagCacheDir
    // must run AFTER readEnviron, AND resolveZagCacheDir must run
    // BEFORE mkdir+materialize so the materialize destination
    // matches what the resolved cache dir says it should be.
    readEnviron();
    zag_cache_dir = resolveZagCacheDir(&zag_cache_dir_buf);
    const zig_path_formatted = std.fmt.bufPrint(
        &zag_cache_zig_path_buf,
        "{s}/zig",
        .{zag_cache_dir},
    ) catch build_options.z_install ++ "/zig";
    zag_cache_zig_path = zig_path_formatted;

    // Best-effort mkdir of the cache parent. EEXIST (common
    // case after first install) is silently absorbed because
    // `std.os.linux.mkdir` returns a raw usize rc we discard.
    // Other errors (EACCES on a root-restricted HOME, etc.)
    // surface as the openat ENOENT during the tryMaterialize
    // call below and the catch fallback routes to the
    // installed zig.
    _ = std.os.linux.mkdir(@ptrCast(zag_cache_dir.ptr), 0o755);

    // Materialize-error handling: any openat/chmod/write error
    // is logged and treated as "no materialize" so HOME-dir
    // write issues don't block `zag run` entirely -- they fall
    // through to the installed-zig path. The labeled-block
    // catch `blk:` lets us print a diagnostic before yielding
    // a fallback `false`. The diagnostic includes the
    // materialize destination so multi-developer-machine
    // debugging can attribute the failure to the right HOME.
    const materialized = toolchain.tryMaterialize(zag_cache_zig_path) catch |err| blk: {
        std.debug.print("warning: embedded zig materialize at {s} failed: {s}; using installed zig\n", .{ zag_cache_zig_path, @errorName(err) });
        break :blk false;
    };
    zig_path = if (materialized) zag_cache_zig_path else zig_install_path;

    const args = try parseArgs();

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

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
    // Defensive NUL termination: the read loop's per-entry `:0`
    // sentinel annotation assumes `environ_buf[i] == 0` at the
    // post-loop position. POSIX `/proc/self/environ` ends with
    // a final NUL terminator and the kernel returns that final
    // byte in `n`, so the loop normally terminates cleanly. But
    // the byte right *after* the kernel-returned bytes
    // (`environ_buf[n]` if `n < environ_buf.len`) is BSS-
    // `undefined` (Debug/ReleaseSafe paint 0xaa, not 0), so a
    // really-large env where the read consumed N bytes whose
    // last byte is non-NUL would silently corrupt the last
    // entry's `:0` sentinel and trigger downstream
    // sentinel-mismatch UB. Paint 0 here as a safety net.
    if (n < environ_buf.len) environ_buf[n] = 0;

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

/// Walk `environ_entries` (populated by `readEnviron`) for an
/// entry whose key matches `name`. Returns the value slice
/// (everything after the first `=`) if found, else `null`. Empty
/// values (e.g. `FOO=`) are returned as an empty slice.
fn getenv(name: []const u8) ?[]const u8 {
    for (environ_entries[0..environ_count]) |maybe_entry| {
        const entry_ptr = maybe_entry orelse continue;
        // `entry_ptr` is a many-pointer [*:0]const u8; zig 0.16's
        // `std.mem.indexOfScalar` and `std.mem.eql` both require
        // `[]const T` slices (not pointers), so we materialise a
        // `[]const u8` from the NUL sentinel up-front.
        const entry_slice = std.mem.span(entry_ptr);
        const sep = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
        if (sep == name.len and std.mem.eql(u8, entry_slice[0..sep], name)) {
            return entry_slice[sep + 1..];
        }
    }
    return null;
}

/// Resolve the zag-managed cache directory at runtime per the
/// priority chain documented on `zag_cache_dir` above. Writes
/// any `$XDG_CACHE_HOME`- or `$HOME`-derived result into `buf`
/// (via `bufPrint`); `$ZAG_HOME` and the `build_options.z_install`
/// fallback are returned as comptime slice values -- no buffer
/// write needed for those branches. `buf` should be at least
/// `PATH_MAX`-ish; we use a 4096-byte scratch at the call site
/// for headroom over the typical 4 KB PATH_MAX / `PATH=...` length.
fn resolveZagCacheDir(buf: []u8) []const u8 {
    if (getenv("ZAG_HOME")) |home| return home;
    if (getenv("XDG_CACHE_HOME")) |cache| {
        return std.fmt.bufPrint(buf, "{s}/zag", .{cache}) catch build_options.z_install;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.cache/zag", .{home}) catch build_options.z_install;
    }
    return build_options.z_install;
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





















































































































































































































// -------------------------------------------------------------------
// docs/19-memory.md feature tests — heap-from-new bug fix, errdefer,
// unsafe block, `as` cast, and the `new(<alloc>, T(v))` allocator
// sugar. Each pair has a parser test pinning the AST shape and a
// codegen test pinning the emitted zigzag source. Without these the
// next refactor can silently regress the docs-documented surface.
// -------------------------------------------------------------------





























// -------------------------------------------------------------------
// docs/12-structs.md feature tests — struct def / struct-literal /
// field-read / field-write / method-call / impl-block method nesting.
// Each pair pins a parser tag and a codegen emission shape matching the
// per-f64 24-byte value model the spec describes. The complete vec3
// example is exercised by examples/structs/vec3.zag (simplified form
// — no imports / no operator overload, all in-scope surface only).
// -------------------------------------------------------------------































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



































































// -------------------------------------------------------------------
// docs/manual/09-pointers.md feature tests - `&` address-of, slicing,
// and the multi-token pointer type annotations (`*T`, `*const T`,
// `[]T`, `[]const T`, `?*T`). Each pair pins the AST shape or the
// emitted zig source so a future refactor in `parser.zig`/`codegen.zig`
// cannot silently break the chapter's documented surface.
// -------------------------------------------------------------------























































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


// ---- test entrypoints (extracted from main.zig) ----
comptime {
    _ = @import("tests/lexer.zig");
    _ = @import("tests/parser.zig");
    _ = @import("tests/codegen.zig");
    _ = @import("tests/toolchain.zig");
    // Phase 1 single-file staging: toolchain.zig's top-level
    // `@embedFile("../vendor/zig/zig.empty")` must fire so a future
    // materialize call site can consult `has_payload()`. Today's
    // embedded payload is empty (sentinel at project root); the
    // installer-script path is still the active zig-fetch flow.
    _ = @import("toolchain.zig");
}
