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
    template_lit: TemplateLitExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    index: IndexExpr,
    range: RangeExpr,

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
    };

    pub const FreeExpr = struct {
        target: *Expr,
    };

    pub const DerefExpr = struct {
        target_ptr: *Expr,
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
    expr_stmt: Expr,

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
