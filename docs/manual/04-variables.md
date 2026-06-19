# Variables

## `let` — Immutable Binding

```
let x: i32 = 42;
let name: []const u8 = "hello";
let pi: f64 = 3.14;
```

`let` creates an immutable binding. The value cannot be reassigned:

```
let x: i32 = 10;
x = 20;    # compile error: cannot reassign let
```

**Memory:** Stack-allocated. The binding lives until the end of its scope.

## `var` — Mutable Binding

```
var counter: i32 = 0;
counter += 1;    # ok
```

**Memory:** Stack-allocated. Same lifetime as `let`, but the value can be mutated.

## Bare Rebinding

A `var` binding can be reassigned with a bare `name = expr` statement (no `var` keyword on the left):

```
var count: i32 = 0;
count = count + 1;          # bare-assignment rebinding
count = 99;                  # bare-assignment to fresh value
```

Bare `=` on a `let` binding is a **compile error** — `let` bindings cannot be mutated. The compiler rejects it with the standard zig error `cannot assign to const`. Bare `=` on an identifier that has not been declared is also a compile error (rogue identifier).

A bare `name = expr` is the canonical zag form for rebinding. The compound assignment forms (`+=`, `-=`, `*=`, `/=`) work too and desugar to `name = name OP expr` — but they require the operator overload to be defined for the value's type (`__add__` for `+=`, etc.).

**Memory:** No allocation. The binding's storage location is reused; only the slot value changes.

## `const` — Compile-Time Constant

```
const PI: f64 = 3.141592653589793;
const MAX_SIZE: usize = 1024;
const MASK: u32 = 0xFF;
```

**Memory:** Embedded in the binary as a static constant. No stack or heap allocation.

## Type Annotations

