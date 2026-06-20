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

    pub const PatternRange = struct {
        start: *Expr,
        end: *Expr,
        inclusive: bool,
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
};

pub const FunDecl = struct {
    name: []const u8,
    body: []const Stmt,
    loc: Loc,
    doc: ?[]const u8,
};

pub const Program = struct {
    functions: []const FunDecl,
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
