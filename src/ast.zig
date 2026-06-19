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

    pub const BinaryOp = enum {
        add,
        sub,
        mul,
        div,
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
    };

    pub const AssignStmt = struct {
        /// Bare `name = expr` rebinding for an already-declared `var`.
        /// Zag's parser disambiguates this from a call/identifier expression
        /// with a one-token lookahead at statement-scope.
        name: []const u8,
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
