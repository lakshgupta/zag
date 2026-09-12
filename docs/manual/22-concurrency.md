# Concurrency

Zag's concurrency lives at `std.concurrent.*`. Threads are real
clone(2) threads (see below); atomics are language intrinsics
router-emitted by the compiler (they need no import); mutexes are
still a stub:

```
import std.concurrent.thread.{spawn, join, Thread}
```

## Atomics (`std.concurrent.atomic`)

`load`, `store`, `fetch_add`, and `compare_exchange` are compiler
intrinsics (built into the language — no import needed). They emit
`@atomicLoad` / `@atomicStore` / `@atomicRmw` / `@cmpxchgStrong`
with seq_cst ordering at the call site. `std.concurrent.atomic` is
importable (its decls document the surface and whole-module
`import std.concurrent.atomic` binds the names), but importing is
optional: the intrinsics resolve whether or not you import.

Lock-free, single-instruction primitives for shared-memory concurrency (intrinsics — no import needed):

```
fun main() {
    let ptr: *i32 = new i32(0);
    defer free(ptr);

    store(ptr, 42);
    let val: i32 = load(ptr);
    let old: i32 = fetch_add(ptr, 1);
    let ok: bool = compare_exchange(ptr, old + 1, 99);
}
```

| Function | Emits | Use |
|---|---|---|
| `load(ptr)` | `@atomicLoad(T, ptr, .seq_cst)` | Read |
| `store(ptr, val)` | `@atomicStore(T, ptr, val, .seq_cst)` | Write |
| `fetch_add(ptr, val)` | `@atomicRmw(T, ptr, .Add, val, .seq_cst)` | RMW (returns old) |
| `compare_exchange(ptr, expected, new)` | `(@cmpxchgStrong(T, ...) == null)` | CAS — returns `true` when swapped |

`compare_exchange` returns the CAS **success flag** as a plain
`bool`: `true` means the word still held `expected` and now holds
the new value; `false` means another writer intervened (re-read with
`load` and retry — this is what lock loops build on, see
`std.concurrent.mutex.lock`).

## Mutex (`std.concurrent.mutex`)

A pure-Zag futex mutex — the lock word is a futex-addressable `i32`
driven by the atomic intrinsics above and `std.posix`'s private
futex primitives. No zig-stdlib Mutex involvement:

```
import std.concurrent.mutex

var m: Mutex = create();
lock(&m);      # CAS 0→1 fast path; kernel park when contended
# critical section
unlock(&m);    # wake one parked waiter only if any
```

The implementation is the classic Drepper Type-2 state machine: the
word is 0 (unlocked), 1 (locked, no waiters), or 2 (locked, waiters
parked). The uncontended path is a single CAS on lock and a single
`fetch_add` on unlock — zero syscalls; the contended path parks in
`FUTEX_WAIT_PRIVATE` and is woken by `FUTEX_WAKE_PRIVATE` from the
releasing `unlock`. See `examples/concurrency/mutex.zag` for a
cross-thread demonstration of both mutual exclusion (exact count
with non-atomic updates under the lock) and the park path.

## Threads (`std.concurrent.thread`)

Real threads over the raw clone(2) syscall — no zig-stdlib Thread
involvement. `spawn(body, payload)` starts `body(payload)` on a new
kernel thread; `join(handle)` parks the caller on the kernel's
child-tid futex (`CLONE_CHILD_CLEARTID`) — a zero-syscall fast path
when the child already exited, a kernel park otherwise. The body is
`fun (usize)`: one usize payload word. Pass a pointer through it
(multiple values go through a pointer to a struct):

```
import std.concurrent.thread.{spawn, join, Thread}

fun worker(_: usize) { print("thread\n"); }

fun main() {
    let h: Thread = spawn(worker, 0);
    join(h);
}
```

The child runs on a 128KB stack allocated by `std.mem.alloc` and
released by `join`.

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
