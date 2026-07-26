const std = @import("std");
const ast = @import("../ast.zig");

// Module-scope aliases only — there is NO inner
// `pub const Token/TokenTag` on the Lexer struct
// (would conflict with `const Token =` if we also
// added it as a struct-member alias). External
// callers reach `Token`/`TokenTag` via the
// aggregator's module-scope re-exports; the
// bottom-of-files field `tokens_buf: [4096]Token`
// resolves to the module-scope `const Token = ...`
// alias here.
const token = @import("token.zig");
const TokenTag = token.TokenTag;
const Token = token.Token;

// ============================================================
// core.zig — Lexer struct (state + orchestrator)
// ============================================================

pub const Lexer = struct {

    src: []const u8,
    pos: u32,
    line: u32,
    col: u32,
    tokens_buf: [4096]Token,
    tokens_len: u32,
    // v2 char fix path (docs/features.md §08 v2 4-byte Unicode char
    // row, gap (b)): each bare `\uNNNN` escape is normalized to the
    // brace form `\u{NNNN}` and the rewritten text stored in a slot
    // of `char_norm_bufs` rather than slicing into immutable `src`.
    // Slot indexing is monotonic: token N's text references
    // `char_norm_bufs[N]`; once that token is added to `tokens_buf`
    // the slice is stable for the lexer's lifetime. 256 slots cover
    // any realistic zag source. Bounds: each slot handles up to 16-byte
    // char literals (the largest form `'\u{FFFFFF}'` is 12 chars; 16 is
    // double-margin + safety for future-extended escape sequences).
    char_norm_bufs: [256][16]u8 = undefined,
    char_norm_count: u32 = 0,

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

    pub fn addToken(self: *Lexer, tok: Token) void {
        self.tokens_buf[self.tokens_len] = tok;
        self.tokens_len += 1;
    }

    pub fn tokenize(self: *Lexer) []const Token {
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            const start_loc = ast.Loc{ .line = self.line, .col = self.col, .offset = self.pos };

            if (ch == '#' or ch == '@') {
                const is_at = ch == '@';
                if (is_at and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '[') {
                    // `@[ ... ]` annotation attribute
                    self.advance(); // consume @
                    self.advance(); // consume [
                    var depth: u32 = 1;
                    const attr_start = self.pos;
                    while (self.pos < self.src.len and depth > 0) {
                        if (self.src[self.pos] == '[') depth += 1;
                        if (self.src[self.pos] == ']') depth -= 1;
                        self.pos += 1;
                        self.col += 1;
                    }
                    const attr_text = self.src[attr_start .. self.pos - 1];
                    if (std.mem.eql(u8, attr_text, "test")) {
                        self.addToken(.{ .tag = .test_annotation, .loc = start_loc, .text = "test" });
                    }
                    continue;
                }
                if (!is_at) {
                    // ch == '#' — handle ## (doc), #[ (skip), or bare #
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '#') {
                        self.readDocComment(start_loc);
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '[') {
                        self.advance(); // consume #
                        self.advance(); // consume [
                        var depth: u32 = 1;
                        while (self.pos < self.src.len and depth > 0) {
                            if (self.src[self.pos] == '[') depth += 1;
                            if (self.src[self.pos] == ']') depth -= 1;
                            self.pos += 1;
                            self.col += 1;
                        }
                    } else {
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                            self.pos += 1;
                            self.col += 1;
                        }
                    }
                    continue;
                }
                // `@` without `[` — treat as regular character, fall through
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

            if (std.ascii.isDigit(ch) or (ch == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) or (ch == '+' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
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
                '(' => {
                    self.addToken(.{ .tag = .lparen, .loc = start_loc, .text = "(" });
                    self.advance();
                },
                ')' => {
                    self.addToken(.{ .tag = .rparen, .loc = start_loc, .text = ")" });
                    self.advance();
                },
                '[' => {
                    self.addToken(.{ .tag = .lbracket, .loc = start_loc, .text = "[" });
                    self.advance();
                },
                ']' => {
                    self.addToken(.{ .tag = .rbracket, .loc = start_loc, .text = "]" });
                    self.advance();
                },
                '{' => {
                    self.addToken(.{ .tag = .lbrace, .loc = start_loc, .text = "{" });
                    self.advance();
                },
                '}' => {
                    self.addToken(.{ .tag = .rbrace, .loc = start_loc, .text = "}" });
                    self.advance();
                },
                ':' => {
                    self.addToken(.{ .tag = .colon, .loc = start_loc, .text = ":" });
                    self.advance();
                },
                ',' => {
                    self.addToken(.{ .tag = .comma, .loc = start_loc, .text = "," });
                    self.advance();
                },
                '=' => {
                    // `=` is the leading byte of:
                    //   `=`    (assignment)
                    //   `==`   (equal)
                    //   `=>`   (match-arm arrow)
                    //   `+=` `-=` `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>=`
                    //     (compound-assign forms)
                    // We peek up to two chars forward to disambiguate. The
                    // `=>` arm shares the same `.arrow` tag as `->` (function
                    // return marker); parser dispatch on position context
                    // keeps them distinct at the AST level.
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
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                        // `=>` — match-arm arrow (e.g. `1 => "one"`). Same
                        // `.arrow` tag as the `->` function-return marker;
                        // AST-level position tells them apart at the
                        // dispatch site (parseMatchExpr vs parseFunDecl).
                        self.addToken(.{ .tag = .arrow, .loc = start_loc, .text = "=>" });
                        self.pos += 2;
                        self.col += 2;
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
                '~' => {
                    self.addToken(.{ .tag = .tilde, .loc = start_loc, .text = "~" });
                    self.advance();
                },
                '?' => {
                    // Nullable pointer prefix. Always emitted as a single
                    // `?` token so `collectCastType` can glue it onto the
                    // following identifier (or `*` for `?*T` shapes) without
                    // an intervening space; the type text round-trips as
                    // `?*T` / `?i32` / `?*const T` verbatim.
                    self.addToken(.{ .tag = .question, .loc = start_loc, .text = "?" });
                    self.advance();
                },
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
                        // Standalone `.` (postfix chain: member access /
                        // method call). Emit `.dot` token so the parser's
                        // parsePostfix loop can dispatch `.name` (no
                        // parens) to `.member_access` and `.name(...)` to
                        // `.method_call`. Range/ellipsis were checked
                        // above; we land here only for a single bare dot.
                        self.addToken(.{ .tag = .dot, .loc = start_loc, .text = "." });
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

    pub fn advance(self: *Lexer) void {
        self.pos += 1;
        self.col += 1;
    }

    pub const readString = @import("string.zig").readString;

    pub const readNumber = @import("number.zig").readNumber;

    pub fn readDocComment(self: *Lexer, start_loc: ast.Loc) void {
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

    pub const readIdent = @import("ident.zig").readIdent;

    pub const readByteString = @import("string.zig").readByteString;

    pub const readChar = @import("string.zig").readChar;

};

// ============================================================
// core.zig — file-scope helpers (none currently)
// ============================================================

