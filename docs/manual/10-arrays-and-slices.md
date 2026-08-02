# Arrays and Slices

## Arrays — Fixed-Size, Stack-Allocated

```
let arr = [5]i32 { 1, 2, 3, 4, 5 };
let zeros = [10]i32 { 0 ... };      # fill: [0, 0, ..., 0]
let pattern = [4]i32 { 1, 2 ... };  # [1, 2, 1, 2]
```

### Inferred-element arrays (shorthand)

When the element type is already known from context — a typed binding
LHS or a call argument — the type is not repeated:

```
let numbers: [5]i32 = { 10, 20, 30, 40, 50 };   # instead of [5]i32 { ... }
let s: i32 = sum3({ 1, 2, 3 });                 # call-arg coercion
let single: [1]i32 = { 5, };                    # trailing comma for one element
```

The `{ ... }` form compiles to zig's anonymous-struct literal `.{ ... }`,
which coerces to the expected array, slice, or tuple type. `{ ... }` with
statement keywords (`let`, `if`, `while`, ...) or a single expression with
no comma stays a **block expression** (`{ let x = 5; x }`); fill (`...`)
and progression need a size, so those keep the typed `[N]T { ... }` form.

**Memory:** Arrays are value types, stack-allocated. `[5]i32` is 20 bytes on the stack. No heap allocation.

## Array Access

```
let first = arr[0];     # read
arr[0] = 10;            # write
```

Bounds checking is off by default. Enable with `-Dbounds-check`.

## Array Length

```
let len = arr.len;      # compile-time constant: 5
```

## Slicing — Borrowing a View

```
var arr = [10]i32 { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
let slice: []i32 = arr[2..7];        # elements 2, 3, 4, 5, 6
let view: []const i32 = arr[..];     # full array view
let partial: []i32 = arr[5..];       # elements 5..9
```

`arr` is `var` (not `let`) here so the `[]i32`-annotated slices carry the intended mutable-element view. For a `let`-bound source the slice type would be `[]const T` instead — see the note below.

**Memory:** Slicing produces a stack-allocated slice `{ ptr: *T, len: usize }`. It borrows the original array — no elements are copied. The slice is valid only while the array is alive.

### Note: `let`-Bound Sources Require `[]const T`

The slice expression `arr[a..b]` yields its type directly from the source's pointee. When `arr` is `let`-bound, the source's pointee is `*const T`, so the slice itself has type `[]const T` — there is no further coercion to `[]T`:

```
let arr: [3]i32 = [3]i32 { 1, 2, 3 };
let view: []const i32 = arr[1..3];   # ✓ matches the slice-expression type
let bad:  []i32       = arr[1..3];   # ✗ zig: expected []i32, found []const i32
```

Zig will not widen `[]const T` to `[]T` because doing so would let you write through a pointer to const memory (undefined behaviour). Reading through either slice type is interchangeable.

To get a `[]T`-typed slice (mutable element access), declare the source as `var`:

```
var arr: [3]i32 = [3]i32 { 1, 2, 3 };
let view: []i32 = arr[1..3];   # ✓ var-source slice expression has type []i32
```

Caveat: `var` makes the **binding** reassignable (`arr = other;`) in addition to letting the slice's elements be mutable. If you only want the latter (mutable elements, fixed binding), you must copy into a `var` source or accept the read-only view — there is no "let-binding, mutable-element slice" mode.

## Slice Layout

```
[]T = { ptr: *T, len: usize }        # 16 bytes on 64-bit
[]const T = { ptr: *const T, len: usize }
```

## Multi-Dimensional Arrays

```
let matrix = [3][3]i32 {
    [3]i32 { 1, 0, 0 },
    [3]i32 { 0, 1, 0 },
    [3]i32 { 0, 0, 1 },
};

let val = matrix[1][2];     # 0
```

**Memory:** `[3][3]i32` is 36 bytes on the stack. Row-major layout.

## Array as SIMD

Arrays can be cast to SIMD vectors:

```
let arr = [4]f32 { 1.0, 2.0, 3.0, 4.0 };
let vec: f32x4 = arr as f32x4;    # exact lane count required
let back: [4]f32 = vec as [4]f32; # convert back
```

**Memory:** `as` between array and SIMD is a reinterpret cast. No allocation, no copy.

## Common Patterns

```
# Initialize with default values
var buf = [1024]u8 { 0 ... };

# Fill with a computed value
var lut = [256]u32 { 0 ... };
for i in 0..256 {
    lut[i] = (i * 2654435761) as u32;
}

# Pass to SIMD kernel
let input = [8]f32 { ... };
let result = process(input as f32x8);
```
