# Concurrency

Zag inherits zig's concurrency model. Threads, mutexes, and atomics map directly to zig stdlib calls. The concurrency module lives at `std.concurrent.*`:

```
import std.concurrent.atomic
import std.concurrent.thread
import std.concurrent.mutex
```

## Atomics (`std.concurrent.atomic`)

Lock-free, single-instruction primitives for shared-memory concurrency:

```
import std.concurrent.atomic

fun main() {
    let ptr: *i32 = new i32(0);
    defer free(ptr);

    store(ptr, 42);
    let val: i32 = load(ptr);
    let old: i32 = fetch_add(ptr, 1);
    let cas: i32 = compare_exchange(ptr, old + 1, 99);
}
```

| Function | Emits | Use |
|---|---|---|
| `load(ptr)` | `@atomicLoad(T, ptr, .seq_cst)` | Read |
| `store(ptr, val)` | `@atomicStore(T, ptr, val, .seq_cst)` | Write |
| `fetch_add(ptr, val)` | `@atomicRmw(T, ptr, .Add, val, .seq_cst)` | RMW |
| `compare_exchange(ptr, old, new)` | `@cmpxchgStrong(T, ...)` | CAS |

## Threads (`std.concurrent.thread`)

`spawn(fn, args)` runs a function on a new OS thread. `join(handle)` blocks until exit:

```
import std.concurrent.thread

fun worker(id: i32) { print("thread {id}\n"); }

fun main() {
    let h = spawn(worker, (42));
    join(h);
}
```

## Mutexes (`std.concurrent.mutex`)

`create()`, `lock(m)`, `unlock(m)` wrap `std.Thread.Mutex`:

```
import std.concurrent.mutex

fun main() {
    let m = create();
    lock(m);
    # critical section
    unlock(m);
}
```

## Memory Model

Zag inherits zig's DRF (data-race-free) model. Use atomics or mutexes to guard shared mutable state. Non-atomic concurrent access is undefined behavior.

## Forward-looking

These modules build on `std.concurrent.*` primitives and are planned:

| Module | Built on | Description |
|---|---|---|
| `std.concurrent.channel` | Atomics | Bounded MPSC channel, inline ring buffer |
| `std.concurrent.pool` | Threads + Atomics | Work-stealing thread pool |
| `std.concurrent.rwlock` | Mutex | Read-write lock |
| `std.concurrent.waitgroup` | Atomics | WaitGroup for barrier synchronization |
| `std.concurrent.once` | Atomics | One-time initialization |

Each is implementable as a small zig struct emitted in the codegen preamble, with zag builtins wrapping its methods. The pattern: emit the zig type definition, then provide `channel_send`/`channel_recv`-style builtins that call its methods.
