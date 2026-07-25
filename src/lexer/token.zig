const std = @import("std");
const ast = @import("../ast.zig");

// ============================================================
// token.zig — top-level types from src/lexer.zig
// ============================================================

pub const TokenTag = enum {
    fun,
    let,
    var_kw,
    const_kw,
    defer_kw,
    errdefer_kw,
    unsafe_kw,
    new,
    free,
    print,
    as_kw,
    return_kw,
    /// `struct` keyword — introduces a struct declaration
    /// (`struct Vec3 { x: f64, … }`). Distinct from `.struct_lit` AST
    /// variant which lives downstream at the expression level.
    struct_kw,
    /// `impl` keyword — introduces an impl block
    /// (`impl Vec3 { pub fun length(...) -> … { … } }`). Methods inside
    /// the block are flattened to zig free functions by codegen.
    impl_kw,
    /// `enum` keyword — introduces a bare-enumeration declaration
    /// (`enum Direction { North, South, East, West }`). In the v2 split
    /// landed by surfacing the keyword surface (docs/manual/14-unions
    /// §"Definition"), `enum` strictly means bare-enumeration: variants
    /// cannot carry a payload (the parser rejects `enum X { Foo(T) }`
    /// with `expected variant or '}', got '('`); use `union` for
    /// payload-bearing forms. Variants are tokenized as bare
    /// identifiers (PascalCase by convention) and codegen emits the
    /// declared enum as zig's native `enum { ... }` form so functions
    /// over variants compile via zig's exhaustive match checking.
    enum_kw,
    /// `union` keyword — introduces a tagged-union declaration
    /// (`union Shape { Circle(f64), Rect(f64, f64), Empty }`). The
    /// v2 split (docs/manual/13-enums §"Choosing Between enum and
    /// union") reserves `union` for any type whose variants carry
    /// payloads (or mix bare + payload variants — bare variants inside
    /// a union are zero-cost because their slot is purely the tag).
    /// Variants accept three shapes: bare (`Empty`), paren-positional
    /// (`Circle(f64)`, `Rect(f64, f64)`), or brace-named-field
    /// (`Drag { x: f64, y: f64 }`). Codegen emits the declared union as
    /// zig's `union(enum) { ... }` form so users get exhaustive-match
    /// checking on the tag.
    union_kw,
    /// `trait` keyword — introduces a trait declaration
    /// (`trait Drawable { fun draw(self: *Self); fun name(self: *Self) -> str; }`).
    /// Phase 1 (this commit) scaffolds only the lexer/parser surface;
    /// codegen lives in Phase 2 (Methods with required-only bodies; no
    /// default-method bodies; no `Self` keyword — `Self` is captured
    /// verbatim into MethodParam.type_text and rewrite happens at
    /// codegen time so we don't add a new lexer token in Phase 1).
    trait_kw,
    /// `with` keyword — introduces the trait-spec list on an impl block
    /// (`impl Button with Drawable (print), Show { ... }`, docs/17 §"Implementing").
    /// The clause that follows names one or more traits this block
    /// implements, each optionally parenthesised with preferred method
    /// names that disambiguate the diamond (same method name appearing
    /// in multiple listed traits). Phase: lands as part of the canonical
    /// `impl Type with Trait (m) { ... }` form rollout.
    with_kw,
    /// `pub` keyword — visibility modifier on top-level decls and
    /// methods. Spec framing reserves privacy enforcement to a followup;
    /// current parser accepts-and-ignores it (the keyword is preserved
    /// in the AST for future use but codegen does not gate emission on
    /// `pub` because all generated decls already use zig's `pub fn`).
    pub_kw,
    /// `import` keyword — top-level decl that brings another module's
    /// declarations into scope. Two surface shapes:
    ///   1. `import std.string`              (whole-module import)
    ///   2. `pub import std.atomic.{AtomicI32, Ordering.AcqRel}` (selective import with optional alias)
    /// Resolved against the KNOWN_STD_MODULES lookup table in
    /// `src/parser/core.zig` (any `import std.X` whose path matches a
    /// table entry routes to the on-disk `.zag` source at that entry's
    /// recorded path). User module imports (`import foo` — top-level
    /// directory name) are a follow-up parser pass; v1 only resolves
    /// `std.*` paths.
    import_kw,
    /// Reserved with `_kw` suffix because `if`/`else`/`while`/`for`/`match`/
    /// `break`/`continue` are reserved words in the Zig backend (the lexer
    /// cannot name a TokenTag literal `if`/`else`/etc. without colliding
    /// with the corresponding zig keyword). `in` is not zig-reserved but
    /// gets the suffix for naming consistency across the suite.
    if_kw,
    else_kw,
    while_kw,
    for_kw,
    in_kw,
    match_kw,
    break_kw,
    /// `catch` keyword — introduces error-handling expression
    /// (`risky_call() catch 0` or `risky_call() catch |err| handle(err)`).
    catch_kw,
    continue_kw,
    true_kw,
    false_kw,
    null_kw,
    undefined_kw,
    string_literal,
    byte_string_literal,
    char_literal,
    integer_literal,
    float_literal,
    identifier,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    colon,
    // The vast majority of these operators come from `docs/manual/05-operators.md`
    // and were added in one pass to expose the documented operator surface.
    // All multi-char forms (`<=`, `+=`, `&&`, et al.) are disambiguated in
    // the `tokenize` loop by peeking the second and third chars from the
    // current `pos` before consuming.
    equals, // `=` (also the leading char of `==`, `+=`, `-=`, …)
    plus,
    minus,
    star,
    slash,
    percent, // `%`
    amp, // `&`
    pipe, // `|`
    caret, // `^`
    tilde, // `~`
    lt, // `<`
    gt, // `>`
    lt_eq, // `<=`
    gt_eq, // `>=`
    bang, // `!`
    eq_eq, // `==`
    bang_eq, // `!=`
    amp_amp, // `&&`
    pipe_pipe, // `||`
    lt_lt, // `<<`
    gt_gt, // `>>`
    plus_eq, // `+=`
    minus_eq, // `-=`
    star_eq, // `*=`
    slash_eq, // `/=`
    percent_eq, // `%=`
    amp_eq, // `&=`
    pipe_eq, // `|=`
    caret_eq, // `^=`
    lt_lt_eq, // `<<=`
    gt_gt_eq, // `>>=`
    range, // `..` (half-open range; doc range table also lists `...` which is `ellipsis` for inclusive)
    comma,
    arrow,
    ellipsis,
    /// `?` — used in nullable pointer type annotations like `?*T` and
    /// `?i32`. Distinct from `as`'s destination-type syntax because the
    /// `?` is part of the type identifier, not a separate operator —
    /// `collectCastType` consumes the leading `?` and concatenates it
    /// to the rest of the type verbatim so the emitted zig type mirrors
    /// zag's surface (`?*T` → `?*T`, `?i32` → `?i32`).
    question,
    /// `.` — the standalone dot operator. Used for postfix member access
    /// (`v.x`), method call (`v.length()`, `Vec3.new(...)`), and as the
    /// leading byte of `..` (range) and `...` (ellipsis). The parser
    /// dispatches based on what follows the `.`: an identifier chains
    /// into `.member_access` (no parens) or `.method_call` (parens); a
    /// second `.` short-circuits into the range/ellipsis arms.
    dot,
    newline,
    doc_comment,
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    loc: ast.Loc,
    text: []const u8,
};

