const std = @import("std");

pub const Loc = struct {
    line: u32,
    col: u32,
    offset: u32,
};

pub const Expr = union(enum) {
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
    /// `Enum.Variant(args...)` or unqualified `Variant(args...)` — the
    /// constructor form (RHS of `let`, call arg, return value, etc.).
    /// `enum_name` is `null` when the parser saw only `Variant` (the
    /// user is relying on type inference per docs/13; codegen forwards
    /// the bare `Variant(args...)` form verbatim and lets zig's type
    /// checker resolve the enum name). When `enum_name` is non-null
    /// it's the verbatim captured identifier (e.g. `Option`). Built by
    /// `Parser.parsePrimary`'s `.identifier` arm when an uppercase
    /// PascalCase identifier is followed by `(`.
    enum_variant_ctor: EnumVariantCtor,

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
        size: u32,
        /// Element type identifier (e.g. "i32" in `[3]i32`).
        type_name: []const u8,
        /// Explicit element expressions before any `...`.
        elements: []const Expr,
        /// Fill mode: `[N]T { value ... }` repeats `value` to fill `size` slots.
        fill: bool,
        /// Arithmetic-progression mode: `[N]T { v1, v2 ... }` extends
        /// by `v2 - v1` until the array is `size` long.
        progression: bool,
    };

    pub const TemplateLitExpr = struct {
        /// Alternating literal text segments and interpolation expressions.
        /// A literal segment with `len == 0` is allowed as a leading or
        /// trailing placeholder when the template begins or ends with `{...}`.
        parts: []TemplatePart,
    };

    pub const TemplatePart = struct {
        /// `null` here means this slot is an interpolation expression (use `expr`).
        /// `non-null` here means this slot is a literal text segment.
        literal: ?[]const u8,
        expr: ?Expr,
        /// Optional printf-style format spec text captured between `{` and `}`,
        /// e.g. `:.5`, `:5`, `:x`, `:-5`. `null` for plain `{name}` (no spec).
        /// Applies only to interpolation slots — literal slots always have `spec
        /// = null`. The codegen appends this verbatim after `{any}` so zig's
        /// debug formatter (which DOES honour spec on `{any}` in 0.16) applies
        /// the requested precision/width/format at print time.
        spec: ?[]const u8 = null,
    };

    pub const CallExpr = struct {
        name: []const u8,
        args: []const Expr,
    };

    pub const NewExpr = struct {
        type_name: []const u8,
        value: *Expr,
        /// Allocator name for the `new(<allocator>, T(...))` form, e.g.
        /// emitted as `<allocator>.create(T)` instead of the global page
        /// allocator. `null` means use `std.heap.page_allocator` (the
        /// default). Used by `docs/19-memory.md` Pattern 3 (Arena) where
        /// the user writes `new(&arena, T(value))` to allocate inside a
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
};

/// Discriminates the three binding kinds the parser wires to `Stmt`
/// (`let`, `var`, `const`) and is forward-extensible: adding a future kind
/// (`mut`, `implicit`, `ref`, …) requires three small additions — a new
/// enum member here, a new arm in `Parser.parseBinding`'s keyword switch,
/// and a new dispatch arm in `Parser.parseStmt` — no new struct
/// definition needed because all kinds carry the same `BindingStmt` shape.
pub const BindingKind = enum {
    let,
    var_binding,
    const_binding,
};

/// Destructuring pattern for bindings. Lives at module scope (next to
/// `BindingKind`) so it can be referenced as `ast.BindingPattern` from
/// `src/parser.zig` and `src/codegen.zig` without the `Stmt.` prefix.
/// Mirrors the four shapes in `docs/manual/04-variables.md`:
///
///   let (x, y) = (10, 20);                 → .tuple([.name("x"), .name("y")])
///   let [a, b, c] = arr;                   → .array([.name("a"), .name("b"), .name("c")])
///   let (_, y, _) = (1, 2, 3);             → .tuple([.discard, .name("y"), .discard])
///   let _ = something;                     → .discard
///
/// Recursive via `.tuple` / `.array` so nested forms like
/// `let (a, (b, c)) = …` parse cleanly. Wildcard `_` is a leaf value
/// (with no zigzag binding emitted) rather than a separate top-level
/// variant, so the same helper handles `let _` and partial discards.
pub const BindingPattern = union(enum) {
    name: []const u8,
    discard: void,
    tuple: []const BindingPattern,
    array: []const BindingPattern,
    /// `...NAME` rest-binding — collects the *remaining* tuple elements
    /// after the previous leaves. Must be the LAST element in a tuple/
    /// array pattern (parser enforces this). `before_count` is the
    /// number of named/discard leaves that came before this rest in
    /// the pattern, so codegen can slice the temp from `before_count`
    /// to `init_len - 1`. Phase 1 supports rest-binding only when the
    /// init expression is a literal `tuple_lit` whose length is known
    /// at codegen time; runtime RHS is Phase 2.
    rest: RestBinding,
};

