const std = @import("std");

pub const Loc = struct {
    line: u32,
    col: u32,
    offset: u32,
};

pub const Expr = union(enum) {
    string_lit: []const u8,
    int_lit: i64,
    ident: []const u8,
    call: CallExpr,
    new_expr: NewExpr,
    free_expr: FreeExpr,
    deref: DerefExpr,

    pub const CallExpr = struct {
        name: []const u8,
        args: []const Expr,
    };

    pub const NewExpr = struct {
        type_name: []const u8,
        value: *Expr,
    };

    pub const FreeExpr = struct {
        target: *Expr,
    };

    pub const DerefExpr = struct {
        target_ptr: *Expr,
    };
};

pub const Stmt = union(enum) {
    let: LetStmt,
    defer_stmt: DeferStmt,
    expr_stmt: Expr,

    pub const LetStmt = struct {
        name: []const u8,
        init: Expr,
    };

    pub const DeferStmt = struct {
        expr: Expr,
    };
};

pub const FunDecl = struct {
    name: []const u8,
    body: []const Stmt,
    loc: Loc,
};

pub const Program = struct {
    functions: []const FunDecl,
};

pub const Arena = struct {
    buf: [65536]u8,
    pos: usize,

    pub fn init() Arena {
        return .{ .buf = undefined, .pos = 0 };
    }

    pub fn alloc(self: *Arena, comptime T: type, count: usize) []T {
        const size = @sizeOf(T) * count;
        const align_bytes = @alignOf(T);
        const aligned_pos = (self.pos + align_bytes - 1) / align_bytes * align_bytes;
        const result = @as([*]T, @ptrCast(@alignCast(self.buf[aligned_pos .. aligned_pos + size])));
        self.pos = aligned_pos + size;
        return result[0..count];
    }

    pub fn dupe(self: *Arena, comptime T: type, slice: []const T) []T {
        const result = self.alloc(T, slice.len);
        @memcpy(result, slice);
        return result;
    }
};
