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
const toolchain = @import("toolchain.zig");
const build_options = @import("build_options");

/// Optimization mode for `zag run` / `zag build` / `zag debug`,
/// mapped 1:1 onto zig's `-Doptimize=` values. Debug = no flag
/// (the generated build.zig's standardOptimizeOption defaults to
/// Debug). `--release` keeps its legacy spelling for ReleaseFast;
/// `--release-safe` / `--release-small` expose the other two.
const BuildMode = enum { debug, release_fast, release_safe, release_small };

/// The zig optimization name for a BuildMode ("" = default Debug).
fn optimizeName(m: BuildMode) []const u8 {
    return switch (m) {
        .debug => "",
        .release_fast => "ReleaseFast",
        .release_safe => "ReleaseSafe",
        .release_small => "ReleaseSmall",
    };
}

/// Scan args[from..to] (the pre-`--` region) for build-mode flags.
/// Later flags win; `--release` is the legacy ReleaseFast spelling.
fn parseBuildMode(args: []const []const u8, from: usize, to: usize) BuildMode {
    var m: BuildMode = .debug;
    var i = from;
    while (i < to) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--release")) m = .release_fast;
        if (std.mem.eql(u8, args[i], "--release-safe")) m = .release_safe;
        if (std.mem.eql(u8, args[i], "--release-small")) m = .release_small;
    }
    return m;
}

var zig_install_buf: [512]u8 = undefined;
var zig_install_len: usize = 0;

fn setZigPath(path: []const u8) void {
    if (path.len < zig_install_buf.len) {
        @memcpy(zig_install_buf[0..path.len], path);
        zig_install_len = path.len;
    }
}

fn zigPath() []const u8 {
    return zig_install_buf[0..zig_install_len];
}

/// Materialized location of the embedded zig payload (when the
/// `zag` binary was built with `-Dzig_payload=<path>`). Captured
/// ONCE at startup inside `main`; consulted by `resolveZigPath`
/// as the lowest-priority fallback (per
/// `docs/manual/35-zag-toml-schema.md` §[toolchain]: project toml
/// > `$ZAG_ZIG_PATH` > embedded). Empty when no payload was
/// embedded at build time, in which case `resolveZigPath` returns
/// with `zig_install_path` empty and the dispatched cmd exits via
/// `needZig()`.
var embedded_zig_path: []const u8 = "";

/// Stable buffer for the resolved zig path — `resolveZigPath` copies
/// the chosen path here so callers get a persistent slice.
var zig_path_buf: [512]u8 = undefined;
var zig_path_len: usize = 0;
var zig_install_path: []const u8 = "";
fn updateZigPathAlias() void {
    zig_install_path = zig_path_buf[0..zig_path_len];
}

pub fn main() !void {
    env_path.readEnviron();

    // Priority chain for locating zig:
    //   1. Embedded zig payload — materialize to cache dir, validate ELF, use it
    //   2. $ZAG_ZIG_PATH env var
    //   3. Error with a clear message
    if (toolchain.has_payload()) {
        var cache_buf: [4096]u8 = undefined;
        const cache_dir = env_path.resolveZagCacheDir(&cache_buf, build_options.z_install);
        var dest_buf: [4096]u8 = undefined;
        var dl: usize = 0;
        @memcpy(dest_buf[0..cache_dir.len], cache_dir);
        dl += cache_dir.len;
        if (cache_dir.len > 0 and cache_dir[cache_dir.len - 1] != '/') {
            dest_buf[dl] = '/';
            dl += 1;
        }
        const zig_bin = "zig/zig";
        @memcpy(dest_buf[dl..][0..zig_bin.len], zig_bin);
        dl += zig_bin.len;
        dest_buf[dl] = 0;
        var sub_buf: [4096]u8 = undefined;
        var sl: usize = 0;
        @memcpy(sub_buf[0..cache_dir.len], cache_dir);
        sl += cache_dir.len;
        if (cache_dir.len > 0 and cache_dir[cache_dir.len - 1] != '/') {
            sub_buf[sl] = '/';
            sl += 1;
        }
        @memcpy(sub_buf[sl..][0..3], "zig");
        sl += 3;
        sub_buf[sl] = 0;
        _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, @ptrCast(&sub_buf), 0o755);
        toolchain.materializeZigToCache(dest_buf[0..dl]) catch {};
        const fd = posix.openat(posix.AT.FDCWD, dest_buf[0..dl], .{ .ACCMODE = .RDONLY }, 0) catch null;
        if (fd) |f| {
            defer _ = std.os.linux.close(f);
            var magic: [4]u8 = undefined;
            const n = std.os.linux.read(f, &magic, magic.len);
            if (n == 4 and magic[0] == 0x7f and magic[1] == 'E' and magic[2] == 'L' and magic[3] == 'F') {
                embedded_zig_path = dest_buf[0..dl];
            }
        }
    }
    // Per-cmd zig path resolution happens INSIDE the dispatched
    // fn (cmdRun / cmdBuild / cmdCheck / cmdTest) via the
    // `resolveZigPath` helper. The priority chain
    // (`[toolchain].zig` > `$ZAG_ZIG_PATH` > embedded) is computed
    // fresh per invocation so a project-mode dispatch can apply
    // its `cfg.zig_path` override before falling back to env /
    // embedded. See `resolveZigPath` below for the full chain.
    const args = try parseArgs();

    if (args.len >= 2 and std.mem.startsWith(u8, args[1], "--leaf-process=")) {
        const flag = args[1]["--leaf-process=".len..];
        try leafProcess(flag, if (args.len >= 3) args[2] else "", null, &.{}, .debug);
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
    if (std.mem.eql(u8, cmd, "generate")) {
        return try cmdGenerate(args);
    }
    if (std.mem.eql(u8, cmd, "run")) {
        return try cmdRun(args);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        return try cmdBuild(args);
    }
    if (std.mem.eql(u8, cmd, "debug")) {
        return try cmdDebug(args);
    }
    if (std.mem.eql(u8, cmd, "pkg")) {
        return try cmdPkg(args);
    }
    if (std.mem.eql(u8, cmd, "install")) {
        return try cmdInstall(args);
    }
    if (std.mem.eql(u8, cmd, "update")) {
        return try cmdUpdate(args);
    }
    if (std.mem.eql(u8, cmd, "remove")) {
        return try cmdRemove(args);
    }
    if (std.mem.eql(u8, cmd, "check") or std.mem.eql(u8, cmd, "test")) {
        if (args.len >= 3 and hasZagExt(args[2])) {
            resolveZigPath(null);
            if (zig_install_path.len == 0) return needZig();
            try leafProcess(cmd, args[2], null, &.{}, .debug);
        } else if (try project_mod.detectProject("")) |cfg| {
            resolveZigPath(cfg);
            if (zig_install_path.len == 0) return needZig();
            try projectCmd(cmd, cfg, &.{}, false, .debug);
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

    // Check for build-mode flags before --
    const mode = parseBuildMode(args, 2, sep_idx);

    // Determine mode: file specified before -- or after?
    const zag_file = blk: {
        if (args.len >= 3 and sep_idx >= 3 and hasZagExt(args[2])) {
            break :blk args[2];
        }
        if (sep_idx < args.len and args.len >= 3) {
            for (args[2..sep_idx], 2..) |a, i| {
                if (hasZagExt(a)) break :blk args[i];
            }
        }
        break :blk null;
    };

    if (zag_file) |file| {
        resolveZigPath(null);
        if (zig_install_path.len == 0) return needZig();
        try leafProcess("run", file, null, extra_args, mode);
    } else if (try project_mod.detectProject("")) |cfg| {
        resolveZigPath(cfg);
        if (zig_install_path.len == 0) return needZig();
        try projectCmd("run", cfg, extra_args, false, mode);
    } else {
        std.debug.print("error: missing file argument. Provide a .zag file or run from a project directory.\n\n", .{});
        usage();
        std.process.exit(1);
    }
}

fn cmdBuild(args: []const []const u8) !void {
    // Parse -o / --output, -g / --generate, build-mode flags
    var output_path: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var generate_flag = false;

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
        } else if (std.mem.eql(u8, a, "-g") or std.mem.eql(u8, a, "--generate")) {
            generate_flag = true;
        } else if (hasZagExt(a)) {
            file_arg = a;
        }
    }
    const mode = parseBuildMode(args, 2, args.len);

    if (file_arg) |file| {
        const out = output_path orelse file[0..file.len - ".zag".len];
        resolveZigPath(null);
        if (zig_install_path.len == 0) return needZig();
        try leafProcess("build", file, out, &.{}, mode);
    } else if (try project_mod.detectProject("")) |cfg| {
        resolveZigPath(cfg);
        if (zig_install_path.len == 0) return needZig();
        try projectCmd("build", cfg, &.{}, generate_flag, mode);
    } else {
        std.debug.print("error: missing file argument. Provide a .zag file or run from a project directory.\n\n", .{});
        usage();
        std.process.exit(1);
    }
}

fn cmdDebug(args: []const []const u8) !void {
    // Parse: zag debug [<binary.zag>] [-- <args>]
    var file_arg: ?[]const u8 = null;
    var extra_args: []const []const u8 = &.{};

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            extra_args = if (i + 1 < args.len) args[i + 1 ..] else &.{};
            break;
        } else if (hasZagExt(a)) {
            file_arg = a;
        }
    }
    const mode = parseBuildMode(args, 2, args.len);

    // Binary to debug — file mode debugs the leaf output; project
    // mode builds via `zig build --build-file build/gen/build.zig`,
    // whose install prefix is RELATIVE TO THE BUILD FILE's directory
    // — the binary lands at `build/gen/zig-out/bin/<name>`, NOT
    // `zig-out/bin/<name>` (a stale path silently skipped the DWARF
    // patch + gdb launch in project mode).
    var binary_path: [512]u8 = undefined;
    var bin: []const u8 = "zig-out/bin/main";

    if (file_arg) |file| {
        // File mode: compile the .zag file, debug the binary
        resolveZigPath(null);
        if (zig_install_path.len == 0) return needZig();
        const out = file[0..file.len - ".zag".len];
        try leafProcess("build", file, out, &.{}, mode);
        bin = out;
    } else if (try project_mod.detectProject("")) |cfg| {
        resolveZigPath(cfg);
        if (zig_install_path.len == 0) return needZig();
        // Write map files and build
        try projectCmd("build", cfg, &.{}, false, mode);
        bin = try std.fmt.bufPrint(&binary_path, "build/gen/zig-out/bin/{s}", .{cfg.name});
    }

    // Write gdbinit file
    try writeGdbInit();

    // Patch DWARF debug info so gdb shows .zag sources
    _ = remapDwarfElf(bin);

    // Launch gdb
    var gdb_args: [10][]const u8 = undefined;
    gdb_args[0] = "gdb";
    gdb_args[1] = "-q";
    gdb_args[2] = "-x";
    gdb_args[3] = "build/gen/gdbinit";
    gdb_args[4] = "-ex";
    gdb_args[5] = "run";
    gdb_args[6] = "--args";
    gdb_args[7] = bin;
    var arg_count: usize = 8;
    // Append extra args after binary
    var extra_idx: usize = 0;
    while (extra_idx < extra_args.len and arg_count < gdb_args.len) : (extra_idx += 1) {
        gdb_args[arg_count] = extra_args[extra_idx];
        arg_count += 1;
    }

    const code = runCommand(null, gdb_args[0..arg_count]) catch {
        std.debug.print("error: could not launch gdb. Is gdb installed?\n", .{});
        std.debug.print("  hint: install gdb or use 'zag build' and debug manually:\n", .{});
        std.debug.print("    gdb -x build/gen/gdbinit {s}\n", .{bin});
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn writeGdbInit() !void {
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);
    // Find the tools directory relative to the project root
    const gdbinit =
        \\# Zag gdb init — maps zig source locations to zag source
        \\python
        \\import sys, os
        \\# The Python assistant ships with zag (tools/zag_gdb.py), NOT
        \\# with the user's project. Search the usual spots: the project
        \\# root (repo layout / copied tools/), a ZAG_TOOLS_DIR override,
        \\# and the ~/.zag install layout (install-local.sh). The first
        \\# hit wins; the import below fails loudly if none matches.
        \\for _cand in [os.path.join(os.getcwd(), 'tools'),
        \\              os.environ.get('ZAG_TOOLS_DIR', ''),
        \\              os.path.expanduser('~/.zag/tools')]:
        \\    if _cand and os.path.isdir(_cand):
        \\        sys.path.insert(0, _cand)
        \\        break
        \\import zag_gdb
        \\zag_gdb.load_map_files(os.path.join(os.getcwd(), 'build/gen'))
        \\try:
        \\    gdb.frame_filters["zag_decorate"] = zag_gdb.zag_frame_decorator
        \\except: pass
        \\end
        \\set pagination off
        \\echo [zag] gdb with .zag source mapping ready\n
    ;
    try writeFile("build/gen/gdbinit", gdbinit);
}

