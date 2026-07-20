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

    // Type-aware format specifier (gap #6 widening, DRY'd out of the
    // duplicated in-line widening that previously lived in BOTH
    // `genPrintCall`'s else arm AND `genTemplateLit`'s interpolation
    // slot — ~12 lines of byte-identical logic at each site). Walks
    // `self.type_info_buf` (populated by `collectTypedBindings` for
    // every `let X: T = ...`) and returns the bare format specifier
    // (`"s"` for byte-slice family, `"any"` otherwise) plus a flag
    // for whether the source-side annotation is leading-`?`
    // (`?[]const u8` family), which the caller appends via `orelse
    // ""` so zig's strictly-typed `{s}` formatter accepts the
    // non-optional slice.
    //
    // The matcher uses substring `[]const u8` (after `zagTypeToZig`
    // rewrite) so it catches BOTH canonical `[]const u8` AND the
    // `str` alias (which rewrites to `[]const u8`); the leading-`?`
    // optional-gate keeps `*?[]const u8` (pointer-to-optional,
    // requiring deref-then-orelse codegen we don't yet emit) from
    // silently mis-routing through `orelse ""` and zig rejecting at
    // the call site.
    //
    // Sites call this with the `.ident` payload they already have:
    //   - genPrintCall else arm: `typeAwareFmtSpec(self, arg.ident)`
    //     then prepend/append `{`/`}` around the returned spec.
    //   - genTemplateLit interpolation slot: same helper call; the
    //     for-loop that builds `fmt_buf` already adds braces around
    //     each spec char.
    //
    // Both sites use FREE-FN call style (`typeAwareFmtSpec(self, x)`)
    // rather than method-call (`self.typeAwareFmtSpec(x)`) because the
    // helper is defined in this file's scope and the call sites are
    // also in this file — file-scope lookup resolves the symbol
    // without a Codegen-struct re-export. Switching to method-call
    // would require re-registering `typeAwareFmtSpec` on `Codegen`
    // via the `pub const X = @import("primary.zig").X;` table in
    // core.zig's struct definition; not done because no current
    // stmt.zig / expr.zig / decl.zig caller would benefit (DRY-extracted
    // widening is internal to primary.zig only). When the first
    // cross-bucket consumer lands, switch all 4 call sites to
    // method-call syntax AND register the helper.
    //
    // Both sites eliminate the previous duplicate substring walk
    // and the equivalent `type_name[0] == '?'` leading-`?` check;
    // any future widening (e.g. mutable `[]u8` byte-slice,
    // `[*]const u8` many-ptr) lands here once and both sites
    // automatically benefit.
    // Named return-type alias shared between
    // `typeAwareFmtSpec` (.ident-widening) and its v1.6 sibling
    // `typeAwareFmtSpecFromExpr` (.member_access widening). Both
    // helpers previously returned an anonymous struct literal
    // `struct { spec, is_optional_byte_slice }` which zig treats
    // as distinct types PER function — calling `typeAwareFmtSpec`
    // from inside `typeAwareFmtSpecFromExpr`'s `.ident` arm produces
    // an `expected type X, found Y` compile error even when
    // structurally identical. Sharing the named alias makes the
    // two helpers return-type compatible.
    pub const FmtSpec = struct {
        spec: []const u8,
        is_optional_byte_slice: bool,
    };
    // v1.6 byte-slice widening, member-access sibling helper
    // (gap-closure over gap #6's `.ident`-only widening). When the
    // expr is `.member_access { target: &.ident(X), name: Y }` and
    // we're emitting an impl-block method body whose receiver is an
    // instance of struct X, look up the `Y` field on `X`'s decl via
    // `self.prog.structs` and check whether its type (after
    // `zagTypeToZig` rewrite) is a byte-slice family
    // (`[]const u8` or `str` alias). If yes, return the same
    // `{s}` widening as the typed-binding path does for `.ident`
    // args. If no (e.g. field is `i32`, or `X` has no field `Y`,
    // or we're not in a method body), fall through to
    // `{any}` so the LHS still gets the codegen-tested
    // byte-deferred formatter that zig renders correctly for
    // scalars/structs.
    //
    // Returning a struct {spec, is_optional_byte_slice} (rather
    // than mutating shared scratch fields) lets BOTH call sites
    // (`genPrintCall` else arm + `genTemplateLit` interpolation
    // slot) consume the result byte-for-byte in lockstep with the
    // `.ident` branch's `typeAwareFmtSpec(self, ident_name)` call.
    // The widening triggers on EITHER:
    //   (1) leading-`?` optional annotation on `Y`'s type_text —
    //       `is_optional_byte_slice = true` → caller appends
    //       `orelse \"\"` so zig's strictly-typed `{s}` formatter
    //       accepts the rewritten non-optional slice;
    //   (2) leading-`*` pointer-annotation (`*[]const u8`) — out of
    //       scope for v1 widening (no deref-then-orelse codegen).
    //       Surfaced as `{any}` so we don't emit `{s}` against a
    //       `*[]const u8` arg that zig would reject at the call
    //       site.
    //
    // Identifier-name heuristic: the user wrote `print(self.label)`
    // because the receiver param is conventionally named `self`.
    // If a user invents a non-`self` receiver (`print(this.x)` in an
    // `impl Foo { fun bar(this: *Foo) { ... } }` body), we still
    // accept `this` as the receiver because the helper is gated on
    // `current_receiver_struct_name` (the STRUCT), not on `self`
    // (the IDENT). The receiver ident's name doesn't matter — only
    // the receiver struct type does. This preserves the user-facing
    // freedom to call their receiver pointees whatever they want.
    pub fn typeAwareFmtSpecFromExpr(self: *Codegen, expr: ast.Expr) FmtSpec {
        if (expr == .ident) {
            return typeAwareFmtSpec(self, expr.ident);
        }
        if (expr == .member_access) {
            const recv_name_opt = self.current_receiver_struct_name;
            if (recv_name_opt == null) return .{ .spec = "any", .is_optional_byte_slice = false };
            const recv_name = recv_name_opt.?;
            const ma = expr.member_access;
            if (ma.target.* != .ident) return .{ .spec = "any", .is_optional_byte_slice = false };
            // We do NOT gate the field walk on the receiver IDENT
            // text (`self`/`this`/`me`/etc.) because the STRUCT
            // name match is the only correctness predicate. The
            // struct-name uniqueness in zag (each struct gets one
            // decl, fields are flat and uniquely named inside it)
            // makes the receiver-struct match definitive.
            for (self.prog.structs) |sd| {
                if (!std.mem.eql(u8, sd.name, recv_name)) continue;
                for (sd.fields) |f| {
                    if (f.kind != .named) continue;
                    if (!std.mem.eql(u8, f.kind.named.name, ma.name)) continue;
                    const tt = f.kind.named.type_text;
                    const rewritten = zagTypeToZig(tt);
                    if (tt.len > 0 and tt[0] != '*' and
                        std.mem.indexOf(u8, rewritten, "[]const u8") != null)
                    {
                        return .{
                            .spec = "s",
                            .is_optional_byte_slice = tt.len > 0 and tt[0] == '?',
                        };
                    }
                    // Field exists but isn't a byte-slice family.
                    // Fall through to `{any}` rather than returning
                    // here — a wider struct-walk could also find a
                    // DIFFERENT struct with a matching field name
                    // and a byte-slice type. In practice the user's
                    // struct's field declaration is definitive, so
                    // the early-return on first match above is fine.
                    return .{ .spec = "any", .is_optional_byte_slice = false };
                }
            }
            return .{ .spec = "any", .is_optional_byte_slice = false };
        }
        return .{ .spec = "any", .is_optional_byte_slice = false };
    }

    pub fn typeAwareFmtSpec(self: *Codegen, ident_name: []const u8) FmtSpec {
        var i: u32 = 0;
        while (i < self.type_info_count) : (i += 1) {
            if (std.mem.eql(u8, self.type_info_buf[i].name, ident_name)) {
                const rewritten = zagTypeToZig(self.type_info_buf[i].type_name);
                // Pointer-to-optional byte slice (`*?[]const u8`) is OUT
                // of scope for v1 widening — deref-then-orelse codegen
                // (`s.? orelse \"\"`) needs a separate pass. Until then,
                // skip the widening for any leading-`*` source type so
                // we don't emit `__zag_print(\"{s}\", .{s,})` on a
                // `*?[]const u8` arg that zig would reject at the call
                // site (`{s}` strictly requires non-optional `[]const
                // u8`).
                if (self.type_info_buf[i].type_name.len > 0 and
                    self.type_info_buf[i].type_name[0] != '*' and
                    std.mem.indexOf(u8, rewritten, "[]const u8") != null)
                {
                    return .{
                        .spec = "s",
                        // Source-side annotation leading-`?`
                        // (`?[]const u8`) — caller wraps with
                        // `orelse ""` so the strictly-typed `{s}`
                        // formatter sees a non-optional slice.
                        // `*?[]const u8` (pointer-to-optional) is
                        // NOT supported in v1; the substring match
                        // widens its format spec to `{s}` but the
                        // leading-`?` gate correctly leaves
                        // `is_optional_byte_slice` false so the
                        // emitted call site is `.{s,}` (no `orelse
                        // ""`). zig would reject the call anyway
                        // because `{s}` requires non-optional
                        // `[]const u8`; that's a known-limitation
                        // punt to v1.2 (dereference-then-orelse
                        // codegen for pointer-to-optional is the
                        //                     // wanted widening).
                        .is_optional_byte_slice = self.type_info_buf[i].type_name.len > 0 and
                            self.type_info_buf[i].type_name[0] == '?',
                    };
                }
            }
        }
        return .{ .spec = "any", .is_optional_byte_slice = false };
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
                // Type-aware formatter (gap #6): when the arg is
                // an `.ident` bound to a `str` (`[]const u8`)
                // annotation, use zig's `{s}` formatter which
                // prints the slice as its contents. The default
                // `{any}` formatter prints the byte elements as
                // a list (`{ 104, 105, 103, 104 }`), which is
                // correct for `u8` arrays but wrong for
                // `[]const u8` slices — the user expects the
                // human-readable string (`high`).
                //
                // The type-info lookup walks `self.type_info_buf`
                // (populated by `collectTypedBindings` in codegen/
                // stmt.zig for each `let X: T = ...` binding).
                // Annotations are stored verbatim (e.g. `"str"`)
                // so the `zagTypeToZig` rewrite is required to
                // match against zig's `[]const u8` canonical
                // form. Non-`[]const u8` idents (e.g. `u8`, `i32`,
                // `bool`) fall through to the `{any}` default
                // which zig formats correctly for primitive
                // scalars.
                //
                // For non-ident args (e.g. method calls, binary
                // expressions, enum-variant ctors) the lookup
                // doesn't fire — the format falls back to
                // `{any}` which works for the existing
                // codegen-tested print surfaces (`{a + b}`,
                // `{obj.f()}`, etc.). The `{s}` widening is
                // opt-in via the explicit `let lvl: str = ...`
                // annotation so users keep full control over the
                // emitted format spec.
                // Type-aware formatter (gap #6 widening, DRY-extracted
                // to `typeAwareFmtSpec`): when the arg is an `.ident`
                // bound to a byte-slice annotation (`[]const u8` family
                // — direct or `str` alias via `zagTypeToZig` rewrite),
                // use zig's `{s}` formatter which prints the slice as
                // its contents (`hello`) instead of the byte-element
                // list (`{ 104, 101, 108, 108, 111 }`).
                //
                // The helper handles the substring walk AND the
                // leading-`?` optional-unwrap decision; this site
                // just consumes the returned tuple and emits the
                // `{<spec>}` format placeholder + the optional
                // `orelse ""` arg wrap when matched. The same
                // helper is reused verbatim in `genTemplateLit`'s
                // interpolation slot so any future widening lands
                // once for both surfaces.
                var format_spec: []const u8 = "any";
                var is_optional_byte_slice = false;
                // v1.6 byte-slice widening, gap-closure: route
                // through `typeAwareFmtSpecFromExpr` so
                // `.member_access` args (`self.label` /
                // `this.byte_slice_field` etc.) widen to `{s}`
                // when the field on the current method's
                // receiver struct is a byte-slice family. The
                // `.ident` arm keeps its existing behaviour
                // unchanged (delegate to `typeAwareFmtSpec`).
                // No `== .ident` gate here — fire on every
                // shape so captures from non-current-receiver
                // contexts still resolve through the helper's
                // fallback-to-`{any}` path.
                const info = typeAwareFmtSpecFromExpr(self, arg);
                format_spec = info.spec;
                is_optional_byte_slice = info.is_optional_byte_slice;
                self.write("__zag_print(\"{");
                self.write(format_spec);
                self.write("}\", .{");
                self.genExpr(arg);
                if (is_optional_byte_slice) self.write(" orelse \"\"");
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
        // v1.5 multi-dim widening (docs/10 \u00a7"Multi-Dim Arrays"):
        // when `a.sizes` is set, OUTER dim brackets `[s0][s1]...[sN-1]`
        // are pre-fixed (inner-most bracket consumes the legacy
        // single-bracket emit and the type slot). Single-dim
        // (`a.sizes == null`) keeps pre-v1.5 shape byte-identical
        // (existing `parser_decl.zig` line 64-98 fixtures pin
        // `init.array_lit.size` and do not touch `sizes`).
        if (a.sizes) |sizes| {
            for (sizes[0 .. sizes.len - 1]) |s| {
                var s_buf: [16]u8 = undefined;
                const s_str = std.fmt.bufPrint(&s_buf, "{d}", .{s}) catch "0";
                self.write("[");
                self.write(s_str);
                self.write("]");
            }
            self.write("[");
            self.write(size_str);
            self.write("]");
            self.write(zagTypeToZig(a.type_name));
            self.write("{ ");
            for (a.elements, 0..) |el, idx| {
                if (idx > 0) self.write(", ");
                self.genExpr(el);
            }
            self.write(" }");
            return;
        }
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
        // Copy the parent's `type_info` map into args_cg so the
        // child's genExpr routes through `.call` arm closure-bound
        // detection (`isClosureBound` consults type_info_buf to
        // identify `<name>.call(...)` rewrite targets). Without this
        // transfer the placeholder `args_cg.genExpr(expr)` call sees
        // a fresh Codegen with `type_info_count == 0` and falls
        // through to the bare `<name>(<args>)` emit, which zig then
        // rejects as `type 'main__struct_X' not a function` when the
        // `<name>` is a closure binding. The user's `print("double(5)
        // = {double(5)}\n")` demo relies on this; the previous
        // shape passed because zig-side type resolution was more
        // lenient (or the test surface didn't exercise closure-in-
        // template). Now that zig 0.16's stricter dispatch is wired,
        // the transfer is required. Mirrors the `type_info =
        // type_info::init()` pattern at codegen struct init.
        args_cg.type_info_buf = self.type_info_buf;
        args_cg.type_info_count = self.type_info_count;
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
                // Gap #6 carry (template-literal arm): when the
                // interpolated expr is an `.ident` whose typed-
                // binding source-type rewrites to `[]const u8`
                // via `zagTypeToZig` (covering both explicit
                // `[]const u8` annotations AND the `str` alias
                // per docs/07's transparent-`[]const u8` contract),
                // emit `{s}` so zig's string formatter displays
                // the slice's contents (`hello`) instead of the
                // element list (`{ 104, 101, 108, 108, 111 }`).
                // The `{any}` default still works correctly for
                // primitive scalar types (i32, bool, u8, f64, ...)
                // so they fall through unchanged.
                //
                // Optional byte slices (`?[]const u8`) are NOT
                // routed through `{s}` because zig's `{s}`
                // formatter strictly requires `[]const u8` and
                // rejects the optional form. The `{any}` fallback
                // emits a zigzag-native discriminant display
                // (`null` or `.{ ... }`) which the user can re-
                // extract via `.?` for the string form:
                // `print("{maybe_s.?}")` forces the non-null
                // slot. This mirrors the fall-through gap #6
                // already made in `genPrintCall`'s else arm —
                // aligning the two sites keeps print behaviour
                // consistent across both `print(arg)` and
                // `print(\"v={arg}\")` surfaces.
                //
                // Closes pointers.zag's residual `also_slice =
                // { 104, 101, 108, 108, 111 }` bug where the
                // typed binding `let also_slice: ?[]const u8`
                // (with literal-cover traversal now emitting
                // a non-null value of type `[]const u8`)
                // printed as bytes; the optional cover case is
                // unaffected (still emits discriminant), only
                // the non-optional annotated byte-slice
                // interpolation surfaces the string instead.
                // Gap #6 widening, DRY-extracted to
                // `typeAwareFmtSpec`: this interpolation-slot site
                // reuses the same helper that `genPrintCall`'s else
                // arm calls. `fmt_buf` writes `{<spec>}` itself
                // (the surrounding `{...}` brace handling for the
                // template-literal form is downstream of this
                // helper call), so the spec returned is bare (`s`
                // or `any`) and the for-loop that builds
                // `fmt_buf` below adds the braces. The
                // `is_optional_byte_slice` flag is consumed
                // identically in both sites — appending `orelse
                // ""` after the genExpr'd ident so the
                // strictly-typed `{s}` formatter accepts the
                // non-optional slice.
                //
                // Optional byte slices (`?[]const u8`) ARE
                // routed through `{s}` here (vs. the prior
                // gap #6 narrowing that left them on `{any}`)
                // because the helper's substring match
                // catches the rewritten type while the
                // leading-`?` gate fires the optional-unwrap.
                // This divergence from the genPrintCall else
                // arm's docs is intentional and documented in
                // the helper's docblock above.
                var format_spec: []const u8 = "any";
                var is_optional_byte_slice = false;
                // v1.6 byte-slice widening, gap-closure: identical
                // to the genPrintCall else arm above — route
                // through `typeAwareFmtSpecFromExpr` so
                // `.member_access` interpolation args widen to
                // `{s}` when the accessed field is a byte-slice.
                // The fmt_buf append here mirrors the existing
                // brace-wrapping pattern (`{` + spec + optional
                // `:` + spec + `}`).
                const info = typeAwareFmtSpecFromExpr(self, expr);
                format_spec = info.spec;
                is_optional_byte_slice = info.is_optional_byte_slice;
                if (fmt_len + 1 + format_spec.len + (if (part.spec) |spec| 1 + spec.len else 0) + 1 <= fmt_buf.len) {
                    fmt_buf[fmt_len] = '{';
                    fmt_len += 1;
                    for (format_spec) |c| {
                        fmt_buf[fmt_len] = c;
                        fmt_len += 1;
                    }
                    if (part.spec) |spec| {
                        fmt_buf[fmt_len] = ':';
                        fmt_len += 1;
                        for (spec) |c| {
                            fmt_buf[fmt_len] = c;
                            fmt_len += 1;
                        }
                    }
                    fmt_buf[fmt_len] = '}';
                    fmt_len += 1;
                }
                if (!first_arg) args_cg.write(", ");
                args_cg.genExpr(expr);
                if (is_optional_byte_slice) args_cg.write(" orelse \"\"");
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
