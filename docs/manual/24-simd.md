# SIMD and Inline Assembly

## Implementation status

| Surface | Status |
|---|---|
| Vector types (`f32x4` … `u64x2`, sub-byte `i4x16` … `u8x64`) | ✅ — maps to zig's `@Vector(N, T)` via the transparent-alias table |
| Vector literals `f32x4 { ... }` (positional) | ✅ — emits `@Vector(4, f32){ ... }` |
| Element-wise `+ - * /` | ✅ — lowers to zig's native vector ops verbatim |
| `as` conversions (array ↔ vector) | ✅ — zig coerces both directions |
| `sum()` / `max()` / `min()` / `dot(x)` | ✅ — rewrite to `@reduce(.Add/.Max/.Min, ...)` (dot = element-wise product + horizontal add) |
| `bf16x8` | ⚠️ maps to `@Vector(8, f16)` — zig 0.16 has no `bf16` type |
| Inline assembly block | ⏸️ syntax not yet implemented (needs a zag-side `asm` design mapping to zig's asm) |
| `import std.arch.x86.avx2` intrinsics | ⏸️ zig 0.16 removed `std.arch.x86` entirely — the `_mm256_*` pass-through target no longer exists |

## SIMD Vector Types

First-class types that map to target ISA registers:

```
f32x4       f32x8       f64x2       f64x4
f16x8       bf16x8
i8x16       i16x8       i32x4       i64x2
u8x16       u16x8       u32x4       u64x2
```

Syntax: `{elem}{width}x{lanes}`

## SIMD Literals

```
let a = f32x4 { 1.0, 2.0, 3.0, 4.0 };
let b = f32x4 { 5.0, 6.0, 7.0, 8.0 };
let zeros = i8x16 { 0 ... };
```

**Memory:** Stack-allocated, maps to target SIMD register (16-64 bytes).

## Element-Wise Operations

Element-wise operations (`+`, `-`, `*`, `/`), comparisons, and `select` guarantee a **single hardware instruction** on targets with the required ISA extension. No loops, no library calls:

```
let c = a + b;         # element-wise add
let d = a * b;         # element-wise multiply
let mask = a > b;      # comparison mask
let selected = select(mask, a, b);  # per-lane select
```

## Horizontal Reductions

```
let sum = c.sum();     # f32
let max = c.max();     # f32
let min = c.min();     # f32
```

## Array <-> SIMD Conversion

```
let arr = [4]f32 { 1.0, 2.0, 3.0, 4.0 };
let vec: f32x4 = arr as f32x4;    # array to SIMD
let back: [4]f32 = vec as [4]f32; # SIMD to array
```

**Memory:** `as` is a reinterpret cast. No allocation, no copy. Lane count must match exactly.

## AI Inference Pattern

```
# bf16 multiply with f32 accumulation
fun mul_bf16(a: [8]f32, b: [8]f32) -> [8]f32 {
    let a_bf: bf16x8 = a as bf16x8;
    let b_bf: bf16x8 = b as bf16x8;
    let prod: bf16x8 = a_bf * b_bf;    # hardware BF16 FMA
    return prod as [8]f32;
}

# int8 GEMM with VNNI
fun dot_int8(a: [32]i8, w: [32]i8) -> i32 {
    let a_vec: i8x32 = a as i8x32;
    let w_vec: i8x32 = w as i8x32;
    let prod: i32x32 = a_vec.dot(w_vec);  # hardware int8 dot product
    return prod.sum();
}
```

**Memory:** SIMD operations are stack-only. No allocation. Hardware dispatch is automatic.

## Sub-Byte Types

For int4/int8 AI inference:

```
i4x16      u4x16      i4x32      u4x32
i8x16      i8x32      i8x64
u8x32      u8x64
```

## Inline Assembly

```
asm {
    # x86-64 AVX2 FMA
    ("vfmadd231ps {dst}, {src}, {acc}"
     : {dst} = "=x"(out)
     : {src} = "x"(a), {acc} = "x"(b)
     :
    )
}
```

**Constraint classes:** `"r"` (GPR), `"x"` (SSE/AVX), `"=r"` (output), `"+r"` (read-write), `"m"` (memory), `"i"` (immediate). Inline assembly may not appear in `const` blocks.

**Memory:** Inline assembly is stack-only. No allocation.

## Compiler Intrinsics

```
import std.arch.x86.avx2

let result = avx2._mm256_fmadd_ps(x, y, z);  # guaranteed FMA
```

## SIMD Methods (v1)

| Method | Description |
|--------|-------------|
| `sum()` | Horizontal sum |
| `max()` | Maximum element |
| `min()` | Minimum element |
| `dot(other)` | Dot product (widens to i32 for sub-byte) |
| `+`, `-`, `*`, `/` | Element-wise ops |
| `==`, `!=`, `<`, `>` | Element-wise comparisons |
