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
            // literals + tuple / array / template literals) -- each carries
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
            // Compile-time type-parameter evaluation block (docs/manual/16
            // §6 "Compile-Time Type Parameters"): `const NAME: T = const {
            // ... return EXPR; }`. Detected BEFORE the ordinary `=`
            // expression path because the inner `{ … }` would either
            // reach parseExpr as a struct-literal initializer (rejected
            // because `const` is a reserved keyword in primary position)
            // OR silently produce a `expected '=' after type annotation,
            // got 'const'` parse error. Only valid on `.const_binding`;
            // `let x = const { … }` and `var x = const { … }` fall
            // through to the standard path and surface the same parse
            // error so the rejection is uniform.
            if (kind == .const_binding and
                self.peek().tag == .equals and
                self.peekAhead(1) == .const_kw)
            {
                self.expect(.equals);
                self.advance(); // consume `const_kw`
                const block_body = self.parseBlock();
                if (block_body.len == 0 or block_body[block_body.len - 1].payload != .return_stmt) {
                    std.debug.print("error:{d}:{d}: const block for '{s}' must end with `return EXPR;`\n", .{
                        binding_loc.line,
                        binding_loc.col,
                        pattern.name,
                    });
                    std.process.exit(1);
                }
                // Reject bare `return;` (no value) -- the block's value
                // is the binding's RHS and zig's `break :blk ;` rejects
                // value-less breaks. The parse-by-parse ReturnStmt parser
                // accepts `return;` (value=null) for void-returning fns,
                // but const-blocks always need a value.
                if (block_body[block_body.len - 1].payload.return_stmt.value == null) {
                    std.debug.print("error:{d}:{d}: const block for '{s}' `return` must carry a value (const blocks always evaluate to a value)\n", .{
                        binding_loc.line,
                        binding_loc.col,
                        pattern.name,
                    });
                    std.process.exit(1);
                }
                // `init` stays null for const-block bindings -- the
                // const-block path carries no value-level initializer
                // because the body's tail `return EXPR;` becomes the
                // binding's RHS at codegen time. Codegen gates on
                // `b.block != null` first and never reads `b.init`
                // for the const-block path (the null sentinel is the
                // semantic representation of "this binding has no
                // Expr init").
                const result: Stmt.BindingStmt = .{
                    .name = pattern.name,
                    .type_name = type_name,
                    .init = null,
                    .block = block_body,
                };
                // Parser invariant documented in src/ast/stmt.zig
                // BindingStmt doc comment (init=null iff block!=null).
                // Codegen enforces it via the diagnostic + exit in
                // src/codegen/stmt.zig:genBinding (destructuring + simple
                // path arms), so we trust the helper's caller-control
                // here rather than duplicating the check at parse time.
                return result;
            }
            self.expect(.equals);
            const initializer = self.parseExpr();
            // Track closure-typed bindings so subsequent `.call` RHS
            // can resolve the callee's type via isClosureBound without
            // an explicit `: T` annotation. Mirrors codegen's
            // `collectTypedBindings` (src/codegen/stmt.zig) which
            // seeds `is_closure = true` for closure init literals.
            if (initializer.payload == .closure) {
                if (self.closure_binding_count < self.closure_bindings.len) {
                    self.closure_bindings[self.closure_binding_count] = pattern.name;
                    self.closure_binding_count += 1;
                }
            }
            if (type_name == null and !isLiteralInit(self, initializer)) {
                std.debug.print("error:{d}:{d}: {s} requires an explicit type annotation when binding non-tuple values (e.g. {s} {s}: T = …)\n", .{
                    binding_loc.line,
                    binding_loc.col,
                    kind_name,
                    kind_name,
                    pattern.name,
                });
                std.process.exit(1);
            }
            const result: Stmt.BindingStmt = .{ .name = pattern.name, .type_name = type_name, .init = initializer };
            // Parser invariant documented in src/ast/stmt.zig
            // BindingStmt doc comment (init=null iff block!=null).
            // Codegen enforces it via the diagnostic + exit in
            // src/codegen/stmt.zig:genBinding, so the helper is not
            // duplicated at parse time.
            return result;
        }
        // Destructuring form: per the parser-level type-annotation rule, a
        // colon after the opening `(` or `[` IS NOT a binding-name annotation
        // (those tokens select the destructuring shape) -- pattern leaves are
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
        const result: Stmt.BindingStmt = .{ .name = "", .type_name = null, .init = initializer, .pattern = pattern };
        // Parser invariant documented in src/ast/stmt.zig
        // BindingStmt doc comment (init=null iff block!=null).
        // Codegen enforces it via the diagnostic + exit in
        // src/codegen/stmt.zig:genBinding, so the helper is not
        // duplicated at parse time.
        return result;
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
                    // `...NAME` rest-binding -- must be the LAST pattern
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
            // the array-with-rest surface beyond what already exists -- both
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
                    // Terminal (no trailing `,`) -- break immediately so the
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
            const tag = self.peek().tag;
            // Skip block-level trivia: newlines (statement separator) and
            // doc_comment tokens (`##` block at the top of a function,
            // captured as a single `doc_comment` token by the lexer's
            // readDocComment). The `##` inside a function body must NOT
            // become a statement — without this skip, parseStmt's expr_stmt
            // fallback would wrap the comment text as an `.ident` Expr and
            // genStmt would emit `    ## Some text.;` to the output zig,
            // which zig's compiler rejects with `expected statement, found
            // '##'`. Top-level `##` (preceding a function decl) is consumed
            // by parseFunDecl's leading-doc-comment capture BEFORE this
            // loop ever runs, so the only path that reaches here with
            // `doc_comment` is an interior comment that's already been
            // detached from any decl — trivia.
            if (tag == .newline or tag == .doc_comment) {
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
        const name_loc = self.peek().loc;
        const name = self.expectIdent();
        // Consume the OP_EQ token -- parseStmt's lookahead verified the
        // specific tag, but `advance` walks past whatever OP_EQ associate
        // matched the originalTokenTag` to the matching TokenTag forms.
        self.advance();
        const rhs = self.parseExpr();
        // Desugar `x OP= rhs` → `x = x OP rhs`. The ident Expr("x") and the
        // `rhs` get lifted into arena-allocated slots via makeBinary so
        // their addresses match the BinaryExpr's pointer convention.
        const bin_expr = self.makeBinary(op, Expr{ .payload = .{ .ident = name }, .loc = name_loc }, rhs);
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
        const target_loc = self.peek().loc;
        const target_name = self.expectIdent();
        var target: Expr = .{ .payload = .{ .ident = target_name }, .loc = target_loc };
        // Dotted-chain target support (`entry.fut.done = true` —
        // surfaced by std.async's EventLoop.poll): consume
        // `. ident` pairs while ANOTHER `.` follows, so the final
        // `.field = value` pair stays unconsumed. The codegen's
        // field_assign emit writes `target.field = value` where the
        // target is a member_access expr — the chain round-trips
        // verbatim.
        while (self.peek().tag == .dot and
            self.peekAhead(1) == .identifier and
            self.peekAhead(2) == .dot)
        {
            self.advance();
            const chain_field = self.expectIdent();
            const boxed = self.arena.alloc(Expr, 1);
            boxed[0] = target;
            target = Expr{ .payload = .{ .member_access = .{ .target = &boxed[0], .name = chain_field } }, .loc = target_loc };
        }
        const target_ptr = self.arena.alloc(Expr, 1);
        target_ptr[0] = target;
        self.expect(.dot);
        const field_name = self.expectIdent();
        self.expect(.equals);
        const value = self.parseExpr();
        return .{ .target = &target_ptr[0], .field_name = field_name, .value = value };
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
        // `if let Pattern = expr { body } else { ... }`
        // Desugar at codegen: match scrutinee { Pattern => body, _ => {} }
        if (self.peek().tag == .let) {
            self.advance(); // consume let
            const pattern = self.parsePattern();
            self.expect(.equals);
            const scrutinee = self.parseExpr();
            self.expect(.lbrace);
            const then_body = self.parseStmtList();
            self.expect(.rbrace);
            var else_kind: Stmt.IfStmt.IfElseKind = .{ .none = {} };
            if (self.peek().tag == .else_kw) {
                self.advance();
                if (self.peek().tag == .if_kw) {
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
            return .{ .cond = scrutinee, .then_body = then_body, .else_kind = else_kind, .is_if_let = true, .if_let_pat = pattern };
        }
        // Suppress struct-literal parsing in if-condition position. The
        // default `allow_struct_lit = true` everywhere; the principled
        // carve-out is the EXACT list of "block-start `{` required" sites
        // (if-cond, while-cond, for-iter, match-scrutinee). `if Foo { ... }`
        // should parse as cond=ident(Foo), body={...} -- NOT as a
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
                // NOT advance past `.if_kw` here -- the nested call below
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


/// `name.field[index] = value;` — index-write through a member-access
/// target (the `self.ptr[self.len] = ch;` shape in lib/std/string.zag).
/// parseIndexAssign's `parsePrimary()` target cannot consume the
/// `.dot` chain, so this builds the member_access Expr explicitly,
/// then consumes the bracket/index/equals/value. Codegen's
/// `.index_assign` arm emits `genExpr(target)[index] = value`
/// verbatim for any Expr target — only the leading `name.field`
/// member-access construction differs from the plain-ident path.
pub fn parseIndexAssignField(self: *Parser) Stmt.IndexAssignStmt {
        const target_loc = self.peek().loc;
        const base_name = self.expectIdent();
        self.expect(.dot);
        const field_name = self.expectIdent();
        self.expect(.lbracket);
        const index = self.parseExpr();
        self.expect(.rbracket);
        self.expect(.equals);
        const value = self.parseExpr();
        const target_buf = self.arena.alloc(Expr, 1);
        const base_buf = self.arena.alloc(Expr, 1);
        base_buf[0] = Expr{ .payload = .{ .ident = base_name }, .loc = target_loc };
        target_buf[0] = Expr{ .payload = .{ .member_access = .{ .target = &base_buf[0], .name = field_name } }, .loc = target_loc };
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
        // Cap matches the size the parser uses for the other list-shaped
        // constructs (stmts_buf in parseBlock/parseStmtList is [256]). The
        // previous [16] was the outlier and overran silently: a match with
        // 17+ arms -- an ordinary thing to write, e.g. one arm per variant
        // of an enum -- indexed past the end of this buffer and aborted the
        // COMPILER with `index out of bounds` and no diagnostic. The guard
        // below turns any future overrun into a real parse error.
        var arms_buf: [256]ast.MatchArm = undefined;
        var arm_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            const tag = self.peek().tag;
            // Mirror parseBlock/parseStmtList's trivia-skip: a `##`
            // doc_comment token between match arms is interior trivia,
            // not an arm pattern. Without this skip, parsePattern would
            // reject the `##` text with `expected match-arm pattern
            // (literal, range, ident, or '_'), got '##'` and the user's
            // match would fail to parse. See parseBlock's doc.
            if (tag == .newline or tag == .doc_comment) {
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
            // is optional -- if rbrace is the immediate next token after the
            // rbrace of the body, we accept it without error.
            if (self.peek().tag == .comma) self.advance();
            if (arm_count >= arms_buf.len) {
                const over = self.peek();
                std.debug.print("error:{d}:{d}: too many match arms (limit {d})\n", .{ over.loc.line, over.loc.col, arms_buf.len });
                std.process.exit(1);
            }
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
        const start_loc = tok.loc;
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
                    const end_loc = self.tokens[self.pos + 2].loc;
                    self.advance(); // start
                    self.advance(); // .. or ...
                    self.advance(); // end
                    const start_buf = self.arena.alloc(Expr, 1);
                    start_buf[0] = Expr{ .payload = .{ .int_lit = start_text }, .loc = start_loc };
                    const end_buf = self.arena.alloc(Expr, 1);
                    end_buf[0] = Expr{ .payload = .{ .int_lit = end_text }, .loc = end_loc };
                    return .{ .range = .{ .start = &start_buf[0], .end = &end_buf[0], .inclusive = inclusive } };
                }
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = Expr{ .payload = .{ .int_lit = tok.text }, .loc = start_loc };
                return .{ .literal = &lit_buf[0] };
            },
            .string_literal => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = Expr{ .payload = .{ .string_lit = tok.text }, .loc = start_loc };
                return .{ .literal = &lit_buf[0] };
            },
            .true_kw => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = Expr{ .payload = .{ .bool_lit = true }, .loc = start_loc };
                return .{ .literal = &lit_buf[0] };
            },
            .false_kw => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = Expr{ .payload = .{ .bool_lit = false }, .loc = start_loc };
                return .{ .literal = &lit_buf[0] };
            },
            .char_literal => {
                self.advance();
                const lit_buf = self.arena.alloc(Expr, 1);
                lit_buf[0] = Expr{ .payload = .{ .char_lit = tok.text }, .loc = start_loc };
                return .{ .literal = &lit_buf[0] };
            },
            .identifier => {
                // Enum-variant pattern detection (docs/manual/13). When the
                // leading identifier is PascalCase (Rust/Zig convention for
                // type + variant names), the three shapes are:
                //   1. `Enum.Variant(args...)` -- qualified; emits
                //      enum_name="Enum", variant_name="Variant", bindings set.
                //   2. `Variant(args...)` -- unqualified, type-inferred per
                //      docs/13; emits enum_name="", variant_name="Variant",
                //      bindings set.
                //   3. `Variant` (bare, followed by `=>`, `if guard`,
                //      `,`, `}`, newline, or eof) -- bare variant pattern
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
                    // Unqualified shape: peek 0 = .lparen -- type-inferred binding.
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
                    // Unqualified brace-named-field shape: peek 0 =
                    // .lbrace -- `Variant { name1: b1, name2: b2, ... }`
                    // (gap #6, docs/manual/14-unions §"Definition"). The
                    // field-name walker mirrors `parseStructDecl`'s named-
                    // field shape (declared on `src/parser/primary.zig`)
                    // but routes binds through `parsePatternField` instead
                    // of `parseFieldAssign` because pattern-side bindings
                    // accept `_` discards via `parsePatternBinding`
                    // returning `null`. `bindings` carried by the AST
                    // shape `EnumVariantNamedPattern.fields` (sibling to
                    // the legacy `EnumVariantPattern.bindings`) — codegen
                    // consumes this slot to emit the binding preamble
                    // inside the arm block (`const w = __m.x; ...`). The
                    // `token.tag` lookahead is captured BEFORE the
                    // consume so `(.dot .identifier .identifier)` style
                    // scoped paths (`Shape.Drag { x: w }` qualified) are
                    // distinguishable from the bare
                    // `Drag { x: w }` unqualified form — covered by the
                    // outer `peek[1]==.dot && peek[2]==identifier` arm
                    // above. This arm fires ONLY when the immediately-
                    // following token is `.lbrace` so the order in which
                    // the three shape-detect arms run (qualified-dot,
                    // unqualified-paren, unqualified-brace) is critical —
                    // putting the brace arm AFTER the paren arm ensures a
                    // source written as `Foo(x)` still matches the paren
                    // shape and isn't misparsed as a single-field brace
                    // form `Foo { x: ... }`.
                    if (self.pos + 1 < self.tokens.len and
                        self.tokens[self.pos + 1].tag == .lbrace)
                    {
                        const variant_name = self.expectIdent();
                        self.expect(.lbrace);
                        var field_buf: [16]ast.VariantFieldPattern = undefined;
                        var field_count: usize = 0;
                        if (self.peek().tag != .rbrace) {
                            field_buf[field_count] = self.parsePatternField();
                            field_count += 1;
                            while (self.peek().tag == .comma) {
                                self.advance();
                                field_buf[field_count] = self.parsePatternField();
                                field_count += 1;
                            }
                        }
                        self.expect(.rbrace);
                        const fields_arena = self.arena.alloc(ast.VariantFieldPattern, field_count);
                        @memcpy(fields_arena, field_buf[0..field_count]);
                        return .{ .enum_variant_named = .{
                            .enum_name = "",
                            .variant_name = variant_name,
                            .fields = fields_arena,
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


pub fn parsePatternField(self: *Parser) ast.VariantFieldPattern {
        // Brace-named-field match pattern walker (gap #6,
        // docs/manual/14-unions §"Definition" + docs/manual/13-enums
        // §"Choosing Between enum and union"). Mirrors the per-field
        // walker inside `parseStructDecl` (src/parser/primary.zig) but
        // routes through `parsePatternBinding` (returns `null` for `_`
        // discard, otherwise ident) so the captured bindings may skip
        // any single slot via wildcard. The `name` prefix MUST be an
        // identifier (no `_` — the field name is sourced from the
        // variant-decl side, not the binding side); rejects any other
        // leading token with a parse error so the user gets a clear
        // diagnostic instead of a silent mismatch with zig's
        // (later) anonymous-struct field-name resolver. Returns
        // `null` capture when the binding is a wildcard (so codegen
        // can avoid emitting a useless `const _ = __m.x` preamble).
        const name = self.expectIdent();
        self.expect(.colon);
        const capture = self.parsePatternBinding();
        return .{ .name = name, .capture = capture };
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
            // not see the union tag -- it just parses the common shape and
            // returns a BindingStmt; the structural duplication that
            // motivated the refactor lives here at exactly three lines.
            .let => return Stmt{ .payload = .{ .let = self.parseBinding(.let) }, .loc = tok.loc },
            .var_kw => return Stmt{ .payload = .{ .var_binding = self.parseBinding(.var_binding) }, .loc = tok.loc },
            .const_kw => return Stmt{ .payload = .{ .const_binding = self.parseBinding(.const_binding) }, .loc = tok.loc },
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
                        return Stmt{ .payload = .{ .assign = self.parseAssign() }, .loc = tok.loc };
                    }
                    if (compoundOpForTag(next)) |op| {
                        return Stmt{ .payload = .{ .assign = self.parseCompoundAssign(op) }, .loc = tok.loc };
                    }
                    if (next == .lbracket) {
                        return Stmt{ .payload = .{ .index_assign = self.parseIndexAssign() }, .loc = tok.loc };
                    }
                    // 3-token lookahead for `name . ident =` field-write.
                    // Pattern: ident (current) . dot (next) . ident (n+2) . equals (n+3).
                    // Only the canonical `bare-name . bare-name = value` form
                    // is supported via this lookahead -- for more complex LHSs
                    // like `(getBox()).x = …` or `arr[i].x = …`, the user can
                    // extract the value to a local first then field-assign.
                    //
                    // Dotted CHAIN targets (`entry.fut.done = true` —
                    // std.async EventLoop.poll): scan forward over
                    // `. ident` pairs; when an `.equals` follows the
                    // final ident of the run, route to parseFieldAssign
                    // (which consumes the whole chain). Without the
                    // scan the 3-token check misses chains and the
                    // statement falls to expr_stmt, emitting garbage.
                    if (next == .dot and
                        self.pos + 2 < self.tokens.len and
                        self.tokens[self.pos + 2].tag == .identifier)
                    {
                        var scan: usize = 1;
                        var chain_field_assign = false;
                        while (self.pos + scan + 2 < self.tokens.len and
                            self.tokens[self.pos + scan].tag == .dot and
                            self.tokens[self.pos + scan + 1].tag == .identifier)
                        {
                            const after = self.tokens[self.pos + scan + 2].tag;
                            if (after == .equals) {
                                chain_field_assign = true;
                                break;
                            }
                            if (after != .dot) break;
                            scan += 2;
                        }
                        if (chain_field_assign) {
                            return Stmt{ .payload = .{ .field_assign = self.parseFieldAssign() }, .loc = tok.loc };
                        }
                    }
                    // Postfix deref-write `name.* = value` (the zig-shaped
                    // spelling of the prefix `*name = value` form below).
                    // Both lower to the SAME `.deref_assign` AST slot, so
                    // codegen and escape analysis need no change — this
                    // arm just accepts the postfix spelling users reach
                    // for (zig's own deref-write is postfix-only).
                    // Pattern: ident (current) . dot . star . equals.
                    if (next == .dot and
                        self.pos + 2 < self.tokens.len and
                        self.tokens[self.pos + 2].tag == .star and
                        self.pos + 3 < self.tokens.len and
                        self.tokens[self.pos + 3].tag == .equals)
                    {
                        const name = self.expectIdent();
                        self.expect(.dot);
                        self.expect(.star);
                        self.expect(.equals);
                        const value = self.parseExpr();
                        return Stmt{ .payload = .{ .deref_assign = .{ .name = name, .value = value } }, .loc = tok.loc };
                    }
                    // 4-token lookahead for `name . ident [ expr ] =` — the
                    // field-index-write form used by lib/std/string.zag's
                    // field-index-write form used by lib/std/string.zag's
                    // push_ch / insert_ch (`self.ptr[self.len] = ch;`). The
                    // target is a member_access (`self.ptr`) so it cannot
                    // ride the plain `.index_assign` path (which expects
                    // the `.lbracket` immediately after the leading ident);
                    // this arm routes to parseIndexAssignField which builds
                    // the member_access target then consumes the bracket +
                    // index + equals + value. Codegen's `.index_assign` arm
                    // emits any Expr target verbatim, so no codegen change.
                    if (next == .dot and
                        self.pos + 2 < self.tokens.len and
                        self.tokens[self.pos + 2].tag == .identifier and
                        self.pos + 3 < self.tokens.len and
                        self.tokens[self.pos + 3].tag == .lbracket)
                    {
                        return Stmt{ .payload = .{ .index_assign = self.parseIndexAssignField() }, .loc = tok.loc };
                    }
                }
                return Stmt{ .payload = .{ .expr_stmt = self.parseExpr() }, .loc = tok.loc };
            },
            .defer_kw => return Stmt{ .payload = .{ .defer_stmt = self.parseDefer() }, .loc = tok.loc },
            .errdefer_kw => return Stmt{ .payload = .{ .errdefer_stmt = self.parseErrDefer() }, .loc = tok.loc },
            .unsafe_kw => return Stmt{ .payload = .{ .unsafe_block = self.parseUnsafeBlock() }, .loc = tok.loc },
            .if_kw => return Stmt{ .payload = .{ .if_stmt = self.parseIfBranch() }, .loc = tok.loc },
            .while_kw => return Stmt{ .payload = .{ .while_stmt = self.parseWhileStmt() }, .loc = tok.loc },
            .for_kw => return Stmt{ .payload = .{ .for_stmt = self.parseForStmt() }, .loc = tok.loc },
            .match_kw => return Stmt{ .payload = .{ .match_stmt = self.parseMatchExpr() }, .loc = tok.loc },
            .break_kw => {
                self.advance();
                return Stmt{ .payload = .{ .break_stmt = {} }, .loc = tok.loc };
            },
            .continue_kw => {
                self.advance();
                return Stmt{ .payload = .{ .continue_stmt = {} }, .loc = tok.loc };
            },
            .return_kw => return Stmt{ .payload = .{ .return_stmt = self.parseReturnStmt() }, .loc = tok.loc },
            .star => {
                // `*p = value;` dereference-write (zag's mirror of zig
                // 0.16's `p.* = value;` postfix-deref-write form). 3-token
                // lookahead disambiguates "deref-write" from "bare deref-
                // as-expression" by inspecting the immediate successor
                // tokens for the `identifier, equals` triplet. If the
                // triple is present we consume all 3 tokens and emit a
                // `DerefAssignStmt`: after consuming `.star`, the inner
                // `expectIdent` captures the bare pointer name (no
                // descriptive deref-tree support yet — users needing
                // `*obj.field = x` should extract a local first), then
                // `expect(.equals)` consumes the assignment operator,
                // then `parseExpr` captures the RHS expr. If the triple
                // is NOT present (e.g. `*p;` no-op deref-stmt or
                // `*p.method(args)` whose next tokens break the
                // identifier-then-equals sequence), we fall through to
                // the `else => expr_stmt` arm so the existing unary-
                // deref expr_stmt surface keeps working. Mirrors the
                // 4-token `name . ident =` lookahead for `.field_assign`
                // above (which sits at the `.identifier` arm) — the
                // difference here is starting-token `.star` plus the
                // shorter (3-token) lookahead because no `.field` is
                // possible in the deref-write form (we only support
                // bare-ident LHS for deref-write; richer trees are
                // future work per the `DerefAssignStmt` doc comment in
                // src/ast/stmt.zig).
                if (self.pos + 2 < self.tokens.len and
                    self.tokens[self.pos + 1].tag == .identifier and
                    self.tokens[self.pos + 2].tag == .equals)
                {
                    self.advance(); // consume `.star`
                    const name = self.expectIdent();
                    self.expect(.equals);
                    const value = self.parseExpr();
                    return Stmt{ .payload = .{ .deref_assign = .{ .name = name, .value = value } }, .loc = tok.loc };
                }
                return Stmt{ .payload = .{ .expr_stmt = self.parseExpr() }, .loc = tok.loc };
            },
            else => return Stmt{ .payload = .{ .expr_stmt = self.parseExpr() }, .loc = tok.loc },
        }
    }


pub fn parseStmtList(self: *Parser) []const Stmt {
        var stmts_buf: [256]Stmt = undefined;
        var stmt_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            const tag = self.peek().tag;
            // Mirror parseBlock's trivia-skip: newlines separate stmts,
            // doc_comment tokens are interior `##` blocks the lexer
            // captured as a single token. Without this skip, the
            // `## ...` text becomes a `## ... .ident` expr_stmt and the
            // codegen emits `    ## ... .;` into the output zig, which
            // zig rejects with `expected statement, found '##'`. See
            // parseBlock's doc for the full rationale.
            if (tag == .newline or tag == .doc_comment) {
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
        // `while let Pattern = expr { body }`
        if (self.peek().tag == .let) {
            self.advance();
            const pattern = self.parsePattern();
            self.expect(.equals);
            const scrutinee = blk: {
                const prev = self.allow_struct_lit;
                defer self.allow_struct_lit = prev;
                self.allow_struct_lit = false;
                break :blk self.parseExpr();
            };
            const body = self.parseBlock();
            return .{ .cond = scrutinee, .body = body, .is_while_let = true, .while_let_pat = pattern };
        }
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

