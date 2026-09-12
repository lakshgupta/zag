const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;
// Phase 0 codegen-router table: src/codegen/builtins.zig holds the
// `builtin_table` consulted by the `.call` and `.method_call` arms
// BEFORE the verbatim fallback. Phase 0 ships with the table EMPTY
// so this lookup is a no-op; Phase 1 (argv_get, env_var)
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

    /// Overloaded trait-method call-site suffix (docs/manual/18
    /// §"Overloaded trait methods"): a trait declaring the same
    /// method name more than once gets its VTable fields suffixed
    /// `render_0` / `render_1` (traitMethodVtableName). Every trait
    /// value's dispatch shim owns a distinct zig method per overload
    /// (arity is the only overload dimension), so the argument count
    /// alone picks the vtable field. Unique names return null — the
    /// verbatim emit stays byte-identical for the non-overloaded
    /// baseline.
    pub     fn traitOverloadSuffix(self: *Codegen, trait_name: []const u8, method_name: []const u8, arg_count: usize) ?[]const u8 {
        const td = self.traitDeclByName(trait_name) orelse return null;
        var dup_count: usize = 0;
        for (td.methods) |tm| {
            if (std.mem.eql(u8, tm.name, method_name)) dup_count += 1;
        }
        if (dup_count <= 1) return null;
        // `self` is the implicit receiver; user args follow it. The
        // FIRST overload whose user-arity matches wins (declaration
        // order — matches traitMethodVtableName's `_N` indexing).
        for (td.methods, 0..) |tm, tmi| {
            if (!std.mem.eql(u8, tm.name, method_name)) continue;
            if (tm.params.len < 1 or tm.params.len - 1 != arg_count) continue;
            // Declaration-order index among same-name overloads.
            var dup_idx: usize = 0;
            var total: usize = 0;
            for (td.methods, 0..) |tm2, ti2| {
                if (std.mem.eql(u8, tm2.name, method_name)) {
                    if (ti2 < tmi) dup_idx += 1;
                    total += 1;
                }
            }
            // Instance intern pool (single-threaded compiler): the
            // returned suffix is a slice that must outlive this call
            // until the caller writes it — a shared static buffer was
            // aliased by back-to-back suffix lookups.
            var scratch: [16]u8 = undefined;
            const sfx = std.fmt.bufPrint(&scratch, "_{d}", .{dup_idx}) catch return null;
            return self.internedSuffixName(sfx);
        }
        return null;
    }

    /// Lookup companion for traitOverloadSuffix: the tracked trait
    /// decl by source name, or null. Mirrors isTrackedTrait's walk
    /// shape but returns the decl so dispatch sites can read the
    /// method list without re-walking prog.traits in the caller.
    pub     fn traitDeclByName(self: *Codegen, name: []const u8) ?ast.TraitDecl {
        for (self.prog.traits) |td| {
            if (std.mem.eql(u8, td.name, name)) return td;
        }
        return null;
    }

    /// True when ANY impl method named `method_name` on target type
    /// `type_name` takes a mutable `self: *T` receiver (vs
    /// `self: *const T`). Consulted before emitting `&ident` at a
    /// `obj.Trait.method(...)` direct-dispatch call site: a `let`
    /// binding's address is `*const T`, and zig rejects passing it
    /// to a `*T` parameter as const-discard — the caller wraps the
    /// address in `@constCast`. A no-op verdict for `*const T`
    /// receivers keeps the qualifier (zig accepts `*const` →
    /// `*const`). Bounded walk over prog.impls; false when no impl
    /// matches (unreachable for a resolved binding — the qualifier
    /// call site only fires after the trait method resolved).
    /// Type-agnostic variant of methodTakesMutableSelf: true when ANY
    /// impl in the program provides `method_name` with a mutable
    /// `self: *T` receiver. Used by the verbatim method-call emit —
    /// codegen has no full type resolver, so the receiver's concrete
    /// type may be unknown (embedded forwarders, stdlib types); the
    /// @constCast wrap is a no-op on mutable bindings and the only
    /// correct shape for `let`-bound receivers of `*T` methods.
    pub     fn methodTakesMutableSelfanyType(self: *Codegen, method_name: []const u8) bool {
        for (self.prog.impls) |impl| {
            for (impl.methods) |m| {
                if (!std.mem.eql(u8, m.name, method_name)) continue;
                if (m.params.len == 0) continue;
                if (std.mem.startsWith(u8, m.params[0].type_text, "*const")) return false;
                if (std.mem.startsWith(u8, m.params[0].type_text, "*")) return true;
            }
        }
        return false;
    }

    pub     fn methodTakesMutableSelf(self: *Codegen, type_name: []const u8, method_name: []const u8) bool {
        for (self.prog.impls) |impl| {
            if (!std.mem.eql(u8, impl.target_type, type_name)) continue;
            for (impl.methods) |m| {
                if (!std.mem.eql(u8, m.name, method_name)) continue;
                if (m.params.len == 0) continue;
                if (std.mem.startsWith(u8, m.params[0].type_text, "*const")) return false;
                if (std.mem.startsWith(u8, m.params[0].type_text, "*")) return true;
            }
        }
        return false;
    }

    pub     fn genExpr(self: *Codegen, expr: ast.Expr) void {
        if (expr.loc.line > 0) self.recordLoc(expr.loc, "");
        switch (expr.payload) {
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
                    // Empty tuple `()` — zig 0.16 types bare `{}` as
                    // `void`, which `@call(.auto, f, args)` rejects
                    // ("expected a tuple, found 'void'") at std.Thread
                    // spawn sites. `.{ }` is the canonical empty-tuple
                    // literal (an anonymous struct with zero fields).
                    self.write(".{ }");
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
                // Phase 2 (zig 0.16 closure-as-method dispatch):
                // pre-Phase-2 emit `(struct { pub fn call(x: i32) i32 { ... } }){}`
                // which zig 0.16 rejected when the call-site was `instance.call(x)`:
                // `call` was a static (namespace) function because it lacked a
                // self-shaped parameter, so zig told us `no field or member
                // function named 'call' in 'instance_type'`. The simplest fix is
                // to prepend `_: @This()` — a self-shaped but unused parameter —
                // so zig recognizes `call` as a member function bound to the
                // struct instance and dispatches `instance.call(x)` correctly.
                // `_:` keeps the unused param quiet (no `unused variable` warning).
                self.write("(struct { pub fn call(_: @This()");
                // Unconditional `, ` separator: `_: @This()` is always the first
                // parameter so the user-supplied params always follow it with
                // a leading comma. Empty `cl.params` (e.g. `||  { ... }`) emits
                // cleanly because the loop body never executes and the trailing
                // `") "` closes the signature with just `_: @This()`.
                for (cl.params) |p| {
                    self.write(", ");
                    self.write(p.name);
                    self.write(": ");
                    self.writeType(p.type_text);
                }
                self.write(") ");
                if (cl.return_type) |rt| self.writeType(rt) else self.write("void");
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
                } else if (std.mem.indexOfScalar(u8, c.name, '.')) |dot| {
                    // Dotted call `list.len()`: the template-literal
                    // placeholder parser builds dotted callees as
                    // `.call` with name "list.len" (not `.method_call`
                    // — its extraction is a token-scan, not the full
                    // postfix chain). Route generic instances through
                    // the same free-fn dispatch as the method_call
                    // arm so `print("{list.len()}")` doesn't emit the
                    // verbatim (non-existent) member call. The
                    // non-generic fallback emits the call verbatim —
                    // this branch is an else-if TERMINAL, so a
                    // non-generic dotted call MUST emit here or the
                    // arg tuple ends up empty.
                    const recv = c.name[0..dot];
                    const meth = c.name[dot + 1 ..];
                    var dispatched = false;
                    if (self.getSourceTypeName(recv)) |tn| {
                        if (self.genericInstanceOfTypeText(tn)) |gi| {
                            if (self.genericStructModulePath(gi.base)) |mod_path| {
                                self.write("@import(\"");
                                self.write(mod_path);
                                self.write("\").");
                            }
                            self.write(gi.base);
                            self.write("_");
                            self.write(meth);
                            self.write("(");
                            for (gi.args, 0..) |ga, i| {
                                if (i > 0) self.write(", ");
                                self.writeType(ga);
                            }
                            if (gi.args.len > 0) self.write(", ");
                            // `&<recv>` wrapped in @constCast: a const
                            // capture (zig optional-capture `|v|`) would
                            // otherwise produce `*const T`, rejected as
                            // const-discard by the `*T` orphan receiver.
                            // No-op on mutable bindings.
                            if (!gi.is_pointer) {
                                self.write("@constCast(&");
                                self.write(recv);
                                self.write(")");
                            } else {
                                self.write(recv);
                            }
                            for (c.args) |a| {
                                self.write(", ");
                                self.genExpr(a);
                            }
                            self.write(")");
                            dispatched = true;
                        }
                    }
                    if (!dispatched) {
                        // Union orphan-method dispatch for dotted callees
                        // (`print("{ClickEvent.is_action(hover)}")` — the
                        // template-literal placeholder parser token-scans
                        // dotted calls into `.call` with name
                        // "ClickEvent.is_action", not `.method_call`).
                        // Same rewrite as the `.method_call` arm below:
                        // union impl methods flatten to module-scope free
                        // fns `<Union>_<Method>`.
                        if (self.tryEmitUnionOrphanCall(recv, meth, c.args)) {
                            dispatched = true;
                        }
                    }
                    if (!dispatched) {
                        // docs/manual/18 §"Overloaded trait methods" —
                        // dotted-callee mirror of the `.method_call`
                        // trait-value dispatch: a trait-typed receiver
                        // gets the overload-suffixed vtable shim
                        // (`r.render_0()`); plain receivers stay verbatim.
                        if (self.getSourceTypeName(recv)) |rtn| {
                            var rtrait: []const u8 = rtn;
                            if (std.mem.startsWith(u8, rtrait, "*const ")) rtrait = rtrait["*const ".len..];
                            if (std.mem.startsWith(u8, rtrait, "*")) rtrait = rtrait["*".len..];
                            if (self.isTrackedTrait(rtrait)) {
                                if (self.traitOverloadSuffix(rtrait, meth, c.args.len)) |sfx| {
                                    self.write(recv);
                                    self.write(".");
                                    self.write(meth);
                                    self.write(sfx);
                                    self.write("(");
                                    for (c.args, 0..) |arg, i| {
                                        if (i > 0) self.write(", ");
                                        self.genExpr(arg);
                                    }
                                    self.write(")");
                                    dispatched = true;
                                }
                            }
                        }
                    }
                    if (!dispatched) {
                        self.write(c.name);
                        self.write("(");
                        for (c.args, 0..) |arg, i| {
                            if (i > 0) self.write(", ");
                            self.genExpr(arg);
                        }
                        self.write(")");
                    }
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
                } else if (c.type_args.len == 0 and self.isProgramFn(c.name)) {
                    // User-fn precedence (see isProgramFn docblock): a
                    // program-local fun decl with this name resolves
                    // to the USER fn even when the name+arity also
                    // matches a router row (`assert`, `type_name`,
                    // …). Emit the plain call — zig's own overload/
                    // arity checking applies from here. Imported
                    // aliases never reach this branch (they are not
                    // program decls) and stay routed, keeping the
                    // atomic intrinsics working for programs that
                    // import std.concurrent.atomic. Turbofish calls
                    // (c.type_args.len > 0) fall through even for
                    // program fns — the comptime type-arg expansion
                    // below owns that shape.
                    self.write(c.name);
                    self.write("(");
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
                    // fs_read_file (legacy router arm, removed) emitted `catch &[_]u8{}` for error
                    // collapse, env_var wraps `orelse null` around
                    // std.os.getenv's `?[:0]const u8`). See
                    // src/codegen/builtins.zig for the per-dispatch
                    // contract; changes to the table are NOT silently
                    // absorbed -- a future Phase must add the matching
                    // genBuiltinCall case simultaneously or zig will
                    // hard-error at compile time (the switch is
                    // exhaustiveness-checked).
                    self.genBuiltinCall(dispatch, c.args, expr.loc, null);
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
                        self.writeType(ta);
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
                // Manual memory model (zig-style, docs/19-memory.md): the
                // June-style escape analysis (src/codegen/escape.zig) is
                // a DIAGNOSTIC pass — it reports leak warnings for
                // never-freed Local sites but NEVER changes the emitted
                // shape. Every `new` always emits the inline create form
                // below; the user's explicit `free` / `defer free` is the
                // only deallocation. (The pre-manual-model auto-free
                // prologue was retired with the memory-model change.)
                //
                // The `try` propagates `OutOfMemory` through the enclosing
                // `pub fn main() !void { … }` signature emitted by
                // `genFun`. For the
                // custom-allocator sugar `new(<arena>, T(value))` we route
                // through `<arena>.create(T)` instead so per-request arena
                // allocations land in the user-supplied arena (e.g.
                // HTTP-request lifecycles that `defer arena.free_all()`);
                // arena-backed sites are never auto-freed by the escape
                // pass (the arena owns the lifecycle).
                const id = self.alloc_counter;
                self.alloc_counter += 1;
                var name_buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "__p_{d}", .{id}) catch "__p";
                self.write("blk: { const ");
                self.write(name);
                // OOM propagation is return-type-aware: the `try` shape
                // only works when the enclosing fn can carry the error
                // (`pub fn main() !void` — the unannotated default).
                // Inside a fn with an explicit NON-`!` return annotation
                // (`-> Result<i32, str>`, `-> i32`, ...) `try` would make
                // zig reject the body ("function cannot return an error"
                // / "expected type 'main.Result(...)', found
                // 'error{OutOfMemory}'" — surfaced by the defer/
                // errdefer_partial + multiple_resources examples'
                // `new i32(...)` in Result-returning fns). Fall back to a
                // hard OOM panic there (C-style abort) so the allocation
                // stays single-expression and the fn signature is kept.
                const oom_try = self.fn_ret_type_len == 0 or self.fn_ret_type_buf[0] == '!';
                self.write(" = ");
                if (oom_try) self.write("try ");
                if (n.allocator) |alloc_name| {
                    self.write(alloc_name);
                    self.write(".create(");
                } else {
                    self.write("std.heap.page_allocator.create(");
                }
                self.writeType(n.type_name);
                if (oom_try) {
                    self.write("); ");
                } else {
                    self.write(") catch @panic(\"__zag: page_alloc OOM\"); ");
                }
                // std.bench allocation counter (docs/manual/20 + the
                // __zag_bench_* preamble helpers): every `new` site
                // charges @sizeOf(T). The matching charge-back lands
                // in the `.free_expr` arm / the escape-prologue
                // defer, so Counters.snapshot() reports live bytes.
                self.write("__zag_bench_alloc(@sizeOf(");
                self.writeType(n.type_name);
                self.write(")); ");
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
                if (self.isTrackedTrait(c.type_text) and c.expr.payload == .ident) {
                    const source_ident = c.expr.payload.ident;
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
                        // The `.ptr` field expects `*anyopaque`, and
                        // `&<const_var>` produces `*const T`. zig 0.16
                        // rejects implicit `*const T` → `*T` (const-
                        // discard) so we wrap with `@constCast` to
                        // strip the outer `const` qualifier, leaving
                        // `*T`. The pointer-kind change to `*anyopaque`
                        // happens via zig's implicit coercion from
                        // `*T` → `*anyopaque` driven by the field's
                        // declared destination type — no explicit
                        // `@ptrCast` wrapper needed.
                        self.writeType(c.type_text);
                        self.write("{ .ptr = @constCast(");
                        if (!is_pointer_source) self.write("&");
                        self.write(source_ident);
                        self.write("), .vtable = &");
                        self.writeType(c.type_text);
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
                if (core.isFloatTypeName(target_zig) and c.expr.payload == .ident) {
                    const op_ident = c.expr.payload.ident;
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
                // Int-source → float-target carve-out (`top as f64`
                // where top: u64, stdlib random next_f64): zig 0.16's
                // `@as(f64, u64_var)` is rejected ("expected type
                // 'f64', found 'u64'") — the canonical form is
                // `@as(T, @floatFromInt(value))`, which is safe for
                // every int width (widening only, IEEE rounding).
                // Ident sources route through the tracked-type check
                // (float idents are caught by the @floatCast branch
                // above); the bit-twiddle expression forms are
                // int-by-construction in the stdlib surface.
                if (core.isFloatTypeName(target_zig)) {
                    const is_int_source = switch (c.expr.payload) {
                        .ident => blk: {
                            const op_ident = c.expr.payload.ident;
                            if (self.getSourceTypeName(op_ident)) |source_type| {
                                break :blk core.isIntTypeName(source_type);
                            }
                            break :blk false;
                        },
                        .binary, .unary, .index, .call, .method_call => true,
                        else => false,
                    };
                    if (is_int_source) {
                        self.write("@as(");
                        self.writeType(c.type_text);
                        self.write(", @floatFromInt(");
                        self.genExpr(c.expr.*);
                        self.write("))");
                        return;
                    }
                }
                // Int-family narrowing carve-out (`fd_raw as i32` where
                // fd_raw: usize): zig 0.16's `@as(i32, usize_var)` is
                // rejected ("signed 32-bit int cannot represent all
                // possible unsigned 64-bit values"). Emit the canonical
                // `@as(T, @intCast(value))` pair — the @as provides the
                // explicit result type (zig 0.16's single-arg @intCast
                // requires a known target from context, which binary
                // positions like `pos + n_signed` don't provide).
                // Surfaced by lib/std/fs.zag's fd + write-loop casts
                // (Tier-1 migration).
                //
                // v2 widening (stdlib batch): the `.ident`-only guard
                // rejected the shift/bit-twiddle shapes the pure-.zag
                // stdlib needs — `(b0 >> 2) as usize`,
                // `(triple >> 16) as u8`, `(26 + c - 'a') as u32` all
                // carry binary/unary/index operands whose result type
                // is int-by-construction (bit-ops on tracked uN idents).
                // These now route to `@as(T, @intCast(expr))` too;
                // `@intCast` is a no-op for widening and truncates for
                // narrowing, matching the wrapping intent of hash
                // arithmetic. Float-typed binary operands under an
                // int-target cast would be rejected by zig at compile
                // time (loud, not silent) — no such shape exists in
                // the stdlib surface.
                // Float-source → int-target carve-out (`f as u64` where
                // f: f64): zig 0.16 rejects `@as(u64, f64_var)`
                // ("expected type 'u64', found 'f64'") and the only
                // canonical lowering is `@as(T, @intFromFloat(value))`
                // (truncates toward zero; UB-safety is the source
                // program's range contract, mirroring zig's own
                // semantics). Surfaced by the pure-.zag std.fmt
                // migration — format_f64 / parse_f64 need
                // `int_part: u64 = @intFromFloat(v)` / digit casts that
                // .zag can only spell as `as` casts. Operand shapes
                // mirror the int-source table below (ident via tracked
                // type, binary/unary/index/call/method_call
                // int-by-construction under a float target).
                if (core.isIntTypeName(target_zig)) {
                    const is_float_source = switch (c.expr.payload) {
                        .ident => blk: {
                            const op_ident = c.expr.payload.ident;
                            if (self.getSourceTypeName(op_ident)) |source_type| {
                                break :blk core.isFloatTypeName(source_type);
                            }
                            break :blk false;
                        },
                        // CAUTION: a `.binary` operand is float-source
                        // ONLY when one of its leaves is a tracked float
                        // ident — int arithmetic (`d - '0'` digit math,
                        // the stdlib's dominant cast-operand shape)
                        // arrives as `.binary` too. Optimistically
                        // routing every `.binary` to @intFromFloat broke
                        // digit casts with "expected float type, found
                        // 'u8'", so the check walks the leaves; an
                        // untracked leaf keeps the conservative false
                        // (falls through to the @intCast path below).
                        .binary => |ib| blk: {
                            break :blk self.binaryHasFloatLeaf(ib);
                        },
                        else => false,
                    };
                    if (is_float_source) {
                        self.write("@as(");
                        self.writeType(c.type_text);
                        self.write(", @intFromFloat(");
                        self.genExpr(c.expr.*);
                        self.write("))");
                        return;
                    }
                }
                if (core.isIntTypeName(target_zig)) {
                    // Pointer→int carve-out (v0.5 self-hosting): zig 0.16
                    // rejects @intCast on a pointer SOURCE ("expected int,
                    // found pointer") — the canonical lowering is
                    // @intFromPtr. Surfaced by std.mem's allocator header
                    // math (`(buf.ptr - 16) as usize` for the mapped-length
                    // store) — the symmetric twin of the int→pointer
                    // @ptrFromInt carve-out in the pointer-target branch
                    // below. Detection is source-type-informed: pointer-
                    // shaped tracked types (`*T`, `[*]T`, `[*:0]T`,
                    // `[]T`…) route here; pointer-typed COMPTIME forms
                    // (`null`, string literals) also carry pointer source
                    // text — `null` must NOT go through @intFromPtr
                    // (it's not a pointer value zig accepts there), so
                    // the literal-null ident case is excluded by the
                    // tracked-type lookup (untyped nulls fall through to
                    // the generic @as emit, where zig surfaces the
                    // mismatch loudly).
                    var ptr_src = false;
                    {
                        const st_opt = core.getSourceTypeNameOfExpr(self, c.expr.*);
                        if (st_opt) |st| {
                            ptr_src = std.mem.startsWith(u8, st, "*") or
                                std.mem.startsWith(u8, st, "[") or
                                std.mem.eql(u8, st, "str");
                            // Fn-pointer sources (`*const fn (…) …` —
                            // std.concurrent.thread stores the entry
                            // address as the control block's first
                            // word): zig's canonical int form is
                            // @intFromPtr, identical to the pointer
                            // case.
                            if (!ptr_src and std.mem.startsWith(u8, st, "*const fn")) ptr_src = true;
                        }
                    }
                    if (ptr_src) {
                        self.write("@as(");
                        self.writeType(c.type_text);
                        self.write(", @intFromPtr(");
                        self.genExpr(c.expr.*);
                        self.write("))");
                        return;
                    }
                    const is_ident_int = switch (c.expr.payload) {
                        .ident => blk: {
                            const op_ident = c.expr.payload.ident;
                            if (self.getSourceTypeName(op_ident)) |source_type| {
                                break :blk core.isIntTypeName(source_type) and !std.mem.eql(u8, source_type, target_zig);
                            }
                            break :blk false;
                        },
                        .binary, .unary, .index, .call, .method_call => true,
                        // Member access (`payload.len`, `node.count`):
                        // int-typed in the overwhelming majority of
                        // cases, and a narrowing cast on one previously
                        // emitted a bare `@as(T, x)` that zig 0.16
                        // rejects ("cannot represent all possible
                        // values") because @as never truncates -- the
                        // failure mode that forced callers to route
                        // every narrowing through a local first. A
                        // non-int member (e.g. an f64 field) is a zig
                        // error either way, so no case regresses.
                        .member_access => true,
                        else => false,
                    };
                    if (is_ident_int) {
                        self.write("@as(");
                        self.writeType(c.type_text);
                        self.write(", @intCast(");
                        self.genExpr(c.expr.*);
                        self.write("))");
                        return;
                    }
                }
                self.write("@as(");
                self.writeType(c.type_text);
                self.write(", ");
                // Many-pointer cast targets (`[*:0]const u8` sentinel
                // pointers) reject `@as(T, single_ptr)` in zig 0.16 —
                // "a single pointer cannot cast into a many pointer".
                // Wrap the operand in @ptrCast so the emitted shape is
                // `@as([*:0]const u8, @ptrCast(&buf[0]))`, the canonical
                // zig form for the lib/std/fs.zag openat path argument
                // (surfaced by the Tier-1 migration's first full zig
                // compile of the materialized stdlib).
                //
                // ALIGNMENT: `[*]T` targets from a byte allocator
                // (`__zag_page_alloc(...) as [*]i32` — std.collections
                // grow) increase alignment (1 → 4), and zig 0.16
                // rejects a bare @ptrCast for that ("@ptrCast
                // increases pointer alignment"). @alignCast around the
                // @ptrCast is a no-op when the alignment is unchanged
                // and asserts it when it increases (page_allocator
                // hands out max-aligned pages).
                // Check the MAPPED form — `*raw u8` → `[*]u8` must
                // take the same @ptrCast route as a literal `[*:0]`
                // spelling (surfaced by std.async's opaque future
                // pointers). Single-pointer targets from many-
                // pointer operands (`[*]u8` → `*Future(void)`) need
                // the same wrap — zig rejects both directions
                // ("a single pointer cannot cast into a many
                // pointer" / the reverse) without @ptrCast, and
                // @alignCast covers the alignment increase.
                const cast_target_zig = zagTypeToZig(c.type_text);
                if (std.mem.startsWith(u8, cast_target_zig, "[*") or std.mem.startsWith(u8, cast_target_zig, "*")) {
                    // Const-slice sources (`let msg: str = "…"` cast to
                    // `*raw u8` — the C-FFI write(2) shape in
                    // examples/ffi/basic_io.zag): a bare @ptrCast on a
                    // `[]const u8` ident discards the const qualifier,
                    // which zig 0.16 REJECTS ("@ptrCast discards const
                    // qualifier"). Wrap the operand in @constCast — the
                    // explicit C-FFI escape-hatch for many-pointer casts
                    // (no-op at runtime on non-const sources). Detection
                    // is type-informed: only `str` / `[]const …`
                    // annotated bindings trigger it.
                    var const_src = false;
                    if (c.expr.payload == .ident) {
                        if (self.getSourceTypeName(c.expr.payload.ident)) |st| {
                            const_src = std.mem.eql(u8, st, "str") or std.mem.startsWith(u8, st, "[]const");
                        }
                    }
                    // Int→pointer carve-out (v0.5 self-hosting): zig 0.16
                    // rejects @ptrCast on an int SOURCE ("expected pointer,
                    // found usize") — the canonical lowering is
                    // @ptrFromInt. Surfaced by std.posix.mmap's address
                    // return (`let p: [*]u8 = rc as [*]u8;`), the base of
                    // the pure-zag allocator. @alignCast still wraps (page
                    // mappings are max-aligned; no-op for byte targets).
                    // Detection is source-type-informed: only idents
                    // tracked as int-family (usize/isize/iN/uN) route
                    // here; comptime-int literals (null deref checks,
                    // `0 as [*]u8`) stay on the @ptrCast route — zig
                    // accepts those via the comptime-known-null path and
                    // the guess can't silently misfire.
                    var int_src = false;
                    {
                        const st_opt = core.getSourceTypeNameOfExpr(self, c.expr.*);
                        if (st_opt) |st| {
                            int_src = core.isIntTypeName(st);
                        }
                    }
                    if (int_src) {
                        // No @alignCast: its operand type is unconstrained,
                        // which strands @ptrFromInt's result inference
                        // ("must have a known result type"). The @as
                        // wrapper supplies the target directly.
                        // @alignCast was a no-op here anyway — page
                        // mappings are max-aligned by the kernel.
                        self.write("@ptrFromInt(");
                        self.genExpr(c.expr.*);
                        self.write(")");
                    } else {
                        if (const_src) self.write("@constCast(");
                        self.write("@alignCast(@ptrCast(");
                        self.genExpr(c.expr.*);
                        self.write("))");
                        if (const_src) self.write(")");
                    }
                } else {
                    self.genExpr(c.expr.*);
                }
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
                    if (t.payload != .ident) break :blk false;
                    const tn = self.getSourceTypeName(t.payload.ident) orelse break :blk false;
                    // Slice-shaped: leading `[]` covers `[]u8`, `[]const
                    // u8`, `[]T`, and any future `[]<qualifier> T` shape.
                    if (tn.len >= 2 and tn[0] == '[' and tn[1] == ']') break :blk true;
                    // Transparent alias `str` → `[]const u8` per docs/07.
                    if (std.mem.eql(u8, tn, "str")) break :blk true;
                    break :blk false;
                };
                // std.bench allocation counter: ident targets (the only
                // shape whose size is statically knowable without
                // re-evaluating the target) wrap the dealloc in a blk
                // and charge __zag_bench_free(<size>) — `p.len` for
                // slices, @sizeOf(pointee) for pointers (via the same
                // @typeInfo drill the `.add`/`.offset` arms use).
                // Non-ident targets keep the plain emit — the target
                // must not be evaluated twice (e.g. `free(getBox())`).
                const is_ident = f.target.*.payload == .ident;
                if (is_ident) self.write("({ ");
                if (use_slice_free) {
                    self.write("std.heap.page_allocator.free(");
                } else {
                    self.write("std.heap.page_allocator.destroy(");
                }
                self.genExpr(f.target.*);
                self.write(")");
                if (is_ident) {
                    self.write("; __zag_bench_free(");
                    if (use_slice_free) {
                        // Slice: the allocation was `alloc(N)` with
                        // len == capacity, so `.len` is the charge-back.
                        self.genExpr(f.target.*);
                        self.write(".len");
                    } else {
                        self.write("@sizeOf(@typeInfo(@TypeOf(");
                        self.genExpr(f.target.*);
                        self.write(")).pointer.child)");
                    }
                    self.write("); })");
                }
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
                self.writeType(sl.type_name);
                // Generic struct literals `Box<T> { v: x }` (docs/16
                // §2): the thunk-instantiation call parenthesizes the
                // type args — `.Box(T) { .v = x }`. Empty `type_args`
                // keeps the non-generic emit byte-identical.
                if (sl.type_args.len > 0) {
                    self.write("(");
                    for (sl.type_args, 0..) |ta, i| {
                        if (i > 0) self.write(", ");
                        self.write(ta);
                    }
                    self.write(")");
                }
                self.write("{ ");
                // Positional slots (SIMD vector literals —
                // `f32x4 { 1.0, 2.0, ... }` from docs/manual/24):
                // every field name is the empty string, so emit the
                // positional `Type{ v1, v2, ... }` shape (zig's
                // vector-literal form). Named slots emit the usual
                // `Type{ .f = v }` struct form. The parser produces
                // uniform slots (all-named or all-positional), so the
                // first slot decides.
                if (sl.inits.len > 0 and sl.inits[0].name.len == 0) {
                    // docs/manual/12 §"Structural Embedding" carve-out:
                    // a leading positional slot whose expression is a
                    // bare struct literal of an EMBEDDED field's type
                    // emits as a NAMED field (`Widget { ... }` →
                    // `.Widget = ...`), because the outer struct's
                    // embed row lands as a named field of the embed
                    // type (genStructDecl's `.embed` arm) and zig
                    // rejects a positional init on a mixed named-field
                    // struct. Non-embed SIMD vector literals keep the
                    // positional emit byte-identical.
                    var named_embed = false;
                    if (sl.inits[0].value.payload == .struct_lit) {
                        const embed_type = sl.inits[0].value.payload.struct_lit.type_name;
                        var base_sl = sl.type_name;
                        if (std.mem.startsWith(u8, base_sl, "*const ")) base_sl = base_sl["*const ".len..];
                        if (std.mem.startsWith(u8, base_sl, "*")) base_sl = base_sl["*".len..];
                        for (self.prog.structs) |sd2| {
                            if (!std.mem.eql(u8, sd2.name, base_sl)) continue;
                            for (sd2.fields) |f2| {
                                if (f2.kind != .embed) continue;
                                if (std.mem.eql(u8, f2.kind.embed.type_name, embed_type)) {
                                    named_embed = true;
                                    break;
                                }
                            }
                            break;
                        }
                    }
                    if (named_embed) {
                        for (sl.inits, 0..) |fi, i| {
                            if (i > 0) self.write(", ");
                            if (fi.name.len > 0) {
                                // Named slot alongside the embed
                                // (`label: "ok"`): zig rejects ANY
                                // positional init once one field is
                                // named, so emit the `.name = value`
                                // form for these too.
                                self.write(".");
                                self.write(fi.name);
                                self.write(" = ");
                                self.genExpr(fi.value.*);
                            } else if (fi.value.payload == .struct_lit) {
                                const et = fi.value.payload.struct_lit.type_name;
                                var matched = false;
                                for (self.prog.structs) |sd2| {
                                    if (!std.mem.eql(u8, sd2.name, sl.type_name)) continue;
                                    for (sd2.fields) |f2| {
                                        if (f2.kind != .embed) continue;
                                        if (std.mem.eql(u8, f2.kind.embed.type_name, et)) {
                                            self.write(".");
                                            self.write(et);
                                            self.write(" = ");
                                            self.genExpr(fi.value.*);
                                            matched = true;
                                            break;
                                        }
                                    }
                                    break;
                                }
                                if (!matched) self.genExpr(fi.value.*);
                            } else {
                                self.genExpr(fi.value.*);
                            }
                        }
                    } else {
                        for (sl.inits, 0..) |fi, i| {
                            if (i > 0) self.write(", ");
                            self.genExpr(fi.value.*);
                        }
                    }
                } else {
                    for (sl.inits, 0..) |fi, i| {
                        if (i > 0) self.write(", ");
                        self.write(".");
                        self.write(fi.name);
                        self.write(" = ");
                        self.genExpr(fi.value.*);
                    }
                }
                self.write(" }");
            },
            .enum_variant_ctor => |evc| {
                // Preamble builtin generic ctors (`Option.Some(x)`,
                // `Option.None`, `Result.Ok(v)`, plus the BARE `None`
                // ident form) — INSTANTIATE the preamble generic from
                // the binding/return anchor when the enum name resolves
                // to the anchor's base (`Option<i32>{ .Some = x }`).
                // Without the anchor, `Option{ .Some = x }` is a
                // comptime-fn instantiation zig rejects ("expected type
                // 'type', found 'fn (comptime type) type'") and
                // `Option.None` is field-access on the fn type. The
                // anchor is set around let/return RHS emits (see
                // ctor_anchor_buf field doc in core.zig); no anchor →
                // legacy qualified emit below preserves today's zig
                // diagnostic. Docs surface: docs/manual/19
                // §"Option"-style construction (Option.Some(42) /
                // Option.None).
                const en_opt = evc.enum_name;
                const is_preamble_base = if (en_opt) |en|
                    std.mem.eql(u8, en, "Option") or std.mem.eql(u8, en, "Result")
                else
                    false;
                const is_bare_none = en_opt == null and
                    evc.args.len == 0 and
                    std.mem.eql(u8, evc.variant_name, "None");
                if ((is_preamble_base or is_bare_none) and self.ctor_anchor_len > 0) {
                    const anchor = self.ctor_anchor_buf[0..self.ctor_anchor_len];
                    const base = if (en_opt) |en| en else "Option";
                    if (anchor.len >= base.len and std.mem.eql(u8, anchor[0..base.len], base)) {
                        self.writeType(anchor);
                        self.write("{ .");
                        self.write(evc.variant_name);
                        self.write(" = ");
                        if (evc.args.len == 0) {
                            self.write("{}");
                        } else if (evc.args.len == 1) {
                            self.genExpr(evc.args[0]);
                        } else {
                            self.write(".{ ");
                            for (evc.args, 0..) |a, i| {
                                if (i > 0) self.write(", ");
                                self.genExpr(a);
                            }
                            self.write(" }");
                        }
                        self.write(" }");
                        return;
                    }
                }
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
                // SIMD reductions (docs/manual/24-simd.md §"SIMD
                // Methods"): `.sum()` / `.max()` / `.min()` /
                // `.dot(other)` on a vector-typed receiver rewrite to
                // zig's `@reduce` builtin — @Vector has no methods.
                // The receiver must be an ident whose `: T`
                // annotation expands to `@Vector(...)` via
                // zagTypeToZig (typed bindings land in type_info_buf
                // via collectTypedBindings). Un-annotated receivers
                // fall through to the verbatim emit and zig surfaces
                // "no field or member function named 'sum'" — the
                // annotation rule makes that a source error, not a
                // codegen one.
                if (mc.target.payload == .ident) {
                    if (self.getSourceTypeName(mc.target.payload.ident)) |tn| {
                        if (std.mem.startsWith(u8, zagTypeToZig(tn), "@Vector(")) {
                            if (std.mem.eql(u8, mc.name, "sum") and mc.args.len == 0) {
                                self.write("@reduce(.Add, ");
                                self.genExpr(mc.target.*);
                                self.write(")");
                                return;
                            }
                            if (std.mem.eql(u8, mc.name, "max") and mc.args.len == 0) {
                                self.write("@reduce(.Max, ");
                                self.genExpr(mc.target.*);
                                self.write(")");
                                return;
                            }
                            if (std.mem.eql(u8, mc.name, "min") and mc.args.len == 0) {
                                self.write("@reduce(.Min, ");
                                self.genExpr(mc.target.*);
                                self.write(")");
                                return;
                            }
                            if (std.mem.eql(u8, mc.name, "dot") and mc.args.len == 1) {
                                // Dot product = element-wise product +
                                // horizontal add (portable lowering;
                                // sub-byte VNNI hardware dispatch is a
                                // follow-up per the chapter's note).
                                self.write("@reduce(.Add, ");
                                self.genExpr(mc.target.*);
                                self.write(" * ");
                                self.genExpr(mc.args[0]);
                                self.write(")");
                                return;
                            }
                        }
                    }
                }
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
                if (mc.target.payload == .ident) {
                    if (builtins.lookupWithRecv(mc.target.payload.ident, mc.name, mc.args.len)) |dispatch| {
                        self.genBuiltinCall(dispatch, mc.args, expr.loc, mc.target.payload.ident);
                        return;
                    }
                }
                // Intercept String instance methods — emit zig-native calls.
                // `s.as_str()` → `s.as_str()`, `s.push_str(x)` → `s.pushStr(x)`.
                if (builtins.BuiltinDispatch.stringMethodZigName(mc.name)) |zig_name| {
                    self.genExpr(mc.target.*);
                    self.write(".");
                    self.write(zig_name);
                    self.write("(");
                    for (mc.args, 0..) |a, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(a);
                    }
                    self.write(")");
                    return;
                }
                // Intercept Writer instance methods — emit zig-native calls.
                if (builtins.BuiltinDispatch.writerMethodZigName(mc.name)) |zig_name| {
                    self.genExpr(mc.target.*);
                    self.write(".");
                    self.write(zig_name);
                    self.write("(");
                    for (mc.args, 0..) |a, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(a);
                    }
                    self.write(")");
                    return;
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
                // Call-site direct dispatch for `obj.Trait.method()`:
                // when the AST is method_call(member_access(ident, "TraitName"), "method", args)
                // and the middle identifier matches a known trait, emit
                // ConcreteType_TraitName_methodName(ident, args) — a
                // direct monomorphized call with zero vtable overhead.
                // Generic-instance dispatch (docs/16 §2): the
                // thunk-form generic struct (`fn Box(comptime T:
                // type) type`) has NO nested methods — impl methods
                // were emitted as orphan free fns (`Box_T_make`),
                // so `list.push(x)` cannot stay verbatim. Two shapes:
                //   1. ident receiver with a tracked generic type —
                //      `list: Box(i32)`; `list.push(x)` →
                //      `Box_T_push(i32, &list, x)` — the comptime
                //      type arg passes EXPLICITLY (zig does not infer
                //      it from the receiver param), and a value
                //      receiver gets address-of (`&list` → `*Box(i32)`)
                //      mirroring zig's own method-call sugar; a
                //      pointer receiver (`self: *Box(T)` inside the
                //      orphan fns) passes verbatim.
                //   2. static constructor `Box(i32).make(42)` → the
                //      type args pass explicitly (no receiver to
                //      infer from): `Box_T_make(i32, 42)`. The paren
                //      args are the comptime type args; turbofish
                //      `Box<i32>(...)` carries them in type_args.
                //
                // docs/manual/18 §"Overloaded trait methods": a trait
                // value bound through `x as Trait` carries the
                // overload-suffixed dispatch shim (`render_0` /
                // `render_1`), so a call on a TRAIT-TYPED receiver
                // gets the arity-matched suffix appended. The receiver's
                // tracked source-type strips to the trait name; plain
                // struct receivers keep the verbatim emit (zig resolves
                // member methods directly). The receiver const-fix
                // rides the same shape: a `let` binding (const)
                // calling a `self: *T` method is a const-discard in
                // zig, so the callee's receiver mutability is checked
                // and a `@constCast` wraps the address-of form.
                //
                // `obj.Trait.method()` direct dispatch (docs/18
                // §"Dot-qualified methods" — the AST shape is
                // method_call(member_access(ident, "TraitName"),
                // "method", args)): emit the monomorphized free fn
                // `ConcreteType_TraitName_methodName(ident, args)` —
                // zero vtable overhead. Fires before the trait-value
                // overload dispatch so the qualified call never
                // routes through the vtable shim.
                if (mc.target.payload == .member_access) {
                    const ma = mc.target.payload.member_access;
                    if (ma.target.payload == .ident and self.isTrackedTrait(ma.name)) {
                        const concrete = ma.target.payload.ident;
                        // Receiver type: the ident's tracked annotation,
                        // or — for `self.Drawable.draw()` inside a method
                        // body — the enclosing impl's target type kept in
                        // current_receiver_struct_name (a bare `self` has
                        // no typed-binding entry, which previously made
                        // the resolver emit verbatim and zig reject
                        // "no field named 'Drawable'").
                        var receiver_type: ?[]const u8 = null;
                        if (self.getSourceTypeName(concrete)) |ct| {
                            receiver_type = ct;
                        } else if (std.mem.eql(u8, concrete, "self")) {
                            if (self.current_receiver_struct_name) |rs| receiver_type = rs;
                        }
                        if (receiver_type != null) {
                            const ct = receiver_type.?;
                            // Fn-name prefix is the CONCRETE TYPE name
                            // (`Button_Drawable_draw`), never the
                            // receiver ident — `self.Drawable.draw()`
                            // inside a resolver body must not decay to
                            // `self_Drawable_draw` (undeclared ident).
                            var type_base: []const u8 = ct;
                            if (std.mem.startsWith(u8, type_base, "*const ")) type_base = type_base["*const ".len..];
                            if (std.mem.startsWith(u8, type_base, "*")) type_base = type_base["*".len..];
                        var arg_emitted = false;
                        self.write(type_base);
                        self.write("_");
                        self.write(ma.name);
                        self.write("_");
                        self.write(mc.name);
                        self.write("(");
                        {
                            if (!std.mem.startsWith(u8, ct, "*")) {
                                // Value binding: pass address-of. When
                                // the callee's receiver is `self: *T`,
                                // zig rejects a `let` binding's
                                // `*const T` as const-discard — strip
                                // the qualifier with @constCast (a
                                // no-op on mutable `var` bindings).
                                if (self.methodTakesMutableSelf(ma.name, mc.name)) {
                                    self.write("@constCast(&");
                                    self.write(concrete);
                                    self.write(")");
                                } else {
                                    self.write("&");
                                    self.write(concrete);
                                }
                            } else if (std.mem.startsWith(u8, ct, "*const ")) {
                                // `*const T` binding + `self: *T`
                                // callee: strip the qualifier in place.
                                if (self.methodTakesMutableSelf(ma.name, mc.name)) {
                                    self.write("@constCast(");
                                    self.write(concrete);
                                    self.write(")");
                                } else {
                                    self.write(concrete);
                                }
                            } else {
                                // `*T` or other pointer: passes verbatim.
                                self.write(concrete);
                            }
                            arg_emitted = true;
                        }
                        for (mc.args) |a| {
                            if (arg_emitted) self.write(", ");
                            self.genExpr(a);
                            arg_emitted = true;
                        }
                        self.write(")");
                        return;
                        }
                    }
                }
                if (mc.target.payload == .ident) {
                    if (self.getSourceTypeName(mc.target.payload.ident)) |tn| {
                        // Trait value dispatch: the receiver's annotation
                        // is (a pointer-stripped) tracked trait name.
                        var trait_base: []const u8 = tn;
                        if (std.mem.startsWith(u8, trait_base, "*const ")) trait_base = trait_base["*const ".len..];
                        if (std.mem.startsWith(u8, trait_base, "*")) trait_base = trait_base["*".len..];
                        if (self.isTrackedTrait(trait_base)) {
                            const suffix = self.traitOverloadSuffix(trait_base, mc.name, mc.args.len);
                            self.genExpr(mc.target.*);
                            self.write(".");
                            self.write(mc.name);
                            if (suffix) |s| self.write(s);
                            self.write("(");
                            for (mc.args, 0..) |a, i| {
                                if (i > 0) self.write(", ");
                                self.genExpr(a);
                            }
                            self.write(")");
                            return;
                        }
                    }
                }
                if (mc.target.payload == .ident) {
                    if (self.getSourceTypeName(mc.target.payload.ident)) |tn| {
                        if (self.genericInstanceOfTypeText(tn)) |gi| {
                            // Materialized stdlib generics (collections)
                            // emit the orphan fns into THEIR module —
                            // qualify through the inline @import; the
                            // module's own generic structs call bare.
                            if (self.genericStructModulePath(gi.base)) |mod_path| {
                                self.write("@import(\"");
                                self.write(mod_path);
                                self.write("\").");
                            }
                            self.write(gi.base);
                            self.write("_");
                            self.write(mc.name);
                            self.write("(");
                            for (gi.args, 0..) |ga, i| {
                                if (i > 0) self.write(", ");
                                self.writeType(ga);
                            }
                            if (gi.args.len > 0) self.write(", ");
                            // `&<receiver>` wrapped in @constCast: a
                            // const capture (zig optional-capture `|v|`)
                            // would otherwise produce `*const T`,
                            // rejected as const-discard by the `*T`
                            // orphan receiver. No-op on mutable
                            // bindings.
                            if (!gi.is_pointer) {
                                self.write("@constCast(&");
                                self.genExpr(mc.target.*);
                                self.write(")");
                            } else {
                                self.genExpr(mc.target.*);
                            }
                            for (mc.args) |a| {
                                self.write(", ");
                                self.genExpr(a);
                            }
                            self.write(")");
                            return;
                        }
                    }
                }
                // Member-access receivers on GENERIC-TYPED FIELDS —
                // `self.timers.push(...)` where the field's declared
                // type is `ArrayList(TimerEntry)` (std.async's
                // EventLoop). Resolve the field type from the base
                // ident's tracked struct + the module's struct decls,
                // then dispatch like the ident case (the receiver
                // expr — the member_access — emits verbatim; already
                // a pointer when the field is a struct, so no `&`).
                if (mc.target.payload == .member_access) {
                    const ma = mc.target.payload.member_access;
                    if (ma.target.payload == .ident) {
                        if (self.getSourceTypeName(ma.target.payload.ident)) |tn| {
                            // Base struct name: strip `*`/`*const `
                            // pointer prefixes — the receiver of a
                            // non-generic struct (`self: *EventLoop`)
                            // has no generic-paren shape to match.
                            var base: []const u8 = tn;
                            if (std.mem.startsWith(u8, base, "*const ")) base = base["*const ".len..];
                            if (std.mem.startsWith(u8, base, "*")) base = base["*".len..];
                            if (self.structFieldType(base, ma.name)) |field_type| {
                                if (self.genericInstanceOfTypeText(field_type)) |gi| {
                                    const field_is_pointer = std.mem.startsWith(u8, field_type, "*");
                                        if (self.genericStructModulePath(gi.base)) |mod_path| {
                                            self.write("@import(\"");
                                            self.write(mod_path);
                                            self.write("\").");
                                        }
                                        self.write(gi.base);
                                        self.write("_");
                                        self.write(mc.name);
                                        self.write("(");
                                        for (gi.args, 0..) |ga, i| {
                                            if (i > 0) self.write(", ");
                                            self.writeType(ga);
                                        }
                                        if (gi.args.len > 0) self.write(", ");
                                        // `&<receiver>` wrapped in
                                        // @constCast (same rationale as
                                        // the ident-receiver dispatch
                                        // above — const captures reject
                                        // bare `&` as const-discard).
                                        if (!field_is_pointer) {
                                            self.write("@constCast(&");
                                            self.genExpr(mc.target.*);
                                            self.write(")");
                                        } else {
                                            self.genExpr(mc.target.*);
                                        }
                                        for (mc.args) |a| {
                                            self.write(", ");
                                            self.genExpr(a);
                                        }
                                        self.write(")");
                                        return;
                                    }
                                }
                            }
                        }
                    }
                if (mc.target.payload == .call) {
                    const tc = mc.target.payload.call;
                    if (self.isGenericStructName(tc.name)) {
                        if (self.genericStructModulePath(tc.name)) |mod_path| {
                            self.write("@import(\"");
                            self.write(mod_path);
                            self.write("\").");
                        }
                        self.write(tc.name);
                        self.write("_");
                        self.write(mc.name);
                        self.write("(");
                        if (tc.type_args.len > 0) {
                            for (tc.type_args, 0..) |ta, i| {
                                if (i > 0) self.write(", ");
                                self.writeType(ta);
                            }
                        } else {
                            for (tc.args, 0..) |a, ai| {
                                if (ai > 0) self.write(", ");
                                // Type-arg idents route through
                                // writeType for the transparent-alias
                                // wrap (`str` → `[]const u8`); any
                                // non-ident arg falls back to the
                                // generic expression emit.
                                if (a.payload == .ident) {
                                    self.writeType(a.payload.ident);
                                } else {
                                    self.genExpr(a);
                                }
                            }
                        }
                        for (mc.args) |a| {
                            self.write(", ");
                            self.genExpr(a);
                        }
                        self.write(")");
                        return;
                    }
                }
                // Union orphan-method dispatch — `hover.is_action()`
                // (member form) and `ClickEvent.is_action(hover)`
                // (qualified static form). Union impl methods flatten to
                // module-scope free fns `<Union>_<Method>` (genFreeMethod
                // — zig 0.16 rejects methods nested inside `union(enum)`),
                // so neither shape can stay verbatim. The shared rewrite
                // resolves the union name from the receiver, confirms the
                // method exists, and emits the orphan call with `&` on the
                // receiver when the impl takes a pointer and the binding
                // is a value. Trait-turbofish call sites (mc.type_args)
                // skip the rewrite — the trait dispatch path handles them.
                if (mc.target.payload == .ident and mc.type_args.len == 0) {
                    if (self.tryEmitUnionOrphanCall(mc.target.payload.ident, mc.name, mc.args)) {
                        return;
                    }
                }
                // Const-receiver fix (docs/18 §"Using Traits" — the
                // resolving-method call shape): a `let` binding is a
                // zig const, so `btn.method()` on a `self: *T` method
                // rejects `&btn` as const-discard. When the receiver
                // is an ident bound to a VALUE (non-pointer annotation)
                // AND any impl of that method takes a mutable `self`,
                // wrap the receiver in `@constCast(&…)`. `var` bindings
                // (bindingIsVar) stay bare — their `&` is already `*T`,
                // and an unconditional cast would hide genuine mut-
                // ability errors. `obj.Trait.method()` and generic-
                // dispatch sites above carry their own copies of this
                // logic (the receiver kind differs per path).
                if (mc.target.payload == .ident) {
                    if (self.getSourceTypeName(mc.target.payload.ident)) |rtn| {
                        if (!std.mem.startsWith(u8, rtn, "*")) {
                            if (self.methodTakesMutableSelfanyType(mc.name)) {
                                self.write("@constCast(&");
                                self.genExpr(mc.target.*);
                                self.write(")");
                                self.write(".");
                                self.write(mc.name);
                                self.write("(");
                                for (mc.type_args, 0..) |ta, i| {
                                    if (i > 0) self.write(", ");
                                    self.writeType(ta);
                                }
                                if (mc.args.len > 0 and mc.type_args.len > 0) self.write(", ");
                                for (mc.args, 0..) |a, i| {
                                    if (i > 0) self.write(", ");
                                    self.genExpr(a);
                                }
                                self.write(")");
                                return;
                            }
                        }
                    }
                }
                self.genExpr(mc.target.*);
                self.write(".");
                self.write(mc.name);
                self.write("(");
                for (mc.type_args, 0..) |ta, i| {
                    if (i > 0) self.write(", ");
                    self.writeType(ta);
                }
                if (mc.args.len > 0 and mc.type_args.len > 0) self.write(", ");
                for (mc.args, 0..) |a, i| {
                    if (i > 0) self.write(", ");
                    self.genExpr(a);
                }
                self.write(")");
            },
            .block_expr => |body| {
                // `{ stmts... }` — block expression. Emit a labeled
                // zig block that executes all statements and yields
                // the value of the final expression via `break :blk`.
                self.write("(blk: {\n");
                for (body, 0..) |s, i| {
                    if (i == body.len - 1 and s.payload == .return_stmt) {
                        const rs = s.payload.return_stmt;
                        if (rs.value) |v| {
                            self.write("        break :blk ");
                            self.genExpr(v);
                            self.write(";\n");
                        } else {
                            self.genStmt(s, false);
                        }
                    } else if (i == body.len - 1 and s.payload == .expr_stmt) {
                        self.write("        break :blk ");
                        self.genExpr(s.payload.expr_stmt);
                        self.write(";\n");
                    } else {
                        self.genStmt(s, false);
                    }
                }
                self.write("    })");
            },
            .const_block => |body| {
                // `const { stmts; return expr; }` — compile-time block.
                // Emit zig comptime labeled block that evaluates at
                // compile time and yields the return value. The
                // `comptime` keyword is dropped when the emit sits
                // inside a `const` binding RHS (comptime_scope flag set
                // by genBinding) — zig 0.16 rejects "redundant comptime
                // keyword in already comptime scope" there; in runtime
                // scope (`let x = const { … }`) the keyword stays so the
                // block still evaluates at compile time.
                if (!self.comptime_scope) self.write("(comptime ");
                self.write("blk: {\n");
                for (body, 0..) |s, i| {
                    if (i == body.len - 1 and s.payload == .return_stmt) {
                        const rs = s.payload.return_stmt;
                        if (rs.value) |v| {
                            self.write("        break :blk ");
                            self.genExpr(v);
                            self.write(";\n");
                        } else {
                            self.genStmt(s, false);
                        }
                    } else {
                        self.genStmt(s, false);
                    }
                }
                if (self.comptime_scope) {
                    self.write("    }");
                } else {
                    self.write("    })");
                }
            },
            .await_expr => |ae| {
                // `await EXPR` (docs/manual/00-overview.md "Zero-cost
                // async"): the awaited expression produces a `Future(T)`;
                // drive() parks until completion (zero syscalls on the
                // eager same-thread path — state is already 1 — and a
                // kernel futex wait for cross-thread producers) and
                // take() unwraps the payload:
                //   (blk: { var __fut_<N> = <expr>;
                //          __fut_<N>.drive();
                //          break :blk __fut_<N>.take(); })
                // The methods live on the Future type itself (the
                // __zag_future_drive free fn is retired) so the lowering
                // is module-agnostic — a user-module await on a std
                // module's future names its own preamble's Future
                // instance through the receiver, never a free-fn
                // signature. take() panics only on a pending non-void
                // future the caller take()s without driving; drive()
                // always precedes take() in this lowering.
                const id = self.blk_counter;
                self.blk_counter += 1;
                var name_buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "__fut_{d}", .{id}) catch "__fut";
                self.write("(blk: { var ");
                self.write(name);
                self.write(" = ");
                self.genExpr(ae.expr.*);
                self.write("; ");
                self.write(name);
                self.write(".drive(); break :blk ");
                self.write(name);
                self.write(".take(); })");
            },
            .asm_expr => |a| {
                // Inline assembly (docs/manual/24-simd.md §"Inline
                // Assembly"): translate the zag spec into zig's asm
                // expression. `{name}` placeholders in the template
                // become `%[name]`; `{name} = "constraint"(expr)`
                // bindings become `[name] "constraint" (expr)` in the
                // outputs (first section) / inputs (second) slots;
                // clobber strings become `.{ .<name> = true }` — zig
                // 0.16's clobbers slot is the packed
                // `std.builtin.assembly.Clobbers` struct (bare string
                // lists were rejected: "expected type
                // 'builtin.assembly.Clobbers__struct'"). The emitted
                // form is `asm ("tpl" : outs : ins : clobbers)`.
                self.write("(asm (\"");
                // Template rewrite: `{ident}` → `%[ident]` (literal
                // `%` passes through — zig templates use `%%` for a
                // literal percent, which the user can write directly).
                var i: usize = 0;
                while (i < a.template.len) {
                    if (a.template[i] == '{') {
                        const close = std.mem.indexOfScalarPos(u8, a.template, i + 1, '}');
                        if (close) |c| {
                            self.write("%[");
                            self.write(a.template[i + 1 .. c]);
                            self.write("]");
                            i = c + 1;
                            continue;
                        }
                    }
                    var seg_end = i;
                    while (seg_end < a.template.len and a.template[seg_end] != '{') : (seg_end += 1) {}
                    self.write(a.template[i..seg_end]);
                    i = seg_end;
                }
                self.write("\" : ");
                for (a.outputs, 0..) |op, oi| {
                    if (oi > 0) self.write(", ");
                    self.write("[");
                    self.write(op.name);
                    self.write("] \"");
                    self.write(op.constraint);
                    self.write("\" (");
                    self.genExpr(op.expr.*);
                    self.write(")");
                }
                self.write(" : ");
                for (a.inputs, 0..) |op, ii| {
                    if (ii > 0) self.write(", ");
                    self.write("[");
                    self.write(op.name);
                    self.write("] \"");
                    self.write(op.constraint);
                    self.write("\" (");
                    self.genExpr(op.expr.*);
                    self.write(")");
                }
                self.write(" : ");
                if (a.clobbers.len > 0) {
                    self.write(".{ ");
                    for (a.clobbers, 0..) |cl, ci| {
                        if (ci > 0) self.write(", ");
                        self.write(".");
                        self.write(cl);
                        self.write(" = true");
                    }
                    self.write(" }");
                } else {
                    self.write(".{}");
                }
                self.write("))");
            },
            .try_op => |t| {
                // `expr?` — postfix try/unwrap. Emit a labeled block +
                // compile-time `@hasField` discriminators so the same
                // codegen works for both `Result<T,E>` (has Ok/Err) and
                // `Option<T>` (has Some/None). The early-return wraps
                // the error/none value in the appropriate constructor
                // so the enclosing function's return type matches.
                var lbl_buf: [16]u8 = undefined;
                const tl = self.nextBlkLabel(&lbl_buf);
                self.write("(");
                self.write(tl);
                self.write(": { const __try = ");
                self.genExpr(t.expr.*);
                self.write("; if (@hasField(@TypeOf(__try), \"Ok\")) { switch (__try) { .Ok => |__v| break :");
                self.write(tl);
                self.write(" __v, .Err => |__e| return @as(@TypeOf(__try), .{ .Err = __e }), } } else { switch (__try) { .Some => |__v| break :");
                self.write(tl);
                self.write(" __v, .None => return @as(@TypeOf(__try), .{ .None = {} }), } } })");
            },
            .catch_expr => |c| {
                // `expr catch HANDLER` or `expr catch |err| HANDLER` —
                // emits a label-block with compile-time type discriminator
                // (same approach as try_op). When `err_binding` is
                // set (the `|err|` form), the Err value is bound before
                // evaluating the handler. For the None case (Option<T>),
                // the binding is unused but the handler expression runs.
                var cl_lbl_buf: [16]u8 = undefined;
                const cl = self.nextBlkLabel(&cl_lbl_buf);
                self.write("(");
                self.write(cl);
                self.write(": { const __cgt = ");
                self.genExpr(c.expr.*);
                self.write("; if (@hasField(@TypeOf(__cgt), \"Ok\")) { switch (__cgt) { .Ok => |__v| break :");
                self.write(cl);
                self.write(" __v, .Err => ");
                if (c.err_binding) |eb| {
                    self.write("|");
                    self.write(eb);
                    self.write("| ");
                }
                // NOTE: when `err_binding` is null (plain `catch 0`),
                // the arm OMITS the capture entirely — zig 0.16 rejects
                // the loose `|_|` discard form with "discard of capture;
                // omit it instead" (surfaced by
                // examples/error-handling/result.zag's `catch 0`).
                self.write("break :");
                self.write(cl);
                self.write(" ");
                self.genExpr(c.handler.*);
                self.write(", } } else { switch (__cgt) { .Some => |__v| break :");
                self.write(cl);
                self.write(" __v, .None => ");
                // `.None` carries no payload, but a `catch |err| { … }`
                // handler on an OPTION scrutinee may still reference the
                // bound name (the None arm runs the handler per the
                // "binding unused but handler runs" contract above).
                // Bind the option's void payload to the same name the
                // Err arm binds so `err` stays in scope — without the
                // capture zig rejects the reference with "use of
                // undeclared identifier 'err'" (surfaced by
                // examples/error-handling/error_handling.zag's
                // block-handler catch on a Result scrutinee, whose None
                // arm is DEAD code that zig still type-checks).
                if (c.err_binding) |eb| {
                    self.write("|");
                    self.write(eb);
                    self.write("| ");
                }
                self.write("break :");
                self.write(cl);
                self.write(" ");
                self.genExpr(c.handler.*);
                self.write(", } } })");
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
                    if (b.lhs.payload == .string_lit or b.rhs.payload == .string_lit) {
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
                // String concatenation with `+` (docs/11 "Owned
                // Strings" + "String Builder" — the manual's
                // builder-free join surface). Heuristic dispatch: when
                // the operator is `.add` AND at least one operand is
                // string-ish (a `.string_lit` / `.byte_string_lit`, or
                // an ident whose tracked binding type is a byte-slice:
                // `str` / `[]const u8` / `[]u8`), lower to the
                // always-emitted `__zag_str_concat(a, b)` preamble
                // helper — a fresh heap buffer holding a ++ b. Left-assoc
                // chains (`"a" + s + "!"`) work because the inner
                // binary already emitted a concat call and the outer
                // level re-fires on the remaining string-ish operand
                // (the nested-`.binary` operand is string-ish whenever
                // its SIBLING at this level is). Non-string numeric
                // adds fall through to the plain `(a + b)` emit;
                // mixing an int with a string operand is a zig-side
                // type error (loud, not silent) — the manual's
                // int-to-string surface is `{}` interpolation.
                if (b.op == .add) {
                    const lhs_str = switch (b.lhs.payload) {
                        .string_lit, .byte_string_lit => true,
                        .ident => |n| self.isStringishIdent(n),
                        // Left-assoc chains: `"a" + s + "!"` parses as
                        // binary(add, binary(add, "a", s), "!") — the
                        // nested binary is string-ish when THIS level's
                        // sibling is (the level that sees a literal/
                        // ident pair fires the emit; outer levels
                        // cascade off it).
                        .binary => |inner| blk: {
                            if (inner.op != .add) break :blk false;
                            const il = switch (inner.lhs.payload) {
                                .string_lit, .byte_string_lit => true,
                                .ident => |n| self.isStringishIdent(n),
                                else => false,
                            };
                            const ir = switch (inner.rhs.payload) {
                                .string_lit, .byte_string_lit => true,
                                .ident => |n| self.isStringishIdent(n),
                                else => false,
                            };
                            break :blk il or ir;
                        },
                        else => false,
                    };
                    const rhs_str = switch (b.rhs.payload) {
                        .string_lit, .byte_string_lit => true,
                        .ident => |n| self.isStringishIdent(n),
                        else => false,
                    };
                    if (lhs_str or rhs_str) {
                        // Outer parens keep the every-`.binary`-emit-is-
                        // parenthesized invariant the eq/ne shim restored
                        // (see its comment below) — call-site arg slots
                        // rely on the shape.
                        self.write("(__zag_str_concat(");
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
                    // wrapping arithmetic (docs/05 §Wrapping Arithmetic —
                    // verbatim to zig; no shim needed beyond the wrap)
                    .add_wrap => self.write("+%"),
                    .sub_wrap => self.write("-%"),
                    .mul_wrap => self.write("*%"),
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
    // env_var @panic at runtime so a future release
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
    pub     fn genBuiltinCall(self: *Codegen, dispatch: builtins.BuiltinDispatch, args: []const ast.Expr, loc: ast.Loc, receiver: ?[]const u8) void {
        switch (dispatch) {
            .builtin_size_of => {
                self.write("@sizeOf(");
                self.genExpr(args[0]);
                self.write(")");
            },
            .builtin_align_of => {
                self.write("@alignOf(");
                self.genExpr(args[0]);
                self.write(")");
            },
            .builtin_volatile_store => {
                self.write("@volatileStore(");
                self.genExpr(args[0]);
                self.write(", ");
                self.genExpr(args[1]);
                self.write(")");
            },
            .builtin_volatile_load => {
                self.write("@volatileLoad(");
                self.genExpr(args[0]);
                self.write(")");
            },
            .builtin_atomic_load => {
                self.write("@atomicLoad(@TypeOf(");
                self.genExpr(args[0]);
                self.write(".*), ");
                self.genExpr(args[0]);
                self.write(", .seq_cst)");
            },
            .builtin_atomic_store => {
                self.write("@atomicStore(@TypeOf(");
                self.genExpr(args[0]);
                self.write(".*), ");
                self.genExpr(args[0]);
                self.write(", ");
                self.genExpr(args[1]);
                self.write(", .seq_cst)");
            },
            .builtin_atomic_fetch_add => {
                self.write("@atomicRmw(@TypeOf(");
                self.genExpr(args[0]);
                self.write(".*), ");
                self.genExpr(args[0]);
                self.write(", .Add, ");
                self.genExpr(args[1]);
                self.write(", .seq_cst)");
            },
            .builtin_atomic_compare_exchange => {
                // (@cmpxchgStrong(...) == null) — zig's cmpxchg
                // returns ?T (null on SUCCESS, Some(actual) on
                // failure), so the `== null` test converts it to the
                // "CAS succeeded" bool the zag surface declares.
                // Lock loops (`while (!compare_exchange(&w, 0, 1))
                // futex_wait(...);`) need exactly this shape; the
                // raw ?T form leaked zig's optional into zag source,
                // which no zag type annotation can name.
                self.write("(@cmpxchgStrong(@TypeOf(");
                self.genExpr(args[0]);
                self.write(".*), ");
                self.genExpr(args[0]);
                self.write(", ");
                self.genExpr(args[1]);
                self.write(", ");
                self.genExpr(args[2]);
                self.write(", .seq_cst, .seq_cst) == null)");
            },
            .builtin_thread_spawn => {
                // thread_spawn(fn_name, args_tuple)
                self.write("(std.Thread.spawn(.{}, ");
                self.genExpr(args[0]);
                self.write(", ");
                self.genExpr(args[1]);
                self.write(") catch @panic(\"thread spawn failed\"))");
            },
            .builtin_thread_join => {
                self.write("(");
                self.genExpr(args[0]);
                self.write(".join())");
            },
            .builtin_mutex_create => {
                self.write("std.Thread.Mutex{}");
            },
            .builtin_mutex_lock => {
                self.write("(");
                self.genExpr(args[0]);
                self.write(".lock())");
            },
            .builtin_mutex_unlock => {
                self.write("(");
                self.genExpr(args[0]);
                self.write(".unlock())");
            },
            .builtin_assert => {
                self.write("if (!(");
                self.genExpr(args[0]);
                self.write(")) __zag_panic_at(");
                if (args.len >= 2) {
                    self.genExpr(args[1]);
                } else {
                    self.write("\"assertion failed\"");
                }
                self.write(", \"");
                self.write(self.source_path);
                self.write("\", ");
                self.writeInt(loc.line);
                self.write(", ");
                self.writeInt(loc.col);
                self.write(")");
            },
            .builtin_type_name => {
                self.write("@typeName(");
                self.genExpr(args[0]);
                self.write(")");
            },
            .builtin_type_eq => {
                // Comptime type dispatch (`type_eq(K, str)`): emits a
                // zig TYPE-equality `(K == []const u8)`. Args are
                // type-ish idents — generic type params (pass through
                // verbatim) or zag type names (`str` → `[]const u8`
                // via the type-text mapper). The result is
                // comptime-known at every instantiation, so zig's
                // comptime-if discards the untaken branch without
                // type-checking it — which is the property the old
                // preamble helpers (`__zag_keys_eq` / `__zag_key_hash`)
                // relied on happening "in pure zig". Non-ident args
                // (a misuse) fall through to value emission, so the
                // comparison degenerates to comparing comptime values
                // of the same type rather than a compile error.
                self.write("(");
                for (args, 0..) |arg, i| {
                    if (i > 0) self.write(" == ");
                    if (arg.payload == .ident) {
                        self.writeType(arg.payload.ident);
                    } else {
                        self.genExpr(arg);
                    }
                }
                self.write(")");
            },
            .builtin_addr_of => {
                // Address-of (`addr_of(key)` → `(&key)`): .zag has no
                // `&` unary string, so the value-key byte walk needs
                // the builtin to synthesize it. `(&v)` is a
                // single-pointer result; cast sites wrap the usual
                // @alignCast(@ptrCast(...)) for many/slice targets.
                self.write("(&");
                self.genExpr(args[0]);
                self.write(")");
            },
            .builtin_bitcast => {
                // Raw-value reinterpretation (`bitcast(v)` →
                // `@bitCast(v)`): the posix.zag syscall boundary
                // (u32 flag word → the packed-bitfield O flags type).
                self.write("@bitCast(");
                self.genExpr(args[0]);
                self.write(")");
            },
            .builtin_enum_from_int => {
                // Int→enum conversion (`enum_from_int(v)` →
                // `@enumFromInt(v)`): the clockid_t boundary in
                // posix.zag's clock_gettime.
                self.write("@enumFromInt(");
                self.genExpr(args[0]);
                self.write(")");
            },
            // v0.1 String/Writer migration (follow-up commit). The
            // router emits one of two shapes depending on
            // `use_hybrid_stdlib`:
            //  - hybrid mode (project + materialise): the @imported
            //    lib/std/string.zag + lib/std/fmt.zag surface
            //    snake_case methods with 1-arg signatures
            //    (`with_capacity(N)`, `std_out()`, `std_err()`) —
            //    matching the .zag source 1:1.
            //  - file mode (no project root): the inline
            //    `__zag_String_inline` / `__zag_Writer_inline`
            //    structs keep the legacy camelCase 2-arg / 0-arg
            //    signatures (`withCapacity(alloc, capacity)`,
            //    `stdOut()`, `stdErr()`) so the file-mode zig
            //    preamble still compiles without @import of std/.
            //    The split is selected by `use_hybrid_stdlib`;
            //    `src/tests/codegen_builtins.zig`'s positive pins
            //    verify the legacy 2-arg shape (default
            //    use_hybrid_stdlib = false from Codegen.init()).
            .string_with_capacity => {
                // v0.1 Tier-1 follow-up: emit the receiver name from
                // the call site (e.g. `String.with_capacity(4096)` in
                // lib/std/fs.zag) instead of the legacy
                // `__zag_String` alias. The old `__zag_String`
                // spelling points at the per-file INLINE struct in
                // materialized std files, whose type differs from the
                // user-facing imported `String` — returning the
                // inline type from a `var sb: String = ...` binding
                // failed zig's type check. With the receiver name,
                // the emitted call resolves through the file's own
                // `String` alias (imported real type in materialized
                // mode, hybrid-rebound type in user mode). File mode
                // (import_std_base = "std/", no mirror) keeps the
                // legacy 2-arg inline shape.
                if (self.import_std_base.len == 0 or self.use_hybrid_stdlib) {
                    const recv = receiver orelse "String";
                    self.write(recv);
                    self.write(".with_capacity(");
                    self.genExpr(args[0]);
                    self.write(")");
                } else {
                    self.write("__zag_String.with_capacity(std.heap.page_allocator, ");
                    self.genExpr(args[0]);
                    self.write(")");
                }
            },
            .writer_std_out => {
                if (self.use_hybrid_stdlib) {
                    self.write("__zag_Writer.std_out()");
                } else {
                    self.write("__zag_Writer.std_out()");
                }
            },
            .writer_std_err => {
                if (self.use_hybrid_stdlib) {
                    self.write("__zag_Writer.std_err()");
                } else {
                    self.write("__zag_Writer.std_err()");
                }
            },
        }
    }
