const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;


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


pub fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }


pub fn advance(self: *Parser) void {
        self.pos += 1;
    }


pub fn eof(self: *Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].tag == .eof;
    }


pub fn peekAhead(self: *Parser, n: u32) TokenTag {
        const idx = self.pos + n;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].tag;
    }


pub fn expect(self: *Parser, tag: TokenTag) void {
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


pub fn isLiteralInit(expr: Expr) bool {
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


pub fn expectIdent(self: *Parser) []const u8 {
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


    // ----- Method aliases -----

    pub const peekAhead = @import("core.zig").peekAhead;
    pub const expectIdent = @import("core.zig").expectIdent;
    pub const init = @import("core.zig").init;
    pub const expect = @import("core.zig").expect;
    pub const advance = @import("core.zig").advance;
    pub const peek = @import("core.zig").peek;
    pub const isLiteralInit = @import("core.zig").isLiteralInit;
    pub const eof = @import("core.zig").eof;
    pub const parse = @import("core.zig").parse;

    // --- decl.zig ---
    pub const parseClosureExpr = @import("decl.zig").parseClosureExpr;
    pub const parseEnumDecl = @import("decl.zig").parseEnumDecl;
    pub const parseEnumVariantPayload = @import("decl.zig").parseEnumVariantPayload;
    pub const parseFunDecl = @import("decl.zig").parseFunDecl;
    pub const parseImplBlock = @import("decl.zig").parseImplBlock;
    pub const parseMethod = @import("decl.zig").parseMethod;
    pub const parseMethodParam = @import("decl.zig").parseMethodParam;
    pub const parseStructDecl = @import("decl.zig").parseStructDecl;

    // --- stmt.zig ---
    pub const compoundOpForTag = @import("stmt.zig").compoundOpForTag;
    pub const parseAssign = @import("stmt.zig").parseAssign;
    pub const parseBinding = @import("stmt.zig").parseBinding;
    pub const parseBindingPattern = @import("stmt.zig").parseBindingPattern;
    pub const parseBlock = @import("stmt.zig").parseBlock;
    pub const parseCompoundAssign = @import("stmt.zig").parseCompoundAssign;
    pub const parseDefer = @import("stmt.zig").parseDefer;
    pub const parseErrDefer = @import("stmt.zig").parseErrDefer;
    pub const parseFieldAssign = @import("stmt.zig").parseFieldAssign;
    pub const parseForStmt = @import("stmt.zig").parseForStmt;
    pub const parseIfBranch = @import("stmt.zig").parseIfBranch;
    pub const parseIndexAssign = @import("stmt.zig").parseIndexAssign;
    pub const parseMatchExpr = @import("stmt.zig").parseMatchExpr;
    pub const parsePattern = @import("stmt.zig").parsePattern;
    pub const parsePatternBinding = @import("stmt.zig").parsePatternBinding;
    pub const parseReturnStmt = @import("stmt.zig").parseReturnStmt;
    pub const parseStmt = @import("stmt.zig").parseStmt;
    pub const parseStmtList = @import("stmt.zig").parseStmtList;
    pub const parseUnsafeBlock = @import("stmt.zig").parseUnsafeBlock;
    pub const parseWhileStmt = @import("stmt.zig").parseWhileStmt;

    // --- expr.zig ---
    pub const collectCastType = @import("expr.zig").collectCastType;
    pub const isExprStart = @import("expr.zig").isExprStart;
    pub const makeBinary = @import("expr.zig").makeBinary;
    pub const makeRange = @import("expr.zig").makeRange;
    pub const parseAdditive = @import("expr.zig").parseAdditive;
    pub const parseBitAnd = @import("expr.zig").parseBitAnd;
    pub const parseBitOr = @import("expr.zig").parseBitOr;
    pub const parseBitXor = @import("expr.zig").parseBitXor;
    pub const parseCast = @import("expr.zig").parseCast;
    pub const parseComparison = @import("expr.zig").parseComparison;
    pub const parseExpr = @import("expr.zig").parseExpr;
    pub const parseIfExpr = @import("expr.zig").parseIfExpr;
    pub const parseLogicalAnd = @import("expr.zig").parseLogicalAnd;
    pub const parseLogicalOr = @import("expr.zig").parseLogicalOr;
    pub const parseMultiplicative = @import("expr.zig").parseMultiplicative;
    pub const parseRange = @import("expr.zig").parseRange;
    pub const parseShift = @import("expr.zig").parseShift;
    pub const parseUnary = @import("expr.zig").parseUnary;
    pub const rejectRangeChaining = @import("expr.zig").rejectRangeChaining;

    // --- primary.zig ---
    pub const buildTemplate = @import("primary.zig").buildTemplate;
    pub const parseArrayLit = @import("primary.zig").parseArrayLit;
    pub const parseCallExpr = @import("primary.zig").parseCallExpr;
    pub const parseFree = @import("primary.zig").parseFree;
    pub const parseNew = @import("primary.zig").parseNew;
    pub const parsePostfix = @import("primary.zig").parsePostfix;
    pub const parsePrimary = @import("primary.zig").parsePrimary;
    pub const parseStructLit = @import("primary.zig").parseStructLit;

};
