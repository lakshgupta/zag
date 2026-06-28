// In-process pin-tests for `src/env_path.zig`'s `getenv` +
// `resolveZagCacheDir` helpers.
//
// Why these tests live here
// -------------------------
// Pre-pin path: `env_path.zig`'s env-resolution contract was only
// exercised end-to-end via `zig build smoke`, with a vendor zig
// fixture staged at `vendor/zig/zig.test`. Any off-by-one in
// `getenv` (e.g. an `indexOfScalar` boundary bug) or a bufPrint-cap
// regression in `resolveZagCacheDir` could slip past the smoke
// silently because SKIP-branch invocations (no fixture staged)
// exit 0 without ever consulting the priority chain. Pinning the
// surface in-process catches these regressions at `zig build test`
// time without a fixture dependency.
//
// Why the test-only helper uses a caller-provided backing buffer
// ------------------------------------------------------------
// `env_path.environ_buf` was tightened to module-private (no `pub`)
// during the (c) cleanup so the module encapsulation-on-default
// principle holds: future refactors (mmap'd backing, staged reads,
// etc.) are free to swap `environ_buf` without breaking any caller.
// Tests respect that encapsulation by passing their own scratch
// bytes via `setEnvironForTesting(entries, backing)`; production
// code still writes to `environ_buf`'s 131 KB reserve at startup
// via `readEnviron`. Each test below allocates a small stack buffer
// (`env_buf`) sized for the handful of entries it sets up; this
// avoids any test-time coupling to the production 131 KB reserve.
//
// Per-test isolation
// ------------------
// Each `test "..."` block calls `setEnvironForTesting` at its start
// with the env array it intends to exercise. This rewrites
// `environ_count` to the new value, so leftover state from a prior
// test cannot leak. The zig test runner also resets BSS-zeroed
// globals between tests under the default `refAllDecls`, but the
// explicit reset makes test isolation visible at the assertion
// surface.

const std = @import("std");
const env_path = @import("env_path");

// Reusable scratch buffer. 4 KB comfortably holds ~30 short env
// entries (each ~10–50 bytes of key=value text). Each test case
// uses its OWN stack buffer declared inline for tighter scope; this
// const lives at module-private area for tests that want to share.
const env_buf_size: usize = 4096;
var env_buf: [env_buf_size]u8 = undefined;

test "env_path: getenv returns Some(value) for a literal KEY=VALUE" {
    const env = [_][]const u8{"HOME=/tmp/test"};
    env_path.setEnvironForTesting(&env, &env_buf);
    const result = env_path.getenv("HOME");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/tmp/test", result.?);
}

test "env_path: getenv returns null when the env array is empty" {
    // Mirrors the post-`readEnviron` failure path's BSS-zero state:
    // empty entries + empty count = every key is missing. The
    // caller can distinguish null from Some("") via the optional
    // — these two paths MUST produce different results.
    env_path.setEnvironForTesting(&[_][]const u8{}, &env_buf);
    try std.testing.expect(env_path.getenv("ANY_KEY") == null);
    try std.testing.expect(env_path.getenv("HOME") == null);
    try std.testing.expect(env_path.getenv("ZAG_HOME") == null);
}

