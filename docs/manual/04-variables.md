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

```
let (x, y) = (10, 20);
let Vec3 { x, y, z } = v;
let [a, b, c] = arr;
let (_, y, _) = (1, 2, 3);   # discard values
```

**Memory:** Each binding is stack-allocated. Destructuring copies/moves values from the source.

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
