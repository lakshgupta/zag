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

/// Walk `src/` and discover all `.zag` source files. Returns a slice
/// of ModuleEntry structures, each with a path and derived module
/// name. Files are discovered in order.
pub fn discoverModules() []const ModuleEntry {
    module_count = 0;
    module_paths_pos = 0;
    module_names_pos = 0;

    // Check src/main.zag (required entry point)
    if (posix.openat(posix.AT.FDCWD, "src/main.zag", .{ .ACCMODE = .RDONLY }, 0)) |fd| {
        _ = std.os.linux.close(fd);
        addModuleEntry("src/main.zag", "main") catch {};
    } else |_| {
        return &[_]ModuleEntry{};
    }

    // Scan for additional modules in src/ using a simple approach:
    // list all .zag files by trying common patterns.
    // Full getdents64 enumeration is deferred — for v1 we support a
    // hardcoded set of common module directory + file patterns.
    const modules = [_][]const u8{
        "lib", "math", "util", "types", "io", "parse", "config",
        "models", "handlers", "services", "db", "api", "cli",
    };
    for (modules) |m| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "src/{s}.zag", .{m}) catch continue;
        if (posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            _ = std.os.linux.close(fd);
            addModuleEntry(path, m) catch {};
        } else |_| {}
    }

    return module_buf[0..module_count];
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
const TomlFields = struct {
    name: ?[]const u8,
    zig: ?[]const u8,
};

/// State-machine line walker for zag.toml. Recognises:
///   - `[section]` headers — switches the active section;
///   - `key = "value"` body lines — captures the quoted value into
///     the active section's slot.
/// Section "package" is the implicit top-level (initial state) so
/// that legacy scaffold output (bare `name = "..."` without a
/// `[package]` header) keeps parsing in lockstep with the new
/// scaffold format (`[package]\nname = "..."`). Section "toolchain"
/// is explicit-only (must be declared in the file to be picked up).
/// Other sections (forward-looking `[dependencies]`, `[build]`,
/// etc.) switch the state to `.none`, suppressing accidental
/// capture of `name`/`zig`-shaped keys from unrelated subtables.
///
/// Implementation note: section state starts as `.package` rather
/// than `.none` purely for backward compatibility — the pre-v2.1
/// scaffold (`createProject` used to emit just `name = "..."`)
/// still parses. New scaffolds emit `[package]\nname = "..."`
/// explicitly (clearer intent, matches the schema doc).
fn parseToml(content: []const u8) ?TomlFields {
    const Section = enum { package, toolchain, none };
    var section: Section = .package; // backward-compat default
    var name_field: ?[]const u8 = null;
    var zig_field: ?[]const u8 = null;

    var cursor: usize = 0;
    while (cursor < content.len) {
        const nl_index = std.mem.indexOfScalar(u8, content[cursor..], '\n');
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
                } else if (std.mem.eql(u8, sect, "toolchain")) {
                    section = .toolchain;
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
                    .none => {},
                }
            }
        }

        cursor = line_end + 1;
    }

    return TomlFields{ .name = name_field, .zig = zig_field };
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
    const vrel_end = std.mem.indexOfScalar(u8, line[vstart..], '"') orelse return null;
    return line[vstart..][0..vrel_end];
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
    // Subtle invariant: parser starts in .package state, so a
    // bare `zig = "..."` key without a preceding [toolchain]
    // header is silently dropped. Confirms the opt-in-to-override
    // contract -- accidental naked keys don't accidentally enable
    // the override.
    const content =
        \\[package]
        \\name = "myproj"
        \\zig = "/accidental/no-toolchain-header"
        \\
    ;
    cfg_name_buf = [_]u8{0} ** cfg_name_buf.len;
    cfg_zig_buf = [_]u8{0} ** cfg_zig_buf.len;
    const fields = parseToml(content).?;
    try std.testing.expectEqualStrings("myproj", fields.name.?);
    try std.testing.expect(fields.zig == null);
}