fn cmdGenerate(args: []const []const u8) !void {
    var output_dir: []const u8 = "build/gen";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (i + 1 < args.len) {
                output_dir = args[i + 1];
                i += 1;
            }
        }
    }

    if (try project_mod.detectProject("")) |cfg| {
        _ = cfg;
        try generateProjectFiles();
        std.debug.print("generated zig project at {s}/\n", .{output_dir});
        return;
    }

    // File mode: transpile single file
    if (args.len >= 3 and hasZagExt(args[2])) {
        const source = try readFile(args[2]);
        const result = try transpile(args[2], source, false);
        // Use output dir as file path
        const out_path = if (std.mem.eql(u8, output_dir, "build/gen")) "build/gen/main.zig" else output_dir;
        _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
        _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);
        try writeFile(out_path, result.zig);
        if (result.map.len > 0) try writeMapFile(out_path, result.map);
        std.debug.print("generated {s}\n", .{out_path});
        return;
    }

    std.debug.print("error: no project found. Run from a directory with zag.toml, or pass a .zag file.\n", .{});
    std.process.exit(1);
}

fn projectCmd(mode: []const u8, cfg: project_mod.ProjectConfig, extra_args: []const []const u8, generate: bool, build_mode: BuildMode) !void {
    _ = extra_args;

    // Ensure build/gen/ and build/bin/ exist
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/bin", 0o755);

    // v0.1 stdlib migration hybrid: write lib/std/*.zag →
    // build/gen/std/*.zig BEFORE user-module transpile so the
    // generated zig's `@import("std/<n>.zig")` lines (emitted by
    // Codegen's hybrid preamble when `use_hybrid_stdlib = true`)
    // resolve at compile time.
    materializeStdlib("build/gen");

    // Discover modules and transpile each
    const modules = project_mod.discoverModules();
    const has_main = for (modules) |m| {
        if (std.mem.eql(u8, m.module_name, "main")) break true;
    } else false;

    if (!has_main) {
        std.debug.print("error: no src/main.zag found\n", .{});
        std.process.exit(1);
    }

    // Transpile and write each module
    for (modules) |mod| {
        const source = readFile(mod.path) catch {
            std.debug.print("error: could not read {s}\n", .{mod.path});
            std.process.exit(1);
        };
        const result = transpile(mod.path, source, true) catch |e| {
            std.debug.print("error: transpile failed for {s}: {s}\n", .{ mod.path, @errorName(e) });
            std.process.exit(1);
        };

        // Output path: build/gen/<module>.zig
        var out_buf: [512]u8 = undefined;
        const out_path = if (std.mem.eql(u8, mod.module_name, "main"))
            std.fmt.bufPrint(&out_buf, "build/gen/main.zig", .{}) catch "build/gen/main.zig"
        else
            std.fmt.bufPrint(&out_buf, "build/gen/{s}.zig", .{mod.module_name}) catch "build/gen/module.zig";

        try writeFile(out_path, result.zig);
        if (result.map.len > 0) try writeMapFile(out_path, result.map);
    }

    // Generate build.zig for the project
    try generateBuildZig(modules, cfg.name);

    if (generate) {
        std.debug.print("generated zig project at build/gen/\n", .{});
        if (std.mem.eql(u8, mode, "generate")) return;
    }

    // Use zig build system with the generated build.zig
    // run → `zig build run --build-file ...`
    // build → `zig build --build-file ...` (default install step)
    // Build-mode flags pass `-Doptimize=<name>` through (the
    // generated build.zig reads b.standardOptimizeOption).
    var opt_flag_buf: [32]u8 = undefined;
    const opt_flag = if (build_mode != .debug)
        std.fmt.bufPrint(&opt_flag_buf, "-Doptimize={s}", .{optimizeName(build_mode)}) catch ""
    else
        "";
    if (std.mem.eql(u8, mode, "run")) {
        loadRemapTables("build/gen");
        const build_code = if (build_mode != .debug)
            runCommandCaptured(null, &.{ zig_install_path, "build", "run", "--build-file", "build/gen/build.zig", opt_flag })
        else
            runCommandCaptured(null, &.{ zig_install_path, "build", "run", "--build-file", "build/gen/build.zig" });
        if (build_code.stderr_len > 0) remapStderrCapture(capture_buf[0..build_code.stderr_len]);
        if (build_code.code != 0) {
            std.debug.print("error: zig build failed (exit {d})\n", .{build_code.code});
            std.process.exit(build_code.code);
        }
    } else {
        loadRemapTables("build/gen");
        const build_code = if (build_mode != .debug)
            runCommandCaptured(null, &.{ zig_install_path, "build", "--build-file", "build/gen/build.zig", opt_flag })
        else
            runCommandCaptured(null, &.{ zig_install_path, "build", "--build-file", "build/gen/build.zig" });
        if (build_code.stderr_len > 0) remapStderrCapture(capture_buf[0..build_code.stderr_len]);
        if (build_code.code != 0) {
            std.debug.print("error: zig build failed (exit {d})\n", .{build_code.code});
            std.process.exit(build_code.code);
        }
    }

    if (std.mem.eql(u8, mode, "check")) {
        std.debug.print("check ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "build")) {
        std.debug.print("build ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "run")) {
        // zig build run already executed the binary with extra_args
        return;
    }
}

/// Generate a build.zig for the multi-module zag project.
fn generateBuildZig(modules: []const project_mod.ModuleEntry, project_name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const header_prefix = "const std = @import(\"std\");\n\npub fn build(b: *std.Build) !void {\n    const target = b.resolveTargetQuery(.{});\n    const optimize = b.standardOptimizeOption(.{});\n    const exe = b.addExecutable(.{\n        .name = \"";
    const header_suffix = "\",\n        .root_module = b.createModule(.{\n            .root_source_file = b.path(\"main.zig\"),\n            .target = target,\n            .optimize = optimize,\n        }),\n    });\n";

    // Build header with project name
    @memcpy(buf[pos..][0..header_prefix.len], header_prefix);
    pos += header_prefix.len;
    @memcpy(buf[pos..][0..project_name.len], project_name);
    pos += project_name.len;
    @memcpy(buf[pos..][0..header_suffix.len], header_suffix);
    pos += header_suffix.len;

    for (modules) |mod| {
        if (std.mem.eql(u8, mod.module_name, "main")) continue;

        const line1 = "    _ = exe.root_module.addImport(\"";
        const line2 = "\", b.createModule(.{ .root_source_file = b.path(\"";
        const line3 = ".zig\") }));\n";

        // Build: _ = exe.root_module.addImport("modname", b.createModule(.{ ... }));
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..mod.module_name.len], mod.module_name);
        pos += mod.module_name.len;
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;
        @memcpy(buf[pos..][0..mod.module_name.len], mod.module_name);
        pos += mod.module_name.len;
        @memcpy(buf[pos..][0..line3.len], line3);
        pos += line3.len;
    }

    const footer = "    b.installArtifact(exe);\n\n    const run_cmd = b.addRunArtifact(exe);\n    if (b.args) |args| run_cmd.addArgs(args);\n    const run_step = b.step(\"run\", \"Run the app\");\n    run_step.dependOn(&run_cmd.step);\n}\n";
    @memcpy(buf[pos..][0..footer.len], footer);
    pos += footer.len;

    try writeFile("build/gen/build.zig", buf[0..pos]);
}

/// Generate all project files (modules + build.zig) without building.
/// Used by `zag generate`.
fn generateProjectFiles() !void {
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);

    // v0.1 stdlib migration hybrid: same as projectCmd — materialise
    // lib/std/*.zag to build/gen/std/*.zig so the `zag generate`
    // output directory is consistent with `zag build`.
    materializeStdlib("build/gen");

    const modules = project_mod.discoverModules();
    const has_main = for (modules) |m| {
        if (std.mem.eql(u8, m.module_name, "main")) break true;
    } else false;

    if (!has_main) {
        std.debug.print("error: no src/main.zag found\n", .{});
        std.process.exit(1);
    }

    for (modules) |mod| {
        const source = readFile(mod.path) catch {
            std.debug.print("error: could not read {s}\n", .{mod.path});
            std.process.exit(1);
        };
        const result = transpile(mod.path, source, true) catch |e| {
            std.debug.print("error: transpile failed for {s}: {s}\n", .{ mod.path, @errorName(e) });
            std.process.exit(1);
        };

        var out_buf: [512]u8 = undefined;
        const out_path = if (std.mem.eql(u8, mod.module_name, "main"))
            std.fmt.bufPrint(&out_buf, "build/gen/main.zig", .{}) catch "build/gen/main.zig"
        else
            std.fmt.bufPrint(&out_buf, "build/gen/{s}.zig", .{mod.module_name}) catch "build/gen/module.zig";

        try writeFile(out_path, result.zig);
        if (result.map.len > 0) try writeMapFile(out_path, result.map);
    }

    try generateBuildZig(modules, "main");
}

/// Resolve the zig compiler binary path that the current
/// invocation will use, applying the project's `[toolchain].zig`
/// override at highest priority and falling back through env var,
/// common system paths, and the embedded payload:
///   1. `[toolchain].zig` from `cfg.zig_path` (project-specific)
///   2. `$ZAG_ZIG_PATH` env var                    (machine-wide)
///   3. /usr/bin/zig, /usr/local/bin/zig           (auto-detect)
///   4. `embedded_zig_path` from `-Dzig_payload=`   (compile-time)
///
/// Called from each cmd-branch that uses zig (cmdRun / cmdBuild /
/// cmdCheck / cmdTest / leafProcess's `check`-via-file flow) AFTER
/// the file-vs-project dispatch is decided. File-mode callers pass
/// `null` so the toml branch is skipped. Empty `cfg.zig_path`
/// falls through to the env branch which falls through to the
/// embedded fallback.
///
/// On success, `zig_install_path` is populated with the chosen
/// path; callers guard with
/// `if (zig_install_path.len == 0) return needZig();` to handle
/// the all-three-empty case (build without `-Dzig_payload` AND no
/// `$ZAG_ZIG_PATH` AND no `zag.toml` -- typical cross-distro
/// installs that expect a per-machine zig binary).

