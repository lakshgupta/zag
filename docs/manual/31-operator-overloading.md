# Operator Overloading

Operators desugar to specially named methods. Define them in an `impl` block and the operator syntax works on the type.

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

Operators with no row — `&&`, `||`, the shifts, and wrapping arithmetic like `+%` — have no dunder form and always apply to the builtin types.

## Example

```
struct Vec3 { x: f64, y: f64, z: f64 }

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

The operators are the ordinary spellings:

```
let c: Vec3 = a + b;
let d: Vec3 = a - b;
let e: Vec3 = a * 2.0;
let same: bool = a == b;
let val: f64 = v[0];
```

`__index_set__` backs assignment through the bracket:

```
impl Store {
    pub fun __index_set__(self: *Store, i: usize, v: i32) {
        if i == 0 { self.a = v; } else { self.b = v; }
    }
}

var s: Store = Store.init();
s[0] = 7;
```

The receiver must be a mutable binding for `__index_set__` — the method takes `self: *Store`.

## When Desugaring Fires

The compiler rewrites an operator only when the operand's type is statically known and declares the matching dunder:

1. **Left operand's type** — an annotated binding, `self` inside an `impl` method, a struct field, a cast, or another expression the compiler can type.
2. **Dunder arity** — a binary operator needs a two-parameter method, unary `__neg__` one parameter, `__index__` two (receiver + key), `__index_set__` three.

When no such method exists, the operator falls through to zig's builtin behavior for the operand type — which is why `i32 + i32` keeps working unchanged, and why `a + b` on a struct with no `__add__` is a compile error rather than a silent miscompile.

Because the operand's type must be visible, an operator applied directly to a call result does not desugar:

```
let c = make() + b;      # no receiver type to check — not desugared
let a: Vec3 = make();
let c = a + b;           # works
```

## In String Interpolation

Arithmetic and indexing desugar inside `{...}` placeholders:

```
print("sum=({sum.x}, {sum.y})\n");   # from `let sum: Vec3 = a + b`
print("first={a[0]}\n");
```

A comparison used as a placeholder still has to be bound to a local first, because the placeholder parser builds only literal, name, field, cast, call, and index arguments:

```
let same: bool = a == b;
print("eq: {same}\n");
```

## Operator Methods and Overloading

Operator methods participate in the same overload resolution as ordinary methods (chapter 30). A type may declare several `__add__` methods when their parameter types differ, and the compiler picks the one matching the operands.

## Protocol Completeness

There is no fallback between related operators: `a != b` needs `__ne__` even when `__eq__` is defined, and `a >= b` needs `__ge__` even when `__le__` is defined. Defining only one of a pair leaves the other spelling a compile error for that type.

## Memory

Operator methods are ordinary methods — stack-only unless their implementation allocates. They take and return values by pointer or by value. Resolution is compile-time; no vtable and no indirection are involved.
