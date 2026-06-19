# Defer and Errdefer

## `defer`

`defer` runs when the current scope exits, in **reverse order** of declaration:

```
fun read_file(path: str) -> Result<[]u8, Error> {
    let fd = open(path)?;
    defer close(fd);            # runs AFTER the next defer

    let buf = alloc(1024);
    defer free(buf as *raw c_void);  # runs FIRST

    return Ok(buf);
}
```

Execution order: `free(buf)` then `close(fd)`.

## `defer` on Error Paths

`defer` runs on **all** exit paths — normal return, error propagation, and panic:

```
fun process() {
    let a = acquire();
    defer release(a);     # runs regardless of how we exit

    if error {
        return;           # defer runs
    }
    # defer also runs here
}
```

## `errdefer`

`errdefer` runs **only** on error paths (`?` propagation or `return Err(...)`):

```
fun read_into(path: str) -> Result<[]u8, Error> {
    let fd = open(path)?;
    defer close(fd);            # always runs

    let buf = alloc(1024);
    errdefer free(buf as *raw c_void);  # only runs if read fails

    let n = read(fd, buf)?;     # if this fails, buf is freed
    return Ok(buf[0..n]);       # if this succeeds, buf is NOT freed
}
```

**Memory:** `errdefer` is the standard pattern for partial initialization. It cleans up resources allocated before an error, without duplicating `free` calls on the success path.

## Common Patterns

### Resource Acquisition

```
fun transaction(db: *Database) -> Result<(), Error> {
    let tx = db.begin()?;
    errdefer tx.rollback();

    tx.execute("INSERT ...")?;
    tx.execute("UPDATE ...")?;

    return tx.commit();    # errdefer does NOT run
}
```

### Multiple Resources

```
fun complex_init() -> Result<State, Error> {
    let a = init_a()?;
    errdefer free_a(a);

    let b = init_b()?;
    errdefer free_b(b);

    let c = init_c()?;
    errdefer free_c(c);

    return Ok(State { a: a, b: b, c: c });
    # On success: no errdefer runs
    # On failure at init_c: free_b, free_a run (reverse order)
    # On failure at init_b: free_a runs
}
```

## Summary

| Construct | Normal exit | Error exit | Panic |
|-----------|-------------|------------|-------|
| `defer` | Runs | Runs | Runs |
| `errdefer` | Does NOT run | Runs | Runs |
