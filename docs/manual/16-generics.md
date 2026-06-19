# Generics

## Generic Functions

```
fun max<T: Ordered>(a: T, b: T) -> T {
    if a > b {
        return a;
    }
    return b;
}

let m = max<i32>(3, 5);    # m = 5
let m2 = max<f64>(1.0, 2.0);  # m2 = 2.0
```

**Memory:** Generic functions are monomorphized at compile time. Each concrete type gets its own copy. No runtime overhead, no boxing.

## Generic Types

```
struct List<T> {
    data: *T,
    len: usize,
    cap: usize,
}

let nums: List<i32> = ...;
let strs: List<str> = ...;
```

## Trait Bounds

```
fun sort<T: Ordered + Clone>(slice: []T) { ... }
fun print_all<T: Display>(items: []T) { ... }
fun clone_and_modify<T: Clone>(val: T) -> T { ... }
```

Available bounds:
- `Clone` — has `clone()` method
- `Default` — has `default()` constructor
- `Zero` — all-zero bytes is valid
- `Ordered` — comparison operators defined
- `Display` — zero-alloc formatting
- `Iterator<T>` — iteration protocol
- `AsyncStream<T>` — async iteration

## Const Parameters

```
fun fill<T, const N: usize>(val: T) -> [N]T {
    var out: [N]T = [N]T { val ... };
    return out;
}

let zeros = fill<i32, 10>(0);    # [10]i32 filled with 0
```

**Memory:** Const parameters are compile-time values. The function is monomorphized for each `N`.

## Generic impl Blocks

```
impl<T> List<T> {
    pub fun push(self: *List<T>, value: T) { ... }
    pub fun pop(self: *List<T>) -> Option<T> { ... }
    pub fun len(self: *const List<T>) -> usize { return self.len; }
}
```

## No Trait Bounds on Associated Types

In v1, bounds only apply to type parameters:

```
# ok
fun first<T: Clone>(items: []T) -> T { ... }

# NOT ok in v1 (associated types cannot be bounded)
# fun process<I: Iterator>(iter: I) -> I::Item { ... }
```

## Compile-Time Type Parameters

```
const TABLE: [256]u32 = const {
    var t: [256]u32 = undefined;
    for i in 0..256 {
        t[i] = (i * 2654435761) as u32;
    }
    return t;
};
```

**Memory:** `const` blocks are evaluated at compile time. The result is embedded in the binary as a static constant.
