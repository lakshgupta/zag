// Aggregator: src/lexer.zig
//
// Re-exports the 3 public types from the lexer sub-tree at module
// scope. (There are NO `Lexer.TokenTag` / `Lexer.Token` nested-struct
// access paths — the version that added those aliases caused an
// "ambiguous reference Token" compile error and was reverted in
// favor of module-scope-only re-exports. External code uses
// `lexer_mod.TokenTag.X` and `lexer_mod.Lexer.X` exclusively, so
// nothing was lost.)

const lexer_token = @import("lexer/token.zig");
const lexer_core = @import("lexer/core.zig");

pub const TokenTag = lexer_token.TokenTag;
pub const Token = lexer_token.Token;
pub const Lexer = lexer_core.Lexer;
