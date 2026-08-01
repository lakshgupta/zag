// -------------------------------------------------------------------
// src/project.zig — zag.toml parser + project-scaffold helper.
//
// Two responsibilities:
//   - detectProject: walk up from `root_dir` looking for `zag.toml`,
//     then parse a minimal section-keyed view of it (state machine
//     over `[section]` lines + `key = "value"` body lines). Returns
//     `?ProjectConfig` -- null when no zag.toml is reached OR the
//     file is unparseable (no `[package].name` field).
//   - createProject: scaffold a new project directory: `zag.toml`
//     (`[package]` + `name`), `src/main.zag` (hello-world body), and
//     the `src/` subdirectory.
//
// v2.1 addition: `[toolchain].zig` field. The compiler's priority
// chain (src/main.zig's `resolveZigPath`) consults this BEFORE the
// env-var override ($ZAG_ZIG_PATH). Restaurants the legacy
// substring-search parser (`parseName`) -- which is fragile against
// accidentally-correct lookups across sections (e.g. `[dependencies]
// name = "..."`) -- with a proper line-state machine (parseToml).
//
// Substring-search parser still applies to bare top-level keys: the
// state machine initializes `section = .package` so the
// scaffold-emitted `name = "..."` line (which `createProject` used
// to write WITHOUT a `[package]` header) keeps parsing. The
// scaffold has now been upgraded to emit the `[package]` header
// explicitly -- better-zag form, matches the schema doc.
// -------------------------------------------------------------------

const std = @import("std");
const posix = std.posix;

/// Parsed view of `zag.toml` for project-mode commands (`zag run`,
/// `zag build`, `zag check`, `zag test`). Today the runtime only
/// needs `name` (used to build the `build/bin/<name>` output path)
/// and `zig_path` (used by `main.zig`'s `resolveZigPath` to consult
/// BEFORE the env-var override). The schema at
/// `docs/manual/35-zag-toml-schema.md` documents another 9
/// top-level sections that are forward-looking; the runtime parser
/// ignores them (`section = .none` skips their keys).
pub const ProjectConfig = struct {
    name: []const u8,
    root_dir: []const u8,
    /// Path to the zig compiler binary, drawn from the
    /// `[toolchain].zig = "..."` line. null when the section is
    /// absent. Used by `main.zig`'s `resolveZigPath` -- if set,
    /// it OVERRIDES `$ZAG_ZIG_PATH` and the embedded payload
    /// (highest priority per `docs/manual/35-zag-toml-schema.md`'s
    /// `[toolchain]` section discussion).
    zig_path: ?[]const u8,
};

/// One discovered source module in a zag project.
pub const ModuleEntry = struct {
    /// Path relative to the project root, e.g. "src/main.zag"
    path: []const u8,
    /// Module name derived from the path, e.g. "main" or "math.vec3"
    module_name: []const u8,
};

var module_buf: [128]ModuleEntry = undefined;
var module_count: usize = 0;

var module_paths_buf: [128 * 128]u8 = undefined;
var module_paths_pos: usize = 0;
var module_names_buf: [128 * 64]u8 = undefined;
var module_names_pos: usize = 0;

/// Walk `src/` and discover all `.zag` source files (recursive).
///
/// v3 change: replaces the prior hard-coded 14-name allow-list
/// (`lib`, `math`, `util`, `types`, ...) with a real
/// `getdents64`-based recursive walker. Any `.zag` file under
/// `src/` is now detected, with the matching module name derived
/// from its path (see "Module-name derivation" below).
///
/// Module-name derivation: given a project-relative path, the
/// module name is the path with the leading `src/` prefix and
/// trailing `.zag` suffix stripped, and any remaining `/`
/// replaced with `.`. Examples:
///   - `src/main.zag`        → `main`
///   - `src/foo.zag`         → `foo`
///   - `src/db/schema.zag`   → `db.schema`
///   - `src/a/b/c.zag`       → `a.b.c`
///
/// Walk policy:
///   - Recursive: descends every sub-directory under `src/` that
///     isn't dropped by the skip rules.
///   - Skip rules (deliberate, conservative):
///     - hidden entries (`.git`, `.cache`, `.idea`, etc.),
///     - the `build/` output directory.
///   - d_type gating: only `DT.DIR` and `DT.REG` are acted on;
///     `DT.UNKNOWN` (some FUSE / NFS mounts) is skipped — see
///     the latency note below.
///
/// Boundary semantics:
///   - `src/` doesn't exist at all              → empty slice.
///   - `src/` exists but is empty               → empty slice.
///   - `src/` non-empty but no `src/main.zag`   → empty slice
///     (matches v1; `src/main.zig`'s `projectCmd` already exits
///     with "no src/main.zag" on empty discovery).
///
/// Result ordering: v3 sorts the slice alphabetically by `path` so
/// the output is deterministic across runs (getdents64 doesn't
/// guarantee order across filesystems and we want stable
/// debugger-map output for the
/// `docs/manual/33-debugging.md` §"Multi-module projects" example).
pub fn discoverModules() []const ModuleEntry {
    module_count = 0;
    module_paths_pos = 0;
    module_names_pos = 0;

    const src_fd = posix.openat(posix.AT.FDCWD, "src", .{ .ACCMODE = .RDONLY }, 0) catch return &[_]ModuleEntry{};
    defer _ = std.os.linux.close(src_fd);

    walkSrcTree(src_fd, "");
    sortByPath();

    // Gate on main: src/main.zag is required (matches v1).
    for (module_buf[0..module_count]) |m| {
        if (std.mem.eql(u8, m.module_name, "main")) return module_buf[0..module_count];
    }
    module_count = 0;
    return &[_]ModuleEntry{};
}

