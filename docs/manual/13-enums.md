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

The tag type follows `T`; explicit `= N` discriminants pin specific values. FFI requires `#[repr(C, T)]` if a C-side enum is involved.

## `Error` Type

The canonical error type in the standard library is an `enum Error { NotFound, Permission, Io, Parse, InvalidInput, Unavailable, Other }` — all bare variants, hence `enum`, not `union`. See [Error Handling](18-error-handling.md) for the full discussion.

## See Also

- [Unions](14-unions.md) — tagged unions / sum types
- [Pattern Matching](27-pattern-matching.md) — full `match` syntax
