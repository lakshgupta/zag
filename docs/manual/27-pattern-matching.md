# Pattern Matching

## `match` Expression

```
match value {
    pattern1 => result1,
    pattern2 => result2,
    _        => default,
}
```

## Literals

```
match x {
    0      => "zero",
    1      => "one",
    2..9   => "digit",
    _      => "other",
}
```

## Enum Variants

```
match option {
    Option.Some(val) => process(val),
    Option.None      => default(),
}

# Unqualified when type is inferred:
match result {
    Ok(val)  => handle(val),
    Err(err) => fail(err),
}
```

## Guards

```
match cmd {
    Read(path) if path.len > 0 => open(path),
    Read(_)                    => panic("empty path"),
    Write(data)                => flush(data),
    Close                      => shutdown(),
}
```

## Destructuring

```
# Tuples
let (x, y) = point;

# Structs
let Vec3 { x, y, z } = v;

# Arrays
let [a, b, c] = arr;

# Nested
match data {
    (0, _)           => "starts with zero",
    (_, 0, _)        => "second is zero",
    (a, b, c) if a == b => "first two match",
    _                => "other",
}
```

## `if let`

```
if let Option.Some(val) = risky() {
    process(val);
}
```

## `while let`

```
while let Option.Some(line) = reader.read_line() {
    process(line);
}
```

## Exhaustiveness

`match` must handle every possible value:

```
match dir {
    Direction.North => ...,
    Direction.South => ...,
    Direction.East  => ...,
    Direction.West  => ...,
}
# Missing a variant is a compile error
```

Use `_` for a catch-all:

```
match result {
    Ok(val) => process(val),
    _       => {},    # catch-all
}
```

## Range Patterns

```
match age {
    0       => "newborn",
    1..12   => "child",
    13..19  => "teenager",
    _       => "adult",
}
```

**Memory:** Pattern matching is compiled to a decision tree. No allocation.
