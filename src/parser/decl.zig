// src/parser/decl.zig - file-scope method bodies for the decl bucket.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");
const core = @import("core.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Parser = core.Parser;


pub fn parseTypeParam(self: *Parser) ast.TypeParam {
        var is_const = false;
        // `const N: usize` prefix — the only thing distinguishing a
        // const-param from a type-param. Consumes `.const_kw` and
        // sets `is_const = true` so codegen emits `comptime N: usize`
        // instead of `comptime N: type`.
        if (self.peek().tag == .const_kw) {
            self.advance();
            is_const = true;
        }
        const name = self.expectIdent();
        if (is_const) {
            // Const params REQUIRE a type annotation (`const NAME: T`).
            // Reuses `collectCastType` so multi-token const-types like
            // `const N: *const usize` round-trip verbatim (zig accepts
            // those as `comptime X: *const usize`).
            self.expect(.colon);
            // Local `const` avoids a `.len` field-access on the
            // OPTIONAL `type_text` outer var (zig rejects optional
            // field-access directly). The slice is implicitly
            // coerced into the optional slot at struct-init.
            const tt = self.collectCastType();
            if (tt.len == 0) {
                std.debug.print("error:{d}:{d}: const type parameter '{s}' requires a type after ':'\n", .{ self.peek().loc.line, self.peek().loc.col, name });
                std.process.exit(1);
            }
            return .{ .name = name, .bounds = &[_][]const u8{}, .is_const = true, .type_text = tt };
        }
        // Type param: optional `: Bound1 + Bound2 + ...` after the
        // name. The bounds list is a `[]const []const u8` split at
        // `+` boundaries so codegen can iterate without further
        // string-splitting. Bounds are stored verbatim (the trait
        // name appears as-is in the source — `Clone`, `Ordered`, etc.).
        var bounds_buf: [8][]const u8 = undefined;
        var bound_count: usize = 0;
        if (self.peek().tag == .colon) {
            self.advance();
            if (self.peek().tag != .gt and self.peek().tag != .comma) {
                bounds_buf[bound_count] = self.expectIdent();
                bound_count += 1;
                while (self.peek().tag == .plus) {
                    self.advance();
                    bounds_buf[bound_count] = self.expectIdent();
                    bound_count += 1;
                }
            }
        }
        const bounds_arena = self.arena.alloc([]const u8, bound_count);
        @memcpy(bounds_arena, bounds_buf[0..bound_count]);
        return .{ .name = name, .bounds = bounds_arena };
    }


pub fn parseTypeParams(self: *Parser) []const ast.TypeParam {
        // Caller has verified peek() == .lt already. Consume `<`, then
        // one or more comma-separated TypeParams, then a closing `>`.
        // Empty `<>` is rejected (no zero-param generics are valid) —
        // callers should bypass parseTypeParams when there's nothing
        // to parse.
        self.expect(.lt);
        var tps_buf: [8]ast.TypeParam = undefined;
        var tp_count: usize = 0;
        tps_buf[tp_count] = self.parseTypeParam();
        tp_count += 1;
        while (self.peek().tag == .comma) {
            self.advance();
            tps_buf[tp_count] = self.parseTypeParam();
            tp_count += 1;
        }
        self.expect(.gt);
        const tps_arena = self.arena.alloc(ast.TypeParam, tp_count);
        @memcpy(tps_arena, tps_buf[0..tp_count]);
        return tps_arena;
    }


pub fn parseTurbofishArgs(self: *Parser) []const []const u8 {
        // Caller has verified the ident-`<`-typename-`>`-`(` shape
        // and consumed the leading ident + `<`. We now collect one
        // turbofish slot per comma-separated list, then consume `>`.
        //
        // Each slot is verbatim source text. We accept three shapes:
        //   1. typename ident (`i32`, `f64`, `usize`, ...) — reuses
        //      `collectCastType` so multi-token typenames like
        //      `*const T` round-trip (Phase 2 commitment).
        //   2. integer literal (`10`, `256`, ...) — verbatim from the
        //      token's `.text`. These are the const-args in
        //      `fill<i32, 10>(0)`.
        //   3. single identifier token (rare, but accepted).
        //
        // For the first cut of generics (`fun NAME<T>(...) { ... }`
        // and the turbofish call site at `NAME<T>(args)`), we keep this
        // simple: ONE token per slot, captured verbatim as a single
        // string. Compositional generics inside turbofish (e.g.
        // `Map<K, V>`) require collecting with bracket-balancing;
        // that's Phase 2 work.
        var args_buf: [8][]const u8 = undefined;
        var arg_count: usize = 0;
        if (self.peek().tag != .gt) {
            if (self.peek().tag == .identifier) {
                args_buf[arg_count] = self.peek().text;
                self.advance();
            } else if (self.peek().tag == .integer_literal) {
                args_buf[arg_count] = self.peek().text;
                self.advance();
            } else {
                args_buf[arg_count] = self.collectCastType();
            }
            arg_count += 1;
            while (self.peek().tag == .comma) {
                self.advance();
                if (self.peek().tag == .identifier) {
                    args_buf[arg_count] = self.peek().text;
                    self.advance();
                } else if (self.peek().tag == .integer_literal) {
                    args_buf[arg_count] = self.peek().text;
                    self.advance();
                } else {
                    args_buf[arg_count] = self.collectCastType();
                }
                arg_count += 1;
            }
        }
        self.expect(.gt);
        const args_arena = self.arena.alloc([]const u8, arg_count);
        @memcpy(args_arena, args_buf[0..arg_count]);
        return args_arena;
    }


pub fn parseClosureExpr(self: *Parser) Expr {
        const start_loc = self.peek().loc;
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
        return Expr{ .payload = .{ .closure = .{
            .params = params,
            .return_type = return_type,
            .body = body,
        } }, .loc = start_loc };
    }


pub fn parseEnumDecl(self: *Parser) ast.EnumDecl {
        // v1→v2 transitional surface (docs/manual/13-enums §"Choosing
        // Between enum and union" + §"Backed Enums" + docs/manual/14-
        // unions §"Definition"): `enum` accepts BOTH bare variants
        // AND payload-bearing variants (paren-positional). The new
        // `union` keyword is an ALIAS for the payload-bearing form
        // landing in v2 — parsing `union X { Foo(T) }` is identical
        // to parsing `enum X { Foo(T) }` (both routes go through
        // parseEnumDecl's shared logic via the new parseUnionDecl
        // helper). Backed-enum `enum(T) { V = value }` form is also
        // accepted here (T must be in zagTypeToZig's alias table for
        // the codegen-side alias rewrite).
        //
        // The strict-split (enum = bare-only, union = payload-only)
        // was rolled back in this commit because it broke 4 pre-
        // existing parser + codegen tests that use the legacy v1
        // payload-bearing enum shape. The v2 split lands as a
        // NARRATIVE in the docs/13/14 manual (the user's previous
        // commit) but the parser still accepts both shapes for both
        // keywords. A future commit can re-introduce the strict-
        // split once the legacy test surface migrates to `union` for
        // payload forms (matching the example/types/enum.zag
        // migration already landed).
        const start_loc = self.peek().loc;
        self.expect(.enum_kw);
        // Optional backing-type `enum(T)`. Captured verbatim via
        // collectCastType so multi-token forms round-trip; codegen
        // routes through `zagTypeToZig` for the alias rewrite.
        var backing_type: ?[]const u8 = null;
        if (self.peek().tag == .lparen) {
            self.advance();
            backing_type = self.collectCastType();
            self.expect(.rparen);
        }
        const name = self.expectIdent();
        // Name-first backing type `enum Status -> u8` (v2.2 canonical
        // surface): the enum NAME leads and the backing type trails
        // after the function-return-style arrow, so the bare default
        // is `enum Status { ... }`. Both this arrow form and the
        // legacy `enum(u8) Status` paren form above populate the same
        // `backing_type` slot, so codegen dispatch is unchanged.
        if (self.peek().tag == .arrow) {
            self.advance();
            backing_type = self.collectCastType();
        }
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
            var fields_buf: [16]ast.VariantField = undefined;
            var field_count: usize = 0;
            if (self.peek().tag == .lparen) {
                // Paren-positional payload (e.g. `Circle(f64)` or
                // `Rect(f64, f64)`): join multi-token type-text with
                // ", " so codegen emits `struct { a: T0, b: T1, ... }`
                // with sequential single-letter field names. Mirrors
                // the legacy parseEnumDecl payload-collection code
                // byte-for-byte (preserves all 4 pre-existing tests'
                // expectations).
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
            } else if (self.peek().tag == .lbrace) {
                // Brace-named-field payload (e.g. `Drag { x: f64, y: f64 }`):
                // capture structured `[{name, type_text}, ...]` so codegen
                // emits `struct { x: f64, y: f64 }` with the user's
                // actual names (vs. the legacy single-letter scheme used
                // for paren-positional). Mirrors parseStructDecl's
                // named-field loop pattern.
                self.advance(); // consume {
                fields_buf[field_count] = blk: {
                    const fname = self.expectIdent();
                    self.expect(.colon);
                    const ftype = self.collectCastType();
                    break :blk ast.VariantField{ .name = fname, .type_text = ftype };
                };
                field_count += 1;
                while (self.peek().tag == .comma) {
                    self.advance();
                    fields_buf[field_count] = blk: {
                        const fname = self.expectIdent();
                        self.expect(.colon);
                        const ftype = self.collectCastType();
                        break :blk ast.VariantField{ .name = fname, .type_text = ftype };
                    };
                    field_count += 1;
                }
                self.expect(.rbrace);
            }
            // Backed-enum per-variant value (`enum(T) { V = expr }`):
            // only meaningful when a backing_type was captured; allowed
            // in any `enum` or `union` decl shape for parser-uniformity
            // (zig rejects the combination at the byte level if it
            // would produce a malformed `union(enum) { V = expr, ... }`).
            var value_text: ?[]const u8 = null;
            if (self.peek().tag == .equals) {
                self.advance();
                value_text = self.parseBackedEnumValue();
            }
            const fields_arena = self.arena.alloc(ast.VariantField, field_count);
            if (field_count > 0) @memcpy(fields_arena, fields_buf[0..field_count]);
            variants_buf[variant_count] = .{
                .name = variant_name,
                .payload_type = payload,
                .loc = variant_loc,
                .fields = fields_arena,
                .value_text = value_text,
            };
            variant_count += 1;
        }
        self.expect(.rbrace);
        const variants = self.arena.alloc(ast.EnumVariant, variant_count);
        @memcpy(variants, variants_buf[0..variant_count]);
        // Gap #2 closure hook (docs/manual/14-unions §Mixed Bare + Payload):
        // register each brace-named-field variant's name into the
        // parser's `known_variant_names` table so parsePrimary's
        // `.identifier` arm can disambiguate `T { ... }` as a
        // unqualified brace ctor (when `T` is in the table) vs a
        // struct literal (when not). The registration filters by
        // `fields.len > 0` so only brace-named-field variants get
        // registered — bare variants and paren-positional variants
        // do not accept brace form, so accepting `Bare { ... }` for
        // a bare `Bare` would surface as a downstream zig-side error
        // rather than a useful emit. Mirrors the codegen-side
        // `variant_fields_buf` population in `genEnumDecl`'s
        // `v.fields.len > 0` arm (src/codegen/decl.zig) so the
        // parser's known-variant table matches the codegen's
        // brace-fields table.
        var vi: usize = 0;
        while (vi < variant_count) : (vi += 1) {
            if (variants[vi].fields.len > 0 and
                self.known_variant_count < self.known_variant_names.len)
            {
                self.known_variant_names[self.known_variant_count] = variants[vi].name;
                self.known_variant_count += 1;
            }
        }
        return .{ .name = name, .variants = variants, .loc = start_loc, .backing_type = backing_type };
    }


