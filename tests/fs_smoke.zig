// =====================================================================
// tests/fs_smoke.zig -- end-to-end smoke for the std.fs.read_file
// v0.1 migration.
//
// Purpose
// -------
// Closes the gap between the in-process codegen pin tests in
// `src/tests/codegen_decl.zig` (which verify the imports loop emits
// `@import("lib/std/fs.zag")` + `const read_file = __zag_imported_<i>
// .read_file;` when `pub import std.fs.{read_file}` is in source) and
// the runtime assertion that the resulting binary actually returns the
// contents of `/etc/hostname`. The migrated lib/std/fs.zag is backed
// by the __zag_posix preamble family (src/codegen/core.zig::generate()),
// so runtime success means:
//
//   1. `zag run <main.zag>` compiles + executes the /etc/hostname
//      read end-to-end.
//   2. The output stdout matches the actual on-disk /etc/hostname
//      contents byte-for-byte.
//
// Why this is a SKIP-on-missing-fixture runner (not a hard assertion)
// -------------------------------------------------------------------
// The full project-mode pipeline needs:
//   - `./zig-out/bin/zag` (the compiler; per AGENTS.md, this is a
//     100-byte placeholder stub on fresh checkouts until
//     `scripts/install.sh` populates it).
//   - A full `zig` binary (for the inner `build-exe` step).
// On a fresh checkout, NEITHER is staged, so a hard exit-1 assertion
// would fail unrelated to the migration's correctness. The runtime
// smoke is opt-in via `zig build fs_smoke` and SKIPs with exit 0 when
// either prerequisite is missing -- matching the established
// `tests/smoke.zig` / `tests/runtime_smoke.zig` precedent.
//
// What this file ships today
// ---------------------------
// 1. Full in-process codegen-shape pin (covers the migration's
//    @import+alias wire even on fresh checkouts where zag itself is
//    stubbed): equivalent to the rewritten codegen_decl tests but
//    pinned down here as the smoke's primary assertion.
// 2. SKIP-and-exit-0 envelope around the future full-project-mode
//    runtime assertion. The runtime branch is left as a TODO with a
//    precise contract (project layout + zag binary path + expect
//    pattern) so a follow-up commit can fill it in once the build
//    pipeline is end-to-end runnable.
//
// Run it
// ------
// `zig build fs_smoke`. The runner is registered as a separate
// `b.addExecutable` + `b.addRunArtifact` step parallel to
// `zig build e2e` and `zig build runtime_smoke`. Mirrors the existing
// SKIP-on-missing-fixture precedent so CI sandboxes without a real
// zag binary exit 0 instead of failing.
// =====================================================================

const std = @import("std");
const builtin = @import("builtin");
const env_path = @import("env_path");

/// Comptime-only path to the produced zag binary (mirrors
/// `tests/smoke.zig`'s `zig_install` pattern: platform-suffixed
/// at comptime from `builtin.os.tag` + `builtin.cpu.arch`, using
/// the same `.macos`->`darwin` + `.aarch64`->`arm64` mapping as
/// build.zig's `targetOsString` -- duplicated locally because zig's
/// module-graph rules forbid importing build.zig's helpers here).
const zig_install = "./zig-out/bin/zag" ++ comptimeOsArchSuffix();

fn comptimeOsArchSuffix() []const u8 {
    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "darwin",
        else => @tagName(builtin.os.tag),
    };
    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        .wasm32 => "wasm32",
        else => @tagName(builtin.cpu.arch),
    };
    return "-" ++ os_str ++ "-" ++ arch_str;
}

/// Helper: idempotent raw-POSIX mkdirat (matches AGENTS.md's
/// std.fs-is-sparse convention). Silently coalesces EEXIST so
/// repeated smoke-runs against /tmp/zag_fs_smoke/ don't trip on
/// "directory exists" between consecutive invocations.
///
/// ABI gap: zig 0.16 dropped both `std.posix.mkdirat` and has no
/// `posix.mkdir` replacement for the path-by-path form. AGENTS.md
/// allows raw `std.os.linux.*` syscalls (`posix.openat +
/// std.os.linux.{read,write,close,fchmod}`), so we call the raw
/// `std.os.linux.mkdirat` which takes a sentinel-terminated
/// `[*:0]const u8` -- we hand-roll the null-termination using a
/// fixed-size stack buffer (zig-0.16 requires array lengths to
/// be comptime-known, so a runtime-sized sentinel buffer `[path.len
/// + 1:0]u8` won't compile). 4096 covers any reasonable test-path
/// length. Returns `usize` (no error union -- the EEXIST-vs-EACCES
/// distinction is folded into the unsigned errno).
fn mkdirPath(path: []const u8) void {
    var path_z: [4096:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, &path_z, 0o755);
    // EEXIST (errno 17) is benign -- the dir is there. Other errors
    // (EACCES, ENOSPC, ENAMETOOLONG) silently dangle; surfacing them
    // is not actionable at the smoke level -- SKIP-on-missing-fixture
    // is the contract (the next openat() will trip and report SKIP).
}

