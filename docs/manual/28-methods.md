# Methods and impl Blocks

## Basic Methods

Methods are declared in `impl` blocks:

```
impl Vec3 {
    pub fun length(self: *const Vec3) -> f64 {
        return sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fun normalize(self: *Vec3) {
        let len = self.length();
        self.x /= len;
        self.y /= len;
        self.z /= len;
    }
}
```

## Self Parameter

The first parameter determines how `self` is received:

```
impl Widget {
    pub fun area(self: *const Widget) -> i32 { ... }    # immutable borrow
    pub fun move(self: *Widget, dx: i32, dy: i32) { ... } # mutable borrow
    pub fun consume(self: Widget) { ... }                 # by value (moves)
}
```

- `self: *const T` — immutable borrow, most common
- `self: *T` — mutable borrow, for mutation
- `self: T` — by value, consumes the struct

## Method Call Syntax

```
let len = v.length();           # desugars to Vec3.length(&v)
v.normalize();                  # desugars to Vec3.normalize(&v)
```

## Generic Methods

```
impl<T> List<T> {
    pub fun push(self: *List<T>, value: T) { ... }
    pub fun pop(self: *List<T>) -> Option<T> { ... }
    pub fun len(self: *const List<T>) -> usize { return self.len; }
}
```

## Multiple impl Blocks

```
impl Vec3 {
    pub fun length(self: *const Vec3) -> f64 { ... }
}

impl Vec3 {
    pub fun scale(self: *Vec3, s: f64) { ... }
}
```

Multiple `impl` blocks for the same type are allowed. They share the same namespace.

## Trait Methods in impl

Prefix with the trait name to implement a trait method:

```
trait Drawable {
    fun draw(self: *Self);
}

impl Button {
    pub fun Drawable.draw(self: *Button) {
        print("drawing button");
    }
}
```

The `fun Trait.method` prefix makes the binding unambiguous.

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

## Operator Methods

Define operators with dunder methods:

```
impl Vec3 {
    pub fun __add__(a: Vec3, b: Vec3) -> Vec3 {
        return Vec3 { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
    }

    pub fun __eq__(a: Vec3, b: Vec3) -> bool {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
}
```

## Constructor Pattern

```
impl Config {
    pub fun default() -> Config {
        return Config {
            host: "localhost",
            port: 8080,
            max_conn: 100,
        };
    }

    pub fun new(host: str, port: u16) -> Config {
        return Config {
            host: host,
            port: port,
            max_conn: 100,
        };
    }
}

let cfg = Config.default();
let custom = Config.init("example.com", 443);
```

## Memory

- Methods take `self` by pointer — no copy of the struct
- Generic methods are monomorphized per concrete type
- No vtable, no indirection for direct calls
- Trait methods use vtable lookup (1 indirect call)
