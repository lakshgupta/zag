const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
// June-style escape analysis (src/codegen/escape.zig): classifies
// every `new` site in a function body as Local / escaping / freed /
// arena-backed via fixed-point use-def flow; genFun & co. consume
// the verdict side-vector to auto-insert `defer destroy` for Local
// sites (see emitEscapePrologue in core.zig + the `.new_expr` arm
// in expr.zig). Mirrors June's "Lifetime Checker" pass shape.
const escape = @import("escape.zig");
const lexer = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");

/// Module-level scratch for `zagTypeToZig`'s generic-instantiation
/// rebuild (see the recursion branch in the helper) — a stack-local
/// buffer would dangle past return; the returned slice is consumed
/// by the next writeType before any subsequent call overwrites it
/// (single-threaded compiler).
var zag_type_zig_scratch: [256]u8 = undefined;

// Cross-bucket file-scope aliases. See CROSS_BUCKET_REEXPORTS in
// the extraction script for rationale.
const Codegen = core.Codegen;

// ============================================================
// FILE-SCOPE methods (DECL bucket)
// ============================================================

    /// June-style escape-analysis wiring shared by every function-
    /// body emitter (genFun / genMethod / genFreeMethod / genTestFun):
    /// run the fixed-point pass over the body, stash the verdict
    /// side-vector on `self` (the `.new_expr` arm in expr.zig
    /// consumes `escape_autofree`), then emit the hoisted
    /// allocation+defer prologue for the Local sites. Must run
    /// BEFORE any body statement emits — alloc_counter is still 0
    /// here, and the analysis numbers sites in AST walk order so
    /// its indices align with the alloc_counter values the
    /// `.new_expr` arm will assign during emission.
    pub     fn runEscapeAnalysis(self: *Codegen, params: []const ast.MethodParam, body: []const ast.Stmt, tail_match_returns: bool) void {
        // Manual memory model (zig-style, docs/19-memory.md): the
        // escape analysis is a DIAGNOSTIC pass — it never changes the
        // emitted code. Every LEAK-verdict site (never escapes the
        // function, never explicitly freed, page allocator) gets a
        // compile-time warning naming the site; freeing remains the
        // user's explicit `free` / `defer free`. The .new_expr arm
        // therefore always emits the inline create form (no hoisted
        // prologue, no inserted defers).
        const er = escape.analyze(params, body, tail_match_returns);
        var i: u32 = 0;
        while (i < er.site_count) : (i += 1) {
            if ((er.leaks >> @intCast(i)) & 1 == 0) continue;
            const loc = er.site_locs[i];
            const symbol = if (self.current_symbol.len > 0) self.current_symbol else "<top>";
            std.debug.print("warning: `new {s}` at {s}:{d}:{d} in {s} is never freed (leak) — add an explicit `free` or `defer free`\n", .{
                er.sites[i].type_name,
                if (self.source_path.len > 0) self.source_path else "<source>",
                loc.line,
                loc.col,
                symbol,
            });
        }
    }

    pub     fn rewriteReceiverType(self: *Codegen, text: []const u8, tps: []const ast.TypeParam) void {
        // Generics (§5 Generic impl Blocks): inside an
        // `impl<T, U, ...> Target<T, U, ...>` block, method-receiver
        // `type_text` carries turbofish syntax (`*Target<T>`, `*const
        // Map<K, V>`, `[]Option<T>`). zig's thunk form for generic
        // structs requires paren-monomorphization (`*Target(T)`,
        // `*const Map(K, V)`, `[]Option(T)`), so this helper scans each
        // `<...>` segment inside `text` and converts it to `(...)` when
        // its contents match a type-param name declared on the
        // enclosing impl. Segments whose contents are NOT in the
        // current impl's type-param list are emitted verbatim — the
        // user's other generic types (none generic structs / enums)
        // round-trip as-is and would require explicit handling if v1
        // ever grows multi-param canonical-form generics elsewhere.
        //
        // Multi-token names like `*const Map<K, V>` are handled by
        // walking the segment characters: split on `<`, locate the
        // matching `>` (single-level greedy; nested generic-arg
        // expressions are not chunked, the `K, V` body emits verbatim
        // because no single TypeParam.name matches the comma-bearing
        // string), then rewrite-or-leave the contents. First-segment
        // rewrite only — the user's v1 surface is single-level
        // turbofish as per docs/16 §1 (`T`, `T, U`, `K, V`).
        //
        // Choosing Option A (rewrite only when contents match the
        // current impl's type_params) over the more aggressive
        // every-`<...>` rewrite keeps generic-enum mono usage working
        // at impl-block receivers where no rewrite is wanted.
        if (tps.len == 0) {
            self.write(text);
            return;
        }
        var i: usize = 0;
        while (i < text.len) {
            const lt = std.mem.indexOfScalar(u8, text[i..], '<');
            if (lt == null) {
                self.write(text[i..]);
                return;
            }
            const lt_abs = i + lt.?;
            self.write(text[i..lt_abs]);
            // Find the matching `>` (single-level; nested generics not
            // yet supported as a turbofish case).
            const gt_rel = std.mem.indexOfScalar(u8, text[lt_abs + 1 ..], '>');
            if (gt_rel == null) {
                // Unbalanced `<` — emit the rest verbatim and bail.
                self.write(text[lt_abs..]);
                return;
            }
            const inner_start = lt_abs + 1;
            const inner_end = lt_abs + 1 + gt_rel.?;
            const inner = text[inner_start..inner_end];
            // Trim whitespace so `Map< K, V >` (source-discretionary
            // spacing) doesn't miss the tps match by a stray space.
            var a: usize = 0;
            var b: usize = inner.len;
            while (a < b and (inner[a] == ' ' or inner[a] == '\t')) : (a += 1) {}
            while (b > a and (inner[b - 1] == ' ' or inner[b - 1] == '\t')) : (b -= 1) {}
            const trimmed = inner[a..b];
            var matched: ?[]const u8 = null;
            for (tps) |tp| {
                if (std.mem.eql(u8, tp.name, trimmed)) {
                    matched = tp.name;
                    break;
                }
            }
            if (matched == null) {
                // Multi-param segments — `Map<K, V>` (std.collections
                // HashMap receiver): rewrite when EVERY comma-split
                // element is a declared type param, so the thunk form
                // gets `*HashMap(K, V)` rather than the invalid
                // `*HashMap<K, V>`.
                var all_params = true;
                var any_split = false;
                var start: usize = 0;
                var s: usize = 0;
                while (s <= trimmed.len) : (s += 1) {
                    if (s == trimmed.len or trimmed[s] == ',') {
                        if (s > start) any_split = true;
                        const part = std.mem.trim(u8, trimmed[start..s], " ");
                        var found = false;
                        for (tps) |tp| {
                            if (std.mem.eql(u8, tp.name, part)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) all_params = false;
                        start = s + 1;
                    }
                }
                if (any_split and all_params) {
                    // Rewrite the comma list to paren form; the
                    // trimmed contents are exactly the param names
                    // (single-level, no nesting in the v1 surface).
                    var rebuilt: [256]u8 = undefined;
                    var rl: usize = 0;
                    var rs: usize = 0;
                    var w: usize = 0;
                    while (w <= trimmed.len) : (w += 1) {
                        if (w == trimmed.len or trimmed[w] == ',') {
                            const part = std.mem.trim(u8, trimmed[rs..w], " ");
                            if (rl > 0 and rl < rebuilt.len) {
                                rebuilt[rl] = ',';
                                rl += 1;
                            }
                            @memcpy(rebuilt[rl..][0..part.len], part);
                            rl += part.len;
                            rs = w + 1;
                        }
                    }
                    matched = @constCast(rebuilt[0..rl]);
                }
            }
            if (matched) |name| {
                self.write("(");
                self.write(name);
                self.write(")");
            } else {
                // Not a current-impl type-param; emit the segment
                // verbatim (non-generic use case, or a generic-enum
                // reference that v1 doesn't yet rewrite).
                self.write("<");
                self.write(inner);
                self.write(">");
            }
            i = inner_end + 1;
        }
    }

    /// Mark every function parameter the body never references with
    /// a leading `_ = <name>;` discard at body entry - zig 0.16
    /// rejects unused function parameters with a hard error (docs
    /// examples' trait-method shims like `log(self: *Console, msg:
    /// str)` with no `msg` use; docs/manual/29 "unused method
    /// parameters are declared `_ = x;`"). Conservative shape:
    /// a shallow lexical walk (params referenced ANYWHERE in the
    /// body count as used, no scoping), so a false "used" verdict
    /// only leaves an unused param for zig to flag - never discards
    /// a genuinely used one. Bounded walks. `self` is NOT skipped:
    /// zig flags an unused `self: *T` receiver exactly like any
    /// other param (default-method bodies that ignore the receiver
    /// — docs/18 §Default Methods — need the discard too), and for
    /// used receivers the walk marks it like any name.
    ///
    /// Discriminated-union subtlety: `.let`/`.var_binding`/
    /// `.const_binding` share the same payload struct, so the switch
    /// arms must be grouped - a per-tag payload capture is rejected
    /// by zig 0.16 for aliasing duplicates of the same payload type.
    pub fn markUnusedParamDiscards(self: *Codegen, params: []const ast.MethodParam, body: []const ast.Stmt) void {
        var used: [16]bool = [_]bool{false} ** 16;
        var walker = UsedNameWalker{ .names = undefined, .used = &used };
        for (params, 0..) |p, i| {
            if (i >= used.len) break;
            walker.names[i] = p.name;
            walker.name_count += 1;
        }
        for (body) |s| walker.walkStmt(s);
        for (used[0..walker.name_count], 0..) |is_used, i| {
            if (!is_used) {
                self.write("    _ = ");
                self.write(params[i].name);
                self.write(";\n");
            }
        }
    }

    const UsedNameWalker = struct {
        names: [16][]const u8,
        used: *[16]bool,
        name_count: usize = 0,

        fn mark(self: *UsedNameWalker, name: []const u8) void {
            for (self.names[0..self.name_count], 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) self.used[i] = true;
            }
        }

        fn walkStmt(self: *UsedNameWalker, s: ast.Stmt) void {
            switch (s.payload) {
                .let, .var_binding, .const_binding => |b| {
                    if (b.init) |init| self.walkExpr(init);
                    if (b.block) |blk| for (blk) |bs| self.walkStmt(bs);
                },
                .assign => |a| self.walkExpr(a.value),
                .index_assign => |ia| {
                    self.walkExpr(ia.target.*);
                    self.walkExpr(ia.index.*);
                    self.walkExpr(ia.value);
                },
                .defer_stmt => |d| self.walkExpr(d.expr),
                .errdefer_stmt => |d| self.walkExpr(d.expr),
                .unsafe_block => |blk| for (blk) |bs| self.walkStmt(bs),
                .expr_stmt => |e| self.walkExpr(e),
                .if_stmt => |is| {
                    self.walkExpr(is.cond);
                    for (is.then_body) |bs| self.walkStmt(bs);
                    switch (is.else_kind) {
                        .none => {},
                        .block => |blk| for (blk) |bs| self.walkStmt(bs),
                        .if_chain => |chain| self.walkStmt(.{ .payload = .{ .if_stmt = chain.* }, .loc = s.loc }),
                    }
                },
                .while_stmt => |ws| {
                    self.walkExpr(ws.cond);
                    for (ws.body) |bs| self.walkStmt(bs);
                },
                .for_stmt => |fs| {
                    self.walkExpr(fs.iter);
                    for (fs.body) |bs| self.walkStmt(bs);
                },
                .match_stmt => |ms| self.walkMatch(ms),
                .break_stmt, .continue_stmt => {},
                .return_stmt => |rs| if (rs.value) |v| self.walkExpr(v),
                .field_assign => |fa| {
                    self.walkExpr(fa.target.*);
                    self.walkExpr(fa.value);
                },
                .deref_assign => |da| self.walkExpr(da.value),
            }
        }

        fn walkMatch(self: *UsedNameWalker, ms: ast.Expr.MatchExpr) void {
            self.walkExpr(ms.scrutinee.*);
            for (ms.arms) |arm| {
                if (arm.guard) |g| self.walkExpr(g.*);
                self.walkExpr(arm.expr.*);
            }
        }

        fn walkExpr(self: *UsedNameWalker, e: ast.Expr) void {
            switch (e.payload) {
                .ident => |name| self.mark(name),
                .string_lit, .int_lit, .float_lit, .bool_lit, .char_lit, .byte_string_lit, .null_lit, .undefined_lit => {},
                .tuple_lit => |els| for (els) |el| self.walkExpr(el),
                .single_tuple_lit => |el| self.walkExpr(el.*),
                .named_tuple_lit => |nt| for (nt.elements) |el| self.walkExpr(el),
                .array_lit => |a| for (a.elements) |el| self.walkExpr(el),
                .call => |c| {
                    for (c.args) |a| self.walkExpr(a);
                },
                .new_expr => |n| self.walkExpr(n.value.*),
                .free_expr => |f| self.walkExpr(f.target.*),
                .deref => |d| self.walkExpr(d.target_ptr.*),
                .cast => |c| self.walkExpr(c.expr.*),
                .template_lit => |t| {
                    for (t.parts) |part| {
                        if (part.expr) |pe| self.walkExpr(pe);
                    }
                },
                .binary => |b| {
                    self.walkExpr(b.lhs.*);
                    self.walkExpr(b.rhs.*);
                },
                .unary => |u| self.walkExpr(u.operand.*),
                .index => |ix| {
                    self.walkExpr(ix.target.*);
                    self.walkExpr(ix.index.*);
                },
                .slice => |sl| {
                    self.walkExpr(sl.target.*);
                    if (sl.start) |st| self.walkExpr(st.*);
                    if (sl.end) |en| self.walkExpr(en.*);
                },
                .range => |r| {
                    self.walkExpr(r.start.*);
                    self.walkExpr(r.end.*);
                },
                .if_expr => |ie| {
                    self.walkExpr(ie.cond.*);
                    self.walkExpr(ie.then_expr.*);
                    self.walkExpr(ie.else_expr.*);
                },
                .match_expr => |ms| self.walkMatch(ms),
                .struct_lit => |sl| {
                    for (sl.inits) |ini| self.walkExpr(ini.value.*);
                },
                .member_access => |ma| self.walkExpr(ma.target.*),
                .method_call => |mc| {
                    self.walkExpr(mc.target.*);
                    for (mc.args) |a| self.walkExpr(a);
                },
                .enum_variant_ctor => |evc| for (evc.args) |a| self.walkExpr(a),
                .closure => |cl| {
                    for (cl.body) |bs| self.walkStmt(bs);
                },
                .try_op => |t| self.walkExpr(t.expr.*),
                .catch_expr => |c| {
                    self.walkExpr(c.expr.*);
                    self.walkExpr(c.handler.*);
                },
                .block_expr => |blk| for (blk) |bs| self.walkStmt(bs),
                .const_block => |blk| for (blk) |bs| self.walkStmt(bs),
                .asm_expr => |a| {
                    for (a.outputs) |op| self.walkExpr(op.expr.*);
                    for (a.inputs) |op| self.walkExpr(op.expr.*);
                },
                .await_expr => |ae| self.walkExpr(ae.expr.*),
            }
        }
    };

    pub     fn genFreeMethod(self: *Codegen, target_type: []const u8, m: ast.MethodDecl, impl_type_params: []const ast.TypeParam) void {        // Trait-method rename (docs/17 §"Implementing"): when `m.trait_name`
        // is set (the `Trait.method` source shape), the emitted free-fn name
        // becomes `<TargetType>_<TraitName>_<MethodName>` so the vtable
        // registration can reference the implementation by exact-name. The
        // legacy orphan path emits `<TargetType>_<MethodName>` so trait-method
        // and non-trait methods never collide (the renaming infix adds the
        // trait-qualifier). The pre-trait shape (no trait_name) keeps the
        // legacy 234-baseline path so all orphan-impl tests pin identically.
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        if (m.trait_name) |tn| {
            @memcpy(name_buf[name_len..][0..target_type.len], target_type);
            name_len += target_type.len;
            name_buf[name_len] = '_';
            name_len += 1;
            @memcpy(name_buf[name_len..][0..tn.len], tn);
            name_len += tn.len;
            name_buf[name_len] = '_';
            name_len += 1;
            @memcpy(name_buf[name_len..][0..m.name.len], m.name);
            name_len += m.name.len;
        }
        self.write("pub fn ");
        if (m.trait_name != null) {
            self.write(name_buf[0..name_len]);
        } else {
            self.write(target_type);
            self.write("_");
            self.write(m.name);
        }
        self.write("(");
        // Generics impl-level type_params preamble. Mirrors genMethod
        // and genFun so generic impl-blocks land as
        // `pub fn List_T_push(comptime T: type, self: *List(T), value: T)`.
        // The `*List(T)` receiver is produced by `rewriteReceiverType`
        // (above) which converts `<TyParamName>` to `(TyParamName)` for
        // each segment whose contents match the impl's declared type
        // params. See `rewriteReceiverType`'s doc for the multi-token
        // and non-matching-passthrough semantics.
        const generics_preamble = self.genTypeParamsPreamble(impl_type_params);
        for (m.params, 0..) |p, i| {
            if (i > 0 or generics_preamble) self.write(", ");
            // Phase 2 var-p name-isolation (zig 0.16 fix): when
            // `is_var` is set, rename the parameter to
            // `__zag_local_<name>` so the body's
            // `var <name> = __zag_local_<name>;` introduces a fresh
            // local rather than shadowing the parameter. zig 0.16
            // rejects any local variable that shares a name with a
            // function parameter (`local variable 'x' shadows
            // function parameter from outer scope`).
            if (p.is_var) self.write("__zag_local_");
            self.write(p.name);
            self.write(": ");
            self.rewriteReceiverType(zagTypeToZig(p.type_text), impl_type_params);
        }
        self.write(") ");
        if (m.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(" {\n");
        // Unused-param discard pass (docs/manual/18 SS Default Methods
        // + docs/29): zig 0.16 hard-errors on unused fn params; trait-
        // method shims routinely ignore some of them. Emits `_ = name;`
        // for each body-unreferenced param BEFORE any body stmts.
        self.markUnusedParamDiscards(m.params, m.body);
        // Reset per-function counters (matching `genMethod`/`genFun`).
        self.destructure_counter = 0;
        self.alloc_counter = 0;
        self.match_counter = 0;
        self.blk_counter = 0;
        self.current_symbol = m.name;
        self.type_info_count = 0;
        // v1.7 param-type seeding (mirror of genFun's): the generic-
        // dispatch path reads the receiver's tracked type to rewrite
        // `self.grow()` → `ArrayList_grow(T, self)` — without seeding
        // `self: *ArrayList(T)` the call stays verbatim and zig
        // rejects it ("no field or member function named 'grow'",
        // surfaced by std.collections grow/probe). Same for print
        // placeholders on method params.
        for (m.params) |p| {
            if (self.type_info_count >= self.type_info_buf.len) break;
            var already = false;
            for (self.type_info_buf[0..self.type_info_count]) |ti| {
                if (std.mem.eql(u8, ti.name, p.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            self.type_info_buf[self.type_info_count] = .{
                .name = p.name,
                .type_name = p.type_text,
                .is_closure = false,
            };
            self.type_info_count += 1;
        }
        self.fn_returns_value = m.return_type != null;
        if (m.return_type) |rt| self.setFnRetType(rt) else self.fn_ret_type_len = 0;
        // async is a top-level `async fun` surface (v1); methods are
        // always synchronous — keep the future-wrap flag off.
        self.fn_is_async = false;
        // v1.6 byte-slice widening: set the per-body method-receiver
        // struct-name so `print(self.byte_slice_field)` widens the
        // format spec to `{s}` (per typeAwareFmtSpecFromExpr in
        // src/codegen/primary.zig). Reset on next genFun body entry
        // or on the next non-impl member set, so subsequent fns /
        // orphans don't inherit this impl's receiver by mistake.
        self.current_receiver_struct_name = target_type;
        // Trait-bounds guards (docs/16 §3) — mirrors genFun's body
        // entry so unresolved impl-block generic bounds surface
        // as a zag compile-error at the user's source-line.
        self.genBoundsGuards(impl_type_params);
        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry. The
        // fresh local `<name>` is mutable (allowing body mutations like
        // `x += 1`), and the parameter carrying the caller's value
        // passes through zig's pass-by-value default — caller isolation
        // is preserved. The body still references `<name>` verbatim; the
        // local shadows nothing because the parameter has a different
        // name (`__zag_local_<name>`).
        for (m.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = __zag_local_");
                self.write(p.name);
                self.write(";\n");
            }
        }
        for (m.body) |s| self.collectTypedBindings(s);
        // June-style escape analysis (see runEscapeAnalysis doc).
        self.runEscapeAnalysis(m.params, m.body, m.return_type != null);
        for (m.body, 0..) |s, i| self.genStmt(s, self.fn_returns_value and i == m.body.len - 1);
        // Reset ONLY the receiver-tracking field at body end —
        // `fn_returns_value` is set per-body by every genFun/
        // genMethod/genFreeMethod entry, so an explicit reset
        // would be redundant (and was previously rejected by the
        // code-reviewer as a stray copy-paste — left as a comment
        // here so future drive-by cleanups don't reintroduce it).
        self.current_receiver_struct_name = null;
        self.write("}\n");
    }

    pub     fn genStructDecl(self: *Codegen, sd: ast.StructDecl, all_impls: []const ast.ImplBlock) void {
        // Doc (docs/02 §"Doc Comments"): emit `/// ` lines immediately
        // BEFORE the `pub const NAME = ...` emit so the doc survives
        // through to the zig container site. Mirrors genFun's
        // `if (fun.doc) |d| self.genDocComment(d)` call. The parser
        // has already attached `sd.doc` via StructDecl.doc — null
        // means no doc, render the bare `pub const NAME = struct {...}`
        // shape (existing tests pin this path).
        if (sd.doc) |d| self.genDocComment(d);
        // Generics (§2 Generic Types): when `sd.type_params.len > 0`,
        // emit the thunk form `pub fn NAME(comptime T0: type, ...) type
        // { return struct { … }; }` so call sites `List(i32, ...)`
        // resolve at monomorphization time. The non-generic path keeps
        // the existing `pub const NAME = struct { … };` shape so all
        // pre-existing tests/examples round-trip unchanged.
        //
        // Nested impl-method emission is SKIPPED on the thunk path. The
        // returned struct type cannot contain methods directly (zig
        // compiles the return type as a fresh anonymous type per call
        // site, so nested methods would clash on per-monomorphization
        // vtable construction). The `generate` function in core.zig
        // marks generic structs as orphans by NOT recording them in
        // `matched_targets_buf` so the matching impls fall through to
        // `genFreeMethod`'s orphan-impl emit. The free-fn name encodes
        // `TargetType_methodName` and includes the rewritten receivers
        // (via `rewriteReceiverType`), so `List_T_push(comptime T: type,
        // self: *List(T), value: T)` is the actual emitted form once
        // generic impl-block wires in.
        const is_generic = sd.type_params.len > 0;
        if (is_generic) {
            self.write("pub fn ");
            self.write(sd.name);
            self.write("(");
            _ = self.genTypeParamsPreamble(sd.type_params);
            self.write(") type {\n    return struct {\n");
        } else {
            self.write("pub const ");
            self.write(sd.name);
            self.write(" = struct {\n");
        }
        for (sd.fields) |f| {
            switch (f.kind) {
                .named => |nf| {
                    self.write("    ");
                    self.write(nf.name);
                    self.write(": ");
                    self.writeType(nf.type_text);
                    self.write(",\n");
                },
                .embed => |ef| {
                    // Embedding promotion: docs/12 "embedded types promote
                    // their fields + methods into the outer struct". The
                    // simplifcation is to emit a named field whose type is
                    // the embedded type itself; `.field` access then goes
                    // through a one-level indirection (`btn.Widget.x`).
                    // Strict Promotion (where `btn.x` resolves directly) is
                    // deferred to a followup commit because zig 0.16 does
                    // not expose anonymous-struct flattening macros — a
                    // field-shorthand trick is plausible but breaks
                    // struct-literal's `T { .f = … }` enforcement on
                    // anonymous fields, so the indirection form is the
                    // safe first-pass until the spread-flavor lands.
                    self.write("    ");
                    self.write(ef.type_name);
                    self.write(": ");
                    self.write(ef.type_name);
                    // No `= .{}` default: zig requires EVERY field of
                    // the embedded struct to have a default before a
                    // struct-level default is legal (`missing struct
                    // field: x`). The field is unconditionally provided
                    // at every construction site — the positional-
                    // embed-slot emit in expr.zig names it `.Embed = ...`
                    // — so a default is dead weight that only breaks
                    // compilation.
                    self.write(", // embedded (promote fields+methods via dot deref)\n");
                },
            }
        }
        // Embedding promotion: for each embed field, emit forwarding
        // getter methods that flatten the embedded type's fields and
        // methods into the outer struct's namespace. `btn.pos()` and
        // `btn.click()` resolve directly — no `btn.Widget.` prefix
        // needed. Only runs on the non-generic path (generic structs
        // use thunk form which can't host nested methods).
        if (!is_generic) {
            for (sd.fields) |f| {
                if (f.kind != .embed) continue;
                const embed_type = f.kind.embed.type_name;
                // Forward named fields of the embedded struct as
                // getter methods.
                for (self.prog.structs) |esd| {
                    if (!std.mem.eql(u8, esd.name, embed_type)) continue;
                    for (esd.fields) |ef| {
                        if (ef.kind != .named) continue;
                        const fn_field = ef.kind.named;
                        self.write("    pub fn ");
                        self.write(fn_field.name);
                        self.write("(self: *const ");
                        self.write(sd.name);
                        self.write(") ");
                        self.writeType(fn_field.type_text);
                        self.write(" {\n");
                        self.write("        return self.");
                        self.write(embed_type);
                        self.write(".");
                        self.write(fn_field.name);
                        self.write(";\n");
                        self.write("    }\n");
                    }
                    break;
                }
                // Forward non-trait methods from impl blocks on the
                // embedded type.
                for (self.prog.impls) |impl| {
                    if (!std.mem.eql(u8, impl.target_type, embed_type)) continue;
                    for (impl.methods) |m4| {
                        if (m4.trait_name != null) continue;
                        self.write("    pub fn ");
                        self.write(m4.name);
                        self.write("(");
                        // Rewrite the first param (self) to the outer type.
                        // The receiver constness mirrors the EMBEDDED
                        // method's: `self: *Widget` forwards as
                        // `self: *Button` (zig accepts `*Button` →
                        // `*Widget` via the named `Widget` field — the
                        // forwarding body passes `&self.Widget`), but a
                        // `*const Button` forwarder CANNOT hand `*Widget`
                        // to the inner call (const-discard). Callers on
                        // `let` bindings would fail, so `*T` receivers
                        // forward as `*T`.
                        for (m4.params, 0..) |p4, pi| {
                            if (pi > 0) self.write(", ");
                            self.write(p4.name);
                            self.write(": ");
                            if (p4.is_self) {
                                self.write("*");
                                self.write(sd.name);
                            } else {
                                self.writeType(p4.type_text);
                            }
                        }
                        self.write(") ");
                        if (m4.return_type) |rt| self.writeType(rt) else self.write("void");
                        self.write(" {\n");
                        // Unused-param discard pass (docs/manual/18 SS
                        // "Structural Embedding"): forwarding shims that
                        // drop an argument still bind it - discard it.
                        self.markUnusedParamDiscards(m4.params, m4.body);
                        if (m4.return_type != null) {
                            self.write("        return ");
                        } else {
                            self.write("        ");
                        }
                        self.write("self.");
                        self.write(embed_type);
                        self.write(".");
                        self.write(m4.name);
                        self.write("(");
                        // p5[0] is the embedded receiver: the inner call
                        // is a METHOD call on `self.<Embed>` — zig's
                        // method sugar passes `&self.<Embed>` itself, so
                        // the forwarder emits NO explicit receiver arg
                        // (a manual `&self.<Embed>` would double the
                        // receiver: `self.Widget.show(&self.Widget)`).
                        for (m4.params[1..]) |p5| {
                            self.write(", ");
                            self.write(p5.name);
                        }
                        self.write(");\n");
                        self.write("    }\n");
                    }
                }
            }
        }
        // Nest matching impl methods inside the struct definition. The
        // body emission path is shared with `genFun` so all the existing
        // stmt/expr handling (destructuring, compound assign, if/match,
        // etc.) works for methods too. Each method body sees a fresh
        // counter set so destructuring temps + new-temporaries inside
        // the method don't clash with sibling methods' temps. SKIPPED
        // on the generic struct path because the thunk-returned type
        // cannot host nested methods (zig compiles each monomorphization
        // to a fresh anonymous type); see the doc above on the thunk
        // form. The orphan-impl routing in `generate` catches the
        // matching impls and lands them at module scope. TRAIT-method
        // methods (Trait.method-prefixed impl methods whose
        // `trait_name` is non-null) are SKIPPED here too — they emit
        // as renamed free fns (Target_Trait_method) + vtable
        // registration during the trait-handling pass, NEVER nested
        // inside the struct body (the nested shape lacks the trait
        // prefix in the zig fn name which the vtable registration
        // references by exact-string).
        if (!is_generic) {
            for (all_impls) |impl| {
                if (!std.mem.eql(u8, impl.target_type, sd.name)) continue;
                for (impl.methods) |m| {
                    // Canonical `with Trait (m)` dispatch (docs/17
                    // §"Diamond Disambiguation"): a method bound to a
                    // trait (via the legacy `Trait.method` prefix OR the
                    // block's `trait_specs` clause) skips nested-emit so
                    // the trait-handling pass in `generate` emits the
                    // renamed `<Target>_<Trait>_<Method>` free fn and
                    // matching vtable registration. Regular-type-method
                    // path (c) emits nested here.
                    if (self.resolveTraitBinding(&impl, m) != null) continue;
                    // v1.6 byte-slice widening: set receiver-struct
                    // before emitting the nested method body so
                    // `print(self.byte_slice_field)` widens correctly.
                    // Mirrors genFreeMethod's setting.
                    self.current_receiver_struct_name = impl.target_type;
                    // Phase 2 tail: thread impl-level type_params so the
                    // nested method emits `comptime X: type` BEFORE its
                    // own params. Mirrors genFreeMethod's call update.
                    self.genMethod(m, impl.type_params);
                    self.current_receiver_struct_name = null;
                }
            }
        }
        if (is_generic) {
            // Close both layers of the thunk form: the inner
            // `return struct { … };` and the outer `pub fn NAME(…) type
            // { … }`. Without the double-closing brace zig rejects the
            // emission with "expected '}' after struct body".
            self.write("    };\n}\n\n");
        } else {
            self.write("};\n\n");
        }
    }

    pub     fn genMethod(self: *Codegen, m: ast.MethodDecl, impl_type_params: []const ast.TypeParam) void {
        // Receiver tracking for nested method bodies (genStructDecl
        // sets it before calling, but a direct genMethod call — e.g.
        // the resolver-body path — may arrive without it). Only set
        // when NOT already tracking; the caller's reset handles the
        // restore.
        self.write("    pub fn ");
        self.write(m.name);
        self.write("(");
        // Generics impl-level type_params preamble. Mirrors genFun
        // — emits `comptime X: type` (or `comptime X: TYPE`) for each
        // impl-block type-param BEFORE the method's own params. The
        // matching call site (genStructDecl / genEnumDecl for the
        // nested case; the orphan-impl loop in generate for the
        // free-fn case via genFreeMethod) threads `impl.type_params`
        // in. Phase 4 wires the `*List<T>` → `*List(T)` receiver
        // rewrite via `rewriteReceiverType` so generic impl-block
        // method parameters resolve through the thunk form.
        const generics_preamble = self.genTypeParamsPreamble(impl_type_params);
        for (m.params, 0..) |p, i| {
            if (i > 0 or generics_preamble) self.write(", ");
            // Phase 2 var-p name-isolation (zig 0.16 fix): when
            // `is_var` is set, rename the parameter to
            // `__zag_local_<name>` so the body's
            // `var <name> = __zag_local_<name>;` introduces a fresh
            // local rather than shadowing the parameter. zig 0.16
            // rejects any local variable that shares a name with a
            // function parameter (`local variable 'x' shadows
            // function parameter from outer scope`).
            if (p.is_var) self.write("__zag_local_");
            self.write(p.name);
            self.write(": ");
            self.rewriteReceiverType(zagTypeToZig(p.type_text), impl_type_params);
        }
        self.write(") ");
        if (m.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(" {\n");
        // Unused-param discard pass - see genFreeMethod's comment.
        self.markUnusedParamDiscards(m.params, m.body);
        // Trait-bounds guards (docs/16 §3) — see genFun's comment.
        self.genBoundsGuards(impl_type_params);
        // Reset per-function counters before this method body's emission
        // so destructuring temps (`__destruct_<N>`) and `new` temps
        // (`__p_<N>`) and match scrutinees (`__m_<N>`) start fresh at
        // `_0`. These counters will be re-zeroed at the next `genFun`
        // entry anyway, but resetting here ensures the method body
        // inside a struct definition has its own local counter space.
        self.destructure_counter = 0;
        self.alloc_counter = 0;
        self.match_counter = 0;
        self.blk_counter = 0;
        self.current_symbol = m.name;
        // Re-populate the per-function type-info map for any locally-
        // declared typed bindings inside the method body so the
        // div-shim predicate (`needsIntDivShim`) gets correct info
        // for the method's own locals (not the enclosing pub fn's).
        self.type_info_count = 0;
        self.fn_returns_value = m.return_type != null;
        if (m.return_type) |rt| self.setFnRetType(rt) else self.fn_ret_type_len = 0;
        // Param-type seeding (mirror of genFun/genFreeMethod): the
        // generic-field dispatch (`self.timers.push(...)` —
        // std.async EventLoop) reads `self`'s tracked type to resolve
        // the field's declared generic type; without the seed the
        // member-access dispatch misses and the call emits verbatim
        // ("no field or member function named 'push'").
        for (m.params) |p| {
            if (self.type_info_count >= self.type_info_buf.len) break;
            var already = false;
            for (self.type_info_buf[0..self.type_info_count]) |ti| {
                if (std.mem.eql(u8, ti.name, p.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            self.type_info_buf[self.type_info_count] = .{
                .name = p.name,
                .type_name = p.type_text,
                .is_closure = false,
            };
            self.type_info_count += 1;
        }
        // async is a top-level `async fun` surface (v1); methods are
        // always synchronous — keep the future-wrap flag off.
        self.fn_is_async = false;
        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry. The
        // fresh local `<name>` is mutable (allowing body mutations like
        // `x += 1`), and the parameter carrying the caller's value
        // passes through zig's pass-by-value default — caller isolation
        // is preserved. The body still references `<name>` verbatim; the
        // local shadows nothing because the parameter has a different
        // name (`__zag_local_<name>`).
        for (m.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = __zag_local_");
                self.write(p.name);
                self.write(";\n");
            }
        }
        for (m.body) |s| self.collectTypedBindings(s);
        // June-style escape analysis (see runEscapeAnalysis doc).
        // Methods: the last body statement's match value is RETURNED
        // when the method has a return type (fn_returns_value), so
        // tail-position match arm flows escape in that shape.
        self.runEscapeAnalysis(m.params, m.body, m.return_type != null);
        for (m.body, 0..) |s, i| self.genStmt(s, self.fn_returns_value and i == m.body.len - 1);
        self.write("    }\n");
    }

    pub     fn genBoundsGuards(self: *Codegen, tps: []const ast.TypeParam) void {
        // Generics trait-bounds (docs/16 §3): emit one
        // `if (!@hasDecl(TP_name, "method_name")) @compileError(...);`
        // guard per bounded TypeParam. Called at body entry (BEFORE
        // var-p injection) so unresolved bounds surface as a zag
        // compile-error at the user's source-line, not as a zig
        // panic downstream.
        //
        // Unknown traits (not in boundToMethodName's canonical map)
        // skip the guard emit entirely — Phase 3 will replace this
        // pragmatic carve-out with a real trait-system wiring.
        for (tps) |tp| {
            for (tp.bounds) |b| {
                const method = boundToMethodName(b);
                if (std.mem.eql(u8, method, b)) continue;
                // Primitive types (i32, f64, ...) have no decl namespace:
                // zig 0.16 REJECTS `@hasDecl(f64, "compare")` outright
                // ("expected struct, enum, union, or opaque; found
                // 'f64'") — the `@typeInfo(T) != .int/.float` guards
                // skip the lookup so the bound passes for primitives
                // (matching the docs/16 §3 claim that built-in numerics
                // satisfy the Ordered-style protocol naturally). The
                // @typeInfo comparisons are comptime-known so the
                // `and` chain collapses to a constant in every
                // instantiation.
                self.write("    if (@typeInfo(");
                self.write(tp.name);
                self.write(") != .int and @typeInfo(");
                self.write(tp.name);
                self.write(") != .float and !@hasDecl(");
                self.write(tp.name);
                self.write(", \"");
                self.write(method);
                self.write("\")) @compileError(\"type ");
                self.write(tp.name);
                self.write(" must implement ");
                self.write(b);
                self.write(" (missing `");
                self.write(method);
                self.write("` method)\");\n");
            }
        }
    }

    pub     fn genTypeParamsPreamble(self: *Codegen, tps: []const ast.TypeParam) bool {
        // Emit `comptime X: type` (non-const) or `comptime X: TYPE`
        // (const-generic) for each type-param BEFORE the regular param
        // emit. Returns true if any preamble was emitted so the
        // caller can insert a `, ` separator between the last
        // type-param and the first regular param.
        //
        // For `const N: TYPE` slots, the verbatim type_text is
        // emitted directly (zig accepts `comptime N: usize` / `comptime
        // N: *const usize` / etc., reusing collectCastType's
        // multi-token capture pipeline).
        var emitted = false;
        for (tps) |tp| {
            if (emitted) self.write(", ");
            self.write("comptime ");
            self.write(tp.name);
            self.write(": ");
            if (tp.is_const) {
                // type_text is set by parseTypeParam when `is_const =
                // true`. We panic on a missing type_text rather than
                // fall back to a sentinel — a parser regression
                // surfacing as a zag compile-time panic is the desired
                // diagnostic, not a silently-wrong type at every
                // const-param site. Wrap through `zagTypeToZig` so
                // `fun foo(comptime N: str)` round-trips to `comptime
                // N: []const u8` (docs/07 transparent-alias contract).
                self.writeType(tp.type_text.?);
            } else {
                self.write("type");
            }
            emitted = true;
        }
        return emitted;
    }

    pub     fn zagTypeToZig(text_in: []const u8) []const u8 {
        var text: []const u8 = text_in;
        //     type str = []const u8;
        // and "Aliases are transparent" — the type and its alias are
        // the same type under the v1 type system. Codegen expands
        // the alias at emit time so downstream zig sees the canonical
        // `[]const u8` directly rather than the bare `str` ident
        // (which zig has no type slot for and would reject with
        // `unknown type name "str"` once any user writes a `str`-
        // typed annotation, param, return, cast, struct field, enum
        // payload, or binding annotation).
        //
        // v1 alias set is intentionally narrow (`str` only — the
        // borrowed-string-view alias documented in docs/11). Primitive
        // aliasing (`i32`, `f64`, `bool`, ...) is unnecessary because
        // those already are zig's native types and round-trip verbatim.
        // This helper returns `text` unchanged for any non-matching
        // input so callers don't need a `if (text == "str")` guard
        // at every emit site — the function call itself is the guard.
        //
        // The pin-test for this resolution path is
        // `codegen: void fun emits pub fn NAME(...) void` in
        // src/tests/codegen.zig (source: `fun greet(name: str) {
        // print("hello, {name}\n"); }` must emit `pub fn
        // greet(name: []const u8) void`). Any future alias
        // (docs/07 Phase 2: numeric type aliases, generic type
        // aliases, etc.) follows the same `if (eql(u8, t, NAME))
        // return CANONICAL;` pattern; do NOT site-specialize the
        // alias to a single emit location.
        if (std.mem.eql(u8, text, "str")) return "[]const u8";
        // `never` → zig `noreturn`: the bottom type, used for
        // functions that never return (e.g.
        // `pub fun exit(code: i32) -> never`). zig has no `never`
        // keyword, so the alias maps to zig's own bottom type
        // `noreturn` at every emit site (return-type annotations
        // go through the same writeType → zagTypeToZig funnel, so
        // `-> never` automatically emits `-> noreturn`). Same
        // transparent-alias pattern as `str`.
        if (std.mem.eql(u8, text, "never")) return "noreturn";
        // Generic instantiation recursion: `HashMap(i32, str)` —
        // the alias wrap must apply to each top-level type argument
        // (parenthesis-balanced split) so aliased args (`str` → the
        // borrowed view) stay transparent inside generic annotations.
        // Surfaced by std.collections: `HashMap(i32, str)` at a
        // binding annotation emitted `str` to zig, which rejects it
        // as undeclared. Nested instantiations (`Box(Box(str))`)
        // recurse via the arg-split. The rebuild lands in a
        // module-level scratch (single-threaded compiler; each
        // returned slice is consumed by the next writeType before
        // the next call overwrites it).
        // Recursed-input snapshot: when `text` IS the module scratch
        // (the turbofish-normalization recursion), the rebuild below
        // would clobber the head/tail/inner VIEWS while copying —
        // snapshot into a stack copy so the views stay intact.
        // 1024 covers deeply-nested generic signatures (e.g.
        // HashMap<String, ArrayList<Result<TimerEntry, str>>>)
        // — a truncation would silently skip the snapshot and
        // re-enter the clobber hazard it exists to prevent.
        var local_copy: [1024]u8 = undefined;
        if (@as([*]const u8, text.ptr) == @as([*]const u8, @ptrCast(&zag_type_zig_scratch[0]))) {
            if (text.len <= local_copy.len) {
                @memcpy(local_copy[0..text.len], text);
                text = local_copy[0..text.len];
            }
        }
        const open = std.mem.indexOfScalar(u8, text, '(');
        // Turbofish normalization: `Result<i32, str>` — the source
        // annotation uses `<...>`; normalize to the paren form before
        // the arg-split so the alias wrap reaches the args (`str` →
        // `[]const u8`). The rebuilt text lands in the module scratch
        // (consumed immediately by the recursion below).
        if (open == null) {
            const lt = std.mem.indexOfScalar(u8, text, '<');
            if (lt != null and lt.? > 0) {
                const gt = std.mem.lastIndexOfScalar(u8, text, '>');
                if (gt != null and gt.? > lt.?) {
                    var nl: usize = 0;
                    if (lt.? > 0) {
                        @memcpy(zag_type_zig_scratch[0..lt.?], text[0..lt.?]);
                        nl = lt.?;
                    }
                    zag_type_zig_scratch[nl] = '(';
                    nl += 1;
                    @memcpy(zag_type_zig_scratch[nl..][0 .. gt.? - lt.? - 1], text[lt.? + 1 .. gt.?]);
                    nl += gt.? - lt.? - 1;
                    zag_type_zig_scratch[nl] = ')';
                    nl += 1;
                    const tail_start = gt.? + 1;
                    if (tail_start < text.len) {
                        @memcpy(zag_type_zig_scratch[nl..][0 .. text.len - tail_start], text[tail_start..]);
                        nl += text.len - tail_start;
                    }
                    return zagTypeToZig(zag_type_zig_scratch[0..nl]);
                }
            }
        }
        if (open != null and open.? > 0) {
            // Shape validation BEFORE splitting: the arg-split exists
            // for GENERIC-INSTANTIATION text (`Head(A, B)Tail`) — the
            // text must contain exactly ONE balanced top-level paren
            // group. Fn-pointer type text (`*const fn (X) callconv(.c)
            // R`) has TWO top-level groups (the signature parens plus
            // callconv's) — splitting it mangles the rebuild (the arg
            // paren's close is NOT the last `)`, which the old
            // lastIndexOf lookup assumed), and any unbalanced `)` drove
            // `depth -= 1` on a usize (integer-overflow PANIC — the
            // compiler crashed outright on fn-pointer annotations).
            // Non-conforming shapes (2+ groups, unbalanced, or a `)`
            // before any `(`) fall through to the verbatim/*raw paths —
            // conservative: no arg-aliasing inside fn signatures, which
            // zig-native param types (usize, i64, ...) don't need.
            var depth: isize = 0;
            var groups: usize = 0;
            var balanced = true;
            var match_close: ?usize = null; // close of the first (only) group
            for (text, 0..) |ch, ti| {
                if (ch == '(') {
                    depth += 1;
                    if (depth == 1) groups += 1;
                } else if (ch == ')') {
                    depth -= 1;
                    if (depth == 0 and groups == 1 and match_close == null) match_close = ti;
                    if (depth < 0) {
                        balanced = false;
                        break;
                    }
                }
            }
            if (balanced and depth == 0 and groups == 1) {
                const close = match_close.?;
                if (close > open.?) {
                const head = text[0 .. open.? + 1];
                const tail = text[close..];
                const inner = text[open.? + 1 .. close];
                var rl: usize = 0;
                @memcpy(zag_type_zig_scratch[0..head.len], head);
                rl = head.len;
                // Inner scan: relative depth starts at 0. Shape
                // validation above guarantees every `)` in `inner`
                // matches a `(` also in `inner` (only one top-level
                // group, balanced), so isize depth cannot go negative —
                // the guard bails to the verbatim path if it ever does.
                var rdepth: isize = 0;
                var start: usize = 0;
                var i: usize = 0;
                while (i <= inner.len) : (i += 1) {
                    if (i < inner.len and inner[i] == '(') rdepth += 1;
                    if (i < inner.len and inner[i] == ')') rdepth -= 1;
                    if (rdepth < 0) {
                        balanced = false;
                        break;
                    }
                    if (i == inner.len or (rdepth == 0 and inner[i] == ',')) {
                        const part = std.mem.trim(u8, inner[start..i], " ");
                        const mapped = zagTypeToZig(part);
                        if (rl > head.len and rl < zag_type_zig_scratch.len) {
                            zag_type_zig_scratch[rl] = ',';
                            rl += 1;
                        }
                        if (rl + mapped.len <= zag_type_zig_scratch.len) {
                            // copyForwards (memmove semantics): a
                            // NESTED generic arg's recursion returns a
                            // slice into the SAME scratch — the
                            // forward copy handles the overlap.
                            std.mem.copyForwards(u8, zag_type_zig_scratch[rl..][0..mapped.len], mapped);
                            rl += mapped.len;
                        }
                        start = i + 1;
                    }
                }
                if (!balanced) {
                    // Unbalanced inner scan (shouldn't happen given the
                    // shape check above, but never underflow) — verbatim
                    // passthrough (the *raw rewrite is skipped; this is
                    // dead-code defense).
                    return text;
                }
                std.mem.copyForwards(u8, zag_type_zig_scratch[rl..][0..tail.len], tail);
                rl += tail.len;
                return zag_type_zig_scratch[0..rl];
                }
            }
        }
        // v0.1 stdlib migration (String/Writer follow-up commit):
        // String/Writer overrides removed in the String+Writer
        // migration — see the rationale block above. Type aliases
        // for these names now resolve via the imports loop's
        // `pub import std.{string,fmt}.{String,Writer}` alias emit
        // path; bare `: String` / `: Writer` references without an
        // import fail zig compilation (a deliberate narrowing of the
        // type-annotation surface area as the migration proceeds).
        // v1.5 raw pointer shapes (docs/09 §\"Raw Pointers\"): zag's
        //     *raw T        — raw pointer to T       →  zig   [*]T
        //     ?*raw T       — optional raw pointer   →  zig   ?[*]T
        // General `*raw T` → `[*]T` rewrite (zig 0.16 uses `[*]` for
        // many-pointers, not `*raw`). Also handles `c_void` → `anyopaque`
        // for FFI compatibility.
        if (std.mem.indexOf(u8, text, "*raw ")) |idx| {
            const inner = text[idx + "*raw ".len ..];
            var scratch: [256]u8 = undefined;
            var slen: usize = 0;
            @memcpy(scratch[slen..][0..idx], text[0..idx]);
            slen += idx;
            @memcpy(scratch[slen..][0..3], "[*]");
            slen += 3;
            // Leading `c_void` word maps to `anyopaque` even when the
            // text CONTINUES past it (`*raw c_void) callconv(.c) i64`
            // fn-pointer params, `*raw c_void` as a suffix-bearing
            // annotation). The old exact-equality check only covered
            // the bare `*raw c_void` annotation, so fn-pointer text
            // leaked zig-foreign `c_void` into the emit.
            var rest = inner;
            if (std.mem.startsWith(u8, inner, "c_void")) {
                @memcpy(scratch[slen..][0..9], "anyopaque");
                slen += 9;
                rest = inner["c_void".len ..];
            }
            if (rest.len > 0 and rest.len <= scratch.len - slen) {
                @memcpy(scratch[slen..][0..rest.len], rest);
                slen += rest.len;
            }
            return scratch[0..slen];
        }
        if (std.mem.indexOf(u8, text, "?*raw ")) |idx| {
            const inner = text[idx + "?*raw ".len ..];
            var scratch: [256]u8 = undefined;
            var slen: usize = 0;
            @memcpy(scratch[slen..][0..idx], text[0..idx]);
            slen += idx;
            @memcpy(scratch[slen..][0..4], "?[*]");
            slen += 4;
            if (std.mem.eql(u8, inner, "c_void")) {
                @memcpy(scratch[slen..][0..9], "anyopaque");
                slen += 9;
            } else {
                @memcpy(scratch[slen..][0..inner.len], inner);
                slen += inner.len;
            }
            return scratch[0..slen];
        }
        if (std.mem.eql(u8, text, "c_void")) return "anyopaque";
        // General array-prefix recursion: strip the bracket+size
        // prefix (`[]`, `[3]`, `[N]`, `[15]`) and recurse on the
        // ELEMENT so every alias expands inside array wrappers of any
        // shape — `[4]str` → `[4][]const u8`, `[N]str` →
        // `[N][]const u8`, `[8]char` → `[8]u32`, `[2]f32x4` →
        // `[2]@Vector(4, f32)`, `[3]?str` → `[3]?[]const u8`.
        // Replaces the two literal `[]str` / `[3]str` entries
        // (byte-identical for those shapes — the CLI bootstrap's
        // spawn_leaf, exercised end-to-end by the e2e test importing
        // lib/cli.zag, keeps its emission). The parser captures the
        // full bracket text (size = int / float / identifier, e.g.
        // `[3]str` and `[15]?[:0]u8`), so the strip is
        // bracket-anchored, not size-literal-anchored. Composes with
        // the pointer recursion: `*[3]str` → `*[3][]const u8`,
        // `[3]*str` → `[3]*[]const u8`. The eql guard returns
        // non-alias elements (`[5]i32`, `[3]Json`, sentinel
        // `[*:0]const u8`) untouched, so the common
        // fixed-size-buffer types pay one cheap compare, not a
        // scratch rebuild.
        if (text.len > 1 and text[0] == '[') {
            const arr_close = std.mem.indexOfScalar(u8, text, ']');
            if (arr_close != null and arr_close.? >= 1) {
                const arr_elem = text[arr_close.? + 1 ..];
                if (arr_elem.len > 0) {
                    const arr_mapped = zagTypeToZig(arr_elem);
                    if (!std.mem.eql(u8, arr_mapped, arr_elem)) {
                        var arr_scratch: [264]u8 = undefined;
                        const arr_head_len = arr_close.? + 1;
                        if (arr_head_len + arr_mapped.len <= arr_scratch.len) {
                            @memcpy(arr_scratch[0..arr_head_len], text[0..arr_head_len]);
                            @memcpy(arr_scratch[arr_head_len..][0..arr_mapped.len], arr_mapped);
                            return arr_scratch[0 .. arr_head_len + arr_mapped.len];
                        }
                    }
                    return text;
                }
            }
        }
        // Optional-string form `?str` → `?[]const u8` — the get_env
        // contract (`get_env(name) -> ?str`) and user `let x: ?str`
        // bindings both emit this shape. Surfaced when the Tier-1
        // stdlib migration made lib/std/env.zag's `-> ?str` return
        // type compile through zig for the first time.
        if (std.mem.eql(u8, text, "?str")) return "?[]const u8";
        // General pointer-prefix recursion: strip the pointer marker
        // (plus optional `const` qualifier / `?` optional-pointer
        // marker) and recurse on the POINTEE so every alias expands
        // inside pointer wrappers of any shape — `*str` → `*[]const
        // u8`, `*?str` → `*?[]const u8`, `*char` → `*u32`, `*f32x4`
        // → `*@Vector(4, f32)`, `*c_void` → `*anyopaque`, `**str` →
        // `**[]const u8` (depth-limited: each level strips one
        // marker). Replaces the four literal `*str` entries — the
        // prefix round-trips verbatim and only the pointee walks the
        // alias table. When the pointee contains no alias (the
        // recursion returns it unchanged) the original `text` is
        // returned untouched, so the ubiquitous `*Json` /
        // `*ArrayList(...)` receiver types pay one cheap compare, not
        // a scratch rebuild. NOTE: collectCastType glues `?` onto the
        // preceding token, so source `*const ?str` is captured as
        // `*const?str` — the `*const?` prefix key matches the
        // PARSER's output, not the source whitespace. Runs AFTER the
        // `*raw ` / `?*raw ` handlers so the v1.5 raw-pointer surface
        // (`*raw T` → `[*]T`) wins.
        var ptr_prefix: []const u8 = "";
        var ptr_pointee: []const u8 = text;
        if (std.mem.startsWith(u8, text, "*const?")) {
            ptr_prefix = "*const?";
            ptr_pointee = text["*const?".len..];
        } else if (std.mem.startsWith(u8, text, "*const ")) {
            ptr_prefix = "*const ";
            ptr_pointee = text["*const ".len..];
        } else if (std.mem.startsWith(u8, text, "?*")) {
            ptr_prefix = "?*";
            ptr_pointee = text[2..];
        } else if (std.mem.startsWith(u8, text, "*") and text.len > 1) {
            ptr_prefix = "*";
            ptr_pointee = text[1..];
        }
        if (ptr_prefix.len > 0 and ptr_pointee.len > 0) {
            const mapped = zagTypeToZig(ptr_pointee);
            if (!std.mem.eql(u8, mapped, ptr_pointee)) {
                var pscratch: [264]u8 = undefined;
                if (ptr_prefix.len + mapped.len <= pscratch.len) {
                    @memcpy(pscratch[0..ptr_prefix.len], ptr_prefix);
                    @memcpy(pscratch[ptr_prefix.len..][0..mapped.len], mapped);
                    return pscratch[0 .. ptr_prefix.len + mapped.len];
                }
            }
            return text;
        }
        // v2 char fix path (docs/features.md §08 v2 4-byte Unicode char
        // row): zag's `char` ident silently rewrites to zig's `u32`
        // primitive so let-bind / var-bind / struct-field / enum-varlist /
        // impl-method-receiver / fun-param / fun-return surfaces emit a
        // type zig's 0.16 lexer accepts. Pin: codegen test (a) `char
        // type ident silently rewrites to u32` and the integration test
        // `let c: char = '\u2764' surfaces both gap (a) and gap (c)
        // lanes together` both-fixed form arm.
        if (std.mem.eql(u8, text, "char")) return "u32";
        // SIMD vector types (docs/manual/24-simd.md §"SIMD Vector
        // Types"): the `{elem}{width}x{lanes}` spelling maps onto
        // zig 0.16's `@Vector(N, T)` — zig has no f32x4-style type
        // names, so the alias table carries the full documented
        // surface (f32x4 → @Vector(4, f32), i8x16 → @Vector(16, i8),
        // ...). `bf16x8` maps to f16 (zig 0.16 has no bf16 type; f16
        // is the closest IEEE half-precision lane). The @Vector form
        // is emitted wherever a type text appears (annotations,
        // params, returns, casts, struct-literal heads), so literals
        // `f32x4 { ... }` become `@Vector(4, f32){ ... }` and
        // element-wise `+`/`-`/`*`/`/` lower to zig's native vector
        // ops with zero codegen changes.
        if (std.mem.eql(u8, text, "f32x4")) return "@Vector(4, f32)";
        if (std.mem.eql(u8, text, "f32x8")) return "@Vector(8, f32)";
        if (std.mem.eql(u8, text, "f64x2")) return "@Vector(2, f64)";
        if (std.mem.eql(u8, text, "f64x4")) return "@Vector(4, f64)";
        if (std.mem.eql(u8, text, "f16x8")) return "@Vector(8, f16)";
        if (std.mem.eql(u8, text, "bf16x8")) return "@Vector(8, f16)";
        if (std.mem.eql(u8, text, "i8x16")) return "@Vector(16, i8)";
        if (std.mem.eql(u8, text, "i16x8")) return "@Vector(8, i16)";
        if (std.mem.eql(u8, text, "i32x4")) return "@Vector(4, i32)";
        if (std.mem.eql(u8, text, "i64x2")) return "@Vector(2, i64)";
        if (std.mem.eql(u8, text, "u8x16")) return "@Vector(16, u8)";
        if (std.mem.eql(u8, text, "u16x8")) return "@Vector(8, u16)";
        if (std.mem.eql(u8, text, "u32x4")) return "@Vector(4, u32)";
        if (std.mem.eql(u8, text, "u64x2")) return "@Vector(2, u64)";
        if (std.mem.eql(u8, text, "i4x16")) return "@Vector(16, i4)";
        if (std.mem.eql(u8, text, "u4x16")) return "@Vector(16, u4)";
        if (std.mem.eql(u8, text, "i4x32")) return "@Vector(32, i4)";
        if (std.mem.eql(u8, text, "u4x32")) return "@Vector(32, u4)";
        if (std.mem.eql(u8, text, "i8x32")) return "@Vector(32, i8)";
        if (std.mem.eql(u8, text, "i8x64")) return "@Vector(64, i8)";
        if (std.mem.eql(u8, text, "u8x32")) return "@Vector(32, u8)";
        if (std.mem.eql(u8, text, "u8x64")) return "@Vector(64, u8)";
        if (std.mem.eql(u8, text, "i32x32")) return "@Vector(32, i32)";
        return text;
    }


    pub     fn boundToMethodName(b: []const u8) []const u8 {
        // Maps docs/16 §3 trait-bound names to the canonical method
        // name that a conforming zig type would expose. Pinned
        // mapping (from the user's review-confirmed spec):
        //   Clone          → clone()
        //   Default        → default()
        //   Zero           → is_zero()
        //   Ordered        → compare()  (used by sind, max, etc.)
        //   Display        → display()
        //   Iterator<T>    → next()  (v1 — the `<T>` form is ignored)
        //   AsyncStream<T> → poll_next()  (v1 — same carve-out)
        //
        // Returns `b` (the input) verbatim when no mapping exists,
        // which `genBoundsGuards` treats as "skip guard emit" so
        // unspecified bounds pass through silently until the trait
        // system wires in (Phase 3).
        if (std.mem.eql(u8, b, "Clone")) return "clone";
        if (std.mem.eql(u8, b, "Default")) return "default";
        if (std.mem.eql(u8, b, "Zero")) return "is_zero";
        if (std.mem.eql(u8, b, "Ordered")) return "compare";
        if (std.mem.eql(u8, b, "Display")) return "display";
        if (std.mem.eql(u8, b, "Iterator")) return "next";
        if (std.mem.eql(u8, b, "AsyncStream")) return "poll_next";
        return b;
    }

    pub     fn rewriteSelfToT(self: *Codegen, text: []const u8) void {
        // Docs/17 §"Self": `Self` refers to the implementing type.
        // In trait VTable function-pointer types and dispatch shims,
        // `Self` is rewritten to `anyopaque` — the vtable function
        // signatures use `*anyopaque` throughout so the dispatch
        // shim can forward any concrete type through the vtable
        // without a comptime type parameter.
        var scratch_buf: [256]u8 = undefined;
        var scratch_len: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const found = std.mem.indexOf(u8, text[i..], "Self");
            if (found == null) {
                const tail = text[i..];
                if (scratch_len + tail.len <= scratch_buf.len) {
                    @memcpy(scratch_buf[scratch_len..][0..tail.len], tail);
                    scratch_len += tail.len;
                }
                break;
            }
            const abs = i + found.?;
            const pre = text[i..abs];
            if (scratch_len + pre.len <= scratch_buf.len) {
                @memcpy(scratch_buf[scratch_len..][0..pre.len], pre);
                scratch_len += pre.len;
            }
            const replacement = "anyopaque";
            if (scratch_len + replacement.len <= scratch_buf.len) {
                @memcpy(scratch_buf[scratch_len..][0..replacement.len], replacement);
                scratch_len += replacement.len;
            }
            i = abs + "Self".len;
        }
        self.writeType(scratch_buf[0..scratch_len]);
    }

    pub     fn genTraitDecl(self: *Codegen, td: ast.TraitDecl) void {
        // Doc (docs/02 §"Doc Comments"): emit `/// ` lines BEFORE the
        // `pub const NAME = struct { ... }` emit (mirrors genStructDecl
        // and genFun; struct vs trait both surface as named zig
        // containers).
        if (td.doc) |d| self.genDocComment(d);
        // Docs/17 §"Definition": `trait NAME { fun draw(self: *Self); ... }`
        // compiles to a zig fat-pointer container holding (data ptr,
        // vtable ptr), an inner VTable struct of function pointers keyed
        // by method name, and a per-method dispatch shim:
        //
        //   pub const NAME = struct {
        //       pub const VTable = struct {
        //           m1: *const fn (ptr: *anyopaque, ...) RET1,
        //           m2: *const fn (ptr: *anyopaque, ...) RET2,
        //       };
        //       ptr: *anyopaque,
        //       vtable: *const VTable,
        //       pub fn m1(self: NAME) RET1 {
        //           return self.vtable.m1(self.ptr);
        //       }
        //       ...
        //   };
        //
        // Vtable dispatch is purely runtime — the function pointer
        // is looked up via `self.vtable` and the data pointer is
        // `self.ptr` (`*anyopaque`). No comptime type parameter is
        // needed; the concrete type is determined at cast time (when
        // `btn as Drawable` constructs the fat pointer).
        //
        // The receiver parameter (`self: *Self`) is always the FIRST
        // param in a trait method signature per the docs/17 §"Definition"
        // grammar. The dispatch path omits this slot because the receiver
        // collapses to `self.ptr` (an `*anyopaque`) at the vtable signature
        // and to `self: NAME` (the trait container type) at the dispatch
        // shim signature. Subsequent params (additional user-declared args)
        // round-trip through `rewriteSelfToT` so any `*Self`-typed arg
        // converts to `*anyopaque` — the vtable function-pointer type
        // uses `*anyopaque` for all Self-derived parameters.
        self.write("pub const ");
        self.write(td.name);
        self.write(" = struct {\n");
        self.write("    pub const VTable = struct {\n");
        for (td.methods, 0..) |m, mi| {
            // VTable field name: suffixed for overloaded methods.
            var sfn_buf: [128]u8 = undefined;
            const vtable_name = blk: {
                var dup_idx: usize = 0;
                var total: usize = 0;
                for (td.methods) |tm| {
                    if (std.mem.eql(u8, tm.name, m.name)) {
                        if (total < mi) dup_idx += 1;
                        total += 1;
                    }
                }
                if (total <= 1) break :blk m.name;
                @memcpy(sfn_buf[0..m.name.len], m.name);
                const sfx = std.fmt.bufPrint(sfn_buf[m.name.len + 1 .. sfn_buf.len], "{d}", .{dup_idx}) catch "0";
                sfn_buf[m.name.len] = '_';
                break :blk sfn_buf[0 .. m.name.len + 1 + sfx.len];
            };
            self.write("        ");
            self.write(vtable_name);
            self.write(": *const fn (ptr: *anyopaque");
            // Additional params (skip the always-first `self` receiver).
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
                self.write(": ");
                self.rewriteSelfToT(p.type_text);
            }
            self.write(") ");
            if (m.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
            self.write(",\n");
        }
        self.write("    };\n");
        // Fat-pointer container fields (data ptr + vtable ptr).
        self.write("    ptr: *anyopaque,\n");
        self.write("    vtable: *const VTable,\n");
        // Per-method dispatch shim. Each shim is a thin wrapper that
        // forwards to the trait-defined vtable slot; the extra comptime
        // the dispatch shim uses the correct vtable field.
        for (td.methods, 0..) |m, mi| {
            var sfn_buf: [128]u8 = undefined;
            const vtable_name = blk: {
                var dup_idx: usize = 0;
                var total: usize = 0;
                for (td.methods) |tm| {
                    if (std.mem.eql(u8, tm.name, m.name)) {
                        if (total < mi) dup_idx += 1;
                        total += 1;
                    }
                }
                if (total <= 1) break :blk m.name;
                @memcpy(sfn_buf[0..m.name.len], m.name);
                const sfx = std.fmt.bufPrint(sfn_buf[m.name.len + 1 .. sfn_buf.len], "{d}", .{dup_idx}) catch "0";
                sfn_buf[m.name.len] = '_';
                break :blk sfn_buf[0 .. m.name.len + 1 + sfx.len];
            };
            self.write("    pub fn ");
            // Overload-suffixed shim name (`render_0` / `render_1`):
            // zig has no overloading, so the SECOND same-name shim
            // would collide ("duplicate struct member name 'render'").
            // The call-site dispatch (traitOverloadSuffix in expr.zig)
            // appends the same `_N` by arity, so `r.render()` →
            // `r.render_0()` and `r.render(2.0)` → `r.render_1()`.
            self.write(vtable_name);
            self.write("(self: ");
            self.write(td.name);
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
                self.write(": ");
                self.rewriteSelfToT(p.type_text);
            }
            self.write(") ");
            if (m.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
            self.write(" {\n");
            self.write("        return self.vtable.");
            self.write(vtable_name);
            self.write("(self.ptr");
            for (m.params[1..]) |p| {
                self.write(", ");
                self.write(p.name);
            }
            self.write(");\n");
            self.write("    }\n");
        }
        self.write("};\n\n");
    }

    /// Strip a trailing `_N` overload suffix (`render_1` → `render`)
    /// so genTraitRegistration's slot matching compares the BARE
    /// method name against the trait decl's (unsuffixed) method list.
    /// Registration buckets store suffixed names for overloaded
    /// traits (traitMethodVtableName), while all_trait_methods carries
    /// the decl's spelling. Non-suffixed names pass through unchanged.
    fn baseMethodName(name: []const u8) []const u8 {
        // Fast path: no trailing digit → no suffix.
        if (name.len == 0 or !std.ascii.isDigit(name[name.len - 1])) return name;
        var end: usize = name.len;
        while (end > 0 and std.ascii.isDigit(name[end - 1])) end -= 1;
        if (end == 0 or end + 1 > name.len or name[end - 1] != '_') return name;
        return name[0 .. end - 1];
    }

    pub     fn genTraitRegistration(self: *Codegen, trait_name: []const u8, target_type: []const u8, methods: []const ast.MethodDecl, method_field_names: []const []const u8, default_methods: []const []const u8, default_field_names: []const []const u8, all_trait_methods: []const ast.TraitMethodDecl) void {
        // Docs/17 §"Implementing" — emit a per-(trait, target_type)
        // vtable instantiation so a future `x.draw()` call site (Phase 3
        // — fat-pointer cast encoding) dispatches through THIS
        // registration. The shape:
        //
        //   pub const Trait_VTable_for_Type: Trait.VTable = .{
        //       .method = @ptrCast(&Type_Trait_method),
        //       ...
        //   };
        //
        // The `@ptrCast` 1-arg form lets zig type-infer the destination
        // function-pointer type from the VTable field declaration
        // (`*const fn (ptr: *anyopaque, ...) RET` in `genTraitDecl`).
        // zig 0.16 dropped explicit destination-type args for `@ptrCast`
        // — the destination is taken from the struct-literal field's
        // declared type. Source and destination are both function-
        // pointer types with identical calling convention, so the cast
        // is a "raw rebrand" from the impl-side receiver-type
        // (`*Type`) to the dispatch-side (`*anyopaque`). The free-fn
        // implementation's exact-name reference is preserved so the
        // vtable slot maps 1:1 to the renamed `<Target>_<Trait>_<Method>`
        // orphan-impl emit above.
        // Emit unfulfilled-slot stub fns BEFORE the registration
        // literal: zig accepts free fns interleaved with decls, but
        // the literal body itself must contain only `.field = value`
        // assignments - a stray fn inside `.{ ... }` is a parse error
        // ("expected field initializer").
        {
            var mi0: usize = 0;
            stub_loop: while (mi0 < all_trait_methods.len) : (mi0 += 1) {
                const tm = all_trait_methods[mi0];
                for (methods) |im| {
                    // Overload-suffix compare: registration buckets
                    // store the SUFFIXED name (`render_1`) for
                    // overloaded trait methods, while the trait decl
                    // list carries the bare name (`render`). Compare
                    // the base (suffix-stripped) names + arity so an
                    // implemented overload never gets a stub.
                    if (im.params.len == tm.params.len and
                        std.mem.eql(u8, baseMethodName(im.name), tm.name)) continue :stub_loop;
                }
                for (default_methods, default_field_names) |_, dfn| {
                    if (std.mem.eql(u8, dfn, tm.name)) continue :stub_loop;
                }
                const vfn = self.traitMethodVtableNameFull(all_trait_methods, mi0);
                // Stub fn with the EXACT vtable-field signature so the
                // @ptrCast rebrand needs no coercion. @panic is
                // noreturn, so a value-returning slot needs no dummy
                // result expression.
                self.write("fn __zag_unimpl_");
                self.write(trait_name);
                self.write("_");
                self.write(vfn);
                self.write("_");
                self.write(target_type);
                self.write("(ptr: *anyopaque");
                for (tm.params[1..]) |p| {
                    self.write(", ");
                    self.write(p.name);
                    self.write(": ");
                    self.rewriteSelfToT(p.type_text);
                }
                self.write(") ");
                if (tm.return_type) |rt| self.rewriteSelfToT(rt) else self.write("void");
                self.write(" {\n");
                self.write("    _ = ptr;\n");
                // Discard the trait method's remaining params: zig
                // rejects unused fn params, and a panic stub never
                // touches them (`render_1(self, scale)` would fail
                // with "unused function parameter" before it could
                // even compile the @panic).
                for (tm.params[1..]) |p| {
                    self.write("    _ = ");
                    self.write(p.name);
                    self.write(";\n");
                }
                self.write("    @panic(\"");
                self.write(trait_name);
                self.write(".");
                self.write(tm.name);
                self.write(" is not implemented for ");
                self.write(target_type);
                self.write(" - the `impl ");
                self.write(target_type);
                self.write(" with ");
                self.write(trait_name);
                self.write("` block leaves this trait slot unfulfilled. Add a body (dot-qualified or plain) for the method.\\n\");\n");
                self.write("}\n\n");
            }
        }
        self.write("pub const ");
        self.write(trait_name);
        self.write("_VTable_for_");
        self.write(target_type);
        self.write(": ");
        self.write(trait_name);
        self.write(".VTable = .{\n");
        for (methods, method_field_names) |m, fn_| {
            self.write("    .");
            self.write(fn_);
            self.write(" = @ptrCast(&");
            self.write(target_type);
            self.write("_");
            self.write(trait_name);
            self.write("_");
            self.write(m.name);
            self.write("),\n");
        }
        for (default_methods, default_field_names) |_, dfn| {
            self.write("    .");
            self.write(dfn);
            self.write(" = @ptrCast(&");
            self.write(trait_name);
            self.write("__");
            self.write(dfn);
            self.write("),\n");
        }
        // Unfulfilled slots (docs/manual/18 SS "Dot-qualified methods":
        // a lopsided diamond leaves Show.print without a body). The
        // stub fns were emitted above (BEFORE the literal); here we
        // only bind the missing slots to them so the partial impl
        // still compiles - the doc's contract: only CALLING the
        // unfulfilled slot panics.
        {
            var mi: usize = 0;
            slot_loop2: while (mi < all_trait_methods.len) : (mi += 1) {
                const tm2 = all_trait_methods[mi];
                for (methods) |im| {
                    // Same overload-suffix compare as the stub emit
                    // above: `render_1` in the bucket matches the
                    // decl's bare `render` when arity agrees.
                    if (im.params.len == tm2.params.len and
                        std.mem.eql(u8, baseMethodName(im.name), tm2.name)) continue :slot_loop2;
                }
                for (default_methods, default_field_names) |_, dfn| {
                    if (std.mem.eql(u8, dfn, tm2.name)) continue :slot_loop2;
                }
                const vfn2 = self.traitMethodVtableNameFull(all_trait_methods, mi);
                self.write("    .");
                self.write(vfn2);
                self.write(" = @ptrCast(&__zag_unimpl_");
                self.write(trait_name);
                self.write("_");
                self.write(vfn2);
                self.write("_");
                self.write(target_type);
                self.write("),\n");
            }
        }
        self.write("};\n\n");
    }

    pub     fn genEnumDecl(self: *Codegen, ed: ast.EnumDecl, all_impls: []const ast.ImplBlock) void {
        // 3-way emit shape (v2 split landing — docs/13 §"Choosing
        // Between enum and union" + §"Backed Enums"):
        //   1. `ed.backing_type != null` → `enum(T) { V = value, ... }`
        //      (backed enum; requires strict-split at parser level so
        //      variants are bare-with-value, never payload-bearing).
        //   2. `ed.backing_type == null` AND any variant has a payload
        //      (paren-positional OR brace-named-field) → `union(enum)
        //      { Variant: T | struct { ... }, ... }`.
        //   3. `ed.backing_type == null` AND no variants carry a
        //      payload → bare `enum { V1, V2, ... }`.
        var any_payload = false;
        for (ed.variants) |v| {
            if (v.payload_type != null or v.fields.len > 0) {
                any_payload = true;
                break;
            }
        }
        // Gap #3 binary: bare-vs-payload. The codegen's nested-method
        // loop (below) only fires on the BARE path because zig 0.16
        // rejects methods nested inside `union(enum) { ... }` and
        // `enum(T) { ... }` containers. The orphan-impl routing in
        // generate() does NOT re-emit methods for matched targets, so
        // skipping the nest on non-bare enums requires ALSO updating
        // matched_targets_buf push logic in generate() to leave payload-
        // bearing enum names OUT. Both layers must stay in lockstep.
        const ed_is_bare = ed.backing_type == null and !any_payload;
        // Doc (docs/02 §"Doc Comments"): emit `///` lines BEFORE the
        // `pub const NAME = ...` emit (mirrors genStructDecl/genFun).
        if (ed.doc) |d| self.genDocComment(d);
        self.write("pub const ");
        self.write(ed.name);
        self.write(" = ");
        // Branches are mutually exclusive: backed-enum has no
        // payload shape (parser-enforced); union/union(enum) has no
        // backing type (parser-enforced via the strict-split
        // parseEnumDecl rejecting payloads — parseUnionDecl explicitly
        // does not capture backing_type). The any_payload /
        // ed_is_bare computation lives at the TOP of the function
        // (above the doc emit) so both the union-emit branch AND the
        // nested-method loop gate consult the same values downstream.
        if (ed.backing_type) |bt| {
            // Backed-enum emit shape: `enum(T) { V = value, ... }`.
            // No variant payload (parser-enforced). Each variant MAY
            // carry a per-variant value via `v.value_text`; codegen
            // emits `= value` only when non-null so auto-infer (zig's
            // default incrementing) is preserved when the user omits
            // the value text. The backing-type text goes through
            // zagTypeToZig so `str` → `[]const u8` while primitives
            // (`u8`, `i32`) round-trip verbatim.
            // Backing-type rewrite through `zagTypeToZig` (gap #4
            // resolution): a previous carve-out preserved the user's
            // literal `char` here under the assumption that
            // "byte-stream semantics" would be lost via the
            // `char → u32` rewrite, but zig 0.16 rejects an `enum(char)`
            // emit entirely (`undefined identifier 'char'`) — there
            // is no byte-stream form to preserve. The uniform
            // `zagTypeToZig` rewrite is the canonical solution:
            // `char` becomes `u32`, primitives (`u8`, `i32`, `bool`)
            // round-trip verbatim. The str-backed form is split out
            // below — see the `[]const u8` arm. Crucially, the
            // `enum(` opener lives INSIDE the int branch (below)
            // because the str branch emits a struct shape and the
            // `enum(` prefix would produce `enum(struct { ... }`
            // which zig rejects (caught by an earlier turn's
            // debug: `error: expected ')', found ';'` at line 52).
            const bt_rewrite = zagTypeToZig(bt);
            if (std.mem.eql(u8, bt_rewrite, "[]const u8")) {
                // Str-backed shape: zig rejects `enum([]const u8)`
                // because enum tag types must be integers (`expected
                // integer tag type, found '[]const u8'`). Emit a
                // struct-with-const-fields instead — each variant
                // becomes `pub const Name = value;` so `Level.High`
                // references a `*const [N:0]u8` constant that
                // coerces to `[]const u8` (zig's standard str-literal
                // → slice coercion). Value-equality holds because
                // const fields of identical string literals are the
                // SAME canonical literal in the zig binary, and the
                // array-`==` semantics on `[N:0]u8` does element-
                // wise compare when comparing two distinct literals.
                //
                // The matching genBinding wrap path (codegen/stmt.zig)
                // skips wrapping for str-backed variants because the
                // variant IS already `[]const u8` — `let lvl: str =
                // Level.High` round-trips to `let lvl: []const u8 =
                // Level.High;` without any `@tagName` indirection.
                //
                // The closing `};\n\n` is emitted by the outer
                // `};\n\n` write after the if-else chain, so this
                // branch only writes the body. Empty-value fallback
                // (`""`) covers the edge case of a str-backed enum
                // variant without an explicit `= expr` clause —
                // zig requires const-field initializers so a missing
                // value is coerced to the empty-string literal.
                self.write("struct {\n");
                for (ed.variants) |v| {
                    self.write("    pub const ");
                    self.write(v.name);
                    self.write(" = ");
                    if (v.value_text) |vt| {
                        self.write(vt);
                    } else {
                        self.write("\"\"");
                    }
                    self.write(";\n");
                }
            } else {
                // Int / char / bool backing: emit the canonical zig
                // `enum(T) { V = value, ... }` shape. Each variant
                // MAY carry a per-variant value via `v.value_text`;
                // codegen emits `= value` only when non-null so
                // auto-infer (zig's default incrementing) is preserved
                // when the user omits the value text.
                self.write("enum(");
                self.write(bt_rewrite);
                self.write(") {\n");
                for (ed.variants) |v| {
                    self.write("    ");
                    self.write(v.name);
                    if (v.value_text) |vt| {
                        self.write(" = ");
                        self.write(vt);
                    }
                    self.write(",\n");
                }
            }
        } else if (any_payload) {
            // union(enum) emit shape: any variant with non-null
            // payload_type OR non-empty fields triggers the tagged-
            // union form. All variants in a single declaration share
            // the same emission shape — mixing plain variants with
            // payload variants in the same zig container is rejected by
            // zig 0.16 (the `union(enum) { ... }` requires every
            // variant to specify its payload slot OR be its own bare
            // bare-zero-byte tag, which our emit handles by skipping
            // the `: TYPE` tail for payload-less variants).
            self.write("union(enum) {\n");
            for (ed.variants) |v| {
                self.write("    ");
                self.write(v.name);
                if (v.fields.len > 0) {
                    // Brace-named-field payload
                    // (`Drag { x: f64, y: f64 }`): emit
                    // `struct { x: f64, y: f64 }` with the ACTUAL
                    // field names preserved (vs. the legacy single-
                    // letter a/b/c/... scheme used for paren-
                    // positional). The matching constructor emit
                    // (`.enum_variant_ctor` arm) future-work: extend
                    // to use named-struct literal init `.{ .x = x, .y
                    // = y }` instead of the legacy positional
                    // `.{ arg1, arg2 }`. v1's positional ctor still
                    // works because the auto-generated field names
                    // (x, y) align with declaration order, but the
                    // ctor surface for brace-named variants is
                    // deferred until v2.1 lands named-struct-literal
                    // codegen. match-side destructuring
                    // (`Drag { x: w, y: h } => ...`) is similarly
                    // deferred per docs/14 §FFI callout.
                    //
                    // Gap #2 side-table push (emit-side): record
                    // (enum_name, variant_name → fields) so the
                    // `.enum_variant_ctor` arm in genExpr can
                    // recover the user's actual field names at
                    // runtime ctor sites. Without this entry the
                    // ctor arm falls back to the letter-based
                    // alphabetical emit, which zig rejects because
                    // the named-field struct has the user's names
                    // (e.g. `x, y`), NOT `a, b`. The push is
                    // unconditional here so ANY brace-named-field
                    // variant populates the table; branches that
                    // aren't ctor sites don't care about it.
                    if (self.variant_fields_count < self.variant_fields_buf.len) {
                        self.variant_fields_buf[self.variant_fields_count] = .{
                            .enum_name = ed.name,
                            .variant_name = v.name,
                            .fields = v.fields,
                        };
                        self.variant_fields_count += 1;
                    }
                    self.write(": struct { ");
                    for (v.fields, 0..) |f, fi| {
                        if (fi > 0) self.write(", ");
                        self.write(f.name);
                        self.write(": ");
                        self.writeType(f.type_text);
                    }
                    self.write(" }");
                } else if (v.payload_type) |pt| {
                    // zig 0.16 rejects bare `Rect: f64, f64` (parsed
                    // as TWO variants, not one with a tuple type).
                    // Multi-arg payloads MUST be wrapped in an
                    // anonymous struct so zig's tagged-union parser
                    // sees one variant with a struct-typed payload.
                    // Single-arg payloads stay bare (`Circle: f64`
                    // is a valid union(enum) variant type).
                    //
                    // Detection: count commas in `pt`. Zero commas
                    // → single arg, emit verbatim. ≥1 comma → multi-
                    // arg, emit `struct { a: T0, b: T1, ... }` with
                    // sequential single-letter field names (a, b, c,
                    // …). The matching constructor emit
                    // (`.enum_variant_ctor` arm) uses positional init
                    // `.{ x, y }` which zig forwards to the struct's
                    // named fields in declaration order, so the emit-
                    // side letter sequence must align with the parse
                    // order of the source's comma-list.
                    var comma_count: usize = 0;
                    for (pt) |c| if (c == ',') {
                        comma_count += 1;
                    };
                    if (comma_count == 0) {
                        self.write(": ");
                        self.writeType(pt);
                    } else {
                        self.write(": struct { ");
                        const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
                        var seg_start: usize = 0;
                        var idx: usize = 0;
                        var i: usize = 0;
                        while (i <= pt.len) : (i += 1) {
                            if (i == pt.len or pt[i] == ',') {
                                // Trim leading/trailing whitespace
                                // from the captured type-text segment
                                // so `f64, f64` doesn't emit
                                // `: a: f64, b:  f64`.
                                var a: usize = seg_start;
                                var b: usize = i;
                                while (a < b and (pt[a] == ' ' or pt[a] == '\t')) a += 1;
                                while (b > a and (pt[b - 1] == ' ' or pt[b - 1] == '\t')) b -= 1;
                                if (idx > 0) self.write(", ");
                                self.write(letters[idx]);
                                self.write(": ");
                                self.writeType(pt[a..b]);
                                idx += 1;
                                seg_start = i + 1;
                            }
                        }
                        self.write(" }");
                    }
                }
                self.write(",\n");
            }
        } else {
            // Bare-enum emit shape: `enum { V1, V2, ... }`. No
            // variants carry payloads or fields.
            self.write("enum {\n");
            for (ed.variants) |v| {
                self.write("    ");
                self.write(v.name);
                self.write(",\n");
            }
        }
        // Nest matching impl methods inside the BARE-ENUM body only.
        // zig 0.16 rejects methods nested inside `union(enum) { ... }`
        // (gap #3 fix) AND inside `enum(T) { ... }` containers; only
        // the bare `enum { V1, V2, ... }` form accepts nested pub fns.
        // Payload-bearing enums + backed enums route their impl methods
        // through `generate()`'s orphan-impl loop (via
        // `genFreeMethod` at module scope) — see the matched_targets_buf
        // gate update in src/codegen/core.zig that excludes non-bare
        // enum names so the orphan path picks them up. The bare-enum
        // path retains the legacy nested-method emit (existing tests
        // for `impl Direction { ... }` etc. pin this surface).
        // TRAIT-method methods are SKIPPED here (same reason as
        // genStructDecl): they emit as renamed free fns (Target_Trait_
        // method) + vtable registration during the trait-handling
        // pass, NEVER nested inside the enum body.
        if (ed_is_bare) {
            for (all_impls) |impl| {
                if (!std.mem.eql(u8, impl.target_type, ed.name)) continue;
                for (impl.methods) |m| {
                    // Canonical `with Trait (m)` dispatch (docs/17
                    // §"Diamond Disambiguation") — same logic as
                    // genStructDecl: trait-bound methods skip nested
                    // emit so the trait-handling pass in `generate`
                    // emits the renamed free fn + vtable registration.
                    if (self.resolveTraitBinding(&impl, m) != null) continue;
                    // v1.6 byte-slice widening: set receiver-struct
                    // before emitting the nested method body so
                    // `print(self.byte_slice_field)` widens correctly.
                    // Mirror of genStructDecl's setting.
                    self.current_receiver_struct_name = impl.target_type;
                    // Phase 2 tail: thread impl-level type_params so
                    // the nested-on-enum method emits `comptime X:
                    // type` BEFORE its own params. Same path as
                    // genStructDecl.
                    self.genMethod(m, impl.type_params);
                    self.current_receiver_struct_name = null;
                }
            }
        }
        self.write("};\n\n");
    }

    pub     fn genFun(self: *Codegen, fun: ast.FunDecl) void {
        if (fun.is_test) {
            self.genTestFun(fun);
            return;
        }
        // Comptime-body fn (`fun NAME(...) = <expr>;`): emit a zig
        // `pub const NAME = <expr>;` — no runtime fn surface. The
        // comptime body text is re-lexed/parsed into an expression
        // AST (the parser captured it verbatim; see parseFunDecl's
        // comptime-body branch) and emitted through the ordinary
        // genExpr path so nested casts/calls ride the same lowering
        // as runtime code. Params/type_params of a comptime fn are
        // carried on the zig side by the EXPRESSION itself (comptime
        // zig params are spelled inside the expression — zag just
        // passes the text through). Self-hosting batch: lets pure-.zag
        // stdlib helpers (format_any's type-keyed dispatch) spell
        // comptime tables without a zig file-side shim.
        if (fun.is_comptime_body) {
            self.write("pub const ");
            self.write(fun.name);
            self.write(" = ");
            var clex = lexer.Lexer.init(fun.comptime_body_text);
            const ctoks = clex.tokenize();
            var carena = ast.Arena.init();
            var cp = parser_mod.Parser.init(ctoks, &carena);
            const cexpr = cp.parseExpr();
            self.genExpr(cexpr);
            self.write(";\n");
            return;
        }
        // Reset destructuring counter at the top of each function so the
        // temp bindings inside this body stay local (avoiding clashes
        // across sibling `pub fn` declarations) and count from `_0`.
        self.destructure_counter = 0;
        // Reset type-info map at the top of each function so sibling
        // `pub fn` declarations don't bleed entries across functions.
        // Walk the body once to populate the map before any emission
        // happens — the predicates need to see this map when each
        // binary/literal expression hits the `.binary` arm.
        self.type_info_count = 0;
        // v1.6 byte-slice widening: top-level `pub fun` declarations
        // have no method receiver. Reset to null so any stale value
        // from a previous impl-block method body doesn't carry over
        // into a regular fn body (which would over-widen to `{s}` on
        // first print, e.g. a `print(self.foo)` written inside `fun
        // main` would resolve against the most-recent impl's
        // receiver even though there's no `self` in main).
        self.current_receiver_struct_name = null;
        self.current_symbol = fun.name;
        // Reset the `new`-temp counter at the top of each function so
        // sibling `pub fn` declarations don't reuse the same `__p_<N>`
        // names (zig's redeclaration-error would reject a collision).
        self.alloc_counter = 0;
        // Per-function match scrutinee counter for the laddered match
        // codegen path (see `genMatchExpr`). Two match expressions in
        // the same body produce distinct `__m_<N>` names so zig's
        // no-redeclaration rule is satisfied; sibling `pub fn`s reset
        // their own counters to start fresh at `_0`.
        self.match_counter = 0;
        self.blk_counter = 0;
        // Top-level `fun` is parsed for return_type in Phase 2, but
        // `fn_returns_value` is only relevant for impl-block methods
        // where the typed-return drives tail-position match emission.
        // Top-level funs conservatively keep the legacy
        // value-discarding match emission — the body can still use
        // explicit `return expr;` to yield a value, which zig's type
        // checker validates against the emitted `RET_TYPE` signature.
        self.fn_returns_value = false;
        if (fun.return_type) |rt| self.setFnRetType(rt) else self.fn_ret_type_len = 0;
        // async fun (docs/manual/18 §"Async Trait Methods"): the
        // return_stmt arm wraps `return EXPR;` into
        // `return .{ .done = true, .value = EXPR };` for the emitted
        // Future(T). Reset per body (see the fn_is_async field doc).
        self.fn_is_async = fun.is_async;
        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry. The
        // fresh local `<name>` is mutable (allowing body mutations like
        // `x += 1`), and the parameter carrying the caller's value
        // passes through zig's pass-by-value default — caller isolation
        // is preserved. The body still references `<name>` verbatim; the
        // local shadows nothing because the parameter has a different
        for (fun.body) |stmt| {
            self.collectTypedBindings(stmt);
        }
        // v1.7 param-type seeding: `print("hello, {name}")` on a
        // function PARAMETER (e.g. `fun greet(name: str)`) previously
        // widened to `{any}` — type_info_buf only recorded typed
        // BINDINGS, so the template-literal/print `{s}` widening
        // (typeAwareFmtSpec in primary.zig) missed params and printed
        // byte lists. Seed each param's `: T` annotation into the
        // buffer (skip names a binding already recorded — shadowing
        // bindings win). Mirrors the free-fn/method side in
        // genFreeMethod/genMethod when those receivers matter.
        for (fun.params) |p| {
            if (self.type_info_count >= self.type_info_buf.len) break;
            var already = false;
            for (self.type_info_buf[0..self.type_info_count]) |ti| {
                if (std.mem.eql(u8, ti.name, p.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            self.type_info_buf[self.type_info_count] = .{
                .name = p.name,
                .type_name = p.type_text,
                .is_closure = false,
            };
            self.type_info_count += 1;
        }
        if (fun.doc) |d| self.genDocComment(d);
        // Phase 2 (docs/15 §"Declaration"): emit the FULL signature
        // from `fun.params`. Pre-Phase-2 the body unconditionally
        // emitted `pub fn NAME() !void {` regardless of source-side
        // params or return type; that's why the docs example
        // `fun add(a, b) -> i32 { return a + b; }` previously didn't
        // compile-able (zig rejected the call sites that omitted the
        // two args). Now args and return type both round-trip
        // verbatim. Default `ret = "void"` when `fun.return_type` is
        // null so the legacy form (`fun NAME() {}`) keeps emitting
        // the no-return surface.
        self.write("pub fn ");
        self.write(fun.name);
        // zig 0.16 main-signature migration: when the source-side
        // function is named `main`, the generated zig must use the
        // new `pub fn main(init: std.process.Init) !void` signature
        // (the old `pub fn main() void` form is no longer accepted
        // as an OS entry point in zig 0.16). The `init` parameter
        // is where the event-loop handle (`init.io`) is captured
        // into the module-level `__zag_io` global for the fs/process
        // dispatches. argv is NOT captured here anymore: the v0.5
        // self-hosting migration moved it to lib/std/posix.zag's
        // argv() — a pure-zag /proc/self/cmdline reader needing no
        // main-entry capture. The `!void` return type stays forced
        // (rather than inferred from the body) to keep main's
        // signature stable for the io-capture statement above.
        const is_main = std.mem.eql(u8, fun.name, "main");
        self.write("(");
        if (is_main) self.write("init: std.process.Init");
        // Generics (docs/16 §1, §4): emit `comptime X: type` or
        // `comptime X: TYPE` for each TypeParam BEFORE the regular
        // params. Zig's comptime-arg convention places compile-time
        // values at the start of the signature, so the preprint goes
        // here rather than at the end. Returns true if any
        // preamble was emitted so the regex check below inserts a
        // `, ` separator between the last type-param and the first
        // regular param.
        const generics_preamble = self.genTypeParamsPreamble(fun.type_params);
        for (fun.params, 0..) |p, i| {
            if (i > 0 or generics_preamble or is_main) self.write(", ");
            // Phase 2 var-p name-isolation (zig 0.16 fix): when
            // `is_var` is set, rename the parameter to
            // `__zag_local_<name>` so the body's
            // `var <name> = __zag_local_<name>;` introduces a fresh
            // local rather than shadowing the parameter. zig 0.16
            // rejects any local variable that shares a name with a
            // function parameter.
            if (p.is_var) self.write("__zag_local_");
            self.write(p.name);
            self.write(": ");
            self.writeType(p.type_text);
        }
        self.write(") ");
        // zig 0.16 main-signature migration: wrap the return
        // type in `!` (error union) so the `try` on
        // `init.minimal.args.toSlice(...)` can propagate
        // `OutOfMemory`. Preserves the user's annotated return
        // type (e.g., `fun main() -> i32` → `!i32`) rather than
        // hardcoding `!void`, so a user who writes a fallible
        // main with a non-void return type doesn't lose the
        // return-value contract. The `if (fun.return_type) |rt|
        // ... else "void"` pattern matches the legacy
        // non-main branch below; we just prefix `!` to the
        // resolved type.
        // zig 0.16 main-signature migration: wrap the return
        // type in `!` (error union) so the `try` on
        // `init.minimal.args.toSlice(...)` can propagate
        // `OutOfMemory`. Preserves the user's annotated return
        // type (e.g., `fun main() -> i32` → `!i32`) rather than
        // hardcoding `!void`, so a user who writes a fallible
        // main with a non-void return type doesn't lose the
        // return-value contract. The double-wrap guard checks
        // whether the user's return type already starts with `!`
        // (i.e., is already an error union) and skips the prefix
        // in that case — otherwise we'd emit `!!i32` which zig
        // rejects. The `if (fun.return_type) |rt| ... else "void"`
        // pattern matches the legacy non-main branch below; we
        // just prefix `!` to the resolved type when not already
        // error-union.
        if (is_main) {
            const already_err_union = if (fun.return_type) |rt| rt.len > 0 and rt[0] == '!' else false;
            if (!already_err_union) self.write("!");
            if (fun.return_type) |rt| self.writeType(rt) else self.write("void");
        } else if (fun.is_async) {
            // async fun: the emitted return type is `Future(T)`
            // wrapping the declared `-> T` (void when omitted) — the
            // docs/manual/18 §"Async Trait Methods" rewrite contract.
            // `await` sites in the body drive the future and unwrap.
            self.write("Future(");
            if (fun.return_type) |rt| self.writeType(rt) else self.write("void");
            self.write(")");
        } else if (fun.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(" {\n");
        // Trait-bounds guards (docs/16 §3): emit
        // `if (!@hasDecl(T, "method")) @compileError(...)` BEFORE
        // the var-params injection so unresolved bounds surface as a
        // zag compile-error at the user's source-line rather than a
        // sig validation panic downstream.
        self.genBoundsGuards(fun.type_params);
        // Phase 2 (docs/15 §"Parameters"): inject `var p = p;` at body
        // entry for each `is_var = true` param so mutations to `p`
        // don't reach the caller's binding (zag's "mutable local copy"
        // semantic). zig 0.16 makes parameters `const` so the body
        // can't rebind a param directly through `p = ...`; this
        // shadow-rebind is the simplest path that honors the
        // "var copies the value to a stack-local mutable" contract.
        // The Phase 2 `var p = p;` shadow-rebind was a workaround
        // for mutable-param emulation that zig 0.16 rejects as
        // `local variable 'p' shadows function parameter`. zig's
        // own pass-by-value defaults satisfy zag's caller-isolated-
        // mutation semantic. The `is_var` slot on `ast.MethodParam`
        // is no longer consulted here at codegen time but remains
        // on the AST for documentation / future-tooling use.
        // (No-op loop: removed to avoid zig 0.16's
        // `pointless discard of capture` warning on a
        // `if (p.is_var) { _ = p; }` marker.)
        // zig 0.16 main-signature migration: capture the event-loop
        // handle at main entry. (The argv capture that shared this
        // block retired in the v0.5 self-hosting migration —
        // lib/std/posix.zag's argv() reads /proc/self/cmdline, no
        // main-entry state involved.) Emitted ONLY for the main
        // function; other functions don't have `init` in scope.
        if (is_main) {
                // zig 0.16: capture the Io event-loop handle from init
                // so the .fs_write_file / .fs_mkdir / .process_exec dispatches
                // can pass it to std.Io.Dir.cwd().createFile(io, ...) etc.
                self.write("    __zag_io = init.io;\n");
        }

        // Phase 2 var-p name-isolation (zig 0.16 fix): for each
        // `is_var = true` param (renamed to `__zag_local_<name>` above),
        // inject `var <name> = __zag_local_<name>;` at body entry.
        // The fresh local `<name>` is mutable (allowing body mutations
        // like `x += 1`), and the parameter carrying the caller's
        // value passes through zig's pass-by-value default — caller
        // isolation is preserved.
        for (fun.params) |p| {
            if (p.is_var) {
                self.write("    var ");
                self.write(p.name);
                self.write(" = __zag_local_");
                self.write(p.name);
                self.write(";\n");
            }
        }
        // June-style escape analysis: classify every `new` site in
        // this body (Local → hoisted alloc + `defer destroy` in the
        // prologue below; escaping/freed/arena → inline as before).
        // Top-level funs never return their last-stmt match value
        // (genStmt gets is_tail_pos = false), so tail_match_returns
        // is always false here — methods pass their actual gate.
        self.runEscapeAnalysis(fun.params, fun.body, false);
        for (fun.body) |stmt| {
            self.genStmt(stmt, false);
        }

        self.write("}\n\n");
    }

    /// Emit a zig `extern fn` declaration for a zag `extern fun`
    /// (docs/24 §"extern fun"). The function is declared with C
    /// calling convention (default for `extern` in zig).
    pub     fn genExternDecl(self: *Codegen, ext: ast.ExternDecl) void {
        self.write("pub extern fn ");
        self.write(ext.name);
        self.write("(");
        for (ext.params, 0..) |p, i| {
            if (i > 0) self.write(", ");
            self.write(p.name);
            self.write(": ");
            self.writeType(p.type_text);
        }
        if (ext.is_variadic) {
            if (ext.params.len > 0) self.write(", ");
            self.write("...");
        }
        self.write(") ");
        if (ext.return_type) |rt| self.writeType(rt) else self.write("void");
        self.write(";\n\n");
    }

    /// Emit a zig `test "name" { ... }` block for an `@[test]` function.
    /// Test functions have no parameters — the body runs directly.
    pub     fn genTestFun(self: *Codegen, fun: ast.FunDecl) void {
        self.destructure_counter = 0;
        self.type_info_count = 0;
        self.current_symbol = fun.name;
        self.alloc_counter = 0;
        self.match_counter = 0;
        self.blk_counter = 0;

        // Type-info seeding (mirror of genFun): the `as`-cast
        // lowerings (pointer→int @intFromPtr, float→int
        // @intFromFloat, print `{s}` widening) read this map, and
        // without the walk a `ptr as usize` inside a test body falls
        // through to a bare `@as(usize, ptr)` the zig compiler
        // rejects. Surfaced by the concurrency examples' threaded
        // @[test] fns (`spawn(worker, st as usize)`).
        for (fun.body) |stmt| {
            self.collectTypedBindings(stmt);
        }
        for (fun.params) |p| {
            if (self.type_info_count >= self.type_info_buf.len) break;
            var already = false;
            for (self.type_info_buf[0..self.type_info_count]) |ti| {
                if (std.mem.eql(u8, ti.name, p.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            self.type_info_buf[self.type_info_count] = .{
                .name = p.name,
                .type_name = p.type_text,
                .is_closure = false,
            };
            self.type_info_count += 1;
        }

        // Doc comment on the test block
        if (fun.doc) |d| self.genDocComment(d);

        self.write("test \"");
        self.write(fun.name);
        self.write("\" {\n");

        // Trait-bounds guards (if generics present)
        self.genBoundsGuards(fun.type_params);

        // June-style escape analysis (see runEscapeAnalysis doc).
        // Test bodies never return their last-stmt value.
        self.runEscapeAnalysis(&[_]ast.MethodParam{}, fun.body, false);

        for (fun.body) |s| self.genStmt(s, false);

        self.write("}\n\n");
    }

    /// Emit a zig `const` declaration for a top-level `const` binding.
    pub     fn genConstDecl(self: *Codegen, cd: ast.ConstDecl) void {
        // Module binding: `const` (compile-time, docs/26) or `var`
        // (module-level mutable state, e.g. posix.zag's getenv scan
        // buffer). Both emit through the same shape — only the leading
        // keyword differs.
        if (cd.is_var) {
            self.write("var ");
        } else {
            self.write("const ");
        }
        self.write(cd.name);
        if (cd.type_text) |tt| {
            self.write(": ");
            self.writeType(tt);
        }
        self.write(" = ");
        // Compile-time-block initializer (`const SQUARES: [16]i32 =
        // const { … }`): mark comptime-scoped like the fn-local
        // binding path (stmt.zig genBinding) so the `.const_block`
        // expr drops its `comptime` keyword — zig 0.16 rejects the
        // redundant spelling inside a const-decl RHS. `var`
        // module-level decls keep the keyword (variants evaluate at
        // compile time in runtime scope).
        const prev_comptime = self.comptime_scope;
        self.comptime_scope = !cd.is_var and cd.init.*.payload == .const_block;
        self.genExpr(cd.init.*);
        self.comptime_scope = prev_comptime;
        self.write(";\n\n");
    }
