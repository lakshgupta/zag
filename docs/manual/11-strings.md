# Strings

## String vs str

Zag has two string types:

| Type | Description | Memory |
|------|-------------|--------|
| `str` (`[]const u8`) | Borrowed string view | Stack (ptr + len) |
| `String` | Owned, growable, heap-allocated | Heap |

```
let greeting: []const u8 = "hello";
var owned: String = String.from_str("hello");   # String — heap allocated
```

## Concatenation with `+`

The `+` operator concatenates two strings. Operands can be literals,
`str` bindings, `[]const u8` / `[]u8` bindings, or any mix — the result
is a fresh heap buffer holding both byte sequences:

```
let name: str = "world";
let greeting: str = "hello, " + name;   # literal + ident
let full: str = first + " " + last;     # chains are left-assoc
print("{a + b}\n");                      # also valid in `{...}` placeholders
```

**Memory:** each `+` allocates a new buffer (page allocator, charged to
std.bench counters); operands are never mutated, so literals (static
data) are safe inputs. Building a long string piece by piece in a loop
is O(n²) — prefer `String.push_str` for accumulation.

**Numeric `+` is untouched:** when neither operand is string-typed, the
operator lowers to zig's plain add. Mixing an int with a string operand
is a compile error — use `{}` interpolation to render numbers as text.

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

# with_capacity(n): allocate n bytes, length 0.
# from_str(s):     allocate a fresh buffer holding a COPY of s.
var s: String = String.from_str("hello");

s.push_str(" world");            # append a borrowed slice
s.push_ch('!');                  # append one byte
print("{s.as_str()}\n");         # "hello world"

s.deinit();                      # release the buffer
```

**Memory:** both constructors heap-allocate through `std.mem`'s raw tier
(`alloc_raw` over `mmap`). The buffer is owned by the `String` and has **no
implicit reclamation** — release it with `deinit()`. The binding must be `var`
for that, because `deinit` takes `*String`; a `let` binding is `*const` and
the call is a compile error.

Printing a `String` directly (`print("{s}\n")`) does **not** print its
contents — `String` has no `Display` impl, so a bare `{s}` placeholder shows
the struct fields. Use `s.as_str()` (or `s.trim()` / `s.slice(a, b)`, which
also return a borrowed `[]const u8`).

## String Methods

```
var s: String = String.from_str("hello");

s.push_str(" world");                # append a slice
s.push_ch('!');                      # append one byte
s.insert_ch(0, '>');                 # insert one byte at an index (bounds-checked)
let last: ?u8 = s.pop_ch();          # remove + return the last byte, or null
let view: []const u8 = s.as_str();   # borrow the bytes

# Comparison and search take a borrowed `str`, not a String:
let same: bool = s.eq("hello world");
let has:  bool = s.contains("ell");
let pre:  bool = s.starts_with("he");
let suf:  bool = s.ends_with("lo");
let at: ?usize = s.find("ell");       # first index, or null
let part: []const u8 = s.slice(0, 3);
let trimmed: []const u8 = s.trim();

s.to_upper();                        # in-place ASCII case conversion
s.to_lower();

print("view={view} same={same} contains={has} prefix={pre} suffix={suf} part={part} trimmed={trimmed} last={last} at={at}\n");

s.clear();                           # length 0, buffer still allocated
s.deinit();                          # release the buffer
```

**Memory:** `push_str` / `push_ch` / `insert_ch` reallocate (via
`realloc_raw`) when the length would exceed `cap`, doubling until it fits.
`clear` resets the length **without** freeing — the buffer stays charged
until `deinit`. `to_upper` / `to_lower` are in place; the search and slice
methods return borrowed views that must not outlive the `String`.

## String Builder Pattern

```
fun build_greeting(name: str) -> String {
    var s: String = String.with_capacity(64);   # one allocation
    s.push_str("hello, ");
    s.push_str(name);
    s.push_ch('!');
    return s;                                    # ownership moves to the caller
}

fun main() {
    var g: String = build_greeting("world");
    print("{g.as_str()}\n");
    g.deinit();
}
```

**Memory:** `with_capacity(n)` allocates once, so the `push` calls only
reallocate if the result exceeds `n`. The returned `String` carries ownership
to the caller, which is why the builder needs no `deinit` of its own — and why
the caller does.

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

**Expression content** — a placeholder holds an expression, not
necessarily a single identifier. The parser understands literals
(integer, float, and string), names, field access (`self.n`),
casts (`x as f64`), calls (`obj.f()`), indexing (`a[0]`), and
top-level `+`/`-` chains:

```
let a: i32 = 1;
let b: i32 = 2;
print("sum = {a + b}\n");                 # "sum = 3"
print("dot = {obj.f()}\n");               # method-call expression
print("quoted = {p.show(\"hi\")}\n");    # a string ARGUMENT, not data
print("precise = {pi:.5}\n");            # format spec still works
```

A string containing `{...}` stays a plain string (an embedded code
blob or JSON payload, not an interpolation) when a placeholder
contains a nested `{`, a `;`, or when its first non-whitespace
character is a quote or backslash — `"{\"a\": [1, 2, 3]}"` is
data. Quotes later in a placeholder are string arguments, as above.

Other compound expressions are not part of the placeholder grammar;
bind them to a local first:

```
let same: bool = a == b;
print("eq = {same}\n");                   # not {a == b}
```

Format specifiers (`:spec`) are split off the first `:` and applied
to the placeholder (e.g. `{pi:.5}` becomes `{any:.5}` with arg `pi`).

**Memory:** Outside `print`/`eprint` a template is materialized into the destination binding. There is no `String`-producing form and no `with_writer`/`as_writer`; to build an owned buffer, `push_str`/`push_ch` into a `String.with_capacity(n)` and `deinit` it (see the methods section above).

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
var owned: String = String.from_str(borrowed);   # heap allocate + copy
let back: str = owned.as_str();                  # borrow — no allocation
```

**Memory:** `String.from_str(str)` copies the bytes to the heap; `as_str()` borrows them back at zero cost. Note the `var`: `String.from_str` returns an owned buffer, and releasing it with `deinit` (which takes `*String`) requires a mutable binding.
