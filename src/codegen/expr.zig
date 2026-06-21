const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;
const needsIntDivShim = @import("primary.zig").needsIntDivShim;

// ============================================================
// FILE-SCOPE methods (EXPR bucket)
// ============================================================

    pub     fn genExpr(self: *Codegen, expr: ast.Expr) void {
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
            .single_tuple_lit => |el_ptr| {
                // Single-element tuple `(x,)` — emit `.{ x }`. The
                // trailing-comma disambiguator from paren-grouping
                // was detected at parse time; codegen just lifts the
                // captured expression verbatim into a one-element
                // anonymous-struct literal.
                self.write(".{ ");
                self.genExpr(el_ptr.*);
                self.write(" }");
            },
            .named_tuple_lit => |nt| {
                // Named-tuple literal `(x: 10, y: 20)` — emit
                // `.{ .x = 10, .y = 20 }`. zig 0.16 accepts named-field
                // init on anonymous-struct literals and field-name lookup
                // via `.x` (which is the same shape as struct-field
                // access). The names are emitted verbatim so the
                // round-trip test (sources's `point.x` access → codegen's
                // `.x = 10` literal) is byte-exact.
                self.write(".{ ");
                for (nt.elements, 0..) |el, i| {
                    if (i > 0) self.write(", ");
                    self.write(".");
                    self.write(nt.names[i]);
                    self.write(" = ");
                    self.genExpr(el);
                }
                self.write(" }");
            },
            .array_lit => |a| {
                self.genArrayLit(a);
            },
            .template_lit => |t| {
                self.genTemplateLit(t, .buf_print);
            },
            .closure => |cl| {
                // Phase 2 (docs/15 §"Closures"): emit the closure as an
                // anonymous-struct-instance literal whose zig type
                // exposes exactly one `call(args) RET` method.
                // Example `let double = |x: i32| -> i32 { return x *
                // 2; };` emits `(struct { pub fn call(x: i32) i32 {
                // return x * 2; } }){}` — the outer `(struct {...}){}`
                // is a fresh anonymous-struct value, and the `call`
                // method captures the user's closure body verbatim.
                // The let-binding's `isClosureBound` retrieval (set by
                // `collectTypedBindings` on `.closure` init) routes any
                // subsequent `double(args)` call site through
                // `<name>.call(args)` via the `.call` arm above.
                //
                // Empty `params` and `null` return_type are accepted:
                // `|| { print("hi"); }` -> `(struct { pub fn call()
                // void { ... } }){}`. Without an explicit return type,
                // zig's type inference picks `void` for the body shape
                // `{}` and refuses to return a value; if the user
                // needs a returned value, the docs require the
                // explicit `-> T` annotation.
                self.write("(struct { pub fn call(");
                for (cl.params, 0..) |p, i| {
                    if (i > 0) self.write(", ");
                    self.write(p.name);
                    self.write(": ");
                    self.write(p.type_text);
                }
                self.write(") ");
                if (cl.return_type) |rt| self.write(rt) else self.write("void");
                self.write(" {\n");
                for (cl.body) |s| self.genStmt(s, false);
                self.write("    } }){}");
            },
            .ident => |name| {
                self.write(name);
            },
            .call => |c| {
                if (std.mem.eql(u8, c.name, "print")) {
                    self.genPrintCall(c);
                } else if (self.isClosureBound(c.name)) {
                    // Phase 2 (docs/15 §"Closures"): rewrite a closure-
                    // bound callee into a method-call on the closure's
                    // anonymous-struct instance. Without this rewrite
                    // zig emits `<name>(<args>)` and rejects with
                    // "expected type expression, found '('" because
                    // closures are anonymous-struct values that don't
                    // act as free fns. The rewrite produces
                    // `<name>.call(<args>)` which zig accepts as a
                    // struct method dispatch (each closure's codegen
                    // shape defines exactly one `call(args) RET`
                    // method).
                    self.write(c.name);
                    self.write(".call(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(arg);
                    }
                    self.write(")");
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
                // Heap-allocation rewrite (the bug fix exposing the docs
                // / spec contract for `new`). Each `new T(value)` now
                // allocates via `std.heap.page_allocator.create(T)` so the
                // returned pointer is a real owning heap pointer rather
                // than a stack-local address that would dangle as soon as
                // the surrounding block exits. Codegen uses a per-function
                // counter so the synthetic `__p_<N>` names never collide
                // when a body has multiple `new` expressions.
                //
                // The `try` propagates `OutOfMemory` through the enclosing
                // `pub fn main() !void { … }` signature emitted by
                // `genFun`. For the custom-allocator sugar `new(<arena>,
                // T(value))` we route through `<arena>.create(T)` instead
                // so per-request arena allocations land in the user-supplied
                // arena (e.g. HTTP-request lifecycles that `defer
                // arena.free_all()`).
                const id = self.alloc_counter;
                self.alloc_counter += 1;
                var name_buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "__p_{d}", .{id}) catch "__p";
                self.write("blk: { const ");
                self.write(name);
                if (n.allocator) |alloc_name| {
                    self.write(" = try ");
                    self.write(alloc_name);
                    self.write(".create(");
                } else {
                    self.write(" = try std.heap.page_allocator.create(");
                }
                self.write(n.type_name);
                self.write("); ");
                self.write(name);
                self.write(".* = ");
                self.genExpr(n.value.*);
                self.write("; break :blk ");
                self.write(name);
                self.write("; }");
            },
            .cast => |c| {
                // `expr as T` — emit as Zig's `@as(T, expr)` builtin.
                // zig 0.16 does not have an `as` keyword (it was a
                // pre-0.14 deprecation; modern zig routes all explicit
                // coercions through `@as(type, value)` and the related
                // `@ptrCast` / `@intCast` family). Emitting the
                // parenthesised `(expr as T)` form that the prior
                // comment promised was rejected by zig 0.16 with
                // `expected ')'` (the `as` token isn't a known infix op
                // so zig parses `(` … saw `as` … saw `f32` and
                // deduces an unfinished sub-expression).
                //
                // The parser's `collectCastType` joined multi-token
                // types like `*raw c_void` / `*const T` into the one
                // `type_text` slice stored on the AST node, so emitting
                // `@as(*raw c_void, val)` / `@as(*const T, val)` works
                // verbatim for far-cast paths. The expression side is
                // emitted via the existing `genExpr` recursion so binary
                // and unary LHSes (e.g. `(a + b) as f32`) surface as
                // `@as(f32, (a + b))` with their internal precedence
                // bindings intact.
                self.write("@as(");
                self.write(c.type_text);
                self.write(", ");
                self.genExpr(c.expr.*);
                self.write(")");
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
                // Codegen mirrors the parser's five prefix forms:
                //   `-x`  → `-<operand>`
                //   `~x`  → `~<operand>`
                //   `!x`  → `!<operand>`
                //   `*x`  → `<operand>.*`  (zig's post-fix deref)
                //   `&x`  → `&<operand>`  (zig's address-of; result type is
                //           `*T` for mutable bindings, `*const T` for
                //           immutable bindings — the source-of-address binding
                //           kind is preserved through zig's type inference)
                switch (u.op) {
                    .neg => self.write("-"),
                    .bnot => self.write("~"),
                    .lnot => self.write("!"),
                    .deref => {},
                    .addr => self.write("&"),
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
            .slice => |s| {
                // `target[start..end]` (or variants like `target[..end]`,
                // `target[start..]`, `target[..]`). Codegen emits zig's
                // native slicing syntax verbatim — zig 0.16 lowers
                // `arr[a..b]` directly to a `[]T` slice value with the
                // layout `{ ptr: *T, len: usize }`, no shim needed.
                // Inclusive (`a...b`) ranges get a `+ 1` adjustment so
                // the half-open-slice lowering matches zag's inclusive
                // intent; the no-end forms (`[..]`, `[N..]`, `[N...]`)
                // skip the end expression entirely so the half-open
                // semantics cover "to end of array" without inventing a
                // synthetic `len` Expr.
                self.genExpr(s.target.*);
                self.write("[");
                if (s.start) |st| self.genExpr(st.*);
                self.write("..");
                if (s.end) |en| {
                    self.genExpr(en.*);
                    if (s.inclusive) self.write(" + 1");
                }
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
            .if_expr => |ife| {
                // `if cond { … } else { … }` expression form. Emitted as a
                // labeled block + two `break :blk` arms so the whole
                // construct yields a value without forcing zig's `if` to
                // be the only shape. The outer parens make this a
                // parenthesised expression so the caller can use it in any
                // expression position (RHS of let, binary operand, etc.).
                // Pointer fields are dereferenced because IfExpr carries
                // `*Expr` to break the Expr-size type cycle (see the
                // `IfExpr`/IfExpr.doc in ast.zig).
                //
                // Same outer-paren caveat as `.if_stmt`: genExpr already
                // wraps `.binary`, so do NOT emit literal `(` / `)` around
                // the cond here either. The shared outer `(blk: { … })`
                // parenthesisation is sufficient.
                self.write("(blk: { if ");
                self.genExpr(ife.cond.*);
                self.write(" break :blk ");
                self.genExpr(ife.then_expr.*);
                self.write(" else break :blk ");
                self.genExpr(ife.else_expr.*);
                self.write("; })");
            },
            .match_expr => |m| {
                // Same laddered emission as the statement-position form.
                // Just rendered without a trailing semicolon because the
                // caller is embedding us in a larger expression (e.g. the
                // RHS of a let binding).
                self.genMatchExpr(m);
            },
            .struct_lit => |sl| {
                // `Type { .f1 = v1, .f2 = v2, }` — emit zig's named-struct
                // literal form (NO leading dot — `.TypeName { … }` is the
                // anonymous-struct form, and `TypeName { .f = … }` is the
                // named-struct form). The fields are emitted in
                // declaration order so the emitted source preserves the
                // user's initialization order (matters for tests that
                // assert the exact field-position sequence).
                self.write(sl.type_name);
                self.write("{ ");
                for (sl.inits, 0..) |fi, i| {
                    if (i > 0) self.write(", ");
                    self.write(".");
                    self.write(fi.name);
                    self.write(" = ");
                    self.genExpr(fi.value.*);
                }
                self.write(" }");
            },
            .enum_variant_ctor => |evc| {
                // zig 0.16 REJECTS the prior emission `Enum.Variant(arg)`
                // for payload-bearing variants with `type '@typeInfo(...).@"union".tag_type.?' not a function`.
                // The canonical form is the tagged-union-init literal:
                //   bare variant   (args.len == 0)  → `Enum.Variant`            (works in 0.16)
                //   single-arg payload             → `Enum{ .Variant = arg }`   (literal-arg form)
                //   multi-arg payload              → `Enum{ .Variant = .{ a, b } }` (anonymous-struct arg)
                // The unqualified case (enum_name == null) drops the `Enum`.
                // prefix so zig's type-inference picks the enum from the
                // binding's `: T` annotation when present.
                if (evc.args.len == 0) {
                    // Bare tag-only — function-style works as a value
                    // expression in zig 0.16 (no parens).
                    if (evc.enum_name) |en| {
                        self.write(en);
                        self.write(".");
                    }
                    self.write(evc.variant_name);
                } else if (evc.enum_name) |en| {
                    // Qualified payload variant — tagged-union-init.
                    // zig 0.16 rejects positional `Shape{ .Rect = .{ 3.0, 4.0 } }`
                    // (`type 'Shape__struct_NNNN' does not support array
                    // initialization syntax`). The accepted form is NAMED-
                    // field init `.Rect = .{ .a = x, .b = y }` because
                    // genEnumDecl emits the payload struct with named
                    // fields (a, b, c, ...) for multi-type payloads.
                    self.write(en);
                    self.write("{ .");
                    self.write(evc.variant_name);
                    self.write(" = ");
                    if (evc.args.len == 1) {
                        self.genExpr(evc.args[0]);
                    } else {
                        // Named-field init via letter sequence (a, b, c, ...)
                        // matching `genEnumDecl`'s per-variant struct-field
                        // naming. zig forwards each literal to the named
                        // struct field at the matching letter position.
                        const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
                        self.write(".{ ");
                        for (evc.args, 0..) |arg, i| {
                            if (i > 0) self.write(", ");
                            self.write(".");
                            self.write(letters[i]);
                            self.write(" = ");
                            self.genExpr(arg);
                        }
                        self.write(" }");
                    }
                    self.write(" }");
                } else {
                    // Unqualified payload variant — zig infers target
                    // type from the binding's `: T` annotation. Same
                    // named-field init as the qualified branch.
                    self.write(".{ .");
                    self.write(evc.variant_name);
                    self.write(" = ");
                    if (evc.args.len == 1) {
                        self.genExpr(evc.args[0]);
                    } else {
                        const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
                        self.write(".{ ");
                        for (evc.args, 0..) |arg, i| {
                            if (i > 0) self.write(", ");
                            self.write(".");
                            self.write(letters[i]);
                            self.write(" = ");
                            self.genExpr(arg);
                        }
                        self.write(" }");
                    }
                    self.write(" }");
                }
            },
            .member_access => |ma| {
                // `target.name` — emit `target.name` verbatim because
                // zig's struct-field-access syntax is the user-visible
                // surface form (no transformation needed). For nested
                // targets (calls, indices, other member-accesses), the
                // recursive genExpr call walks the chain depth-first so
                // `getBox().width` emits as `getBox().width`, `arr[i].len`
                // as `arr[i].len`, etc.
                self.genExpr(ma.target.*);
                self.write(".");
                self.write(ma.name);
            },
            .method_call => |mc| {
                // `target.name(args...)` — emit verbatim because zig
                // supports both the value-receiver form (e.g. `v.length()`
                // where v: Vec3) and the type-static constructor form
                // (e.g. `Vec3.new(1, 2, 3)`) natively without zag needing a
                // type resolver. The struct emission NESTED the impl
                // methods INSIDE `pub const Name = struct { pub fn … }`
                // so zig sees the receiver method and the type-static
                // constructor as distinct methods of the same zig type.
                // Args are comma-separated and emitted verbatim via the
                // existing `genExpr` recursion.
                self.genExpr(mc.target.*);
                self.write(".");
                self.write(mc.name);
                self.write("(");
                for (mc.args, 0..) |a, i| {
                    if (i > 0) self.write(", ");
                    self.genExpr(a);
                }
                self.write(")");
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
                if (needsIntDivShim(self, b)) {
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
