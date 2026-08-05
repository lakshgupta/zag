const std = @import("std");
const ast = @import("../ast.zig");
const ast_decl = @import("../ast/decl.zig");
const zagTypeToZig = @import("decl.zig").zagTypeToZig;
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

/// Scratch for the nested-materialized-module `../` relative-import
/// prefix (see the imports loop in generate()).
var std_module_rel_scratch: [1024]u8 = undefined;

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
    /// Generated-zig output buffer. Grows on demand from the page
    /// allocator — large hybrid stdlib imports (base64 tables,
    /// SHA-256 K arrays, …) push the emitted module past 64KiB,
    /// which the historical fixed inline buffer could not hold
    /// (out-of-bounds panic in `write`). The slice is owned for the
    /// process lifetime (no deinit — the compiler exits after one
    /// generate pass).
    out_buf: []u8 = &[_]u8{},
    out_len: usize,
    /// Reference to the parsed `ast.Program` this codegen pass
    /// operates on. `init()` leaves it undefined; `generate()`
    /// sets it to `&prog` immediately at entry so every emit
    /// function (genStmt → genBinding → …) can walk
    /// `self.prog.enums` / `self.prog.structs` etc. without
    /// threading the program reference through dozens of call
    /// sites. The pointer is stable for the duration of one
    /// `generate()` call because `prog` is a stack-local by-value
    /// parameter whose address doesn't change once the function
    /// is entered — every emit during that pass sees the same
    /// pointer.
    ///
    /// Used at minimum by:
    ///   - `genBinding` (codegen/stmt.zig) when wrapping a
    ///     backed-enum variant RHS with `@intFromEnum` /
    ///     `@tagName` (gap #5 fix). Walks `self.prog.enums` to
    ///     resolve `Status` → its `backing_type`.
    ///   - any future emit pass that needs to look up an enclosing
    ///     type for a nested emit site.
    prog: *const ast.Program,
    /// Source file path of the zig module being generated
    /// (e.g. "src/main.zag"). Set by the caller before `generate()`.
    source_path: []const u8 = "",
    /// Hybrid-stdlib flag (v0.1 stdlib migration): when true, the
    /// generated preamble emits @import bindings for the stdlib modules
    /// that have moved OUT of the inline preamble (see `generate()`'s
    /// hybrid-preamble block, which runs AFTER the inline preamble but
    /// BEFORE the imports loop). Currently false by default; main.zig's
    /// project-mode dispatch sets it to true after `materializeStdlib()`
    /// has written `build/gen/std/*.zig` to disk for every
    /// `lib/std/<name>.zag` source. File mode (single .zag → /tmp file)
    /// leaves it false — file mode can't materialise `build/gen/std/`
    /// without a project root, and the inline preamble's `__zag_<Type>`
    /// entries keep working without it.
    ///
    /// v0.1 Tier-1 migration follow-up: file mode now materialises the
    /// stdlib next to the leaf zig (main.zig::leafProcess), so
    /// `use_hybrid_stdlib` is set true in BOTH modes — the hybrid
    /// preamble's `@import("std/<n>.zig")` lines resolve against the
    /// materialised mirror in both layouts, and the `__zag_<Type>`
    /// aliases (String/Writer/Error/…) rebind to the materialised
    /// module types so a stdlib function returning `String` and a user
    /// `import std.string.{String}` see the SAME zig type (no
    /// inline-vs-imported split).
    ///
    /// String/Writer are intentionally NOT moved: their inline preamble
    /// type definitions are referenced directly by zig source emitted from
    /// the codegen router arms in `src/codegen/expr.zig` (lines 1598,
    /// 1603, 1606 — `__zag_String.withCapacity`, `__zag_Writer.stdOut`,
    /// `__zag_Writer.stdErr`) and by `zagTypeToZig`'s `String`/`Writer`
    /// overrides in `src/codegen/decl.zig`. Moving them in the same
    /// commit as the rest of the stdlib would force a rewrite of those
    /// sites, which is out of scope for this migration. A follow-up
    /// commit can move String/Writer once the router arms are rebased on
    /// the @imported module shape.
    use_hybrid_stdlib: bool = false,
    /// Relative path prefix (from the generated zig file's directory to
    /// the materialised `std/` mirror) used when emitting stdlib
    /// `@import("<base><rel>.zig")` lines in the imports loop.
    ///
    /// v0.1 Tier-1 migration: the user-module emit sits at
    /// `build/gen/main.zig` (project mode) or `<leaf>/main.zig` (file
    /// mode) with the mirror one level down, so the default `"std/"`
    /// resolves correctly in both layouts. Stdlib materialisation
    /// (main.zig::materializeStdlib) transpiles each `lib/std/*.zag`
    /// INTO the mirror itself, where sibling modules live in the same
    /// directory — that pass sets this to `""` so
    /// `import std.string.{String}` inside `lib/std/fs.zag` emits
    /// `@import("string.zig")` (same-dir relative) instead of a
    /// `std/`-prefixed path that would double-nest.
    import_std_base: []const u8 = "std/",
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
    /// Per-function counter for labeled blocks (`blk: { ... }`).
    /// Reset to 0 by genFun/genMethod so each fn body has unique
    /// `__blk_0`, `__blk_1`, ... labels (zig rejects duplicate labels).
    ///
    /// NOTE (v0.1 Tier-1 migration): the Phase 0-3 router counters
    /// (argv_counter, env_counter, write_file_counter, mkdir_counter,
    /// exec_counter) have ALL been retired — the remaining routed
    /// dispatches either reference a module-level global (`.argv_get`
    /// → `__zag_argv`, no per-call temp) or emit self-contained
    /// inline `blk:` expressions (`.fs_mkdir`, `.process_exec`) with
    /// no temp names that can collide. Only `alloc_counter`
    /// (`new`-heap-local temps) and `destructure_counter` /
    /// `match_counter` / `blk_counter` remain live.
    blk_counter: u32 = 0,
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
    /// Generic-struct base names (`struct Box<T>` — structs with
    /// `type_params.len > 0`), populated at generate() entry alongside
    /// `tracked_trait_names`. The `.method_call` arm in expr.zig uses
    /// the set to dispatch calls on generic instances to the orphan
    /// free fns (`Box_T_make(comptime T, ...)`) instead of the
    /// verbatim member-call emit — the thunk-form struct returned by
    /// `fn Box(comptime T: type) type` has no nested methods, so
    /// `list.push(x)` must become `Box_T_push(list, x)`.
    generic_struct_names: [256][]const u8,
    /// Count of valid entries in `generic_struct_names`.
    generic_struct_count: u32,
    /// Scratch backing for `genericInstanceOfTypeText`'s args slice —
    /// the split parts point into the caller's type-text (which lives
    /// in source), but the ARRAY must outlive the helper's frame, so
    /// it's a Codegen field (same lifetime pattern as
    /// `type_info_buf`).
    generic_args_buf: [8][]const u8,
    /// Owned storage for the turbofish-normalized type text
    /// (`*ArrayList<T>` → `*ArrayList(T)`) — the normalized form is
    /// stack-built and the arg slices point INTO it, so it must live
    /// in the Codegen (a stack-local would dangle past the helper's
    /// return, corrupting the emitted free-fn name).
    generic_norm_buf: [256]u8,
    // Brace-named-field variant lookup side-table (gap #2 fix):
    // genEnumDecl pushes one entry per brace-named-field variant it
    // emits; the `.enum_variant_ctor` arm in genExpr consults the
    // side-table to recover the user's actual field names so it can
    // emit `.{ .x = a, .y = b }` instead of the legacy alphabetical
    // `.{ .a = a, .b = b }` (latter is rejected by zig 0.16 because
    // the emitted `union(enum) { Drag: struct { x: f64, y: f64 } }`
    // container has named fields `x, y`, not `a, b`). The buf is
    // populated at module-scope emit time (so the side-table is
    // stable across any function-body ctor emit later in the same
    // codegen pass); the lookup is O(N) linear scan because
    // tot variant count is bounded by O(256) per program.
    variant_fields_buf: [256]VariantFieldsEntry = undefined,
    variant_fields_count: u32,
    /// Scratch buffer for `resolveTraitBindings` (docs/17 §"Diamond
    /// Disambiguation"): holds the trait-name slice returned to the
    /// caller — usually 0 entries (regular type method) or 1 (normal
    /// trait binding); the shared-body diamond shape fills 2+ entries
    /// (`with T1 (m), T2 (m)` resolves `m` to BOTH `T1` and `T2`).
    /// Overwritten on each call; the slice the caller receives is
    /// valid only until the next invocation. Bounded at 8 — v1
    /// surface won't realistically list more than 8 traits on a
    /// single `impl Type with ...` block.
    trait_binding_buf: [8][]const u8 = undefined,
    /// Scratch buffer for short string formatting (e.g. vtable field
    /// name suffix computation in `traitMethodVtableName`). Not
    /// shared across nested calls; each use overwrites.
    scratch_buf: [128]u8 = undefined,
    /// v1.6 byte-slice member_access widening: read by
    /// `genPrintCall`'s else arm + `genTemplateLit`'s interpolation
    /// slot to widen the format spec from `{any}` to `{s}` when
    /// the user writes `print(self.byte_slice_field)` inside an
    /// impl-block method body. Set by `genFreeMethod`
    /// (target_type-driven orphan emit) and by `genStructDecl`'s +
    /// `genEnumDecl`'s nested-method loops (each pass sets
    /// `impl.target_type` BEFORE calling `genMethod`). Reset to
    /// null at top of `genFun` (top-level `pub fun` declarations
    /// don't have a method receiver). The reason we don't reuse
    /// `type_info_buf` (the existing per-fn let-binding map):
    /// method receivers (`self: *Button`) are NOT `let` bindings
    /// — they're function parameters — so they never populate
    /// `type_info_buf`. A separate `?[]const u8` field keeps the
    /// let-binding invariant clean and the per-body "what struct
    /// am I receiving" lookup cost-free (no map scan).
    current_receiver_struct_name: ?[]const u8 = null,
    /// Layer 3a panic-override guard (docs/manual/33-debugging.md):
    /// set by generate() when the program imports a `panic` selector.
    /// The root `pub const panic = std.debug.FullPanic(...)` override
    /// must NOT be emitted in that case — the imports loop would emit
    /// `const panic = __zag_imported_<N>.panic;` at module scope and
    /// clash with the override (the pre-Tier-1 FullPanic shim was
    /// retired for exactly this collision).
    suppress_panic_override: bool = false,
    /// True while emitting the body of an `async fun` (docs/manual/18
    /// §"Async Trait Methods"): the return_stmt arm wraps `return
    /// EXPR;` into `return .{ .done = true, .value = EXPR };` so the
    /// emitted Future(T) carries the value. Reset false at every
    /// function-body entry (genFun/genMethod/genFreeMethod/genTestFun).
    fn_is_async: bool = false,

    /// Source location map: zig output line → zag source location.
    /// Populated during codegen as expressions/statements are emitted.
    /// Bounded at 16384 entries — one per emitted AST node per module.
    map_entries: [16384]MapEntry = undefined,
    map_count: u32 = 0,
    /// Current line number in the generated zig output (1-based).
    /// Incremented by write() on each newline.
    current_zig_line: u32 = 1,
    /// Current function/method name being generated. Set by genFun/genMethod
    /// before emitting the body; used by recordLoc() for the map symbol column.
    current_symbol: []const u8 = "",
    /// Serialized map text (tab-separated format for .zag.map side-file).
    /// Populated by buildMapText() after generate() completes map recording.
    map_text_buf: [131072]u8 = undefined,
    map_text_len: u32 = 0,

/// One entry in `Codegen.variant_fields_buf` (gap #2 fix). Carries
/// the (enum_name, variant_name) key + the user's actual field names
/// (`[]const ast.VariantField` mirror the EnumVariant.fields slice
/// so codegen can reuse fields directly without re-parse). The
/// keys are stored as source-side slices so a `Drag(2.0, 3.0)` ctor
/// at any depth in the program maps cleanly back to the same
/// `Drag { x: f64, y: f64 }` declaration site via string equality.
pub const VariantFieldsEntry = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    fields: []const ast.VariantField,
};