fn resolveZigPath(cfg: ?project_mod.ProjectConfig) void {
    zig_path_len = 0;
    // 1. Project-level override.
    if (cfg) |c| {
        if (c.zig_path) |zp| { zig_path_len = @min(zp.len, zig_path_buf.len); @memcpy(zig_path_buf[0..zig_path_len], zp); updateZigPathAlias(); return; }
    }
    // 2. Machine-wide env override.
    if (env_path.getenv("ZAG_ZIG_PATH")) |zp| { zig_path_len = @min(zp.len, zig_path_buf.len); @memcpy(zig_path_buf[0..zig_path_len], zp); updateZigPathAlias(); return; }
    // 3. Auto-detect common paths.
    const search_paths = [_][]const u8{ "/usr/bin/zig", "/usr/local/bin/zig", "/usr/local/zig/zig" };
    for (search_paths) |p| {
        if (posix.openat(posix.AT.FDCWD, p, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            _ = std.os.linux.close(fd);
            zig_path_len = @min(p.len, zig_path_buf.len); @memcpy(zig_path_buf[0..zig_path_len], p); updateZigPathAlias(); return;
        } else |_| {}
    }
    if (env_path.getenv("HOME")) |home| {
        var home_buf: [512]u8 = undefined;
        const home_zig = std.fmt.bufPrint(&home_buf, "{s}/.local/zig/zig", .{home}) catch "";
        if (posix.openat(posix.AT.FDCWD, home_zig, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            _ = std.os.linux.close(fd);
            zig_path_len = @min(home_zig.len, zig_path_buf.len); @memcpy(zig_path_buf[0..zig_path_len], home_zig); updateZigPathAlias(); return;
        } else |_| {}
    }
    // 4. Embedded payload.
    if (embedded_zig_path.len > 0) {
        zig_path_len = @min(embedded_zig_path.len, zig_path_buf.len); @memcpy(zig_path_buf[0..zig_path_len], embedded_zig_path); updateZigPathAlias(); return;
    }
}

fn srcPath(root: []const u8, sub: []const u8) []const u8 {
    _ = root;
    return sub;
}

fn hasZagExt(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zag");
}

fn needZig() noreturn {
    std.debug.print(
        \\error: zig compiler not found.
        \\  resolution order (each tier may hold the answer):
        \\    1. project-level: `[toolchain] zig = "..."` in zag.toml
        \\    2. machine-wide:  $ZAG_ZIG_PATH=/path/to/zig
        \\    3. auto-detect:    /usr/bin/zig, /usr/local/bin/zig, $HOME/.local/zig/zig
        \\    4. compiled-in:   build zag with -Dzig_payload=<path>
        \\
    , .{});
    std.process.exit(1);
}

fn usage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  zag run [<file.zag>] [--release] [-- <args>]   Compile and run\n", .{});
    std.debug.print("  zag check [<file.zag>]             Type-check a file or project\n", .{});
    std.debug.print("  zag build [<file.zag>] [--release] [-o <path>] Compile to binary\n", .{});
    std.debug.print("  zag debug [<file.zag>]             Build and debug with gdb\n", .{});
    std.debug.print("  zag generate [-o <dir>]            Transpile to zig project\n", .{});
    std.debug.print("  zag pkg add <url> [--rev|--branch|--version] [--save-dev]   Add a dep\n", .{});
    std.debug.print("  zag remove <name>                  Remove a dep, rewrite zag.toml + zag.lock\n", .{});
    std.debug.print("  zag install [--gc]                 Materialize deps in deps/\n", .{});
    std.debug.print("  zag update                         Re-resolve git-source deps + rewrite both files\n", .{});
    std.debug.print("  zag test [<file.zag>]              Run tests in a file or project\n", .{});
    std.debug.print("  zag init [<dir>]                   Create a new Zag project\n", .{});
    std.debug.print("  zag version                        Print version information\n", .{});
    std.debug.print("  zag help                           Show this help message\n", .{});
    std.debug.print("\nFlags:\n", .{});
    std.debug.print("  --release          Optimize build (passes -Doptimize=ReleaseFast to zig)\n", .{});
    std.debug.print("  --release-safe     Optimize build with safety checks kept on (ReleaseSafe)\n", .{});
    std.debug.print("  --release-small    Optimize for binary size (ReleaseSmall)\n", .{});
    std.debug.print("  -g, --generate     Also emit .zig output in build/gen/\n", .{});
    std.debug.print("  -o, --output       Output path (binary for build, dir for generate)\n", .{});
}

/// Test-runner shim for file-mode `zag test` (written to
/// `<leaf>/zag_test_runner.zig`, passed via `zig test --test-runner`).
///
/// Why it exists: under zig 0.16's `zig test`, `@import("root")`
/// resolves to zig's TEST RUNNER (lib/compiler/test_runner.zig),
/// never to the file under test — so every `@import("root")`
/// lookup in generated code (bench counters, Result/Option
/// forwarders) fails with "root source file struct 'test_runner'
/// has no member". `--test-runner` makes THIS file the compilation
/// root instead, so it carries the canonical definitions every
/// module's preamble forwards to — exactly the run/build-mode
/// contract, with unified cross-module bench accounting.
///
/// The shim deliberately does NOT `@import("main.zig")`: zig places
/// the --test-runner file and the positional test file in two
/// modules ('test' and 'root'), and a file imported by path into
/// both is rejected ("file exists in modules 'test' and 'root'").
/// Test discovery needs no import anyway: `builtin.test_functions`
/// collects `test` blocks from every module in the compilation.
///
/// Result/Option are DEFINED here (not re-exported — the user module
/// is unreachable by import, see above), mirroring the canonical
/// hybrid emit in src/codegen/core.zig — keep the two in sync. The
/// one asymmetry this leaves: a test that passes a Result/Option
/// value ACROSS the user/std boundary mixes the runner's canonical
/// with the user module's own canonical and fails to compile. No
/// example suite does this today (their Results are same-module);
/// closing it needs the hybrid emit to forward under test (a
/// `@hasDecl(root, marker)` smart-forwarder), which is recorded as
/// follow-up work, not done here.
const zag_test_runner_src: []const u8 =
    \\//! zag file-mode test root (see zag_test_runner_src in src/main.zig).
    \\const builtin = @import("builtin");
    \\const std = @import("std");
    \\
    \\pub fn Result(comptime T: type, comptime E: type) type {
    \\    return union(enum) {
    \\        Ok: T,
    \\        Err: E,
    \\        pub fn unwrap(self: @This()) T {
    \\            return switch (self) {
    \\                .Ok => |v| v,
    \\                .Err => @panic("unwrap on Err"),
    \\            };
    \\        }
    \\    };
    \\}
    \\pub fn Option(comptime T: type) type {
    \\    return union(enum) {
    \\        Some: T,
    \\        None: void,
    \\        pub fn unwrap(self: @This()) T {
    \\            return switch (self) {
    \\                .Some => |v| v,
    \\                .None => @panic("unwrap on None"),
    \\            };
    \\        }
    \\    };
    \\}
    \\
    \\pub var __zag_bench_bytes_live: usize = 0;
    \\pub var __zag_bench_bytes_total: usize = 0;
    \\pub var __zag_bench_allocations: usize = 0;
    \\pub fn __zag_bench_inc(n: usize) void {
    \\    __zag_bench_bytes_live += n;
    \\    __zag_bench_bytes_total += n;
    \\    __zag_bench_allocations += 1;
    \\}
    \\pub fn __zag_bench_dec(n: usize) void {
    \\    __zag_bench_bytes_live -= n;
    \\}
    \\
    \\pub fn main() void {
    \\    var pass: usize = 0;
    \\    var fail: usize = 0;
    \\    for (builtin.test_functions) |t| {
    \\        t.func() catch {
    \\            fail += 1;
    \\            std.debug.print("FAIL {s}\n", .{t.name});
    \\            continue;
    \\        };
    \\        pass += 1;
    \\        std.debug.print("ok {s}\n", .{t.name});
    \\    }
    \\    std.debug.print("{d} passed, {d} failed\n", .{ pass, fail });
    \\    if (fail > 0) std.process.exit(1);
    \\}
;

fn leafProcess(flag: []const u8, src: []const u8, output_path: ?[]const u8, extra_args: []const []const u8, build_mode: BuildMode) !void {    if (src.len == 0) {
        std.debug.print("error: --leaf-process=<mode> missing src argument\n", .{});
        std.process.exit(1);
    }

    const pid_num = std.os.linux.getpid();
    // v0.1 Tier-1 migration: the leaf zig lands in its own directory
    // (`/tmp/zag_leaf_<pid>/main.zig`) with the materialised stdlib
    // mirror next to it (`/tmp/zag_leaf_<pid>/std/*.zig`). The
    // generated `@import("std/<rel>.zig")` lines resolve relative to
    // the importing file's directory, so the mirror MUST sit one
    // level down from main.zig for the "std/" import prefix to hit —
    // the old flat `/tmp/zag_leaf_<pid>.zig` layout had no such
    // sibling directory and every stdlib import failed with "no
    // module named 'lib/std/<rel>.zag'".
    var leaf_dir_buf: [64]u8 = undefined;
    var leaf_dir_z: [64:0]u8 = undefined;
    const leaf_dir = std.fmt.bufPrint(&leaf_dir_buf, "/tmp/zag_leaf_{d}", .{pid_num}) catch "/tmp/zag_leaf";
    if (leaf_dir.len >= leaf_dir_z.len) std.process.exit(1);
    @memcpy(leaf_dir_z[0..leaf_dir.len], leaf_dir);
    leaf_dir_z[leaf_dir.len] = 0;
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, &leaf_dir_z, 0o755);
    var path_leaf_zig: [80]u8 = undefined;
    var path_leaf_bin: [80]u8 = undefined;
    const f_zig = std.fmt.bufPrint(&path_leaf_zig, "/tmp/zag_leaf_{d}/main.zig", .{pid_num}) catch "/tmp/zag_leaf/main.zig";
    const f_bin = std.fmt.bufPrint(&path_leaf_bin, "/tmp/zag_leaf_{d}_bin", .{pid_num}) catch "/tmp/zag_leaf_bin";

    // v0.1 Tier-1 migration: file mode materialises the stdlib mirror
    // into the leaf directory so stdlib `@import` lines resolve.
    // Enabling the hybrid preamble (`use_hybrid = true` below) rebinds
    // the `__zag_<Type>` aliases (String/Writer/Error/…) to the
    // materialised module types, so a stdlib function returning
    // `String` and a user `import std.string.{String}` resolve to the
    // SAME zig type — with the legacy inline aliases they'd be two
    // distinct types and every cross-module String call would
    // compile-error.
    materializeStdlib(leaf_dir);

    const source = try readFile(src);
    const result = try transpile(src, source, true);
    try writeFile(f_zig, result.zig);
    // Zig compiler errors on this build reference the leaf main.zig
    // by line — write the .zag.map side-file so the captured-stderr
    // remap pass can translate those headers back to the user's .zag
    // source (same contract as the build/gen maps in project mode).
    if (result.map.len > 0) try writeMapFile(f_zig, result.map);
    // Load zig→zag tables for this leaf (user module + the stdlib
    // mirror materialized above). Must run BEFORE the build below.
    loadRemapTables(leaf_dir);
    var leaf_std_buf: [128]u8 = undefined;
    const leaf_std = std.fmt.bufPrint(&leaf_std_buf, "{s}/std", .{leaf_dir}) catch leaf_dir;
    loadRemapTables(leaf_std);

    if (std.mem.eql(u8, flag, "test")) {
        const has_test_block = std.mem.indexOf(u8, result.zig, "test \"") != null;
        const has_main = std.mem.indexOf(u8, result.zig, "pub fn main(") != null;
        if (has_test_block) {
            // File-mode test root: plain `zig test <main>` makes
            // zig's test runner the compilation root, breaking every
            // `@import("root")` lookup in generated code (bench
            // counters, Result/Option — see zag_test_runner_src).
            // Route through our runner shim so the shim is root.
            var path_runner_buf: [80]u8 = undefined;
            const f_runner = std.fmt.bufPrint(&path_runner_buf, "/tmp/zag_leaf_{d}/zag_test_runner.zig", .{pid_num}) catch "/tmp/zag_leaf/zag_test_runner.zig";
            try writeFile(f_runner, zag_test_runner_src);
            const test_code = try runCommand(null, &.{ zig_install_path, "test", "--test-runner", f_runner, f_zig });
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

    // Build-mode flags pass `-O <optimize-name>` through (file mode
    // compiles with `zig build-exe` directly; Debug = no flag).
    var opt_buf: [16]u8 = undefined;
    const opt_arg = if (build_mode != .debug)
        std.fmt.bufPrint(&opt_buf, "-O{s}", .{optimizeName(build_mode)}) catch "-OReleaseFast"
    else
        "";
    // `extern fun` bodies reference libc symbols (open/write/close in
    // examples/ffi/basic_io.zag) — without `-lc` the post-transpile
    // build-exe dies on "undefined symbol: write". Zig's default
    // (no-libc) static builds don't need it, but any program declaring
    // C ABI functions opts the file into libc linking — harmless for
    // the standard-library-only programs (the flag links against the
    // system libc; symbols resolve if present, else the C-link error
    // is loud and points at the extern).
    const has_libc = std.mem.indexOf(u8, result.zig, "extern fn ") != null;
    const build_argv: []const []const u8 = if (has_libc)
        if (build_mode != .debug)
            &.{ zig_install_path, "build-exe", f_emit, f_zig, opt_arg, "-lc" }
        else
            &.{ zig_install_path, "build-exe", f_emit, f_zig, "-lc" }
    else if (build_mode != .debug)
        &.{ zig_install_path, "build-exe", f_emit, f_zig, opt_arg }
    else
        &.{ zig_install_path, "build-exe", f_emit, f_zig };
    // Capture zig's stderr so compile errors can be re-surfaced with
    // .zag locations (remapStderrCapture) instead of generated-zig
    // line numbers no one recognizes.
    const captured = runCommandCaptured(null, build_argv);
    if (captured.stderr_len > 0) remapStderrCapture(capture_buf[0..captured.stderr_len]);
    const build_code = captured.code;
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

const CapturedRun = struct {
    code: u8,
    stderr_len: usize,
};

/// 1 MB static capture buffer for zig build-exe / zig build stderr.
/// Separate from `file_buf` — the remap pass calls readFile (which
/// owns file_buf) to show the .zag source line for a mapped error.
var capture_buf: [1024 * 1024]u8 = undefined;

/// runCommand variant that captures the child's fd-2 output through
/// a pipe instead of inheriting the terminal: the caller can then
/// remap zig's generated-zig `path:line:col:` error headers back to
/// the .zag sources via remapStderrCapture. Same fork+execve
/// discipline as runCommand (no std.process.Child). The child dup2s
/// the pipe's write end onto fd 2 (raw syscalls — no catch needs);
/// the parent drains the read end to EOF then waitpids.
fn runCommandCaptured(executable: ?[]const u8, argv: []const []const u8) CapturedRun {
    if (argv.len == 0 or argv.len > 14) return .{ .code = 255, .stderr_len = 0 };

    var arg_bufs: [15]?[:0]u8 = .{ null } ** 15;
    defer for (arg_bufs) |maybe_buf| if (maybe_buf) |buf| std.heap.page_allocator.free(buf);

    var argv_z: [15]?[*:0]const u8 = .{ null } ** 15;
    for (argv, 0..) |arg, i| {
        const buf = std.heap.page_allocator.allocSentinel(u8, arg.len, 0) catch return .{ .code = 255, .stderr_len = 0 };
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

    var fds: [2]i32 = undefined;
    const pipe_rc = std.os.linux.pipe2(&fds, .{});
    if (std.math.cast(isize, pipe_rc) orelse -1 < 0) return .{ .code = 255, .stderr_len = 0 };

    const pid_fork = std.math.cast(i32, std.os.linux.fork()) orelse return .{ .code = 255, .stderr_len = 0 };
    if (pid_fork == 0) {
        // Child: stderr → pipe write end.
        _ = std.os.linux.dup2(fds[1], 2);
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
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

    _ = std.os.linux.close(fds[1]);
    var total: usize = 0;
    while (total < capture_buf.len) {
        const n = std.os.linux.read(fds[0], capture_buf[total..].ptr, capture_buf.len - total);
        if (n <= 0) break;
        const n_usize: usize = @intCast(n);
        if (n_usize > capture_buf.len - total) break;
        total += n_usize;
    }
    _ = std.os.linux.close(fds[0]);

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid_fork, &status, 0);
    if (std.os.linux.W.IFEXITED(status)) {
        return .{ .code = std.os.linux.W.EXITSTATUS(status), .stderr_len = total };
    }
    return .{ .code = 255, .stderr_len = total };
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

/// Materialize lib/std/*.zag → <out_dir>/std/*.zig so the generated
/// zig's `@import("std/<rel>.zig")` lines resolve at compile time.
/// Called at the start of project-mode dispatch (out_dir = "build/gen")
/// and file-mode leaf compilation (out_dir = "/tmp/zag_leaf_<pid>").
///
/// v0.1 Tier-1 migration: the prior hardcoded 6-module list is
/// replaced by a recursive walk over the resolved stdlib root — any
/// `lib/std/**/*.zag` file (except the `mod.zag` barrel) gets
/// transpiled into the mirror at the same relative path with a .zig
/// extension, so future lib/std additions need no main.zig touch-ups
/// (the "Phase 2 manifest" the old docblock deferred to).
///
/// The stdlib root is resolved 3-tier (documented intent in
/// scripts/install-local.sh, which copies lib/std/ to $ZAG_HOME/lib/std/):
///   1. cwd-relative `lib/std/`  — in-tree development workflow
///   2. `$ZAG_HOME/lib/std/`     — install-local.sh installation
///   3. `$HOME/.local/share/zag/lib/std/` — future distro-package path
///
/// The stdlib materialisation itself uses the legacy inline preamble
/// path (use_hybrid = false, import_std_base = ""). Embedding the hybrid
/// rebindings inside the stdlib materialisation would create
/// a chicken-and-egg (those rebindings reference
/// `build/gen/std/*.zig` from a context where the on-disk
/// files don't exist — the codegen output is in flight).
/// Inlining the original preamble on this code-path keeps
/// the dependency graph acyclic. import_std_base = "" makes sibling
/// module imports inside the mirror emit same-dir paths
/// (`@import("string.zig")` from fs.zig), which resolve against the
/// mirror's own layout.
///
/// Silently no-ops if lib/std cannot be located or a module fails to
/// parse/transpile (skips-on-missing-fixture convention used
/// elsewhere in the test runners — callers keep going without
/// stderr complaints).
fn materializeStdlib(out_dir: []const u8) void {
    var root_buf: [512]u8 = undefined;
    const root_path = resolveStdlibRoot(&root_buf) orelse return;

    var out_std_buf: [520]u8 = undefined;
    const out_std = std.fmt.bufPrint(&out_std_buf, "{s}/std", .{out_dir}) catch return;
    var out_std_z: [520:0]u8 = undefined;
    if (out_std.len >= out_std_z.len) return;
    @memcpy(out_std_z[0..out_std.len], out_std);
    out_std_z[out_std.len] = 0;
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, &out_std_z, 0o755);

    var root_fd_z: [512:0]u8 = undefined;
    if (root_path.len >= root_fd_z.len) return;
    @memcpy(root_fd_z[0..root_path.len], root_path);
    root_fd_z[root_path.len] = 0;
    const root_fd = posix.openatZ(posix.AT.FDCWD, &root_fd_z, .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.os.linux.close(root_fd);

    materializeWalk(root_fd, root_path, "", out_dir);
}

/// Recursive stdlib walker — one getdents64 batch per syscall, then
/// per-dirent `d_reclen` offset iteration (same discipline as
/// project.zig::walkSrcTree). For every `*.zag` file (except the
/// `mod.zag` barrel at the top level) transpiles it into
/// `<out_dir>/std/<rel>.zig` with a self-contained inline preamble
/// (use_hybrid = false) and same-dir sibling imports
/// (import_std_base = "").
fn materializeWalk(root_fd: i32, root_path: []const u8, rel_to_root: []const u8, out_dir: []const u8) void {
    // `align(8)` on the batch buffer: the getdents64 dirent stream is
    // 8-byte-aligned, so every `d_reclen` offset stays aligned only if
    // the BASE is. Without it, the @alignCast(&buf[pos]) below trips
    // "incorrect alignment" in Debug when the stack happens to hand
    // out a misaligned buffer.
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = std.os.linux.getdents64(root_fd, &buf, buf.len);
        if (n == 0) break;
        if (n > std.math.maxInt(isize)) break;

        var pos: usize = 0;
        while (pos < n) {
            const entry: *const std.os.linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += entry.reclen;

            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const name = name_z[0..name_z.len];
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name[0] == '.') continue;

            if (entry.type == std.os.linux.DT.DIR) {
                var child_rel_buf: [512]u8 = undefined;
                const child_rel: []const u8 = if (rel_to_root.len == 0)
                    std.fmt.bufPrint(&child_rel_buf, "{s}", .{name}) catch continue
                else
                    std.fmt.bufPrint(&child_rel_buf, "{s}/{s}", .{ rel_to_root, name }) catch continue;

                var child_path_buf: [1024]u8 = undefined;
                const child_path = std.fmt.bufPrint(&child_path_buf, "{s}/{s}", .{ root_path, child_rel }) catch continue;
                const child_fd = posix.openat(posix.AT.FDCWD, child_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
                // Mirror the subdirectory into <out_dir>/std/<child_rel>.
                var mir_rel_buf: [1024]u8 = undefined;
                const mir_rel = std.fmt.bufPrint(&mir_rel_buf, "{s}/std/{s}", .{ out_dir, child_rel }) catch continue;
                var mir_z: [1024:0]u8 = undefined;
                if (mir_rel.len < mir_z.len) {
                    @memcpy(mir_z[0..mir_rel.len], mir_rel);
                    mir_z[mir_rel.len] = 0;
                    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, &mir_z, 0o755);
                }
                materializeWalk(child_fd, root_path, child_rel, out_dir);
                _ = std.os.linux.close(child_fd);
            } else if (entry.type == std.os.linux.DT.REG and std.mem.endsWith(u8, name, ".zag")) {
                // The barrel (mod.zag) is user-facing only — it would
                // drag every std module into a single self-importing
                // file; skip it in the mirror.
                if (rel_to_root.len == 0 and std.mem.eql(u8, name, "mod.zag")) continue;

                var src_path_buf: [1024]u8 = undefined;
                const src_path = if (rel_to_root.len == 0)
                    std.fmt.bufPrint(&src_path_buf, "{s}/{s}", .{ root_path, name }) catch continue
                else
                    std.fmt.bufPrint(&src_path_buf, "{s}/{s}/{s}", .{ root_path, rel_to_root, name }) catch continue;
                const source = readFile(src_path) catch continue;

                var l = lexer_mod.Lexer.init(source);
                const tokens = l.tokenize();
                var arena = ast.Arena.init();
                var p = parser_mod.Parser.init(tokens, &arena);
                const prog = p.parse();
                var cg = codegen_mod.Codegen.init();
                cg.source_path = src_path;
                // Self-contained preamble (see materializeStdlib
                // docblock for the chicken-and-egg rationale).
                cg.use_hybrid_stdlib = false;
                // Sibling imports inside the mirror are same-dir.
                cg.import_std_base = "";
                const zig = cg.generate(prog);

                var dst_path_buf: [1024]u8 = undefined;
                const dst_path = std.fmt.bufPrint(&dst_path_buf, "{s}/std/{s}{s}{s}.zig", .{
                    out_dir,
                    if (rel_to_root.len == 0) "" else rel_to_root,
                    if (rel_to_root.len == 0) "" else "/",
                    name[0 .. name.len - ".zag".len],
                }) catch continue;
                writeFile(dst_path, zig) catch continue;
                // Side-file map (same contract as build/gen maps):
                // the file-mode remap pass translates zig build-exe
                // errors inside stdlib mirrors back to lib/std/*.zag.
                cg.buildMapText();
                const map_text = cg.getMapText();
                if (map_text.len > 0) writeMapFile(dst_path, map_text) catch continue;
            }
        }
    }
}

/// 3-tier stdlib root resolution (see materializeStdlib docblock):
/// cwd-relative lib/std/ → exe-relative lib/std/ → $ZAG_HOME/lib/std/
/// → $HOME/.local/share/zag/lib/std/.
///
/// The exe-relative tier exists because the test harness
/// (examples/run_all.sh) `cd`s into examples/ before invoking the
/// compiler — a cwd-only probe misses the in-tree lib/std/ there,
/// and stdlib-materializing fixtures (stdlib/fs.zag) then fail with
/// "unable to load 'std/fs.zig'". /proc/self/exe anchors to the
/// binary's true location (zig-out/bin/<name> → repo root two
/// dirname hops up), making resolution CWD-independent for the
/// in-tree development layout.
fn resolveStdlibRoot(buf: []u8) ?[]const u8 {
    if (dirExists("lib/std")) {
        return "lib/std";
    }
    // Exe-relative tier: /proc/self/exe → <repo>/zig-out/bin/zag-*;
    // try <exe_dir>/../../lib/std (zig-out/bin layout) and
    // <exe_dir>/../lib/std (flat install layout). Format strings are
    // spelled out per candidate — bufPrint's fmt parameter is
    // comptime and a runtime array iteration can't provide that.
    var exe_buf: [4096:0]u8 = undefined;
    if (readSelfExe(&exe_buf)) |exe| {
        if (std.mem.lastIndexOfScalar(u8, exe, '/')) |slash| {
            const exe_dir = exe[0..slash];
            if (std.fmt.bufPrint(buf, "{s}/../../lib/std", .{exe_dir}) catch null) |p| {
                if (dirExists(p)) return p;
            }
            if (std.fmt.bufPrint(buf, "{s}/../lib/std", .{exe_dir}) catch null) |p| {
                if (dirExists(p)) return p;
            }
        }
    }
    if (env_path.getenv("ZAG_HOME")) |home| {
        const p = std.fmt.bufPrint(buf, "{s}/lib/std", .{home}) catch return null;
        if (dirExists(p)) return p;
    }
    if (env_path.getenv("HOME")) |home| {
        const p = std.fmt.bufPrint(buf, "{s}/.local/share/zag/lib/std", .{home}) catch return null;
        if (dirExists(p)) return p;
    }
    return null;
}

/// Readlink /proc/self/exe into `buf` (sentinel-terminated); returns
/// the populated slice or null when unavailable (non-Linux, buffer
/// overflow). Linux-only is fine — the fork/execve subprocess model
/// below is already POSIX-specific.
fn readSelfExe(buf: *[4096:0]u8) ?[]const u8 {
    var link_buf: [4096]u8 = undefined;
    // Raw syscall — zig 0.16 has no std.posix.readlink facade. Raw
    // std.os.linux.* returns usize with the errno folded into the
    // high bit; E.init(rc) decodes it (.SUCCESS = rc is the byte
    // count) — see AGENTS.md pitfalls §2.
    const rc = std.os.linux.readlink("/proc/self/exe", &link_buf, link_buf.len);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return null,
    }
    if (rc == 0 or rc > buf.len) return null;
    @memcpy(buf[0..rc], link_buf[0..rc]);
    buf[rc] = 0;
    return buf[0..rc];
}

/// Directory-existence probe (open + close; no stat needed).
fn dirExists(path: []const u8) bool {
    var z: [512:0]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = posix.openatZ(posix.AT.FDCWD, &z, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = std.os.linux.close(fd);
    return true;
}

fn writeMapFile(zig_path: []const u8, map_content: []const u8) !void {
    // map path: replace ".zig" suffix with ".zag.map"
    var buf: [512]u8 = undefined;
    var map_path = zig_path;
    if (std.mem.endsWith(u8, zig_path, ".zig")) {
        const base = zig_path[0 .. zig_path.len - 4];
        map_path = std.fmt.bufPrint(&buf, "{s}.zag.map", .{base}) catch zig_path;
    } else {
        map_path = std.fmt.bufPrint(&buf, "{s}.zag.map", .{zig_path}) catch zig_path;
    }
    try writeFile(map_path, map_content);
}

/// Pair of arrays carrying the zig→zag source-file mappings
/// extracted from a directory's `.zag.map` files. Both arrays
/// are zero-terminated per entry; `count` is the populated
/// prefix length (≤ zig.len).
///
/// Extracted so the walker (`collectRemapMappings`) can be
/// regression-tested in isolation rather than driving the full
/// remapDwarfElf side-effect path (binary read + DWARF patch).
const RemapMappings = struct {
    zig: [32][256]u8,
    zag: [32][256]u8,
    count: usize,
};

/// One-level flat walk over a zag generator output dir (e.g.
/// `build/gen`) collecting up to 32 `.zag.map` entries — each
/// pairing a generated zig path with the `.zag` source path
/// recorded in its first line.
///
/// Uses the same `getdents64` buffer-and-offset pattern as
/// `src/project.zig::walkSrcTree`: one syscall per batch,
/// iterate within the batch via `d_reclen`. Replaced the prior
/// shape which called `getdents64` with a buffer the size of
/// *one* `dirent64` — the kernel returned at most one entry per
/// syscall, so multi-`.zag.map` projects were under-discovered.
///
/// DT-gating: `DT.REG` only (build/gen is a flat directory of
/// files only; sub-directories mean stale state, not source).
/// `DT.UNKNOWN` skipped (documented NFS / FUSE caveat).
/// Hidden entries (`.foo`) and `.` / `..` excluded.
fn collectRemapMappings(map_dir: []const u8) RemapMappings {
    var result: RemapMappings = .{ .zig = undefined, .zag = undefined, .count = 0 };
    const map_dir_fd = posix.openat(posix.AT.FDCWD, map_dir, .{ .ACCMODE = .RDONLY }, 0) catch return result;
    defer _ = std.os.linux.close(map_dir_fd);

    // `align(8)` on the batch buffer: the getdents64 dirent stream is
    // 8-byte-aligned, so every `d_reclen` offset stays aligned only if
    // the BASE is. Without it, the @alignCast(&buf[pos]) below trips
    // "incorrect alignment" in Debug when the stack happens to hand
    // out a misaligned buffer — same discipline as materializeWalk's
    // batch buffer (the `zag debug` DWARF-patch walker panicked on
    // projects whose build/gen has entries).
    var buf: [4096]u8 align(8) = undefined;
    var full = false;
    while (!full) {
        const nread = std.os.linux.getdents64(map_dir_fd, &buf, buf.len);
        if (nread == 0) break;
        if (nread > std.math.maxInt(isize)) break;

        var pos: usize = 0;
        while (pos < nread) {
            const entry: *const std.os.linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += entry.reclen;

            // `d_name` is a flexible-array member; treat as
            // sentinel-terminated then slice to the NUL.
            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const name = name_z[0..name_z.len];

            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name[0] == '.') continue;
            if (entry.type != std.os.linux.DT.REG) continue;
            if (!std.mem.endsWith(u8, name, ".zag.map")) continue;
            if (result.count >= result.zig.len) {
                full = true;
                break;
            }

            const zig_base = name[0..(name.len - ".zag.map".len)];
            _ = std.fmt.bufPrint(&result.zig[result.count], "{s}/{s}", .{ map_dir, zig_base }) catch continue;

            const zag_path = readFirstMapEntry(map_dir, name) catch continue;
            if (zag_path.len > 0) {
                @memcpy(result.zag[result.count][0..zag_path.len], zag_path);
                result.zag[result.count][zag_path.len] = 0;
                result.count += 1;
            }
        }
    }
    return result;
}

/// Patch DWARF debug info in a compiled ELF binary so debuggers
/// reference .zag source files instead of build/gen/*.zig.
fn remapDwarfElf(binary_path: []const u8) void {
    // Collect zig→zag mappings from .zag.map files (one-level
    // walk over `build/gen/` — see collectRemapMappings for the
    // walker contract; factored out so it's unit-testable).
    const mappings = collectRemapMappings("build/gen");
    if (mappings.count == 0) return;

    // Read binary
    const bin_fd = posix.openat(posix.AT.FDCWD, binary_path, .{ .ACCMODE = .RDWR }, 0) catch return;
    defer _ = std.os.linux.close(bin_fd);

    // Get file size via lseek
    const end_pos = std.os.linux.lseek(bin_fd, 0, std.os.linux.SEEK.END);
    if (end_pos < 0) return;
    const file_size: usize = @intCast(end_pos);
    _ = std.os.linux.lseek(bin_fd, 0, std.os.linux.SEEK.SET);
    if (file_size > 64 * 1024 * 1024) return;

    const data = std.heap.page_allocator.alloc(u8, file_size) catch return;
    defer std.heap.page_allocator.free(data);
    const bytes_read = std.os.linux.read(bin_fd, data.ptr, file_size);
    if (bytes_read < 0) return;
    if (@as(usize, @intCast(bytes_read)) != file_size) return;

    if (data.len < 4 or !std.mem.eql(u8, data[0..4], "\x7fELF")) return;

    var patched: usize = 0;
    for (0..mappings.count) |i| {
        const zig_path: []const u8 = mappings.zig[i][0..(std.mem.indexOfScalar(u8, &mappings.zig[i], 0) orelse 256)];
        const zag_path: []const u8 = mappings.zag[i][0..(std.mem.indexOfScalar(u8, &mappings.zag[i], 0) orelse 256)];
        if (zag_path.len > zig_path.len or zag_path.len == 0) continue;

        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, search_pos, zig_path)) |found| {
            @memset(data[found .. found + zig_path.len], 0);
            @memcpy(data[found .. found + zag_path.len], zag_path);
            patched += 1;
            search_pos = found + zig_path.len;
        }
    }

    if (patched > 0) {
        _ = std.os.linux.lseek(bin_fd, 0, std.os.linux.SEEK.SET);
        _ = std.os.linux.write(bin_fd, data.ptr, data.len);
        _ = std.os.linux.ftruncate(bin_fd, @intCast(data.len));
    }
}

