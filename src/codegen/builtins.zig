// src/codegen/builtins.zig -- Phase 0 codegen-router surface.
//
// BACKGROUND
// ----------
// Prior to Phase 0, src/codegen/expr.zig's `.call` and `.method_call`
// arms emitted the user's call VERBATIM (`<name>(<args>)`) -- the only
// special cases were `print(...)` (which always shimmed to
// `std.debug.print`) and closure-bound callees (which always
// rewrote to `<name>.call(<args>)`). Any other stdlib call that
// needs to lower to a non-trivial zig stdlib invocation had no
// way to express it: a `.zag` source calling `read_file(path)` would
// emit `read_file(path)` and zig would reject the call site because
// read_file was never declared (no import emit, no shim).
//
// The architecture fix: a tiny builtin-router table checked at codegen
// time BEFORE the verbatim fallback. Each entry declares a name +
// arity + a dispach enum tag. When a `.call` or `.method_call` arm
// sees a matching name (and arity, when non-zero), it routes to an
// inline zig-shim emit instead of the verbatim form. Lookups are
// linear scans over a comptime-known table; the Phase 6 steady-state
// surface is bounded (under 30 entries) so a hash-table rewrite is
// deferred until a real use case warrants it.
//
// Each Phase adds entries by:
//   (1) Adding one BuiltinDispatch variant below.
//   (2) Adding one BuiltinRoute row to builtin_table with the
//       name + arity + dispatch tag.
//   (3) Adding one inline `switch (dispatch) case` arm in src/codegen/expr.zig's
//       genBuiltinCall emit helper with the specific zig shim.
//
// The router does NOT cover `print` (existing special case) or closure
// callees (`.call` shim path). Adding `get`/`var`/`read_file` entries
// is purely additive -- existing tests stay byte-identical.
//
// ----------------------------------------------------------------------------
// IMPORTANT: sibling-bucket pattern
// ----------------------------------------------------------------------------
// This file is a sibling to core/expr/stmt/primary/decl under src/codegen/.
// It is auto-registered through build.zig's `addModule("zag", ...)` which
// resolves sibling paths via `b.path("src/codegen/X.zig")` -- no build.zig
// edit is needed when a new sibling lands. Cross-bucket access works the
// same way: src/codegen/expr.zig does
//     const builtins = @import("builtins.zig");
// and reads `builtins.lookup(...)` / `builtins.BuiltinDispatch.argv_get`
// here. Tests follow the same path via src/tests/codegen.zig's
// `const builtins_mod = @import("../codegen/builtins.zig");` chain --
// the e2e and scaffold module reach these helpers through the parser
// helper module's full `@import("../codegen/builtins.zig")` re-export.
// ----------------------------------------------------------------------------

const std = @import("std");

/// Dispatch enum: one variant per registered builtin. Each variant drives
/// an inline `case` in src/codegen/expr.zig's `genBuiltinCall` helper.
/// Adding a new builtin = add one variant here + one table row +
/// one switch case in expr.zig.
///
/// `argv_get`, `env_var`, `fs_read_file` are the Phase 1 set; the
/// future Phase 2+ entries (`process_exec`, `hash_sha256`,
/// `time_now_utc`, ...) extend this same enum without breaking
/// prior wirings -- the use site is a comptime-known switch
/// which zig exhaustiveness-checks at compile time, so a future
/// addition that's missing its case would fail to compile.
pub const BuiltinDispatch = enum {
    /// `argv_get` -- emit a per-call `(blk: { ... })` that walks
    /// `std.os.argv` (zippty-terminated sentinel slice of optional
    /// *u8) into a stack-allocated `__argv_<N>: [32][]const u8` slice
    /// and yields that slice. Intentionally NOT heap-allocating
    /// because argv slicing is on the CLI hot path; the [32] cap
    /// matches the conventional `argc <= 32` working case and
    /// the loop is bounded.
    argv_get,

    /// `env_var` -- emit `std.os.getenv(<arg>) orelse null`. zig's
    /// `std.os.getenv` returns `?[:0]const u8`; the `orelse null`
    /// collapses to a `?[]const u8` zig-side which the user's zag
    /// surface reads as `Option<str>`. Errors are NOT bubbled up
    /// here -- env_var is a convenience lookup, not a control-flow
    /// primitive; the `Option` channel provides the same
    /// ergonomics zag's `?` operator consumes.
    env_var,

    /// `fs_read_file` -- emit
    /// `std.fs.cwd().readFileAlloc(std.heap.page_allocator, <arg>, 65536) catch &[_]u8{}`
    /// so the error path lowers to an empty slice. The 65536-byte
    /// cap matches conventional small-file reading (manifests,
    /// lockfiles, source files); larger reads are a Phase 2 widening
    /// (probably `readAlloc` with a user-supplied cap, or
    /// `readFileStream` for unbounded). The `catch &[_]u8{}` is
    /// documented in lib/std/fs.zag's docblock so users have a
    /// single-source-of-truth for the error-collapse contract.
    fs_read_file,
};

