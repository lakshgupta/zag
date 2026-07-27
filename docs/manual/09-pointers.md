# Pointers

Pointers in zag behave like Zig's pointers: there is **no borrow checker in the core language**, and the programmer is responsible for memory validity. Safety tooling (`-Downership-check`, `-Dref-check`, `-fsanitize=memory`) is opt-in but catches common bugs at compile time or runtime.

This chapter walks through the pointer types zag exposes (per `docs/spec.md §3.2`), how to construct them (`new`, `&`, `new(<alloc>, …)`), how to read and write through them (`*p`, `p[i]`), and how slices (`[]T`) tie the whole surface together. See `examples/memory/pointers.zag` for a runnable tour.

## Pointer Types

| Type              | Meaning                                              |
|-------------------|------------------------------------------------------|
| `*T`              | Single-item pointer, mutable                         |
| `*const T`        | Single-item pointer, immutable                       |
| `?*T`             | Nullable, mutable; `null` is the null value; `Copy`  |
| `?*const T`       | Nullable, immutable; `Copy`                          |
| `?*raw T`         | Nullable, raw C-style; `Copy`                        |
| `*raw T`          | C-style raw pointer (no ownership, no null safety); use only inside `unsafe` |
| `[]T`             | Slice, mutable:  layout `{ ptr: *T, len: usize }`   |
| `[]const T`       | Slice, immutable: layout `{ ptr: *const T, len }`   |

Only `*T` (non-nullable, mutable) and `String` are not `Copy` — they move on assignment. Every other pointer form is a non-owning view and copies its value. Pointers are first-class in zag: they can be stored in arrays, structs, slices, returned from functions, and passed as arguments.

## Allocating a pointer: `new`

`new` allocates on the heap and returns an owning pointer. See `docs/20-memory.md` for the full heap-allocation surface.

```
let p = new i32(42);        # global allocator (default)
defer free(p);              # release via destroy on the global allocator

let q = new(arena, Vec3 { x: 1.0, y: 2.0, z: 3.0 });  # arena allocator
```

`free(ptr)` releases a `new`-allocated pointer back to the global allocator. **Do not mix**: freeing an arena-allocated pointer with global `free` is undefined behavior, and freeing a stack address (`&local`) is also undefined.

## Taking an address: `&x`

The unary `&` operator returns a pointer to a value. The resulting type depends on whether the source binding is mutable (`var`) or immutable (`let`/`const`):

```
var   mutable:   i32 = 10;
let   read_only: i32 = 20;

let p_mut:  *i32      = &mutable;        # *i32      (mutable)
let p_ro:   *const i32 = &read_only;     # *const i32 (immutable)
```

`&x` is **only valid on lvalues** — a variable or a struct field, not a literal or a temporary expression. The compiler emits `&<operand>` directly in the generated zig, so the layout matches one-to-one.

Binary `&` is bitwise AND and not affected by the address-of addition; the parser disambiguates by syntactic context — prefix position routes to address-of, infix position routes to bitwise AND. Both share the same `.amp` TokenTag in the lexer; the dispatch lives entirely in the parser.

## Dereferencing: `*p`

`*p` reads or writes through a pointer:

```
let v: i32 = *p;        # read
*p = 100;                # write
```

The dereferenced type is the pointee's type — `*i32` dereferences to `i32`. The compiler emits `<pointer>.*` in zig (postfix deref), so the AST shape round-trips directly. `*p = expr` is the canonical way to mutate state through a borrowed pointer without naming the underlying variable.

## Slicing: `arr[a..b]`

Slicing produces a `[]T` view into an underlying `[N]T` array without copying:

```
let arr: [5]i32 = [5]i32 { 1, 2, 3, 4, 5 };
let s:    []i32  = arr[1..4];  # elements at indices 1, 2, 3
let all:  []i32  = arr[..];    # full array view
let tail: []i32  = arr[3..];   # from index 3 to end
let head: []i32  = arr[..3];   # from start to index 2 (exclusive)
let incl: []i32  = arr[1...3]; # INCLUSIVE — equivalent to arr[1..4]
```

A slice's layout is `{ ptr: *T, len: usize }` — same as Zig's. You can index into a slice (`s[1]`), pass it to a function (`fun sum(s: []i32) -> i32`), iterate it (`for v in slice { … }`), or store it in a struct. Slicing is zero-copy.

The four slicing shapes:

| Source       | Meaning                                             |
|--------------|-----------------------------------------------------|
| `arr[a..b]`  | Half-open `[a, b)` — excludes index `b`             |
| `arr[a...b]` | Inclusive `[a, b]` — includes index `b` (integer slices only) |
| `arr[a..]`   | From index `a` to the end of the array              |
| `arr[..b]`   | From start to index `b - 1`                         |
| `arr[..]`    | Whole-array view                                    |

