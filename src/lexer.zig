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
    // The vast majority of these operators come from `docs/manual/05-operators.md`
    // and were added in one pass to expose the documented operator surface.
    // All multi-char forms (`<=`, `+=`, `&&`, et al.) are disambiguated in
    // the `tokenize` loop by peeking the second and third chars from the
    // current `pos` before consuming.
    equals, // `=` (also the leading char of `==`, `+=`, `-=`, …)
    plus,
    minus,
    star,
    slash,
    percent, // `%`
    amp, // `&`
    pipe, // `|`
    caret, // `^`
    tilde, // `~`
    lt, // `<`
    gt, // `>`
    lt_eq, // `<=`
    gt_eq, // `>=`
    bang, // `!`
    eq_eq, // `==`
    bang_eq, // `!=`
    amp_amp, // `&&`
    pipe_pipe, // `||`
    lt_lt, // `<<`
    gt_gt, // `>>`
    plus_eq, // `+=`
    minus_eq, // `-=`
    star_eq, // `*=`
    slash_eq, // `/=`
    percent_eq, // `%=`
    amp_eq, // `&=`
    pipe_eq, // `|=`
    caret_eq, // `^=`
    lt_lt_eq, // `<<=`
    gt_gt_eq, // `>>=`
    range, // `..` (half-open range; doc range table also lists `...` which is `ellipsis` for inclusive)
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
                ',' => { self.addToken(.{ .tag = .comma, .loc = start_loc, .text = "," }); self.advance(); },
                '=' => {
                    // `=` is the leading byte of:
                    //   `=`  (assignment), `==` (equal), and 10 compound-assign forms
                    //   (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`).
                    // We peek two chars forward to disambiguate. Whichever form
                    // the user wrote, we consume the right number of bytes.
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .eq_eq, .loc = start_loc, .text = "==" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '+') {
                        self.addToken(.{ .tag = .plus_eq, .loc = start_loc, .text = "+=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                        self.addToken(.{ .tag = .minus_eq, .loc = start_loc, .text = "-=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                        self.addToken(.{ .tag = .star_eq, .loc = start_loc, .text = "*=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                        self.addToken(.{ .tag = .slash_eq, .loc = start_loc, .text = "/=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '%') {
                        self.addToken(.{ .tag = .percent_eq, .loc = start_loc, .text = "%=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '&') {
                        self.addToken(.{ .tag = .amp_eq, .loc = start_loc, .text = "&=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '|') {
                        self.addToken(.{ .tag = .pipe_eq, .loc = start_loc, .text = "|=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '^') {
                        self.addToken(.{ .tag = .caret_eq, .loc = start_loc, .text = "^=" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == '<' and self.src[self.pos + 2] == '<') {
                        self.addToken(.{ .tag = .lt_lt_eq, .loc = start_loc, .text = "<<=" });
                        self.pos += 3;
                        self.col += 3;
                    } else if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == '>' and self.src[self.pos + 2] == '>') {
                        self.addToken(.{ .tag = .gt_gt_eq, .loc = start_loc, .text = ">>=" });
                        self.pos += 3;
                        self.col += 3;
                    } else {
                        self.addToken(.{ .tag = .equals, .loc = start_loc, .text = "=" });
                        self.advance();
                    }
                },
                '*' => {
                    // `*` is the leading byte of `*=` (compound mul-assign). Bare `*`
                    // is multiplicative (or, in unary context, deref — the parser
                    // distinguishes via parseUnary vs parseMultiplicative).
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .star_eq, .loc = start_loc, .text = "*=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .star, .loc = start_loc, .text = "*" });
                        self.advance();
                    }
                },
                '+' => {
                    // `+` is the leading byte of `+=` (compound add-assign). Bare `+`
                    // is additive (or, in unary context, plus-prefix on a literal,
                    // routed to readNumber by the early isDigit check above).
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .plus_eq, .loc = start_loc, .text = "+=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .plus, .loc = start_loc, .text = "+" });
                        self.advance();
                    }
                },
                '/' => {
                    // `/` is the leading byte of `/=` (compound div-assign). Bare
                    // `/` is multiplicative division.
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .slash_eq, .loc = start_loc, .text = "/=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .slash, .loc = start_loc, .text = "/" });
                        self.advance();
                    }
                },
                '%' => {
                    // `%` is the leading byte of `%=` (compound mod-assign). Bare
                    // `%` is multiplicative modulo.
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .percent_eq, .loc = start_loc, .text = "%=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .percent, .loc = start_loc, .text = "%" });
                        self.advance();
                    }
                },
                '&' => {
                    // `&` is the leading byte of:
                    //   `&&` (logical and, parseLogicalAnd)
                    //   `&=` (compound bitand-assign)
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '&') {
                        self.addToken(.{ .tag = .amp_amp, .loc = start_loc, .text = "&&" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .amp_eq, .loc = start_loc, .text = "&=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .amp, .loc = start_loc, .text = "&" });
                        self.advance();
                    }
                },
                '|' => {
                    // `|` is the leading byte of:
                    //   `||` (logical or, parseLogicalOr)
                    //   `|=` (compound bitor-assign)
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '|') {
                        self.addToken(.{ .tag = .pipe_pipe, .loc = start_loc, .text = "||" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .pipe_eq, .loc = start_loc, .text = "|=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .pipe, .loc = start_loc, .text = "|" });
                        self.advance();
                    }
                },
                '^' => {
                    // `^` is the leading byte of `^=` (compound bitxor-assign). Bare
                    // `^` is bitwise xor.
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .caret_eq, .loc = start_loc, .text = "^=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .caret, .loc = start_loc, .text = "^" });
                        self.advance();
                    }
                },
                '~' => { self.addToken(.{ .tag = .tilde, .loc = start_loc, .text = "~" }); self.advance(); },
                '<' => {
                    // `<` is the leading byte of `<=`, `<<`, `<<=` (compound shift-assign).
                    if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == '<' and self.src[self.pos + 2] == '=') {
                        self.addToken(.{ .tag = .lt_lt_eq, .loc = start_loc, .text = "<<=" });
                        self.pos += 3;
                        self.col += 3;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '<') {
                        self.addToken(.{ .tag = .lt_lt, .loc = start_loc, .text = "<<" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .lt_eq, .loc = start_loc, .text = "<=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .lt, .loc = start_loc, .text = "<" });
                        self.advance();
                    }
                },
                '>' => {
                    // `>` is the leading byte of `>=`, `>>`, `>>=` (compound shift-assign).
                    if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == '>' and self.src[self.pos + 2] == '=') {
                        self.addToken(.{ .tag = .gt_gt_eq, .loc = start_loc, .text = ">>=" });
                        self.pos += 3;
                        self.col += 3;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                        self.addToken(.{ .tag = .gt_gt, .loc = start_loc, .text = ">>" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .gt_eq, .loc = start_loc, .text = ">=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .gt, .loc = start_loc, .text = ">" });
                        self.advance();
                    }
                },
                '!' => {
                    // `!` is the leading byte of `!=`.
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .bang_eq, .loc = start_loc, .text = "!=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        self.addToken(.{ .tag = .bang, .loc = start_loc, .text = "!" });
                        self.advance();
                    }
                },
                '.' => {
                    // `.` is the leading byte of `..` (range) and `...` (ellipsis).
                    // Range must be checked FIRST so `..` short-circuits before
                    // `...`; otherwise `0..10` would tokenize as two malformed
                    // form: `0` `.` `.` `.10` (which readNumber might re-attach).
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '.' and
                        self.pos + 2 < self.src.len and self.src[self.pos + 2] == '.')
                    {
                        // `...` — ellipsis (for inclusive range `a...b` and for
                        // array fill/progression `[N]T { a, b ... }`). Same
                        // token consumed in both contexts; parser
                        // disambiguates from syntax position.
                        self.addToken(.{ .tag = .ellipsis, .loc = start_loc, .text = "..." });
                        self.pos += 3;
                        self.col += 3;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '.') {
                        // `..` — half-open range operator.
                        self.addToken(.{ .tag = .range, .loc = start_loc, .text = ".." });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        // Standalone `.` (e.g. method-call syntax not yet in
                        // the language) is dropped on the floor to remain a
                        // forward-compatible no-op. Members `.f` access
                        // requires struct support first.
                        self.advance();
                    }
                },
                '-' => {
                    // `-` is the leading byte of:
                    //   `->` (arrow function-return-type marker)
                    //   `-=` (compound sub-assign)
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                        self.addToken(.{ .tag = .arrow, .loc = start_loc, .text = "->" });
                        self.pos += 2;
                        self.col += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                        self.addToken(.{ .tag = .minus_eq, .loc = start_loc, .text = "-=" });
                        self.pos += 2;
                        self.col += 2;
                    } else {
                        // Binary minus operator. Number-prefix (`-digit`) is
                        // already routed to readNumber by the early isDigit
                        // check above, so any `-` reaching here is a binary
                        // operator (as in `a - b`) or unary-prefix-on-an-identifier
                        // (the latter handled by parseUnary in the parser).
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
