# Primitive Types

The canonical source of truth for primitive-type sizes, ranges, and representation. For literal syntax (how to *write* `42`, `0xFF`, `1_000_000`, `'\n'`, etc.), see [Literals](03-literals.md). For the type system that those literals feed into — type inference, `Copy` vs move, `as` conversions, struct embedding — see [Types](07-types.md).

> All primitive types in Zag are **statically typed**: every `let x = 42` binding has exactly one compile-time-resolved type, every `*T` dereference is type-checked, and every `as` conversion is verified at compile time. There is no implicit numeric promotion in overload resolution (unlike Julia or C++), no auto-boxing, and no runtime type dispatch for primitive operations — the compiler emits native instructions for every primitive type on every target.

## Integers

| Type | Size | Range |
|------|------|-------|
| `i8` | 1 B | -128 to 127 |
| `i16` | 2 B | -32,768 to 32,767 |
| `i32` | 4 B | -2^31 to 2^31-1 |
| `i64` | 8 B | -2^63 to 2^63-1 |
| `i128` | 16 B | -2^127 to 2^127-1 |
| `u8` | 1 B | 0 to 255 |
| `u16` | 2 B | 0 to 65,535 |
| `u32` | 4 B | 0 to 2^32-1 |
| `u64` | 8 B | 0 to 2^64-1 |
| `u128` | 16 B | 0 to 2^128-1 |
| `isize` | ptr B | pointer-width signed |
| `usize` | ptr B | pointer-width unsigned |

```
let a: i32 = 42;
let b: u64 = 100;
let c: usize = 0xFF;
```

**Memory:** Stack-allocated, fixed size. No heap allocation. Arithmetic wraps silently on overflow (use `-fsanitize=undefined` to catch).

## Floats

| Type | Size | Notes |
|------|------|-------|
| `f16` | 2 B | IEEE 754 half (library-only in v1) |
| `f32` | 4 B | IEEE 754 single |
| `f64` | 8 B | IEEE 754 double |
| `bf16` | 2 B | Brain Float 16 (AI compute) |

```
let pi: f64 = 3.141592653589793;
let small: f32 = 1.0e-10;
```

**Memory:** Stack-allocated. `f16` and `bf16` are library-only for scalar ops — use SIMD vectors for hardware acceleration.

## Boolean

```
let flag: bool = true;
```

**Memory:** 1 byte on the stack.

## Char

```
let letter: char = 'A';
let emoji: char = '\u2764';
```

**Memory:** 4 bytes (Unicode scalar value).

## void

```
let _: void = {};          # unit value
fun do_nothing() -> void { # explicit return type
    return;
}
```

**Memory:** Zero bytes. Occupies no stack space.
