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

## `!` — Panicking Unwrap

`?` propagates an error and `catch` recovers from one. The third policy is
**fail fast**: postfix `!` yields the `Ok`/`Some` value and panics on
`Err`/`None`, naming the operation and the source location.

```zag
let data: String = read_file("config.toml")!;   # panic if it cannot be read
let n: i64 = parse_i64(text)!;                  # panic if the text is not a number
```

`!` is the mirror of `?`, so the same expression supports every policy at the
call site:

```zag
let a = read_file(p)!;        # panic (fail fast)
let b = read_file(p)?;        # propagate to my caller
let c = read_file(p) catch default_text();   # fall back
match read_file(p) { Ok(d) => use(d), Err(e) => report(e) }   # branch
```

Why this matters for a library: because the caller spells the policy, an API
publishes **one** function per operation, named for the operation rather than
for its failure mode. There is no second, panicking spelling that can drift
out of step — `read_file(p)` is the value form and `read_file(p)!` is the
panicking one, the same call with one character appended. That is why the
stdlib dropped the `_or` suffix (and, before it, the `*_or_panic` twins): once
`!` carries the policy, a suffix that also encodes it only duplicates the
information and gives the two spellings somewhere to disagree.

Notes:

* `!` works on `Result(T, E)` **and** `Option(T)`. On `Result` it panics with
  the `Err` payload; on `Option` it panics on `None`.
* It binds tighter than any operator, so `!` applies to the whole call
  (`f.read_at(buf, off)!`, not `f.read_at(buf, off!)`).
* `!=` is a single token, so `a != b` is never read as `(a!) = b`.
* Inside an interpolation, `{f.size()!}` works — the placeholder parser accepts
the trailing `!`.

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

## Errors from the Standard Library

The language surface above is deliberately small. The standard library follows
one rule on top of it — **fail closed**: an operation that cannot complete
returns an error value, and an operation that cannot report an error must say
so in its name.

### `std.error` — the canonical error type

`Error` (above) is the shared error type for IO. The filesystem and streaming
APIs collapse the kernel's errno into it:

| errno | `Error` variant |
|-------|-----------------|
| `ENOENT` | `Error.NotFound` |
| `EPERM`, `EACCES` | `Error.Permission` |
| everything else | `Error.Io` |

So a caller can tell "missing" from "denied" without inspecting a raw syscall
return:

```zag
match read_file("config.toml") {
    Ok(data) => parse(data),
    Err(Error.NotFound) => use_defaults(),
    Err(Error.Permission) => return Err(Error.Permission),
    Err(e) => return Err(e),
}
```

### `std.errno` — the errno vocabulary

When that mapping is too coarse, `std.posix` hands back the errno itself.
`std.errno` names every code:

```zag
import std.errno.{Errno, ErrnoKind}

match openat(std.posix.AT.FDCWD, path, 0, 0) {
    Ok(fd) => use(fd),
    Err(e) => {
        if (e.is(ErrnoKind.Noent)) { return Err(Error.NotFound); }
        # The exact code survives even when it has no named kind:
        print("open failed: {e.name()} (errno {e.code})\n");
        return Err(Error.Io);
    },
}
```

`ErrnoKind` covers the codes callers branch on (`Noent`, `Eacces`, `Eisdir`,
`Enospc`, `Eexist`, `Eagain`, `Enotdir`, …). `e.name()` still renders a
faithful `errno 1234` for a number the named set does not cover, so nothing is
lost by not enumerating every errno the kernel can return.

### `std.posix` — two tiers

Every fallible entry point exists twice:

| Form | Returns | Use for |
|------|---------|---------|
| `name(...)` | `Result(T, Errno)` | the default — checked and ergonomic |
| `raw_name(...)` | the kernel's value verbatim (`usize` / `isize`) | hot loops that own their own errno policy |

The canonical tier is the only place the high-bit-set-`usize` /
negative-`isize` convention is decoded. `EINTR` is retried inside
`read_some` / `read_full` / `write_full` and never surfaces as a failure. Only
where a `raw_` twin would be meaningless is it absent — `clock_gettime` and
`getcwd` need a success-side out-parameter, `spawn` is a composition (arena +
`environ` + fork + `execve` + `waitpid`) rather than one syscall, and `gettid`
cannot fail.

### `std.fs.File` — a `Result` handle

`File` returns `Result(_, Error)` from every operation that can fail, and there
is exactly **one** spelling of each operation — the failure policy is chosen at
the call site with `!` / `?` / `catch` / `match`:

```zag
import std.fs.{File, FileMode}

# One constructor, mode explicit: Read / Rw / Append / Create.
var f: File = File.open("log.bin", FileMode.Create)!;   # panic on failure
let g: Result(File, Error) = File.open("log.bin", FileMode.Read);   # recoverable

match File.open("log.bin", FileMode.Rw) {
    Ok(h) => {
        _ = h.append("…")!;
        h.close_durable()!;   # fsync contents, checked close, fsync parent
    },
    Err(Error.Permission) => eprint("not writable\n"),
    Err(e) => return Err(e),
}

let size: usize = f.size()!;   # the panicking spelling of the same call
```

The mode is mandatory because `File` lives in an imported module: method
overloading resolves against a type's own `impl` table, which the *calling*
module cannot see across a module boundary, so `File.open(path)` /
`File.open(path, mode)` could not be one name. One explicit signature works
from every module (see [Method Overloading](30-method-overloading.md)
§"Across modules").

`close_durable` flushes the contents **and** the directory entry when the
handle created the file, so a "successful" write is durable. `write_file`
and `read_file` are the whole-file free functions (both `Result`), and
`write_file(p, bytes)!` is the fail-fast form. Nothing in this layer
silently short-reads, and a failed write is never reported as success. The
`examples/error-handling/` fixtures (`io_robustness.zag`, `posix_tier.zag`,
`recoverable_io.zag`) run these paths at runtime.

### Discarding a result on purpose

`_ = f.close();` compiles, and that is exactly why a dropped failure can hide in
a library: the compiler cannot tell a harmless discard from a silent data-loss
path. Where the discard is genuinely the right call, **say so on the same line**:

```zag
# read-only descriptor: the read errno above is the primary failure
_ = close(fd); # deliberate discard: read-only fd, no buffered write to report
```

The phrase `deliberate discard` (case-insensitive) is what
`zig build audit` looks for. That step fails the build when a `lib/std` source
line discards the result of a close/sync or transfer call — `close`, `sync`,
`fsync`, `fdatasync`, `write`/`write_full`/`write_at`/`write_block`,
`append`, `read`/`read_full`/`read_at`/`read_block`, and the `pread`/`pwrite`
forms — without the marker. `zig build test` runs it too, so the check rides
along with the usual test command.

The audit scans `lib/std/**/*.zag` **and** `src/**/*.zig`, so it applies to the
compiler's own Zig code as much as to the standard library — `waitpid`, `dup2`,
`lseek`, and `ftruncate` are in the set alongside the transfer family. A few
callee families are intentionally outside it: `futex_wait`, whose `EAGAIN` on a
spurious wakeup is a normal return; `nanosleep_retry`, `fetch_add`, `release`;
`execve`, which only returns on failure and is followed immediately by
`exit(127)`; and `mkdirat`/`mkdir`/`unlink`, where `EEXIST`/`ENOENT` are the
expected results.

Two named escapes cover the common "the error I am already returning is the
report" shapes, so they do not need a marker and read the same everywhere:
`sys.closeOnErrorPath(fd)` in Zig, and the in-line marker in Zag.

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
