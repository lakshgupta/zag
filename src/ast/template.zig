const std = @import("std");

// EXPR: TemplatePart.expr: ?Expr.
const expr = @import("expr.zig");
const Expr = expr.Expr;

// ============================================================
// template.zig — template-literal types extracted from the
// Expr union body. Each type lives at TOP-LEVEL here; the
// original nested `pub const` inside Expr is replaced with
// a re-export alias so `ast.Expr.TemplateLitExpr` and
// `ast.TemplateLitExpr` resolve to the same struct type.
// ============================================================

pub const TemplateLitExpr = struct {
    /// Alternating literal text segments and interpolation expressions.
    /// A literal segment with `len == 0` is allowed as a leading or
    /// trailing placeholder when the template begins or ends with `{...}`.
    parts: []TemplatePart,
};

pub const TemplatePart = struct {
    /// `null` here means this slot is an interpolation expression (use `expr`).
    /// `non-null` here means this slot is a literal text segment.
    literal: ?[]const u8,
    expr: ?Expr,
    /// Optional printf-style format spec text captured between `{` and `}`,
    /// e.g. `:.5`, `:5`, `:x`, `:-5`. `null` for plain `{name}` (no spec).
    /// Applies only to interpolation slots — literal slots always have `spec
    /// = null`. The codegen appends this verbatim after `{any}` so zig's
    /// debug formatter (which DOES honour spec on `{any}` in 0.16) applies
    /// the requested precision/width/format at print time.
    spec: ?[]const u8 = null,
};

