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
pub const EnumDecl = ast_decl.EnumDecl;
pub const EnumVariant = ast_decl.EnumVariant;
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

// Template-literal types (extracted from Expr union body, now top-level).
pub const TemplateLitExpr = ast_template.TemplateLitExpr;
pub const TemplatePart = ast_template.TemplatePart;
