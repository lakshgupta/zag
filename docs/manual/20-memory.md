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

**`new` is the ONLY heap keyword.** It always returns `*T`. Every `new` must be paired with `free` — the memory model is manually managed, zig-style (the compiler warns about unpaired `new`s; see [Manual management + leak warnings](#manual-management--leak-warnings-escape-analysis)).

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

Zag's memory model is **manually managed, zig-style**: `new` allocates,
`free` is the only deallocator, and the compiler never inserts frees.
To help you keep every allocation paired, the compiler runs a
per-function **escape analysis** (June-language-style lifetime
inference: *Local* / *Parameter* / *Return*, iterated to a fixed
point) and warns about the sites nothing will ever free:

- **Leak warning** — a `new` whose value never leaves the function,
  isn't passed to a call, and is never explicitly `free`d:

  ```
  fun main() {
      let p = new i32(42);        # ⚠ warning: never freed (leak)
      print("value: {p}\n");      # print(p) makes p escape → no warning
  }
  ```

  The compiler prints `warning: \`new i32\` at src/main.zag:2:13 in
  main is never freed (leak) — add an explicit \`free\` or \`defer
  free\`` at compile time. Warnings are advisory — the emitted code is
  unchanged, and the fix is always the user's explicit `free`:

  ```
  fun main() {
      let p = new i32(42);
      defer free(p);              # ✓ explicit ownership
  }
  ```

- **Escaping** — returned (directly or through a variable), stored into
  a parameter, a field, a global, or passed to any call. No warning;
  the caller/owner is responsible:

  ```
  fun make() -> *i32 { return new i32(7); }   # escaped — caller frees
  ```

- **Explicitly freed** — the site keeps its manual `free`/`defer free`
  form unchanged (no double-free).

- **Allocator-backed** — `new(arena, ...)` is never warned; the arena
  owns the lifecycle.

The analysis is deliberately conservative: any path by which a value
*could* escape suppresses the warning (a missed warning only means the
user's explicit free still applies; a false warning would cry wolf on a
legitimately-owned value). Values allocated inside closures or
compile-time blocks always count as escaping.

## Custom Allocators

`new(allocator, T(value))` allocates via a named allocator instead of the global page allocator:

```
let p = new(arena, i32(42));       # arena.create(i32){ .* = 42 }
```

The allocator name is emitted verbatim — `arena` must be a variable in scope whose type has a `.create(T)` method (the zig convention).

## Builtins

| Builtin | Emits | Returns |
|---|---|---|
| `alloc(N)` | `page_allocator.alloc(u8, N)` | `[]u8` |
| `size_of(T)` | `@sizeOf(T)` | `usize` (comptime) |
| `align_of(T)` | `@alignOf(T)` | `usize` (comptime) |
| `volatile_store(p, v)` | `@volatileStore(p, v)` | `void` |
| `volatile_load(p)` | `@volatileLoad(p)` | `T` |

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