## Nullable pointers

Any pointer type can be made nullable by prefixing `?`:

```
let p:   ?*i32       = null;        # initialised to no pointer
let q:   ?*const i32 = &x;          # can hold a real pointer OR null
let r:   ?[]const u8  = null;       # nullable slice
```

Nullable pointers are `Copy` — assigning one to another duplicates the value (including the `null` case). Reading a `null` value is a runtime error (it would deref a null pointer). Use a `match` against the scrutinee or pass the nullable pointer to a function that handles the `null` arm explicitly.

## Raw pointers (`*raw T`)

Raw pointers (`*raw T`) are C-style: no ownership, no null safety, no alignment guarantee. **All reads and writes through `*raw T` require an `unsafe` block**:

```
unsafe {
    let p: *raw i32 = alloc(4) as *raw i32;
    *p = 42;
}
```

Pointer arithmetic on `*raw T` is also `unsafe`:

```
unsafe {
    let q = p.add(5);     # p + 5 * sizeof(T)
    let n = q.offset(p);  # (q - p) / sizeof(T)
}
```

Use `*raw T` only for FFI interop, lock-free algorithms, or other low-level code that has no safe alternative.

> **Implementation note** (zig-fallback): the `.add` / `.offset` method
> calls on `*raw T` are recognised by zag's parser as ordinary
> `.method_call` nodes; the codegen layer (`src/codegen/expr.zig`'s
> `.method_call` arm) rewrites them into the equivalent zig intrinsics
> at compile time:
>
> ```
> p.add(N)     -> @as(@TypeOf(p), @ptrFromInt(@intFromPtr(p) + N * @sizeOf(@typeInfo(@TypeOf(p)).pointer.child)))
> q.offset(p)  -> (@intFromPtr(q) - @intFromPtr(p)) / @sizeOf(@typeInfo(@TypeOf(q)).pointer.child)
> ```
>
> The `@typeInfo(@TypeOf(p)).pointer.child` strip is critical — it
> extracts the **pointee type** (`u8` for `p: *raw u8`) instead of the
> pointer type (`*raw u8` itself, which has `@sizeOf` = 8 on 64-bit).
> Without the strip, `p.add(2)` on `p: *raw u8` would advance by 16
> bytes instead of 2, and `q.offset(p)` would divide by 8 instead of
> 1 — producing element-stride counts that are wrong by a factor of
> `sizeof(pointer)`.
>
> Wrong-arity calls (anything other than exactly 1 argument) and
> method names other than `add` / `offset` fall through to the
> verbatim `p.foo(args)` emission so zig can report
> `no method named 'foo'` with high-quality diagnostics. The
> `unsafe` wrapper is purely a user-side convention — zag does not
> enforce any special semantics on its contents.

## What zag does NOT catch

The "no hidden control flow" principle means zag is explicitly permissive at the type level and pushes safety to optional, opt-in tools. The classes of bug below are common but require explicit tooling to surface:

| Class of bug                                       | Behavior in source language | Tool to detect |
|----------------------------------------------------|------------------------------|----------------|
| Use-after-free of `*T` or `*raw T`                 | Allowed                      | `-fsanitize=memory`                              |
| Double-free of an owning `*T`                      | Allowed                      | `-Downership-check` or `-fsanitize=memory`       |
| Leak of an owning `*T` (never freed)               | Allowed                      | `-Dleak-check` or `-fsanitize=leak`             |
| Aliasing two `*T` (mutable)                        | Allowed                      | Programmer discipline; v2 borrow-check pass     |
| Dangling `&local` past the scope it points into    | Allowed                      | `-Dref-check` (intraprocedural)                  |
| Misaligned load/store via `*raw T`                 | Allowed, UB on most targets  | `-fsanitize=undefined`                           |

The default `zag check` profile runs `-Downership-check` and `-Dleak-check` automatically — these two checks are the cheapest to run and they compensate for the absence of a borrow checker.

## Worked example

```
fun main() {
    var counter: i32 = 0;
    let p: *i32 = &counter;

    *p = 1;
    *p = *p + 1;

    let data: [4]i32 = [4]i32 { 10, 20, 30, 40 };
    let view: []const i32 = data[1..3];
    for v in view {
        print("{v} ");
    }
    print("\n");
}
```

See `examples/memory/pointers.zag` for the full runnable example demonstrating mutable / const address-of, deref, every slicing form, and nullable pointer initialisation.
