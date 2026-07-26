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

var zig_install_path: []const u8 = "";

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
        const zig_src = try transpile(source);
        // Use output dir as file path
        const out_path = if (std.mem.eql(u8, output_dir, "build/gen")) "build/gen/main.zig" else output_dir;
        _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
        _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);
        try writeFile(out_path, zig_src);
        std.debug.print("generated {s}\n", .{out_path});
        return;
    }

    std.debug.print("error: no project found. Run from a directory with zag.toml, or pass a .zag file.\n", .{});
    std.process.exit(1);
}

fn projectCmd(mode: []const u8, cfg: project_mod.ProjectConfig, extra_args: []const []const u8, generate: bool, release: bool) !void {

    // Ensure build/gen/ and build/bin/ exist
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/bin", 0o755);

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
        const zig_src = transpile(source) catch |e| {
            std.debug.print("error: transpile failed for {s}: {s}\n", .{ mod.path, @errorName(e) });
            std.process.exit(1);
        };

        // Output path: build/gen/<module>.zig
        var out_buf: [512]u8 = undefined;
        const out_path = if (std.mem.eql(u8, mod.module_name, "main"))
            std.fmt.bufPrint(&out_buf, "build/gen/main.zig", .{}) catch "build/gen/main.zig"
        else
            std.fmt.bufPrint(&out_buf, "build/gen/{s}.zig", .{mod.module_name}) catch "build/gen/module.zig";

        try writeFile(out_path, zig_src);
    }

    // Generate build.zig for the project
    try generateBuildZig(modules);

    if (generate) {
        std.debug.print("generated zig project at build/gen/\n", .{});
        if (std.mem.eql(u8, mode, "generate")) return;
    }

    // Use zig build system with the generated build.zig
    const build_step: []const u8 = if (std.mem.eql(u8, mode, "run")) "run" else "build";

    const build_code = if (release)
        try runCommand(null, &.{ zig_install_path, "build", build_step, "--build-file", "build/gen/build.zig", "-Doptimize=ReleaseFast" })
    else
        try runCommand(null, &.{ zig_install_path, "build", build_step, "--build-file", "build/gen/build.zig" });
    if (build_code != 0) {
        std.debug.print("error: zig build failed (exit {d})\n", .{build_code});
        std.process.exit(build_code);
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
        // Find the binary for run
        var run_buf: [256]u8 = undefined;
        const run_bin = std.fmt.bufPrint(&run_buf, "zig-out/bin/{s}", .{cfg.name}) catch unreachable;
        const run_code = try runCommandWithArgs(run_bin, extra_args);
        std.process.exit(run_code);
    }
}

/// Generate a build.zig for the multi-module zag project.
fn generateBuildZig(modules: []const project_mod.ModuleEntry) !void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const header = "const std = @import(\"std\");\n\npub fn build(b: *std.Build) !void {\n    const target = b.resolveTargetQuery(.{});\n    const optimize = b.standardOptimizeOption(.{});\n    const exe = b.addExecutable(.{\n        .name = \"main\",\n        .root_source_file = b.path(\"main.zig\"),\n        .target = target,\n        .optimize = optimize,\n    });\n";
    @memcpy(buf[pos..][0..header.len], header);
    pos += header.len;

    for (modules) |mod| {
        if (std.mem.eql(u8, mod.module_name, "main")) continue;

        const line1 = "    _ = exe.addModule(\"";
        const line2 = "\", b.createModule(.{ .root_source_file = b.path(\"";
        const line3 = ".zig\") }));\n";

        // Build the line: _ = exe.addModule("modname", b.createModule(.{ .root_source_file = b.path("modname.zig") }));
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

    const footer = "    b.installArtifact(exe);\n}\n";
    @memcpy(buf[pos..][0..footer.len], footer);
    pos += footer.len;

    try writeFile("build/gen/build.zig", buf[0..pos]);
}

/// Generate all project files (modules + build.zig) without building.
/// Used by `zag generate`.
fn generateProjectFiles() !void {
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build", 0o755);
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, "build/gen", 0o755);

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
        const zig_src = transpile(source) catch |e| {
            std.debug.print("error: transpile failed for {s}: {s}\n", .{ mod.path, @errorName(e) });
            std.process.exit(1);
        };

        var out_buf: [512]u8 = undefined;
        const out_path = if (std.mem.eql(u8, mod.module_name, "main"))
            std.fmt.bufPrint(&out_buf, "build/gen/main.zig", .{}) catch "build/gen/main.zig"
        else
            std.fmt.bufPrint(&out_buf, "build/gen/{s}.zig", .{mod.module_name}) catch "build/gen/module.zig";

        try writeFile(out_path, zig_src);
    }

    try generateBuildZig(modules);
}

/// Resolve the zig compiler binary path that the current
/// invocation will use, applying the project's `[toolchain].zig`
/// override at highest priority and falling back through the env
/// var to the embedded payload in that order. Mirrors
/// `docs/manual/35-zag-toml-schema.md` §[toolchain]:
///   1. `[toolchain].zig` from `cfg.zig_path` (project-specific file)
///   2. `$ZAG_ZIG_PATH` env var                              (machine-wide)
///   3. `embedded_zig_path` from `-Dzig_payload=...`        (compile-time)
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
    // 1. Project-level override (highest priority). A user-set
    //    `[toolchain].zig` in the current project's `zag.toml`
    //    wins regardless of any env-var override -- this matches
    //    Cargo's `[source.crates-io]` > `CARGO_REGISTRIES_*`
    //    ordering and rustup's `rust-toolchain.toml` > `RUSTUP_TOOLCHAIN`
    //    ordering: project-contextual config beats machine-wide env.
    if (cfg) |c| {
        if (c.zig_path) |zp| {
            zig_install_path = zp;
            return;
        }
    }
    // 2. Machine-wide env override.
    if (env_path.getenv("ZAG_ZIG_PATH")) |zp| {
        zig_install_path = zp;
        return;
    }
    // 3. Embedded payload (lowest priority). Populated at startup
    //    via `toolchain.materializeZigToCache` against
    //    `build_options.zig_payload` -- only present when the
    //    compiler binary was built with `-Dzig_payload=<path>`.
    if (embedded_zig_path.len > 0) {
        zig_install_path = embedded_zig_path;
        return;
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
    // Tri-clause help line: enumerate the three resolution tiers
    // the user can configure so the failure path itself is
    // discoverability for the v2.1 `[toolchain].zig` project-level
    // override. The priority chain order (toml > env > embedded)
    // matches the docs/manual/35-zag-toml-schema.md §[toolchain]
    // description.
    //
    // Multi-line literal (zig 0.16 `\\` raw-string syntax) sidesteps
    // the `++` operator requirements (must be at comptime on
    // `*const u8` literals) and gives one self-contained
    // print-and-exit call site.
    std.debug.print(
        \\error: zig compiler not found.
        \\  resolution order (each tier may hold the answer):
        \\    1. project-level: `[toolchain] zig = "..."` in zag.toml
        \\    2. machine-wide:  $ZAG_ZIG_PATH=/path/to/zig
        \\    3. compiled-in:   build zag with -Dzig_payload=<path>
        \\
    , .{});
    std.process.exit(1);
}

fn usage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  zag run [<file.zag>] [--release] [-- <args>]   Compile and run\n", .{});
    std.debug.print("  zag check [<file.zag>]             Type-check a file or project\n", .{});
    std.debug.print("  zag build [<file.zag>] [--release] [-o <path>] Compile to binary\n", .{});
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