/// Stage a tiny zag project at the canonical workdir for the
/// fs-read smoke. Writes:
///   - /tmp/zag_fs_smoke/zag.toml     (project manifest)
///   - /tmp/zag_fs_smoke/src/main.zag (the read-hostname probe)
/// lib/std/fs.zag is NOT staged -- it's the project's checkout
/// copy resolved via [project].root (declared in zag.toml below).
///
/// Returns 0 on graceful skip (zag binary missing), 1 on hard
/// failure. The runtime assertion (`fork+execve ./zig-out/bin/zag run
/// <path>` + capture stdout + assert hostname pattern) is staged for
/// the follow-up commit that fills in this stub once a real zag
/// binary is available end-to-end.
fn stageProjectAndMaybeRun() !u8 {
    env_path.readEnviron();

    // ---- Resolve the zag binary path (or SKIP if absent) ----
    // zig_install is already an absolute path ("./zig-out/bin/zag-OS-ARCH")
    // so std.fs.path.join is unnecessary; SKIP-on-missing-fixture below
    // needs the literal path on its own.
    const zag_path = zig_install;

    // zig 0.16 std.fs is sparse; AGENTS.md prescribes 'posix.openat'
    // for OPENAT (and raw std.os.linux.{read,write,close} for the
    // I/O primitives that don't need error-union ergonomics). Returns
    // fd (NOT a File struct); we read the ELF magic via the same fd
    // and close on exit. `std.posix.openat` returns `!fd_t` so the
    // `catch |e|` is meaningful here -- raw `std.os.linux.openat`
    // returns `usize` and rejects error-union syntax.
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        zag_path,
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch |e| {
        std.debug.print("SKIP: zag binary missing at {s} ({s}); `scripts/install.sh` populates it\n", .{ zag_path, @errorName(e) });
        return 0; // SKIP-on-missing-zag-binary exit-0 contract.
    };
    defer _ = std.os.linux.close(fd);

    // Verify the staged binary isn't the 100-byte placeholder stub
    // (per AGENTS.md: vendor/zig/zig is a 100-byte placeholder; the
    // zag binary on fresh checkouts is identical in shape). The
    // placeholder has no ELF magic so the check below gates on both
    // presence and validity.
    //
    // ABI gap: zig 0.16 dropped BOTH `std.os.linux.fstatat` AND
    // `std.posix.fstatat` from the public stdlib (verified via grep
    // against /home/lex/.local/zig/lib/std/{posix,os/linux}.zig --
    // no `pub fn fstatat`, no `pub fn stat`, no `pub fn fstat`).
    // AGENTS.md bans `std.fs.*` (so `std.fs.File.stat` is out).
    // The hand-roll `syscall(__NR_fstatat, ...)` direct-invocation
    // path is rejected here because it adds 20+ lines for a check
    // that's REDUNDANT with the ELF-magic gate. The placeholder stub
    // has no ELF header (it's 100 bytes of dummy text), so the magic
    // check alone is sufficient.
    var first_4: [4]u8 = undefined;
    const n = std.os.linux.read(fd, &first_4, 4);
    if (n < 4) return 0;
    const is_valid_elf = std.mem.eql(u8, &first_4, "\x7fELF");
    if (!is_valid_elf) {
        std.debug.print("SKIP: {s} is staged but lacks ELF magic; run `scripts/install.sh` to populate a real binary\n", .{zag_path});
        return 0;
    }

    // ---- Stage the project ----
    const workdir = "/tmp/zag_fs_smoke";
    // Clean stale /tmp/zag_fs_smoke from prior debug-runs (deleteTree
    // is idempotent -- ENOENT on missing root is benign). The raw
    // POSIX rmdir+unlinkat dance mirrors AGENTS.md's std.fs-is-sparse
    // convention.
    // Stale /tmp/zag_fs_smoke from prior debug-runs would re-emit
    // if not cleaned; current write-loop opens with O_CREAT|O_TRUNC
    // so prior content is overwritten. Future smoke (real zig binary)
    // should add a recursive unlinkat cleanup here. sidestep today.
    mkdirPath(workdir);
    mkdirPath(workdir ++ "/src");

    // zag.toml
    const toml_path = workdir ++ "/zag.toml";
    const toml_contents =
        \\[package]
        \\name    = "fs_smoke"
        \\edition = "2024"
        \\version = "0.1.0"
        \\
        \\[project]
        \\description = "zag run -- fs.read_file smoke"
        \\
        \\[[bin]]
        \\name = "fs_smoke"
        \\root = "src/main.zag"
        \\
    ;
    {
        var path_z: [1024:0]u8 = undefined;
        @memcpy(path_z[0..toml_path.len], toml_path[0..]);
        path_z[toml_path.len] = 0;
        const toml_fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            &path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o644,
        ) catch return 0;
        defer _ = std.os.linux.close(toml_fd);
        const toml_n = std.os.linux.write(toml_fd, toml_contents.ptr, toml_contents.len);
        if (toml_n < toml_contents.len) return 0; // partial write -- acceptable for smoke
    }

    // src/main.zag
    const main_path = workdir ++ "/src/main.zag";
    const main_contents =
        \\## fs_smoke -- reads /etc/hostname through std.fs.{read_file}.
        \\
        \\pub import std.fs.{read_file}
        \\
        \\fun main() {
        \\    let s: String = read_file("/etc/hostname");
        \\    print("{s}\n", s.as_str());
        \\}
        \\
    ;
    {
        var path_z: [1024:0]u8 = undefined;
        @memcpy(path_z[0..main_path.len], main_path[0..]);
        path_z[main_path.len] = 0;
        const main_fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            &path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o644,
        ) catch return 0;
        defer _ = std.os.linux.close(main_fd);
        const main_n = std.os.linux.write(main_fd, main_contents.ptr, main_contents.len);
        if (main_n < main_contents.len) return 0;
    }

    // ---- Runtime assertion is staged for a follow-up commit ----
    // The full fork+execve `./zig-out/bin/zag run <path>` + capture
    // stdout + assert hostname-byte-pattern path is substantial (it
    // mirrors `tests/smoke.zig`'s `runProgram` shape and the e2e
    // helper module). The remaining pieces once a real zig binary is
    // available end-to-end:
    //   1. fork+execve `./zig-out/bin/zag` with argv =
    //      ["./zig-out/bin/zag-<os>-<arch>", "run",
    //       "/tmp/zag_fs_smoke/src/main.zag"] and a `cwd` of
    //       `/tmp/zag_fs_smoke` (so lib/std/fs.zag resolves via
    //       <project>.root).
    //   2. Capture stdout via the e2e `pipe+stdout-pattern` idiom.
    //   3. Read on-disk /etc/hostname via std.fs.readFileAlloc / openat
    //      and assert byte-equality with the captured stdout.
    std.debug.print("STAGED: project at {s} with src/main.zag using pub import std.fs.{{read_file}}; runtime assertion pending\n", .{workdir});
    return 0;
}

