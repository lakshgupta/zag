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
                // Multi-form lookahead. statement-leading identifier can be:
                //   - `name = expr;`           → bare assign (.assign)
                //   - `name OP_EQ rhs;`        → compound assign (desugared)
                //   - `name[i] = x;`           → indexed write (.index_assign)
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

    /// Parse a compound assignment `x OP= rhs` and desugar it into a bare
    /// `Stmt.AssignStmt` whose value is `binary(op, ident("x"), rhs)`. No
    /// new AST node is emitted — the doc frames the compound forms as sugar
    /// for `x = x OP rhs`, so the existing AssignStmt shape can carry both.
    /// `op` is supplied by `compoundOpForTag` via the parseStmt lookahead.
    fn parseCompoundAssign(self: *Parser, op: ast.Expr.BinaryOp) Stmt.AssignStmt {
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

    /// Parse `target[i] = value`. The full power is determined by
    /// parseStmt.identifier branch's lookahead — the only entry is when
    /// the current token is `.identifier` and the next is `.lbracket`.
    /// The target is parsed as a primary expression (NOT invoking the
    /// `[N]T { ... }` array-lit path because that's a leading-`[` only),
    /// then the bracketed index is expected, then `=`, then the value.
    /// Multi-dim index writes (`arr[i][j] = x`) are NOT supported here
    /// because they would require the chained-Index form on the LHS —
    /// supported only via explicit parens like `(arr[i])[j] = x` once
    /// chained Index parfactoring lands.
    fn parseIndexAssign(self: *Parser) Stmt.IndexAssignStmt {
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

    /// Map a compound-assign TokenTag to its corresponding BinaryOp. Returns
    /// `null` for non-compound tags so parseStmt's identifier branch can
    /// dispatch in one switch (`next == equals` → parseAssign,
    /// `compoundOpForTag(next) != null` → parseCompoundAssign, etc).
    fn compoundOpForTag(tag: TokenTag) ?ast.Expr.BinaryOp {
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

    fn parseDefer(self: *Parser) Stmt.DeferStmt {
        self.expect(.defer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }

    /// `errdefer expr;` — runs the expression ONLY if the enclosing scope
    /// exits via `?`-propagation or explicit `return Err(...)`. Mirrors zig
    /// 0.16's `errdefer` keyword one-to-one. Example (from
    /// `docs/19-memory.md` Pattern 2):
    ///   let a = compute()?;
    ///   errdefer free(a);
    ///   ...
    /// Used by the new carve-out where partial initialization must be rolled
    /// back on `?` but the success path skips the cleanup.
    fn parseErrDefer(self: *Parser) Stmt.ErrDeferStmt {
        self.expect(.errdefer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }

    /// `unsafe { <stmts> }` block marker. Sits in `parseStmt`'s dispatch so
    /// the leading ident-or-expression forms don't accidentally consume
    /// `unsafe` as a binding name; the keyword is reserved at token-time by
    /// `lexer.readIdent`. The zig 0.16 backend no longer has a block-form
    /// `unsafe` keyword — codegen emits the body wrapped in plain `{ ... }`
    /// with comment markers so the AST shape remains analyzable for future
    /// `-Dunsafe-block-check` tooling without changing the emitted
    /// zig semantics (raw pointer dereferences and `@ptrCast` are already
    /// unconditional in 0.16).
    fn parseUnsafeBlock(self: *Parser) []const Stmt {
        self.expect(.unsafe_kw);
        return self.parseBlock();
    }

    /// Parse one `if cond { stmts... }` head plus its optional else-branch.
    /// Consumes the leading `.if_kw` here (mirroring the convention used by
    /// parseWhileStmt / parseForStmt / parseMatchExpr / parseReturnStmt).
    /// Without this `expect`, parseExpr (called for the cond) would
    /// self-dispatch on `.if_kw` to `parseIfExpr`, leaving the parser with
    /// `if_kw` unconsumed and the cond never parsed — surfacing as
    /// `expected rbrace, got 'print'` on the body statement. The
    /// recursive `else if` chain is rendered via the `.if_chain` arm of
    /// `IfStmt.else_kind` (boxed `*IfStmt`); terminal `else { ... }` via
    /// the `.block` arm. The condition parses via `parseExpr` so binary
    /// precedence (e.g. `i < 10 && ready`) works without special-casing.
    fn parseIfBranch(self: *Parser) Stmt.IfStmt {
        const start_loc = self.peek().loc;
        self.expect(.if_kw);
        const cond = self.parseExpr();
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

    /// `if cond { expr } else { expr }` expression form. Used when `if_kw`
    /// is the leading token in an expression-position context
    /// (RHS of a `let`, inside a binary operand list, etc.). Each branch's
    /// `Expr` is lifted into an arena slot so the resulting `IfExpr`'s
    /// pointer fields point at stable storage (the existing BinaryExpr
    /// `*Expr` convention). The else-branch is REQUIRED for the
    /// expression form (otherwise the type would be `?T`); the parser
    /// emits a clear error if missing.
    fn parseIfExpr(self: *Parser) Expr {
        self.expect(.if_kw);
        const cond_buf = self.arena.alloc(Expr, 1);
        cond_buf[0] = self.parseExpr();
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
        return .{ .if_expr = .{
            .cond = &cond_buf[0],
            .then_expr = &then_buf[0],
            .else_expr = &else_buf[0],
        } };
    }

    /// `while cond { stmts... }`. `while let` is deferred to followup commit
    /// — surface requires enum-variant patterns which lexer doesn't tokenize.
    /// Return type is `Stmt.WhileStmt` (the inner payload struct), not the
    /// outer `Stmt` union, so the dispatch in `parseStmt` can assign the
    /// value into `.while_stmt = …` without a redundant re-wrap.
    fn parseWhileStmt(self: *Parser) Stmt.WhileStmt {
        self.expect(.while_kw);
        const cond = self.parseExpr();
        const body = self.parseBlock();
        return .{ .cond = cond, .body = body };
    }

    /// `for pat in iter { stmts... }`. Pattern is currently the one-element
    /// subset (ident or discard) — see `Stmt.for_stmt` doc for the
    /// tuple-pattern followup plan. After the pattern, parser expects `in`,
    /// then any expression for `iter`, then a `{ stmts }` body. Returns
    /// the inner payload struct `Stmt.ForStmt` so the dispatch in
    /// `parseStmt` can assign into `.for_stmt = …` directly.
    fn parseForStmt(self: *Parser) Stmt.ForStmt {
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
        const iter = self.parseExpr();
        const body = self.parseBlock();
        return .{ .pattern = pat, .iter = iter, .body = body };
    }

    /// `match scrutinee { arms... }` expression. Built once and reused for
    /// statement-position use (via `Stmt.match_stmt`) and expression-
    /// position use (via `Expr.match_expr`); the AST node lives in the
    /// `Expr` envelope. Arm bodies are single expressions per the user-
    /// confirmed shape; arm separator is comma.
    ///
    /// Scrutinee, guard, and arm body are each lifted into arena slots
    /// so the resulting `Expr.MatchExpr` and `MatchArm` pointer fields
    /// point at stable storage (mirrors the existing BinaryExpr `*Expr`
    /// cycle-breaking convention — see the `IfExpr` doc for why).
    fn parseMatchExpr(self: *Parser) ast.Expr.MatchExpr {
        self.expect(.match_kw);
        const scrut_buf = self.arena.alloc(Expr, 1);
        scrut_buf[0] = self.parseExpr();
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
            self.expect(.lbrace);
            const body_buf = self.arena.alloc(Expr, 1);
            body_buf[0] = self.parseExpr();
            self.expect(.rbrace);
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

    /// Parse one match-arm pattern. Four shapes:
    /// - `.literal(*LitExpr)` — int / bool / string / char literal value
    /// - `.range(...)`        — `int_lit..int_lit` or `int_lit...int_lit`
    /// - `.ident(name)`       — a name binding; the arm's body can reference it
    /// - `.discard`           — the wildcard `_`
    /// Enum-variant patterns are deferred to followup (need lexer support).
    /// Emit a clear error on patterns we can't express (tuple, array,
    /// prefix operators).
    ///
    /// Literal/range fields carry `*Expr` pointers (not value-typed
    /// Expr) for the same cycle-breaking reason as MatchArm/IfExpr
    /// fields — see the `Pattern` doc in ast.zig. Each pattern value
    /// is lifted into an arena slot before being wrapped in the
    /// pointer-typed union variant.
    fn parsePattern(self: *Parser) ast.Pattern {
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

    /// `return [expr];` — expr is optional, yielding bare `return;`.
    /// Returns the inner payload struct `Stmt.ReturnStmt` so the dispatch
    /// in `parseStmt` can assign into `.return_stmt = …` directly.
    fn parseReturnStmt(self: *Parser) Stmt.ReturnStmt {
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

    /// Helper for parsing the inside of a block. Caller is responsible for
    /// consuming the surrounding `{` and `}`. Skips leading newlines and
    /// terminates at the first non-newline token that's NOT a statement
    /// delimiter (i.e. when the next token is `}` the caller will consume).
    fn parseStmtList(self: *Parser) []const Stmt {
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

    /// Top-level entry point: parses a full Zag expression. Delegates to a
    /// 12-layer precedence ladder rooted at parseRange (lowest precedence)
    /// and terminating at parsePrimary (highest precedence). The ordering
    /// mirrors `docs/manual/05-operators.md`'s precedence table exactly
    /// so `1 + 2 * 3` parses as `1 + (2 * 3)` rather than `(1 + 2) * 3`,
    /// and `0..10 + 5` parses as `0..(10 + 5)` because range binds looser
    /// than additive.
    ///
    /// Handles expression-position `if` and `match` BEFORE delegating to
    /// the precedence ladder. The check is essential because the ladder's
    /// parseRange never sees `.if_kw` (its first layer parses an Expression
    /// for the LHS, then expects `.range` or `.ellipsis`); without the
    /// leading-token check at the entry, `let x = if cond { … } else { … };`
    /// would consume `let x = <parse-the-let>` and reject the `if` because
    /// parseExpr only knows how to dispatch to binary-expr layers.
    fn parseExpr(self: *Parser) Expr {
        switch (self.peek().tag) {
            .if_kw => return self.parseIfExpr(),
            .match_kw => {
                const m = self.parseMatchExpr();
                // Wrap in Expr.match_expr so codegen sees the same node shape
                // regardless of whether the call site is statement-position
                // or expression-position. Statement-position call sites
                // (i.e. `parseStmt`'s `.match_kw` arm) build the same
                // match_expr and route the codegen via this exact node.
                return .{ .match_expr = m };
            },
            else => return self.parseRange(),
        }
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

    /// Multiplicative layer: chains `*`/`/`/`%` while the next token is one
    /// of those (precedence class 3 per the manual). Adds modulo `%` to the
    /// previously-only-`*`/`/` set. Each operand recurses through
    /// parseUnary so leading `-x`/`!x`/`~x`/`*x` (deref) prefix operators are
    /// consumed at this level too — important for `5 % -3` to attach the
    /// unary minus to the 3, not to the modulo result.
    fn parseMultiplicative(self: *Parser) Expr {
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

    // ------------------------------------------------------------------
    // 12-layer precedence ladder
    // ------------------------------------------------------------------
    // The ordering below mirrors `docs/manual/05-operators.md` exactly:
    //   parseRange         class 12 (lowest precedence)
    //   parseLogicalOr     class 11
    //   parseLogicalAnd    class 10
    //   parseComparison    class 9 (no chaining — errors on `a < b < c`)
    //   parseBitOr         class 8
    //   parseBitXor        class 7
    //   parseBitAnd        class 6
    //   parseShift         class 5
    //   parseAdditive      class 4
    //   parseMultiplicative class 3 (extended with `%`)
    //   parseUnary         class 1 (prefix `-x`, `~x`, `!x`, `*x` deref)
    //   parsePostfix       nested between unary and primary — chains `[i]`
    //   parsePrimary       literal / paren / call / array-literal `[N]T {…}`
    // Each layer descends by calling the NEXT layer for operands, then
    // chains same-class operators via a `while` loop. The non-chaining
    // classes (range, comparison) use a single consume with explicit
    // error if a same-class op follows.
    // ------------------------------------------------------------------

    /// Range layer: lowest-precedence binary op. `a..b` (half-open) emits
    /// `.range { inclusive = false }` and `a...b` (inclusive) emits
    /// `.range { inclusive = true }`. Per the manual, range has None
    /// associativity — chaining `0..5..10` is a syntax error caught here.
    fn parseRange(self: *Parser) Expr {
        const tok = self.peek().tag;
        // Range-as-prefix is not in the grammar — `0..10` requires a
        // preceding LHS that's a full Expression. We start from
        // parseLogicalOr for both sides so `0..10` parses as Range(0, 10)
        // but `0 + 1..10` parses as Range(0 + 1, 10) (range binds looser).
        const lhs = self.parseLogicalOr();
        if (tok == .range) {
            self.advance();
            const rhs = self.parseLogicalOr();
            self.rejectRangeChaining();
            return self.makeRange(lhs, rhs, false);
        }
        if (tok == .ellipsis) {
            self.advance();
            const rhs = self.parseLogicalOr();
            self.rejectRangeChaining();
            return self.makeRange(lhs, rhs, true);
        }
        return lhs;
    }

    /// Helper for parseRange. Lifts lhs/rhs into arena-allocated Expr slots
    /// then constructs the `.range` union payload.
    fn makeRange(self: *Parser, lhs: Expr, rhs: Expr, inclusive: bool) Expr {
        const lb = self.arena.alloc(Expr, 1);
        lb[0] = lhs;
        const rb = self.arena.alloc(Expr, 1);
        rb[0] = rhs;
        return .{ .range = .{ .start = &lb[0], .end = &rb[0], .inclusive = inclusive } };
    }

    /// Explicit guard for `a..b..c` / `a...b..c` / etc. After consuming
    /// one range op, any SECOND range/ellipsis op directly following is
    /// a syntax error per the manual's None-associativity rule. Emits a
    /// diagnostic with the offending token's location.
    fn rejectRangeChaining(self: *Parser) void {
        const peek_tok = self.peek();
        switch (peek_tok.tag) {
            .range, .ellipsis => {
                std.debug.print("error:{d}:{d}: range operator cannot chain; use '&&' or parentheses\n", .{ peek_tok.loc.line, peek_tok.loc.col });
                std.process.exit(1);
            },
            else => {},
        }
    }

    /// Logical-OR layer: chains `||` while the next token is one. Codegen
    /// emits zig's `or` keyword (zig uses words for the logical operators,
    /// unlike the bitwise `|` operator which is its own symbol).
    fn parseLogicalOr(self: *Parser) Expr {
        var lhs = self.parseLogicalAnd();
        while (self.peek().tag == .pipe_pipe) {
            self.advance();
            const rhs = self.parseLogicalAnd();
            lhs = self.makeBinary(.lor, lhs, rhs);
        }
        return lhs;
    }

    /// Logical-AND layer: chains `&&` while the next token is one. Zig
    /// emits `and` for `&&` to distinguish from bitwise `&`.
    fn parseLogicalAnd(self: *Parser) Expr {
        var lhs = self.parseComparison();
        while (self.peek().tag == .amp_amp) {
            self.advance();
            const rhs = self.parseComparison();
            lhs = self.makeBinary(.land, lhs, rhs);
        }
        return lhs;
    }

    /// Comparison layer: `==`, `!=`, `<`, `>`, `<=`, `>=`. Per the manual
    /// these have None associativity — `a < b < c` is a syntax error. So
    /// this layer consumes AT MOST ONE comparison op and explicitly
    /// rejects a second one with a helpful diagnostic if the user wrote
    /// the chained form. A common idiomatic pattern in zig/zag is
    /// `a < b && c < d` instead of chaining comparisons.
    fn parseComparison(self: *Parser) Expr {
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

    /// Bitwise-OR layer: chains `|`.
    fn parseBitOr(self: *Parser) Expr {
        var lhs = self.parseBitXor();
        while (self.peek().tag == .pipe) {
            self.advance();
            const rhs = self.parseBitXor();
            lhs = self.makeBinary(.bitor, lhs, rhs);
        }
        return lhs;
    }

    /// Bitwise-XOR layer: chains `^`.
    fn parseBitXor(self: *Parser) Expr {
        var lhs = self.parseBitAnd();
        while (self.peek().tag == .caret) {
            self.advance();
            const rhs = self.parseBitAnd();
            lhs = self.makeBinary(.bitxor, lhs, rhs);
        }
        return lhs;
    }

    /// Bitwise-AND layer: chains `&`. Reserve `&&` for the higher layer
    /// (`amp_amp`) so the parser cleanly distinguishes them at the
    /// lexer/`TokenTag` level.
    fn parseBitAnd(self: *Parser) Expr {
        var lhs = self.parseShift();
        while (self.peek().tag == .amp) {
            self.advance();
            const rhs = self.parseShift();
            lhs = self.makeBinary(.bitand, lhs, rhs);
        }
        return lhs;
    }

    /// Shift layer: chains `<<` and `>>`.
    fn parseShift(self: *Parser) Expr {
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

    /// Unary prefix layer: `-x`, `!x`, `~x`, `*x` (deref). All four are
    /// prefix operators binding tighter than any binary op, so this layer
    /// sits at the top of the precedence ladder. Recursive on the operand
    /// so `--x` parses as `-(-x)` and `!!flag` as `!(!flag)`. After the
    /// unary refactor moved deref `*x` here from parsePrimary, the four
    /// operators emit `Expr.unary { op, operand }` consistently with the
    /// existing NewExpr/DerefExpr pointer convention.
    fn parseUnary(self: *Parser) Expr {
        const op: ast.Expr.UnaryOp = switch (self.peek().tag) {
            .minus => .neg,
            .tilde => .bnot,
            .bang => .lnot,
            .star => .deref,
            else => return self.parseCast(),
        };
        self.advance();
        const operand = self.parseUnary();
        const buf = self.arena.alloc(Expr, 1);
        buf[0] = operand;
        return .{ .unary = .{ .op = op, .operand = &buf[0] } };
    }

    /// Postfix layer: chains `[i]` indexing onto a primary expression so
    /// `arr[i][j]` parses as Index(Index(arr, i), j). The recursive walk
    /// stops at the first non-bracket token and returns the LHS up the
    /// precedence ladder to whichever binary op is next. Note: this is
    /// NOT for chained-function-calls (`f(1)(2)`) — that would require a
    /// `.lparen` arm here too, but the user-chosen shape is "chained
    /// single-Index per bracket pair" only.
    /// `expr as Type` postfix cast. Sits between unary and postfix in the
    /// ladder so `1 + x as i32` parses as `1 + (x as i32)`. The destination
    /// type can be a multi-token form (`*raw c_void`, `*const T`, `?*i32`,
    /// …) so `collectCastType` walks tokens of the source verbatim until a
    /// structural delimiter. Captured text round-trips into zig 0.16's `as`
    /// operator without further translation.
    fn parseCast(self: *Parser) Expr {
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
        return .{ .cast = .{ .expr = &buf[0], .type_text = type_text } };
    }

    /// Capture the verbatim `type_text` after a zag `as` keyword. Walks
    /// tokens without consuming the structural delimiter (newline, comma,
    /// closing bracket, binary operator, etc.) and joins `*` + identifiers
    /// with single-space separators except that `*` concatenates directly
    /// to the next identifier (so `*raw c_void` round-trips to zig as
    /// `*raw c_void` — the parenthesised type modifier form zig expects for
    /// raw pointer types). Bounded to 256 bytes; deeper type expressions
    /// fail loudly at the slice-bounds check.
    fn collectCastType(self: *Parser) []const u8 {
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
        while (!self.eof()) {
            const tok = self.peek();
            const is_term: bool = switch (tok.tag) {
                .newline, .comma, .rparen, .rbracket, .rbrace, .colon, .equals, .plus_eq, .minus_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq, .plus, .minus, .slash, .percent, .amp, .pipe, .caret, .tilde, .bang, .lt_lt, .gt_gt, .lt, .gt, .lt_eq, .gt_eq, .eq_eq, .bang_eq, .amp_amp, .pipe_pipe, .range, .ellipsis, .arrow, .doc_comment, .eof => true,
                else => false,
            };
            if (is_term) break;
            // Treat `.star` as the pointer marker (concatenated, no space)
            // and identifiers as the type name proper.
            if (tok.tag == .identifier or tok.tag == .print) {
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

    fn parsePostfix(self: *Parser) Expr {
        var lhs = self.parsePrimary();
        while (self.peek().tag == .lbracket) {
            self.advance(); // consume [
            const idx = self.parseExpr();
            self.expect(.rbracket);
            const target_buf = self.arena.alloc(Expr, 1);
            target_buf[0] = lhs;
            const idx_buf = self.arena.alloc(Expr, 1);
            idx_buf[0] = idx;
            lhs = .{ .index = .{ .target = &target_buf[0], .index = &idx_buf[0] } };
        }
        return lhs;
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
                // Note: `*x` (deref) is NOT routed here. After the unary
                // refactor, parseUnary handles all four prefix operators
                // (`-x`, `~x`, `!x`, `*x` deref) at one level above
                // parsePrimary. parsePrimary is invoked by parsePostfix,
                // which is invoked by parseUnary. Tokens that reach this
                // arm with `.star` are unreachable in practice; we still
                // emit a structural deref node to keep the AST complete
                // and silence the exhaustive switcher.
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
        // Custom-allocator sugar form: `new(<allocator>, T(value))`. The
        // leading `(` distinguishes it from the simple `new T(value)`
        // shape; the allocator ident + comma is the discriminator. Codegen
        // emits `<allocator>.create(T)` rather than the global
        // `page_allocator.create(T)` so the operand uses the user-supplied
        // allocator (typical: `<arena>` from `Arena.new()`).
        if (self.peek().tag == .lparen) {
            self.advance();
            const allocator = self.expectIdent();
            self.expect(.comma);
            const type_name = self.expectIdent();
            self.expect(.lparen);
            const value = self.parseExpr();
            self.expect(.rparen);
            self.expect(.rparen);
            const v = self.arena.alloc(Expr, 1);
            v[0] = value;
            return .{ .new_expr = .{
                .type_name = type_name,
                .value = &v[0],
                .allocator = allocator,
            } };
        }
        // Simple form: `new T(value)` — global allocator (zig's
        // `std.heap.page_allocator`) is used at codegen.
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
                    const expr_text = raw[expr_start .. spec_start - 1];
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

    /// True iff `expr` is a literal Expr kind whose type is determined by
    /// the source shape alone (no inference required). Used by parseBinding
    /// to decide whether a bare `let/var/const NAME = EXPR;` is allowed
    /// without a `: T` annotation — every kind here carries its type
    /// directly in the source:
    ///   int_lit/float_lit         — numeric literal shape → numeric type
    ///   bool_lit                  — true/false → bool
    ///   char_lit                  — 'x' → u8
    ///   string_lit/byte_string_lit — "..."/b"..." → []const u8
    ///   null_lit/undefined_lit    — zig builtins
    ///   tuple_lit                 — (a, b) → anonymous struct (zig-inferred)
    ///   array_lit                 — `[N]T { … }` → `[N]T` (T in source)
    ///   template_lit              — "…{name}…" → debug-printable slice
    ///   new_expr                  — `new T(v)` always produces `*T`; the
    ///                                 type is read from `T` directly in
    ///                                 the source form (memory-feature
    ///                                 carve-out, see `docs/19-memory.md`).
    /// Any other Expr kind (binary, ident, call, index, range, …) requires
    /// an explicit `: T` annotation. This keeps the language statically
    /// typed: every binding has a known type at compile time, even when
    /// the user doesn't write `: T` explicitly.
    fn isLiteralInit(expr: Expr) bool {
        return switch (expr) {
            .int_lit, .float_lit, .bool_lit, .char_lit, .string_lit, .byte_string_lit, .null_lit, .undefined_lit, .tuple_lit, .array_lit, .template_lit, .new_expr => true,
            else => false,
        };
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