/// Backing struct for `BindingPattern.rest`. See the doc on
/// `BindingPattern.rest` for the `before_count` semantics.
pub const RestBinding = struct {
    name: []const u8,
    before_count: u32,
};

pub const Stmt = union(enum) {
    /// `let` binding. The keyword tag is on the envelope, the kind on the
    /// payload (see `BindingKind`): one `BindingStmt` struct is reused for
    /// `let`, `var`, and `const` so adding a future kind (e.g. `mut`,
    /// `implicit`) only requires a new `BindingKind` member + a new dispatch
    /// arm in the parser, not a fresh struct definition.
    let: BindingStmt,
    /// `var` binding. The tag is named `.var_binding` rather than `.var`
    /// because Zig's tagged-union tag literals cannot reuse `var` (it's a
    /// reserved keyword in Zig 0.16). The lexer accepts `var` as the
    /// `var_kw` TokenTag and the parser constructs `.var_binding = …` here.
    var_binding: BindingStmt,
    /// `const` binding. Mirrors the shape of the other two exactly. The tag
    /// is named `.const_binding` (not `.const`) for the same Zig-keyword
    /// reason as `.var_binding`. Zag's `const` is a *compile-time* binding by
    /// convention; codegen emits a Zig `const NAME: T = expr;`, which is
    /// itself evaluated at compile time.
    const_binding: BindingStmt,
    assign: AssignStmt,
    /// `arr[i] = x` indexed-write statement. Distinct from `.assign` because
    /// the target path includes a runtime-computed index; codegen emits
    /// `target[index] = value;` directly. The `value` field is value-typed
    /// (Expr) since it is the leaf of the assignment, while `target` and
    /// `index` are pointer-typed to avoid arena allocations for what are
    /// typically other Expr nodes (ident, call, etc.).
    index_assign: IndexAssignStmt,
    defer_stmt: DeferStmt,
    errdefer_stmt: ErrDeferStmt,
    unsafe_block: []const Stmt,
    expr_stmt: Expr,
    /// `if cond { stmts... }` statement form (NOT the expression form —
    /// that's `Expr.if_expr`). Statement form lets each branch contain a
    /// list of statements; otherwise the user must build tagged-union
    /// expr by hand. Else-chain is unified via the recursive
    /// `IfStmt.else_kind` union (`.none` / `.block` / `.if_chain`).
    if_stmt: IfStmt,
    /// `while cond { stmts... }` plain form. `while let` is deferred to a
    /// followup commit because it requires enum-variant patterns or at
    /// least a more permissive `if let` pattern surface than the
    /// ident-and-discard-only carve-out this commit ships.
    while_stmt: WhileStmt,
    /// `for pat in iter { stmts... }` form. Pattern is simplified to the
    /// one-element subset (just ident or discard) for this commit — tuple
    /// destructuring like `for (k, v) in …` needs a tuple-pattern parser
    /// path that's structurally identical to the existing
    /// `BindingPattern.tuple` walker; defer to followup.
    for_stmt: ForStmt,
    /// `match scrutinee { arms... }` expression-as-statement. The match
    /// node itself lives at `Expr.match_expr` so codegen emits the
    /// labeled if-else ladder uniformly; this slot is just a passthrough
    /// wrapper for statement-position contexts. Codegen delegates to
    /// `Expr.match_expr`'s codegen path. The type qualifier `Expr.`
    /// here is required because `MatchExpr` is nested inside `Expr`
    /// (mirrors `IndexAssignStmt` being nested inside `Stmt`).
    match_stmt: Expr.MatchExpr,
    /// `break;` — exit the innermost enclosing loop. Statement-only per
    /// the user-confirmed shape (no `break val;` value form). Codegen
    /// emits `break;` verbatim targeting zig's default innermost loop —
    /// no explicit loop labels needed.
    break_stmt: void,
    /// `continue;` — skip to next iteration of the innermost enclosing
    /// loop. Codegen emits `continue;` verbatim.
    continue_stmt: void,
    /// `return expr;` (or bare `return;`). The function signature
    /// (`fun foo(...) -> T`) isn't yet parsed in this compiler revision
    /// so codegen unconditionally emits `return expr;` and zig's
    /// downstream type checker validates the type against the inferred
    /// `pub fn main() !void` body return shape. If `value` is `null`,
    /// codegen emits `return;` (no value).
    return_stmt: ReturnStmt,
    /// `name.field = expr` field-write statement. Distinct from
    /// `.assign` because the RHS is a field on an aggregate rather
    /// than a bare-name rebind. The 3-token lookahead at parseStmt's
    /// identifier arm dispatches into this variant when the pattern
    /// `identifier . identifier =` is detected. `target` is `*Expr`
    /// so non-identifier receivers (e.g. `getBox().field = …`) parse
    /// cleanly via parsePostfix; `value` is value-typed Expr because
    /// it's the leaf of the assignment.
    field_assign: FieldAssignStmt,

    /// Backing struct for all three binding kinds (`let`, `var`, `const`).
    /// The kind is carried *by the union tag* on `Stmt`, not duplicated here
    /// in a payload-level field — Zig's tagged union already gives us
    /// exhaustive payload access (`stmt.let.init`, `stmt.var_binding.name`),
    /// so storing `kind` here would just be redundant and risk drift. The
    /// parser emits these from a single `parseBinding(kind)` helper that
    /// knows the expected keyword from `kind` and the canonical union tag
    /// from the dispatch site.
    pub const BindingStmt = struct {
        name: []const u8,
        /// Optional type annotation parsed from `name: T = expr`.
        /// `null` for un-annotated bindings (type inferred from `init`).
        type_name: ?[]const u8,
        init: Expr,
        /// Optional destructuring pattern. `null` for the plain
        /// `let NAME = INIT` form (codegen emits one zig binding per stmt).
        /// Non-`null` for destructuring forms like `let (a, b) = …` or
        /// `let [a, b, c] = arr` (codegen emits a temp `__destruct_<N>`
        /// followed by per-leaf bindings). When set, `name` is the empty
        /// sentinel and `type_name` must be `null` (the parser rejects
        /// `: T` annotations on destructuring forms because the doc does
        /// not specify a syntax for them).
        pattern: ?BindingPattern = null,
    };

    pub const AssignStmt = struct {
        /// Bare `name = expr` rebinding for an already-declared `var`.
        /// Zag's parser disambiguates this from a call/identifier expression
        /// with a one-token lookahead at statement-scope.
        name: []const u8,
        value: Expr,
    };

    /// `arr[i] = x` indexed-write. Empty-tuple payload is `.assign`'s
    /// counterpart for plain-name rebinding — the target/index paths make
    /// the destination non-identifier so a separate node is cleaner.
    pub const IndexAssignStmt = struct {
        target: *Expr,
        index: *Expr,
        value: Expr,
    };

    pub const DeferStmt = struct {
        expr: Expr,
    };

    /// `errdefer expr;` — runs `expr` ONLY when the enclosing scope exits
    /// via `?`-propagation or explicit `return Err(...)`. Mirrors zig 0.16's
    /// `errdefer` keyword one-to-one. Used by `docs/19-memory.md` Pattern 2
    /// (partial-init cleanup). Codegen emits `errdefer <expr>;` verbatim —
    /// zig's `errdefer` semantics already match the zag docs.
    pub const ErrDeferStmt = struct {
        expr: Expr,
    };

    /// `if cond { stmts... }` statement form with optional else-branch
    /// (block or else-if chain). The `else_kind` union collapses the three
    /// shapes into a single node: `.none` (no else), `.block` (terminal
    /// `else { … }`), or `.if_chain` (recursive `else if`). The recursive
    /// arm is boxed via `*IfStmt` so the struct doesn't need to be
    /// self-referential in the tagged union — the arena allocator backs
    /// the boxed node's storage lifetime.
    pub const IfStmt = struct {
        cond: Expr,
        then_body: []const Stmt,
        else_kind: IfElseKind,

        pub const IfElseKind = union(enum) {
            none: void,
            block: []const Stmt,
            /// `*IfStmt` boxed pointer — enables infinite-chain else-ifs
            /// (`if a {} else if b {} else if c {} else {}`) without the
            /// struct needing to be self-referential.
            if_chain: *IfStmt,
        };
    };

    /// `while cond { stmts... }` plain form (no `while let`).
    pub const WhileStmt = struct {
        cond: Expr,
        body: []const Stmt,
    };

    /// `for pat in iter { stmts... }` form. Pattern is the one-element
    /// subset (ident or discard) for this commit — see `for_stmt` Stmt
    /// variant doc above for the tuple-pattern followup.
    pub const ForStmt = struct {
        pattern: Pattern,
        iter: Expr,
        body: []const Stmt,
    };

    /// `return expr;` or bare `return;`. The `value` field is `null` for
    /// the bare form, `Expr` for the value form.
    pub const ReturnStmt = struct {
        value: ?Expr,
    };

    /// `target.field = value` field-write. The receiver path is any
    /// expression that parses via parsePostfix (ident, call result,
    /// index, etc.), and the field name is the bare identifier after
    /// the `.`. `target` is `*Expr` for cycle-breaking; `value` is
    /// value-typed Expr (leaf position).
    pub const FieldAssignStmt = struct {
        target: *Expr,
        field_name: []const u8,
        value: Expr,
    };
};

