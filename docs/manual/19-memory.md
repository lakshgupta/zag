# Memory Model

Zag has **no garbage collector**. All memory management is explicit.

## Stack vs Heap

| Storage | Types | Lifetime | Deallocation |
|---------|-------|----------|--------------|
| Stack | Primitives, structs, arrays, tuples, slices | Scope exit | Automatic |
| Heap | `new T(...)` | Until `free` | Manual |

## Allocation with `new`

```
let p = new i32(42);             # heap allocate single value
let arr = new [10]i32 { 0 ... }; # heap allocate array
let s = new String("hello");     # heap allocate string
```

`new` returns an owning `*T`. Must be `free`d.

## Deallocation with `free`

```
let p = new i32(42);
defer free(p);            # freed when scope exits

let s = new String("hello");
defer free(s);
```

**Memory:** `free` deallocates the heap memory. The pointer becomes invalid.

## Custom Allocators

```
let arena = Arena.new();
let p = new(arena, i32(42));     # arena allocation
defer arena.free(p);

# Or bulk-free the entire arena:
arena.free_all();                 # O(1) reset
```

**Memory:** Arena allocators are bump allocators. `free_all` resets the entire arena in O(1) — ideal for game frames, HTTP requests.

**Warning:** `free_all()` does **not** recursively free inner allocations. Types like `String`, `List<T>`, or `Map<K,V>` contain heap-allocated buffers that are **leaked** by `free_all()`. Either call per-element cleanup before `free_all()`, or use arena only for flat types (`i32`, structs whose `*T` fields point into the same arena, POD arrays). See spec §5.1.

## Ownership Rules

1. Each `new` has a single owner
2. Assignment moves ownership for non-`Copy` types
3. `Copy` types duplicate on assignment

```
let s = new String("hello");
let t = s;          # s is moved — s is now invalid
free(t);            # only t is valid
```

## Ownership Checking

The default `zag check` profile runs `-Downership-check` and `-Dleak-check`:

```
zag check              # runs ownership + leak checks
zag check --strict     # all checks + runtime sanitizers
```

## Common Patterns

### Pattern 1: defer free

```
fun process() {
    let buf = alloc(1024);
    defer free(buf as *raw c_void);

    # use buf...
}
```

### Pattern 2: errdefer for partial init

```
fun build() -> Result<Config, Error> {
    let a = compute()?;
    errdefer free(a);

    let b = compute()?;
    # b is returned — errdefer for a does NOT run
    return Ok(Config { a: a, b: b });
}
```

### Pattern 3: Arena for scoped lifetimes

```
async fun handle_request(conn: TcpConn) {
    var arena = Arena.new();
    defer arena.free_all();      # O(1) cleanup

    let req = new(&arena, Request { ... });
    let resp = process(req);
    conn.write(resp);
}
```

### Pattern 4: Rc/Arc for shared ownership

```
import std.mem

let shared = new Arc<Data> { ... };
let clone = Arc.clone(shared);    # reference count increment
defer Arc.release(clone);         # reference count decrement
```

## Safety Tooling

| Check | Flag | Detects |
|-------|------|---------|
| Ownership | `-Downership-check` | Double-free, use-after-move |
| Leak | `-Dleak-check` | Missing `free` calls |
| Bounds | `-Dbounds-check` | Out-of-bounds access |
| Ref | `-Dref-check` | Dangling references |
| Init | `-Dinit-check` | Uninitialized reads |
| Thread | `-Dthread-safety` | Data races |

## Unsafe Operations

```
unsafe {
    let p: *raw i32 = alloc(4) as *raw i32;
    *p = 42;                          # raw pointer dereference
    let val = *p;
    free(p as *raw c_void);
}
```

Unsafe is required for:
- Dereferencing `*raw T`
- Pointer arithmetic
- Pointer-to-integer casts
- `transmute`
- C FFI calls