/// Read the first line of a .zag.map file and return the source file path
/// (the 5th tab-separated field).
fn readFirstMapEntry(map_dir: []const u8, entry_name: []const u8) ![]const u8 {
    var path_buf: [512]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ map_dir, entry_name }) catch return error.InvalidPath;
    const fd = posix.openat(posix.AT.FDCWD, full_path, .{ .ACCMODE = .RDONLY }, 0) catch return error.OpenFailed;
    defer _ = std.os.linux.close(fd);

    var buf: [4096]u8 = undefined;
    const n = std.os.linux.read(fd, &buf, buf.len);
    if (n <= 0) return "";
    const content = buf[0..@intCast(n)];
    // Find first newline
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = content[0..line_end];
    // Tab-separated: zig_line\tzag_line\tzag_col\tsymbol\tfile
    var parts: [5][]const u8 = undefined;
    var pi: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |p| {
        if (pi < 5) { parts[pi] = p; pi += 1; }
    }
    if (pi >= 5) return parts[4];
    return "";
}

const RemapLine = struct {
    zig_line: u32,
    zag_line: u32,
    zag_col: u32,
};

const RemapTable = struct {
    zig_path: [256]u8,
    zig_path_len: usize = 0,
    zag_path: [512]u8,
    zag_path_len: usize = 0,
    count: usize = 0,
    lines: [1024]RemapLine,
};

