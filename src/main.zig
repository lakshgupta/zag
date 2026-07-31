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
    if (std.mem.eql(u8, cmd, "check") or std.mem.eql(u8, cmd, "test")) {
        if (args.len >= 3 and hasZagExt(args[2])) {
            resolveZigPath(null);
            if (zig_install_path.len == 0) return needZig();
            try leafProcess(cmd, args[2], null, &.{});
        } else if (try project_mod.detectProject("")) |cfg| {
            resolveZigPath(cfg);
            if (zig_install_path.len == 0) return needZig();
            try projectCmd(cmd, cfg, &.{}, false, false);
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

    // Check for --release flag before --
    var release_flag = false;
    for (args[2..sep_idx]) |a| {
        if (std.mem.eql(u8, a, "--release")) release_flag = true;
    }

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
        try leafProcess("run", file, null, extra_args);
    } else if (try project_mod.detectProject("")) |cfg| {
        resolveZigPath(cfg);
        if (zig_install_path.len == 0) return needZig();
        try projectCmd("run", cfg, extra_args, false, release_flag);
    } else {
        std.debug.print("error: missing file argument. Provide a .zag file or run from a project directory.\n\n", .{});
        usage();
        std.process.exit(1);
    }
}

fn cmdBuild(args: []const []const u8) !void {
    // Parse -o / --output, -g / --generate, --release
    var output_path: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var generate_flag = false;
    var release_flag = false;

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
        } else if (std.mem.eql(u8, a, "--release")) {
            release_flag = true;
        } else if (hasZagExt(a)) {
            file_arg = a;
        }
    }

    if (file_arg) |file| {
        const out = output_path orelse file[0..file.len - ".zag".len];
        resolveZigPath(null);
        if (zig_install_path.len == 0) return needZig();
        try leafProcess("build", file, out, &.{});
    } else if (try project_mod.detectProject("")) |cfg| {
        resolveZigPath(cfg);
        if (zig_install_path.len == 0) return needZig();
        try projectCmd("build", cfg, &.{}, generate_flag, release_flag);
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

    // Binary to debug — default to project's build/bin/<name>
    var binary_path: [512]u8 = undefined;
    var bin: []const u8 = "zig-out/bin/main";

    if (file_arg) |file| {
        // File mode: compile the .zag file, debug the binary
        resolveZigPath(null);
        if (zig_install_path.len == 0) return needZig();
        const out = file[0..file.len - ".zag".len];
        try leafProcess("build", file, out, &.{});
        bin = out;
    } else if (try project_mod.detectProject("")) |cfg| {
        resolveZigPath(cfg);
        if (zig_install_path.len == 0) return needZig();
        // Write map files and build
        try projectCmd("build", cfg, &.{}, false, false);
        bin = try std.fmt.bufPrint(&binary_path, "zig-out/bin/{s}", .{cfg.name});
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
        \\sys.path.insert(0, os.path.join(os.getcwd(), 'tools'))
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

fn projectCmd(mode: []const u8, cfg: project_mod.ProjectConfig, extra_args: []const []const u8, generate: bool, release: bool) !void {
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
    materializeStdlib();

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
    if (std.mem.eql(u8, mode, "run")) {
        const build_code = if (release)
            try runCommand(null, &.{ zig_install_path, "build", "run", "--build-file", "build/gen/build.zig", "-Doptimize=ReleaseFast" })
        else
            try runCommand(null, &.{ zig_install_path, "build", "run", "--build-file", "build/gen/build.zig" });
        if (build_code != 0) {
            std.debug.print("error: zig build failed (exit {d})\n", .{build_code});
            std.process.exit(build_code);
        }
    } else {
        const build_code = if (release)
            try runCommand(null, &.{ zig_install_path, "build", "--build-file", "build/gen/build.zig", "-Doptimize=ReleaseFast" })
        else
            try runCommand(null, &.{ zig_install_path, "build", "--build-file", "build/gen/build.zig" });
        if (build_code != 0) {
            std.debug.print("error: zig build failed (exit {d})\n", .{build_code});
            std.process.exit(build_code);
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
    materializeStdlib();

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
    std.debug.print("  zag test [<file.zag>]              Run tests in a file or project\n", .{});
    std.debug.print("  zag init [<dir>]                   Create a new Zag project\n", .{});
    std.debug.print("  zag version                        Print version information\n", .{});
    std.debug.print("  zag help                           Show this help message\n", .{});
    std.debug.print("\nFlags:\n", .{});
    std.debug.print("  --release          Optimize build (passes -Doptimize=ReleaseFast to zig)\n", .{});
    std.debug.print("  -g, --generate     Also emit .zig output in build/gen/\n", .{});
    std.debug.print("  -o, --output       Output path (binary for build, dir for generate)\n", .{});
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
    const result = try transpile(src, source, false);
    try writeFile(f_zig, result.zig);

    if (std.mem.eql(u8, flag, "test")) {
        const has_test_block = std.mem.indexOf(u8, result.zig, "test \"") != null;
        const has_main = std.mem.indexOf(u8, result.zig, "pub fn main(") != null;
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

/// Materialize lib/std/{error,fmt,time,atomic,bench}.zag →
/// build/gen/std/*.zig at the start of project-mode dispatch. The
/// hybrid preamble in `src/codegen/core.zig::generate()` (gated by
/// `use_hybrid_stdlib` on Codegen, set here via the `use_hybrid`
/// parameter on `transpile`) emits `@import("std/<n>.zig")` lines
/// that resolve against the files written by this step.
///
/// v0.1 hardcodes the migrated list. A Phase 2 should derive this
/// from a manifest so future lib/std additions don't require
/// main.zig touch-ups. Each file is fully re-emitted per zag
/// invocation (~5 small files, ~few-ms cost); mtime-based skipping
/// is a Phase 2 optimisation.
///
/// Silently no-ops if lib/std cannot be read or one of the migrated
/// modules is missing (skips-on-missing-fixture convention used
/// elsewhere in the test runners — callers keep going without
/// stderr complaints).
///
/// The hybrid preamble that consumes these files leaves String and
/// Writer INLINE in `src/codegen/core.zig` (per `use_hybrid_stdlib`'s
/// docblock); the migrated zig files DO emit working String/Writer
/// `pub const` declarations, but the user-facing alias name is
/// wired directly to the inline preamble by stdlibPreambleName. A
/// follow-up commit can reconcile by routing the user-importable
/// Name through `@import("std/string.zig")` once the
/// `String`/`Writer` callsites in `src/codegen/expr.zig` are
/// rewritten to use the @imported module path.
fn materializeStdlib() void {
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);
    var mkdir_buf: [256]u8 = undefined;
    @memcpy(mkdir_buf[0..13], "build/gen/std");
    mkdir_buf[13] = 0;
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, @ptrCast(&mkdir_buf), 0o755);

    // v0.1 stdlib migration (String/Writer follow-up commit): the
    // list extends from the prior commit's 5 modules to 7 — `string`
    // and `fmt` migrated now that the inline preamble no longer
    // hard-codes their type definitions (see `__zag_String_inline` /
    // `__zag_Writer_inline` rename in `src/codegen/core.zig`).
    // `__zag_page_alloc` family helpers and `__zag_fd_write` /
    // `__zag_memcpy` are emitted as preamble always (file mode +
    // hybrid mode) so the migrated impl blocks can express generic
    // heap-alloc / fd-write primitives without dropping into raw
    // zig. See `codegen::core::generate()` preamble for the emit.
    // v0.1 stdlib migration follow-up commit (String/Writer): extend
    // the list from 5 modules to 6 (the prior commit added `fmt`;
    // the follow-up adds `string` so the @imported `String` rebinding
    // resolves at compile time). `__zag_page_alloc` family helpers
    // and `__zag_fd_write` / `__zag_memcpy` are emitted as preamble
    // always (file mode + hybrid mode) so the migrated impl blocks
    // can express generic heap-alloc / fd-write primitives without
    // dropping into raw zig. See codegen::core::generate() preamble.
    const modules = [_][]const u8{ "error", "fmt", "time", "atomic", "bench", "string" };
    for (modules) |name| {
        var src_buf: [256]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "lib/std/{s}.zag", .{name}) catch continue;
        const source = readFile(src_path) catch continue;

        var l = lexer_mod.Lexer.init(source);
        const tokens = l.tokenize();
        var arena = ast.Arena.init();
        var p = parser_mod.Parser.init(tokens, &arena);
        const prog = p.parse();
        var cg = codegen_mod.Codegen.init();
        cg.source_path = src_path;
        // The stdlib materialisation itself uses the legacy inline
        // preamble path (use_hybrid = false). Embedding the hybrid
        // rebindings inside the stdlib materialisation would create
        // a chicken-and-egg (those rebindings reference
        // `build/gen/std/*.zig` from a context where the on-disk
        // files don't exist — the codegen output is in flight).
        // Inlining the original preamble on this code-path keeps
        // the dependency graph acyclic.
        const zig = cg.generate(prog);

        var dst_buf: [256]u8 = undefined;
        const dst_path = std.fmt.bufPrint(&dst_buf, "build/gen/std/{s}.zig", .{name}) catch continue;
        writeFile(dst_path, zig) catch continue;
    }
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

    var buf: [4096]u8 = undefined;
    var full = false;
    while (!full) {
        const nread = std.os.linux.getdents64(map_dir_fd, &buf, buf.len);
        if (nread == 0) break;
        if (nread > std.math.maxInt(isize)) break;

        var pos: usize = 0;
        while (pos < nread) {
            const entry: *const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
            pos += entry.d_reclen;

            // `d_name` is a flexible-array member; treat as
            // sentinel-terminated then slice to the NUL.
            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.d_name)));
            const name = name_z[0..name_z.len];

            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name[0] == '.') continue;
            if (entry.d_type != std.os.linux.DT.REG) continue;
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

fn transpile(path: []const u8, source: []const u8, use_hybrid: bool) !TranspileResult {
    var l = lexer_mod.Lexer.init(source);
    const tokens = l.tokenize();

    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();

    var cg = codegen_mod.Codegen.init();
    cg.source_path = path;
    // v0.1 stdlib migration hybrid preamble toggle (see
    // Codegen.use_hybrid_stdlib docblock). Project-mode codegen
    // passes `true` after `materializeStdlib()` has written
    // `build/gen/std/*.zig`; file-mode and leaf-process pass
    // `false` so the inline preamble is the only stdlib source.
    cg.use_hybrid_stdlib = use_hybrid;
    const zig = cg.generate(prog);
    cg.buildMapText();
    return .{ .zig = zig, .map = cg.getMapText() };
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
