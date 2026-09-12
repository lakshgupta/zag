# Concurrency

Zag's concurrency lives at `std.concurrent.*`. Threads are real
clone(2) threads (see below); atomics are language intrinsics
router-emitted by the compiler (they need no import); and the
synchronization primitives — mutex, semaphore, once, rwlock — are
pure-Zag futex protocols over those intrinsics plus `std.posix`'s
futex/wait/wake syscalls. No zig-stdlib `Thread` involvement
anywhere:

```
import std.concurrent.thread.{spawn, join, Thread}
import std.concurrent.mutex
import std.concurrent.semaphore
import std.concurrent.once
import std.concurrent.rwlock
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

## Semaphore (`std.concurrent.semaphore`)

A pure-Zag counting semaphore — the count is a futex-addressable
`u32` driven by the atomic intrinsics and `std.posix`'s private
futex primitives:

```
import std.concurrent.semaphore

var sem: Semaphore = create(0);
wait(&sem);   # take a unit (parks in the kernel at 0)
post(&sem);   # give a unit (wakes one parked waiter)
```

`wait` is a single CAS while the count is positive and a
`FUTEX_WAIT_PRIVATE` park at 0; `post` is a `fetch_add(1)` plus a
single-waiter wake. Surplus posts raise the count for later
waiters. See `examples/concurrency/semaphore.zag` for bounded
concurrency, exact unit accounting, and the park path.

## Once (`std.concurrent.once`)

Run-once initialization over the classic 3-state protocol
(INCOMPLETE → RUNNING → COMPLETE) on a futex-addressable word:

```
import std.concurrent.once

var o: Once = create();
call_once(&o, init_fn, payload);   # runs init_fn(payload) once
```

The first thread to CAS 0→1 runs `f(payload)`; concurrent callers
park until the run completes, late callers return on the fast path.
A panicking run resets the word so a later call can retry. The fn
ABI is the thread-body ABI (`*const fn (usize) void`), so state
passes by pointer without closures. See
`examples/concurrency/once.zag` for the 8-thread race proof.

## RwLock (`std.concurrent.rwlock`)

A writer-preferring reader/writer lock on a single `i32` word
(bit 30 = writer interest, bits 0..29 = active reader count):

```
import std.concurrent.rwlock

var l: RwLock = create();
read_lock(&l);    # many readers hold concurrently
# ... read shared state ...
read_unlock(&l);

write_lock(&l);   # exclusive: drains readers, blocks new ones
# ... mutate shared state ...
write_unlock(&l); # wakes every parked reader/writer
```

Once a writer sets the interest bit, new readers park instead of
joining, so a reader stream cannot starve the writer; existing
readers drain, the last one out wakes the writer, and release wakes
everything (wake count `INT_MAX` — the kernel takes the
`FUTEX_WAKE` count signed, so `UINT_MAX` would wake exactly one
waiter and strand the rest). See
`examples/concurrency/rwlock.zag` for reader concurrency, writer
exclusion, the block park path, and the wake-all release.

## Memory Model

Zag inherits zig's DRF (data-race-free) model. Use atomics or mutexes to guard shared mutable state. Non-atomic concurrent access is undefined behavior.

## Forward-looking

These modules build on `std.concurrent.*` primitives and are planned:

| Module | Built on | Description |
|---|---|---|
| `std.concurrent.channel` | Atomics | Bounded MPSC channel, inline ring buffer |
| `std.concurrent.pool` | Threads + Atomics | Work-stealing thread pool |
| `std.concurrent.waitgroup` | Atomics | WaitGroup for barrier synchronization |

Each is implementable in pure Zag on the same pattern as the
primitives above: a futex-addressable word driven by the atomic
intrinsics plus `std.posix`'s futex/wait/wake syscalls — no
zig-stdlib involvement, no codegen preamble helpers.
