const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

pub const Parser = struct {
    tokens: []const Token,
    pos: u32,
    arena: *ast.Arena,

    pub fn init(tokens: []const Token, arena: *ast.Arena) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
        };
    }

    pub fn parse(self: *Parser) ast.Program {
        var functions_buf: [256]ast.FunDecl = undefined;
        var fun_count: usize = 0;

        while (!self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            var doc: ?[]const u8 = null;
            while (self.peek().tag == .doc_comment) {
                doc = self.peek().text;
                self.advance();
                while (self.peek().tag == .newline) self.advance();
            }
            if (self.eof()) break;
            functions_buf[fun_count] = self.parseFunDecl();
            functions_buf[fun_count].doc = doc;
            fun_count += 1;
        }

        const functions = self.arena.alloc(ast.FunDecl, fun_count);
        @memcpy(functions, functions_buf[0..fun_count]);
        return .{ .functions = functions };
    }

    fn parseFunDecl(self: *Parser) ast.FunDecl {
        const start = self.peek().loc;
        self.expect(.fun);
        const name = self.expectIdent();
        self.expect(.lparen);
        self.expect(.rparen);
        const body = self.parseBlock();
        return .{ .name = name, .body = body, .loc = start, .doc = null };
    }

    fn parseBlock(self: *Parser) []const Stmt {
        self.expect(.lbrace);
        var stmts_buf: [256]Stmt = undefined;
        var stmt_count: usize = 0;

        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            stmts_buf[stmt_count] = self.parseStmt();
            stmt_count += 1;
        }

        self.expect(.rbrace);
        const stmts = self.arena.alloc(Stmt, stmt_count);
        @memcpy(stmts, stmts_buf[0..stmt_count]);
        return stmts;
    }

    fn parseStmt(self: *Parser) Stmt {
        const tok = self.peek();
        switch (tok.tag) {
            // Each binding-kind dispatch arm selects the kind AND the union
            // tag simultaneously so the AST carries both. parseBinding does
            // not see the union tag — it just parses the common shape and
            // returns a BindingStmt; the structural duplication that
            // motivated the refactor lives here at exactly three lines.
            .let => return .{ .let = self.parseBinding(.let) },
            .var_kw => return .{ .var_binding = self.parseBinding(.var_binding) },
            .const_kw => return .{ .const_binding = self.parseBinding(.const_binding) },
            .identifier => {
                // One-token lookahead: rebinding `name = expr` is a statement,
                // not a free identifier expression. Without this, the leading
                // `name` would be consumed as an `.expr_stmt` ident, leaving
                // an unconsumed `=` token and a follow-up parse error.
                if (self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].tag == .equals) {
                    return .{ .assign = self.parseAssign() };
                }
                return .{ .expr_stmt = self.parseExpr() };
            },
            .defer_kw => return .{ .defer_stmt = self.parseDefer() },
            else => return .{ .expr_stmt = self.parseExpr() },
        }
    }

    /// Parse one of the three binding declarations (`let`, `var`, `const`).
    /// All three share this code path — the only divergence is which keyword
    /// the source starts with, which we route via the `kind` parameter. The
    /// dispatch site in `parseStmt` carries the binding kind to the AST by
    /// selecting the matching union tag (`.let` / `.var_binding` /
    /// `.const_binding`) and threading the same `kind` value here; the
    /// payload `BindingStmt` is structurally identical across all three so
    /// zig's tagged union gives us uniform field access (`stmt.let.init`,
    /// `stmt.var_binding.name`, `stmt.const_binding.type_name`) without
    /// duplicating struct definitions.
    ///
    /// Adding a future binding kind (`mut`, `implicit`, `ref`, ...) is a
    /// three-line change: a new `BindingKind` enum member in `ast.zig`, a
    /// matching arm in the `kw` switch below, plus a new dispatch arm in
    /// `parseStmt` that calls `parseBinding(<kind>)`.
    ///
    /// The first token after the keyword disambiguates single-name from
    /// destructuring: `(` opens a tuple pattern, `[` opens an array
    /// pattern, an identifier is either a name or the wildcard `_`. Either
    /// way `parseBindingPattern` returns the shape and we promote `.name`
    /// results into the simple-binding code path (.pattern = null) so the
    /// existing 83-unit-call-site test suite continues to read
    /// `stmt.let.name` / `stmt.let.type_name.?` without modification.
    fn parseBinding(self: *Parser, kind: ast.BindingKind) Stmt.BindingStmt {
        // The kind determines which leading keyword the binding must start
        // with. The lexer enforces `let`/`var`/`const` as reserved
        // `TokenTag`s so a user-shadowed identifier never reaches us here.
        const kw: TokenTag = switch (kind) {
            .let => .let,
            .var_binding => .var_kw,
            .const_binding => .const_kw,
        };
        self.expect(kw);
        const pattern = self.parseBindingPattern();
        if (pattern == .name) {
            // Plain single-name binding: optionally annotated `: T`. The
            // pattern's `.name` text is promoted into the legacy `name`
            // field so callers that read `stmt.let.name` continue to work.
            var type_name: ?[]const u8 = null;
            if (self.peek().tag == .colon) {
                self.advance();
                type_name = self.expectIdent();
            }
            self.expect(.equals);
            const initializer = self.parseExpr();
            return .{ .name = pattern.name, .type_name = type_name, .init = initializer };
        }
        // Destructuring form: docs do not specify a syntax for `: T`
        // annotations on patterns, so we reject them by consuming the
        // `=` directly. The `name` field is the empty sentinel (codegen
        // ignores it when `pattern` is set).
        self.expect(.equals);
        const initializer = self.parseExpr();
        return .{ .name = "", .type_name = null, .init = initializer, .pattern = pattern };
    }

    /// Parse a destructuring pattern starting at the current token. Recursive
    /// for nested forms (`let (a, (b, c)) = …` is a tuple containing a tuple).
    ///
    /// Returns a `BindingPattern`:
    /// - `.name("x")` — single identifier (no destructuring)
    /// - `.discard`   — the wildcard `_`
    /// - `.tuple([ … ])` — pattern wrapped in `(…)` (tuple destructuring)
    /// - `.array([ … ])` — pattern wrapped in `[…]` (array destructuring)
    fn parseBindingPattern(self: *Parser) ast.BindingPattern {
        const tok = self.peek();
        if (tok.tag == .lparen) {
            // Tuple destructuring: `(p0, p1, ..., pN)`. Recurse into each
            // element so `let (a, (b, c)) = …` is a valid form.
            self.advance();
            var pats_buf: [16]ast.BindingPattern = undefined;
            var pat_count: usize = 0;
            if (self.peek().tag != .rparen) {
                pats_buf[pat_count] = self.parseBindingPattern();
                pat_count += 1;
                while (self.peek().tag == .comma) {
                    self.advance();
                    pats_buf[pat_count] = self.parseBindingPattern();
                    pat_count += 1;
                }
            }
            self.expect(.rparen);
            const pats = self.arena.alloc(ast.BindingPattern, pat_count);
            @memcpy(pats, pats_buf[0..pat_count]);
            return .{ .tuple = pats };
        }
        if (tok.tag == .lbracket) {
            // Array destructuring: `[p0, p1, ..., pN]`. Recursive like tuple.
            self.advance();
            var pats_buf: [16]ast.BindingPattern = undefined;
            var pat_count: usize = 0;
            if (self.peek().tag != .rbracket) {
                pats_buf[pat_count] = self.parseBindingPattern();
                pat_count += 1;
                while (self.peek().tag == .comma) {
                    self.advance();
                    pats_buf[pat_count] = self.parseBindingPattern();
                    pat_count += 1;
                }
            }
            self.expect(.rbracket);
            const pats = self.arena.alloc(ast.BindingPattern, pat_count);
            @memcpy(pats, pats_buf[0..pat_count]);
            return .{ .array = pats };
        }
        if (tok.tag == .identifier) {
            // `_` is the wildcard; everything else is a name.
            if (std.mem.eql(u8, tok.text, "_")) {
                self.advance();
                return .{ .discard = {} };
            }
            const name = self.expectIdent();
            return .{ .name = name };
        }
        // Anything else is a syntactic error: the doc only defines patterns
        // starting with `(`, `[`, or an identifier.
        std.debug.print("error:{d}:{d}: expected binding pattern, got '{s}'\n", .{
            tok.loc.line, tok.loc.col, tok.text,
        });
        std.process.exit(1);
    }

    fn parseAssign(self: *Parser) Stmt.AssignStmt {
        const name = self.expectIdent();
        self.expect(.equals);
        const value = self.parseExpr();
        return .{ .name = name, .value = value };
    }

    fn parseDefer(self: *Parser) Stmt.DeferStmt {
        self.expect(.defer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }

    /// Top-level entry point: parses a full Zag expression including binary
    /// arithmetic. Delegates to a 2-level precedence ladder (additive →
    /// multiplicative → primary). `parseExpr` callers get the precedence-
    /// handled behaviour; primary-only lookahead for unary `*` (deref) is
    /// handled inside `parsePrimary`.
    fn parseExpr(self: *Parser) Expr {
        return self.parseAdditive();
    }

    /// Additive layer: chains `+`/`-` while the next token is one of those.
    /// Each additive operand is consumed via `parseMultiplicative` so that
    /// `1 + 2 * 3` parses as `1 + (2 * 3)` rather than `(1 + 2) * 3`.
    fn parseAdditive(self: *Parser) Expr {
        var lhs = self.parseMultiplicative();
        while (true) {
            const op: ast.Expr.BinaryOp = switch (self.peek().tag) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            self.advance();
            const rhs = self.parseMultiplicative();
            lhs = self.makeBinary(op, lhs, rhs);
        }
        return lhs;
    }

    /// Multiplicative layer: chains `*`/`/` while the next token is one of
    /// those. Binds tighter than additive. Each operand is a `parsePrimary`
    /// so leading `*` (deref) is consumed only at primary level.
    fn parseMultiplicative(self: *Parser) Expr {
        var lhs = self.parsePrimary();
        while (true) {
            const op: ast.Expr.BinaryOp = switch (self.peek().tag) {
                .star => .mul,
                .slash => .div,
                else => break,
            };
            self.advance();
            const rhs = self.parsePrimary();
            lhs = self.makeBinary(op, lhs, rhs);
        }
        return lhs;
    }

    /// Allocate a BinaryExpr in the arena and return it as an Expr. Using
    /// the arena for both operands avoids per-node allocations and matches
    /// the existing NewExpr/DerefExpr `*Expr` pointer convention.
    fn makeBinary(self: *Parser, op: ast.Expr.BinaryOp, lhs: Expr, rhs: Expr) Expr {
        const lhs_buf = self.arena.alloc(Expr, 1);
        lhs_buf[0] = lhs;
        const rhs_buf = self.arena.alloc(Expr, 1);
        rhs_buf[0] = rhs;
        return .{ .binary = .{ .op = op, .lhs = &lhs_buf[0], .rhs = &rhs_buf[0] } };
    }

    fn parsePrimary(self: *Parser) Expr {
        const tok = self.peek();

        if (tok.tag == .lbracket) {
            return self.parseArrayLit();
        }

        switch (tok.tag) {
            .new => return self.parseNew(),
            .free => return self.parseFree(),
            .print, .identifier => {
                const name = tok.text;
                self.advance();
                if (self.peek().tag == .lparen) {
                    return self.parseCallExpr(name);
                } else {
                    return .{ .ident = name };
                }
            },
            .string_literal => {
                self.advance();
                if (std.mem.indexOf(u8, tok.text, "{") != null) {
                    return self.buildTemplate(tok.text);
                }
                return .{ .string_lit = tok.text };
            },
            .byte_string_literal => {
                self.advance();
                return .{ .byte_string_lit = tok.text };
            },
            .char_literal => {
                self.advance();
                return .{ .char_lit = tok.text };
            },
            .integer_literal => {
                self.advance();
                return .{ .int_lit = tok.text };
            },
            .float_literal => {
                self.advance();
                return .{ .float_lit = tok.text };
            },
            .true_kw => {
                self.advance();
                return .{ .bool_lit = true };
            },
            .false_kw => {
                self.advance();
                return .{ .bool_lit = false };
            },
            .null_kw => {
                self.advance();
                return .{ .null_lit = {} };
            },
            .undefined_kw => {
                self.advance();
                return .{ .undefined_lit = {} };
            },
            .star => {
                // Unary deref at primary level so `*x + 1` parses as
                // `(*x) + 1` rather than (mis)interpreted as multiply. The
                // *target* is also primary-only so `(*x)` doesn't accidentally
                // absorb a following operator: `*(x + y)` would consume only
                // the parenthesised primary, then stop.
                self.advance();
                const target = self.parsePrimary();
                const t = self.arena.alloc(Expr, 1);
                t[0] = target;
                return .{ .deref = .{ .target_ptr = &t[0] } };
            },
            .lparen => {
                self.advance();
                // Empty tuple: ()
                if (self.peek().tag == .rparen) {
                    self.advance();
                    const elements = self.arena.alloc(Expr, 0);
                    return .{ .tuple_lit = elements };
                }
                // Parse first expression — delegate via the top of the
                // precedence ladder so `(1 + 2)` is parsed as a full
                // binary expression rather than just a primary.
                var elements_buf: [32]Expr = undefined;
                var element_count: usize = 0;
                elements_buf[element_count] = self.parseExpr();
                element_count += 1;
                // If a comma follows, this is a tuple literal
                if (self.peek().tag == .comma) {
                    self.advance();
                    elements_buf[element_count] = self.parseExpr();
                    element_count += 1;
                    while (self.peek().tag == .comma) {
                        self.advance();
                        elements_buf[element_count] = self.parseExpr();
                        element_count += 1;
                    }
                    self.expect(.rparen);
                    const elements = self.arena.alloc(Expr, element_count);
                    @memcpy(elements, elements_buf[0..element_count]);
                    return .{ .tuple_lit = elements };
                }
                self.expect(.rparen);
                return elements_buf[0];
            },
            else => {
                self.advance();
                return .{ .ident = tok.text };
            },
        }
    }

    fn parseCallExpr(self: *Parser, name: []const u8) Expr {
        self.expect(.lparen);
        var args_buf: [32]Expr = undefined;
        var arg_count: usize = 0;

        while (self.peek().tag != .rparen and !self.eof()) {
            if (self.peek().tag == .comma) {
                self.advance();
                continue;
            }
            args_buf[arg_count] = self.parseExpr();
            arg_count += 1;
        }

        self.expect(.rparen);
        const args = self.arena.alloc(Expr, arg_count);
        @memcpy(args, args_buf[0..arg_count]);
        return .{ .call = .{ .name = name, .args = args } };
    }

    fn parseArrayLit(self: *Parser) Expr {
        self.expect(.lbracket);
        // The size literal follows.
        const size_tok = self.peek();
        if (size_tok.tag != .integer_literal) {
            std.debug.print("error:{d}:{d}: expected integer literal for array size, got '{s}'\n", .{
                size_tok.loc.line, size_tok.loc.col, size_tok.text,
            });
            std.process.exit(1);
        }
        var size: u32 = 0;
        for (size_tok.text) |c| {
            if (c >= '0' and c <= '9') {
                size = size * 10 + @as(u32, c - '0');
            }
        }
        self.advance();
        self.expect(.rbracket);
        const type_name = self.expectIdent();
        self.expect(.lbrace);

        var elements_buf: [64]Expr = undefined;
        var element_count: usize = 0;

        // Allow `}` (zero-element explicit list) or at least one expression.
        if (self.peek().tag != .rbrace) {
            elements_buf[element_count] = self.parseExpr();
            element_count += 1;
            while (self.peek().tag == .comma) {
                self.advance();
                elements_buf[element_count] = self.parseExpr();
                element_count += 1;
            }
        }

        var fill = false;
        var progression = false;
        if (self.peek().tag == .ellipsis) {
            self.advance();
            if (element_count == 1) {
                fill = true;
            } else if (element_count == 2) {
                progression = true;
            }
        }

        self.expect(.rbrace);

        const elements = self.arena.alloc(Expr, element_count);
        @memcpy(elements, elements_buf[0..element_count]);
        return .{ .array_lit = .{
            .size = size,
            .type_name = type_name,
            .elements = elements,
            .fill = fill,
            .progression = progression,
        } };
    }

    fn parseNew(self: *Parser) Expr {
        self.expect(.new);
        const type_name = self.expectIdent();
        self.expect(.lparen);
        const value = self.parseExpr();
        self.expect(.rparen);
        const v = self.arena.alloc(Expr, 1);
        v[0] = value;
        return .{ .new_expr = .{ .type_name = type_name, .value = &v[0] } };
    }

    /// Split a raw string literal that contains `{...}` interpolation markers
    /// into a template literal: alternating literal / expression parts.
    /// The contents of `{...}` are stored verbatim as a single `.ident` Expr —
    /// Zig re-tokenizes the emitted text at compile time, which means richer
    /// interpolation bodies such as `{x + y}` or `{arr[i]}` are accepted
    /// without further parsing effort here. A trailing empty literal segment
    /// is always emitted so the parts alternation is intact when the template
    /// ends with `{...}`.
    ///
    /// Reserves a fixed `[32]` parts buffer; deeper templates fail loudly via
    /// overflow (a `zig` debug-build assert) so silent truncation is impossible.
    fn buildTemplate(self: *Parser, raw: []const u8) Expr {
        var parts_buf: [32]ast.Expr.TemplatePart = undefined;
        var part_count: usize = 0;
        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < raw.len) {
            if (raw[i] == '{' and i + 1 < raw.len) {
                if (i > literal_start) {
                    parts_buf[part_count] = .{ .literal = raw[literal_start..i], .expr = null };
                    part_count += 1;
                }
                i += 1; // skip '{'
                const expr_start = i;
                // Walk until either `}` or end-of-text. The matched-`}` case
                // must be distinguished from the end-of-text case explicitly
                // because `}` at the very last index makes `i` equal `raw.len`
                // after we exit the while body. Within this walk we also
                // detect an optional printf-style format spec: `{name:spec}`.
                // The first `:` we reach separates the expression text from
                // the spec text; the spec runs from `:`+1 to `}` exclusive.
                // Plain `{name}` (no `:`) leaves `spec` null and triggers the
                // backward-compatible `{any}` codegen path.
                var end_i = expr_start;
                var found_close = false;
                var has_spec = false;
                var spec_start: usize = 0;
                while (end_i < raw.len) : (end_i += 1) {
                    if (raw[end_i] == '}') {
                        found_close = true;
                        break;
                    }
                    if (raw[end_i] == ':' and !has_spec) {
                        spec_start = end_i + 1;
                        has_spec = true;
                    }
                }

                if (!found_close) {
                    // Unmatched '{' — treat the remaining run (including the
                    // '{') as a literal segment and stop.
                    parts_buf[part_count] = .{
                        .literal = raw[expr_start - 1 ..],
                        .expr = null,
                    };
                    part_count += 1;
                    break;
                }

                i = end_i + 1; // skip '}'
                if (has_spec) {
                    const expr_text = raw[expr_start..spec_start - 1];
                    const spec_text = raw[spec_start..end_i];
                    parts_buf[part_count] = .{
                        .literal = null,
                        .expr = .{ .ident = expr_text },
                        .spec = spec_text,
                    };
                } else {
                    const expr_text = raw[expr_start..end_i];
                    parts_buf[part_count] = .{
                        .literal = null,
                        .expr = .{ .ident = expr_text },
                        .spec = null,
                    };
                }
                part_count += 1;
                literal_start = i;
            } else {
                i += 1;
            }
        }

        // Always emit a trailing literal part — possibly zero-length — so a
        // string that ends with `{...}` keeps the alternation intact
        // ("hello, " / name / "").
        parts_buf[part_count] = .{ .literal = raw[literal_start..], .expr = null };
        part_count += 1;

        const parts = self.arena.alloc(ast.Expr.TemplatePart, part_count);
        @memcpy(parts, parts_buf[0..part_count]);
        return .{ .template_lit = .{ .parts = parts } };
    }

    fn parseFree(self: *Parser) Expr {
        self.expect(.free);
        const target = self.parseExpr();
        const t = self.arena.alloc(Expr, 1);
        t[0] = target;
        return .{ .free_expr = .{ .target = &t[0] } };
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn eof(self: *Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].tag == .eof;
    }

    fn expect(self: *Parser, tag: TokenTag) void {
        if (self.peek().tag != tag) {
            const tok = self.peek();
            std.debug.print("error:{d}:{d}: expected {s}, got '{s}'\n", .{
                tok.loc.line,
                tok.loc.col,
                @tagName(tag),
                tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
    }

    fn expectIdent(self: *Parser) []const u8 {
        const tok = self.peek();
        if (tok.tag != .identifier and tok.tag != .print) {
            std.debug.print("error:{d}:{d}: expected identifier, got '{s}'\n", .{
                tok.loc.line,
                tok.loc.col,
                tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
        return tok.text;
    }
};