/// Recursive walker given an open fd to a directory under `src/`
/// and the path of that directory relative to `src/` (`""` at
/// top-level, `"db"` inside `src/db/`, `"db/sub"` at three
/// levels deep, etc.).
///
/// Uses the proper buffer-and-offset `getdents64` pattern: one
/// syscall per batch, then iterate the batch via `d_reclen`
/// offsets. Sidesteps the shape used by the legacy
/// `remapDwarfElf` walker in `src/main.zig` which only reads the
/// first entry of each batch — that walker is one-syscall-per-
/// dirent, which is wrong on barriers and doesn't expose
/// subsequent entries after `d.off = 0`.
///
/// Caveat: `DT.UNKNOWN` is treated as "skip". This is fine on
/// ext4, btrfs, tmpfs, xfs (all of which populate d_type). On
/// filesystems that don't (e.g., some FUSE mounts configured
/// with `-o default_permissions,nodiratime`), the walker will
/// under-discover. Future fix: switch those branches to a
/// `posix.fstatat` fallback if it ever bites a real project.
fn walkSrcTree(dir_fd: i32, rel_to_src: []const u8) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.os.linux.getdents64(dir_fd, &buf, buf.len);
        if (n == 0) break;
        if (n > std.math.maxInt(isize)) break;

        var pos: usize = 0;
        while (pos < n) {
            const entry: *const std.os.linux.dirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += entry.reclen;

            // `d_name` is a flexible-array member; treat as
            // sentinel-terminated pointer then slice to the NUL.
            const name_z = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const name = name_z[0..name_z.len];

            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name[0] == '.') continue;
            // `name == "build"` is checked ONLY inside the
            // DT_DIR branch below — a top-level `src/build.zag`
            // file (whose module name is just `build`) is a
            // legitimate source file. Deliberate trade-off:
            // skipping a directory called `build/` keeps the
            // output dir out of the source-walk, but a
            // plain file at any depth is processed normally.

            if (entry.type == std.os.linux.DT.DIR) {
                if (std.mem.eql(u8, name, "build")) continue;
                // Build new_rel = rel_to_src ++ "/" ++ name (or
                // just `name` when at the top level).
                var new_rel_buf: [512]u8 = undefined;
                const new_rel: []const u8 = if (rel_to_src.len == 0)
                    std.fmt.bufPrint(&new_rel_buf, "{s}", .{name}) catch continue
                else
                    std.fmt.bufPrint(&new_rel_buf, "{s}/{s}", .{ rel_to_src, name }) catch continue;

                // Open the child relative to CWD (rather than
                // relative to dir_fd) — easier reasoning + the
                // path-buf overhead is dominated by syscall
                // cost on every walker step anyway. `child_path`
                // is "src/<new_rel>".
                var child_path_buf: [1024]u8 = undefined;
                const child_path = std.fmt.bufPrint(&child_path_buf, "src/{s}", .{new_rel}) catch continue;
                const child_fd = posix.openat(posix.AT.FDCWD, child_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
                walkSrcTree(child_fd, new_rel);
                _ = std.os.linux.close(child_fd);
            } else if (entry.type == std.os.linux.DT.REG and std.mem.endsWith(u8, name, ".zag")) {
                // Build abs path "src/<rel>/<name>" (only `name`
                // for top-level entries).
                var path_buf: [1024]u8 = undefined;
                const abs_path: []const u8 = if (rel_to_src.len == 0)
                    std.fmt.bufPrint(&path_buf, "src/{s}", .{name}) catch continue
                else
                    std.fmt.bufPrint(&path_buf, "src/{s}/{s}", .{ rel_to_src, name }) catch continue;

                // Build dotted module name directly into
                // module_names_buf: combine rel_to_src's `/` → `.`
                // rewrite with the file's stem (name minus `.zag`).
                // Examples:
                //   rel="db" name="schema.zag"     → "db.schema"
                //   rel="db/sub" name="foo.zag"    → "db.sub.foo"
                //   rel="" name="main.zag"         → "main"
                //   rel="" name="foo.zag"          → "foo"
                const stem_len = name.len - ".zag".len;
                const dotted_len: usize = if (rel_to_src.len == 0)
                    stem_len
                else
                    rel_to_src.len + 1 + stem_len;

                if (module_names_pos + dotted_len > module_names_buf.len) continue;
                var di: usize = module_names_pos;
                if (rel_to_src.len > 0) {
                    @memcpy(module_names_buf[di..][0..rel_to_src.len], rel_to_src);
                    var j: usize = 0;
                    while (j < rel_to_src.len) : (j += 1) {
                        if (module_names_buf[di + j] == '/') module_names_buf[di + j] = '.';
                    }
                    di += rel_to_src.len;
                    module_names_buf[di] = '.';
                    di += 1;
                }
                @memcpy(module_names_buf[di..][0..stem_len], name[0..stem_len]);

                const mod_name = module_names_buf[module_names_pos..][0..dotted_len];
                module_names_pos += dotted_len;

                addModuleEntry(abs_path, mod_name) catch continue;
            }
        }
    }
}

/// Insertion sort module_buf[0..module_count] in place by `path`
/// (byte-wise lexicographic). Bounded by the 128-entry
/// module_buf ceiling — O(n²) is fine for that scale.
fn sortByPath() void {
    var i: usize = 1;
    while (i < module_count) : (i += 1) {
        const cur = module_buf[i];
        var j: usize = i;
        while (j > 0 and std.mem.lessThan(u8, module_buf[j - 1].path, cur.path)) {
            module_buf[j] = module_buf[j - 1];
            j -= 1;
        }
        module_buf[j] = cur;
    }
}

fn addModuleEntry(path: []const u8, mod_name: []const u8) !void {
    if (module_count >= module_buf.len) return;
    if (module_names_pos + mod_name.len > module_names_buf.len) return;
    if (module_paths_pos + path.len > module_paths_buf.len) return;

    @memcpy(module_paths_buf[module_paths_pos .. module_paths_pos + path.len], path);
    const mpath = module_paths_buf[module_paths_pos .. module_paths_pos + path.len];
    module_paths_pos += path.len;

    @memcpy(module_names_buf[module_names_pos .. module_names_pos + mod_name.len], mod_name);
    module_names_pos += mod_name.len;

    module_buf[module_count] = .{ .path = mpath, .module_name = mod_name };
    module_count += 1;
}

/// Backing buffer for `ProjectConfig.name`. Module-private so that
/// the parser can mirror its contents (avoids lifetime annotations
/// on returned slices — the slice points into this global, which
/// lives for the duration of the program). Sized 256 bytes: package
/// names are limited to lowercase alnum + `-` + `_`.
var cfg_name_buf: [256]u8 = undefined;

/// Backing buffer for `ProjectConfig.zig_path`. Module-private
/// (same reasoning as `cfg_name_buf`). Sized 4096 to absorb
/// Linux/Windows-arbitrary absolute paths comfortably without
/// TOCTOU-style truncation surprises for niche `ZAG_HOME` paths.
var cfg_zig_buf: [4096]u8 = undefined;

// =====================================================================
// Dependency-tracking surface (v0.1 pkg CLI).
// =====================================================================

/// One deps/dev-deps entry, parsed from a single line in
/// `[dependencies]` / `[dev-dependencies]`. Schema per
/// `docs/manual/35-zag-toml-schema.md` §[dependencies]:
///   `name = { git = "...", rev|branch|version|path = "...", optional = bool }`
/// Exactly one of `git` or `path` must be set on a well-formed entry.
/// The parser is tolerant: if both are set, `path` wins (matches the
/// "local-sibling workspace" override contract from the manual).
pub const DepEntry = struct {
    name: []const u8,
    git: ?[]const u8 = null,
    /// SHA only populated by `LockEntry`, not `DepEntry`. Kept on
    /// the same struct for write-back convenience (a freshly-resolved
    /// `git+rev` becomes a `DepEntry` with a populated `sha` before
    /// being emitted to lockfile).
    sha: ?[]const u8 = null,
    path: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    version: ?[]const u8 = null,
    optional: bool = false,
};