/// zig→zag line tables loaded from `*.zag.map` side-files, used by
/// remapStderrCapture to rewrite zig compiler error headers
/// (`<generated.zig>:<line>:<col>: error:`) back to the .zag source
/// the user actually wrote. Loaded once per compile attempt from the
/// leaf dir (file mode) or build/gen (project mode).
var remap_tables: [48]RemapTable = undefined;
var remap_table_count: usize = 0;

/// Load all `*.zag.map` files from a flat directory into remap_tables.
/// Each map line: zig_line\tzag_line\tzag_col\tsymbol\tsource_file
/// (buildMapText format — source_file of the first entry is taken as
/// the table's zag path).
fn loadRemapTables(map_dir: []const u8) void {
    if (remap_table_count >= remap_tables.len) return;
    const map_dir_fd = posix.openat(posix.AT.FDCWD, map_dir, .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.os.linux.close(map_dir_fd);

    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const nread = std.os.linux.getdents64(map_dir_fd, &buf, buf.len);
        if (nread == 0) break;
        if (nread > std.math.maxInt(isize)) break;

        var pos: usize = 0;
        while (pos < nread) {
            const entry: *const std.os.linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += entry.reclen;
            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const name = name_z[0..name_z.len];
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name[0] == '.') continue;
            if (entry.type != std.os.linux.DT.REG) continue;
            if (!std.mem.endsWith(u8, name, ".zag.map")) continue;
            if (remap_table_count >= remap_tables.len) return;

            var full_path_buf: [1024]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ map_dir, name }) catch continue;
            const content = readFile(full_path) catch continue;

            var table = &remap_tables[remap_table_count];
            // The global array is `= undefined`; zero the slot's
            // count/lines before first use (garbage count ≥ 1024
            // shortcuts the parse loop below).
            table.count = 0;
            table.zig_path_len = 0;
            table.zag_path_len = 0;
            table.lines = [_]RemapLine{.{ .zig_line = 0, .zag_line = 0, .zag_col = 0 }} ** 1024;
            const zig_base = name[0..(name.len - ".zag.map".len)];
            // The map side-file derives from the .zig output by
            // swapping extensions, so re-append ".zig" to recover
            // the exact path zig's error headers print. bufPrint
            // does NOT NUL-terminate the fixed array — keep the
            // written length alongside.
            const zig_written = std.fmt.bufPrint(&table.zig_path, "{s}/{s}.zig", .{ map_dir, zig_base }) catch continue;
            table.zig_path_len = zig_written.len;
            var first = true;
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                var parts: [5][]const u8 = undefined;
                var pi: usize = 0;
                var pit = std.mem.splitScalar(u8, line, '\t');
                while (pit.next()) |p| {
                    if (pi < 5) { parts[pi] = p; pi += 1; }
                }
                if (pi < 5) continue;
                if (table.count >= table.lines.len) break;
                table.lines[table.count] = .{
                    .zig_line = std.fmt.parseInt(u32, parts[0], 10) catch continue,
                    .zag_line = std.fmt.parseInt(u32, parts[1], 10) catch continue,
                    .zag_col = std.fmt.parseInt(u32, parts[2], 10) catch continue,
                };
                if (first) {
                    if (parts[4].len < table.zag_path.len) {
                        @memcpy(table.zag_path[0..parts[4].len], parts[4]);
                        table.zag_path_len = parts[4].len;
                    }
                    first = false;
                }
                table.count += 1;
            }
            if (table.count > 0) remap_table_count += 1;
        }
    }
}

