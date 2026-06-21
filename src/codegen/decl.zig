const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;

// ============================================================
// FILE-SCOPE methods (DECL bucket)
// ============================================================

    pub     fn genFreeMethod(self: *Codegen, target_type: []const u8, m: ast.MethodDecl) void {
        self.write("pub fn ");
        self.write(target_type);
        self.write("_");
        self.write(m.name);
        self.write("(");
        for (m.params, 0..) |p, i| {
            if (i > 0) self.write(", ");
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
                self.genMethod(m);
            }
        }
        self.write("};\n\n");
    }

    pub     fn genMethod(self: *Codegen, m: ast.MethodDecl) void {
        self.write("    pub fn ");
        self.write(m.name);
        self.write("(");
        for (m.params, 0..) |p, i| {
            if (i > 0) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.write(p.type_text);
        }
        self.write(") ");
        if (m.return_type) |rt| self.write(rt);
        self.write(" {\n");
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
                self.genMethod(m);
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
        for (fun.params, 0..) |p, i| {
            if (i > 0) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.write(p.type_text);
        }
        self.write(") ");
        if (fun.return_type) |rt| self.write(rt) else self.write("void");
        self.write(" {\n");
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
