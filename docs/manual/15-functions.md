# Functions

## Declaration

```
fun add(a: i32, b: i32) -> i32 {
    return a + b;
}
```

**Memory:** Arguments are passed by value (copied for `Copy` types, moved for non-`Copy`). Return values are placed on the caller's stack.

## Calling

```
let sum = add(3, 5);     # sum = 8
```

## void Functions

```
fun log(msg: str) {
    print(msg);
}
# or explicitly:
fun log(msg: str) -> void {
    print(msg);
    return;
}
```

## Parameters

Parameters are immutable bindings. Use `var` for mutation:

```
fun bump(x: i32) {
    x += 1;    # compile error: x is immutable
}

fun bump(var x: i32) {
    x += 1;    # ok — x is a local copy
}
```

**Memory:** `var` parameter creates a local copy on the stack. The caller's value is not affected.

## Default Parameters

```
fun connect(host: str, port: u16 = 8080, timeout: u32 = 30) {
    ...
}

connect("localhost");                # uses defaults
connect("localhost", 443);           # custom port
connect("localhost", 443, 60);       # custom port + timeout
```

## Variadic Parameters

The last parameter can be variadic:

```
fun sum(values: i32...) -> i32 {
    var total: i32 = 0;
    for v in values {
        total += v;
    }
    return total;
}

let s = sum(1, 2, 3, 4);    # s = 10
```

**Memory:** Variadic parameters are passed as a slice (`[]i32`). No heap allocation when arguments are contiguous.

## Higher-Order Functions

```
fun apply<T, U>(f: fun(T) -> U, value: T) -> U {
    return f(value);
}

let result = apply(add, 3, 5);   # result = 8
```

**Memory:** Function pointers are stack-allocated values. No heap allocation.

## Tuple Spread

Spread a tuple into positional arguments with `...`:

```
fun add(a: i32, b: i32) -> i32 { return a + b; }
fun pair() -> (i32, i32) { return (3, 5); }

let result = add(...pair());   # desugars to add(3, 5)
```

Works with any tuple that matches the parameter count and types:

```
fun log_event(level: str, msg: str, code: i32) { ... }

let event = ("ERROR", "disk full", 507);
log_event(...event);   # desugars to log_event("ERROR", "disk full", 507)
```

**Memory:** Zero cost — the compiler inlines tuple elements as positional arguments. No intermediate allocation.

## Methods

Methods are declared in `impl` blocks:

```
impl Vec3 {
    pub fun length(self: *const Vec3) -> f64 {
        return sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fun scale(self: *Vec3, s: f64) {
        self.x *= s;
        self.y *= s;
        self.z *= s;
    }
}
```

Method call syntax:

```
let len = v.length();     # desugars to Vec3.length(&v)
v.scale(2.0);             # desugars to Vec3.scale(&v, 2.0)
```

**Memory:** Methods take `self` by pointer. No copy of the struct.

## Method Overloading

Multiple methods can share a name with different parameter types:

```
impl Printer {
    pub fun print(self, x: i32) { ... }
    pub fun print(self, s: str) { ... }
    pub fun print(self, v: Vec3) { ... }
}

printer.print(42);       # calls print(i32)
printer.print("hello");  # calls print(str)
printer.print(pos);      # calls print(Vec3)
```

Resolution is compile-time with zero runtime cost.

## Closures

```
let offset: i32 = 10;
let add_offset = |x: i32| -> i32 { return x + offset; };
let result = add_offset(5);    # result = 15
```

Explicit capture lists (recommended):

```
let add_offset = [&offset] |x: i32| -> i32 { return x + offset; };   # borrow
let consume = [s = move s] |x: i32| -> String { return s + x.to_string(); };  # move
```

**Memory:** Closures are stack-allocated structs containing captured variables. No heap allocation unless captures are heap types.
