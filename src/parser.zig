// src/parser.zig - thin aggregator.
pub const Parser = @import("parser/core.zig").Parser;
// Re-exports for cross-module consumers (the `scaffold-tests` build
// module is the primary user). The scaffold module is rooted at
// `tests/scaffold.zig`, so its path scope is `tests/` and direct
// `@import("src/ast.zig")` or `@import("src/lexer.zig")` is rejected
// as "outside module path" by zig 0.16. To give scaffold.zig a clean
// surface that exposes both `ast` types (Arena, Program, ImportDecl,
// ...) and the Lexer without needing three separate helper modules
// (which would create a file-membership conflict on
// `src/lexer/token.zig` — that file is imported by both src/ast.zig
// and src/lexer.zig's modules, and zig requires files to belong to
// at most one module), we route everything through this parser
// aggregator: ONE helper module rooted at `src/parser.zig` brings
// in src/ast.zig, src/lexer.zig, and src/parser/* transitively, and
// scaffold.zig does `@import("parser")` to reach the surface below.
pub const ast = @import("ast.zig");
pub const Lexer = @import("lexer.zig").Lexer;
// E2E helper re-export: tests/e2e.zig needs `Codegen.init()` to run
// the in-process lex+parse+codegen hop. Adding a SECOND helper module
// rooted at `src/codegen.zig` would create a file-membership
// collision on `src/lexer/token.zig` (src/codegen/core.zig
// transitively imports src/parser.zig which transitively imports
// src/lexer/token.zig -- which the existing scaffold helper rooted
// here ALREADY pulls in; zig's at-most-one-module-per-source-file
// rule would reject the second pull). Re-exporting Codegen here
// keeps the e2e using ONE shared helper module (this parser.zig
// module) and avoids the collision; scaffold is unaffected (it
// never references Codegen). The first attempt to use a separate
// codegen module + this module failed with "file exists in
// modules X and Y" exactly as the scaffold_mod docblock above
// predicted for the three-helper case.
pub const Codegen = @import("codegen.zig").Codegen;