pub const FunDecl = struct {
    name: []const u8,
    body: []const Stmt,
    loc: Loc,
    doc: ?[]const u8,
};

/// One field in a struct declaration. Two shapes:
/// - `.named { name, type_text }` — `field: T` form. The `type_text` is
///   the verbatim source sequence after the colon (multi-token types
///   like `*const Foo` are captured as a single slice so codegen can
///   emit the type text without re-tokenizing).
/// - `.embed { type_name }` — bare `Widget,` row that promotes the
///   embedded type's fields + methods into the outer struct.
///   Codegen emits a `{ type_name: TypeName }` anonymous-struct
///   insertion so zig's `.field` access and `.method()` invocation
///   resolve through the outer struct without explicit field prefixes
///   in user code (the docs/12 embedding-promotes-fields contract).
///
/// The `idx` field on both arms records the position of THIS field
/// within the parent struct's field list, so codegen/walkers can quickly
/// map a field-init back to its declaration position if needed (the
/// ordering is preserved so structural copies and struct-literal codegen
/// stay byte-identical to the source declaration order).
pub const StructField = struct {
    /// 0-based position within the struct's field list.
    idx: u32,
    kind: StructFieldKind,

    pub const StructFieldKind = union(enum) {
        /// `name: T` field declaration. The `type_text` is captured
        /// verbatim so multi-token types like `*const T` round-trip.
        named: NamedField,
        /// Bare-typed promotion row (`Widget,` in the docs/12
        /// embedding example). `type_name` is the verbatim source
        /// ident; codegen emits a single anonymous-struct field whose
        /// value is a fresh instance of the embedded type.
        embed: EmbedField,

        pub const NamedField = struct {
            name: []const u8,
            type_text: []const u8,
        };
        pub const EmbedField = struct {
            type_name: []const u8,
        };
    };
};

