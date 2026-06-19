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
            \\// Module-level scratch buffer for standalone template-literal evaluation.
            \\// Each `let x = "...{a}..."` overwrites this; successive uses race but
            \\// works for patterns where the slice is consumed before the next
            \\// template-literal expression runs (the common form is single-shot
            \\// `print` interpolation which uses the per-call `.debug_print` ctx).
            \\// The `__zag_` prefix reserves the name against user identifiers.
            \\var __zag_interp_buf: [4096]u8 = undefined;
            \\
        );

        for (prog.functions) |fun| {
            self.genFun(fun);
        }

        return self.out_buf[0..self.out_len];
    }

    fn genFun(self: *Codegen, fun: ast.FunDecl) void {
        if (fun.doc) |d| self.genDocComment(d);
        self.write("pub fn ");
        self.write(fun.name);
        self.write("() !void {\n");

        for (fun.body) |stmt| {
            self.genStmt(stmt);
        }

        self.write("}\n\n");
    }

    fn genDocComment(self: *Codegen, doc: []const u8) void {
        var i: usize = 0;
        while (i < doc.len) {
            var j: usize = i;
            while (j < doc.len and doc[j] != '\n') : (j += 1) {}
            var k: usize = i;
            while (k < j and (doc[k] == ' ' or doc[k] == '\t')) : (k += 1) {}
            while (k < j and doc[k] == '#') : (k += 1) {}
            while (k < j and (doc[k] == ' ' or doc[k] == '\t')) : (k += 1) {}
            self.write("/// ");
            self.write(doc[k..j]);
            // Always emit `\n` after each doc line — including the LAST line.
            // Zig's slice `[start..end]` excludes `end` so `doc` may end right
            // before a `\n` byte (e.g. when multi-line doc block was assembled
            // from multiple doc_comment tokens at lexer time, the LAST token's
            // text is `[start..newline_pos]` NOT `[start..newline_pos+1]`).
            // Without this unconditional write, `pub fn` would concatenate
            // directly onto the `///` line and the compiled zigzag source
            // becomes a single unbroken token like
            // `/// doc linepub fn main() …`.
            self.write("\n");
            // Advance `i` past the trailing `\n` if present; otherwise clamp
            // to doc.len so the outer while exits cleanly.
            if (j < doc.len and doc[j] == '\n') {
                i = j + 1;
            } else {
                i = doc.len;
            }
        }
    }

    fn genStmt(self: *Codegen, stmt: ast.Stmt) void {
        switch (stmt) {
            .let => |l| {
                self.write("    const ");
                self.write(l.name);
                // Preserve the user's type annotation `let x: T = ...` so Zig's
                // type checker picks it up too. Without `type_name` we let Zig
                // infer from the initializer (which still produces a `const`).
                if (l.type_name) |t| {
                    self.write(": ");
                    self.write(t);
                }
                self.write(" = ");
                self.genExpr(l.init);
                self.write(";\n");
            },
            .var_binding => |v| {
                // Mutable binding: emit Zig's `var` so a follow-up
                // `name = expr` rebinding via `.assign` compiles cleanly.
                self.write("    var ");
                self.write(v.name);
                if (v.type_name) |t| {
                    self.write(": ");
                    self.write(t);
                }
                self.write(" = ");
                self.genExpr(v.init);
                self.write(";\n");
            },
            .const_binding => |c| {
                // Compile-time binding: emit Zig's `const`. The zig keyword
                // matches zag's keyword shape exactly; what changes between
                // the let/var/const trio is where the storage lives (stack
                // mutable for var, stack immutable for let, compile-time for
                // const).
                self.write("    const ");
                self.write(c.name);
                if (c.type_name) |t| {
                    self.write(": ");
                    self.write(t);
                }
                self.write(" = ");
                self.genExpr(c.init);
                self.write(";\n");
            },
            .assign => |a| {
                // Bare rebinding: `name = expr;` (no leading `let`/`var`).
                // The name must refer to a previously-declared `var`; Zig's
                // compile-time type checker surfaces "undeclared identifier"
                // errors at the generated use site.
                self.write("    ");
                self.write(a.name);
                self.write(" = ");
                self.genExpr(a.value);
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
            .byte_string_lit => |s| {
                self.write("\"");
                self.write(s);
                self.write("\"");
            },
            .char_lit => |s| {
                self.write(s);
            },
            .int_lit => |s| {
                self.write(s);
            },
            .float_lit => |s| {
                self.write(s);
            },
            .bool_lit => |b| {
                self.write(if (b) "true" else "false");
            },
            .null_lit => {
                self.write("null");
            },
            .undefined_lit => {
                self.write("undefined");
            },
            .tuple_lit => |elements| {
                if (elements.len == 0) {
                    self.write("{}");
                } else {
                    self.write(".{ ");
                    for (elements, 0..) |el, i| {
                        if (i > 0) self.write(", ");
                        self.genExpr(el);
                    }
                    self.write(" }");
                }
            },
            .array_lit => |a| {
                self.genArrayLit(a);
            },
            .template_lit => |t| {
                self.genTemplateLit(t, .buf_print);
            },
            .ident => |name| {
                self.write(name);
            },
            .call => |c| {
                if (std.mem.eql(u8, c.name, "print")) {
                    if (c.args.len == 1) {
                        switch (c.args[0]) {
                            .string_lit, .byte_string_lit => |str| {
                                // Literal string/byte-string: emit the bytes
                                // directly as the format string with no args.
                                self.write("std.debug.print(\"");
                                self.write(str);
                                self.write("\", .{})");
                            },
                            .char_lit => {
                                // Zig's `{}` formats `u8` as a numeric code
                                // point; use `{c}` to render the actual char.
                                self.write("std.debug.print(\"{c}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                            .array_lit => {
                                // Arrays don't accept `{}` in zig 0.16;
                                // `{any}` produces a debug-list of elements.
                                self.write("std.debug.print(\"{any}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                            .tuple_lit => {
                                // `{any}` produces a debug-formatted
                                // anonymous struct of the tuple fields.
                                self.write("std.debug.print(\"{any}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
                            },
                            .template_lit => |t| {
                                self.genTemplateLit(t, .debug_print);
                            },
                            else => {
                                self.write("std.debug.print(\"{any}\", .{");
                                self.genExpr(c.args[0]);
                                self.write(",})");
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
            .binary => |b| {
                // Emit `(lhs op rhs)` with parenthesisation so emitted
                // source respects the AST's precedence even if we eventually
                // loosen the parser ladder (e.g. add `||` short-circuit).
                self.write("(");
                self.genExpr(b.lhs.*);
                self.write(" ");
                switch (b.op) {
                    .add => self.write("+"),
                    .sub => self.write("-"),
                    .mul => self.write("*"),
                    .div => self.write("/"),
                }
                self.write(" ");
                self.genExpr(b.rhs.*);
                self.write(")");
            },
        }
    }

    /// Emit a Zag array literal `[N]T { ... }` to its Zig counterpart.
    /// Three sub-forms:
    /// - **Explicit**:    `[N]T { v1, v2, ... }`         → `[N]T{ v1, v2, ... }`
    /// - **Fill**:        `[N]T { v ... }`               → `[1]T{ v } ** N`
    /// - **Progression**: `[N]T { v1, v2 ... }`         → `blk: { var __arr = ...; const __pat = .{v1,v2}; while (...) __arr[i] = __pat[i%K]; break :blk __arr; }`
    ///   The progression form repeats the explicit prefix cyclically until the
    ///   array is `N` long (i.e. `[4]i32 { 1, 2 ... }` yields `[1, 2, 1, 2]`).
    fn genArrayLit(self: *Codegen, a: ast.Expr.ArrayLitExpr) void {
        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{a.size}) catch "0";

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

    const TemplateCtx = enum { debug_print, buf_print };

    /// Emit a Zag string-interpolation template literal.
    ///
    /// - `.debug_print`: emit `std.debug.print("<fmt>", .{args})` directly. This
    ///   is the path used as the first arg to `print(...)`.
    /// - `.buf_print`: emit a block that produces `[]u8` via `std.fmt.bufPrint`
    ///   into the module-level scratch buffer. Successive independent
    ///   template-literal expressions race on the buffer (intended for one-shot
    ///   use, not long-lived retention).
    ///
    /// The format string is built up char-by-char with a *minimal* escape set:
    /// only `"`, LF, CR, and TAB bytes are escaped — these are the bytes that
    /// would otherwise break a Zig string literal in the generated source. We
    /// deliberately do NOT re-escape the `\` byte: the Zag lexer keeps the
    /// user's intended escape sequences intact (e.g. `\n` in source stays
    /// `\n` in the lexer text), and the lexer's text round-trips byte-for-byte
    /// through Zig's source-level escape decoding.
    fn genTemplateLit(self: *Codegen, t: ast.Expr.TemplateLitExpr, ctx: TemplateCtx) void {
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
                    fmt_buf[fmt_len] = '{'; fmt_len += 1;
                    fmt_buf[fmt_len] = 'a'; fmt_len += 1;
                    fmt_buf[fmt_len] = 'n'; fmt_len += 1;
                    fmt_buf[fmt_len] = 'y'; fmt_len += 1;
                    if (part.spec) |spec| {
                        if (fmt_len + 1 + spec.len <= fmt_buf.len) {
                            fmt_buf[fmt_len] = ':'; fmt_len += 1;
                            for (spec) |c| {
                                fmt_buf[fmt_len] = c;
                                fmt_len += 1;
                            }
                        }
                    }
                    fmt_buf[fmt_len] = '}'; fmt_len += 1;
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
};
