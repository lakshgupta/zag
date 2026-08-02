const std = @import("std");
const ast = @import("../ast.zig");

// ============================================================
// escape.zig — June-style escape/lifetime analysis (per function)
// ============================================================
//
// Inspiration (june/docs/architecture.md "Lifetime Checker"): June
// associates a lifetime with every expression that can influence an
// allocation — bindings, assignments, calls, returns — and classifies
// each value as one of:
//
//   Local     — the value does not escape this function
//   Parameter — storing into a mutable parameter lets values escape
//   Return    — values returned from the function escape
//
// and iterates to a FIXED POINT (repeat until nothing changes) to
// propagate those verdicts through use-def chains (e.g. the
// `new A()` stored into a local struct that is later returned gets
// a `Return` lifetime even though no direct `return new A()` exists).
//
// Zag's v1 integration (docs/19-memory.md Pattern 1): `new T(v)`
// allocates on the heap and today the USER must pair it with
// `defer free(p)`. This pass classifies every `new` site in a
// function body and lets codegen AUTO-INSERT the matching
// `defer <alloc>.destroy(__p_N)` for Local sites — leak-free-by-
// default without changing the manual-ownership surface.
//
// June's data model is used directly: the pass produces a SIDE-
// VECTOR of per-site info keyed by a stable site index (the Nth
// `new_expr` in AST depth-first walk order) — nothing is stuffed
// into the AST node structs. The site index IS the codegen
// `alloc_counter` value at the corresponding `.new_expr` arm in
// src/codegen/expr.zig, so the two passes agree by construction
// as long as both walk the AST in the same left-to-right order.
// The one intentional divergence — the `.add` / `.offset`
// method-call arms re-emit subexpressions — is mirrored here (see
// the `.method_call` arm below).
//
// Soundness contract: the analysis errs CONSERVATIVELY toward
// "escapes" — any site that might escape (returned, passed to a
// call, stored through a pointer, assigned to a parameter or
// global, allocated inside a closure) is excluded from auto-free.
// A false "escape" only costs a leak (status quo); a false
// "Local" would cost a use-after-free, and the rules below never
// produce one: every syntactic route by which a `new` value can
// leave the function walks its bit into `escapes` before the
// verdict is computed.

/// Max tracked `new` sites per function body. Sites beyond this are
/// treated as escaping (no auto-free) via the `overflow` flag.
pub const MAX_SITES = 128;
/// Max tracked variable slots (per-scope name slots are reused
/// across fixpoint iterations by construction — see `defineVar`).
const MAX_VARS = 256;
/// Max nested scopes (if/while/for/match/block/closure bodies).
const MAX_SCOPES = 64;
/// Max variables declared per scope.
const MAX_SCOPE_VARS = 32;
/// Fixpoint iteration cap. Union-monotone analysis terminates in
/// bounded steps (each site can enter each var-flow once); the cap
/// is defensive — on a hit everything conservatively escapes.
const MAX_FIXPOINT_ITERS = 32;

/// One tracked allocation site: the info codegen needs to emit the
/// hoisted `const __p_N = try ...create(T);` prologue.
pub const SiteInfo = struct {
    type_name: []const u8,
    allocator: ?[]const u8,
};

/// Per-function verdict table (the June-style side-vector).
pub const Result = struct {
    site_count: u32 = 0,
    /// Bit `i` set → site `i` is LOCAL (auto-free eligible): it
    /// never escapes the function, is not explicitly freed, and
    /// uses the default page allocator.
    autofree: u128 = 0,
    /// Site info by index; valid up to `site_count`.
    sites: [MAX_SITES]SiteInfo = undefined,
};

/// One name→slot entry in a scope frame. Slots index into
/// `var_flow`; a slot is REUSED for the same (scope depth, name)
/// across fixpoint iterations so loop-carried flows accumulate
/// monotonically instead of oscillating.
const VarSlot = struct {
    name: []const u8,
    slot: u16,
};

