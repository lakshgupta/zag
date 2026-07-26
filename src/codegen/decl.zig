const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;

// ============================================================
// FILE-SCOPE methods (DECL bucket)
// ============================================================

    pub     fn rewriteReceiverType(self: *Codegen, text: []const u8, tps: []const ast.TypeParam) void {
        // Generics (§5 Generic impl Blocks): inside an
        // `impl<T, U, ...> Target<T, U, ...>` block, method-receiver
        // `type_text` carries turbofish syntax (`*Target<T>`, `*const
        // Map<K, V>`, `[]Option<T>`). zig's thunk form for generic
        // structs requires paren-monomorphization (`*Target(T)`,
        // `*const Map(K, V)`, `[]Option(T)`), so this helper scans each
        // `<...>` segment inside `text` and converts it to `(...)` when
        // its contents match a type-param name declared on the
        // enclosing impl. Segments whose contents are NOT in the
        // current impl's type-param list are emitted verbatim — the
        // user's other generic types (none generic structs / enums)
        // round-trip as-is and would require explicit handling if v1
        // ever grows multi-param canonical-form generics elsewhere.
        //
        // Multi-token names like `*const Map<K, V>` are handled by
        // walking the segment characters: split on `<`, locate the
        // matching `>` (single-level greedy; nested generic-arg
        // expressions are not chunked, the `K, V` body emits verbatim
        // because no single TypeParam.name matches the comma-bearing
        // string), then rewrite-or-leave the contents. First-segment
        // rewrite only — the user's v1 surface is single-level
        // turbofish as per docs/16 §1 (`T`, `T, U`, `K, V`).
        //
        // Choosing Option A (rewrite only when contents match the
        // current impl's type_params) over the more aggressive
        // every-`<...>` rewrite keeps generic-enum mono usage working
        // at impl-block receivers where no rewrite is wanted.
        if (tps.len == 0) {
            self.write(text);
            return;
        }
        var i: usize = 0;
        while (i < text.len) {
            const lt = std.mem.indexOfScalar(u8, text[i..], '<');
            if (lt == null) {
                self.write(text[i..]);
                return;
            }
            const lt_abs = i + lt.?;
            self.write(text[i..lt_abs]);
            // Find the matching `>` (single-level; nested generics not
            // yet supported as a turbofish case).
            const gt_rel = std.mem.indexOfScalar(u8, text[lt_abs + 1 ..], '>');
            if (gt_rel == null) {
                // Unbalanced `<` — emit the rest verbatim and bail.
                self.write(text[lt_abs..]);
                return;
            }
            const inner_start = lt_abs + 1;
            const inner_end = lt_abs + 1 + gt_rel.?;
            const inner = text[inner_start..inner_end];
            // Trim whitespace so `Map< K, V >` (source-discretionary
            // spacing) doesn't miss the tps match by a stray space.
            var a: usize = 0;
            var b: usize = inner.len;
            while (a < b and (inner[a] == ' ' or inner[a] == '\t')) : (a += 1) {}
            while (b > a and (inner[b - 1] == ' ' or inner[b - 1] == '\t')) : (b -= 1) {}
            const trimmed = inner[a..b];
            var matched: ?[]const u8 = null;
            for (tps) |tp| {
                if (std.mem.eql(u8, tp.name, trimmed)) {
                    matched = tp.name;
                    break;
                }
            }
            if (matched) |name| {
                self.write("(");
                self.write(name);
                self.write(")");
            } else {
                // Not a current-impl type-param; emit the segment
                // verbatim (non-generic use case, or a generic-enum
                // reference that v1 doesn't yet rewrite).
                self.write("<");
                self.write(inner);
                self.write(">");
            }
            i = inner_end + 1;
        }
    }

    pub     fn genFreeMethod(self: *Codegen, target_type: []const u8, m: ast.MethodDecl, impl_type_params: []const ast.TypeParam) void {
        // Trait-method rename (docs/17 §"Implementing"): when `m.trait_name`
        // is set (the `Trait.method` source shape), the emitted free-fn name
        // becomes `<TargetType>_<TraitName>_<MethodName>` so the vtable
        // registration can reference the implementation by exact-name. The
        // legacy orphan path emits `<TargetType>_<MethodName>` so trait-method
        // and non-trait methods never collide (the renaming infix adds the
        // trait-qualifier). The pre-trait shape (no trait_name) keeps the
        // legacy 234-baseline path so all orphan-impl tests pin identically.
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        if (m.trait_name) |tn| {
            @memcpy(name_buf[name_len..][0..target_type.len], target_type);
            name_len += target_type.len;
            name_buf[name_len] = '_';
            name_len += 1;
            @memcpy(name_buf[name_len..][0..tn.len], tn);
            name_len += tn.len;
            name_buf[name_len] = '_';
            name_len += 1;
            @memcpy(name_buf[name_len..][0..m.name.len], m.name);
            name_len += m.name.len;
        }
        self.write("pub fn ");
        if (m.trait_name != null) {
            self.write(name_buf[0..name_len]);
        } else {
            self.write(target_type);
            self.write("_");
            self.write(m.name);
        }
        self.write("(");
        // Generics impl-level type_params preamble. Mirrors genMethod
        // and genFun so generic impl-blocks land as
        // `pub fn List_T_push(comptime T: type, self: *List(T), value: T)`.
        // The `*List(T)` receiver is produced by `rewriteReceiverType`
        // (above) which converts `<TyParamName>` to `(TyParamName)` for
        // each segment whose contents match the impl's declared type
        // params. See `rewriteReceiverType`'s doc for the multi-token
        // and non-matching-passthrough semantics.
        const generics_preamble = self.genTypeParamsPreamble(impl_type_params);
        for (m.params, 0..) |p, i| {
            if (i > 0 or generics_preamble) self.write(", ");
            // Phase 2 var-p name-isolation (zig 0.16 fix): when
            // `is_var` is set, rename the parameter to
            // `__zag_local_<name>` so the body's
            // `var <name> = __zag_local_<name>;` introduces a fresh
            // local rather than shadowing the parameter. zig 0.16
            // rejects any local variable that shares a name with a
            // function parameter (`local variable 'x' shadows
            // function parameter from outer scope`).
            if (p.is_var) self.write("__zag_local_");
            self.write(p.name);
            self.write(": ");
            self.rewriteReceiverType(zagTypeToZig(p.type_text), impl_type_params);
        }
        self.write(") ");
        if (m.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(" {\n");
        // Reset per-function counters (matching `genMethod`/`genFun`).
        self.destructure_counter = 0;
        self.alloc_counter = 0;
        self.match_counter = 0;
        // Phase 1 codegen-router: env_counter reset mirrors the argv
        // counter pattern so sibling `__env_<N>` temps (one per
        // env_var / getEnv call site) start fresh at `_0` per fn.
        // Without this reset, sibling pub fns would reuse the same
        // `__env_0` name and zig's no-redeclaration rule would reject
        // a sibling fn body's emit.
        // Phase 2 codegen-router: fs_counter reset mirrors env_counter
        // above. Sibling `pub fn` declarations with read_file calls
        // get their own scoped counter slot to avoid `__fs_<N>`
        // redeclaration when two fns in the same module both call
        // read_file.
        self.fs_counter = 0;
        // Phase 3 (CLI migration) codegen-router: write_file / mkdir /
        // exec counters reset mirrors the fs_counter (Phase 2) pattern
        // above so each fn body has its own scoped counter slot
        // starting at `_0`. `process_exit` doesn't need a counter —
        // its emit is a single inline statement with no temp names.
        self.type_info_count = 0;
        self.fn_returns_value = m.return_type != null;
        // v1.6 byte-slice widening: set the per-body method-receiver
        // struct-name so `print(self.byte_slice_field)` widens the
        // format spec to `{s}` (per typeAwareFmtSpecFromExpr in
        // src/codegen/primary.zig). Reset on next genFun body entry
        // or on the next non-impl member set, so subsequent fns /
        // orphans don't inherit this impl's receiver by mistake.
        self.current_receiver_struct_name = target_type;
        // Trait-bounds guards (docs/16 §3) — mirrors genFun's body
        // entry so unresolved impl-block generic bounds surface
        // as a zag compile-error at the user's source-line.
        self.genBoundsGuards(impl_type_params);
        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry. The
        // fresh local `<name>` is mutable (allowing body mutations like
        // `x += 1`), and the parameter carrying the caller's value
        // passes through zig's pass-by-value default — caller isolation
        // is preserved. The body still references `<name>` verbatim; the
        // local shadows nothing because the parameter has a different
        // name (`__zag_local_<name>`).
        for (m.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = __zag_local_");
                self.write(p.name);
                self.write(";\n");
            }
        }
        for (m.body) |s| self.collectTypedBindings(s);
        for (m.body, 0..) |s, i| self.genStmt(s, self.fn_returns_value and i == m.body.len - 1);
        // Reset ONLY the receiver-tracking field at body end —
        // `fn_returns_value` is set per-body by every genFun/
        // genMethod/genFreeMethod entry, so an explicit reset
        // would be redundant (and was previously rejected by the
        // code-reviewer as a stray copy-paste — left as a comment
        // here so future drive-by cleanups don't reintroduce it).
        self.current_receiver_struct_name = null;
        self.write("}\n");
    }

    pub     fn genStructDecl(self: *Codegen, sd: ast.StructDecl, all_impls: []const ast.ImplBlock) void {
        // Doc (docs/02 §"Doc Comments"): emit `/// ` lines immediately
        // BEFORE the `pub const NAME = ...` emit so the doc survives
        // through to the zig container site. Mirrors genFun's
        // `if (fun.doc) |d| self.genDocComment(d)` call. The parser
        // has already attached `sd.doc` via StructDecl.doc — null
        // means no doc, render the bare `pub const NAME = struct {...}`
        // shape (existing tests pin this path).
        if (sd.doc) |d| self.genDocComment(d);
        // Generics (§2 Generic Types): when `sd.type_params.len > 0`,
        // emit the thunk form `pub fn NAME(comptime T0: type, ...) type
        // { return struct { … }; }` so call sites `List(i32, ...)`
        // resolve at monomorphization time. The non-generic path keeps
        // the existing `pub const NAME = struct { … };` shape so all
        // pre-existing tests/examples round-trip unchanged.
        //
        // Nested impl-method emission is SKIPPED on the thunk path. The
        // returned struct type cannot contain methods directly (zig
        // compiles the return type as a fresh anonymous type per call
        // site, so nested methods would clash on per-monomorphization
        // vtable construction). The `generate` function in core.zig
        // marks generic structs as orphans by NOT recording them in
        // `matched_targets_buf` so the matching impls fall through to
        // `genFreeMethod`'s orphan-impl emit. The free-fn name encodes
        // `TargetType_methodName` and includes the rewritten receivers
        // (via `rewriteReceiverType`), so `List_T_push(comptime T: type,
        // self: *List(T), value: T)` is the actual emitted form once
        // generic impl-block wires in.
        const is_generic = sd.type_params.len > 0;
        if (is_generic) {
            self.write("pub fn ");
            self.write(sd.name);
            self.write("(");
            _ = self.genTypeParamsPreamble(sd.type_params);
            self.write(") type {\n    return struct {\n");
        } else {
            self.write("pub const ");
            self.write(sd.name);
            self.write(" = struct {\n");
        }
        for (sd.fields) |f| {
            switch (f.kind) {
                .named => |nf| {
                    self.write("    ");
                    self.write(nf.name);
                    self.write(": ");
                    self.writeType(nf.type_text);
                    self.write(",\n");
                },
                .embed => |ef| {
                    // Embedding promotion: docs/12 "embedded types promote
                    // their fields + methods into the outer struct". The
                    // simplifcation is to emit a named field whose type is
                    // the embedded type itself; `.field` access then goes
                    // through a one-level indirection (`btn.Widget.x`).
                    // Strict Promotion (where `btn.x` resolves directly) is
                    // deferred to a followup commit because zig 0.16 does
                    // not expose anonymous-struct flattening macros — a
                    // field-shorthand trick is plausible but breaks
                    // struct-literal's `T { .f = … }` enforcement on
                    // anonymous fields, so the indirection form is the
                    // safe first-pass until the spread-flavor lands.
                    self.write("    ");
                    self.write(ef.type_name);
                    self.write(": ");
                    self.write(ef.type_name);
                    self.write(" = .{}, // embedded (promote fields+methods via dot deref) \n");
                },
            }
        }
        // Embedding promotion: for each embed field, emit forwarding
        // getter methods that flatten the embedded type's fields and
        // methods into the outer struct's namespace. `btn.pos()` and
        // `btn.click()` resolve directly — no `btn.Widget.` prefix
        // needed. Only runs on the non-generic path (generic structs
        // use thunk form which can't host nested methods).
        if (!is_generic) {
            for (sd.fields) |f| {
                if (f.kind != .embed) continue;
                const embed_type = f.kind.embed.type_name;
                // Forward named fields of the embedded struct as
                // getter methods.
                for (self.prog.structs) |esd| {
                    if (!std.mem.eql(u8, esd.name, embed_type)) continue;
                    for (esd.fields) |ef| {
                        if (ef.kind != .named) continue;
                        const fn_field = ef.kind.named;
                        self.write("    pub fn ");
                        self.write(fn_field.name);
                        self.write("(self: *const ");
                        self.write(sd.name);
                        self.write(") ");
                        self.writeType(fn_field.type_text);
                        self.write(" {\n");
                        self.write("        return self.");
                        self.write(embed_type);
                        self.write(".");
                        self.write(fn_field.name);
                        self.write(";\n");
                        self.write("    }\n");
                    }
                    break;
                }
                // Forward non-trait methods from impl blocks on the
                // embedded type.
                for (self.prog.impls) |impl| {
                    if (!std.mem.eql(u8, impl.target_type, embed_type)) continue;
                    for (impl.methods) |m4| {
                        if (m4.trait_name != null) continue;
                        self.write("    pub fn ");
                        self.write(m4.name);
                        self.write("(");
                        // Rewrite the first param (self) to the outer type
                        for (m4.params, 0..) |p4, pi| {
                            if (pi > 0) self.write(", ");
                            self.write(p4.name);
                            self.write(": ");
                            if (p4.is_self) {
                                self.write("*");
                                self.write(sd.name);
                            } else {
                                self.writeType(p4.type_text);
                            }
                        }
                        self.write(") ");
                        if (m4.return_type) |rt| self.writeType(rt) else self.write("void");
                        self.write(" {\n");
                        if (m4.return_type != null) {
                            self.write("        return ");
                        } else {
                            self.write("        ");
                        }
                        self.write("self.");
                        self.write(embed_type);
                        self.write(".");
                        self.write(m4.name);
                        self.write("(");
                        for (m4.params, 0..) |p5, pj| {
                            if (pj > 0) self.write(", ");
                            if (pj == 0 and p5.is_self) {
                                self.write("&self.");
                                self.write(embed_type);
                            } else {
                                self.write(p5.name);
                            }
                        }
                        self.write(");\n");
                        self.write("    }\n");
                    }
                }
            }
        }
        // Nest matching impl methods inside the struct definition. The
        // body emission path is shared with `genFun` so all the existing
        // stmt/expr handling (destructuring, compound assign, if/match,
        // etc.) works for methods too. Each method body sees a fresh
        // counter set so destructuring temps + new-temporaries inside
        // the method don't clash with sibling methods' temps. SKIPPED
        // on the generic struct path because the thunk-returned type
        // cannot host nested methods (zig compiles each monomorphization
        // to a fresh anonymous type); see the doc above on the thunk
        // form. The orphan-impl routing in `generate` catches the
        // matching impls and lands them at module scope. TRAIT-method
        // methods (Trait.method-prefixed impl methods whose
        // `trait_name` is non-null) are SKIPPED here too — they emit
        // as renamed free fns (Target_Trait_method) + vtable
        // registration during the trait-handling pass, NEVER nested
        // inside the struct body (the nested shape lacks the trait
        // prefix in the zig fn name which the vtable registration
        // references by exact-string).
        if (!is_generic) {
            for (all_impls) |impl| {
                if (!std.mem.eql(u8, impl.target_type, sd.name)) continue;
                for (impl.methods) |m| {
                    // Canonical `with Trait (m)` dispatch (docs/17
                    // §"Diamond Disambiguation"): a method bound to a
                    // trait (via the legacy `Trait.method` prefix OR the
                    // block's `trait_specs` clause) skips nested-emit so
                    // the trait-handling pass in `generate` emits the
                    // renamed `<Target>_<Trait>_<Method>` free fn and
                    // matching vtable registration. Regular-type-method
                    // path (c) emits nested here.
                    if (self.resolveTraitBinding(&impl, m) != null) continue;
                    // v1.6 byte-slice widening: set receiver-struct
                    // before emitting the nested method body so
                    // `print(self.byte_slice_field)` widens correctly.
                    // Mirrors genFreeMethod's setting.
                    self.current_receiver_struct_name = impl.target_type;
                    // Phase 2 tail: thread impl-level type_params so the
                    // nested method emits `comptime X: type` BEFORE its
                    // own params. Mirrors genFreeMethod's call update.
                    self.genMethod(m, impl.type_params);
                    self.current_receiver_struct_name = null;
                }
            }
        }
        if (is_generic) {
            // Close both layers of the thunk form: the inner
            // `return struct { … };` and the outer `pub fn NAME(…) type
            // { … }`. Without the double-closing brace zig rejects the
            // emission with "expected '}' after struct body".
            self.write("    };\n}\n\n");
        } else {
            self.write("};\n\n");
        }
    }

    pub     fn genMethod(self: *Codegen, m: ast.MethodDecl, impl_type_params: []const ast.TypeParam) void {
        self.write("    pub fn ");
        self.write(m.name);
        self.write("(");
        // Generics impl-level type_params preamble. Mirrors genFun
        // — emits `comptime X: type` (or `comptime X: TYPE`) for each
        // impl-block type-param BEFORE the method's own params. The
        // matching call site (genStructDecl / genEnumDecl for the
        // nested case; the orphan-impl loop in generate for the
        // free-fn case via genFreeMethod) threads `impl.type_params`
        // in. Phase 4 wires the `*List<T>` → `*List(T)` receiver
        // rewrite via `rewriteReceiverType` so generic impl-block
        // method parameters resolve through the thunk form.
        const generics_preamble = self.genTypeParamsPreamble(impl_type_params);
        for (m.params, 0..) |p, i| {
            if (i > 0 or generics_preamble) self.write(", ");
            // Phase 2 var-p name-isolation (zig 0.16 fix): when
            // `is_var` is set, rename the parameter to
            // `__zag_local_<name>` so the body's
            // `var <name> = __zag_local_<name>;` introduces a fresh
            // local rather than shadowing the parameter. zig 0.16
            // rejects any local variable that shares a name with a
            // function parameter (`local variable 'x' shadows
            // function parameter from outer scope`).
            if (p.is_var) self.write("__zag_local_");
            self.write(p.name);
            self.write(": ");
            self.rewriteReceiverType(zagTypeToZig(p.type_text), impl_type_params);
        }
        self.write(") ");
        if (m.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(" {\n");
        // Trait-bounds guards (docs/16 §3) — see genFun's comment.
        self.genBoundsGuards(impl_type_params);
        // Reset per-function counters before this method body's emission
        // so destructuring temps (`__destruct_<N>`) and `new` temps
        // (`__p_<N>`) and match scrutinees (`__m_<N>`) start fresh at
        // `_0`. These counters will be re-zeroed at the next `genFun`
        // entry anyway, but resetting here ensures the method body
        // inside a struct definition has its own local counter space.
        self.destructure_counter = 0;
        self.alloc_counter = 0;
        self.match_counter = 0;
        // Phase 1 codegen-router: env_counter reset mirrors the argv
        // counter pattern above so nested methods get a clean
        // `__env_<N>` sequence starting at `_0`.
        // Phase 2 codegen-router: fs_counter reset mirrors env_counter
        // above so nested methods get a clean `__fs_<N>` sequence
        // starting at `_0`. The fs_read_file dispatch emits
        // `var __io_threaded = std.Io.Threaded.init(...)` per call
        // so a sibling read_file in the same method body needs its
        // own scoped counter slot to avoid `__fs_<N>` redeclaration.
        self.fs_counter = 0;
        // Phase 3 (CLI migration) codegen-router: write_file / mkdir /
        // exec counters reset mirrors the fs_counter (Phase 2) pattern
        // above so each fn body has its own scoped counter slot
        // starting at `_0`. `process_exit` doesn't need a counter —
        // its emit is a single inline statement with no temp names.
        // Re-populate the per-function type-info map for any locally-
        // declared typed bindings inside the method body so the
        // div-shim predicate (`needsIntDivShim`) gets correct info
        // for the method's own locals (not the enclosing pub fn's).
        self.type_info_count = 0;
        self.fn_returns_value = m.return_type != null;
        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry. The
        // fresh local `<name>` is mutable (allowing body mutations like
        // `x += 1`), and the parameter carrying the caller's value
        // passes through zig's pass-by-value default — caller isolation
        // is preserved. The body still references `<name>` verbatim; the
        // local shadows nothing because the parameter has a different
        // name (`__zag_local_<name>`).
        for (m.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = __zag_local_");
                self.write(p.name);
                self.write(";\n");
            }
        }
        for (m.body) |s| self.collectTypedBindings(s);
        for (m.body, 0..) |s, i| self.genStmt(s, self.fn_returns_value and i == m.body.len - 1);
        self.write("    }\n");
    }

    pub     fn genBoundsGuards(self: *Codegen, tps: []const ast.TypeParam) void {
        // Generics trait-bounds (docs/16 §3): emit one
        // `if (!@hasDecl(TP_name, "method_name")) @compileError(...);`
        // guard per bounded TypeParam. Called at body entry (BEFORE
        // var-p injection) so unresolved bounds surface as a zag
        // compile-error at the user's source-line, not as a zig
        // panic downstream.
        //
        // Unknown traits (not in boundToMethodName's canonical map)
        // skip the guard emit entirely — Phase 3 will replace this
        // pragmatic carve-out with a real trait-system wiring.
        for (tps) |tp| {
            for (tp.bounds) |b| {
                const method = boundToMethodName(b);
                if (std.mem.eql(u8, method, b)) continue;
                self.write("    if (!@hasDecl(");
                self.write(tp.name);
                self.write(", \"");
                self.write(method);
                self.write("\")) @compileError(\"type ");
                self.write(tp.name);
                self.write(" must implement ");
                self.write(b);
                self.write(" (missing `");
                self.write(method);
                self.write("` method)\");\n");
            }
        }
    }

    pub     fn genTypeParamsPreamble(self: *Codegen, tps: []const ast.TypeParam) bool {
        // Emit `comptime X: type` (non-const) or `comptime X: TYPE`
        // (const-generic) for each type-param BEFORE the regular param
        // emit. Returns true if any preamble was emitted so the
        // caller can insert a `, ` separator between the last
        // type-param and the first regular param.
        //
        // For `const N: TYPE` slots, the verbatim type_text is
        // emitted directly (zig accepts `comptime N: usize` / `comptime
        // N: *const usize` / etc., reusing collectCastType's
        // multi-token capture pipeline).
        var emitted = false;
        for (tps) |tp| {
            if (emitted) self.write(", ");
            self.write("comptime ");
            self.write(tp.name);
            self.write(": ");
            if (tp.is_const) {
                // type_text is set by parseTypeParam when `is_const =
                // true`. We panic on a missing type_text rather than
                // fall back to a sentinel — a parser regression
                // surfacing as a zag compile-time panic is the desired
                // diagnostic, not a silently-wrong type at every
                // const-param site. Wrap through `zagTypeToZig` so
                // `fun foo(comptime N: str)` round-trips to `comptime
                // N: []const u8` (docs/07 transparent-alias contract).
                self.writeType(tp.type_text.?);
            } else {
                self.write("type");
            }
            emitted = true;
        }
        return emitted;
    }

    pub     fn zagTypeToZig(text: []const u8) []const u8 {
        // Type aliases (docs/07 "Type Aliases"): zag provides
        //     type str = []const u8;
        // and "Aliases are transparent" — the type and its alias are
        // the same type under the v1 type system. Codegen expands
        // the alias at emit time so downstream zig sees the canonical
        // `[]const u8` directly rather than the bare `str` ident
        // (which zig has no type slot for and would reject with
        // `unknown type name "str"` once any user writes a `str`-
        // typed annotation, param, return, cast, struct field, enum
        // payload, or binding annotation).
        //
        // v1 alias set is intentionally narrow (`str` only — the
        // borrowed-string-view alias documented in docs/11). Primitive
        // aliasing (`i32`, `f64`, `bool`, ...) is unnecessary because
        // those already are zig's native types and round-trip verbatim.
        // This helper returns `text` unchanged for any non-matching
        // input so callers don't need a `if (text == "str")` guard
        // at every emit site — the function call itself is the guard.
        //
        // The pin-test for this resolution path is
        // `codegen: void fun emits pub fn NAME(...) void` in
        // src/tests/codegen.zig (source: `fun greet(name: str) {
        // print("hello, {name}\n"); }` must emit `pub fn
        // greet(name: []const u8) void`). Any future alias
        // (docs/07 Phase 2: numeric type aliases, generic type
        // aliases, etc.) follows the same `if (eql(u8, t, NAME))
        // return CANONICAL;` pattern; do NOT site-specialize the
        // alias to a single emit location.
        if (std.mem.eql(u8, text, "str")) return "[]const u8";
        // v1.5 raw pointer shapes (docs/09 §\"Raw Pointers\"): zag's
        //     *raw T        — raw pointer to T       →  zig   [*]T
        //     ?*raw T       — optional raw pointer   →  zig   ?[*]T
        // General `*raw T` → `[*]T` rewrite (zig 0.16 uses `[*]` for
        // many-pointers, not `*raw`). Also handles `c_void` → `anyopaque`
        // for FFI compatibility.
        if (std.mem.indexOf(u8, text, "*raw ")) |idx| {
            const inner = text[idx + "*raw ".len ..];
            var scratch: [256]u8 = undefined;
            var slen: usize = 0;
            @memcpy(scratch[slen..][0..idx], text[0..idx]);
            slen += idx;
            @memcpy(scratch[slen..][0..3], "[*]");
            slen += 3;
            if (std.mem.eql(u8, inner, "c_void")) {
                @memcpy(scratch[slen..][0..9], "anyopaque");
                slen += 9;
            } else {
                @memcpy(scratch[slen..][0..inner.len], inner);
                slen += inner.len;
            }
            return scratch[0..slen];
        }
        if (std.mem.indexOf(u8, text, "?*raw ")) |idx| {
            const inner = text[idx + "?*raw ".len ..];
            var scratch: [256]u8 = undefined;
            var slen: usize = 0;
            @memcpy(scratch[slen..][0..idx], text[0..idx]);
            slen += idx;
            @memcpy(scratch[slen..][0..4], "?[*]");
            slen += 4;
            if (std.mem.eql(u8, inner, "c_void")) {
                @memcpy(scratch[slen..][0..9], "anyopaque");
                slen += 9;
            } else {
                @memcpy(scratch[slen..][0..inner.len], inner);
                slen += inner.len;
            }
            return scratch[0..slen];
        }
        if (std.mem.eql(u8, text, "c_void")) return "anyopaque";
        // Phase 3 (CLI migration) followup: extend the alias table to
        // cover the array-shaped forms `[]str` and `[N]str` so a
        // `let args: [3]str = ...;` binding or a `[3]str { a, b, c }`
        // array-literal rounds-trips to `[3][]const u8` instead of
        // surfacing a bare `str` ident to zig (which has no such
        // type slot and rejects with `undeclared identifier 'str'`).
        // The cli.zag bootstrap's `spawn_leaf` function uses both
        // forms in one body, so the mapping is end-to-end-exercised
        // by the e2e test that imports lib/cli.zag.
        //
        // The mappings are LITERAL on the bracket shape (the parser
        // captures the full bracket text including the size digit
        // span, e.g. `[3]str` and `[15]?[:0]u8`); a future generic
        // array alias would need a more general rewriter (the
        // `.range`-style walk of <...> segments in
        // `rewriteReceiverType` is the model). For v1, the two
        // concrete sizes (slice + fixed-3) cover the only
        // array-of-strings shape that the CLI bootstrap uses.
        if (std.mem.eql(u8, text, "[]str")) return "[][]const u8";
        if (std.mem.eql(u8, text, "[3]str")) return "[3][]const u8";
        // v2 char fix path (docs/features.md §08 v2 4-byte Unicode char
        // row): zag's `char` ident silently rewrites to zig's `u32`
        // primitive so let-bind / var-bind / struct-field / enum-varlist /
        // impl-method-receiver / fun-param / fun-return surfaces emit a
        // type zig's 0.16 lexer accepts. Pin: codegen test (a) `char
        // type ident silently rewrites to u32` and the integration test
        // `let c: char = '\u2764' surfaces both gap (a) and gap (c)
        // lanes together` both-fixed form arm.
        if (std.mem.eql(u8, text, "char")) return "u32";
        return text;
    }


    pub     fn boundToMethodName(b: []const u8) []const u8 {
        // Maps docs/16 §3 trait-bound names to the canonical method
        // name that a conforming zig type would expose. Pinned
        // mapping (from the user's review-confirmed spec):
        //   Clone          → clone()
        //   Default        → default()
        //   Zero           → is_zero()
        //   Ordered        → compare()  (used by sind, max, etc.)
        //   Display        → display()
        //   Iterator<T>    → next()  (v1 — the `<T>` form is ignored)
        //   AsyncStream<T> → poll_next()  (v1 — same carve-out)
        //
        // Returns `b` (the input) verbatim when no mapping exists,
        // which `genBoundsGuards` treats as "skip guard emit" so
        // unspecified bounds pass through silently until the trait
        // system wires in (Phase 3).
        if (std.mem.eql(u8, b, "Clone")) return "clone";
        if (std.mem.eql(u8, b, "Default")) return "default";
        if (std.mem.eql(u8, b, "Zero")) return "is_zero";
        if (std.mem.eql(u8, b, "Ordered")) return "compare";
        if (std.mem.eql(u8, b, "Display")) return "display";
        if (std.mem.eql(u8, b, "Iterator")) return "next";
        if (std.mem.eql(u8, b, "AsyncStream")) return "poll_next";
        return b;
    }

    pub     fn rewriteSelfToT(self: *Codegen, text: []const u8) void {
        // Docs/17 §"Self": `Self` refers to the implementing type.
        // In trait VTable function-pointer types and dispatch shims,
        // `Self` is rewritten to `anyopaque` — the vtable function
        // signatures use `*anyopaque` throughout so the dispatch
        // shim can forward any concrete type through the vtable
        // without a comptime type parameter.
        var scratch_buf: [256]u8 = undefined;
        var scratch_len: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const found = std.mem.indexOf(u8, text[i..], "Self");
            if (found == null) {
                const tail = text[i..];
                if (scratch_len + tail.len <= scratch_buf.len) {
                    @memcpy(scratch_buf[scratch_len..][0..tail.len], tail);
                    scratch_len += tail.len;
                }
                break;
            }
            const abs = i + found.?;
            const pre = text[i..abs];
            if (scratch_len + pre.len <= scratch_buf.len) {
                @memcpy(scratch_buf[scratch_len..][0..pre.len], pre);
                scratch_len += pre.len;
            }
            const replacement = "anyopaque";
            if (scratch_len + replacement.len <= scratch_buf.len) {
                @memcpy(scratch_buf[scratch_len..][0..replacement.len], replacement);
                scratch_len += replacement.len;
            }
            i = abs + "Self".len;
        }
        self.writeType(scratch_buf[0..scratch_len]);
    }

    pub     fn genTraitDecl(self: *Codegen, td: ast.TraitDecl) void {
        // Doc (docs/02 §"Doc Comments"): emit `/// ` lines BEFORE the
        // `pub const NAME = struct { ... }` emit (mirrors genStructDecl
        // and genFun; struct vs trait both surface as named zig
        // containers).
        if (td.doc) |d| self.genDocComment(d);
        // Docs/17 §"Definition": `trait NAME { fun draw(self: *Self); ... }`
        // compiles to a zig fat-pointer container holding (data ptr,
        // vtable ptr), an inner VTable struct of function pointers keyed
        // by method name, and a per-method dispatch shim:
        //
        //   pub const NAME = struct {
        //       pub const VTable = struct {
        //           m1: *const fn (ptr: *anyopaque, ...) RET1,
        //           m2: *const fn (ptr: *anyopaque, ...) RET2,
        //       };
        //       ptr: *anyopaque,
        //       vtable: *const VTable,
        //       pub fn m1(self: NAME) RET1 {
        //           return self.vtable.m1(self.ptr);
        //       }
        //       ...
        //   };
        //
        // Vtable dispatch is purely runtime — the function pointer
        // is looked up via `self.vtable` and the data pointer is
        // `self.ptr` (`*anyopaque`). No comptime type parameter is
        // needed; the concrete type is determined at cast time (when
        // `btn as Drawable` constructs the fat pointer).
        //
        // The receiver parameter (`self: *Self`) is always the FIRST
        // param in a trait method signature per the docs/17 §"Definition"
        // grammar. The dispatch path omits this slot because the receiver
        // collapses to `self.ptr` (an `*anyopaque`) at the vtable signature
        // and to `self: NAME` (the trait container type) at the dispatch
        // shim signature. Subsequent params (additional user-declared args)
        // round-trip through `rewriteSelfToT` so any `*Self`-typed arg
        // converts to `*anyopaque` — the vtable function-pointer type
        // uses `*anyopaque` for all Self-derived parameters.
        self.write("pub const ");
        self.write(td.name);
        self.write(" = struct {\n");
        self.write("    pub const VTable = struct {\n");
        for (td.methods, 0..) |m, mi| {
            // VTable field name: suffixed for overloaded methods.
            var sfn_buf: [128]u8 = undefined;
            const vtable_name = blk: {
                var dup_idx: usize = 0;
                var total: usize = 0;
                for (td.methods) |tm| {
                    if (std.mem.eql(u8, tm.name, m.name)) {
                        if (total < mi) dup_idx += 1;
                        total += 1;
                    }
                }
                if (total <= 1) break :blk m.name;
                @memcpy(sfn_buf[0..m.name.len], m.name);
                const sfx = std.fmt.bufPrint(sfn_buf[m.name.len + 1 .. sfn_buf.len], "{d}", .{dup_idx}) catch "0";
                sfn_buf[m.name.len] = '_';
                break :blk sfn_buf[0 .. m.name.len + 1 + sfx.len];
            };
            self.write("        ");
            self.write(vtable_name);
            self.write(": *const fn (ptr: *anyopaque");
            // Additional params (skip the always-first `self` receiver).
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
                self.write(": ");
                self.rewriteSelfToT(p.type_text);
            }
            self.write(") ");
            if (m.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
            self.write(",\n");
        }
        self.write("    };\n");
        // Fat-pointer container fields (data ptr + vtable ptr).
        self.write("    ptr: *anyopaque,\n");
        self.write("    vtable: *const VTable,\n");
        // Per-method dispatch shim. Each shim is a thin wrapper that
        // forwards to the trait-defined vtable slot; the extra comptime
        // the dispatch shim uses the correct vtable field.
        for (td.methods, 0..) |m, mi| {
            var sfn_buf: [128]u8 = undefined;
            const vtable_name = blk: {
                var dup_idx: usize = 0;
                var total: usize = 0;
                for (td.methods) |tm| {
                    if (std.mem.eql(u8, tm.name, m.name)) {
                        if (total < mi) dup_idx += 1;
                        total += 1;
                    }
                }
                if (total <= 1) break :blk m.name;
                @memcpy(sfn_buf[0..m.name.len], m.name);
                const sfx = std.fmt.bufPrint(sfn_buf[m.name.len + 1 .. sfn_buf.len], "{d}", .{dup_idx}) catch "0";
                sfn_buf[m.name.len] = '_';
                break :blk sfn_buf[0 .. m.name.len + 1 + sfx.len];
            };
            self.write("    pub fn ");
            self.write(m.name);
            self.write("(self: ");
            self.write(td.name);
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
                self.write(": ");
                self.rewriteSelfToT(p.type_text);
            }
            self.write(") ");
            if (m.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
            self.write(" {\n");
            self.write("        return self.vtable.");
            self.write(vtable_name);
            self.write("(self.ptr");
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
            }
            self.write(");\n");
            self.write("    }\n");
        }
        self.write("};\n\n");
    }

    pub     fn genTraitRegistration(self: *Codegen, trait_name: []const u8, target_type: []const u8, methods: []const ast.MethodDecl, method_field_names: []const []const u8, default_methods: []const []const u8, default_field_names: []const []const u8) void {
        // Docs/17 §"Implementing" — emit a per-(trait, target_type)
        // vtable instantiation so a future `x.draw()` call site (Phase 3
        // — fat-pointer cast encoding) dispatches through THIS
        // registration. The shape:
        //
        //   pub const Trait_VTable_for_Type: Trait.VTable = .{
        //       .method = @ptrCast(&Type_Trait_method),
        //       ...
        //   };
        //
        // The `@ptrCast` 1-arg form lets zig type-infer the destination
        // function-pointer type from the VTable field declaration
        // (`*const fn (ptr: *anyopaque, ...) RET` in `genTraitDecl`).
        // zig 0.16 dropped explicit destination-type args for `@ptrCast`
        // — the destination is taken from the struct-literal field's
        // declared type. Source and destination are both function-
        // pointer types with identical calling convention, so the cast
        // is a "raw rebrand" from the impl-side receiver-type
        // (`*Type`) to the dispatch-side (`*anyopaque`). The free-fn
        // implementation's exact-name reference is preserved so the
        // vtable slot maps 1:1 to the renamed `<Target>_<Trait>_<Method>`
        // orphan-impl emit above.
        self.write("pub const ");
        self.write(trait_name);
        self.write("_VTable_for_");
        self.write(target_type);
        self.write(": ");
        self.write(trait_name);
        self.write(".VTable = .{\n");
        for (methods, method_field_names) |m, fn_| {
            self.write("    .");
            self.write(fn_);
            self.write(" = @ptrCast(&");
            self.write(target_type);
            self.write("_");
            self.write(trait_name);
            self.write("_");
            self.write(m.name);
            self.write("),\n");
        }
        for (default_methods, default_field_names) |_, dfn| {
            self.write("    .");
            self.write(dfn);
            self.write(" = @ptrCast(&");
            self.write(trait_name);
            self.write("__");
            self.write(dfn);
            self.write("),\n");
        }
        self.write("};\n\n");
    }

    pub     fn genEnumDecl(self: *Codegen, ed: ast.EnumDecl, all_impls: []const ast.ImplBlock) void {
        // 3-way emit shape (v2 split landing — docs/13 §"Choosing
        // Between enum and union" + §"Backed Enums"):
        //   1. `ed.backing_type != null` → `enum(T) { V = value, ... }`
        //      (backed enum; requires strict-split at parser level so
        //      variants are bare-with-value, never payload-bearing).
        //   2. `ed.backing_type == null` AND any variant has a payload
        //      (paren-positional OR brace-named-field) → `union(enum)
        //      { Variant: T | struct { ... }, ... }`.
        //   3. `ed.backing_type == null` AND no variants carry a
        //      payload → bare `enum { V1, V2, ... }`.
        var any_payload = false;
        for (ed.variants) |v| {
            if (v.payload_type != null or v.fields.len > 0) {
                any_payload = true;
                break;
            }
        }
        // Gap #3 binary: bare-vs-payload. The codegen's nested-method
        // loop (below) only fires on the BARE path because zig 0.16
        // rejects methods nested inside `union(enum) { ... }` and
        // `enum(T) { ... }` containers. The orphan-impl routing in
        // generate() does NOT re-emit methods for matched targets, so
        // skipping the nest on non-bare enums requires ALSO updating
        // matched_targets_buf push logic in generate() to leave payload-
        // bearing enum names OUT. Both layers must stay in lockstep.
        const ed_is_bare = ed.backing_type == null and !any_payload;
        // Doc (docs/02 §"Doc Comments"): emit `///` lines BEFORE the
        // `pub const NAME = ...` emit (mirrors genStructDecl/genFun).
        if (ed.doc) |d| self.genDocComment(d);
        self.write("pub const ");
        self.write(ed.name);
        self.write(" = ");
        // Branches are mutually exclusive: backed-enum has no
        // payload shape (parser-enforced); union/union(enum) has no
        // backing type (parser-enforced via the strict-split
        // parseEnumDecl rejecting payloads — parseUnionDecl explicitly
        // does not capture backing_type). The any_payload /
        // ed_is_bare computation lives at the TOP of the function
        // (above the doc emit) so both the union-emit branch AND the
        // nested-method loop gate consult the same values downstream.
        if (ed.backing_type) |bt| {
            // Backed-enum emit shape: `enum(T) { V = value, ... }`.
            // No variant payload (parser-enforced). Each variant MAY
            // carry a per-variant value via `v.value_text`; codegen
            // emits `= value` only when non-null so auto-infer (zig's
            // default incrementing) is preserved when the user omits
            // the value text. The backing-type text goes through
            // zagTypeToZig so `str` → `[]const u8` while primitives
            // (`u8`, `i32`) round-trip verbatim.
            // Backing-type rewrite through `zagTypeToZig` (gap #4
            // resolution): a previous carve-out preserved the user's
            // literal `char` here under the assumption that
            // "byte-stream semantics" would be lost via the
            // `char → u32` rewrite, but zig 0.16 rejects an `enum(char)`
            // emit entirely (`undefined identifier 'char'`) — there
            // is no byte-stream form to preserve. The uniform
            // `zagTypeToZig` rewrite is the canonical solution:
            // `char` becomes `u32`, primitives (`u8`, `i32`, `bool`)
            // round-trip verbatim. The str-backed form is split out
            // below — see the `[]const u8` arm. Crucially, the
            // `enum(` opener lives INSIDE the int branch (below)
            // because the str branch emits a struct shape and the
            // `enum(` prefix would produce `enum(struct { ... }`
            // which zig rejects (caught by an earlier turn's
            // debug: `error: expected ')', found ';'` at line 52).
            const bt_rewrite = zagTypeToZig(bt);
            if (std.mem.eql(u8, bt_rewrite, "[]const u8")) {
                // Str-backed shape: zig rejects `enum([]const u8)`
                // because enum tag types must be integers (`expected
                // integer tag type, found '[]const u8'`). Emit a
                // struct-with-const-fields instead — each variant
                // becomes `pub const Name = value;` so `Level.High`
                // references a `*const [N:0]u8` constant that
                // coerces to `[]const u8` (zig's standard str-literal
                // → slice coercion). Value-equality holds because
                // const fields of identical string literals are the
                // SAME canonical literal in the zig binary, and the
                // array-`==` semantics on `[N:0]u8` does element-
                // wise compare when comparing two distinct literals.
                //
                // The matching genBinding wrap path (codegen/stmt.zig)
                // skips wrapping for str-backed variants because the
                // variant IS already `[]const u8` — `let lvl: str =
                // Level.High` round-trips to `let lvl: []const u8 =
                // Level.High;` without any `@tagName` indirection.
                //
                // The closing `};\n\n` is emitted by the outer
                // `};\n\n` write after the if-else chain, so this
                // branch only writes the body. Empty-value fallback
                // (`""`) covers the edge case of a str-backed enum
                // variant without an explicit `= expr` clause —
                // zig requires const-field initializers so a missing
                // value is coerced to the empty-string literal.
                self.write("struct {\n");
                for (ed.variants) |v| {
                    self.write("    pub const ");
                    self.write(v.name);
                    self.write(" = ");
                    if (v.value_text) |vt| {
                        self.write(vt);
                    } else {
                        self.write("\"\"");
                    }
                    self.write(";\n");
                }
            } else {
                // Int / char / bool backing: emit the canonical zig
                // `enum(T) { V = value, ... }` shape. Each variant
                // MAY carry a per-variant value via `v.value_text`;
                // codegen emits `= value` only when non-null so
                // auto-infer (zig's default incrementing) is preserved
                // when the user omits the value text.
                self.write("enum(");
                self.write(bt_rewrite);
                self.write(") {\n");
                for (ed.variants) |v| {
                    self.write("    ");
                    self.write(v.name);
                    if (v.value_text) |vt| {
                        self.write(" = ");
                        self.write(vt);
                    }
                    self.write(",\n");
                }
            }
        } else if (any_payload) {
            // union(enum) emit shape: any variant with non-null
            // payload_type OR non-empty fields triggers the tagged-
            // union form. All variants in a single declaration share
            // the same emission shape — mixing plain variants with
            // payload variants in the same zig container is rejected by
            // zig 0.16 (the `union(enum) { ... }` requires every
            // variant to specify its payload slot OR be its own bare
            // bare-zero-byte tag, which our emit handles by skipping
            // the `: TYPE` tail for payload-less variants).
            self.write("union(enum) {\n");
            for (ed.variants) |v| {
                self.write("    ");
                self.write(v.name);
                if (v.fields.len > 0) {
                    // Brace-named-field payload
                    // (`Drag { x: f64, y: f64 }`): emit
                    // `struct { x: f64, y: f64 }` with the ACTUAL
                    // field names preserved (vs. the legacy single-
                    // letter a/b/c/... scheme used for paren-
                    // positional). The matching constructor emit
                    // (`.enum_variant_ctor` arm) future-work: extend
                    // to use named-struct literal init `.{ .x = x, .y
                    // = y }` instead of the legacy positional
                    // `.{ arg1, arg2 }`. v1's positional ctor still
                    // works because the auto-generated field names
                    // (x, y) align with declaration order, but the
                    // ctor surface for brace-named variants is
                    // deferred until v2.1 lands named-struct-literal
                    // codegen. match-side destructuring
                    // (`Drag { x: w, y: h } => ...`) is similarly
                    // deferred per docs/14 §FFI callout.
                    //
                    // Gap #2 side-table push (emit-side): record
                    // (enum_name, variant_name → fields) so the
                    // `.enum_variant_ctor` arm in genExpr can
                    // recover the user's actual field names at
                    // runtime ctor sites. Without this entry the
                    // ctor arm falls back to the letter-based
                    // alphabetical emit, which zig rejects because
                    // the named-field struct has the user's names
                    // (e.g. `x, y`), NOT `a, b`. The push is
                    // unconditional here so ANY brace-named-field
                    // variant populates the table; branches that
                    // aren't ctor sites don't care about it.
                    if (self.variant_fields_count < self.variant_fields_buf.len) {
                        self.variant_fields_buf[self.variant_fields_count] = .{
                            .enum_name = ed.name,
                            .variant_name = v.name,
                            .fields = v.fields,
                        };
                        self.variant_fields_count += 1;
                    }
                    self.write(": struct { ");
                    for (v.fields, 0..) |f, fi| {
                        if (fi > 0) self.write(", ");
                        self.write(f.name);
                        self.write(": ");
                        self.writeType(f.type_text);
                    }
                    self.write(" }");
                } else if (v.payload_type) |pt| {
                    // zig 0.16 rejects bare `Rect: f64, f64` (parsed
                    // as TWO variants, not one with a tuple type).
                    // Multi-arg payloads MUST be wrapped in an
                    // anonymous struct so zig's tagged-union parser
                    // sees one variant with a struct-typed payload.
                    // Single-arg payloads stay bare (`Circle: f64`
                    // is a valid union(enum) variant type).
                    //
                    // Detection: count commas in `pt`. Zero commas
                    // → single arg, emit verbatim. ≥1 comma → multi-
                    // arg, emit `struct { a: T0, b: T1, ... }` with
                    // sequential single-letter field names (a, b, c,
                    // …). The matching constructor emit
                    // (`.enum_variant_ctor` arm) uses positional init
                    // `.{ x, y }` which zig forwards to the struct's
                    // named fields in declaration order, so the emit-
                    // side letter sequence must align with the parse
                    // order of the source's comma-list.
                    var comma_count: usize = 0;
                    for (pt) |c| if (c == ',') {
                        comma_count += 1;
                    };
                    if (comma_count == 0) {
                        self.write(": ");
                        self.writeType(pt);
                    } else {
                        self.write(": struct { ");
                        const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
                        var seg_start: usize = 0;
                        var idx: usize = 0;
                        var i: usize = 0;
                        while (i <= pt.len) : (i += 1) {
                            if (i == pt.len or pt[i] == ',') {
                                // Trim leading/trailing whitespace
                                // from the captured type-text segment
                                // so `f64, f64` doesn't emit
                                // `: a: f64, b:  f64`.
                                var a: usize = seg_start;
                                var b: usize = i;
                                while (a < b and (pt[a] == ' ' or pt[a] == '\t')) a += 1;
                                while (b > a and (pt[b - 1] == ' ' or pt[b - 1] == '\t')) b -= 1;
                                if (idx > 0) self.write(", ");
                                self.write(letters[idx]);
                                self.write(": ");
                                self.writeType(pt[a..b]);
                                idx += 1;
                                seg_start = i + 1;
                            }
                        }
                        self.write(" }");
                    }
                }
                self.write(",\n");
            }
        } else {
            // Bare-enum emit shape: `enum { V1, V2, ... }`. No
            // variants carry payloads or fields.
            self.write("enum {\n");
            for (ed.variants) |v| {
                self.write("    ");
                self.write(v.name);
                self.write(",\n");
            }
        }
        // Nest matching impl methods inside the BARE-ENUM body only.
        // zig 0.16 rejects methods nested inside `union(enum) { ... }`
        // (gap #3 fix) AND inside `enum(T) { ... }` containers; only
        // the bare `enum { V1, V2, ... }` form accepts nested pub fns.
        // Payload-bearing enums + backed enums route their impl methods
        // through `generate()`'s orphan-impl loop (via
        // `genFreeMethod` at module scope) — see the matched_targets_buf
        // gate update in src/codegen/core.zig that excludes non-bare
        // enum names so the orphan path picks them up. The bare-enum
        // path retains the legacy nested-method emit (existing tests
        // for `impl Direction { ... }` etc. pin this surface).
        // TRAIT-method methods are SKIPPED here (same reason as
        // genStructDecl): they emit as renamed free fns (Target_Trait_
        // method) + vtable registration during the trait-handling
        // pass, NEVER nested inside the enum body.
        if (ed_is_bare) {
            for (all_impls) |impl| {
                if (!std.mem.eql(u8, impl.target_type, ed.name)) continue;
                for (impl.methods) |m| {
                    // Canonical `with Trait (m)` dispatch (docs/17
                    // §"Diamond Disambiguation") — same logic as
                    // genStructDecl: trait-bound methods skip nested
                    // emit so the trait-handling pass in `generate`
                    // emits the renamed free fn + vtable registration.
                    if (self.resolveTraitBinding(&impl, m) != null) continue;
                    // v1.6 byte-slice widening: set receiver-struct
                    // before emitting the nested method body so
                    // `print(self.byte_slice_field)` widens correctly.
                    // Mirror of genStructDecl's setting.
                    self.current_receiver_struct_name = impl.target_type;
                    // Phase 2 tail: thread impl-level type_params so
                    // the nested-on-enum method emits `comptime X:
                    // type` BEFORE its own params. Same path as
                    // genStructDecl.
                    self.genMethod(m, impl.type_params);
                    self.current_receiver_struct_name = null;
                }
            }
        }
        self.write("};\n\n");
    }

    pub     fn genFun(self: *Codegen, fun: ast.FunDecl) void {
        if (fun.is_test) {
            self.genTestFun(fun);
            return;
        }
        // Reset destructuring counter at the top of each function so the
        // temp bindings inside this body stay local (avoiding clashes
        // across sibling `pub fn` declarations) and count from `_0`.
        self.destructure_counter = 0;
        // Reset type-info map at the top of each function so sibling
        // `pub fn` declarations don't bleed entries across functions.
        // Walk the body once to populate the map before any emission
        // happens — the predicates need to see this map when each
        // binary/literal expression hits the `.binary` arm.
        self.type_info_count = 0;
        // v1.6 byte-slice widening: top-level `pub fun` declarations
        // have no method receiver. Reset to null so any stale value
        // from a previous impl-block method body doesn't carry over
        // into a regular fn body (which would over-widen to `{s}` on
        // first print, e.g. a `print(self.foo)` written inside `fun
        // main` would resolve against the most-recent impl's
        // receiver even though there's no `self` in main).
        self.current_receiver_struct_name = null;
        // Reset the `new`-temp counter at the top of each function so
        // sibling `pub fn` declarations don't reuse the same `__p_<N>`
        // names (zig's redeclaration-error would reject a collision).
        self.alloc_counter = 0;
        // Per-function match scrutinee counter for the laddered match
        // codegen path (see `genMatchExpr`). Two match expressions in
        // the same body produce distinct `__m_<N>` names so zig's
        // no-redeclaration rule is satisfied; sibling `pub fn`s reset
        // their own counters to start fresh at `_0`.
        self.match_counter = 0;
        // Phase 1 codegen-router: env_counter reset (mirrors the
        // match_counter reset above) so sibling getEnv calls within
        // the same
        // body produce distinct `__env_<N>` names. Sibling pub fns
        // start fresh at `_0` thanks to this reset.
        // Phase 2 codegen-router: fs_counter reset (mirrors env_counter
        // immediately above) so sibling read_file calls within the
        // same body produce distinct `__fs_<N>` names. Sibling pub
        // fns start fresh at `_0` thanks to this reset.
        self.fs_counter = 0;
        // Phase 3 (CLI migration) codegen-router: write_file / mkdir /
        // exec counters reset mirrors the fs_counter (Phase 2) pattern
        // above so each fn body has its own scoped counter slot
        // starting at `_0`. `process_exit` doesn't need a counter —
        // its emit is a single inline statement with no temp names.
        // Top-level `fun` is parsed for return_type in Phase 2, but
        // `fn_returns_value` is only relevant for impl-block methods
        // where the typed-return drives tail-position match emission.
        // Top-level funs conservatively keep the legacy
        // value-discarding match emission — the body can still use
        // explicit `return expr;` to yield a value, which zig's type
        // checker validates against the emitted `RET_TYPE` signature.
        self.fn_returns_value = false;
        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry. The
        // fresh local `<name>` is mutable (allowing body mutations like
        // `x += 1`), and the parameter carrying the caller's value
        // passes through zig's pass-by-value default — caller isolation
        // is preserved. The body still references `<name>` verbatim; the
        // local shadows nothing because the parameter has a different
        for (fun.body) |stmt| {
            self.collectTypedBindings(stmt);
        }
        if (fun.doc) |d| self.genDocComment(d);
        // Phase 2 (docs/15 §"Declaration"): emit the FULL signature
        // from `fun.params`. Pre-Phase-2 the body unconditionally
        // emitted `pub fn NAME() !void {` regardless of source-side
        // params or return type; that's why the docs example
        // `fun add(a, b) -> i32 { return a + b; }` previously didn't
        // compile-able (zig rejected the call sites that omitted the
        // two args). Now args and return type both round-trip
        // verbatim. Default `ret = "void"` when `fun.return_type` is
        // null so the legacy form (`fun NAME() {}`) keeps emitting
        // the no-return surface.
        self.write("pub fn ");
        self.write(fun.name);
        // zig 0.16 main-signature migration: when the source-side
        // function is named `main`, the generated zig must use the
        // new `pub fn main(init: std.process.Init) !void` signature
        // (the old `pub fn main() void` form is no longer accepted
        // as an OS entry point in zig 0.16). The `init` parameter
        // is the ONLY way to access argv at runtime via
        // `init.minimal.args.toSlice(allocator)`; we capture it
        // into the module-level `__zag_argv` global at the start
        // of main's body so the `.argv_get` dispatch can return
        // it without threading `init` through every function that
        // calls `get()`. The `!void` return type is forced (rather
        // than inferred from the body) because the `try` on the
        // `toSlice` call needs a fallible signature.
        const is_main = std.mem.eql(u8, fun.name, "main");
        self.write("(");
        if (is_main) self.write("init: std.process.Init");
        // Generics (docs/16 §1, §4): emit `comptime X: type` or
        // `comptime X: TYPE` for each TypeParam BEFORE the regular
        // params. Zig's comptime-arg convention places compile-time
        // values at the start of the signature, so the preprint goes
        // here rather than at the end. Returns true if any
        // preamble was emitted so the regex check below inserts a
        // `, ` separator between the last type-param and the first
        // regular param.
        const generics_preamble = self.genTypeParamsPreamble(fun.type_params);
        for (fun.params, 0..) |p, i| {
            if (i > 0 or generics_preamble or is_main) self.write(", ");
            // Phase 2 var-p name-isolation (zig 0.16 fix): when
            // `is_var` is set, rename the parameter to
            // `__zag_local_<name>` so the body's
            // `var <name> = __zag_local_<name>;` introduces a fresh
            // local rather than shadowing the parameter. zig 0.16
            // rejects any local variable that shares a name with a
            // function parameter.
            if (p.is_var) self.write("__zag_local_");
            self.write(p.name);
            self.write(": ");
            self.writeType(p.type_text);
        }
        self.write(") ");
        // zig 0.16 main-signature migration: wrap the return
        // type in `!` (error union) so the `try` on
        // `init.minimal.args.toSlice(...)` can propagate
        // `OutOfMemory`. Preserves the user's annotated return
        // type (e.g., `fun main() -> i32` → `!i32`) rather than
        // hardcoding `!void`, so a user who writes a fallible
        // main with a non-void return type doesn't lose the
        // return-value contract. The `if (fun.return_type) |rt|
        // ... else "void"` pattern matches the legacy
        // non-main branch below; we just prefix `!` to the
        // resolved type.
        // zig 0.16 main-signature migration: wrap the return
        // type in `!` (error union) so the `try` on
        // `init.minimal.args.toSlice(...)` can propagate
        // `OutOfMemory`. Preserves the user's annotated return
        // type (e.g., `fun main() -> i32` → `!i32`) rather than
        // hardcoding `!void`, so a user who writes a fallible
        // main with a non-void return type doesn't lose the
        // return-value contract. The double-wrap guard checks
        // whether the user's return type already starts with `!`
        // (i.e., is already an error union) and skips the prefix
        // in that case — otherwise we'd emit `!!i32` which zig
        // rejects. The `if (fun.return_type) |rt| ... else "void"`
        // pattern matches the legacy non-main branch below; we
        // just prefix `!` to the resolved type when not already
        // error-union.
        if (is_main) {
            const already_err_union = if (fun.return_type) |rt| rt.len > 0 and rt[0] == '!' else false;
            if (!already_err_union) self.write("!");
            if (fun.return_type) |rt| self.writeType(rt) else self.write("void");
        } else if (fun.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(" {\n");
        // Trait-bounds guards (docs/16 §3): emit
        // `if (!@hasDecl(T, "method")) @compileError(...)` BEFORE
        // the var-params injection so unresolved bounds surface as a
        // zag compile-error at the user's source-line rather than a
        // sig validation panic downstream.
        self.genBoundsGuards(fun.type_params);
        // Phase 2 (docs/15 §"Parameters"): inject `var p = p;` at body
        // entry for each `is_var = true` param so mutations to `p`
        // don't reach the caller's binding (zag's "mutable local copy"
        // semantic). zig 0.16 makes parameters `const` so the body
        // can't rebind a param directly through `p = ...`; this
        // shadow-rebind is the simplest path that honors the
        // "var copies the value to a stack-local mutable" contract.
        // The Phase 2 `var p = p;` shadow-rebind was a workaround
        // for mutable-param emulation that zig 0.16 rejects as
        // `local variable 'p' shadows function parameter`. zig's
        // own pass-by-value defaults satisfy zag's caller-isolated-
        // mutation semantic. The `is_var` slot on `ast.MethodParam`
        // is no longer consulted here at codegen time but remains
        // on the AST for documentation / future-tooling use.
        // (No-op loop: removed to avoid zig 0.16's
        // `pointless discard of capture` warning on a
        // `if (p.is_var) { _ = p; }` marker.)
        // zig 0.16 main-signature migration: capture argv at main
        // entry into the module-level `__zag_argv` global. The
        // `init.minimal.args.toSlice(allocator)` call is the ONLY
        // way to get argv in zig 0.16 (the old `std.os.argv` /
        // `std.posix.argv` slices were removed). The
        // `init.arena.allocator()` returns an arena-backed allocator
        // that lives for the process lifetime, so the returned
        // slice needs no manual cleanup. The `try` propagates
        // `OutOfMemory` through the main signature (forced `!void`
        // above). Emitted ONLY for the main function; other functions
        // don't have `init` in scope.
        if (is_main) {
            self.write("    __zag_argv = try init.minimal.args.toSlice(init.arena.allocator());\n");
                // zig 0.16: also capture the Io event-loop handle from init
                // so the .fs_write_file / .fs_mkdir / .process_exec dispatches
                // can pass it to std.Io.Dir.cwd().createFile(io, ...) etc.
                self.write("    __zag_io = init.io;\n");
        }

        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry.
        // The fresh local `<name>` is mutable (allowing body mutations
        // like `x += 1`), and the parameter carrying the caller's
        // value passes through zig's pass-by-value default — caller
        // isolation is preserved.
        for (fun.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = __zag_local_");
                self.write(p.name);
                self.write(";\n");
            }
        }
        for (fun.body) |stmt| {
            self.genStmt(stmt, false);
        }

        self.write("}\n\n");
    }

    /// Emit a zig `extern fn` declaration for a zag `extern fun`
    /// (docs/24 §"extern fun"). The function is declared with C
    /// calling convention (default for `extern` in zig).
    pub     fn genExternDecl(self: *Codegen, ext: ast.ExternDecl) void {
        self.write("pub extern fn ");
        self.write(ext.name);
        self.write("(");
        for (ext.params, 0..) |p, i| {
            if (i > 0) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.writeType(p.type_text);
        }
        if (ext.is_variadic) {
            if (ext.params.len > 0) self.write(", ");
            self.write("...");
        }
        self.write(") ");
        if (ext.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(";\n\n");
    }

    /// Emit a zig `test "name" { ... }` block for an `@[test]` function.
    /// Test functions have no parameters — the body runs directly.
    pub     fn genTestFun(self: *Codegen, fun: ast.FunDecl) void {
        self.destructure_counter = 0;
        self.type_info_count = 0;
        self.alloc_counter = 0;
        self.match_counter = 0;
        self.fs_counter = 0;

        // Doc comment on the test block
        if (fun.doc) |d| self.genDocComment(d);

        self.write("test \"");
        self.write(fun.name);
        self.write("\" {\n");

        // Trait-bounds guards (if generics present)
        self.genBoundsGuards(fun.type_params);

        for (fun.body) |s| self.genStmt(s, false);

        self.write("}\n\n");
    }

    /// Emit a zig `const` declaration for a top-level `const` binding.
    pub     fn genConstDecl(self: *Codegen, cd: ast.ConstDecl) void {
        self.write("const ");
        self.write(cd.name);
        if (cd.type_text) |tt| {
            self.write(": ");
            self.writeType(tt);
        }
        self.write(" = ");
        self.genExpr(cd.init.*);
        self.write(";\n\n");
    }