/// One entry in the zig→zag source location map.
/// `zig_line` is the line number in the generated zig output.
/// `zag_line`/`zag_col` are the source location in the .zag file.
/// `file` is the source path (e.g. "src/main.zag").
/// `symbol` is the enclosing function/method name.
pub const MapEntry = struct {
    zig_line: u32,
    zag_line: u32,
    zag_col: u32,
    file: []const u8,
    symbol: []const u8,
};


    pub const collectTypedBindings = @import("stmt.zig").collectTypedBindings;
    pub const collectNestedBindings = @import("stmt.zig").collectNestedBindings;
    pub const emitPatternCond = @import("stmt.zig").emitPatternCond;
    pub const genArrayLit = @import("primary.zig").genArrayLit;
    pub const genBinding = @import("stmt.zig").genBinding;
    pub const genBindingLeaves = @import("stmt.zig").genBindingLeaves;
    pub const genDocComment = @import("stmt.zig").genDocComment;
    pub const genElseBranch = @import("stmt.zig").genElseBranch;
    pub const genEnumDecl = @import("decl.zig").genEnumDecl;
    pub const genExpr = @import("expr.zig").genExpr;
    // Phase 0 codegen-router helper. Called from the `.call` and
    // `.method_call` arms in expr.zig when builtin_table matches.
    // Without this registration the arms compile-error with
    // `no field named 'genBuiltinCall' in 'Codegen'`, so the build
    // wouldn't reach the inline switch dispatch downstream.
    pub const genBuiltinCall = @import("expr.zig").genBuiltinCall;
    pub const genFreeMethod = @import("decl.zig").genFreeMethod;
    pub const genFun = @import("decl.zig").genFun;
    pub const genTestFun = @import("decl.zig").genTestFun;
    // June-style escape-analysis wiring (src/codegen/escape.zig):
    // called at every function-body emitter entry; under the manual
    // memory model it emits LEAK WARNINGS for never-freed Local
    // sites (no code changes). Without this re-export, decl.zig's
    // genFun/genMethod/genFreeMethod/genTestFun calls to
    // `self.runEscapeAnalysis(...)` would compile-error with
    // `no field or member function named 'runEscapeAnalysis'`.
    pub const runEscapeAnalysis = @import("decl.zig").runEscapeAnalysis;
    pub const genConstDecl = @import("decl.zig").genConstDecl;
    pub const genExternDecl = @import("decl.zig").genExternDecl;
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
    pub const isIntTypeName = @import("core.zig").isIntTypeName;
    pub const isTrackedTrait = @import("core.zig").isTrackedTrait;
    pub const writeCond = @import("stmt.zig").writeCond;
    pub const isGenericStructName = @import("core.zig").isGenericStructName;
    pub const genericStructModulePath = @import("core.zig").genericStructModulePath;
    pub const genericBaseOfTypeText = @import("core.zig").genericBaseOfTypeText;
    pub const genericInstanceOfTypeText = @import("core.zig").genericInstanceOfTypeText;
    pub const genericInstanceOfParenText = @import("core.zig").genericInstanceOfParenText;
    pub const structFieldType = @import("core.zig").structFieldType;
    pub const getSourceTypeName = @import("core.zig").getSourceTypeName;
    // Canonical `with Trait (m)` dispatch (docs/17 §"Diamond
    // Disambiguation"). The two helpers below are file-scope
    // functions — like their sibling `getSourceTypeName` — re-exported
    // into the Codegen struct so cross-bucket callers in
    // decl.zig (genStructDecl/genEnumDecl) and core.zig (generate)
    // can invoke them as `self.resolveTraitBinding(impl, m)` /
    // `self.traitDeclaresMethod(trait, method)` without manually
    // importing the file-scope definition. Without these re-exports
    // zig compiles-error with `no field or member function named
    // '<name>' in 'codegen.core.Codegen'` (mirror of the
    // getSourceTypeName re-export pattern above).
    pub const traitDeclaresMethod = @import("core.zig").traitDeclaresMethod;
    pub const resolveTraitBindings = @import("core.zig").resolveTraitBindings;
    pub const resolveTraitBinding = @import("core.zig").resolveTraitBinding;
    // Gap #2 lookup helper registration: needed because
    // src/codegen/expr.zig's `.enum_variant_ctor` arm calls
    // `self.lookupVariantFields(...)` to recover the user's
    // brace-named-field list for the ctor emit. Without this
    // binding, zig compile-errors with `no field or member
    // function named 'lookupVariantFields' in 'codegen.core.Codegen'`
    // (the same diagnostic surfaced in this turn's build attempt).
    pub const lookupVariantFields = @import("core.zig").lookupVariantFields;
    // Gap-closure (extended `.enum_variant_ctor` unqualified arm in
    // src/codegen/expr.zig uses `self.lookupVariantFieldsByName(...)`
    // to recover brace-field shapes for ctors like `Pos { x: 2.0,
    // y: 3.0 }` written without a `Pos.` prefix). Without this
    // binding, zig compile-errors with `no field or member function
    // named 'lookupVariantFieldsByName' in 'codegen.core.Codegen'`
    // (mirror of the gap #2 lookupVariantFields re-export above).
    pub const lookupVariantFieldsByName = @import("core.zig").lookupVariantFieldsByName;
    // Gap #6 binding-preamble registration: `src/codegen/stmt.zig`'s
    // `genMatchExpr` arm loop calls `self.emitPatternBindings(...)` so
    // captures declared on a brace-named-field or paren-positional
    // match pattern (`Variant { x: w, y: h } => ...` OR `Variant(w,
    // h) => ...`) get a `const NAME = __m.field;` preamble inside the
    // surrounding `if (...) { ... }` block. Without this binding,
    // zig compile-errors with `no field or member function named
    // 'emitPatternBindings' in 'codegen.core.Codegen'` (the same
    // re-export pattern used by the gap #2 `lookupVariantFields`
    // helper above).
    pub const emitPatternBindings = @import("stmt.zig").emitPatternBindings;
    pub const variantSlotType = @import("stmt.zig").variantSlotType;
    pub const seedCaptureType = @import("stmt.zig").seedCaptureType;
    pub const needsIntDivShim = @import("primary.zig").needsIntDivShim;
    // Gap #6 widening helper (`typeAwareFmtSpec`): intentionally
    // NOT re-exported here. Both current call sites (`genPrintCall`
    // else arm + `genTemplateLit` interpolation slot) live inside
    // primary.zig itself, so the helper consumes via direct
    // file-scope lookup without a Codegen-struct indirection.
    // Re-export here is meant to land in lockstep with the FIRST
    // cross-bucket consumer — half-installed re-exports rot, so we
    // register only when there's an actual stmt.zig / expr.zig /
    // decl.zig caller. The helper definition in primary.zig is
    // stable across that future registration.
    pub const write = @import("core.zig").write;
    pub const writeType = @import("core.zig").writeType;
    pub const writeInt = @import("core.zig").writeInt;
    pub const recordLoc = @import("core.zig").recordLoc;
    pub const nextBlkLabel = @import("core.zig").nextBlkLabel;
    pub const buildMapText = @import("core.zig").buildMapText;
    pub const getMapText = @import("core.zig").getMapText;
    pub const stdlibPreambleName = @import("core.zig").stdlibPreambleName;
};