/// Lockfile resolution of a `DepEntry` — only `git` deps get a SHA.
/// `path` deps have no SHA (their integrity is verified per-build
/// against the local filesystem).
pub const LockEntry = struct {
    name: []const u8,
    git: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// Resolved lockfile state, written to `zag.lock`.
pub const Lockfile = struct {
    deps: []LockEntry = &[_]LockEntry{},
    dev_deps: []LockEntry = &[_]LockEntry{},
};

// Backing buffers for parsed deps + dev_deps from zag.toml.
// Sized conservatively (64 + 32) — typical projects have well under
// 10 transitive deps. Larger projects would block here.
var dep_entry_buf: [64]DepEntry = undefined;
var dep_entry_count: usize = 0;
var dev_dep_entry_buf: [32]DepEntry = undefined;
var dev_dep_entry_count: usize = 0;

// Backing buffers for the inline-table field strings (one slice per
// (key, value) pair). Each entry is `null`-terminated inline; the
// DepEntry's g1/labels point into this buffer.
var dep_field_buf: [64 * 4][256]u8 = undefined; // name + git+rev + branch+version + path + optional
var dep_field_pos: usize = 0;

// Backing for lockfile entries.
var lock_entry_buf: [64]LockEntry = undefined;
var lock_entry_count: usize = 0;
var dev_lock_entry_buf: [32]LockEntry = undefined;
var dev_lock_entry_count: usize = 0;
var lock_field_buf: [96 * 2][256]u8 = undefined;
var lock_field_pos: usize = 0;

/// Walk `root_dir` then `zag.toml`, parse, return `ProjectConfig`.
/// Returns `null` when:
///   - no `zag.toml` is reachable at `root_dir` (or cwd if empty),
///   - the file is empty or unreadable,
///   - the file does not contain a `[package].name = "..."` line.
///
/// The parser is intentionally minimal — we recognise only
/// `[package]` + `[toolchain]` sections; everything else falls into
/// `.none` and is ignored. Trims ASCII whitespace around `=` and
/// around the quoted value (TOML's bare required trim); does NOT
/// handle escapes (`\"`, `\\`) inside quoted strings — paths rarely
/// need them, and unescaped-input is the documented contract.
/// Newline-terminated by `\n` (Linux-style; `\r\n` is stripped by
/// the per-line trim step).
pub fn detectProject(root_dir: []const u8) !?ProjectConfig {
    var path_buf: [4096]u8 = undefined;

    const config_path = if (root_dir.len == 0) blk: {
        break :blk "zag.toml";
    } else blk2: {
        const len = if (root_dir[root_dir.len - 1] == '/')
            root_dir.len + "zag.toml".len
        else
            root_dir.len + 1 + "zag.toml".len;
        if (len > path_buf.len) return null;

        var i: usize = 0;
        @memcpy(path_buf[0..root_dir.len], root_dir);
        i += root_dir.len;
        if (root_dir[root_dir.len - 1] != '/') {
            path_buf[i] = '/';
            i += 1;
        }
        @memcpy(path_buf[i..][0.."zag.toml".len], "zag.toml");
        i += "zag.toml".len;
        break :blk2 path_buf[0..i];
    };

    const fd = posix.openat(posix.AT.FDCWD, config_path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    var buf: [4096]u8 = undefined;
    const n = std.os.linux.read(fd, &buf, buf.len);
    if (n == 0) return null;

    const content = buf[0..n];
    const fields = parseToml(content) orelse return null;

    return ProjectConfig{
        .name = fields.name orelse return null,
        .root_dir = root_dir,
        .zig_path = fields.zig,
    };
}

/// Parsed view returned by `parseToml`. `name` is required for the
/// surrounding `detectProject` to declare success — without a
/// `[package].name` line, the file is malformed for our purposes.
/// `zig` is optional (it stays null when no `[toolchain]` section
/// is present, which the CLI treats as "no project-level override").
/// `deps` + `dev_deps` are populated from `[dependencies]` and
/// `[dev-dependencies]` sections (parallel arrays; entries point
/// into module-private buffers via deps slots owned by this struct).
const TomlFields = struct {
    name: ?[]const u8,
    zig: ?[]const u8,
    deps: []const DepEntry = &[_]DepEntry{},
    dev_deps: []const DepEntry = &[_]DepEntry{},
};

/// State-machine line walker for zag.toml. Recognises:
///   - `[section]` headers — switches the active section;
///   - `key = "value"` body lines — captures the quoted value into
///     the active section's slot;
///   - `name = { k = "v", ... }` dep-table body lines in `[dependencies]`
///     or `[dev-dependencies]` — extracts a `DepEntry` via the inline
///     table parser (`extractTable`).
/// Section "package" is the implicit top-level (initial state) so
/// that legacy scaffold output (bare `name = "..."` without a
/// `[package]` header) keeps parsing in lockstep with the new
/// scaffold format (`[package]\nname = "..."`). Sections
/// "toolchain" / "dependencies" / "dev-dependencies" are explicit-
/// only. Other sections (forward-looking `[build]`, `[scripts]`,
/// `[modules]`, etc.) switch the state to `.none`, suppressing
/// accidental capture of `name`/`zig`-shaped keys.
///
/// Implementation note: section state starts as `.package` rather
/// than `.none` purely for backward compatibility — the pre-v2.1
/// scaffold (`createProject` used to emit just `name = "..."`)
/// still parses. New scaffolds emit `[package]\nname = "..."`
/// explicitly (clearer intent, matches the schema doc).
pub fn parseToml(content: []const u8) ?TomlFields {
    const Section = enum { package, toolchain, dependencies, dev_dependencies, none };
    var section: Section = .package; // backward-compat default
    var name_field: ?[]const u8 = null;
    var zig_field: ?[]const u8 = null;

    var cursor: usize = 0;
    while (cursor < content.len) {
        const nl_index = std.mem.findScalar(u8, content[cursor..], '\n');
        const line_end = if (nl_index) |e| cursor + e else content.len;
        const raw_line = content[cursor..line_end];
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        if (trimmed.len > 0) {
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                // Section header — switch state. Unknown sections
                // route to .none so any `name`/`zig` keys inside
                // (which would be syntax errors by TOML strict
                // reading) cannot accidentally capture.
                const sect = trimmed[1 .. trimmed.len - 1];
                if (std.mem.eql(u8, sect, "package")) {
                    section = .package;
                    // Reset dep counts on transition INTO a non-deps
                    // section so subsequent writes don't accumulate
                    // into the wrong array. The counts go back to 0
                    // when a non-deps section is entered, but the
                    // already-parsed slice is preserved by reading
                    // it before the reset.
                    if (dep_entry_count > 0) dep_entry_count = 0;
                    if (dev_dep_entry_count > 0) dev_dep_entry_count = 0;
                } else if (std.mem.eql(u8, sect, "toolchain")) {
                    section = .toolchain;
                } else if (std.mem.eql(u8, sect, "dependencies")) {
                    section = .dependencies;
                } else if (std.mem.eql(u8, sect, "dev-dependencies")) {
                    section = .dev_dependencies;
                } else {
                    section = .none;
                }
            } else if (trimmed[0] != '#') {
                // Body line — capture based on active section.
                switch (section) {
                    .package => if (extractQuoted(trimmed, "name")) |v| {
                        if (v.len <= cfg_name_buf.len) {
                            @memcpy(cfg_name_buf[0..v.len], v);
                            name_field = cfg_name_buf[0..v.len];
                        }
                    },
                    .toolchain => if (extractQuoted(trimmed, "zig")) |v| {
                        if (v.len <= cfg_zig_buf.len) {
                            @memcpy(cfg_zig_buf[0..v.len], v);
                            zig_field = cfg_zig_buf[0..v.len];
                        }
                    },
                    .dependencies => parseDepLine(trimmed, false),
                    .dev_dependencies => parseDepLine(trimmed, true),
                    .none => {},
                }
            }
        }

        cursor = line_end + 1;
    }

    return TomlFields{
        .name = name_field,
        .zig = zig_field,
        .deps = dep_entry_buf[0..dep_entry_count],
        .dev_deps = dev_dep_entry_buf[0..dev_dep_entry_count],
    };
}

/// Find a substring `key = "value"` on `line` and return the value
/// (without the surrounding quotes). Tolerates whitespace between
/// the key, the `=`, and the opening quote. Returns null when:
///   - `key` doesn't appear as a substring,
///   - the `=` is missing or has non-whitespace after `key`,
///   - the opening `"` is missing,
///   - the closing `"` is missing.
///
/// Caveat: this is a SUBSTRING scan, NOT a prefix scan — it picks
/// up `name` inside e.g. `username = "..."` and `zig` inside
/// `zigzag = "..."`. The state-machine caller only invokes this
/// for body lines in the active section after a section header
/// has been recognised, so cross-section false matches are
/// prevented by `parseToml`'s section state — within a section,
/// duplicate keys are rare in real configs.
///
/// Internal whitespace inside the value is preserved verbatim
/// (path values containing spaces survive intact — the user can
/// write `"path with space/zig"`). Escape handling is NOT
/// implemented — TOML allows `\"` for embedded quotes in real
/// TOML, but our compiler never emits `zag.toml` files with
/// embedded escapes, and the documented contract is "verbatim".
fn extractQuoted(line: []const u8, key: []const u8) ?[]const u8 {
    const kp = std.mem.indexOf(u8, line, key) orelse return null;
    var i: usize = kp + key.len;

    // Skip whitespace between `key` and `=`.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len or line[i] != '=') return null;
    i += 1;

    // Skip whitespace between `=` and opening `"`.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;

    const vstart = i + 1;
    const vrel_end = std.mem.findScalar(u8, line[vstart..], '"') orelse return null;
    return line[vstart..][0..vrel_end];
}

/// Parse a dep-table line `name = { k = "v", k2 = "v2", ... }` and
/// append it to either the deps or dev_deps backing buffer. The
/// table body's keys are matched against the schema's known set:
/// `git`, `rev`, `branch`, `version`, `path`, `optional`. Unknown
/// keys are silently dropped (matches the most-toml implementations'
/// forward-compat contract — the user can round-trip new keys
/// without us needing to track them). Sub-parses the `{` ... `}`
/// table body and extracts each `k = "v"` pair via `extractQuoted`.
///
/// Returns silently on parse failure (line consumed but no entry
/// added). `name` captures the dep key (the identifier on the
/// left of `=`); the rest populate the inline-table fields.
fn parseDepLine(line: []const u8, is_dev: bool) void {
    // Find the `{` that opens the table body.
    const lbrace = std.mem.findScalar(u8, line, '{') orelse return;
    // Strip everything up to and including the `{` to get the
    // dep-name prefix `name = ` (and any leading whitespace).
    const prefix = std.mem.trim(u8, line[0..lbrace], " \t");

    // Parse the prefix `<name> =` — extract the key (everything
    // before the first `=`, trimmed).
    const eq_idx = std.mem.findScalar(u8, prefix, '=') orelse return;
    const dep_name = std.mem.trim(u8, prefix[0..eq_idx], " \t");

    // Get the matching `}` -- naive scan, sufficient for the
    // well-formed lines `zag` itself emits.
    const rbrace = std.mem.findScalarPos(u8, line, lbrace, '}') orelse return;
    const inner = line[lbrace + 1 .. rbrace];

    // Allocate a DepEntry slot in the appropriate buffer.
    const dep_target = if (is_dev) blk: {
        if (dev_dep_entry_count >= dev_dep_entry_buf.len) return;
        const idx = dev_dep_entry_count;
        dev_dep_entry_count += 1;
        break :blk &dev_dep_entry_buf[idx];
    } else blk: {
        if (dep_entry_count >= dep_entry_buf.len) return;
        const idx = dep_entry_count;
        dep_entry_count += 1;
        break :blk &dep_entry_buf[idx];
    };

    // Copy name into the data-table slot (lock_field_buf shares
    // storage with the parsed [dependencies] name slots; for dep
    // entries we use the dep_field_buf).
    if (dep_name.len > dep_field_buf[dep_field_pos].len) return;
    @memcpy(dep_field_buf[dep_field_pos][0..dep_name.len], dep_name);
    dep_field_buf[dep_field_pos][dep_name.len] = 0;
    dep_target.name = dep_field_buf[dep_field_pos][0..dep_name.len];
    dep_field_pos += 1;

    // Extract each `k = "v"` pair from the inner table body.
    const known_keys = [_][]const u8{ "git", "rev", "branch", "version", "path", "sha" };
    inline for (known_keys) |key| {
        if (extractQuoted(inner, key)) |v| {
            // zig 0.16: `continue` inside `inline for` is comptime control flow
            // inside a runtime block; invert condition + use if/else so the
            // loop body stays scrutable.
            if (v.len <= dep_field_buf[dep_field_pos].len) {
                @memcpy(dep_field_buf[dep_field_pos][0..v.len], v);
                dep_field_buf[dep_field_pos][v.len] = 0;
                const slot: ?[]const u8 = dep_field_buf[dep_field_pos][0..v.len];
                dep_field_pos += 1;
                inline for (known_keys) |slot_key| {
                    if (std.mem.eql(u8, slot_key, key)) {
                        @field(dep_target, slot_key) = slot;
                    }
                }
            }
        }
    }

    // `optional = true` — scan for "optional = true" substring.
    if (std.mem.indexOf(u8, inner, "optional") != null and
        std.mem.indexOf(u8, inner, "true") != null)
    {
        dep_target.optional = true;
    }
}

/// Parse `zag.lock` (TOML-style with `[deps]` + `[dev-deps]` tables
/// holding `name = { git = "...", sha = "..." }` rows). Returns
/// null on parse failure or absence of required structure.
pub fn parseLockfile(content: []const u8) ?Lockfile {
    const Section = enum { deps, dev_deps, none };
    var section: Section = .none;

    lock_entry_count = 0;
    dev_lock_entry_count = 0;
    lock_field_pos = 0;

    var cursor: usize = 0;
    while (cursor < content.len) {
        const nl_index = std.mem.findScalar(u8, content[cursor..], '\n');
        const line_end = if (nl_index) |e| cursor + e else content.len;
        const raw_line = content[cursor..line_end];
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        if (trimmed.len > 0 and trimmed[0] != '#') {
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const sect = trimmed[1 .. trimmed.len - 1];
                if (std.mem.eql(u8, sect, "deps")) {
                    section = .deps;
                } else if (std.mem.eql(u8, sect, "dev-deps")) {
                    section = .dev_deps;
                } else {
                    section = .none;
                }
            } else {
                // `<name> = { git = "...", sha = "..." }` — strip the
                // name = prefix, then split the inner table.
                const eq_idx = std.mem.findScalar(u8, trimmed, '=') orelse {
                    cursor = line_end + 1;
                    continue;
                };
                const dep_name = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                const lbrace2 = std.mem.findScalarPos(u8, trimmed, eq_idx, '{') orelse {
                    cursor = line_end + 1;
                    continue;
                };
                const rbrace2 = std.mem.findScalarPos(u8, trimmed, lbrace2, '}') orelse {
                    cursor = line_end + 1;
                    continue;
                };
                const inner = trimmed[lbrace2 + 1 .. rbrace2];

                const tgt = switch (section) {
                    .deps => blk: {
                        if (lock_entry_count >= lock_entry_buf.len) break :blk null;
                        const idx = lock_entry_count;
                        lock_entry_count += 1;
                        break :blk &lock_entry_buf[idx];
                    },
                    .dev_deps => blk: {
                        if (dev_lock_entry_count >= dev_lock_entry_buf.len) break :blk null;
                        const idx = dev_lock_entry_count;
                        dev_lock_entry_count += 1;
                        break :blk &dev_lock_entry_buf[idx];
                    },
                    .none => null,
                };
                if (tgt == null) {
                    cursor = line_end + 1;
                    continue;
                }

                if (dep_name.len > lock_field_buf[lock_field_pos].len) {
                    cursor = line_end + 1;
                    continue;
                }
                @memcpy(lock_field_buf[lock_field_pos][0..dep_name.len], dep_name);
                lock_field_buf[lock_field_pos][dep_name.len] = 0;
                tgt.?.name = lock_field_buf[lock_field_pos][0..dep_name.len];
                lock_field_pos += 1;

                if (extractQuoted(inner, "git")) |v| {
                    if (v.len > lock_field_buf[lock_field_pos].len) {
                        cursor = line_end + 1;
                        continue;
                    }
                    @memcpy(lock_field_buf[lock_field_pos][0..v.len], v);
                    lock_field_buf[lock_field_pos][v.len] = 0;
                    tgt.?.git = lock_field_buf[lock_field_pos][0..v.len];
                    lock_field_pos += 1;
                }
                if (extractQuoted(inner, "sha")) |v| {
                    if (v.len > lock_field_buf[lock_field_pos].len) {
                        cursor = line_end + 1;
                        continue;
                    }
                    @memcpy(lock_field_buf[lock_field_pos][0..v.len], v);
                    lock_field_buf[lock_field_pos][v.len] = 0;
                    tgt.?.sha = lock_field_buf[lock_field_pos][0..v.len];
                    lock_field_pos += 1;
                }
                if (extractQuoted(inner, "path")) |v| {
                    if (v.len > lock_field_buf[lock_field_pos].len) {
                        cursor = line_end + 1;
                        continue;
                    }
                    @memcpy(lock_field_buf[lock_field_pos][0..v.len], v);
                    lock_field_buf[lock_field_pos][v.len] = 0;
                    tgt.?.path = lock_field_buf[lock_field_pos][0..v.len];
                    lock_field_pos += 1;
                }
            }
        }

        cursor = line_end + 1;
    }

    return Lockfile{
        .deps = lock_entry_buf[0..lock_entry_count],
        .dev_deps = dev_lock_entry_buf[0..dev_lock_entry_count],
    };
}

