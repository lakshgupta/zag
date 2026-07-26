const std = @import("std");

// TEMPLATE: Expr.template_lit field type, plus the
// re-export aliases `pub const TemplateLitExpr =
// @import("template.zig").TemplateLitExpr;` inside the
// Expr union body.
const template = @import("template.zig");

// DECL: ClosureExpr.params: []const MethodParam.
const decl = @import("decl.zig");
const MethodParam = decl.MethodParam;

// STMT: ClosureExpr.body: []const Stmt.
const stmt = @import("stmt.zig");
const Stmt = stmt.Stmt;

// TOP: Loc for expression source locations.
const top = @import("top.zig");
const Loc = top.Loc;

// ============================================================
// expr.zig — top-level types from src/ast.zig
// ============================================================

pub const ExprPayload = union(enum) {
    string_lit: []const u8,
    int_lit: []const u8,
    float_lit: []const u8,
    bool_lit: bool,
    char_lit: []const u8,
    byte_string_lit: []const u8,
    null_lit: void,
    undefined_lit: void,
    tuple_lit: []const Expr,
    /// Single-element tuple `(x,)` (trailing comma present).
    /// Distinguishes from paren-grouping `(x)` which routes to just
    /// `x` (no tuple). Single-element tuples at the codegen level
    /// emit `.{ x }` (anonymous struct with one positional element).
    /// `*Expr` pointer-typed to break Expr's size cycle with the
    /// `Expr.NamedTupleLit.elements` induction — same cycle-breaking
    /// convention as `BinaryExpr.lhs`.
    single_tuple_lit: *Expr,
    /// Named-tuple literal `(x: 10, y: 20)`. Fields have compile-time
    /// names that disappear at the ABI level (the runtime value is a
    /// positional anonymous struct). Codegen emits `. { .x = 10, .y = 20 }`
    /// in zig 0.16 syntax. Distinct from `struct_lit` because there's
    /// no typename — the named fields are anonymous-struct keys.
    named_tuple_lit: NamedTupleLit,
    array_lit: ArrayLitExpr,
    ident: []const u8,
    call: CallExpr,
    new_expr: NewExpr,
    free_expr: FreeExpr,
    deref: DerefExpr,
    cast: CastExpr,
    template_lit: TemplateLitExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    index: IndexExpr,
    /// `target[start..end]` (or variants like `target[start..]` /
    /// `target[..end]` / `target[..]`). Produced by the postfix chain
    /// when `[` opens and the inside resolves to a range expression
    /// rather than a single index. `start` and `end` are nullable to
    /// cover the no-bound forms (`arr[..]`, `arr[2..]`, `arr[..5]`).
    /// Codegen emits zig's native `[start..end]`/slice syntax so the
    /// resulting value is a `[]T` slice (layout `{ ptr, len }`) — no
    /// extra shim required.
    slice: SliceExpr,
    range: RangeExpr,
    /// `if cond { expr } else { expr }` expression form (single expression
    /// per branch). Built by `Parser.parseIfExpr` when `if_kw` is the
    /// leading token of an expression-position context (e.g. RHS of a
    /// `let` binding). Statement-position `if` parses into `Stmt.if_stmt`
    /// instead. Codegen emits a labeled block + `break :blk` for the
    /// expression form so the whole construct yields a value.
    if_expr: IfExpr,
    /// `match scrutinee { arms... }` expression. The match is always
    /// expression-valued per the user-confirmed shape (single-expression
    /// arm bodies). Codegen emits a labeled-block if-else ladder.
    match_expr: MatchExpr,
    /// `Type { f1: v1, f2: v2, }` struct-literal expression. Built by
    /// `Parser.parsePrimary` when the leading token is an identifier
    /// followed by `{` (the lexical discriminator between a bare
    /// `.ident` and a struct-literal). Field-init list is preserved in
    /// declaration order; codegen emits `.TypeName{ .f1 = …, .f2 = … }`
    /// verbatim. NOTE: this field is declared BEFORE the `pub const`
    /// block below because zig requires all union fields to be declared
    /// before any non-field declarations — a `pub const NestedStruct`
    /// between fields triggers a compile error. The backing
    /// `StructLitExpr` and `FieldInit` types live near the other nested
    /// payload struct definitions in this union. This field lives
    /// BEFORE the `pub const` block to satisfy the ordering rule.
    struct_lit: StructLitExpr,
    member_access: MemberAccessExpr,
    method_call: MethodCallExpr,
    /// `Enum.Variant(args...)` (with payload) or the no-args form
    /// `Enum.Variant` -- the qualified constructor form (RHS of `let`,
    /// call arg, return value, etc.). Codegen forwards both forms
    /// verbatim and lets zig's type checker resolve the enum name.
    /// Built by `Parser.parsePrimary`'s `.identifier` arm when TWO
    /// consecutive PascalCase identifiers are followed by a `.`
    /// (the enum-name + variant-name qualified shape). The trailing
    /// `.lparen` is OPTIONAL because the no-args variant ctor shape
    /// `Direction.North` (no payload) terminates at the variant name
    /// itself without requiring a parenthesised argument list. The
    /// pattern counterpart for match arms
    /// (`Direction.North => 1`) is a separate `Pattern.EnumVariantPattern`
    /// node -- that form does require parens when bindings are
    /// captured (e.g. `Some(x)`) and is documented separately on
    /// `Pattern.EnumVariantPattern` below.
    enum_variant_ctor: EnumVariantCtor,
    /// `|params| -> RET? { body }` closure expression (docs/15 §"Closures").
    /// Parsed by `Parser.parseClosureExpr` from expression position
    /// when the leading token is `.pipe`. Codegen emits an anonymous
    /// struct with a `call(args) RET` method so `closure_expr(args)`
    /// can be rewritten as `closure_expr.call(args)` at call sites
    /// (closure-type tracking happens in codegen's per-fn type-info map
    /// so binding-driven call sites are detected correctly). Empty
    /// `params` and `null` return_type are accepted (primitives
    /// like `|| { print("hi"); return 0; }`).
    closure: ClosureExpr,
    /// `expr?` — postfix try/unwrap operator. On a `Result<T,E>`, extracts
    /// the `Ok(T)` value or early-returns the `Err(E)` from the enclosing
    /// function. On an `Option<T>`, extracts the `Some(T)` value or
    /// early-returns `None`. Emits a labeled block + switch at codegen time.
    /// Built by `Parser.parsePostfix` when a `?` token follows an expression.
    try_op: TryOp,
    /// `expr catch HANDLER` — error-handling expression. Evaluates `expr`;
    /// if it is `Ok(T)`, yields the `T` value; if it is `Err(E)`, evaluates
    /// `handler` (an expression serving as the default value) or, when
    /// `err_binding` is set (`catch |err| handler`), binds the error to
    /// `err` and evaluates `handler`. Built by `Parser.parseCatchExpr`.
    catch_expr: CatchExpr,
    /// `{ stmt; stmt; expr }` — block expression. Evaluates to the
    /// value of the last expression in the block. Built by
    /// `Parser.parsePrimary` when `.lbrace` is encountered in an
    /// expression position. Codegen emits a zig labeled block with
    /// `break :blk` for the final value.
    block_expr: []const Stmt,
    /// `const { stmts; return expr; }` — compile-time evaluated block.
    /// Codegen emits zig `comptime blk: { ... break :blk expr; }`.
    /// Built by `Parser.parsePrimary` when `.const_kw` is encountered
    /// in an expression position.
    const_block: []const Stmt,

    pub const BinaryExpr = struct {
        /// Operator tag. Stored as an enum so codegen can switch on the
        /// textual representation (`+ - * /`) without re-parsing the
        /// source location. Operator precedence is encoded in the parser's
        /// recursive-descent ladder, not the AST itself: a flat chain of
        /// `.binary` nodes is fine for codegen because Zig preserves
        /// left-associativity for these operators exactly as emitted.
        op: BinaryOp,
        /// Left and right operands. Pointers (`*Expr`) follow the existing
        /// NewExpr/DerefExpr convention so we avoid per-node allocations —
        /// each BinaryExpr only stores 1× Binop + 2× pointer.
        lhs: *Expr,
        rhs: *Expr,
    };

    /// Every binary operator the grammar accepts from `docs/manual/05-operators.md`.
    /// Codegen emits the corresponding zig operator literal in `genExpr` `.binary` switch
    /// arms. `.range` is included here for codegen simplicity (RangeExpr lives
    /// separately in the union so the AST can carry `start`/`end`/`inclusive`
    /// distinctly, but the descriptor still routes through `.binary`'s path
    /// shape where arrow-shaped emission would also work). Membership here is
    /// driven by the precedence ladder: each operator class in the manual maps
    /// to one layer in `Parser.parseExpr`'s recursive descent.
    pub const BinaryOp = enum {
        // arithmetic
        add,
        sub,
        mul,
        div,
        mod,
        // bitwise
        bitand,
        bitor,
        bitxor,
        shl,
        shr,
        // comparison
        eq,
        ne,
        lt,
        gt,
        le,
        ge,
        // logical
        land,
        lor,
        // range (codegen picks `.{start, end, false}` or `.{start, end, true}` from the
        // accompanying Expr.range node's `inclusive` flag — BinaryOp.range is
        // unused as a node payload but kept for future Range-as-op tagging)
        _range,
    };

    /// Unary expression node — built by `Parser.parseUnary` for `-x` /
    /// `~x` / `!x` / `*x` (the last was previously handled inside
    /// `parsePrimary`; the move unifies all prefix-op emission here).
    pub const UnaryExpr = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const UnaryOp = enum {
        /// `-x` — arithmetic negation (zig: `-operand`)
        neg,
        /// `~x` — bitwise NOT (zig: `~operand`)
        bnot,
        /// `!x` — logical NOT (zig: `!operand`); acts on bool-typed operands.
        lnot,
        /// `*x` — pointer deref (zig: `operand.*`); zig syntax stays as-is because
        /// deref is postfix in zig, so we emit `&x.*` shimming only when needed.
        deref,
        /// `&x` — address-of. Codegen emits `&<operand>`; the resulting zig type
        /// is `*T` (mutable) when `x` is a `var` and `*const T` (immutable)
        /// when `x` is a `let` / `const` / function parameter. The zag parser
        /// keeps a single `.amp` token and dispatches unary-vs-binary by
        /// syntactic context, mirroring how `-x` (unary) vs `a - b` (binary)
        /// share the `.minus` token.
        addr,
    };

    /// Postfix indexing — `arr[i]`. Codegen emits `arr[i]` directly because
    /// both arrays and anonymous structs accept `[i]` access in zig 0.16.
    /// The AST is recursive (target may itself be an `.index`), so chains
    /// like `arr[i][j]` surface as `.index(.index(arr, i), j)` and codegen
    /// emits them verbatim.
    pub const IndexExpr = struct {
        target: *Expr,
        index: *Expr,
    };

    /// Postfix member-access — `target.name`. Built by
    /// `Parser.parsePostfix` when the chain sees a `.identifier` (no
    /// parens follow). Codegen emits `<target>.<name>` verbatim because
    /// zig's struct-field-access syntax is identical to zag's
    /// surface — the user's `v.x` round-trips to zig `v.x` and zig's
    /// native type checker validates the field exists on `v`'s type.
    /// The `target` is `*Expr` for the cycle-breaking reason
    /// documented on `BinaryExpr.lhs`.
    pub const MemberAccessExpr = struct {
        target: *Expr,
        name: []const u8,
    };

    /// Postfix method-call — `target.name(args...)`. Built by
    /// `Parser.parsePostfix` when `.identifier` is followed by `(`.
    /// Codegen emits `<target>.<name>(<args>)` verbatim because zig
    /// natively distinguishes between value-receiver calls (`v.length()`,
    /// `v: Vec3`) and type-static calls (`Vec3.new(...)`). No za-side type
    /// resolver is required — zig's own type checking handles the dispatch.
    /// Args are positional Exprs in order; named-arg form is reserved for
    /// a future syntax (the current spec uses positional args for both
    /// constructors and regular methods, mirroring zig's own convention).
    pub const MethodCallExpr = struct {
        target: *Expr,
        name: []const u8,
        args: []const Expr,
        /// Generics turbofish (Phase 3 trait dispatch, docs/17 §"Using Traits"):
        /// the user must supply the vtable's source-type via turbofish at the
        /// call site so the dispatch shim's `comptime T: type` parameter
        /// resolves to the registered source-type (e.g.
        /// `d.draw<Button>()` emits `d.draw(Button)` which binds Button to the
        /// shim's `T`). Empty default slice preserves the non-generic call
        /// shape — existing tests that never used turbofish on `.method_call`
        /// keep round-tripping byte-identical. Set by Parser.parsePostfix's
        /// `.dot` arm when the leading `(<types...)` follows the method's own
        /// `(args...)` paren-pair; mirrors CallExpr.type_args so the same
        /// `Parser.parseTurbofishArgs` helper drives both call shapes.
        type_args: []const []const u8 = &[_][]const u8{},
    };

    /// Range expression — `start..end` (inclusive=false) or `start...end`
    /// (inclusive=true). Codegen emits an anonymous struct
    /// `.{ start, end, inclusive }` whose fields zig can pattern-match or
    /// field-access downstream. `for ... in range` iteration is deferred
    /// until `for`/`in` keywords land; the range value itself is consumable
    /// today via tuple destructuring or by extracting `.0`/`.1`/`.2`.
    pub const RangeExpr = struct {
        start: *Expr,
        end: *Expr,
        /// `false` for `a..b` (half-open `[a, b)`), `true` for `a...b`
        /// (inclusive `[a, b]`).
        inclusive: bool,
    };

    /// `target[start..end]` slicing. Distinct from `.index` because the
    /// slice expression has TWO operands (start, end) plus the inclusive
    /// flag, and codegen emits zig's native slicing syntax `target[a..b]`
    /// which lowers to a `[]T` slice value. `start` and `end` are
    /// nullable so the no-bound forms (respectively `arr[..]` and the
    /// `[a..]` / `[..b]` halves) parse cleanly without inventing a
    /// synthetic `0` or `len` Expr. The pointer-typed `*Expr` fields
    /// follow the existing `IndexExpr.target`/`.index` convention to
    /// keep `Expr`'s size bounded (the cycle-breaking convention is
    /// explained in `BinaryExpr`).
    pub const SliceExpr = struct {
        target: *Expr,
        start: ?*Expr,
        end: ?*Expr,
        /// `false` for `a..b` (half-open `[a, b)`), `true` for `a...b`
        /// (inclusive `[a, b]`). When `end` is `null` the flag is moot —
        /// codegen ignores it for the no-end forms.
        inclusive: bool,
    };

    pub const ArrayLitExpr = struct {
        /// Compile-time-known element count parsed from `[N]T { ... }`.
        /// Only meaningful for the literal-size case (`[3]i32 { ... }`,
        /// `[4]T`); for the identifier-size case (`[N]T { ... }` where `N`
        /// is a const-param ident in scope) the digit-walk yields `0` and
        /// `size_text` carries the verbatim source (`"N"`) so codegen can
        /// emit the comptime-monomomorphized form. `Init pattern: ?` —
        /// mirrors `NewExpr.allocator` so the optional slot is omitted
        /// from the literal-only path (the existing `size: u32` keeps its
        /// meaning for inferred-array-size surfaces).
        size: u32,
        /// Verbatim size text for the identifier-size case (`[N]T`,
        /// `[count]T`, ...). `null` for the literal-size case (the
        /// digit-walked `size: u32` is the authoritative value).
        /// Codegen prefers this text over `size` when present so the
        /// emitted zig code carries the user-facing identifier (the
        /// comptime N flows through zig's monomorphization path with
        /// zero surgical conversion). Set by `parseArrayLit` ONLY on the
        /// `.identifier` size branch; the `.integer_literal` branch
        /// leaves it null.
        size_text: ?[]const u8 = null,
        /// Element type identifier (e.g. "i32" in `[3][3]i32`).
        type_name: []const u8,
        /// Explicit element expressions before any `...`.
        elements: []const Expr,
        /// Fill mode: `[N]T { value ... }` repeats `value` to fill `size` slots.
        fill: bool,
        /// Arithmetic-progression mode: `[N]T { v1, v2 ... }` extends
        /// by `v2 - v1` until the array is `size` long.
        progression: bool,
        /// v1.5 multi-dim bracket list (docs/10 \u00a7"Multi-Dim Arrays"):
        /// when non-null, captures ALL `[K]` brackets before the type
        /// identifier in the `[N][M]...T { ... }` LHS. `sizes[0]` mirrors
        /// `size` for backward-compat (single-dim/readers of the legacy
        /// `size` field keep working); the additional entries
        /// `sizes[1..]` are the OUTER dim brackets emitted as a prefix in
        /// `genArrayLit`'s explicit-list arm (zig equivalent:
        /// `[sizes[0]][sizes[1]]...[sizes[n-1]]T { ... }`).
        /// `null` for the LEGACY single-dim shape. All existing codesites
        /// that read `size`/`type_name`/`elements` continue to work
        /// because they do not touch this slot.
        sizes: ?[]const u32 = null,
    };

    // TemplateLitExpr: source of truth moved to template.zig;
    // this alias keeps `ast.Expr.TemplateLitExpr` resolving.
    pub const TemplateLitExpr = @import("template.zig").TemplateLitExpr;

    // TemplatePart: source of truth moved to template.zig;
    // this alias keeps `ast.Expr.TemplatePart` resolving.
    pub const TemplatePart = @import("template.zig").TemplatePart;

    pub const CallExpr = struct {
        name: []const u8,
        args: []const Expr,
        /// Generics turbofish (docs/16 §"Turbofish"): verbatim source
        /// text per slot, e.g. `["i32"]` for `max<i32>(3, 5)` or
        /// `["i32", "10"]` for `fill<i32, 10>(0)`. Empty default slice
        /// preserves the non-generic call shape. Codegen prefix-emits
        /// `type_args` before `args` because zig's comptime parameter
        /// convention places compile-time values ahead of runtime args
        /// (e.g. `max(i32, 3, 5)`). Each slot is captured verbatim by
        /// `Parser.parseTurbofishArgs` — no AST-level resolution of
        /// `List<i32>`-style nested generics in this phase.
        type_args: []const []const u8 = &[_][]const u8{},
    };

    pub const NewExpr = struct {
        type_name: []const u8,
        value: *Expr,
        /// Allocator name for the `new(<allocator>, T(...))` form, e.g.
        /// emitted as `<allocator>.create(T)` instead of the global page
        /// allocator. `null` means use `std.heap.page_allocator` (the
        /// default). Used by `docs/19-memory.md` Pattern 3 (Arena) where
        /// the user writes `new(arena, T(value))` to allocate inside a
        /// scoped arena. Only meaningful for the simple single-value form
        /// `new T(v)` — array-flavoured `new [N]T { ... }` always uses the
        /// global allocator (rug form: `let arr = new [10]i32 { 0 }`).
        allocator: ?[]const u8 = null,
    };

    pub const FreeExpr = struct {
        target: *Expr,
    };

    pub const DerefExpr = struct {
        target_ptr: *Expr,
    };

    /// `expr as T` type-cast expression. Codegen emits `<expr> as <type_text>`
    /// verbatim because zig 0.16 `as` is the canonical cast operator and
    /// supports the same surface as the zag `as` (pointer conversions,
    /// widening/narrowing numerics). The destination type can be a multi-token
    /// form like `*raw c_void` so we capture the verbatim source text rather
    /// than a parsed identifier — the AST parser scans tokens until a
    /// natural delimiter (newline, comma, `)`, `]`, `}`, `;`, `+`, etc.) and
    /// stores the joined run as `type_text`.
    pub const CastExpr = struct {
        expr: *Expr,
        type_text: []const u8,
    };

    /// `if cond { expr } else { expr }` expression form. Built by
    /// `Parser.parseIfExpr` when the leading token is `.if_kw` and the
    /// context is expression-position (RHS of a `let`, inside a binary
    /// operand list, return value, etc.). Each branch carries an
    /// `*Expr` pointer (NOT a value-typed Expr) to break the size cycle
    /// that would otherwise arise between `Expr` (here) and these
    /// nested struct definitions — mirrors the existing `BinaryExpr.lhs
    /// : *Expr` convention. The statement form is `Stmt.if_stmt` so
    /// codegen can switch on AST tag without inspecting payload shape.
    pub const IfExpr = struct {
        cond: *Expr,
        then_expr: *Expr,
        else_expr: *Expr,
    };

    /// `match scrutinee { arms... }` expression. Always expression-valued
    /// per the user-confirmed shape — the docs show match used both as a
    /// RHS binding and as a function body (`fun foo() { match ... }`),
    /// both of which surface in the AST as `Expr.match_expr` (the
    /// statement-position variant is just `Stmt.expr_stmt` wrapping the
    /// same node). `scrutinee` is `*Expr` for the same cycle-breaking
    /// reason as IfExpr fields; arm bodies are kept as values in the
    /// external `MatchArm` slice. Codegen emits a labeled-block if-else
    /// ladder; arm bodies are single expressions per the user-confirmed
    /// shape.
    pub const MatchExpr = struct {
        scrutinee: *Expr,
        arms: []const MatchArm,
    };

    /// Backing struct for `Expr.struct_lit` — `Type { f1: v1, f2: v2, }`.
    /// `type_name` carries the verbatim source text (e.g. `Vec3`); the
    /// parser does not validate it against a struct-decl table because
    /// zag has no module system. Codegen emits `.TypeName { .f1 = …, .f2 = … }`
    /// verbatim — zig's anonymous-struct literal syntax accepts the
    /// dotted-field form when the TypeName is a real declared struct
    /// and the field names match. `FieldInit.value` is `*Expr` for the
    /// same cycle-breaking reason as `BinaryExpr.lhs`.
    pub const StructLitExpr = struct {
        type_name: []const u8,
        inits: []const FieldInit,
    };

    /// One field-init inside a struct-literal. The field name is preserved
    /// verbatim so codegen can emit `.field_name = value` exactly as the
    /// user wrote it. `value` is `*Expr` for cycle-breaking (see the
    /// `StructLitExpr` doc).
    pub const FieldInit = struct {
        name: []const u8,
        value: *Expr,
    };

    /// Backing struct for `Expr.enum_variant_ctor`. `args` uses the
    /// `[]const Expr` slice convention (value-typed) because the
    /// constructor is a leaf position in expression trees — não need
    /// for cycle-breaking pointer indirection (unlike the pattern form,
    /// which sits inside MatchArm and needs the *Expr pointer convention).
    pub const EnumVariantCtor = struct {
        enum_name: ?[]const u8,
        variant_name: []const u8,
        args: []const Expr,
    };

    /// Backing struct for `Expr.named_tuple_lit`. `names` is parallel
    /// to `elements` by index (preserve order in code review per the
    /// docs/14 tuples.md example). Lengths must match.
    pub const NamedTupleLit = struct {
        names: []const []const u8,
        elements: []const Expr,
    };

    /// Backing struct for `Expr.closure`. `params` carries the
    /// pipe-bracketed parameter list (same shape as `FunDecl.params` /
    /// `MethodDecl.params`). `return_type` is the optional `-> T` arrow
    /// following the params; `null` falls through to zig's type
    /// inference. `body` is a stmt-list (mirrors `FunDecl.body` /
    /// `MethodDecl.body`) so the canonical docs/15 form
    /// `|x: i32| -> i32 { return x * 2; }` parses with the `return`
    /// stmt in body position.
    pub const ClosureExpr = struct {
        params: []const MethodParam,
        return_type: ?[]const u8,
        body: []const Stmt,
    };

    /// Backing struct for `Expr.try_op` — `expr?` postfix try operator.
    /// `expr` is `*Expr` for the same cycle-breaking reason as
    /// `BinaryExpr.lhs` — the Expr union's size would explode if every
    /// variant carried a value-typed Expr child.
    pub const TryOp = struct {
        expr: *Expr,
    };

    /// Backing struct for `Expr.catch_expr` — `expr catch HANDLER` or
    /// `expr catch |err| HANDLER`. `expr` is the expression being
    /// caught; `handler` is the fallback expression (always present).
    /// `err_binding` is non-null when the user wrote `catch |err| ...`
    /// so codegen can inject the binding preamble.
    pub const CatchExpr = struct {
        expr: *Expr,
        handler: *Expr,
        err_binding: ?[]const u8 = null,
    };
};

