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


pub fn parseClosureExpr(self: *Parser) Expr {
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


pub fn parseEnumDecl(self: *Parser) ast.EnumDecl {
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


pub fn parseEnumVariantPayload(self: *Parser) ?[]const u8 {
        _ = self;
        return null;
    }


pub fn parseFunDecl(self: *Parser) ast.FunDecl {
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


pub fn parseImplBlock(self: *Parser) ast.ImplBlock {
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


pub fn parseMethod(self: *Parser) ast.MethodDecl {
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

