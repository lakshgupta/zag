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

The first `<T>` introduces the type-param into scope; the `T`s in the parameter list and return type reference it. Both are required — there is no `fun max(a: T, b: T) -> T` shorthand, because without the first `<T>` there is no scope in which to introduce `T`. (The turbofish `max<i32>(3, 5)` at the call site is a separate surface — see [Generic Types](#generic-types).)

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

Generic structs monomorphize at compile time to the **thunk form**:

```
// zag source                                // zig emission
struct List<T> { data: *T, len: usize, ... } pub fn List(comptime T: type) type {
                                                return struct {
                                                    data: *T,
                                                    len: usize,
                                                    ...
                                                };
                                            }
let nums: List<i32> = ...;                   // resolves to List(i32)[]…
```

The compiler rewrites the source turbofish `<TYPE>` to a parentheses-monomorphization `(TYPE)` at every call site and type annotation. Struct literals `List<i32> { … }` round-trip through the same rewrite.

## Trait Bounds

```
fun sort<T: Ordered + Clone>(slice: []T) { ... }
fun print_all<T: Display>(items: []T) { ... }
fun clone_and_modify<T: Clone>(val: T) -> T { ... }
```

Available bounds and the method the compiler checks for via `@hasDecl`:

| Bound          | Method required on the type |
|----------------|------------------------------|
| `Clone`        | `clone()` |
| `Default`      | `default()` |
| `Zero`         | `is_zero()` |
| `Ordered`      | `compare()` |
| `Display`      | `display()` |
| `Iterator`     | `next()` |
| `AsyncStream`  | `poll_next()` |

The compiler emits `if (!@hasDecl(T, "method")) @compileError("type T must implement Trait (missing `method` method)");` at the generic function / impl-block body entry. Built-in zig primitive types (`i32`, `f64`, `usize`, …) naturally expose `compare` and the other baseline methods, so the bounds pass for primitives without user work.

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

The first `<T>` introduces the type-param into scope; the second `<T>` (and any `T` inside `List<T>`) references it. Both are required — there is no `impl List<T>` shorthand, because without the first `<T>` there is no scope in which to introduce `T`. This mirrors the function form `fun max<T: Ordered>(a: T, b: T)` — the `<T>` declares, the `T`s in the signature and body use.

Generic impl blocks emit one orphan free function per method at module scope:

```
// zig emission for List<T>::push
pub fn List_T_push(comptime T: type, self: *List(T), value: T) void { ... }
```

The compiler rewrites each `<TYPE>` segment in receiver and parameter types to `(TYPE)` when the segment matches one of the impl's declared type-param names (`T`, `U`, `K`, `V`, …). Segments that don't match a type-param name on the enclosing impl (e.g. nested generic-enum or generic-union monomorphizations, including `enum(T)` instances like `enum(str) Color` where `T` isn't a type-param of the enclosing impl) pass through verbatim.

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

A `const` binding can take a `const { … return EXPR; }` block initializer. The block is evaluated at compile time, the result is embedded in the binary as a static constant, and every runtime use of the binding resolves to the embedded value with no per-site recomputation.

The body can use any statement form available to function bodies (`var`, `for`, `if`, nested `const`, etc.). The trailing `return EXPR;` is required — it is the value the binding takes. Bare `return;` (no value) is rejected at parse time.

**Memory:** `const` blocks are evaluated at compile time. The result is embedded in the binary as a static constant.
