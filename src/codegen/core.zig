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
    /// `true` only for `var` bindings — the mutable kind. Method-call
    /// emit consults this before wrapping a receiver's address in
    /// `@constCast`: a `var` binding needs NO cast (its `&` is already
    /// `*T`), and an unconditional cast would hide genuine mutability
    /// errors (`var` + `*const T` receiver). `let`/`const` default to
    /// `false`, matching zig's immutable-by-default semantics.
    is_var: bool = false,
};

/// Comptime-empty Program default for freshly-`init()`ed Codegen
/// instances that never went through `generate()` (the template-
/// literal placeholder codegen in primary.zig's genTemplateLit builds
/// an `args_cg = Codegen.init()` and copies only type_info_buf — its
/// `prog` pointer would otherwise dangle, and any emit path that walks
/// `self.prog.enums` / `self.prog.structs` (e.g. the union-method
/// dispatch helpers) would fault on the garbage pointer. All slices
/// default empty so lookups return "not found" and callers fall
/// through to verbatim emission.
const empty_prog: ast.Program = .{ .functions = &[_]ast.FunDecl{} };

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
    /// Lazily-emitted print fallback: set when a print arg's type is
    /// not statically known (genPrintCall else arm / genTemplateLit
    /// interpolation slot route through `{f}` + `__zag_auto_fmt(...)`).
    /// The helper is appended at the END of generate() — NOT the
    /// preamble — so tests that scan the whole output for
    /// `@TypeOf`/`struct {`/`blk: {`/`pub fn f` substrings, the
    /// 13-helper __zag_posix preamble pin, and the `std.mem.span`
    /// forbidden-substring pin never see it unless a print site
    /// actually needs it. Zig container decls are order-independent,
    /// so the end-of-file helper is reachable from earlier user code.
    used_auto_fmt: bool = false,
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
    prog: *const ast.Program = &empty_prog,
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
    /// Builtin generic-ctor anchor (Option/Result ctor gap): the
    /// expected type at a binding/return site (`let x: Option<i32> = …`,
    /// `return Option.None;`). The `.enum_variant_ctor` emit in
    /// expr.zig reads this to INSTANTIATE the preamble generic —
    /// `Option.Some(21)` → `Option(i32){ .Some = 21 }`. Without the
    /// anchor the qualified form emits `Option{ .Some = 21 }` (a
    /// comptime-fn instantiation zig rejects with "expected type
    /// 'type', found 'fn (comptime type) type'") or `Option.None`
    /// (field access on the fn type). Set around the RHS emit at
    /// binding/return sites; saved/restored around nested emits so
    /// inner bindings don't leak their annotation outward.
    ctor_anchor_buf: [256]u8 = undefined,
    ctor_anchor_len: usize = 0,
    /// True while emitting the RHS of a `const NAME = const { … }`
    /// binding (or nested within its body). The `.const_block` expr
    /// emit (expr.zig) drops the `comptime` keyword in this state —
    /// zig 0.16 rejects "redundant comptime keyword in already
    /// comptime scope" when the block is the initializer of a const
    /// binding. In runtime scope (`let x = const { … }`) the keyword
    /// stays, so the block still evaluates at compile time.
    comptime_scope: bool = false,
    /// Current fn's return-type text (`Option<i32>` etc.), copied at
    /// genFun/genMethod body entry so `return Option.None;` can anchor
    /// the ctor emit on the return type. Zeroed at entry when the fn
    /// has no return annotation.
    fn_ret_type_buf: [128]u8 = undefined,
    fn_ret_type_len: usize = 0,
    /// Per-function counter for labeled blocks (`blk: { ... }`).
    /// Reset to 0 by genFun/genMethod so each fn body has unique
    /// `__blk_0`, `__blk_1`, ... labels (zig rejects duplicate labels).
    ///
    /// NOTE (v0.1 Tier-1 migration): the Phase 0-3 router counters
    /// (argv_counter, env_counter, write_file_counter, mkdir_counter,
    /// exec_counter) have ALL been retired — the remaining routed
    /// dispatches either referenced a module-level global (the
    /// `.argv_get` → `__zag_argv` pairing retired in the v0.5
    /// self-hosting migration — argv resolves through std.posix now)
    /// or emit self-contained
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
    /// EXPR;` into `return .{ .state = 1, .value = EXPR };` so the
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
    /// Interning pool for overload-suffixed method names (`go_0`,
    /// `go_1`, …). traitMethodVtableName / traitMethodVtableNameFull
    /// previously formatted into a SHARED static buffer, so the Nth
    /// call overwrote the buffer the (N-1)th call's return slice
    /// pointed at — two `go` overloads decayed to two `.go_1` vtable
    /// fields ("duplicate struct member name"). internedSuffixName
    /// copies each result into this append-only pool; entries live
    /// for the whole generate() pass, which is all callers need.
    name_pool_buf: [16384]u8 = undefined,
    name_pool_len: usize = 0,

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
    // Unused-param discard pass (docs/manual/18 §"Default Methods" +
    // zig 0.16 unused-parameter hard error): the default-method emit
    // in core.zig and the embed-forwarder emit in decl.zig call
    // `self.markUnusedParamDiscards(...)`; the walker lives alongside
    // the other function-body emitters in decl.zig, so re-export it
    // here (same pattern as genFreeMethod / runEscapeAnalysis above).
    pub const markUnusedParamDiscards = @import("decl.zig").markUnusedParamDiscards;
    pub const methodTakesMutableSelfanyType = @import("expr.zig").methodTakesMutableSelfanyType;
    pub const bindingIsVar = @import("core.zig").bindingIsVar;
    pub const traitMethodVtableNameFull = @import("core.zig").traitMethodVtableNameFull;
    pub const traitMethodVtableName = @import("core.zig").traitMethodVtableName;
    pub const internedSuffixName = @import("core.zig").internedSuffixName;
    pub const genTypeParamsPreamble = @import("decl.zig").genTypeParamsPreamble;
    pub const genBoundsGuards = @import("decl.zig").genBoundsGuards;
    pub const rewriteReceiverType = @import("decl.zig").rewriteReceiverType;
    pub const rewriteSelfToT = @import("decl.zig").rewriteSelfToT;
    pub const generate = @import("core.zig").generate;
    pub const init = @import("core.zig").init;
    pub const isClosureBound = @import("core.zig").isClosureBound;
    pub const isFloatIdentType = @import("core.zig").isFloatIdentType;
    pub const isIntTypeName = @import("core.zig").isIntTypeName;
    pub const isStringishTypeText = @import("core.zig").isStringishTypeText;
    pub const isStringishIdent = @import("core.zig").isStringishIdent;
    pub const binaryHasFloatLeaf = @import("core.zig").binaryHasFloatLeaf;
    pub const isTrackedTrait = @import("core.zig").isTrackedTrait;
    pub const writeCond = @import("stmt.zig").writeCond;
    pub const isGenericStructName = @import("core.zig").isGenericStructName;
    pub const genericStructModulePath = @import("core.zig").genericStructModulePath;
    pub const genericBaseOfTypeText = @import("core.zig").genericBaseOfTypeText;
    pub const genericInstanceOfTypeText = @import("core.zig").genericInstanceOfTypeText;
    pub const genericInstanceOfParenText = @import("core.zig").genericInstanceOfParenText;
    pub const structFieldType = @import("core.zig").structFieldType;
    pub const getSourceTypeName = @import("core.zig").getSourceTypeName;
    // Union orphan-method dispatch (union member calls like
    // `hover.is_action()` / qualified `ClickEvent.is_action(hover)`):
    // union impl methods flatten to module-scope free fns
    // (`<Union>_<Method>` — genFreeMethod, because zig 0.16 rejects
    // methods nested inside `union(enum)`), so the `.method_call` and
    // dotted `.call` arms route through `tryEmitUnionOrphanCall` with
    // the three lookups below. Same re-export pattern as
    // getSourceTypeName / genericStructModulePath above — without
    // these bindings zig compile-errors with `no field or member
    // function named '<name>' in 'codegen.core.Codegen'`.
    pub const unionModulePath = @import("core.zig").unionModulePath;
    pub const isUnionTarget = @import("core.zig").isUnionTarget;
    pub const unionMethodReceiverIsPointer = @import("core.zig").unionMethodReceiverIsPointer;
    pub const tryEmitUnionOrphanCall = @import("core.zig").tryEmitUnionOrphanCall;
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
    // Overload-suffix call-site dispatch (docs/manual/18 §"Overloaded
    // trait methods"): the trait-value call sites in expr.zig consult
    // the trait decl + arity to pick the `_N`-suffixed vtable shim.
    // Re-exported like traitDeclaresMethod above so
    // `self.traitOverloadSuffix(...)` / `self.traitDeclByName(...)` /
    // `self.methodTakesMutableSelf(...)` resolve from expr.zig.
    pub const traitOverloadSuffix = @import("expr.zig").traitOverloadSuffix;
    pub const traitDeclByName = @import("expr.zig").traitDeclByName;
    pub const methodTakesMutableSelf = @import("expr.zig").methodTakesMutableSelf;
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
    // Builtin generic-ctor anchor helpers (Option/Result ctor gap):
    // file-scope functions re-exported so the binding/return sites in
    // stmt.zig (pushCtorAnchor/popCtorAnchor) and the fn-body entries
    // in decl.zig (setFnRetType) can address them via `self.` — same
    // pattern as the getSourceTypeName re-export above. Without the
    // bindings zig compile-errors with `no field or member function
    // named '<name>' in 'codegen.core.Codegen'`.
    pub const setFnRetType = @import("core.zig").setFnRetType;
    pub const pushCtorAnchor = @import("core.zig").pushCtorAnchor;
    pub const popCtorAnchor = @import("core.zig").popCtorAnchor;
    // User-fn precedence (router retirement): bare-call dispatch in
    // expr.zig consults `self.isProgramFn(name)` BEFORE the router
    // table so a program-local fun decl with a router-row name
    // resolves to the user fn. Free-fn in the CORE_INLINE bucket
    // below; re-exported here so `self.` addressing works (same
    // pattern as the re-exports above).
    pub const isProgramFn = @import("core.zig").isProgramFn;

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
            .ctor_anchor_buf = undefined,
            .ctor_anchor_len = 0,
            .comptime_scope = false,
            .fn_ret_type_buf = undefined,
            .fn_ret_type_len = 0,
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
            // `generate`). Pointing fresh instances at the
            // comptime-empty Program is intentional: the template-
            // literal placeholder codegen in primary.zig's
            // genTemplateLit builds an `args_cg = Codegen.init()`
            // (copying only type_info_buf) and routes placeholder
            // exprs through genExpr — any path that walks
            // `self.prog.enums` / `self.prog.structs` (e.g. the
            // union-method dispatch helpers) would fault on an
            // `undefined` pointer. The empty Program's slices are all
            // empty, so lookups return "not found" and emit falls
            // through to verbatim.
            .prog = &empty_prog,
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
            // __zag_argv — RETIRED (v0.5 self-hosting migration): the
            // module-level argv snapshot (zig-0.16 main-signature
            // capture via init.minimal.args.toSlice) moved into
            // lib/std/posix.zag's argv() — a pure-zag /proc/self/
            // cmdline reader, no main-entry capture needed. Reading
            // the name is the regression signal.
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
            \\// __zag_page_alloc / __zag_page_realloc / __zag_page_free —
            \\// RETIRED (v0.5 self-hosting batch): the page-allocator
            \\// wrappers moved into lib/std/mem.zag as pure-zag fns over
            \\// std.posix.mmap/munmap (alloc/alloc_raw/realloc_raw/
            \\// release). Reading any of the three names is the
            \\// regression signal.
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
            \\// RETIRED in the v0.4 pass: __zag_memcpy (byte-copy
            \\// helper, slice-destination form) moved into
            \\// lib/std/mem.zag as a plain .zag fn — an index loop is
            \\// fully expressible in .zag, so the always-emitted
            \\// helper gave way. The slice-destination signature it
            \\// carried (accepted `[]u8` not `[*]u8` because the .zag
            \\// call sites pattern-match on `self.ptr[self.len..]`-
            \\// shaped expressions, which transpile to slice
            \\// expressions) is preserved verbatim in the .zag fn's
            \\// `dst: []u8` param.
            \\// RETIRED with the comptime-type-dispatch batch: the
            \\// __zag_keys_eq / __zag_key_hash generic container key
            \\// helpers moved into lib/std/collections/hash_map.zag as
            \\// pure .zag (type_eq<K, str> comptime dispatch + addr_of
            \\// byte-walk), so str keys get CONTENT semantics and value
            \\// keys get byte semantics without a preamble presence.
            \\
            \\// __zag_str_concat — string `+` operator lowering (docs/11).
            \\// Allocates a fresh page-allocator buffer holding a ++ b;
            \\// the result is `[]u8` (coerces to `str` / `[]const u8` at
            \\// every binding/arg position). Never mutates its operands,
            \\// so string literals (static data) are safe inputs. The
            \\// bench charge keeps std.bench counters honest for
            \\// allocation-reporting examples. Bootstrapping note: this
            \\// helper stays in the preamble because lib/std's own
            \\// allocator (std.mem.alloc_raw over posix.mmap) is written
            \\// in .zag — the concat lowering cannot import it without a
            \\// circular stdlib dependency.
            \\fn __zag_str_concat(a: []const u8, b: []const u8) []u8 {
            \\    const out = std.heap.page_allocator.alloc(u8, a.len + b.len) catch @panic("__zag: str_concat OOM");
            \\    @memcpy(out[0..a.len], a);
            \\    @memcpy(out[a.len..], b);
            \\    __zag_bench_alloc(a.len + b.len);
            \\    return out;
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
            \\// Future(T) — async/await (docs/manual/00-overview.md
            \\// "Zero-cost async"): `async fun` returns `Future(T)`
            \\// wrapping the declared return type; `await EXPR` calls
            \\// the future's drive() (parking until completion) and
            \\// take()s the value.
            \\//
            \\// Suspension contract (v2 self-hosting batch): `state`
            \\// is a futex-addressable done-word — 0 = pending, 1 =
            \\// complete. drive() spin-checks once (the eager
            \\// same-thread path: an awaited async body ran before the
            \\// call, so state is already 1 and NO syscall happens),
            \\// then parks in the kernel via futex WAIT on the word;
            \\// complete() stores 1 with a seq-cst atomic and issues
            \\// futex WAKE, resuming the parked driver. That is real
            \\// suspension — resume-on-completion, no polling, no
            \\// busy-wait — for cross-thread producers; the eager
            \\// same-thread model stays zero-cost.
            \\//
            \\// The methods live on the TYPE (not free preamble fns —
            \\// __zag_future_drive/__zag_future_ready_void retired) so
            \\// the await lowering is `fut.drive()` / `fut.take()`
            \\// regardless of which module's preamble instantiated the
            \\// generic: Future is a per-module preamble type and a
            \\// user-module await on a std module's future (e.g.
            \\// std.time's `after`) would otherwise name the wrong
            \\// module's type in a free-fn signature.
            \\fn Future(comptime T: type) type {
            \\    return struct {
            \\        state: u32 = 0,
            \\        value: ?T = null,
            \\
            \\        pub fn complete(self: *@This()) void {
            \\            @atomicStore(u32, &self.state, 1, .seq_cst);
            \\            _ = std.os.linux.futex_3arg(
            \\                @ptrCast(&self.state),
            \\                .{ .cmd = .WAKE, .private = true },
            \\                1,
            \\            );
            \\        }
            \\
            \\        pub fn drive(self: *@This()) void {
            \\            while (@atomicLoad(u32, &self.state, .seq_cst) == 0) {
            \\                // Park until the word changes (complete()'s
            \\                // store). A spurious wake or a lost race
            \\                // (state flipped between the load and the
            \\                // wait) re-loops; the kernel returns
            \\                // EWOULDBLOCK immediately when the word is no
            \\                // longer 0, so the loop self-corrects.
            \\                _ = std.os.linux.futex_4arg(
            \\                    @ptrCast(&self.state),
            \\                    .{ .cmd = .WAIT, .private = true },
            \\                    0,
            \\                    null,
            \\                );
            \\            }
            \\        }
            \\
            \\        pub fn take(self: *@This()) T {
            \\            // Void futures complete without a payload —
            \\            // their `value` stays undefined and take()
            \\            // fabricates the zero-sized payload comptime-
            \\            // statically (reading the undefined optional
            \\            // would be UB).
            \\            if (T == void) return {};
            \\            return self.value.?;
            \\        }
            \\    };
            \\}
            \\
            \\fn __zag_thread_tramp(payload: usize) callconv(.c) u8 {
            \\    // Thread entry ABI glue (std.concurrent.thread). The
            \\    // kernel starts the child on THIS trampoline with the
            \\    // control-page address as its sole argument (zig's clone
            \\    // trampoline pops it into rdi and `call`s the entry); the
            \\    // control page's slot [1] holds the user body as a ZIG-
            \\    // convention fn pointer — the one convention this glue
            \\    // exists for, since zag's auto-convention fns cannot cast
            \\    // to callconv(.c) pointers ("calling convention 'auto'
            \\    // cannot cast into calling convention 'x86_64_sysv'").
            \\    // Returning the u8 status lets zig's clone asm SYS_exit the
            \\    // thread with it. The child's ctid word is NOT touched
            \\    // here — the kernel clears+wakes it on exit
            \\    // (CLONE_CHILD_CLEARTID), which is what join parks on.
            \\    // Locals are __zag_-prefixed: the trampoline is module-
            \\    // scope glue in every generated file, and a bare local
            \\    // name here (e.g. `const body`) would collide with a
            \\    // user fn of the same name (zig 0.16's strict-shadow
            \\    // check rejects "local constant shadows declaration").
            \\    const tramp_words: [*]usize = @ptrFromInt(payload);
            \\    const tramp_body: *const fn (usize) void = @ptrFromInt(tramp_words[1]);
            \\    tramp_body(tramp_words[2]);
            \\    return 0;
            \\}
            \\fn __zag_thread_start(payload: usize, flags: u32, stack: usize, ptid: *i32, ctid: *i32) usize {
            \\    // Drives zig's clone wrapper with the trampoline above as
            \\    // the entry — the func MUST be a compile-time-known zig fn
            \\    // here (the raw sys_clone takes no function argument; the
            \\    // child resumes at the wrapper's asm continuation, which
            \\    // pops func/arg from the stack this wrapper sets up).
            \\    // tls = 0 (CLONE_SETTLS is not in the spawn flag mask).
            \\    return std.os.linux.clone(__zag_thread_tramp, stack, flags, payload, ptid, 0, ctid);
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
            \\// __zag_format_val — RETIRED (self-hosting batch): had zero
            \\// remaining call sites once std.json moved to std.fmt's
            \\// pure-zag format_f64 and print/template args settled on
            \\// __zag_auto_fmt/{any} paths. Deleted; reading the name is
            \\// the regression signal.
            \\// __zag_atof / __zag_ftoa — RETIRED into lib/std/fmt.zag as
            \\// pure .zag fns (parse_f64 / format_f64) once float<->int
            \\// casts (`f as u64` -> @as(T, @intFromFloat(v))) lowered.
            \\// std.json routes through the std.fmt imports now; reading
            \\// the retired names is the regression signal.

            \\// __zag_nanosleep_ms — RETIRED into lib/std/time.zag as a
            \\// pure .zag fn (sleep_us via posix.nanosleep's raw syscall
            \\// facade) once std.async's loop imported it. The ms→{sec,
            \\// nsec} decomposition is plain zag arithmetic; reading the
            \\// retired name in lib/std/ is the regression signal.
\\// __zag_posix family — RETIRED (v0.3 + v0.4): the twelve
             \\// raw syscall wrappers (__zag_openat / __zag_read /
             \\// __zag_write / __zag_close / __zag_mkdirat /
             \\// __zag_getdents64 / __zag_clock_gettime / __zag_getcwd /
             \\// __zag_getenv / __zag_exit / __zag_posix_spawn /
             \\// __zag_waitpid) moved into lib/std/posix.zag as plain
             \\// .zag fns once bitcast / enum_from_int builtins +
             \\// module-level `var` landed (__zag_posix_spawn and
             \\// __zag_waitpid were dead router-era leftovers, dropped
             \\// outright). The v0.4 pass retired the LAST resident,
             \\// __zag_process_spawn, into posix.zag's spawn — a raw
             \\// fork/execve/waitpid path that needs neither
             \\// std.process.spawn's anonymous SpawnOptions literal nor
             \\// the term-union .exited switch the old zig helper
             \\// existed for. The posix family is now COMPLETELY out of
             \\// the preamble; lib/std/posix.zag owns every raw syscall.
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
                                // Compare against the std-root-RELATIVE
                                // caller dir: resolveStdImport paths are
                                // root-relative ("lib/std/posix.zag")
                                // while source_path is the resolved
                                // (possibly absolute, ZAG_HOME-rooted)
                                // stdlib path — a direct prefix test
                                // between the two never matches for
                                // absolute roots and wrongly emits
                                // "../posix.zig" for same-dir imports
                                // (surfaced by the v0.3 std-to-std
                                // imports). `lastIndexOf("lib/std")`
                                // finds the root marker in both forms.
                                const src_dir = self.source_path[0..sde];
                                var root_rel: []const u8 = src_dir;
                                if (std.mem.lastIndexOf(u8, src_dir, "lib/std")) |root_at| {
                                    if (root_at == 0 or src_dir[root_at - 1] == '/') {
                                        root_rel = src_dir[root_at..];
                                    }
                                }
                                if (std.mem.startsWith(u8, resolved_path, root_rel) and
                                    resolved_path.len > root_rel.len and resolved_path[root_rel.len] == '/')
                                {
                                    // Same-residence (or sibling
                                    // top-level) module: the caller's
                                    // dir is a prefix of the target, so
                                    // the remainder is root-relative —
                                    // correct for BOTH relative
                                    // ("lib/std/…") and absolute
                                    // (ZAG_HOME) stdlib roots.
                                    emit_rel = resolved_path[root_rel.len + 1 ..];
                                } else if (std_module_rel_scratch.len >= 3 + rel_path.len) {
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
                                    std_module_rel_scratch[0] = '.';
                                    std_module_rel_scratch[1] = '.';
                                    std_module_rel_scratch[2] = '/';
                                    @memcpy(std_module_rel_scratch[3..][0..rel_path.len], rel_path);
                                    emit_rel = std_module_rel_scratch[0 .. 3 + rel_path.len];
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
                    // (`selectors.len == 0`) are expanded at PARSE
                    // time (expandWholeModuleImport in
                    // src/parser/decl.zig): the target module is
                    // sub-parsed and its top-level decls synthesized
                    // into selectors, so by the time codegen runs
                    // every import has selectors and this pass binds
                    // all of them. (Historically whole-module imports
                    // reached here unexpanded and bound nothing; the
                    // parser-side expansion replaced that shape —
                    // see the expandWholeModuleImport docblock for
                    // the why-at-parse-time rationale.)
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
        // Phase 3 trait-cast: populate `tracked_trait_names` from
        // `prog.traits` BEFORE any decl body emits — this includes the
        // struct-decl loop below, whose nested method bodies can
        // contain `self.Trait.method()` resolver dispatches (docs/18
        // §"Resolving methods"): `genStructDecl` runs while
        // `genExpr` still walks those bodies, and the dispatch arm in
        // `genExpr` keys off `isTrackedTrait`. Populating after the
        // struct loop left the set empty during method-body emission,
        // so resolver calls fell through to the verbatim emit and zig
        // rejected them with "no field named '<Trait>'". The populate
        // only records source-decl names into a plain buffer — order-
        // independent w.r.t. the struct/impl broadcasting itself.
        for (prog.traits) |td| {
            if (self.tracked_trait_count < self.tracked_trait_names.len) {
                self.tracked_trait_names[self.tracked_trait_count] = td.name;
                self.tracked_trait_count += 1;
            }
        }
        for (prog.structs) |sd| {
            if (matched_count < matched_targets_buf.len and sd.type_params.len == 0) {
                matched_targets_buf[matched_count] = sd.name;
                matched_count += 1;
            }
            self.genStructDecl(sd, prog.impls);
        }
        // (trait-name populate moved above the struct loop — see the
        // resolver-dispatch comment there; this space intentionally
        // left to keep the broadcast ordering comment below intact.)

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
                const vtable_name = self.traitMethodVtableName(td, tmi);
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
                // Unused-param discard pass (docs/manual/18 §"Default
                // Methods"): the *anyopaque receiver shim and any
                // body-unreferenced user params need `_ = name;`
                // discards or zig 0.16 hard-errors on the unused
                // parameter. Same conservative walk as genFreeMethod's.
                self.markUnusedParamDiscards(tm.params, tm.body.?);
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
                                const vfn = self.traitMethodVtableName(td1, tmi1);
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
            // Defensive default BEFORE the trait-decl walk: an impl
            // whose trait name doesn't match any declared trait (or a
            // registration bucket whose decl emit never ran) would
            // otherwise hand genTraitRegistration UNDEFINED slices —
            // write() on a garbage slice is UB/integer-overflow. The
            // walk below overrides entries with the `_N`-suffixed
            // vtable names when the decl matches.
            for (trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count], 0..) |im, ii| {
                method_field_buf[ii] = im.name;
            }
            // Matched trait decl (for the unfulfilled-slot pass in
            // genTraitRegistration) — nullable because a registration
            // bucket can reference a trait whose decl emit didn't run
            // (defensive; resolveTraitBindings only binds to declared
            // traits, so this is a can't-happen guard).
            var matched_trait: ?*const ast.TraitDecl = null;
            for (prog.traits) |*td| {
                if (!std.mem.eql(u8, td.name, trait_reg_buf[ri].trait)) continue;
                matched_trait = @constCast(td);
                for (td.methods, 0..) |tm, tmi| {
                    if (tm.body == null) continue;
                    var already_impl = false;
                    for (trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count]) |im| {
                        // baseMethodNameOf: bucket names carry the `_N`
                        // overload suffix; decl list is bare. Compare
                        // base + arity (same contract as the field-name
                        // walk below).
                        if (im.params.len == tm.params.len and
                            std.mem.eql(u8, baseMethodNameOf(im.name), tm.name))
                        {
                            already_impl = true;
                            break;
                        }
                    }
                    if (!already_impl and default_count < default_buf.len) {
                        default_buf[default_count] = tm.name;
                        default_field_buf[default_count] = self.traitMethodVtableName(td.*, tmi);
                        default_count += 1;
                    }
                }
                // Compute vtable field names for impl-provided methods
                for (trait_reg_buf[ri].methods[0..trait_reg_buf[ri].method_count], 0..) |im, ii| {
                    var found = false;
                    for (td.methods, 0..) |tm, tmi| {
                        // Overload-suffix compare (mirrors genTraitRegis-
                        // tration's baseMethodName): the bucket stores
                        // the SUFFIXED name (`render_1`); the decl list
                        // carries the bare spelling (`render`). Match on
                        // base name + arity so each overload maps to its
                        // OWN decl slot — the old exact-equal compare
                        // matched BOTH buckets to the LAST same-name decl
                        // and emitted duplicate vtable fields.
                        if (im.params.len == tm.params.len and
                            std.mem.eql(u8, baseMethodNameOf(im.name), tm.name))
                        {
                            method_field_buf[ii] = self.traitMethodVtableName(td.*, tmi);
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
                if (matched_trait) |mtd| mtd.methods else &[_]ast.TraitMethodDecl{},
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
                    \\    // v0.3 syscall-FFI migration: the __zag_posix
                    \\    // helpers retired into lib/std/posix.zag, so the
                    \\    // source-line printer calls the syscalls directly
                    \\    // (zig-side literal: `.{}` is the all-default O
                    \\    // flags = O_RDONLY; @bitCast folds the usize→isize
                    \\    // errno convention).
                    \\    const fd_raw = std.os.linux.openat(std.posix.AT.FDCWD, @as([*:0]const u8, @ptrCast(&path_z[0])), .{}, 0);
                    \\    if ((fd_raw & 0x8000000000000000) != 0) return;
                    \\    const fd: i32 = @as(i32, @intCast(fd_raw));
                    \\    defer _ = std.os.linux.close(fd);
                    \\    var buf: [8192]u8 = undefined;
                    \\    var total: usize = 0;
                    \\    while (total < buf.len) {
                    \\        const n_signed = @as(isize, @bitCast(std.os.linux.read(fd, buf[total..].ptr, buf.len - total)));
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

        // __zag_auto_fmt family — emitted LAZILY at the end of
        // generate() rather than in the always-on preamble. Only
        // programs whose print args have a statically-unresolvable
        // type (function returns, method results, unannotated
        // bindings, cross-module values) set `used_auto_fmt`; the
        // preamble stays byte-identical for everything else, which
        // keeps whole-output scans in the test suite (the 13-helper
        // __zag_posix pin, the @TypeOf / struct { / blk: { / pub fn f
        // absence pins, and the std.mem.span forbidden-substring pin)
        // green. Zig container-level decls are order-independent, so
        // the end-of-file helper is reachable from earlier user code.
        //
        // The wrapper's format() comptime-inspects the VALUE's runtime
        // type: the byte-slice family ([]const u8 / str, []u8, string
        // literals as *const [N:0]u8, [:0]const u8, sentinel many-ptrs,
        // ?str optionals, and the pointer forms *[]const u8 / *?[]const
        // u8) prints as text via writeAll; everything else
        // falls back to `{any}` — byte-identical to the pre-gap output
        // for scalars/structs/unions. Closes the gap where a string
        // whose type wasn't statically known printed as a byte list
        // (`{ 104, 101, 108, 108, 111 }`).
        if (self.used_auto_fmt) {
            self.write(
                \\fn __zag_auto_fmt(value: anytype) __zag_AutoFmt(@TypeOf(value)) {
                \\    return .{ .value = value };
                \\}
                \\fn __zag_AutoFmt(comptime T: type) type {
                \\    return struct {
                \\        value: T,
                \\        pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
                \\            const TT = @TypeOf(self.value);
                \\            // Optional-of-byte-slice (?str): unwrap, text or "" for null.
                \\            if (@typeInfo(TT) == .optional) {
                \\                const child = @typeInfo(TT).optional.child;
                \\                if (comptime __zag_is_byte_slice(child)) {
                \\                    if (self.value) |v| return w.writeAll(__zag_as_str(v));
                \\                    return w.writeAll("");
                \\                }
                \\            }
                \\            // Display dispatch (self-hosting batch): when the
                \\            // VALUE's type declares `pub fun format(self) -> str`
                \\            // — the zag-side Display impl convention, emitted as a
                \\            // plain nested fn by the struct impl walker — route to
                \\            // it INSTEAD of the raw `{any}` dump; the returned text is
                \\            // written verbatim. This makes
                \\            // `print("{p}\n")` on a Display-impl'ing struct render
                \\            // the user's format body. The @hasDecl guard keeps
                \\            // non-Display types on the byte-identical `{any}` path.
                \\            if (comptime @typeInfo(TT) == .@"struct") {
                \\                if (comptime @hasDecl(TT, "format")) {
                \\                    try w.writeAll(self.value.format());
                \\                    return;
                \\                }
                \\            }
                \\            if (comptime !__zag_is_byte_slice(TT)) {
                \\                return w.print("{any}", .{self.value});
                \\            }
                \\            return w.writeAll(__zag_as_str(self.value));
                \\        }
                \\    };
                \\}
                \\fn __zag_is_byte_slice(comptime T: type) bool {
                \\    return switch (@typeInfo(T)) {
                \\        .optional => __zag_is_byte_slice(@typeInfo(T).optional.child),
                \\        .pointer => |info| switch (info.size) {
                \\            .slice => info.child == u8,
                \\            .one => blk: {
                \\                const child = info.child;
                \\                if (child == u8) break :blk true;
                \\                if (@typeInfo(child) == .array) {
                \\                    const ai = @typeInfo(child).array;
                \\                    break :blk ai.child == u8;
                \\                }
                \\                // Pointer-to-byte-slice forms: the pointee is itself
                \\                // a slice (*[]const u8) or an optional of a slice
                \\                // (*?[]const u8) — recurse on the pointee shape.
                \\                if (@typeInfo(child) == .optional) break :blk __zag_is_byte_slice(@typeInfo(child).optional.child);
                \\                if (@typeInfo(child) == .pointer) {
                \\                    const ci = @typeInfo(child).pointer;
                \\                    if (ci.size == .slice) break :blk ci.child == u8;
                \\                }
                \\                break :blk false;
                \\            },
                \\            .many, .c => info.child == u8 and info.sentinel_ptr != null,
                \\        },
                \\        else => false,
                \\    };
                \\}
                \\fn __zag_as_str(value: anytype) []const u8 {
                \\    const T = @TypeOf(value);
                \\    switch (@typeInfo(T)) {
                \\        .optional => return if (value) |v| __zag_as_str(v) else "",
                \\        .pointer => |info| switch (info.size) {
                \\            .slice => return value,
                \\            .one => {
                \\                const child = info.child;
                \\                if (child == u8) return value[0..1];
                \\                // *[]const u8 — deref to the slice.
                \\                if (@typeInfo(child) == .pointer and @typeInfo(child).pointer.size == .slice) return value.*;
                \\                // *?[]const u8 — deref, then unwrap the optional.
                \\                if (@typeInfo(child) == .optional) {
                \\                    return if (value.*) |v| __zag_as_str(v) else "";
                \\                }
                \\                return value;
                \\            },
                \\            .many, .c => return std.mem.span(value),
                \\        },
                \\        else => return value,
                \\    }
                \\}
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

    /// Byte-slice type predicate for the string-`+` concat dispatch:
    /// true for `str` and any `[]const u8` / `[]u8` spelling. Used by
    /// the `.binary` add path to decide between `__zag_str_concat`
    /// lowering and the plain numeric emit. The raw-pointer many-
    /// item form `[*]u8` is intentionally EXCLUDED (no len — not a
    /// string). Cheap scan, no allocation: slices pass verbatim,
    /// everything else fails fast on byte 1.
    pub     fn isStringishTypeText(type_name: []const u8) bool {
        if (std.mem.eql(u8, type_name, "str")) return true;
        if (type_name.len < 2 or type_name[0] != '[') return false;
        if (type_name[1] != ']') return false;
        // `[]u8` vs `[]const u8`: the element type after `[]` must
        // start with `u8` (covers `[]u8`, `[]const u8`;
        // `[]const u8`'s element scan starts at `const u8`).
        const elem = type_name[2..];
        if (std.mem.startsWith(u8, elem, "const u8")) return true;
        return std.mem.eql(u8, elem, "u8");
    }

    /// Ident convenience wrapper: looks the binding up in the tracked
    /// typed-binding table, then applies isStringishTypeText.
    pub     fn isStringishIdent(self: *Codegen, name: []const u8) bool {
        if (self.getSourceTypeName(name)) |tn| {
            return isStringishTypeText(tn);
        }
        return false;
    }

    /// Leaf scan for float-typed operands under a cast (float→int
    /// lowering): true when any ident leaf in the binary tree carries
    /// a tracked float type. Used to route `f2 - f1 as u64` to
    /// `@intFromFloat` while keeping int arithmetic (`d - '0'`, the
    /// digit-cast shape) on the `@intCast` path. Untracked leaves
    /// (comptime literals, params absent from the binding table)
    /// conservatively report false — zig then surfaces the mismatch
    /// at compile time if the guess was wrong, so no silent
    /// truncation can slip through.
    pub     fn binaryHasFloatLeaf(self: *Codegen, b: ast.Expr.BinaryExpr) bool {
        switch (b.lhs.payload) {
            .ident => |n| {
                if (self.getSourceTypeName(n)) |tn| {
                    if (isFloatTypeName(tn)) return true;
                }
            },
            .binary => |ib| {
                if (self.binaryHasFloatLeaf(ib)) return true;
            },
            else => {},
        }
        switch (b.rhs.payload) {
            .ident => |n| {
                if (self.getSourceTypeName(n)) |tn| {
                    if (isFloatTypeName(tn)) return true;
                }
            },
            .binary => |ib| {
                if (self.binaryHasFloatLeaf(ib)) return true;
            },
            else => {},
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
        // were added alongside the pure-.zag stdlib batch. The
        // Log2Int widths `u4`/`u5`/`u6`/`u7` (shift-amount types for
        // u16/u32/u64/u128 operands — zig 0.16 requires Log2Int shift
        // slots) were added for hash.zag's `rotr(x: u32, n: u6)` whose
        // `(n as u5)` / `((32 - n) as u5)` casts must route through
        // the `@as(T, @intCast(v))` narrowing carve-out.
        return std.mem.eql(u8, type_name, "usize") or
            std.mem.eql(u8, type_name, "isize") or
            std.mem.eql(u8, type_name, "i8") or
            std.mem.eql(u8, type_name, "i16") or
            std.mem.eql(u8, type_name, "i32") or
            std.mem.eql(u8, type_name, "i64") or
            std.mem.eql(u8, type_name, "i128") or
            std.mem.eql(u8, type_name, "u4") or
            std.mem.eql(u8, type_name, "u5") or
            std.mem.eql(u8, type_name, "u6") or
            std.mem.eql(u8, type_name, "u7") or
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

    /// User-fn precedence (bare-name resolution order, docs/23
    /// §"Bare-name resolution order"): true iff `name` is a top-level
    /// fun decl in the program being generated. The bare-call dispatch
    /// chain consults this BEFORE `builtins.lookup` so a program-local
    /// fn with a router-row name (`assert`, `type_name`, …) resolves
    /// to the USER fn — emitting the verbatim call — instead of being
    /// silently hijacked by the router's inline zig emit. This is
    /// what lets stdlib modules written in zag define functions with
    /// builtin-sounding names.
    ///
    /// Imported aliases deliberately stay BELOW the router: the
    /// atomic primitives (load/store/fetch_add/compare_exchange) are
    /// compiler intrinsics whose importable module bodies are dummies
    /// (see lib/std/concurrent/atomic.zag) — a program that imports
    /// them must keep getting the hardware emit, not a call to the
    /// dummy body. Program-local decls are the one surface that can
    /// meaningfully outrank the router (the author opted into the
    /// name in the same file that gets compiled).
    pub     fn isProgramFn(self: *Codegen, name: []const u8) bool {
        for (self.prog.functions) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
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
                        // Root-agnostic depth test: nested = the
                        // caller's dir is not the stdlib root dir.
                        // The old `sde > "lib/std/".len` fired for
                        // EVERY file under an absolute (ZAG_HOME)
                        // root, wrongly ../-prefixing top-level
                        // module paths.
                        const src_dir = self.source_path[0..sde];
                        nested = !(std.mem.eql(u8, src_dir, "lib/std") or
                            std.mem.endsWith(u8, src_dir, "/lib/std"));
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

    /// stdlib union → materialized module path (mirror of
    /// `genericStructModulePath`): the orphan free fns for
    /// MATERIALIZED stdlib unions (`Json_get`) live in
    /// lib/std/json.zag, not the user module — call sites must route
    /// through `@import("std/json.zig").Json_get(...)`. User-defined
    /// unions (declared in the module being generated) return null —
    /// their free fns are same-module. Keep in sync with union decls
    /// added to lib/std/ (self-module detection below keys off the
    /// source file name).
    pub     fn unionModulePath(self: *Codegen, name: []const u8) ?[]const u8 {
        // Paths are the MATERIALIZED module names — the imports loop
        // emits `@import("std/json.zig")` (the build/gen/std/ tree),
        // NOT the source lib/std/ paths.
        const KNOWN = &[_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "Json", .path = "std/json.zig" },
        };
        for (KNOWN) |k| {
            if (!std.mem.eql(u8, k.name, name)) continue;
            // Self-module case: lib/std/json.zag's own codegen instance
            // (source_path == the stdlib source path) calls its free fns
            // BARE — an inline @import("std/json.zig") inside
            // build/gen/std/json.zig would resolve relative to itself
            // and fail to load. The match is the FULL stdlib source
            // path, not a bare suffix: examples/stdlib/json.zag also
            // ends with "json.zag" and would otherwise be mistaken for
            // the stdlib module, silently dropping the dispatch
            // (surfaced by examples/stdlib/json.zag's `jv.get(...)`).
            if (self.source_path.len > 0 and std.mem.endsWith(u8, self.source_path, "lib/std/json.zag")) {
                return null;
            }
            // Materialized std module calling a union from another std
            // dir: the path is relative to the generated file's dir —
            // strip the `std/` module-root prefix (the k.path form is
            // for the USER module at build/gen/main.zig), and prepend
            // `../` when the caller lives in a nested dir.
            if (self.import_std_base.len == 0 and self.source_path.len > 0) {
                const rel_to_std = if (std.mem.startsWith(u8, k.path, "std/"))
                    k.path["std/".len..]
                else
                    k.path;
                const src_dir_end = std.mem.lastIndexOfScalar(u8, self.source_path, '/');
                var nested = false;
                if (src_dir_end) |sde| {
                    // Root-agnostic depth test (same rationale as the
                    // generic-dispatch twin above — the `sde > 7`
                    // form misfired on absolute ZAG_HOME roots).
                    const src_dir = self.source_path[0..sde];
                    nested = !(std.mem.eql(u8, src_dir, "lib/std") or
                        std.mem.endsWith(u8, src_dir, "/lib/std"));
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
        return null;
    }

    /// True when `name` is a UNION — a payload-bearing or backed enum
    /// (the container shapes whose impl methods flatten to orphan free
    /// fns) — either declared in the current module or known from the
    /// materialized stdlib. BARE enums return false: their methods
    /// stay nested inside the zig `enum` container and zig's native
    /// member-call sugar handles them, so the orphan rewrite must not
    /// fire. Mirrors the generate() gate that records only bare enums
    /// in matched_targets_buf (gap #3 dispatch-side).
    pub     fn isUnionTarget(self: *Codegen, name: []const u8) bool {
        // Module-local decls win over the KNOWN stdlib-union table: a
        // user module declaring its own `struct Json` / `union Json`
        // must NOT be hijacked into the stdlib orphan path. A local
        // struct's methods stay nested and dispatch natively (verbatim
        // `x.get(...)` compiles — struct methods are NOT flattened),
        // and a local union's impl blocks are resolved from
        // prog.impls by unionMethodReceiverIsPointer. The KNOWN table
        // is consulted only for names with NO module-local decl.
        for (self.prog.structs) |sd| {
            if (std.mem.eql(u8, sd.name, name)) return false;
        }
        for (self.prog.enums) |ed| {
            if (!std.mem.eql(u8, ed.name, name)) continue;
            if (ed.backing_type != null) return true;
            for (ed.variants) |v| {
                if (v.payload_type != null or v.fields.len > 0) return true;
            }
            return false; // bare enum — nested methods, native dispatch
        }
        return self.unionModulePath(name) != null;
    }

    /// Union orphan-method receiver-shape lookup: returns non-null
    /// when `method_name` resolves to a non-trait-bound method on
    /// `union_name`'s impl block; the returned bool is true when the
    /// method's receiver param is a pointer (`self: *Json`), which the
    /// call-site emit uses to decide whether to pass the receiver by
    /// address (`&`). Same-module unions walk `prog.impls`; materialized
    /// stdlib unions (whose impls aren't visible to the user module)
    /// consult a KNOWN method table that must stay in sync with the
    /// impl blocks in lib/std/. Trait-bound methods emit under the
    /// renamed `<Target>_<Trait>_<Method>` shape (resolveTraitBinding)
    /// and return null so the verbatim fallback stays in charge.
    pub     fn unionMethodReceiverIsPointer(self: *Codegen, union_name: []const u8, method_name: []const u8) ?bool {
        // Module-local impls win (mirror of isUnionTarget's local-first
        // rule): a user-declared union's receiver shape resolves from
        // prog.impls, never the stdlib KNOWN table — a local union
        // sharing a stdlib name must not be shaped by the stdlib's
        // method signatures. Only names with NO module-local impl
        // block fall through to the materialized-stdlib table.
        var local_impl_found = false;
        for (self.prog.impls) |impl| {
            if (!std.mem.eql(u8, impl.target_type, union_name)) continue;
            local_impl_found = true;
            for (impl.methods) |m| {
                if (!std.mem.eql(u8, m.name, method_name)) continue;
                if (self.resolveTraitBinding(&impl, m) != null) continue;
                if (m.params.len == 0) return false; // static method, no receiver
                return std.mem.startsWith(u8, m.params[0].type_text, "*");
            }
        }
        if (local_impl_found) return null; // local union lacks the method — verbatim fallback
        if (self.unionModulePath(union_name) != null) {
            // Receiver shapes for MATERIALIZED stdlib union methods
            // (the user module can't see lib/std impl blocks). Keep
            // in sync with the impl blocks in lib/std/ — a stdlib
            // method missing here silently falls back to verbatim
            // (zig then rejects the bare member call), so add an
            // entry whenever lib/std gains a union method.
            const KNOWN = &[_]struct { u: []const u8, m: []const u8, recv_ptr: bool }{
                .{ .u = "Json", .m = "get", .recv_ptr = true },
            };
            for (KNOWN) |k| {
                if (std.mem.eql(u8, k.u, union_name) and std.mem.eql(u8, k.m, method_name)) return k.recv_ptr;
            }
            return null;
        }
        return null;
    }

    /// Union orphan-method dispatch — the shared rewrite behind both
    /// `hover.is_action()` (member form) and `ClickEvent.is_action(hover)`
    /// (qualified static form) in the `.method_call` arm, and their
    /// template-placeholder dotted-`.call` cousins. Resolves the union
    /// name from the receiver (a binding's tracked type or a bare
    /// union type name), confirms the method exists, then emits
    /// `[<@import>. ]<Union>_<Method>(<receiver?>, <args...>)`. The
    /// member form passes the receiver as the first argument with `&`
    /// when the impl's receiver param is a pointer and the binding is
    /// a value (mirroring the generic-instance dispatch's `&` rule and
    /// zig's own method-call sugar); the qualified form passes args
    /// verbatim. Returns true when the call was rewritten — false
    /// leaves the caller's verbatim fallback in charge.
    pub     fn tryEmitUnionOrphanCall(self: *Codegen, receiver_ident: []const u8, method_name: []const u8, args: []const ast.Expr) bool {
        var union_name: []const u8 = receiver_ident;
        var tracked: ?[]const u8 = null;
        if (!self.isUnionTarget(union_name)) {
            // Member form: resolve the binding's tracked type, strip
            // pointer prefixes to reach the union name, and remember
            // the original so the `&` decision knows the binding kind.
            const tn = self.getSourceTypeName(receiver_ident) orelse return false;
            var base: []const u8 = tn;
            if (std.mem.startsWith(u8, base, "*const ")) base = base["*const ".len..];
            if (std.mem.startsWith(u8, base, "*")) base = base["*".len..];
            if (!self.isUnionTarget(base)) return false;
            union_name = base;
            tracked = tn;
        }
        const recv_ptr = self.unionMethodReceiverIsPointer(union_name, method_name) orelse return false;
        if (self.unionModulePath(union_name)) |mod_path| {
            self.write("@import(\"");
            self.write(mod_path);
            self.write("\").");
        }
        self.write(union_name);
        self.write("_");
        self.write(method_name);
        self.write("(");
        if (tracked) |tt| {
            var base: []const u8 = tt;
            if (std.mem.startsWith(u8, base, "*const ")) base = base["*const ".len..];
            if (std.mem.startsWith(u8, base, "*")) base = base["*".len..];
            const binding_is_ptr = !std.mem.eql(u8, tt, base);
            if (recv_ptr and !binding_is_ptr) {
                // Value binding + pointer receiver: a bare `&v` would
                // be `*const T` when the binding is a const capture
                // (zig's optional-capture `|v|` and match captures are
                // const), which zig rejects as const-discard — wrap in
                // @constCast to strip the qualifier (same pattern as
                // the trait-cast arm). A no-op on already-mutable
                // bindings, so the wrap is unconditional for the
                // address form.
                self.write("@constCast(&");
                self.write(receiver_ident);
                self.write(")");
            } else {
                self.write(receiver_ident);
            }
            if (args.len > 0) self.write(", ");
        }
        for (args, 0..) |a, i| {
            if (i > 0) self.write(", ");
            self.genExpr(a);
        }
        self.write(")");
        return true;
    }

    /// Resolve a field's declared type text from a module-local
    /// struct decl: `timers` on `EventLoop` → `ArrayList(TimerEntry)`.
    /// Used by the `.method_call` generic dispatch to route
    /// `self.timers.push(...)` (a member-access receiver whose base
    /// resolves to a generic-typed field) to the orphan free fn.
    pub     fn structFieldType(self: *Codegen, struct_name: []const u8, field_name: []const u8) ?[]const u8 {
        // Pointer-base auto-deref (docs/08 §"Field access on pointer
        // bindings"): `st.sem` where `st: *Probe` looks the field up
        // on Probe. Without this strip the lookup fails and the
        // addr_of cast emit can't type the field — surfaced by the
        // concurrency examples' `addr_of(st.sem) as usize`
        // payload-thunk shape (unknown type → @intCast on a pointer,
        // which zig rejects).
        var base = struct_name;
        if (std.mem.startsWith(u8, base, "*const ")) base = base["*const ".len..];
        if (std.mem.startsWith(u8, base, "*")) base = base[1..];
        for (self.prog.structs) |sd| {
            if (!std.mem.eql(u8, sd.name, base)) continue;
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

    /// Static type text for an EXPRESSION source, for cast-site
    /// detection: bare idents resolve via the typed-binding table;
    /// member-access chains (`t.ctl`, `a.b.c`) resolve the BASE
    /// binding through the table, then walk field-by-field via
    /// structFieldType. Returns null for anything unresolvable (the
    /// cast emit then takes its conservative default route).
    /// Surfaced by std.concurrent.thread's join — `t.ctl as [*]usize`
    /// was emitting `@ptrCast` on an int source (zig: "expected
    /// pointer type, found usize") because the int→pointer carve-out
    /// only recognized bare idents.
    pub     fn getSourceTypeNameOfExpr(self: *Codegen, e: ast.Expr) ?[]const u8 {
        switch (e.payload) {
            .ident => |name| return self.getSourceTypeName(name),
            .member_access => |ma| {
                const base = getSourceTypeNameOfExpr(self, ma.target.*) orelse return null;
                // Slice-shaped bases have no zag-side struct decl —
                // their builtins map directly: `.ptr` is the many-
                // pointer (matching ptr_src prefix detection for
                // `buf.ptr as usize` → @intFromPtr), `.len` is usize.
                if (std.mem.startsWith(u8, base, "[") or std.mem.eql(u8, base, "str")) {
                    if (std.mem.eql(u8, ma.name, "ptr")) return base;
                    if (std.mem.eql(u8, ma.name, "len")) return "usize";
                    return null;
                }
                return self.structFieldType(base, ma.name);
            },
            // A cast HAS its target's type (`ctl_buf.ptr as usize` is
            // a usize) — needed so integer-arithmetic chains over cast
            // results (`(p as usize + 24) as *i32`, the ctid address
            // computation in std.concurrent.thread.spawn) still
            // resolve to an int and take the @ptrFromInt route.
            .cast => |c| return c.type_text,
            // Integer-arithmetic sources (`(p as usize + 24) as *i32` —
            // pointer math at the syscall boundary): the LHS's tracked
            // type flows through — + - & | << >> and their wrapping
            // twins keep int-ness (the RHS operand's comptime-int
            // literal can't change it). Surfaced by
            // std.concurrent.thread.spawn's ctid address computation.
            .binary => |b| {
                switch (b.op) {
                    .add, .sub, .mul, .div, .mod, .add_wrap, .sub_wrap, .mul_wrap, .bitand, .bitor, .bitxor, .shl, .shr => {
                        const lt = getSourceTypeNameOfExpr(self, b.lhs.*) orelse return null;
                        if (isIntTypeName(lt)) return lt;
                        return null;
                    },
                    else => return null,
                }
            },
            .call => |c| {
                // `addr_of(x)` — the address-of intrinsic — has type
                // `*T` where `x: T`. Surfaced by the concurrency
                // examples' `addr_of(st.sem) as usize` payload-thunk
                // shape: the cast emit's ptr-source detection queries
                // THIS fn for the cast operand, and without a .call
                // arm the addr_of result type is unknown → the cast
                // falls to @intCast, which zig rejects on a pointer
                // source. The synthesized `*T` text is heap-owned for
                // the compile's duration (page_allocator, matching
                // out_buf's allocator; the strings are tiny and few).
                if (c.args.len == 1 and std.mem.eql(u8, c.name, "addr_of")) {
                    const inner = getSourceTypeNameOfExpr(self, c.args[0]) orelse return null;
                    const joined = std.heap.page_allocator.alloc(u8, inner.len + 1) catch return null;
                    joined[0] = '*';
                    @memcpy(joined[1..], inner);
                    return joined;
                }
                return null;
            },
            else => return null,
        }
    }

    /// True when `name`'s tracked binding is a `var` (mutable kind).
    /// Method-call emit consults this before wrapping a receiver's
    /// address in `@constCast` — see BindingTypeInfo.is_var.
    pub     fn bindingIsVar(self: *Codegen, name: []const u8) bool {
        for (self.type_info_buf[0..self.type_info_count]) |ti| {
            if (std.mem.eql(u8, ti.name, name)) return ti.is_var;
        }
        return false;
    }

    /// Copy the current fn's return-type text into `fn_ret_type_buf`
    /// (bounded 128) so return-position Option/Result ctors can anchor
    /// on the signature. Called at genFun/genMethod body entry; zero
    /// length when the fn has no return annotation. Copied verbatim
    /// (raw source text, `Option<i32>` or `Result<i32, str>`) — the
    /// instantiated-ctor emit parses the args itself.
    pub     fn setFnRetType(self: *Codegen, text: []const u8) void {
        const n = if (text.len > self.fn_ret_type_buf.len) self.fn_ret_type_buf.len else text.len;
        @memcpy(self.fn_ret_type_buf[0..n], text[0..n]);
        self.fn_ret_type_len = n;
    }

    /// Push the expected-type anchor (`let x: Option<i32> = …`) around
    /// an RHS emit. Returns the PRIOR anchor length so the caller can
    /// restore it after the emit (nested bindings must not leak their
    /// annotation outward to sibling expressions).
    pub     fn pushCtorAnchor(self: *Codegen, text: []const u8) usize {
        const prev = self.ctor_anchor_len;
        const n = if (text.len > self.ctor_anchor_buf.len) self.ctor_anchor_buf.len else text.len;
        if (n > 0) @memcpy(self.ctor_anchor_buf[0..n], text[0..n]);
        self.ctor_anchor_len = n;
        return prev;
    }

    pub     fn popCtorAnchor(self: *Codegen, prev: usize) void {
        self.ctor_anchor_len = prev;
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
    /// Copy `name` into the per-instance name pool and return the
    /// pooled slice. See `name_pool_buf` for why the old shared-
    /// static-buffer contract was unsound for overload suffixes.
    pub     fn internedSuffixName(self: *Codegen, name: []const u8) []const u8 {
        if (self.name_pool_len + name.len > self.name_pool_buf.len) return name;
        const start = self.name_pool_len;
        @memcpy(self.name_pool_buf[start .. start + name.len], name);
        self.name_pool_len += name.len;
        return self.name_pool_buf[start .. start + name.len];
    }

    pub     fn traitMethodVtableName(self: *Codegen, trait_decl: ast.TraitDecl, method_index: usize) []const u8 {
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

        // Format into a local scratch, then INTERN into the
        // instance's name pool. The old shared static buffer was
        // overwritten by the next call while earlier return slices
        // still pointed into it.
        var scratch: [128]u8 = undefined;
        @memcpy(scratch[0..method_name.len], method_name);
        const suffix = std.fmt.bufPrint(
            scratch[method_name.len + 1 .. scratch.len],
            "{d}",
            .{my_dup_index},
        ) catch "0";
        scratch[method_name.len] = '_';
        const total_len = method_name.len + 1 + suffix.len;
        return self.internedSuffixName(scratch[0..total_len]);
    }

    /// Overload-suffix companion to `traitMethodVtableName` operating
    /// on ANY method list (the same-name-count walk is identical). Used
    /// by genTraitRegistration's unfulfilled-slot emit where the list
    /// is the trait's full method slice rather than the (decl, index)
    /// pair — same `_N` numbering, so a vtable slot name computed here
    /// always matches the one genTraitDecl computed from the decl.
    pub     fn traitMethodVtableNameFull(self: *Codegen, methods: []const ast.TraitMethodDecl, method_index: usize) []const u8 {
        if (method_index >= methods.len) return "";
        const method_name = methods[method_index].name;
        var dup_count: usize = 0;
        var my_dup_index: usize = 0;
        for (methods, 0..) |tm, i| {
            if (std.mem.eql(u8, tm.name, method_name)) {
                if (i < method_index) my_dup_index += 1;
                dup_count += 1;
            }
        }
        if (dup_count <= 1) return method_name;
        // Interned like traitMethodVtableName — shared static buffers
        // alias across calls.
        var scratch: [128]u8 = undefined;
        @memcpy(scratch[0..method_name.len], method_name);
        const suffix = std.fmt.bufPrint(
            scratch[method_name.len + 1 .. scratch.len],
            "{d}",
            .{my_dup_index},
        ) catch "0";
        scratch[method_name.len] = '_';
        const total_len = method_name.len + 1 + suffix.len;
        return self.internedSuffixName(scratch[0..total_len]);
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
    // std.argv.get (v0.5 self-hosting migration): the `__zag_argv`
    // fast-path alias is RETIRED — lib/std/argv.zag now delegates to
    // std.posix.argv's /proc/self/cmdline reader, so `pub import
    // std.argv.{get}` resolves through the standard @import+alias
    // fallthrough like every other std module. Reading `__zag_argv`
    // or the "get" row here is the regression signal.
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

/// Strip a trailing `_N` overload suffix (`render_1` → `render`).
/// File-scope twin of decl.zig's baseMethodName (core.zig cannot
/// import decl.zig at file scope without a cycle — decl imports
/// core's types). Used by the vtable-registration field-name walk
/// where bucket entries carry suffixed names but the trait decl's
/// method list carries bare spellings.
fn baseMethodNameOf(name: []const u8) []const u8 {
    if (name.len == 0 or !std.ascii.isDigit(name[name.len - 1])) return name;
    var end: usize = name.len;
    while (end > 0 and std.ascii.isDigit(name[end - 1])) end -= 1;
    if (end == 0 or end + 1 > name.len or name[end - 1] != '_') return name;
    return name[0 .. end - 1];
}
