const std = @import("std");

// DECL: Program.functions/structs/impls/enums reference
// decl-side types.
const decl = @import("decl.zig");
const FunDecl = decl.FunDecl;
const StructDecl = decl.StructDecl;
const ImplBlock = decl.ImplBlock;
const EnumDecl = decl.EnumDecl;
// Traits (docs/17, Phase 1): Program.traits carries the trait-decl
// surface so codegen can walk trait types alongside structs/impls/
// enums. Imported via the same `decl.TraitDecl` chain as the other
// decl-side types; the `&[_]TraitDecl{}` empty default preserves the
// non-trait source-shape compatibility for the 235+ baseline tests.
const TraitDecl = decl.TraitDecl;
// Module imports (docs/manual/22-modules.md §Imports): Program.imports
// carries each top-level `pub import std.X.{A, B as C}` decl so
// codegen can walk the resolved paths against KNOWN_STD_MODULES (in
// src/parser/core.zig). Imported via the same `decl.ImportDecl`
// chain as the other decl-side types; default-empty preserves the
// non-import source-shape compat (no pre-imports code existed).
const ImportDecl = decl.ImportDecl;
// Module re-exports (docs/manual/22 §Re-exports): `[pub] use
// <dotted-path> as <name>`. Imported via the same `decl.ImportDecl`
// chain; default-empty preserves the non-use source-shape compat.
const UseDecl = decl.UseDecl;
// FFI (docs/24). ExternDecl carries `extern fun` declarations so
// parser can parse them at top-level and codegen can emit them.
const ExternDecl = decl.ExternDecl;
// Compile-time (docs/26). ConstDecl carries `const NAME = EXPR` declarations.
const ConstDecl = decl.ConstDecl;

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
    /// Module-level trait declarations (docs/17 §"Definition"). Parsed
    /// by `Parser.parseTraitDecl` (scaffolded in Phase 1; codegen
    /// lives in Phase 2). The parser records them in source-decl
    /// order alongside structs/impls/enums; codegen walks the slice
    /// before any impl that might register a trait-method so the trait
    /// type is declared before any vtable instantiation references it.
    /// `[]const TraitDecl{}` default empty preserves the
    /// pre-traits-source-shape compatibility (none of the existing
    /// 235+ tests reference trait decls).
    traits: []const TraitDecl = &[_]TraitDecl{},
    /// Module-level import declarations (`import std.string` and the
    /// `pub import std.X.{A, B as C}` selective form). Each entry is
    /// parsed against the KNOWN_STD_MODULES table in
    /// `src/parser/core.zig` (currently a comptime-baked 8-entry list
    /// covering `lib/std/{mod,string,error,fmt,time,atomic,bench}.zag`,
    /// `lib/std/async/stream.zag`, and `lib/std/arch/x86/avx2.zag`);
    /// a `import std.X` whose path doesn't match a table entry
    /// currently surfaces a parser-time error (the table is the
    /// resolution surface for v1 — user-module imports live behind a
    /// later parser pass). Codegen walks `imports` at generate() entry
    /// to emit one `@import("...")`-style pre-bind per resolved entry.
    imports: []const ImportDecl = &[_]ImportDecl{},
    /// Module-level `[pub] use <path> as <name>` re-exports
    /// (docs/manual/22 §Re-exports). Codegen walks `uses` at
    /// generate() entry (right after the imports loop) and emits one
    /// `pub const <name> = @import("<resolved>.zig");` per entry whose
    /// dotted path resolves against KNOWN_STD_MODULES; unresolvable
    /// paths are skipped silently (same null-on-miss contract as the
    /// imports loop). Default-empty keeps pre-use source shapes
    /// byte-compatible.
    uses: []const UseDecl = &[_]UseDecl{},
    /// Top-level `extern fun` declarations (docs/24 §"extern fun").
    /// Codegen emits `extern fn` for each entry before any function
    /// bodies so zig's linker can resolve FFI symbols.
    externs: []const ExternDecl = &[_]ExternDecl{},
    /// Top-level `const` declarations (docs/26). Codegen emits zig
    /// `const NAME: TYPE = EXPR;` for each entry.
    consts: []const ConstDecl = &[_]ConstDecl{},
};

pub const Arena = struct {
    /// Overflow chunks — appended on demand once the inline `buf`
    /// (64KiB) is exhausted. Large stdlib modules (e.g. hash.zag's
    /// 64-entry SHA-256 K table + 32-entry digest literal) exceed
    /// 64KiB of AST nodes; without this the parser aborts with an
    /// out-of-bounds panic in `alloc`. Growth chunks are allocated
    /// from the page allocator and linked into a singly-linked list
    /// (`next`); they live for the process lifetime (arena semantics
    /// — the parser never deinits its AST).
    const OverflowChunk = struct {
        next: ?*OverflowChunk,
        buf: [65536]u8,
        pos: usize,
    };
    buf: [65536]u8,
    pos: usize,
    overflow: ?*OverflowChunk = null,

    pub fn init() Arena {
        return .{ .buf = undefined, .pos = 0 };
    }

    pub fn alloc(self: *Arena, comptime T: type, count: usize) []T {
        const size = @sizeOf(T) * count;
        const align_bytes = @alignOf(T);
        const aligned_pos = (self.pos + align_bytes - 1) / align_bytes * align_bytes;
        if (aligned_pos + size <= self.buf.len) {
            const result = @as([*]T, @ptrCast(@alignCast(self.buf[aligned_pos .. aligned_pos + size])));
            self.pos = aligned_pos + size;
            return result[0..count];
        }
        // Slow path: the inline buffer is exhausted — bump through the
        // overflow chain, allocating a fresh 64KiB chunk on demand.
        var chunk = self.overflow;
        while (chunk) |c| {
            const c_pos = (c.pos + align_bytes - 1) / align_bytes * align_bytes;
            if (c_pos + size <= c.buf.len) {
                const result = @as([*]T, @ptrCast(@alignCast(c.buf[c_pos .. c_pos + size])));
                c.pos = c_pos + size;
                return result[0..count];
            }
            chunk = c.next;
        }
        const fresh = std.heap.page_allocator.create(OverflowChunk) catch @panic("parser arena exhausted");
        fresh.* = .{ .next = self.overflow, .buf = undefined, .pos = 0 };
        self.overflow = fresh;
        const result = @as([*]T, @ptrCast(@alignCast(fresh.buf[0..size])));
        fresh.pos = size;
        return result[0..count];
    }

    pub fn dupe(self: *Arena, comptime T: type, slice: []const T) []T {
        const result = self.alloc(T, slice.len);
        @memcpy(result, slice);
        return result;
    }
};

