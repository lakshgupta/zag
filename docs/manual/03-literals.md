# Literals

Zag is **statically typed**: every literal has a known type at compile time. Integer literals default to `i32`, float literals to `f64`, character literals to `char`, boolean literals to `bool`, and string/byte-string literals to `[]const u8`. Explicit annotations and explicit-type literals override the defaults. The number in `0xFF`, the underscore in `1_000_000`, and the prefix in `b"hello"` are all literal syntax — they do not change the type, only the form of the value. See [Types](07-types.md) for the type system and [Primitives](08-primitives.md) for per-type sizes, ranges, and memory representation.

> Statically-typed literals let the compiler emit native machine code for every primitive operation with no boxing, no runtime tag dispatch, and no allocated temporaries for value-typed bindings. The same `let x = 42` instruction sequence produces a single `mov` on every target — the type is resolved at compile time and never revisited at runtime.

## Integer Literals

```
let a = 42;          # decimal — i32
let b = 0xFF;        # hex — i32
let c = 0o77;        # octal — i32
let d = 0b1010;      # binary — i32
let e = 1_000_000;   # decimal with underscores for readability — i32
let f: u64 = 100;    # explicit type annotation overrides the default
```

Sizes and signedness ranges are documented in [Primitives](08-primitives.md). Arithmetic wraps silently on overflow; use `-fsanitize=undefined` to surface it.

## Float Literals

```
let pi    = 3.14;        # f64 by default
let speed = 1.0e10;      # scientific notation — f64
let tiny: f32 = 1.0e-10; # explicit type annotation
let hex   = 0x1.0p10;    # hex float (IEEE 754 binary16/32/64 form)
```

Sizes and hardware-acceleration notes are documented in [Primitives](08-primitives.md) and [SIMD](23-simd.md).

## Boolean Literals

```
let on  = true;     # bool
let off = false;    # bool
```

## Character Literals

```
let letter    = 'a';        # char
let newline   = '\n';       # char
let null_char = '\x00';     # char (NUL byte)
let heart     = '\u2764';   # char (UTF-8 multi-byte scalar)
```

`char` is a 4-byte Unicode scalar value (see [Primitives](08-primitives.md)).

## String Literals

String literals produce `[]const u8` — a borrowed view with no allocation:

```
let greeting = "hello";          # []const u8 — borrowed, no allocation
let owned    = new String("hello"); # String — heap-allocated, must be free'd
```

**Memory:**
- `"hello"` — stack-allocated pointer + length. No heap allocation. The character bytes live in static read-only memory.
- `new String("hello")` — heap allocation via global allocator. Must be `free`d.

String interpolation:

```
let name = "world";
let msg = "hello, {name}";     # String interpolation
print("{msg}\n");
```

**Memory:** Interpolation allocates a new `String` via `Display.write`. Inside `print` / `eprint`, interpolation is **zero-alloc** — values are written directly to the writer buffer. Outside `print`, use `String.with_writer(|w| { ... })` for zero-alloc formatting into a pre-allocated buffer.

## Byte String Literals

```
let bytes = b"hello";   # []u8 — mutable byte slice (see spec §2.2)
```

**Memory:** The slice header (`ptr: *u8`, `len: usize`) is stack-allocated; the bytes live in the binary's rodata. The slice type is `[]u8` (mutable); the underlying storage is read-only memory and writing through the pointer is undefined behavior on most targets — use it as a read-only byte view, or `memcpy` it into a mutable buffer first if mutation is needed.

## Array Literals

```
let arr   = [3]i32 { 1, 2, 3 };
let zeros = [5]i32 { 0 ... };     # fill: [0, 0, 0, 0, 0]
let ones  = [4]i32 { 1, 2 ... };  # [1, 2, 1, 2]
```

**Memory:** Fixed-size, value-typed, stack-allocated. No heap allocation. Array element count is part of the type (`[3]i32` is a distinct type from `[4]i32`). See [Arrays and Slices](10-arrays-and-slices.md) for slicing, indexing, and SIMD conversion.

## Tuple Literals

```
let point  : (i32, i32)    = (10, 20);    # 2-tuple of i32
let mixed                  = (42, 3.14, true); # inferred: (i32, f64, bool)
let unit                   = ();          # void / unit tuple — zero-sized
let named                  = (x: 10, y: 20); # field names compile away; same ABI as (10, 20)
```

**Memory:** Stack-allocated. Size is sum of element sizes (with padding). Names vanish at the ABI level — `(x: 10, y: 20)` and `(10, 20)` are identical in memory. See [Tuples](14-tuples.md) for destructuring.

## Null and Undefined

```
let p: ?*i32 = null;       # nullable pointer — null value
let x: i32 = undefined;    # uninitialized — reading is UB
```

**Memory:** `null` is a valid value for nullable pointer types (`?*T`, `?*const T`, `?*raw T`). `undefined` is explicitly uninitialized memory — never read it. Numeric and boolean types cannot be `null`; use `Option<T>` if you need a possibly-absent value of a value type.

## SIMD Vector Literals

```
let v     = f32x4 { 1.0, 2.0, 3.0, 4.0 };
let zeros = i8x16 { 0 ... };
```

**Memory:** Value-typed, stack-allocated, maps to the target SIMD register (16-64 bytes depending on lane count). Lane count and element type are part of the type — `f32x4` and `f32x8` are distinct. See [SIMD](23-simd.md) for the type taxonomy and hardware acceleration notes.
