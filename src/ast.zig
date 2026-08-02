// Aggregator: src/ast.zig
//
// Re-exports all top-level types from the 5 sub-files. Nested union
// member types (e.g. ast.Expr.BinaryOp, ast.Stmt.IfStmt, ast.StructField
// .StructFieldKind.NamedField) remain accessible via the parent union
// or struct's NAMESPACE — no per-type re-export needed because they're
// already on the qualified type.

const ast_top = @import("ast/top.zig");
const ast_expr = @import("ast/expr.zig");
const ast_stmt = @import("ast/stmt.zig");
const ast_decl = @import("ast/decl.zig");
const ast_template = @import("ast/template.zig");

// Loc + Arena + Program (top-file utility types).
pub const Loc = ast_top.Loc;
pub const Arena = ast_top.Arena;
pub const Program = ast_top.Program;

// Expr union + Expr's nested member types stay on `ast.Expr.*` —
// External callers using `ast.Expr.BinaryOp`, `ast.Expr.NewExpr`,
// `ast.Expr.MatchArm` (sic, MatchExpr actually — re-exports below),
// etc. resolve via the Expr namespace.
// For top-level types also referenced outside Expr namespace:
pub const Expr = ast_expr.Expr;
pub const Pattern = ast_expr.Pattern;
// MatchArm is a TOP-LEVEL type (in expr.zig, not nested in Expr).
pub const MatchArm = ast_expr.MatchArm;
// Inline assembly (docs/manual/24 §"Inline Assembly"): the asm
// block expression + its named operand bindings, re-exported so
// parser/primary.zig's parseAsmExpr can reference `ast.AsmOperand`.
pub const AsmExpr = ast_expr.Expr.AsmExpr;
pub const AsmOperand = ast_expr.Expr.AsmOperand;
// Async/await (docs/manual/00-overview.md "Zero-cost async"):
// `await EXPR` expression node.
pub const AwaitExpr = ast_expr.Expr.AwaitExpr;

// Stmt union + its nested type aliases stay on `ast.Stmt.*`.
pub const Stmt = ast_stmt.Stmt;
// BindingKind / BindingPattern / RestBinding are top-level.
pub const BindingKind = ast_stmt.BindingKind;
pub const BindingPattern = ast_stmt.BindingPattern;
pub const RestBinding = ast_stmt.RestBinding;

// Decl-side types (all top-level).
pub const FunDecl = ast_decl.FunDecl;
pub const StructField = ast_decl.StructField;
pub const StructDecl = ast_decl.StructDecl;
pub const MethodParam = ast_decl.MethodParam;
pub const MethodDecl = ast_decl.MethodDecl;
pub const ImplBlock = ast_decl.ImplBlock;
/// TraitSpec (docs/17 §"Implementing"): one entry in an ImplBlock's
/// `with Trait (m1, m2)?, ...` clause. Re-exported here so parser-side
/// `ast.TraitSpec` references in `parseImplBlock` resolve uniformly
/// with the sibling decl-side types.
pub const TraitSpec = ast_decl.TraitSpec;
pub const EnumDecl = ast_decl.EnumDecl;
pub const EnumVariant = ast_decl.EnumVariant;
// v2-split landing (docs/manual/14-unions §\"Definition\"): the
// brace-named-field variant syntax `Drag { x: f64, y: f64 }` requires
// a structured AST shape per named-field slot (vs. the legacy joined-
// text payload_type). VariantField carries the per-slot name +
// verbatim type-text so codegen can emit `struct { x: f64, y: f64 }`
// preserving the user's actual field names (instead of the legacy
// single-letter a/b/c/... scheme). Without this re-export, parser/
// decl.zig's `fields_buf[...]: ast.VariantField` references would
// surface as `ast.VariantField not found` at compile time.
pub const VariantField = ast_decl.VariantField;
// gap #6 (docs/manual/14-unions §\"Definition\" + docs/manual/13-enums
// §\"Choosing Between enum and union\"): brace-named-field MATCH-side
// destructuring (`Variant { x: w, y: h } => ...`) is a parallel
// sibling to gap #2 ctor-side. The pattern-side `Pattern.EnumVariant
// NamedPattern` carries the same per-slot structured shape as
// gap #2's `EnumVariant.fields` (`ast.VariantField`), but the
// pattern instead of a type-text is `name` + optional `capture`
// ident (null = `_` wildcard discard). These nested types live
// inside the `pub const Pattern = union(enum) { ... }` block
// in `src/ast/expr.zig`; without these top-level re-exports the
// parser-side `field_buf: [16]ast.VariantFieldPattern` references
// in `src/parser/stmt.zig`'s brace-form walker surface as
// `root source file struct 'ast' has no member named
// 'VariantFieldPattern'` at compile time (the exact diagnostic
// surfaced in this turn's first build attempt).
pub const VariantFieldPattern = ast_expr.Pattern.VariantFieldPattern;
pub const EnumVariantNamedPattern = ast_expr.Pattern.EnumVariantNamedPattern;
// Traits (docs/17). TraitDecl + TraitMethodDecl are the decl-side
// AST nodes for trait declarations. Phase 1 (this commit) scaffolds
// only lexer/AST/parser; codegen for vtable + dispatch shims lives
// in Phase 2. The aggregator re-exports here so `ast.TraitDecl` and
// `ast.TraitMethodDecl` (referenced from Program and parser) resolve
// uniformly with the existing decl-side types above.
pub const TraitDecl = ast_decl.TraitDecl;
pub const TraitMethodDecl = ast_decl.TraitMethodDecl;
// Generics (docs/16). The TypeParam struct lives next to FunDecl
// in decl.zig and is referenced from parser/decl.zig helpers
// (`parseTypeParam`, `parseTypeParams`). The aggregator re-export
// preserves the `ast.TypeParam` access path documented for the
// AST-laundering layer in main.zig.
pub const TypeParam = ast_decl.TypeParam;
// Module imports (docs/manual/22-modules.md §Imports).
// ImportSelector is the AST node for one entry in the optional
// `{A, B as C}` selective list attached to a `pub import std.X.{...}`
// decl. ImportDecl is the AST node carrying the dotted path nodes,
// optional selective-list, and `is_pub` flag. Both are referenced
// from parser/decl.zig's parseImportDecl and reachable on
// `Program.imports` via the top.zig aggregator.
pub const ImportSelector = ast_decl.ImportSelector;
pub const ImportDecl = ast_decl.ImportDecl;
// Module re-exports (docs/manual/22-modules.md §Re-exports): the
// `[pub] use <dotted-path> as <name>` decl. Codegen emits
// `pub const <name> = @import(...)` so `<name>.member` resolves to
// the re-exported module's namespace.
pub const UseDecl = ast_decl.UseDecl;
// FFI (docs/24). ExternDecl carries `extern fun` declarations.
pub const ExternDecl = ast_decl.ExternDecl;
// Compile-time (docs/26). ConstDecl carries `const NAME = EXPR` declarations.
pub const ConstDecl = ast_decl.ConstDecl;

// Template-literal types (extracted from Expr union body, now top-level).
pub const TemplateLitExpr = ast_template.TemplateLitExpr;
pub const TemplatePart = ast_template.TemplatePart;
