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
    /// Per-function counter for argv-slice temps emitted by the
    /// `argv_get` builtin route (Phase 0 codegen router). Reset to 0
    /// by `genFun` so each `pub fn` body has its own `__argv_<N>` /
    /// Per-function counter for the env-result scratch variable
    /// emitted by the `env_var` builtin route (Phase 1 codegen
    /// router). Reset to 0 by `genFun` / `genMethod` /
    /// `genFreeMethod` so each `pub fn` body has its own `__env_<N>`
    /// sequence. Two getEnv calls in the same body produce
    /// `__env_0` and `__env_1` so zig's no-redeclaration rule is
    /// satisfied. The counter steps ONLY on the env_var dispatch path.
    /// Per-function counter for the fs-read scratch variable emitted
    /// by the `fs_read_file` builtin route (Phase 2 codegen router).
    /// Reset to 0 by `genFun` / `genMethod` / `genFreeMethod` so
    /// each `pub fn` body has its own `__fs_<N>` sequence. Two
    /// read_file calls in the same body produce `__fs_0` and
    /// `__fs_1` so zig's no-redeclaration rule is satisfied. The
    /// counter steps ONLY on the fs_read_file dispatch path.
    fs_counter: u32,
    /// Per-function counter for the fs-write scratch namespace
    /// emitted by the `fs_write_file` builtin route (Phase 3 CLI
    /// migration). Reset to 0 by `genFun` / `genMethod` /
    /// `genFreeMethod` so each `pub fn` body has its own `__wf_<N>_*`
    /// sequence. Two write_file calls in the same body produce
    /// `__wf_0_*` and `__wf_1_*` so zig's no-redeclaration rule is
    /// satisfied across the per-call (fd, byte-count, ...) namespace.
    /// The counter steps ONLY on the fs_write_file dispatch path.
    /// Per-function counter for the mkdir scratch emitted by the
    /// `fs_mkdir` builtin route (Phase 3 CLI migration). Reset to 0
    /// by `genFun` / `genMethod` / `genFreeMethod` so each fn body
    /// has its own `__mk_<N>_z` slot. Two mkdir calls in the same
    /// body produce `__mk_0_z` and `__mk_1_z` so zig's
    /// no-redeclaration rule is satisfied across the toPosixPath
    /// scratch variable.
    /// Per-function counter for the exec scratch namespace emitted
    /// by the `process_exec` builtin route (Phase 3 CLI migration).
    /// Reset to 0 by `genFun` / `genMethod` / `genFreeMethod` so
    /// each fn body has its own `__exec_<N>_*` sequence. The
    /// execution shape stacks several local vars per call
    /// (arg_bufs, argv_z, env_buf, envp_z, pid, status) so a
    /// fresh namespace per call avoids zig's no-redeclaration
    /// rejection on sibling `exec` calls.
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


    pub const collectTypedBindings = @import("stmt.zig").collectTypedBindings;
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
    pub const isTrackedTrait = @import("core.zig").isTrackedTrait;
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
            // Phase 1 env-result counter starts at 0; each
            // `getEnv` builtin emit steps it and emits a fresh
            // `__env_<N>` scratch used to bridge
            // `std.posix.system.getenv`'s `?[*:0]u8` surface to the
            // zag-side `?[]const u8` shape via `std.mem.span`.
            // Phase 2 fs-read scratch: each `read_file` builtin emit
            // reuses the same `__fs_0` temp scoped to its blk: { ... }
            // block. Multiple read_file calls in the same body
            // produce distinct scoped names so zig's no-redeclaration
            // rule is satisfied.
            .fs_counter = 0,
            // Phase 3 (CLI migration): fs_write_file, fs_mkdir, and
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
            // `prog` is set by `generate()` immediately on entry
            // (see the `self.prog = &prog;` line at the top of
            // `generate`). Leaving it undefined here is intentional
            // — every emit call goes through `generate()` so prog
            // is always populated before any field that reads it.
            .prog = undefined,
        };
    }

    pub     fn write(self: *Codegen, s: []const u8) void {
        @memcpy(self.out_buf[self.out_len .. self.out_len + s.len], s);
        self.out_len += s.len;
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
            // Result<T,E> and Option<T> — error-handling fundamental types
            // (docs/manual/18-error-handling.md). Defined as generic zig
            // union(enum) types so the `?` try/unwrap operator and `catch`
            // expression can emit switch-based extraction at codegen time.
            // `Result(T, E)` carries Ok(T) and Err(E) payloads; `Option(T)`
            // carries Some(T) and None (void). Both types defined here in
            // the preamble so every generated zig module can reference them
            // without an explicit import.
            \\fn Result(comptime T: type, comptime E: type) type {
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
            \\fn Option(comptime T: type) type {
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