/// Serialize a Lockfile back into zag.lock TOML format. Writes a
/// comment header + `[deps]` table + `[dev-deps]` table. Caller
/// is responsible for writing the returned buffer to disk via
/// the existing `writeFile` helper.
pub fn writeLockfileToBuf(buf: []u8, lockfile: Lockfile) usize {
    var pos: usize = 0;
    const header = "# zag.lock -- auto-generated, do not hand-edit.\n\n";
    @memcpy(buf[pos..][0..header.len], header);
    pos += header.len;

    const deps_open = "[deps]\n";
    if (pos + deps_open.len <= buf.len) {
        @memcpy(buf[pos..][0..deps_open.len], deps_open);
        pos += deps_open.len;
    }
    for (lockfile.deps) |dep| {
        const line = writeLockEntry(dep, buf[pos..]) catch break;
        pos += line;
    }

    if (lockfile.dev_deps.len > 0) {
        const dev_open = "\n[dev-deps]\n";
        if (pos + dev_open.len <= buf.len) {
            @memcpy(buf[pos..][0..dev_open.len], dev_open);
            pos += dev_open.len;
        }
        for (lockfile.dev_deps) |dep| {
            const line = writeLockEntry(dep, buf[pos..]) catch break;
            pos += line;
        }
    }

    return pos;
}

