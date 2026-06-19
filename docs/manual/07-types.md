# Types

Zag is statically typed. Every expression has a known type at compile time.

## Type Inference

```
let x = 42;           # inferred as i32
let y = 3.14;         # inferred as f64
let s = "hello";      # inferred as []const u8
```

You can add explicit annotations:

```
let x: i64 = 42;
let y: f32 = 3.14;
```

## Type Categories

| Category | Examples | Memory |
|----------|----------|--------|
| Primitives | `i32`, `f64`, `bool`, `char` | Stack, fixed size |
| Pointers | `*T`, `*const T`, `?*T` | Stack (pointer value) |
| Slices | `[]T`, `[]const T` | Stack (ptr + len) |
| Arrays | `[N]T` | Stack, fixed size |
| Structs | `struct { ... }` | Stack (by value) |
| Enums | `enum { ... }` | Stack (tagged union) |
| Tuples | `(T, U)` | Stack |
| SIMD | `f32x4`, `i8x32` | Stack (register) |

## Zero-Sized Types

`void` is the zero-byte unit type:

```
let _: void = {};
fun do_nothing() { }    # returns void
```

**Memory:** `void` occupies no stack space. `List<void>` is valid but degenerate.

## Type Aliases

```
type str = []const u8;
```

`str` and `[]const u8` are the same type. Aliases are transparent.

## Copy vs Move

Types that are `Copy` duplicate on assignment. Non-`Copy` types move:

```
let a: i32 = 10;
let b = a;          # a is copied — both a and b are valid

let s = new String("hello");
let t = s;          # s is moved — s is invalid after this
# print(*s);        # compile error: s is moved
```

**Copy rules:**
- All primitive types (`i32`, `f64`, `bool`, `char`) are `Copy`
- `*const T`, `*raw T`, `[]T`, `[]const T`, `?*T`, `?*const T`, `?*raw T` are `Copy`
- `*T` (owning mutable pointer) is NOT `Copy`
- `String` is NOT `Copy`
- Structs/enums are `Copy` iff all fields are `Copy`

## `as` — Type Conversion

```
let x: i32 = 42;
let y: f64 = x as f64;         # integer to float
let z: i16 = x as i16;         # truncating
let p: *raw u8 = ptr as *raw u8;  # pointer cast
```

**Memory:** `as` is a compile-time cast. No allocation. Some casts are unsafe (pointer to integer).