const Analyzer = struct {
    result: Result,
    /// Use-def flow: var slot → union of site bits that may be in
    /// the variable. Grows monotonically across fixpoint iterations.
    var_flow: [MAX_VARS]u128 = [_]u128{0} ** MAX_VARS,
    /// True for slots seeded from function parameters. June's
    /// "Parameter" lifetime: values stored into params escape.
    var_is_param: [MAX_VARS]bool = [_]bool{false} ** MAX_VARS,
    var_count: usize = 0,
    /// Scope stack of name→slot maps. `scope_vars[depth]` is valid
    /// up to `scope_count[depth]`; frames are overwritten by the
    /// next block at the same depth (block-scoped vars are gone
    /// once their block ends, so overwriting is sound).
    scope_vars: [MAX_SCOPES][MAX_SCOPE_VARS]VarSlot = undefined,
    scope_count: [MAX_SCOPES]u8 = [_]u8{0} ** MAX_SCOPES,
    depth: usize = 0,
    /// Union of site bits that escape the function (Return /
    /// Parameter / call-arg / pointer-store / closure / global).
    escapes: u128 = 0,
    /// Union of site bits whose value is passed to an explicit
    /// `free(...)` in the body (manual ownership — skip auto-free).
    freed: u128 = 0,
    /// Sites allocated through the allocator-sugar form
    /// `new(<arena>, T(v))` — the arena owns the lifecycle, never
    /// auto-free these.
    arena_sites: u128 = 0,
    /// Set when a buffer overflows or a site count exceeds
    /// MAX_SITES — every site conservatively escapes.
    overflow: bool = false,
    /// Set when a flow set or the escape mask grew this iteration.
    changed: bool = false,
    /// Mirrors codegen's `fn_returns_value and last-stmt` gate: when
    /// true, a tail-position match statement's arm flows are returned
    /// by the emitted zig (genStmt prefixes `return`).
    tail_match_returns: bool = false,
    /// Position of the current `.new_expr` visit in THIS iteration's
    /// walk. Resets to 0 every fixpoint iteration; because the walk
    /// is deterministic (AST-driven), the same node lands on the
    /// same position every iteration — which IS the site id. Site
    /// recording happens only on the first pass so a re-walked
    /// `.new_expr` node keeps its id (codegen's alloc_counter
    /// visits each node exactly once).
    visit_count: u32 = 0,
    /// True while the first fixpoint iteration is running. Only the
    /// first pass appends to `result.sites` / `result.site_count`.
    first_pass: bool = true,
};

/// Run the per-function escape analysis. `tail_match_returns` must
/// mirror codegen's `fn_returns_value and last-stmt` gate (true for
/// impl-block methods with a return type whose LAST body statement
/// is a match — genStmt prefixes `return` in that exact position).
pub fn analyze(
    params: []const ast.MethodParam,
    body: []const ast.Stmt,
    tail_match_returns: bool,
) Result {
    var a = Analyzer{ .result = .{ .sites = undefined } };
    a.tail_match_returns = tail_match_returns;
    // June's fixed-point: repeat the full body walk until no flow
    // set and no escape mask changed. Flows only grow (union), so
    // termination is guaranteed in bounded steps; the iteration cap
    // below is purely defensive.
    var iters: usize = 0;
    while (true) : (iters += 1) {
        a.changed = false;
        a.visit_count = 0;
        a.depth = 0;
        pushScope(&a);
        for (params) |p| {
            const slot = defineVar(&a, p.name);
            a.var_is_param[slot] = true;
        }
        walkStmts(&a, body, null);
        // June's "Parameter" lifetime: mutable params (and the
        // method receiver) can store values and have them escape.
        var pbits: u128 = 0;
        for (a.var_is_param, 0..) |is_p, i| {
            if (is_p) pbits |= a.var_flow[i];
        }
        addEscapes(&a, pbits);
        a.first_pass = false;
        if (!a.changed) break;
        if (iters >= MAX_FIXPOINT_ITERS) {
            // Defensive: the analysis didn't converge in the cap —
            // everything conservatively escapes (safe direction).
            a.overflow = true;
            break;
        }
    }
    // Fold the side-vectors into the verdict mask: Local = tracked,
    // not escaping, not explicitly freed, not arena-backed.
    var r = a.result;
    r.site_count = a.result.site_count;
    const all: u128 = if (a.result.site_count >= 128)
        ~@as(u128, 0)
    else
        (@as(u128, 1) << @intCast(a.result.site_count)) - 1;
    r.autofree = all & ~(a.escapes | a.freed | a.arena_sites);
    if (a.overflow) r.autofree = 0;
    return r;
}

