// src/codegen/builtins.zig -- Phase 0+1 codegen-router surface.
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
// callees (`.call` shim path). Adding `get`/`getEnv`/`read_file` entries
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
/// Phase 0 wired `argv_get`; Phase 1 widens with `env_var` (real emit)
/// (DEFERRED -- @panic placeholder for future-shape rows). Future Phase 2+
/// entries (`process.exec`, `hash.sha256`, `time.now_utc`, …)
/// extend this same enum without breaking prior wirings -- the use
/// site is a comptime-known switch which zig exhaustiveness-checks at
/// compile time, so a future addition that's missing its case would
/// fail to compile.
pub const BuiltinDispatch = enum {
    /// `builtin_size_of` — emit zig's `@sizeOf(T)` for compile-time
    /// type-size reflection. The single argument must be a type ident;
    /// codegen emits the type verbatim. No per-call counter needed.
    builtin_size_of,

    /// `builtin_align_of` — emit zig's `@alignOf(T)` for compile-time
    /// type-alignment reflection. Same shape as size_of.
    builtin_align_of,

    /// `builtin_volatile_store` — emit zig's `@volatileStore(p, v)`.
    /// For MMIO and embedded systems where stores must not be
    /// optimized away. arity = 2: `volatile_store(ptr, value)`.
    builtin_volatile_store,

    /// `builtin_volatile_load` — emit zig's `@volatileLoad(p)`.
    /// For MMIO reads that must not be cached or reordered.
    /// arity = 1: `volatile_load(ptr)`.
    builtin_volatile_load,

    /// `builtin_atomic_load` — emit `@atomicLoad(T, ptr, .seq_cst)`.
    /// The type T is inferred from `@TypeOf(ptr.*)` at zig level.
    /// arity = 1: `atomic_load(ptr)`.
    builtin_atomic_load,

    /// `builtin_atomic_store` — emit `@atomicStore(T, ptr, val, .seq_cst)`.
    /// arity = 2: `atomic_store(ptr, val)`.
    builtin_atomic_store,

    /// `builtin_atomic_fetch_add` — emit `@atomicRmw(T, ptr, .Add, val, .seq_cst)`.
    /// arity = 2: `atomic_fetch_add(ptr, val)`.
    builtin_atomic_fetch_add,

    /// `builtin_atomic_compare_exchange` — emit `@cmpxchgStrong(...)`.
    /// arity = 3: `atomic_compare_exchange(ptr, expected, new)`.
    builtin_atomic_compare_exchange,

    /// `builtin_thread_spawn` — emit `std.Thread.spawn(.{}, fn, args)`.
    /// Returns a std.Thread handle. arity = 2: `thread_spawn(fn, args)`.
    builtin_thread_spawn,

    /// `builtin_thread_join` — emit `handle.join()`.
    /// arity = 1: `thread_join(handle)`.
    builtin_thread_join,

    /// `builtin_mutex_create` — emit `std.Thread.Mutex{}`.
    /// Returns a mutex value. arity = 0: `mutex_create()`.
    builtin_mutex_create,

    /// `builtin_mutex_lock` — emit `m.lock()`.
    /// arity = 1: `mutex_lock(m)`.
    builtin_mutex_lock,

    /// `builtin_mutex_unlock` — emit `m.unlock()`.
    /// arity = 1: `mutex_unlock(m)`.
    builtin_mutex_unlock,

    /// `builtin_assert` — emit `std.testing.expect(cond) catch unreachable`.
    /// arity = 1: `assert(cond)`. arity = 2: `assert(cond, "msg")`.
    builtin_assert,

    /// `builtin_type_name` — emit zig's `@typeName(T)` for compile-time
    /// type reflection. arity = 1: `type_name(T)`.
    builtin_type_name,

    /// `builtin_type_eq` — emit a zig TYPE-equality `(A == B)`, the
    /// comptime-type-dispatch primitive. Args are type-ish idents
    /// (generic type params like `K`, or zag type names like `str`);
    /// each routes through the type-text mapper so `str` lands as
    /// `[]const u8` while params pass through verbatim. The emitted
    /// condition is comptime-known at every instantiation, so zig's
    /// comptime-if discards the dead branch — the stdlib HashMap
    /// helpers (str-content vs value comparison/hashing) now live in
    /// .zag source instead of the preamble's `__zag_keys_eq` /
    /// `__zag_key_hash` (whose own comment claimed .zag "can't do
    /// that"). arity = 2: `type_eq(K, str)`.
    builtin_type_eq,

    /// `builtin_addr_of` — emit zig's address-of `(&value)` for a
    /// value-expression operand. Closes the .zag surface gap the
    /// hash_map byte-walk needs: there's no `&` unary operator in
    /// zag source, and `__zag_key_hash`'s `@ptrCast(&key)` had no
    /// .zag spelling to point at. Combined with a `[*]const u8` cast
    /// (`@alignCast(@ptrCast(...))` at the cast site) it produces
    /// the canonical value-byte walk. arity = 1: `addr_of(v)`.
    builtin_addr_of,

    /// `builtin_bitcast` — emit zig's `@bitCast(v)` raw-value cast.
    /// Zig 0.16's `std.os.linux.openat` flags parameter is the
    /// packed-bitfield `os.linux.O` type (see lib/std/posix.zag's
    /// openat), which a plain `as` cast cannot reach — the preamble's
    /// `__zag_openat` used to own the `@bitCast` at the boundary.
    /// arity = 1: `bitcast(flags)`.
    builtin_bitcast,

    /// `builtin_enum_from_int` — emit zig's `@enumFromInt(v)` int→enum
    /// conversion. Zig 0.16's `std.os.linux.clock_gettime` clock-id
    /// parameter is the `clockid_t` enum (u32-backed); callers pass a
    /// plain i32 clock-id (CLOCK_MONOTONIC = 1) and this does the
    /// boundary conversion (the preamble's `__zag_clock_gettime` owned
    /// the same `@enumFromInt` call). arity = 1: `enum_from_int(id)`.
    builtin_enum_from_int,

    /// `string_with_capacity` — `String.with_capacity(n)` → `__zag_String.withCapacity(alloc, n)`.
    string_with_capacity,

    /// `writer_std_out` — `Writer.std_out()` → `__zag_Writer.stdOut()`.
    writer_std_out,
    /// `writer_std_err` — `Writer.std_err()` → `__zag_Writer.stdErr()`.
    writer_std_err,

    /// Returns the zig name for a known zag String method.
    pub fn stringMethodZigName(zag_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, zag_name, "as_str")) return "as_str";
        if (std.mem.eql(u8, zag_name, "push_str")) return "push_str";
        if (std.mem.eql(u8, zag_name, "with_capacity")) return "with_capacity";
        if (std.mem.eql(u8, zag_name, "push_ch")) return "push_ch";
        if (std.mem.eql(u8, zag_name, "pop_ch")) return "pop_ch";
        if (std.mem.eql(u8, zag_name, "insert_ch")) return "insert_ch";
        return null;
    }

    /// Returns the zig name for a known Writer method.
    pub fn writerMethodZigName(zag_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, zag_name, "write_all")) return "write_all";
        if (std.mem.eql(u8, zag_name, "std_out")) return "std_out";
        if (std.mem.eql(u8, zag_name, "std_err")) return "std_err";
        return null;
    }
};

