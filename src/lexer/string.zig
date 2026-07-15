const std = @import("std");

const core = @import("core.zig");
const Lexer = core.Lexer;

const token = @import("token.zig");
const TokenTag = token.TokenTag;

const ast = @import("../ast.zig");
const Loc = ast.Loc;

// ============================================================
// string.zig
// ============================================================

pub     fn readString(self: *Lexer, start_loc: ast.Loc) void {
    self.pos += 1;
    self.col += 1;
    const start = self.pos;
    while (self.pos < self.src.len and self.src[self.pos] != '"') {
        if (self.src[self.pos] == '\\') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
                self.pos += 2;
                self.col += 2;
            } else {
                self.pos += 1;
                self.col += 1;
            }
        } else {
            self.pos += 1;
            self.col += 1;
        }
    }
    const text = self.src[start..self.pos];
    if (self.pos < self.src.len) {
        self.pos += 1;
        self.col += 1;
    }
    self.addToken(.{ .tag = .string_literal, .loc = start_loc, .text = text });
}

pub     fn readByteString(self: *Lexer, start_loc: ast.Loc) void {
    self.pos += 2; // skip 'b"'
    self.col += 2;

    const start = self.pos;
    while (self.pos < self.src.len and self.src[self.pos] != '"') {
        if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
            self.pos += 2;
            self.col += 2;
        } else {
            self.pos += 1;
            self.col += 1;
        }
    }
    const text = self.src[start..self.pos];
    if (self.pos < self.src.len) {
        self.pos += 1;
        self.col += 1;
    }
    self.addToken(.{ .tag = .byte_string_literal, .loc = start_loc, .text = text });
}

pub     fn readChar(self: *Lexer, start_loc: ast.Loc) void {
    const start = self.pos;
    self.pos += 1; // skip opening '
    self.col += 1;

    while (self.pos < self.src.len and self.src[self.pos] != '\n' and self.src[self.pos] != '\'') {
        if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
            self.pos += 1;
            self.col += 1;
        }
        if (self.pos < self.src.len) {
            self.pos += 1;
            self.col += 1;
        }
    }

    if (self.pos < self.src.len and self.src[self.pos] == '\'') {
        self.pos += 1; // skip closing '
        self.col += 1;
    }

    const raw = self.src[start..self.pos];
    // v2 char fix path (docs/features.md §08 v2 4-byte Unicode char
    // row, gap (b)): bare `\uNNNN` escapes are normalized to brace
    // form `\u{NNNN}` so downstream zig 0.16 accepts the escape. The
    // detection rule is intentionally narrow: 8-char slice `'\uHHHH'`
    // (apostrophe, backslash, u, 4 hex digits, apostrophe). Braced
    // form `'\u{HHHH}'` and other escapes (`\n`, `\t`, `\xNN`, ASCII
    // chars) are preserved verbatim. MALFORMED-INPUT: `'\u276g'`
    // (non-hex digit in the 4-hex position) is preserved verbatim —
    // the `is_bare_unicode_escape` predicate requires all 4 chars
    // after `\u` to be valid hex; downstream zig then rejects with
    // its brace-unicode grammar error rather than silent
    // normalize-skip. See lexer test (b) `'\u2764' char literal
    // normalized to brace form (v2 fix path landed)` for the pin.
    if (is_bare_unicode_escape(raw)) {
        // Defensive bounds check: 256 slots cover any realistic zag
        // source. The dynamic `@panic` message includes the actual
        // count + capacity so the maintainer can triage the failure
        // mode at runtime; increase the `char_norm_bufs: [256][16]u8`
        // size in src/lexer/core.zig's Lexer struct if a source has
        // more normalized char literals than this.
        if (self.char_norm_count >= self.char_norm_bufs.len) {
            var msg_buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "char_norm_bufs exhausted (count={d}, capacity={d}); increase the char_norm_bufs size in src/lexer/core.zig Lexer struct", .{ self.char_norm_count, self.char_norm_bufs.len }) catch unreachable;
            @panic(msg);
        }
        const slot = self.char_norm_count;
        const buf = &self.char_norm_bufs[slot];
        buf[0] = '\'';
        buf[1] = '\\';
        buf[2] = 'u';
        buf[3] = '{';
        buf[4] = raw[3];
        buf[5] = raw[4];
        buf[6] = raw[5];
        buf[7] = raw[6];
        buf[8] = '}';
        buf[9] = '\'';
        self.char_norm_count += 1;
        self.addToken(.{ .tag = .char_literal, .loc = start_loc, .text = buf[0..10] });
        return;
    }
    self.addToken(.{ .tag = .char_literal, .loc = start_loc, .text = raw });
}

/// Returns true if `raw` is exactly the 8-char bare `'\uHHHH'` escape (apostrophe,
/// backslash, 'u', 4 hex digits, apostrophe); other shapes are preserved verbatim.
fn is_bare_unicode_escape(raw: []const u8) bool {
    return raw.len == 8 and raw[0] == '\'' and raw[1] == '\\' and raw[2] == 'u' and
        is_hex_digit(raw[3]) and is_hex_digit(raw[4]) and is_hex_digit(raw[5]) and is_hex_digit(raw[6]) and raw[7] == '\'';
}

/// Returns true if `c` is a base-16 digit (0-9 / a-f / A-F).
fn is_hex_digit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