// ============================================================
// Scope / flow primitives
// ============================================================

fn pushScope(a: *Analyzer) void {
    if (a.depth >= MAX_SCOPES) {
        a.overflow = true;
        return;
    }
    // NOTE: the frame at this depth is deliberately NOT cleared.
    // Frame entries persist across fixpoint iterations so a var
    // redeclared in the same position keeps its slot (defineVar
    // allocates slots monotonically — clearing would give every
    // re-walked var a FRESH slot each iteration and orphan the
    // flow accumulated on the previous iteration's slot, which
    // breaks loop-carried propagation). Within one iteration the
    // persistence is harmless too: sibling blocks at the same
    // depth that redeclare a name share that name's slot, which
    // only ever OVER-approximates flows (the conservative
    // direction — see the soundness contract in the header).
    a.depth += 1;
}

fn popScope(a: *Analyzer) void {
    if (a.depth > 0) a.depth -= 1;
}

/// Look up a var slot by name in the scope stack (innermost first).
/// Returns null when the name is not bound in any active scope (a
/// module-level global, an imported name, or a closure param).
fn resolveVar(a: *Analyzer, name: []const u8) ?u16 {
    var d = a.depth;
    while (d > 0) {
        d -= 1;
        const n = a.scope_count[d];
        for (a.scope_vars[d][0..n]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.slot;
        }
    }
    return null;
}

/// Bind `name` in the current scope. Reuses the existing slot when
/// the name is already bound in the current frame (a redeclaration
/// is invalid source anyway; reuse keeps flows monotone), and reuses
/// the frame's deterministic slot allocation order across fixpoint
/// iterations so the same logical var always maps to the same slot.
fn defineVar(a: *Analyzer, name: []const u8) u16 {
    if (a.depth == 0 or a.depth > MAX_SCOPES) {
        // No scope frame (shouldn't happen — analyze seeds one) or
        // overflow: fail safe by routing to a fresh slot if possible.
        if (a.var_count < MAX_VARS) {
            const slot: u16 = @intCast(a.var_count);
            a.var_count += 1;
            return slot;
        }
        a.overflow = true;
        return 0;
    }
    const d = a.depth - 1;
    const n = a.scope_count[d];
    for (a.scope_vars[d][0..n]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.slot;
    }
    if (n >= MAX_SCOPE_VARS or a.var_count >= MAX_VARS) {
        a.overflow = true;
        return 0;
    }
    const slot: u16 = @intCast(a.var_count);
    a.var_count += 1;
    a.scope_vars[d][n] = .{ .name = name, .slot = slot };
    a.scope_count[d] = n + 1;
    return slot;
}

fn setFlow(a: *Analyzer, slot: u16, bits: u128) void {
    const old = a.var_flow[slot];
    const merged = old | bits;
    if (merged != old) {
        a.var_flow[slot] = merged;
        a.changed = true;
    }
}

fn addEscapes(a: *Analyzer, bits: u128) void {
    const old = a.escapes;
    a.escapes |= bits;
    if (a.escapes != old) a.changed = true;
}

fn addFreed(a: *Analyzer, bits: u128) void {
    a.freed |= bits;
}

fn addArena(a: *Analyzer, idx: u32) void {
    if (idx < 128) a.arena_sites |= @as(u128, 1) << @intCast(idx);
}

