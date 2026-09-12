# Memory Model

Zag has **no garbage collector**. All memory management is explicit.

## Construction

Three forms, three purposes:

| Form | Returns | Where | When |
|---|---|---|---|
| `Type { fields }` | `T` | Stack | Direct field-by-field construction |
| `Type.init(args)` | `T` | Stack | Constructor with logic, defaults |
| `new T(value)` | `*T` | Heap | Explicit heap allocation — must `free` |

```
let v = Vec3 { x: 1.0, y: 2.0, z: 3.0 };       # struct literal — stack
let cfg = Config.init("localhost", 443);           # constructor — stack
let arr = [8]u8 { 0, 1, 2, 3, 4, 5, 6, 7 };     # fixed array — stack
let zero: [4096]u8 = [4096]u8 { 0 ... };          # fill array — stack

let p = new i32(42);                               # heap value — returns *i32
let buf: []u8 = alloc(1024);                       # heap buffer — returns []u8
```

**`Type.init()` is a convention, not a keyword.** It's a regular static method. Use it when construction needs logic (validation, defaults, computed fields). Use `Type { fields }` for simple direct construction.

**`new` is the ONLY heap keyword.** It always returns `*T`. Every `new` must be paired with `free` — the memory model is manually managed, zig-style (the compiler warns about unpaired `new` / `alloc` / `alloc_raw` sites; see [Manual management + leak warnings](#manual-management--leak-warnings-escape-analysis)).

## Deallocation

`free` works on both pointers and slices — the compiler infers the right zig deallocator from the binding's type annotation:

```
let p = new i32(42);
defer free(p);                     # pointer → page_allocator.destroy(p)

let buf: []u8 = alloc(1024);
defer free(buf);                   # slice → page_allocator.free(buf)
```

`defer` runs at scope exit in LIFO order. `errdefer` runs only on the error path (when `?` propagates):

```
fun build() -> Result<Config, str> {
    let a = compute()?;
    errdefer free(a);              # only runs if `?` propagates

    let b = compute()?;
    return Ok(Config { a: a, b: b });
}
```

## Manual management + leak warnings (escape analysis)

Zag's memory model is **manually managed, zig-style**: `new`/`alloc`
allocate, `free`/`release` deallocate, and the compiler never inserts
frees. To help you keep every allocation paired, the compiler runs a
per-function **escape analysis** (June-language-style lifetime
inference: *Local* / *Parameter* / *Return*, iterated to a fixed
point) and warns about the sites nothing will ever free:

- **Leak warning** — an allocation whose value never leaves the
  function and is never explicitly freed. All three allocation
  families are tracked, so slice allocations are covered too:

  ```
  fun main() {
      let p = new i32(42);        # ⚠ `new i32` is never freed (leak)
      print("value: {p}\n");      # printing does NOT take ownership

      let buf: []u8 = alloc(1024); # ⚠ `alloc` is never freed (leak)
      buf[0] = 1;
  }
  ```

  The message names the construct and the site:

  ```
  warning: `new i32` at src/main.zag:2:13 in main is never freed (leak) — add an explicit `free` or `defer free`
  warning: `alloc` at src/main.zag:5:24 in main is never freed (leak) — add an explicit `free` or `defer free`
  warning: `alloc_raw` at src/main.zag:8:26 in main is never freed (leak) — add an explicit `release(p, n)` or `defer release(p, n)`
  ```

  Warnings are advisory — the emitted code is unchanged, and the fix
  is always your explicit deallocation:

  ```
  fun main() {
      let p = new i32(42);
      defer free(p);              # ✓ explicit ownership

      let buf: []u8 = alloc(1024);
      defer free(buf);            # ✓ the `free` keyword's slice overload
  }
  ```

  Note the differing hint for the two `std.mem` spellings: `alloc(n)`
  returns a `[]u8`, which the `free` keyword's *slice* overload
  discharges; `alloc_raw(n)` returns a `[*]u8`, which the keyword would
  route through its *pointer* overload, so the raw tier's pairing is
  `release(p, n)`.

- **Escaping** — returned (directly or through a variable), stored into
  a field or global, written through an index or pointer, or passed to
  any **user** call. No warning; the caller/owner is responsible:

  ```
  fun make() -> *i32 { return new i32(7); }   # escaped — caller frees

  let buf: []u8 = alloc(16);
  consume(buf);                                # escaped — callee owns it
  ```

- **Explicitly freed** — `free p` / `free buf` / `release(p, n)`, and
  any of those under `defer` or `errdefer`, clear the verdict (no
  double-free is implied — the site keeps its manual form unchanged).

- **Allocator-backed** — `new(arena, ...)` is never warned; the arena
  owns the lifecycle.

`print` and `assert` are **read-only sinks**: they format or test the
value and retain nothing, so they do *not* count as ownership transfer.
That is deliberate — the shape this warning exists to catch is
"allocate a buffer, report something about it, never free it", which a
"was it printed?" escape rule would hide.

The analysis is otherwise deliberately conservative: any path by which a
value *could* escape suppresses the warning (a missed warning only means
your explicit free still applies; a false warning would cry wolf on a
legitimately-owned value). Values allocated inside closures or
compile-time blocks always count as escaping, and a callee the analysis
cannot see into always takes ownership of its arguments.

## Checking for leaks

The escape analysis warns at *compile* time. For the run itself, `std.bench`
exposes a runtime **allocation ledger** you can read at any point:

```zag
import std.bench.{Counters}

fun main() {
    let before: usize = Counters.snapshot().bytes_live;

    ... allocate, use, and free ...

    let after: usize = Counters.snapshot().bytes_live;
    if (after == before) {
        print("no leak\n");
    } else {
        print("LEAK: {after - before} bytes still live\n");
    }
}
```

`Counters.snapshot()` returns three counters:

| Field | Meaning |
|---|---|
| `bytes_live` | bytes currently allocated — **this is the leak check** |
| `bytes_total` | cumulative bytes ever allocated (churn / how much you allocate) |
| `allocations` | cumulative number of allocations |

`bytes_live` is charged by every allocation and discharged by every
deallocation, so a non-zero difference at the end of a scope *is* the leak,
measured in bytes. Nothing is sampled or estimated; the counters are two integer
adds at each site, with no logging-allocator swap.

### What is accounted, and where

The charges live in the **primitives**, not at each call site — a charge the
caller has to remember is a charge that gets forgotten or applied twice:

| Construct | Charged | Discharged by |
|---|---|---|
| `new T(v)` | `@sizeOf(T)` | `free p` |
| `alloc(n)` | `n` | `free buf` |
| `alloc_raw(n)` | `n` | `release(p, n)` |
| `realloc_raw(p, cap, n)` | `n - cap` (the delta) | `release(p, cap)` at the end |
| `String` / `ArrayList` / `HashMap` | via the primitives above on every grow | the container's `deinit()` — **including `String.deinit()`** |
| `split` / `join` / `to_upper` / … | via `alloc_raw` | `free` the returned slice |

Because the charge comes from the same `n` the allocator used, a container
reports its **capacity** as live bytes, not its element count — an
`ArrayList(i32)` holding 100 elements reports its storage (e.g. 512 bytes for a
128-slot buffer), not 400. That is the number that matters for leaks, because it
is what the allocator actually holds.

### Rules the ledger depends on

- **`release(p, cap)` must use the same `cap` the mapping was acquired with.**
  `alloc_raw(n)` charges `n`; `release` discharges its argument. A different
  number leaves a residue equal to the difference.
- **Free the whole slice you allocated.** `free buf[0..10]` discharges 10, not
  the `n` that was charged — the rest stays live forever.
- **Use `release` for the raw tier, not `free`.** The `free` keyword infers the
  charge-back from the pointee type, which is exact for `new`/`alloc` results
  but cannot know a hand-computed mapping size; `release(p, cap)` states it.
- **`String` bindings must be `var` to be released.** `deinit(self: *String)`
  needs a mutable receiver, so `let s = read_file(p)!; s.deinit();` is a
  compile error (`expected type '*T', found '*const T'`). Declare
  `var s: String = read_file(p)!;` when you intend to reclaim it. The ledger
  reports an unreleased buffer honestly rather than hiding it — a
  `read_file` result starts at its 4 KiB initial capacity, so it reads as
  4096 live bytes until `deinit`.
- **`read_file` returns an owned `String`, so it needs a `deinit`.** Every
  String buffer is `alloc_raw`-backed and has no implicit reclamation.
  `deinit()` releases `cap` bytes — the exact amount charged — and zeroes
  `cap`, so a second call is a no-op rather than an `munmap` of a released
  range. It is the only way to bring the ledger back to baseline after any
  `String` workload.

The discharge is **saturating**: an over-large `release` clamps `bytes_live` to
zero rather than wrapping to a huge `usize`. A real double-free is caught by the
allocator itself (`munmap` of an unmapped range panics in `release`), so the
ledger's job stays leak *detection*, not double-free detection.

A worked example, with a `@[test]` row per construct plus a row proving a real
leak *is* visible, lives in `examples/memory/leak_check.zag`.

## Custom Allocators

`new(allocator, T(value))` allocates via a named allocator instead of the global page allocator:

```
let p = new(arena, i32(42));       # arena.create(i32){ .* = 42 }
```

The allocator name is emitted verbatim — `arena` must be a variable in scope whose type has a `.create(T)` method (the zig convention).

## Builtins

| Builtin | Emits | Returns |
|---|---|---|
| `alloc(N)` | `mmap`-backed mapping (`lib/std/mem.zag`) | `[]u8` |
| `size_of(T)` | `@sizeOf(T)` | `usize` (comptime) |
| `align_of(T)` | `@alignOf(T)` | `usize` (comptime) |
| `volatile_store(p, v)` | `@volatileStore(p, v)` | `void` |
| `volatile_load(p)` | `@volatileLoad(p)` | `T` |
| `type_eq(A, B)` | `(A == B)` | `bool` (comptime) |
| `addr_of(v)` | `(&v)` | `*const T` |
| `bitcast(v)` | `@bitCast(v)` | `T` (same-size reinterpret) |
| `enum_from_int(v)` | `@enumFromInt(v)` | tagged enum (runtime value) |

`type_eq(A, B)` is the comptime type-dispatch primitive: it emits a
zig *type equality* — `type_eq(K, str)` emits `(K == []const u8)`
— where `A`/`B` are type texts (generic type params pass through
verbatim; zag names map, so `str` becomes `[]const u8`). The result
is comptime-known at every generic instantiation, so a surrounding
`if` is a comptime branch in zig and the untaken side is discarded
without type-checking. This is what lets std.collections hash_map
give `str` keys content semantics and value keys byte semantics
entirely in .zag (its key helpers retired the preamble's
`__zag_keys_eq`/`__zag_key_hash`).

`addr_of(v)` emits zig's address-of `(&v)` for a value expression —
the .zag surface gap that `val_key_hash`'s byte walk needs; combine
it with a `[*]const u8` cast (`@alignCast(@ptrCast(...))` at the
cast site) to hash a value's raw bytes.

`bitcast(v)` emits zig's `@bitCast(v)` — a same-size, no-ops
reinterpretation of `v`'s bits. The operand must be a *typed* value:
zig's `@bitCast` rejects comptime-known integers, so pass a
`u32`-typed flags variable rather than a literal. `lib/std/posix.zag`
uses it to feed the packed `O` flag bitfield to
`std.os.linux.openat` (`std.os.linux.openat(-100, ".", @bitCast(flags), 0)`).

`enum_from_int(v)` emits zig's `@enumFromInt(v)` — the runtime
integer→enum conversion (the comptime-side `@enumFromInt` is implicit
in `.Tag` syntax). Used by `posix.clock_gettime` to turn a runtime
`i32` clock id into zig's `clockid_t` enum.

## Common Patterns

### Stack buffer

Zero allocation — fixed array on the stack:

```
fun process() {
    let buf: [4096]u8 = [4096]u8 { 0 ... };
    # use buf — freed at scope exit, zero cost
}
```

### Heap buffer with deferred free

```
fun read_and_process(path: str) {
    let data: []u8 = alloc(1024);
    defer free(data);
    # use data — freed at scope exit
}
```

### Heap `String` with deferred `deinit`

`read_file` and `String.from_str` both hand back an owned buffer, so the same
`defer` shape applies — but the binding must be `var`, because `deinit` takes
`*String`:

```
fun read_and_process(path: str) {
    var text: String = read_file(path)!;
    defer text.deinit();
    # use text — buffer released at scope exit, ledger back to baseline
}
```

This is what makes the leak check below usable in a file-reading program: before
`String.deinit` existed, the buffer had no release path, so `bytes_live` could
never return to its baseline.

### Partial init with errdefer

```
fun build_pair() -> Result<Pair, str> {
    let a = new i32(10);
    errdefer free(a);               # freed only if ? propagates

    let b = compute()?;
    return Ok(Pair { a: a, b: b });
}
```

### Unsafe raw pointers

```
unsafe {
    let p: *raw u8 = alloc(4) as *raw u8;
    *p = 0x41;
    let val: u8 = *p;
    free(p as *raw c_void);
}
```

Unsafe is required for: `*raw T` dereferences, pointer arithmetic, pointer-to-integer casts, and C FFI calls.

## Stack vs Heap Summary

| Storage | Syntax | Returns | Lifetime |
|---|---|---|---|
| Struct literal | `Type { .f = v }` | `T` | Scope exit |
| Constructor | `Type.init(args)` | `T` | Scope exit |
| Array literal | `[N]T { vals }` | `[N]T` | Scope exit |
| Array fill | `[N]T { val ... }` | `[N]T` | Scope exit |
| Heap value | `new T(value)` | `*T` | Until `free` |
| Heap buffer | `alloc(N)` | `[]u8` | Until `free` |

**No hidden allocations.** Struct and array literals are on the stack. Only `new` and `alloc` touch the heap.
