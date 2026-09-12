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

## Value Copy vs Intended Ownership

Every Zag type has a fixed size, and assignment copies those bytes. For
primitives that is exactly what you want:

```
let a: i32 = 10;
let b = a;          # a is copied — both a and b are valid
```

**Owning types are copyable too, and that is a hazard.** `String` is a
three-word `{ ptr, len, cap }` descriptor and a `*T` from `new` is a one-word
address. Copying either copies the *descriptor*, not the resource — the two
bindings then name the same buffer:

```
let s: String = String.from_str("hello");
var t: String = s;         # copies { ptr, len, cap }: t.ptr == s.ptr
t.deinit();                # releases the buffer BOTH bindings still point at
print("{s.as_str()}\n");   # USE-AFTER-FREE — segfault, no diagnostic

let p: *i32 = new i32(42);
let q: *i32 = p;           # q aliases p
free(p);                   # q now dangles
```

The language does **not** insert move semantics for these types and does not
diagnose the aliasing. The one rule the compiler does enforce is receiver
mutability: `deinit` and other mutating methods take `*String`, so they reject
a `let` binding — but that only forces you to write `var`; it does not stop two
`var` bindings from aliasing one buffer.

**The discipline:** exactly one binding owns a buffer. Hand callees a `*T` or a
borrowed view (`s.as_str()`), never the value, so no second owner is created —
and release through that owner once.

**Copy classification:**
- All primitive types (`i32`, `f64`, `bool`, `char`) are value types
- `*const T`, `*raw T`, `[]T`, `[]const T`, `?*T`, `?*const T`, `?*raw T` are non-owning views (safe to copy)
- Structs, bare enums, and `union`s are value types iff all fields/variants are
- `*T` (owning mutable pointer) and `String` are classified as *owning*, and an
  ownership checker is meant to reject copying them — **not implemented today**,
  so treat the classification as a naming convention and follow the discipline
  above.

## `as` — Type Conversion

```
let x: i32 = 42;
let y: f64 = x as f64;         # integer to float
let z: i16 = x as i16;         # truncating
let p: *raw u8 = ptr as *raw u8;  # pointer cast
```

**Memory:** `as` is a compile-time cast. No allocation. Some casts are unsafe (pointer to integer).