pub const Expr = struct {
    payload: ExprPayload,
    loc: Loc,

    pub const BinaryExpr = ExprPayload.BinaryExpr;
    pub const BinaryOp = ExprPayload.BinaryOp;
    pub const UnaryExpr = ExprPayload.UnaryExpr;
    pub const UnaryOp = ExprPayload.UnaryOp;
    pub const IndexExpr = ExprPayload.IndexExpr;
    pub const MemberAccessExpr = ExprPayload.MemberAccessExpr;
    pub const MethodCallExpr = ExprPayload.MethodCallExpr;
    pub const RangeExpr = ExprPayload.RangeExpr;
    pub const SliceExpr = ExprPayload.SliceExpr;
    pub const ArrayLitExpr = ExprPayload.ArrayLitExpr;
    pub const TemplateLitExpr = ExprPayload.TemplateLitExpr;
    pub const TemplatePart = ExprPayload.TemplatePart;
    pub const CallExpr = ExprPayload.CallExpr;
    pub const NewExpr = ExprPayload.NewExpr;
    pub const FreeExpr = ExprPayload.FreeExpr;
    pub const DerefExpr = ExprPayload.DerefExpr;
    pub const CastExpr = ExprPayload.CastExpr;
    pub const IfExpr = ExprPayload.IfExpr;
    pub const MatchExpr = ExprPayload.MatchExpr;
    pub const StructLitExpr = ExprPayload.StructLitExpr;
    pub const FieldInit = ExprPayload.FieldInit;
    pub const EnumVariantCtor = ExprPayload.EnumVariantCtor;
    pub const NamedTupleLit = ExprPayload.NamedTupleLit;
    pub const ClosureExpr = ExprPayload.ClosureExpr;
    pub const TryOp = ExprPayload.TryOp;
    pub const CatchExpr = ExprPayload.CatchExpr;
};

