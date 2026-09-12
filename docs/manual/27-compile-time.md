# Compile-Time Execution

## `const` Variables

```
const PI: f64 = 3.141592653589793;
const MAX_SIZE: usize = 1024;
const MASK: u32 = 0xFF;
```

**Memory:** Embedded in the binary as static constants. No stack or heap allocation.

A module-level `const` is private to its module. Write `pub const` to
export it, so importers can bind it by name (`import std.fs.{PAGE_SIZE}`)
and use it where a compile-time value is required — including array
lengths:

```zag
# lib.zag
pub const PAGE_SIZE: usize = 4096;

# main.zag
import lib.{PAGE_SIZE}
var page: [PAGE_SIZE]u8 = undefined;
```

## `const` Blocks

Arbitrary code evaluated at compile time:

```
const TABLE: [256]u32 = const {
    var t: [256]u32 = undefined;
    for i in 0..256 {
        t[i] = (i * 2654435761) as u32;
    }
    return t;
};
```

**Memory:** The `const` block is evaluated by the compiler's interpreter. The result is embedded in the binary.

## `const` Type Parameters

```
fun fill<T, const N: usize>(val: T) -> [N]T {
    var out: [N]T = [N]T { val ... };
    return out;
}

let zeros = fill<i32, 10>(0);    # monomorphized for N=10
```

**Memory:** Each `N` value produces a separate monomorphized function. No runtime overhead.

## Compile-Time Builtins

| Builtin | Returns | Example |
|---------|---------|---------|
| `fields(T)` | Field descriptors | `fields(Vec3)` → `[{name: "x", type: f64, offset: 0}, ...]` |
| `size_of(T)` | Size in bytes | `size_of(i32)` → `4` |
| `align_of(T)` | Alignment | `align_of(f64)` → `8` |
| `type_name(T)` | Type name | `type_name(Vec3)` → `"Vec3"` |

## Compile-Time Serialization

```
fun serialize<T>(val: *const T, buf: *raw u8) -> usize {
    var offset: usize = 0;
    const flds = fields(T);
    for fld in flds {
        let src = (val as *raw u8).add(fld.offset);
        for j in 0..fld.size {
            buf[offset] = src.add(j).*;
            offset += 1;
        }
    }
    return offset;
}
```

## Rules

- `const` blocks can call only other `const`-evaluable functions
- A `fun` with no I/O, no allocation, and no FFI is implicitly `const`-evaluable
- I/O, heap allocation, and syscalls are forbidden inside `const` blocks
- `const type` allows passing types as values for metaprogramming

## Use Cases

- Trigonometric lookup tables
- State-machine transition tables
- Encoding tables (Base64, CRC32)
- Compile-time SIMD shuffle masks
- Hash tables (Knuth multiplicative hash)
