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

// Template-literal types (extracted from Expr union body, now top-level).
pub const TemplateLitExpr = ast_template.TemplateLitExpr;
pub const TemplatePart = ast_template.TemplatePart;
