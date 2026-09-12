# Method Overloading

Zag supports compile-time method overloading — multiple methods can share a name when their arity or parameter types differ. Resolution happens in the compiler; the emitted call is a plain direct call with no runtime indirection.

## Basic Overloading

```
struct Printer { prefix: str }

impl Printer {
    pub fun print(self: *const Printer, x: i32) -> str { ... }
    pub fun print(self: *const Printer, s: str) -> str { ... }
    pub fun print(self: *const Printer, v: Vec3) -> str { ... }
}
```

Calling `p.print(42)` selects the `i32` overload, `p.print("hi")` the `str` overload, and `p.print(pos)` the `Vec3` overload.

Arity distinguishes overloads too:

```
impl Printer {
    pub fun bump(self: *Printer, x: i32) -> i32 { ... }
    pub fun bump(self: *Printer, a: i32, b: i32) -> i32 { ... }
}
```

## Resolution Order

For `receiver.name(args...)` where `receiver`'s declared type overloads `name`:

1. **Arity filter** — keep candidates whose user-visible parameter count (receiver excluded) equals the call's argument count. If none match, the call is a compile error.
2. **Score each candidate** over the argument list, using the types the compiler can see statically:
   - an exact type match scores **+2**;
   - an integer literal passed to a float parameter scores **+1** (the widening is allowed, but a dedicated integer overload wins over it);
   - an argument whose type cannot be determined scores **0** — it neither helps nor disqualifies a candidate.
3. **Highest total wins.**
4. **A tie is a compile error**, reported at the call site with the candidate list and a remedy.

Types the compiler can see include literals, annotated `let` bindings, `self` inside an `impl` method, struct-field accesses (`self.n`, `p.x`), and explicit casts (`n as f64`). A nested call result — `p.show(Point.init(1, 2))` — has no inferred type, so it scores 0.

## Ambiguity

When the score ties, the call does not compile:

```
error:12:19: call to overloaded method 'W.go' is ambiguous for these argument(s)
  candidate: W.go(x: i32)
  candidate: W.go(x: f64)
  hint: annotate the argument (e.g. `let x: i32 = ...`) or cast it (`x as i32`) so the type selects one overload.
```

Both remedies work: an annotated binding scores by its declared type, and a cast scores by its target type.

```
let n: i32 = 5;
w.go(n);             # W.go(x: i32)
w.go(n as f64);      # W.go(x: f64)
```

A cast that does not match any overload scores 0, so it leaves the call ambiguous rather than silently selecting the wrong method.

## Overload Scope

All overloads of a name on a type share one overload set, whether they are declared in a single `impl` block or spread across several `impl` blocks for the same type.

## Across modules

Overloading resolves against the type's own `impl` table, which is only
available where the type is **declared**. A call from an *importing* module
cannot see the imported type's overload set, so a static call
`ImportedType.method(args)` is emitted with the bare method name — and a type
that has two same-named methods in its own module emits them under mangled
names. The two spellings then do not meet.

The rule that follows: **do not overload a method that callers in other
modules invoke off the type name.** Give it one signature instead. That is
why `std.fs.File` has a single constructor, `File.open(path, mode)`, rather
than a one-argument `File.open(path)` overload — a mandatory `FileMode`
argument keeps one name covering every mode while staying callable from
anywhere. Overloading a method on a type used *within* one module (including
inside `lib/std`'s own files) is unaffected, and the `Type.method(...)` form
resolves normally when the type is declared in the same file.

## In String Interpolation

Overloaded calls resolve inside `{...}` placeholders as well as in statement position:

```
print("count={p.print(42)}\n");
print("name={p.print(\"hi\")}\n");
```

The placeholder parser builds literal, name, field, cast, call, and index arguments; a comparison or other compound expression used as a placeholder still needs to be bound to a local first (see chapter 11).

## Trait Methods Are Not Overloaded

A trait method has a fixed signature per trait:

```
trait Drawable {
    fun draw(self: *Self);
}

impl Button {
    pub fun Drawable.draw(self: *Button) { ... }
    # Cannot have another Drawable.draw with a different signature
}
```

## Embedded Methods

A method promoted from an embedded struct participates in resolution, and a method declared on the outer type with the same name and arity shadows the promoted one:

```
struct Base { x: i32 }

impl Base {
    pub fun show(self: *Base) -> str { return "base"; }
}

struct Child {
    Base,
    y: i32,
}

impl Child {
    pub fun show(self: *Child) -> str { return "child"; }
}

var c: Child = Child { Base { x: 1 }, y: 2 };
c.show();    # Child.show — the outer declaration wins
```

Without an outer declaration, `c.show()` calls the promoted method. The promotion goes through a generated forwarder whose receiver is the outer type, so the binding must be a `var` (a `let` binding would be a const-discard). Promoted *field* access is not part of this mechanism — see [Structs](12-structs.md) and [Traits](18-traits.md).

## Memory

Overload resolution is purely compile-time. The compiler selects one method and emits a direct call — zero runtime cost, no vtable, no indirection.
