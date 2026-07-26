const std = @import("std");

// EXPR: BindingStmt.init: Expr, match_stmt:
// Expr.MatchExpr, ForStmt.pattern: Pattern, plus
// several other Expr-typed fields across the Stmt
// union members. Module-local aliases let the bodies
// reference `Expr` / `Pattern` unqualified.
const expr = @import("expr.zig");
const Expr = expr.Expr;
const Pattern = expr.Pattern;

// TOP: Loc for statement source locations.
const top = @import("top.zig");
const Loc = top.Loc;

// ============================================================
// stmt.zig — top-level types from src/ast.zig
// ============================================================

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

pub const Stmt = struct {
    /// Backing struct for all three binding kinds (`let`, `var`, `const`).
    /// The kind is carried *by the union tag* on `Payload`, not duplicated here
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
        /// Initializer expression. `null` ONLY for compile-time block
        /// bindings (`const NAME: T = const { … return EXPR; }`), where
        /// the value-yielding body lives on `block`. Non-`null` for every
        /// other binding kind (let / var / const plain + destructuring).
        /// Codegen gates on `b.init != null` (and `b.block != null`
        /// first) so a const-block binding's null init is never read.
        init: ?Expr = null,
        /// Optional destructuring pattern. `null` for the plain
        /// `let NAME = INIT` form (codegen emits one zig binding per stmt).
        /// Non-`null` for destructuring forms like `let (a, b) = …` or
        /// `let [a, b, c] = arr` (codegen emits a temp `__destruct_<N>`
        /// followed by per-leaf bindings). When set, `name` is the empty
        /// sentinel and `type_name` must be `null` (the parser rejects
        /// `: T` annotations on destructuring forms because the doc does
        /// not specify a syntax for them).
        pattern: ?BindingPattern = null,
        /// `const NAME: T = const { … return EXPR; };` compile-time
        /// block form (docs/manual/16-generics.md §6 "Compile-Time Type
        /// Parameters"). `null` for ordinary value bindings. When set,
        /// codegen emits the body as a zig labeled block
        /// `const NAME: T = blk: { ...stmts... break :blk EXPR; };`,
        /// translating the user's `return EXPR;` terminator into
        /// `break :blk EXPR;`. Only valid on `.const_binding` AST tag;
        /// the parser rejects `let x = const { … }` and `var x = const
        /// { … }` at parse time. Mutually exclusive with `pattern`
        /// (destructuring is not allowed on a const-block binding) and
        /// with `init` (a non-null init on a const-block binding is a
        /// codegen bug — the bind's value comes from `block`'s tail
        /// `return EXPR;`).
        block: ?[]const Stmt = null,
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
        /// True when `if let` syntax was used.
        is_if_let: bool = false,
        /// Pattern from `if let Pattern = expr`. Only valid when is_if_let.
        if_let_pat: Pattern = undefined,

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
        /// True when `while let` syntax was used.
        is_while_let: bool = false,
        /// Pattern from `while let Pattern = expr`. Only valid when is_while_let.
        while_let_pat: Pattern = undefined,
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

    /// `*p = value` dereference-write. The LHS pointer must be a bare
    /// identifier (the parser's `.star` arm enforces this via
    /// `expectIdent`); complex deref-trees are not supported by this
    /// AST slot. Zig's postfix deref-write `p.* = value` is the
    /// canonical emit shape -- the user-facing syntax `*p = value`
    /// matches the canonical zig surface because zig's `.star` is
    /// left-associative: `*p = value` parses as `*(p = value)` in
    /// zig, which is exactly the deref-write form. `name` carries
    /// the bare identifier text (no leading `*`); `value` is the
    /// value-typed Expr (leaf position, value-typed not pointer-typed
    /// because it is the RHS of an assignment, not a target).
    pub const DerefAssignStmt = struct {
        name: []const u8,
        value: Expr,
    };

    /// The statement payload — all possible statement kinds.
    pub const Payload = union(enum) {
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
        /// `*p = expr` dereference-write statement. Distinct from
        /// `.assign` because the LHS is a deref of a bare-named pointer
        /// rather than a rebind. The 3-token lookahead at parseStmt's
        /// `.star` arm dispatches into this variant when the pattern
        /// `star identifier equals` is detected. The parser restricts the
        /// LHS to a bare identifier (no complex deref-trees like
        /// `*obj.field` or `*arr[i]` for this slot; users wanting those
        /// forms should extract a local first). Codegen emits
        /// `name.* = value;` -- zig 0.16's postfix deref-and-write form,
        /// semantically equivalent to the source-side `*p = x`.
        deref_assign: DerefAssignStmt,
    };

    payload: Payload,
    loc: Loc,
};