// ============================================================
// FILE-SCOPE methods (CORE_INLINE bucket)
// ============================================================

    pub fn init() Codegen {
        return .{
            .out_buf = &[_]u8{},
            .out_len = 0,
            .destructure_counter = 0,
            .type_info_buf = undefined,
            .type_info_count = 0,
            .alloc_counter = 0,
            .match_counter = 0,
            .blk_counter = 0,
            // Phase 1 env-result counter starts at 0; each
            // `getEnv` builtin emit steps it and emits a fresh
            // `__env_<N>` scratch used to bridge
            // `std.posix.system.getenv`'s `?[*:0]u8` surface to the
            // process_exec dispatches each emit a hardcoded scratch
            // name (`__wf_file`, `__mk_buf`, `__exec_res`) scoped
            // to the per-call blk: { ... } block. process_exit
            // doesn't need a scratch — its emit is a single inline
            // `(std.os.linux.exit(...))` statement with no temp names.
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
            .generic_struct_names = undefined,
            .generic_struct_count = 0,
            .generic_args_buf = undefined,
            .generic_norm_buf = undefined,
            // Brace-named-field variant side-table (gap #2 fix):
            // empty at init(); populated by genEnumDecl when emitting
            // brace-named-field variants. Reset ALSO at generate() entry
            // so a Codegen reused across multiple runs (e.g. smoke +
            // scaffold tests in the same process) starts fresh.
            .variant_fields_buf = undefined,
            .variant_fields_count = 0,
            // v1.6 byte-slice widening: init-time null per the
            // genFun-resets-at-body-entry contract (see the field's
            // docblock above).
            .current_receiver_struct_name = null,
            // Layer 3a panic-override guard: recomputed at every
            // generate() entry from prog.imports; false default is
            // the only safe init (a stale true would suppress the
            // override for a Codegen instance reused across runs).
            .suppress_panic_override = false,
            .fn_is_async = false,
            // `prog` is set by `generate()` immediately on entry
            // (see the `self.prog = &prog;` line at the top of
            // `generate`). Leaving it undefined here is intentional
            // — every emit call goes through `generate()` so prog
            // is always populated before any field that reads it.
            .prog = undefined,
        };
    }

    pub     fn write(self: *Codegen, s: []const u8) void {
        const needed = self.out_len + s.len;
        if (needed > self.out_buf.len) {
            var new_cap = if (self.out_buf.len == 0) 65536 else self.out_buf.len * 2;
            while (new_cap < needed) new_cap *= 2;
            const grown = std.heap.page_allocator.alloc(u8, new_cap) catch @panic("codegen output buffer OOM");
            @memcpy(grown[0..self.out_len], self.out_buf[0..self.out_len]);
            self.out_buf = grown;
        }
        @memcpy(self.out_buf[self.out_len .. self.out_len + s.len], s);
        for (s) |c| {
            if (c == '\n') self.current_zig_line += 1;
        }
        self.out_len += s.len;
    }

    /// Record a source location mapping at the current generated zig line.
    /// Called before emitting an expression or statement with a known zag source location.
    pub fn recordLoc(self: *Codegen, loc: ast.Loc, symbol: []const u8) void {
        const sym = if (symbol.len > 0) symbol else self.current_symbol;
        if (self.map_count < self.map_entries.len) {
            self.map_entries[self.map_count] = .{
                .zig_line = self.current_zig_line,
                .zag_line = loc.line,
                .zag_col = loc.col,
                .file = self.source_path,
                .symbol = sym,
            };
            self.map_count += 1;
        }
    }

    /// Writes a type text to out_buf, applying (1) transparent-alias expansion
    /// via `zagTypeToZig` and (2) generic-parameter bracket rewrite:
    ///   `Result<T, E>` → `Result(T, E)`   and   `Option<T>` → `Option(T)`
    /// zag uses `<T>` syntax for generics but zig uses `(T)` function syntax.
    /// Every type-emit site that could reference these generic types must use
    /// this function (or call `zagTypeToZig` + bracket-replace by hand).
    pub fn writeType(self: *Codegen, text: []const u8) void {
        const expanded = zagTypeToZig(text);
        // Intermediate buffer large enough for alias-expanded + bracket-replaced
        // text (max expansion ~3× `str` → `[]const u8`).
        var buf: [1024]u8 = undefined;
        if (expanded.len > buf.len) {
            // Safety fallback: emit unreachable for now; we can widen buf
            // if real-world type texts ever exceed 1024 bytes.
            @panic("writeType: type text too long for intermediate buffer");
        }
        var len: usize = 0;
        for (expanded) |c| {
            buf[len] = switch (c) {
                '<' => '(',
                '>' => ')',
                else => c,
            };
            len += 1;
        }
        self.write(buf[0..len]);
    }

    /// Write a u32 integer to the output buffer as decimal text.
    pub fn writeInt(self: *Codegen, val: u32) void {
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
        self.write(s);
    }

    /// Allocate a unique labeled-block label name for the current function.
    /// Writes the label into `buf` and returns the slice.
    pub fn nextBlkLabel(self: *Codegen, buf: []u8) []const u8 {
        const id = self.blk_counter;
        self.blk_counter += 1;
        return std.fmt.bufPrint(buf, "__blk_{d}", .{id}) catch "__blk_0";
    }

    /// Write a u32 integer into a caller-provided buffer. Returns the number
    /// of bytes written.
    fn writeIntToBuf(buf: []u8, val: u32) usize {
        var tmp: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch "0";
        @memcpy(buf[0..s.len], s);
        return s.len;
    }

    /// Build the tab-separated map text in `map_text_buf`. Must be called
    /// AFTER `generate()` has recorded all entries. Each line:
    ///   zig_line\tzag_line\tzag_col\tsymbol\tsource_file\n
    pub fn buildMapText(self: *Codegen) void {
        if (self.map_count == 0) return;
        var pos: usize = 0;
        const buf: []u8 = &self.map_text_buf;
        for (self.map_entries[0..self.map_count]) |entry| {
            pos += writeIntToBuf(buf[pos..], entry.zig_line);
            buf[pos] = '\t'; pos += 1;
            pos += writeIntToBuf(buf[pos..], entry.zag_line);
            buf[pos] = '\t'; pos += 1;
            pos += writeIntToBuf(buf[pos..], entry.zag_col);
            buf[pos] = '\t'; pos += 1;
            @memcpy(buf[pos..pos + entry.symbol.len], entry.symbol);
            pos += entry.symbol.len;
            buf[pos] = '\t'; pos += 1;
            @memcpy(buf[pos..pos + entry.file.len], entry.file);
            pos += entry.file.len;
            buf[pos] = '\n'; pos += 1;
        }
        self.map_text_len = @intCast(pos);
    }

    /// Returns the serialized map text (tab-separated). Empty if no map entries.
    pub fn getMapText(self: *Codegen) []const u8 {
        return self.map_text_buf[0..self.map_text_len];
    }

    pub fn generate(self: *Codegen, prog: ast.Program) []const u8 {
        // Store a stable pointer to the stack-local `prog` parameter
        // on the Codegen struct so every emit function (genStmt →
        // genBinding → ...) can resolve type lookups (e.g. backed-
        // enum backing-type for @intFromEnum wrapping at typed-bind
        // sites) via `self.prog.enums` without threading the program
        // reference through every helper. The pointer is stable for
        // the duration of this call because `prog` is a by-value
        // parameter on a fixed stack frame.
        self.prog = &prog;
        // Layer 3a collision guard: the root `pub const panic =
        // std.debug.FullPanic(...)` override must not be emitted when
        // the generated module would ALSO declare a `panic` binding —
        // either via an import selector (`const panic =
        // __zag_imported_<N>.panic;` from the imports loop) or via a
        // top-level .zag decl. The latter covers the materialized
        // lib/std/debug.zag itself, which DEFINES `pub fun panic` —
        // its transpiled file would otherwise collide with the
        // override (the pre-Tier-1 FullPanic shim was retired for
        // exactly this collision). Suppressed programs keep the
        // exact-site __zag_panic_at path.
        self.suppress_panic_override = false;
        for (prog.imports) |imp| {
            for (imp.selectors) |sel| {
                if (std.mem.eql(u8, sel.name, "panic")) {
                    self.suppress_panic_override = true;
                    break;
                }
            }
        }
        for (prog.functions) |f| {
            if (std.mem.eql(u8, f.name, "panic")) {
                self.suppress_panic_override = true;
                break;
            }
        }
        for (prog.consts) |c| {
            if (std.mem.eql(u8, c.name, "panic")) {
                self.suppress_panic_override = true;
                break;
            }
        }
        // Brace-named-field variant side-table (gap #2 fix): reset
        // at generate() entry so the table is fresh per
        // codegen-pass. genEnumDecl pushes one entry per
        // brace-named-field variant emit and the .enum_variant_ctor
        // arm consults the table at every emission site. Resetting
        // here mirrors the existing `matched_targets_buf` /
        // `tracked_trait_*` per-pass pattern so a Codegen reused
        // across multiple tests in the same process (smoke +
        // scaffold + e2e) starts empty.
        self.variant_fields_count = 0;
        self.write(
            \\const std = @import("std");
            \\
            \\// Module-level `__zag_print` shim — replaces the prior
            \\// `pub fn print_fn` helper that routed `print(...)` calls
            \\// through zig's `prior primitive` (STDERR-bound). The new
            \\// helper writes to STDOUT via zig 0.16's buffered-writer
            \\// File.stdout() API; emit sites in
            \\// `src/codegen/primary.zig::genPrintCall` and
            \\// `genTemplateLit`'s `.debug_print` ctx call this
            \\// helper instead of `prior primitive(...)`. The
            \\// `comptime fmt` + `anytype args` signature mirrors
            \\// `prior primitive`'s own surface so the format-string
            \\// interpolation rules (`{any}`, `:.N`, `:x`, etc.) are
            \\// preserved byte-identical — only the destination
            \\// fd changes. `catch return` is intentional: v1's
            \\// `print(...)` is documented to silently drop I/O
            \\// errors (no exception/panic propagation expected
            \\// from a print statement). The `__zag_` prefix
            \\// reserves the name against user identifiers.
            \\fn __zag_print(comptime fmt: []const u8, args: anytype) void {
            \\    var buf: [65536]u8 = undefined;
            \\    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
            \\    var written: usize = 0;
            \\    while (written < slice.len) {
            \\        const rc = std.os.linux.write(std.posix.STDOUT_FILENO, slice.ptr + written, slice.len - written);
            \\        if (rc == 0) return;
            \\        written += @intCast(rc);
            \\    }
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
            // Module-level argv snapshot (zig 0.16 migration). The
            // new zig 0.16 main signature is `pub fn main(init:
            // std.process.Init) !void`; argv is only available via
            // `init.minimal.args.toSlice(allocator)` at main entry.
            // Since zag's codegen doesn't thread `init` through every
            // function that might call `get()` (the argv accessor
            // builtin), we capture the args into this module-level
            // global at main entry and have `.argv_get` dispatch
            // return it directly. The arena-allocator-backed slice
            // lives for the process lifetime, so no manual cleanup
            // is needed. Type is `[]const []const u8` (slice of
            // string slices) matching the `.argv_get` codegen's
            // per-call array element type; `toSlice` returns
            // `[]const [:0]const u8` (sentinel-terminated) which
            // implicitly coerces to `[]const []const u8` on store.
            // Declared as `var` (not `const`) because it's
            // reassigned at main entry; the `__zag_` prefix reserves
            // the name against user identifiers.
            \\var __zag_argv: []const []const u8 = &[_][]const u8{};
            \\
            // zig 0.16: the std.Io event-loop handle is now the canonical
            // way to do file/process operations. Store it at main entry
            // (see genFun's is_main special-case in decl.zig) so the
            // .fs_write_file / .fs_mkdir / .process_exec dispatches can
            // pass it to std.Io.Dir.cwd().createFile(io, ...) etc.
            // without a per-call io parameter. The `var` is needed
            // because it's assigned at runtime from init.io.
            \\var __zag_io: std.Io = undefined;
            \\
            \\// Zig safety checks (OOB, overflow, etc.) use zig's default
            \\// panic handler (no explicit `pub const panic` override — the
            \\// The Layer-3a panic override (see the end of generate():
            \\// `pub const panic = std.debug.FullPanic(...)`) was RE-LANDED
            \\// with a collision guard — the pre-Tier-1 FullPanic shim was
            \\// retired because it clashed with the migrated
            \\// `import std.debug.{panic}` alias at user-module scope; the
            \\// override is now suppressed whenever the generated module
            \\// would also declare a `panic` binding (import selector or
            \\// top-level .zag decl — e.g. materialized lib/std/debug.zag).
            \\// Explicit `panic(msg)` calls in zag source route through
            \\// lib/std/debug.zag → __zag_panic below for zag-source
            \\// file:line:col locations.
            \\
            \\// Zag panic helper — prints a panic message with zag source location.
            \\// Called by `panic(msg)` builtin. Writes to stderr and calls @trap().
            \\fn __zag_panic_at(msg: []const u8, file: []const u8, line: u32, col: u32) noreturn {
            \\    // Layer 3a (docs/manual/33-debugging.md): in Debug
            \\    // builds, record the exact panic site and delegate to
            \\    // the COMPILATION ROOT's trace handler (`@import("root")`
            \\    // is the user module in a real build; a materialized
            \\    // std file compiled standalone resolves to itself).
            \\    // Delegating to the root matters: the root's
            \\    // stack-resolver resolves frames across EVERY module
            \\    // (user main + std), while a std module's own
            \\    // resolver can only map its own code — a trace run
            \\    // from a std file's machinery would silently skip
            \\    // the user's frames. The machinery is emitted into
            \\    // every module, so the @hasDecl guard and the field
            \\    // accesses always resolve; only the root's copies
            \\    // ever execute.
            \\    // `@returnAddress()` makes the trace skip the panic
            \\    // machinery frames and start at the caller of this
            \\    // function.
            \\    if (@import("builtin").mode == .Debug and @hasDecl(@import("root"), "__zag_panic_trace")) {
            \\        @import("root").__zag_panic_site_file = file;
            \\        @import("root").__zag_panic_site_line = line;
            \\        @import("root").__zag_panic_site_col = col;
            \\        @import("root").__zag_panic_trace(msg, @returnAddress());
            \\    }
            \\    const stderr_writer = &std.debug.lockStderr(&.{}).file_writer.interface;
            \\    stderr_writer.print("panic: {s}\n", .{msg}) catch {};
            \\    if (@import("builtin").mode == .Debug) {
            \\        stderr_writer.print("  at {s}:{d}:{d}\n", .{ file, line, col }) catch {};
            \\    }
            \\    @trap();
            \\}
            \\
            \\// Zag panic shim - 1-arg convenience over __zag_panic_at.
            \\// Called by lib/std/debug.zag's panic() real impl (v0.1
            \\// Tier-1 migration, replaces the retired builtin_panic
            \\// router) and by lib/std/string.zag's impl block panic
            \\// sites. Posts a sentinel "<generated>" file + zero
            \\// line/col so the stderr trace lands without a bogus
            \\// location. Shim exists so .zag impl blocks can use the
            \\// canonical panic(msg) shape without threading file /
            \\// line / col through every site — the location accuracy
            \\// trade-off vs the old router emit (which knew the call
            \\// site) is documented in lib/std/debug.zag.
            \\fn __zag_panic(msg: []const u8) noreturn {
            \\    __zag_panic_at(msg, "<generated>", 0, 0);
            \\}
// v0.1 stdlib migration (String/Writer follow-up commit):
            \\// small primitive family referenced by both the inline
            \\// `__zag_String_inline` / `__zag_Writer_inline` method
            \\// bodies (file mode) AND the @imported
            \\// lib/std/{string,fmt}.zag impl blocks (hybrid mode,
            \\// after `materializeStdlib` has run). The user module's
            \\// preamble has these on a separate zig scope from the
            \\// @imported std/<n>.zig files (which get their own
            \\// @emit from materializeStdlib's use_hybrid_stdlib=false
            \\// codegen pass) — zig's per-file module namespace
            \\// keeps duplicates scoped to their respective files;
            \\// user code referencing `__zag_page_alloc(...)`
            \\// directly (rare) resolves via this preamble.
            \\fn __zag_page_alloc(n: usize) [*]u8 {
            \\    return (std.heap.page_allocator.alloc(u8, n) catch @panic("__zag: page_alloc OOM")).ptr;
            \\}
            \\fn __zag_page_realloc(p: [*]u8, old_cap: usize, new_cap: usize) [*]u8 {
            \\    return (std.heap.page_allocator.realloc(p[0..old_cap], new_cap) catch @panic("__zag: page_realloc OOM")).ptr;
            \\}
            \\fn __zag_page_free(p: [*]u8, cap: usize) void {
            \\    std.heap.page_allocator.free(p[0..cap]);
            \\}
            \\// __zag_bench_* — std.bench allocation counters. Every
            \\// `new` / `alloc` site emits __zag_bench_alloc(@sizeOf(T));
            \\// the matching destroy/free sites emit __zag_bench_free.
            \\// bytes_live is the running delta; bytes_total and
            \\// allocations are monotone. Read via lib/std/bench.zag's
            \\// Counters.snapshot(). Overhead per allocation is two
            \\// integer adds — negligible next to the syscall itself.
            \\//
            \\// Cross-module accounting: the state lives in every
            \\// module's preamble copy, but only the COMPILATION
            \\// ROOT's copies are ever mutated — the per-file wrappers
            \\// forward to `@import("root")` (the root module always
            \\// carries the preamble), so a `new` charged in the user
            \\// module and an `alloc` charged inside std/mem.zag land
            \\// in the SAME counters that the user's snapshot() reads
            \\// (mirrors the __zag_panic_trace root-delegation design).
            \\pub var __zag_bench_bytes_live: usize = 0;
            \\pub var __zag_bench_bytes_total: usize = 0;
            \\pub var __zag_bench_allocations: usize = 0;
            \\pub fn __zag_bench_inc(n: usize) void {
            \\    __zag_bench_bytes_live += n;
            \\    __zag_bench_bytes_total += n;
            \\    __zag_bench_allocations += 1;
            \\}
            \\pub fn __zag_bench_dec(n: usize) void {
            \\    __zag_bench_bytes_live -= n;
            \\}
            \\fn __zag_bench_alloc(n: usize) void {
            \\    @import("root").__zag_bench_inc(n);
            \\}
            \\fn __zag_bench_free(n: usize) void {
            \\    @import("root").__zag_bench_dec(n);
            \\}
            \\pub fn __zag_bench_live() usize {
            \\    return @import("root").__zag_bench_bytes_live;
            \\}
            \\pub fn __zag_bench_total() usize {
            \\    return @import("root").__zag_bench_bytes_total;
            \\}
            \\pub fn __zag_bench_allocs() usize {
            \\    return @import("root").__zag_bench_allocations;
            \\}
            \\// v0.1 stdlib migration follow-up: `__zag_memcpy` accepts a
            \\// slice (`[]u8`) for the destination rather than a
            \\// many-pointer (`[*]u8`). The reason: the .zag impl
            \\// blocks in lib/std/string.zag pattern-match on
            \\// `self.ptr[self.len..]` at the call site, which zag's
            \\// codegen translates to a slice expression on a
            \\// many-pointer — in zig, `[*]u8[lo..hi]` produces a
            \\// `[]u8` (slice) NOT a `[*]u8` (pointer). The original
            \\// `__zag_memcpy(dst: [*]u8, ...)` signature was rejected
            \\// at zig compile time because the call site passes a
            \\// slice. Indexing internals (`dst[i] = src[i]`) work
            \\// identically for both types, so the helper's internal
            \\// implementation is unchanged.
            \\fn __zag_memcpy(dst: []u8, src: []const u8, len: usize) void {
            \\    var i: usize = 0;
            \\    while (i < len) {
            \\        dst[i] = src[i];
            \\        i += 1;
            \\    }
            \\}
            \\// Generic container key helpers (std.collections): zig's
            \\// `==` on slices compares the slice DESCRIPTOR (and is
            \\// rejected outright for []const u8 operands), so the
            \\// HashMap's generic probe/contains/get equality + hashing
            \\// delegate here — a comptime K branch selects CONTENT
            \\// semantics for slice keys (str) and value semantics for
            \\// everything else. Pure zig side, so the comptime `if`
            \\// discards the dead branch properly (the .zag emitter
            \\// can't do that — its comptime if still type-checks both
            \\// branches).
            \\fn __zag_keys_eq(comptime K: type, a: K, b: K) bool {
            \\    if (K == []const u8) {
            \\        return std.mem.eql(u8, a, b);
            \\    }
            \\    return a == b;
            \\}
            \\fn __zag_key_hash(comptime K: type, key: K) usize {
            \\    if (K == []const u8) {
            \\        const s: []const u8 = key;
            \\        var h: u64 = 2166136261;
            \\        for (s) |b| {
            \\            h = (h ^ @as(u64, b)) *% 16777619;
            \\        }
            \\        return @as(usize, @truncate(h));
            \\    }
            \\    const bytes: [*]const u8 = @ptrCast(&key);
            \\    var h: u64 = 2166136261;
            \\    var i: usize = 0;
            \\    while (i < @sizeOf(K)) {
            \\        h = (h ^ @as(u64, bytes[i])) *% 16777619;
            \\        i += 1;
            \\    }
            \\    return @as(usize, @truncate(h));
            \\}
            \\fn __zag_fd_write(fd: i32, bytes: []const u8) void {
            \\    var pos: usize = 0;
            \\    while (pos < bytes.len) {
            \\        const n = std.os.linux.write(fd, bytes.ptr + pos, bytes.len - pos);
            \\        if (n <= 0) return;
            \\        pos += @intCast(n);
            \\    }
            \\}
            \\
            \\// __zag_String — heap-allocated mutable UTF-8 string.
            \\// Layout: { ptr: [*]u8, len: usize, cap: usize }.
            \\// Used by `import std.string` and the `String` type in zag.
            \\// v0.1 follow-up: renamed to `__zag_String_inline` so the
            \\// canonical user-facing name `__zag_String` can be
            \\// rebound to `@import("std/types.zig").String` in hybrid
            \\// mode (the hybrid-mode rebinding at the bottom of
            \\// this function shadows the inline decl at user-module
            \\// level; the inline decl survives as a file-mode
            \\// fallback when there's no project root to materialise
            \\// from). The `with_capacity` param is named `allocator`
            \\// (not `alloc`) so a user-module `import std.mem.{alloc}`
            \\// alias at module scope doesn't trigger zig 0.16's
            \\// strict-shadow error on the param (surfaced by the
            \\// Tier-1 mem.zag migration).
            \\const __zag_String_inline = struct {
            \\    ptr: [*]u8,
            \\    len: usize,
            \\    cap: usize,
            \\
            \\    pub fn with_capacity(allocator: std.mem.Allocator, capacity: usize) @This() {
            \\        const buf = allocator.alloc(u8, capacity) catch @panic("String: out of memory");
            \\        return .{ .ptr = buf.ptr, .len = 0, .cap = capacity };
            \\    }
            \\
            \\    pub fn as_str(self: *const @This()) []const u8 {
            \\        return self.ptr[0..self.len];
            \\    }
            \\
            \\    pub fn push_str(self: *@This(), s: []const u8) void {
            \\        const needed = self.len + s.len;
            \\        if (needed > self.cap) {
            \\            var new_cap = self.cap;
            \\            while (new_cap < needed) new_cap *= 2;
            \\            self.ptr = (std.heap.page_allocator.realloc(self.ptr[0..self.cap], new_cap) catch
            \\                @panic("String: realloc failed")).ptr;
            \\            self.cap = new_cap;
            \\        }
            \\        @memcpy(self.ptr[self.len..][0..s.len], s);
            \\        self.len = needed;
            \\    }
            \\
            \\    pub fn deinit(self: *@This()) void {
            \\        std.heap.page_allocator.free(self.ptr[0..self.cap]);
            \\    }
            \\
            \\    pub fn push_ch(self: *@This(), ch: u8) void {
            \\        const needed = self.len + 1;
            \\        if (needed > self.cap) {
            \\            var new_cap = self.cap;
            \\            if (new_cap == 0) new_cap = 16;
            \\            while (new_cap < needed) new_cap *= 2;
            \\            self.ptr = (std.heap.page_allocator.realloc(self.ptr[0..self.cap], new_cap) catch
            \\                @panic("String: realloc failed")).ptr;
            \\            self.cap = new_cap;
            \\        }
            \\        self.ptr[self.len] = ch;
            \\        self.len = needed;
            \\    }
            \\
            \\    pub fn pop_ch(self: *@This()) ?u8 {
            \\        if (self.len == 0) return null;
            \\        self.len -= 1;
            \\        return self.ptr[self.len];
            \\    }
            \\
            \\    pub fn clear(self: *@This()) void {
            \\        self.len = 0;
            \\    }
            \\
            \\    pub fn insert_ch(self: *@This(), pos: usize, ch: u8) void {
            \\        if (pos > self.len) @panic("String.insertCh: position out of bounds");
            \\        const needed = self.len + 1;
            \\        if (needed > self.cap) {
            \\            var new_cap = self.cap;
            \\            if (new_cap == 0) new_cap = 16;
            \\            while (new_cap < needed) new_cap *= 2;
            \\            self.ptr = (std.heap.page_allocator.realloc(self.ptr[0..self.cap], new_cap) catch
            \\                @panic("String: realloc failed")).ptr;
            \\            self.cap = new_cap;
            \\        }
            \\        std.mem.copyBackwards(u8, self.ptr[pos+1..needed], self.ptr[pos..self.len]);
            \\        self.ptr[pos] = ch;
            \\        self.len = needed;
            \\    }
            \\};
            \\
            // Result<T,E> and Option<T> — error-handling fundamental types
            // (docs/manual/18-error-handling.md). Defined as generic zig
            // union(enum) types so the `?` try/unwrap operator and `catch`
            // expression can emit switch-based extraction at codegen time.
            // `Result(T, E)` carries Ok(T) and Err(E) payloads; `Option(T)`
            // carries Some(T) and None (void). Both types defined here in
            // the preamble so every generated zig module can reference them
            // without an explicit import.
            );
            // Result/Option are emitted CONDITIONALLY: the user module
            // defines the canonical inline union(enum) types; MATERIALIZED
            // std modules (use_hybrid_stdlib=false) forward to
            // @import("root") so a std fn returning Result(T, E) shares
            // the USER's Result type — without the forwarder, std.json's
            // parse returns std.json.Result(...) which mismatches the
            // caller's main.Result(...) annotation (per-module preamble
            // duplication surfaced by the json batch).
            if (self.use_hybrid_stdlib) {
                self.write(
                            \\pub fn Result(comptime T: type, comptime E: type) type {
                            \\    return union(enum) {
                            \\        Ok: T,
                            \\        Err: E,
                            \\        pub fn unwrap(self: @This()) T {
                            \\            return switch (self) {
                            \\                .Ok => |v| v,
                            \\                .Err => @panic("unwrap on Err"),
                            \\            };
                            \\        }
                            \\    };
                            \\}
                            \\pub fn Option(comptime T: type) type {
                            \\    return union(enum) {
                            \\        Some: T,
                            \\        None: void,
                            \\        pub fn unwrap(self: @This()) T {
                            \\            return switch (self) {
                            \\                .Some => |v| v,
                            \\                .None => @panic("unwrap on None"),
                            \\            };
                            \\        }
                            \\    };
                            \\}
                );
            } else {
                self.write(
                    \\fn Result(comptime T: type, comptime E: type) type {
                    \\    return @import("root").Result(T, E);
                    \\}
                    \\fn Option(comptime T: type) type {
                    \\    return @import("root").Option(T);
                    \\}
                );
            }
            self.write(
            \\// Future(T) — async/await v1 (docs/manual/00-overview.md
            \\// "Zero-cost async"): `async fun` returns `Future(T)`
            \\// wrapping the declared return type; `await EXPR` drives
            \\// the future to completion and unwraps `value`. The v1
            \\// driver is SYNCHRONOUS: an awaited async call's body
            \\// runs eagerly inside the call, so a future returned to
            \\// an await site is already `done` (or is completed by
            \\// its producer's own drive loop — e.g. a timer
            \\// busy-wait); a future that never completes would block
            \\// forever. Real suspension (resume-on-completion without
            \\// a blocked thread) is the documented follow-up; the
            \\// Future surface and the await lowering are stable
            \\// across it.
            \\fn Future(comptime T: type) type {
            \\    return struct {
            \\        done: bool = false,
            \\        value: ?T = null,
            \\    };
            \\}
            \\fn __zag_future_drive(comptime T: type, fut: *T) void {
            \\    // v1 synchronous driver: the awaited future is
            \\    // completed by its producer before the drive returns
            \\    // (see the Future(T) docblock for the contract).
            \\    // `f: *T` (not *Future(T)): Future is a per-module
            \\    // preamble type, and a user-module await on a std
            \\    // module's Future (e.g. std.time's `after`) must not
            \\    // name the wrong module's Future in the signature.
            \\    _ = fut;
            \\}
            \\fn __zag_future_ready_void() Future(void) {
            \\    return .{ .done = true, .value = {} };
            \\}
            \\
            \\// __zag_err_to_result — bridge from zig error unions to zag's Result.
            \\// Wraps `anyerror!T` into `Result(T, []const u8)` so standard-library
            \\// functions that return zig errors can be used with zag's `?` operator.
            \\fn __zag_err_to_result(comptime T: type, val: anyerror!T) Result(T, []const u8) {
            \\    return if (val) |v| .{ .Ok = v } else |err| .{ .Err = @errorName(err) };
            \\}
            \\
            \\// __zag_Writer — byte sink for formatted output.
            \\// Wraps a file descriptor.  Used by `import std.fmt`.
            \\const __zag_Writer_inline = struct {
            \\    fd: i32,
            \\
            \\    pub fn stdOut() @This() { return .{ .fd = std.posix.STDOUT_FILENO }; }
            \\    pub fn stdErr() @This() { return .{ .fd = std.posix.STDERR_FILENO }; }
            \\
            \\    pub fn writeAll(self: *const @This(), bytes: []const u8) void {
            \\        var pos: usize = 0;
            \\        while (pos < bytes.len) {
            \\            const n = std.os.linux.write(self.fd, bytes.ptr + pos, bytes.len - pos);
            \\            if (n <= 0) return;
            \\            pos += @intCast(n);
            \\        }
            \\    }
            \\
            \\    pub fn print(self: *const @This(), comptime fmt: []const u8, args: anytype) void {
            \\        var buf: [4096]u8 = undefined;
            \\        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
            \\        self.writeAll(s);
            \\    }
            \\};
            \\
            \\// __zag_format_val — format any value to a stack-allocated string.
            \\const __zag_format_buf: [4096]u8 = undefined;
            \\var __zag_format_buf_idx: usize = 0;
            \\fn __zag_format_val(value: anytype) []const u8 {
            \\    const idx = __zag_format_buf_idx;
            \\    const buf = __zag_format_buf[idx..][0..4096];
            \\    __zag_format_buf_idx = (idx + 4096) % (__zag_format_buf.len);
            \\    return std.fmt.bufPrint(buf, "{any}", .{value}) catch "(fmt overflow)";
            \\}
            \\
            \\// __zag_atof — libc-free float parse for std.json: scans a
            \\// sign, integer digits, fractional digits, then an optional
            \\// e/E exponent (the v1 subset json.zag produces).
            \\fn __zag_atof(s: []const u8) f64 {
            \\    var i: usize = 0;
            \\    var neg = false;
            \\    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            \\        neg = s[i] == '-';
            \\        i += 1;
            \\    }
            \\    var result: f64 = 0;
            \\    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            \\        result = result * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
            \\    }
            \\    if (i < s.len and s[i] == '.') {
            \\        i += 1;
            \\        var scale: f64 = 0.1;
            \\        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            \\            result += @as(f64, @floatFromInt(s[i] - '0')) * scale;
            \\            scale *= 0.1;
            \\        }
            \\    }
            \\    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            \\        i += 1;
            \\        var eneg = false;
            \\        if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            \\            eneg = s[i] == '-';
            \\            i += 1;
            \\        }
            \\        var exp: i32 = 0;
            \\        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            \\            exp = exp * 10 + @as(i32, s[i] - '0');
            \\        }
            \\        if (eneg) exp = -exp;
            \\        while (exp > 0) : (exp -= 1) result *= 10.0;
            \\        while (exp < 0) : (exp += 1) result *= 0.1;
            \\    }
            \\    return if (neg) -result else result;
            \\}
            \\// __zag_ftoa — libc-free float formatting for std.json:
            \\// writes integer digits, a '.', and 6 fractional digits
            \\// into `buf`, returning the byte length.
            \\fn __zag_ftoa(value: f64, buf: []u8) usize {
            \\    var v = value;
            \\    var neg = false;
            \\    if (v < 0) {
            \\        neg = true;
            \\        v = -v;
            \\    }
            \\    var int_part: u64 = @intFromFloat(v);
            \\    var frac = v - @as(f64, @floatFromInt(int_part));
            \\    var pos: usize = 0;
            \\    if (neg) {
            \\        if (pos < buf.len) buf[pos] = '-';
            \\        pos += 1;
            \\    }
            \\    var digits: [32]u8 = undefined;
            \\    var nd: usize = 0;
            \\    if (int_part == 0) {
            \\        digits[0] = '0';
            \\        nd = 1;
            \\    } else {
            \\        while (int_part > 0) : (int_part /= 10) {
            \\            digits[nd] = @intCast('0' + int_part % 10);
            \\            nd += 1;
            \\        }
            \\    }
            \\    var d = nd;
            \\    while (d > 0) {
            \\        d -= 1;
            \\        if (pos < buf.len) buf[pos] = digits[d];
            \\        pos += 1;
            \\    }
            \\    if (pos < buf.len) buf[pos] = '.';
            \\    pos += 1;
            \\    var k: usize = 0;
            \\    while (k < 6) : (k += 1) {
            \\        frac *= 10.0;
            \\        const digit: u8 = @intFromFloat(frac);
            \\        frac -= @as(f64, @floatFromInt(digit));
            \\        if (pos < buf.len) buf[pos] = '0' + digit;
            \\        pos += 1;
            \\    }
            \\    return pos;
            \\}
            \\
            \\// __zag_nanosleep_ms — blocking nanosleep for std.async's
            \\// timer loop (sleep/wait/run_for tick at 1ms granularity;
            \\// no busy-wait). Decomposes ms into sec + nsec so long
            \\// sleeps stay accurate.
            \\fn __zag_nanosleep_ms(ms: i64) void {
            \\    var req = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
            \\    if (ms >= 1000) {
            \\        req.sec = @intCast(@divFloor(ms, 1000));
            \\        req.nsec = @intCast(@rem(ms, 1000) * 1_000_000);
            \\    } else if (ms > 0) {
            \\        req.nsec = @intCast(ms * 1_000_000);
            \\    }
            \\    _ = std.os.linux.nanosleep(&req, null);
            \\}
            \\
            \\// __zag_posix family — raw POSIX syscall wrappers
            \\// exposed so lib/std/{fs,env,process,time}.zag can be
            \\// written entirely in .zag (no inline-preamble
            \\// std.Io / std.process / std.fs calls). Linux-only
            \\// (project is Linux-first per AGENTS.md).
            \\
            \\// __zag_openat — raw `openat(2)`. Returns fd on
            \\// success, errno-encoded usize on failure. zig 0.16's
            \\// `std.os.linux.openat` takes the packed-bitfield
            \\// `os.linux.O` flags type (not a bare u32), so the
            \\// helper bitcasts the raw flag word at the boundary.
            \\fn __zag_openat(dirfd: i32, path: [*:0]const u8, flags: u32, mode: u32) usize {
            \\    return std.os.linux.openat(dirfd, path, @bitCast(flags), @intCast(mode));
            \\}
            \\// __zag_read — raw `read(2)`. Returns bytes read
            \\// (partial reads possible) or -1.
            \\fn __zag_read(fd: i32, buf: []u8, len: usize) isize {
            \\    return @bitCast(std.os.linux.read(fd, buf.ptr, len));
            \\}
            \\// __zag_write — raw `write(2)`. Returns bytes
            \\// written (partial writes possible) or -1.
            \\fn __zag_write(fd: i32, buf: []const u8, len: usize) isize {
            \\    return @bitCast(std.os.linux.write(fd, buf.ptr, len));
            \\}
            \\// __zag_close — raw `close(2)`. Returns 0 on
            \\// success, errno-encoded usize on failure.
            \\fn __zag_close(fd: i32) usize {
            \\    return std.os.linux.close(fd);
            \\}
            \\// __zag_mkdirat — raw `mkdirat(2)`. Returns 0 on
            \\// success, errno-encoded usize on failure (high-bit
            \\// set; EEXIST = 17, which lib/std/fs.zag's mkdir
            \\// coalesces to 0 for "mkdir -p" semantics). The
            \\// `mode_t` param is u32 on Linux so it passes
            \\// through directly.
            \\fn __zag_mkdirat(dirfd: i32, path: [*:0]const u8, mode: u32) usize {
            \\    return std.os.linux.mkdirat(dirfd, path, mode);
            \\}
            \\// __zag_getdents64 — raw `getdents64(2)`. Returns
            \\// bytes written into `buf` (0 = EOF). Caller walks
            \\// entries via the canonical `d_reclen` offset walk
            \\// (see src/project.zig::walkSrcTree).
            \\fn __zag_getdents64(fd: i32, buf: [*]u8, buf_len: usize) usize {
            \\    return std.os.linux.getdents64(fd, buf, buf_len);
            \\}
            \\// __zag_clock_gettime — ns since clock-id epoch
            \\// (CLOCK_REALTIME=0, CLOCK_MONOTONIC=1 on Linux).
            \\// zig 0.16's `std.os.linux.clock_gettime` takes the
            \\// `clockid_t` enum, so the helper casts the i32 at the
            \\// boundary.
            \\fn __zag_clock_gettime(clockid: i32) i64 {
            \\    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
            \\    _ = std.os.linux.clock_gettime(@enumFromInt(clockid), &ts);
            \\    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
            \\}
            \\// __zag_getcwd — CWD written into a 4096-byte static
            \\// scratch; returns a slice of it. Two calls in the
            \\// same expression will alias.
            \\const __zag_cwd_buf: [4096]u8 = undefined;
            \\fn __zag_getcwd() []const u8 {
            \\    const n = std.os.linux.getcwd(&__zag_cwd_buf, __zag_cwd_buf.len);
            \\    if (n == 0) return "";
            \\    const eff = if (__zag_cwd_buf[n - 1] == 0) n - 1 else n;
            \\    return __zag_cwd_buf[0..eff];
            \\}
            \\// __zag_getenv — scans /proc/self/environ for `name=value\0`.
            \\// Pure self-contained impl: no dependency on the zig
            \\// stdlib's env accessor (which has churned across zig
            \\// versions and zig 0.16 has no libc-getenv bridge at
            \\// all). Reads env fresh on each call; hot-path callers
            \\// should cache. Returns the value slice (without the
            \\// NUL) or null when unset. Takes `[]const u8` (not a
            \\// sentinel-terminated pointer) so the lib/std/env.zag
            \\// call site passes `name` directly — no `&buf[0] as
            \\// [*:0]const u8` cast at the zag level (a single
            \\// pointer cannot @as-cast into a many-pointer in zig
            \\// 0.16; surfaced by the Tier-1 env.zag migration).
            \\var __zag_env_buf: [32768]u8 = undefined;
            \\// (`var` not `const` so `__zag_env_buf[0..].ptr` is
            \\// `[*]u8` — a const buffer yields `[*]const u8`, which
            \\// __zag_read's `[*]u8` buf param rejects)
            \\fn __zag_getenv(name: []const u8) ?[]const u8 {
            \\    const fd_raw = __zag_openat(std.posix.AT.FDCWD, "/proc/self/environ", 0, 0);
            \\    const fd_signed: isize = @bitCast(fd_raw);
            \\    if (fd_signed < 0) return null;
            \\    const fd: i32 = @intCast(fd_signed);
            \\    defer _ = __zag_close(fd);
            \\    const n = __zag_read(fd, __zag_env_buf[0..], __zag_env_buf.len);
            \\    if (n <= 0) return null;
            \\    const env_len: usize = @intCast(n);
            \\    const name_len = name.len;
            \\    if (name_len == 0) return null;
            \\    var i: usize = 0;
            \\    while (i < env_len) {
            \\        const entry_start = i;
            \\        while (i < env_len and __zag_env_buf[i] != 0) : (i += 1) {}
            \\        const entry_len = i - entry_start;
            \\        if (entry_len > name_len and
            \\            std.mem.eql(u8, __zag_env_buf[entry_start..][0..name_len], name) and
            \\            __zag_env_buf[entry_start + name_len] == '=') {
            \\            return __zag_env_buf[entry_start + name_len + 1 .. i];
            \\        }
            \\        if (i < env_len) i += 1;
            \\    }
            \\    return null;
            \\}
            \\// __zag_exit — `_exit(2)`. noreturn.
            \\fn __zag_exit(code: i32) noreturn {
            \\    std.os.linux.exit(code);
            \\}
            \\// __zag_posix_spawn — fork + execve + waitpid,
            \\// blocking. Caller passes sentinel-terminated
            \\// argv + envp (build `[]?[*:0]const u8` ending in
            \\// null, then pass `.ptr`). Returns child's exit
            \\// code on success, -1 on fork-fail or signal-death.
            \\fn __zag_posix_spawn(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) i32 {
            \\    const pid = std.math.cast(i32, std.os.linux.fork()) orelse return -1;
            \\    if (pid == 0) {
            \\        std.os.linux.execve(argv[0].?, argv, envp);
            \\        std.os.linux.exit(127);
            \\    }
            \\    var status: u32 = 0;
            \\    _ = std.os.linux.waitpid(pid, &status, 0);
            \\    if (std.os.linux.W.IFEXITED(status)) {
            \\        return @as(i32, std.os.linux.W.EXITSTATUS(status));
            \\    }
            \\    return -1;
            \\}
            \\// __zag_waitpid — blocks waiting for an
            \\// already-spawned child. Returns exit code on
            \\// success, -1 on signal-death.
            \\fn __zag_waitpid(pid: i32) i32 {
            \\    var status: u32 = 0;
            \\    _ = std.os.linux.waitpid(pid, &status, 0);
            \\    if (std.os.linux.W.IFEXITED(status)) {
            \\        return @as(i32, std.os.linux.W.EXITSTATUS(status));
            \\    }
            \\    return -1;
            \\}
            \\// __zag_process_spawn — zig 0.16 spawn+wait wrapper for
            \\// lib/std/process.zag's exec. std.process.spawn(io,
            \\// SpawnOptions{ .argv }) inherits the parent environment;
            \\// kill+wait(io) reap the child; the .exited term maps to
            \\// the child's exit code, any other term (signal / stop /
            \\// abort) or a spawn/wait failure maps to 255 (shell
            \\// convention for exec failure). The options literal + term
            \\// union switch live here in zig because zag source cannot
            \\// express anonymous struct literals or union switches —
            \\// the same reason the pre-migration process_exec router
            \\// emitted this block inline.
            \\fn __zag_process_spawn(argv: []const []const u8) i32 {
            \\    var __child = std.process.spawn(__zag_io, .{ .argv = argv }) catch return 255;
            \\    defer __child.kill(__zag_io);
            \\    const __term = __child.wait(__zag_io) catch return 255;
            \\    switch (__term) {
            \\        .exited => |__c| return @as(i32, __c),
            \\        else => return 255,
            \\    }
            \\}
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

        // Hybrid stdlib preamble (v0.1 stdlib migration). When
        // `use_hybrid_stdlib` is true (project mode + the materialise
        // step in src/main.zig has written `build/gen/std/<n>.zig` on
        // disk), the emitted zig `@import`s those files directly.
        // The `__zag_<Type>` aliases below mirror the
        // `stdlibPreambleName` map — `pub import
        // std.error.{Error as E}` will emit `const E = __zag_Error;`
        // (vs. the pre-migration empty-string skip). See
        // `use_hybrid_stdlib`'s docblock on Codegen for the routing
        // rationale; see `src/main.zig::materializeStdlib` for the
        // build-step side of the contract.
        if (self.use_hybrid_stdlib) {
            // v0.1 String/Writer follow-up commit: the migration list
            // grew to 6 modules in src/main.zig::materializeStdlib
            // (`string` join). The `__zag_std_fmt` import below also
            // covers the migrated Writer (its impl block in
            // lib/std/fmt.zag's struct declares the same fd-backed
            // type, accessed via `__zag_std_fmt.Writer`). The
            // `__zag_std_error` / `__zag_std_time` / `__zag_std_atomic`
            // / `__zag_std_bench` imports cover the prior commit's
            // migrated types.
            self.write("const __zag_std_error = @import(\"std/error.zig\");\n");
            self.write("const __zag_std_fmt = @import(\"std/fmt.zig\");\n");
            self.write("const __zag_std_time = @import(\"std/time.zig\");\n");
            self.write("const __zag_std_atomic = @import(\"std/atomic.zig\");\n");
            self.write("const __zag_std_bench = @import(\"std/bench.zig\");\n");
            // std.types hosts the String type (the std.string module
            // was removed — String is ONLY importable as
            // std.types.{String}); the hybrid rebinding follows.
            self.write("const __zag_std_types = @import(\"std/types/mod.zig\");\n");
            // String/Writer rebindings (v0.1 follow-up): in hybrid
            // mode, the @imported module's exported type aliases to
            // `__zag_String` / `__zag_Writer` so call sites written
            // before the migration (router arms in expr.zig) keep
            // resolving without a per-callsite rewrite. The
            // `__zag_String_inline` / `__zag_Writer_inline` names
            // collide only in the file-mode path (which uses the
            // inline alias binder below); the hybrid-mode rebinding
            // here shadows them at the user-module level. The
            // shadowing is fine because `__zag_String_inline` is
            // only referenced from the inline struct's method bodies
            // (inside the struct), not from outside.
            self.write("const __zag_String = __zag_std_types.String;\n");
            self.write("const __zag_Writer = __zag_std_fmt.Writer;\n");
            self.write("const __zag_Error = __zag_std_error.Error;\n");
            self.write("const __zag_Context = __zag_std_error.Context;\n");
            self.write("const __zag_FmtError = __zag_std_fmt.FmtError;\n");
            self.write("const __zag_Duration = __zag_std_time.Duration;\n");
            self.write("const __zag_Timer = __zag_std_time.Timer;\n");
            self.write("const __zag_AtomicI32 = __zag_std_atomic.AtomicI32;\n");
            self.write("const __zag_AtomicI64 = __zag_std_atomic.AtomicI64;\n");
            self.write("const __zag_AtomicUsize = __zag_std_atomic.AtomicUsize;\n");
            self.write("const __zag_AtomicBool = __zag_std_atomic.AtomicBool;\n");
            self.write("const __zag_AtomicPtr = __zag_std_atomic.AtomicPtr;\n");
            self.write("const __zag_Ordering = __zag_std_atomic.Ordering;\n");
            self.write("const __zag_Counters = __zag_std_bench.Counters;\n");
        } else {
            // File-mode fallback (v0.1 follow-up): in file mode
            // there's no project root to materialise std/<n>.zig
            // from, so the user module references the inline
            // `__zag_String_inline` / `__zag_Writer_inline` structs
            // already emitted by the preamble write above. The two
            // alias bindings here are what surface the inline
            // types to user code under the canonical
            // `__zag_String` / `__zag_Writer` names. Hybrid mode
            // skips this — the hybrid preamble block above rebinds
            // `__zag_String` / `__zag_Writer` to the @imported
            // module's exported types instead.
            self.write("const __zag_String = __zag_String_inline;\n");
            self.write("const __zag_Writer = __zag_Writer_inline;\n");
        }

        {
            var import_scratch: [256]u8 = undefined;
            var import_i: usize = 0;
            while (import_i < prog.imports.len) : (import_i += 1) {
                const imp = prog.imports[import_i];
                const dotted = parser.Parser.joinDottedPath(&import_scratch, imp.path_nodes);
                if (parser.Parser.resolveStdImport(dotted)) |resolved_path| {
                    // Stdlib imports: types that ARE in the preamble
                    // (e.g. __zag_String, __zag_Writer, __zag_Error)
                    // alias directly to the preamble type. Types /
                    // functions that are NOT in the preamble
                    // (e.g. std.fs.read_file after the v0.1 migration
                    // to a real .zag file) alias through
                    // `__zag_imported_<i>.<name>`, requiring us to
                    // emit the @import preamble line for the .zag
                    // source's compiled form. The first-pass scan
                    // distinguishes these two cases so we only emit
                    // the @import line when genuinely needed (the
                    // fast-path preserves the prior shape byte-for-
                    // byte for imports that ONLY resolve to
                    // preamble types — no zig-side regression).
                    if (std.mem.startsWith(u8, resolved_path, "lib/std/")) {
                        var any_needs_import = false;
                        for (imp.selectors) |sel| {
                            if (stdlibPreambleName(sel.name).len == 0) {
                                any_needs_import = true;
                                break;
                            }
                        }

                        // Fast path: every selector maps to a
                        // preamble type — no @import line needed
                        // (preserves the pre-migration behaviour
                        // byte-for-byte). User-module modes only
                        // (import_std_base = "std/"): in MATERIALIZED
                        // std files (import_std_base = "") the
                        // preamble types are the inline per-file
                        // copies, so aliasing `String` to
                        // `__zag_String` would produce a DIFFERENT
                        // type than the user module's `String`
                        // (rebound to `@import("std/types.zig").String`
                        // in the hybrid block above) — read_file
                        // returning the inline String would fail the
                        // user's `let s: String = read_file(...)`
                        // binding (Tier-1 migration surfaced this on
                        // examples exercising fs.read_file). The
                        // materialized files fall through to the slow
                        // path, which emits the same-dir
                        // `@import("string.zig")` and yields the
                        // shared real String type.
                        if (!any_needs_import and self.import_std_base.len > 0) {
                            for (imp.selectors) |sel| {
                                const preamble_name = stdlibPreambleName(sel.name);
                                const user_name = sel.alias orelse sel.name;
                                // `pub import` → `pub const` (cross-
                                // module re-export; see the slow-path
                                // docblock below).
                                if (imp.is_pub) self.write("pub ");
                                self.write("const ");
                                self.write(user_name);
                                self.write(" = ");
                                self.write(preamble_name);
                                self.write(";\n");
                            }
                            continue;
                        }

                        // Slow path: at least one selector lives in
                        // the .zag source file (the v0.1 migration's
                        // case for std.fs.{read_file}). Emit the
                        // @import preamble ONCE, then per-selector
                        // emit chooses the right bridge.
                        //
                        // v0.1 Tier-1 migration: the import path is
                        // rewritten from the KNOWN_STD_MODULES
                        // `lib/std/<rel>.zag` shape into the
                        // materialised-mirror shape
                        // `<import_std_base><rel>.zig` (e.g.
                        // `std/fs.zig` from build/gen/main.zig,
                        // `string.zig` from inside the mirror
                        // itself). `lib/std/*.zag` files are never
                        // directly @importable — zig resolves the
                        // emitted path relative to the generated
                        // module's directory, and only the
                        // materialised `.zig` copies live there.
                        const rel_start = "lib/std/".len;
                        if (resolved_path.len <= rel_start) continue;
                        const rel_path = resolved_path[rel_start..];
                        // Nested materialized modules (std.collections
                        // directory split): a file transpiled INTO the
                        // mirror (import_std_base == "") emits sibling
                        // imports relative to ITS OWN directory —
                        // `build/gen/std/collections/mod.zig` must
                        // import `array_list.zig`, NOT
                        // `collections/array_list.zig` (which would
                        // resolve under build/gen/std/collections/).
                        // Strip the current file's directory prefix
                        // from the resolved path when the file lives
                        // under lib/std/.
                        var emit_rel: []const u8 = rel_path;
                        if (self.import_std_base.len == 0 and self.source_path.len > 0) {
                            const src_dir_end = std.mem.lastIndexOfScalar(u8, self.source_path, '/');
                            if (src_dir_end) |sde| {
                                const src_dir = self.source_path[0..sde];
                                if (std.mem.startsWith(u8, resolved_path, src_dir) and
                                    resolved_path.len > src_dir.len and resolved_path[src_dir.len] == '/')
                                {
                                    emit_rel = resolved_path[src_dir.len + 1 ..];
                                } else if (sde > "lib/std/".len) {
                                    // Cross-directory import from a
                                    // NESTED materialized module:
                                    // build/gen/std/strings/slices.zig
                                    // importing std.collections needs
                                    // `../collections/mod.zig`, not
                                    // `collections/mod.zig` (which
                                    // resolves under its own dir).
                                    // All lib/std modules live at
                                    // depth <= 1, so a single `../`
                                    // prefix suffices.
                                    if ("../".len + rel_path.len <= std_module_rel_scratch.len) {
                                        std_module_rel_scratch[0] = '.';
                                        std_module_rel_scratch[1] = '.';
                                        std_module_rel_scratch[2] = '/';
                                        @memcpy(std_module_rel_scratch[3..][0..rel_path.len], rel_path);
                                        emit_rel = std_module_rel_scratch[0 .. 3 + rel_path.len];
                                    }
                                }
                            }
                        }
                        const zig_ext_start = if (std.mem.endsWith(u8, emit_rel, ".zag"))
                            emit_rel.len - ".zag".len
                        else
                            emit_rel.len;
                        self.write("const __zag_imported_");
                        var idx_buf: [16]u8 = undefined;
                        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{import_i}) catch "X";
                        self.write(idx_str);
                        self.write(" = @import(\"");
                        self.write(self.import_std_base);
                        self.write(emit_rel[0..zig_ext_start]);
                        self.write(".zig\");\n");
                        for (imp.selectors) |sel| {
                            const preamble_name = stdlibPreambleName(sel.name);
                            const user_name = sel.alias orelse sel.name;
                            if (preamble_name.len > 0 and self.import_std_base.len > 0) {
                                // Known-preamble-name: alias directly
                                // to the preamble type (no need to
                                // plumb through __zag_imported_<i>).
                                // User-module modes only — in
                                // materialized std files
                                // (import_std_base = "") the
                                // preamble-name alias would point at
                                // the per-file inline type, breaking
                                // cross-module type identity (see the
                                // fast-path docblock above); those
                                // files alias through the @import.
                                if (imp.is_pub) self.write("pub ");
                                self.write("const ");
                                self.write(user_name);
                                self.write(" = ");
                                self.write(preamble_name);
                                self.write(";\n");
                            } else {
                                // .zag-source-backed: forward through
                                // the @import alias so zig sees
                                // `__zag_imported_<i>.<canonical>`.
                                if (imp.is_pub) self.write("pub ");
                                self.write("const ");
                                self.write(user_name);
                                self.write(" = __zag_imported_");
                                self.write(idx_str);
                                self.write(".");
                                self.write(sel.name);
                                self.write(";\n");
                            }
                        }
                        continue;
                    }
                    // Non-stdlib imports: emit @import of the resolved path.
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
                    // `is_pub` IS honored at v1: `pub import` emits
                    // `pub const <name> = __zag_imported_<i>.<sel>;`
                    // (a cross-module-visible re-export), while a
                    // plain `import` keeps the module-local `const`.
                    // This is what makes `std.types`-style re-export
                    // barrels work: lib/std/string.zag's
                    // `pub import std.types.{String}` emits
                    // `pub const String = @import("types.zig").String;`
                    // so `import std.string.{String}` resolves the
                    // SAME type across modules (without pub, zig
                    // rejects "decl is not pub" at the cross-module
                    // use site). The pre-Phase-2 shape ("is_pub NOT
                    // honored") predates the std.types move.
                    for (imp.selectors) |sel| {
                        const user_name = sel.alias orelse sel.name;
                        if (imp.is_pub) self.write("pub ");
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
            // Gap #3 dispatch-side: only BARE enums (no variants
            // with payload, no backing_type) register as matched. Payload-
            // bearing enums (`union(enum) { ... }`) and backed enums
            // (`enum(T) { ... }`) are intentionally left out so their
            // matching impl blocks fall through to the orphan-impl loop
            // below — emit them as module-scope free fns via
            // `genFreeMethod` because zig 0.16 rejects methods nested
            // inside those two container shapes. The bare-enum path
            // keeps the legacy nested-method emit (existing tests
            // for `impl Direction { ... }` etc. pin this surface).
            // The mirrored emit-side gate lives in `genEnumDecl` (gap
            // #3 emit-side) so nested methods only emit on bare enums.
            var is_bare_enum = ed.backing_type == null;
            if (is_bare_enum) {
                for (ed.variants) |v| {
                    if (v.payload_type != null or v.fields.len > 0) {
                        is_bare_enum = false;
                        break;
                    }
                }
            }                if (is_bare_enum and matched_count < matched_targets_buf.len) {
                matched_targets_buf[matched_count] = ed.name;
                matched_count += 1;
            }
            self.genEnumDecl(ed, prog.impls);
        }
        // Module re-exports (docs/manual/22 §Re-exports): `[pub] use
        // <dotted-path> as <name>` emits `pub const <name> =
        // @import("<resolved>.zig");` — a module-namespace binding so
        // `<name>.member` resolves to the re-exported module's
        // members. Path resolution mirrors the imports loop:
        // KNOWN_STD_MODULES lookup + the materialized-mirror path
        // rewrite (`<import_std_base><rel>.zig` — "std/" from the
        // user module, same-dir "" inside the materialized mirror).
        // Unresolvable paths are skipped silently (the imports loop's
        // null-on-miss contract).
        for (prog.uses) |use_decl| {
            var use_scratch: [256]u8 = undefined;
            const dotted = parser.Parser.joinDottedPath(&use_scratch, use_decl.path_nodes);
            const resolved = parser.Parser.resolveStdImport(dotted) orelse continue;
            if (resolved.len <= "lib/std/".len) continue;
            const rel_path = resolved["lib/std/".len..];
            const zig_ext_start = if (std.mem.endsWith(u8, rel_path, ".zag"))
                rel_path.len - ".zag".len
            else
                rel_path.len;
            if (use_decl.is_pub) self.write("pub ");
            self.write("const ");
            self.write(use_decl.name);
            self.write(" = @import(\"");
            self.write(self.import_std_base);
            self.write(rel_path[0..zig_ext_start]);
            self.write(".zig\");\n");
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

        // Generic-struct tracking: record every struct decl with
        // type params so `.method_call` can dispatch instance calls
        // to the orphan free fns (the thunk-form struct has no
        // nested methods — nested emission is skipped on the thunk
        // path, see genStructDecl's is_generic branch).
        for (prog.structs) |sd| {
            if (sd.type_params.len > 0 and self.generic_struct_count < self.generic_struct_names.len) {
                self.generic_struct_names[self.generic_struct_count] = sd.name;
                self.generic_struct_count += 1;
            }
        }

        // Emit default method free functions for trait methods that
        // have a body. Named `<Trait>__<Method>` with the first
        // parameter `self: *anyopaque` matching the vtable function-
        // pointer signature and the body's `self` references.
        for (prog.traits) |td| {
            for (td.methods, 0..) |tm, tmi| {
                if (tm.body == null) continue;
                const vtable_name = traitMethodVtableName(td, tmi);
                self.write("pub fn ");
                self.write(td.name);
                self.write("__");
                self.write(vtable_name);
                self.write("(self: *anyopaque");
                for (tm.params[1..]) |p| {
                    self.write(", ");
                    self.write(p.name);
                    self.write(": ");
                    self.writeType(p.type_text);
                }
                self.write(") ");
                if (tm.return_type) |rt| self.writeType(rt) else self.write("void");
                self.write(" {\n");
                for (tm.body.?) |s| self.genStmt(s, false);
                self.write("}\n\n");
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
                // Canonical `with Trait (m)` dispatch (docs/17
                // §"Diamond Disambiguation"): if the block's
                // trait_specs (or the legacy `Trait.method` prefix)
                // bind this method to a trait, skip it here so the
                // trait-handling pass below emits the renamed
                // `<Target>_<Trait>_<Method>` free fn and the matching
                // vtable registration. Methods with no trait binding
                // (regular-type-method path (c)) emit through the
                // orphan free-fn shape here.
                if (self.resolveTraitBinding(&impl, m) != null) continue;
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
                // Canonical `with Trait (m)` dispatch (docs/17
                // §"Diamond Disambiguation"): resolveTraitBindings
                // returns the LIST of traits whose vtables should
                // register this body — 0 entries → regular type
                // method (already emitted by the orphan walk above);
                // 1 entry → normal trait binding; 2+ entries → the
                // shared-body diamond (`with T1 (m), T2 (m)` registers
                // the same body on BOTH vtables, emitting one renamed
                // free fn per owning trait).
                const bindings = self.resolveTraitBindings(&impl, m);
                if (bindings.len == 0) continue;
                for (bindings) |trait_name| {
                    // Copy m with the resolved trait_name so genFreeMethod's
                    // `<Target>_<Trait>_<Method>` rename and the vtable
                    // registration both reference the bound trait. The
                    // AST is `[]const` (immutable) so we copy locally;
                    // the original MethodDecl is untouched. Each
                    // binding in the list produces its own renamed fn
                    // so the shared-body shape lands as two distinct
                    // free fns referencing the same impl body.
                    var m_resolved = m;
                    m_resolved.trait_name = trait_name;
                    // For overloaded methods, suffix the method name
                    // in the free fn so `@ptrCast` can uniquely
                    // reference it (zig can't resolve overloaded
                    // function names in `@ptrCast` without a suffix).
                    for (prog.traits) |td1| {
                        if (!std.mem.eql(u8, td1.name, trait_name)) continue;
                        for (td1.methods, 0..) |tm1, tmi1| {
                            if (std.mem.eql(u8, tm1.name, m.name) and tm1.params.len == m.params.len) {
                                const vfn = traitMethodVtableName(td1, tmi1);
                                if (!std.mem.eql(u8, vfn, m.name)) {
                                    m_resolved.name = vfn;
                                }
                                break;
                            }
                        }
                        break;
                    }
                    // Emit the renamed free fn (genFreeMethod applies
                    // the <Target>_<Trait>_<Method> shape itself).
                    self.genFreeMethod(impl.target_type, m_resolved, impl.type_params);
                    // Group (trait, target_type) for the vtable
                    // registration. The shared-body shape tiles the
                    // same method into multiple `(trait, target)`
                    // buckets so each trait's VTable gets its own
                    // `@ptrCast` bridge into the renamed fn.
                    var found = false;
                    var fi: usize = 0;
                    while (fi < trait_reg_count) : (fi += 1) {
                        if (std.mem.eql(u8, trait_reg_buf[fi].trait, trait_name) and
                            std.mem.eql(u8, trait_reg_buf[fi].target, impl.target_type))
                        {
                            if (trait_reg_buf[fi].method_count < trait_reg_buf[fi].methods.len) {
                                trait_reg_buf[fi].methods[trait_reg_buf[fi].method_count] = m_resolved;
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
                            trait_reg_buf[trait_reg_count].methods[0] = m_resolved;
                            trait_reg_count += 1;
                        }
                    }
                }
            }
        }
        // Post-pass: for impl blocks with trait_specs but zero method
        // bodies (all defaults inherited), create a vtable registration
        // entry so the defaults get registered. Without this, a
        // completely-defaults impl like `impl Widget with Greeter {}`
        // would never get a VTable.
        for (prog.impls) |impl| {
            if (impl.trait_specs.len == 0) continue;
            for (impl.trait_specs) |spec| {
                // Check if this (trait, target) pair already has an entry
                var already_exists = false;
                var ei: usize = 0;
                while (ei < trait_reg_count) : (ei += 1) {
                    if (std.mem.eql(u8, trait_reg_buf[ei].trait, spec.name) and
                        std.mem.eql(u8, trait_reg_buf[ei].target, impl.target_type))
                    {
                        already_exists = true;
                        break;
                    }
                }
                if (!already_exists and trait_reg_count < trait_reg_buf.len) {
                    trait_reg_buf[trait_reg_count].trait = spec.name;
                    trait_reg_buf[trait_reg_count].target = impl.target_type;
                    trait_reg_buf[trait_reg_count].method_count = 0;
                    trait_reg_count += 1;
                }
            }
        }
        // VTable registrations: emit one `<Trait>_VTable_for_<Type>`
        // per unique (trait, target_type) pair, populating each
        // registration with the grouped method names. The order of
        // registration emission follows the trait_reg_buf's append
        // order (effectively source-decl order), which matches the
        // user's mental model ("what I declared first comes out first").
        // For each pair, check the trait's full method list for
        // default methods the impl did not provide and register those
        // too — they reference the <Trait>__<Method> default free fns.
        var ri: usize = 0;
        while (ri < trait_reg_count) : (ri += 1) {
            var default_buf: [16][]const u8 = undefined;
            var default_field_buf: [16][]const u8 = undefined;
            var default_count: usize = 0;
            var method_field_buf: [16][]const u8 = undefined;
            for (prog.traits) |td| {
                if (!std.mem.eql(u8, td.name, trait_reg_buf[ri].trait)) continue;
                for (td.methods, 0..) |tm, tmi| {
                    if (tm.body == null) continue;
                    var already_impl = false;
                    for (trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count]) |im| {
                        if (std.mem.eql(u8, im.name, tm.name) and im.params.len == tm.params.len) {
                            already_impl = true;
                            break;
                        }
                    }
                    if (!already_impl and default_count < default_buf.len) {
                        default_buf[default_count] = tm.name;
                        default_field_buf[default_count] = traitMethodVtableName(td, tmi);
                        default_count += 1;
                    }
                }
                // Compute vtable field names for impl-provided methods
                for (trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count], 0..) |im, ii| {
                    var found = false;
                    for (td.methods, 0..) |tm, tmi| {
                        if (std.mem.eql(u8, im.name, tm.name) and im.params.len == tm.params.len) {
                            method_field_buf[ii] = traitMethodVtableName(td, tmi);
                            found = true;
                            break;
                        }
                    }
                    if (!found) method_field_buf[ii] = im.name;
                }
                break;
            }
            self.genTraitRegistration(
                trait_reg_buf[ri].trait,
                trait_reg_buf[ri].target,
                trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count],
                method_field_buf[0..trait_reg_buf[ri].method_count],
                default_buf[0..default_count],
                default_field_buf[0..default_count],
            );
        }

        for (prog.externs) |ext| {
            self.genExternDecl(ext);
        }

        for (prog.consts) |c| {
            self.genConstDecl(c);
        }

        for (prog.functions) |fun| {
            self.genFun(fun);
        }

        // Emit the zig→zag source location map table. ALWAYS emitted
        // (empty entry list when map_count == 0): the Layer-3a panic
        // machinery below references __zag_map by name, and zig 0.16
        // name-resolves identifiers inside comptime-pruned `if`
        // branches — a conditionally-absent table would fail every
        // __zag_panic_at that guards on it. Only included in debug
        // builds (stripped by @compileIf in release).
        self.write(
            \\
            \\const __ZagMapEntry = struct {
            \\    zig_line: u32,
            \\    zag_line: u32,
            \\    zag_col: u32,
            \\    file: []const u8,
            \\    symbol: []const u8,
            \\};
            \\const __zag_map = if (@import("builtin").mode == .Debug)
                \\    [_]__ZagMapEntry{
                \\
            );
            for (self.map_entries[0..self.map_count]) |entry| {
                self.write("        .{ .zig_line = ");
                self.writeInt(entry.zig_line);
                self.write(", .zag_line = ");
                self.writeInt(entry.zag_line);
                self.write(", .zag_col = ");
                self.writeInt(entry.zag_col);
                self.write(", .file = \"");
                self.write(entry.file);
                self.write("\", .symbol = \"");
                self.write(entry.symbol);
                self.write("\" },\n");
            }
            self.write(
                \\    }
                \\else
                \\    [_]__ZagMapEntry{}
                \\;
                \\
            );
            // resolves each frame to its GENERATED zig file:line via
            // std.debug, then maps it back to the original .zag
            // file:line:col through the embedded __zag_map table
            // (binary search by zig_line — map_entries are appended
            // in ascending zig_line order because current_zig_line
            // only grows) and prints the zag source line + caret
            // marker. Explicit `panic(msg)` calls route through
            // __zag_panic_at (preamble above), which records the
            // exact site so the trace's top line is precise even when
            // DWARF resolution is fuzzy. Release builds fall back to
            // zig's defaultPanic (the map table is compiled out by the
            // mode guard) and __zag_panic_at keeps its slim
            // print+@trap path.
            //
            // The override is SKIPPED when the program imports a
            // `panic` selector: the imports loop would emit
            // `const panic = __zag_imported_<N>.panic;` at module
            // scope and clash with the root override (the pre-Tier-1
            // FullPanic shim was retired for exactly this collision);
            // such programs keep the exact-site panic path. The
            // machinery below is emitted unconditionally regardless —
            // __zag_panic_at references it by name and zig 0.16
            // name-resolves identifiers in comptime-pruned branches.
            self.write(
                \\pub var __zag_panic_site_file: []const u8 = "";
                \\pub var __zag_panic_site_line: u32 = 0;
                \\pub var __zag_panic_site_col: u32 = 0;
                \\
                    \\fn __zag_panic_map_lookup(zig_line: u32) ?__ZagMapEntry {
                    \\    if (__zag_map.len == 0) return null;
                    \\    const S = struct {
                    \\        fn cmp(target: u32, item: __ZagMapEntry) std.math.Order {
                    \\            return std.math.order(target, item.zig_line);
                    \\        }
                    \\    };
                    \\    const i = std.sort.lowerBound(__ZagMapEntry, &__zag_map, zig_line, S.cmp);
                    \\    if (i == 0) return null;
                    \\    return __zag_map[i - 1];
                    \\}
                    \\
                    \\fn __zag_panic_print_source_line(file: []const u8, line: u32, col: u32) void {
                    \\    var path_z: [1024]u8 = undefined;
                    \\    const n = file.len;
                    \\    if (n + 1 > path_z.len) return;
                    \\    @memcpy(path_z[0..n], file);
                    \\    path_z[n] = 0;
                    \\    const fd_raw = __zag_openat(std.posix.AT.FDCWD, @as([*:0]const u8, @ptrCast(&path_z[0])), 0, 0);
                    \\    if ((fd_raw & 0x8000000000000000) != 0) return;
                    \\    const fd: i32 = @as(i32, @intCast(fd_raw));
                    \\    defer _ = __zag_close(fd);
                    \\    var buf: [8192]u8 = undefined;
                    \\    var total: usize = 0;
                    \\    while (total < buf.len) {
                    \\        const n_signed = __zag_read(fd, buf[total..], buf.len - total);
                    \\        if (n_signed <= 0) break;
                    \\        total += @as(usize, @intCast(n_signed));
                    \\    }
                    \\    var cur: usize = 1;
                    \\    var start: usize = 0;
                    \\    var i: usize = 0;
                    \\    var found = false;
                    \\    const stderr_writer = &std.debug.lockStderr(&.{}).file_writer.interface;
                    \\    while (i < total) : (i += 1) {
                    \\        if (buf[i] == '\n') {
                    \\            if (cur == line) {
                    \\                stderr_writer.print("      {s}\n", .{buf[start..i]}) catch {};
                    \\                found = true;
                    \\                break;
                    \\            }
                    \\            cur += 1;
                    \\            start = i + 1;
                    \\        }
                    \\    }
                    \\    if (!found and cur == line and start < total) {
                    \\        stderr_writer.print("      {s}\n", .{buf[start..total]}) catch {};
                    \\    }
                    \\    if (col > 0) {
                    \\        var caret_buf: [256]u8 = undefined;
                    \\        const spaces = @min(col - 1, caret_buf.len - 1);
                    \\        @memset(caret_buf[0..spaces], ' ');
                    \\        caret_buf[spaces] = '^';
                    \\        stderr_writer.print("      {s}\n", .{caret_buf[0 .. spaces + 1]}) catch {};
                    \\    }
                    \\}
                    \\
                    \\pub fn __zag_panic_trace(msg: []const u8, first_trace_addr: ?usize) noreturn {
                    \\    const stderr_writer = &std.debug.lockStderr(&.{}).file_writer.interface;
                    \\    stderr_writer.print("panic: {s}\n", .{msg}) catch {};
                    \\    if (__zag_panic_site_line > 0) {
                    \\        stderr_writer.print("  at {s}:{d}:{d}\n", .{ __zag_panic_site_file, __zag_panic_site_line, __zag_panic_site_col }) catch {};
                    \\        __zag_panic_print_source_line(__zag_panic_site_file, __zag_panic_site_line, __zag_panic_site_col);
                    \\    }
                    \\    stderr_writer.print("stack trace:\n", .{}) catch {};
                    \\    const di = std.debug.getSelfDebugInfo() catch {
                    \\        stderr_writer.print("  (debug info unavailable)\n", .{}) catch {};
                    \\        @trap();
                    \\    };
                    \\    // Public unwind surface (zig 0.16 keeps StackIterator
                    \\    // itself private): captureCurrentStackTrace returns the
                    \\    // raw return addresses, then getSymbols resolves each —
                    \\    // the same pair writeStackTrace uses internally.
                    \\    // `first_trace_addr` (from the panic machinery or
                    \\    // __zag_panic_at) skips the handler frames. The -1
                    \\    // mirrors StackIterator.ra_call_offset so the resolved
                    \\    // address lands IN the call instruction, not after it.
                    \\    const ra_call_offset: usize = if (@import("builtin").cpu.arch.isSPARC()) 0 else 1;
                    \\    var addr_buf: [128]usize = undefined;
                    \\    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = first_trace_addr }, &addr_buf);
                    \\    var text_arena: std.heap.ArenaAllocator = .init(std.debug.getDebugInfoAllocator());
                    \\    defer text_arena.deinit();
                    \\    const io = std.Options.debug_io;
                    \\    for (trace.return_addresses) |addr| {
                    \\        var symbol_fallback_allocator = std.heap.stackFallback(@sizeOf(std.debug.Symbol) + @alignOf(std.debug.Symbol) - 1, std.debug.getDebugInfoAllocator());
                    \\        const symbol_allocator = symbol_fallback_allocator.get();
                    \\        var symbols = std.ArrayList(std.debug.Symbol).initCapacity(symbol_allocator, 1) catch continue;
                    \\        defer symbols.deinit(symbol_allocator);
                    \\        di.getSymbols(io, symbol_allocator, text_arena.allocator(), addr -| ra_call_offset, true, &symbols) catch continue;
                    \\        var printed = false;
                    \\        for (symbols.items) |sym| {
                    \\            if (sym.source_location) |sl| {
                    \\                if (__zag_panic_map_lookup(@intCast(sl.line))) |e| {
                    \\                    stderr_writer.print("  at {s}:{d}:{d} in {s}\n", .{ e.file, e.zag_line, e.zag_col, e.symbol }) catch {};
                    \\                    __zag_panic_print_source_line(e.file, e.zag_line, e.zag_col);
                    \\                    printed = true;
                    \\                    break;
                    \\                }
                    \\            }
                    \\        }
                    \\        if (!printed) {
                    \\            for (symbols.items) |sym| {
                    \\                if (sym.source_location) |sl| {
                    \\                    stderr_writer.print("  at {s}:{d}:{d} (generated zig)\n", .{ sl.file_name, sl.line, sl.column }) catch {};
                    \\                    printed = true;
                    \\                    break;
                    \\                }
                    \\            }
                    \\        }
                    \\        if (!printed) {
                    \\            stderr_writer.print("  at 0x{x} (unknown)\n", .{addr}) catch {};
                    \\        }
                    \\    }
                    \\    @trap();
                    \\}
                    \\
                );
            if (!self.suppress_panic_override) {
                self.write(
                    \\pub const panic = if (@import("builtin").mode == .Debug)
                    \\    std.debug.FullPanic(__zag_panic_trace)
                    \\else
                    \\    std.debug.FullPanic(std.debug.defaultPanic);
                    \\
                );
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

    pub     fn isIntTypeName(type_name: []const u8) bool {
        // zig int-family type names. `usize` / `isize` are arch-sized
        // ints; `i8..i128` / `u8..u128` are the fixed-width families.
        // `u128`/`i128` (stdlib fnv1a64's wrapping-accumulator type)
        // were added alongside the pure-.zag stdlib batch.
        return std.mem.eql(u8, type_name, "usize") or
            std.mem.eql(u8, type_name, "isize") or
            std.mem.eql(u8, type_name, "i8") or
            std.mem.eql(u8, type_name, "i16") or
            std.mem.eql(u8, type_name, "i32") or
            std.mem.eql(u8, type_name, "i64") or
            std.mem.eql(u8, type_name, "i128") or
            std.mem.eql(u8, type_name, "u8") or
            std.mem.eql(u8, type_name, "u16") or
            std.mem.eql(u8, type_name, "u32") or
            std.mem.eql(u8, type_name, "u64") or
            std.mem.eql(u8, type_name, "u128");
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

    /// Generic-struct lookup: returns true iff `base` is a tracked
    /// generic struct name (a struct decl with type params). Used by
    /// the `.method_call` arm to route instance/static calls on
    /// generic types to the orphan free fns. Same O(N) contract as
    /// `isTrackedTrait`.
    pub     fn isGenericStructName(self: *Codegen, base: []const u8) bool {
        if (self.genericStructModulePath(base) != null) return true;
        for (self.generic_struct_names[0..self.generic_struct_count]) |gs| {
            if (std.mem.eql(u8, gs, base)) return true;
        }
        return false;
    }

    /// Stdlib generic → module path: the orphan free fns for
    /// MATERIALIZED stdlib generics (`ArrayList_*`) live in
    /// lib/std/collections.zag, not the user module — call sites
    /// must route through `@import("lib/std/collections.zag").Name`.
    /// User-defined generic structs (declared in the module being
    /// generated) return null — their free fns are same-module.
    /// Keep in sync with generic struct decls added to lib/std/.
    pub     fn genericStructModulePath(self: *Codegen, base: []const u8) ?[]const u8 {
        // Paths are the MATERIALIZED module names — the imports loop
        // emits `@import("std/collections/array_list.zig")` (the
        // build/gen/std/ tree), NOT the source lib/std/ paths.
        const KNOWN = &[_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "ArrayList", .path = "std/collections/array_list.zig" },
            .{ .name = "HashMap", .path = "std/collections/hash_map.zig" },
        };
        for (KNOWN) |k| {
            if (std.mem.eql(u8, k.name, base)) {
                // Self-module case: the per-type file's own codegen
                // instance (source_path ends with the KNOWN source
                // path) must call its free fns BARE — the inline
                // @import("std/collections/array_list.zig") inside
                // build/gen/std/collections/array_list.zig would
                // resolve relative to itself and fail to load.
                const src_name = if (std.mem.eql(u8, base, "ArrayList")) "array_list.zag" else "hash_map.zag";
                if (self.source_path.len > 0 and std.mem.endsWith(u8, self.source_path, src_name)) {
                    return null;
                }
                // Materialized std module calling a generic from
                // another std dir: the path is relative to the
                // generated file's dir — strip the `std/` module-root
                // prefix (the k.path form is for the USER module at
                // build/gen/main.zig), and prepend `../` when the
                // caller lives in a nested dir (std.strings.slices
                // → std.collections).
                if (self.import_std_base.len == 0 and self.source_path.len > 0) {
                    const rel_to_std = if (std.mem.startsWith(u8, k.path, "std/"))
                        k.path["std/".len..]
                    else
                        k.path;
                    const src_dir_end = std.mem.lastIndexOfScalar(u8, self.source_path, '/');
                    var nested = false;
                    if (src_dir_end) |sde| {
                        nested = sde > "lib/std/".len;
                    }
                    if (nested) {
                        if (std_module_rel_scratch.len >= 3 + rel_to_std.len) {
                            std_module_rel_scratch[0] = '.';
                            std_module_rel_scratch[1] = '.';
                            std_module_rel_scratch[2] = '/';
                            @memcpy(std_module_rel_scratch[3..][0..rel_to_std.len], rel_to_std);
                            return std_module_rel_scratch[0 .. 3 + rel_to_std.len];
                        }
                    } else {
                        return rel_to_std;
                    }
                }
                return k.path;
            }
        }
        return null;
    }

    /// Generic-instance receiver type check: `list: Box(i32)` tracks
    /// the source type text `Box(i32)`. Returns a small struct when
    /// the text has the `<GenericBase>(...)` shape AND the base is a
    /// tracked generic struct; null otherwise. `*`-prefixed forms
    /// (`self: *Box(T)` — the receiver of the orphan free fns) strip
    /// the leading `*`/`*const` first and record `is_pointer` so the
    /// call-site dispatch knows whether to emit `&receiver` (a value
    /// receiver needs address-of; an already-pointer receiver passes
    /// verbatim).
    pub const GenericInstance = struct {
        base: []const u8,
        args: []const []const u8,
        is_pointer: bool,
    };

    pub     fn genericInstanceOfTypeText(self: *Codegen, type_text: []const u8) ?GenericInstance {
        var t = type_text;
        var is_pointer = false;
        if (std.mem.startsWith(u8, t, "*const ")) {
            t = t["*const ".len..];
            is_pointer = true;
        } else if (std.mem.startsWith(u8, t, "*")) {
            t = t["*".len..];
            is_pointer = true;
        }
        // Turbofish normalization: source annotations inside generic
        // impl receivers use the `<...>` form (`self: *ArrayList<T>`),
        // while binding annotations use the paren form
        // (`list: ArrayList(i32)`). Normalize the first `<...>` segment
        // to `(...)` so both parse identically below.
        const lt = std.mem.indexOfScalar(u8, t, '<');
        if (lt != null) {
            const gt = std.mem.indexOfScalar(u8, t[lt.? + 1 ..], '>');
            if (gt != null) {
                const inner = t[lt.? + 1 .. lt.? + 1 + gt.?];
                var nl: usize = 0;
                if (lt.? > 0) {
                    @memcpy(self.generic_norm_buf[0..lt.?], t[0..lt.?]);
                    nl = lt.?;
                }
                self.generic_norm_buf[nl] = '(';
                nl += 1;
                @memcpy(self.generic_norm_buf[nl..][0..inner.len], inner);
                nl += inner.len;
                self.generic_norm_buf[nl] = ')';
                nl += 1;
                const tail_start = lt.? + 1 + gt.? + 1;
                if (tail_start < t.len) {
                    @memcpy(self.generic_norm_buf[nl..][0 .. t.len - tail_start], t[tail_start..]);
                    nl += t.len - tail_start;
                }
                const norm = self.generic_norm_buf[0..nl];
                return self.genericInstanceOfParenText(norm, is_pointer);
            }
        }
        return self.genericInstanceOfParenText(t, is_pointer);
    }

    fn genericInstanceOfParenText(self: *Codegen, t: []const u8, is_pointer: bool) ?GenericInstance {
        const paren = std.mem.indexOfScalar(u8, t, '(');
        if (paren == null or paren.? == 0) return null;
        const base = t[0..paren.?];
        if (!self.isGenericStructName(base)) return null;
        const close = std.mem.lastIndexOfScalar(u8, t, ')');
        if (close == null or close.? < paren.?) return null;
        const inner = t[paren.? + 1 .. close.?];
        var arg_count: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            if (i == inner.len or inner[i] == ',') {
                const part = std.mem.trim(u8, inner[start..i], " ");
                if (part.len > 0 and arg_count < self.generic_args_buf.len) {
                    self.generic_args_buf[arg_count] = part;
                    arg_count += 1;
                }
                start = i + 1;
            }
        }
        return .{
            .base = base,
            .args = self.generic_args_buf[0..arg_count],
            .is_pointer = is_pointer,
        };
    }

    /// Back-compat wrapper: base name only (used where the caller
    /// only needs the generic-struct identity).
    pub     fn genericBaseOfTypeText(self: *Codegen, type_text: []const u8) ?[]const u8 {
        if (self.genericInstanceOfTypeText(type_text)) |gi| return gi.base;
        return null;
    }

    /// Resolve a field's declared type text from a module-local
    /// struct decl: `timers` on `EventLoop` → `ArrayList(TimerEntry)`.
    /// Used by the `.method_call` generic dispatch to route
    /// `self.timers.push(...)` (a member-access receiver whose base
    /// resolves to a generic-typed field) to the orphan free fn.
    pub     fn structFieldType(self: *Codegen, struct_name: []const u8, field_name: []const u8) ?[]const u8 {
        for (self.prog.structs) |sd| {
            if (!std.mem.eql(u8, sd.name, struct_name)) continue;
            for (sd.fields) |f| {
                switch (f.kind) {
                    .named => |nf| {
                        if (std.mem.eql(u8, nf.name, field_name)) return nf.type_text;
                    },
                    .embed => {},
                }
            }
        }
        return null;
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

    /// Diamond disambiguator support (docs/17 §"Diamond Disambiguation"):
    /// walks `prog.traits` for the decl named `trait_name` and returns
    /// true iff one of its `TraitMethodDecl`s is named `method_name`.
    /// Used by `resolveTraitBindings`'s uniqueness check (b): "exactly
    /// one listed trait declares the method → bind to that trait".
    /// Returns false when the trait name is unknown to this program
    /// (the dispatch rule then leaves the slot unfulfilled, surfacing
    /// as a zig compile-error at the vtable registration step).
    pub     fn traitDeclaresMethod(self: *Codegen, trait_name: []const u8, method_name: []const u8) bool {
        for (self.prog.traits) |td| {
            if (std.mem.eql(u8, td.name, trait_name)) {
                for (td.methods) |tm| {
                    if (std.mem.eql(u8, tm.name, method_name)) return true;
                }
                return false;
            }
        }
        return false;
    }

    /// Returns the VTable field name for a trait method. When the
    /// method name is unique within the trait, it returns the name
    /// unchanged. When multiple trait methods share the same name
    /// (overloaded), appends an index suffix `_N` — e.g. `render`
    /// and `render_f64` → `render_0` and `render_1`.
    /// The returned slice points into a static scratch buffer valid
    /// until the next call to this function.
    pub     fn traitMethodVtableName(trait_decl: ast.TraitDecl, method_index: usize) []const u8 {
        if (method_index >= trait_decl.methods.len) return "";
        const method_name = trait_decl.methods[method_index].name;

        var dup_count: usize = 0;
        var my_dup_index: usize = 0;
        for (trait_decl.methods, 0..) |tm, i| {
            if (std.mem.eql(u8, tm.name, method_name)) {
                if (i < method_index) my_dup_index += 1;
                dup_count += 1;
            }
        }
        if (dup_count <= 1) return method_name;

        // Use a thread-local buffer for the suffixed name. Each call
        // overwrites; callers must consume the result before the next
        // call.
        const tls_buf = struct {
            var buf: [128]u8 = undefined;
        };
        @memcpy(tls_buf.buf[0..method_name.len], method_name);
        const suffix = std.fmt.bufPrint(
            tls_buf.buf[method_name.len + 1 .. tls_buf.buf.len],
            "{d}",
            .{my_dup_index},
        ) catch "0";
        tls_buf.buf[method_name.len] = '_';
        const total_len = method_name.len + 1 + suffix.len;
        return tls_buf.buf[0..total_len];
    }

    /// Canonical impl-form dispatch rule (docs/17 §"Implementing"
    /// + §"Diamond Disambiguation"). Resolves the LIST of traits
    /// whose vtables should register `m`'s body. Most methods have
    /// 0 (regular type method) or 1 (normal trait binding) entries;
    /// the shared-body diamond shape returns 2+ — e.g.
    /// `with Drawable (print), Show (print)` resolves `print` to
    /// BOTH `Drawable` and `Show`, emitting one renamed free fn per
    /// trait (`<Target>_<Trait>_<Method>` per entry). Resolution
    /// order mirrors the design spec's per-method rule:
    ///   (0) `m.trait_name` set (legacy `Trait.method` prefix) → a
    ///       singleton list with that trait. Explicit per-method
    ///       binding takes precedence over any block-level `with`
    ///       clause so pre-canonical source keeps round-tripping.
    ///   (a) every `impl.trait_specs[i].preferred_methods` containing
    ///       `m.name` → that spec's trait joins the list. Returns
    ///       multiple entries when the same name is parenthesised
    ///       on several traits (the shared-body diamond).
    ///   (b) no parens match, but `trait_specs` non-empty AND exactly
    ///       one listed trait declares `m.name` → singleton list.
    ///   (c) `trait_specs` empty AND `m.trait_name` null → empty
    ///       list (regular type method, no vtable entry).
    ///   (d) Multiple listed traits declare `m.name` and no parens
    ///       disambiguate → compile error with the disambiguator hint.
    /// The returned slice is owned by `self.trait_binding_buf`
    /// (overwritten on each call — caller must copy or finish with
    /// the slice before the next invocation). Bounded at 8 entries
    /// (v1 surface won't realistically list more than 8 traits on a
    /// single impl block).
    pub     fn resolveTraitBindings(self: *Codegen, impl: *const ast.ImplBlock, m: ast.MethodDecl) []const []const u8 {
        // (0) Explicit `Trait.method` prefix still wins — singleton.
        if (m.trait_name) |tn| {
            self.trait_binding_buf[0] = tn;
            return self.trait_binding_buf[0..1];
        }
        if (impl.trait_specs.len == 0) return self.trait_binding_buf[0..0];

        // (a) Preferred-methods match — collect EVERY listed trait
        // whose parenthesised names contain `m.name`. The shared-body
        // diamond (`with T1 (m), T2 (m)`) yields BOTH entries so
        // codegen emits one renamed free fn per owning trait.
        var count: u32 = 0;
        for (impl.trait_specs) |spec| {
            for (spec.preferred_methods) |pm| {
                if (std.mem.eql(u8, pm, m.name)) {
                    if (count < self.trait_binding_buf.len) {
                        self.trait_binding_buf[count] = spec.name;
                        count += 1;
                    }
                    break; // one match per spec suffices
                }
            }
        }
        if (count > 0) return self.trait_binding_buf[0..count];

        // (b) Uniqueness across listed traits: count how many of the
        // listed traits declare a method named `m.name`.
        var match: ?[]const u8 = null;
        var match_count: u32 = 0;
        for (impl.trait_specs) |spec| {
            if (self.traitDeclaresMethod(spec.name, m.name)) {
                match = spec.name;
                match_count += 1;
            }
        }
        if (match_count == 1) {
            self.trait_binding_buf[0] = match.?;
            return self.trait_binding_buf[0..1];
        }
        if (match_count == 0) return self.trait_binding_buf[0..0]; // method not declared by any listed trait → regular method

        // (d) Ambiguous: multiple listed traits declare this method
        // and no parenthesised name picked one. Check for a Raku-style
        // resolving method pattern: if OTHER methods in the same impl
        // block have the same name with `trait_name` set for ALL
        // conflicting traits, this unqualified method is a resolver
        // — a regular type method, no vtable entry. It dispatches
        // to the preferred trait at runtime with zero overhead.
        //
        // If not ALL conflicts are covered, surface a compile-error.
        var conflicts: [8][]const u8 = undefined;
        var conflict_count: u32 = 0;
        for (impl.trait_specs) |spec| {
            if (self.traitDeclaresMethod(spec.name, m.name)) {
                if (conflict_count < conflicts.len) {
                    conflicts[conflict_count] = spec.name;
                    conflict_count += 1;
                }
            }
        }
        if (conflict_count < 2) return self.trait_binding_buf[0..0];

        // Scan other methods in the same impl block for qualified
        // counterparts covering the conflicting traits.
        var covered: [8]bool = [_]bool{false} ** 8;
        var covered_count: u32 = 0;
        for (impl.methods) |other| {
            if (other.trait_name == null) continue;
            if (!std.mem.eql(u8, other.name, m.name)) continue;
            for (conflicts[0..conflict_count], 0..) |ct, ci| {
                if (!covered[ci] and std.mem.eql(u8, ct, other.trait_name.?)) {
                    covered[ci] = true;
                    covered_count += 1;
                }
            }
        }
        if (covered_count >= conflict_count) {
            // All conflicting traits are covered by qualified
            // methods — this is a resolver, not a vtable method.
            return self.trait_binding_buf[0..0];
        }

        std.debug.print(
            "error: ambiguous trait binding for method '{s}' on type '{s}' — multiple `with`-listed traits declare it. Add a dot-qualifier, e.g. `Trait1.{s}`, or write a resolving method alongside qualified ones.\n",
            .{ m.name, impl.target_type, m.name },
        );
        std.process.exit(1);
    }

    /// Singleton-handling convenience wrapper for callers that want
    /// the legacy single-trait shape (`?[]const u8` — null when the
    /// method is regular, non-null when it binds to exactly one
    /// trait). The first walk in `generate` uses this to skip
    /// trait-bound methods in the orphan-emit path; the second walk
    /// uses the slice form (`resolveTraitBindings`) so the
    /// shared-body diamond emits per-trait free fns. The wrapper
    /// surfaces the (d) ambiguous path the same way
    /// `resolveTraitBindings` does (compile error + exit).
    pub     fn resolveTraitBinding(self: *Codegen, impl: *const ast.ImplBlock, m: ast.MethodDecl) ?[]const u8 {
        const bindings = self.resolveTraitBindings(impl, m);
        if (bindings.len == 0) return null;
        return bindings[0];
    }

    /// Gap #2 lookup helper: returns the user's named-field list for
    /// the (enum_name, variant_name) pair if a brace-named-field
    /// decl was emitted. Called from the `.enum_variant_ctor` arm
    /// in genExpr to recover the original field names so a ctor
    /// like `Drag(2.0, 3.0)` emits `.{ .x = 2.0, .y = 3.0 }`
    /// (matching the `Drag: struct { x: f64, y: f64 }` declaration
    /// shape, NOT the legacy alphabetical `.{ .a = 2.0, .b = 3.0 }`
    /// which zig 0.16 rejects because the struct has `x, y` fields
    /// — `a` and `b` don't exist). Returns null on miss so the
    /// caller falls back to the paren-positional letter-sequence
    /// emit for union ctors whose variant is paren-positional (or
    /// whose enum wasn't seen yet — future cross-module ctor
    /// resolution is deferred; v1 only handles locally-declared
    /// variants).
    pub     fn lookupVariantFields(
        self: *Codegen,
        enum_name: []const u8,
        variant_name: []const u8,
    ) ?[]const ast.VariantField {
        for (self.variant_fields_buf[0..self.variant_fields_count]) |e| {
            if (std.mem.eql(u8, e.enum_name, enum_name) and
                std.mem.eql(u8, e.variant_name, variant_name))
            {
                return e.fields;
            }
        }
        return null;
    }

    pub     fn lookupVariantFieldsByName(
        self: *Codegen,
        variant_name: []const u8,
    ) ?[]const ast.VariantField {
        // Unqualified-by-name lookup companion for
        // `lookupVariantFields`. Used by the `.enum_variant_ctor`
        // arm in `src/codegen/expr.zig` when `evc.enum_name == null`
        // — i.e. the user wrote `Pos { x: 2.0, y: 3.0 }` without a
        // `Pos.` prefix and we're trying to recover the variant's
        // brace-fields list from the source-side variant_name alone.
        //
        // Returns the brace_fields ONLY when exactly ONE brace-named
        // entry in `variant_fields_buf` has this `variant_name`.
        // Zero OR multiple matches return null so the caller falls
        // through to the legacy positional emit (single-letter
        // `a`/`b`/... naming). For the multi-match case, the legacy
        // emit will be **loudly rejected by zig 0.16** at compile
        // time — the brace-declared variants' payload structs have
        // the user's literal field names (per gap #2's brace emit),
        // not the single-letter alphabet. So `null`-return-on-
        // ambiguity produces a useful diagnostic (\"no field named
        // 'a' in struct\") at the user's union type-instance rather
        // than a silent miscompile emitting `.{ .a = arg }` for a
        // struct that has fields `.x` and `.y`. This is the Option-B
        // collision strategy (designed and validated in gap-closure
        // review): safe-by-default rather than best-effort.
        var match_count: usize = 0;
        var first_match: ?[]const ast.VariantField = null;
        for (self.variant_fields_buf[0..self.variant_fields_count]) |e| {
            if (std.mem.eql(u8, e.variant_name, variant_name)) {
                match_count += 1;
                first_match = e.fields;
                // Early bail: more than one match means we cannot
                // confidently route the unqualified ctor, so skip
                // the entire buf-walk and return null.
                if (match_count > 1) return null;
            }
        }
        if (match_count == 1) return first_match;
        return null;
    }

/// Map a stdlib type name to its preamble equivalent.
/// Returns "" if the type is not available in the preamble.
fn stdlibPreambleName(name: []const u8) []const u8 {
    // v0.1 stdlib migration (hybrid preamble): String/Writer and
    // Display/ErrorExt stay in the inline preamble because of
    // hardcoded coupling in `src/codegen/expr.zig`'s router arms
    // (lines 1598 `__zag_String.withCapacity(...)`, 1603
    // `__zag_Writer.stdOut()`, 1606 `__zag_Writer.stdErr()`) — these
    // site-specific references can't survive a `@import("std/<n>")`
    // migration without router-arm rewiring, deferred to a follow-up
    // commit. Display and ErrorExt stay inline for an additional reason:
    // their declarations reference other stdlib types (`Display.write`
    // takes `*Writer`, `ErrorExt.context` returns `Context`) that would
    // fail to resolve at materialization time without a separate
    // preamble injection per-file.
    //
    // The moved types below rebind to the @imported module's exported
    // types via the hybrid preamble emitted at `generate()`'s
    // imports-loop boundary. Returning a non-empty string here
    // triggers the `const ALIAS = PREAMBLE_NAME;` emit in the imports
    // loop (see `core.zig::generate()` line ~821-829). The pre-
    // migration shape returned "" for these names — the imports loop
    // SKIPPED the alias emit, leaving `pub import std.error.{Error}`
    // silently broken (no usable identifier). The migration fixes
    // that on the moved types.
    if (std.mem.eql(u8, name, "String")) return "__zag_String";
    if (std.mem.eql(u8, name, "Writer")) return "__zag_Writer";
    // std.argv.get (v0.1 Tier-1 migration): `pub import std.argv.{get}`
    // aliases DIRECTLY to the module-level `__zag_argv` global (the
    // fast path in the imports loop emits `const get = __zag_argv;`).
    // This must NOT go through the @import + alias slow path: the
    // materialized std/argv.zig is a separate zig module with its OWN
    // self-contained preamble (use_hybrid = false), so its `__zag_argv`
    // copy is never assigned — genFun's is_main special case captures
    // argv into the USER module's global at main entry. lib/std/argv.zag
    // keeps the reference body for documentation + scaffold parsing,
    // but the binding is preamble-side, mirroring the String/Writer
    // hardcoded-coupling rationale above.
    if (std.mem.eql(u8, name, "get")) return "__zag_argv";
    if (std.mem.eql(u8, name, "Display")) return "";
    if (std.mem.eql(u8, name, "ErrorExt")) return "";
    if (std.mem.eql(u8, name, "Error")) return "__zag_Error";
    if (std.mem.eql(u8, name, "Context")) return "__zag_Context";
    if (std.mem.eql(u8, name, "FmtError")) return "__zag_FmtError";
    if (std.mem.eql(u8, name, "Duration")) return "__zag_Duration";
    if (std.mem.eql(u8, name, "Timer")) return "__zag_Timer";
    if (std.mem.eql(u8, name, "Ordering")) return "__zag_Ordering";
    if (std.mem.eql(u8, name, "Counters")) return "__zag_Counters";
    return "";
}
