const std = @import("std");
const ast = @import("ast.zig");

pub const TokenTag = enum {
    fun,
    let,
    defer_kw,
    new,
    free,
    print,
    return_kw,
    string_literal,
    integer_literal,
    identifier,
    lparen,
    rparen,
    lbrace,
    rbrace,
    colon,
    equals,
    star,
    comma,
    arrow,
    newline,
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
                while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                    self.pos += 1;
                    self.col += 1;
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

            if (ch == '"') {
                self.readString(start_loc);
                continue;
            }

            if (std.ascii.isDigit(ch) or (ch == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
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
                '{' => { self.addToken(.{ .tag = .lbrace, .loc = start_loc, .text = "{" }); self.advance(); },
                '}' => { self.addToken(.{ .tag = .rbrace, .loc = start_loc, .text = "}" }); self.advance(); },
                ':' => { self.addToken(.{ .tag = .colon, .loc = start_loc, .text = ":" }); self.advance(); },
                '=' => { self.addToken(.{ .tag = .equals, .loc = start_loc, .text = "=" }); self.advance(); },
                '*' => { self.addToken(.{ .tag = .star, .loc = start_loc, .text = "*" }); self.advance(); },
                ',' => { self.addToken(.{ .tag = .comma, .loc = start_loc, .text = "," }); self.advance(); },
                '-' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                        self.addToken(.{ .tag = .arrow, .loc = start_loc, .text = "->" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.readNumber(start_loc);
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
                self.pos += 1;
                self.col += 1;
            }
            self.pos += 1;
            self.col += 1;
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
        while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
            self.col += 1;
        }
        self.addToken(.{ .tag = .integer_literal, .loc = start_loc, .text = self.src[start..self.pos] });
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
        else
            .identifier;

        self.addToken(.{ .tag = tag, .loc = start_loc, .text = text });
    }
};
