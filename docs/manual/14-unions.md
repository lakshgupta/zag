# Unions

> **v1→v2 migration note.** The `union` keyword represents tagged unions / sum types — variants may carry a payload, be bare, or mix both. The v1 compiler does not yet recognize `union` as a keyword; instead it parses the v2 `union` surface as `enum`. Once `union` is wired in, payload-bearing declarations that today read `enum X { Variant(T) }` will be rewritten to `union X { Variant(T) }`. Example `.zag` files in this repository continue to use the legacy `enum` form so they remain runnable against the v1 compiler.

## Definition

A `union` is a tagged union (algebraic data type). Variants can:
- Carry a payload: `Variant(T)`, `Variant(T, U)`
- Be bare: `Variant`
- Mix the two in the same type: `union Shape { Circle(f64), Empty }`

```zag
union Shape {
    Circle(f64),                # radius — payload
    Rect(f64, f64),            # width, height — payload
    Triangle([3]f64),          # vertices — payload
    Empty,                     # bare variant — no payload
}
```

**Memory:** A `union` is a tag plus the largest variant. For `Shape`: `max(sizeof(f64), sizeof([3]f64), 0) + tag = 24 + 1 = 25 bytes` (with platform alignment). Bare variants cost zero bytes beyond the tag.

## Constructors

```zag
let c: Shape = Shape.Circle(2.0);    # payload ctor — args in parentheses
let r: Shape = Shape.Rect(3.0, 4.0); # multi-arg payload ctor
let e: Shape = Shape.Empty;          # bare ctor — no parens
```

## Pattern Matching

Match each variant. The payload binds per pattern:

```zag
match shape {
    Shape.Circle(r) => {
        let area = 3.14159 * r * r;
        print("circle area: {area}\n");
    }
    Shape.Rect(w, h) => {
        let area = w * h;
        print("rect area: {area}\n");
    }
    Shape.Triangle(pts) => {
        print("triangle\n");
    }
    Shape.Empty => {
        print("empty\n");
    }
}
```

Outside the body, the bare variant's pattern is just the variant name (`Shape.Empty =>`). The payload variants' patterns are parenthesised (`Shape.Circle(r)`, `Shape.Rect(w, h)`).

## Mixed Bare + Payload

A single `union` is free to combine bare variants and payload variants:

```zag
union ClickEvent {
    Hover,                      # bare
    Press(i32),                 # one arg
    Drag { x: f64, y: f64 },    # named-field form (records)
    Resize { w: u32, h: u32 },
}
```

This is the v2 surface — `enum X { ... }` with such a mix is the current-source spelling; v2 writes `union X { ... }`.

## Option and Result

The standard library defines these core unions:

```zag
union Option<T> {
    Some(T),
    None,
}

union Result<T, E> {
    Ok(T),
    Err(E),
}
```

`Option<T>` mixes a payload variant (`Some(T)`) with a bare variant (`None`). `Result<T, E>` has both variants with payloads. See [Error Handling](18-error-handling.md) for the full discussion.

## Exhaustiveness

`match` on a `union` value must be exhaustive — every variant must be handled:

```zag
match dir {
    Direction.North => ...,
    Direction.South => ...,
    Direction.East  => ...,
    Direction.West  => ...,
}
# omitting a variant is a compile error
```

Use `_` for a catch-all:

```zag
match result {
    Ok(val) => process(val),
    _ => handle_unknown(),
}
```

## Unqualified Variants

When the type is inferred, variants can be unqualified:

```zag
match result {
    Ok(val)  => process(val),       # unqualified
    Err(e)   => handle_error(e),    # qualified for clarity
}
```

## Custom Error Unions

For errors that carry data on at least one variant, use `union`:

```zag
union MyError {
    NotFound,
    Timeout,
    Custom(str),            # payload — must be a union, not an enum
}

fun risky() -> Result<i32, MyError> {
    return Err(MyError.Timeout);
}
```

The `ErrorExt` trait (in `std.error`) is implemented for any custom error union and lets you attach a context message — see [Error Handling](18-error-handling.md).

## FFI

`#[repr(C, T)]` constrains a `union`'s tag width and discriminant layout to match a C-compatible representation:

```zag
#[repr(C, u8)]
union PacketKind {
    Hello = 0,
    Data = 1,
    Close = 2,
    Payload { seq: u32, body: []const u8 },   # mixed bare + payload
}
```

The tag type follows `T`. Variants with `= N` pin a specific discriminant; bare variants without `= N` take the next successive value; payload variants still get distinct tag values via the runtime ADT contract.

## Memory

Unions are stack-allocated. No heap allocation unless a variant contains a heap type (`String`, etc.). Size = `sizeof(Tag) + max(sizeof(variants))`. Bare variants cost zero payload bytes.

## See Also

- [Enums](13-enums.md) — bare enumerations (no payloads)
- [Pattern Matching](27-pattern-matching.md) — full `match` syntax, payload destructuring
- [Error Handling](18-error-handling.md) — Result / Option / Error / Context
- [FFI and Interop](24-ffi.md) — `#[repr(C, T)]` for C compatibility
