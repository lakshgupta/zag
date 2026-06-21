const std = @import("std");

// TOP: every decl has a `loc: Loc` field.
const top = @import("top.zig");
const Loc = top.Loc;

// EXPR: MethodParam.default_value: ?*const Expr.
const expr = @import("expr.zig");
const Expr = expr.Expr;

// STMT: FunDecl.body / MethodDecl.body: []const Stmt.
const stmt = @import("stmt.zig");
const Stmt = stmt.Stmt;

// ============================================================
// decl.zig — top-level types from src/ast.zig
// ============================================================

pub const FunDecl = struct {
    name: []const u8,
    /// Parameter list, parsed comma-separated `name: type` form (with
    /// optional `var` prefix and `...` suffix, plus optional `= default`
    /// tail). Mirrors `MethodDecl.params` shape so codegen emits the
    /// zig `pub fn NAME(p1: T1, p2: T2, ...) RET_TYPE {` signature
    /// verbatim. Empty slice means no parameters (existing legacy form).
    /// Phase 2: full decl params; Phase 1 was `pub fn NAME() !void`.
    params: []const MethodParam = &[_]MethodParam{},
    body: []const Stmt,
    loc: Loc,
    doc: ?[]const u8,
    /// Optional return type annotation `fun foo(...) -> RET_TYPE { … }`.
    /// `null` when the source omits the arrow clause (legacy form,
    /// still entered as `pub fn NAME() !void`). Codegen falls back to
    /// zig's type-inference downstream when `null`.
    return_type: ?[]const u8 = null,
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
    /// `var x: T` parameter marker (docs/15 §"Parameters"). When true,
    /// codegen emits `var x = x;` at the body top so mutations to `x`
    /// don't reach the caller's binding. `false` (default) preserves
    /// the parameter-as-immutable-binding semantic per the docs.
    is_var: bool = false,
    /// `x: T...` variadic-parameter marker. When true, the parameter
    /// receives a slice-typed value (e.g. `values: []const i32`) so the
    /// body can iterate via `for v in values`. Codegen folds  ... /
    /// slicer-spell via @call() at the call site when args are literal
    /// (see `Phase 2+` notes in docs/15).
    is_variadic: bool = false,
    /// `x: T = EXPR` default-value marker. Codegen treats the param
    /// as optional and at every call site emits a shim pass that
    /// substitutes the default. Direct zig codegen path: emit the
    /// default as a sentinel `__opt_<i>` arg and let the body branch.
    /// Currently parser-side only — full call-site shaping is Phase 3
    /// because zag has no type-resolver to count args per call site.
    default_value: ?*const Expr = null,
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

