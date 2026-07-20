const std = @import("std");
const posix = std.posix;

pub const ProjectConfig = struct {
    name: []const u8,
    root_dir: []const u8,
};

const zag_toml_prefix: []const u8 = "name = \"";
const zag_toml_suffix: u8 = '"';

var cfg_name_buf: [256]u8 = undefined;

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
    if (parseName(content)) |name| {
        return ProjectConfig{
            .name = name,
            .root_dir = root_dir,
        };
    }
    return null;
}

fn parseName(content: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, content, zag_toml_prefix)) |start| {
        const value_start = start + zag_toml_prefix.len;
        if (std.mem.indexOfScalar(u8, content[value_start..], zag_toml_suffix)) |end| {
            const name = content[value_start..][0..end];
            if (name.len > 0 and name.len <= cfg_name_buf.len) {
                @memcpy(cfg_name_buf[0..name.len], name);
                return cfg_name_buf[0..name.len];
            }
        }
    }
    return null;
}

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
    // Note: uses project name in boilerplate — compute the formatted string
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

    // zag.toml
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
    const name_line = "name = \"";
    @memcpy(toml_body[0..name_line.len], name_line);
    var tbi: usize = name_line.len;
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
