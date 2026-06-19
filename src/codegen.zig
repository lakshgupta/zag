const std = @import("std");
const ast = @import("ast.zig");

pub const Codegen = struct {
    out_buf: [65536]u8,
    out_len: usize,

    pub fn init() Codegen {
        return .{
            .out_buf = undefined,
            .out_len = 0,
        };
    }

    fn write(self: *Codegen, s: []const u8) void {
        @memcpy(self.out_buf[self.out_len .. self.out_len + s.len], s);
        self.out_len += s.len;
    }

    pub fn generate(self: *Codegen, prog: ast.Program) []const u8 {
        self.write(
            \\const std = @import("std");
            \\
            \\pub fn print_fn(msg: []const u8) void {
            \\    std.debug.print("{s}", .{msg});
            \\}
            \\
        );

        for (prog.functions) |fun| {
            self.genFun(fun);
        }

        return self.out_buf[0..self.out_len];
    }

    fn genFun(self: *Codegen, fun: ast.FunDecl) void {
        self.write("pub fn ");
        self.write(fun.name);
        self.write("() !void {\n");

        for (fun.body) |stmt| {
            self.genStmt(stmt);
        }

        self.write("}\n\n");
    }

    fn genStmt(self: *Codegen, stmt: ast.Stmt) void {
        switch (stmt) {
            .let => |l| {
                self.write("    const ");
                self.write(l.name);
                self.write(" = ");
                self.genExpr(l.init);
                self.write(";\n");
            },
            .defer_stmt => |d| {
                self.write("    defer ");
                self.genExpr(d.expr);
                self.write(";\n");
            },
            .expr_stmt => |e| {
                self.write("    ");
                self.genExpr(e);
                self.write(";\n");
            },
        }
    }

    fn genExpr(self: *Codegen, expr: ast.Expr) void {
        switch (expr) {
            .string_lit => |s| {
                self.write("\"");
                self.write(s);
                self.write("\"");
            },
            .int_lit => |v| {
                var buf: [20]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
                self.write(str);
            },
            .ident => |name| {
                self.write(name);
            },
            .call => |c| {
                if (std.mem.eql(u8, c.name, "print")) {
                    if (c.args.len == 1) {
                        switch (c.args[0]) {
                            .string_lit => |str| {
                                self.write("std.debug.print(\"");
                                self.write(str);
                                self.write("\", .{})");
                            },
                            else => {
                                self.write("std.debug.print(\"{}\", .{");
                                self.genExpr(c.args[0]);
                                self.write("})");
                            },
                        }
                    }
                } else {
                    self.write(c.name);
                    self.write("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(arg);
                    }
                    self.write(")");
                }
            },
            .new_expr => |n| {
                self.write("blk: { var __val: ");
                self.write(n.type_name);
                self.write(" = ");
                self.genExpr(n.value.*);
                self.write("; break :blk &__val; }");
            },
            .free_expr => |f| {
                self.write("std.heap.page_allocator.destroy(");
                self.genExpr(f.target.*);
                self.write(")");
            },
            .deref => |d| {
                self.write("(&");
                self.genExpr(d.target_ptr.*);
                self.write(").*");
            },
        }
    }
};
