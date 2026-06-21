const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;

    const TemplateCtx = enum { debug_print, buf_print };

// ============================================================
// FILE-SCOPE methods and free helpers (PRIMARY bucket)
// ============================================================

    pub     fn inferZigTypeFromExpr(expr: ast.Expr) []const u8 {
        return switch (expr) {
            .int_lit => "i32",
            .float_lit => "f64",
            .bool_lit => "bool",
            .char_lit => "u8",
            .string_lit, .byte_string_lit => "[]const u8",
            else => "",
        };
    }

    pub     fn getTopElements(expr: ast.Expr) []const ast.Expr {
        return switch (expr) {
            .tuple_lit => |els| els,
            .single_tuple_lit => |el_ptr| @as([*]const ast.Expr, @ptrCast(el_ptr))[0..1],
            .named_tuple_lit => |nt| nt.elements,
            .array_lit => |a| a.elements,
            else => &[_]ast.Expr{},
        };
    }

    pub     fn exprContainsFloat(expr: ast.Expr) bool {
        return switch (expr) {
            .float_lit => true,
            .binary => |b| exprContainsFloat(b.lhs.*) or exprContainsFloat(b.rhs.*),
            .unary => |u| exprContainsFloat(u.operand.*),
            else => false,
        };
    }

    pub     fn needsIntDivShim(self: *Codegen, b: ast.Expr.BinaryExpr) bool {
        if (b.op != .div and b.op != .mod) return false;
        if (b.rhs.* != .int_lit) return false;
        // Both sides comptime_int → zig folds the bare form at compile time.
        // Skip the shim so the user's source round-trips: `1 / 2 === (1 / 2)`.
        if (b.lhs.* == .int_lit) return false;
        // LHS ident annotated with a float type in the per-function map →
        // `@divTrunc` requires integer args so the shim would miscompile.
        // Skip the wrap and emit the bare form; zig infers the operand
        // types from the binding annotations and accepts `f64 / comptime_int`.
        if (b.lhs.* == .ident and self.isFloatIdentType(b.lhs.*.ident)) return false;
        return !exprContainsFloat(b.lhs.*);
    }

    pub     fn genPrintCall(self: *Codegen, c: ast.Expr.CallExpr) void {
        if (c.args.len != 1) {
            // Multi-arg print: fall back to the generic debug-print
            // form with the args list. Mirrors the codegen already
            // used for templates where the trailing comma is appended
            // unconditionally when args are non-empty.
            self.write("std.debug.print(\"{any}\", .{");
            for (c.args, 0..) |arg, i| {
                if (i > 0) self.write(", ");
                self.genExpr(arg);
            }
            if (c.args.len > 0) self.write(",");
            self.write("})");
            return;
        }
        const arg = c.args[0];
        switch (arg) {
            .string_lit, .byte_string_lit => |str| {
                self.write("std.debug.print(\"");
                self.write(str);
                self.write("\", .{})");
            },
            .char_lit => {
                self.write("std.debug.print(\"{c}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .array_lit => {
                self.write("std.debug.print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .tuple_lit => {
                self.write("std.debug.print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .template_lit => |t| {
                self.genTemplateLit(t, .debug_print);
            },
            else => {
                self.write("std.debug.print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
        }
    }

    pub     fn genArrayLit(self: *Codegen, a: ast.Expr.ArrayLitExpr) void {
        // Phase 3 followup: prefer `a.size_text` (preserved verbatim by
        // parseArrayLit's identifier branch) over the digit-walked
        // `a.size` so `[N]T { ... }` round-trips as `[1]T{ val } ** N`
        // (or `[N]T{ a, b, c }` on the explicit-list path) instead of
        // the silently-broken `** 0`/`[0]T{ ... }`. The literal branch
        // (`[3]i32 { 1, 2, 3 }`) keeps the `size_str` from the
        // existing `std.fmt.bufPrint` path so the pre-Phase-3 surface
        // is unchanged. Mirrors the additive-optional convention
        // threaded through `NewExpr.allocator` (a `?[]const u8`)
        // — adding a slot, not changing an existing one.
        var size_buf: [16]u8 = undefined;
        const size_str = a.size_text orelse std.fmt.bufPrint(&size_buf, "{d}", .{a.size}) catch "0";

        if (a.fill) {
            // `[1]T{ v } ** N` — Zig's repeat operator. The leading element is
            // present by grammar whenever `fill` is true.
            self.write("[1]");
            self.write(a.type_name);
            self.write("{ ");
            if (a.elements.len >= 1) self.genExpr(a.elements[0]);
            self.write(" } ** ");
            self.write(size_str);
            return;
        }

        if (a.progression) {
            const k = a.elements.len;
            self.write("(blk: { var __arr: [");
            self.write(size_str);
            self.write("]");
            self.write(a.type_name);
            self.write(" = undefined; ");
            if (k > 0) {
                self.write("const __pat: [");
                var k_buf: [16]u8 = undefined;
                const k_str = std.fmt.bufPrint(&k_buf, "{d}", .{k}) catch "0";
                self.write(k_str);
                self.write("]");
                self.write(a.type_name);
                self.write(" = .{ ");
                for (a.elements, 0..) |el, i| {
                    if (i > 0) self.write(", ");
                    self.genExpr(el);
                }
                self.write(" }; ");
                self.write("var __i: usize = 0; while (__i < ");
                self.write(size_str);
                self.write(") : (__i += 1) __arr[__i] = __pat[__i % ");
                self.write(k_str);
                self.write("]; ");
            }
            self.write("break :blk __arr; })");
            return;
        }

        // Explicit list: `[N]T{ v1, v2, ..., vK }`.
        self.write("[");
        self.write(size_str);
        self.write("]");
        self.write(a.type_name);
        self.write("{ ");
        for (a.elements, 0..) |el, i| {
            if (i > 0) self.write(", ");
            self.genExpr(el);
        }
        self.write(" }");
    }

    pub     fn genTemplateLit(self: *Codegen, t: ast.Expr.TemplateLitExpr, ctx: TemplateCtx) void {
        var fmt_buf: [4096]u8 = undefined;
        var fmt_len: usize = 0;
        var args_cg = Codegen.init();
        var first_arg = true;

        for (t.parts) |part| {
            if (part.literal) |lit| {
                for (lit) |c| {
                    switch (c) {
                        '"' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = '"';
                                fmt_len += 2;
                            }
                        },
                        0x0A => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 'n';
                                fmt_len += 2;
                            }
                        },
                        0x0D => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 'r';
                                fmt_len += 2;
                            }
                        },
                        0x09 => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 't';
                                fmt_len += 2;
                            }
                        },
                        else => {
                            if (fmt_len < fmt_buf.len) {
                                fmt_buf[fmt_len] = c;
                                fmt_len += 1;
                            }
                        },
                    }
                }
            } else if (part.expr) |expr| {
                // `{any}` accepts any Zig type at the format-arg site. If the
                // user wrote a printf-style format spec (e.g. `:.5`, `:5`,
                // `:x`), we append it verbatim after `{any}` so zig's debug
                // formatter produces the requested precision/width/format.
                // Empirical zig 0.16 testing confirmed `{any:.N}` IS honoured
                // for numeric values (zig applies the spec to the underlying
                // numeric type when the value is rendered via the `{any}`
                // argument slot — the Spec slot follows the same rules as it
                // would on a type-specific placeholder).
                if (fmt_len + 5 <= fmt_buf.len) {
                    fmt_buf[fmt_len] = '{';
                    fmt_len += 1;
                    fmt_buf[fmt_len] = 'a';
                    fmt_len += 1;
                    fmt_buf[fmt_len] = 'n';
                    fmt_len += 1;
                    fmt_buf[fmt_len] = 'y';
                    fmt_len += 1;
                    if (part.spec) |spec| {
                        if (fmt_len + 1 + spec.len <= fmt_buf.len) {
                            fmt_buf[fmt_len] = ':';
                            fmt_len += 1;
                            for (spec) |c| {
                                fmt_buf[fmt_len] = c;
                                fmt_len += 1;
                            }
                        }
                    }
                    fmt_buf[fmt_len] = '}';
                    fmt_len += 1;
                }
                if (!first_arg) args_cg.write(", ");
                args_cg.genExpr(expr);
                first_arg = false;
            }
        }

        switch (ctx) {
            .debug_print => {
                self.write("std.debug.print(\"");
                self.write(fmt_buf[0..fmt_len]);
                self.write("\", .{");
                self.write(args_cg.out_buf[0..args_cg.out_len]);
                // Zig 0.16 requires a trailing comma inside the anonymous
                // struct literal `.{…}` even when only one field is present;
                // `.{x}` is interpreted as `.{ x }` (no field) and rejected
                // with "expected ',' after field". Append `,` whenever any
                // arg was written so single-arg and multi-arg calls both
                // produce a parseable anonymous struct.
                if (args_cg.out_len > 0) self.write(",");
                self.write("})");
            },
            .buf_print => {
                // Borrow into the module-level scratch buffer; this avoids the
                // dangling-pointer pitfall of returning a slice into a block-
                // local `var`. Multiple independent template_lit expressions
                // would race on this buffer, so standalone template_lit is
                // appropriate only when each value is consumed before the next
                // assignment (e.g. `print((blk: { ... })  .*)` is wrong; use
                // single-arg `print("...{x}...")` instead).
                self.write("(blk: { const __tmp = std.fmt.bufPrint(__zag_interp_buf[0..], \"");
                self.write(fmt_buf[0..fmt_len]);
                self.write("\", .{");
                self.write(args_cg.out_buf[0..args_cg.out_len]);
                self.write("}) catch __zag_interp_buf[0..0]; break :blk __tmp; })");
            },
        }
    }