/// One struct declaration of the form
/// `struct NAME { field-decl, ... }`. The `fields` slice preserves
/// declaration order so codegen emits zig struct fields in the same
/// sequence the user wrote them (preserves field-position assumptions
/// like `arr[0]` returning the first declared field's named-init
/// via spread). `loc` is carried so error messages on later uses of
/// the name can anchor to the declaration site.
pub const StructDecl = struct {
    name: []const u8,
    fields: []const StructField,
    loc: Loc,
};

/// One parameter on a method declaration inside an impl block. The
/// `name` is the verbatim source identifier; `type_text` is the verbatim
/// type after the colon (e.g. `*const Vec3`, `f64`). The `is_self`
/// flag distinguishes a `self`-prefixed receiver parameter from
/// positional parameters used in the constructor pattern
/// (`pub fun new(x: f64, y: f64) -> Vec3` — no `self`). Codegen
/// treats `is_self`-true receivers specially (the receiver is moved
/// to the first positional zig arg).
pub const MethodParam = struct {
    name: []const u8,
    type_text: []const u8,
    /// True iff this parameter is the receiver (`self: *const T` or
    /// `self: *T`). Codegen passes `&<receiver_expr>` for the implicit
    /// first-arg call from `.method_call` codegen (which doesn't expose
    /// `self` to the source author — they write `v.length()` not
    /// `v.length(self)`).
    is_self: bool,
};