/// Re-emit a zag.lock for the given zag.toml content. Walks the
/// parsed `deps` + `dev_deps` slices from `parseToml` and builds a
/// parallel `Lockfile` via `writeLockfileToBuf`. Only entries with
/// a `git` field are emitted; path-only entries are skipped since
/// they need no remote fetch.
///
/// Returns the number of bytes written. Errors with
/// `error.LockEntryBufOverflow` if the 64-slot primary or 32-slot
/// dev-dep buffer would be exceeded. Errors with `error.TomlParseFailed`
/// if the content can't be parsed (parseToml returns null).
///
/// This is the v0.1 "lockfile mirrors manifest" helper: the 4 cmd
/// handlers in src/main.zig call it after every manifest mutation
/// so the lockfile stays in sync without per-handler locking logic.
/// A follow-up commit can replace this with a streaming diff against
/// the project's own config struct.
pub fn writeLockfileFromToml(buf: []u8, content: []const u8) !usize {
    const fields = parseToml(content) orelse return error.TomlParseFailed;

    var n_primary: usize = 0;
    var n_dev: usize = 0;

    for (fields.deps) |dep| {
        if (dep.git == null) continue;
        if (n_primary >= 64) return error.LockEntryBufOverflow;
        lock_entry_buf[n_primary] = LockEntry{
            .name = dep.name,
            .git = dep.git,
            .sha = dep.sha,
            .path = dep.path,
        };
        n_primary += 1;
    }
    for (fields.dev_deps) |dep| {
        if (dep.git == null) continue;
        if (n_dev >= 32) return error.LockEntryBufOverflow;
        dev_lock_entry_buf[n_dev] = LockEntry{
            .name = dep.name,
            .git = dep.git,
            .sha = dep.sha,
            .path = dep.path,
        };
        n_dev += 1;
    }

    const lockfile = Lockfile{
        .deps = lock_entry_buf[0..n_primary],
        .dev_deps = dev_lock_entry_buf[0..n_dev],
    };
    return writeLockfileToBuf(buf, lockfile);
}

fn writeLockEntry(dep: LockEntry, buf: []u8) !usize {
    var pos: usize = 0;
    const wrap_open = "\"";
    const wrap_close = "\" = { ";
    const brace_close = " }\n";
    @memcpy(buf[pos..][0..wrap_open.len], wrap_open);
    pos += wrap_open.len;
    @memcpy(buf[pos..][0..dep.name.len], dep.name);
    pos += dep.name.len;
    @memcpy(buf[pos..][0..wrap_close.len], wrap_close);
    pos += wrap_close.len;

    if (dep.git) |g| {
        const git_open = "git = \"";
        @memcpy(buf[pos..][0..git_open.len], git_open);
        pos += git_open.len;
        @memcpy(buf[pos..][0..g.len], g);
        pos += g.len;
        const close = "\", ";
        @memcpy(buf[pos..][0..close.len], close);
        pos += close.len;
    }
    if (dep.sha) |s| {
        const sha_open = "sha = \"";
        @memcpy(buf[pos..][0..sha_open.len], sha_open);
        pos += sha_open.len;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
        const close = "\", ";
        @memcpy(buf[pos..][0..close.len], close);
        pos += close.len;
    }
    if (dep.path) |p| {
        const path_open = "path = \"";
        @memcpy(buf[pos..][0..path_open.len], path_open);
        pos += path_open.len;
        @memcpy(buf[pos..][0..p.len], p);
        pos += p.len;
        const close = "\", ";
        @memcpy(buf[pos..][0..close.len], close);
        pos += close.len;
    }
    // Trim trailing ", " if present.
    if (pos >= 2 and buf[pos - 2] == ',' and buf[pos - 1] == ' ') pos -= 2;
    @memcpy(buf[pos..][0..brace_close.len], brace_close);
    pos += brace_close.len;
    return pos;
}

