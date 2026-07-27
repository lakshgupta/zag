# Operator Overloading

Operators desugar to specially named methods. Define them in an `impl` block.

## Operator Methods

| Operator | Method |
|----------|--------|
| `a + b` | `__add__(a, b)` |
| `a - b` | `__sub__(a, b)` |
| `a * b` | `__mul__(a, b)` |
| `a / b` | `__div__(a, b)` |
| `a % b` | `__mod__(a, b)` |
| `-a` | `__neg__(a)` |
| `a == b` | `__eq__(a, b)` |
| `a != b` | `__ne__(a, b)` |
| `a < b` | `__lt__(a, b)` |
| `a > b` | `__gt__(a, b)` |
| `a <= b` | `__le__(a, b)` |
| `a >= b` | `__ge__(a, b)` |
| `a[i]` | `__index__(a, i)` |
| `a[i] = v` | `__index_set__(a, i, v)` |

## Example

```
impl Vec3 {
    pub fun __add__(a: Vec3, b: Vec3) -> Vec3 {
        return Vec3 { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
    }

    pub fun __sub__(a: Vec3, b: Vec3) -> Vec3 {
        return Vec3 { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
    }

    pub fun __mul__(a: Vec3, s: f64) -> Vec3 {
        return Vec3 { x: a.x * s, y: a.y * s, z: a.z * s };
    }

    pub fun __eq__(a: Vec3, b: Vec3) -> bool {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }

    pub fun __index__(self: *const Vec3, i: usize) -> f64 {
        return match i {
            0 => self.x,
            1 => self.y,
            2 => self.z,
            _ => panic("index out of bounds"),
        };
    }
}
```

## Usage

Dunder methods are called directly — automatic desugaring (`a + b` → `a.__add__(b)`) requires a type resolver not yet implemented:

```
let c = a.__add__(b);      # Vec2.__add__(a, b)
let d = a.__sub__(b);      # Vec2.__sub__(a, b)
let e = a.__mul__(2.0);    # Vec2.__mul__(a, 2.0)
let same = a.__eq__(b);    # Vec2.__eq__(a, b)
let val = v.__index__(0);  # Vec2.__index__(v, 0)
```

Once the type resolver lands, these will desugar to `a + b`, `a - b`, `a * 2.0`, `a == b`, `v[0]`.

## Operator Methods Participate in Overload Resolution

```
impl Printer {
    pub fun print(self, x: i32) { ... }
    pub fun print(self, v: Vec3) { ... }
}
```

Operator methods are resolved the same way as regular methods — compile-time, zero cost.

## Memory

All operator methods are stack-only. They take and return values by pointer or by value. No heap allocation unless the implementation allocates.
