// src/parser/primary.zig - file-scope method bodies for the primary bucket.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");
const core = @import("core.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Parser = core.Parser;


pub fn buildTemplate(self: *Parser, raw: []const u8, start_loc: ast.Loc) Expr {
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
                const expr_text = if (has_spec) raw[expr_start .. spec_start - 1] else raw[expr_start..end_i];
                // Closure-call widening for template-literal interpolations
                // (docs/15 §\"Closures\" + basic.zag section 3). The pre-fix
                // code unconditionally wrapped the interpolation text as
                // `.{ .ident = expr_text }`, even when the text was
                // `name(args)` — meaning `{x}` and `{double(5)}` BOTH
                // surfaced as `Expr.ident(\"...\")`, and codegen emitted
                // the literal text into the args tuple. zig then parsed
                // the inline `double(5)` as a fresh bare dispatch and
                // rejected with `type 'main__struct_X' not a function`
                // because `double` is a closure-struct value (with a
                // `call(x) i32` method), not a free fn.
                //
                // The `.call` Expr shape unlocks the existing closure-
                // rewrite hook in codegen/expr.zig's `.call` arm
                // (`isClosureBound(c.name)` → emit `<name>.call(<args>)`)
                // which was previously unreachable from the template
                // path because the AST was forced to `.ident`. Now: if
                // the bracketed text matches `name(...)` — `(` appears
                // somewhere in the text, the trailing byte is `)` —
                // build a real `.call` Expr with each top-level
                // comma-separated arg parsed as `.int_lit` (digit walk)
                // or `.ident` (text ident). All other interpolation
                // shapes (`{x}`, `{a + b}`, `{obj.f()}` etc.) keep the
                // legacy `.ident` emit so pre-existing behaviour is
                // preserved exactly. `a + b` and `obj.f()` are still
                // non-functional templates — that's a pre-existing gap
                // not introduced by this fix.
                var build_expr: ast.Expr = Expr{ .payload = .{ .ident = expr_text }, .loc = start_loc };
                // Scan for the first `(` (top-level; the args segment
                // is tracked separately with depth-aware comma-split
                // below, so nested brackets inside `name(...)` don't
                // need outer-bracket tracking here).
                var lparen_idx: ?usize = null;
                {
                    var scan_i: usize = 0;
                    while (scan_i < expr_text.len) : (scan_i += 1) {
                        if (expr_text[scan_i] == '(') {
                            lparen_idx = scan_i;
                            break;
                        }
                    }
                }
                if (lparen_idx) |lparen| {
                    if (expr_text.len > 0 and expr_text[expr_text.len - 1] == ')') {
                        const name_text = std.mem.trim(u8, expr_text[0..lparen], " \t");
                        const args_text = std.mem.trim(u8, expr_text[lparen + 1 .. expr_text.len - 1], " \t");
                        var args_buf: [16]ast.Expr = undefined;
                        var arg_count: usize = 0;
                        var seg_start: usize = 0;
                        {
                            var depth: usize = 0;
                            var pos: usize = 0;
                            while (pos <= args_text.len) : (pos += 1) {
                                if (pos == args_text.len or (args_text[pos] == ',' and depth == 0)) {
                                    var seg_end = pos;
                                    while (seg_start < seg_end and (args_text[seg_start] == ' ' or args_text[seg_start] == '\t')) seg_start += 1;
                                    while (seg_end > seg_start and (args_text[seg_end - 1] == ' ' or args_text[seg_end - 1] == '\t')) seg_end -= 1;
                                    if (seg_end > seg_start) {
                                        const seg = args_text[seg_start..seg_end];
                                        var is_int = seg.len > 0;
                                        for (seg) |c| {
                                            if (c < '0' or c > '9') is_int = false;
                                        }
                                        if (is_int) {
                                            args_buf[arg_count] = Expr{ .payload = .{ .int_lit = seg }, .loc = start_loc };
                                        } else {
                                            args_buf[arg_count] = Expr{ .payload = .{ .ident = seg }, .loc = start_loc };
                                        }
                                        arg_count += 1;
                                    }
                                    seg_start = pos + 1;
                                } else {
                                    const c = args_text[pos];
                                    if (c == '(' or c == '[' or c == '{') depth += 1;
                                    if (c == ')' or c == ']' or c == '}') {
                                        if (depth > 0) depth -= 1;
                                    }
                                }
                            }
                        }
                        // Zero-arg calls (`{list.len()}`) build too —
                        // the empty args slice keeps the `.call` shape
                        // so the codegen's dotted-call dispatch can
                        // route generic instances (`list.len()` →
                        // ArrayList_len(i32, &list)). The `name_text`
                        // guard alone separates `{x}` (no parens, stays
                        // ident) from `{x()}`.
                        if (name_text.len > 0) {
                            const args_arena = self.arena.alloc(ast.Expr, arg_count);
                            @memcpy(args_arena, args_buf[0..arg_count]);
                            build_expr = Expr{ .payload = .{ .call = .{ .name = name_text, .args = args_arena } }, .loc = start_loc };
                        }
                    }
                }
                parts_buf[part_count] = .{
                    .literal = null,
                    .expr = build_expr,
                    .spec = if (has_spec) raw[spec_start..end_i] else null,
                };
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
        return Expr{ .payload = .{ .template_lit = .{ .parts = parts } }, .loc = start_loc };
    }


pub fn parseArrayLit(self: *Parser) Expr {
        const start_loc = self.peek().loc;
        self.expect(.lbracket);
        // The size literal follows.
        const size_tok = self.peek();
        // Phase 3 followup closure: also accept `.identifier` for the
        // size slot so `var out = [N]T { val ... };` (where `N` is a
        // `comptime N: usize` const-param from the surrounding fun
        // signature) parses through zig's own comptime monomorphization
        // path. The literal-only case (`.integer_literal`) keeps the
        // pre-Phase-3 surface intact. A future zag source with computed
        // sizes (e.g. `[N + 1]`) is still rejected here — it's outside
        // this commit's scope but the user's docs/16 §4 surface is
        // covered (the bracket-identifier form).
        if (size_tok.tag != .integer_literal and size_tok.tag != .identifier) {
            // Reviewer-polish (Phase 3): the gate accepts ANY `.identifier`
            // (the size slot isn't constrained to const-param declarations
            // specifically — zig's comptime resolution handles the
            // identifier-sized array surface uniformly). The previous
            // "const-param identifier" framing misled users when they
            // reached for a regular identifier. Purely cosmetic; the
            // parse-time acceptance hasn't changed.
            std.debug.print("error:{d}:{d}: expected integer literal or identifier for array size, got '{s}'\n", .{
                size_tok.loc.line, size_tok.loc.col, size_tok.text,
            });
            std.process.exit(1);
        }
        // Phase 3 followup: preserve verbatim size text on the identifier
        // branch so codegen can emit `** N` (comptime flow-through)
        // instead of `** 0` (silently-broken literal-walk fallback).
        // The literal branch leaves `size_text = null` and the digit-
        // walked `size: u32` is authoritative; `genArrayLit` prefers
        // `size_text orelse size` so the existing literal surface is
        // unchanged.
        var size: u32 = 0;
        var size_text: ?[]const u8 = null;
        if (size_tok.tag == .identifier) {
            size_text = size_tok.text;
        } else {
            for (size_tok.text) |c| {
                if (c >= '0' and c <= '9') {
                    size = size * 10 + @as(u32, c - '0');
                }
            }
        }
        self.advance();
        self.expect(.rbracket);
        // v1.5 multi-dim bracket loop (docs/10 \u00a7"Multi-Dim Arrays"):
        // accumulates additional `[K]` brackets before the type ident
        // so `[3][3]i32 { ... }` parses a 2-deep dim list. The loop
        // terminates when the next token is `.identifier`. `sizes[0]`
        // mirrors `size` for backward-compat; `sizes[1..]` are the
        // OUTER dim brackets emitted as a prefix in `genArrayLit`.
        // Identifier-size multi-dim (`[N][M]T`) is OUT of scope; the
        // dynamic dim-tok gate rejects with a Phase-3 deferral message
        // rather than silently misparsing.
        var sizes_buf: [8]u32 = undefined;
        sizes_buf[0] = size;
        var dim_count: usize = 1;
        while (self.peek().tag == .lbracket) {
            self.advance();
            const dim_tok = self.peek();
            if (dim_tok.tag != .integer_literal) {
                std.debug.print(
                    "error:{d}:{d}: multi-dim bracket must be integer literal (got '{s}'); identifier-size multi-dim deferred to Phase 3\n",
                    .{ dim_tok.loc.line, dim_tok.loc.col, dim_tok.text },
                );
                std.process.exit(1);
            }
            var dim: u32 = 0;
            for (dim_tok.text) |c| {
                if (c >= '0' and c <= '9') {
                    dim = dim * 10 + @as(u32, c - '0');
                }
            }
            sizes_buf[dim_count] = dim;
            dim_count += 1;
            self.advance();
            self.expect(.rbracket);
        }
        const sizes = if (dim_count > 1) blk: {
            const alloc = self.arena.alloc(u32, dim_count);
            @memcpy(alloc, sizes_buf[0..dim_count]);
            break :blk alloc;
        } else null;
        const type_name = self.expectIdent();
        self.expect(.lbrace);
        // A2 newline-skip (lands as separate per-topic commit from the
        // bracket-loop — see commit message for full rationale). Skip
        // leading newlines so the first non-newline peek is the first
        // element expr (or `}` for a zero-element array).
        self.skipNewlines();

        var elements_buf: [64]Expr = undefined;
        var element_count: usize = 0;

        // Allow `}` (zero-element explicit list) or at least one expression.
        if (self.peek().tag != .rbrace) {
            elements_buf[element_count] = self.parseExpr();
            element_count += 1;
            // Skip newlines between elements so `[N]i32 {
            //     1,
            //     2,
            //     3, }`
            // walks commas cleanly.
            self.skipNewlines();
            while (self.peek().tag == .comma) {
                self.advance();
                self.skipNewlines();
                // Trailing-comma escape: `[N]i32 { 1, 2, }` (comma
                // directly before `}`). Without this break the loop
                // would call parseExpr with peek = `}`.
                if (self.peek().tag == .rbrace) break;
                elements_buf[element_count] = self.parseExpr();
                element_count += 1;
                self.skipNewlines();
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

        // Skip trailing newlines before `}` so `1, 2, 3,
        // }` closes cleanly.
        self.skipNewlines();
        self.expect(.rbrace);
        const elements = self.arena.alloc(Expr, element_count);
        @memcpy(elements, elements_buf[0..element_count]);
        return Expr{ .payload = .{ .array_lit = .{
            .size = size,
            .size_text = size_text,
            .type_name = type_name,
            .elements = elements,
            .fill = fill,
            .progression = progression,
            .sizes = sizes,
        } }, .loc = start_loc };
    }


/// File-scope newline-skip helper used by `parseArrayLit`'s element-
/// collection loop. The zag lexer emits `.newline` tokens between
/// source lines, and the OUTER `parseArrayLit`'s body needs to skip
/// leading newlines after `{`, trailing newlines before `}`, and
/// inter-element newlines around commas. Without this helper,
/// `while (peek == .comma)` would skip an element whose first token
/// is `.newline` (since `.newline != .rbrace`, the prior
/// `if (peek != rbrace)` enters parseExpr — parsePrimary's default
/// arm consumes the newline, parsePostfix then misroutes the row's
/// leading `[` as postfix indexing, the OUTER's element becomes a
/// bizarre `.index(.ident, int_lit)`, and the OUTER's `expect(.rbrace)`
/// fires against the row's type ident). Defining here (NOT as a
/// `Parser` method) mirrors `looksLikeTemplateLiteral`'s file-scope
/// precedent in this same file; the helper is currently only used
/// inside `parseArrayLit`, so a cross-bucket re-export is premature.
/// Future widening (e.g., `parseStructLit`'s inline newline-skip in
/// the `{` walker) can promote this to `core.zig`'s Parser struct
/// once a second bucket needs it.
pub fn skipNewlines(self: *Parser) void {
    while (self.peek().tag == .newline) self.advance();
}


pub fn parseCallExpr(self: *Parser, name: []const u8) Expr {
        const start_loc = self.peek().loc;
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
        return Expr{ .payload = .{ .call = .{ .name = name, .args = args } }, .loc = start_loc };
    }


pub fn parseFree(self: *Parser) Expr {
        const start_loc = self.peek().loc;
        self.expect(.free);
        const target = self.parseExpr();
        const t = self.arena.alloc(Expr, 1);
        t[0] = target;
        return Expr{ .payload = .{ .free_expr = .{ .target = &t[0] } }, .loc = start_loc };
    }


pub fn parseNew(self: *Parser) Expr {
        const start_loc = self.peek().loc;
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
            return Expr{ .payload = .{ .new_expr = .{
                .type_name = type_name,
                .value = &v[0],
                .allocator = allocator,
            } }, .loc = start_loc };
        }
        // Simple form: `new T(value)` — global allocator (zig's
        // `std.heap.page_allocator`) is used at codegen.
        const type_name = self.expectIdent();
        self.expect(.lparen);
        const value = self.parseExpr();
        self.expect(.rparen);
        const v = self.arena.alloc(Expr, 1);
        v[0] = value;
        return Expr{ .payload = .{ .new_expr = .{ .type_name = type_name, .value = &v[0] } }, .loc = start_loc };
    }


pub fn parsePostfix(self: *Parser) Expr {
        var lhs = self.parsePrimary();
        const start_loc = lhs.loc;
        // Generics turbofish (docs/16 §"Turbofish"). Detected AT-IDENT
        // rather than in `parseComparison` because the grammar
        // distinguishes `name<T>(...)` (turbofish call) from
        // `a < b` (less-than comparison) by the IDENT-leading + `.lt`
        // shape followed by typename-or-constarg tokens + matching
        // `.gt` + closing `.lparen`. A 4-token lookahead (peek+1
        // `.lt`, scan to matching `.gt`, verify `.lparen` follows)
        // is enough to disambiguate without lexer changes. When the
        // shape holds, we collect turbofish args immediately so the
        // existing `.call(...)` recursive path can pick them up.
        if (lhs.payload == .ident and self.peek().tag == .lt) {
            const tps_start = self.pos;
            var depth: u32 = 1;
            var idx: u32 = 1;
            while (idx < self.tokens.len - tps_start and depth > 0) : (idx += 1) {
                switch (self.tokens[tps_start + idx].tag) {
                    .lt => depth += 1,
                    .gt => {
                        depth -= 1;
                        if (depth == 0) {
                            // Verify generic shape: the token AFTER the
                            // matching `.gt` is `.lparen` (a turbofish
                            // call `name<T>(...)`), `.lbrace` (a
                            // generic struct literal `Name<T> { ... }`,
                            // docs/16 §2), or `.dot` (a turbofish
                            // static-method call `Name<T>.method(...)` —
                            // the postfix chain picks up the method
                            // call on the turbofish-call lhs). If
                            // none, fall back to the non-turbofish
                            // path (the `a < b` form). The `.dot` case
                            // is gated on type-ish args (every
                            // identifier inside the brackets is
                            // PascalCase or a builtin type name) so
                            // `i < arr.len` keeps parsing as a
                            // comparison — `arr` is lowercase.
                            if (idx + 1 < self.tokens.len - tps_start) {
                                const after_tag = self.tokens[tps_start + idx + 1].tag;
                                var generic_ok = after_tag == .lparen or (after_tag == .lbrace and self.allow_struct_lit);
                                if (!generic_ok and after_tag == .dot) {
                                    generic_ok = true;
                                    var s: u32 = 1;
                                    while (s < idx) : (s += 1) {
                                        const it = self.tokens[tps_start + s].tag;
                                        if (it == .identifier) {
                                            const itext = self.tokens[tps_start + s].text;
                                            if (!self.isTypeishName(itext)) {
                                                generic_ok = false;
                                                break;
                                            }
                                        } else if (it != .integer_literal and it != .comma) {
                                            generic_ok = false;
                                            break;
                                        }
                                    }
                                }
                                if (generic_ok) {
                                const name = lhs.payload.ident;
                                // Generics turbofish chain followup (docs/16
                                // §\"Turbofish\"): the OUTER while-loop above
                                // walks tokens by INDEX (`self.tokens[tps_start
                                // + idx].tag`) without advancing self.pos, so
                                // by the time the success-branch fires self.pos
                                // is STILL at the leading `<`. parseTurbofishArgs'
                                // docblock requires \"Caller has verified the
                                // ident-`<`-typename-`>`-`(` shape and consumed
                                // the leading ident + `<`\" — so we self.advance()
                                // past `<` here to satisfy the contract. Without
                                // this advance, parseTurbofishArgs's first token
                                // check (`self.peek().tag == .identifier`) fails,
                                // falls through to collectCastType() (which makes
                                // no progress on the `<` token), and finally
                                // self.expect(.gt) reports `expected gt, got '<'`
                                // — the parse-time hole that left the turbofish
                                // call-site wrap in src/codegen/expr.zig's
                                // `.call` c.type_args loop on the
                                // `c.type_args, 0.. |ta, i|` arm unreachable
                                // from any v1 source until commit
                                // `fix(parser): advance past turbofish < before
                                // calling parseTurbofishArgs` (this commit)
                                // closed the gap. Mirrors parseFunDecl's
                                // bracketed-generic call to parseTypeParams
                                // (which already self.expect(.lt)s the leading
                                // `<` on entry per its docblock's caller
                                // contract) — the turbofish call-site path now
                                // matches that precedent. After
                                // parseTurbofishArgs returns, self.pos is past
                                // `>` because its final `self.expect(.gt)`
                                // consumed it, which is why the
                                // `self.expect(.lparen)` immediately below
                                // sees the verified-precondition `.lparen`
                                // token without re-scanning.
                                self.advance();
                                const tps_args = self.parseTurbofishArgs();
                                if (after_tag == .lparen) {
                                self.expect(.lparen);
                                var call_args_buf: [16]Expr = undefined;
                                var call_arg_count: usize = 0;
                                if (self.peek().tag != .rparen) {
                                    const prev = self.allow_struct_lit;
                                    self.allow_struct_lit = false;
                                    defer self.allow_struct_lit = prev;
                                    call_args_buf[call_arg_count] = self.parseExpr();
                                    call_arg_count += 1;
                                    while (self.peek().tag == .comma) {
                                        self.advance();
                                        call_args_buf[call_arg_count] = self.parseExpr();
                                        call_arg_count += 1;
                                    }
                                }
                                self.expect(.rparen);
                                const args_arena = self.arena.alloc(Expr, call_arg_count);
                                @memcpy(args_arena, call_args_buf[0..call_arg_count]);
                                lhs = Expr{ .payload = .{ .call = .{ .name = name, .args = args_arena, .type_args = tps_args } }, .loc = start_loc };
                                } else if (after_tag == .dot) {
                                    // Turbofish static-method chain
                                    // `Name<T>.method(...)`: build the
                                    // argless turbofish call (type args
                                    // only) and let the postfix chain
                                    // pick up `.method(...)`.
                                    const empty_args = self.arena.alloc(Expr, 0);
                                    lhs = Expr{ .payload = .{ .call = .{ .name = name, .args = empty_args, .type_args = tps_args } }, .loc = start_loc };
                                } else {
                                    // Generic struct literal — the
                                    // `<...>` slot is the type args; the
                                    // `{...}` that follows is the field
                                    // init list (parseStructLitWithArgs
                                    // consumes the opening `{` itself).
                                    lhs = self.parseStructLitWithArgs(name, tps_args);
                                }
                                // Continue the postfix chain so things like
                                // `max<i32>(3,5)[0]` or `max<i32>(3,5).field`
                                // continue parsing. The fragment below is
                                // a fallback hook so the postfix chain
                                // continues.
                                continue;
                            }
                            break;
                        }
                    }
                    },
                    else => {},
                }
            }
        }
        // The postfix chain interleaves three shapes:
        //   - `?` (postfix try/unwrap) → `.try_op`
        //   - `[start..end]` (or single-index or no-bound variants) → `.index` / `.slice`
        //   - `.name` (no parens) → `.member_access` | `.name(args...)` → `.method_call`
        // Both shapes are checked in this single `while` so chains like
        // `arr[i].len`, `(getBox()).field`, `obj.method().chain` interleave
        // naturally — each iteration of the loop consumes one postfix
        // token and re-emits `lhs` with the wrapping applied.
        while (true) {
            // Postfix `?` (try/unwrap operator): `expr?` unwraps
            // Result<T,E> or Option<T>, early-returning on error/None.
            if (self.peek().tag == .question) {
                const target_buf = self.arena.alloc(Expr, 1);
                target_buf[0] = lhs;
                lhs = Expr{ .payload = .{ .try_op = .{ .expr = &target_buf[0] } }, .loc = start_loc };
                self.advance();
                continue;
            }
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
                        lhs = Expr{ .payload = .{ .index = .{ .target = &target_buf[0], .index = &idx_buf[0] } }, .loc = start_loc };
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
                lhs = Expr{ .payload = .{ .slice = .{ .target = &target_buf[0], .start = start_opt, .end = end_opt, .inclusive = inclusive } }, .loc = start_loc };
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
                    lhs = Expr{ .payload = .{ .method_call = .{ .target = &target_buf[0], .name = name, .args = args } }, .loc = start_loc };
                } else if (self.peek().tag == .lt) {
                    // Method-call turbofish (Phase 3 trait dispatch,
                    // docs/17 §"Using Traits"). The `.lt` token after
                    // `.name` could be a turbofish start (`obj.draw<T>(a)`)
                    // OR a comparison (`argv.len < 3`). Disambiguate with
                    // the same depth+paren lookahead as the `.ident`
                    // branch's call turbofish gate: walk the remaining
                    // token stream tracking nested `<...>`, and on
                    // matching the closing `>` verify that `.lparen`
                    // follows. If not, fall through unchanged so
                    // parseComparison picks up the `<`. Mirrors the
                    // `.call` turbofish surface (parsePrimary's ident
                    // path) but applied to `.method_call` so the
                    // dispatch shim's `comptime T: type` resolves at
                    // the call site to the registered source-type —
                    // `d.draw<Button>()` emits `d.draw(Button)` which
                    // binds Button to the shim's `T` placeholder, and
                    // the shim body discards T (the `_ = T;` in
                    // `genTraitDecl`) and forwards to the vtable slot.
                    const tps_start = self.pos;
                    var depth: u32 = 1;
                    var idx: u32 = 1;
                    var is_turbo: bool = false;
                    while (idx < self.tokens.len - tps_start and depth > 0) : (idx += 1) {
                        switch (self.tokens[tps_start + idx].tag) {
                            .lt => depth += 1,
                            .gt => {
                                depth -= 1;
                                if (depth == 0) {
                                    if (idx + 1 < self.tokens.len - tps_start and self.tokens[tps_start + idx + 1].tag == .lparen) {
                                        is_turbo = true;
                                    }
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                    if (is_turbo) {
                        self.advance(); // consume leading `<`
                        const mc_type_args = self.parseTurbofishArgs();
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
                        const ta_args = self.arena.alloc(Expr, arg_count);
                        @memcpy(ta_args, args_buf[0..arg_count]);
                        const ta_target_buf = self.arena.alloc(Expr, 1);
                        ta_target_buf[0] = lhs;
                        lhs = Expr{ .payload = .{ .method_call = .{ .target = &ta_target_buf[0], .name = name, .args = ta_args, .type_args = mc_type_args } }, .loc = start_loc };
                    } else {
                        // Fall-through: `.name <` is a property access
                        // followed by a binary operator — NOT a
                        // turbofish start (the paren-after-gt
                        // discriminator in the lookahead above
                        // already rejected it). Construct the
                        // `.member_access` node so the property name
                        // is NOT silently dropped on the floor. Pre-fix
                        // the `if (is_turbo)` block had no `else`,
                        // so `argv.len < 2` parsed as `argv < 2` and
                        // zig rejected the generated source with
                        // `incompatible types: '[]const []const u8'
                        // and 'comptime_int'` because the slice was
                        // compared to a literal without `.len` first.
                        // Same code as the outer `else` arm below; the
                        // duplication is the cost of the nested-if
                        // structure that pre-dates this fix.
                        const target_buf = self.arena.alloc(Expr, 1);
                        target_buf[0] = lhs;
                        lhs = Expr{ .payload = .{ .member_access = .{ .target = &target_buf[0], .name = name } }, .loc = start_loc };
                    }
                } else {
                    // Property-access form: `.name` (no parens). Codegen
                    // emits `<target>.<name>` verbatim — the user-facing
                    // form on `v.x` is identical to zig's struct-field-
                    // access syntax so no special conversion is needed.
                    const target_buf = self.arena.alloc(Expr, 1);
                    target_buf[0] = lhs;
                    lhs = Expr{ .payload = .{ .member_access = .{ .target = &target_buf[0], .name = name } }, .loc = start_loc };
                }
                continue;
            }
            break;
        }
        return lhs;
    }


/// Template-literal auto-promotion gate. The `.string_literal` arm
/// of `parsePrimary` consults this before deciding between `.string_lit`
/// (plain string) and `.template_lit` (interpolated).
///
/// This is a MATCHING-BRACE gate: for each `{` it walks forward to the
/// matching `}` at the same brace depth, accepting ANY content inside
/// (dots, spaces, operators, parens, slashes) so expressions like
/// `{a + b}`, `{obj.f()}`, `{pi:.5}` auto-promote to `.template_lit`.
///
/// The content-level rejections are:
///   1. NESTED `{` inside the candidate `{...}` — embedded code with
///      its own brace pair (e.g. a JSON object).
///   2. `;` (semicolon) inside the candidate — statement separator;
///      template interpolations are EXPRESSIONS, not statements. This
///      catches the cli.zag boilerplate
///      `"fun main() {\n    print(...);\n}\n"` which has
///      `{ print(...); }` (a statement, not an expression) and was
///      wrongly auto-promoted by the f559cf3 matching-brace gate.
///      The legacy char-class gate achieved the same rejection
///      indirectly by bailing on `;` (non-alphanumeric); the
///      matching-brace gate needs an explicit `;` check because the
///      inner `print(...)` parens are not braces, so the nested-`{`
///      path doesn't fire.
/// The legacy char-class gate (`isAlphanumeric || _ || :`) caught
/// BOTH rejections (nested-`{` indirectly via non-alphanumeric
/// characters; `;` directly) but at the cost of also rejecting
/// legitimate expression interpolations (`{a + b}`'s space + `+`,
/// `{pi:.5}`'s `.`, `{obj.f()}`'s `.` + `(`). The matching-brace
/// gate unblocks those 3 patterns while the `;` check keeps the
/// embedded-code strings as `.string_lit`.
///
/// Trade-offs vs. the legacy gate: accepts expression content
/// (operators, dots, parens, method calls); rejects only nested
/// braces. The `buildTemplate` walker stores the inner text as
/// `.ident` and codegen's `.ident` arm emits it verbatim, so any
/// expression-shaped content becomes a valid Zig expression at the
/// format-arg site.
///
/// Returns true iff AT LEAST ONE well-formed `{...}` exists AND none
/// of them have nested braces. A string with no `{` returns false so
/// the caller keeps it as `.string_lit` (preserves the legacy
/// no-brace-stays-string invariant).
fn looksLikeTemplateLiteral(text: []const u8) bool {
    var any_braces = false;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            any_braces = true;
            i += 1;
            // Scan for the matching `}` at the SAME brace depth. A
            // nested `{` before the matching `}` disqualifies this
            // string as a template — it's embedded code (function
            // body, JSON object, etc.), not an interpolation. A
            // `;` (semicolon) before the matching `}` also
            // disqualifies — template interpolations are
            // EXPRESSIONS, not statements. Any other content
            // (dots, spaces, operators, parens) is fine because
            // the .ident verbatim-emit at codegen will produce a
            // valid Zig expression.
            var found_close = false;
            while (i < text.len) {
                const c = text[i];
                if (c == '{') {
                    // Nested brace — embedded code, not a template
                    // interpolation. The legacy char-class gate
                    // achieved the same rejection indirectly (the
                    // nested `{` is non-alphanumeric so the gate
                    // bailed), but this explicit check is clearer
                    // about WHY we reject and accepts all the
                    // expression-content cases the legacy gate
                    // blocked.
                    return false;
                }
                if (c == ';') {
                    // Statement separator — template interpolations
                    // are expressions, so a `;` inside `{...}` is
                    // a strong signal of embedded code. The
                    // canonical case is the cli.zag boilerplate
                    // `"fun main() {\n    print(\"hello, world\\n\");\n}\n"`
                    // whose `{ print(...); }` is a statement (not
                    // an expression) and was wrongly auto-promoted
                    // by the f559cf3 matching-brace gate. The
                    // legacy char-class gate caught this
                    // indirectly (`;` is non-alphanumeric); the
                    // matching-brace gate needs this explicit check
                    // because the inner `print(...)` parens are
                    // NOT braces, so the nested-`{` path above
                    // doesn't fire for the boilerplate.
                    return false;
                }
                if (c == '}') {
                    found_close = true;
                    i += 1;
                    break;
                }
                i += 1;
            }
            if (!found_close) return false; // unmatched '{' — not a template
        } else {
            i += 1;
        }
    }
    // Auto-promote only when at least one well-formed `{...}` exists;
    // a string with no braces stays a string literal. Same return
    // semantics as the legacy gate (the old char-class implementation
    // also returned `any_braces` here).
    return any_braces;
}


pub fn parsePrimary(self: *Parser) Expr {
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
                // Qualified enum-variant constructor `Enum.Variant(...)` or
                // bare `Enum.Variant` (no-args form, docs/manual/13).
                // Conservative gate: only enable the QUALIFIED form
                // because the unqualified `Variant(args)` shape is
                // ambiguous between variant-construction and
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
                //
                // The gate accepts BOTH the parened form `Enum.Variant(args)`
                // AND the unparened `Enum.Variant` (no-args variant
                // constructor — matches the test `parser: qualified
                // enum-variant-ctor expression with no args` and the
                // idiomatic Rust shape `Direction::North` translated to
                // zag's `.`-style namespace). Token-economy check: after
                // consuming the enum-name ident via the outer arm, peek
                // `.dot` and then an ident with uppercase leading
                // letter. We do NOT require `.lparen` at peek+2 -- the
                // no-args form terminates after the variant name itself
                // (peek could be `;`, `,`, `.` for chained access, EOF,
                // or any other terminator). Both branches produce
                // `Expr.enum_variant_ctor` because that's the parser's
                // surfacing of the syntactic constructor form; semantic
                // validation lands downstream in zig's type-checker once
                // codegen emits the verbatim `Enum.Variant` or
                // `Enum{ .Variant = ... }` form.
                //
                // `.new` (reserved keyword) is excluded by the
                // `tokens[pos + 1].tag == .identifier` gate -- the
                // lexer emits `.new` as a single TokenTag, not
                // `.identifier`, so `Vec3.new(...)` (a method-call on
                // Vec3) keeps its postfix chain route through
                // `parsePostfix`'s `.dot` dispatch. Same carve-out for
                // any future reserved method-name keywords (`.init`,
                // `.deinit`, etc.).
                if (tok.tag == .identifier and name.len > 0 and name[0] >= 'A' and name[0] <= 'Z' and
                    self.pos + 1 < self.tokens.len and
                    self.tokens[self.pos].tag == .dot and
                    self.tokens[self.pos + 1].tag == .identifier and
                    self.tokens[self.pos + 1].text.len > 0 and
                    self.tokens[self.pos + 1].text[0] >= 'A' and
                    self.tokens[self.pos + 1].text[0] <= 'Z')
                {
                    const variant_name = self.tokens[self.pos + 1].text;
                    self.expect(.dot);
                    _ = self.expectIdent();
                    if (self.peek().tag == .lparen) {
                        // With-args form: `Direction.North(2.5)` —
                        // args are comma-separated Exprs parsed via
                        // `parseExpr`, same convention as method-call
                        // and tuple-literal. Mirrors the args-parsing
                        // block in `parseCallExpr` above.
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
                        return Expr{ .payload = .{ .enum_variant_ctor = .{
                            .enum_name = name,
                            .variant_name = variant_name,
                            .args = args,
                        } }, .loc = tok.loc };
                    }
                    // No-args form: `Direction.North` — the variant
                    // ctor with no payload. Peek after the variant name
                    // is some terminator (`.` for chained access,
                    // `;`/`,`/`)`/`]` for end-of-statement, EOF, etc.)
                    // but NOT `.lparen`. Mirrors the docs/13 surface
                    // for payload-less variants; codegen forwards
                    // `Enum.Variant` verbatim and lets zig's type
                    // checker thread through the inferred enum-name
                    // surface (the same forwarding strategy as the
                    // with-args branch).
                    const args = self.arena.alloc(Expr, 0);
                    return Expr{ .payload = .{ .enum_variant_ctor = .{
                        .enum_name = name,
                        .variant_name = variant_name,
                        .args = args,
                    } }, .loc = tok.loc };
                }
                if (self.peek().tag == .lparen) {
                    return self.parseCallExpr(name);
                } else if (self.peek().tag == .lbrace and self.allow_struct_lit and
                    name.len > 0 and name[0] >= 'A' and name[0] <= 'Z' and
                    !self.isKnownStruct(name) and self.isKnownVariant(name))
                {
                    // Gap #2 closure (docs/manual/14-unions §Mixed Bare +
                    // Payload): unqualified brace ctor when `T` matches a
                    // registered variant name. Routes to a new
                    // `.enum_variant_ctor { enum_name = null,
                    // variant_name, args = ... }` AST node so the codegen's
                    // `lookupVariantFieldsByName` helper in
                    // src/codegen/core.zig can recover the brace-fields
                    // list and emit `.{ .Variant = .{ .f1 = v1, .f2 = v2 } }`
                    // Source-order requirement: the union/enum decl must
                    // come BEFORE the function body that references the
                    // variant (the parser tracks variant names by appending
                    // on decl completion, so a forward reference would
                    // miss the lookup and fall through to the struct-lit
                    // arm below — loud zig-side error rather than silent
                    // miscompile). The `isKnownVariant(name) == true` gate
                    // is the disambiguation contract; bare variants and
                    // paren-positional variants are not registered
                    // (filter in parseEnumDecl/parseUnionDecl registration
                    // hook), so `Bare { x: 1 }` for a bare `Bare` falls
                    // through to `.struct_lit` as before.
                    return self.parseEnumVariantCtorBrace(name);
                } else if (self.peek().tag == .lbrace and self.allow_struct_lit and
                    ((name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') or self.isSimdTypeName(name)))
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
                    //   SIMD vector names (`f32x4 { ... }` —
                    //      docs/manual/24 §"SIMD Literals") start
                    //      lowercase but are first-class type spellings;
                    //      `isSimdTypeName`'s digit-`x`-digit shape is
                    //      the disambiguation contract (see its docblock
                    //      in src/parser/core.zig).
                    return self.parseStructLit(name);
                } else {
                    return Expr{ .payload = .{ .ident = name }, .loc = tok.loc };
                }
            },
            .string_literal => {
                self.advance();
                // Template-literal auto-promotion gate. The
                // `looksLikeTemplateLiteral` helper is a matching-brace
                // gate: it walks each `{...}` and accepts any content
                // (dots, spaces, operators, parens) so expression-shaped
                // interpolations like `{pi:.5}`, `{a + b}`, `{obj.f()}`
                // auto-promote to `.template_lit`. The single content
                // rejection is a NESTED `{` inside the candidate — that
                // keeps embedded-code strings (function bodies, JSON
                // objects, etc.) as `.string_lit`. See
                // `looksLikeTemplateLiteral`'s docblock for the full
                // rationale and edge cases.
                if (looksLikeTemplateLiteral(tok.text)) {
                    return self.buildTemplate(tok.text, tok.loc);
                }
                return Expr{ .payload = .{ .string_lit = tok.text }, .loc = tok.loc };
            },
            .byte_string_literal => {
                self.advance();
                return Expr{ .payload = .{ .byte_string_lit = tok.text }, .loc = tok.loc };
            },
            .char_literal => {
                self.advance();
                return Expr{ .payload = .{ .char_lit = tok.text }, .loc = tok.loc };
            },
            .integer_literal => {
                self.advance();
                return Expr{ .payload = .{ .int_lit = tok.text }, .loc = tok.loc };
            },
            .float_literal => {
                self.advance();
                return Expr{ .payload = .{ .float_lit = tok.text }, .loc = tok.loc };
            },
            .true_kw => {
                self.advance();
                return Expr{ .payload = .{ .bool_lit = true }, .loc = tok.loc };
            },
            .false_kw => {
                self.advance();
                return Expr{ .payload = .{ .bool_lit = false }, .loc = tok.loc };
            },
            .null_kw => {
                self.advance();
                return Expr{ .payload = .{ .null_lit = {} }, .loc = tok.loc };
            },
            .const_kw => {
                // `const { stmts; return expr; }` — compile-time block
                self.advance();
                self.expect(.lbrace);
                const body = self.parseStmtList();
                self.expect(.rbrace);
                return Expr{ .payload = .{ .const_block = body }, .loc = tok.loc };
            },
            .await_kw => {
                // `await EXPR` (docs/manual/00-overview.md "Zero-cost
                // async"): suspends until the awaited Future<T>
                // completes. v1 lowering is the inline-drive form
                // (the callee's async body runs eagerly), so the
                // operand is parsed as a normal expression and the
                // codegen's .await_expr arm emits the drive + unwrap.
                self.advance();
                const operand = self.parseExpr();
                const operand_buf = self.arena.alloc(Expr, 1);
                operand_buf[0] = operand;
                return Expr{ .payload = .{ .await_expr = .{ .expr = &operand_buf[0] } }, .loc = tok.loc };
            },
            .asm_kw => {
                // Inline assembly (docs/manual/24-simd.md §"Inline
                // Assembly"): `asm { ("tpl" : {dst} = "=x"(out) :
                // {src} = "x"(a), {acc} = "x"(b) : ) }`. The
                // parenthesised spec has up to four `:`-separated
                // sections after the template string: outputs,
                // inputs, clobbers (positional; empty sections are
                // allowed and skipped). Output/input bindings are
                // `{name} = "constraint"(expr)`; clobbers are bare
                // `"memory"`-style strings. Sections beyond the
                // third are rejected (zig's asm has no options
                // section in v1 of this surface).
                self.advance();
                self.expect(.lbrace);
                while (self.peek().tag == .newline) self.advance();
                self.expect(.lparen);
                while (self.peek().tag == .newline) self.advance();
                const template = self.expectStringLiteral();
                var outputs_buf: [8]ast.AsmOperand = undefined;
                var outputs_count: usize = 0;
                var inputs_buf: [8]ast.AsmOperand = undefined;
                var inputs_count: usize = 0;
                var clobbers_buf: [8][]const u8 = undefined;
                var clobbers_count: usize = 0;
                var section: usize = 0;
                while (true) {
                    while (self.peek().tag == .newline) self.advance();
                    if (self.peek().tag != .colon) break;
                    self.advance();
                    section += 1;
                    if (section > 3) {
                        std.debug.print("error:{d}:{d}: asm: too many ':' sections (template : outputs : inputs : clobbers)\n", .{ tok.loc.line, tok.loc.col });
                        std.process.exit(1);
                    }
                    // Empty section (`: :` adjacency or trailing `:`).
                    if (self.peek().tag == .colon or self.peek().tag == .rparen) continue;
                    while (self.peek().tag != .colon and self.peek().tag != .rparen and !self.eof()) {
                        if (self.peek().tag == .newline or self.peek().tag == .comma) {
                            self.advance();
                            continue;
                        }
                        if (section <= 2) {
                            // `{name} = "constraint"(expr)` binding.
                            self.expect(.lbrace);
                            const name = self.expectIdent();
                            self.expect(.rbrace);
                            self.expect(.equals);
                            const constraint = self.expectStringLiteral();
                            self.expect(.lparen);
                            const value = self.parseExpr();
                            self.expect(.rparen);
                            const value_buf = self.arena.alloc(Expr, 1);
                            value_buf[0] = value;
                            const op = ast.AsmOperand{ .name = name, .constraint = constraint, .expr = &value_buf[0] };
                            if (section == 1) {
                                if (outputs_count < outputs_buf.len) {
                                    outputs_buf[outputs_count] = op;
                                    outputs_count += 1;
                                }
                            } else {
                                if (inputs_count < inputs_buf.len) {
                                    inputs_buf[inputs_count] = op;
                                    inputs_count += 1;
                                }
                            }
                        } else {
                            // Clobber string.
                            const clobber = self.expectStringLiteral();
                            if (clobbers_count < clobbers_buf.len) {
                                clobbers_buf[clobbers_count] = clobber;
                                clobbers_count += 1;
                            }
                        }
                    }
                }
                while (self.peek().tag == .newline) self.advance();
                self.expect(.rparen);
                while (self.peek().tag == .newline) self.advance();
                self.expect(.rbrace);
                const outputs = self.arena.alloc(ast.AsmOperand, outputs_count);
                @memcpy(outputs, outputs_buf[0..outputs_count]);
                const inputs = self.arena.alloc(ast.AsmOperand, inputs_count);
                @memcpy(inputs, inputs_buf[0..inputs_count]);
                const clobbers = self.arena.alloc([]const u8, clobbers_count);
                @memcpy(clobbers, clobbers_buf[0..clobbers_count]);
                return Expr{ .payload = .{ .asm_expr = .{
                    .template = template,
                    .outputs = outputs,
                    .inputs = inputs,
                    .clobbers = clobbers,
                } }, .loc = tok.loc };
            },
            .undefined_kw => {
                self.advance();
                return Expr{ .payload = .{ .undefined_lit = {} }, .loc = tok.loc };
            },
            .lbrace => {
                // `{ ... }` in expression position is either a BLOCK
                // expression (statements) or a BARE ARRAY literal
                // (docs/manual/10 §"Inferred-element arrays"): the
                // element type comes from the expected type, so the
                // LHS annotation is not repeated — `let numbers:
                // [5]i32 = { 10, 20, 30, 40, 50 };` instead of
                // `[5]i32 { ... }`. Codegen emits `.{ ... }` (zig's
                // anonymous-struct literal) which coerces to the
                // expected array/slice/tuple type. Disambiguation by
                // pre-scan: between the braces, a top-level `;` or
                // statement keyword means BLOCK; otherwise a
                // top-level `,` means BARE ARRAY. A single expression
                // with no comma (`{ expr }`) stays a block (the
                // existing labeled-block value form).
                const is_bare_array = blk: {
                    var depth: usize = 0;
                    var saw_comma = false;
                    var i = self.pos + 1;
                    while (i < self.tokens.len) : (i += 1) {
                        const t = self.tokens[i].tag;
                        if (t == .lbrace or t == .lparen or t == .lbracket) {
                            depth += 1;
                        } else if (t == .rbrace or t == .rparen or t == .rbracket) {
                            if (depth == 0) break;
                            depth -= 1;
                        } else if (depth == 0) {
                            if (t == .comma) {
                                saw_comma = true;
                            } else switch (t) {
                                // Statement-leading keywords mean
                                // BLOCK (note: `;` is not a token —
                                // the lexer drops it — so keyword
                                // detection is the discriminator).
                                .let, .var_kw, .const_kw, .if_kw, .while_kw, .for_kw,
                                .match_kw, .return_kw, .break_kw, .continue_kw,
                                .unsafe_kw, .defer_kw, .errdefer_kw, .asm_kw,
                                .doc_comment,
                                => break :blk false,
                                else => {},
                            }
                        }
                    }
                    break :blk saw_comma;
                };
                if (is_bare_array) {
                    self.advance(); // consume `{`
                    var elem_buf: [16]ast.Expr = undefined;
                    var elem_count: usize = 0;
                    while (self.peek().tag != .rbrace and !self.eof()) {
                        if (self.peek().tag == .newline or self.peek().tag == .comma) {
                            self.advance();
                            continue;
                        }
                        if (elem_count < elem_buf.len) {
                            elem_buf[elem_count] = self.parseExpr();
                            elem_count += 1;
                        } else {
                            _ = self.parseExpr();
                        }
                    }
                    self.expect(.rbrace);
                    const elements = self.arena.alloc(ast.Expr, elem_count);
                    @memcpy(elements, elem_buf[0..elem_count]);
                    // Empty type_name marks the bare form; size 0
                    // (unused — codegen emits `.{ ... }`).
                    return Expr{ .payload = .{ .array_lit = .{
                        .size = 0,
                        .size_text = null,
                        .type_name = "",
                        .elements = elements,
                        .fill = false,
                        .progression = false,
                    } }, .loc = tok.loc };
                }
                self.advance();
                const body = self.parseStmtList();
                self.expect(.rbrace);
                // Return raw block expression — codegen wraps in a
                // labeled block to produce the final value.
                return Expr{ .payload = .{ .block_expr = body }, .loc = tok.loc };
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
                return Expr{ .payload = .{ .deref = .{ .target_ptr = &t[0] } }, .loc = tok.loc };
            },
            .lparen => {
                self.advance();
                // Empty tuple: ()
                if (self.peek().tag == .rparen) {
                    self.advance();
                    const elements = self.arena.alloc(Expr, 0);
                    return Expr{ .payload = .{ .tuple_lit = elements }, .loc = tok.loc };
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
                    return Expr{ .payload = .{ .named_tuple_lit = .{ .names = names_alloc, .elements = elements_alloc } }, .loc = tok.loc };
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
                        return Expr{ .payload = .{ .single_tuple_lit = &single[0] }, .loc = tok.loc };
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
                    return Expr{ .payload = .{ .tuple_lit = elements }, .loc = tok.loc };
                }
                self.expect(.rparen);
                return elements_buf[0];
            },
            else => {
                self.advance();
                return Expr{ .payload = .{ .ident = tok.text }, .loc = tok.loc };
            },
        }
    }


pub fn parseStructLit(self: *Parser, type_name: []const u8) Expr {
        return self.parseStructLitWithArgs(type_name, &[_][]const u8{});
    }

pub fn parseStructLitWithArgs(self: *Parser, type_name: []const u8, type_args: []const []const u8) Expr {
        const start_loc = self.peek().loc;
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
            // Positional-value slots (`f32x4 { 1.0, 2.0, ... }` —
            // docs/manual/24-simd.md §"SIMD Literals") vs the named
            // `f: v` form. The field name is the empty string for
            // positional slots; codegen emits the positional
            // `Type{ v1, v2 }` shape when every slot is positional
            // (a regular struct literal with positional values would
            // emit invalid zig, but the shape only occurs for SIMD
            // vector types today — the parser does not type-check).
            // Detection: a `name:` pair has an identifier followed
            // by a colon; anything else is a positional value.
            const is_named = self.peek().tag == .identifier and self.peekAhead(1) == .colon;
            if (is_named) {
                const field_name = self.expectIdent();
                self.expect(.colon);
                const value = self.parseExpr();
                const value_buf = self.arena.alloc(Expr, 1);
                value_buf[0] = value;
                inits_buf[init_count] = .{ .name = field_name, .value = &value_buf[0] };
                init_count += 1;
            } else {
                const value = self.parseExpr();
                const value_buf = self.arena.alloc(Expr, 1);
                value_buf[0] = value;
                inits_buf[init_count] = .{ .name = "", .value = &value_buf[0] };
                init_count += 1;
            }
        }
        self.expect(.rbrace);
        const inits = self.arena.alloc(ast.Expr.FieldInit, init_count);
        @memcpy(inits, inits_buf[0..init_count]);
        return Expr{ .payload = .{ .struct_lit = .{ .type_name = type_name, .type_args = type_args, .inits = inits } }, .loc = start_loc };
    }


/// Gap #2 closure (docs/manual/14-unions §Mixed Bare + Payload) ctor
/// parser: parses `Variant { f1: v1, f2: v2, ... }` into an
/// `Expr.enum_variant_ctor { enum_name = null, variant_name,
/// args = [v1, v2, ...] }` AST node. Called from parsePrimary's
/// `.identifier` arm when the leading ident matches a registered
/// variant name (registered via parseEnumDecl / parseUnionDecl's
/// `known_variant_names` table push hooks).
///
/// The `args` slice is captured POSITIONAL in declaration order so
/// the codegen's `lookupVariantFieldsByName` helper can pair
/// `args[i]` with `brace_fields[i].name` recovered from the variant's
/// decl. The source-side field names in each `{f: v}` slot are
/// discarded here — they MUST match the variant decl's brace-field
/// ordering for the round-trip to emit `.{ .f = v }` in field order.
/// (A future Phase could verify the source-side names against the decl
/// for stronger error reporting, but v1's conservative contract is
/// positional-order rather than name-order.)
///
/// Mirrors the parseStructLit walker pattern verbatim (newline + comma
/// skipping inside `{...}`, single ident + colon + expr per slot)
/// but builds the variant-ctor AST node instead of struct-lit's. The
/// 16-slot cap matches parseStructLit's `inits_buf` for symmetry.
pub fn parseEnumVariantCtorBrace(self: *Parser, variant_name: []const u8) Expr {
    const start_loc = self.peek().loc;
    // BLOCKING #1 fix (gap #2 closure): reject EMPTY brace `Variant {}` on a
    // brace-named-field variant because codegen iterates `fields` and reads
    // from args by positional index — an empty args list would segfault.
    if (self.peek().tag == .rbrace) {
        std.debug.print("error:{d}:{d}: variant `{s}` requires named-field slots; got empty brace\n", .{ self.peek().loc.line, self.peek().loc.col, variant_name });
        std.process.exit(1);
    }
    self.expect(.lbrace);
    var args_buf: [16]Expr = undefined;
    var arg_count: usize = 0;
    while (self.peek().tag != .rbrace and !self.eof()) {
        if (self.peek().tag == .newline) {
            self.advance();
            continue;
        }
        if (self.peek().tag == .comma) {
            self.advance();
            continue;
        }
        // Source-side field name is captured but DISCARDED — the
        // codegen lookup takes its field list from the variant decl
        // (via `Codegen.variant_fields_buf` populated by genEnumDecl),
        // so positional ordering is sufficient. A future Phase could
        // attach the field_name as a debug-only payload here, but
        // v1's contract doesn't carry it on the AST node.
        _ = self.expectIdent();
        self.expect(.colon);
        args_buf[arg_count] = self.parseExpr();
        arg_count += 1;
    }
    self.expect(.rbrace);
    const args = self.arena.alloc(Expr, arg_count);
    @memcpy(args, args_buf[0..arg_count]);
    return Expr{ .payload = .{ .enum_variant_ctor = .{
        .enum_name = null,
        .variant_name = variant_name,
        .args = args,
    } }, .loc = start_loc };
}