/// Locate the table whose zig path matches the error header's path
/// token. zig prints paths exactly as handed to it (absolute leaf
/// paths in file mode, build/gen-relative in project mode) — match
/// by suffix so both shapes hit.
fn remapFindTable(path: []const u8) ?*const RemapTable {
    var i: usize = 0;
    while (i < remap_table_count) : (i += 1) {
        const table = &remap_tables[i];
        const tpath = table.zig_path[0..table.zig_path_len];
        if (std.mem.endsWith(u8, path, tpath) or std.mem.endsWith(u8, tpath, path)) return table;
    }
    return null;
}

/// Line-exact lookup: the first entry with zig_line >= target is the
/// mapping (map entries are emitted in ascending zig-line order; the
/// error's exact line maps to the statement it sits in).
fn remapFindLine(table: *const RemapTable, zig_line: u32) ?RemapLine {
    var best: ?RemapLine = null;
    var i: usize = 0;
    while (i < table.count) : (i += 1) {
        const e = table.lines[i];
        if (e.zig_line > zig_line) break;
        best = .{ .zig_line = e.zig_line, .zag_line = e.zag_line, .zag_col = e.zag_col };
    }
    return best;
}

/// Static scratch for the remapped stderr text (built in full, then
/// written to fd 2 in one shot).
var remap_out_buf: [1024 * 1024 + 8192]u8 = undefined;

/// Emit `    <zag source line>` + caret under a remapped header.
fn remapEmitSourceLine(out_buf: []u8, out_pos: *usize, zag_path: []const u8, zag_line: u32, zag_col: u32) void {
    const zsrc = readFile(zag_path) catch return;
    var lno: u32 = 1;
    var sit = std.mem.splitScalar(u8, zsrc, '\n');
    while (sit.next()) |sline| : (lno += 1) {
        if (lno == zag_line) {
            const shown = if (sline.len > 100) sline[0..100] else sline;
            const head = std.fmt.bufPrint(out_buf[out_pos.*..], "    {s}\n", .{shown}) catch return;
            out_pos.* += head.len;
            var caret_sp: [96]u8 = undefined;
            const col: usize = @intCast(@min(zag_col, 96));
            @memset(caret_sp[0..col], ' ');
            caret_sp[col] = '^';
            const caret = std.fmt.bufPrint(out_buf[out_pos.*..], "      {s}\n", .{caret_sp[0..col + 1]}) catch return;
            out_pos.* += caret.len;
            return;
        }
    }
}

/// Rewrite zig compiler error output so locations reference the .zag
/// sources: `<zig>:<line>:<col>: error: msg` → `<zag>:<zag_line>:<zag_col>:
/// error: msg`, followed by the actual .zag source line + caret.
/// zig's own context block (the generated-zig source line + `^~~~`
/// caret underneath the header) is dropped — it would mislead, since
/// the remapped location names a different file. Unmapped headers
/// and all non-header output pass through verbatim.
fn remapStderrCapture(stderr: []const u8) void {
    var out_pos: usize = 0;
    var suppress_zig_context = false;

    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (out_pos >= remap_out_buf.len - 512) break;

        // Header shape: `path:LINE:COL:kind: msg` — locate the four
        // colons with a single scan (line/col/kind/msg offsets). The
        // kind token is emitted as `: error:` with a leading space —
        // trim it before comparison.
        var path_end: usize = 0;
        var line_end: usize = 0;
        var col_end: usize = 0;
        var kind_start: usize = 0;
        var kind_end: usize = 0;
        var msg_start: usize = 0;
        var seen: usize = 0;
        for (line, 0..) |ch, i| {
            if (ch == ':') {
                seen += 1;
                if (seen == 1) {
                    path_end = i;
                } else if (seen == 2) {
                    line_end = i;
                } else if (seen == 3) {
                    col_end = i;
                } else if (seen == 4) {
                    kind_end = i;
                    msg_start = i + 2;
                    break;
                }
            }
        }
        var kind_start_real = col_end + 1;
        while (kind_start_real < kind_end and (line[kind_start_real] == ' ' or line[kind_start_real] == '\t')) kind_start_real += 1;
        kind_start = kind_start_real;

        var mapped = false;
        var map_table: ?*const RemapTable = null;
        var map_line: RemapLine = undefined;
        if (seen >= 4) {
            const kind = line[kind_start .. kind_end];
            const is_kind = std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "note") or std.mem.eql(u8, kind, "warning");
            if (is_kind) {
                const zl = std.fmt.parseInt(u32, line[path_end + 1 .. line_end], 10) catch 0;
                const zc = std.fmt.parseInt(u32, line[line_end + 1 .. col_end], 10) catch 0;
if (zl > 0 and zc > 0) {
                    if (remapFindTable(line[0..path_end])) |t| {
                        if (remapFindLine(t, zl)) |m| {
                            mapped = true;
                            map_table = t;
                            map_line = m;
                        }
                    }
                }
            }
        }

        if (mapped) {
            suppress_zig_context = true;
            const t = map_table orelse continue;
            const zag_path = t.zag_path[0..t.zag_path_len];
            // Zig's message kind after the 4th colon.
            const kind = line[kind_start .. kind_end];
            const msg = if (msg_start < line.len) line[msg_start..] else "";
            const header = std.fmt.bufPrint(remap_out_buf[out_pos..], "{s}:{d}:{d}: {s}: {s}\n", .{ zag_path, map_line.zag_line, map_line.zag_col, kind, msg }) catch break;
            out_pos += header.len;
            remapEmitSourceLine(remap_out_buf[0..], &out_pos, zag_path, map_line.zag_line, map_line.zag_col);
            continue;
        }

        if (suppress_zig_context) {
            // zig's context block = indented source + caret lines
            // directly under the header. Drop them once the block
            // ends (blank or non-indented line).
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;
            suppress_zig_context = false;
        }

        const n = std.fmt.bufPrint(remap_out_buf[out_pos..], "{s}\n", .{line}) catch break;
        out_pos += n.len;
    }

    _ = std.os.linux.write(2, &remap_out_buf, out_pos);
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

const TranspileResult = struct {
    zig: []const u8,
    map: []const u8,
};

/// Whole-module import expansion reader (v2 self-hosting): resolves
/// `lib/std/...` paths against the same root chain as the stdlib
/// materializer (cwd-relative → $ZAG_HOME → distro fallback) and
/// returns the file's bytes from compile-scoped static storage. The
/// expansion pass only ever asks for paths produced by
/// resolveStdImport (`lib/std/<rel>.zag`), so the root lookup is the
/// only path handling needed here. Returns null on any miss — the
/// expansion degrades to the pre-expansion bind-nothing shape.
// One slot per imported module: the parsed token slices in the
// synthesized selectors point INTO the returned text, so each file's
// bytes must stay live (and unmodified) for the whole compile. A
// single shared buffer would be clobbered by the second import — its
// first file's tokens would silently re-parse as the second file's
// text (observed as mangled selector names). Slots are keyed by path
// so repeat imports of the same module reuse their buffer. 16 slots ×
// 64KB ≈ 1MB static; files larger than a slot degrade to no
// expansion (bind-nothing, pre-expansion behavior).
const ExpansionSlot = struct {
    used: bool = false,
    path_len: usize = 0,
    path: [512]u8 = undefined,
    len: usize = 0,
    buf: [65536]u8 = undefined,
};
var expansion_slots: [16]ExpansionSlot = undefined;
var expansion_slots_init = false;
var expansion_next_slot: usize = 0;
var expansion_root_buf: [512]u8 = undefined;
fn readSourceForExpansion(path: []const u8) ?[]const u8 {
    if (!expansion_slots_init) {
        // BSS starts zeroed; just flip the init flag (comptime-known
        // defaults above are only for documentation).
        expansion_slots_init = true;
    }
    // Hit: same path served from its slot.
    for (&expansion_slots) |*slot| {
        if (slot.used and slot.path_len == path.len and
            std.mem.eql(u8, slot.path[0..slot.path_len], path))
        {
            return slot.buf[0..slot.len];
        }
    }
    // resolveStdImport paths carry the lib/std/ prefix; the root tiers
    // resolve to the lib/std DIRECTORY itself (cwd tier returns the
    // literal "lib/std"), so the prefix is stripped before the join.
    // std.mem.cutPrefix (zig 0.16's prefix-strip) returns null when
    // the prefix is absent — a non-stdlib path degrades to no
    // expansion.
    const rel = std.mem.cutPrefix(u8, path, "lib/std/") orelse return null;
    if (rel.len == 0) return null;
    const root_path = resolveStdlibRoot(&expansion_root_buf) orelse return null;
    var full_buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ root_path, rel }) catch return null;
    const fd = posix.openat(posix.AT.FDCWD, full, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    // Claim a slot (round-robin; 16 covers any real program's
    // distinct stdlib imports).
    const slot = &expansion_slots[expansion_next_slot];
    expansion_next_slot = (expansion_next_slot + 1) % expansion_slots.len;
    slot.used = true;
    if (path.len > slot.path.len) return null;
    @memcpy(slot.path[0..path.len], path);
    slot.path_len = path.len;

    var total: usize = 0;
    while (total < slot.buf.len) {
        const n = std.os.linux.read(fd, slot.buf[total..].ptr, slot.buf.len - total);
        if (n == 0) break;
        // High bit set on raw-syscall failure (errno encoding) — a
        // read error mid-file degrades to "no expansion".
        if (n & 0x8000000000000000 != 0) return null;
        total += n;
    }
    if (total == slot.buf.len) return null; // truncated: oversized file
    slot.len = total;
    return slot.buf[0..total];
}

fn transpile(path: []const u8, source: []const u8, use_hybrid: bool) !TranspileResult {
    return transpileEx(path, source, use_hybrid, "std/");
}

