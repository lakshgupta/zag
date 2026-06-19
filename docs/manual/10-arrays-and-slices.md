# Arrays and Slices

## Arrays — Fixed-Size, Stack-Allocated

```
let arr = [5]i32 { 1, 2, 3, 4, 5 };
let zeros = [10]i32 { 0 ... };      # fill: [0, 0, ..., 0]
let pattern = [4]i32 { 1, 2 ... };  # [1, 2, 1, 2]
```

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
let arr = [10]i32 { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
let slice: []i32 = arr[2..7];        # elements 2, 3, 4, 5, 6
let view: []const i32 = arr[..];     # full array view
let partial: []i32 = arr[5..];       # elements 5..9
```

**Memory:** Slicing produces a stack-allocated slice `{ ptr: *T, len: usize }`. It borrows the original array — no elements are copied. The slice is valid only while the array is alive.

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