/// Register a `.new_expr` visit. Returns the site id = the visit's
/// position in the current (deterministic) walk. Site records are
/// appended only on the first fixpoint pass so re-walked nodes keep
/// their id; overflow sites (id >= MAX_SITES) mark the whole result
/// conservative (no auto-free).
fn newSite(a: *Analyzer, n: ast.Expr.NewExpr) u32 {
    const id = a.visit_count;
    a.visit_count += 1;
    if (id >= MAX_SITES) {
        a.overflow = true;
        return id;
    }
    if (a.first_pass) {
        a.result.sites[id] = .{ .type_name = n.type_name, .allocator = n.allocator };
        a.result.site_count = id + 1;
    }
    return id;
}

/// Mark every site visited within [before, after) as escaping —
/// used for closure bodies and comptime const-blocks, whose values
/// can leave the function through paths we don't track.
fn escapeRange(a: *Analyzer, before: u32, after: u32) void {
    if (after <= before) return;
    var bits: u128 = 0;
    var i = before;
    while (i < after) : (i += 1) {
        if (i < 128) bits |= @as(u128, 1) << @intCast(i);
    }
    addEscapes(a, bits);
}

// ============================================================
// Statement walker
// ============================================================

/// Walk a statement list. `value_out`, when non-null, receives the
/// flow of the block's final value (the last statement's expr when
/// it is an expr_stmt) so expression-position block walkers
/// (.block_expr) can propagate the block's value without re-walking
/// (re-walking would desync the new-site numbering).
fn walkStmts(a: *Analyzer, stmts: []const ast.Stmt, value_out: ?*u128) void {
    const n = stmts.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        walkStmt(a, stmts[i], i == n - 1, if (value_out != null and i == n - 1) value_out else null);
    }
}

