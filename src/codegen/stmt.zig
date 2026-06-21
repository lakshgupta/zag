const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;
const inferZigTypeFromExpr = @import("primary.zig").inferZigTypeFromExpr;
const getTopElements = @import("primary.zig").getTopElements;

// ============================================================
// FILE-SCOPE methods (STMT bucket)
// ============================================================

    pub     fn collectTypedBindings(self: *Codegen, stmt: ast.Stmt) void {
        const b: ast.Stmt.BindingStmt = switch (stmt) {
            .let => stmt.let,
            .var_binding => stmt.var_binding,
            .const_binding => stmt.const_binding,
            else => return,
        };
        if (b.pattern != null) return;
        if (self.type_info_count >= self.type_info_buf.len) return;
        // Closure-typed binding — no `: T` annotation required.
        if (b.init == .closure) {
            self.type_info_buf[self.type_info_count] = .{
                .name = b.name,
                .type_name = "",
                .is_closure = true,
            };
            self.type_info_count += 1;
            return;
        }
        const tn = b.type_name orelse return;
        self.type_info_buf[self.type_info_count] = .{
            .name = b.name,
            .type_name = tn,
            .is_closure = false,
        };
        self.type_info_count += 1;
    }

    pub     fn genDocComment(self: *Codegen, doc: []const u8) void {
        var i: usize = 0;
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
        switch (stmt) {
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
                // Statement form: `if cond { … } else …` rendered with
                // zig's `if`/`else` keyword directly. The recursive
                // `else_kind` union walks the chain so `else if …`, `else`,
                // and bare (`none`) all render uniformly via `genElseBranch`.
                //
                // IMPORTANT: do NOT emit literal `(` / `)` around the
                // condition. The `.binary` codegen path already wraps its
                // emission in `(lhs op rhs)` so adding outer parens would
                // produce `if ((x > 0)) {` (one extra paren pair) and break
                // substring assertion tests like the docs/06 pin tests.
                // For an identifier cond (`if cond { … }`) no outer paren
                // is needed; the form `if cond {` is exactly what zig
                // accepts.
                self.write("    if ");
                self.genExpr(ifs.cond);
                self.write(" {\n");
                for (ifs.then_body) |s| self.genStmt(s, false);
                self.write("    }");
                self.genElseBranch(ifs.else_kind);
                self.write("\n");
            },
            .while_stmt => |ws| {
                // Plain `while cond { … }` mirrors zig directly. Cond
                // and body are both standard zig, so no shim is needed.
                //
                // Same outer-paren caveat as `.if_stmt` above: genExpr
                // already wraps `.binary` in `(lhs op rhs)`, so emitting
                // literal `(` / `)` around the cond would produce
                // `while ((i < 10)) {` (double parens) breaking substring
                // assertions. Drop the wrappers.
                self.write("    while ");
                self.genExpr(ws.cond);
                self.write(" {\n");
                for (ws.body) |s| self.genStmt(s, false);
                self.write("    }\n");
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
                if (fs.iter == .range) {
                    self.genExpr(fs.iter.range.start.*);
                    self.write("..");
                    self.genExpr(fs.iter.range.end.*);
                    if (fs.iter.range.inclusive) self.write(" + 1");
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
        }
    }

    pub     fn genBinding(self: *Codegen, kw: []const u8, b: ast.Stmt.BindingStmt) void {
        if (b.pattern) |pattern| {
            const idx = self.destructure_counter;
            self.destructure_counter += 1;
            var tmp_buf: [32]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&tmp_buf, "__destruct_{d}", .{idx}) catch "__destruct";
            self.write("    const ");
            self.write(tmp_name);
            self.write(" = ");
            self.genExpr(b.init);
            self.write(";\n");
            // Walk the init expression in parallel with the pattern so each
            // leaf can infer its type from the corresponding source literal
            // (e.g. `(1, 2)` → leaves get `: i32` for `var` destructurings).
            self.genBindingLeaves(kw, tmp_name, pattern, getTopElements(b.init));
            return;
        }
        // Simple path.
        self.write("    ");
        self.write(kw);
        self.write(" ");
        self.write(b.name);
        // Preserve the user's type annotation `let x: T = ...` so Zig's
        // type checker picks it up too. Without `type_name` we let Zig
        // infer from the initializer (which still produces a `const`/`var`).
        if (b.type_name) |t| {
            self.write(": ");
            self.write(t);
        }
        self.write(" = ");
        self.genExpr(b.init);
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
                self.genExpr(ifs_ptr.cond);
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
                switch (lit.*) {
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
        }
    }