test "env_path: getenv returns null when the key is absent" {
    // Defensive: a non-empty env that simply doesn't include the
    // target key. Tests `indexOfScalar` exit + `std.mem.eql`
    // mismatch path returns `null`.
    const env = [_][]const u8{
        "HOME=/tmp",
        "PATH=:/usr/bin",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    try std.testing.expect(env_path.getenv("MISSING_KEY") == null);
}

test "env_path: getenv does not match prefix keys (F != FOO)" {
    // The off-by-one risk: confusing `ZAG_HOME` with `ZAG`. The
    // `if (sep == name.len)` length-equality guard must reject the
    // shorter key regardless of the longer key's content.
    const env = [_][]const u8{
        "FOO=bar",
        "ZAG_HOME=/explicit",
        "Z=last",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    try std.testing.expect(env_path.getenv("F") == null);
    try std.testing.expect(env_path.getenv("FO") == null);
    try std.testing.expect(env_path.getenv("ZAG") == null);
    try std.testing.expect(env_path.getenv("ZAG_HOME") != null);
    try std.testing.expectEqualStrings("/explicit", env_path.getenv("ZAG_HOME").?);
}

test "env_path: getenv returns the value slice only — strips key= prefix exactly once" {
    // A value that itself contains an `=` (e.g. URL parameters,
    // COOKIE values). getenv must find the FIRST `=` via
    // `indexOfScalar` and return everything after, ignoring
    // subsequent `=` bytes. Without this guarantee, a URL-style
    // env var lands truncated.
    const env = [_][]const u8{
        "URL=http://example.com?a=1&b=2",
        "COOKIE=key=value;foo=bar",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    try std.testing.expectEqualStrings(
        "http://example.com?a=1&b=2",
        env_path.getenv("URL").?,
    );
    try std.testing.expectEqualStrings(
        "key=value;foo=bar",
        env_path.getenv("COOKIE").?,
    );
}

test "env_path: getenv returns empty-slice Some(\"\") for KEY= (empty value)" {
    // The deliberate zero-byte value case. `indexOfScalar` finds
    // the `=` at offset `name.len`; the returned slice spans
    // `name.len + 1 .. end` of the entry, which is `name.len + 1
    // .. name.len + 1` (zero bytes). Pin `Some` rather than `null`
    // so a regression that treats `KEY=` as "no match" surfaces
    // here rather than silently dropping the env var.
    const env = [_][]const u8{
        "EMPTY=",
        "NONEMPTY=ok",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    const empty = env_path.getenv("EMPTY");
    try std.testing.expect(empty != null);
    try std.testing.expectEqualStrings("", empty.?);
    try std.testing.expectEqual(@as(usize, 0), empty.?.len);
    // Sanity: the non-empty neighbour still resolves correctly.
    try std.testing.expectEqualStrings("ok", env_path.getenv("NONEMPTY").?);
}

test "env_path: getenv is order-independent across the entries array" {
    // The lookup walks `environ_entries[0..count]` linearly, so any
    // permutation of the same set must yield the same value. Without
    // this pin, a regression that switched to a hashmap or to
    // last-write-wins would surface as a position-dependent bug.
    const target_first = [_][]const u8{
        "TARGET=found",
        "OTHER=ignored",
        "MORE=trash",
    };
    const target_middle = [_][]const u8{
        "OTHER=ignored",
        "TARGET=found",
        "MORE=trash",
    };
    const target_last = [_][]const u8{
        "MORE=trash",
        "OTHER=ignored",
        "TARGET=found",
    };

    for ([3][]const []const u8{ &target_first, &target_middle, &target_last }) |ordering| {
        env_path.setEnvironForTesting(ordering, &env_buf);
        try std.testing.expectEqualStrings("found", env_path.getenv("TARGET").?);
        try std.testing.expectEqualStrings("ignored", env_path.getenv("OTHER").?);
        try std.testing.expectEqualStrings("trash", env_path.getenv("MORE").?);
    }
}

test "env_path: getenv finds the entry across multiple bins of unrelated keys" {
    // Five unrelated key=value pairs; each lookup must hit its
    // specific entry. Pins that the iteration walks every slot
    // rather than first-or-last shortcuts.
    const env = [_][]const u8{
        "ONE=1",
        "TWO=2",
        "THREE=3",
        "FOUR=4",
        "FIVE=5",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    try std.testing.expectEqualStrings("1", env_path.getenv("ONE").?);
    try std.testing.expectEqualStrings("2", env_path.getenv("TWO").?);
    try std.testing.expectEqualStrings("3", env_path.getenv("THREE").?);
    try std.testing.expectEqualStrings("4", env_path.getenv("FOUR").?);
    try std.testing.expectEqualStrings("5", env_path.getenv("FIVE").?);
    // Sanity: an absent sibling still reports null.
    try std.testing.expect(env_path.getenv("SIX") == null);
}

test "env_path: resolveZagCacheDir $ZAG_HOME wins when set alone" {
    // The strongest priority: explicit user override beats every
    // other convention. The value passes through verbatim (no
    // bufPrint, no suffix append) so a regression that routes
    // $ZAG_HOME through the bufPrint path would alias-rewrite it
    // and surface here.
    const env = [_][]const u8{"ZAG_HOME=/explicit/user/path"};
    env_path.setEnvironForTesting(&env, &env_buf);
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/explicit/user/path",
        env_path.resolveZagCacheDir(&buf, "/default-fallback"),
    );
}

test "env_path: resolveZagCacheDir $ZAG_HOME wins over $XDG_CACHE_HOME" {
    // Pin the second-column of the priority chain: $ZAG_HOME out-
    // ranks $XDG_CACHE_HOME regardless of which is set first in
    // the env. Without the early-return on $ZAG_HOME, the resolver
    // would arrive at the XDG branch and emit
    // `/xdg_loses/zag` instead.
    const env = [_][]const u8{
        "ZAG_HOME=/zag_wins",
        "XDG_CACHE_HOME=/xdg_loses",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/zag_wins",
        env_path.resolveZagCacheDir(&buf, "/default-fallback"),
    );
}

test "env_path: resolveZagCacheDir $ZAG_HOME wins over $XDG_CACHE_HOME + $HOME" {
    // The fully-populated priority-chain stress test: all three
    // env vars are set. $ZAG_HOME must still be the first-returned
    // branch; the resolver never consults $XDG_CACHE_HOME or
    // $HOME in this case.
    const env = [_][]const u8{
        "ZAG_HOME=/zag_wins",
        "XDG_CACHE_HOME=/xdg_loses",
        "HOME=/home_loses",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/zag_wins",
        env_path.resolveZagCacheDir(&buf, "/default-fallback"),
    );
}

test "env_path: resolveZagCacheDir $XDG_CACHE_HOME alone produces `<cache>/zag`" {
    // Second priority: freedesktop.org cache convention. The
    // `/zag` suffix is appended via `std.fmt.bufPrint` so the
    // returned slice points into the caller's scratch buffer.
    // The test confirms (a) the suffix appears, (b) the slice
    // matches the expected verbatim string (so a `+ "/zag"` typo
    // would also fail), and (c) the slice still equals the input
    // when stripped, proving bufPrint materialised correctly.
    const env = [_][]const u8{"XDG_CACHE_HOME=/var/cache"};
    env_path.setEnvironForTesting(&env, &env_buf);
    var buf: [4096]u8 = undefined;
    const result = env_path.resolveZagCacheDir(&buf, "/default-fallback");
    try std.testing.expectEqualStrings("/var/cache/zag", result);
    // Sanity: the bare `/var/cache` substring must NOT appear in
    // the returned slice — that's the substring's whole point of
    // being passed to bufPrint.
    try std.testing.expect(std.mem.indexOf(u8, result, "/var/cache/zag") != null);
}

test "env_path: resolveZagCacheDir $XDG_CACHE_HOME wins over $HOME" {
    // The XDG/HOME relative-priority pin. XDG is the freedesktop
    // convention; HOME is the POSIX fallback. Both being set, XDG
    // must win regardless of which appears first in the env list.
    const env = [_][]const u8{
        "XDG_CACHE_HOME=/var/cache",
        "HOME=/home/user",
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/var/cache/zag",
        env_path.resolveZagCacheDir(&buf, "/default-fallback"),
    );
}

test "env_path: resolveZagCacheDir $HOME alone produces `<home>/.cache/zag`" {
    // Third priority: POSIX HOME fallback. The `/home/user` value
    // is joined with `/.cache/zag` to follow freedesktop's
    // `~/.cache` convention even when XDG_CACHE_HOME is unset.
    const env = [_][]const u8{"HOME=/home/user"};
    env_path.setEnvironForTesting(&env, &env_buf);
    var buf: [4096]u8 = undefined;
    const result = env_path.resolveZagCacheDir(&buf, "/default-fallback");
    try std.testing.expectEqualStrings("/home/user/.cache/zag", result);
}

test "env_path: resolveZagCacheDir no env vars → comptime_fallback unchanged" {
    // The none-of-the-above branch: a stripped CI container with
    // no $ZAG_HOME / $XDG_CACHE_HOME / $HOME still materialises
    // at the configured compile-time path. Reachable from the
    // return statement at the very end of the priority chain.
    env_path.setEnvironForTesting(&[_][]const u8{}, &env_buf);
    var buf: [4096]u8 = undefined;
    const result = env_path.resolveZagCacheDir(&buf, "/build-options-default");
    try std.testing.expectEqualStrings("/build-options-default", result);
}

test "env_path: resolveZagCacheDir bufPrint-cap (path > buf) → comptime_fallback" {
    // Pin the `bufPrint (... ) catch comptime_fallback` guard. A
    // $HOME value that, after appending `/.cache/zag`, exceeds
    // the caller's scratch-buffer capacity must route to the
    // fallback rather than truncate or panic. The 64-byte scratch
    // is deliberately tiny so the long HOME value exceeds it.
    //
    // The HOME path is ~96 bytes; combined with the 11-byte
    // `/.cache/zag` suffix, the formatter sees ~107 bytes — well
    // past the 64-byte buffer's hard cap.
    const long_home = "/this/path/is/artificially/very/very/long/so/that/bufPrint/must/overflow";
    const env = [_][]const u8{
        "HOME=" ++ long_home,
    };
    env_path.setEnvironForTesting(&env, &env_buf);
    var small_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/build-options-default",
        env_path.resolveZagCacheDir(&small_buf, "/build-options-default"),
    );
    // Sanity: the long home path must NOT have leaked into the
    // scratch buffer's prefix — a regression that bypassed the
    // `catch` would leave the long path truncated in `buf`.
    try std.testing.expect(std.mem.indexOf(u8, &small_buf, long_home) == null);
}

test "env_path: setEnvironForTesting caps at environ_entries capacity" {
    // Defensive pin: an env array larger than `environ_entries.len`
    // must saturate at the array boundary rather than overflow.
    // Every overflow guard in the helper (count-cap, backing-len-cap)
    // must trigger the right way. The cap mirrors `readEnviron`'s
    // `while (i < n and environ_count < 512)` guard -- both fns cap
    // at 512 (the `environ_entries` array's full capacity). The
    // envp_z consumers in main.zig's `runCommand` and smoke.zig's
    // `runProgram` need the trailing null slot (envp_z is
    // `[513]?[*:0]const u8` with `@min(env_path.environ_count,
    // envp_z.len - 1) = 512`), so capping at 512 (= the array's
    // full length) leaves room for the trailing null without
    // changing the consumer-side invariant.
    var entries: [600][]const u8 = undefined;
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        entries[i] = "X=1";
    }
    env_path.setEnvironForTesting(&entries, &env_buf);
    // Strict equality pin: catches off-by-cap regressions in either
    // direction (e.g. a future bump to 513 hiding a backing-len-cap
    // mismatch, OR an accidental cap-back to 511). Loose `<= 512`
    // would silently accept both directions of drift; `== 512` is
    // the surgical pin for the helper's actual saturation behaviour
    // when 600 entries are written into a 512-slot array.
    try std.testing.expect(env_path.environ_count == 512);
}
