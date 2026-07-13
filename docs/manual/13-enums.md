# Enums

> **v1→v2 migration note.** In the unified v2 taxonomy, `enum` is reserved for **bare enumerations** (variants carry no payload). For any type whose variants carry payload — or for a type mixing bare and payload variants — use `union` instead; see [Unions](14-unions.md). For v1 (the current compiler), the `enum` keyword continues to accept bare and payload forms alike: `enum Direction { North, South }` and `enum Option<T> { Some(T), None }` both compile today. The split is forward-looking — once the v2 `union` keyword lands, payload-bearing declarations move to `union`.

## Definition

Enums are bare enumerations. Each variant is a name with no associated data:

```zag
enum Direction {
    North,
    South,
    East,
    West,
}

let dir = Direction.North;
```

**Memory:** The variants of a bare enumeration reduce to a tag. `Direction` is 1 byte (4 variants, fits in a `u8` tag). For ≤256 variants the size is 1 byte; for larger enumerations the tag widens to `u16` / `u32`.

## Color Example

```zag
enum Color {
    Red,
    Green,
    Blue,
}

let c: Color = Color.Red;
```

## Pattern Matching

```zag
match dir {
    Direction.North => print("up\n"),
    Direction.South => print("down\n"),
    Direction.East  => print("right\n"),
    Direction.West  => print("left\n"),
}
```

For partial matches, use `_` as the catch-all pattern. This works for both bare `enum` and `enum(T)` — in the backed-enum case `_` catches both unmatched identifiers *and* unmatched `T`-value literals (see [Backed Enums](#backed-enums-enumt) below):

```zag
match dir {
    Direction.North => print("up\n"),
    _               => print("other\n"),    # catches South, East, West
}
```

## Exhaustiveness

`match` on an enum value must be exhaustive — every variant must be handled. Omitting a variant is a compile error:

```zag
match dir {
    Direction.North => ...,
    Direction.South => ...,
    Direction.East  => ...,
    Direction.West  => ...,
    # omitting any of the four is a compile error
}
```

Use `_` for a catch-all (covers all unlisted variants):

```zag
match dir {
    Direction.North => ...,
    _               => ...,    # catches South, East, West
}
```

## Unqualified Variants

When the type is inferred, variants can be unqualified:

```zag
fun is_north(d: Direction) -> bool {
    match d {
        North => true,
        _     => false,
    }
}
```

Use qualified names when the type is ambiguous or for clarity.

## Backed Enums (`enum(T)`)

Parens (not angle brackets) signal that `T` is a concrete backing type, not a generic parameter. Per [Generics](16-generics.md), `<T>` introduces a type variable into scope while `(T)` wraps a concrete type.

For v2.1, an `enum` may declare a backing type `T`. The supported `T` universe is restricted to integer types, `bool`, `char`, and `str` — custom `Copy` struct/enum/array types as `T` are deferred. Each variant identifier is bound to a value of type `T` at compile time.

```zag
# String-backed enum (TypeScript / PHP BackedEnum / Swift-style)
enum(str) Level {
    Low    = "low",
    Medium = "medium",
    High   = "high",
}

# Integer-backed enum (Zig-style)
enum(u8) Status {
    Ok   = 0,
    Warn = 1,
    Err  = 2,
}
```

**Rules:**
- `enum(T)` requires explicit `= v` for every variant. Implicit values are not supported in v1.
- Default `enum { V1, V2 }` (no `T`) keeps bare-only behavior; tag-only memory layout (1-byte tag for ≤256 variants).
- Storage: `sizeof(T)` per value. The variant identifier IS the value — there is no extra tag byte.
- Variants remain bare; there is no per-variant payload type distinct from `T`.

`enum(T)` belongs on `enum` (not `union`): variants carry no per-variant payload type, and storage is `sizeof(T)` directly. `union` is for variants whose payload types may differ (`Shape { Circle(f64), Rect(f64, f64) }`); `enum(T)` is for variants that all share one `T` type ("category of similar values").

**Operations:**

```zag
let lvl: Level  = Level.High;
let ok:  Status = Status.Ok;

match lvl {
    "low"        => print("…"),    # match on the T-value
    Level.High   => print("…"),    # match on the identifier
    _            => print("…"),    # catch-all
}

# Synthesized equality compares T-values:
let ok_high: bool = (Level.High == "high");      # true — the value IS "high"
let ok_eq:    bool = (Status.Ok   == Status.Ok);  # true — both 0
let ok_neq:   bool = (Status.Ok   != Status.Err); # true — 0 != 2
```

**Synthesized methods (auto-generated):**
- `__eq__` — **value-based** for `enum(T)`: compares `T`-values across both T families. `Level.High == "high"` (T=str) and `Status.Ok == Status.Ok` (T=u8) are both `true`. Compare with default `enum { … }`, where `__eq__` is **tag-based** (variants are equal only to themselves and never equal to their `T`-value-shapes).
- `from_str(s: str) -> Option<Enum>` — synthesized whenever `T = str`; returns `None` for unrecognized strings.
- `Display::write` — auto-implemented; writes the `T`-value via `T`'s own `Display`.

**Cross-construction rules:**
- `let x: Level = "low";` — bind by T-value; compile error if `"low"` doesn't match a registered variant.
- `Level.High` and the literal `"high"` are interchangeable **in any binding position whose expected type is `Level`** (`: Level` annotation, `match` scrutinee of type `Level`, function parameter of type `Level`). In free-context bindings (e.g. `let s = "high";`, no annotation), the literal is a borrowed string view, not `Level` — there is no implicit coercion.

> **Rust users take note:** `enum(str) Level { High = "high" }` introduces true value-equality (`Level.High == "high"`). This differs from Rust's bare-reference enum, where `High == "high"` is a compile error (different types). Read the synthesized methods above as the binding contract.

**Combining with FFI:** `#[repr(C, T1)] enum(T2) X { … }` keeps `T2` as the Zag-side value type while using `T1` for the C-ABI footprint. The compiler synthesizes the conversion at FFI boundaries. See [FFI and Interop](24-ffi.md) for the full interaction.

## Repr Control

`#[repr(C, T)]` constrains an enum's tag width and layout to match a C-compatible representation:

```zag
#[repr(C, i32)]
enum CError {
    Ok = 0,
    NotFound = 1,
    Permission = 2,
}
```

The tag type follows `T`; explicit `= N` discriminants pin specific values. FFI requires `#[repr(C, T)]` if a C-side enum is involved. `#[repr(C, T1)] enum(T2) X { … }` composes: see [Backed Enums](#backed-enums-enumt) above.

## `Error` Type

The canonical error type in the standard library is an `enum Error { NotFound, Permission, Io, Parse, InvalidInput, Unavailable, Other }` — all bare variants, hence `enum`, not `union`. See [Error Handling](18-error-handling.md) for the full discussion.

## See Also

- [Unions](14-unions.md) — tagged unions / sum types
- [Pattern Matching](27-pattern-matching.md) — full `match` syntax
- [Spec](../spec.md) — canonical language spec; enums, backed enums, and unions live in §3.3 Compound Types
