const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;
// Phase 0 codegen-router table: src/codegen/builtins.zig holds the
// `builtin_table` consulted by the `.call` and `.method_call` arms
// BEFORE the verbatim fallback. Phase 0 ships with the table EMPTY
// so this lookup is a no-op; Phase 1 (argv_get, env_var, fs_read_file)
// and Phase 2+ widenings append entries to the table and matching
// inline `switch (dispatch) case` arms in `genBuiltinCall` below.
// The @import path is sibling-bucket (zig 0.16's module-local
// resolution picks up src/codegen/builtins.zig automatically -- no
// src/codegen.zig aggregator edit needed, mirror of how stmt.zig and
// decl.zig peer-references each other without a parent module).
const builtins = @import("builtins.zig");
const needsIntDivShim = @import("primary.zig").needsIntDivShim;
// Cross-bucket alias-resolution import (docs/07 "Type Aliases",
// docs/11 borrowed-string-view). Same pattern as the
// `needsIntDivShim` import above: a sibling-bucket helper made
// available by file-scope re-export rather than re-implementing.
// See `zagTypeToZig` in src/codegen/decl.zig for the alias set
// and the in-line-guard rationale. Used at the closure-literal
// emit site (params + return) and the `.cast` emit site so that
// `|x: str| -> str { ... }` round-trips to `pub fn call(x:
// []const u8) []const u8 { ... }` and `x as str` to
// `@as([]const u8, x)` without zig ever seeing a bare `str`
// ident.
const zagTypeToZig = @import("decl.zig").zagTypeToZig;

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
                    self.write(zagTypeToZig(p.type_text));
                }
                self.write(") ");
                if (cl.return_type) |rt| self.write(zagTypeToZig(rt)) else self.write("void");
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
                } else if (builtins.lookup(c.name, c.args.len)) |dispatch| {
                    // Phase 0 codegen-router: when the call name +
                    // arity match a builtin route, fire the
                    // matched dispatch's inline zig-emit instead of
                    // the verbatim `<name>(<args>)` form. Phase 0
                    // ships with builtin_table EMPTY so this branch
                    // is dead-code-by-design (zig's comptime
                    // unreachable-check will catch any future skipped
                    // case in `genBuiltinCall`'s switch). Each
                    // registered entry writes directly into out_buf
                    // via genBuiltinCall; the inline emit shape is
                    // per-dispatch (argv_get emits a blk wrapper,
                    // fs_read_file emits a `catch &[_]u8{}` for error
                    // collapse, env_var wraps `orelse null` around
                    // std.os.getenv's `?[:0]const u8`). See
                    // src/codegen/builtins.zig for the per-dispatch
                    // contract; changes to the table are NOT silently
                    // absorbed -- a future Phase must add the matching
                    // genBuiltinCall case simultaneously or zig will
                    // hard-error at compile time (the switch is
                    // exhaustiveness-checked).
                    self.genBuiltinCall(dispatch, c.args);
                } else {
                    // Generics (docs/16 §"Turbofish"):
                    // `name<type_args...>(regular_args...)` emits
                    // `name(type_args..., regular_args...)` so the
                    // comptime args come BEFORE runtime args (zig's
                    // `comptime` parameter convention). When
                    // `type_args` is empty, the call shape is identical
                    // to the non-generic legacy path so existing
                    // 213-baseline tests are preserved untouched.
                    // Type-arg slices are verbatim source text (e.g.
                    // `["i32"]` for `max<i32>(3, 5)` or `["i32", "10"]`
                    // for `fill<i32, 10>(0)`); corgen passes them
                    // through unchanged so zig's compile-time arg
                    // matching handles the dispatch. Wrap through
                    // `zagTypeToZig` so the v1 alias contract
                    // (docs/07: `str` is transparent alias for
                    // `[]const u8`) extends to turbofish sites — a
                    // hypothetical `max<str>(...)` round-trips to
                    // `max([]const u8)(...)` instead of zig rejecting
                    // with `unknown type name "str"`.
                    self.write(c.name);
                    self.write("(");
                    for (c.type_args, 0..) |ta, i| {
                        if (i > 0) self.write(", ");
                        self.write(zagTypeToZig(ta));
                    }
                    if (c.args.len > 0 and c.type_args.len > 0) self.write(", ");
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
                self.write(zagTypeToZig(n.type_name));
                self.write("); ");
                self.write(name);
                self.write(".* = ");
                self.genExpr(n.value.*);
                self.write("; break :blk ");
                self.write(name);
                self.write("; }");
            },
            .cast => |c| {
                // Phase 3 trait-cast (docs/17 §"Using Traits"): when
                // the cast's `type_text` matches a tracked trait name
                // (populated from `prog.traits` at `generate()`
                // entry) AND the operand is an `.ident` whose
                // source-type was captured by `collectTypedBindings`
                // (so we can identify the vtable registration's
                // `<SourceType>` slot), the user-facing cast
                // `btn as Drawable` produces a fat-pointer container:
                //
                //     Drawable {
                //         .ptr = @ptrCast(&btn),  // or @ptrCast(btn_p) for pointer source
                //         .vtable = &Drawable_VTable_for_Button,
                //     }
                //
                // The trait-cast branch fires BEFORE the legacy
                // `@as(T, expr)` emit so non-trait casts (e.g.
                // `x as i32`, `x as *T`) preserve their old shape
                // byte-identical. The pointer detection strips a
                // leading `*`/`*const` from `source_type` to derive the
                // bare type name used in the vtable registration
                // (`<Trait>_VTable_for_<BareType>`). Source-tokens
                // without a `*` prefix get an implicit `&` so the
                // `@ptrCast` accepts the resulting `*T` slot. v1
                // minimum subset restricts the operand to `.ident`
                // only — more complex sources like `get_btn().as Trait`
                // would require a type-inferer to identify the
                // source; deferred to a Phase 4 widening.
                if (self.isTrackedTrait(c.type_text) and c.expr.* == .ident) {
                    const source_ident = c.expr.*.ident;
                    if (self.getSourceTypeName(source_ident)) |source_type| {
                        // Strip leading `*` markers and the `const`
                        // qualifier from the source-type so the
                        // vtable registration name uses the bare
                        // type name (`*Button` → `Button`,
                        // `*const Foo` → `Foo`). Mutability never
                        // affects vtable layout so the `const` is
                        // safe to drop.
                        var base_type = source_type;
                        while (base_type.len > 0 and base_type[0] == '*') base_type = base_type[1..];
                        if (base_type.len >= 6 and std.mem.eql(u8, base_type[0..6], "const ")) base_type = base_type[6..];
                        const is_pointer_source = base_type.len < source_type.len;
                        // Emit fat-pointer container — the cast
                        // itself (no `@as` wrapper) because zig's
                        // struct-literal type inference picks up
                        // `Drawable` from the trailing-without-dot
                        // leading-identifier in the cast-arm shape.
                        self.write(c.type_text);
                        self.write("{ .ptr = @ptrCast(");
                        if (!is_pointer_source) self.write("&");
                        self.write(source_ident);
                        self.write("), .vtable = &");
                        self.write(c.type_text);
                        self.write("_VTable_for_");
                        self.write(base_type);
                        self.write(" }");
                        return;
                    }
                }
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
                //
                // Float-family carve-out (the bug fix exposed by
                // examples/types/primitives.zag `pi as f32`): when the
                // cast target is a float type (`f16`/`f32`/`f64`) AND
                // the operand is a float-typed `.ident` (verified via
                // the per-function `type_info_buf` populated by
                // `collectTypedBindings`), emit zig 0.16's single-arg
                // `@floatCast(<value>)` form. The target type is
                // inferred from the enclosing binding's `: T`
                // annotation (e.g. `let half: f32 = pi as f32;` →
                // `const half: f32 = @floatCast(pi);`); the literal
                // f64 rounds to f32 per IEEE 754 with no overflow
                // error. For ALL other float-target operands (int-lit,
                // binary/call/member-access RHS, untyped idents, ...)
                // the legacy `@as(target, value)` form is the safe
                // default — zig 0.16's `@as` accepts widening cleanly
                // (`@as(f64, i32_var)` works) and accepts comptime
                // coercion of `.int_lit` and `.float_lit` operands via
                // implicit type-resolution. The previous `@as(f32,
                // f64_var)` rejection only fires for lossy narrowing
                // from a runtime-float source, which is the precise
                // case the typed-binding lookup catches. Non-float
                // targets (`i32`, `*T`, `str`→`[]const u8`, trait
                // names, ...) keep the legacy `@as(target, value)` path
                // untouched so the existing `codegen: as cast emits
                // @as builtin` and trait-cast tests stay byte-stable.
                //
                // Known limitation (deferred): narrowing casts whose
                // RHS is a non-`.ident` expression (e.g.
                // `(a + b) as f32` where `a + b` is evaluated at
                // runtime) fall through to `@as(target, value)` and
                // zig will reject the same way it rejected
                // `@as(f32, f64_var)`. A fix would require a
                // recursive operand-type walker; the v1 surface
                // passes the common ident-RHS shape (which the
                // user-reported bug exposes) and a followup can
                // widen to `.binary` / `.call` operands once the
                // expression-type-resolution infrastructure lands.
                const target_zig = zagTypeToZig(c.type_text);
                if (core.isFloatTypeName(target_zig) and c.expr.* == .ident) {
                    const op_ident = c.expr.*.ident;
                    if (self.getSourceTypeName(op_ident)) |source_type| {
                        if (core.isFloatTypeName(source_type)) {
                            // Single-arg form: zig infers target from
                            // the enclosing binding's `: T` annotation
                            // OR the rhs-coercion position.
                            self.write("@floatCast(");
                            self.genExpr(c.expr.*);
                            self.write(")");
                            return;
                        }
                    }
                }
                self.write("@as(");
                self.write(target_zig);
                self.write(", ");
                self.genExpr(c.expr.*);
                self.write(")");
            },
            .free_expr => |f| {
                // Phase 2.1: slice-vs-pointer discriminator (closes
                // examples/stdlib/fs.zag's leak-tolerance caveat from
                // Phase 2). The cached typed-binding info from
                // `collectTypedBindings` at fn entry (src/codegen/stmt.zig:27)
                // gives us the source-side `:T` annotation text per ident
                // binding. When the free target is a bare `.ident` whose
                // typed-binding entry starts with `[]` (slice-shaped:
                // `[]u8`, `[]const u8`, `[]T`, ...) or is exactly `str`
                // (the docs/07 transparent alias for `[]const u8`), emit
                // `page_allocator.free(<ident>)` so the heap-owned slice
                // from `read_file` (Phase 2) gets a matching deallocator.
                //
                // Fall-back to `page_allocator.destroy(<expr>)` for:
                //   - Pointer-typed slots — the existing v1 `new T(v)`
                //     surface (`let p = new i32(42); defer free p;` from
                //     allocation.zag).
                //   - Untyped bindings (no `: T` annotation, so no entry
                //     lands in `type_info_buf` for the ident). User can
                //     opt in to the slice overload by adding `: []u8` or
                //     `: str` to the let.
                //   - Non-ident operands: `free read_file("p")` (free-of-
                //     call), `free buf[..5]` (free-of-slice), `free getBox()`
                //     (free-of-method-call), `free arr[i]` (free-of-index),
                //     `free (x as *T)` (free-of-cast). Without a type-
                //     resolver we conservatively route these through the
                //     pointer overload — users wanting slice-deallocation
                //     on these forms bind the result to an annotated ident
                //     first.
                //
                // Discriminator cost: O(type_info_count) per `free` site.
                // Count is bounded by O(small) per fn so per-call cost is
                // negligible. No helper-factor (a 1-shot block is cheaper
                // than a named fn + extra stack frame on every free site).
                const use_slice_free = blk: {
                    const t = f.target.*;
                    if (t != .ident) break :blk false;
                    const tn = self.getSourceTypeName(t.ident) orelse break :blk false;
                    // Slice-shaped: leading `[]` covers `[]u8`, `[]const
                    // u8`, `[]T`, and any future `[]<qualifier> T` shape.
                    if (tn.len >= 2 and tn[0] == '[' and tn[1] == ']') break :blk true;
                    // Transparent alias `str` → `[]const u8` per docs/07.
                    if (std.mem.eql(u8, tn, "str")) break :blk true;
                    break :blk false;
                };
                if (use_slice_free) {
                    self.write("std.heap.page_allocator.free(");
                } else {
                    self.write("std.heap.page_allocator.destroy(");
                }
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
                // zig 0.16 REJECTS a leading `..` in any indexing
                // expression — `arr[..]`, `arr[..end]`, AND
                // `arr[..end+1]` (inclusive) all surface `expected
                // expression, found '..'`. The no-start slice form
                // ALWAYS needs a synthetic `0` anchor to satisfy zig's
                // `arr[a..b]` slice grammar. The prior carve-out
                // `else if (s.end == null) { self.write("0"); }`
                // only handled the `arr[..]` (both-null) case; the
                // `arr[..end]` half-open form silently fell through
                // to a bare `..end` emit that zig rejected — this is
                // the `pointers.zag` line-58 failure exposed by the
                // v1.3 drift-cleanup bundled test. Collapsing the two
                // null-start arms into a single `else` branch unifies
                // the synthetic-0 prefix across BOTH no-start shapes
                // (both-null + half-open-with-end) so zig consistently
                // sees `arr[0..end]` regardless of which no-start
                // variant the user authored.
                if (s.start) |st| {
                    self.genExpr(st.*);
                } else {
                    self.write("0");
                }
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
                //
                // Phase 3 (CLI migration) followup: wrap the type name
                // through `zagTypeToZig` so the v1 transparent-alias
                // contract (`str` becomes `[]const u8`, etc.) extends to
                // struct-literal sites. Without this wrap, a struct
                // literal whose type name contains a bare `str` (or any
                // other aliased identifier) emits the unaliased name to
                // zig and zig rejects it with `undeclared identifier
                // 'str'`. The wrap is a no-op for type names that don't
                // contain a tracked alias (e.g. `Point`, `Vec3`),
                // matching the `.call` / `.method_call` arm's existing
                // wrap-on-turbofish-only pattern but applied
                // unconditionally because struct-literal type names
                // are the user-visible type, not a type-param slot.
                self.write(zagTypeToZig(sl.type_name));
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
                    //
                    // Gap #2 brace-named-field carve-out (lookup-side):
                    // when the user declared the variant as
                    // `Drag { x: f64, y: f64 }`, genEnumDecl emits the
                    // payload struct with the user's ACTUAL field names
                    // (`struct { x: f64, y: f64 }`) — NOT the legacy
                    // alphabetical scheme (`struct { a: f64, b: f64 }`).
                    // The legacy ctor emit `.{ .a = x, .b = y }` would
                    // be rejected by zig because the named fields are
                    // `x, y`, not `a, b`. We look up the brace-named
                    // field list via `lookupVariantFields` (populated at
                    // emit time in genEnumDecl) and use those names
                    // instead. Misses (the enum was declared paren-
                    // positional rather than brace-named, OR the enum
                    // lives in an imported module — see lookupVariantFields
                    // doc for cross-module deferral) fall through to the
                    // legacy alphabetical emit which is correct for the
                    // paren-positional shape `Rect(f64, f64)`.
                    self.write(en);
                    self.write("{ .");
                    self.write(evc.variant_name);
                    self.write(" = ");
                    const brace_fields = self.lookupVariantFields(en, evc.variant_name);
                    if (brace_fields) |bf| {
                        // Brace-named-field ctor: emit `.{ .x = a,
                        // .y = b }` with the user's literal names.
                        // Single-arg and multi-arg forms share the
                        // same named-init shape; zig's named-struct
                        // literal accepts both with the field-name
                        // 0-list being any subset.
                        self.write(".{ ");
                        for (bf, 0..) |f, fi| {
                            if (evc.args.len <= fi) break;
                            if (fi > 0 and evc.args.len > fi) self.write(", ");
                            self.write(".");
                            self.write(f.name);
                            self.write(" = ");
                            self.genExpr(evc.args[fi]);
                        }
                        self.write(" }");
                    } else if (evc.args.len == 1) {
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
                    // type from the binding's `: T` annotation. Gap #6
                    // brace-named-field carry-over (gap-closure land):
                    // when `lookupVariantFieldsByName` finds EXACTLY ONE
                    // brace-named entry matching `evc.variant_name` (i.e.
                    // unambiguously one enum in the program declared the
                    // variant as brace-named), the unqualified ctor
                    // `Pos { x: 2.0, y: 3.0 }` round-trips to the same
                    // `.{ .Pos = .{ .x = 2.0, .y = 3.0 } }` shape as the
                    // qualified branch. Zero matches OR multiple matches
                    // fall through to the legacy positional emit below
                    // (the multi-match case produces a zig 0.16 diagnostic
                    // because the brace-declared variants' struct fields
                    // are user-named, not the single-letter `a`/`b`/...
                    // sequence) — Option-B collision strategy per the
                    // gap-closure design call.
                    self.write(".{ .");
                    self.write(evc.variant_name);
                    self.write(" = ");
                    const brace_fields = self.lookupVariantFieldsByName(evc.variant_name);
                    if (brace_fields) |bf| {
                        // Brace-named-field emit (single-match path).
                        // Same shape as the qualified branch's brace
                        // emit `.{ .x = a, .y = b }` so zig's tagged-
                        // union-init accepts both forms identically.
                        self.write(".{ ");
                        for (bf, 0..) |f, fi| {
                            if (evc.args.len <= fi) break;
                            if (fi > 0 and evc.args.len > fi) self.write(", ");
                            self.write(".");
                            self.write(f.name);
                            self.write(" = ");
                            self.genExpr(evc.args[fi]);
                        }
                        self.write(" }");
                    } else if (evc.args.len == 1) {
                        self.genExpr(evc.args[0]);
                    } else {
                        // Legacy positional/letter-named init (only
                        // reached when the variant was declared as the
                        // paren-positional form OR when collision was
                        // detected by `lookupVariantFieldsByName`).
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
                // Raw-pointer arithmetic methods (p.add(N) / q.offset(p))
                // — zig-fallback emit because zig has no .add /
                // .offset method on `*raw T`. Both forms re-emit the
                // target expression three times (zig's `@TypeOf` is
                // compile-time so the re-emission is cached at
                // comptime). Arity-checked to exactly 1 arg; wrong-
                // arity call sites fall through to the verbatim emit
                // so zig reports "no method named 'add'" with high-
                // quality diagnostics rather than zig's panic-on-
                // arity in codegen. Codegen doesn't have a type-
                // resolver so the bytecode is emitted regardless of
                // whether the target's binding annotation is `*raw T`
                // — the user's "fall back to Zig" brief is honoured
                // by letting zigzag's type checker catch non-`*raw T`
                // accidental uses (zig 0.16 will reject a numeric
                // stride offset on an owning pointer at type-check).
                if (mc.args.len == 1) {
                    if (std.mem.eql(u8, mc.name, "add")) {
                        // p.add(N) -> @as(@TypeOf(p), @ptrFromInt(@intFromPtr(p) + N * @sizeOf(@typeInfo(@TypeOf(p)).pointer.child)))
                        // The `@typeInfo(@TypeOf(p)).pointer.child` strip
                        // is critical: `@sizeOf(@TypeOf(p))` returns the
                        // POINTER size (8 on 64-bit for `*raw u8`), not
                        // the POINTE size (1 for u8). Without the strip,
                        // `p.add(2)` on `p: *raw u8` advances by 16 bytes
                        // instead of 2. The strip is symmetric on the
                        // offset branch (the divisor should also be the
                        // pointee stride).
                        self.write("@as(@TypeOf(");
                        self.genExpr(mc.target.*);
                        self.write("), @ptrFromInt(@intFromPtr(");
                        self.genExpr(mc.target.*);
                        self.write(") + ");
                        self.genExpr(mc.args[0]);
                        self.write(" * @sizeOf(@typeInfo(@TypeOf(");
                        self.genExpr(mc.target.*);
                        self.write(")).pointer.child)))");
                        return;
                    }
                    if (std.mem.eql(u8, mc.name, "offset")) {
                        // q.offset(p) -> (@intFromPtr(q) - @intFromPtr(p)) / @sizeOf(@typeInfo(@TypeOf(q)).pointer.child)
                        // Pointee-stride divisor (see `.add` comment for
                        // the `@typeInfo` strip rationale).
                        // Paren balance: 6 opens (outer `(`, two
                        // `@intFromPtr(`, `@sizeOf(`, `@typeInfo(`,
                        // `@TypeOf(`) and 6 closes — the trailing
                        // `)).pointer.child)` sequence closes
                        // @TypeOf, @typeInfo (via `.pointer.child)`),
                        // and @sizeOf. The prior emit shape was an
                        // over-correction (an EXTRA trailing `)`
                        // after `.pointer.child`) producing 6 opens
                        // + 7 closes. The unbalanced leaf tripped
                        // zig's parser on examples/memory/pointers.zag's
                        // `q.offset(p)` call site; removing the extra
                        // `)` restores 6+6 balance.
                        self.write("(@intFromPtr(");
                        self.genExpr(mc.target.*);
                        self.write(") - @intFromPtr(");
                        self.genExpr(mc.args[0]);
                        self.write(")) / @sizeOf(@typeInfo(@TypeOf(");
                        self.genExpr(mc.target.*);
                        self.write(")).pointer.child)");
                        return;
                    }
                }
                // Phase 0 codegen-router: when the receiver-prefix
                // (e.target.* must be `.ident` for this path) + the
                // method name + the arity match a registered builtin
                // route, fire the matched dispatch's inline zig-emit
                // and `return;` so the verbatim form below is never
                // executed for this call. Phase 0 ships with
                // builtin_table EMPTY so this branch is dead-code
                // (mirrors the .call arm above); future Phase entries
                // extend `builtins.builtin_table` and the matching
                // genBuiltinCall switch case. The early `return;` is
                // required because the verbatim emit below doesn't
                // fall through to a sentinel -- it writes to self.out_buf
                // inline -- and skipping it preserves the existing
                // emit shape for non-builtin method calls.
                if (mc.target.* == .ident) {
                    if (builtins.lookupWithRecv(mc.target.*.ident, mc.name, mc.args.len)) |dispatch| {
                        self.genBuiltinCall(dispatch, mc.args);
                        return;
                    }
                }
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
                //\n                // Phase 3 trait dispatch (docs/17 §"Using Traits"): the\n                // user supplies the vtable's source-type via turbofish\n                // at the call site so the dispatch shim's `comptime T:\n                // type` parameter resolves to the registered\n                // source-type — `d.draw<Button>()` emits `d.draw(Button)`\n                // which binds Button to the shim's `T` placeholder\n                // (the shim discards T via `_ = T;` and forwards to\n                // the vtable slot). Empty type_args keeps the verbatim\n                // `target.method(args)` emit shape so non-turbofish\n                // call sites round-trip byte-identical with the\n                // pre-Phase-3 baseline. Wrap through `zagTypeToZig`\n                // so turbofish on a trait call site honours the\n                // docs/07 transparent-alias contract (`str` becomes\n                // `[]const u8`) identically to the `.call` arm.
                self.genExpr(mc.target.*);
                self.write(".");
                self.write(mc.name);
                self.write("(");
                for (mc.type_args, 0..) |ta, i| {
                    if (i > 0) self.write(", ");
                    self.write(zagTypeToZig(ta));
                }
                if (mc.args.len > 0 and mc.type_args.len > 0) self.write(", ");
                for (mc.args, 0..) |a, i| {
                    if (i > 0) self.write(", ");
                    self.genExpr(a);
                }
                self.write(")");
            },
            .binary => |b| {
                // zig 0.16 string-comparison shim. The bare `(lhs == rhs)`
                // form is rejected by zig 0.16 when both operands are
                // `[]const u8` (slices don't implement `==` by default
                // — only single-value types do, and slices are
                // fat-pointer aggregates). The existing `emitPatternCond`
                // for `match` arms already handles this via
                // `std.mem.eql(u8, scrut, "lit")`; the `.binary` arm
                // extends the same surface to any expression position
                // (if-condition, while-condition, return-RHS, let-RHS,
                // binary-operand nested position). Heuristic: when the
                // operator is `.eq` or `.ne` AND at least one operand
                // is a `.string_lit` (the common pattern `cmd == "help"`,
                // `name != "anonymous"`, etc.), we route through
                // `std.mem.eql(u8, lhs, rhs)` (with a leading `!` for
                // `.ne`). Non-string-literal operands (e.g. two bare
                // `[]const u8` idents) fall through to the default
                // `(lhs == rhs)` emit — the heuristic intentionally
                // does NOT guess at the operand's type because we lack
                // a type-resolver in codegen. Users wanting equality
                // between two slice idents bind one to a `str` literal
                // first (or we add a `slice_eq` builtin in a followup).
                if (b.op == .eq or b.op == .ne) {
                    if (b.lhs.* == .string_lit or b.rhs.* == .string_lit) {
                        if (b.op == .ne) self.write("!");
                        // Phase 3 (CLI migration) followup: the string-
                        // comparison shim is wrapped in an outer `(` / `)`
                        // so the emit shape `(std.mem.eql(u8, lhs, rhs))`
                        // carries its own parens. The previous bare
                        // `std.mem.eql(...)` emit was rejected by zig in
                        // `if`-condition position (`if std.mem.eql(...) {`
                        // → `expected '(', found 'an identifier'`) because
                        // the surrounding `.if_stmt` / `.while_stmt` arms
                        // intentionally do NOT add outer parens (they
                        // rely on the `.binary` codegen path's existing
                        // wrap to keep the docs/06 single-paren surface).
                        // The AST tag is still `.binary` (the parser
                        // doesn't rewrite the expr), so any
                        // AST-tag-based outer-paren discriminator at
                        // the call site is fooled — wrapping HERE
                        // restores the assumed invariant (every `.binary`
                        // emit is parenthesized) without forcing every
                        // call site to re-inspect the emit shape.
                        self.write("(std.mem.eql(u8, ");
                        self.genExpr(b.lhs.*);
                        self.write(", ");
                        self.genExpr(b.rhs.*);
                        self.write("))");
                        return;
                    }
                }
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

    // Phase 0 codegen-router helper. Called from the `.call` and
    // `.method_call` arms above when `builtins.lookup(...)` returns
    // a non-null dispatch. Each switch arm emits the inline zig
    // shim that lowers the free-fn form to a direct zig stdlib
    // invocation. Phase 0 ships argv_get as the only wired entry;
    // env_var and fs_read_file @panic at runtime so a future release
    // adding them to the table without wiring the helper case fails
    // LOUDLY at the user's host invocation (not silently falling
    // through to the verbatim form which would emit undeclared-name
    // errors downstream).
    //
    // zig's comptime switch is exhaustiveness-checked: a FUTURE
    // BuiltinDispatch variant that's missing its case here would
    // hard-error at this file's COMPILE pass (zig requires all
    // enum variants to be handled or an `_ => ...` else clause).
    // Adding a new dispatch must be paired with the matching helper
    // emit in the same commit, otherwise the zig compile fails
    // before the runtime test can run. The runtime `@panic` is the
    // SECOND line of defense for cases where the variant IS handled
    // but the body is stubbed out — catches the
    // "table populated, case hit, but body not implemented" footgun
    // at the user's host invocation with a self-documenting message.
    //
    // Earlier draft used `@compileError` here, but zig 0.16 fires
    // @compileError at .zig compile time WHENEVER the containing
    // function is compiled, not when reached at runtime — which
    // would have blocked Phase 0's existing helper from compiling
    // even though the stubbed arms were never reached. `@panic`
    // is the runtime-only equivalent that preserves the loud-fail
    // when-reached intent without the compile-time false positive.
    pub     fn genBuiltinCall(self: *Codegen, dispatch: builtins.BuiltinDispatch, args: []const ast.Expr) void {
        switch (dispatch) {
            .argv_get => {
                // zig 0.16 main-signature migration: argv is no
                // longer accessible at runtime via a raw slice
                // (`std.os.argv` and `std.posix.argv` were both
                // removed). The canonical idiom is to capture
                // `init.minimal.args.toSlice(allocator)` at main
                // entry (see `genFun` in decl.zig, which special-
                // cases the main function to accept
                // `init: std.process.Init` and store the result in
                // the module-level `__zag_argv` global). The
                // `.argv_get` dispatch is now a simple reference
                // to that global -- no per-call blk wrapper, no
                // 32-slot cap (the slice is already bounded by the
                // actual argc), no `std.mem.span` coercion
                // (toSlice already returns the right type). The
                // `argv_counter` field and per-call `__argv_<N>`
                // temps have been retired (this commit completes
                // the dead-counter cleanup alongside env_counter,
                // write_file_counter, mkdir_counter, and
                // exec_counter).
                self.write("__zag_argv");
            },
            .env_var => {
                // Phase 1 router: real emit shape for the env_var
                // dispatch. The bridge is intentionally minimal: copy
                // the user-side name arg into a sentinel-terminated
                // stack buffer via `std.posix.toPosixPath`, pass that
                // buffer's pointer to `std.posix.system.getenv`, and
                // convert the non-null arm's `[*:0]u8` pointer to a
                // `[]const u8` slice via `std.mem.span`. The end
                // result is the zag-side `?[]const u8` shape (the
                // docs/11 borrowed-string-view contract: non-null is a
                // sentinel-terminated slice to a process-owned buffer
                // — users wanting heap ownership must copy or convert).
                //
                // Per-call scoping: each env_var invocation steps
                // env_counter and emits a fresh `__env_<N>` result
                // variable + per-call `__env_<N>_z` sentinel buffer
                // ref. Sibling getEnv calls in the same body produce
                // distinct names (zig's no-redeclaration rule would
                // reject a clash). The counter resets at the top of
                // each function body (genFun + genMethod +
                // genFreeMethod in decl.zig).
                // Emit a (blk: { ... }) wrapper that
                //   1. allocates a fresh `var __env_<N>: ?[]const u8 = null;`
                //   2. tries to copy the user-side name arg into a
                //      sentinel-terminated buffer via toPosixPath (the
                //      if-let [|__env_<N>_z|] silently degrades to
                //      `null` on PATH-too-long without bubbling);
                //   3. passes `&__env_<N>_z` (the inner-`[]:0`u8` array
                //      pointer) to `std.posix.system.getenv` — the `&`
                //      coerces `*[PATH_MAX-1:0]u8` to `[*:0]const u8`
                //      for the libc-or-syscall layer's argument shape;
                //   4. on non-null inner if-let, sets `__env_<N> =
                //      std.mem.span(__s)` which widens the
                //      sentinel-terminated pointer to the zag-side
                //      `[]const u8` slice shape.
                //   5. `break :blk __env_<N>` yields the nullable slice
                //      out of the blk to the zag call site.
                //
                // The double-`if-let` (vs a single `if-let {|n|
                // try...else null`) preserves the docs/11 borrow
                // contract — neither arm produces a heap allocation,
                // both arms stay on the borrowed env-block storage
                // managed by the OS, and the user's copy/convert
                // decision is left at the call site.
                // Const-cast rationale (the v1 caveat). Two cast
                // points: (a) `&__env_<N>_z` is `*[4095:0]u8`
                // (mutable) but `std.posix.system.getenv` expects
                // `[*:0]const u8` — zig 0.16 will not implicitly
                // coerce `*[N:0]u8` → `[*:0]const u8`, hence
                // `@constCast(&__env_<N>_z)`. (b) `std.mem.span(__s)`
                // where `__s: [*:0]u8` resolves to the mutable slice
                // overload that returns `[]u8`; assigning into the
                // outer `?[]const u8` slot requires `@constCast` for
                // the same reason. The const-cast is sound on both
                // sides — the underlying storage is the OS-managed
                // env-block which is logically read-only for the
                // lifetime of the process, so we are just restoring
                // the const-ness the OS ABI would have offered if
                // zig exposed a const-native getenv return type
                // (it doesn't, by design — libc's `getenv` returns
                // the mutable pointer for in-place modification).
                // zig 0.16: std.posix.toPosixPath, std.posix.system.getenv,
                // and std.mem.span were all retired. std.posix.getenv is the
                // canonical replacement — takes []const u8 directly, returns
                // ?[:0]const u8. The @as(?[]const u8, ...) coerces the
                // sentinel-terminated optional into the docs/11 borrowed-
                // string-view shape zag exposes.
                self.write("blk: { break :blk @as(?[]const u8, std.posix.getenv(");
                self.genExpr(args[0]);
                self.write(")); }");            },
            .fs_read_file => {
                // Phase 2 router: real emit shape for the fs_read_file
                // dispatch. zig 0.16's `std.Io.Dir.readFileAlloc` (which
                // RETIRED the legacy `std.fs.cwd().readFileAlloc` form —
                // the 21-line `vendor/zig/lib/std/fs.zig` is a deprecation
                // stub) requires an active `Io` event-loop instance. We
                // construct one per call via `std.Io.Threaded.init` so
                // each `read_file(path)` invocation owns a fresh Io
                // context, leveraging zig's per-scope-stack-allocation
                // for the `Threaded` struct itself + RAII via `defer
                // __io_threaded.deinit()` to tear down the thread pool,
                // signal handlers (`SIG.IO` / `SIG.PIPE`), environ scan
                // scratch, and the random/pipe/null file handles the
                // Threaded impl caches.
                //
                // Allocator: `std.heap.page_allocator` mirrors the
                // existing `.new_expr` codegen path so heap-owned
                // ownership policy stays consistent (user must free via
                // `std.heap.page_allocator.free(slice)` before
                // discarding; Phase 2.1 widening will add a `free
                // <slice>` overload to `.free_expr` so the .zag
                // surface gets a cleaner `defer free data` syntax).
                // Memory ownership of the returned `[]u8` is the
                // caller; page-aligned leaks at process exit are
                // acceptable for short-lived zag binaries.
                //
                // Error collapse: `catch &[_]u8{}` silently coalesces
                // every path of the triple-union error set
                // (`Io.Dir.Reader.Error || std.mem.Allocator.Error ||
                // Io.UnexpectedError`) into an empty-slice. The docs/18
                // error-propagation contract isn't here yet — Phase 3
                // may add a sibling `read_file_or` builtin that bubbles
                // `error.FileNotFound` etc. via zag's `?` operator. v1
                // surface keeps read_file simple: empty slice on
                // failure, heap-allocated bytes on success, no error
                // channel.
                //
                // Per-call scoping: each fs_read_file invocation steps
                // fs_counter and emits a fresh `__fs_<N>` scratch —
                // sibling read_file calls in the same body produce
                // distinct names (zig's no-redeclaration rule would
                // reject a clash). The counter is reset at the top of
                // each function body (genFun + genMethod +
                // genFreeMethod in decl.zig).
                //
                // NOTE: no `_ = args` suppression is needed — mirror
                // the rationale on `.argv_get` and `.env_var` above.
                const id = self.fs_counter;
                self.fs_counter += 1;
                var name_buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "__fs_{d}", .{id}) catch "__fs_0";

                // Init order is LIFO at scope exit: `defer
                // __io_threaded.deinit()` registers at construction
                // time and runs AFTER `break :blk` captures the slice
                // into the call site, so the Io's thread pool +
                // signal handlers outlive the readFileAlloc call but
                // are torn down before the surrounding block exits.
                // The init is infallible (any CpuCountError is stored
                // on `t.cpu_count_error`, NOT raised); no `catch` is
                // needed.
                self.write("blk: { var __io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{}); defer __io_threaded.deinit(); const ");
                self.write(name);
                self.write(": []u8 = std.Io.Dir.cwd().readFileAlloc(__io_threaded.io(), ");
                self.genExpr(args[0]);
                self.write(", std.heap.page_allocator, .unlimited) catch &[_]u8{}; break :blk ");
                self.write(name);
                self.write("; }");
            },
            .fs_write_file => {
                // Phase 3 (CLI migration) router: per-call (blk: { \u2026 })
                // wrapper that opens the path via `std.posix.toPosixPath`
                // (the same shape `env_var` uses for libc getenv) then
                // `std.posix.openat(WRONLY|CREAT|TRUNC, 0o644)` + a per-
                // chunk write loop. Returns 0 on success, -1 on any open
                // or write failure (the cli.zag init handler treats -1
                // as "scaffolding failed" and exits with code 1).
                // zig 0.16: `std.posix.openat`, `std.posix.write`, and
                // `std.posix.close` were all retired. `std.fs.cwd().createFile`
                // is the canonical replacement — takes a `[]const u8` path,
                // returns a `File` handle with `writeAll` and `close` methods.
                // The `.truncate = true` flag matches the prior
                // `O_WRONLY|O_CREAT|O_TRUNC` behavior. Single `writeAll` call
                // replaces the per-chunk write loop (small files only — the
                // cli.zag init boilerplate is < 100 bytes).
                // zig 0.16 STUB: the vendored stdlib's std.fs / std.Io.Dir /
                // std.posix.s API surface diverges significantly from standard
                // zig 0.16. The real implementation requires either:
                //   (a) an Io event-loop handle (std.Io.Dir.createFile needs
                //       dir, io, sub_path, flags), or
                //   (b) raw std.posix.openat(AT_FDCWD, ...) with a
                //       null-terminated stack buffer for the path.
                // Both are substantial refactors deferred to a followup
                // commit once the vendored stdlib surface stabilises. For
                // now, emit a clear runtime error so the user sees what's
                // missing instead of a zig panic.
                // The .len and .ptr references consume args[0] and args[1]
                // so zig doesn't flag them as unused locals in the caller
                // (e.g. cli.zag's `let boilerplate = ...; write_file(p, boilerplate)`).
                // zig 0.16: std.Io.Dir.cwd().createFile(io, path, flags)
                // opens a file at the current working directory. writePositionalAll
                // (offset=0) replaces the per-chunk write loop. close on defer
                // is the v1 RAII shape.
                self.write("blk: { const __wf_file = std.Io.Dir.cwd().createFile(__zag_io, ");
                self.genExpr(args[0]);
                self.write(", .{ .truncate = true }) catch break :blk -1; defer __wf_file.close(__zag_io); __wf_file.writePositionalAll(__zag_io, ");
                self.genExpr(args[1]);
                self.write(", 0) catch break :blk -1; break :blk @as(i32, 0); }");
            },
            .fs_mkdir => {
                // Phase 3 (CLI migration) router: per-call (blk: { ... })
                // via toPosixPath + std.posix.mkdir. EEXIST silently
                // coalesced (matches cli.zag init's "mkdir -p" semantics);
                // other failures surface as -1.
                // zig 0.16: `std.posix.mkdir` and `std.posix.mkdirat` were
                // both retired. `std.fs.cwd().makeDir` is the canonical
                // replacement — takes a `[]const u8` path, returns
                // `PathAlreadyExists` on duplicate (which we silently
                // coalesce to match cli.zag's `mkdir -p` semantics). Other
                // failures (permission denied, ENOSPC) surface as -1.
                // zig 0.16 STUB: see .fs_write_file above for the full
                // rationale. The real implementation needs std.Io.Dir.makeDir
                // or std.posix.mkdir with null-terminated path. Deferred.
                // zig 0.16: std.Io.Dir.cwd().createDir(io, sub_path, permissions)
                // creates a directory. PathAlreadyExists is silently coalesced
                // to 0 (cli.zag init's "mkdir -p" semantics); other failures
                // surface as -1. Permissions default to .{} (0o755 via the
                // std.Io.Dir.createDir default).
                self.write("blk: { std.Io.Dir.cwd().createDir(__zag_io, ");
                self.genExpr(args[0]);
                // zig 0.16: std.Io.File.Permissions is an enum (not a
                // raw integer) on POSIX, with two named variants:
                // .default_file = 0o666 and .default_dir = 0o777. The
                // enum has a `_ =>` catch-all for any other mode_t
                // value, so @enumFromInt(0o755) would also work, but
                // .default_dir is the idiomatic stdlib choice for
                // directory creation (rwxrwxrwx; the owner's write
                // bit is implicit since they just created the dir).
                self.write(", .default_dir) catch |e| { if (e != error.PathAlreadyExists) break :blk -1; }; break :blk @as(i32, 0); }");
            },
            .process_exec => {
                // Phase 3 (CLI migration) router: per-call (blk: { ... })
                // that does fork+execve+waitpid with env read from
                // /proc/self/environ on every invocation. Returns the
                // child's exit code (255 on parent fork failure, 127 on
                // child execve failure, otherwise W.EXITSTATUS).
                // Phase 3 (CLI migration) router: per-call (blk: { ... })
                // wrapper. The opening `{` is REQUIRED — every other dispatch
                // helper in this switch (argv_get, env_var, fs_read_file,
                // fs_write_file, fs_mkdir) emits `blk: { ... }` with the brace;
                // .process_exec is the only one that emitted `blk:\n` (no
                // brace), causing zig to parse the body's `var __exec_0_arg_bufs`
                // line as a malformed statement after a label-named `blk:`
                // (the `expected 'var' or 'const' before variable declaration`
                // error seen on the bootstrap). Adding `{` here restores
                // consistency with the other dispatch-helper shapes.
                // zig 0.16: std.posix.fork, std.posix.execve, std.posix.waitpid,
                // std.posix.openat, std.posix.close, and the /proc/self/environ
                // scanning were all retired. std.process.Child is the canonical
                // replacement — takes []const []const u8 argv, inherits the
                // parent environment automatically, and spawnAndWait returns
                // a Term enum with .Exited(code) for normal exit. The catch
                // handles spawn failure (255), and the else arm covers
                // signal/stop/abort exits (also 255).
                // zig 0.16 STUB: std.process.Child no longer has .allocator
                // or .argv fields. The real API is std.process.spawn(io,
                // SpawnOptions) returning a Child, or std.process.run(gpa,
                // io, RunOptions) returning a RunResult. Both require an
                // Io event-loop handle. Deferred to a followup commit.
                // 255 (not -1) matches the shell convention for exec failure
                // ("command not found"). The .len reference consumes args[0]
                // so zig doesn't flag it as unused in the caller.
                // zig 0.16: std.process.run(gpa, io, RunOptions) wraps spawn+wait
                // and returns a RunResult with .term (a Term union: .Exited(code)
                // for normal exit, .Signal/.Stopped/.Aborted for the else arm).
                // 255 (not -1) matches the shell convention for exec failure.
                // The page_allocator is used for the run's internal scratch
                // (stdout/stderr capture buffers); the call returns when the
                // child exits so the leak is bounded to the run duration.
                self.write("blk: { var __child = std.process.spawn(__zag_io, .{ .argv = ");
                self.genExpr(args[0]);
                self.write(" }) catch break :blk 255; defer __child.kill(__zag_io); const __term = __child.wait(__zag_io) catch break :blk 255; switch (__term) { .exited => |__c| break :blk @as(i32, __c), else => break :blk 255, } }");
            },
            .process_exit => {
                // Phase 3 (CLI migration) router: bare statement-shaped
                // emit. Outer parens let it work in both statement and
                // expression positions. @as(u8, @intCast(...)) clamps
                // i32 to one byte since std.os.linux.exit only takes u8.
                // No per-call counter needed (no temp names).
                self.write("(std.os.linux.exit(@as(u8, @intCast(");
                self.genExpr(args[0]);
                self.write("))))");
            },
        }
    }