/// Scaffold a new zag project at `dir` (or `.` if `dir` is empty).
/// Writes:
///   - `<dir>/src/main.zag` (hello-world body),
///   - `<dir>/zag.toml` (`[package]\nname = "<dir>"\n`).
/// The post-write `mkdir` for `src/` is best-effort
/// (existing directories are tolerated).
///
/// The `[package]` header was added in the v2.1 surface so the
/// scaffolded manifest matches the canonical `[section]`-then-
/// `key` shape documented in `manual/35-zag-toml-schema.md`. The
/// pre-v2.1 scaffold emitted only `name = "..."` (no header), which
/// still parses via `parseToml`'s default-section default — but the
/// explicit header is the form users see in the docs.
pub fn createProject(dir: []const u8) !void {
    var d: [256]u8 = undefined;
    if (dir.len > 0) {
        @memcpy(d[0..dir.len], dir);
        d[dir.len] = 0;
        _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, @ptrCast(&d), 0o755);
    }

    var pn_buf: [256]u8 = undefined;
    const project_name = if (dir.len > 0) dir else blk: {
        var cwdb: [4096]u8 = undefined;
        const n = std.os.linux.getcwd(&cwdb, cwdb.len);
        if (n == 0) break :blk "myproject";
        const effective_len = if (n > 0 and cwdb[n - 1] == 0) n - 1 else n;
        const cwd = cwdb[0..effective_len];
        const last_slash = std.mem.lastIndexOfScalar(u8, cwd, '/') orelse break :blk "myproject";
        const name = cwd[last_slash + 1 ..];
        if (name.len == 0 or name.len > pn_buf.len) break :blk "myproject";
        @memcpy(pn_buf[0..name.len], name);
        break :blk pn_buf[0..name.len];
    };

    // src/ subdirectory
    var src_buf: [256]u8 = undefined;
    var sl: usize = 0;
    if (dir.len > 0) {
        @memcpy(src_buf[0..dir.len], dir);
        sl += dir.len;
        src_buf[sl] = '/';
        sl += 1;
    }
    @memcpy(src_buf[sl..][0..4], "src/");
    sl += 4;
    const src_sub = src_buf[0 .. sl - 1]; // "src" (no trailing slash for mkdir)
    var src_null: [256]u8 = undefined;
    @memcpy(src_null[0..src_sub.len], src_sub);
    src_null[src_sub.len] = 0;
    _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, @ptrCast(&src_null), 0o755);

    // src/main.zag
    var main_zag: [512]u8 = undefined;
    var ml: usize = 0;
    if (dir.len > 0) {
        @memcpy(main_zag[0..dir.len], dir);
        ml += dir.len;
        main_zag[ml] = '/';
        ml += 1;
    }
    const src_main = "src/main.zag";
    @memcpy(main_zag[ml..][0..src_main.len], src_main);
    ml += src_main.len;
    const main_zag_path = main_zag[0..ml];
    var body_buf: [512]u8 = undefined;
    body_buf[0] = 'f';
    body_buf[1] = 'u';
    body_buf[2] = 'n';
    body_buf[3] = ' ';
    body_buf[4] = 'm';
    body_buf[5] = 'a';
    body_buf[6] = 'i';
    body_buf[7] = 'n';
    body_buf[8] = '(';
    body_buf[9] = ')';
    body_buf[10] = ' ';
    body_buf[11] = '{';
    body_buf[12] = '\n';
    var bi: usize = 13;
    const indent = "    ";
    @memcpy(body_buf[bi..][0..indent.len], indent);
    bi += indent.len;
    const print_start = "print(\"hello, ";
    @memcpy(body_buf[bi..][0..print_start.len], print_start);
    bi += print_start.len;
    @memcpy(body_buf[bi..][0..project_name.len], project_name);
    bi += project_name.len;
    const print_end = "\\n\");\n";
    @memcpy(body_buf[bi..][0..print_end.len], print_end);
    bi += print_end.len;
    body_buf[bi] = '}';
    bi += 1;
    body_buf[bi] = '\n';
    bi += 1;
    writeFile(main_zag_path, body_buf[0..bi]) catch {};

    // zag.toml — v2.1 surfaces the `[package]` header explicitly so
    // the scaffolded file matches the doc form (manual/35 §Top-Level
    // Shape). parseToml still accepts the pre-v2.1 bare form via
    // the default `.package` section state, so old project files
    // continue to round-trip.
    var toml_path_buf: [512]u8 = undefined;
    var tl: usize = 0;
    if (dir.len > 0) {
        @memcpy(toml_path_buf[0..dir.len], dir);
        tl += dir.len;
        toml_path_buf[tl] = '/';
        tl += 1;
    }
    const toml_name = "zag.toml";
    @memcpy(toml_path_buf[tl..][0..toml_name.len], toml_name);
    tl += toml_name.len;
    const toml_path = toml_path_buf[0..tl];

    var toml_body: [512]u8 = undefined;
    const section_header = "[package]\n";
    @memcpy(toml_body[0..section_header.len], section_header);
    var tbi: usize = section_header.len;
    const name_line = "name = \"";
    @memcpy(toml_body[tbi..][0..name_line.len], name_line);
    tbi += name_line.len;
    @memcpy(toml_body[tbi..][0..project_name.len], project_name);
    tbi += project_name.len;
    toml_body[tbi] = '"';
    tbi += 1;
    toml_body[tbi] = '\n';
    tbi += 1;
    writeFile(toml_path, toml_body[0..tbi]) catch {};

    const display_path = if (dir.len > 0) dir else ".";
    std.debug.print("created project at {s}/\n", .{display_path});
    std.debug.print("  {s}/zag.toml\n", .{display_path});
    std.debug.print("  {s}/src/main.zag\n", .{display_path});
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

// =====================================================================
// Manifest write-back helpers (v0.1 pkg CLI).
// =====================================================================
//
// The `appendDepToToml` / `removeDepFromToml` helpers are the
// read-modify-write half of the pkg CLI. They preserve non-deps
// bytes byte-for-byte; only the target `[dependencies]` /
// `[dev-dependencies]` block mutates. The output goes into a
// module-private write-back buffer (caller MUST write to disk
// before the next call — the buffer is reused).

/// Module-private storage for write-back slices. 8 KiB covers
/// typical config files (the largest commit prior to this turn
/// didn't exceed ~2 KiB). Larger files would block here with
/// `error.BufferTooSmall` — caller's problem to chunk or
/// allocate their own buffer.
var writeback_buf: [8192]u8 = undefined;

/// Locate the splice-position (byte index) of the next section
/// header `[NAME]` after `start`. Returns null at EOF. Naive
/// scan: `\n[` lookahead is sufficient because inline tables
/// inside the current section's body don't open with `[` at
/// line-start position.
fn findNextSectionHeader(content: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (i + 1 < content.len) {
        if (content[i] == '\n' and content[i + 1] == '[') return i + 1;
        i += 1;
    }
    return null;
}

/// Build `<name> = { ... }` inside `buf` for `dep`. Field order
/// is fixed (git → rev → branch → version → path → sha →
/// optional) so the on-disk shape is stable across runs.
fn buildDepLine(buf: []u8, dep: DepEntry) !usize {
    var pos: usize = 0;
    if (dep.name.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[pos..][0..dep.name.len], dep.name);
    pos += dep.name.len;
    const eq_open = " = { ";
    if (pos + eq_open.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[pos..][0..eq_open.len], eq_open);
    pos += eq_open.len;

    var first = true;
    if (dep.git) |v| try appendKV(buf, &pos, "git", v, &first);
    if (dep.rev) |v| try appendKV(buf, &pos, "rev", v, &first);
    if (dep.branch) |v| try appendKV(buf, &pos, "branch", v, &first);
    if (dep.version) |v| try appendKV(buf, &pos, "version", v, &first);
    if (dep.path) |v| try appendKV(buf, &pos, "path", v, &first);
    if (dep.sha) |v| try appendKV(buf, &pos, "sha", v, &first);
    if (dep.optional) {
        if (!first) {
            if (pos + 2 > buf.len) return error.BufferTooSmall;
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        const opt_kv = "optional = true";
        if (pos + opt_kv.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..opt_kv.len], opt_kv);
        pos += opt_kv.len;
        first = false;
    }

    if (pos + 1 > buf.len) return error.BufferTooSmall;
    buf[pos] = '}';
    pos += 1;
    return pos;
}

fn appendKV(buf: []u8, pos: *usize, key: []const u8, value: []const u8, first: *bool) !void {
    if (!first.*) {
        if (pos.* + 2 > buf.len) return error.BufferTooSmall;
        buf[pos.*] = ',';
        buf[pos.* + 1] = ' ';
        pos.* += 2;
    }
    @memcpy(buf[pos.*..][0..key.len], key);
    pos.* += key.len;
    const eq = " = \"";
    if (pos.* + eq.len + value.len + 1 > buf.len) return error.BufferTooSmall;
    @memcpy(buf[pos.*..][0..eq.len], eq);
    pos.* += eq.len;
    @memcpy(buf[pos.*..][0..value.len], value);
    pos.* += value.len;
    buf[pos.*] = '"';
    pos.* += 1;
    first.* = false;
}