fn walkStmt(a: *Analyzer, s: ast.Stmt, is_tail: bool, value_out: ?*u128) void {
    switch (s.payload) {
        .let, .var_binding, .const_binding => |b| {
            if (b.block) |stmts| {
                // Compile-time block binding: values inside are
                // comptime; treat any site as escaping.
                const before = a.visit_count;
                pushScope(a);
                walkStmts(a, stmts, null);
                popScope(a);
                escapeRange(a, before, a.visit_count);
                return;
            }
            if (b.pattern != null) {
                // Destructuring: the per-leaf ownership split is not
                // tracked; conservatively treat every site in the
                // initializer as escaping.
                var flow: u128 = 0;
                if (b.init) |init_expr| walkExpr(a, init_expr, &flow);
                addEscapes(a, flow);
                return;
            }
            const slot = defineVar(a, b.name);
            var flow: u128 = 0;
            if (b.init) |init_expr| walkExpr(a, init_expr, &flow);
            setFlow(a, slot, flow);
        },
        .assign => |asg| {
            var flow: u128 = 0;
            walkExpr(a, asg.value, &flow);
            if (resolveVar(a, asg.name)) |slot| {
                setFlow(a, slot, flow);
            } else {
                // Module-level / imported target: the stored value
                // outlives the function.
                addEscapes(a, flow);
            }
        },
        .index_assign => |ia| {
            // Target is emitted by codegen (keep numbering in sync).
            var scratch: u128 = 0;
            walkExpr(a, ia.target.*, &scratch);
            var flow: u128 = 0;
            walkExpr(a, ia.value, &flow);
            // Write-through into an indexable container.
            addEscapes(a, flow);
        },
        .field_assign => |fa| {
            var scratch: u128 = 0;
            walkExpr(a, fa.target.*, &scratch);
            var flow: u128 = 0;
            walkExpr(a, fa.value, &flow);
            // Store into a field — the struct may itself escape.
            addEscapes(a, flow);
        },
        .deref_assign => |da| {
            var flow: u128 = 0;
            walkExpr(a, da.value, &flow);
            // Write-through a pointer: reachable from the pointee.
            addEscapes(a, flow);
        },
        .defer_stmt => |d| {
            var scratch: u128 = 0;
            walkExpr(a, d.expr, &scratch);
        },
        .errdefer_stmt => |d| {
            var scratch: u128 = 0;
            walkExpr(a, d.expr, &scratch);
        },
        .unsafe_block => |stmts| {
            pushScope(a);
            walkStmts(a, stmts, null);
            popScope(a);
        },
        .if_stmt => |ifs| {
            if (ifs.is_if_let) {
                var flow: u128 = 0;
                walkExpr(a, ifs.cond, &flow);
                bindPattern(a, ifs.if_let_pat, flow);
            } else {
                var scratch: u128 = 0;
                walkExpr(a, ifs.cond, &scratch);
            }
            pushScope(a);
            walkStmts(a, ifs.then_body, null);
            popScope(a);
            switch (ifs.else_kind) {
                .none => {},
                .block => |stmts| {
                    pushScope(a);
                    walkStmts(a, stmts, null);
                    popScope(a);
                },
                .if_chain => |inner| {
                    walkStmt(a, ast.Stmt{ .payload = .{ .if_stmt = inner.* }, .loc = ifs.cond.loc }, false, null);
                },
            }
        },
        .while_stmt => |ws| {
            if (ws.is_while_let) {
                var flow: u128 = 0;
                walkExpr(a, ws.cond, &flow);
                bindPattern(a, ws.while_let_pat, flow);
            } else {
                var scratch: u128 = 0;
                walkExpr(a, ws.cond, &scratch);
            }
            pushScope(a);
            walkStmts(a, ws.body, null);
            popScope(a);
        },
        .for_stmt => |fs| {
            var iter_flow: u128 = 0;
            walkExpr(a, fs.iter, &iter_flow);
            pushScope(a);
            // The iteration variable receives the iterator's flow.
            switch (fs.pattern) {
                .ident => |name| {
                    const slot = defineVar(a, name);
                    setFlow(a, slot, iter_flow);
                },
                else => {},
            }
            walkStmts(a, fs.body, null);
            popScope(a);
        },
        .match_stmt => |m| {
            // June's "Return" via tail-position match: genStmt emits
            // `return (blk: {...});` when the match is the LAST
            // statement of a value-returning method — its arm flows
            // then leave the function.
            var scr: u128 = 0;
            walkExpr(a, m.scrutinee.*, &scr);
            pushScope(a);
            for (m.arms) |arm| {
                // Pattern literal/range exprs are emitted by
                // emitPatternCond BEFORE the guard — walk them for
                // numbering parity (no new-site can appear inside a
                // literal pattern, but the walk keeps order honest).
                walkPatternExprs(a, arm.pat);
                bindPattern(a, arm.pat, scr);
                if (arm.guard) |g| {
                    var scratch: u128 = 0;
                    walkExpr(a, g.*, &scratch);
                }
                var arm_flow: u128 = 0;
                walkExpr(a, arm.expr.*, &arm_flow);
                if (a.tail_match_returns and is_tail) addEscapes(a, arm_flow);
            }
            popScope(a);
        },
        .return_stmt => |r| {
            if (r.value) |v| {
                var flow: u128 = 0;
                walkExpr(a, v, &flow);
                addEscapes(a, flow);
            }
        },
        .break_stmt, .continue_stmt => {},
        .expr_stmt => |e| {
            var flow: u128 = 0;
            walkExpr(a, e, &flow);
            if (value_out) |vo| vo.* = flow;
        },
    }
}

/// Bind the capture names declared on a match/if-let/while-let
/// pattern, seeded with the scrutinee/cond flow (codegen emits each
/// capture as `const NAME = __m...;` so the scrutinee's sites flow
/// into the captures).
fn bindPattern(a: *Analyzer, p: ast.Pattern, flow: u128) void {
    switch (p) {
        .ident => |name| {
            const slot = defineVar(a, name);
            setFlow(a, slot, flow);
        },
        .enum_variant => |ev| {
            if (ev.bindings) |bs| {
                for (bs) |b| {
                    if (b) |name| {
                        const slot = defineVar(a, name);
                        setFlow(a, slot, flow);
                    }
                }
            }
        },
        .enum_variant_named => |env| {
            for (env.fields) |f| {
                if (f.capture) |name| {
                    const slot = defineVar(a, name);
                    setFlow(a, slot, flow);
                }
            }
        },
        .literal, .range, .discard => {},
    }
}