/// One arm of a `match` expression: a `Pattern`, an optional `if`-guard,
/// and a single-expression body. The user-confirmed shape is single-
/// expression body (no block form like `=> { stmts; },`); this keeps
/// codegen uniform — all arms yield a value via `break :blk expr`.
///
/// The `expr` and `guard` fields are `*Expr` / `?*Expr` because
/// `MatchArm` participates in `Expr.MatchExpr.arms` and the union size
/// cycle would otherwise form between `Expr` and `MatchArm` — mirrors
/// the existing `BinaryExpr.lhs: *Expr` cycle-breaking convention.
pub const MatchArm = struct {
    pat: Pattern,
    guard: ?*Expr,
    expr: *Expr,
};

/// Discriminates the four patterns implemented for this commit. Enum-
/// variant patterns (`Some(x)`, `Write(data)`) are deferred to a followup
/// because they require zag to lex `Option.Some` as one token (currently
/// the standalone `.` is dropped by the lexer).
///
/// - `.literal(LitExpr)`   — int / bool / string literal value matches
/// - `.range(...)`         — `start..end` or `start...end` integer range
/// - `.ident(name)`        — name binding (always matches); the arm's
///                            body can reference the name; codegen emits
///                            `const <name> = __m; break :blk body`.
/// - `.discard`            — wildcard `_`, always matches, no binding
///
/// `.literal` and `.range.start/end` carry `*Expr` pointers (not
/// value-typed Expr) for the same cycle-breaking reason as MatchArm
/// and IfExpr fields — without it, Expr's size would transitively
/// depend on MatchArm -> Pattern -> Expr for each pattern variant
/// holding Expr, and zig would reject the type declaration with
/// "dependency loop with length N". The pointer indirection breaks
/// the size dependency while still allowing the AST to capture the
/// full Expr kinds our parser can produce.
pub const Pattern = union(enum) {
    literal: *Expr,
    range: PatternRange,
    ident: []const u8,
    discard: void,
    /// `Enum.Variant(b1, b2, ...)` or unqualified `Variant(b1, b2, ...)`
    /// (when type is inferred per `docs/manual/13-enums.md`). Built by
    /// `Parser.parsePattern` when the leading token is an identifier
    /// (PascalCase-by-convention) optionally preceded by `Enum.`
    /// (qualified) and optionally followed by `(` and a comma-separated
    /// list of either binding-name idents or wildcard `_` tokens.
    /// `bindings` is `null` for bare tag-only variants (e.g.
    /// `Direction.North =>`); non-null for variants carrying a payload
    /// and listing each binding name (and `_` for throw-away ones).
    enum_variant: EnumVariantPattern,
    /// `Enum.Variant { name1: b1, name2: b2, ... }` (brace-named-field
    /// match-side destructuring per docs/manual/14-unions §"Definition"
    /// §"Bare Variant" / docs/manual/13-enums §"Choosing Between enum
    /// and union" + gap #2 emit shape). Sibling variant to
    /// `.enum_variant`; the difference is the payload-shape marker
    /// (`(...)` → `.enum_variant`, `{...}` → `.enum_variant_named`).
    /// Each `fields` slot is a `VariantFieldPattern` carrying the
    /// source field name (verbatim, must match the variant-decl side)
    /// and an optional capture ident (`null` = `_` discard). Codegen
    /// emits `__m == .Variant` for the cond AND a preamble
    /// `const c1 = __m.name1; ...` inside the arm block so the
    /// captures are in scope for the arm-body Expr.
    enum_variant_named: EnumVariantNamedPattern,

    pub const PatternRange = struct {
        start: *Expr,
        end: *Expr,
        inclusive: bool,
    };

    /// Backing struct for `Pattern.enum_variant`. `enum_name` is the
    /// verbatim parser-captured identifier (e.g. `Direction`); empty
    /// string when the parser sees only `Variant` (the writeup is
    /// "scheme supports unqualified variants when the type is
    /// inferred"; at AST level we preserve the source text and let
    /// codegen thread through the inferred-type surface). `bindings`
    /// is `null` when the variant is bare (no `(...)` follows); when
    /// present, each slot is a per-arg binding name (null = wildcard
    /// `_`, non-null = ident text captured verbatim).
    pub const EnumVariantPattern = struct {
        enum_name: []const u8,
        variant_name: []const u8,
        bindings: ?[]?[]const u8,
    };

    /// Backing struct for `Pattern.enum_variant_named` — the
    /// brace-named-field match-side destructuring form per
    /// docs/manual/14-unions.md §"Definition" + gap #2 emit shape.
    /// Parsed from `Variant { name1: bind1, name2: bind2, ... }` where
    /// each `nameN` MUST match the field name declared on the variant
    /// (the gap #2 emit preserves user-written field names on the
    /// anonymous-struct payload, so the destructured name resolves to
    /// the SAME field that source ctor-side `Variant { name = value }`
    /// writes to). `enum_name` follows the same convention as
    /// `EnumVariantPattern.enum_name` (verbatim capture, empty string
    /// for unqualified `Variant { ... }` patterns where type is
    /// inferred). `fields` is in declaration order — codegen emits
    /// `const <capture> = __m.<name>;` for each non-discard entry.
    pub const EnumVariantNamedPattern = struct {
        enum_name: []const u8,
        variant_name: []const u8,
        fields: []const VariantFieldPattern,
    };

    /// One named-field slot inside a brace-named-field match pattern
    /// (`Variant { name: bind }` after pattern-binding desugaring).
    /// Distinct from the gap #2 ctor-side `ast.VariantField` because
    /// the pattern side carries an optional capture name (`capture =
    /// null` represents the `_` wildcard discard) instead of a verbatim
    /// type-text. `name` is preserved verbatim from the source so codegen
    /// can emit `__m.<name>` as the access path for the binding RValue.
    /// The `name` corresponds to the variant's declared payload field
    /// (per gap #2 codegen in `src/codegen/decl.zig`'s brace-named-field
    /// arm); binding names are independent of the payload field names.
    pub const VariantFieldPattern = struct {
        name: []const u8,
        /// `null` = wildcard `_` discard; non-null = ident to bind.
        capture: ?[]const u8,
    };
};

