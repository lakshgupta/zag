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
    /// Parse-context flag for struct-literal disambiguation in
    /// `parsePrimary`. True (default) in every expression position
    /// EXCEPT those where `{` MUST mean block-start: if-condition,
    /// while-condition, for-iter, match-scrutinee. In those positions
    /// the call site temporarily sets the flag to false (via a scoped
    /// save/false/`defer`-restore pattern around the single parseExpr
    /// call) so `if Foo { ... }` and `match Foo { ... }` parse as
    /// `<cond>` + `{ <body> }` rather than swallowing the block as a
    /// struct-literal.
    ///
    /// Why default-true (vs the earlier default-false): the user's
    /// contract explicitly says struct-literal parsing should fire in
    /// binding-init positions, return-value positions, field-assign
    /// positions, AND any other expression-yielding position. The
    /// principled carve-out is therefore the EXACT list of positions
    /// where `{` must be block-start, NOT a whitelist of positions
    /// where struct-literal is allowed. Implementing it via "suppress
    /// at the boundaries" rather than "opt-in everywhere else" keeps
    /// the precedence ladder untouched (no flag threading through
    /// parseExpr → parsePrimary) and avoids the regression where
    /// expressions like `return Vec3 { ... }` or
    /// `print(Vec3 { ... })` — common idioms in the user's example
    /// code — silently stop parsing as struct-literals.
    ///
    /// Two-gate disambiguation in parsePrimary: (a) this flag must be
    /// true AND (b) the leading identifier must start with an
    /// uppercase letter. The uppercase sub-clause is defense-in-depth
    /// (Rust/Zig-style PascalCase-types convention) so an accidental
    /// flag flip doesn't allow lower-case locals like `vec { ... }`
    /// to silently swallow blocks.
    allow_struct_lit: bool,

    pub fn init(tokens: []const Token, arena: *ast.Arena) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
            .allow_struct_lit = true,
        };
    }

    pub fn parse(self: *Parser) ast.Program {
        var functions_buf: [256]ast.FunDecl = undefined;
        var fun_count: usize = 0;
        var structs_buf: [256]ast.StructDecl = undefined;
        var struct_count: usize = 0;
        var impls_buf: [256]ast.ImplBlock = undefined;
        var impl_count: usize = 0;
        var enums_buf: [256]ast.EnumDecl = undefined;
        var enum_count: usize = 0;

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
            // Top-level dispatch: structs and impl blocks live alongside
            // top-level functions. The dispatch is order-independent at
            // codegen time (codegen re-walks and interleaves struct fields
            // with their matching impl-method-NESTED-inside emission), so
            // the parser simply records each decl in its appropriate slice
            // and preserves source order across all three.
            const lead = self.peek().tag;
            if (lead == .struct_kw) {
                // Struct decls at module-scope don't carry a doc slot
                // (`StructDecl` has no `doc` field) — discarding the
                // captured doc keeps the top-of-loop accumulator clean
                // without forcing every decl-kind to accept it.
                structs_buf[struct_count] = self.parseStructDecl();
                struct_count += 1;
                continue;
            }
            if (lead == .impl_kw) {
                // Same rationale as the struct-decl branch — impl blocks
                // don't carry doc at module scope.
                impls_buf[impl_count] = self.parseImplBlock();
                impl_count += 1;
                continue;
            }
            if (lead == .enum_kw) {
                // Top-level enum decl — recorded into `enums` so codegen
                // emits `pub const NAME = enum { ... };` and consumers
                // (functions, impls, other top-level decls) reference
                // the name naturally.
                enums_buf[enum_count] = self.parseEnumDecl();
                enum_count += 1;
                continue;
            }
            functions_buf[fun_count] = self.parseFunDecl();
            functions_buf[fun_count].doc = doc;
            fun_count += 1;
        }

        const functions = self.arena.alloc(ast.FunDecl, fun_count);
        @memcpy(functions, functions_buf[0..fun_count]);
        const structs = self.arena.alloc(ast.StructDecl, struct_count);
        @memcpy(structs, structs_buf[0..struct_count]);
        const impls = self.arena.alloc(ast.ImplBlock, impl_count);
        @memcpy(impls, impls_buf[0..impl_count]);
        const enums = self.arena.alloc(ast.EnumDecl, enum_count);
        @memcpy(enums, enums_buf[0..enum_count]);
        return .{ .functions = functions, .structs = structs, .impls = impls, .enums = enums };
    }

    /// Parse `struct NAME { field-decl, ... }`. Two field shapes inside the
    /// body:
    /// - **Named**: `name: T,` — captured verbatim with the
    ///   colon-stripped type text so multi-token types like `*const Foo`
    ///   round-trip cleanly through codegen's struct-field emission.
    /// - **Embed**: `TypeName,` (or `TypeName { … }` per the docs/12
    ///   example) — promotes the embedded type's fields + methods into the
    ///   outer struct. Codegen handles the field-promotion by emitting an
    ///   embedded anonymous-struct field whose dotted-field access works
    ///   straight through zig's `.field` resolution.
    ///
    /// Each field's `idx` records its position in the declaration order
    /// so codegen can preserve order at the zig emission site (the
    /// fields slice is otherwise order-preserving but the explicit `idx`
    /// makes walker logic that needs to look up "this field-init's
    /// declaration index" trivial to write).
    fn parseStructDecl(self: *Parser) ast.StructDecl {
        const start_loc = self.peek().loc;
        self.expect(.struct_kw);
        const name = self.expectIdent();
        self.expect(.lbrace);
        var fields_buf: [64]ast.StructField = undefined;
        var field_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            // Pre-existing token is either an identifier (named or embed)
            // OR a comma (skip as a separator between fields).
            if (self.peek().tag == .comma) {
                self.advance();
                continue;
            }
            const field_name = self.expectIdent();
            if (self.peek().tag == .colon) {
                // Named field: `name: T`. Capture the type text via the
                // same multi-token collector used by `as` casts so types
                // like `*const T` and `[]T` round-trip cleanly. The
                // collector arena-allocates its result, so the slice is
                // stable after parseStructDecl returns.
                self.advance();
                const type_text = self.collectCastType();
                if (type_text.len == 0) {
                    std.debug.print("error:{d}:{d}: named struct field '{s}' requires a type after ':'\n", .{ start_loc.line, start_loc.col, field_name });
                    std.process.exit(1);
                }
                fields_buf[field_count] = .{
                    .idx = @intCast(field_count),
                    .kind = .{ .named = .{ .name = field_name, .type_text = type_text } },
                };
                field_count += 1;
            } else {
                // Embed-form: bare `TypeName,` (no colon). Docs/12 covers
                // `Widget,` inside `struct Button { Widget, label: String }`.
                fields_buf[field_count] = .{
                    .idx = @intCast(field_count),
                    .kind = .{ .embed = .{ .type_name = field_name } },
                };
                field_count += 1;
            }
        }
        self.expect(.rbrace);
        const fields_src = fields_buf[0..field_count];
        const fields = self.arena.dupe(ast.StructField, fields_src);
        return .{ .name = name, .fields = fields, .loc = start_loc };
    }

    /// Parse `impl TYPE { method-decl, ... }`. Each method-decl is
    /// `pub? fun NAME(params?) -> RET_TYPE? { body }`. The leading `pub`
    /// keyword is accepted-and-ignored; codegen emits every body as a
    /// `pub fn` regardless, matching the user-confirmed scope (privacy
    /// enforcement is deferred to a followup commit).
    ///
    /// Method bodies share the same `[]const Stmt` slice shape as
    /// top-level `fun` declarations, so codegen reuses the body-emission
    /// path (`genFunDecl` → `genStmt` loop). The receiver (`self`) is
    /// modelled as the first `MethodParam` with `is_self = true` and a
    /// type like `*const Vec3` — see `parseMethod` for the discriminator.
    fn parseImplBlock(self: *Parser) ast.ImplBlock {
        const start_loc = self.peek().loc;
        self.expect(.impl_kw);
        const target_type = self.expectIdent();
        self.expect(.lbrace);
        var methods_buf: [64]ast.MethodDecl = undefined;
        var method_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            methods_buf[method_count] = self.parseMethod();
            method_count += 1;
        }
        self.expect(.rbrace);
        const methods = self.arena.alloc(ast.MethodDecl, method_count);
        @memcpy(methods, methods_buf[0..method_count]);
        return .{ .target_type = target_type, .methods = methods, .loc = start_loc };
    }

    /// Parse one `pub? fun NAME(params) -> RET? { body }` method-decl.
    /// Returns the inner payload `ast.MethodDecl` (NOT a `Stmt`) since
    /// impl-block methods don't carry a stmt-union tag.
    ///
    /// Params are parsed comma-separated. Each param is `name: type`.
    /// The discriminator to `is_self = true` is purely the param-name
    /// being `self` — the type_text handles both `*const T` and `*T`
    /// (mutable receiver) forms uniformly, since codegen emits the
    /// type verbatim regardless of pointer-vs-pointer-to-const shape.
    /// Trailing `-> RET_TYPE` is optional; when omitted, codegen defers
    /// to zig's type inference downstream.
    fn parseMethod(self: *Parser) ast.MethodDecl {
        const start_loc = self.peek().loc;
        // Accept-and-ignore `pub` (the keyword exists in the lexer so the
        // grammar reserves it; privacy enforcement is deferred).
        if (self.peek().tag == .pub_kw) self.advance();
        self.expect(.fun);
        const name = self.expectIdent();
        self.expect(.lparen);
        var params_buf: [16]ast.MethodParam = undefined;
        var param_count: usize = 0;
        if (self.peek().tag != .rparen) {
            params_buf[param_count] = self.parseMethodParam();
            param_count += 1;
            while (self.peek().tag == .comma) {
                self.advance();
                params_buf[param_count] = self.parseMethodParam();
                param_count += 1;
            }
        }
        self.expect(.rparen);
        var return_type: ?[]const u8 = null;
        if (self.peek().tag == .arrow) {
            self.advance();
            const rt = self.collectCastType();
            return_type = if (rt.len == 0) null else rt;
        }
        self.expect(.lbrace);
        const body = self.parseStmtList();
        self.expect(.rbrace);
        const params = self.arena.alloc(ast.MethodParam, param_count);
        @memcpy(params, params_buf[0..param_count]);
        return .{ .name = name, .params = params, .return_type = return_type, .body = body, .loc = start_loc };
    }

    /// Parse one comma-separated method parameter: `name: type_text`.
    /// `is_self` is set when the param name is exactly `self`
    /// (the docs/12 receiver convention). The type text is captured
    /// verbatim via `collectCastType` so multi-token types
    /// (`*const Vec3`, `*Vec3`) round-trip cleanly.
    /// Parse one comma-separated param: optional `var` prefix +
    /// `name: type_text` + optional `...` suffix + optional `= default`
    /// tail. Three Phase-2 extensions over the original
    /// `name: type_text` method param shape:
    ///
    /// - `var`: when the leading token is `.var_kw`, flag
    ///   `is_var = true` so codegen emits `var x = x;` at body entry.
    ///   Mutual exclusion with `is_self` is enforced by the parser
    ///   implicitly — `self` parameters are receivers and don't carry
    ///   `var` mutation semantics in the docs/15 contract.
    ///
    /// - `...`: trailing `.ellipsis` immediately after the type token
    ///   flags `is_variadic = true`. codegen currently treats this as
    ///   `T: anytype` (the simplest zig compat; full slice-typed
    ///   variadic + call-site splat is Phase 3+).
    ///
    /// - `= EXPR`: trailing `.equals` followed by a parsed Expr
    ///   produces `default_value`. The Expr is arena-allocated so the
    ///   pointer-cycle-breaking convention (`?*const Expr`) is
    ///   honoured. Same as `is_variadic`, codegen support for the
    ///   optional-arg call-site shim is Phase 3+.
    fn parseMethodParam(self: *Parser) ast.MethodParam {
        var is_var = false;
        if (self.peek().tag == .var_kw) {
            self.advance();
            is_var = true;
        }
        const name = self.expectIdent();
        self.expect(.colon);
        const type_text = self.collectCastType();
        if (type_text.len == 0) {
            std.debug.print("error:{d}:{d}: method parameter '{s}' requires a type after ':'\n", .{ self.peek().loc.line, self.peek().loc.col, name });
            std.process.exit(1);
        }
        var is_variadic = false;
        if (self.peek().tag == .ellipsis) {
            self.advance();
            is_variadic = true;
        }
        var default_value: ?*const ast.Expr = null;
        if (self.peek().tag == .equals) {
            self.advance();
            const dv_buf = self.arena.alloc(ast.Expr, 1);
            dv_buf[0] = self.parseExpr();
            default_value = &dv_buf[0];
        }
        const is_self = std.mem.eql(u8, name, "self");
        return .{
            .name = name,
            .type_text = type_text,
            .is_self = is_self,
            .is_var = is_var,
            .is_variadic = is_variadic,
            .default_value = default_value,
        };
    }

    /// Parse `|params| -> RET? { body }` closure expression
    /// (docs/15 §"Closures"). Body is a stmt list (mirrors
    /// `FunDecl.body`) so the docs-canonical form
    /// `|x: i32| -> i32 { return x * 2; }` parses with `return` in
    /// stmt position. Param parsing reuses `parseMethodParam` —
    /// including the Phase-2 `var`/`...`/`= default` extensions on
    /// MethodParam — so closures accept the same param shape as
    /// top-level funs and impl-block methods.
    fn parseClosureExpr(self: *Parser) Expr {
        self.expect(.pipe);
        var params_buf: [16]ast.MethodParam = undefined;
        var param_count: usize = 0;
        if (self.peek().tag != .pipe) {
            params_buf[param_count] = self.parseMethodParam();
            param_count += 1;
            while (self.peek().tag == .comma) {
                self.advance();
                params_buf[param_count] = self.parseMethodParam();
                param_count += 1;
            }
        }
        self.expect(.pipe);
        var return_type: ?[]const u8 = null;
        if (self.peek().tag == .arrow) {
            self.advance();
            const rt = self.collectCastType();
            return_type = if (rt.len == 0) null else rt;
        }
        const body = self.parseBlock();
        const params = self.arena.alloc(ast.MethodParam, param_count);
        if (param_count > 0) @memcpy(params, params_buf[0..param_count]);
        return .{ .closure = .{
            .params = params,
            .return_type = return_type,
            .body = body,
        } };
    }

    fn parseFunDecl(self: *Parser) ast.FunDecl {
        const start = self.peek().loc;
        self.expect(.fun);
        const name = self.expectIdent();
        self.expect(.lparen);
        // Phase 2 (docs/15 §"Declaration"): parse a comma-separated
        // parameter list inside `(<params>)`. Each param is the same
        // shape as `parseMethodParam` (just without the `self`
        // receiver carve-out — top-level functions don't carry a
        // receiver). The multi-token type collector handles
        // pointer types like `*const T` and bracket prefixes `[]T`
        // so `fun add(a: i32, b: i32)` round-trips. When the param
        // list is empty (the legacy `fun NAME() {}` form), we emit
        // a zero-length slice and codegen uses the legacy
        // `pub fn NAME() RET_TYPE` shape.
        var params_buf: [16]ast.MethodParam = undefined;
        var param_count: usize = 0;
        if (self.peek().tag != .rparen) {
            params_buf[param_count] = self.parseMethodParam();
            param_count += 1;
            while (self.peek().tag == .comma) {
                self.advance();
                params_buf[param_count] = self.parseMethodParam();
                param_count += 1;
            }
        }
        self.expect(.rparen);
        // Optional `-> RET_TYPE` annotation. When absent, codegen
        // defaults to `void` (no return value); zig's type
        // inference takes over for the expression-bodied cases.
        var return_type: ?[]const u8 = null;
        if (self.peek().tag == .arrow) {
            self.advance();
            const rt = self.collectCastType();
            return_type = if (rt.len == 0) null else rt;
        }
        const body = self.parseBlock();
        const params = self.arena.alloc(ast.MethodParam, param_count);
        @memcpy(params, params_buf[0..param_count]);
        return .{
            .name = name,
            .params = params,
            .body = body,
            .loc = start,
            .doc = null,
            .return_type = return_type,
        };
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

    // Parse one of the three binding declarations (`let`, `var`, `const`).
    // All three share this code path — the only divergence is which keyword
    // the source starts with, which we route via the `kind` parameter. The
    // dispatch site in `parseStmt` carries the binding kind to the AST by
    // selecting the matching union tag (`.let` / `.var_binding` /
    // `.const_binding`) and threading the same `kind` value here; the
    // payload `BindingStmt` is structurally identical across all three so
    // zig's tagged union gives us uniform field access (`stmt.let.init`,
    // `stmt.var_binding.name`, `stmt.const_binding.type_name`) without
    // duplicating struct definitions.
    //
    // Adding a future binding kind (`mut`, `implicit`, `ref`, ...) is a
    // three-line change: a new `BindingKind` enum member in `ast.zig`, a
    // matching arm in the `kw` switch below, plus a new dispatch arm in
    // `parseStmt` that calls `parseBinding(<kind>)`.
    //
    // The first token after the keyword disambiguates single-name from
    // destructuring: `(` opens a tuple pattern, `[` opens an array
    // pattern, an identifier is either a name or the wildcard `_`. Either
    // way `parseBindingPattern` returns the shape and we promote `.name`
    // results into the simple-binding code path (.pattern = null) so the
    // existing 83-unit-call-site test suite continues to read
    // `stmt.let.name` / `stmt.let.type_name.?` without modification.
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

    // Parse a destructuring pattern starting at the current token. Recursive
    // for nested forms (`let (a, (b, c)) = …` is a tuple containing a tuple).
    //
    // Returns a `BindingPattern`:
    // - `.name("x")` — single identifier (no destructuring)
    // - `.discard`   — the wildcard `_`
    // - `.tuple([ … ])` — pattern wrapped in `(…)` (tuple destructuring)
    // - `.array([ … ])` — pattern wrapped in `[…]` (array destructuring)
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

    fn parseAssign(self: *Parser) Stmt.AssignStmt {
        const name = self.expectIdent();
        self.expect(.equals);
        const value = self.parseExpr();
        return .{ .name = name, .value = value };
    }

    // Parse a compound assignment `x OP= rhs` and desugar it into a bare
    // `Stmt.AssignStmt` whose value is `binary(op, ident("x"), rhs)`. No
    // new AST node is emitted — the doc frames the compound forms as sugar
    // for `x = x OP rhs`, so the existing AssignStmt shape can carry both.
    // `op` is supplied by `compoundOpForTag` via the parseStmt lookahead.
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

    /// Parse `name.field = expr`. The lookahead at parseStmt's identifier
    /// arm verified the pattern `name . field = `. The receiver is a
    /// bare identifier (NOT a full expr), which keeps the dispatch
    /// trivial. For complex LHSs (`arr[i].field = …`,
    /// `getBox().field = …`), the user can extract to a local first.
    fn parseFieldAssign(self: *Parser) Stmt.FieldAssignStmt {
        const target_name = self.expectIdent();
        const target = self.arena.alloc(Expr, 1);
        target[0] = .{ .ident = target_name };
        self.expect(.dot);
        const field_name = self.expectIdent();
        self.expect(.equals);
        const value = self.parseExpr();
        return .{ .target = &target[0], .field_name = field_name, .value = value };
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

    /// Parse one comma-separated enum-variant payload type: `name: type_text`
    /// for `struct_field` style payloads, OR the inner type-list of an
    /// enum variant (e.g. `Circle(f64, f64)`'s payload). This single helper
    /// covers both via the same `collectCastType` machinery.
    /// (OBSOLETE: kept for compile-time symbol preservation during the
    /// enum refactor; the active parseEnumDecl uses collectCastType
    /// directly for single-type payloads and a comma-loop for the
    /// multi-type form. Will be removed in a followup commit.)
    fn parseEnumVariantPayload(self: *Parser) ?[]const u8 {
        _ = self;
        return null;
    }

    /// Parse `enum NAME { Variant1, Variant2(T) | Circle(f64), Rectangle(f64, f64), ... }`.
    /// Mirrors `parseStructDecl` for the brace-walk loop (newline/comma
    /// tolerant). Variant payloads are captured via `collectCastType`
    /// once or in a comma-separated slice — the joined verbatim text is
    /// stored on `EnumVariant.payload_type` so codegen emits the source
    /// exactly as written, including `*const` / `[]` / `?` shape.
    fn parseEnumDecl(self: *Parser) ast.EnumDecl {
        const start_loc = self.peek().loc;
        self.expect(.enum_kw);
        const name = self.expectIdent();
        self.expect(.lbrace);
        var variants_buf: [64]ast.EnumVariant = undefined;
        var variant_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            if (self.peek().tag == .comma) {
                self.advance();
                continue;
            }
            const variant_loc = self.peek().loc;
            const variant_name = self.expectIdent();
            var payload: ?[]const u8 = null;
            if (self.peek().tag == .lparen) {
                // Multi-arg payload (e.g. `Rect(f64, f64)`): collect one or
                // more comma-separated type-text segments and join them
                // with ", " so codegen emits the source verbatim. Use the
                // existing collectCastType so multi-token pointer types
                // (`*const T`), slice prefixes (`[]T`), and nullable
                // prefixes (`?*T`) round-trip cleanly through codegen.
                self.advance(); // consume (
                var type_texts_buf: [16][]const u8 = undefined;
                var type_count: usize = 0;
                type_texts_buf[type_count] = self.collectCastType();
                type_count += 1;
                while (self.peek().tag == .comma) {
                    self.advance();
                    type_texts_buf[type_count] = self.collectCastType();
                    type_count += 1;
                }
                self.expect(.rparen);
                var joined_buf: [512]u8 = undefined;
                var joined_len: usize = 0;
                // Manual-index `while` instead of `for (slice) |tt, i|` —
                // the latter produced a "extra capture in for loop" error in
                // zig 0.16 for this expression shape (only one such loop in
                // the file; no impact on the other sites which iterate over
                // string-text or arena slices with single captures).
                var i: usize = 0;
                while (i < type_count) : (i += 1) {
                    const tt = type_texts_buf[i];
                    if (i > 0) {
                        if (joined_len + 2 <= joined_buf.len) {
                            joined_buf[joined_len] = ',';
                            joined_buf[joined_len + 1] = ' ';
                            joined_len += 2;
                        }
                    }
                    if (joined_len + tt.len <= joined_buf.len) {
                        @memcpy(joined_buf[joined_len..][0..tt.len], tt);
                        joined_len += tt.len;
                    }
                }
                const payload_arena = self.arena.alloc(u8, joined_len);
                @memcpy(payload_arena, joined_buf[0..joined_len]);
                payload = payload_arena;
            }
            variants_buf[variant_count] = .{
                .name = variant_name,
                .payload_type = payload,
                .loc = variant_loc,
            };
            variant_count += 1;
        }
        self.expect(.rbrace);
        const variants = self.arena.alloc(ast.EnumVariant, variant_count);
        @memcpy(variants, variants_buf[0..variant_count]);
        return .{ .name = name, .variants = variants, .loc = start_loc };
    }

    /// Parse one comma-separated enum-variant pattern binding: either an
    /// identifier (which becomes a binding in the arm body) OR a `_`
    /// wildcard (which suppresses the binding). Returns `null` for the
    /// wildcard case so the pattern's `[]?[]const u8` slot distinguishes
    /// "discard this slot" from "capture this name verbatim". Mirrors the
    /// `parseBindingPattern` distinction between `.name` and `.discard`
    /// but for the pattern (not binding) surface.
    fn parsePatternBinding(self: *Parser) ?[]const u8 {
        const tok = self.peek();
        if (tok.tag == .identifier and std.mem.eql(u8, tok.text, "_")) {
            self.advance();
            return null;
        }
        return self.expectIdent();
    }

    // Map a compound-assign TokenTag to its corresponding BinaryOp. Returns
    // `null` for non-compound tags so parseStmt's identifier branch can
    // dispatch in one switch (`next == equals` → parseAssign,
    // `compoundOpForTag(next) != null` → parseCompoundAssign, etc).
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

    // `errdefer expr;` — runs the expression ONLY if the enclosing scope
    // exits via `?`-propagation or explicit `return Err(...)`. Mirrors zig
    // 0.16's `errdefer` keyword one-to-one. Example (from
    // `docs/19-memory.md` Pattern 2):
    //   let a = compute()?;
    //   errdefer free(a);
    //   ...
    // Used by the new carve-out where partial initialization must be rolled
    // back on `?` but the success path skips the cleanup.
    fn parseErrDefer(self: *Parser) Stmt.ErrDeferStmt {
        self.expect(.errdefer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }

    // `unsafe { <stmts> }` block marker. Sits in `parseStmt`'s dispatch so
    // the leading ident-or-expression forms don't accidentally consume
    // `unsafe` as a binding name; the keyword is reserved at token-time by
    // `lexer.readIdent`. The zig 0.16 backend no longer has a block-form
    // `unsafe` keyword — codegen emits the body wrapped in plain `{ ... }`
    // with comment markers so the AST shape remains analyzable for future
    // `-Dunsafe-block-check` tooling without changing the emitted
    // zig semantics (raw pointer dereferences and `@ptrCast` are already
    // unconditional in 0.16).
    fn parseUnsafeBlock(self: *Parser) []const Stmt {
        self.expect(.unsafe_kw);
        return self.parseBlock();
    }

    // Parse one `if cond { stmts... }` head plus its optional else-branch.
    // Consumes the leading `.if_kw` here (mirroring the convention used by
    // parseWhileStmt / parseForStmt / parseMatchExpr / parseReturnStmt).
    // Without this `expect`, parseExpr (called for the cond) would
    // self-dispatch on `.if_kw` to `parseIfExpr`, leaving the parser with
    // `if_kw` unconsumed and the cond never parsed — surfacing as
    // `expected rbrace, got 'print'` on the body statement. The
    // recursive `else if` chain is rendered via the `.if_chain` arm of
    // `IfStmt.else_kind` (boxed `*IfStmt`); terminal `else { ... }` via
    // the `.block` arm. The condition parses via `parseExpr` so binary
    // precedence (e.g. `i < 10 && ready`) works without special-casing.
    fn parseIfBranch(self: *Parser) Stmt.IfStmt {
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

    // `if cond { expr } else { expr }` expression form. Used when `if_kw`
    // is the leading token in an expression-position context
    // (RHS of a `let`, inside a binary operand list, etc.). Each branch's
    // `Expr` is lifted into an arena slot so the resulting `IfExpr`'s
    // pointer fields point at stable storage (the existing BinaryExpr
    // `*Expr` convention). The else-branch is REQUIRED for the
    // expression form (otherwise the type would be `?T`); the parser
    // emits a clear error if missing.
    fn parseIfExpr(self: *Parser) Expr {
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
        return .{ .if_expr = .{
            .cond = &cond_buf[0],
            .then_expr = &then_buf[0],
            .else_expr = &else_buf[0],
        } };
    }

    // `while cond { stmts... }`. `while let` is deferred to followup commit
    // — surface requires enum-variant patterns which lexer doesn't tokenize.
    // Return type is `Stmt.WhileStmt` (the inner payload struct), not the
    // outer `Stmt` union, so the dispatch in `parseStmt` can assign the
    // value into `.while_stmt = …` without a redundant re-wrap.
    fn parseWhileStmt(self: *Parser) Stmt.WhileStmt {
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

    // `for pat in iter { stmts... }`. Pattern is currently the one-element
    // subset (ident or discard) — see `Stmt.for_stmt` doc for the
    // tuple-pattern followup plan. After the pattern, parser expects `in`,
    // then any expression for `iter`, then a `{ stmts }` body. Returns
    // the inner payload struct `Stmt.ForStmt` so the dispatch in
    // `parseStmt` can assign into `.for_stmt = …` directly.
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

    // `match scrutinee { arms... }` expression. Built once and reused for
    // statement-position use (via `Stmt.match_stmt`) and expression-
    // position use (via `Expr.match_expr`); the AST node lives in the
    // `Expr` envelope. Arm bodies are single expressions per the user-
    // confirmed shape; arm separator is comma.
    //
    // Scrutinee, guard, and arm body are each lifted into arena slots
    // so the resulting `Expr.MatchExpr` and `MatchArm` pointer fields
    // point at stable storage (mirrors the existing BinaryExpr `*Expr`
    // cycle-breaking convention — see the `IfExpr` doc for why).
    fn parseMatchExpr(self: *Parser) ast.Expr.MatchExpr {
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
            // Closure expressions (docs/15 §"Closures") start with the
            // leading `.pipe` token of the param-bracketed `|x| body`
            // shape. Dispatched here at the top of parseExpr so the rest
            // of the precedence ladder sees the closure as a single
            // operand and `let f = |x| x + 1;` parses as a single
            // Closure-typed RHS rather than something bitwise-OR-shaped.
            // This route mirrors the `.if_kw` arm above and avoids
            // touching `parsePrimary` directly (where the anchor
            // surface is large). The `.pipe_pipe` (logical-or) and
            // `.pipe_eq` (compound-assign) tokens remain binary
            // operators handled by the binary parse-layers; only the
            // bare `.pipe` is the closure sentinel.
            .pipe => return self.parseClosureExpr(),
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

    /// Helper for parseRange. Lifts lhs/rhs into arena-allocated Expr slots
    /// then constructs the `.range` union payload.
    fn makeRange(self: *Parser, lhs: Expr, rhs: Expr, inclusive: bool) Expr {
        const lb = self.arena.alloc(Expr, 1);
        lb[0] = lhs;
        const rb = self.arena.alloc(Expr, 1);
        rb[0] = rhs;
        return .{ .range = .{ .start = &lb[0], .end = &rb[0], .inclusive = inclusive } };
    }

    /// True if `tag` can begin an expression — i.e. is a primary Expr kind
    /// or a unary prefix, or one of the recipe-level `if_kw` / `match_kw`
    /// sentinels that parseExpr dispatches on at the top of the ladder.
    /// Used by parseRange to gate the `.ellipsis` arm on a valid RHS so
    /// `0...5` parses as a range but `0...}` (array-lit fill mode) is
    /// left untouched for the caller to interpret as the fill marker.
    fn isExprStart(tag: TokenTag) bool {
        return switch (tag) {
            .integer_literal, .float_literal, .string_literal, .byte_string_literal, .char_literal, .true_kw, .false_kw, .null_kw, .undefined_kw, .identifier, .print, .lparen, .lbracket, .minus, .amp, .plus, .tilde, .bang, .star, .new, .free, .if_kw, .match_kw => true,
            else => false,
        };
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

    /// Unary prefix layer: `-x`, `!x`, `~x`, `*x` (deref), `&x` (addr-of).
    /// All five are prefix operators binding tighter than any binary op,
    /// so this layer sits at the top of the precedence ladder. Recursive
    /// on the operand so `--x` parses as `-(-x)` and `**p` parses as
    /// `*( *p)` (two stacked derefs). After the unary refactor moved deref
    /// `*x` here from parsePrimary, the operators emit
    /// `Expr.unary { op, operand }` consistently with the existing
    /// NewExpr/DerefExpr pointer convention.
    ///
    /// The `.amp` token is shared with the binary bitwise-AND operator
    /// (consumed by `parseBitAnd`); the choice between unary address-of
    /// and binary bitwise-AND is purely syntactic context — when `.amp`
    /// appears in expression-prefix position it routes to `.addr`, when
    /// it appears between two expressions (e.g. `a & b`) it routes to
    /// `.bitand`. The lexer keeps a single `.amp` token so the parser
    /// can make this dispatch without expanding the lexer surface
    /// (mirrors how `-x` (unary) vs `a - b` (binary) share the `.minus`
    /// token, and `*x` (deref) vs `a * b` (mul) share the `.star`).
    fn parseUnary(self: *Parser) Expr {
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
                .newline, .comma, .rparen, .rbracket, .rbrace, .colon, .equals, .plus_eq, .minus_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq, .plus, .minus, .slash, .percent, .amp, .pipe, .caret, .tilde, .bang, .lt_lt, .gt_gt, .lt, .gt, .lt_eq, .gt_eq, .eq_eq, .bang_eq, .amp_amp, .pipe_pipe, .range, .ellipsis, .arrow, .doc_comment, .eof => true,
                else => false,
            };
            if (is_term) break;
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

    /// Postfix layer: chains `[i]` indexing OR `[start..end]` slicing
    /// onto a primary expression so `arr[i][j]` parses as
    /// `Index(Index(arr, i), j)` and `arr[a..b][0]` parses as
    /// `Index(Slice(arr, a, b, false), 0)`. Three bracket shapes:
    ///   - index:  `EXPR ]`                 → IndexExpr(target, EXPR)
    ///   - slice:  `[ .. | ... ] [EXPR] ]`  → SliceExpr with nullable bounds
    ///   - slice:  `[.. | ...] ]`           → SliceExpr with both bounds null
    ///   - slice:  `[EXPR [.. | ...] ]`     → SliceExpr with non-null start
    ///
    /// Disambiguation: after consuming `[`, peek is one of `.range`,
    /// `.ellipsis`, `.rbracket`, or a primary-start token. The first two
    /// make the slice form immediately known (empty-start slice); the
    /// third is an empty `[]` form (currently rejected as malformed);
    /// the fourth path parses a single `parseAdditive` for the start
    /// bounded AT the additive layer (NOT reaching parseRange, which
    /// would consume a trailing `..`/`...` and silently turn the slice
    /// into an index over a RangeExpr). The bounded parse ensures the
    /// postfix loop sees the `.range`/`.ellipsis`/`.rbracket` token
    /// next and can dispatch correctly.
    ///
    /// The recursive walk stops at the first non-bracket token and
    /// returns the LHS up the precedence ladder to whichever binary op
    /// is next. Note: this is NOT for chained-function-calls
    /// (`f(1)(2)`) — that would require a `.lparen` arm here too, but
    /// the user-chosen shape is "chained single-Index per bracket pair"
    /// only.
    fn parsePostfix(self: *Parser) Expr {
        var lhs = self.parsePrimary();
        // The postfix chain interleaves two shapes:
        //   - `[start..end]` (or single-index or no-bound variants) → `.index` / `.slice`
        //   - `.name` (no parens) → `.member_access` | `.name(args...)` → `.method_call`
        // Both shapes are checked in this single `while` so chains like
        // `arr[i].len`, `(getBox()).field`, `obj.method().chain` interleave
        // naturally — each iteration of the loop consumes one postfix
        // token and re-emits `lhs` with the wrapping applied.
        while (true) {
            if (self.peek().tag == .lbracket) {
                self.advance(); // consume [
                // Three valid shapes and one error follow the opening `[`:
                // 1. empty start slice: peek `.range` or `.ellipsis`
                // 2. malformed `[]`: peek `.rbracket` immediately
                // 3. explicit start: parseAdditive, then range/ellipsis/bracket
                var inclusive: bool = false;
                var start_opt: ?*Expr = null;

                if (self.peek().tag == .range) {
                    inclusive = false;
                    self.advance();
                } else if (self.peek().tag == .ellipsis) {
                    inclusive = true;
                    self.advance();
                } else if (self.peek().tag == .rbracket) {
                    const tok = self.peek();
                    std.debug.print("error:{d}:{d}: empty slice form '[]' — write '[..]' for whole-array view or '[N..]' / '[..N]' for partial slices\n", .{ tok.loc.line, tok.loc.col });
                    std.process.exit(1);
                } else {
                    const start_expr = self.parseAdditive();
                    if (self.peek().tag == .range) {
                        inclusive = false;
                        const sb = self.arena.alloc(Expr, 1);
                        sb[0] = start_expr;
                        start_opt = &sb[0];
                        self.advance();
                    } else if (self.peek().tag == .ellipsis) {
                        inclusive = true;
                        const sb = self.arena.alloc(Expr, 1);
                        sb[0] = start_expr;
                        start_opt = &sb[0];
                        self.advance();
                    } else {
                        self.expect(.rbracket);
                        const target_buf = self.arena.alloc(Expr, 1);
                        target_buf[0] = lhs;
                        const idx_buf = self.arena.alloc(Expr, 1);
                        idx_buf[0] = start_expr;
                        lhs = .{ .index = .{ .target = &target_buf[0], .index = &idx_buf[0] } };
                        continue;
                    }
                }

                var end_opt: ?*Expr = null;
                if (self.peek().tag != .rbracket) {
                    const end_expr = self.parseAdditive();
                    const eb = self.arena.alloc(Expr, 1);
                    eb[0] = end_expr;
                    end_opt = &eb[0];
                }
                self.expect(.rbracket);
                const target_buf = self.arena.alloc(Expr, 1);
                target_buf[0] = lhs;
                lhs = .{ .slice = .{ .target = &target_buf[0], .start = start_opt, .end = end_opt, .inclusive = inclusive } };
                continue;
            }
            // `.` postfix chain — `.name` (no parens) → `.member_access`,
            // `.name(...)` → `.method_call`. The chain target is lifted to
            // an arena slot so the resulting `.member_access`/`.method_call`
            // payload's `*Expr` pointer points at stable storage (mirrors
            // the cycle-breaking convention used everywhere else).
            if (self.peek().tag == .dot) {
                self.advance(); // consume .
                const name = self.expectIdent();
                if (self.peek().tag == .lparen) {
                    // Method-call form: `.name(args...)`. Args are
                    // comma-separated Exprs parsed via the top of the
                    // precedence ladder so `obj.method(1 + 2)` works.
                    self.advance(); // consume (
                    var args_buf: [16]Expr = undefined;
                    var arg_count: usize = 0;
                    if (self.peek().tag != .rparen) {
                        args_buf[arg_count] = self.parseExpr();
                        arg_count += 1;
                        while (self.peek().tag == .comma) {
                            self.advance();
                            args_buf[arg_count] = self.parseExpr();
                            arg_count += 1;
                        }
                    }
                    self.expect(.rparen);
                    const args = self.arena.alloc(Expr, arg_count);
                    @memcpy(args, args_buf[0..arg_count]);
                    const target_buf = self.arena.alloc(Expr, 1);
                    target_buf[0] = lhs;
                    lhs = .{ .method_call = .{ .target = &target_buf[0], .name = name, .args = args } };
                } else {
                    // Property-access form: `.name` (no parens). Codegen
                    // emits `<target>.<name>` verbatim — the user-facing
                    // form on `v.x` is identical to zig's struct-field-
                    // access syntax so no special conversion is needed.
                    const target_buf = self.arena.alloc(Expr, 1);
                    target_buf[0] = lhs;
                    lhs = .{ .member_access = .{ .target = &target_buf[0], .name = name } };
                }
                continue;
            }
            break;
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
                // Qualified enum-variant constructor `Enum.Variant(args...)`
                // (docs/manual/13). Conservative gate: only enable the
                // QUALIFIED form because the unqualified `Variant(args)`
                // shape is ambiguous between variant-construction and
                // function-call (the existing `.print, .identifier` arm
                // already routes parenthetical idents to parseCallExpr).
                // Pattern-context (match/if-let/while-let) is the ONLY
                // surface where unqualified `Variant(args)` is unambiguous
                // (handled in parsePattern's extension above).
                //
                // CRITICAL: BOTH the enum name AND the variant name must
                // start with an uppercase letter (Rust/Zig PascalCase
                // convention). Without the second uppercase check, the
                // gate falsely matches `Direction.opposite(d)` —
                // the `opposite` is a method name (lowercase), not a
                // variant name. Without the second check, codegen routes
                // the method call to enum_variant_ctor and emits
                // `Direction{ .opposite = d }` (struct-init syntax),
                // which zig 0.16 rejects with "type 'Direction' does
                // not support struct initialization syntax" because the
                // bare `enum { North, South, ... }` form doesn't have
                // fields.
                if (tok.tag == .identifier and name.len > 0 and name[0] >= 'A' and name[0] <= 'Z' and
                    self.pos + 2 < self.tokens.len and
                    self.tokens[self.pos].tag == .dot and
                    self.tokens[self.pos + 1].tag == .identifier and
                    self.tokens[self.pos + 1].text.len > 0 and
                    self.tokens[self.pos + 1].text[0] >= 'A' and
                    self.tokens[self.pos + 1].text[0] <= 'Z' and
                    self.tokens[self.pos + 2].tag == .lparen)
                {
                    const variant_name = self.tokens[self.pos + 1].text;
                    self.expect(.dot);
                    _ = self.expectIdent();
                    self.expect(.lparen);
                    var args_buf: [16]Expr = undefined;
                    var arg_count: usize = 0;
                    if (self.peek().tag != .rparen) {
                        args_buf[arg_count] = self.parseExpr();
                        arg_count += 1;
                        while (self.peek().tag == .comma) {
                            self.advance();
                            args_buf[arg_count] = self.parseExpr();
                            arg_count += 1;
                        }
                    }
                    self.expect(.rparen);
                    const args = self.arena.alloc(Expr, arg_count);
                    @memcpy(args, args_buf[0..arg_count]);
                    return .{ .enum_variant_ctor = .{
                        .enum_name = name,
                        .variant_name = variant_name,
                        .args = args,
                    } };
                }
                if (self.peek().tag == .lparen) {
                    return self.parseCallExpr(name);
                } else if (self.peek().tag == .lbrace and self.allow_struct_lit and
                    name.len > 0 and name[0] >= 'A' and name[0] <= 'Z')
                {
                    // Struct-literal: `Type { name: value, ... }`. The
                    // lexer already gave us an identifier followed by `{`,
                    // so we discriminate against a bare `.ident` on this
                    // single-token lookahead. The struct-literal payload
                    // is captured in declaration order so codegen's
                    // verbatim `.f1 = v1` emission matches source order.
                    //
                    // Two-gate disambiguation:
                    //   1. `self.allow_struct_lit` — primary parse-context
                    //      flag. `parseBinding` and `parseFieldAssign` set
                    //      it true at scope entry and restore via `defer`.
                    //      Anywhere else (if-conditions, while-conditions,
                    //      call args, return RHS, expr-stmt RHS) the flag
                    //      is false, so `if Foo { ... }` where Foo is a
                    //      PascalCase local is correctly parsed as the
                    //      if-condition `Foo` followed by its if-body
                    //      `{ ... }` rather than swallowing the block as
                    //      a struct-literal.
                    //   2. Uppercase-first-letter — defense-in-depth
                    //      heuristic (Rust/Zig-style convention for type
                    //      names). Even inside a binding-init position,
                    //      `vec { x: 1 }` is rejected as a struct-literal
                    //      because the leading identifier isn't capitalized;
                    //      lowercase type names must be constructed via
                    //      `Type.new(...)` instead. Belt-and-suspenders so
                    //      an accidental flag flip can't regress the
                    //      parser's structural disambiguation.
                    return self.parseStructLit(name);
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
                // Lookahead: named tuple `(name: expr, ...)`. Two-token
                // discriminator: identifier followed by COLON. Distinct
                // from struct-lit (which uses `{`) and from positional
                // / single-element (which starts with a non-ident or an
                // ident NOT followed by colon). Rust / Python tuple
                // syntax convention.
                if (self.peek().tag == .identifier and
                    self.pos + 1 < self.tokens.len and
                    self.tokens[self.pos + 1].tag == .colon)
                {
                    var names_buf: [32][]const u8 = undefined;
                    var named_elems_buf: [32]Expr = undefined;
                    var named_count: usize = 0;
                    while (self.peek().tag != .rparen and !self.eof()) {
                        names_buf[named_count] = self.expectIdent();
                        self.expect(.colon);
                        named_elems_buf[named_count] = self.parseExpr();
                        named_count += 1;
                        if (self.peek().tag == .comma) {
                            self.advance();
                            // Allow trailing comma `(x: 10, y: 20,)`.
                            if (self.peek().tag == .rparen) break;
                        } else break;
                    }
                    self.expect(.rparen);
                    const names_alloc = self.arena.alloc([]const u8, named_count);
                    @memcpy(names_alloc, names_buf[0..named_count]);
                    const elements_alloc = self.arena.alloc(Expr, named_count);
                    @memcpy(elements_alloc, named_elems_buf[0..named_count]);
                    return .{ .named_tuple_lit = .{ .names = names_alloc, .elements = elements_alloc } };
                }
                // Parse first expression — delegate via the top of the
                // precedence ladder so `(1 + 2)` is parsed as a full
                // binary expression rather than just a primary.
                var elements_buf: [32]Expr = undefined;
                var element_count: usize = 0;
                elements_buf[element_count] = self.parseExpr();
                element_count += 1;
                // If a comma follows, this is a tuple literal
                // (multi-element or single-element `(expr,)`).
                // The single-element form is captured via the
                // dedicated `.single_tuple_lit` variant so codegen
                // and downstream tests can distinguish it from
                // paren-grouping `(expr)` at the AST level. The
                // trailing-comma disambiguator follows Rust /
                // Python tuple syntax conventions.
                if (self.peek().tag == .comma) {
                    self.advance();
                    // Single-element `(expr,)` — distinguishing
                    // from `()` (empty tuple) and `(expr)`
                    // (paren-group) is the trailing comma,
                    // surfacing in zig as `.{ expr }` (one-field
                    // anonymous struct).
                    if (self.peek().tag == .rparen) {
                        self.advance();
                        const single = self.arena.alloc(Expr, 1);
                        single[0] = elements_buf[0];
                        return .{ .single_tuple_lit = &single[0] };
                    }
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

    /// Parse `Type { f1: v1, f2: v2, }` — the `.struct_lit` Expr form.
    /// Caller has already consumed the leading identifier (the type-name).
    /// Field-inits are comma-separated `name: value` pairs. The body
    /// bracket-len form `T { … }` is fully supported including the
    /// trailing-comma case the parser accepts (parser is
    /// comma-tolerant — extra trailing commas don't error so users can
    /// line up the closing brace naturally).
    fn parseStructLit(self: *Parser, type_name: []const u8) Expr {
        self.expect(.lbrace);
        var inits_buf: [16]ast.Expr.FieldInit = undefined;
        var init_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            if (self.peek().tag == .comma) {
                self.advance();
                continue;
            }
            const field_name = self.expectIdent();
            self.expect(.colon);
            const value = self.parseExpr();
            const value_buf = self.arena.alloc(Expr, 1);
            value_buf[0] = value;
            inits_buf[init_count] = .{ .name = field_name, .value = &value_buf[0] };
            init_count += 1;
        }
        self.expect(.rbrace);
        const inits = self.arena.alloc(ast.Expr.FieldInit, init_count);
        @memcpy(inits, inits_buf[0..init_count]);
        return .{ .struct_lit = .{ .type_name = type_name, .inits = inits } };
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

    /// Two-token lookahead: returns the tag at `pos + n` without consuming
    /// any tokens. Mirrors the 1-token `peek()` at the parser entry but
    /// with an explicit offset. Used by parseRange to disambiguate `0...5`
    /// (expression-starter follows — true range form) from `0...}`
    /// (structural delimiter follows — NOT a range; caller consumes the
    /// `.ellipsis` as the fill or progression marker instead).
    fn peekAhead(self: *Parser, n: u32) TokenTag {
        const idx = self.pos + n;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].tag;
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
            // NOTE: `.single_tuple_lit` (Phase 1 single-element tuple) and
            // `.named_tuple_lit` (Phase 1 named-field tuple) intentionally
            // read as "literal init" here even though their runtime type is
            // an anonymous struct (`.{ EXPR }` / `.{ .name = expr }`). The
            // carve-out above is only needed to surface a clear parser error
            // when binding a NON-LITERAL expression whose type zig cannot
            // infer to a primitive (specifically: `comptime_int` values that
            // would silently coerce into the wrong shape downstream — see
            // `codegen.needsIntDivShim` for the failure surface). Anonymous
            // structs have a fully decidable type that zig accepts in any
            // expression position, so allowing bare binding of these two
            // variants is safe — the resulting zig code round-trips through
            // downstream uses (print, member access, comparisons).
            .int_lit, .float_lit, .bool_lit, .char_lit, .string_lit, .byte_string_lit, .null_lit, .undefined_lit, .tuple_lit, .array_lit, .template_lit, .new_expr, .struct_lit, .single_tuple_lit, .named_tuple_lit => true,
            else => false,
        };
    }
    fn expectIdent(self: *Parser) []const u8 {
        const tok = self.peek();
        // Method/struct names can be any user-facing identifier PLUS
        // the keyword tokens `print`/`new`/`free` because the docs/12
        // common pattern is `impl Vec3 { pub fun new(...) -> Vec3 }`
        // where `new` is the conventional constructor name. Without
        // this concession the parser rejects `pub fun new(...)` even
        // though the user's surface clearly distinguishes the method
        // name from heap allocation via the surrounding `fun NAME(...)`
        // syntax. Same reasoning for `print` (already accepted) and
        // `free` (the docs/19 example `defer free(p)` uses `free` as
        // both a heap-op and a potential method name without clash).
        if (tok.tag != .identifier and tok.tag != .print and
            tok.tag != .new and tok.tag != .free)
        {
            std.debug.print("error:{d}:{d}: expected identifier, got '{s}'\n", .{
                tok.loc.line, tok.loc.col, tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
        return tok.text;
    }
};
