const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;
const inferZigTypeFromExpr = @import("primary.zig").inferZigTypeFromExpr;
const getTopElements = @import("primary.zig").getTopElements;
// Cross-bucket alias-resolution import (docs/07 "Type Aliases",
// docs/11 borrowed-string-view). Same pattern as the
// `inferZigTypeFromExpr` / `getTopElements` imports above: a
// sibling-bucket helper made available by file-scope re-export
// rather than re-implementing. See `zagTypeToZig` in
// src/codegen/decl.zig for the alias set and the in-line-guard
// rationale. Used at the `b.type_name` emit sites (block-form
// compile-time binding + simple-path binding) so that
// `let s: str = ...;` / `const x: str = const { ... };` round-
// trip to `let s: []const u8 = ...;` / `const x: []const u8 =
// ...;` without zig ever seeing a bare `str` ident.
const zagTypeToZig = @import("decl.zig").zagTypeToZig;

// ============================================================
// FILE-SCOPE methods (STMT bucket)
// ============================================================

    pub     fn collectTypedBindings(self: *Codegen, stmt: ast.Stmt) void {
        const b: ast.Stmt.BindingStmt = switch (stmt.payload) {
            .let => stmt.payload.let,
            .var_binding => stmt.payload.var_binding,
            .const_binding => stmt.payload.const_binding,
            else => {
                // Recurse into block-carrying statements so bindings
                // declared inside nested bodies (while/for/if/match/
                // unsafe blocks) are visible to the cast carve-outs
                // (@floatCast / @intCast), which look up the operand
                // ident's source type in `type_info_buf`. Previously
                // only top-level fn-body bindings were recorded —
                // lib/std/fs.zag's `n_signed as usize` (declared
                // inside a while-loop body) fell through to the
                // `@as(usize, isize)` emit which zig 0.16 rejects
                // (Tier-1 migration).
                self.collectNestedBindings(stmt);
                return;
            },
        };
        if (b.pattern != null) {
            self.collectNestedBindings(stmt);
            return;
        }
        if (self.type_info_count >= self.type_info_buf.len) return;
        // Closure-typed binding — no `: T` annotation required.
        // Const-block bindings (`b.init == null`) carry no Expr to
        // inspect: skip the closure-detection branch and any subsequent
        // type-info recording that relied on `b.init` shape. The
        // `b.type_name` arm keeps recording (a const-block binding can
        // carry an explicit `: T` annotation independent of `init`).
        if (b.init) |init_val| {
            if (init_val.payload == .closure) {
                self.type_info_buf[self.type_info_count] = .{
                    .name = b.name,
                    .type_name = "",
                    .is_closure = true,
                };
                self.type_info_count += 1;
                return;
            }
        } else {
            return;
        }
        const tn = b.type_name orelse return;
        self.type_info_buf[self.type_info_count] = .{
            .name = b.name,
            .type_name = tn,
            .is_closure = false,
        };
        self.type_info_count += 1;
        self.collectNestedBindings(stmt);
    }

    /// Walk block-carrying statements and collect typed bindings from
    /// their nested bodies (if-branches, while/for bodies, unsafe
    /// blocks, match arms). See collectTypedBindings' docblock.
    pub     fn collectNestedBindings(self: *Codegen, stmt: ast.Stmt) void {
        switch (stmt.payload) {
            .if_stmt => |ifs| {
                for (ifs.then_body) |s| self.collectTypedBindings(s);
                switch (ifs.else_kind) {
                    .none => {},
                    .block => |blk| for (blk) |s| self.collectTypedBindings(s),
                    .if_chain => |inner| self.collectTypedBindings(ast.Stmt{ .payload = .{ .if_stmt = inner.* }, .loc = stmt.loc }),
                }
            },
            .while_stmt => |ws| {
                for (ws.body) |s| self.collectTypedBindings(s);
            },
            .for_stmt => |fs| {
                for (fs.body) |s| self.collectTypedBindings(s);
            },
            .unsafe_block => |stmts| {
                for (stmts) |s| self.collectTypedBindings(s);
            },
            else => {},
        }
    }

    /// Condition-paren wrapping for `if` / `while` / `else if` conds.
    /// Binary and unary conds self-parenthesize in genExpr
    /// (`(i < 10)`, `(!flag)`); every other payload (ident, index,
    /// member access, call, bool literal) emits bare and zig 0.16
    /// rejects `if x {` — so wrap those in explicit parens. Surfaced
    /// by lib/std/collections.zag's `if (uslot[idx])` and fs.zag's
    /// `while (true)`.
    pub     fn writeCond(self: *Codegen, cond: ast.Expr) void {
        const self_parens = cond.payload == .binary or cond.payload == .unary;
        if (!self_parens) self.write("(");
        self.genExpr(cond);
        if (!self_parens) self.write(")");
    }

    pub     fn genDocComment(self: *Codegen, doc: []const u8) void {        var i: usize = 0;
        while (i < doc.len) {
            var j: usize = i;
            while (j < doc.len and doc[j] != '\n') : (j += 1) {}
            var k: usize = i;
            while (k < j and (doc[k] == ' ' or doc[k] == '\t')) : (k += 1) {}
            while (k < j and doc[k] == '#') : (k += 1) {}
            while (k < j and (doc[k] == ' ' or doc[k] == '\t')) : (k += 1) {}
            self.write("/// ");
            self.write(doc[k..j]);
            // Always emit `\n` after each doc line — including the LAST line.
            // Zig's slice `[start..end]` excludes `end` so `doc` may end right
            // before a `\n` byte (e.g. when multi-line doc block was assembled
            // from multiple doc_comment tokens at lexer time, the LAST token's
            // text is `[start..newline_pos]` NOT `[start..newline_pos+1]`).
            // Without this unconditional write, `pub fn` would concatenate
            // directly onto the `///` line and the compiled zigzag source
            // becomes a single unbroken token like
            // `/// doc linepub fn main() …`.
            self.write("\n");
            // Advance `i` past the trailing `\n` if present; otherwise clamp
            // to doc.len so the outer while exits cleanly.
            if (j < doc.len and doc[j] == '\n') {
                i = j + 1;
            } else {
                i = doc.len;
            }
        }
    }

    pub     fn genStmt(self: *Codegen, stmt: ast.Stmt, is_tail_pos: bool) void {
        if (stmt.loc.line > 0) self.recordLoc(stmt.loc, "");
        switch (stmt.payload) {
            // All three binding kinds funnel through `genBinding`, which
            // decides between the simple single-binding path (no `pattern`
            // set) and the destructuring path (one temp binding + per-leaf
            // `const/var` bindings recursively walked through the pattern).
            // `kw` is the literal zig keyword spelling the binding kind.
            .let => |l| self.genBinding("const", l),
            .var_binding => |v| self.genBinding("var", v),
            .const_binding => |c| self.genBinding("const", c),
            .assign => |a| {
                // Bare rebinding: `name = expr;` (no leading `let`/`var`).
                // The name must refer to a previously-declared `var`; Zig's
                // compile-time type checker surfaces "undeclared identifier"
                // errors at the generated use site.
                self.write("    ");
                self.write(a.name);
                self.write(" = ");
                self.genExpr(a.value);
                self.write(";\n");
            },
            .defer_stmt => |d| {
                self.write("    defer ");
                self.genExpr(d.expr);
                self.write(";\n");
            },
            .errdefer_stmt => |d| {
                // zig 0.16 `errdefer expr;` mirrors zag's semantics
                // one-to-one — runs `expr` ONLY on the error-propagation
                // path (`?`-error or explicit `Err` early-return). See
                // `docs/19-memory.md` Pattern 2 for the canonical use.
                self.write("    errdefer ");
                self.genExpr(d.expr);
                self.write(";\n");
            },
            .unsafe_block => |stmts| {
                // zig 0.16 has no block-form `unsafe` keyword — raw pointer
                // dereferences and `@ptrCast` are already unconditional.
                // Emit the body wrapped in a plain block with comment
                // markers so the AST shape is visible to future
                // `-Dunsafe-block-check` tooling without affecting the
                // generated zig semantics. The leading/trailing comments
                // guarantee the structure is auditable in code review.
                self.write("    // unsafe {\n");
                for (stmts) |s| {
                    self.genStmt(s, false);
                }
                self.write("    // }\n");
            },
            .if_stmt => |ifs| {
                if (ifs.is_if_let) {
                    self.write("    if (");
                    self.genExpr(ifs.cond);
                    self.write(") |");
                    // Write the capture name from the pattern
                    const pat = ifs.if_let_pat;
                    if (pat == .enum_variant) {
                        const ev = pat.enum_variant;
                        if (ev.bindings) |binds| {
                            if (binds.len > 0 and binds[0] != null) {
                                self.write(binds[0].?);
                            } else {
                                self.write("_");
                            }
                        } else {
                            self.write("_");
                        }
                    } else if (pat == .ident) {
                        self.write(pat.ident);
                    } else {
                        self.write("_");
                    }
                    self.write("| {\n");
                    for (ifs.then_body) |s| self.genStmt(s, false);
                    self.write("    }");
                    self.genElseBranch(ifs.else_kind);
                    self.write("\n");
                } else {
                    self.write("    if ");
                    self.writeCond(ifs.cond);
                    self.write(" {\n");
                    for (ifs.then_body) |s| self.genStmt(s, false);
                    self.write("    }");
                    self.genElseBranch(ifs.else_kind);
                    self.write("\n");
                }
            },
            .while_stmt => |ws| {
                if (ws.is_while_let) {
                    self.write("    while (");
                    self.genExpr(ws.cond);
                    self.write(") |");
                    const pat = ws.while_let_pat;
                    if (pat == .enum_variant) {
                        const ev = pat.enum_variant;
                        if (ev.bindings) |binds| {
                            if (binds.len > 0 and binds[0] != null) {
                                self.write(binds[0].?);
                            } else {
                                self.write("_");
                            }
                        } else {
                            self.write("_");
                        }
                    } else if (pat == .ident) {
                        self.write(pat.ident);
                    } else {
                        self.write("_");
                    }
                    self.write("| {\n");
                    for (ws.body) |s| self.genStmt(s, false);
                    self.write("    }\n");
                } else {
                    // Plain `while (cond) { … }`. Binary conds
                    // self-parenthesize in genExpr (`(i < 10)`), but a
                    // bare-ident / bool-literal cond (`while (true)`)
                    // emits unwrapped (`while true`) which zig 0.16
                    // rejects. Wrap only the non-binary conds in
                    // explicit parens (surfaced by lib/std/fs.zag
                    // read_file's `while (true)` loop in the Tier-1
                    // migration).
                    self.write("    while ");
                    self.writeCond(ws.cond);
                    self.write(" {\n");
                    for (ws.body) |s| self.genStmt(s, false);
                    self.write("    }\n");
                }
            },
            .for_stmt => |fs| {
                // `for (iter) |pat| { … }`. The iter expression is emitted
                // verbatim when it isn't a RangeExpr; for ranges we
                // INLINE emit `start..end[ + 1]` so zig's native range
                // syntax handles iteration without the
                // anonymous-tuple-wrapper round-trip (zag's RangeExpr
                // emits `.{ start, end, inclusive }`, NOT a native range).
                // Inclusive ranges get +1 so the half-open semantics
                // become inclusive; static and dynamic ends both work
                // because `end + 1` is a valid zig binary expression.
                self.write("    for (");
                if (fs.iter.payload == .range) {
                    self.genExpr(fs.iter.payload.range.start.*);
                    self.write("..");
                    self.genExpr(fs.iter.payload.range.end.*);
                    if (fs.iter.payload.range.inclusive) self.write(" + 1");
                } else {
                    self.genExpr(fs.iter);
                }
                self.write(") |");
                switch (fs.pattern) {
                    .ident => |name| self.write(name),
                    .discard => self.write("_"),
                    else => {
                        // Range / literal patterns inside `for` are not
                        // supported in this commit; emit a placeholder.
                        self.write("_");
                    },
                }
                self.write("| {\n");
                for (fs.body) |s| self.genStmt(s, false);
                self.write("    }\n");
            },
            .match_stmt => |m| {
                // CRITICAL: match-as-stmt emit shape. The MATCH form
                // always emits a labelled `(blk: { ... });` block.
                // Because that block sits on its own indented line in
                // the generated zig (NOT inline with the function
                // body's closing `}`), zig's implicit-return detection
                // does NOT fire (zig 0.16 only treats the body's last
                // expression as the return value when the expression
                // is inline and not followed by `;`; a parenthesised
                // block on its own line is read as a separate
                // statement that needs a trailing `;`). When the match
                // sits at the function-tail position AND the fn has a
                // non-void return type, we therefore prefix the block
                // with an explicit `return ` so the matched value gets
                // returned. Otherwise (mid-fn match, OR last-in-a-void-
                // fn match) we emit the bare indented
                // `(blk: { ... });` — zig accepts the discared block
                // value at statement position.
                //
                // The caller (`genFun`/`genMethod`/`genFreeMethod`)
                // passes `is_tail_pos` already gated by
                // `fn_returns_value and i == body.len - 1`, so we
                // don't repeat the fn_returns_value check here.
                if (is_tail_pos) {
                    self.write("    return ");
                } else {
                    self.write("    ");
                }
                self.genMatchExpr(m);
                self.write(";\n");
            },
            .break_stmt => {
                // Statement-only break per the user-confirmed shape.
                // zig's `break;` targets the innermost enclosing loop by
                // default; no label needed for the single-level case.
                self.write("    break;\n");
            },
            .continue_stmt => {
                // Continue targets the innermost loop by default; emit
                // verbatim.
                self.write("    continue;\n");
            },
            .return_stmt => |r| {
                // `return expr;` or bare `return;`. The function
                // signature isn't yet parsed, so zig's downstream type
                // checker validates the type against the inferred
                // `pub fn main() !void` body return shape.
                // async fun (docs/manual/18 §"Async Trait Methods"):
                // wrap the value into the emitted Future(T) —
                // `return .{ .done = true, .value = EXPR };` (bare
                // return → `return .{ .done = true };`).
                if (self.fn_is_async) {
                    if (r.value) |v| {
                        self.write("    return .{ .done = true, .value = ");
                        self.genExpr(v);
                        self.write(" };\n");
                    } else {
                        self.write("    return .{ .done = true };\n");
                    }
                    return;
                }
                if (r.value) |v| {
                    self.write("    return ");
                    self.genExpr(v);
                    self.write(";\n");
                } else {
                    self.write("    return;\n");
                }
            },
            .index_assign => |ia| {
                // `target[i] = value;` writes a single element of an
                // indexable container. Zig 0.16 accepts `a[i] = b;` syntax
                // for both arrays and (where applicable) anonymous-struct
                // tuple literals, so the AST shape round-trips directly.
                self.write("    ");
                self.genExpr(ia.target.*);
                self.write("[");
                self.genExpr(ia.index.*);
                self.write("] = ");
                self.genExpr(ia.value);
                self.write(";\n");
            },
            .expr_stmt => |e| {
                // Inline-asm statements (docs/manual/24 §"Inline
                // Assembly"): the asm expression is VALUE-typed when
                // it has outputs, and zig rejects a discarded non-void
                // expression at statement position — prefix the
                // explicit `_ = ` discard (the outputs are still
                // written; the block's own value is thrown away).
                if (e.payload == .asm_expr) {
                    self.write("    _ = ");
                    self.genExpr(e);
                    self.write(";\n");
                    return;
                }
                self.write("    ");
                self.genExpr(e);
                self.write(";\n");
            },
            .field_assign => |fa| {
                // `target.field = value;` — zig 0.16 accepts this
                // verbatim for any receiver whose zig-type declares
                // `field` as a `var` (struct field is always var-able).
                // Note: zig REJECTS field-write to a `const` receiver,
                // so the binding kind (`let` vs `var`) on `target`'s
                // declaration determines correctness — which mirrors
                // zag's own semantics (zig's `let` rejects field-write
                // exactly because the binding is immutable).
                self.write("    ");
                self.genExpr(fa.target.*);
                self.write(".");
                self.write(fa.field_name);
                self.write(" = ");
                self.genExpr(fa.value);
                self.write(";\n");
            },
            .deref_assign => |da| {
                // `*p = value;` writes through the pointer on the LHS.
                // zig 0.16's postfix-deref-write `p.* = value;` is
                // precisely equivalent — `.*` postfix applied to a
                // pointer expression gives write-through semantics.
                // Mirrors the `.assign` arm shape (just `name`, `.* = `,
                // value, `;\n`) with the `.*` interleaved so zig's
                // tagged-union / pointer dispatch accepts the
                // assignment. Used by `examples/memory/pointers.zag`
                // line ~25 (`*p_mut = 42;`). The LHS is restricted to
                // a bare identifier because the parser's `.star` arm
                // performs `expectIdent` after consuming `.star`; the
                // AST slot does not carry a richer `*target` Expr so
                // complex deref-trees like `*obj.field = x` would need
                // either AST widening or a parser carve-out (deferred).
                self.write("    ");
                self.write(da.name);
                self.write(".* = ");
                self.genExpr(da.value);
                self.write(";\n");
            },
        }
    }

    pub     fn genBinding(self: *Codegen, kw: []const u8, b: ast.Stmt.BindingStmt) void {
        if (b.pattern) |pattern| {
            // Const-block bindings and pattern-bindings are mutually
            // exclusive (parser rejects the latter combination), so
            // reaching the destructuring path implies a non-null
            // `b.init`. The parser invariant is enforced at parseBinding
            // (see `validateBindingInvariant` below) — if a future parser
            // regression ever lets a null `init` reach here, surface an
            // actionable diagnostic naming the binding kind instead of
            // crashing. Mirrors the `.rest`-arm shape of `genBindingLeaves`
            // so all parser-invariant violations uniformly route to
            // `std.debug.print` + `std.process.exit(1)`.
            const init_expr = b.init orelse {
                std.debug.print("error:codegen: {s} destructuring binding {s}: parser invariant violated — init is null on a non-const-block binding (b.pattern set)\n", .{
                    kw,
                    b.name,
                });
                std.process.exit(1);
            };
            const idx = self.destructure_counter;
            self.destructure_counter += 1;
            var tmp_buf: [32]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&tmp_buf, "__destruct_{d}", .{idx}) catch "__destruct";
            self.write("    const ");
            self.write(tmp_name);
            self.write(" = ");
            self.genExpr(init_expr);
            self.write(";\n");
            // Walk the init expression in parallel with the pattern so each
            // leaf can infer its type from the corresponding source literal
            // (e.g. `(1, 2)` → leaves get `: i32` for `var` destructurings).
            self.genBindingLeaves(kw, tmp_name, pattern, getTopElements(init_expr));
            return;
        }
        // Compile-time block form (docs/manual/16-generics.md §6): `const
        // NAME: T = const { … return EXPR; };`. We emit the body as a zig
        // labeled block `blk: { …stmts…; break :blk EXPR; }`, translating
        // the parser-side `return EXPR;` terminator into `break :blk EXPR;`
        // so the result of the block is the binding's RHS value (matching
        // zig's native `return` (for fns) → `break :blk` (for blocks)
        // difference). The block is evaluated at comptime when bound to a
        // `const` so the entire payload collapses to a compile-time constant
        // downstream. Body statements are emitted via the shared `genStmt`
        // path so `for` / `if` / `var` / nested expressions all round-trip
        // identically to their function-body counterparts.
        if (b.block) |stmts| {
            self.write("    const ");
            self.write(b.name);
            if (b.type_name) |t| {
                self.write(": ");
                self.writeType(t);
            }
            self.write(" = blk: {\n");
            for (stmts) |s| {
                if (s.payload == .return_stmt) {
                    // `return EXPR;` → `break :blk EXPR;` so zig's
                    // labeled-block semantics carries the bind's RHS
                    // value out. Bare `return;` (no value) is rejected
                    // at parse time so this arm always has a value.
                    self.write("        break :blk ");
                    if (s.payload.return_stmt.value) |v| {
                        self.genExpr(v);
                    }
                    self.write(";\n");
                } else {
                    self.genStmt(s, false);
                }
            }
            self.write("    };\n");
            return;
        }
        // Simple path. Const-block bindings return above; reaching the
        // simple path implies a non-null `b.init`. The parser invariant
        // is enforced at parseBinding (see `validateBindingInvariant`
        // below) — if a future parser regression ever lets a null `init`
        // reach here, surface an actionable diagnostic naming the
        // binding kind instead of crashing. Mirrors the destructuring-
        // path arm above so both runtime-invariant violations uniformly
        // route to `std.debug.print` + `std.process.exit(1)`.
        const init_expr = b.init orelse {
            std.debug.print("error:codegen: {s} plain binding {s}: parser invariant violated — init is null on a non-const-block binding (no pattern, no block)\n", .{
                kw,
                b.name,
            });
            std.process.exit(1);
        };
        self.write("    ");
        self.write(kw);
        self.write(" ");
        self.write(b.name);
        // Preserve the user's type annotation `let x: T = ...` so Zig's
        // type checker picks it up too. Without `type_name` we let Zig
        // infer from the initializer (which still produces a `const`/`var`).
        if (b.type_name) |t| {
            self.write(": ");
            self.writeType(t);
        }
        self.write(" = ");
        // Backed-enum typed-bind unwrap (gap #5): when the let-
        // binding carries a `: T` annotation AND the RHS is a
        // `.enum_variant_ctor` reference AND the enum's backing
        // type (post `zagTypeToZig` rewrite) matches the
        // annotation (also rewritten), wrap the RHS so zig accepts
        // the assignment. The bare `Enum.Variant` form has zig-
        // type `enum(T)`, which zig rejects as a value of plain
        // `T` even though the user's source declared them
        // interchangeably (the docs/13 "category of similar values"
        // semantic). `@intFromEnum` lowers an int-/char-/bool-
        // backed enum variant to its T value; `@tagName` does the
        // equivalent for `enum(str)` (returns the str backing-
        // value as a `[]const u8`).
        //
        // The wrap ONLY fires when annotation == backing_type —
        // `let s: Status = Status.Ok;` (target IS the enum, not the
        // backing) emits the bare `Status.Ok` form unchanged so
        // zig sees the enum-typed binding site as-is.
        var backed_wrap: ?[]const u8 = null;
        if (b.type_name) |tn| {
            if (init_expr.payload == .enum_variant_ctor) {
                const evc = init_expr.payload.enum_variant_ctor;
                // `enum_name` is `?[]const u8` because the
                // brace-form brace-named-field ctor can be
                // unqualified (`Variant { x = v }` when only one
                // union in the program declares the variant).
                // Skip the wrap on the unqualified form — without
                // an enum-name we have no entry in
                // `self.prog.enums` to resolve the backing type
                // against, and the bare variant emits as
                // `.Variant` which zig resolves via its own
                // tag-type machinery (no @intFromEnum needed).
                if (evc.enum_name) |enum_name| {
                    const annot_rewrite = zagTypeToZig(tn);
                    for (self.prog.enums) |ed| {
                        if (ed.backing_type) |bt| {
                            const bt_rewrite = zagTypeToZig(bt);
                            if (std.mem.eql(u8, ed.name, enum_name) and
                                std.mem.eql(u8, bt_rewrite, annot_rewrite))
                            {
                            // Str-backed enum variants are emitted
                            // as struct-with-const-fields (see the
                            // matching `enum(str)` arm in codegen/
                            // decl.zig's genEnumDecl) so the
                            // variant identifier IS already a
                            // `[]const u8` constant — wrapping it
                            // with `@tagName(...)` would fail because
                            // the operand is not a zig enum. Skip
                            // the wrap entirely (leave `backed_wrap`
                            // null so the else-branch emits the bare
                            // variant form). Int-/char-/bool-backed
                            // enums retain the `@intFromEnum(...)`
                            // wrap because their bare variant form
                            // is type-`enum(T)` which zig rejects
                            // when bound to a plain `T` slot.
                            backed_wrap = if (std.mem.eql(u8, bt_rewrite, "[]const u8"))
                                null
                            else
                                "@intFromEnum";
                            break;
                            }
                        }
                    }
                }
            }
        }
        if (backed_wrap) |wrap| {
            self.write(wrap);
            self.write("(");
            self.genExpr(init_expr);
            self.write(")");
        } else {
            self.genExpr(init_expr);
        }
        self.write(";\n");
    }

    pub     fn genBindingLeaves(self: *Codegen, kw: []const u8, src_path: []const u8, pattern: ast.BindingPattern, elements: []const ast.Expr) void {
        switch (pattern) {
            .name => |name| {
                self.write("    ");
                self.write(kw);
                self.write(" ");
                self.write(name);
                // `var` leaves need concrete type annotations because
                // zig rejects `var x = comptime_int`. By inspecting the
                // matching element of init, we infer the type from a small
                // lookup table covering literals our parser can produce.
                // For elements we can't infer (idents, calls, etc.), we
                // emit no annotation and trust the user's destination type
                // to be concrete via the assignment's other side.
                if (std.mem.eql(u8, kw, "var") and elements.len > 0) {
                    const t = inferZigTypeFromExpr(elements[0]);
                    if (t.len > 0) {
                        self.write(": ");
                        self.write(t);
                    }
                }
                self.write(" = ");
                self.write(src_path);
                self.write(";\n");
            },
            .discard => {
                // Wildcard leaf — emit no binding. The temp still carries
                // the value; we just throw it away by not aliasing any
                // user-visible name to it.
            },
            .rest => |rb| {
                // Phase 2: two emission shapes depending on whether the
                // init expression's element count is statically known.
                //
                //   - Literal init (`elements.len > 0`): synthesize a
                //     positional anonymous-struct sub-tuple
                //     `const NAME = .{ __destruct_<N>[before_count],
                //       __destruct_<N>[before_count+1], ...,
                //       __destruct_<N>[elements.len-1] };`
                //     No per-element types are needed because the
                //     destructure temp is itself an anonymous struct of
                //     matching positional types — zig 0.16 accepts bare
                //     `.{ a, b, c }` against `__destruct_<N>: .{ ... }`
                //     only when the temp's element types match each
                //     sub-index's match target. The `before_count >
                //     elements.len` guard catches malformed patterns
                //     where the rest-binding's anchor exceeds the init
                //     length (e.g. `(a, b, ...rest) = (1, 2)`).
                //
                //   - Runtime init (`elements.len == 0`): emit a
                //     zig slice open-ended form
                //     `const NAME = __destruct_<N>[<before_count>..];`
                //     which works when the destructured runtime value's
                //     zig type is sliceable (e.g. `[]T`, `[]const u8`,
                //     user arrays). For anonymous-struct-of-positional-
                //     types runtime values (the runtime-tuple case), zig
                //     does NOT accept slice operations on anonymous
                //     struct literals — the compiler will surface
                //     `cannot slice type '(struct { ... })'` at the
                //     generated call site, which IS the intended user
                //     signal that runtime-tuple rest-binding needs the
                //     literal-init surface or a slice-typed declaration.
                //     The Phase 2 decision here is to ACCEPT the
                //     runtime call (instead of rejecting at codegen
                //     time as Phase 1 did) so this surface compiles for
                //     the common slice/array cases.
                self.write("    ");
                self.write(kw);
                self.write(" ");
                self.write(rb.name);
                if (elements.len == 0) {
                    // Runtime slice form — see the doc above for the
                    // slice-vs-anonymous-struct semantics.
                    self.write(" = ");
                    self.write(src_path);
                    self.write("[");
                    var idx_buf: [16]u8 = undefined;
                    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{rb.before_count}) catch "0";
                    self.write(idx_str);
                    self.write("..];\n");
                    return;
                }
                if (rb.before_count > elements.len) {
                    std.debug.print("error: rest-binding '{s}' before_count={d} exceeds init length {d}\n", .{ rb.name, rb.before_count, elements.len });
                    std.process.exit(1);
                }
                self.write(" = .{");
                var j: usize = rb.before_count;
                while (j < elements.len) : (j += 1) {
                    if (j > rb.before_count) self.write(",");
                    self.write(" ");
                    self.write(src_path);
                    self.write("[");
                    var idx_buf2: [16]u8 = undefined;
                    const idx_str2 = std.fmt.bufPrint(&idx_buf2, "{d}", .{j}) catch "0";
                    self.write(idx_str2);
                    self.write("]");
                }
                self.write(" };\n");
            },
            .tuple, .array => |pats| {
                // Manual index counter (NOT `for (pats, 0..)`) so the .rest
                // early-continue branch can skip emitting `new_path` (it does
                // not use `i` for the recursive call's `src_path`) without
                // triggering zig 0.16's "pointless discard of capture" error.
                //
                // Phase 2 NOTE: the `.rest` early-continue passes the
                // CURRENT walker level's `src_path` and `elements` (the
                // outer walker is called with `src_path = __destruct_0`,
                // the inner walker IS called with `src_path = __destruct_0[1]`
                // from the outer walker, AND its `elements` IS the inner
                // tuple's literal elements). The .rest arm then emits
                // `__destruct_<N>[i_or_j]` correctly for both top-level
                // (using `__destruct_0`) and nested (using `__destruct_0[1]`)
                // cases. The reason Phase 1's original logic was already
                // correct: the recursion via `genBindingLeaves` carries the
                // CHUNKED src_path DOWN one level, so when the inner
                // walker hits `.rest`, it sees the inner tuple's path
                // (`__destruct_0[1]`) and emits `__destruct_0[1][j]`.
                var i: usize = 0;
                for (pats) |leaf| {
                    // Rest-binding is terminal: the leaf's .rest arm emits
                    // a single binding whose indices reference the
                    // ORIGINAL source positions, not the per-leaf `i`.
                    // The recursive walk below would index-by-`i` (e.g.
                    // turning `__destruct_0` into `__destruct_0[1]` for the
                    // leaf at position 1) which make the rest arm emit
                    // `__destruct_0[1][j]` instead of the desired
                    // `__destruct_0[j]`. Re-invoke the .rest arm with the
                    // current walker level's `src_path` and `elements` so
                    // it can use the AST-recorded `before_count` for the
                    // proper offset.
                    if (leaf == .rest) {
                        self.genBindingLeaves(kw, src_path, leaf, elements);
                        i += 1;
                        continue;
                    }
                    var new_buf: [256]u8 = undefined;
                    const new_path = std.fmt.bufPrint(&new_buf, "{s}[{d}]", .{ src_path, i }) catch src_path;
                    // Hand each child the elements slice appropriate for
                    // ITS shape. Both branches fall through to the leaf when
                    // `elements` has no element at `i` (init didn't carry a
                    // destructurable Expr at this depth — idents, calls,
                    // etc. — so type inference skips and the leaf is emitted
                    // bare). See the doc header above for why these two
                    // forms differ. The `.rest` arm below returns an empty
                    // slice — it's only here to keep the switch exhaustive;
                    // the early-continue above is the only path that reaches
                    // this switch with `.rest` and skips the recursive call.
                    const sub_elements: []const ast.Expr = switch (leaf) {
                        .name, .discard => if (i < elements.len)
                            elements[i..][0..1]
                        else
                            &[_]ast.Expr{},
                        .tuple, .array => if (i < elements.len)
                            getTopElements(elements[i])
                        else
                            &[_]ast.Expr{},
                        .rest => &[_]ast.Expr{},
                    };
                    self.genBindingLeaves(kw, new_path, leaf, sub_elements);
                    // Manual counter increment (matches the `i += 1;`
                    // inside the `.rest` early-continue above). Without
                    // this, every non-rest leaf would compute `new_path`
                    // as `__destruct_<N>[0]` regardless of position.
                    i += 1;
                }
            },
        }
    }

    pub     fn genElseBranch(self: *Codegen, else_kind: ast.Stmt.IfStmt.IfElseKind) void {
        switch (else_kind) {
            .none => {},
            .block => |stmts| {
                self.write(" else {\n");
                for (stmts) |s| self.genStmt(s, false);
                self.write("    }");
            },
            .if_chain => |ifs_ptr| {
                // Same outer-paren caveat as `.if_stmt`: `genExpr`
                // already wraps `.binary` in `(lhs op rhs)`, so dropping
                // the literal `(` / `)` around the cond yields a single
                // paren (just the binary's own) instead of `else if ((b))`.
                // For ident conds (`else if a`) dropping the wrappers
                // yields the clean `else if a {` form. Either way the
                // substring assertions in docs/06 pin tests match.
                self.write(" else if ");
                self.writeCond(ifs_ptr.cond);
                self.write(" {\n");
                for (ifs_ptr.then_body) |s| self.genStmt(s, false);
                self.write("    }");
                // Recurse for the chained else_kind (another else-if, a
                // terminal else block, or none).
                self.genElseBranch(ifs_ptr.else_kind);
            },
        }
    }

    pub     fn genMatchExpr(self: *Codegen, m: ast.Expr.MatchExpr) void {
        const id = self.match_counter;
        self.match_counter += 1;
        var name_buf: [16]u8 = undefined;
        const scrut_name = std.fmt.bufPrint(&name_buf, "__m_{d}", .{id}) catch "__m";
        self.write("(blk: { const ");
        self.write(scrut_name);
        self.write(" = ");
        // `m.scrutinee` is `*Expr` (cycle-breaking pointer) — deref before
        // walking the AST via genExpr.
        self.genExpr(m.scrutinee.*);
        self.write("; ");
        var had_any_arm = false;
        for (m.arms) |arm| {
            if (had_any_arm) self.write(" else ");
            self.write("if (");
            self.emitPatternCond(scrut_name, arm.pat);
            if (arm.guard) |g| {
                self.write(" and (");
                // `arm.guard` is `?*Expr` — deref the pointer before
                // emitting the guard expression body.
                self.genExpr(g.*);
                self.write(")");
            }
            self.write(") { ");
            if (arm.pat == .ident) {
                // Ident-pattern arm: bind scrutinee to `<name>` so the
                // arm's body can reference it. Always emitted as
                // `const` because the binding is synthetic and a
                // shadow never reuses the name within an arm body.
                self.write("const ");
                self.write(arm.pat.ident);
                self.write(" = ");
                self.write(scrut_name);
                self.write("; ");
            }
            // gap #6 — emit named/positional payload-binding
            // preamble BEFORE `break :blk EXPR;` so the captures
            // declared on the pattern (`Variant { x: w, y: h }` or
            // `Variant(w, h)`) are in lexical scope for the EXPR
            // that follows. The brace-form walker and paren-pos
            // walker both route through `emitPatternBindings`
            // which is a no-op for `.literal`/`.range`/`.ident`/
            // `.discard` patterns. See `emitPatternBindings` doc
            // for the zig 0.16 unused-const throwaway rationale.
            self.emitPatternBindings(scrut_name, arm.pat);
            self.write("break :blk ");
            // `arm.expr` is `*Expr` (cycle-breaking pointer) — deref before
            // emitting the arm-body expression.
            self.genExpr(arm.expr.*);
            self.write("; }");
            had_any_arm = true;
        }
        const last_is_wildcard = m.arms.len > 0 and m.arms[m.arms.len - 1].pat == .discard;
        if (!last_is_wildcard) {
            if (had_any_arm) {
                self.write(" else unreachable;");
            } else {
                self.write("unreachable;");
            }
        }
        self.write(" })");
    }

    pub     fn emitPatternCond(self: *Codegen, scrut_name: []const u8, p: ast.Pattern) void {
        switch (p) {
            .literal => |lit| {
                // `__m == <lit>` for int / bool / char. For string,
                // emit `std.mem.eql(u8, __m, "...")` because direct `==`
                // is rejected by zig 0.16 on `[]const u8` (slices don't
                // implement equality by default). `lit` is `*Expr` (the
                // Pattern-variant cycle-breaking pointer) so deref
                // before walking.
                switch (lit.*.payload) {
                    .string_lit => |s| {
                        self.write("std.mem.eql(u8, ");
                        self.write(scrut_name);
                        self.write(", \"");
                        self.write(s);
                        self.write("\")");
                    },
                    else => {
                        self.write(scrut_name);
                        self.write(" == ");
                        self.genExpr(lit.*);
                    },
                }
            },
            .range => |r| {
                // Half-open: `__m >= start and __m < end`.
                // Inclusive: `__m >= start and __m <= end`.
                // Wrapping in `(...)` so the `and` operator is the
                // outermost, not silently captured by surrounding
                // precedence (zig's `and` is a freestanding keyword
                // here, but we keep the parens for explicitness).
                // `.start` and `.end` are `*Expr` (Pattern-range cycle-
                // breaking pointers) so deref before emitting.
                self.write("((");
                self.write(scrut_name);
                self.write(" >= ");
                self.genExpr(r.start.*);
                self.write(") and (");
                self.write(scrut_name);
                if (r.inclusive) self.write(" <= ") else self.write(" < ");
                self.genExpr(r.end.*);
                self.write("))");
            },
            .ident => self.write("true"),
            .discard => self.write("true"),
            .enum_variant => |ev| {
                // zig 0.16 REJECTS every qualified form (`__m == .Direction.North`,
                // `__m == @as(Direction, .Direction.North)`, ...) because the
                // token `.Direction` is parsed as field-access on a comptime
                // EnumLiteral, and EnumLiterals do not support field access
                // in zig 0.16 — the compiler emits `type '@EnumLiteral()'
                // does not support field access` and rejects the whole
                // match arm.
                //
                // The only working form is the unqualified dotted name:
                // `__m == .North`. zig resolves `.North` against the
                // scrutinee's declared enum type (the per-function
                // `__m_<N>` is declared via `const __m_N = <scrut_expr>;`
                // and zig's compile-time tag-resolution picks
                // `Direction.North` automatically). This works for both
                // qualified and unqualified parser-side patterns because
                // the codegen emits the SAME emit-side form (the runtime
                // scrutinee's type drives the dot-name lookup, not the
                // source-side qualifier).
                self.write(scrut_name);
                self.write(" == .");
                self.write(ev.variant_name);
            },
            .enum_variant_named => |env| {
                // gap #6 — brace-named-field match-side destructuring
                // (docs/manual/14-unions §"Definition" + docs/manual/
                // 13-enums §"Choosing Between enum and union"). Cond
                // is the SAME `__m == .Variant` shape as the paren-
                // positional `.enum_variant` arm; the NAMED-field
                // binding preamble (`const w = __m.x; ...`) is
                // emitted separately by `emitPatternBindings` from
                // `genMatchExpr`'s arm loop, OUTSIDE this cond, so
                // the `const` declarations land INSIDE the
                // `if (cond) { ... }` block where they're in scope
                // for the arm body's `break :blk EXPR`. We chose to
                // share the cond with `.enum_variant` rather than
                // refactor into a single tag-cond because the emit
                // shape is byte-for-byte identical — the only
                // delta is the binding preamble, kept in a parallel
                // arm so this cond stays trivial.
                self.write(scrut_name);
                self.write(" == .");
                self.write(env.variant_name);
            },
        }
    }


    pub     fn emitPatternBindings(self: *Codegen, scrut_name: []const u8, p: ast.Pattern) void {
        // gap #6 — emit per-arm payload-binding preamble so captures
        // declared on the pattern (`Variant { x: w, y: h }` for the
        // brace-named form OR `Variant(w, h)` for the paren-pos
        // form) are in lexical scope for the arm-body EXPR that
        // follows `break :blk`. Emit is called from `genMatchExpr`'s
        // arm loop AFTER the `if (arm.pat == .ident)` block (the
        // legacy ident-binding path) and BEFORE the
        // `self.write("break :blk ")` line, so the `const` decls
        // land inside the surrounding `if (cond) { ... }` block
        // — the exact spot zig 0.16 requires for the EXPR's
        // identifier scope to include them.
        //
        // zig 0.16 also rejects UNUSED local consts. The user's
        // arm body may or may not reference each capture, and our
        // codegen doesn't analyse the EXPR for usage, so we silhouette
        // every captured binding with a no-op `_ = NAME;` throwaway
        // line. The throwaway has zero runtime cost (it's a load
        // into `_` which the optimizer drops) and silences zig's
        // "unused local variable" diagnostic regardless of whether
        // the user actually consumed the capture.
        //
        // Paren-positional (`Pattern.enum_variant.bindings`):
        // emits `const NAME = __m.a;` etc. using single-letter field
        // names per the gap #2 legacy emit shape (zig 0.16's
        // anonymous-struct naming requires sequential lowercase
        // letters because `Variant(a, b)` two-arg users see `.a`/`.b`
        // — not user-named fields). The `letters` table bounds the
        // arity at 26 — variants with more than 26 payload fields
        // would exhaust this alphabet and require a v2 emit shape,
        // but the current spec caps payload arity at the tuple-
        // destructuring ceiling (16 per the `bind_buf: [16]` size
        // in `parsePattern`); 26 is comfortably above that ceiling.
        switch (p) {
            .enum_variant => |ev| {
                if (ev.bindings) |bs| {
                    const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
                    for (bs, 0..) |b, i| {
                        if (b) |name| {
                            self.write("const ");
                            self.write(name);
                            self.write(" = ");
                            self.write(scrut_name);
                            self.write(".");
                            // Bug #2 fix (zig 0.16 paren-positional match): emit
                            // `__m_0.<variant_name>.<single-letter>` instead of
                            // `__m_0.<single-letter>` so zig can dispatch through
                            // the active union variant. Symmetric with the brace-
                            // named-field arm above; required because zig 0.16's
                            // union(enum) does not expose anonymous-struct fields
                            // directly (`p.a` rejected, but `p.Pair.a` accepted).
                            // The `if (__m_0 == .Variant)` cond already established
                            // the active variant so the prefix is statically sound.
                            self.write(ev.variant_name);
                            self.write(".");
                            self.write(letters[i]);
                            self.write("; ");
                        }
                    }
                }
            },
            .enum_variant_named => |env| {
                for (env.fields) |f| {
                    if (f.capture) |name| {
                        // gap #2 brace-named-field emit preserves
                        // user-written field names on the anonymous-
                        // struct payload (`Drag { x: f64, y: f64 }`
                        // becomes `struct { x: f64, y: f64 }` in
                        // zag output, which zig accepts because the
                        // user's source field NAMES are kept intact).
                        // The pattern-side `f.name` must match the
                        // variant-decl-side field name — the AST
                        // walker in `parsePattern` doesn't validate
                        // this match (the source-side pattern walker
                        // accepts any ident as field name); zig's
                        // anonymous-struct resolver rejects mismatches
                        // at compile time so the user gets a clear
                        // "no field named 'foo' in struct" diagnostic
                        // if they typo the field name on the pattern
                        // side.
                        self.write("const ");
                        self.write(name);
                        self.write(" = ");
                        self.write(scrut_name);
                        self.write(".");
                        // Bug #2 fix (zig 0.16 brace-named-field match): emit
                        // `__m_0.<variant_name>.<field_name>` instead of
                        // `__m_0.<field_name>` so zig can dispatch through
                        // the active union variant. union(enum) does not
                        // expose struct fields directly — `p.x` is rejected,
                        // but `p.Pair.x` is accepted by zig 0.16 because
                        // the variant name resolves the tagged-union dispatch
                        // before the field access. The `if (__m == .Pair)`
                        // cond already established Pair is active so the
                        // variant-prefixed field access is statically sound.
                        self.write(env.variant_name);
                        self.write(".");
                        self.write(f.name);
                        self.write("; ");
                    }
                }
            },
            .literal, .range, .ident, .discard => {},
        }
    }
