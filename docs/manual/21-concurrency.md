# Concurrency

## Threads

```
import std.thread

let handle = thread.spawn {
    heavy_computation();
};
handle.join();
```

**Memory:** `thread.spawn` allocates a thread stack (OS-managed). The closure is moved to the new thread.

## Async/Await

Async functions return `Future<T>` — a state machine struct with **zero heap allocation**:

```
async fun handle_conn(c: TcpConn) -> Result<(), Error> {
    let req = await c.read_request()?;
    let resp = process(req);
    await c.write_response(resp)?;
    return Ok(());
}
```

**Memory:** The `Future<T>` is a stack-allocated state machine. `await` yields back to the event loop and resumes when I/O completes. No heap allocation per task.

## Task Spawning

```
async fun serve(addr: SocketAddr) {
    let listener = await TcpListener.bind(addr)?;
    while true {
        let conn = await listener.accept()?;
        let task = task.spawn(handle_conn(conn));  # returns Task<T>
        task.detach();    # fire-and-forget
    }
}
```

**Memory:** `task.spawn` submits the state machine to the thread pool. `Task<T>` is a stack-allocated handle.

## Structured Concurrency

`task.scope` guarantees all spawned tasks complete before the scope exits:

```
async fun handle_request(req: Request) -> Result<Response> {
    let result = task.scope { scope =>
        scope.spawn(fetch_user(req.user_id));
        scope.spawn(fetch_posts(req.user_id));
        scope.spawn(fetch_notifications(req.user_id));

        let (user, posts, notifications) = await scope.join_all();
        return Ok(Response { user, posts, notifications });
    };
    return result;
}
```

**Memory:** Scope tracks all child tasks. On error or scope exit, remaining children are cancelled and joined. No leaked tasks.

## Channels

Bounded MPSC channels for thread/task communication:

```
let (tx, rx) = channel<i32>(1024);

thread.spawn {
    let _ = tx.send(42);           # blocks if full, returns Result<(), SendError>
};

let v: Option<i32> = rx.recv();     # blocks until value (or None if closed)
```

**Memory:** `channel<T>(N)` ring buffer is inline in the channel struct — no heap. Channel size must be a compile-time constant. **Warning:** Large `T` (e.g., >256 bytes) may cause stack overflow on `send`/`recv` because the ring buffer slot is stack-allocated. Use `channel.heap<T>(N)` for heap-backed slots: `let (tx, rx) = channel.heap<LargeStruct>(1024);`.

## Select

Wait on multiple futures:

```
let result = select {
    data = socket.read() => data,
    _ = timer.after(Duration.from_secs(5)) => Err("timeout"),
};
```

The first future to complete executes its branch; others are cancelled. Polling order is round-robin — the branch polled first advances by one after each full round, guaranteeing no branch is starved.

## Cancellation

```
async fun long_running(token: CancellationToken) {
    select {
        _ = token.cancelled() => return,
        result = do_work() => handle(result),
    }
}

async fun parent() {
    let token = CancellationToken.new();
    task.spawn(long_running(token.child()));
    task.spawn(long_running(token.child()));

    await timer.after(Duration.from_secs(5));
    token.cancel();    # cancels all children
}
```

**Memory:** `CancellationToken` is an atomic flag + child token list. `cancel()` sets the flag and wakes waiters.

## Blocking in Async

Never call blocking functions directly from async:

```
#[blocking]
fun blocking_db_query(query: str) -> Result<Rows, Error> { ... }

async fun handler() {
    # BAD: blocks the event loop
    # let rows = blocking_db_query(sql)?;

    # GOOD: run in thread pool
    let rows = await task.spawn_blocking { blocking_db_query(sql) }?;
}
```

## Memory Summary

| Construct | Allocation |
|-----------|------------|
| `async fun` | Stack-allocated state machine |
| `await` | Yield to event loop, no allocation |
| `task.spawn` | Submit to thread pool, no heap |
| `task.scope` | Stack-allocated scope struct |
| `channel<T>` | Inline ring buffer, no heap |
| `channel.heap<T>` | Heap-backed ring buffer for large `T` |
| `CancellationToken` | Atomic flag + list, no heap |
| `thread.spawn` | OS thread stack (OS-managed) |

## Atomics

Atomic types provide lock-free concurrent access. Each operation maps to a single hardware instruction:

