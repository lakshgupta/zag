const std = @import("std");
const ast = @import("ast.zig");

/// Lightweight per-function type-info map entry. The Codegen struct
/// holds a fixed-size array of these and walks each function body once
/// at `genFun` entry to populate it from `let`/`var`/`const`
/// declarations that carry an explicit `: T` annotation. The div-shim
/// predicates then look up whether a referenced `.ident` is recorded
/// as float-typed in this map. Deliberately codegen-internal (lives
/// next to `Codegen` rather than in `ast.zig`) because the caller has
/// no use for the map after compilation — only the shim predicates
/// consume its lifetime.
///
/// Phase 2 (docs/15 §"Closures"): add `is_closure` to record
/// bindings whose initializer is `Expr.closure`. The map carries the
/// closure flag even when no `: T` annotation is present because
/// closure expressions are anonymous-struct values (no user-supplied
/// type). `isClosureBound(name)` then powers the `.call` -> `.call
/// (closure)` rewrite at every call site (e.g. `double(5)` becomes
/// `double.call(5)` so zig recognises the closure-bound value as a
/// struct with a `call` method rather than a free fn).
const BindingTypeInfo = struct {
    name: []const u8,
    type_name: []const u8,
    is_closure: bool = false,
};

pub const Codegen = struct {
    out_buf: [65536]u8,
    out_len: usize,
    /// Per-function counter for destructuring temps. Reset to 0 by `genFun`
    /// so each `pub fn` body has its own `__destruct_0`, `__destruct_1`,
    /// ... sequence. Multiple destructurings in the same body produce
    /// distinct names so zig's no-redeclaration rule is satisfied.
    destructure_counter: u32,
    /// Per-function type-info map: walks the body once at `genFun` entry
    /// and records every binding carrying an explicit `: T` annotation.
    /// Used by `needsIntDivShim` to skip the shim wrap when the LHS ident
    /// is float-typed; without this lookup the integer shim fires on
    /// `.ident` LHSes unconditionally and emits `@divTrunc(pi, 2)` for
    /// `let pi: f64 = …; pi / 2` (zig 0.16 rejects because `@divTrunc`
    /// requires integer args — the typed-binding path is the user-asked
    /// fix). Reset to empty at the top of each `genFun` so sibling
    /// `pub fn` declarations don't bleed entries across functions.
    type_info_buf: [256]BindingTypeInfo,
    type_info_count: u32,
    /// Per-function counter for `new`-introduced heap locals. Reset to 0
    /// by `genFun` so each `pub fn` body has its own `__p_0`, `__p_1`, ...
    /// sequence. The counter steps both for the simple `new T(value)` form
    /// and the allocator-sugar form `new(<alloc>, T(value))` so two new
    /// expressions in the same body never collide on the same temporary
    /// name (zig's no-redeclaration rule would reject a clash).
    alloc_counter: u32,
    /// Per-function counter for match scrutinee temps. Reset to 0 by
    /// `genFun` so each `pub fn` body has its own `__m_0`, `__m_1`, ...
    /// sequence. Two match expressions in the same body produce distinct
    /// names so zig's no-redeclaration rule is satisfied. Reusing the
    /// existing counters here would create collisions with destructuring
    /// temps (`__destruct_<N>`) and `new` heap locals (`__p_<N>`).
    match_counter: u32,
    /// Per-function flag: true when the currently-walked function body
    /// has a non-void return type (only relevant for impl-block methods
    /// because top-level `pub fun` declarations ALWAYS emit
    /// `() !void` per the grammar's missing top-level-return-type carve-
    /// out). Read by `genMethod` and `genFreeMethod` body loops and
    /// passed to `genStmt` as the gate that decides whether a tail-
    /// position `match_stmt` should be prefixed with `return` (so the
    /// matched value is returned to the zig call site) vs emitted as a
    /// bare indented `(blk: { ... });` statement (the value-discarding
    /// form zig accepts at any other position).
    fn_returns_value: bool,

    pub fn init() Codegen {
        return .{
            .out_buf = undefined,
            .out_len = 0,
            .destructure_counter = 0,
            .type_info_buf = undefined,
            .type_info_count = 0,
            .alloc_counter = 0,
            .match_counter = 0,
            .fn_returns_value = false,
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

        // Emit struct declarations BEFORE top-level functions so the
        // emitted zig sees types declared before use. Each struct
        // emission includes its matching impl methods NESTED INSIDE the
        // struct body — this is the simplification that makes
        // `v.length()` and `Vec3.new(...)` 1:1 round-trip to zig
        // (no za-side type resolver needed; zig's own type checker
        // handles receiver-vs-type dispatch natively).
        //
        // Same shape for enums: emit `pub const EnumName = enum {..}` (or
        // `union(enum) {..}` when any variant carries payload) with any
        // matching impl-block methods NESTED INSIDE so zig's native
        // pattern matching supports them.
        var matched_targets_buf: [512][]const u8 = undefined;
        var matched_count: u32 = 0;
        for (prog.enums) |ed| {
            if (matched_count < matched_targets_buf.len) {
                matched_targets_buf[matched_count] = ed.name;
                matched_count += 1;
            }
            self.genEnumDecl(ed, prog.impls);
        }
        for (prog.structs) |sd| {
            if (matched_count < matched_targets_buf.len) {
                matched_targets_buf[matched_count] = sd.name;
                matched_count += 1;
            }
            self.genStructDecl(sd, prog.impls);
        }
        // Orphan impls (target_type not declared as a struct) emit as
        // module-level free functions with `_<target_type>_<name>` names
        // so a stray `impl Foo { pub fun bar() -> i32 { ... } }` line
        // without a matching `struct Foo` still produces callable zig
        // instead of silently being dropped. This preserves the
        // user-facing surface in source-level use cases while keeping
        // the canonical struct+impl nesting simple for the common case.
        // Codegen also passes a `&v` (address-of) prefix automatically
        // when a receiver parameter is named `self` and the call site
        // is a bare-method-call expression — see `.method_call` in
        // `genExpr` for the dispatch surface.
        for (prog.impls) |impl| {
            var is_matched = false;
            for (matched_targets_buf[0..matched_count]) |t| {
                if (std.mem.eql(u8, t, impl.target_type)) {
                    is_matched = true;
                    break;
                }
            }
            if (is_matched) continue;
            for (impl.methods) |m| {
                self.genFreeMethod(impl.target_type, m);
            }
        }

        for (prog.functions) |fun| {
            self.genFun(fun);
        }

        return self.out_buf[0..self.out_len];
    }

    /// Emit a single method as a module-level free function with a
    /// `_<target_type>_<name>` qualified identifier. Used by orphan-impl
    /// handling when no matching `struct NAME` decl exists. The fallback
    /// shape preserves the user-facing method-call form
    /// (`Vec3_length(&v)`) when callers explicitly qualify the
    /// type+name pair. The body emission uses the same `genStmt` recursion
    /// as nested-method-body or top-level-fn-body.
    fn genFreeMethod(self: *Codegen, target_type: []const u8, m: ast.MethodDecl) void {
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

    /// Emit `pub const NAME = struct { fields + matching impl methods };`.
    /// Fields are emitted in declaration order so any odo/zig struct
    /// initializer (`Vec3 { .x = 1, … }`) round-trips the field-position
    /// assumption naturally. Impl methods whose `target_type` matches
    /// the struct name are nested inside so zig sees them as real
    /// struct methods — this is what enables both the value-receiver
    /// form `v.length()` and the type-static constructor form
    /// `Vec3.new(...)` to compile against the same zig struct without
    /// zag needing a type-resolver at codegen time.
    fn genStructDecl(self: *Codegen, sd: ast.StructDecl, all_impls: []const ast.ImplBlock) void {
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

    /// Emit a single method as a zig struct-member function. Leading
    /// `pub fn` regardless of the source's `pub` prefix (privacy is
    /// accept-and-ignored per the user-confirmed scope). The body uses
    /// the same `genStmt` recursion as `genFun` so all existing
    /// primitives (let-bindings, if/match, etc.) work in method bodies.
    fn genMethod(self: *Codegen, m: ast.MethodDecl) void {
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

    /// Emit `pub const NAME = enum { V1, V2, ... };` (or
    /// `pub const NAME = union(enum) { V1: T, V2: T, ... };` when any
    /// variant carries a payload type). Reuses `genMethod` to nest
    /// matching impl-block methods inside the enum, mirroring the
    /// struct-decl path. The enum-vs-union(enum) split matches docs/13:
    /// bare tag-only variants map to zig's plain `enum { ... }` form
    /// (1-byte tag-only payload slot), while data-carrying variants
    /// (`Circle(f64)`) map to `union(enum) { ... }` so zig's native
    /// pattern matching with `|payload|` capture can extract the data.
    fn genEnumDecl(self: *Codegen, ed: ast.EnumDecl, all_impls: []const ast.ImplBlock) void {
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

    fn genFun(self: *Codegen, fun: ast.FunDecl) void {
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

    /// Walk a single statement looking for a binding declaration that
    /// carries an explicit `: T` annotation. When found, record the
    /// binding's name and type-name into the per-function type-info map
    /// so the div-shim predicate can later check whether an `.ident`
    /// LHS is float-typed. Skips destructured patterns (the parser
    /// doesn't accept `: T` on them, so they cannot contribute anyway)
    /// and untyped bindings (their inferred type isn't trustworthy for
    /// the shim decision without walking init expressions, which is
    /// explicitly out of scope — see the `needsIntDivShim` caveat for
    /// the residual cases this leaves behind).
    ///
    /// Phase 2 (docs/15 §"Closures"): in addition to typed bindings,
    /// record a binding whose initializer is `Expr.closure` with
    /// `is_closure = true` so the `.call` rewrite at every call site
    /// can route `closure_val(args)` through `closure_val.call(args)`.
    /// Closures do NOT need a `: T` annotation for this lookup because
    /// the closure expression itself is a self-describing anonymous
    /// struct; presence of the closure init is the only signal.
    fn collectTypedBindings(self: *Codegen, stmt: ast.Stmt) void {
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

    /// True if `name` is present in the per-function type-info map AND
    /// its recorded type name is one of the floats zig treats as
    /// non-integer (`f16`, `f32`, `f64`). Powers the div-shim predicate's
    /// "is this ident LHS float-typed?" check; absent ident (e.g. from a
    /// function param, a non-annotated binding, or a destructured leaf)
    /// returns false, leaving the existing predicate decision intact.
    fn isFloatIdentType(self: *Codegen, name: []const u8) bool {
        for (self.type_info_buf[0..self.type_info_count]) |ti| {
            if (std.mem.eql(u8, ti.name, name)) {
                return isFloatTypeName(ti.type_name);
            }
        }
        return false;
    }

    /// Type-name predicate for the float check. Currently catches
    /// `f16`/`f32`/`f64` (the zig primitive float types); user-defined
    /// aliases like `type MyFloat = f64` are out of scope — without a
    /// type resolver we cannot unwrap the alias chain.
    fn isFloatTypeName(type_name: []const u8) bool {
        return std.mem.eql(u8, type_name, "f64") or
            std.mem.eql(u8, type_name, "f32") or
            std.mem.eql(u8, type_name, "f16");
    }

    /// True if `name` is recorded in the per-function type-info map
    /// with `is_closure = true`. Powers the `.call` arm's rewrite of
    /// `closure_val(args)` into `closure_val.call(args)` so zig sees
    /// the closure as a struct-method-call rather than a free fn.
    /// Idents absent from the map (params, top-level fn calls,
    /// non-closure lets) return false and the `.call` arm keeps the
    /// bare `<name>(args)` form so existing call sites compile
    /// unchanged.
    fn isClosureBound(self: *Codegen, name: []const u8) bool {
        for (self.type_info_buf[0..self.type_info_count]) |ti| {
            if (std.mem.eql(u8, ti.name, name)) {
                return ti.is_closure;
            }
        }
        return false;
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

    fn genStmt(self: *Codegen, stmt: ast.Stmt, is_tail_pos: bool) void {
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
            .single_tuple_lit => |el_ptr| @as([*]const ast.Expr, @ptrCast(el_ptr))[0..1],
            .named_tuple_lit => |nt| nt.elements,
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
    /// Caveat (now closed): with the per-function type-info map populated by
    /// `collectTypedBindings` above, we CAN distinguish a `let pi: f64 = …` LHS
    /// from a `let x: i32 = …` LHS. When the user annotates the LHS binding
    /// with a float type (`f16`/`f32`/`f64`), the predicate returns false and
    /// the bare `/` form survives — `let pi: f64 = 3.14; pi / 2` emits
    /// `pi / 2` (zig infers f64), not `@divTrunc(pi, 2)`. Only the unresolved
    /// cases still rely on user discipline:
    ///   - Unannotated bindings (`let x = 10` whose type zig infers as
    ///     comptime_int, or `let x = 1.0` whose type zig infers as
    ///     comptime_float) — the map records neither, so the predicate falls
    ///     back to the conservative wrap / skip rules.
    ///   - References to bindings outside this function's body scope (e.g.
    ///     future module-level globals, future fn-level params). The map
    ///     only covers body-scope bindings visited by `collectTypedBindings`.
    /// User advice for those residual cases: annotate float bindings with
    /// `: f64` to get correct codegen, OR write the RHS as `2.0` to skip the
    /// shim via the `b.rhs.* != .int_lit` short-circuit.
    fn needsIntDivShim(self: *Codegen, b: ast.Expr.BinaryExpr) bool {
        if (b.op != .div and b.op != .mod) return false;
        if (b.rhs.* != .int_lit) return false;
        // Both sides comptime_int → zig folds the bare form at compile time.
        // Skip the shim so the user's source round-trips: `1 / 2 === (1 / 2)`.
        if (b.lhs.* == .int_lit) return false;
        // LHS ident annotated with a float type in the per-function map →
        // `@divTrunc` requires integer args so the shim would miscompile.
        // Skip the wrap and emit the bare form; zig infers the operand
        // types from the binding annotations and accepts `f64 / comptime_int`.
        if (b.lhs.* == .ident and self.isFloatIdentType(b.lhs.*.ident)) return false;
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

    /// Print dispatch — pulled out from the `.call` arm so the
    /// multi-overload dispatch table is preserved when the closure-
    /// rewrite branch was added (docs/15 §"Closures" Phase 2). Same
    /// per-arg-kind behaviour as the prior inline form: literal-string
    /// formats as `.*.{}` (no args), `char_lit` uses `{c}`, arrays /
    /// tuples / generic expressions use `{any}`, and template-literal
    /// expressions route to the debug-print template codegen.
    fn genPrintCall(self: *Codegen, c: ast.Expr.CallExpr) void {
        if (c.args.len != 1) {
            // Multi-arg print: fall back to the generic debug-print
            // form with the args list. Mirrors the codegen already
            // used for templates where the trailing comma is appended
            // unconditionally when args are non-empty.
            self.write("std.debug.print(\"{any}\", .{");
            for (c.args, 0..) |arg, i| {
                if (i > 0) self.write(", ");
                self.genExpr(arg);
            }
            if (c.args.len > 0) self.write(",");
            self.write("})");
            return;
        }
        const arg = c.args[0];
        switch (arg) {
            .string_lit, .byte_string_lit => |str| {
                self.write("std.debug.print(\"");
                self.write(str);
                self.write("\", .{})");
            },
            .char_lit => {
                self.write("std.debug.print(\"{c}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .array_lit => {
                self.write("std.debug.print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .tuple_lit => {
                self.write("std.debug.print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .template_lit => |t| {
                self.genTemplateLit(t, .debug_print);
            },
            else => {
                self.write("std.debug.print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
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

    /// Recursive walker for `Stmt.IfStmt.else_kind`. The caller's
    /// `genStmt` does the leading `if (cond) { … }` and we emit the suffix
    /// — `.none` ends the chain, `.block` emits a terminal `else { … }`,
    /// `.if_chain` recurses into a boxed `else if` (boxed `*IfStmt`
    /// pointer enables arbitrarily deep chains without the struct being
    /// self-referential in the tagged-union type system).
    fn genElseBranch(self: *Codegen, else_kind: ast.Stmt.IfStmt.IfElseKind) void {
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

    /// Emit a `match scrutinee { arms... }` as a labeled-block if-else
    /// ladder. The block binds the scrutinee ONCE to a unique `__m_<N>`
    /// (per-function counter), so arm conditions and bodies can refer to
    /// the same value without re-evaluating the scrutinee each time.
    ///
    /// Trailing fallback: when the last arm is NOT a wildcard, codegen
    /// appends `else unreachable;` so zig's exhaustive-match check is
    /// satisfied (zig would otherwise flag the ladder as
    /// not-covering-all-paths). When the last arm IS a wildcard, the
    /// wildcard arm's body is the natural fallback — no extra emission.
    ///
    /// Ident-pattern arm body emission prepends `const <name> = __m_<N>;`
    /// before `break :blk body` so the body's expression can reference
    /// the binding name. Codegen's `exhaustiveness` intent — without
    /// this prepend, `match e { x => x + 1, _ => 0 }` would emit
    /// `break :blk (x + 1);` with no `x` definition and zig would reject.
    ///
    /// Caller of `.match_stmt` (statement-position use) appends `;\n`
    /// after this emission; caller of `.match_expr` (expression-position
    /// use) does NOT — the result is already inside parens so it fits
    /// as RHS of `let` or operand of binary op.
    fn genMatchExpr(self: *Codegen, m: ast.Expr.MatchExpr) void {
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

    /// Emit the boolean condition that gates one match-arm. Pulled out
    /// from `genMatchExpr` because each pattern kind has a distinct
    /// emission shape (literal comparison, range bound check, ident/
    /// discard constant `true`).
    ///
    /// The scrutinee name is passed in so the caller picks a fresh
    /// `__m_<N>` per match expression (without parameterising, two
    /// matches in the same body would clash on `__m`).
    fn emitPatternCond(self: *Codegen, scrut_name: []const u8, p: ast.Pattern) void {
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
