# Unions

Use `union` when variants' **payload types may differ**; the uniform-payload case (all variants sharing one `T`) is [`enum(T)`](13-enums.md#backed-enums-enumt) per §13. The `<T>` angle brackets in `Option<T>`, `Result<T, E>`, etc. follow the [Generics](16-generics.md) convention — they declare a type parameter, not a backing type.

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

**Note:** an enum whose variants all share the same type `T` is `enum(T)`, not `union` — see [Enums → Backed Enums](13-enums.md#backed-enums-enumt). `union` is for variants whose **payload types may differ** (`Shape { Circle(f64), Rect(f64, f64) }`). The two keywords are deliberately separated so the "category of similar values" form (enums) doesn't pay for a per-variant tag (which would be redundant when all variants share `T`).

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

For partial matches (handle only some variants, ignore the rest), use `_` as the catch-all pattern. See [Exhaustiveness](#exhaustiveness) below for the catch-all paired with full enumeration:

```zag
# Partial match — handle Circle, ignore everything else:
match shape {
    Shape.Circle(r) => print("circle radius: {r}\n"),
    _               => print("other\n"),    # covers Rect, Triangle, Empty
}
```

## Mixed Bare + Payload

A single `union` is free to combine bare variants and payload variants:

```zag
union ClickEvent {
    Hover,                       # bare
    Press(i32),                  # one arg
    Drag { x: f64, y: f64 },     # named-field form (records)
    Resize { w: u32, h: u32 },   # named-field form (records)
}
```

All three variant shapes are supported at *declaration* time: **bare** (`Variant`), **paren-positional** (`Variant(T)`, `Variant(T, U)`), and **brace-named-field** (`Variant { name: T, ... }`). Match-side destructuring mirrors the constructor shape — destructuring by position (`Drag(w, h) => ...`) or by named field (`Drag { x: w, y: h } => ...`).

For *constructors*, the current compiler expects the qualified paren-positional form: write `ClickEvent.Drag(x, y)` (parens, qualified). Today, both qualified and unqualified brace ctors route through the brace-named-field emit: write `ClickEvent.Drag(1.5, 2.5)` (qualified paren) or `Drag { x: 1.5, y: 2.5 }` (unqualified brace) — both emit `.{ .Drag = .{ .x = 1.5, .y = 2.5 } }`. The unqualified-by-name lookup is unambiguous when at most one union in the program declares the variant as brace-named; if two unions share the same brace-named variant name, the lookup falls through to the legacy positional emit and zig 0.16 surfaces a "no field named 'a'" diagnostic so the collision is loud rather than silent. See [Pattern Matching](#pattern-matching) for the matching syntax.



> **Example**: see [`examples/types/named_field_match.zag`](../../examples/types/named_field_match.zag) for an end-to-end runnable demonstration of brace-named-field match-arm destructuring (`Pair { x: w, y: h } => w + h`).

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

`Option<T>` mixes a payload variant (`Some(T)`) with a bare variant (`None`). `Result<T, E>` has both variants with payloads.

`Option` and `Result` compose directly with `?` and `catch` for control flow:

```zag
fun read_config(path: str) -> Result<Config, Error> {
    let fd = open(path)?;        # ? on Result<T, E> propagates Err early
    defer close(fd);
    let data = read(fd)?;
    return parse(data);
}

let val = find(index)?;          # ? on Option<T> returns None early

let val = risky() catch default_value;   # default on Err

match risky() catch |err| {
    MyError.NotFound => -1,
    MyError.Timeout  => -2,
    _                => 0,
};
```

See [Error Handling](18-error-handling.md) for the full discussion.

## Exhaustiveness

`match` on a `union` value must be exhaustive — every variant must be handled. Omitting a variant is a compile error:

```zag
match shape {
    Shape.Circle(r)      => ...,
    Shape.Rect(w, h)     => ...,
    Shape.Triangle(pts)  => ...,
    Shape.Empty          => ...,
}
# omitting any of Circle/Rect/Triangle/Empty is a compile error
```

Use `_` for a catch-all (covers all unlisted variants):

```zag
match shape {
    Shape.Circle(r) => ...,
    _               => ...,   # covers Rect, Triangle, Empty
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

> FFI on unions is a planned feature. See [FFI and Interop](24-ffi.md) for what's available in the current compiler. The example below shows the target surface.

`@[repr(C, T)]` constrains a `union`'s tag width and discriminant layout to match a C-compatible representation. Discriminants can be pinned with `= N` for both bare and payload variants — the runtime ADT contract reserves distinct tags for unassigned variants too, but pinning is the established way to make the discriminant observable to C code:

```zag
@[repr(C, u8)]
union PacketKind {
    Hello   = 0,
    Data    = 1,
    Close   = 2,
    Payload { seq: u32, body: []const u8 } = 5,    # mixed bare + payload; tag pinned to 5 (non-sequential: slots 3-4 reserved for future insert)
}
```

The tag type follows `T`. Bare variants without `= N` take the next successive value; payload variants that mention `= N` pin a specific discriminant the C-side code can rely on (`Payload { ... } = 5` always reads `5` for the discriminant, regardless of declaration order).

## Memory

Unions are stack-allocated. No heap allocation unless a variant contains a heap type (`String`, etc.). Size = `sizeof(Tag) + max(sizeof(variants))`. Bare variants cost zero payload bytes.

## See Also

- [Enums](13-enums.md) — bare enumerations (no payloads)
- [Pattern Matching](27-pattern-matching.md) — full `match` syntax, payload destructuring
- [Error Handling](18-error-handling.md) — Result / Option / Error / Context
- [FFI and Interop](24-ffi.md) — `@[repr(C, T)]` for C compatibility
- [Spec](../spec.md) — canonical language spec; enums, backed enums, and unions live in §3.3 Compound Types