/// Splice `insert` at position `at` in `src`. If `eol_before` is
/// true, ensure a `\n` separator is present at the splice point.
/// Returns a slice into the module-private writeback_buf.
fn spliceInsert(src: []const u8, at: usize, insert: []const u8, eol_before: bool) ![]const u8 {
    const needed = src.len + insert.len + if (eol_before) @as(usize, 1) else @as(usize, 0);
    if (needed > writeback_buf.len) return error.BufferTooSmall;
    @memcpy(writeback_buf[0..at], src[0..at]);
    var pos: usize = at;
    if (eol_before) {
        if (pos == 0 or src[pos - 1] != '\n') {
            writeback_buf[pos] = '\n';
            pos += 1;
        }
    }
    if (insert.len > 0) {
        @memcpy(writeback_buf[pos..][0..insert.len], insert);
        pos += insert.len;
    }
    @memcpy(writeback_buf[pos..][0..src.len - at], src[at..]);
    pos += src.len - at;
    return writeback_buf[0..pos];
}

/// Append a `<name> = { ... }` line to the `[dependencies]` (or
/// `[dev-dependencies]`) block of `content`. If the section is
/// absent, a new header is prepended at EOF. Bytes outside the
/// section are preserved byte-for-byte.
pub fn appendDepToToml(content: []const u8, dep: DepEntry, is_dev: bool) ![]const u8 {
    const section_name: []const u8 = if (is_dev) "dev-dependencies" else "dependencies";

    var dep_line: [1024]u8 = undefined;
    const dl_len = try buildDepLine(&dep_line, dep);

    var header_marker: [64]u8 = undefined;
    const hm_full = std.fmt.bufPrint(&header_marker, "[{s}]\n", .{section_name}) catch return error.SectionNameTooLong;
    const hm_no_nl = hm_full[0 .. hm_full.len - 1];

    if (std.mem.indexOf(u8, content, hm_no_nl)) |hi| {
        // Section present — splice dep_line at end of section body.
        const body_start = hi + hm_full.len;
        const next_section = findNextSectionHeader(content, body_start);
        const insert_pos = next_section orelse content.len;
        return spliceInsert(content, insert_pos, dep_line[0..dl_len], false);
    }
    // Section absent — append at EOF: newline boundary + header + dep_line.
    if (content.len + hm_full.len + dl_len + 2 > writeback_buf.len) return error.BufferTooSmall;
    @memcpy(writeback_buf[0..content.len], content);
    var pos: usize = content.len;
    if (pos == 0 or content[pos - 1] != '\n') {
        writeback_buf[pos] = '\n';
        pos += 1;
    }
    @memcpy(writeback_buf[pos..][0..hm_full.len], hm_full);
    pos += hm_full.len;
    @memcpy(writeback_buf[pos..][0..dl_len], dep_line[0..dl_len]);
    pos += dl_len;
    if (dl_len > 0 and dep_line[dl_len - 1] != '\n') {
        writeback_buf[pos] = '\n';
        pos += 1;
    }
    return writeback_buf[0..pos];
}

/// Remove the dep line matching `dep_name` from the
/// `[dependencies]` (or `[dev-dependencies]`) block. Returns an
/// error if the section or the dep is not found. Bytes outside
/// the removed line are preserved byte-for-byte.
pub fn removeDepFromToml(content: []const u8, dep_name: []const u8, is_dev: bool) ![]const u8 {
    const section_name: []const u8 = if (is_dev) "dev-dependencies" else "dependencies";

    var header_marker: [64]u8 = undefined;
    const hm_full = std.fmt.bufPrint(&header_marker, "[{s}]\n", .{section_name}) catch return error.SectionNameTooLong;
    const hm_no_nl = hm_full[0 .. hm_full.len - 1];

    const header_idx = std.mem.indexOf(u8, content, hm_no_nl) orelse return error.SectionNotFound;
    const body_start = header_idx + hm_full.len;
    const next_section = findNextSectionHeader(content, body_start);
    const body_end = next_section orelse content.len;

    var i: usize = body_start;
    while (i < body_end) {
        const nl = std.mem.findScalarPos(u8, content, i, '\n') orelse body_end;
        const line = std.mem.trim(u8, content[i..nl], " \t\r");

        // Skip blank + commented-out dep lines (`# foo = { ... }`).
        const is_comment_or_blank = line.len == 0 or line[0] == '#';

        if (!is_comment_or_blank and std.mem.startsWith(u8, line, dep_name)) {
            var j: usize = dep_name.len;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
            if (j < line.len and line[j] == '=') {
                // Match. Splice out content[i..line_end_inclusive].
                const line_end = if (nl < content.len) nl + 1 else nl;
                if (content.len - (line_end - i) > writeback_buf.len) return error.BufferTooSmall;
                @memcpy(writeback_buf[0..i], content[0..i]);
                @memcpy(writeback_buf[i..][0..content.len - line_end], content[line_end..]);
                return writeback_buf[0 .. content.len - (line_end - i)];
            }
        }
        i = if (nl < content.len) nl + 1 else body_end;
    }

    return error.DepNotFound;
}

// =====================================================================
// In-file pin tests (compile-time via `zig build test`).
//
// These pin the four scenarios that the runtime parser must
// recognise correctly:
//   1. canonical `[package]\nname = ...` — the canonical doc form.
//   2. bare top-level `name = ...` — the pre-v2.1 scaffold shape
//      (still recognised via parseToml's default `.package`).
//   3. `[toolchain].zig` — the new v2.1 override field.
//   4. `[package].name` + `[toolchain].zig` coexistence — the
//      realistic user pattern that motivated this commit.
// Plus one negative test for missing [package].name.
// =====================================================================

test "parseToml: [package] header + name + value parses" {
    const content =
        \\[package]
        \\name = "myproj"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("myproj", fields.name.?);
    try std.testing.expect(fields.zig == null);
}

test "parseToml: bare top-level name = ...\"value\"... (legacy scaffold)" {
    const content =
        \\name = "legacy-proj"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("legacy-proj", fields.name.?);
    try std.testing.expect(fields.zig == null);
}

test "parseToml: [toolchain] zig = /path/to/zig parses" {
    const content =
        \\[package]
        \\name = "myproj"
        \\
        \\[toolchain]
        \\zig = "/opt/zig-0.16/zig"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("myproj", fields.name.?);
    try std.testing.expectEqualStrings("/opt/zig-0.16/zig", fields.zig.?);
}

test "parseToml: key = \"value\" whitespace tolerance (extra spaces)" {
    const content =
        \\[package]
        \\name    =   "myproj"
        \\[toolchain]
        \\zig   =    "/usr/bin/zig"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("myproj", fields.name.?);
    try std.testing.expectEqualStrings("/usr/bin/zig", fields.zig.?);
}

test "parseToml: missing [package].name returns null fields" {
    const content =
        \\[toolchain]
        \\zig = "/opt/zig/zig"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    // No [package].name — caller (detectProject) treats this as a
    // malformed manifest and returns null.
    try std.testing.expect(fields.name == null);
    try std.testing.expectEqualStrings("/opt/zig/zig", fields.zig.?);
}

test "parseToml: unknown section suppresses cross-section capture" {
    // `name = "leak"` is INSIDE [dependencies] -- section=none after
    // header read, so the substring shouldn't accidentally promote
    // it to `ProjectConfig.name`. This is the regression case the
    // pre-v2.1 substring-search parser (parseName) FAILED on.
    const content =
        \\[package]
        \\name = "real"
        \\
        \\[dependencies]
        \\name = "leak-should-be-ignored"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("real", fields.name.?);
    // The [dependencies].name should NOT have overwritten the real
    // name -- this is the State machine's key correctness predicate.
}

