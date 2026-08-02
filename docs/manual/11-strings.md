# Strings

## String vs str

Zag has two string types:

| Type | Description | Memory |
|------|-------------|--------|
| `str` (`[]const u8`) | Borrowed string view | Stack (ptr + len) |
| `String` | Owned, growable, heap-allocated | Heap |

```
let greeting: []const u8 = "hello";
let owned = new String("hello");     # String — heap allocated
```

## String Literals

String literals produce `[]const u8`:

```
let s: []const u8 = "hello";
let len = s.len;         # 5
let byte = s[0];         # 'h' as u8
```

**Memory:** No heap allocation. The literal is stored in the binary's static data segment. The variable is a stack-allocated pointer + length.

## Owned Strings

The `String` type lives in `std.types` — its ONLY import path (the
legacy `std.string` module was removed, so a stray
`import std.string.{String}` fails instead of binding a second path):

```
import std.types.{String}

let s = new String("hello");
defer free(s);

s.push('!');
s.push_str(" world");
print("{s}\n");         # "hello world"
```

**Memory:** `new String(...)` heap-allocates via the global allocator. Must be `free`d.

## String Methods

```
let s = new String("hello");

s.push('!');                     # append character
s.push_str(" world");            # append string slice
s.reserve(100);                  # pre-allocate capacity
s.clear();                       # reset to empty (keeps allocation)
let view: []const u8 = s.as_str();  # borrow as slice
```

**Memory:** `push` and `push_str` may reallocate if capacity is exceeded. `reserve` pre-allocates. `clear` resets length without freeing.

## String Builder Pattern

```
fun build_greeting(name: str) -> String {
    var s = String.with_capacity(64);
    s.with_writer(|w| {
        Display.write("hello, ", w);
        Display.write(name, w);
        Display.write("!\n", w);
    });
    return s;
}
```

**Memory:** `with_capacity` allocates once. `with_writer` formats into the buffer without intermediate allocations.

## String Interpolation

```
let name: []const u8 = "world";
let msg: []u8 = "hello, {name}";
print("{msg}\n");

# Format specifiers
let pi: f64 = 3.14159;
print("pi = {pi:.2}\n");        # "pi = 3.14"
print("{42:x}\n");              # "2a"
print("{42:b}\n");              # "101010"
```

**Expression content** — the `{...}` placeholder accepts any
zig expression, not just a single identifier. Dots, spaces,
operators, parens, and method calls are all valid inside the
braces because the gate only rejects a NESTED `{` (an embedded
code block, not an interpolation):

```
let a: i32 = 1;
let b: i32 = 2;
print("sum = {a + b}\n");                 # "sum = 3"
print("dot = {obj.f()}\n");               # method-call expression
print("precise = {pi:.5}\n");            # format spec still works
```

The placeholder text is emitted verbatim at the format-arg site,
so any expression that zig accepts as a value-yielding expression
is a valid interpolation. Format specifiers (`:spec`) are split
off the first `:` and applied to the placeholder (e.g.
`{pi:.5}` becomes `{any:.5}` with arg `pi`).

**Memory:** Interpolation allocates a `String` via `Display.write`. Use `with_writer` for zero-alloc formatting in hot paths.

**Byte-slice printing (`{s}` vs `{any}`):** Interpolated byte-slice bindings (`let s: []const u8 = ...` OR `let s: str = ...`) route through zig's `{s}` formatter and display the slice's contents (`hello`) rather than the byte-element list (`{ 104, 101, 108, 108, 111 }`). Optional byte-slice bindings (`let s: ?[]const u8 = ...`) ALSO route through `{s}` but the arg slot is wrapped with `orelse ""` so the non-null value emits and null displays as an empty string. Unannotated bindings and primitive scalar types (`i32`, `bool`, `f64`, ...) preserve the legacy `{any}` default. The widening applies to BOTH `print(arg)` (direct call) and `print("v={arg}\n")` (template interpolation) surfaces.

## String Slicing

```
let s: []const u8 = "hello, world";
let sub: []const u8 = s[0..5];    # "hello"
```

**Memory:** Slicing borrows — no allocation. Result is a stack-allocated slice.

## Byte Strings

```
let bytes: []const u8 = b"hello";
```

**Memory:** Stack-allocated slice pointing to static data.

## Converting Between String and str

```
let borrowed: str = "hello";
let owned: String = new String(borrowed);   # heap allocate
let back: str = owned.as_str();             # borrow — no allocation
```

**Memory:** `new String(str)` copies the bytes to the heap. `as_str()` borrows — zero cost.
