# Enums

## Choosing Between `enum` and `union`

| Use `enum` when...                           | Use `union` when...                                |
|----------------------------------------------|----------------------------------------------------|
| All variants are bare (no payload)           | Any variant carries a payload                      |
| Variants all share one backing type `T`      | Variants' payload types may differ                 |
| You want a 1-byte tag (≤256 variants)        | You want a tagged-union layout (tag + max payload) |
| You want value-equality across variants      | You want payload binding in match arms (`V(x) =>`) |

**Layout reference (zig-equivalent):**
- `enum { North, South }` ⇒ `pub const Direction = enum { North, South };` — bare enum, 1-byte tag.
- `enum(u8) { Ok = 0, Err = 1 }` ⇒ `pub const Status = enum(u8) { Ok = 0, Err = 1 };` — backed enum, no per-variant tag, storage is `sizeof(u8)`.
- `union { Circle(f64), Rect(f64, f64) }` ⇒ `pub const Shape = union(enum) { Circle: f64, Rect: [2]f64 };` — tagged union, tag + max payload size; payload fields are anonymous.

`enum(T)` (backed enum) is for "category of similar values" — all variants share `T` and storage is `sizeof(T)` directly. `union` is for variants whose payload types may differ (`Shape { Circle(f64), Rect(f64, f64) }`). The two keywords are deliberately separated so the "category of similar values" form (enums) doesn't pay for a per-variant tag that's redundant when all variants share `T`.

**Pick the keyword that matches your payload shape — not both.** A declaration is either an enum OR a union, not both. If you start typing `enum` and realize you need a heterogeneous payload, switch the keyword to `union` (and vice-versa). Both keywords support pattern matching in `match` arms; the distinction is payload-binding (`V(x) =>` extracts the payload's fields) which only `union` (and `enum(T)`'s bare variants) provide.

> **Today's compiler.** The keywords are interchangeable in today's compiler — both `enum` and `union` accept bare, paren-positional, and brace-named-field declaration shapes. The split above describes the canonical direction: bare-only for `enum`, payload-bearing for `union`. Prefer `union` for any payload-bearing declaration so your source aligns with the canonical surface.

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

For partial matches, use `_` as the catch-all pattern:

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

Parens (not angle brackets) signal that `T` is a concrete backing type, not a generic parameter. Per [Generics](17-generics.md), `<T>` introduces a type variable into scope while `(T)` wraps a concrete type. See [`examples/types/enum_backed.zag`](../../examples/types/enum_backed.zag) for the end-to-end runnable demonstration covering `enum(u8)`, `enum(str)`, `enum(char)`, and the auto-inferred `enum(u8)` shape.

An `enum` may declare a backing type `T`. The supported `T` universe is restricted to integer types, `bool`, `char`, and `str` — custom `Copy` struct/enum/array types as `T` are deferred. Each variant identifier is bound to a value of type `T` at compile time:

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
- For str-backed enums, every variant MUST carry `= "value"` (zig's `const`-field requires an initializer; zig rejects an empty const-decl without one). Omitting the value routes through the codegen's `""` fallback (same string-literal syntax as the empty `="\\"\\""` source-side form).
- For int-/char/bool-backed enums, `= v` is OPTIONAL — variants without an explicit value auto-infer (zig picks the next T-value, walking up from the prior variant — `First = 0`, `Second = 1`, `Third = 2` for an all-implicit `enum(u8)`).
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

# Equality compares T-values:
let ok_high: bool = (Level.High == "high");      # true — the value IS "high"
let ok_eq:    bool = (Status.Ok   == Status.Ok);  # true — both 0
let ok_neq:   bool = (Status.Ok   != Status.Err); # true — 0 != 2
```

**Provided methods:**
- **Equality (`==`)** — **value-based** for `enum(T)`: compares `T`-values. `Level.High == "high"` (T=str) and `Status.Ok == Status.Ok` (T=u8) are both `true`. Compare with default `enum { … }`, where equality is **tag-based** (variants are equal only to themselves).
- **`from_str(s: str) -> Option<Enum>`** — provided whenever `T = str`; returns `None` for unrecognized strings.
- **Display** — auto-implemented; writes the `T`-value via `T`'s own display formatter.

**Cross-construction rules:**
- `let x: Level = "low";` — bind by T-value; compile error if `"low"` doesn't match a registered variant.
- `Level.High` and the literal `"high"` are interchangeable **in any binding position whose expected type is `Level`** (`: Level` annotation, `match` scrutinee of type `Level`, function parameter of type `Level`). In free-context bindings (e.g. `let s = "high";`, no annotation), the literal is a borrowed string view, not `Level` — there is no implicit coercion.

> **Rust users take note:** `enum(str) Level { High = "high" }` introduces true value-equality (`Level.High == "high"`). This differs from Rust's bare-reference enum, where `High == "high"` is a compile error (different types). Read the provided methods above as the binding contract.

**Combining with FFI:** `@[repr(C, T1)] enum(T2) X { … }` keeps `T2` as the zag-side value type while using `T1` for the C-ABI footprint. The compiler synthesizes the conversion at FFI boundaries. See [FFI and Interop](25-ffi.md) for the full interaction.

## Repr Control

`@[repr(C, T)]` constrains an enum's tag width and layout to match a C-compatible representation:

```zag
@[repr(C, i32)]
enum CError {
    Ok = 0,
    NotFound = 1,
    Permission = 2,
}
```

The tag type follows `T`; explicit `= N` discriminants pin specific values. FFI requires `@[repr(C, T)]` if a C-side enum is involved. `@[repr(C, T1)] enum(T2) X { … }` composes: see [Backed Enums](#backed-enums-enumt) above.

## `Error` Type

The canonical error type in the standard library is an `enum Error { NotFound, Permission, Io, Parse, InvalidInput, Unavailable, Other }` — all bare variants, hence `enum`, not `union`. See [Error Handling](19-error-handling.md) for the full discussion.

## See Also

- [Unions](14-unions.md) — tagged unions / sum types
- [Pattern Matching](28-pattern-matching.md) — full `match` syntax
- [Spec](../spec.md) — canonical language spec; enums, backed enums, and unions live in §3.3 Compound Types
