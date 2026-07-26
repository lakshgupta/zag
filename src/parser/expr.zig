// src/parser/expr.zig - file-scope method bodies for the expr bucket.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");
const core = @import("core.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Parser = core.Parser;


pub fn collectCastType(self: *Parser) []const u8 {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        // `prev_was_ptr` tracks whether the prior emitted token was the
        // pointer marker `*`. When true, the NEXT identifier must be
        // concatenated directly (no space) so `*` + `raw` yields the
        // single token `*raw` (the form zig 0.16 expects for raw-pointer
        // modifier keywords). When false, two consecutive identifiers
        // ARE separated by a space (`T` + `U` → `T U`). The previous
        // `first`-flag approach lost this distinction: after consuming
        // `*`, `first` flipped to `false`, then the next ident triggered
        // the space branch — so `*raw u8` was emitted as `* raw u8`,
        // breaking the `cast.type_text == "*raw u8"` test.
        var prev_was_ptr = false;
        var generic_depth: usize = 0;
        while (!self.eof()) {
            const tok = self.peek();
            // Slice type prefix `[]` — consume the bracket pair as a single
            // two-byte token so collectCastType round-trips `[]const T` and
            // `[]T` to zig verbatim. Without this carve-out the `]` would
            // hit the `.rbracket` is_term arm and break the type-text
            // capture before the `const T` element is read, leaving the
            // emitted binding annotation as `[]` only and breaking zig's
            // type-check (`[]` alone is not a valid type).
            //
            // `prev_was_ptr` is set so the `T` of `[]T` glues onto `[]`
            // without an inserted space — zig rejects `[] T` (a slice of
            // `T` written with a space between prefix and element name)
            // because `[]` already binds to whatever identifier follows
            // in the source.
            if (tok.tag == .lbracket and self.peekAhead(1) == .rbracket) {
                if (len + 2 <= buf.len) {
                    @memcpy(buf[len..][0..2], "[]");
                    len += 2;
                }
                prev_was_ptr = true;
                self.advance();
                self.advance();
                continue;
            }
            // Array-size prefix `[<size>]` — consume the bracket pair
            // with a single-token size (`[N]T`, `[4]i32`, `[const N]`) as
            // a single multi-byte type-text segment. Without this carve-out
            // `[` falls through the dispatch and hits `else => break;`,
            // leaving the captured type text EMPTY when the source uses
            // any non-`[]` bracket form for an annotation. The most common
            // miss-mode prior to this carve-out was the docs/16 §4
            // const-generic + array-shape return type
            // `fun fill<T, const N: usize>(val: T) -> [N]T` where the
            // `[N]T` return-type annotation truncated to empty type-text
            // and zig rejected the emitted `pub fn fill(...)` signature
            // for the missing return type. Both literal-N (`[4]i32`) and
            // ident-N (`[N]T`) shapes now round-trip.
            //
            // The carve-out only handles single-token size (`[N+1]` is
            // punted to a follow-up; the docs/16 surface doesn't include
            // computed-size brackets yet). The size's token text is copied
            // verbatim — docs/16's `comptime N: usize` const-generic slot
            // already round-trips because the type_param capture in
            // `parser/decl.zig` uses collectCastType too (so `const M: *const
            // usize` works through the same `[*.consume]` pathway).
            //
            // `prev_was_ptr = true` so the next identifier glues onto
            // `[N]` without a separator (so `[N]T` emits `[N]T`, not
            // `[N] T` — zig rejects the spaced form because `[N]` already
            // binds to a single type-name).
            if (tok.tag == .lbracket and self.pos + 2 < self.tokens.len) {
                const size_tag = self.tokens[self.pos + 1].tag;
                const is_simple_size: bool = switch (size_tag) {
                    // Size tokens accepted:
                    //   `.integer_literal` — `[4]i32` (literal-N arrays)
                    //   `.float_literal`   — `[1.5]T` (would be unusual but
                    //                         parity with the integer case)
                    //   `.identifier`      — `[N]T` (const-param N from
                    //                         the surrounding fun sig)
                    // Tokens NOT accepted (would emit invalid zig if
                    // present in zag source):
                    //   `.true_kw` / `.false_kw` — bool literals, not
                    //                              array sizes
                    //   `.const_kw`              — `[const N]T` lands as a
                    //                              literal 5-byte `[const`
                    //                              token in zig but zig 0.16
                    //                              rejects `[const` outside
                    //                              decl contexts. The user's
                    //                              actual surface is `[N]T`
                    //                              where `N` is already
                    //                              `comptime N: usize` in
                    //                              the fun signature; the
                    //                              `const_kw` lives upstream
                    //                              of the bracket, not inside.
                    .integer_literal, .float_literal, .identifier => true,
                    else => false,
                };
                if (is_simple_size and self.tokens[self.pos + 2].tag == .rbracket) {
                    if (len + 1 <= buf.len) {
                        buf[len] = '[';
                        len += 1;
                    }
                    const size_text = self.tokens[self.pos + 1].text;
                    if (len + size_text.len <= buf.len) {
                        @memcpy(buf[len..][0..size_text.len], size_text);
                        len += size_text.len;
                    }
                    if (len + 1 <= buf.len) {
                        buf[len] = ']';
                        len += 1;
                    }
                    prev_was_ptr = true;
                    self.advance(); // consume `[`
                    self.advance(); // consume size
                    self.advance(); // consume `]`
                    continue;
                }
            }
            // Nullable pointer prefix `?` — consume as a single byte and
            // mark `prev_was_ptr` so the next identifier or `*` glues on
            // without a separator (`?i32`, `?*T`). The `.rbracket`-as-term
            // rule was previously the only way a `?` could exit the loop,
            // so the new arm is inserted BEFORE the is_term switch to keep
            // the dispatch order on `tok.tag` consistent.
            if (tok.tag == .question) {
                if (len + 1 <= buf.len) {
                    buf[len] = '?';
                    len += 1;
                }
                prev_was_ptr = true;
                self.advance();
                continue;
            }
            const is_term: bool = switch (tok.tag) {
                .newline, .comma, .rparen, .rbracket, .rbrace, .colon, .equals, .plus_eq, .minus_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq, .plus, .minus, .slash, .percent, .amp, .pipe, .caret, .tilde, .bang, .lt_lt, .gt_gt, .lt_eq, .gt_eq, .eq_eq, .bang_eq, .amp_amp, .pipe_pipe, .range, .ellipsis, .arrow, .doc_comment, .eof => true,
                else => false,
            };
            if (is_term) {
                if (generic_depth == 0) break;
                // Inside generic angle brackets: consume comma as
                // part of type text, but break on other terminators.
                if (tok.tag == .comma) {
                    if (len + 1 <= buf.len) {
                        buf[len] = ',';
                        len += 1;
                    }
                    prev_was_ptr = false;
                    self.advance();
                    continue;
                }
                break;
            }
            // Treat `.star` as the pointer marker (concatenated, no space)
            // and identifiers as the type name proper.
            // `.const_kw` joins the identifier-equivalent dispatch so multi-token
            // pointer types like `*const T` and `[]const T` round-trip the
            // keyword "const" as a type-name byte — otherwise the predicate
            // falls into the `else => break;` arm at `.const_kw` and truncates
            // the captured type text. See `docs/manual/09-pointers.md`.
            if (tok.tag == .identifier or tok.tag == .print or tok.tag == .const_kw) {
                const text = tok.text;
                // Insert a space ONLY when both prev was an ident (not a
                // pointer marker) AND something has already been emitted.
                if (len > 0 and !prev_was_ptr and len + 1 <= buf.len) {
                    buf[len] = ' ';
                    len += 1;
                }
                if (len + text.len <= buf.len) {
                    @memcpy(buf[len..][0..text.len], text);
                    len += text.len;
                }
                prev_was_ptr = false;
                self.advance();
            } else if (tok.tag == .star) {
                // Pointer marker — emit `*` and concatenate without space so
                // `*` + `raw` yields `*raw`. No preceding space regardless
                // of prior emission because the previous token was an ident
                // we want glued onto `*<name>` shape (zig rejects `T * raw`
                // in raw-pointer context).
                if (len + 1 <= buf.len) {
                    buf[len] = '*';
                    len += 1;
                }
                prev_was_ptr = true;
                self.advance();
            } else if (tok.tag == .lt) {
                // Generic open bracket `<` — part of type text for
                // `Result<T, E>` / `Option<T>` and user generics.
                // Mark prev_was_ptr so the next type param glues on
                // without a space (`Result<i32` not `Result< i32`).
                if (len + 1 <= buf.len) {
                    buf[len] = '<';
                    len += 1;
                }
                generic_depth += 1;
                prev_was_ptr = true;
                self.advance();
            } else if (tok.tag == .gt) {
                // Generic close bracket `>` — part of type text for
                // `Result<T, E>` / `Option<T>` and user generics.
                if (generic_depth > 0) {
                    if (len + 1 <= buf.len) {
                        buf[len] = '>';
                        len += 1;
                    }
                    generic_depth -= 1;
                } else {
                    // Lone `>` outside generics — treat as terminator.
                    break;
                }
                prev_was_ptr = true;
                self.advance();
            } else {
                break;
            }
        }
        // Arena-allocate the captured text so it outlives this function's
        // stack frame. The earlier stack-local `return buf[0..len]` was a
        // dangling pointer — `parseCast` stored the slice directly on the
        // AST's `cast.type_text` field, and codegen read random stack
        // residue at use time. Mirroring the existing pattern of allocating
        // Expr / Stmt structs on the arena (see `parseCast`'s
        // `arena.alloc(Expr, 1)` and `parseIfExpr`'s allocations).
        if (len == 0) return &[_]u8{};
        const arena_slice = self.arena.alloc(u8, len);
        @memcpy(arena_slice, buf[0..len]);
        return arena_slice;
    }


pub fn isExprStart(tag: TokenTag) bool {
        return switch (tag) {
            .integer_literal, .float_literal, .string_literal, .byte_string_literal, .char_literal, .true_kw, .false_kw, .null_kw, .undefined_kw, .identifier, .print, .lparen, .lbracket, .lbrace, .const_kw, .minus, .amp, .plus, .tilde, .bang, .star, .new, .free, .if_kw, .match_kw, .catch_kw => true,
            else => false,
        };
    }


pub fn makeBinary(self: *Parser, op: ast.Expr.BinaryOp, lhs: Expr, rhs: Expr) Expr {
        const lhs_buf = self.arena.alloc(Expr, 1);
        lhs_buf[0] = lhs;
        const rhs_buf = self.arena.alloc(Expr, 1);
        rhs_buf[0] = rhs;
        return Expr{ .payload = .{ .binary = .{ .op = op, .lhs = &lhs_buf[0], .rhs = &rhs_buf[0] } }, .loc = lhs.loc };
    }


pub fn makeRange(self: *Parser, lhs: Expr, rhs: Expr, inclusive: bool) Expr {
        const lb = self.arena.alloc(Expr, 1);
        lb[0] = lhs;
        const rb = self.arena.alloc(Expr, 1);
        rb[0] = rhs;
        return Expr{ .payload = .{ .range = .{ .start = &lb[0], .end = &rb[0], .inclusive = inclusive } }, .loc = lhs.loc };
    }


pub fn parseAdditive(self: *Parser) Expr {
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


pub fn parseBitAnd(self: *Parser) Expr {
        var lhs = self.parseShift();
        while (self.peek().tag == .amp) {
            self.advance();
            const rhs = self.parseShift();
            lhs = self.makeBinary(.bitand, lhs, rhs);
        }
        return lhs;
    }


pub fn parseBitOr(self: *Parser) Expr {
        var lhs = self.parseBitXor();
        while (self.peek().tag == .pipe) {
            self.advance();
            const rhs = self.parseBitXor();
            lhs = self.makeBinary(.bitor, lhs, rhs);
        }
        return lhs;
    }


pub fn parseBitXor(self: *Parser) Expr {
        var lhs = self.parseBitAnd();
        while (self.peek().tag == .caret) {
            self.advance();
            const rhs = self.parseBitAnd();
            lhs = self.makeBinary(.bitxor, lhs, rhs);
        }
        return lhs;
    }


pub fn parseCast(self: *Parser) Expr {
        const start_loc = self.peek().loc;
        const lhs = self.parsePostfix();
        if (self.peek().tag != .as_kw) return lhs;
        const binding_loc = self.peek().loc;
        self.advance();
        const type_text = self.collectCastType();
        if (type_text.len == 0) {
            std.debug.print("error:{d}:{d}: expected type after 'as', got empty\n", .{ binding_loc.line, binding_loc.col });
            std.process.exit(1);
        }
        const buf = self.arena.alloc(Expr, 1);
        buf[0] = lhs;
        return Expr{ .payload = .{ .cast = .{ .expr = &buf[0], .type_text = type_text } }, .loc = start_loc };
    }


pub fn parseComparison(self: *Parser) Expr {
        const lhs = self.parseBitOr();
        const op: ast.Expr.BinaryOp = switch (self.peek().tag) {
            .eq_eq => .eq,
            .bang_eq => .ne,
            .lt => .lt,
            .gt => .gt,
            .lt_eq => .le,
            .gt_eq => .ge,
            else => return lhs,
        };
        self.advance();
        const rhs = self.parseBitOr();
        // No chaining: another comparison op directly following means the
        // user wrote `a < b < c` or similar, which the manual rejects.
        const peek_tok = self.peek();
        switch (peek_tok.tag) {
            .eq_eq, .bang_eq, .lt, .gt, .lt_eq, .gt_eq => {
                std.debug.print("error:{d}:{d}: comparison cannot chain ({s}); use '&&' or parens\n", .{ peek_tok.loc.line, peek_tok.loc.col, @tagName(peek_tok.tag) });
                std.process.exit(1);
            },
            else => {},
        }
        return self.makeBinary(op, lhs, rhs);
    }


pub fn parseExpr(self: *Parser) Expr {
        const start_loc = self.peek().loc;
        // Catch expressions (`expr catch HANDLER` or
        // `expr catch |err| HANDLER`) have the lowest precedence.
        // We parse the leading expression first, then check for `catch`.
        const lhs: Expr = switch (self.peek().tag) {
            .if_kw => self.parseIfExpr(),
            .match_kw => blk: {
                const m = self.parseMatchExpr();
                break :blk Expr{ .payload = .{ .match_expr = m }, .loc = start_loc };
            },
            .pipe => self.parseClosureExpr(),
            else => self.parseRange(),
        };
        if (self.peek().tag == .catch_kw) {
            return self.parseCatchExpr(lhs);
        }
        return lhs;
    }


pub fn parseCatchExpr(self: *Parser, lhs: Expr) Expr {
        // `lhs catch HANDLER` or `lhs catch |err| HANDLER`.
        // Already verified that peek() is `.catch_kw`.
        if (lhs.payload == .try_op) {
            // OK: `expr? catch ...`
        }
        self.advance(); // consume `catch`
        var err_binding: ?[]const u8 = null;
        // Check for the `|err|` binding form.
        if (self.peek().tag == .pipe) {
            self.advance(); // consume `|`
            const binding = self.expectIdent();
            err_binding = binding;
            self.expect(.pipe); // consume `|`
        }
        const handler = self.parseExpr();
        const lhs_buf = self.arena.alloc(Expr, 1);
        lhs_buf[0] = lhs;
        const handler_buf = self.arena.alloc(Expr, 1);
        handler_buf[0] = handler;
        return Expr{ .payload = .{ .catch_expr = .{
            .expr = &lhs_buf[0],
            .handler = &handler_buf[0],
            .err_binding = err_binding,
        } }, .loc = lhs.loc };
    }


pub fn parseIfExpr(self: *Parser) Expr {
        const start_loc = self.peek().loc;
        self.expect(.if_kw);
        // Suppress struct-literal parsing in if-expression's cond. The
        // expression-form `let x = if Foo { 1 } else { 2 }` is an
        // arbitrary-rhs use of `if`; without this scope the cond parseExpr
        // flow sees `Foo` followed by `{` with `allow_struct_lit = true`
        // (the new default) and routes into parseStructLit, silently
        // swallowing the cond's body as a field-init list. Mirrors the
        // same suppress wrap used in parseIfBranch / parseWhileStmt /
        // parseForStmt / parseMatchExpr — and is the 5th and last
        // carve-out this refactor needs. See `allow_struct_lit` field
        // doc for the broader rationale.
        const cond_buf = self.arena.alloc(Expr, 1);
        cond_buf[0] = blk: {
            const prev = self.allow_struct_lit;
            defer self.allow_struct_lit = prev;
            self.allow_struct_lit = false;
            break :blk self.parseExpr();
        };
        self.expect(.lbrace);
        const then_buf = self.arena.alloc(Expr, 1);
        then_buf[0] = self.parseExpr();
        self.expect(.rbrace);
        if (self.peek().tag != .else_kw) {
            const tok = self.peek();
            std.debug.print("error:{d}:{d}: 'if' as expression requires 'else' branch for a well-typed value\n", .{ tok.loc.line, tok.loc.col });
            std.process.exit(1);
        }
        self.advance();
        self.expect(.lbrace);
        const else_buf = self.arena.alloc(Expr, 1);
        else_buf[0] = self.parseExpr();
        self.expect(.rbrace);
        return Expr{ .payload = .{ .if_expr = .{
            .cond = &cond_buf[0],
            .then_expr = &then_buf[0],
            .else_expr = &else_buf[0],
        } }, .loc = start_loc };
    }


pub fn parseLogicalAnd(self: *Parser) Expr {
        var lhs = self.parseComparison();
        while (self.peek().tag == .amp_amp) {
            self.advance();
            const rhs = self.parseComparison();
            lhs = self.makeBinary(.land, lhs, rhs);
        }
        return lhs;
    }


pub fn parseLogicalOr(self: *Parser) Expr {
        var lhs = self.parseLogicalAnd();
        while (self.peek().tag == .pipe_pipe) {
            self.advance();
            const rhs = self.parseLogicalAnd();
            lhs = self.makeBinary(.lor, lhs, rhs);
        }
        return lhs;
    }


pub fn parseMultiplicative(self: *Parser) Expr {
        var lhs = self.parseUnary();
        while (true) {
            const op: ast.Expr.BinaryOp = switch (self.peek().tag) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => break,
            };
            self.advance();
            const rhs = self.parseUnary();
            lhs = self.makeBinary(op, lhs, rhs);
        }
        return lhs;
    }


pub fn parseRange(self: *Parser) Expr {
        // Range-as-prefix is not in the grammar — `0..10` requires a
        // preceding LHS that's a full Expression. We start from
        // parseLogicalOr for both sides so `0..10` parses as Range(0, 10)
        // but `0 + 1..10` parses as Range(0 + 1, 10) (range binds looser).
        //
        // IMPORTANT: peek the range/ellipsis tag AFTER parsing the LHS, not
        // before. Pre-fix this function captured `peek().tag` into `tok`
        // before calling `parseLogicalOr`. When the source was `for x in
        // 0..10 { … }`, that snapshot captured `.integer_literal` for `0`,
        // LHS parsing consumed `0` leaving the parser looking at `.range`,
        // but the stale `tok` flag stayed `.integer_literal` so the range
        // branch never fired — `..10` orphaned and the next call
        // (`parseBlock`) surfaced `expected lbrace, got '..'`. Decoupling
        // the peek from LHS parsing allows `0..10` to surface as a single
        // `RangeExpr` while still disallowing the prefix form (when peek
        // returns non-range non-ellipsis BEFORE the LHS, we just return lhs).
        const lhs = self.parseLogicalOr();
        const tok = self.peek().tag;
        if (tok == .range) {
            self.advance();
            const rhs = self.parseLogicalOr();
            self.rejectRangeChaining();
            return self.makeRange(lhs, rhs, false);
        }
        if (tok == .ellipsis) {
            // Ellipsis is only a range op when followed by an expression
            // starter (e.g. `0...5` → Range(0, 5, inclusive=true)). In
            // array-lit fill mode `[N]ty { 0 ... }`, the `.ellipsis` is
            // consumed by parseArrayLit AS the fill marker AFTER parseExpr
            // returns just `0` — NOT here. If we fired this arm
            // unconditionally, we'd try to parse `}` (or `;`, or EOF) as
            // the RHS expression and surface a misleading `expected X`
            // error. peekAhead gives 2-token lookahead so we can decide
            // without committing to consuming `.ellipsis` first.
            if (!isExprStart(self.peekAhead(1))) return lhs;
            self.advance();
            const rhs = self.parseLogicalOr();
            self.rejectRangeChaining();
            return self.makeRange(lhs, rhs, true);
        }
        return lhs;
    }


pub fn parseShift(self: *Parser) Expr {
        var lhs = self.parseAdditive();
        while (true) {
            const op: ast.Expr.BinaryOp = switch (self.peek().tag) {
                .lt_lt => .shl,
                .gt_gt => .shr,
                else => break,
            };
            self.advance();
            const rhs = self.parseAdditive();
            lhs = self.makeBinary(op, lhs, rhs);
        }
        return lhs;
    }


pub fn parseUnary(self: *Parser) Expr {
        const start_loc = self.peek().loc;
        const op: ast.Expr.UnaryOp = switch (self.peek().tag) {
            .minus => .neg,
            .tilde => .bnot,
            .bang => .lnot,
            .star => .deref,
            .amp => .addr,
            else => return self.parseCast(),
        };
        self.advance();
        const operand = self.parseUnary();
        const buf = self.arena.alloc(Expr, 1);
        buf[0] = operand;
        return Expr{ .payload = .{ .unary = .{ .op = op, .operand = &buf[0] } }, .loc = start_loc };
    }


pub fn rejectRangeChaining(self: *Parser) void {
        const peek_tok = self.peek();
        switch (peek_tok.tag) {
            .range, .ellipsis => {
                std.debug.print("error:{d}:{d}: range operator cannot chain; use '&&' or parentheses\n", .{ peek_tok.loc.line, peek_tok.loc.col });
                std.process.exit(1);
            },
            else => {},
        }
    }