All simple bindings (`let`, `var`, `const`) require an explicit `: T` annotation **unless** the initializer is a literal expression — see [Carve-Out: Literal Initializers](#carve-out-literal-initializers) below for the full list of literal kinds accepted without `: T.

```
let x: i32 = 42;              # annotated (works for any initializer)
let y = 42;                   # inferred — int literal coerces to i32
let z: f64 = 3.14;            # annotated
let w = 3.14;                 # inferred — float literal coerces to f64
let s = "hello";              # inferred — string literal coerces to []const u8
let arr = [3]i32 { 1, 2, 3 }; # inferred — array literal
```

### Carve-Out: Literal Initializers

The 11 literal Expr kinds accept bindings without `: T`. Each kind carries its type in the source form alone, so the compiler assigns the type without assistance:

| Expr kind | Examples | Coerced to |
|---|---|---|
| `int_lit` | `42`, `0xFF`, `0b1010`, `1_000_000` | `i32` |
| `float_lit` | `3.14`, `1.0e10`, `0x1.0p10` | `f64` |
| `bool_lit` | `true`, `false` | `bool` |
| `char_lit` | `'a'`, `'\n'`, `'\u2764'`, `'\x00'` | `u8` |
| `string_lit` | `"hello"`, `"line\nbreak"` | `[]const u8` |
| `byte_string_lit` | `b"bytes"` | `[]const u8` |
| `null_lit` | `null` | nullable pointer (context-dependent — codegen errors if no nullable target) |
| `undefined_lit` | `undefined` | inferred from first use |
| `tuple_lit` | `(10, 20)`, `(x: 10, y: 20)` | anonymous struct of element types |
| `array_lit` | `[3]i32 { 1, 2, 3 }`, `[5]i32 { 0 ... }` | `[N]T` (T from elements) |
| `template_lit` | `` `value: {x}` `` | `[]const u8` (runtime-formatted) |

**Why the carve-out exists.** The literal-init pattern is the most common one in zag code (`let x = 42;`, `let pi = 3.14;`, `let n = arr.len;`). Without the carve-out, every binding would need a redundant `: T` even when the type is obvious from the source. With the carve-out, every binding — abstract or literal — has a compile-time known type without burdening the user. Non-literal initializers still require `: T` because their types cannot be inferred from syntax alone.

For all other Expr kinds (`ident`, `binary`, `unary`, `call`, `new_expr`, `free_expr`, `deref`, `index`, `range`), `: T` is **required** and produces a compile error otherwise:

```
let sum: i32 = x + y;        # binary expression — annotation required
# let sum = x + y;           compile error (parser rejects non-literal bare init)
let copy: []const u8 = s;    # ident initializer  — annotation required
# let copy = s;              compile error (parser rejects non-literal bare init)
let parsed: Result<...> = parse(src); # call — annotation required
# let parsed = parse(src);   compile error (parser rejects non-literal bare init)
```

## Destructuring

Zag supports the binding-side destructuring shapes below today. The source can be a literal (`(10, 20)`), a prior let-binding (`pair`), or any expression that evaluates to a tuple/array value.

```
let (x, y) = (10, 20);             # tuple (literal source)
let (a, b) = pair;                 # tuple (prior binding)
let [a, b, c] = arr;               # array
let (_, y, _) = (1, 2, 3);         # tuple with wildcard discards
let (a, (b, c)) = (1, (2, 3));     # nested (tuple-in-tuple)
var (m, n) = (1, 2);               # mutable destructuring (var leaves, const temp)
```

The wildcard `_` may appear anywhere a leaf name is expected and emits no binding. The value is still copied through the temp, so the surrounding leaves' positional access into the source stays correct (e.g. the `y` in `let (_, y, _) = (1, 2, 3);` still reads source index `[1]`).

Destructuring is recursive, so the patterns above freely nest: a tuple leaf can be a tuple, an array leaf can be an array, etc. See `examples/basics/destructuring.zag` for a working demo of every form above.

**Implemented status (as of zig 0.16 codegen):**

- `let (x, y) = (10, 20)` — tuple with literal source: **implemented**
- `let (a, b) = pair` — tuple from prior binding: **implemented**
- `let [a, b, c] = arr` — array source: **implemented**
- `let (_, y, _) = (1, 2, 3)` — wildcard discards: **implemented**
- `let (a, (b, c)) = …` — nested patterns: **implemented**
- `var (m, n) = (1, 2)` — mutable destructuring: **implemented**
- `let Vec3 { x, y, z } = v` — struct destructuring on a `Vec3` struct (see [Structs](12-structs.md)): **deferred**, gated on struct-init support landing first

**`var` destructured leaves and zig 0.16:** two independent hard-error rules apply:

1. **`comptime_int` rejection.** `__destruct_0` is an anonymous struct literal, so `__destruct_0[0]` is a `comptime_int`. `var m = __destruct_0[0];` would be rejected because a runtime `var` cannot hold an unsized integer. The codegen works around this by emitting a concrete type on every `var` leaf (`: i32`, `: f64`, `: bool`, `: u8`, `: []const u8`) inferred from the literal in the source tuple.
2. **`local variable is never mutated`.** zig 0.16 promotes this warning to a hard error, so `var (m, n) = (1, 2); print(n);` fails to compile even though `n` is read. The compiler emits both leaves; the user is responsible for mutating each one (so add `n = n + 1;` or similar).

**Memory:** Each leaf binding is stack-allocated. The destructuring itself is codegen-driven: there is one synthetic `const __destruct_<N> = INIT;` temp that carries the source value throughout its body, plus one emitted binding per leaf walked through the pattern. Discarded leaves emit nothing; the temp is `const` even under `var` bindings because it is only a synthetic carrier — the leaves hold the user-visible names.

## Shadowing

```
let x: i32 = 10;
let x: []const u8 = "hello";
```

## Module-Level Variables

```
var global_counter: i32 = 0;     # mutable, static storage duration
const CONFIG: Config = ...;      # immutable, compile-time
```

**Memory:** Module-level `var` has static storage duration (lives for the entire program). Module-level `let` is not allowed — use `const`.

## Scope

```
fun main() {
    let x: i32 = 10;
    {
        let y: i32 = 20;
        print("{x} {y}\n");
    }
    # y is dead here
    print("{x}\n");
}
```

**Memory:** Bindings are freed when their scope exits. Stack space is reclaimed immediately.
