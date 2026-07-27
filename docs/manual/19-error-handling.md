# Error Handling

Zag uses `Result<T, E>` and `Option<T>` for error handling. No exceptions.

## Result

`Result` is a `union` (tagged union) because its variants carry payloads:

```zag
union Result<T, E> {
    Ok(T),
    Err(E),
}
```

```zag
fun divide(a: f64, b: f64) -> Result<f64, str> {
    if b == 0.0 {
        return Err("division by zero");
    }
    return Ok(a / b);
}

match divide(10.0, 3.0) {
    Ok(val) => print("{val}\n"),
    Err(msg) => print("error: {msg}\n"),
}
```

## Option

`Option` is a `union` because it mixes a payload variant (`Some(T)`) with a bare variant (`None`):

```zag
union Option<T> {
    Some(T),
    None,
}
```

**Mixed bare + payload variants** are fully supported by `union`. The bare form `None` is constructed without parentheses (`Option.None`); the payload form `Some(x)` carries the value (`Option.Some(42)`). Pattern matching destructures per variant: `match opt { Option.Some(x) => use(x), Option.None => bail() }`.

```zag
fun find(arr: []i32, target: i32) -> Option<usize> {
    for i in 0..arr.len {
        if arr[i] == target {
            return Option.Some(i);
        }
    }
    return Option.None;
}
```

## `?` — Error Propagation

```
fun read_config(path: str) -> Result<Config, Error> {
    let fd = open(path)?;          # propagates Err on failure
    defer close(fd);

    let data = read(fd)?;
    let config = parse(data)?;
    return Ok(config);
}
```

`?` on `Result<T, E>` returns `Err(e)` early. `?` on `Option<T>` returns `None` early.

### `?` with Tuple Returns

When a function returns a tuple containing a `Result`, `?` applies to the `Result` element and binds the rest:

```
fun parse(input: str) -> (Result<Config, Error>, u32) {
    # returns (parsed config or error, bytes consumed)
}

# ? propagates the Result, binds the u32
let (config, consumed) = parse(data)?;
```

The `?` operates on the outer `Result`. If the function returns `Result<T, E>` as one element of a tuple, `?` propagates the error and the remaining elements bind normally.

**Cross-type `?` is not implicit:**

```
# ERROR: cannot ? on Option inside Result
fun process() -> Result<i32, Error> {
    let val = maybe()?;    # compile error: Option ? in Result context
    return Ok(val);
}

# FIX: convert explicitly
fun process() -> Result<i32, Error> {
    let val = maybe().ok_or(Error.NotFound)?;   # Option -> Result
    return Ok(val);
}
```

## `catch` — Handle Errors

`_` inside `match err { … }` catches both bare variants (`Error.Io`, `Error.Permission`) and payload variants on a custom error union (`MyError.Custom(msg)`). See [Exhaustiveness](#exhaustiveness) below for the paired exhaustive + catch-all shape:

```
# Block form — error value bound
let val = risky() catch |err| {
    eprint("error: {err}");
    return 0;
};

# Default value form
let val = risky() catch 0;

# Match on the error
let val = risky() catch |err| {
    match err {
        Error.NotFound => return 0,
        _              => return err,
    }
};
```

## Error Type

The canonical error type is `enum` (used bare, no payloads), and is zero-alloc:

```zag
enum Error {
    NotFound,
    Permission,
    Io,
    Parse,
    InvalidInput,
    Unavailable,
    Other,
}
```

**Memory:** `Error` is 1 byte (tag only). No heap allocation.

## Error Context

For cases needing context (HTTP handlers, database queries):

```
import std.error

fun read_config(path: str) -> Result<Config, Context> {
    let data = fs.read(path)?
        .context_str("failed to read config file")?;
    let config = parse(data)?
        .context("failed to parse config")?;
    return Ok(config);
}
```

**Memory:** `Context` wraps `Error` with an optional `String` message. Only allocated when `.context()` is called.

## Custom Error Types

When an error type carries data on any variant, use `union` instead of `enum`:

```zag
union MyError {
    NotFound,
    Timeout,
    Custom(str),
}

fun risky() -> Result<i32, MyError> {
    return Err(MyError.Timeout);
}

# Works with catch
let val = risky() catch |err| {
    match err {
        MyError.NotFound => 0,
        MyError.Timeout  => -1,
        MyError.Custom(msg) => {
            eprint("{msg}\n");
            -2
        }
    }
};
```

## Exhaustiveness

`match err { … }` inside a `catch` block must be exhaustive — every variant of the error type must be handled. Omitting a variant is a compile error:

```zag
match risky() catch |err| {
    MyError.NotFound         => 0,
    MyError.Timeout          => -1,
    MyError.Custom(msg)      => { eprint("{msg}\n"); -2 },
}
# omitting any of NotFound / Timeout / Custom is a compile error
```

Use `_` for a catch-all (covers all unlisted variants):

```zag
match risky() catch |err| {
    MyError.NotFound => 0,
    _                => -99,    # catches Timeout (and any future variants)
}
```

## Memory Summary

| Construct | Allocation |
|-----------|------------|
| `Result::Ok(val)` | Stack only (tag + value) |
| `Result::Err(e)` | Stack only (tag + error) |
| `?` propagation | No allocation — early return |
| `catch` block | No allocation — branch |
| `Context` | Heap only when `.context()` called |
| `Error` enum | 1 byte, no heap |
