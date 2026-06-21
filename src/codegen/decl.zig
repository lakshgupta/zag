const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;

// ============================================================
// FILE-SCOPE methods (DECL bucket)
// ============================================================

    pub     fn genFreeMethod(self: *Codegen, target_type: []const u8, m: ast.MethodDecl, impl_type_params: []const ast.TypeParam) void {
        self.write("pub fn ");
        self.write(target_type);
        self.write("_");
        self.write(m.name);
        self.write("(");
        // Generics impl-level type_params preamble. Mirrors genMethod
        // and genFun so generic impl-blocks land as
        // `pub fn List_T_push(comptime T: type, self: *List(T), value: T)`.
        // The `*List(T)` receiver note: Phase 4 wires the codegen
        // type-text rewrite (`*List<T>` → `*List(T)`); for Phase 2 this
        // preamble only — receiver types stay verbatim until then.
        const generics_preamble = self.genTypeParamsPreamble(impl_type_params);
        for (m.params, 0..) |p, i| {
            if (i > 0 or generics_preamble) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.write(p.type_text);
        }
        self.write(") ");
        if (m.return_type) |rt| self.write(rt);
        self.write(" {\n");
        // Reset per-function counters (matching `genMethod`/`genFun`).
        self.destructure_counter = 0;
        self.alloc_counter = 0;
        self.match_counter = 0;
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
        self.write("pub const ");
        self.write(sd.name);
        self.write(" = struct {\n");
        for (sd.fields) |f| {
            switch (f.kind) {
                .named => |nf| {
                    self.write("    ");
                    self.write(nf.name);
                    self.write(": ");
                    self.write(nf.type_text);
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
        // the method don't clash with sibling methods' temps.
        for (all_impls) |impl| {
            if (!std.mem.eql(u8, impl.target_type, sd.name)) continue;
            for (impl.methods) |m| {
                // Phase 2 tail: thread impl-level type_params so the
                // nested method emits `comptime X: type` BEFORE its
                // own params. Mirrors genFreeMethod's call update.
                self.genMethod(m, impl.type_params);
            }
        }
        self.write("};\n\n");
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
        // in. Phase 2 commit-scope.
        const generics_preamble = self.genTypeParamsPreamble(impl_type_params);
        for (m.params, 0..) |p, i| {
            if (i > 0 or generics_preamble) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.write(p.type_text);
        }
        self.write(") ");
        if (m.return_type) |rt| self.write(rt);
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
                // const-param site.
                self.write(tp.type_text.?);
            } else {
                self.write("type");
            }
            emitted = true;
        }
        return emitted;
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
                    self.write(pt);
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
                            self.write(pt[a..b]);
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
        // type-info map reset behaviour is identical.
        for (all_impls) |impl| {
            if (!std.mem.eql(u8, impl.target_type, ed.name)) continue;
            for (impl.methods) |m| {
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
        self.write("(");
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
            if (i > 0 or generics_preamble) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.write(p.type_text);
        }
        self.write(") ");
        if (fun.return_type) |rt| self.write(rt) else self.write("void");
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

        for (fun.body) |stmt| {
            self.genStmt(stmt, false);
        }

        self.write("}\n\n");
    }
