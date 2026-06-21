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

    self.addToken(.{ .tag = .char_literal, .loc = start_loc, .text = self.src[start..self.pos] });
}

