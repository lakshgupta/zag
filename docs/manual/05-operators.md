# Operators

## Arithmetic

```
let sum = a + b;
let diff = a - b;
let product = a * b;
let quotient = a / b;
let remainder = a % b;
let negated = -a;
```

**Memory:** All arithmetic is stack-only. No allocation.

## Bitwise

```
let and = a & b;
let or = a | b;
let xor = a ^ b;
let not = ~a;
let left = a << 2;
let right = a >> 2;
```

## Comparison

```
a == b
a != b
a < b
a > b
a <= b
a >= b
```

## Logical

```
a && b    # logical AND
a || b    # logical OR
!a        # logical NOT
```

## Assignment

```
x = 10;
x += 5;     # x = x + 5
x -= 3;     # x = x - 3
x *= 2;     # x = x * 2
x /= 4;     # x = x / 4
x %= 3;     # x = x % 3
x &= 0xFF;  # bitwise AND assign
x |= 0x01;  # bitwise OR assign
x ^= 0x02;  # bitwise XOR assign
x <<= 1;    # left shift assign
x >>= 1;    # right shift assign
```

## Range

```
let range = 0..10;        # half-open [0, 10)
for i in 0..10 {
    print("{i}\n");
}
```

**Memory:** `Range<T>` is a stack-allocated struct `{ start: T, end: T }`.

## Index

```
let val = arr[0];         # calls __index__
arr[0] = 10;              # calls __index_set__
```

## Address-of

```
let p: *i32 = &x;         # take address of x
let cp: *const i32 = &x;  # immutable pointer
```

**Memory:** `&` produces a pointer to a stack-allocated value. The pointer is valid only while the referent is alive.

## Operator Precedence

Operators are grouped into precedence classes. Higher classes bind tighter than lower classes; same-class operators are evaluated left-to-right (left-associative) unless noted.

| Priority | Class | Operators | Associativity |
|----------|-------|-----------|---------------|
| 1 | Unary | `!`, `-` (negation), `*` (deref) | Right |
| 2 | Conversion | `as` | Left |
| 3 | Multiplicative | `*`, `/`, `%` | Left |
| 4 | Additive | `+`, `-` | Left |
| 5 | Shift | `<<`, `>>` | Left |
| 6 | Bitwise AND | `&` | Left |
| 7 | Bitwise XOR | `^` | Left |
| 8 | Bitwise OR | `\|` | Left |
| 9 | Comparison | `==`, `!=`, `<`, `>`, `<=`, `>=` | None (cannot chain) |
| 10 | Logical AND | `&&` | Left |
| 11 | Logical OR | `\|\|` | Left |
| 12 | Range | `..`, `...` | None |
| 13 | Assignment | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=` | Right |

Examples:

```
1 + 2 * 3           # 1 + (2 * 3) = 7        (multiplicative binds tighter)
(1 + 2) * 3         # 9                       (parens override precedence)
a + b * c - d       # ((a + (b * c)) - d)     (left-to-right within precedence class)
a < b && c < d      # (a < b) && (c < d)      (comparison has no chaining; `a < b < c` is a syntax error)
! a && b            # (! a) && b              (unary binds tighter than logical)
```

The precedence is enforced by zag's recursive-descent parser — `parseExpr` walks an additive → multiplicative → primary ladder, so `1 + 2 * 3` always parses as `binary(add, 1, binary(mul, 2, 3))`. The compiler emits the AST with full parenthesisation in the generated source so downstream zig observes the AST's intent regardless of zig's own precedence rules.

## Operator Overloading

Define operators by implementing dunder methods:

```
impl Vec3 {
    pub fun __add__(a: Vec3, b: Vec3) -> Vec3 {
        return Vec3 { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
    }

    pub fun __eq__(a: Vec3, b: Vec3) -> bool {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }

    pub fun __index__(self: *const Vec3, i: usize) -> f64 {
        # custom indexing
    }
}
```

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

**Memory:** Operator methods are monomorphized at compile time. No vtable, no indirection.