pub fn parseUnionDecl(self: *Parser) ast.EnumDecl {
        // v2 landing (docs/manual/14-unions §"Definition"): `union`
        // hosts tagged-union types whose variants MAY carry payloads
        // (paren-positional OR brace-named-field) OR be bare. The
        // shared AST shape (EnumDecl / EnumVariant) with parseEnumDecl
        // means codegen and trait-bound machinery reuse the same paths;
        // only the variant-shape acceptance differs.
        //
        // Three variant shapes accepted (any combination per decl):
        //   1. Bare:              `Variant`
        //   2. Paren-positional:  `Variant(T1, T2, ...)`
        //   3. Brace-named-field: `Variant { name1: T1, name2: T2 }`
        //
        // Backed-enum `enum(T) { V = value }` form is NOT accepted on
        // unions (zig's `union(enum) { ... }` shape does not host
        // per-variant backing values). Trying to write one would
        // surface as `expected variant or '}', got '='` from the
        // outer enum-parsing rejection surface (the user's obvious
        // choice for backed semantics is `enum`, not `union`).
        const start_loc = self.peek().loc;
        self.expect(.union_kw);
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
            var fields_buf: [16]ast.VariantField = undefined;
            var field_count: usize = 0;
            if (self.peek().tag == .lparen) {
                // Paren-positional payload (e.g. `Rect(f64, f64)`):
                // join multi-token type-text with ", " so codegen
                // emits `struct { a: f64, b: f64, ... }` with the
                // existing single-letter ordering. Mirrors the legacy
                // parseEnumDecl payload-collection code so the paren
                // form is byte-for-byte identical whether it lands
                // through `enum` (legacy) or `union` (post-split).
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
            } else if (self.peek().tag == .lbrace) {
                // Brace-named-field payload (e.g.
                // `Drag { x: f64, y: f64 }`): capture structured
                // `[{name, type_text}, ...]` so codegen emits
                // `struct { x: f64, y: f64 }` preserving the user's
                // actual names (vs. the legacy single-letter a/b/c/...
                // scheme used for paren-positional). Mirrors
                // parseStructDecl's named-field loop pattern.
                self.advance(); // consume {
                fields_buf[field_count] = blk: {
                    const fname = self.expectIdent();
                    self.expect(.colon);
                    const ftype = self.collectCastType();
                    break :blk ast.VariantField{ .name = fname, .type_text = ftype };
                };
                field_count += 1;
                while (self.peek().tag == .comma) {
                    self.advance();
                    fields_buf[field_count] = blk: {
                        const fname = self.expectIdent();
                        self.expect(.colon);
                        const ftype = self.collectCastType();
                        break :blk ast.VariantField{ .name = fname, .type_text = ftype };
                    };
                    field_count += 1;
                }
                self.expect(.rbrace);
            }
            const fields_arena = self.arena.alloc(ast.VariantField, field_count);
            if (field_count > 0) @memcpy(fields_arena, fields_buf[0..field_count]);
            variants_buf[variant_count] = .{
                .name = variant_name,
                .payload_type = payload,
                .loc = variant_loc,
                .fields = fields_arena,
                .value_text = null,
            };
            variant_count += 1;
        }
        self.expect(.rbrace);
        const variants = self.arena.alloc(ast.EnumVariant, variant_count);
        @memcpy(variants, variants_buf[0..variant_count]);
        // Gap #2 closure hook (docs/manual/14-unions §Mixed Bare + Payload):
        // mirror of the parseEnumDecl registration hook above. Each
        // brace-named-field variant under `union X { ... }` populates
        // the parser's `known_variant_names` table so the
        // `.identifier` arm in parsePrimary can dispatch
        // `VariantName { ... }` to `.enum_variant_ctor { enum_name =
        // null, ... }` rather than the legacy `.struct_lit` arm.
        // Filtering by `fields.len > 0` excludes bare and
        // paren-positional variants from the table (those forms don't
        // accept brace syntax anyway, so a brace-form match would
        // surface as a zig-side downstream error rather than a
        // useful emit). Same wire-up as the matched codegen-side `variant
        // fields_buf` population in `genEnumDecl`.
        var vi: usize = 0;
        while (vi < variant_count) : (vi += 1) {
            if (variants[vi].fields.len > 0 and
                self.known_variant_count < self.known_variant_names.len)
            {
                self.known_variant_names[self.known_variant_count] = variants[vi].name;
                self.known_variant_count += 1;
            }
        }
        return .{ .name = name, .variants = variants, .loc = start_loc, .backing_type = null };
    }


