const std = @import("std");
const ast = @import("ast.zig");

pub const Codegen = struct {
    out_buf: [65536]u8,
    out_len: usize,
    /// Per-function counter for destructuring temps. Reset to 0 by `genFun`
    /// so each `pub fn` body has its own `__destruct_0`, `__destruct_1`,
    /// ... sequence. Multiple destructurings in the same body produce
    /// distinct names so zig's no-redeclaration rule is satisfied.
    destructure_counter: u32,

    pub fn init() Codegen {
        return .{
            .out_buf = undefined,
            .out_len = 0,
            .destructure_counter = 0,
        };
    }

    fn write(self: *Codegen, s: []const u8) void {
        @memcpy(self.out_buf[self.out_len .. self.out_len + s.len], s);
        self.out_len += s.len;
    }

    pub fn generate(self: *Codegen, prog: ast.Program) []const u8 {
        self.write(
            \\const std = @import("std");
            \\
            \\pub fn print_fn(msg: []const u8) void {
            \\    std.debug.print("{s}", .{msg});
            \\}
            \\
            \\// Module-level scratch buffer for standalone template-literal evaluation.
            \\// Each `let x = "...{a}..."` overwrites this; successive uses race but
            \\// works for patterns where the slice is consumed before the next
            \\// template-literal expression runs (the common form is single-shot
            \\// `print` interpolation which uses the per-call `.debug_print` ctx).
            \\// The `__zag_` prefix reserves the name against user identifiers.
            \\var __zag_interp_buf: [4096]u8 = undefined;
            \\
        );

        for (prog.functions) |fun| {
            self.genFun(fun);
        }

        return self.out_buf[0..self.out_len];
    }

    fn genFun(self: *Codegen, fun: ast.FunDecl) void {
        // Reset destructuring counter at the top of each function so the
        // temp bindings inside this body stay local (avoiding clashes
        // across sibling `pub fn` declarations) and count from `_0`.
        self.destructure_counter = 0;
        if (fun.doc) |d| self.genDocComment(d);
        self.write("pub fn ");
        self.write(fun.name);
        self.write("() !void {\n");

        for (fun.body) |stmt| {
            self.genStmt(stmt);
        }

        self.write("}\n\n");
    }

    fn genDocComment(self: *Codegen, doc: []const u8) void {
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

    fn genStmt(self: *Codegen, stmt: ast.Stmt) void {
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
        }
    }

    /// Emit a single binding declaration. Two paths:
    /// - **Simple** (`pattern == null`): one zig statement
    ///   `    <kw> NAME[: T] = INIT;`  — the existing single-name form.
    /// - **Destructuring** (`pattern != null`): one const temp binding
    ///   `    const __destruct_<N> = INIT;`  followed by one zig
    ///   declaration per leaf walked through `pattern`. Discards emit
    ///   nothing; both tuple and array indices use `[k]` bracket-indexing
    ///   on the temp (zig 0.16 accepts `[k]` on both arrays and anonymous
    ///   structs). The temp is `const` even under a `var` binding because
    ///   it's a synthetic carrier — only the leaves are `var`-mutable.
    fn genBinding(self: *Codegen, kw: []const u8, b: ast.Stmt.BindingStmt) void {
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

    /// Recursive walk of a `BindingPattern` emitting leaf bindings. `src_path`
    /// is the cumulative extraction path from the temp, e.g. for
    /// `let (a, (b, c)) = (1, (2, 3))` we first emit `b` from
    /// `__destruct_0[1][0]` and `c` from `__destruct_0[1][1]`. Discards just
    /// drop the leaf. The buffer for each new path is 256 bytes, plenty for
    /// any reasonable nesting depth (each level adds `[k]` ≤ 4 chars).
    ///
    /// Both `.tuple` and `.array` patterns share the same bracket-indexing
    /// zag syntax — `[i]` works on arrays AND on anonymous structs in
    /// zig 0.16. (`.i` numeric-field syntax on anonymous structs is
    /// rejected in 0.16; `.@"i"` quoted-identifier syntax also works but
    /// `[i]` is the simpler form and unifies both pattern variants into one
    /// recursive case.)
    ///
    /// `elements` carries the current-level source container's element
    /// expressions — it's the parallel walk of the init expression. For
    /// `let (a, b) = (10, 20);` at the top call, `elements` is
    /// `[IntLit(10), IntLit(20)]`. The shape of the element slice passed to
    /// each child differs by the child's pattern kind, which is why the
    /// `.tuple`/`.array` arm switches on `leaf`:
    ///
    /// - **Leaf child** (`.name`/`.discard`): the child needs direct access
    ///   to `elements[i]` for type inference (`inferZigTypeFromExpr`), so we
    ///   pass a single-element slice `elements[i..][0..1]`. Earlier naive
    ///   versions wrapped in `getTopElements` and stripped too far, losing
    ///   the type info on `var` destructured leaves.
    /// - **Nested child** (`.tuple`/`.array`): the child needs the
    ///   init expression's element list (e.g. `IntLit(2), IntLit(3)` for the
    ///   inner pair of `let (a, (b, c)) = (1, (2, 3))`), so we drill in via
    ///   `getTopElements(elements[i])`.
    ///
    /// `inferZigTypeFromExpr` covers the literal kinds the parser can
    /// produce. For elements we can't infer (idents, calls, etc.), we emit
    /// no annotation and trust the user's destination type to be concrete
    /// via the assignment's other side or zig's type inference downstream.
    fn genBindingLeaves(self: *Codegen, kw: []const u8, src_path: []const u8, pattern: ast.BindingPattern, elements: []const ast.Expr) void {
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
            .tuple, .array => |pats| {
                for (pats, 0..) |leaf, i| {
                    var new_buf: [256]u8 = undefined;
                    const new_path = std.fmt.bufPrint(&new_buf, "{s}[{d}]", .{ src_path, i }) catch src_path;
                    // Hand each child the elements slice appropriate for
                    // ITS shape. Both branches fall through to the leaf when
                    // `elements` has no element at `i` (init didn't carry a
                    // destructurable Expr at this depth — idents, calls,
                    // etc. — so type inference skips and the leaf is emitted
                    // bare). See the doc header above for why these two
                    // forms differ.
                    const sub_elements: []const ast.Expr = switch (leaf) {
                        .name, .discard => if (i < elements.len)
                            elements[i..][0..1]
                        else
                            &[_]ast.Expr{},
                        .tuple, .array => if (i < elements.len)
                            getTopElements(elements[i])
                        else
                            &[_]ast.Expr{},
                    };
                    self.genBindingLeaves(kw, new_path, leaf, sub_elements);
                }
            },
        }
    }

    /// Infer the default zig type for a zag literal Expr. Returns "" for cases
    /// where zag has no type info (idents, calls, binary expressions, etc.) —
    /// the caller should emit no type annotation in those cases.
    fn inferZigTypeFromExpr(expr: ast.Expr) []const u8 {
        return switch (expr) {
            .int_lit => "i32",
            .float_lit => "f64",
            .bool_lit => "bool",
            .char_lit => "u8",
            .string_lit, .byte_string_lit => "[]const u8",
            else => "",
        };
    }

    /// Top-level elements of a destructurable source Expr. `.tuple_lit` and
    /// `.array_lit` produce real element slices; everything else (idents,
    /// calls, etc.) returns an empty slice to signal "can't infer leaf types
    /// at this depth — caller should emit no annotation".
    fn getTopElements(expr: ast.Expr) []const ast.Expr {
        return switch (expr) {
            .tuple_lit => |els| els,
            .array_lit => |a| a.elements,
            else => &[_]ast.Expr{},
        };
    }

    /// True when any leaf in `expr`'s subtree is a `.float_lit`. Used by
    /// `needsIntDivShim` (below) to decide whether the LHS of a `/` or `%`
    /// could be float-typed — float-typed LHSes can't go through zig's
    /// `@divTrunc`/`@rem` shim because those builtins require integer
    /// arguments. Idents/calls/etc. return false here because we can't
    /// inspect the user's binding type from the AST alone.
    fn exprContainsFloat(expr: ast.Expr) bool {
        return switch (expr) {
            .float_lit => true,
            .binary => |b| exprContainsFloat(b.lhs.*) or exprContainsFloat(b.rhs.*),
            .unary => |u| exprContainsFloat(u.operand.*),
            else => false,
        };
    }

    /// zig 0.16 promotes `i32 / comptime_int` (and `i32 % comptime_int`) to a
    /// hard error — the result type isn't decidable from the operands alone,
    /// so the compiler demands an explicit `@divTrunc` / `@rem` / `@divFloor`
    /// (or `@divExact`) call. Without the shim, the smoke-test
    /// `var x: i32 = 10; x /= 2;` produced an unrunnable zigzag because the
    /// generated `x = (x / 2);` triggered that rule.
    ///
    /// This predicate encodes the user-confirmed wrap rule: emit `@divTrunc` /
    /// `@rem` ONLY when
    ///   1. the operator is `.div` or `.mod`,
    ///   2. the RHS is a comptime int literal (`.int_lit`), AND
    ///   3. the LHS subtree is or could plausibly be integer-typed — i.e.
    ///      (a) LHS is itself an int literal (so the whole thing is comptime-
    ///          foldable — but in that case we DON'T wrap because zig folds
    ///          the bare form fine) OR (b) LHS could be runtime integer
    ///          (no `.float_lit` anywhere in the LHS subtree).
    ///
    /// The explicit "both sides comptime" carve-out in (3a) keeps the
    /// documentation promise that "floored/comptime cases can stay bare" —
    /// `1 / 2` keeps the bare `/` and zig folds to 0 at compile time.
    ///
    /// Caveat: without a type checker we can't tell an `xxx / 2` apart from
    /// `xxx / 2` where `xxx` is a f64 binding. The latter would miscompile
    /// under the shim because `@divTrunc(f64, …)` is not a valid call. User
    /// advice: if your LHS is float-typed, write the RHS as `2.0` instead of
    /// `2` so the shim predicate skips the wrap (RHS is not `.int_lit`).
    fn needsIntDivShim(b: ast.Expr.BinaryExpr) bool {
        if (b.op != .div and b.op != .mod) return false;
        if (b.rhs.* != .int_lit) return false;
        // Both sides comptime_int → zig folds the bare form at compile time.
        // Skip the shim so the user's source round-trips: `1 / 2 === (1 / 2)`.
        if (b.lhs.* == .int_lit) return false;
        return !exprContainsFloat(b.lhs.*);
    }

    fn genExpr(self: *Codegen, expr: ast.Expr) void {
        switch (expr) {
            .string_lit => |s| {
                self.write("\"");
                self.write(s);
                self.write("\"");
            },
            .byte_string_lit => |s| {
                self.write("\"");
                self.write(s);
                self.write("\"");
            },
            .char_lit => |s| {
                self.write(s);
            },
            .int_lit => |s| {
                self.write(s);
            },
            .float_lit => |s| {
                self.write(s);
            },
            .bool_lit => |b| {
                self.write(if (b) "true" else "false");
            },
            .null_lit => {
                self.write("null");
            },
            .undefined_lit => {
                self.write("undefined");
            },
            .tuple_lit => |elements| {
                if (elements.len == 0) {
                    self.write("{}");
                } else {
                    self.write(".{ ");
                    for (elements, 0..) |el, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(el);
                    }
                    self.write(" }");
                }
            },
            .array_lit => |a| {
                self.genArrayLit(a);
            },
            .template_lit => |t| {
                self.genTemplateLit(t, .buf_print);
            },
            .ident => |name| {
                self.write(name);
            },
            .call => |c| {
                if (std.mem.eql(u8, c.name, "print")) {
                    if (c.args.len == 1) {
                        switch (c.args[0]) {
                            .string_lit, .byte_string_lit => |str| {
                                // Literal string/byte-string: emit the bytes
                                // directly as the format string with no args.
                                self.write("std.debug.print(\"");
                                self.write(str);
                                self.write("\", .{})");
                            },
                            .char_lit => {
                                // Zig's `{}` formats `u8` as a numeric code
                                // point; use `{c}` to render the actual char.
                                self.write("std.debug.print(\"{c}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                            .array_lit => {
                                // Arrays don't accept `{}` in zig 0.16;
                                // `{any}` produces a debug-list of elements.
                                self.write("std.debug.print(\"{any}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                            .tuple_lit => {
                                // `{any}` produces a debug-formatted
                                // anonymous struct of the tuple fields.
                                self.write("std.debug.print(\"{any}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                            .template_lit => |t| {
                                self.genTemplateLit(t, .debug_print);
                            },
                            else => {
                                self.write("std.debug.print(\"{any}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                        }
                    }
                } else {
                    self.write(c.name);
                    self.write("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(arg);
                    }
                    self.write(")");
                }
            },
            .new_expr => |n| {
                self.write("blk: { var __val: ");
                self.write(n.type_name);
                self.write(" = ");
                self.genExpr(n.value.*);
                self.write("; break :blk &__val; }");
            },
            .free_expr => |f| {
                self.write("std.heap.page_allocator.destroy(");
                self.genExpr(f.target.*);
                self.write(")");
            },
            .deref => |d| {
                self.write("(&");
                self.genExpr(d.target_ptr.*);
                self.write(").*");
            },
            .unary => |u| {
                // Prefix operator — emitted verbatim with the operand
                // following naturally (no extra parens because prefix
                // operators bind tighter than any binary op downstream).
                // Codegen mirrors the parser's four prefix forms:
                //   `-x`  → `-<operand>`
                //   `~x`  → `~<operand>`
                //   `!x`  → `!<operand>`
                //   `*x`  → `<operand>.*`  (zig's post-fix deref)
                switch (u.op) {
                    .neg => self.write("-"),
                    .bnot => self.write("~"),
                    .lnot => self.write("!"),
                    .deref => {},
                }
                self.genExpr(u.operand.*);
                if (u.op == .deref) self.write(".*");
            },
            .index => |i| {
                // `target[index]` in zigzag source. Zig accepts bracket
                // access on both arrays and anonymous-struct tuples in
                // 0.16, so no method-call shimming is needed. Multi-dim
                // chains surface as nested `.index` nodes and emit
                // `arr[i][j]` verbatim via the recursion.
                self.genExpr(i.target.*);
                self.write("[");
                self.genExpr(i.index.*);
                self.write("]");
            },
            .range => |r| {
                // Range expression — emitted as an anonymous struct so
                // downstream consumer code can extract `.0` (start), `.1`
                // (end), `.2` (inclusive flag) on the resulting value. The
                // docs describe `Range<T>` as `{ start, end }` (no flag);
                // we surface `inclusive` here so a future `for i in 0..10`
                // iterator can read the flag without breaking. Codegen
                // does not require a zigzag-side type alias for Range —
                // the anonymous tuple is sufficient and self-describing.
                self.write(".{ ");
                self.genExpr(r.start.*);
                self.write(", ");
                self.genExpr(r.end.*);
                self.write(", ");
                self.write(if (r.inclusive) "true" else "false");
                self.write(" }");
            },
            .binary => |b| {
                // zig 0.16 shim (see `needsIntDivShim` doc above). When the
                // predicate fires for `.div`/`.mod` we route through
                // `@divTrunc`/`@rem` instead of emitting the bare
                // `(lhs / rhs)` form — otherwise zig 0.16 rejects the
                // generated source with "signed integers must use `@divTrunc`
                // or `@divFloor`" hard-error (the result type isn't
                // decidable when an `i32` divides a comptime_int). After the
                // wrap, control returns — the rest of the binary path is
                // unreachable for these two ops under the shim.
                if (needsIntDivShim(b)) {
                    self.write(if (b.op == .div) "@divTrunc(" else "@rem(");
                    self.genExpr(b.lhs.*);
                    self.write(", ");
                    self.genExpr(b.rhs.*);
                    self.write(")");
                    return;
                }
                // Emit `(lhs op rhs)` with parenthesisation so emitted
                // source respects the AST's precedence even if we eventually
                // loosen the parser ladder (e.g. add `||` short-circuit).
                self.write("(");
                self.genExpr(b.lhs.*);
                self.write(" ");
                switch (b.op) {
                    // arithmetic
                    .add => self.write("+"),
                    .sub => self.write("-"),
                    .mul => self.write("*"),
                    .div => self.write("/"),
                    .mod => self.write("%"),
                    // bitwise
                    .bitand => self.write("&"),
                    .bitor => self.write("|"),
                    .bitxor => self.write("^"),
                    .shl => self.write("<<"),
                    .shr => self.write(">>"),
                    // comparison (zig uses the same symbols)
                    .eq => self.write("=="),
                    .ne => self.write("!="),
                    .lt => self.write("<"),
                    .gt => self.write(">"),
                    .le => self.write("<="),
                    .ge => self.write(">="),
                    // logical (zig uses keyword forms — `and`, `or` — to
                    // distinguish from the bitwise `&`/`|` symbols)
                    .land => self.write("and"),
                    .lor => self.write("or"),
                    // The `_range` member exists for forward extensibility
                    // (BinaryOp is the dispatcher for any future binary
                    // shape) but the actual Range expression lives in
                    // Expr.range — codegen never reaches this case because
                    // the parser emits `.range` for `..`/...`.
                    ._range => unreachable,
                }
                self.write(" ");
                self.genExpr(b.rhs.*);
                self.write(")");
            },
        }
    }

    /// Emit a Zag array literal `[N]T { ... }` to its Zig counterpart.
    /// Three sub-forms:
    /// - **Explicit**:    `[N]T { v1, v2, ... }`         → `[N]T{ v1, v2, ... }`
    /// - **Fill**:        `[N]T { v ... }`               → `[1]T{ v } ** N`
    /// - **Progression**: `[N]T { v1, v2 ... }`         → `blk: { var __arr = ...; const __pat = .{v1,v2}; while (...) __arr[i] = __pat[i%K]; break :blk __arr; }`
    ///   The progression form repeats the explicit prefix cyclically until the
    ///   array is `N` long (i.e. `[4]i32 { 1, 2 ... }` yields `[1, 2, 1, 2]`).
    fn genArrayLit(self: *Codegen, a: ast.Expr.ArrayLitExpr) void {
        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{a.size}) catch "0";

        if (a.fill) {
            // `[1]T{ v } ** N` — Zig's repeat operator. The leading element is
            // present by grammar whenever `fill` is true.
            self.write("[1]");
            self.write(a.type_name);
            self.write("{ ");
            if (a.elements.len >= 1) self.genExpr(a.elements[0]);
            self.write(" } ** ");
            self.write(size_str);
            return;
        }

        if (a.progression) {
            const k = a.elements.len;
            self.write("(blk: { var __arr: [");
            self.write(size_str);
            self.write("]");
            self.write(a.type_name);
            self.write(" = undefined; ");
            if (k > 0) {
                self.write("const __pat: [");
                var k_buf: [16]u8 = undefined;
                const k_str = std.fmt.bufPrint(&k_buf, "{d}", .{k}) catch "0";
                self.write(k_str);
                self.write("]");
                self.write(a.type_name);
                self.write(" = .{ ");
                for (a.elements, 0..) |el, i| {
                    if (i > 0) self.write(", ");
                    self.genExpr(el);
                }
                self.write(" }; ");
                self.write("var __i: usize = 0; while (__i < ");
                self.write(size_str);
                self.write(") : (__i += 1) __arr[__i] = __pat[__i % ");
                self.write(k_str);
                self.write("]; ");
            }
            self.write("break :blk __arr; })");
            return;
        }

        // Explicit list: `[N]T{ v1, v2, ..., vK }`.
        self.write("[");
        self.write(size_str);
        self.write("]");
        self.write(a.type_name);
        self.write("{ ");
        for (a.elements, 0..) |el, i| {
            if (i > 0) self.write(", ");
            self.genExpr(el);
        }
        self.write(" }");
    }

    const TemplateCtx = enum { debug_print, buf_print };

    /// Emit a Zag string-interpolation template literal.
    ///
    /// - `.debug_print`: emit `std.debug.print("<fmt>", .{args})` directly. This
    ///   is the path used as the first arg to `print(...)`.
    /// - `.buf_print`: emit a block that produces `[]u8` via `std.fmt.bufPrint`
    ///   into the module-level scratch buffer. Successive independent
    ///   template-literal expressions race on the buffer (intended for one-shot
    ///   use, not long-lived retention).
    ///
    /// The format string is built up char-by-char with a *minimal* escape set:
    /// only `"`, LF, CR, and TAB bytes are escaped — these are the bytes that
    /// would otherwise break a Zig string literal in the generated source. We
    /// deliberately do NOT re-escape the `\` byte: the Zag lexer keeps the
    /// user's intended escape sequences intact (e.g. `\n` in source stays
    /// `\n` in the lexer text), and the lexer's text round-trips byte-for-byte
    /// through Zig's source-level escape decoding.
    fn genTemplateLit(self: *Codegen, t: ast.Expr.TemplateLitExpr, ctx: TemplateCtx) void {
        var fmt_buf: [4096]u8 = undefined;
        var fmt_len: usize = 0;
        var args_cg = Codegen.init();
        var first_arg = true;

        for (t.parts) |part| {
            if (part.literal) |lit| {
                for (lit) |c| {
                    switch (c) {
                        '"' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = '"';
                                fmt_len += 2;
                            }
                        },
                        0x0A => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 'n';
                                fmt_len += 2;
                            }
                        },
                        0x0D => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 'r';
                                fmt_len += 2;
                            }
                        },
                        0x09 => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 't';
                                fmt_len += 2;
                            }
                        },
                        else => {
                            if (fmt_len < fmt_buf.len) {
                                fmt_buf[fmt_len] = c;
                                fmt_len += 1;
                            }
                        },
                    }
                }
            } else if (part.expr) |expr| {
                // `{any}` accepts any Zig type at the format-arg site. If the
                // user wrote a printf-style format spec (e.g. `:.5`, `:5`,
                // `:x`), we append it verbatim after `{any}` so zig's debug
                // formatter produces the requested precision/width/format.
                // Empirical zig 0.16 testing confirmed `{any:.N}` IS honoured
                // for numeric values (zig applies the spec to the underlying
                // numeric type when the value is rendered via the `{any}`
                // argument slot — the Spec slot follows the same rules as it
                // would on a type-specific placeholder).
                if (fmt_len + 5 <= fmt_buf.len) {
                    fmt_buf[fmt_len] = '{';
                    fmt_len += 1;
                    fmt_buf[fmt_len] = 'a';
                    fmt_len += 1;
                    fmt_buf[fmt_len] = 'n';
                    fmt_len += 1;
                    fmt_buf[fmt_len] = 'y';
                    fmt_len += 1;
                    if (part.spec) |spec| {
                        if (fmt_len + 1 + spec.len <= fmt_buf.len) {
                            fmt_buf[fmt_len] = ':';
                            fmt_len += 1;
                            for (spec) |c| {
                                fmt_buf[fmt_len] = c;
                                fmt_len += 1;
                            }
                        }
                    }
                    fmt_buf[fmt_len] = '}';
                    fmt_len += 1;
                }
                if (!first_arg) args_cg.write(", ");
                args_cg.genExpr(expr);
                first_arg = false;
            }
        }

        switch (ctx) {
            .debug_print => {
                self.write("std.debug.print(\"");
                self.write(fmt_buf[0..fmt_len]);
                self.write("\", .{");
                self.write(args_cg.out_buf[0..args_cg.out_len]);
                // Zig 0.16 requires a trailing comma inside the anonymous
                // struct literal `.{…}` even when only one field is present;
                // `.{x}` is interpreted as `.{ x }` (no field) and rejected
                // with "expected ',' after field". Append `,` whenever any
                // arg was written so single-arg and multi-arg calls both
                // produce a parseable anonymous struct.
                if (args_cg.out_len > 0) self.write(",");
                self.write("})");
            },
            .buf_print => {
                // Borrow into the module-level scratch buffer; this avoids the
                // dangling-pointer pitfall of returning a slice into a block-
                // local `var`. Multiple independent template_lit expressions
                // would race on this buffer, so standalone template_lit is
                // appropriate only when each value is consumed before the next
                // assignment (e.g. `print((blk: { ... })  .*)` is wrong; use
                // single-arg `print("...{x}...")` instead).
                self.write("(blk: { const __tmp = std.fmt.bufPrint(__zag_interp_buf[0..], \"");
                self.write(fmt_buf[0..fmt_len]);
                self.write("\", .{");
                self.write(args_cg.out_buf[0..args_cg.out_len]);
                self.write("}) catch __zag_interp_buf[0..0]; break :blk __tmp; })");
            },
        }
    }
};
