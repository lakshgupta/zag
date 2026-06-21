// src/parser/stmt.zig - file-scope method bodies for the stmt bucket.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");
const core = @import("core.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Parser = core.Parser;

// Re-export core.zig file-scope isLiteralInit called unqualified from
// stmt.zigs parseBinding body.
const isLiteralInit = core.isLiteralInit;


pub fn compoundOpForTag(tag: TokenTag) ?ast.Expr.BinaryOp {
        return switch (tag) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .percent_eq => .mod,
            .amp_eq => .bitand,
            .pipe_eq => .bitor,
            .caret_eq => .bitxor,
            .lt_lt_eq => .shl,
            .gt_gt_eq => .shr,
            else => null,
        };
    }


pub fn parseAssign(self: *Parser) Stmt.AssignStmt {
        const name = self.expectIdent();
        self.expect(.equals);
        const value = self.parseExpr();
        return .{ .name = name, .value = value };
    }


pub fn parseBinding(self: *Parser, kind: ast.BindingKind) Stmt.BindingStmt {
        // The kind determines which leading keyword the binding must start
        // with. The lexer enforces `let`/`var`/`const` as reserved
        // `TokenTag`s so a user-shadowed identifier never reaches us here.
        const kw: TokenTag = switch (kind) {
            .let => .let,
            .var_binding => .var_kw,
            .const_binding => .const_kw,
        };
        // Capture the binding keyword's loc BEFORE consume so error
        // diagnostics point at where the user wrote `let` / `var` /
        // `const`, not at the next token (`:` or `=` or `(`).
        const binding_loc = self.peek().loc;
        self.expect(kw);
        const pattern = self.parseBindingPattern();
        // Map the parser-internal `BindingKind` to the user-facing keyword
        // spelling so error messages don't leak the TokenTag literal
        // (`var_kw` would surface in user code which only knows `var`).
        const kind_name: []const u8 = switch (kind) {
            .let => "let",
            .var_binding => "var",
            .const_binding => "const",
        };
        if (pattern == .name) {
            // Plain single-name binding: the language is statically typed, so
            // a `: T` annotation is REQUIRED for any init shape that doesn't
            // self-describe its type. The carve-out is the LITERAL Expr
            // kinds (int/float/bool/char/string/byte_string/null/undefined
            // literals + tuple / array / template literals) — each carries
            // its type directly in the source form, so the binding is
            // statically typed even when no explicit `: T` annotation is
            // written. Non-literal inits (binary expressions, idents,
            // calls, etc.) still require an annotation because their type
            // is computed from operand types and zag has no inference for
            // that yet. The pattern's `.name` text is promoted into the
            // legacy `name` field so callers that read `stmt.let.name`
            // continue to work.
            var type_name: ?[]const u8 = null;
            if (self.peek().tag == .colon) {
                self.advance();
                // Use the same multi-token collector that `as` casts use so
                // binding annotations can carry pointer types like
                // `*raw u8` consistently with cast destinations. Previously
                // this called `expectIdent` which rejected `.star`, breaking
                // raw-pointer bindings. `collectCastType` arena-allocates
                // the result so the slice is stable after the parser
                // function returns.
                const collected = self.collectCastType();
                if (collected.len == 0) {
                    std.debug.print("error:{d}:{d}: {s} binding requires a type name after ':' (e.g. {s} {s}: T = …)\\n", .{
                        binding_loc.line,
                        binding_loc.col,
                        kind_name,
                        kind_name,
                        pattern.name,
                    });
                    std.process.exit(1);
                }
                type_name = collected;
            }
            self.expect(.equals);
            const initializer = self.parseExpr();
            if (type_name == null and !isLiteralInit(initializer)) {
                std.debug.print("error:{d}:{d}: {s} requires an explicit type annotation when binding non-tuple values (e.g. {s} {s}: T = …)\n", .{
                    binding_loc.line,
                    binding_loc.col,
                    kind_name,
                    kind_name,
                    pattern.name,
                });
                std.process.exit(1);
            }
            return .{ .name = pattern.name, .type_name = type_name, .init = initializer };
        }
        // Destructuring form: per the parser-level type-annotation rule, a
        // colon after the opening `(` or `[` IS NOT a binding-name annotation
        // (those tokens select the destructuring shape) — pattern leaves are
        // type-analyzed at codegen time using the source expression's literal
        // shape and the matching element's inferred zig type. We reject
        // colon-on-pattern here so the parser doesn't try to consume `:` as
        // a top-level annotation; the `name` field is the empty sentinel
        // (codegen ignores it when `pattern` is set).
        const peek_tok = self.peek();
        if (peek_tok.tag == .colon) {
            std.debug.print("error:{d}:{d}: {s} pattern: per-leaf type annotations are not supported; types are inferred from the source element\n", .{
                binding_loc.line,
                binding_loc.col,
                kind_name,
            });
            std.process.exit(1);
        }
        self.expect(.equals);
        const initializer = self.parseExpr();
        return .{ .name = "", .type_name = null, .init = initializer, .pattern = pattern };
    }


