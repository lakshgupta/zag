# Tuples

## Definition

```
let point = (10, 20);
let mixed = (42, 3.14, true);
let single = (42,);        # single-element tuple
let unit = ();              # void tuple
```

**Memory:** Stack-allocated. Size is sum of element sizes (with alignment padding).

## Access

```
let x = point.0;    # first element
let y = point.1;    # second element
```

## Destructuring

```
let (x, y) = point;
print("{x}, {y}\n");   # 10, 20

let (_, y, _) = (1, 2, 3);
```

## Rest Binding

Bind the first elements and collect the rest into a tuple:

```
let (first, ...rest) = (1, 2, 3, 4);
# first = 1, rest = (2, 3, 4)

let (a, b, ...rest) = (10, 20, 30, 40, 50);
# a = 10, b = 20, rest = (30, 40, 50)
```

**Memory:** `rest` is a stack-allocated slice of the remaining elements. Zero cost — the compiler reuses the original tuple's memory.

> **Runtime RHS caveat (Phase 2).** Rest binding on a *runtime* RHS (init is an `.ident` or call, not a literal tuple/array) emits an open-ended zig slice `__destruct_<N>[<before_count>..]`. This requires the RHS subject to be sliceable under zig 0.16: `var arr = [N]T {…}` or `let arr: []T = …`. Anonymous-struct tuple values (e.g. `let x = (1, 2, 3); let (a, ...rest) = x;`) cannot be sliced by zig and reject at compile time — use destructuring instead, or bind the value as a sized array.

## Named Tuple Fields

Tuples can have named fields for documentation and access:

```
let point = (x: 10, y: 20);

print(point.x);     # named access
print(point.0);     # positional access (same value)
```

Named fields are **compile-time only** — they disappear at the ABI level. A `(min: i32, max: i32)` and an `(i32, i32)` are identical in memory and interchangeable.

## Tuples as Return Values

```
fun min_max(arr: []i32) -> (i32, i32) {
    var min = arr[0];
    var max = arr[0];
    for val in arr[1..] {
        if val < min { min = val; }
        if val > max { max = val; }
    }
    return (min, max);
}

let (lo, hi) = min_max(data);
```

**Memory:** Tuples are returned by value on the stack. No heap allocation.

### Named Returns

Function return types can use named fields:

```
fun min_max(arr: []i32) -> (min: i32, max: i32) {
    var min = arr[0];
    var max = arr[0];
    for val in arr[1..] {
        if val < min { min = val; }
        if val > max { max = val; }
    }
    return (min, max);
}

let result = min_max(data);
print(result.min);      # named access
print(result.max);      # named access

let (lo, hi) = min_max(data);   # destructuring still works
```

Named returns are zero cost — they're positional tuples with compile-time metadata.

## Rest Binding on Returns

```
fun parse() -> (i32, i32, i32, i32) {
    return (1, 2, 3, 4);
}

let (first, ...rest) = parse();
# first = 1, rest = (2, 3, 4)
```

## Tuple Spread in Calls

Spread a tuple into positional arguments:

```
fun add(a: i32, b: i32) -> i32 { return a + b; }
fun pair() -> (i32, i32) { return (3, 5); }

let result = add(...pair());   # desugars to add(3, 5)
```

**Memory:** Zero cost — the compiler inlines the tuple elements as positional arguments. No intermediate allocation.

## Tuples in For Loops

```
let items = [(1, "a"), (2, "b"), (3, "c")];
for (num, letter) in items {
    print("{num}: {letter}\n");
}
```

## Tuples as Struct Fields

```
struct Point {
    coords: (f64, f64),
}

let p = Point { coords: (1.0, 2.0) };
let (x, y) = p.coords;
```

## Unit Tuple `()`

The unit tuple `()` (also called `void`, the unit type) has exactly one value. Functions without `-> T` return `()`:

```
fun do_nothing() { }     # returns ()
let result = do_nothing();  # result is ()
```

**Memory:** `()` is zero-sized. No stack space.