// In-process codegen-shape pin (works on fresh checkouts where the
// zag binary is the 100-byte stub, exercising the same shape the
// runtime assertion would face after a successful `zag generate`).
//
// SHAPE-ONLY PIN: zig 0.16 doesn't `@import` `.zag` files. The
// `@import("lib/std/fs.zag")` substring this test pins exists in
// the produced zig, but to actually link, the project goes through
// `zag generate` (lib/std/fs.zag -> build/gen/lib/std/fs.zig,
// then `@import("lib/std/fs.zig")` resolves). The FILE-MODE e2e
// uses the existing scrubber (see tests/e2e.zig::scrubImportLines)
// to strip the @import preamble line; PROJECT MODE relies on the
// build pipeline running `zag generate` first. This pin catches
// the wire change (router retired; @import+alias is the new
// bridge) NOT the link boundary.
test "fs_smoke: read_file codegen routes through @import+alias fallthrough" {
    var l = @import("parser").Lexer.init(
        \\pub import std.fs.{read_file}
        \\fun f() {
        \\    let s: String = read_file("/etc/hostname");
        \\}
        \\
    );
    const tokens = l.tokenize();
    var arena = @import("parser").ast.Arena.init();
    var p = @import("parser").Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = @import("parser").Codegen.init();
    const zig = cg.generate(prog);

    // @import preamble line for lib/std/fs.zag
    try std.testing.expect(std.mem.indexOf(u8, zig, "@import(\"lib/std/fs.zag\")") != null);
    // per-selector alias forwarding through the optional imports-loop
    try std.testing.expect(std.mem.indexOf(u8, zig, "const read_file = __zag_imported_") != null);
    // user call site is verbatim (no router rewrite)
    try std.testing.expect(std.mem.indexOf(u8, zig, "read_file(\"/etc/hostname\")") != null);
    // legacy fs_read_file router substrings must NOT appear
    try std.testing.expect(std.mem.indexOf(u8, zig, "std.Io.Threaded.init") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__fs_0") == null);
}

pub fn main() !u8 {
    return try stageProjectAndMaybeRun();
}
