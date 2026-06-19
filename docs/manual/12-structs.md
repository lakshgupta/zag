# Structs

## Definition

```
struct Vec3 {
    x: f64,
    y: f64,
    z: f64,
}
```

**Memory:** `Vec3` is 24 bytes on the stack (3 × 8-byte f64). No heap allocation.

## Construction

```
let v = Vec3 { x: 1.0, y: 2.0, z: 3.0 };
```

**Memory:** Stack-allocated value. No heap allocation.

## Field Access

```
let x = v.x;       # read
v.x = 10.0;        # write
```

Fields are **private by default**. External access requires getter/setter methods:

```
struct Account {
    balance: f64,       # private
}

impl Account {
    pub fun balance(self: *const Account) -> f64 {
        return self.balance;
    }

    pub fun deposit(self: *Account, amount: f64) {
        self.balance += amount;
    }
}
```

## Struct Update (Spread)

```
let base = Vec3 { x: 1.0, y: 2.0, z: 3.0 };
let modified = Vec3 { ...base, z: 10.0 };   # { 1.0, 2.0, 10.0 }
```

**Memory:** Shallow copy. `modified` is a new stack value with one field replaced.

## Struct Embedding

```
struct Widget {
    x: i32,
    y: i32,
}

struct Button {
    Widget,              # embedded — promotes x, y fields and Widget methods
    label: String,
}

let btn = Button { Widget { x: 0, y: 0 }, label: new String("OK") };
print("{btn.x} {btn.label}\n");   # access promoted field
```

**Memory:** Embedded struct is inline — `Button` contains `Widget`'s fields directly. No pointer indirection.

## Methods

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

let len = v.length();       # method call
v.normalize();              # mutable method
```

**Memory:** Methods take `self` by pointer — no copy of the struct.

## Constructor Pattern

```
struct Config {
    host: str,
    port: u16,
    max_conn: u32,
}

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
let custom = Config.new("example.com", 443);
```

## Derive Attributes

```
#[derive(Clone)]
struct Particle {
    position: [3]f32,
    velocity: [3]f32,
    age: u32,
}

let p2 = p1.clone();     # field-by-field copy
```

**Memory:** `clone()` copies all fields. For `String` fields, this heap-allocates — the single exception to no-hidden-allocation.

## Copy Semantics

Structs are `Copy` iff all fields are `Copy`:

```
#[derive(Clone)]
struct Point { x: f32, y: f32 }    # Copy (all fields Copy)

#[derive(Clone)]
struct Entity {
    id: u64,                         # Copy
    name: String,                    # NOT Copy
}
```

`Point` duplicates on assignment. `Entity` moves.

## Private Fields + Public Construction

```
# In module a:
struct Foo {
    x: i32,         # private
    y: i32,         # private
}

# In module b:
let f = Foo { x: 1, y: 2 };   # compile error: fields are private
```

External code must use constructors:

```
impl Foo {
    pub fun new(x: i32, y: i32) -> Foo {
        return Foo { x: x, y: y };
    }
}
```
