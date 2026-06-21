const std = @import("std");

const core = @import("core.zig");
const Lexer = core.Lexer;

const token = @import("token.zig");
const TokenTag = token.TokenTag;

const ast = @import("../ast.zig");
const Loc = ast.Loc;

// ============================================================
// number.zig
// ============================================================

pub     fn readNumber(self: *Lexer, start_loc: ast.Loc) void {
    const start = self.pos;
    if (self.src[self.pos] == '-' or self.src[self.pos] == '+') {
        self.pos += 1;
        self.col += 1;
    }

    // Detect integer prefix: 0x, 0o, 0b
    if (self.pos + 1 < self.src.len and self.src[self.pos] == '0') {
        const next = self.src[self.pos + 1];
        if (next == 'x' or next == 'X') {
            self.pos += 2;
            self.col += 2;
            while (self.pos < self.src.len and (isHexDigit(self.src[self.pos]) or self.src[self.pos] == '_')) {
                self.pos += 1;
                self.col += 1;
            }
            self.addToken(.{ .tag = .integer_literal, .loc = start_loc, .text = self.src[start..self.pos] });
            return;
        } else if (next == 'o' or next == 'O') {
            self.pos += 2;
            self.col += 2;
            while (self.pos < self.src.len and ((self.src[self.pos] >= '0' and self.src[self.pos] <= '7') or self.src[self.pos] == '_')) {
                self.pos += 1;
                self.col += 1;
            }
            self.addToken(.{ .tag = .integer_literal, .loc = start_loc, .text = self.src[start..self.pos] });
            return;
        } else if (next == 'b' or next == 'B') {
            self.pos += 2;
            self.col += 2;
            while (self.pos < self.src.len and (self.src[self.pos] == '0' or self.src[self.pos] == '1' or self.src[self.pos] == '_')) {
                self.pos += 1;
                self.col += 1;
            }
            self.addToken(.{ .tag = .integer_literal, .loc = start_loc, .text = self.src[start..self.pos] });
            return;
        }
    }

    // Decimal: digits + underscores
    while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) {
        self.pos += 1;
        self.col += 1;
    }

    var is_float = false;

    // Fractional: . + digit
    if (self.pos < self.src.len and self.src[self.pos] == '.' and
        self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))
    {
        is_float = true;
        self.pos += 1;
        self.col += 1;
        while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
            self.col += 1;
        }
    }

    // Exponent: e / E [ + / - ] digit+
    if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
        is_float = true;
        self.pos += 1;
        self.col += 1;
        if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
            self.pos += 1;
            self.col += 1;
        }
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
            self.pos += 1;
            self.col += 1;
        }
    }

    const tag: TokenTag = if (is_float) .float_literal else .integer_literal;
    self.addToken(.{ .tag = tag, .loc = start_loc, .text = self.src[start..self.pos] });
}
// ============================================================
// number.zig — file-scope free fn from src/lexer.zig
// ============================================================

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