/// One method inside an `impl` block. The `params` slice preserves
/// declaration order; `return_type` is `null` for bare constructor
/// methods (the return-type annotation is required when the author
/// wants typed return — when omitted, codegen falls through to zig's
/// type-inference path which is fine for expression-bodied simple
/// methods). The body is the same `[]const Stmt` shape as top-level
/// `fun` declarations, so codegen reuses the body-emission path.
pub const MethodDecl = struct {
    name: []const u8,
    params: []const MethodParam,
    return_type: ?[]const u8,
    body: []const Stmt,
    loc: Loc,
};

/// One `impl NAME { … }` block. The methods are flattened to zig free
/// functions by codegen (`pub fn Vec3_length(self: *const Vec3) f64`),
/// preserving the source-level method shape for human reading.
/// `target_type` is the verbatim source ident (e.g. `Vec3`); methods
/// reference `self` typed against this name so codegen's emit
/// translates structured source into accurately-typed zig free fns.
pub const ImplBlock = struct {
    target_type: []const u8,
    methods: []const MethodDecl,
    loc: Loc,
};

/// One enum declaration of the form
/// `enum NAME { Variant1, Variant2, Variant3(T), ... }`. The `variants`
/// slice preserves source declaration order so codegen emits zig's
/// native `enum { Variant1, Variant2, ... }` form in that same order.
/// Codegen also enables `Enum.Variant(arg)` constructor expressions by
/// emitting the enum's tag variants verbatim and zig's own exhaustive-
/// match checker enforces the docs/13 contract that every match must
/// handle every variant (or fall through to `_`).
pub const EnumDecl = struct {
    name: []const u8,
    variants: []const EnumVariant,
    loc: Loc,
};

/// One variant inside an `enum NAME { ... }`. `payload_type` is `null`
/// for bare tag-only variants (`Direction.North`); non-null for variants
/// carrying a single value whose type is the captured verbatim text
/// (`Shape.Circle` carries `payload_type = "f64"`). Multi-type payloads
/// (`Rect(f64, f64)`) round-trip through `payload_type` verbatim as
/// well — codegen emits the raw text inside the variant's parens.
pub const EnumVariant = struct {
    name: []const u8,
    payload_type: ?[]const u8,
    loc: Loc,
};

pub const Program = struct {
    functions: []const FunDecl,
    /// Module-level struct declarations. Codegen walks `structs` BEFORE
    /// `impls` and BEFORE `functions` so the order of zig emission matches
    /// the source order (types declared before use). The slices are
    /// ordered to match the parser's top-level walk (which interleaves
    /// struct/impl/fun decls in source order); codegen preserves that
    /// ordering by re-walking the source positions rather than relying
    /// on slice order alone. Per the docs/12 contract, struct embedding
    /// is resolved at codegen time by promoting embedded fields into
    /// the outer struct (see `genStructDecl`).
    structs: []const StructDecl = &[_]StructDecl{},
    /// Module-level impl blocks. Codegen walks `impls` after `structs`
    /// so zig's type checker sees the struct before its methods. Each
    /// method is emitted as a top-level zig free function whose name
    /// encodes the (target_type, method_name) pair so call-dispatch
    /// from `.method_call` codegen can find the right implementation.
    impls: []const ImplBlock = &[_]ImplBlock{},
    /// Module-level enum declarations. Codegen walks `enums` alongside
    /// `structs` and `impls` so types are declared before use in any
    /// subsequent function body. Like structs/impls, enums preserve
    /// source-order recording in the parser's main loop and are
    /// emitted at codegen time in source order so any guarantee that
    /// a downstream top-level fn or impl sees the type ahead of itself.
    enums: []const EnumDecl = &[_]EnumDecl{},
};

pub const Arena = struct {
    buf: [65536]u8,
    pos: usize,

    pub fn init() Arena {
        return .{ .buf = undefined, .pos = 0 };
    }

    pub fn alloc(self: *Arena, comptime T: type, count: usize) []T {
        const size = @sizeOf(T) * count;
        const align_bytes = @alignOf(T);
        const aligned_pos = (self.pos + align_bytes - 1) / align_bytes * align_bytes;
        const result = @as([*]T, @ptrCast(@alignCast(self.buf[aligned_pos .. aligned_pos + size])));
        self.pos = aligned_pos + size;
        return result[0..count];
    }

    pub fn dupe(self: *Arena, comptime T: type, slice: []const T) []T {
        const result = self.alloc(T, slice.len);
        @memcpy(result, slice);
        return result;
    }
};
