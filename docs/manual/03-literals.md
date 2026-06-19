# Literals

## Integer Literals

```
let a = 42;          # decimal
let b = 0xFF;        # hex
let c = 0o77;        # octal
let d = 0b1010;      # binary
let e = 1_000_000;   # underscores for readability
```

**Memory:** Integers are stack-allocated, fixed-size values. `i32` is 4 bytes, `u64` is 8 bytes. No heap allocation.

## Float Literals

```
let pi = 3.14;
let speed = 1.0e10;
let hex_float = 0x1.0p10;
```

**Memory:** Floats are stack-allocated. `f32` is 4 bytes, `f64` is 8 bytes.

## Boolean Literals

```
let on = true;
let off = false;
```

**Memory:** 1 byte on the stack.

## Character Literals

```
let letter = 'a';
let newline = '\n';
let null_char = '\x00';
let heart = '\u2764';
```

**Memory:** 4 bytes (Unicode scalar value).

## String Literals

String literals produce `[]const u8` (a borrowed view):

```
let greeting = "hello";         # []const u8 — borrowed, no allocation
let owned = new String("hello"); # String — heap allocated
```

**Memory:**
- `"hello"` — stack-allocated pointer + length. No heap allocation.
- `new String("hello")` — heap allocation via global allocator. Must be `free`d.

String interpolation:

```
let name = "world";
let msg = "hello, {name}";     # String interpolation
print("{msg}\n");
```

**Memory:** Interpolation allocates a new `String` via `Display.write`. Use `with_writer` for zero-alloc formatting.

## Byte String Literals

```
let bytes = b"hello";    # []u8 literal
```

**Memory:** Stack-allocated slice pointing to static data.

## Array Literals

```
let arr = [3]i32 { 1, 2, 3 };
let zeros = [5]i32 { 0 ... };     # fill: [0, 0, 0, 0, 0]
let ones = [4]i32 { 1, 2 ... };   # [1, 2, 1, 2]
```

**Memory:** Stack-allocated, fixed size. No heap allocation. `[3]i32` is 12 bytes on the stack.

## Tuple Literals

```
let point = (10, 20);
let mixed = (42, 3.14, true);
let unit = ();             # void tuple
```

**Memory:** Stack-allocated. Size is sum of element sizes (with padding).

## Null and Undefined

```
let p: ?*i32 = null;       # nullable pointer — null value
let x: i32 = undefined;    # uninitialized — reading is UB
```

**Memory:** `null` is a valid value for nullable pointer types. `undefined` is explicitly uninitialized memory — never read it.

## SIMD Vector Literals

```
let v = f32x4 { 1.0, 2.0, 3.0, 4.0 };
let zeros = i8x16 { 0 ... };
```

**Memory:** Stack-allocated, maps to target SIMD register (16-64 bytes).
