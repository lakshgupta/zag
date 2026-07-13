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
            self.write(p.name);
            self.write(": ");
            self.rewriteReceiverType(zagTypeToZig(p.type_text), impl_type_params);
        }
        self.write(") ");
        if (m.return_type) |rt| self.write(zagTypeToZig(rt)) else self.write("void");
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
        // Trait-bounds guards (docs/16 §3) — mirrors genFun's body
        // entry so unresolved impl-block generic bounds surface
        // as a zag compile-error at the user's source-line.
        self.genBoundsGuards(impl_type_params);
        // Phase 2 var-params injection — mirrors genMethod/genFun.
        for (m.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = ");
                self.write(p.name);
                self.write(";\n");
            }
        }
        for (m.body) |s| self.collectTypedBindings(s);
        for (m.body, 0..) |s, i| self.genStmt(s, self.fn_returns_value and i == m.body.len - 1);
        self.write("}\n");
    }

    pub     fn genStructDecl(self: *Codegen, sd: ast.StructDecl, all_impls: []const ast.ImplBlock) void {
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
                    self.write(zagTypeToZig(nf.type_text));
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
                    if (m.trait_name != null) continue;
                    // Phase 2 tail: thread impl-level type_params so the
                    // nested method emits `comptime X: type` BEFORE its
                    // own params. Mirrors genFreeMethod's call update.
                    self.genMethod(m, impl.type_params);
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
            self.write(p.name);
            self.write(": ");
            self.rewriteReceiverType(zagTypeToZig(p.type_text), impl_type_params);
        }
        self.write(") ");
        if (m.return_type) |rt| self.write(zagTypeToZig(rt)) else self.write("void");
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
        // Phase 2 (docs/15 §"Parameters"): inject `var p = p;` for each
        // `is_var = true` param so mutations stay local. Mirrors the
        // genFun patch so `pub fun bump(var x: i32) { x += 1; }` round-
        // trips to a `bump` method that mutates a stack-local copy.
        for (m.params) |p| {
            if (p.is_var) {
                self.write("        var ");
                self.write(p.name);
                self.write(" = ");
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
                self.write(zagTypeToZig(tp.type_text.?));
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
        // Docs/17 §"Self": `Self` refers to the implementing type. In
        // trait method param + return types, `Self` is rewritten to the
        // dispatch shim's generic `T` so a trait declared on multiple
        // types shares one shim signature. Substring scan-and-replace
        // is sufficient because `Self` always sits at the END of a
        // type expression (it IS the type name, never a prefix) — the
        // alternatives (`*Self`, `*const Self`, `[]Self`, `?Self`)
        // are captured verbatim by `collectCastType` so the slice
        // contains `Self` as a sub-token right before any trim point.
        // Edge: `SelfIsLol` would collide, but no such identifier
        // exists in zag's v1 surface and would conflict with type-name
        // resolution if it did.
        //
        // After the Self→T substitution, the rewritten slice is fed
        // through `zagTypeToZig` so trait-side type emits also honour
        // the docs/07 transparent-alias contract (`str` becomes
        // `[]const u8`). Chaining `.Self→T` THEN `.alias` works for
        // all realistic shapes because no zag alias name contains
        // `Self` AND no `Self` keyword passes through the alias
        // table (which only matches the WHOLE text, not substrings).
        // A local scratch buffer holds the intermediate result so
        // `zagTypeToZig`'s value-return form can be composed with the
        // stream-style Self→T scan-and-replace.
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
            if (scratch_len + 1 <= scratch_buf.len) {
                scratch_buf[scratch_len] = 'T';
                scratch_len += 1;
            }
            i = abs + "Self".len;
        }
        self.write(zagTypeToZig(scratch_buf[0..scratch_len]));
    }

    pub     fn genTraitDecl(self: *Codegen, td: ast.TraitDecl) void {
        // Docs/17 §"Definition": `trait NAME { fun draw(self: *Self); ... }`
        // compiles to a zig fat-pointer container holding (data ptr,
        // vtable ptr), an inner VTable struct of function pointers keyed
        // by method name, and a per-method dispatch shim that re-enters
        // via T. The shape follows the user-confirmed ABI:
        //
        //   pub const NAME = struct {
        //       pub const VTable = struct {
        //           m1: *const fn (ptr: *anyopaque, ...) RET1,
        //           m2: *const fn (ptr: *anyopaque, ...) RET2,
        //       };
        //       ptr: *anyopaque,
        //       vtable: *const VTable,
        //       pub fn m1(self: NAME, comptime T: type, ...) RET1 {
        //           _ = T;
        //           return self.vtable.m1(self.ptr, ...);
        //       }
        //       ...
        //   };
        //
        // The `_ = T;` line is REQUIRED because zig 0.16 rejects unused
        // comptime parameters as a compile error. The shim's body never
        // touches T (the dispatch is purely runtime through the vtable),
        // but the user-facing ABI carries it as a placeholder for the
        // Phase 3 trait-bounds wiring (`where T: SomeBound`). Without
        // `_ = T;` every trait dispatch shim errors out as
        // `unused parameter: comptime T`.
        //
        // The receiver parameter (`self: *Self`) is always the FIRST
        // param in a trait method signature per the docs/17 §"Definition"
        // grammar. The dispatch path omits this slot because the receiver
        // collapses to `self.ptr` (an `*anyopaque`) at the vtable signature
        // and to `self: NAME` (the trait container type) at the dispatch
        // shim signature. Subsequent params (additional user-declared args)
        // round-trip through `rewriteSelfToT` so any `*Self`-typed arg
        // within them converts to `*T` for the shim's per-call monomorph.
        self.write("pub const ");
        self.write(td.name);
        self.write(" = struct {\n");
        self.write("    pub const VTable = struct {\n");
        for (td.methods) |m| {
            self.write("        ");
            self.write(m.name);
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
        // T arg keeps the user-facing ABI claims of Phase 1 intact even
        // though zig's strict unused-parameter rule forces the `_ = T;`
        // discard inside the shim body.
        for (td.methods) |m| {
            self.write("    pub fn ");
            self.write(m.name);
            self.write("(self: ");
            self.write(td.name);
            self.write(", comptime T: type");
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
                self.write(": ");
                self.rewriteSelfToT(p.type_text);
            }
            self.write(") ");
            if (m.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
            self.write(" {\n");
            self.write("        _ = T;\n");
            self.write("        return self.vtable.");
            self.write(m.name);
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

    pub     fn genTraitRegistration(self: *Codegen, trait_name: []const u8, target_type: []const u8, methods: []const ast.MethodDecl) void {
        // Docs/17 §"Implementing" — emit a per-(trait, target_type)
        // vtable instantiation so a future `x.draw()` call site (Phase 3
        // — fat-pointer cast encoding) dispatches through THIS
        // registration. The shape:
        //
        //   pub const Trait_VTable_for_Type: Trait.VTable = .{
        //       .method = @ptrCast(
        //           *const fn (ptr: *anyopaque, ...) RET,
        //           &Type_Trait_method,
        //       ),
        //       ...
        //   };
        //
        // The `@ptrCast` with explicit destination fn-pointer type
        // bridges the receiver-type difference: the implementation
        // free-fn's signature is `*const fn (self: *Type) RET`
        // (concrete-receiver) while the vtable slot expects
        // `*const fn (ptr: *anyopaque) RET`. zig 0.16 requires the
        // destination type arg explicitly (no context-inference), so
        // both the type and the source pointer appear in the call.
        self.write("pub const ");
        self.write(trait_name);
        self.write("_VTable_for_");
        self.write(target_type);
        self.write(": ");
        self.write(trait_name);
        self.write(".VTable = .{\n");
        for (methods) |m| {
            self.write("    .");
            self.write(m.name);
            self.write(" = @ptrCast(*const fn (ptr: *anyopaque");
            // The destination fn-pointer type MUST be explicit - zig
            // 0.16's `@ptrCast(T: type, ptr: anytype)` requires both
            // args (no context-inference from struct-literal field
            // assignment). The destination shape mirrors the VTable
            // entry's exact declared type so the cast resolves:
            // skip the receiver slot (the VTable repackages it as
            // `ptr`), flip `Self` -> `T` on additional params via
            // `rewriteSelfToT`, and apply the same rewrite to the
            // return type. Tests passed on substring-presence
            // assertions while the prior `(@ptrCast(&...)` emit was
            // broken at zig 0.16's strict type-check phase.
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
                self.write(": ");
                self.rewriteSelfToT(p.type_text);
            }
            self.write(") ");
            if (m.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
            self.write(", &");
            self.write(target_type);
            self.write("_");
            self.write(trait_name);
            self.write("_");
            self.write(m.name);
            self.write("),\n");
        }
        self.write("};\n\n");
    }

    pub     fn genEnumDecl(self: *Codegen, ed: ast.EnumDecl, all_impls: []const ast.ImplBlock) void {
        self.write("pub const ");
        self.write(ed.name);
        self.write(" = ");
        // Auto-detect payload form: any variant with non-null
        // payload_type triggers the `union(enum)` form. All variants in
        // a single enum share the same emission shape — mixing plain
        // enum with union(enum) is not allowed in zig.
        var any_payload = false;
        for (ed.variants) |v| {
            if (v.payload_type != null) {
                any_payload = true;
                break;
            }
        }
        if (any_payload) {
            self.write("union(enum) {\n");
        } else {
            self.write("enum {\n");
        }
        for (ed.variants) |v| {
            self.write("    ");
            self.write(v.name);
            if (v.payload_type) |pt| {
                // zig 0.16 rejects bare `Rect: f64, f64` (parsed as TWO
                // variants, not one with a tuple type). Multi-arg
                // payloads MUST be wrapped in an anonymous struct so
                // zig's tagged-union parser sees one variant with a
                // struct-typed payload. Single-arg payloads stay bare
                // (`Circle: f64` is a valid union(enum) variant type).
                //
                // Detection: count commas in `pt`. Zero commas → single
                // arg, emit verbatim. ≥1 comma → multi-arg, emit
                // `struct { a: T0, b: T1, ... }` with sequential
                // single-letter field names (a, b, c, …). The matching
                // constructor emit (`.enum_variant_ctor` arm) uses
                // positional init `.{ x, y }` which zig forwards to the
                // struct's named fields in declaration order, so the
                // emit-side letter sequence must align with the parse
                // order of the source's comma-list.
                var comma_count: usize = 0;
                for (pt) |c| if (c == ',') {
                    comma_count += 1;
                };
                if (comma_count == 0) {
                    self.write(": ");
                    self.write(zagTypeToZig(pt));
                } else {
                    self.write(": struct { ");
                    const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
                    var seg_start: usize = 0;
                    var idx: usize = 0;
                    var i: usize = 0;
                    while (i <= pt.len) : (i += 1) {
                        if (i == pt.len or pt[i] == ',') {
                            // Trim leading/trailing whitespace from the
                            // captured type-text segment so
                            // `f64, f64` doesn't emit `: a: f64, b:  f64`.
                            var a: usize = seg_start;
                            var b: usize = i;
                            while (a < b and (pt[a] == ' ' or pt[a] == '\t')) a += 1;
                            while (b > a and (pt[b - 1] == ' ' or pt[b - 1] == '\t')) b -= 1;
                            if (idx > 0) self.write(", ");
                            self.write(letters[idx]);
                            self.write(": ");
                            self.write(zagTypeToZig(pt[a..b]));
                            idx += 1;
                            seg_start = i + 1;
                        }
                    }
                    self.write(" }");
                }
            }
            self.write(",\n");
        }
        // Nest matching impl methods inside the enum so zig's native
        // pattern matching supports them. Same `genMethod` reuse as the
        // struct decl's nested-impl path — the per-method counters and
        // type-info map reset behaviour is identical. TRAIT-method
        // methods are SKIPPED here too (same reason as
        // genStructDecl): they emit as renamed free fns (Target_Trait_
        // method) + vtable registration during the trait-handling
        // pass, NEVER nested inside the enum body.
        for (all_impls) |impl| {
            if (!std.mem.eql(u8, impl.target_type, ed.name)) continue;
            for (impl.methods) |m| {
                if (m.trait_name != null) continue;
                // Phase 2 tail: thread impl-level type_params so the
                // nested-on-enum method emits `comptime X: type`
                // BEFORE its own params. Same path as genStructDecl.
                self.genMethod(m, impl.type_params);
            }
        }
        self.write("};\n\n");
    }

    pub     fn genFun(self: *Codegen, fun: ast.FunDecl) void {
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
            self.write(p.name);
            self.write(": ");
            self.write(zagTypeToZig(p.type_text));
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
            if (fun.return_type) |rt| self.write(zagTypeToZig(rt)) else self.write("void");
        } else if (fun.return_type) |rt| self.write(zagTypeToZig(rt)) else self.write("void");
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
        for (fun.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = ");
                self.write(p.name);
                self.write(";\n");
            }
        }
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

        for (fun.body) |stmt| {
            self.genStmt(stmt, false);
        }

        self.write("}\n\n");
    }
