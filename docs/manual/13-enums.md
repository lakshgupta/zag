# Enums

## Definition

Enums are tagged unions (algebraic data types):

```
enum Direction {
    North,
    South,
    East,
    West,
}

let dir = Direction.North;
```

**Memory:** Tagged union. Size = tag size + largest variant. `Direction` is 1 byte (1-byte tag).

## Enums with Data

```
enum Shape {
    Circle(f64),                    # radius
    Rectangle(f64, f64),           # width, height
    Triangle([3]f64),              # vertices
}
```

**Memory:** `Shape` is `max(sizeof(f64), sizeof([3]f64))` + tag = 24 + 1 = 25 bytes (with alignment).

## Pattern Matching

```
match shape {
    Shape.Circle(r) => {
        let area = 3.14159 * r * r;
        print("circle area: {area}\n");
    }
    Shape.Rectangle(w, h) => {
        let area = w * h;
        print("rect area: {area}\n");
    }
    Shape.Triangle(pts) => {
        print("triangle\n");
    }
}
```

## Option and Result

The standard library defines these core enums:

```
enum Option<T> {
    Some(T),
    None,
}

enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

## Exhaustiveness

`match` must be exhaustive — every variant must be handled:

```
match dir {
    Direction.North => ...,
    Direction.South => ...,
    Direction.East  => ...,
    Direction.West  => ...,
}
# omitting a variant is a compile error
```

Use `_` for a catch-all:

```
match dir {
    Direction.North => ...,
    _ => ...,
}
```

## Unqualified Variants

When the type is inferred, variants can be unqualified:

```
match result {
    Ok(val) => process(val),       # unqualified
    Err(e) => handle_error(e),     # unqualified
}
```

## Custom Error Enums

```
enum MyError {
    NotFound,
    Timeout,
    Custom(str),
}

fun risky() -> Result<i32, MyError> {
    return Err(MyError.Timeout);
}
```

**Memory:** Enums are stack-allocated. No heap allocation unless a variant contains a heap type (`String`, etc.).
