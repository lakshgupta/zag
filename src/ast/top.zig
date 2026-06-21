const std = @import("std");

// DECL: Program.functions/structs/impls/enums reference
// decl-side types.
const decl = @import("decl.zig");
const FunDecl = decl.FunDecl;
const StructDecl = decl.StructDecl;
const ImplBlock = decl.ImplBlock;
const EnumDecl = decl.EnumDecl;

// ============================================================
// top.zig — top-level types from src/ast.zig
// ============================================================

pub const Loc = struct {
    line: u32,
    col: u32,
    offset: u32,
};

pub const Program = struct {
    functions: []const FunDecl,
    /// Module-level struct declarations. Codegen walks `structs` BEFORE
    /// `impls` and BEFORE `functions` so the order of zig emission matches
    /// the source order (types declared before use). The slices are
    /// ordered to match the parser's top-level walk (which interleaves
    /// struct/impl/fun decls in source order); codegen preserves that
    /// ordering by re-walking the source positions rather than relying
    /// on slice order alone. Per the docs/12 contract, struct embedding
    /// is resolved at codegen time by promoting embedded fields into
    /// the outer struct (see `genStructDecl`).
    structs: []const StructDecl = &[_]StructDecl{},
    /// Module-level impl blocks. Codegen walks `impls` after `structs`
    /// so zig's type checker sees the struct before its methods. Each
    /// method is emitted as a top-level zig free function whose name
    /// encodes the (target_type, method_name) pair so call-dispatch
    /// from `.method_call` codegen can find the right implementation.
    impls: []const ImplBlock = &[_]ImplBlock{},
    /// Module-level enum declarations. Codegen walks `enums` alongside
    /// `structs` and `impls` so types are declared before use in any
    /// subsequent function body. Like structs/impls, enums preserve
    /// source-order recording in the parser's main loop and are
    /// emitted at codegen time in source order so any guarantee that
    /// a downstream top-level fn or impl sees the type ahead of itself.
    enums: []const EnumDecl = &[_]EnumDecl{},
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