pub fn parseBackedEnumValue(self: *Parser) []const u8 {
        // Verbatim text capture from the current position until the
        // next comma / newline / rbrace. Used for `enum(T) { V = value
        // }` value capture. Walks the lexed tokens directly (not the
        // source) so multi-token values like `1 << 2`, computed
        // expressions, and named constants round-trip as-written.
        //
        // String-literal correction: the lexer's `.string_literal` and
        // `.byte_string_literal` tokens carry their payload WITHOUT the
        // surrounding quotes (matches the byte-string test in
        // src/tests/lexer.zig: `b"hello"` has `.text == "hello"` (5
        // chars, stripped quotes)). Naive verbatim capture would emit
        // `Low = low,` for the source `Low = "low"` — losing the
        // quotes and producing a malformed backing-enum value that
        // zig rejects with `error: declaration expects a constant`.
        // The fix: wrap the captured text in `"` for `.string_literal`
        // and `b"` for `.byte_string_literal` so the round-trip
        // preserves the source shape. Char literals are unaffected
        // (their `.text` field already includes the single-quote
        // pair per the lexer test that pins `'\n' → text = "'\\n'"`).
        //
        // Buffer size: most backed-enum values are 1-30 chars (e.g.
        // `0`, `0xFF`, `1.5`, `"low"`, `'a'`, `SomeConst`); 256 bytes
        // covers any realistic literal. A future literal-extending
        // surface (e.g. computed initializers like `Status.Max =
        // MyConst + 1`) may need a larger buffer; the existing carve-
        // out truncates silently which would surface as the codegen
        // emit of a partial expression (zig rejects malformed RHS so
        // the user gets a clear compile error pointing at the
        // truncated value rather than a silent parse-side corruption).
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        while (!self.eof() and self.peek().tag != .comma and
            self.peek().tag != .rbrace and self.peek().tag != .newline)
        {
            const t = self.peek();
            const is_string = t.tag == .string_literal;
            const is_byte_string = t.tag == .byte_string_literal;
            const needs_quotes = is_string or is_byte_string;
            if (len > 0 and len + 1 <= buf.len) {
                buf[len] = ' ';
                len += 1;
            }
            // Per-token-kind opening delimiter. Byte-string literals
            // carry the `b` prefix as part of the literal surface
            // (`b"..."`); plain string literals carry only the `"`
            // delimiter. The capture walk re-emits the prefix byte
            // (byte-strings) and the opening `"` (both) so the
            // captured value_text round-trips back into the emitted
            // zigzag as a string literal of the same kind.
            //
            // Bug caught by the byte-string codegen test (added
            // alongside this fix): the previous shape used a single
            // `opening: u8 = if (is_byte_string) 'b' else '"'` and
            // emitted ONE byte — the byte-string case produced a
            // 1-char `b` opening (no opening `"`), so the captured
            // value for `b"abc"` became `babc"` instead of `b"abc"`,
            // and the codegen emitted `Foo = babc",` instead of
            // `Foo = b"abc",`. Splitting the byte-string path into
            // 2 emitted bytes (`b` + `"`) resolves the asymmetry.
            if (is_byte_string) {
                if (len + 2 <= buf.len) {
                    buf[len] = 'b';
                    buf[len + 1] = '"';
                    len += 2;
                }
            } else if (is_string) {
                if (len + 1 <= buf.len) {
                    buf[len] = '"';
                    len += 1;
                }
            }
            if (len + t.text.len <= buf.len) {
                @memcpy(buf[len..][0..t.text.len], t.text);
                len += t.text.len;
            }
            if (needs_quotes and len + 1 <= buf.len) {
                buf[len] = '"';
                len += 1;
            }
            self.advance();
        }
        const arena = self.arena.alloc(u8, len);
        @memcpy(arena, buf[0..len]);
        return arena;
    }