/// Walk the sub-expressions codegen emits when lowering a match-arm
/// pattern (`emitPatternCond` in src/codegen/stmt.zig re-emits
/// `.literal` patterns and `.range` start/end operands). No `new`
/// can hide in a literal pattern today, but walking keeps the
/// site-numbering parity contract robust against future pattern
/// widening.
fn walkPatternExprs(a: *Analyzer, p: ast.Pattern) void {
    var scratch: u128 = 0;
    switch (p) {
        .literal => |lit| walkExpr(a, lit.*, &scratch),
        .range => |r| {
            walkExpr(a, r.start.*, &scratch);
            walkExpr(a, r.end.*, &scratch);
        },
        .ident, .discard, .enum_variant, .enum_variant_named => {},
    }
}

// ============================================================
// Expression walker
// ============================================================

/// Collect the union of tracked-site bits flowing through `e` into
/// `out`. Also numbers every `new` site in the same left-to-right
/// depth-first order codegen's `.new_expr` arm does (parity
/// contract — see the file header).
fn walkExpr(a: *Analyzer, e: ast.Expr, out: *u128) void {
    switch (e.payload) {
        .string_lit, .int_lit, .float_lit, .bool_lit, .char_lit,
        .byte_string_lit, .null_lit, .undefined_lit,
        => {},
        .tuple_lit => |t| {
            for (t) |el| walkExpr(a, el, out);
        },
        .single_tuple_lit => |t| {
            walkExpr(a, t.*, out);
        },
        .named_tuple_lit => |nt| {
            for (nt.elements) |el| walkExpr(a, el, out);
        },
        .array_lit => |al| {
            for (al.elements) |el| walkExpr(a, el, out);
        },
        .ident => |name| {
            if (resolveVar(a, name)) |slot| out.* |= a.var_flow[slot];
        },
        .call => |c| {
            // Unknown callee: every argument can be stored or
            // returned by the callee, so every arg site escapes.
            for (c.args) |arg| {
                var flow: u128 = 0;
                walkExpr(a, arg, &flow);
                addEscapes(a, flow);
            }
        },
        .new_expr => |n| {
            // Number BEFORE walking the value — codegen's arm also
            // captures `id` before genExpr(value).
            const id = newSite(a, n);
            if (n.allocator != null) addArena(a, id);
            walkExpr(a, n.value.*, out);
            if (id < 128) out.* |= @as(u128, 1) << @intCast(id);
        },
        .free_expr => |f| {
            var flow: u128 = 0;
            walkExpr(a, f.target.*, &flow);
            addFreed(a, flow);
        },
        .deref => |d| {
            walkExpr(a, d.target_ptr.*, out);
        },
        .cast => |c| {
            walkExpr(a, c.expr.*, out);
        },
        .template_lit => |t| {
            for (t.parts) |part| {
                if (part.expr) |pe| walkExpr(a, pe, out);
            }
        },
        .binary => |b| {
            walkExpr(a, b.lhs.*, out);
            walkExpr(a, b.rhs.*, out);
        },
        .unary => |u| {
            walkExpr(a, u.operand.*, out);
        },
        .index => |ix| {
            walkExpr(a, ix.target.*, out);
            walkExpr(a, ix.index.*, out);
        },
        .slice => |sl| {
            walkExpr(a, sl.target.*, out);
            if (sl.start) |st| walkExpr(a, st.*, out);
            if (sl.end) |en| walkExpr(a, en.*, out);
        },
        .range => |r| {
            walkExpr(a, r.start.*, out);
            walkExpr(a, r.end.*, out);
        },
        .if_expr => |ife| {
            var scratch: u128 = 0;
            walkExpr(a, ife.cond.*, &scratch);
            walkExpr(a, ife.then_expr.*, out);
            walkExpr(a, ife.else_expr.*, out);
        },
        .match_expr => |m| {
            // Expression-form match: the match's VALUE is the arm
            // expr flows; the scrutinee is read-only.
            var scratch: u128 = 0;
            walkExpr(a, m.scrutinee.*, &scratch);
            for (m.arms) |arm| {
                walkPatternExprs(a, arm.pat);
                if (arm.guard) |g| {
                    var gflow: u128 = 0;
                    walkExpr(a, g.*, &gflow);
                }
                walkExpr(a, arm.expr.*, out);
            }
        },
        .struct_lit => |sl| {
            for (sl.inits) |fi| walkExpr(a, fi.value.*, out);
        },
        .member_access => |ma| {
            walkExpr(a, ma.target.*, out);
        },
        .method_call => |mc| {
            // PARITY: genExpr's `.add` / `.offset` arms re-emit the
            // target three / two times interleaved with args[0]
            // (zig's @TypeOf/@intFromPtr/@sizeOf drill). Mirror the
            // exact emission order so a `new` inside the target or
            // arg gets the same site ids codegen's alloc_counter
            // assigns. Other method calls emit target + args once.
            if (mc.args.len == 1 and
                (std.mem.eql(u8, mc.name, "add") or std.mem.eql(u8, mc.name, "offset")))
            {
                var scratch: u128 = 0;
                walkExpr(a, mc.target.*, &scratch);
                walkExpr(a, mc.target.*, &scratch);
                walkExpr(a, mc.args[0], &scratch);
                walkExpr(a, mc.target.*, &scratch);
                out.* |= scratch;
                return;
            }
            // Receiver + args escape: methods can store self or any
            // argument into state that outlives the call.
            var scratch: u128 = 0;
            walkExpr(a, mc.target.*, &scratch);
            addEscapes(a, scratch);
            for (mc.args) |arg| {
                var flow: u128 = 0;
                walkExpr(a, arg, &flow);
                addEscapes(a, flow);
            }
        },
        .enum_variant_ctor => |evc| {
            for (evc.args) |arg| walkExpr(a, arg, out);
        },
        .closure => |cl| {
            // Closure-allocated values leave through the closure's
            // call result or captured state — conservatively escape
            // every site inside the body (they are still numbered
            // for codegen parity).
            const before = a.visit_count;
            pushScope(a);
            walkStmts(a, cl.body, null);
            popScope(a);
            escapeRange(a, before, a.visit_count);
        },
        .try_op => |t| {
            walkExpr(a, t.expr.*, out);
        },
        .catch_expr => |c| {
            walkExpr(a, c.expr.*, out);
            walkExpr(a, c.handler.*, out);
        },
        .block_expr => |stmts| {
            pushScope(a);
            var bv: u128 = 0;
            walkStmts(a, stmts, &bv);
            popScope(a);
            out.* |= bv;
        },
        .const_block => |stmts| {
            const before = a.visit_count;
            pushScope(a);
            walkStmts(a, stmts, null);
            popScope(a);
            escapeRange(a, before, a.visit_count);
        },
        .asm_expr => |ae| {
            // Inline-asm operands are read/written by the assembly —
            // their sites can escape through the asm block, so walk
            // the operand expressions and treat them as escaping.
            for (ae.outputs) |op| {
                var scratch: u128 = 0;
                walkExpr(a, op.expr.*, &scratch);
                addEscapes(a, scratch);
            }
            for (ae.inputs) |op| {
                var scratch: u128 = 0;
                walkExpr(a, op.expr.*, &scratch);
                addEscapes(a, scratch);
            }
        },
        .await_expr => |ae| {
            // The awaited future's value flows into the await result.
            walkExpr(a, ae.expr.*, out);
        },
    }
}
