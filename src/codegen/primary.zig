const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;
// Cross-bucket alias-resolution import (docs/07 "Type Aliases",
// docs/11 borrowed-string-view). Same pattern as the imports in
// src/codegen/expr.zig and src/codegen/stmt.zig: a sibling-bucket
// helper made available by file-scope re-export rather than
// re-implementing. Used at the array-literal emit site
// (`genArrayLit`'s three `a.type_name` write sites — fill,
// progression, and explicit-list) so that `[3]str { ... }`
// round-trips to `[3][]const u8 { ... }` (via the
// `[]str`/`[3]str` mappings in `zagTypeToZig`) without zig ever
// seeing a bare `str` ident. The same wrap is correct for any
// other alias-bearing type name (e.g. `[3]?str` would also flow
// through the alias table, though v1 has no such mapping).
const zagTypeToZig = @import("decl.zig").zagTypeToZig;

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
        // Route every call variant through the `__zag_print`
        // preamble helper (declared in src/codegen/core.zig's
        // generate() preamble) instead of `std.debug.print`
        // directly. The shim writes to STDOUT via zig 0.16's
        // buffered-writer File.stdout() API; the original
        // `std.debug.print` route wrote to STDERR which made
        // `zag run foo.zag` produce empty stdout AND empty stderr
        // when invoked via the leaf-process fork+execve path
        // (tests/e2e.zig's stderr-capture caveat is moot now —
        // the destination is canonical stdout).
        if (c.args.len == 0) {
            // No-arg print. parseCallExpr accepts `print()` as a
            // zero-element call (no min-arity guard), and the
            // previous generic-{any}-with-empty-args shape
            // (`__zag_print("{any}", .{})`) is rejected by zig
            // because `{any}` reads 1 arg from `.{}` (arity
            // mismatch). Emit the empty-string form so `print()`
            // is at worst a no-op rather than a zig compile
            // error.
            self.write("__zag_print(\"\", .{})");
            return;
        }
        if (c.args.len >= 2) {
            // Multi-arg print: first arg is the FORMAT string,
            // remaining args are the format-arg tuple. This
            // extends the single-arg `.string_lit` /
            // `.byte_string_lit` arm's existing
            // format-string-first convention
            // (`__zag_print("<str>", .{})`) and matches the
            // user's mental model from C `printf("fmt\n", ...)`
            // and Rust `println!("fmt {}", arg)` where the
            // string-literal slot is the printf-style format
            // spec and the trailing args are the values
            // pulled into the placeholders.
            //
            // The previous generic-{any} fallback was wrong
            // on two counts: (a) it overwrote the user's
            // format string with a hardcoded `"{any}"` so
            // any embedded `{d}`, `{x}`, etc. placeholders
            // were lost; (b) it spliced the N args under a
            // single `{any}` slot, and zig's
            // std.fmt.format arity check rejected the
            // generated call with an opaque
            // `expected expression, found '.'` parse error
            // that pointed at the args tuple rather than
            // naming the multi-arg surface as the cause.
            // operators.zag's range section's docblock
            // flagged this as the upstream bug.
            //
            // Only literal string/byte_string first args are
            // supported today. The `.template_lit` first-arg
            // case (`print("hello {name}", extra)`) is
            // deferred: genTemplateLit's `.debug_print`
            // emit already produces a complete
            // `__zag_print(...)` statement (own format
            // string + own args tuple) rather than a bare
            // format-string token, so naively splicing
            // `c.args[0]` into the outer args tuple would
            // nest a `__zag_print` call inside another
            // `__zag_print`'s args. Refactoring
            // genTemplateLit to return a separate
            // format-string + args slice so this codepath
            // can merge them is the proper fix; deferred
            // to a followup commit. Users hitting this
            // today can route through two consecutive
            // `print` calls (`print(extra); print("hello
            // {name}");`) without losing readability.
            //
            // Other first-arg shapes (tuple_lit, ident,
            // call, method_call, ...) also reject at
            // codegen time with a clear diagnostic naming
            // the cause, following the destructuring-
            // invariant pattern in src/codegen/stmt.zig's
            // genBindingLeaves path (`std.debug.print` +
            // `std.process.exit(1)`). The user sees
            // `error:codegen: ...` at compile time rather
            // than zig's downstream parse rejection.
            switch (c.args[0]) {
                .string_lit, .byte_string_lit => |str| {
                    self.write("__zag_print(\"");
                    self.write(str);
                    self.write("\", .{");
                    for (c.args[1..], 0..) |arg, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(arg);
                    }
                    // zig 0.16 requires a trailing comma
                    // inside even the single-field args
                    // tuple (see genTemplateLit's
                    // `.debug_print` docblock for the
                    // `.{x}` vs `.{x,}` rationale).
                    self.write(",})");
                },
                else => {
                    // The canonical workaround is single-arg template
                    // interpolation (the .template_lit arm above is
                    // fully wired) — and pre-existing zag code uses
                    // this everywhere, so it should lead the error
                    // message. Rephrase
                    //   `print("range: {x}", extra)`
                    // as
                    //   `print("range: {x}, extra={extra} ")`
                    // and the single-arg template arm handles format
                    // string + args uniformly. The split-into-separate-
                    // print-calls fallback is for cases where the
                    // extra args are logically distinct streams.
                    std.debug.print(
                        "error:codegen: multi-arg print first arg must be a literal format string without `{{...}}` placeholders (got '{s}' with {d} extra arg(s)); rephrase as single-arg template interpolation — e.g., `print(\"range: {{x}}, extra={{extra}}\")` combines format + extras into one template, or split into separate print calls if the extras are logically distinct\n",
                        .{ @tagName(c.args[0]), c.args.len - 1 },
                    );
                    std.process.exit(1);
                },
            }
            return;
        }
        const arg = c.args[0];
        switch (arg) {
            .string_lit, .byte_string_lit => |str| {
                self.write("__zag_print(\"");
                self.write(str);
                self.write("\", .{})");
            },
            .char_lit => {
                self.write("__zag_print(\"{c}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .array_lit => {
                self.write("__zag_print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .tuple_lit => {
                self.write("__zag_print(\"{any}\", .{");
                self.genExpr(arg);
                self.write(",})");
            },
            .template_lit => |t| {
                self.genTemplateLit(t, .debug_print);
            },
            else => {
                self.write("__zag_print(\"{any}\", .{");
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
            self.write(zagTypeToZig(a.type_name));
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
            self.write(zagTypeToZig(a.type_name));
            self.write(" = undefined; ");
            if (k > 0) {
                self.write("const __pat: [");
                var k_buf: [16]u8 = undefined;
                const k_str = std.fmt.bufPrint(&k_buf, "{d}", .{k}) catch "0";
                self.write(k_str);
                self.write("]");
                self.write(zagTypeToZig(a.type_name));
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
        self.write(zagTypeToZig(a.type_name));
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
            // Phase: zag-source escape-sequence detection. The LEXER in
            // `src/lexer/string.zig:readString` PRESERVES escape sequences
            // raw (`\"` stays as 2 bytes `\`, `"` rather than decoded to a
            // single `"` char), so codegen sees the `\` byte and must
            // convert it to the equivalent zigzag escape form here.
            // Without this conversion, a zag source `\"` becomes `\\"`
            // in zigzag source (escape-for-backslash + closing-quote),
            // which truncates the format string at the first `\"` and
            // zig 0.16 surfaces the resulting malformed args tuple as
            // `expected ',' after argument`. Same for `\n`, `\t`, `\r`,
            // `\\` — handle each pair explicitly so the emitted zigzag
            // string is parseable. The un-escaped `"`, LF, CR, TAB
            // cases below keep their original role (covering raw
            // decoded characters that arrive via the lexer when a
            // multi-line string source puts the literal LF inside the
            // text directly rather than via `\n`).
            var lit_idx: usize = 0;
            while (lit_idx < lit.len) {
                const c = lit[lit_idx];
                if (c == '\\' and lit_idx + 1 < lit.len) {
                    const nxt = lit[lit_idx + 1];
                    switch (nxt) {
                        '"' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = '"';
                                fmt_len += 2;
                            }
                            lit_idx += 2;
                            continue;
                        },
                        'n' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 'n';
                                fmt_len += 2;
                            }
                            lit_idx += 2;
                            continue;
                        },
                        't' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 't';
                                fmt_len += 2;
                            }
                            lit_idx += 2;
                            continue;
                        },
                        'r' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = 'r';
                                fmt_len += 2;
                            }
                            lit_idx += 2;
                            continue;
                        },
                        '\\' => {
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = '\\';
                                fmt_len += 2;
                            }
                            lit_idx += 2;
                            continue;
                        },
                        else => {
                            // Unrecognized escape sequence — emit `\\` to
                            // escape the backslash and let the next
                            // iteration handle the second byte through
                            // the regular single-byte switch below.
                            if (fmt_len + 2 <= fmt_buf.len) {
                                fmt_buf[fmt_len] = '\\';
                                fmt_buf[fmt_len + 1] = '\\';
                                fmt_len += 2;
                            }
                            lit_idx += 1;
                            continue;
                        },
                    }
                }
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
                lit_idx += 1;
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
                // Route template-literal interpolation through the
                // `__zag_print` preamble helper (defined in
                // src/codegen/core.zig's generate() preamble) so
                // interpolated `print("hello, {name}\n", ...)`
                // writes to STDOUT, matching the multi-arg /
                // single-arg paths in genPrintCall above. The
                // context name `.debug_print` is historical —
                // the destination is now stdout; the rename is
                // deferred to avoid touching the call sites in
                // genPrintCall's template_lit branch.
                self.write("__zag_print(\"");
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
