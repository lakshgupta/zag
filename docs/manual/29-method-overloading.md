# Method Overloading

Zag supports compile-time method overloading — multiple methods can share a name if their parameter types differ.

## Basic Overloading

```
impl Printer {
    pub fun print(self, x: i32) {
        print("{x}\n");
    }

    pub fun print(self, s: str) {
        print("{s}\n");
    }

    pub fun print(self, v: Vec3) {
        print("({v.x}, {v.y}, {v.z})\n");
    }
}
```

## Resolution Order

1. Check the type's own methods for an exact signature match
2. Check promoted (embedded) methods for an exact signature match
3. If no exact match, try implicit conversions (i32 → f64, widening, etc.)
4. If still ambiguous, **compile error** — caller must disambiguate

```
impl Widget {
    pub fun move(self: *Widget, dx: i32, dy: i32) { ... }
}

impl Button {
    pub fun move(self: *Button, dx: f32, dy: f32) { ... }
    pub fun move(self: *Button, dx: i32, dy: i32, dz: i32) { ... }
}

button.move(1, 2);        # Widget.move — exact match on (i32, i32)
button.move(1.0, 2.0);    # Button.move — exact match on (f32, f32)
button.move(1, 2, 3);     # Button.move — exact match on (i32, i32, i32)
```

## Overload Scope

All overloads of a type method live in the same `impl` block:

```
impl Printer {
    pub fun print(self, x: i32) { ... }
    pub fun print(self, s: str) { ... }
    pub fun print(self, v: Vec3) { ... }
}
```

## Trait Methods Are Not Overloaded

A trait method has a fixed signature per trait:

```
trait Drawable {
    fun draw(self: *Self);
}

impl Button {
    pub fun Drawable.draw(self: *Button) { ... }
    # Cannot have another Drawable.draw with different signature
}
```

## Embedded Methods

Methods from embedded structs participate in overload resolution:

```
struct Base { x: i32 }

impl Base {
    pub fun show(self: *Base) { print("{self.x}\n"); }
}

struct Child {
    Base,
    y: i32,
}

impl Child {
    pub fun show(self: *Child) { print("{self.x} {self.y}\n"); }
}

let c = Child { Base { x: 1 }, y: 2 };
c.show();    # Child.show — exact match wins
```

## Disambiguation

When overloads are ambiguous, disambiguate with an explicit cast:

```
let x: i32 = 42;
printer.print(x as i64);     # unambiguous: calls print(i64)
```

## Memory

Overload resolution is purely compile-time. The compiler selects the exact method at compile time — zero runtime cost.
