# Pointers

## Pointer Types

| Type | Meaning | Copy? |
|------|---------|-------|
| `*T` | Single-item mutable pointer | No (owning) |
| `*const T` | Single-item immutable pointer | Yes |
| `?*T` | Nullable mutable pointer | Yes |
| `?*const T` | Nullable immutable pointer | Yes |
| `?*raw T` | Nullable raw pointer | Yes |
| `*raw T` | C-style raw pointer | Yes |
| `[]T` | Slice (ptr + len) | Yes |
| `[]const T` | Immutable slice | Yes |

## Taking Addresses

```
var x: i32 = 10;
let p: *i32 = &x;          # mutable pointer to x
let cp: *const i32 = &x;   # immutable pointer to x
```

**Memory:** `&` produces a pointer to a stack-allocated value. The pointer is valid only while the referent is alive. No allocation.

## Dereferencing

```
let val: i32 = *p;         # read through pointer
*p = 42;                   # write through pointer (requires *T)
```

**Memory:** No allocation. Direct memory access through the pointer.

## Nullable Pointers

```
let p: ?*i32 = null;        # null pointer
let q: ?*i32 = &x;          # non-null pointer

if let Some(ptr) = p {
    print("{*ptr}\n");      # safe to dereference
}
```

**Memory:** `?*T` is the same size as `*T` (one extra bit for null, packed into the pointer).

## Raw Pointers

```
let p: *raw i32 = alloc(4) as *raw i32;
unsafe {
    *p = 42;
    let val = *p;
}
```

**Memory:** Raw pointers have no ownership semantics. Use only inside `unsafe`.

## Pointer Arithmetic

```
unsafe {
    let q = p.add(5);     # p + 5 * sizeof(T)
    let r = p.sub(2);     # p - 2 * sizeof(T)
    let n = q.offset(p);  # (q - p) / sizeof(T)
}
```

## Slicing

```
let arr = [10]i32 { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
let slice: []i32 = arr[2..7];     # elements 2..6
let view: []const i32 = arr[..];  # full view
```

**Memory:** Slicing produces a stack-allocated slice `{ ptr: *T, len: usize }`. No copy of elements.

## Memory Layout

```
[]T = { ptr: *T, len: usize }      # 16 bytes on 64-bit
?*T = pointer with null bit         # 8 bytes on 64-bit
```

## Ownership

Pointers returned by `new` are owning:

```
let p = new i32(42);     # owning pointer
defer free(p);            # must free

let q = &local;           # non-owning — no free needed
```

**Memory:** Owning pointers (`new`) must be `free`d. Non-owning pointers (`&`, slicing) are valid only while the referent lives. The `-Downership-check` flag catches double-free and use-after-move.