pub fn parseEnumVariantPayload(self: *Parser) ?[]const u8 {
        _ = self;
        return null;
    }


pub fn parseTraitMethodDecl(self: *Parser) ast.TraitMethodDecl {
        const start_loc = self.peek().loc;
        // Accept-and-ignore `pub` (mirrors how parseMethod treats
        // impl-decl privacy; the keyword is preserved at the AST surface
        // for any future privacy wiring without re-routing the parser).
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
        // Body: when present, the method is a default (has a body in the
        // trait declaration). When absent (a semicolon or newline follows),
        // the method is required — every impl block must supply a body.
        var body: ?[]const ast.Stmt = null;
        if (self.peek().tag == .lbrace) {
            self.advance();
            body = self.parseStmtList();
            self.expect(.rbrace);
        }
        const params = self.arena.alloc(ast.MethodParam, param_count);
        if (param_count > 0) @memcpy(params, params_buf[0..param_count]);
        return .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .loc = start_loc,
        };
    }


pub fn parseTraitDecl(self: *Parser) ast.TraitDecl {
        // Mirrors parseEnumDecl's surface: open-brace then a comma/newline
        // separated list of methods until close-brace. Each method is
        // parsed via parseTraitMethodDecl (the `pub fun NAME(...) -> RET`
        // signature only; no default bodies in v1 minimum subset).
        const start_loc = self.peek().loc;
        self.expect(.trait_kw);
        const name = self.expectIdent();
        self.expect(.lbrace);
        var methods_buf: [64]ast.TraitMethodDecl = undefined;
        var method_count: usize = 0;
        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            if (self.peek().tag == .comma) {
                self.advance();
                continue;
            }
            methods_buf[method_count] = self.parseTraitMethodDecl();
            method_count += 1;
        }
        self.expect(.rbrace);
        const methods = self.arena.alloc(ast.TraitMethodDecl, method_count);
        @memcpy(methods, methods_buf[0..method_count]);
        return .{ .name = name, .methods = methods, .loc = start_loc };
    }


