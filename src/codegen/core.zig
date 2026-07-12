const std = @import("std");
const ast = @import("../ast.zig");
// CYCLE ANCHOR: parser → codegen → parser. Codegen uses
// `Parser.resolveStdImport` and `Parser.joinDottedPath` for the
// import-preamble emit at `generate()` entry. The mirror
// re-export lives at src/parser.zig (`pub const Codegen =
// @import("codegen.zig").Codegen;`) so the e2e test module
// (tests/e2e.zig) can share the scaffold_parser_helper_mod
// rooted there without creating a file-membership collision on
// `src/lexer/token.zig` (which a separate codegen module root
// would introduce). zig 0.16's module DAG accepts the cycle.
//
// IMPORTANT: do NOT remove either end of the cycle in isolation.
// If you remove the codegen side here, the e2e breaks silently
// (its `parser_mod.Codegen.init()` lookup now dangles). If you
// remove the parser side, the e2e breaks with a file-membership
// collision on `src/lexer/token.zig`. Both ends must stay in
// lockstep; either remove BOTH (and refactor the e2e to use a
// separate module) or keep BOTH. The cycle is anchored here AND
// at src/parser.zig's re-export; cross-reference the parser-side
// docblock before any edit.
const parser = @import("../parser.zig");

/// Lightweight per-function type-info map entry. Lives next to
/// `Codegen` rather than in `ast.zig` because the caller has no
/// use for the map after compilation — only the shim predicates
/// consume its lifetime.
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
    /// Tracked trait-decl names (Phase 3 trait-cast, docs/17 §"Using
    /// Traits"): populated at `generate()` entry from `prog.traits`
    /// so the `.cast` arm in `genExpr` can detect `x as Trait` forms
    /// by string-equality against the SET of declared trait names.
    /// Each slot is parsed-verbatim (e.g. `"Drawable"` from the
    /// source). The buffer reset lives in `init()`. The cast arm
    /// consults this set FIRST — if the cast's `type_text` matches a
    /// tracked name AND the source operand is an `.ident` whose
    /// `type_info_buf` entry exists, the trait-cast branch fires
    /// (emit fat-pointer container + vtable registration lookup);
    /// otherwise the legacy `@as(T, expr)` emit runs unchanged so
    /// non-trait cast surface is preserved byte-identical.
    tracked_trait_names: [256][]const u8,
    /// Count of valid entries in `tracked_trait_names` (Phase 3).
    /// Reset to 0 in `init()`; populated as `prog.traits` is walked
    /// at `generate()` entry, BEFORE any function body emits its
    /// first stmt (so the cast arm in `genExpr` sees the populated
    /// set when traversing function-local casts).
    tracked_trait_count: u32,


    pub const collectTypedBindings = @import("stmt.zig").collectTypedBindings;
    pub const emitPatternCond = @import("stmt.zig").emitPatternCond;
    pub const genArrayLit = @import("primary.zig").genArrayLit;
    pub const genBinding = @import("stmt.zig").genBinding;
    pub const genBindingLeaves = @import("stmt.zig").genBindingLeaves;
    pub const genDocComment = @import("stmt.zig").genDocComment;
    pub const genElseBranch = @import("stmt.zig").genElseBranch;
    pub const genEnumDecl = @import("decl.zig").genEnumDecl;
    pub const genExpr = @import("expr.zig").genExpr;
    pub const genFreeMethod = @import("decl.zig").genFreeMethod;
    pub const genFun = @import("decl.zig").genFun;
    pub const genMatchExpr = @import("stmt.zig").genMatchExpr;
    pub const genMethod = @import("decl.zig").genMethod;
    pub const genPrintCall = @import("primary.zig").genPrintCall;
    pub const genStmt = @import("stmt.zig").genStmt;
    pub const genStructDecl = @import("decl.zig").genStructDecl;
    pub const genTemplateLit = @import("primary.zig").genTemplateLit;
    pub const genTraitDecl = @import("decl.zig").genTraitDecl;
    pub const genTraitRegistration = @import("decl.zig").genTraitRegistration;
    pub const genTypeParamsPreamble = @import("decl.zig").genTypeParamsPreamble;
    pub const genBoundsGuards = @import("decl.zig").genBoundsGuards;
    pub const rewriteReceiverType = @import("decl.zig").rewriteReceiverType;
    pub const rewriteSelfToT = @import("decl.zig").rewriteSelfToT;
    pub const generate = @import("core.zig").generate;
    pub const init = @import("core.zig").init;
    pub const isClosureBound = @import("core.zig").isClosureBound;
    pub const isFloatIdentType = @import("core.zig").isFloatIdentType;
    pub const isTrackedTrait = @import("core.zig").isTrackedTrait;
    pub const getSourceTypeName = @import("core.zig").getSourceTypeName;
    pub const needsIntDivShim = @import("primary.zig").needsIntDivShim;
    pub const write = @import("core.zig").write;
};

