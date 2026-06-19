# Variables

## `let` — Immutable Binding

```
let x = 42;
let name = "hello";
let pi: f64 = 3.14;
```

`let` creates an immutable binding. The value cannot be reassigned:

```
let x = 10;
x = 20;    # compile error: cannot reassign let
```

**Memory:** Stack-allocated. The binding lives until the end of its scope.

## `var` — Mutable Binding

```
var counter = 0;
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

```
let a: i32 = 42;
let b = 42;              # type inferred as i32
let c: f64 = 42;         # explicit annotation
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
let x = 10;
let x = "hello";   # ok — new binding shadows the old one
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
    let x = 10;           # x is alive here
    {
        let y = 20;       # y is alive here
        print("{x} {y}\n");
    }
    # y is dead here
    print("{x}\n");
}
```

**Memory:** Bindings are freed when their scope exits. Stack space is reclaimed immediately.
