# Control Flow

## `if` / `else`

```
if condition {
    do_something();
} else {
    do_other();
}
```

`if` is an expression — it returns a value:

```
let x = if ready { 1 } else { 0 };
```

**Memory:** No allocation. Condition and branches are stack-only.

## `if let`

Destructure and execute only if the pattern matches:

```
if let Option.Some(val) = risky() {
    process(val);
}
```

Equivalent to:

```
match risky() {
    Option.Some(val) => process(val),
    _ => {},
}
```

## `while`

```
while condition {
    do_work();
}
```

## `while let`

Repeatedly destructures until the pattern fails:

```
while let Option.Some(line) = reader.read_line() {
    process(line);
}
```

Equivalent to:

```
while true {
    match reader.read_line() {
        Option.Some(line) => process(line),
        Option.None       => break,
    }
}
```

## `for`

Iterate over ranges or iterators:

```
for i in 0..100 {
    print("{i}\n");
}

for item in collection {
    process(item);
}

for (k, v) in map.iter() {
    print("{k} -> {v}\n");
}
```

**Memory:** The iterator is stack-allocated. `for` calls `next()` on each iteration — no heap allocation.

## `match`

Pattern matching with exhaustive checks.

For partial matches, use `_` as the catch-all pattern. Pair it with the arms you want to handle and let `_` cover the rest (see [Pattern Matching → Exhaustiveness](28-pattern-matching.md#exhaustiveness) for the canonical exhaustive vs. catch-all pairing):

```
match opt {
    Option.Some(x) => use(x),
    _              => default(),    # covers Option.None
}
```

For full exhaustiveness — every variant enumerated, no catch-all — the canonical form is:

```
match value {
    Option.Some(x) => return x,
    Option.None    => return 0,
}

match cmd {
    Read(path) if path.len > 0 => open(path),
    Read(_)                    => panic("empty path"),
    Write(data)                => flush(data),
    Close                      => shutdown(),
}

match x {
    0      => "zero",
    1..9   => "digit",
    _      => "other",
}
```

**Memory:** Pattern matching is compiled to a decision tree. No allocation.

## `break` and `continue`

```
while true {
    if done {
        break;           # exit loop
    }
    if skip {
        continue;        # skip to next iteration
    }
    do_work();
}
```

`break` can return a value from the loop:

```
let result = while true {
    let val = compute();
    if val > 100 {
        break val;       # loop evaluates to val
    }
};
```

## `return`

```
fun add(a: i32, b: i32) -> i32 {
    return a + b;
}
```

Functions without `-> T` return `void`. `return;` is equivalent to `return {};`.

## `defer`

Runs when the current scope exits, in reverse order of declaration:

```
fun read_file(path: str) -> Result<[]u8, Error> {
    let fd = open(path)?;
    defer close(fd);            # runs on scope exit

    let buf = alloc(1024);
    defer free(buf);            # runs after close(fd)

    return Ok(buf);
}
```

**Memory:** `defer` ensures cleanup. `free` runs automatically when the scope exits — no forgotten deallocations.

## `errdefer`

Runs only on error paths (`?` propagation or `return Err(...)`):

```
fun read_into(path: str) -> Result<[]u8, Error> {
    let fd = open(path)?;
    defer close(fd);

    let buf = alloc(1024);
    errdefer free(buf);         # only runs if read fails

    let n = read(fd, buf)?;
    return Ok(buf[0..n]);       # buf is returned — errdefer does NOT run
}
```

**Memory:** `errdefer` is the standard pattern for partial initialization cleanup.

## `panic`

Terminates the current thread. Deferred cleanups run:

```
panic("out of memory");
```

**Memory:** Stack is unwound within the thread. Deferred cleanups (`defer`) run.