/// One row in the router table. The match shape is name + arity --
/// Phase 0+1 surface uses bare-name `get` / `getEnv` / `read_file` so the
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
    /// no selective `{get}`) will populate this slot. Phase 0+1
    /// only have free-fn routes so each entry is `null`.
    receiver: ?[]const u8 = null,
    dispatch: BuiltinDispatch,
};

/// Comptime-known router table. Phase 0 shipped this with a single
/// argv_get row; Phase 1 widens with env_var. fs_read_file retired
/// (lib/std/fs.zag's real impl + @import+alias fallthrough). Phase 2+
/// widens further (`process.exec`, `hash.sha256`, `time.now_utc`, etc.)
/// to a Phase 6 steady-state surface of ≤30 rows. All ≤32 entries at
/// lifetime so a linear-scan lookup is bounded.
///
/// The table is `pub const` and comptime-initialized, which zig 0.16
/// supports without runtime init -- the array lives in the binary's
/// const-data section and the lookup-pointer arithmetic resolves at
/// first-call time. sentinel for over-N is the linear scan itself (no
/// upper bound needed for v1).
pub const builtin_table = [_]BuiltinRoute{
    // v0.1 Tier-1 stdlib migration: the Phase 0 `get` (argv) row was
    // RETIRED — `pub import std.argv.{get}` now resolves to the real
    // lib/std/argv.zag impl (`return __zag_argv;`) through the
    // @import+alias fallthrough, mirroring get_env/read_file/
    // write_file/mkdir. The pre-migration emit (per-call blk walker
    // over std.os.argv into a stack-allocated [32][]const u8) is
    // history; zig 0.16 removed std.os.argv entirely.
    //
    // Phase 3 (CLI migration): additions that close the loop for
    // cli.zag as the canonical CLI dispatcher. Each is additive —
    // prior tests stay byte-identical because the existing argv_get
    // rows are untouched. arity is exact-match per Phase 0's
    // footgun note.
    //
    //   `read_file` / `write_file` / `mkdir` / `exit` / `exec` /
    //   `alloc` / `panic` / `now` / `getEnv`(→get_env) / `get`(argv)
    //   were retired as builtin rows in the v0.1 Tier-1 migration in
    //   favour of real lib/std .zag impls backed by the __zag_posix /
    //   __zag_process_spawn preamble family (see lib/std/{fs,env,
    //   process,time,mem,debug,argv}.zag). Their call sites now
    //   resolve through the @import+alias fallthrough in
    //   src/codegen/core.zig's imports loop (Option A pass-through),
    //   except argv.get which binds preamble-side (__zag_argv lives
    //   in the user module — see stdlibPreambleName).
    //
    //   Remaining rows below are compiler INTRINSICS (size_of /
    //   align_of / volatile_* / atomic_* / thread_* / mutex_* /
    //   type_name) and the String/Writer receiver-routed arms — zag
    //   source cannot express their zig builtin call shapes, so they
    //   stay router-emitted by design.
    .{ .name = "size_of", .arity = 1, .receiver = null, .dispatch = .builtin_size_of },
    .{ .name = "align_of", .arity = 1, .receiver = null, .dispatch = .builtin_align_of },
    .{ .name = "volatile_store", .arity = 2, .receiver = null, .dispatch = .builtin_volatile_store },
    .{ .name = "volatile_load", .arity = 1, .receiver = null, .dispatch = .builtin_volatile_load },
    .{ .name = "load", .arity = 1, .receiver = null, .dispatch = .builtin_atomic_load },
    .{ .name = "store", .arity = 2, .receiver = null, .dispatch = .builtin_atomic_store },
    .{ .name = "fetch_add", .arity = 2, .receiver = null, .dispatch = .builtin_atomic_fetch_add },
    .{ .name = "compare_exchange", .arity = 3, .receiver = null, .dispatch = .builtin_atomic_compare_exchange },
    .{ .name = "spawn", .arity = 2, .receiver = null, .dispatch = .builtin_thread_spawn },
    .{ .name = "join", .arity = 1, .receiver = null, .dispatch = .builtin_thread_join },
    .{ .name = "create", .arity = 0, .receiver = null, .dispatch = .builtin_mutex_create },
    .{ .name = "lock", .arity = 1, .receiver = null, .dispatch = .builtin_mutex_lock },
    .{ .name = "unlock", .arity = 1, .receiver = null, .dispatch = .builtin_mutex_unlock },
    .{ .name = "assert", .arity = 1, .receiver = null, .dispatch = .builtin_assert },
    .{ .name = "assert", .arity = 2, .receiver = null, .dispatch = .builtin_assert },
    .{ .name = "type_name", .arity = 1, .receiver = null, .dispatch = .builtin_type_name },
    // Comptime type dispatch: type equality (HashMap str-key branch
    // selection) + value address-of (value-key byte hashing).
    .{ .name = "type_eq", .arity = 2, .receiver = null, .dispatch = .builtin_type_eq },
    .{ .name = "addr_of", .arity = 1, .receiver = null, .dispatch = .builtin_addr_of },
    // Raw-value reinterpretation for the posix.zag syscall boundary:
    // zig 0.16's `std.os.linux.openat` takes the packed-bitfield `O`
    // flags type (not a plain u32) and `std.os.linux.clock_gettime`
    // takes the `clockid_t` enum — neither has a .zag spelling, so
    // the boundary cast lives in the builtin. bitcast emits
    // `@bitCast(v)`; enum_from_int emits `@enumFromInt(v)`.
    .{ .name = "bitcast", .arity = 1, .receiver = null, .dispatch = .builtin_bitcast },
    .{ .name = "enum_from_int", .arity = 1, .receiver = null, .dispatch = .builtin_enum_from_int },
    // String type static method — receiver = "String" for dispatch
    .{ .name = "with_capacity", .arity = 1, .receiver = "String", .dispatch = .string_with_capacity },
    // Writer type static methods
    .{ .name = "std_out", .arity = 0, .receiver = "Writer", .dispatch = .writer_std_out },
    .{ .name = "std_err", .arity = 0, .receiver = "Writer", .dispatch = .writer_std_err },
};

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
/// 0+1 has no receiver-routed entries so this currently returns null
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
