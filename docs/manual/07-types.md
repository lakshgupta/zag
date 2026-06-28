# Types

Zag is statically typed. Every expression has a known type at compile time.

## Type Inference

The compiler infers the binding type from the initializer **only when the initializer is a literal expression**. Every other form requires an explicit `: T` annotation. See [Variables → Carve-Out: Literal Initializers](04-variables.md#carve-out-literal-initializers) for the canonical rule and the full list of 11 literal Expr kinds accepted without annotation.

```
let x: i32 = 42;             # annotated (works for any initializer)
let y = 42;                  # inferred — int literal coerces to i32
let z: f64 = 3.14;           # annotated
let t = 3.14;                # inferred — float literal coerces to f64
let s = "hello";             # inferred — string literal coerces to []const u8

# Non-literal initializers REQUIRE explicit : T — inference does not apply:
let sum: i32 = a + b;        # binary expression — : T required
# let sum = a + b;           compile error: missing : T
```

You can always add an explicit annotation to a literal initializer — the annotation overrides the inferred default:

```
let x: i64 = 42;             # u64, not the inferred i32
let y: f32 = 3.14;           # f32, not the inferred f64
```

## Type Categories

| Category | Examples | Memory |
|----------|----------|--------|
| Primitives | `i32`, `f64`, `bool`, `char` | Stack, fixed size |
| Pointers | `*T`, `*const T`, `?*T` | Stack (pointer value) |
| Slices | `[]T`, `[]const T` | Stack (ptr + len) |
| Arrays | `[N]T` | Stack, fixed size |
| Structs | `struct { ... }` | Stack (by value) |
| Enums | `enum { ... }` | Stack (bare enumeration — tag only) |
| Unions | `union { ... }` | Stack (tagged union — tag + max payload) |
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
- Structs, bare enums, and `union`s are `Copy` iff all fields/variants are `Copy`

## `as` — Type Conversion

```
let x: i32 = 42;
let y: f64 = x as f64;         # integer to float
let z: i16 = x as i16;         # truncating
let p: *raw u8 = ptr as *raw u8;  # pointer cast
```

**Memory:** `as` is a compile-time cast. No allocation. Some casts are unsafe (pointer to integer).