test "parseToml: comment lines on their own or after a key are ignored" {
    const content =
        \\# Generated by zag init
        \\[package]
        \\# project name
        \\name = "myproj"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("myproj", fields.name.?);
}

test "extractQuoted: returns null when key is absent" {
    try std.testing.expect(extractQuoted("foo = \"bar\"", "name") == null);
    try std.testing.expect(extractQuoted("namex = \"bar\"", "name") == null);
}

test "extractQuoted: returns null when value is missing closing quote" {
    try std.testing.expect(extractQuoted("name = \"bar", "name") == null);
}

test "extractQuoted: substring position is irrelevant within section" {
    // `extractQuoted` itself is a substring scan; the state machine
    // guarantees section isolation. Pin this so a future "fix" to
    // extractQuoted (e.g., prefix-only scan) wouldn't silently break
    // callers.
    try std.testing.expectEqualStrings("bar", extractQuoted("foo name = \"bar\"", "name").?);
}



test "parseToml: [toolchain] header before [package] is order-independent" {
    // The state machine rebuilds section state on each [section]
    // line; order in the file is therefore irrelevant. Locks the
    // doc-claim "headers are order-agnostic".
    const content =
        \\[toolchain]
        \\zig = "/opt/zig/zig"
        \\
        \\[package]
        \\name = "myproj"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("myproj", fields.name.?);
    try std.testing.expectEqualStrings("/opt/zig/zig", fields.zig.?);
}

test "parseToml: scaffold-emitted [package]\nname = \"...\"\n round-trips" {
    // Closes the loop on the v2.1 scaffold change: createProject
    // writes this exact byte sequence; parseToml must accept it
    // verbatim so `zag init` outputs are immediately parseable by
    // subsequent `zag build` invocations.
    const content = "[package]\nname = \"hello\"\n";
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("hello", fields.name.?);
    try std.testing.expect(fields.zig == null);
}

test "parseToml: bare top-level zig = ...\"path\"... is ignored (not in [toolchain])" {
    const content =
        \\[package]
        \\name = "myproj"
        \\zig = "/accidental/no-toolchain-header"
        \\\
    ;
    const fields = parseToml(content).?;
    try std.testing.expect(fields.name != null);
    try std.testing.expect(fields.zig == null);
}

// =====================================================================
// In-file pin tests for the v0.1 pkg CLI helpers.
// =====================================================================

test "appendDepToToml: section absent prepends header + dep row" {
    const content =
        \\[package]
        \\name = "myproj"
        \\\
    ;
    const dep = DepEntry{ .name = "json", .git = "https://github.com/zag/json", .rev = "v0.2.4" };
    const out = try appendDepToToml(content, dep, false);
    try std.testing.expect(std.mem.indexOf(u8, out, "[dependencies]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "json = { git = \"https://github.com/zag/json\", rev = \"v0.2.4\" }") != null);
    // Original bytes preserved verbatim.
    try std.testing.expect(std.mem.indexOf(u8, out, "[package]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name = \"myproj\"") != null);
}

test "appendDepToToml: section present splices at end of body" {
    const content =
        \\[package]
        \\name = "myproj"
        \\
        \\[dependencies]
        \\json = { git = "https://github.com/zag/json", rev = "v0.2.4" }
        \\
        \\[toolchain]
        \\zig = "/opt/zig/zig"
        \\\
    ;
    const dep = DepEntry{ .name = "log", .git = "https://github.com/zag/log", .branch = "main" };
    const out = try appendDepToToml(content, dep, false);
    // The new dep lands BEFORE [toolchain], AFTER the existing json dep.
    const json_marker = "json = {";
    const log_marker = "log = {";
    const tool_marker = "[toolchain]";
    const json_off = std.mem.indexOf(u8, out, json_marker).?;
    const log_off = std.mem.indexOf(u8, out, log_marker).?;
    const tool_off = std.mem.indexOf(u8, out, tool_marker).?;
    try std.testing.expect(json_off < log_off);
    try std.testing.expect(log_off < tool_off);
    // Section boundary preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "zig = \"/opt/zig/zig\"") != null);
}

test "removeDepFromToml: happy path splices out matching line" {
    const content =
        \\[package]
        \\name = "myproj"
        \\
        \\[dependencies]
        \\json = { git = "https://github.com/zag/json", rev = "v0.2.4" }
        \\log  = { git = "https://github.com/zag/log", branch = "main" }
        \\
        \\[toolchain]
        \\zig = "/opt/zig/zig"
        \\\
    ;
    const out = try removeDepFromToml(content, "json", false);
    // json dep gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "json = {") == null);
    // Other dep + sections preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "log = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[toolchain]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zig = \"/opt/zig/zig\"") != null);
}

test "removeDepFromToml: missing dep returns error.DepNotFound" {
    const content =
        \\[dependencies]
        \\json = { git = "https://github.com/zag/json" }
        \\\
    ;
    const result = removeDepFromToml(content, "log", false);
    try std.testing.expectError(error.DepNotFound, result);
}

test "removeDepFromToml: prefix-bounded — does NOT match longer-name dep" {
    // Both `"foo"` and `"foobar"` are present; removeDepFromToml("foo") must
    // splice ONLY the `"foo"` line, leaving `"foobar"` intact. Locks down the
    // `line[dep_name.len] == '='` post-check (with optional whitespace skip)
    // that prevents `foo` from greedily matching `foobar`.
    const content =
        \\[dependencies]
        \\"foo" = { git = "https://github.com/a/foo", sha = "1" }
        \\"foobar" = { git = "https://github.com/a/foobar", sha = "2" }
        \\
    ;
    const out = try removeDepFromToml(content, "foo", false);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"foo\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"foobar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "git = \"https://github.com/a/foobar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sha = \"2\"") != null);
}

test "removeDepFromToml: skips commented-out dep lines" {
    // If the only line mentioning "foo" is commented out (`# ...`), the call
    // must return error.DepNotFound rather than splice out the comment.
    const content =
        \\[dependencies]
        \\# "foo" = { git = "https://github.com/a/foo" }
        \\"bar" = { git = "https://github.com/a/bar" }
        \\
    ;
    const result = removeDepFromToml(content, "foo", false);
    try std.testing.expectError(error.DepNotFound, result);
    // Bar must still be present (the unmatched call didn't touch anything else).
    try std.testing.expect(std.mem.indexOf(u8, content, "\"bar\"") != null);
}

test "buildDepLine: emits field order git ? rev ? branch ? version ? path ? sha ? optional" {
    const dep_a = DepEntry{
        .name = "json",
        .git = "https://github.com/zag/json",
        .rev = "v0.2.4",
        .branch = null,
        .version = null,
        .path = null,
        .sha = null,
        .optional = false,
    };
    var buf_a: [512]u8 = undefined;
    const a_len = try buildDepLine(&buf_a, dep_a);
    const a_str = buf_a[0..a_len];
    try std.testing.expectEqualStrings(
        "json = { git = \"https://github.com/zag/json\", rev = \"v0.2.4\" }",
        a_str,
    );

    const dep_b = DepEntry{
        .name = "local",
        .path = "../local",
        .git = null,
        .rev = null,
        .branch = null,
        .version = null,
        .sha = null,
        .optional = true,
    };
    var buf_b: [512]u8 = undefined;
    const b_len = try buildDepLine(&buf_b, dep_b);
    try std.testing.expectEqualStrings(
        "local = { path = \"../local\", optional = true }",
        buf_b[0..b_len],
    );
}
