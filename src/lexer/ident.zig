const std = @import("std");

// core: readIdent is a method on `*Lexer`, defined here
// at file scope so the core.zig method alias can route to it.
const core = @import("core.zig");
const Lexer = core.Lexer;

const token = @import("token.zig");
const TokenTag = token.TokenTag;

const ast = @import("../ast.zig");
const Loc = ast.Loc;

// ============================================================
// ident.zig
// ============================================================

pub     fn readIdent(self: *Lexer, start_loc: ast.Loc) void {
    const start = self.pos;
    while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
        self.pos += 1;
        self.col += 1;
    }
    const text = self.src[start..self.pos];
    const tag: TokenTag = if (std.mem.eql(u8, text, "fun"))
        .fun
    else if (std.mem.eql(u8, text, "let"))
        .let
    else if (std.mem.eql(u8, text, "var"))
        .var_kw
    else if (std.mem.eql(u8, text, "const"))
        .const_kw
    else if (std.mem.eql(u8, text, "defer"))
        .defer_kw
    else if (std.mem.eql(u8, text, "errdefer"))
        .errdefer_kw
    else if (std.mem.eql(u8, text, "unsafe"))
        .unsafe_kw
    else if (std.mem.eql(u8, text, "as"))
        .as_kw
    else if (std.mem.eql(u8, text, "struct"))
        .struct_kw
    else if (std.mem.eql(u8, text, "impl"))
        .impl_kw
    else if (std.mem.eql(u8, text, "enum"))
        .enum_kw
    else if (std.mem.eql(u8, text, "pub"))
        .pub_kw
    else if (std.mem.eql(u8, text, "new"))
        .new
    else if (std.mem.eql(u8, text, "free"))
        .free
    else if (std.mem.eql(u8, text, "print"))
        .print
    else if (std.mem.eql(u8, text, "return"))
        .return_kw
    else if (std.mem.eql(u8, text, "if"))
        .if_kw
    else if (std.mem.eql(u8, text, "else"))
        .else_kw
    else if (std.mem.eql(u8, text, "while"))
        .while_kw
    else if (std.mem.eql(u8, text, "for"))
        .for_kw
    else if (std.mem.eql(u8, text, "in"))
        .in_kw
    else if (std.mem.eql(u8, text, "match"))
        .match_kw
    else if (std.mem.eql(u8, text, "break"))
        .break_kw
    else if (std.mem.eql(u8, text, "continue"))
        .continue_kw
    else if (std.mem.eql(u8, text, "true"))
        .true_kw
    else if (std.mem.eql(u8, text, "false"))
        .false_kw
    else if (std.mem.eql(u8, text, "null"))
        .null_kw
    else if (std.mem.eql(u8, text, "undefined"))
        .undefined_kw
    else
        .identifier;

    self.addToken(.{ .tag = tag, .loc = start_loc, .text = text });
}