// ============================================================
// FILE-SCOPE methods (CORE_INLINE bucket)
// ============================================================

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
            // Phase 3 trait-cast: the tracked trait-name set starts
            // empty; generate() populates from prog.traits before any
            // function body emits its first stmt. The array content
            // is `undefined` until the population pass writes into
            // indices 0..tracked_trait_count; readers (isTrackedTrait)
            // only consult indices 0..count so the undefined bytes are
            // never observed.
            .tracked_trait_names = undefined,
            .tracked_trait_count = 0,
        };
    }

    pub     fn write(self: *Codegen, s: []const u8) void {
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

        // Module imports (docs/manual/22-modules.md §Imports): walk
        // `prog.imports` at generate() entry and emit one preamble
        // line per resolved entry:
        //   const __zag_imported_<i> = @import("<resolved_path>");
        // The line lands AFTER `const std = @import("std");` and
        // BEFORE `pub fn print_fn` so the produced zig module's
        // stdlib imports are top-of-module (the codegen-emit
        // preamble). Index-based names (always-bumped) guarantee
        // uniqueness across duplicate `import std.X` lines in user
        // source — zig rejects `const` redeclarations with a
        // hard-error at the use site. Misses against
        // KNOWN_STD_MODULES are skipped silently (same
        // null-on-miss contract that `resolveStdImport` already
        // exposes); v1 use-site wiring (Phase 2+) is the place
        // where unresolved paths become a user-facing diagnostic.
        //
        // Scratch buffer (256 bytes) is sized for the longest v1
        // entry (`std.arch.x86.avx2` = 18 bytes including
        // separators) — see `joinDottedPath`'s doc for the
        // truncation-tolerant fallback contract.
        //
        // Order: AFTER the existing `const std = @import("std")`
        // preamble write but BEFORE the struct/enum/impl/fun
        // walks below. The loop's full scope wraps in a labeled
        // block to bound `import_scratch` + `idx_buf` stack
        // lifetimes — neither leak past the loop; both are
        // consumed during the iteration that produced them.
        // (`resolveStdImport` returns a slice into a comptime-static
        // table so the resolved_path is independent of any
        // scratch-locality concerns.)
        {
            var import_scratch: [256]u8 = undefined;
            var import_i: usize = 0;
            while (import_i < prog.imports.len) : (import_i += 1) {
                const imp = prog.imports[import_i];
                const dotted = parser.Parser.joinDottedPath(&import_scratch, imp.path_nodes);
                if (parser.Parser.resolveStdImport(dotted)) |resolved_path| {
                    self.write("const __zag_imported_");
                    var idx_buf: [16]u8 = undefined;
                    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{import_i}) catch "X";
                    self.write(idx_str);
                    self.write(" = @import(\"");
                    self.write(resolved_path);
                    self.write("\");\n");
                    // Per-selector use-site forwarding
                    // (docs/manual/22-modules.md §Imports): for each
                    // entry in the selective `{A, B as C}` list,
                    // emit
                    //   const <alias orelse name> = __zag_imported_<i>.<canonical>;
                    // so user references to `MyStr` or `Display`
                    // resolve at the zig level through zig's own
                    // type-alias mechanism — no codegen-side AST
                    // rewrite needed. Whole-module imports
                    // (`selectors.len == 0`) skip this pass; users
                    // access those bindings via the bare
                    // `__zag_imported_<i>.Foo` form until a future
                    // Phase adds macro-/reflection-based namespace
                    // emission (deferred — would require knowing the
                    // source module's decl list at codegen-emit
                    // time, which is not available at this point in
                    // the pipeline).
                    //
                    // The canonical name on the RHS is `sel.name`
                    // (the source-side identifier from the source
                    // module being imported), NOT `alias orelse
                    // name`. zig's alias indirection (`const MyStr =
                    // __zag_imported_0.String`) is the bridge that
                    // lets the user's `MyStr` reference resolve
                    // cleanly through the type-alias path.
                    //
                    // Misses against KNOWN_STD_MODULES SKIP both
                    // the preamble AND the aliases — alias emit
                    // without a preamble would dangle (zig would
                    // error "use of undeclared identifier"). The
                    // `if (parser.Parser.resolveStdImport(dotted))
                    // |resolved_path|` guard at the outer level
                    // already enforces this: the alias loop runs
                    // inside that block, so a miss cleanly skips
                    // both passes.
                    //
                    // The same `idx_str` formatted once at the top
                    // of the iteration is reused here — zig accepts
                    // duplicate `idx_str` slices that point to the
                    // same bytes because both writes resolve
                    // through `self.write`, which copies them into
                    // `out_buf` immediately.
                    //
                    // `is_pub` is NOT honored at v1: the alias emit
                    // is unconditionally `const`, not `pub const`,
                    // matching the preamble's "module-local binding"
                    // contract. Re-exporting aliases via `pub const
                    // MyStr = ...` is a Phase 2+ widening that the
                    // user can opt into once `pub fun` / `pub
                    // struct` re-exports are wired the same way.
                    for (imp.selectors) |sel| {
                        const user_name = sel.alias orelse sel.name;
                        self.write("const ");
                        self.write(user_name);
                        self.write(" = __zag_imported_");
                        self.write(idx_str);
                        self.write(".");
                        self.write(sel.name);
                        self.write(";\n");
                    }
                }
            }
        }

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
        // Generics (§2 Generic Types + §5 Generic impl Blocks): when a
        // struct carries type params, its decl becomes a thunk form
        // (`pub fn NAME(comptime T: type) type { return struct { … }; }`)
        // that cannot host nested methods (the returned type is a
        // fresh anonymous type per monomorphization). The matching impls
        // must therefore be emitted at module scope via `genFreeMethod`
        // — that's the orphan-impl path below. To make that routing
        // happen we DO NOT record the generic struct's name in
        // `matched_targets_buf` so the orphan-impl loop sees it as
        // unmatched. Non-generic structs keep their existing nested-
        // method emission (genStructDecl's `!is_generic` branch).
        for (prog.structs) |sd| {
            if (matched_count < matched_targets_buf.len and sd.type_params.len == 0) {
                matched_targets_buf[matched_count] = sd.name;
                matched_count += 1;
            }
            self.genStructDecl(sd, prog.impls);
        }
        // Phase 3 trait-cast: populate `tracked_trait_names` from
        // `prog.traits` BEFORE any function body emits so the cast
        // arm in `genExpr` sees the populated set when traversing
        // function-local `x as Trait` expressions. The populate
        // happens AFTER struct/enum-impl broadcasting (so any
        // forward-reference quirks on the struct side don't bleed
        // into the trait-side lookup) but before the trait-decl
        // emission loop below (the trait declarations are emitted
        // into the output buffer, but the codegen-side tracking can
        // happen any time since it just records the source-decl name
        // verbatim — independent of zig-side type resolution).
        for (prog.traits) |td| {
            if (self.tracked_trait_count < self.tracked_trait_names.len) {
                self.tracked_trait_names[self.tracked_trait_count] = td.name;
                self.tracked_trait_count += 1;
            }
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
        // `genExpr` for the dispatch surface. TRAIT-method methods
        // (Trait.method-prefixed impl methods whose `trait_name` is
        // non-null) are SKIPPED here so they fall through to the
        // trait-handling pass below which emits the renamed
        // `<Target>_<Trait>_<Method>` shape and the vtable
        // registration a Phase-3 trait-cast call site will reference.
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
                if (m.trait_name != null) continue;
                // Phase 2 generics: thread impl-level type_params so the
                // orphan free-fn emits `comptime X: type` BEFORE its own
                // params. Same wire-up as genStructDecl/genEnumDecl on
                // the nested-method path.
                self.genFreeMethod(impl.target_type, m, impl.type_params);
            }
        }

        // Traits (docs/17 §"Definition"): emit each trait declaration
        // AFTER structs/impls/regular-functions so any code that
        // references the trait name (a vtable-instantiation typed
        // declaration OR a future trait-cast expression site) sees the
        // declared type. The Phase-3 trait-cast work is the only
        // consumer at the moment; emitting here keeps the AST pipeline
        // round-trippable even without the cast surface wired up.
        for (prog.traits) |td| {
            self.genTraitDecl(td);
        }

        // Trait-method orphan free fns (Phase 2): walk prog.impls a
        // second time, this time filtering for `Trait.method`-prefixed
        // methods whose `trait_name` is non-null. Each match emits as a
        // module-scope free fn via `genFreeMethod`, which automatically
        // applies the `<Target>_<Trait>_<Method>` rename when
        // `m.trait_name` is set (see `genFreeMethod`'s doc above).
        // Concurrently, group by `(trait, target_type)` so the next
        // step emits exactly one `<Trait>_VTable_for_<Type>` per unique
        // pair (multiple methods on the same pair tile into one
        // registration, dedupe-stable across zig's compile-error-prone
        // redeclaration check).
        var trait_reg_buf: [64]struct {
            trait: []const u8,
            target: []const u8,
            methods: [16]ast.MethodDecl,
            method_count: usize,
        } = undefined;
        var trait_reg_count: usize = 0;
        for (prog.impls) |impl| {
            for (impl.methods) |m| {
                const trait_name = m.trait_name orelse continue;
                // Emit the renamed free fn (genFreeMethod applies the
                // <Target>_<Trait>_<Method> shape itself).
                self.genFreeMethod(impl.target_type, m, impl.type_params);
                // Group (trait, target_type) for the vtable registration.
                var found = false;
                var fi: usize = 0;
                while (fi < trait_reg_count) : (fi += 1) {
                    if (std.mem.eql(u8, trait_reg_buf[fi].trait, trait_name) and
                        std.mem.eql(u8, trait_reg_buf[fi].target, impl.target_type))
                    {
                        if (trait_reg_buf[fi].method_count < trait_reg_buf[fi].methods.len) {
                            trait_reg_buf[fi].methods[trait_reg_buf[fi].method_count] = m;
                            trait_reg_buf[fi].method_count += 1;
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (trait_reg_count < trait_reg_buf.len) {
                        trait_reg_buf[trait_reg_count].trait = trait_name;
                        trait_reg_buf[trait_reg_count].target = impl.target_type;
                        trait_reg_buf[trait_reg_count].method_count = 1;
                        trait_reg_buf[trait_reg_count].methods[0] = m;
                        trait_reg_count += 1;
                    }
                }
            }
        }
        // VTable registrations: emit one `<Trait>_VTable_for_<Type>`
        // per unique (trait, target_type) pair, populating each
        // registration with the grouped method names. The order of
        // registration emission follows the trait_reg_buf's append
        // order (effectively source-decl order), which matches the
        // user's mental model ("what I declared first comes out first").
        var ri: usize = 0;
        while (ri < trait_reg_count) : (ri += 1) {
            self.genTraitRegistration(
                trait_reg_buf[ri].trait,
                trait_reg_buf[ri].target,
                trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count],
            );
        }

        for (prog.functions) |fun| {
            self.genFun(fun);
        }

        return self.out_buf[0..self.out_len];
    }

    pub     fn isFloatIdentType(self: *Codegen, name: []const u8) bool {
        for (self.type_info_buf[0..self.type_info_count]) |ti| {
            if (std.mem.eql(u8, ti.name, name)) {
                return isFloatTypeName(ti.type_name);
            }
        }
        return false;
    }

    pub     fn isFloatTypeName(type_name: []const u8) bool {
        return std.mem.eql(u8, type_name, "f64") or
            std.mem.eql(u8, type_name, "f32") or
            std.mem.eql(u8, type_name, "f16");
    }

    pub     fn isClosureBound(self: *Codegen, name: []const u8) bool {
        for (self.type_info_buf[0..self.type_info_count]) |ti| {
            if (std.mem.eql(u8, ti.name, name)) {
                return ti.is_closure;
            }
        }
        return false;
    }

    /// Phase 3 trait-cast: lookup helper for the trait-name set
    /// populated at generate() entry. Returns true iff `name` appears
    /// as a declared trait decl in this program's `prog.traits` slice.
    /// O(N) walk over `tracked_trait_names[0..tracked_trait_count]`
    /// — for v1 surface this is bounded (typically 1-3 traits per
    /// file) so the linear cost is acceptable; a future Phase could
    /// swap to a hash-set if the trait count grows past 16.
    /// Called by `.cast` arm in `genExpr` (only when the cast's
    /// `type_text` is a single identifier — multi-token types like
    /// `*const Trait` never enter the trait-cast branch).
    pub     fn isTrackedTrait(self: *Codegen, name: []const u8) bool {
        for (self.tracked_trait_names[0..self.tracked_trait_count]) |tn| {
            if (std.mem.eql(u8, tn, name)) return true;
        }
        return false;
    }

    /// Phase 3 trait-cast: returns the source-type recorded for the
    /// binding named `name` in this function's `type_info_buf`. The
    /// traced type is the verbatim source text from the user's
    /// `let x: T = ...` annotation (e.g. `"Button"`, `"*Button"`,
    /// `"*const Button"`) — interpreted by the cast arm's pointer-
    /// detection branch. Returns null when no entry exists (the
    /// source binding is unannotated, or the source is a more
    /// complex expression than a single ident). Mirrors
    /// `isClosureBound`'s type_info walk shape so v1's typed-binding
    /// surface is consistent across both call sites.
    pub     fn getSourceTypeName(self: *Codegen, name: []const u8) ?[]const u8 {
        for (self.type_info_buf[0..self.type_info_count]) |ti| {
            if (std.mem.eql(u8, ti.name, name)) return ti.type_name;
        }
        return null;
    }