pub fn parseFunDecl(self: *Parser) ast.FunDecl {
        const start = self.peek().loc;
        self.expect(.fun);
        const name = self.expectIdent();
        // Generics (docs/16 §"Generic Functions"): if the source uses
        // `fun NAME<T>(...)`, consume the `<...>` type-param list
        // IMMEDIATELY after the ident and before the opening `(`.
        // Mirrors parseStructDecl / parseImplBlock; the lookahead is
        // `.lt` (3-byte left-angle bracket; `<=` `<` `<<=` `<` are
        // distinct tokens so we don't disambiguate beyond the bare
        // `.lt` form). When absent, the existing path emits the
        // legacy non-generic signature.
        var type_params: []const ast.TypeParam = &[_]ast.TypeParam{};
        if (self.peek().tag == .lt) {
            type_params = self.parseTypeParams();
        }
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
        // Reset closure_bindings so each fn accumulates only the
        // closures lexically declared inside its body. Mirrors
        // codegen's per-fn `type_info_buf` scoping (see
        // `collectTypedBindings` in src/codegen/stmt.zig). Setting
        // count = 0 is sufficient because `isClosureBound` only
        // consults indices 0..closure_binding_count; array contents
        // beyond the count are ignored.
        self.closure_binding_count = 0;
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
            .type_params = type_params,
        };
    }