```
import std.atomic

var counter: AtomicI32 = AtomicI32.new(0);

counter.fetch_add(1, SeqCst);       # atomic increment
let val = counter.load(Acquire);     # atomic read
counter.store(42, Release);          # atomic write

# Compare-and-swap loop
loop {
    let old = counter.load(Relaxed);
    let result = counter.compare_exchange(old, old + 1, AcqRel, Relaxed);
    match result {
        Ok(_) => break,
        Err(_) => continue,          # retry — old value changed
    }
}
```

**Memory:** Atomics are stack-allocated structs. No heap. Operations are single instructions — `lock xadd`, `lock cmpxchg`, `mov` (with fence).

## Memory Model

Zag uses the **DRF => SC** model: if your program has no data races, it executes as if threads run in some sequential interleaving.

**What's a data race?** Two threads access the same non-atomic memory location, at least one is a write, and neither happens-before the other. Data races are undefined behavior.

**What's safe?** Atomic operations are never data races — even concurrent atomic writes are well-defined. Use `Acquire`/`Release` orderings to establish happens-before edges between threads.

**Happens-before rules for concurrency primitives:**

| Operation A | Operation B | Guarantee |
|-------------|-------------|-----------|
| `channel.send(val)` | `channel.recv()` returning `Some(val)` | A hb B — value visible |
| `channel.close()` | `channel.recv()` returning `None` | A hb B — close visible to receiver |
| `task.spawn(f)` | First instruction of task `f` | A hb B |
| `await` yields | Continuation after `await` | Prior writes hb after-await (even across threads) |
| `select` winning branch | Losing branches' cancellation cleanup | Winner's result hb loser cleanup |
| Child task completes in `task.scope` | `scope.join_all()` returns | Child's writes hb parent |
| `token.cancel()` | `token.cancelled()` future completes | A hb B |
| `thread.spawn` | Child thread's first instruction | A hb B |
| Child thread's last instruction | `handle.join()` returns | A hb B |
| `Mutex.lock()` → `unlock()` | Next `Mutex.lock()` | Unlock's writes hb next lock |
| `RwLock.read()` → `read_unlock()` | Next `RwLock.write_lock()` | Read unlock sw write lock |
| `RwLock.write()` → `write_unlock()` | Next `RwLock.read_lock()` or `write_lock()` | Write unlock sw next lock |
| `SeqCst` store on `M` | `SeqCst` load on `M` | Total order — no later load reads earlier value |
| `channel.close()` | `channel.send()` returning `SendError.Closed` | A hb B — close visible to sender |

Transitivity: if A hb B and B hb C, then A hb C.

These rules mean you can share non-atomic state safely through channels and structured concurrency without explicit atomics:

```
# WRONG — data race
var x: i32 = 0;
thread.spawn { x = 1; };
thread.spawn { let r = x; };

# RIGHT — atomic, well-defined
var x: AtomicI32 = AtomicI32.new(0);
thread.spawn { x.store(1, Release); };
thread.spawn { let r = x.load(Acquire); };
```

**Rule of thumb:** If you're sharing data between threads, use channels or structured concurrency (`task.scope`) for guaranteed safety, or atomics with explicit orderings for lock-free code. Never share non-atomic mutable state without a happens-before edge.

## Parallel Primitives

Thread pool for data-parallel work:

```
import std.thread

let pool = thread.ThreadPool.new(8);

# Parallel for-each
var data: []i32 = ...;
thread.parallel_for(&pool, data, |item| { item.* *= 2; });

# Parallel sort
thread.parallel_sort(&pool, data);

# Parallel reduce
let total = thread.parallel_reduce(&pool, data, |a, b| { a + b; });
```

**Memory:** Work is distributed via work-stealing. No heap allocation — threads pull chunks from a shared queue.

## Simplicity

Zag's concurrency model is intentionally minimal. You need only four primitives for all concurrent patterns:

| Pattern | Primitive |
|---------|-----------|
| Data parallelism | `parallel_for`, `parallel_sort`, `parallel_reduce` |
| Pipeline parallelism | `channel<T>` |
| Request parallelism | `async fun` + `task.spawn` |
| Lock-free algorithms | `atomic` operations |

No mutexes, semaphores, or condition variables needed for new code. These exist in `std.sync` only for C FFI interop.
