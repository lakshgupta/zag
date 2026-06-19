const std = @import("std");
const ast = @import("ast.zig");

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub const TokenTag = enum {
    fun,
    let,
    var_kw,
    const_kw,
    defer_kw,
    new,
    free,
    print,
    return_kw,
    true_kw,
    false_kw,
    null_kw,
    undefined_kw,
    string_literal,
    byte_string_literal,
    char_literal,
    integer_literal,
    float_literal,
    identifier,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    colon,
    equals,
    plus,
    minus,
    star,
    slash,
    comma,
    arrow,
    ellipsis,
    newline,
    doc_comment,
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    loc: ast.Loc,
    text: []const u8,
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32,
    line: u32,
    col: u32,
    tokens_buf: [4096]Token,
    tokens_len: u32,

    pub fn init(src: []const u8) Lexer {
        return .{
            .src = src,
            .pos = 0,
            .line = 1,
            .col = 1,
            .tokens_buf = undefined,
            .tokens_len = 0,
        };
    }

    fn addToken(self: *Lexer, tok: Token) void {
        self.tokens_buf[self.tokens_len] = tok;
        self.tokens_len += 1;
    }

    pub fn tokenize(self: *Lexer) []const Token {
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            const start_loc = ast.Loc{ .line = self.line, .col = self.col, .offset = self.pos };

            if (ch == '#') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '#') {
                    self.readDocComment(start_loc);
                } else {
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                        self.pos += 1;
                        self.col += 1;
                    }
                }
                continue;
            }

            if (ch == '\n') {
                self.addToken(.{ .tag = .newline, .loc = start_loc, .text = "\n" });
                self.pos += 1;
                self.line += 1;
                self.col = 1;
                continue;
            }

            if (ch == ' ' or ch == '\t' or ch == '\r') {
                self.pos += 1;
                self.col += 1;
                continue;
            }

            if (ch == 'b' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
                self.readByteString(start_loc);
                continue;
            }

            if (ch == '"') {
                self.readString(start_loc);
                continue;
            }

            if (ch == '\'') {
                self.readChar(start_loc);
                continue;
            }

            if (std.ascii.isDigit(ch)
                or (ch == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))
                or (ch == '+' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])))
            {
                // Number prefix: `5`, `-5`, `+5`, `-.5` (the `-`/`+` may
                // immediately precede a decimal fraction via readNumber's
                // sign-handler). Symmetry with `+` keeps the surface uniform
                // even though `+x` unary is rare in idiomatic zag code.
                self.readNumber(start_loc);
                continue;
            }

            if (std.ascii.isAlphabetic(ch) or ch == '_') {
                self.readIdent(start_loc);
                continue;
            }

            switch (ch) {
                '(' => { self.addToken(.{ .tag = .lparen, .loc = start_loc, .text = "(" }); self.advance(); },
                ')' => { self.addToken(.{ .tag = .rparen, .loc = start_loc, .text = ")" }); self.advance(); },
                '[' => { self.addToken(.{ .tag = .lbracket, .loc = start_loc, .text = "[" }); self.advance(); },
                ']' => { self.addToken(.{ .tag = .rbracket, .loc = start_loc, .text = "]" }); self.advance(); },
                '{' => { self.addToken(.{ .tag = .lbrace, .loc = start_loc, .text = "{" }); self.advance(); },
                '}' => { self.addToken(.{ .tag = .rbrace, .loc = start_loc, .text = "}" }); self.advance(); },
                ':' => { self.addToken(.{ .tag = .colon, .loc = start_loc, .text = ":" }); self.advance(); },
                '=' => { self.addToken(.{ .tag = .equals, .loc = start_loc, .text = "=" }); self.advance(); },
                '*' => { self.addToken(.{ .tag = .star, .loc = start_loc, .text = "*" }); self.advance(); },
                '+' => { self.addToken(.{ .tag = .plus, .loc = start_loc, .text = "+" }); self.advance(); },
                '/' => { self.addToken(.{ .tag = .slash, .loc = start_loc, .text = "/" }); self.advance(); },
                ',' => { self.addToken(.{ .tag = .comma, .loc = start_loc, .text = "," }); self.advance(); },
                '.' => {
                    if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == '.' and self.src[self.pos + 2] == '.') {
                        self.addToken(.{ .tag = .ellipsis, .loc = start_loc, .text = "..." });
                        self.pos += 3;
                        self.col += 3;
                    } else {
                        self.advance();
                    }
                },
                '-' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                        self.addToken(.{ .tag = .arrow, .loc = start_loc, .text = "->" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        // Binary minus operator. Number-prefix (`-digit`) is
                        // already routed to readNumber by the early isDigit
                        // check above, so any `-` reaching here is a binary
                        // operator or unary-prefix-on-an-identifier (the
                        // latter is not yet exposed in the parser).
                        self.addToken(.{ .tag = .minus, .loc = start_loc, .text = "-" });
                        self.advance();
                    }
                },
                else => {
                    self.advance();
                },
            }
        }

        self.addToken(.{
            .tag = .eof,
            .loc = .{ .line = self.line, .col = self.col, .offset = self.pos },
            .text = "",
        });

        return self.tokens_buf[0..self.tokens_len];
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
        self.col += 1;
    }

    fn readString(self: *Lexer, start_loc: ast.Loc) void {
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

    fn readNumber(self: *Lexer, start_loc: ast.Loc) void {
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

    fn readDocComment(self: *Lexer, start_loc: ast.Loc) void {
        const start_pos = self.pos;

        while (self.pos < self.src.len) {
            while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                self.pos += 1;
                self.col += 1;
            }

            if (self.pos < self.src.len and self.src[self.pos] == '\n') {
                const newline_pos = self.pos;
                var peek_pos: u32 = newline_pos + 1;

                while (peek_pos < self.src.len and (self.src[peek_pos] == ' ' or self.src[peek_pos] == '\t' or self.src[peek_pos] == '\r')) {
                    peek_pos += 1;
                }

                if (peek_pos < self.src.len and self.src[peek_pos] == '#') {
                    if (peek_pos + 1 < self.src.len and self.src[peek_pos + 1] == '#') break;

                    self.pos = peek_pos + 1;
                    self.line += 1;
                    self.col = peek_pos - newline_pos + 1;
                    continue;
                }
            }
            break;
        }

        const text = self.src[start_pos..self.pos];
        self.addToken(.{ .tag = .doc_comment, .loc = start_loc, .text = text });
    }

    fn readIdent(self: *Lexer, start_loc: ast.Loc) void {
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
            self.col += 1;
        }
        const text = self.src[start..self.pos];
        const tag: TokenTag = if (std.mem.eql(u8, text, "fun"))
            .fun
        else if (std.mem.eql(u8, text, "let"))
            .let
        else if (std.mem.eql(u8, text, "var"))
            .var_kw
        else if (std.mem.eql(u8, text, "const"))
            .const_kw
        else if (std.mem.eql(u8, text, "defer"))
            .defer_kw
        else if (std.mem.eql(u8, text, "new"))
            .new
        else if (std.mem.eql(u8, text, "free"))
            .free
        else if (std.mem.eql(u8, text, "print"))
            .print
        else if (std.mem.eql(u8, text, "return"))
            .return_kw
        else if (std.mem.eql(u8, text, "true"))
            .true_kw
        else if (std.mem.eql(u8, text, "false"))
            .false_kw
        else if (std.mem.eql(u8, text, "null"))
            .null_kw
        else if (std.mem.eql(u8, text, "undefined"))
            .undefined_kw
        else
            .identifier;

        self.addToken(.{ .tag = tag, .loc = start_loc, .text = text });
    }

    fn readByteString(self: *Lexer, start_loc: ast.Loc) void {
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

    fn readChar(self: *Lexer, start_loc: ast.Loc) void {
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
};