pub fn parseImplBlock(self: *Parser) ast.ImplBlock {
        const start_loc = self.peek().loc;
        self.expect(.impl_kw);
        // Generics (docs/16 §"Generic impl Blocks"): if the source
        // uses `impl<T>`, consume the `<...>` BEFORE the target-type
        // ident. Same ler as parseFunDecl. The post-target form
        // `impl Box<T>` (type params bound to the target, the shape
        // generic-struct impl blocks use) is consumed after the
        // target ident below — both spell the same semantics: the
        // impl's methods become orphan free fns parameterized by
        // `comptime T: type`.
        var type_params: []const ast.TypeParam = &[_]ast.TypeParam{};
        if (self.peek().tag == .lt) {
            type_params = self.parseTypeParams();
        }
        const target_type = self.expectIdent();
        if (self.peek().tag == .lt) {
            type_params = self.parseTypeParams();
        }
        // Canonical trait-spec clause (docs/17 §"Implementing"):
        // `impl Type with T1 (m1, m2)?, T2 (m3)? { ... }`. Optional —
        // when absent, falls back to the legacy non-trait impl path
        // (empty `trait_specs`). Each spec is one `IDENT` optionally
        // followed by a parenthesised comma-separated method-name
        // list — the diamond disambiguator that binds a method body
        // to that trait's vtable. The clause is terminated by the
        // opening `{`. At least one trait spec is required when the
        // `with` keyword is present; `with` without any spec is a
        // compile error (`expected IDENT, got '{'`).
        var trait_specs: []const ast.TraitSpec = &[_]ast.TraitSpec{};
        if (self.peek().tag == .with_kw) {
            self.advance(); // consume `with`
            var specs_buf: [16]ast.TraitSpec = undefined;
            var specs_count: usize = 0;
            // First spec is mandatory; the comma-loop below only
            // runs while a comma follows a complete spec.
            while (true) {
                const spec_name = self.expectIdent();
                var methods_buf: [16][]const u8 = undefined;
                var methods_count: usize = 0;
                if (self.peek().tag == .lparen) {
                    self.advance(); // consume `(`
                    if (self.peek().tag != .rparen) {
                        while (true) {
                            methods_buf[methods_count] = self.expectIdent();
                            methods_count += 1;
                            if (self.peek().tag == .comma) {
                                self.advance();
                                continue;
                            }
                            break;
                        }
                    }
                    self.expect(.rparen);
                }
                const pref = self.arena.alloc([]const u8, methods_count);
                @memcpy(pref, methods_buf[0..methods_count]);
                specs_buf[specs_count] = .{
                    .name = spec_name,
                    .preferred_methods = pref,
                };
                specs_count += 1;
                if (self.peek().tag == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
            const specs_slice = self.arena.alloc(ast.TraitSpec, specs_count);
            @memcpy(specs_slice, specs_buf[0..specs_count]);
            trait_specs = specs_slice;
        }
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
        return .{
            .target_type = target_type,
            .methods = methods,
            .loc = start_loc,
            .type_params = type_params,
            .trait_specs = trait_specs,
        };
    }


pub fn parseMethod(self: *Parser) ast.MethodDecl {
        const start_loc = self.peek().loc;
        // Accept-and-ignore `pub` (the keyword exists in the lexer so the
        // grammar reserves it; privacy enforcement is deferred).
        if (self.peek().tag == .pub_kw) self.advance();
        self.expect(.fun);
        // Trait-qualified impl method (docs/17 §"Implementing"). The
        // `Trait.method` shape (`pub fun Drawable.draw(self: *Button) { ... }`)
        // inserts a 3-token lookahead immediately after `pub fun`: when
        // `IDENT . IDENT` follows, the first ident is the trait name and
        // the post-dot ident is the method name. Without the lookahead
        // parseMethod would consume `Drawable` as a malformed method
        // name and the postfix `.draw(...)` would surface as a
        // `.method_call` codegen error (or — worse — silently produce
        // a free-fn with the trait name baked into the identifier
        // string). Codegen reads `trait_name` to dual-emit the regular
        // free-fn AND the trait-method registration (the per-(trait,
        // target_type) vtable instantiation lands in Phase 2; here
        // we just carry the qualifier on the AST).
        var trait_name: ?[]const u8 = null;
        if (self.peek().tag == .identifier and
            self.peekAhead(1) == .dot and
            self.peekAhead(2) == .identifier)
        {
            trait_name = self.expectIdent();
            self.expect(.dot);
        }
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
        // Reset closure_bindings per-method body. Mirrors the
        // parseFunDecl reset above; codegen's per-method
        // collectTypedBindings pass also resets its type_info_count
        // at genMethod entry.
        self.closure_binding_count = 0;
        self.expect(.lbrace);
        const body = self.parseStmtList();
        self.expect(.rbrace);
        const params = self.arena.alloc(ast.MethodParam, param_count);
        @memcpy(params, params_buf[0..param_count]);
        return .{ .name = name, .params = params, .return_type = return_type, .body = body, .loc = start_loc, .trait_name = trait_name };
    }


pub fn parseMethodParam(self: *Parser) ast.MethodParam {
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


pub fn parseStructDecl(self: *Parser) ast.StructDecl {
        const start_loc = self.peek().loc;
        self.expect(.struct_kw);        const name = self.expectIdent();
        // Generics (docs/16 §"Generic Types"): if `struct NAME<T> { ... }`,
        // consume the `<...>` BEFORE the opening `{`. Same ler as
        // parseFunDecl.
        var type_params: []const ast.TypeParam = &[_]ast.TypeParam{};
        if (self.peek().tag == .lt) {
            type_params = self.parseTypeParams();
        }
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
        // Gap #2 closure (docs/manual/14-unions §Mixed Bare + Payload):
    // register `name` in known_struct_names so parsePrimary’s
    // `.identifier` arm can detect struct/variant name collisions.
    // When `name` appears as BOTH struct AND variant, struct wins
    // (BLOCKING #2 fix per code-reviewer), so the user writing
    // `T { ... }` for a struct gets the struct-lit route
    // (existing v1 behavior), not the brace-ctor route.
    // BLOCKING bounds check (gap #2 closure): cap struct-table pushes
    // so a 257th struct decl does not silently corrupt memory. The
    // sibling enum/union hooks already carry this guard; struct was
    // missed in the initial land and is added here.
    if (self.known_struct_count < self.known_struct_names.len) {
        self.known_struct_names[self.known_struct_count] = name;
        self.known_struct_count += 1;
    }
    return .{ .name = name, .fields = fields, .loc = start_loc, .type_params = type_params };
    }


pub fn parseImportDecl(self: *Parser, is_pub: bool) ast.ImportDecl {
        // Resolves one of three surface shapes:
        //   1. `import std.string`             (whole-module, no `pub`)
        //   2. `pub import std.string`         (whole-module, exported)
        //   3. `pub import std.X.{A, B as C}`  (selective + optional alias)
        //
        // The caller (`Parser.parse()` top-level dispatch) has already
        // consumed the leading `pub` token (when present) and verified
        // the next token is `.import_kw`. parseImportDecl starts with
        // an `expect(.import_kw)` so the shape is unambiguous from the
        // call site. Path components are verbatim idents separated by
        // `.`; the loop terminates when peek is `.lbrace` (selective
        // list follows), `.newline` (whole-module, no list), `.eof` /
        // any other terminator (whole-module).
        //
        // Resolution lives in `src/parser/core.zig`'s `KNOWN_STD_MODULES`
        // lookup table — this function captures only the AST shape; pair
        // the captured path_nodes with the table at codegen time via
        // the canonical dotted join (`std.string` from `["std", "string"]`).
        const start_loc = self.peek().loc;
        self.expect(.import_kw);
        var path_buf: [8][]const u8 = undefined;
        var path_count: usize = 0;
        path_buf[path_count] = self.expectIdent();
        path_count += 1;
        while (self.peek().tag == .dot) {
            self.advance();
            // Selective list — terminate the path and let the `{`
            // branch parse the selector list. Without this guard, an
            // import like `pub import std.atomic.{AtomicI32}` would
            // mistakenly re-enter the path loop and consume the `{`
            // as an ident (no, the lexer already tokenizes `{` as
            // `.lbrace` — but `expectIdent` would reject it, surface
            // an `expected identifier, got '{'` error, and break the
            // whole `pub import std.X.{…}` shape).
            if (self.peek().tag == .lbrace) break;
            path_buf[path_count] = self.expectIdent();
            path_count += 1;
        }
        // Selective list — captured ONLY when the source uses `{ … }`.
        // The list itself is comma-separated `Ident` slots; each
        // optional `as Ident` tail becomes the binding name on the
        // importing side (codegen looks the `name` slot up against
        // the source module's top-level decls, then emits the binding
        // under `alias orelse name` on the importer side).
        var selectors_buf: [64]ast.ImportSelector = undefined;
        var selector_count: usize = 0;
        if (self.peek().tag == .lbrace) {
            self.advance();
            while (self.peek().tag != .rbrace and !self.eof()) {
                if (self.peek().tag == .newline) {
                    self.advance();
                    continue;
                }
                if (self.peek().tag == .comma) {
                    self.advance();
                    continue;
                }
                const name = self.expectIdent();
                var alias: ?[]const u8 = null;
                if (self.peek().tag == .as_kw) {
                    self.advance();
                    alias = self.expectIdent();
                }
                selectors_buf[selector_count] = .{ .name = name, .alias = alias };
                selector_count += 1;
            }
            self.expect(.rbrace);
        }
        const path_arena = self.arena.alloc([]const u8, path_count);
        @memcpy(path_arena, path_buf[0..path_count]);
        const selectors = self.arena.alloc(ast.ImportSelector, selector_count);
        if (selector_count > 0) @memcpy(selectors, selectors_buf[0..selector_count]);
        return .{
            .is_pub = is_pub,
            .path_nodes = path_arena,
            .selectors = selectors,
            .loc = start_loc,
        };
    }


pub fn parseConstDecl(self: *Parser) ast.ConstDecl {
        const start_loc = self.peek().loc;
        self.expect(.const_kw);
        const name = self.expectIdent();
        var type_text: ?[]const u8 = null;
        if (self.peek().tag == .colon) {
            self.advance();
            type_text = self.collectCastType();
        }
        self.expect(.equals);
        const init_expr = self.arena.alloc(ast.Expr, 1);
        init_expr[0] = self.parseExpr();
        return .{
            .name = name,
            .type_text = type_text,
            .init = &init_expr[0],
            .loc = start_loc,
        };
    }


    /// `[pub] use <dotted-path> as <name>` module re-export
    /// (docs/manual/22-modules.md §Re-exports). The caller (the
    /// top-level dispatch in core.zig) has already consumed the
    /// leading `pub` (when present) and verified the next token is
    /// `.use_kw`. Path components are verbatim idents separated by
    /// `.`; the loop terminates when peek is `.as_kw` (the binding
    /// name follows) or any other terminator (malformed source —
    /// expectIdent surfaces the error). Resolution lives in
    /// KNOWN_STD_MODULES at codegen time (mirrors ImportDecl's
    /// contract).
    pub fn parseUseDecl(self: *Parser, is_pub: bool) ast.UseDecl {
        const start_loc = self.peek().loc;
        self.expect(.use_kw);
        var path_buf: [8][]const u8 = undefined;
        var path_count: usize = 0;
        path_buf[path_count] = self.expectIdent();
        path_count += 1;
        while (self.peek().tag == .dot) {
            self.advance();
            if (self.peek().tag == .as_kw) break;
            path_buf[path_count] = self.expectIdent();
            path_count += 1;
        }
        self.expect(.as_kw);
        const name = self.expectIdent();
        const path_nodes = self.arena.alloc([]const u8, path_count);
        @memcpy(path_nodes, path_buf[0..path_count]);
        return .{ .is_pub = is_pub, .path_nodes = path_nodes, .name = name, .loc = start_loc };
    }

pub fn parseExternDecl(self: *Parser) ast.ExternDecl {
        const start_loc = self.peek().loc;
        self.expect(.extern_kw);
        self.expect(.fun);        const name = self.expectIdent();
        self.expect(.lparen);
        var params_buf: [16]ast.MethodParam = undefined;
        var param_count: usize = 0;
        var is_variadic = false;
        if (self.peek().tag != .rparen) {
            while (true) {
                if (self.peek().tag == .ellipsis) {
                    is_variadic = true;
                    self.advance();
                    break;
                }
                const pname = self.expectIdent();
                self.expect(.colon);
                const ptype = self.collectCastType();
                if (ptype.len == 0) {
                    std.debug.print("error:{d}:{d}: extern fun param '{s}' requires a type\n", .{ self.peek().loc.line, self.peek().loc.col, pname });
                    std.process.exit(1);
                }
                if (param_count < params_buf.len) {
                    params_buf[param_count] = .{
                        .name = pname,
                        .type_text = ptype,
                        .is_self = false,
                    };
                    param_count += 1;
                }
                if (self.peek().tag == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
        }
        self.expect(.rparen);
        var return_type: ?[]const u8 = null;
        if (self.peek().tag == .arrow) {
            self.advance();
            const rt = self.collectCastType();
            return_type = if (rt.len == 0) null else rt;
        }
        const params = self.arena.alloc(ast.MethodParam, param_count);
        if (param_count > 0) @memcpy(params, params_buf[0..param_count]);
        return .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .is_variadic = is_variadic,
            .loc = start_loc,
        };
    }