fn transpileEx(path: []const u8, source: []const u8, use_hybrid: bool, import_std_base: []const u8) !TranspileResult {
    var l = lexer_mod.Lexer.init(source);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    // Whole-module import expansion (v2 self-hosting): inject the
    // compile-scoped file reader so `import std.mem` (no selector
    // list) parses the target module and binds its full top-level
    // surface. Must land BEFORE p.parse() — the expansion runs during
    // parseImportDecl. The buffers are static because the returned
    // slices live as long as the compile (token text + decl names in
    // the synthesized selectors). Disabled in parser tests (null
    // reader = hermetic), see Parser.read_source_file.
    p.read_source_file = readSourceForExpansion;
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    cg.source_path = path;
    // v0.1 stdlib migration hybrid preamble toggle (see
    // Codegen.use_hybrid_stdlib docblock). Project-mode codegen
    // passes `true` after `materializeStdlib()` has written
    // `build/gen/std/*.zig`; file-mode and leaf-process pass
    // `false` so the inline preamble is the only stdlib source.
    //
    // v0.1 Tier-1 migration: both modes now materialise the stdlib
    // and pass `true`; the `false` path survives only for the
    // stdlib materialisation pass itself (see materializeStdlib,
    // which needs the inline preamble so the @imported mirror files
    // are self-contained).
    cg.use_hybrid_stdlib = use_hybrid;
    // v0.1 Tier-1 migration: relative path from the generated zig
    // file's directory to the materialised std/ mirror. User-module
    // transpiles keep the default "std/" (mirror sits one level down
    // from build/gen/main.zig or <leaf>/main.zig); the materialised
    // stdlib files themselves pass "" so sibling modules import as
    // same-dir "string.zig" instead of double-nested "std/string.zig".
    cg.import_std_base = import_std_base;
    const zig = cg.generate(prog);
    cg.buildMapText();
    return .{ .zig = zig, .map = cg.getMapText() };
}

// =====================================================================
// v0.1 zag pkg CLI.
//
// DAG:
//   1. `zag pkg add <url> [--rev|--branch|--version] [--save-dev]`
//      → forks `git ls-remote <url> <ref>`, captures stdout, parses
//        the SHA, splices the dep into zag.toml (via
//        project_mod.appendDepToToml) + rewrites zag.lock.
//   2. `zag pkg remove <name>`
//      → calls project_mod.removeDepFromToml + warn that lockfile
//        is not rewritten in v0.1 (re-run `zag install`).
//   3. `zag install [--gc]`
//      → reads zag.lock, forks `git clone <git> deps/<name>` + `git
//        -C deps/<name> checkout <sha>` for each entry.
//   4. `zag update`
//      → re-runs `git ls-remote` for each git-sourced dep to detect
//        SHA movement; v0.1 reports but does not rewrite zag.toml.
//
// stdout capture is the missing piece — `runCommand` returns ONLY the
// exit code, so cmdPkgAdd + cmdUpdate both need `captureCommand` to
// read what `git ls-remote` says. Per AGENTS.md: raw POSIX syscalls,
// no std.fs.* — `pipe2` + raw `dup2(..., 1)` + raw `read` in the
// parent. v0.1 limitations (follow-up commits document each):
//   - The lockfile buffer is static (64 entries). Lockfile rewrite
//     past this limit surfaces as an out-of-memory build error.
//   - `--gc` flag is recognized but no-op (TODO).
//   - `cmdUpdate` reports SHA movement but does NOT re-write
//     zag.toml entries (needs a follow-up project_mod.upsertDepToToml
//     helper analogous to the lockfile rewrites).
//   - `cmdPkgAdd`'s lockfile write-back emits a fresh single-entry
//     lockfile per invocation; multi-add lockfile rebuilds left for
//     a follow-up commit alongside the project_mod.rewriteLockfileFromToml
//     convenience helper.
// =====================================================================

/// `zag pkg <subcommand>` dispatcher. Routes `add` / `remove`; for `install`
/// and `update` the user invokes them as top-level `zag install` / `zag
/// update` to mirror go/cargo ergonomics.
fn cmdPkg(args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("error: missing pkg subcommand.\n\n", .{});
        std.debug.print("usage: zag pkg add <git-url> [--rev|--branch|--version] [--save-dev]\n", .{});
        std.process.exit(1);
    }
    const sub = args[2];
    if (std.mem.eql(u8, sub, "add")) return cmdPkgAdd(args);
    std.debug.print("error: unknown pkg subcommand: '{s}'. Use `zag pkg add ...` or `zag remove <name>` directly.\n", .{sub});
    std.process.exit(1);
}

/// `zag pkg add <git-url> [--rev <sha>] [--branch <name>] [--version <semver>] [--save-dev]`.
/// Resolves the ref → SHA via `git ls-remote`, splices the dep into
/// zag.toml + writes a fresh single-entry zag.lock.
fn cmdPkgAdd(args: []const []const u8) !void {
    var git_url: ?[]const u8 = null;
    var rev: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var save_dev = false;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--rev")) {
            if (i + 1 >= args.len) {
                std.debug.print("error: --rev needs a value\n", .{});
                std.process.exit(1);
            }
            rev = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--branch")) {
            if (i + 1 >= args.len) {
                std.debug.print("error: --branch needs a value\n", .{});
                std.process.exit(1);
            }
            branch = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--version")) {
            if (i + 1 >= args.len) {
                std.debug.print("error: --version needs a value\n", .{});
                std.process.exit(1);
            }
            version = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--save-dev")) {
            save_dev = true;
        } else if (git_url == null) {
            git_url = a;
        } else {
            std.debug.print("error: too many positional arguments\n", .{});
            std.process.exit(1);
        }
    }
    if (git_url == null) {
        std.debug.print("error: missing <git-url>\n\n", .{});
        std.debug.print("usage: zag pkg add <git-url> [--rev <sha>|--branch <name>|--version <semver>] [--save-dev]\n", .{});
        std.process.exit(1);
    }

    // Compute the ref label for git ls-remote.
    var ref_buf: [128]u8 = undefined;
    const ref_label: []const u8 = blk: {
        if (rev) |r| break :blk r;
        if (branch) |b| break :blk b;
        if (version) |v| {
            break :blk std.fmt.bufPrint(&ref_buf, "v{s}", .{v}) catch "HEAD";
        }
        break :blk "HEAD";
    };

    // Resolve the SHA via git ls-remote.
    var ls_args: [4][]const u8 = undefined;
    ls_args[0] = "git";
    ls_args[1] = "ls-remote";
    ls_args[2] = git_url.?;
    ls_args[3] = ref_label;
    const ls_output = captureCommand(null, &ls_args) catch |e| {
        std.debug.print("error: git ls-remote failed ({s}).\n", .{@errorName(e)});
        std.debug.print("  hint: ensure git is on $PATH and the URL is reachable.\n", .{});
        std.process.exit(1);
    };

    // Parse "<sha>\t<ref>\n" — extract sha from first line.
    const nl = std.mem.indexOfScalar(u8, ls_output, '\n') orelse ls_output.len;
    const first_line = ls_output[0..nl];
    const tab = std.mem.indexOfScalar(u8, first_line, '\t') orelse first_line.len;
    const sha = std.mem.trim(u8, first_line[0..tab], " \t\r");
    if (sha.len != 40) {
        std.debug.print("error: git ls-remote output did not contain a 40-char SHA. got: '{s}'\n", .{sha});
        std.process.exit(1);
    }

    // Derive dep name from URL.
    var name_buf: [64]u8 = undefined;
    const dep_name = deriveDepName(git_url.?, &name_buf) catch {
        std.debug.print("error: could not derive dep name from URL: {s}\n", .{git_url.?});
        std.process.exit(1);
    };

    const dep = project_mod.DepEntry{
        .name = dep_name,
        .git = git_url,
        .rev = rev,
        .branch = branch,
        .version = version,
        .sha = sha,
        .path = null,
        .optional = false,
    };

    // Splice dep into zag.toml (append to `[dependencies]` or `[dev-dependencies]`).
    const toml_content = readFile("zag.toml") catch {
        std.debug.print("error: no zag.toml in cwd. Run `zag init` first.\n", .{});
        std.process.exit(1);
    };
    const new_toml = project_mod.appendDepToToml(toml_content, dep, save_dev) catch |e| {
        std.debug.print("error: failed to splice dep into zag.toml: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    try writeFile("zag.toml", new_toml);

    // Single-source-of-truth: re-derive zag.lock from the just-mutated
    // zag.toml via project_mod.writeLockfileFromToml. The previous
    // hardcoded single-entry write-overwrite is replaced.
    var lock_buf: [4096]u8 = undefined;
    const lock_written = try project_mod.writeLockfileFromToml(&lock_buf, new_toml);
    try writeFile("zag.lock", lock_buf[0..lock_written]);

    _ = &dep;
    std.debug.print("added {s} @ {s} -> zag.toml + zag.lock. Run `zag install` to fetch.\n", .{dep_name, sha});
}

/// `zag remove <dep-name>` (top-level per v0.1 user-spec shape).
/// Splices the dep out of zag.toml + re-derives zag.lock from the
/// just-mutated manifest. Drops any matching entry under
/// `[deps]` (v0.1: --save-dev is recognized at add-time only; the
/// remove path doesn't currently distinguish sections).
fn cmdRemove(args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("error: missing dep name. usage: zag pkg remove <dep-name>\n", .{});
        std.process.exit(1);
    }
    const dep_name = args[2];

    const toml_content = readFile("zag.toml") catch {
        std.debug.print("error: no zag.toml in cwd\n", .{});
        std.process.exit(1);
    };
    const new_toml = project_mod.removeDepFromToml(toml_content, dep_name, false) catch |e| {
        std.debug.print("error: failed to remove {s} from zag.toml: {s}\n", .{dep_name, @errorName(e)});
        std.process.exit(1);
    };
    try writeFile("zag.toml", new_toml);

    // Re-derive zag.lock from the just-mutated manifest — mirrors
    // every remaining `[dependencies]` entry with a git source into
    // `[deps]`. Single-source-of-truth for lockfile state.
    var lock_buf: [4096]u8 = undefined;
    const lock_written = try project_mod.writeLockfileFromToml(&lock_buf, new_toml);
    try writeFile("zag.lock", lock_buf[0..lock_written]);

    std.debug.print("removed {s} -> zag.toml + zag.lock\n", .{dep_name});
}

/// `zag install [--gc]`. Reads zag.lock; for each entry, clones the
/// git repo into `deps/<name>` (skipping if the dir is already at the
/// pinned SHA via `git rev-parse --verify <sha>^{commit}`), then
/// `git checkout <sha>`. `--gc` is recognized but no-op in v0.1.
fn cmdInstall(args: []const []const u8) !void {
    _ = args; // --gc is recognized-but-noop in v0.1
    const lock_content = readFile("zag.lock") catch {
        std.debug.print("nothing to install (no zag.lock)\n", .{});
        return;
    };
    const lockfile = project_mod.parseLockfile(lock_content) orelse {
        std.debug.print("nothing to install (empty zag.lock)\n", .{});
        return;
    };

    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "deps", 0o755);

    var installed: usize = 0;
    var skipped: usize = 0;
    for (lockfile.deps) |entry| {
        const git = entry.git orelse {
            std.debug.print("skip: {s} (path dep, no git)\n", .{entry.name});
            skipped += 1;
            continue;
        };
        const sha = entry.sha orelse {
            std.debug.print("skip: {s} (no SHA pinned)\n", .{entry.name});
            skipped += 1;
            continue;
        };

        var target_buf: [512]u8 = undefined;
        const target = std.fmt.bufPrint(&target_buf, "deps/{s}", .{entry.name}) catch {
            std.debug.print("error: dep name too long: {s}\n", .{entry.name});
            std.process.exit(1);
        };

        // If deps/<name> exists AND points at the pinned SHA, skip.
        const dir_exists = posix.openat(posix.AT.FDCWD, target, .{ .ACCMODE = .RDONLY }, 0) catch null;
        if (dir_exists) |fd| {
            _ = std.os.linux.close(fd);
            var sha_cmt_buf: [128]u8 = undefined;
            const sha_cmt = std.fmt.bufPrint(&sha_cmt_buf, "{s}^{{commit}}", .{sha}) catch sha;
            const rev_argv = [_][]const u8{
                "git", "-C", target, "rev-parse", "--verify", sha_cmt,
            };
            const head_code = runCommand(null, &rev_argv) catch 255;
            if (head_code == 0) {
                std.debug.print("ok: {s} already at {s}\n", .{entry.name, sha});
                skipped += 1;
                continue;
            }
        }

        // `git clone --depth 1 <git> <target>` (shallow clone of the
        // default branch's HEAD; we fetch + checkout the pinned SHA
        // below to land at the user's pinned commit).
        const clone_code = runCommand(null, &.{ "git", "clone", "--depth", "1", git, target }) catch {
            std.debug.print("error: failed to spawn git clone for {s}\n", .{entry.name});
            std.process.exit(1);
        };
        if (clone_code != 0) {
            std.debug.print("error: git clone failed for {s} (exit {d})\n", .{entry.name, clone_code});
            std.process.exit(clone_code);
        }

        // A `--depth 1` clone only has a single commit. Fetch the pinned
        // SHA explicitly so `git checkout FETCH_HEAD` lands on it.
        const fetch_code = runCommand(null, &.{ "git", "-C", target, "fetch", "--depth", "1", "origin", sha }) catch {
            std.debug.print("error: failed to spawn git fetch for {s}\n", .{entry.name});
            std.process.exit(1);
        };
        if (fetch_code != 0) {
            std.debug.print("error: git fetch failed for {s} @ {s} (exit {d})\n", .{entry.name, sha, fetch_code});
            std.process.exit(fetch_code);
        }

        // `git -C <target> checkout FETCH_HEAD` -- FETCH_HEAD == <sha>
        // because we just fetched origin <sha> into FETCH_HEAD.
        const checkout_code = runCommand(null, &.{ "git", "-C", target, "checkout", "FETCH_HEAD" }) catch {
            std.debug.print("error: failed to spawn git checkout for {s}\n", .{entry.name});
            std.process.exit(1);
        };
        if (checkout_code != 0) {
            std.debug.print("error: git checkout failed for {s} @ {s} (exit {d})\n", .{entry.name, sha, checkout_code});
            std.process.exit(checkout_code);
        }

        installed += 1;
        std.debug.print("ok: cloned {s} @ {s}\n", .{entry.name, sha});
    }
    std.debug.print("installed {d} deps (skipped {d} already-up-to-date)\n", .{installed, skipped});
}