/// One row in the router table. The match shape is name + arity --
/// Phase 1 surface uses bare-name `get` / `var` / `read_file` so the
/// user source (after `pub import std.X.{name}` selective import)
/// can match. Forward Phase 2+ entries that need a receiver prefix
/// (e.g. `fs.write_file` only when receiver is `fs`) can add an
/// optional `recv` slot by extending `BuiltinRoute` (the existing
/// `lookupWithRecv` already treats `recv != ""` as a miss so the
/// change is forward-compatible).
pub const BuiltinRoute = struct {
    name: []const u8,
    /// Exact-match arity. arity = 0 means "only matches when the
    /// call has zero args" — NOT a wildcard. Phase 1 surface all
    /// uses exact arity because every builtin has a fixed shape;
    /// the original wildcard design was a footgun (a user call
    /// `get(1, 2)` would have routed to argv_get and silently
    /// emitted wrong data). The exact-arity contract keeps the
    /// router predictable for v1.
    arity: u8,
    /// Optional receiver prefix matching for method-call routes.
    /// When null, the entry is a free-fn (selective-import form
    /// surfaces it as a bare `name(...)` call). When non-null,
    /// the entry only matches method calls whose receiver-prefix
    /// string equals this field — future Phase widening (e.g.
    /// `argv.get()` method form after `pub import std.argv` with
    /// no selective `{get}`) will populate this slot. Phase 0 only
    /// has free-fn routes so each entry is `null`.
    receiver: ?[]const u8 = null,
    dispatch: BuiltinDispatch,
};

/// Comptime-known router table. Phase 0 ships this EMPTY -- adding
/// entries is a per-Phase widening. Phase 1 wires `argv_get`,
/// `env_var`, `fs_read_file` (3 rows); Phase 5 widens to
/// `process.exec`, `hash.sha256`, `time.now_utc` (3 more); the
/// final Phase 6 self-hosted driver tightens to ~30 rows. All ≤32
/// entries at lifetime so a linear-scan lookup is bounded.
///
/// The table is `pub const` and JSON-initialized at compile time,
/// which zig 0.16 supports without runtime init -- the array
/// lives in the binary's const-data section and the lookup-pointer
/// arithmetic resolves at first-call time. sentinel for over-N is
/// the linear scan itself (no upper bound needed for v1).
pub const builtin_table = [_]BuiltinRoute{
    // Phase 0 first entry: `get` (no-receiver free-fn form after
    // `pub import std.argv.{get}` selective import) routes to the
    // argv_get dispatch which emits a per-call blk wrapper that
    // walks `std.os.argv` into a stack-allocated [32][]const u8.
    // arity = 0 is EXACT-match (zero-arg call sites only) per the
    // pin-test `argv_get counter increments across multiple calls
    // in the same body`. The wildcard-design was abandoned after
    // a code-review flagged the footgun (`get(1, 2)` would have
    // silently routed to argv_get's emit shape and burned the
    // user's args).
    .{ .name = "get", .arity = 0, .receiver = null, .dispatch = .argv_get },
}; // Phase 0: 1 entry (argv_get). Phase 1 widens with env_var + fs_read_file.

/// Lookup a free-fn call: returns the dispatch if `<name>` with that
/// arity is a registered builtin, otherwise null. O(N) linear scan
/// over `builtin_table` -- bounded Phase 6 ≤ 30 entries, fine for v1.
///
/// Used by src/codegen/expr.zig's `.call` arm when the call's
/// `name` and `args.len` don't match `print`, aren't closure-bound,
/// and aren't carrying turbofish type_args. Inserting this check
/// BEFORE the verbatim-or-turbofish fallback preserves the existing
/// behavior for non-builtin calls (user functions, generic functions,
/// turbofish call sites) -- the router is a no-op when no entry
/// matches.
pub fn lookup(name: []const u8, arity: usize) ?BuiltinDispatch {
    for (builtin_table) |r| {
        // Free-fn routes only (receiver == null). Method-call
        // routes (receiver != null) need lookupWithRecv; this
        // helper intentionally skips them so a future Phase
        // adding receiver-aware entries doesn't accidentally
        // misfire from the wrong lookup surface.
        if (r.receiver != null) continue;
        if (std.mem.eql(u8, r.name, name) and r.arity == arity) {
            return r.dispatch;
        }
    }
    return null;
}

/// Lookup a method call: same shape as `lookup` plus the receiver
/// prefix constraint. Each entry with `receiver != null` must match
/// the caller's `recv` string exactly; mismatch returns null. Phase
/// 0 has no receiver-routed entries so this currently returns null
/// for every call — the wiring stays forward-compatible for the
/// Phase 2+ surface where `argv.get()` method form (whole-module
/// `import std.argv`) routes through here.
pub fn lookupWithRecv(recv: []const u8, name: []const u8, arity: usize) ?BuiltinDispatch {
    for (builtin_table) |r| {
        const want = r.receiver orelse continue;
        if (!std.mem.eql(u8, want, recv)) continue;
        if (std.mem.eql(u8, r.name, name) and r.arity == arity) {
            return r.dispatch;
        }
    }
    return null;
}
