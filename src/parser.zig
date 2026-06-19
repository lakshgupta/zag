const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

pub const Parser = struct {
    tokens: []const Token,
    pos: u32,
    arena: *ast.Arena,

    pub fn init(tokens: []const Token, arena: *ast.Arena) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
        };
    }

    pub fn parse(self: *Parser) ast.Program {
        var functions_buf: [256]ast.FunDecl = undefined;
        var fun_count: usize = 0;

        while (!self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            functions_buf[fun_count] = self.parseFunDecl();
            fun_count += 1;
        }

        const functions = self.arena.alloc(ast.FunDecl, fun_count);
        @memcpy(functions, functions_buf[0..fun_count]);
        return .{ .functions = functions };
    }

    fn parseFunDecl(self: *Parser) ast.FunDecl {
        const start = self.peek().loc;
        self.expect(.fun);
        const name = self.expectIdent();
        self.expect(.lparen);
        self.expect(.rparen);
        const body = self.parseBlock();
        return .{ .name = name, .body = body, .loc = start };
    }

    fn parseBlock(self: *Parser) []const Stmt {
        self.expect(.lbrace);
        var stmts_buf: [256]Stmt = undefined;
        var stmt_count: usize = 0;

        while (self.peek().tag != .rbrace and !self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            stmts_buf[stmt_count] = self.parseStmt();
            stmt_count += 1;
        }

        self.expect(.rbrace);
        const stmts = self.arena.alloc(Stmt, stmt_count);
        @memcpy(stmts, stmts_buf[0..stmt_count]);
        return stmts;
    }

    fn parseStmt(self: *Parser) Stmt {
        const tok = self.peek();
        switch (tok.tag) {
            .let => return .{ .let = self.parseLet() },
            .defer_kw => return .{ .defer_stmt = self.parseDefer() },
            else => return .{ .expr_stmt = self.parseExpr() },
        }
    }

    fn parseLet(self: *Parser) Stmt.LetStmt {
        self.expect(.let);
        const name = self.expectIdent();
        self.expect(.equals);
        const initializer = self.parseExpr();
        return .{ .name = name, .init = initializer };
    }

    fn parseDefer(self: *Parser) Stmt.DeferStmt {
        self.expect(.defer_kw);
        const expr = self.parseExpr();
        return .{ .expr = expr };
    }

    fn parseExpr(self: *Parser) Expr {
        const tok = self.peek();

        switch (tok.tag) {
            .new => return self.parseNew(),
            .free => return self.parseFree(),
            .print, .identifier => {
                const saved = self.pos;
                const name = tok.text;
                self.advance();
                if (self.peek().tag == .lparen) {
                    return self.parseCallExpr(name);
                } else {
                    self.pos = saved;
                    return .{ .ident = name };
                }
            },
            .string_literal => {
                self.advance();
                return .{ .string_lit = tok.text };
            },
            .integer_literal => {
                self.advance();
                const val = std.fmt.parseInt(i64, tok.text, 0) catch 0;
                return .{ .int_lit = val };
            },
            .star => {
                self.advance();
                const target = self.parseExpr();
                const t = self.arena.alloc(Expr, 1);
                t[0] = target;
                return .{ .deref = .{ .target_ptr = &t[0] } };
            },
            .lparen => {
                self.advance();
                const inner = self.parseExpr();
                self.expect(.rparen);
                return inner;
            },
            else => {
                self.advance();
                return .{ .ident = tok.text };
            },
        }
    }

    fn parseCallExpr(self: *Parser, name: []const u8) Expr {
        self.expect(.lparen);
        var args_buf: [32]Expr = undefined;
        var arg_count: usize = 0;

        while (self.peek().tag != .rparen and !self.eof()) {
            if (self.peek().tag == .comma) {
                self.advance();
                continue;
            }
            args_buf[arg_count] = self.parseExpr();
            arg_count += 1;
        }

        self.expect(.rparen);
        const args = self.arena.alloc(Expr, arg_count);
        @memcpy(args, args_buf[0..arg_count]);
        return .{ .call = .{ .name = name, .args = args } };
    }

    fn parseNew(self: *Parser) Expr {
        self.expect(.new);
        const type_name = self.expectIdent();
        self.expect(.lparen);
        const value = self.parseExpr();
        self.expect(.rparen);
        const v = self.arena.alloc(Expr, 1);
        v[0] = value;
        return .{ .new_expr = .{ .type_name = type_name, .value = &v[0] } };
    }

    fn parseFree(self: *Parser) Expr {
        self.expect(.free);
        const target = self.parseExpr();
        const t = self.arena.alloc(Expr, 1);
        t[0] = target;
        return .{ .free_expr = .{ .target = &t[0] } };
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn eof(self: *Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].tag == .eof;
    }

    fn expect(self: *Parser, tag: TokenTag) void {
        if (self.peek().tag != tag) {
            const tok = self.peek();
            std.debug.print("error:{d}:{d}: expected {s}, got '{s}'\n", .{
                tok.loc.line,
                tok.loc.col,
                @tagName(tag),
                tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
    }

    fn expectIdent(self: *Parser) []const u8 {
        const tok = self.peek();
        if (tok.tag != .identifier and tok.tag != .print) {
            std.debug.print("error:{d}:{d}: expected identifier, got '{s}'\n", .{
                tok.loc.line,
                tok.loc.col,
                tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
        return tok.text;
    }
};