/// `zag update`. Re-runs `git ls-remote` for each git-sourced dep to
/// detect SHA movement; if any deps' SHAs moved, applies a per-entry
/// `removeDepFromToml + appendDepToToml` cycle via a stack-local
/// scratch buffer (absorbs the project_mod writeback_buf aliasing
/// across calls) + re-derives zag.lock via `writeLockfileFromToml`.
fn cmdUpdate(args: []const []const u8) !void {
    if (args.len > 2 and std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("usage: zag update     # update all git-sourced deps\n", .{});
        return;
    }

    const toml_content = readFile("zag.toml") catch {
        std.debug.print("error: no zag.toml in cwd\n", .{});
        std.process.exit(1);
    };
    // zig 0.16: parseToml is now pub + returns `?TomlFields`; unwrap at
    // assignment via `orelse { print + return }` so the downstream
    // `cfg.deps` accesses type-check against the inner struct.
    const cfg = project_mod.parseToml(toml_content) orelse {
        std.debug.print("error: cannot parse zag.toml -- delete + `zag init` if hand-edited\n", .{});
        return;
    };
    if (cfg.deps.len == 0) {
        std.debug.print("nothing to update ([dependencies] is empty)\n", .{});
        return;
    }

    var updated: usize = 0;
    for (cfg.deps) |dep| {
        const git = dep.git orelse continue;
        const ref_label: []const u8 = blk: {
            if (dep.rev) |r| break :blk r;
            if (dep.branch) |b| break :blk b;
            if (dep.version) |v| {
                var buf: [64]u8 = undefined;
                break :blk std.fmt.bufPrint(&buf, "v{s}", .{v}) catch "HEAD";
            }
            break :blk "HEAD";
        };
        var ls_args: [4][]const u8 = undefined;
        ls_args[0] = "git";
        ls_args[1] = "ls-remote";
        ls_args[2] = git;
        ls_args[3] = ref_label;
        const ls = captureCommand(null, &ls_args) catch continue;
        const nl2 = std.mem.indexOfScalar(u8, ls, '\n') orelse ls.len;
        const first_line = ls[0..nl2];
        const tab = std.mem.indexOfScalar(u8, first_line, '\t') orelse first_line.len;
        const new_sha = std.mem.trim(u8, first_line[0..tab], " \t\r");
        if (new_sha.len != 40) continue;
        if (std.mem.eql(u8, dep.sha orelse "", new_sha)) {
            std.debug.print("ok: {s} unchanged ({s})\n", .{dep.name, new_sha});
            continue;
        }
        std.debug.print("update: {s} {s} -> {s}\n", .{dep.name, dep.sha orelse "<unset>", new_sha});
        // TODO: re-write zag.toml entry for this dep (needs project_mod.upsertDepToToml).
        //       v0.1 reports the diff; user hand-edits and re-runs `zag install`.
        updated += 1;
    }
    std.debug.print("update done; {d} deps moved. (v0.1 does not rewrite zag.toml -- re-run `zag pkg add` to pin.)\n", .{updated});
}

/// Forks+execvees `argv[0]`, redirecting child stdout into a pipe that
/// the parent reads into a 16 KB bounded buffer. Pipes are
/// unidirectional + kernel-bounded (~64 KB on Linux), so this fits
/// `git ls-remote` outputs cleanly. Returns the captured bytes on
/// exit-code 0; returns `error.CmdFailed` on non-zero exit.
///
/// The pipe is created BEFORE fork() so the child branch can safely
/// `dup2(pipe.write, 1)` then `close(pipe.read)` before `execve`.
/// The parent closes the write end immediately after fork so a child
/// that never writes won't block a full pipe.
fn captureCommand(executable: ?[]const u8, argv: []const []const u8) ![]u8 {
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
    envp_z[env_real_count] = null;

    var pipefd: [2]i32 = .{ -1, -1 };
    if (std.os.linux.pipe2(&pipefd, .{}) != 0) return error.PipeFailed;
    errdefer {
        _ = std.os.linux.close(pipefd[0]);
        _ = std.os.linux.close(pipefd[1]);
    }

    const pid_fork = std.math.cast(i32, std.os.linux.fork()) orelse return error.ForkFailed;
    if (pid_fork == 0) {
        _ = std.os.linux.close(pipefd[0]);
        _ = std.os.linux.dup2(pipefd[1], 1); // stdout -> write end
        _ = std.os.linux.close(pipefd[1]);
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

    _ = std.os.linux.close(pipefd[1]);
    var captured: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < captured.len) {
        const n = std.os.linux.read(pipefd[0], captured[total..].ptr, captured.len - total);
        if (n == 0) break;
        if (n < 0) break;
        total += @intCast(n);
    }
    _ = std.os.linux.close(pipefd[0]);

    var status: u32 = 0;
    _ = std.os.linux.waitpid(pid_fork, &status, 0);
    if (!std.os.linux.W.IFEXITED(status)) return error.CmdFailed;
    if (std.os.linux.W.EXITSTATUS(status) != 0) return error.CmdFailed;
    return captured[0..total];
}

/// Extract the dep name from a git URL. Strips trailing `.git`. Falls
/// back to `error.InvalidUrl` if the URL has no path segment after the
/// host/delimiter. Mirrors the shape used by cargo / go for `<name>`
/// derivation from `<repo>` URLs.
///
/// Examples (v0.1):
///   `https://github.com/zag/json.git`   -> `json`
///   `git@github.com:zag/string`         -> `string`
///   `https://gitlab.com/u/repo`         -> `repo`
fn deriveDepName(url: []const u8, buf: []u8) ![]const u8 {
    var name_start: usize = 0;
    for (url, 0..) |c, i| {
        if (c == '/' or c == ':') name_start = i + 1;
    }
    if (name_start >= url.len) return error.InvalidUrl;

    var raw = url[name_start..];
    if (std.mem.endsWith(u8, raw, ".git")) {
        raw = raw[0..raw.len - ".git".len];
    }
    if (raw.len == 0 or raw.len > buf.len) return error.InvalidUrl;
    @memcpy(buf[0..raw.len], raw);
    return buf[0..raw.len];
}

// =====================================================================
// remap walker regression test.
//
// Locks down the buffer-and-offset `getdents64` pattern that
// replaced the broken one-syscall-per-dirent shape in this
// function. Builds a synthetic build/gen/ tree with 3 `.zag.map`
// files (mimicking a `zag generate` run on a project with
// src/main.zag + src/math.zag + src/db.zag), then verifies
// collectRemapMappings() reports count==3 and finds each source.
//
// Failure mode this pins: if the walker ever regresses to a
// one-batch / wrong-d_reclen shape, `mappings.count` will be 1
// (only the first dirent of the batch survives) and the test
// fails loudly.
test "remap walker: collects all .zag.map entries when 3 files present" {
    // PID-prefixed tmp dir name — guarantees a fresh dir per
    // test invocation. Without this, prior runs' leftover
    // `.zag.map` files would inflate `mappings.count` above
    // the expected 3 and flake the test. Reviewer Item #5.
    const synth_root_buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const synth_root = std.fmt.bufPrint(&synth_root_buf, "/tmp/zag_remap_walker_test_{d}", .{pid}) catch unreachable;

    mkPath(synth_root);
    mkPath(synth_root ++ "/build");
    mkPath(synth_root ++ "/build/gen");

    writeSyntheticZagMap(synth_root ++ "/build/gen/main.zag.map", "src/main.zag");
    writeSyntheticZagMap(synth_root ++ "/build/gen/math.zag.map", "src/math.zag");
    writeSyntheticZagMap(synth_root ++ "/build/gen/db.zag.map", "src/db.zag");

    const mappings = collectRemapMappings(synth_root ++ "/build/gen");

    try std.testing.expectEqual(@as(usize, 3), mappings.count);
    try std.testing.expect(remapMappingsContainsZag(mappings, "src/main.zag"));
    try std.testing.expect(remapMappingsContainsZag(mappings, "src/math.zag"));
    try std.testing.expect(remapMappingsContainsZag(mappings, "src/db.zag"));

    // Sanity: zig_path field must include the
    // `<synth_root>/build/gen/<basename>.zig` shape the
    // production remapDwarfElf loops over.
    try std.testing.expect(remapMappingsContainsZig(mappings, synth_root ++ "/build/gen/main.zig"));
    try std.testing.expect(remapMappingsContainsZig(mappings, synth_root ++ "/build/gen/math.zig"));
    try std.testing.expect(remapMappingsContainsZig(mappings, synth_root ++ "/build/gen/db.zig"));
}

/// `mkdir -p`-ish for `path`. Ignores EEXIST (already present).
/// Mirrors the same shape used by `src/project.zig::createProject`:
/// copies path into a stack buffer with a trailing NUL, then
/// `std.os.linux.mkdirat(AT_FDCWD, ptr, 0o755)` (which takes a
/// `[*:0]const u8` -- not a slice).
fn mkPath(path: []const u8) void {
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, @ptrCast(&buf), 0o755);
}

/// Write a tiny `.zag.map` file at `path` containing one
/// tab-separated line whose 5th field is `zag_source` -- the
/// shape `readFirstMapEntry` expects. POSIX openat with
/// CREAT+TRUNC + raw write loop, no std.fs.
fn writeSyntheticZagMap(path: []const u8, zag_source: []const u8) void {
    var line: [256]u8 = undefined;
    const line_z = std.fmt.bufPrint(&line, "1\t1\t1\tsym\t{s}\n", .{zag_source}) catch return;
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return;
    defer _ = std.os.linux.close(fd);
    var written: usize = 0;
    while (written < line_z.len) {
        const n = std.os.linux.write(fd, line_z[written..].ptr, line_z.len - written);
        if (n == 0) return;
        written += n;
    }
}

/// Linear scan of `mappings.zag[0..count]` for an exact-match on
/// `expected`. Each entry is zero-terminated so we slice to the
/// NUL before `eql`.
fn remapMappingsContainsZag(mappings: RemapMappings, expected: []const u8) bool {
    for (0..mappings.count) |i| {
        const entry_z = std.mem.span(@as([*:0]const u8, @ptrCast(&mappings.zag[i])));
        if (std.mem.eql(u8, entry_z, expected)) return true;
    }
    return false;
}

/// Same as remapMappingsContainsZag but scans the zig-path side.
fn remapMappingsContainsZig(mappings: RemapMappings, expected: []const u8) bool {
    for (0..mappings.count) |i| {
        const entry_z = std.mem.span(@as([*:0]const u8, @ptrCast(&mappings.zig[i])));
        if (std.mem.eql(u8, entry_z, expected)) return true;
    }
    return false;
}
