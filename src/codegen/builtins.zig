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
/// and `fs_read_file` (DEFERRED -- @panic placeholder, see the
/// fs_read_file variant comment below for why). Future Phase 2+
/// entries (`process.exec`, `hash.sha256`, `time.now_utc`, …)
/// extend this same enum without breaking prior wirings -- the use
/// site is a comptime-known switch which zig exhaustiveness-checks at
/// compile time, so a future addition that's missing its case would
/// fail to compile.
pub const BuiltinDispatch = enum {
    /// `argv_get` -- emit a per-call `(blk: { ... })` that walks
    /// `std.os.argv` (zippty-terminated sentinel slice of optional
    /// *u8) into a stack-allocated `__argv_<N>: [32][]const u8` slice
    /// and yields that slice. Intentionally NOT heap-allocating
    /// because argv slicing is on the CLI hot path; the [32] cap
    /// matches the conventional `argc <= 32` working case and
    /// the loop is bounded.
    argv_get,

    /// `env_var` -- emit a per-call blk wrapper that calls
    /// `std.posix.system.getenv(<args[0]>)` and bridges the
    /// `?[*:0]u8` libc surface to zag's `?[]const u8` shape via
    /// `std.mem.span`. The blk-wrapped form lets the result variable
    /// live across the explicit `if (...)|s|` arm's scope without
    /// leaking the zig-typed `[*:0]u8` pointer into the zag call site's
    /// expression context. `std.posix.system` aliases to `std.c`
    /// when the build links libc (typical user-binary case), and to
    /// `std.os.linux`/`std.os.windows`/etc. otherwise -- so the emit
    /// compiles both with and without libc without an `-Dlibc` flag.
    /// The `orelse null`-style handling is NOT used here because
    /// `std.posix.system.getenv` returns `null` natively on unset
    /// variables (matches `Option<None>` directly) -- the explicit
    /// `if(...)|s|` arm avoids the `orelse`-on-non-optional-type
    /// footgun that Phase 0 hit on the argv element type. Errors
    /// are NOT bubbled; `env_var` is a convenience lookup, not a
    /// control-flow primitive.
    env_var,

    /// `fs_read_file` -- Phase 2 real emit.
    ///
    /// zig 0.16 retired `vendor/zig/lib/std/fs.zig` to a 21-line
    /// deprecation-stub file (every entry there is just
    /// `Deprecated, use std.Io.Dir.<X>`) and relocated the real fs
    /// surface to `std.Io.Dir.readFileAlloc(dir, io, allocator,
    /// sub_path, limit)`. The signature requires a `std.Io`
    /// event-loop instance.
    ///
    /// Per-call blk wrapper shape (the design that landed in
    /// Phase 2 commit):
    ///   ```
    ///   blk: {
    ///       var __io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    ///       defer __io_threaded.deinit();
    ///       const __fs_<N>: []u8 = std.Io.Dir.cwd().readFileAlloc(
    ///           __io_threaded.io(),
    ///           <args[0]>,
    ///           std.heap.page_allocator,
    ///           .unlimited,
    ///       ) catch &[_]u8{};
    ///       break :blk __fs_<N>;
    ///   }
    ///   ```
    ///
    /// Init order is LIFO at scope exit:
    /// `defer __io_threaded.deinit()` registers at construction
    /// time and runs AFTER `break :blk` captures the slice into the
    /// call site, so the Io's thread pool + signal handlers
    /// (`SIG.IO` / `SIG.PIPE`) outlive the `readFileAlloc` call but
    /// are torn down before the surrounding block exits. The init
    /// is infallible (any `CpuCountError` is stored on
    /// `t.cpu_count_error`, NOT raised) so no `catch` is needed.
    ///
    /// Allocator choice (`std.heap.page_allocator`) mirrors the
    /// existing `.new_expr` codegen path so heap allocation policy
    /// stays consistent across .zag's surface. Memory ownership
    /// of the returned `[]u8` is the caller; the user MUST free
    /// via `std.heap.page_allocator.free(slice)` before discarding
    /// (a Phase 2.1 widening will add `free <slice>` overload to
    /// `.free_expr` so the .zag surface gets a cleaner `defer free
    /// data` syntax). Page-aligned leaks at process exit are
    /// acceptable for short-lived zag binaries.
    ///
    /// Error collapse: `catch &[_]u8{}` silently coalesces every
    /// path of the triple-union error set
    /// (`Io.Dir.Reader.Error || std.mem.Allocator.Error ||
    /// Io.UnexpectedError`) into an empty-slice. The docs/18
    /// error-propagation contract isn't here yet — Phase 3 may add
    /// a sibling `read_file_or` builtin that bubbles
    /// `error.FileNotFound` etc. via zag's `?` operator. v1
    /// surface keeps `read_file` simple: empty slice on failure,
    /// heap-allocated bytes on success, no error channel.
    ///    /// Per-call scoping: each fs_read_file invocation steps
        /// `fs_counter` and emits a fresh `__fs_<N>` scratch — sibling
        /// `read_file` calls in the same body produce distinct names
        /// (zig's no-redeclaration rule would reject a clash). The
        /// counter resets at the top of each function body
        /// (`genFun` + `genMethod` + `genFreeMethod` in decl.zig).
        fs_read_file,

    /// `fs_write_file` -- Phase 3 real emit (CLI migration). Bridges
    /// cli.zag's `init` handler to a self-allocating write-loop on the
    /// posix fd surface (no `Io` event-loop needed for write, only
    /// for read in zig 0.16's retired `std.fs` layout). Returns i32:
    /// 0 on success, -1 on any open/write failure. The 2-arity shape
    /// matches the cli.zag call: `write_file(path_str, content_slice)`.
    /// docblock mirrored in the table row below.
    fs_write_file,

    /// `fs_mkdir` -- Phase 3 (CLI migration). Single-arg mkdir patterns
    /// the cli.zag `init <name>` semantics (mkdir -p: EEXIST silent,
    /// other errors surface as -1 from the call). docblock mirrored
    /// in the table row below.
    fs_mkdir,

    /// `process_exec` -- Phase 3 (CLI migration). The cli.zag-run,
    /// cli.zag-build, cli.zag-check subcommands use this fork+execve
    /// to recursively invoke zag in `--leaf-process` mode (which is
    /// the only mode that touches the lex/parse/codegen surface —
    /// keeping the bootstrap's zig-side transpile lifecycle in
    /// place rather than re-implementing it in zag source).
    /// docblock mirrored in the table row below.
    process_exec,

    /// `process_exit` -- Phase 3 (CLI migration). Lets cli.zag's
    /// `cli_main() -> i32` exit code propagate through the zag-side
    /// `exit(rc)` call instead of zig-side `std.process.exit`.
    /// docblock mirrored in the table row below.
    process_exit,

    /// `builtin_alloc` — emit a per-call blk wrapper that calls
    /// `std.heap.page_allocator.alloc(u8, N) catch @panic("OOM")`
    /// and returns `[]u8` (heap-allocated byte slice, docs/19 §1).
    /// The user MUST free with `free(buf)` when done. arity = 1:
    /// only the `alloc(N)` one-arg form routes.
    builtin_alloc,

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

    /// `builtin_panic` — emit zig's `@panic(msg)` which prints a stack
    /// trace in debug mode and aborts the program. arity = 1: `panic(msg)`.
    builtin_panic,

    /// `string_with_capacity` — `String.with_capacity(n)` → `__zag_String.withCapacity(alloc, n)`.
    string_with_capacity,

    /// `writer_std_out` — `Writer.std_out()` → `__zag_Writer.stdOut()`.
    writer_std_out,
    /// `writer_std_err` — `Writer.std_err()` → `__zag_Writer.stdErr()`.
    writer_std_err,

    /// `time_now` — `now()` → `std.time.nanoTimestamp()` (i64 nanos since monotonic epoch).
    time_now,

    /// Returns the zig name for a known zag String method.
    pub fn stringMethodZigName(zag_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, zag_name, "as_str")) return "asStr";
        if (std.mem.eql(u8, zag_name, "push_str")) return "pushStr";
        if (std.mem.eql(u8, zag_name, "with_capacity")) return "withCapacity";
        return null;
    }

    /// Returns the zig name for a known Writer method.
    pub fn writerMethodZigName(zag_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, zag_name, "write_all")) return "writeAll";
        if (std.mem.eql(u8, zag_name, "print")) return "print";
        if (std.mem.eql(u8, zag_name, "std_out")) return "stdOut";
        if (std.mem.eql(u8, zag_name, "std_err")) return "stdErr";
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
/// argv_get row; Phase 1 widens with env_var and fs_read_file. Phase 2+
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
    // Phase 1 second entry: `getEnv` (no-receiver free-fn form
    // after `pub import std.env.{getEnv}` selective import) routes
    // to the env_var dispatch which emits the bridge-blk around
    // `std.posix.system.getenv(<args[0]>)`. arity = 1 is EXACT-match:
    // only the `getEnv("NAME")` one-arg form routes; a future
    // `getEnv("NAME", default_value)` widening would add a SECOND
    // row with arity=2 rather than overloading this one, so the
    // exact-arity contract is preserved per Phase 0's note.
    //
    // The naming is camelCase (`getEnv`, not `get_env` or `var`) per
    // the user's explicit "we use camel case for methods" instruction
    // at the time of Phase 1's planning. The prior docblock here
    // named the placeholder entry "var"; the rename is purely
    // docblock-facing -- the BuiltinDispatch variant stays `.env_var`
    // because that name describes the WIRE to zig-side
    // `std.posix.system.getenv`, which is independent of how the
    // user-facing zag call name is spelled.
    .{ .name = "getEnv", .arity = 1, .receiver = null, .dispatch = .env_var },
    // Phase 2 entry: `read_file` (no-receiver free-fn form after
    // `pub import std.fs.{read_file}` selective import) routes to
    // the fs_read_file dispatch which now emits a real zig 0.16
    // `std.Io.Dir.readFileAlloc` shim — see the `fs_read_file`
    // variant docblock above for the per-call blk wrapper shape +
    // the Io lifecycle (`Threaded.init` + `defer deinit`) +
    // page_allocator ownership contract. arity = 1 is EXACT-match:
    // only the `read_file("PATH")` one-arg form routes; a future
    // `read_file(path, limit)` widening would add a SECOND row
    // with arity=2 rather than overloading this one, so the
    // exact-arity contract is preserved per Phase 0's note.
    .{ .name = "read_file", .arity = 1, .receiver = null, .dispatch = .fs_read_file },
    // Phase 3 (CLI migration): four additions that close the loop for
    // cli.zag as the canonical CLI dispatcher. Each is additive —
    // prior tests stay byte-identical because the existing argv_get /
    // env_var / fs_read_file rows are untouched. arity is exact-match
    // per Phase 0's footgun note: a hypothetical `write_file(p)` (no
    // content arg) would NOT route here, avoiding the silent-wrong-
    // emit trap of the prior arity-wildcard design.
    //
    //   `write_file`  arity=2  -> fs_write_file (path, content) -> i32
    //                                          posix.openat + write loop
    //   `mkdir`       arity=1  -> fs_mkdir      (path)
    //                                          std.os.linux.mkdir via toPosixPath
    //   `exec`        arity=1  -> process_exec  (argv []const []const u8)
    //                                          fork + execve + waitpid
    //   `exit`        arity=1  -> process_exit  (code: i32, clamped to u8)
    //                                          std.os.linux.exit
    .{ .name = "write_file", .arity = 2, .receiver = null, .dispatch = .fs_write_file },
    .{ .name = "mkdir", .arity = 1, .receiver = null, .dispatch = .fs_mkdir },
    .{ .name = "exec", .arity = 1, .receiver = null, .dispatch = .process_exec },
    .{ .name = "exit", .arity = 1, .receiver = null, .dispatch = .process_exit },
    .{ .name = "alloc", .arity = 1, .receiver = null, .dispatch = .builtin_alloc },
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
    .{ .name = "panic", .arity = 1, .receiver = null, .dispatch = .builtin_panic },
    // String type static method — receiver = "String" for dispatch
    .{ .name = "with_capacity", .arity = 1, .receiver = "String", .dispatch = .string_with_capacity },
    // Writer type static methods
    .{ .name = "std_out", .arity = 0, .receiver = "Writer", .dispatch = .writer_std_out },
    .{ .name = "std_err", .arity = 0, .receiver = "Writer", .dispatch = .writer_std_err },
    // Time builtin
    .{ .name = "now", .arity = 0, .receiver = null, .dispatch = .time_now },
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