pub fn parseBindingPattern(self: *Parser) ast.BindingPattern {
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
                    // `...NAME` rest-binding — must be the LAST pattern
                    // in the destructuring tuple. Parsed inline so a
                    // trailing `,` is NOT consumed (rest is terminal).
                    // Phase 1 invokes `.rest = RestBinding` with
                    // `before_count = pat_count` (number of patterns
                    // that came before this rest); codegen uses this
                    // to materialise the leftover elements.
                    if (self.peek().tag == .ellipsis) {
                        self.advance();
                        const rest_name = self.expectIdent();
                        pats_buf[pat_count] = .{ .rest = .{ .name = rest_name, .before_count = @intCast(pat_count) } };
                        pat_count += 1;
                        break;
                    }
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
            // Phase 2: mirror the tuple `.lparen` arm's `...NAME` rest-binding
            // detection so balanced `[a, b, ...rest]` patterns parse cleanly.
            // The rest-binding must be the LAST pattern in the array (the
            // tuple walker enforces this with an early `break` after
            // consuming the rest); codegen uses `before_count` to slice the
            // originating array's remaining elements into a sub-tuple at
            // emission time. The architectural symmetry with the tuple arm
            // (same `before_count = pat_count` numbering, same `rest` arm
            // dispatch in codegen) means no codegen changes are required for
            // the array-with-rest surface beyond what already exists — both
            // shapes lower to `__destruct_N[i][j..]` zig indexing, and zig
            // 0.16 accepts bracketed indexing on BOTH arrays and anonymous
            // structs.
            self.advance();
            var pats_buf: [16]ast.BindingPattern = undefined;
            var pat_count: usize = 0;
            if (self.peek().tag != .rbracket) {
                pats_buf[pat_count] = self.parseBindingPattern();
                pat_count += 1;
                while (self.peek().tag == .comma) {
                    self.advance();
                    // Phase 2 mirror: `.ellipsis IDENT` triggers rest-binding.
                    // Terminal (no trailing `,`) — break immediately so the
                    // closing `]` matches on the next expect().
                    if (self.peek().tag == .ellipsis) {
                        self.advance();
                        const rest_name = self.expectIdent();
                        pats_buf[pat_count] = .{ .rest = .{ .name = rest_name, .before_count = @intCast(pat_count) } };
                        pat_count += 1;
                        break;
                    }
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


pub fn parseBlock(self: *Parser) []const Stmt {
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


pub fn parseCompoundAssign(self: *Parser, op: ast.Expr.BinaryOp) Stmt.AssignStmt {
        const name = self.expectIdent();
        // Consume the OP_EQ token — parseStmt's lookahead verified the
        // specific tag, but `advance` walks past whatever OP_EQ associate
        // matched the originalTokenTag` to the matching TokenTag forms.
        self.advance();
        const rhs = self.parseExpr();
        // Desugar `x OP= rhs` → `x = x OP rhs`. The ident Expr("x") and the
        // `rhs` get lifted into arena-allocated slots via makeBinary so
        // their addresses match the BinaryExpr's pointer convention.
        const bin_expr = self.makeBinary(op, .{ .ident = name }, rhs);
        return .{ .name = name, .value = bin_expr };
    }


pub fn parseDefer(self: *Parser) Stmt.DeferStmt {
        self.expect(.defer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }


pub fn parseErrDefer(self: *Parser) Stmt.ErrDeferStmt {
        self.expect(.errdefer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }


pub fn parseFieldAssign(self: *Parser) Stmt.FieldAssignStmt {
        const target_name = self.expectIdent();
        const target = self.arena.alloc(Expr, 1);
        target[0] = .{ .ident = target_name };
        self.expect(.dot);
        const field_name = self.expectIdent();
        self.expect(.equals);
        const value = self.parseExpr();
        return .{ .target = &target[0], .field_name = field_name, .value = value };
    }


pub fn parseForStmt(self: *Parser) Stmt.ForStmt {
        self.expect(.for_kw);
        // Pattern-side: ident or `_` (discard). Lookahead distinguishes
        // `_` from a real name.
        var pat: ast.Pattern = undefined;
        const tok = self.peek();
        if (tok.tag == .identifier and std.mem.eql(u8, tok.text, "_")) {
            self.advance();
            pat = .{ .discard = {} };
        } else {
            // Reject any non-ident token at pattern position so the parser
            // surfaces a clear error instead of silently accepting a
            // malformed `for` form. The error message names the offending
            // token for easier debugging.
            if (tok.tag != .identifier) {
                std.debug.print("error:{d}:{d}: expected for-loop binding (ident or '_'), got '{s}'\n", .{ tok.loc.line, tok.loc.col, tok.text });
                std.process.exit(1);
            }
            pat = .{ .ident = self.expectIdent() };
        }
        self.expect(.in_kw);
        // Suppress struct-literal parsing in for-iter position. Mirrors
        // parseIfBranch / parseWhileStmt / parseMatchExpr: the
        // immediately-following `{` must be the for-loop body, not a
        // struct-literal payload. See `allow_struct_lit` field doc.
        const iter = blk: {
            const prev = self.allow_struct_lit;
            defer self.allow_struct_lit = prev;
            self.allow_struct_lit = false;
            break :blk self.parseExpr();
        };
        const body = self.parseBlock();
        return .{ .pattern = pat, .iter = iter, .body = body };
    }


pub fn parseIfBranch(self: *Parser) Stmt.IfStmt {
        const start_loc = self.peek().loc;
        self.expect(.if_kw);
        // Suppress struct-literal parsing in if-condition position. The
        // default `allow_struct_lit = true` everywhere; the principled
        // carve-out is the EXACT list of "block-start `{` required" sites
        // (if-cond, while-cond, for-iter, match-scrutinee). `if Foo { ... }`
        // should parse as cond=ident(Foo), body={...} — NOT as a
        // struct-literal that swallows the if-body. Inside the body and
        // any chained else-if below (parseStmtList → parseExpr), the flag
        // reverts to default-true so `let v = Vec3 { ... }` inside the
        // body still parses correctly. Scoped via `blk:` so the
        // suppression is precise: enter-suppress, parse the single cond
        // Expr, exit-restore via defer. See the `allow_struct_lit` field
        // doc for the broader design rationale.
        const cond = blk: {
            const prev = self.allow_struct_lit;
            defer self.allow_struct_lit = prev;
            self.allow_struct_lit = false;
            break :blk self.parseExpr();
        };
        self.expect(.lbrace);
        const then_body = self.parseStmtList();
        self.expect(.rbrace);
        var else_kind: Stmt.IfStmt.IfElseKind = .{ .none = {} };
        if (self.peek().tag == .else_kw) {
            self.advance();
            if (self.peek().tag == .if_kw) {
                // Recursive descent into the chained `else if cond { … }`.
                // The chain can be arbitrarily long because the recursive
                // boxed `*IfStmt` desugars to a left-leaning list, not a
                // self-referential recursion in the type system. NOTE: do
                // NOT advance past `.if_kw` here — the nested call below
                // recurses into `parseIfBranch`, which begins with
                // `expect(.if_kw)`. A premature advance skipped that token
                // and surfaced as `expected if_kw, got <cond-ident>` in the
                // chained `else if` test cases.
                const inner = self.parseIfBranch();
                const boxed = self.arena.alloc(Stmt.IfStmt, 1);
                boxed[0] = inner;
                else_kind = .{ .if_chain = &boxed[0] };
            } else {
                self.expect(.lbrace);
                const else_body = self.parseStmtList();
                self.expect(.rbrace);
                else_kind = .{ .block = else_body };
            }
        }
        _ = start_loc;
        return .{ .cond = cond, .then_body = then_body, .else_kind = else_kind };
    }


pub fn parseIndexAssign(self: *Parser) Stmt.IndexAssignStmt {
        const target = self.parsePrimary();
        self.expect(.lbracket);
        const index = self.parseExpr();
        self.expect(.rbracket);
        self.expect(.equals);
        const value = self.parseExpr();
        const target_buf = self.arena.alloc(Expr, 1);
        target_buf[0] = target;
        const index_buf = self.arena.alloc(Expr, 1);
        index_buf[0] = index;
        return .{ .target = &target_buf[0], .index = &index_buf[0], .value = value };
    }


pub fn parseMatchExpr(self: *Parser) ast.Expr.MatchExpr {
        self.expect(.match_kw);
        // Suppress struct-literal parsing in match-scrutinee position.
        // Mirrors parseIfBranch / parseWhileStmt: the immediately-
        // following `{` must be the match-block arms list, not a
        // struct-literal payload.
        const scrut_buf = self.arena.alloc(Expr, 1);
        scrut_buf[0] = blk: {
            const prev = self.allow_struct_lit;
            defer self.allow_struct_lit = prev;
            self.allow_struct_lit = false;
            break :blk self.parseExpr();
        };
        self.expect(.lbrace);
        var arms_buf: [16]ast.MatchArm = undefined;
        var arm_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            // Arm: `Pat [if guard] => body,`
            const pat = self.parsePattern();
            var guard: ?*ast.Expr = null;
            if (self.peek().tag == .if_kw) {
                self.advance();
                const guard_buf = self.arena.alloc(Expr, 1);
                guard_buf[0] = self.parseExpr();
                guard = &guard_buf[0];
            }
            self.expect(.arrow); // =>
            // Arm body is a single expression, NOT braced. The earlier
            // `self.expect(.lbrace)` / `expect(.rbrace)` pair around the
            // body forced a `=> { expr }` shape, but zag's grammar (and
            // every test in main.zig's match-stmt suite) writes arms as
            // `=> expr`. With the lbrace/rbrace expectations in place, the
            // parser hit `expected lbrace, got 'one'` on the canonical
            // `1 => "one"` form. The brace pair was removed; the body now
            // commits to one Expr, terminated by either a comma (handled
            // below) or the enclosing match-block `}`.
            const body_buf = self.arena.alloc(Expr, 1);
            body_buf[0] = self.parseExpr();
            // Comma separator between arms. The trailing comma before `}`
            // is optional — if rbrace is the immediate next token after the
            // rbrace of the body, we accept it without error.
            if (self.peek().tag == .comma) self.advance();
            arms_buf[arm_count] = .{ .pat = pat, .guard = guard, .expr = &body_buf[0] };
            arm_count += 1;
        }
        self.expect(.rbrace);
        const arms = self.arena.alloc(ast.MatchArm, arm_count);
        @memcpy(arms, arms_buf[0..arm_count]);
        return .{ .scrutinee = &scrut_buf[0], .arms = arms };
    }


pub fn parsePattern(self: *Parser) ast.Pattern {
        const tok = self.peek();
        switch (tok.tag) {
            .integer_literal => {
                // Range detection: if literal is followed by .. or ...,
                // and the next-after-that is another int literal, it's a
                // range pattern. Otherwise it's a literal pattern.
                if (self.pos + 2 < self.tokens.len and
                    (self.tokens[self.pos + 1].tag == .range or self.tokens[self.pos + 1].tag == .ellipsis) and
                    self.tokens[self.pos + 2].tag == .integer_literal)
                {
                    const start_text = tok.text;
                    const sep = self.tokens[self.pos + 1].tag;
                    const inclusive = sep == .ellipsis;
                    const end_text = self.tokens[self.pos + 2].text;
                    self.advance(); // start
                    self.advance(); // .. or ...
                    self.advance(); // end
                    const start_buf = self.arena.alloc(Expr, 1);
                    start_buf[0] = .{ .int_lit = start_text };
                    const end_buf = self.arena.alloc(Expr, 1);
                    end_buf[0] = .{ .int_lit = end_text };
                    return .{ .range = .{ .start = &start_buf[0], .end = &end_buf[0], .inclusive = inclusive } };
                }
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = .{ .int_lit = tok.text };
                return .{ .literal = &lit_buf[0] };
            },
            .string_literal => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = .{ .string_lit = tok.text };
                return .{ .literal = &lit_buf[0] };
            },
            .true_kw => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = .{ .bool_lit = true };
                return .{ .literal = &lit_buf[0] };
            },
            .false_kw => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = .{ .bool_lit = false };
                return .{ .literal = &lit_buf[0] };
            },
            .char_literal => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = .{ .char_lit = tok.text };
                return .{ .literal = &lit_buf[0] };
            },
            .identifier => {
                // Enum-variant pattern detection (docs/manual/13). When the
                // leading identifier is PascalCase (Rust/Zig convention for
                // type + variant names), the three shapes are:
                //   1. `Enum.Variant(args...)` — qualified; emits
                //      enum_name="Enum", variant_name="Variant", bindings set.
                //   2. `Variant(args...)` — unqualified, type-inferred per
                //      docs/13; emits enum_name="", variant_name="Variant",
                //      bindings set.
                //   3. `Variant` (bare, followed by `=>`, `if guard`,
                //      `,`, `}`, newline, or eof) — bare variant pattern
                //      with bindings=null.
                // Lowercase identifiers fall through to the existing
                // ident-binding path (or `_` → discard).
                if (tok.text.len > 0 and tok.text[0] >= 'A' and tok.text[0] <= 'Z') {
                    // Qualified shape: peek 0 = .dot, peek 1 = identifier.
                    if (self.pos + 1 < self.tokens.len and
                        self.tokens[self.pos + 1].tag == .dot and
                        self.pos + 2 < self.tokens.len and
                        self.tokens[self.pos + 2].tag == .identifier)
                    {
                        const enum_name = self.expectIdent();
                        self.expect(.dot);
                        const variant_name = self.expectIdent();
                        var bindings: ?[]?[]const u8 = null;
                        if (self.peek().tag == .lparen) {
                            self.advance();
                            var bind_buf: [16]?[]const u8 = undefined;
                            var bind_count: usize = 0;
                            if (self.peek().tag != .rparen) {
                                bind_buf[bind_count] = self.parsePatternBinding();
                                bind_count += 1;
                                while (self.peek().tag == .comma) {
                                    self.advance();
                                    bind_buf[bind_count] = self.parsePatternBinding();
                                    bind_count += 1;
                                }
                            }
                            self.expect(.rparen);
                            const bindings_arena = self.arena.alloc(?[]const u8, bind_count);
                            @memcpy(bindings_arena, bind_buf[0..bind_count]);
                            bindings = bindings_arena;
                        }
                        return .{ .enum_variant = .{
                            .enum_name = enum_name,
                            .variant_name = variant_name,
                            .bindings = bindings,
                        } };
                    }
                    // Unqualified shape: peek 0 = .lparen — type-inferred binding.
                    if (self.pos + 1 < self.tokens.len and
                        self.tokens[self.pos + 1].tag == .lparen)
                    {
                        const variant_name = self.expectIdent();
                        self.expect(.lparen);
                        var bind_buf: [16]?[]const u8 = undefined;
                        var bind_count: usize = 0;
                        if (self.peek().tag != .rparen) {
                            bind_buf[bind_count] = self.parsePatternBinding();
                            bind_count += 1;
                            while (self.peek().tag == .comma) {
                                self.advance();
                                bind_buf[bind_count] = self.parsePatternBinding();
                                bind_count += 1;
                            }
                        }
                        self.expect(.rparen);
                        const bindings_arena = self.arena.alloc(?[]const u8, bind_count);
                        @memcpy(bindings_arena, bind_buf[0..bind_count]);
                        return .{ .enum_variant = .{
                            .enum_name = "",
                            .variant_name = variant_name,
                            .bindings = bindings_arena,
                        } };
                    }
                    // Bare-variant shape: peek 0 is arm-terminator
                    // (`=>`, `if`, `,`, `}`, newline, or eof). The
                    // PascalCase gate plus the terminator check ensure we
                    // don't accidentally swallow a downstream ident binding.
                    if (self.pos + 1 < self.tokens.len) {
                        const next_tag = self.tokens[self.pos + 1].tag;
                        switch (next_tag) {
                            .arrow, .if_kw, .comma, .rbrace, .newline, .eof => {
                                const variant_name = self.expectIdent();
                                return .{ .enum_variant = .{
                                    .enum_name = "",
                                    .variant_name = variant_name,
                                    .bindings = null,
                                } };
                            },
                            else => {},
                        }
                    }
                }
                // Existing path: `_` → discard, else → ident binding.
                if (std.mem.eql(u8, tok.text, "_")) {
                    self.advance();
                    return .{ .discard = {} };
                }
                const name = self.expectIdent();
                return .{ .ident = name };
            },
            else => {
                std.debug.print("error:{d}:{d}: expected match-arm pattern (literal, range, ident, or '_'), got '{s}'\n", .{ tok.loc.line, tok.loc.col, tok.text });
                std.process.exit(1);
            },
        }
    }


pub fn parsePatternBinding(self: *Parser) ?[]const u8 {
        const tok = self.peek();
        if (tok.tag == .identifier and std.mem.eql(u8, tok.text, "_")) {
            self.advance();
            return null;
        }
        return self.expectIdent();
    }


pub fn parseReturnStmt(self: *Parser) Stmt.ReturnStmt {
        self.expect(.return_kw);
        // Bare return: only valid when the next token is `;`, `}`, or
        // newline-terminated (which our block parser strips). For body
        // source like `return;` parse post-newline `parsePostStmt` runs
        // before the next parseStmt call so the leading token is whatever
        // follows; treat newlines and `}` as bare.
        if (self.peek().tag == .newline or self.peek().tag == .rbrace or self.peek().tag == .eof) {
            return .{ .value = null };
        }
        const value = self.parseExpr();
        return .{ .value = value };
    }


pub fn parseStmt(self: *Parser) Stmt {
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
                // Multi-form lookahead. statement-leading identifier can be:
                //   - `name = expr;`           → bare assign (.assign)
                //   - `name OP_EQ rhs;`        → compound assign (desugared)
                //   - `name[i] = x;`           → indexed write (.index_assign)
                //   - `name.field = expr;`     → field-write (.field_assign)
                //   - `name ...` (any other)   → expr_stmt (call / ident / index read)
                //
                // Without this lookahead, the identifier would be consumed
                // by parseExpr as an `.ident` immediately and the second
                // token (`=`, `+=`, …) would never see its lhs.
                if (self.pos + 1 < self.tokens.len) {
                    const next = self.tokens[self.pos + 1].tag;
                    if (next == .equals) {
                        return .{ .assign = self.parseAssign() };
                    }
                    if (compoundOpForTag(next)) |op| {
                        return .{ .assign = self.parseCompoundAssign(op) };
                    }
                    if (next == .lbracket) {
                        return .{ .index_assign = self.parseIndexAssign() };
                    }
                    // 3-token lookahead for `name . ident =` field-write.
                    // Pattern: ident (current) . dot (next) . ident (n+2) . equals (n+3).
                    // Only the canonical `bare-name . bare-name = value` form
                    // is supported via this lookahead — for more complex LHSs
                    // like `(getBox()).x = …` or `arr[i].x = …`, the user can
                    // extract the value to a local first then field-assign.
                    if (next == .dot and
                        self.pos + 2 < self.tokens.len and
                        self.tokens[self.pos + 2].tag == .identifier and
                        self.pos + 3 < self.tokens.len and
                        self.tokens[self.pos + 3].tag == .equals)
                    {
                        return .{ .field_assign = self.parseFieldAssign() };
                    }
                }
                return .{ .expr_stmt = self.parseExpr() };
            },
            .defer_kw => return .{ .defer_stmt = self.parseDefer() },
            .errdefer_kw => return .{ .errdefer_stmt = self.parseErrDefer() },
            .unsafe_kw => return .{ .unsafe_block = self.parseUnsafeBlock() },
            .if_kw => return .{ .if_stmt = self.parseIfBranch() },
            .while_kw => return .{ .while_stmt = self.parseWhileStmt() },
            .for_kw => return .{ .for_stmt = self.parseForStmt() },
            .match_kw => return .{ .match_stmt = self.parseMatchExpr() },
            .break_kw => {
                self.advance();
                return .{ .break_stmt = {} };
            },
            .continue_kw => {
                self.advance();
                return .{ .continue_stmt = {} };
            },
            .return_kw => return .{ .return_stmt = self.parseReturnStmt() },
            else => return .{ .expr_stmt = self.parseExpr() },
        }
    }


pub fn parseStmtList(self: *Parser) []const Stmt {
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
        const stmts = self.arena.alloc(Stmt, stmt_count);
        @memcpy(stmts, stmts_buf[0..stmt_count]);
        return stmts;
    }


pub fn parseUnsafeBlock(self: *Parser) []const Stmt {
        self.expect(.unsafe_kw);
        return self.parseBlock();
    }


pub fn parseWhileStmt(self: *Parser) Stmt.WhileStmt {
        self.expect(.while_kw);
        // Suppress struct-literal parsing in while-condition position.
        // Mirrors parseIfBranch: the immediately-following `{` must be
        // the while body, not a struct-literal payload. See
        // `allow_struct_lit` field doc for the broader rationale.
        const cond = blk: {
            const prev = self.allow_struct_lit;
            defer self.allow_struct_lit = prev;
            self.allow_struct_lit = false;
            break :blk self.parseExpr();
        };
        const body = self.parseBlock();
        return .{ .cond = cond, .body = body };
    }

