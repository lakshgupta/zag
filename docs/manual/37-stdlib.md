# Standard Library

Zag ships a standard library under `lib/std/` — plain `.zag` source
compiled by the same pipeline as user programs. Every module's
functions are imported explicitly:

```zag
import std.sort.{sort, binary_search}
import std.hash.{fnv1a32, crc32, sha256}
```

`std` (lib/std/mod.zag) is a barrel module re-exporting the public
surface of the modules below.

## Module index

| Module | Surface | Allocation |
|---|---|---|
| `std.types` | `String` (owned mutable UTF-8 buffer) | heap |
| `std.collections` | **directory module** (`lib/std/collections/`) — `ArrayList<T>` in `array_list.zag`, `HashMap<K, V>` in `hash_map.zag`, barrel `mod.zag` re-exports; each type can live in its own file | heap |
| `std.encoding` | `base64_encode/decode`, `hex_encode/decode`, `utf8_validate` | heap (encode/decode) |
| `std.hash` | `fnv1a32/64`, `crc32`, `sha256` | none |
| `std.random` | `XorShift64Star` (new / seed_from, next_u64/32/f64) | none |
| `std.fmt` | `Display`, `Writer`, `FmtError` | — |
| `std.time` | `Duration`, `Timer`, `now` | none |
| `std.atomic` | `AtomicI32/64/Usize/Bool`, `Ordering` | none |
| `std.bench` | `Counters` (allocation counters) | — |
| `std.mem` | `alloc` (keyword `free`), `memcpy` | heap |
| `std.argv` | `get` | heap |
| `std.env` | `get_env` (borrowed view) | none |
| `std.fs` | `read_file`, `write_file`, `mkdir`, `try_read`, `File` (Result-returning: `open(path, FileMode)` — `Read`/`Rw`/`Append`/`Create` — plus `read_at`, `write_at`, `read_block`, `write_block`, `append`, `size`, `block_count`, `truncate`, `sync`, `datasync`, `fsync_parent`, `close`, `close_durable`), `FileMode`, `PAGE_SIZE`, `PARENT_CAP` | heap |
| `std.bytes` | endian-explicit `put_u{16,32,64}_{le,be}` / `get_u{16,32,64}_{le,be}`, LEB128 varints (`put_varint`, `read_varint`, `varint_len`), `eq`, `cmp`, `zero`, `fill`, `copy` | none |
| `std.process` | `exec`, `exit` | heap |
| `std.io` | `read_line`, `read_all`, `write_all`, `ByteWriter` / `ByteReader` (cursor over a buffer), `FileWriter` / `FileReader` (page-buffered streams over an fd) | none |
| `std.posix` | `openat`, `read`, `write`, `close`, `pread`, `pwrite`, `lseek`, `ftruncate`, `fsync`, `fdatasync`, `mkdirat`, `getdents64`, `clock_gettime`, `getcwd`, `nanosleep`, `mmap`, `munmap`, `clone`, `wait4`, `futex_wait`, `futex_wake`, `getenv`, `argv`, `spawn`, `exit`, plus the `raw_*` escape hatch | none |
| `std.debug` | `panic` | none |

## Storage primitives

The set a storage / query engine is built from, in three layers.
Working examples: `examples/storage/append_only.zag` (append-only
record log) and `examples/storage/page_file.zag` (page-oriented
block store with per-page checksums).

**1. Positioned file I/O** — `std.fs.File`, backed by `pread` /
`pwrite` (offset as an argument, so the fd's file position is never
shared state and no seek is needed). Every fallible method returns
`Result(_, Error)`, so a storage engine can report a full disk instead
of dying. There is exactly ONE spelling of each operation: the caller
picks the policy with postfix `!` (panic), `?` (propagate), `catch`
(fallback), or `match` (branch) — so there is no `*_or_panic` twin to
keep in step:

```zag
import std.fs.{File, FileMode, PAGE_SIZE}

var f: File = File.open("db.pages", FileMode.Create)!;
f.truncate(PAGE_SIZE * 2)!;            # pre-extend
var page: [PAGE_SIZE]u8 = undefined;
f.write_block(0, page[0..])!;          # one page at block id 0
let ok: bool = f.read_block(0, page[0..])!;
f.sync()!;                             # durability barrier
f.close()!;
```

The same calls without `!` are the recoverable spelling:

```zag
let cr: Result(File, Error) = File.open("db.pages", FileMode.Rw);
match cr {
    Ok(h) => { f = h; },
    Err(e) => { print("cannot open db.pages\n"); return; },
}
```

`FileMode` selects the open flags (`Read` = O_RDONLY, `Rw` =
O_RDWR|O_CREAT, `Append` = O_WRONLY|O_CREAT|O_APPEND, `Create` =
O_RDWR|O_CREAT|O_TRUNC). The mode is mandatory because `File` is a
cross-module type, where a one-argument overload could not resolve
(see [Method Overloading](30-method-overloading.md) §"Across modules").

**The handle remembers how it was opened.** `File` retains the parent
directory of its path and whether it was opened with `O_CREAT`, which
is what makes durability a property of the handle instead of a ritual
every writer has to reproduce:

- `close()` — a plain checked close. Fast; it never silently fsyncs,
  but it does report a deferred writeback error (ENOSPC/EIO).
- `close_durable()` — flush the contents, checked close, then flush
  the parent directory when this handle created the entry, so the new
  *name* is durable and not just its bytes. `fsync_parent()` for that
  step on its own. `EINVAL`/`ENOTSUP` from a directory fsync (a
  filesystem without support) is tolerated; a parent that did not fit
  in `PARENT_CAP` bytes is an `Err`, because the handle cannot prove
  the name is durable.
- `write_file(path, content) -> Result(usize, Error)` — the whole
  durable create-write-flush sequence, as a value. `write_file(p, c)!`
  is the fail-fast spelling of the same call.

There is no `try_open`: `open` returns a `Result`, and `is_open()`
reports whether the handle still owns a descriptor.

`FileMode.Append` adds `O_APPEND`, which makes seek-to-end + write
atomic — the property a write-ahead log needs for concurrent
writers. `size` / `block_count` / `truncate` / `sync` / `datasync`
manage the file extent and durability.

**2. Byte serialization** — `std.bytes`: explicit-endian fixed-width
fields (`put_u32_le` / `get_u32_le`, `put_u32_be` / `get_u32_be`, and
the 16/64-bit variants) and unsigned LEB128 varints
(`put_varint` / `read_varint` / `varint_len`). Big-endian is for
on-disk *keys*, where byte-wise order must match numeric order;
little-endian is for page-local metadata. Length-prefixing (varint
length, then bytes) is what makes a record skippable and immune to
delimiter-in-value corruption.

**3. Streaming** — `std.io.ByteWriter` / `ByteReader` are cursors
over a caller-owned buffer (a page, or a whole log in memory);
`FileWriter` / `FileReader` put a page-sized buffer in front of an fd
so many small records cost few syscalls. The same cursor code frames
log records and the slot directory inside a page.

Checksums come from `std.hash.crc32` / `sha256`; ordering and lookup
from `std.sort.binary_search` and `std.collections.HashMap`;
concurrency (a buffer pool, a page latch) from
`std.concurrent.{mutex, rwlock, once, atomic}`.

## Directory modules

Stdlib modules are identified by their DIRECTORY when a module grows
multiple types: `std.collections` resolves to `lib/std/collections/`,
`std.types` to `lib/std/types/`, and `std.strings` to
`lib/std/strings/`, with one file per type (`array_list.zag`,
`hash_map.zag`, `string.zag`, `slices.zag`) and a `mod.zag` barrel
chaining the re-exports. The per-type files register as nested
modules (`std.collections.array_list`, `std.types.string`) and are
importable directly or through the barrel:

```zag
import std.collections.{ArrayList}        # barrel → array_list.zag
import std.collections.hash_map.{HashMap} # direct nested import
import std.types.{String}                 # barrel → types/string.zag
import std.strings.{split, join}          # barrel → strings/slices.zag
```

Materialization mirrors the tree (`build/gen/std/collections/*.zig`);
the generic dispatch emits per-type import paths. The same pattern
backs `std.async.stream` / `std.arch.x86.avx2` / `std.concurrent.*`.

## POSIX syscall facade

`std.posix` (`lib/std/posix.zag`) is the raw-syscall layer the
system-facing modules build on. It replaced the preamble's
`__zag_openat` / `__zag_read` / `__zag_write` / `__zag_close` /
`__zag_mkdirat` / `__zag_getdents64` / `__zag_clock_gettime` /
`__zag_getcwd` / `__zag_getenv` / `__zag_exit` /
`__zag_process_spawn` helpers — the posix family is now COMPLETELY
out of the preamble (the last resident retired in the v0.4 `spawn`
pass, below). Modules import it with the std-to-std form:

```zag
pub import std.posix.{openat, read, write, close, mkdirat}
```

### Two tiers: the canonical `Result` surface and `raw_*`

Every fallible entry point exists twice. The canonical name returns
`Result(T, Errno)`; the `raw_` prefix gives the kernel's value verbatim
(a `usize` with bit 63 set on failure, or a negative `isize`).

```zag
import std.posix.{openat, close, read, write, lseek, mkdirat}
import std.errno.{Errno, ErrnoKind}

fun copy_one(src: str, dst: str) -> Result(void, Errno) {
    let s: Result(i32, Errno) = openat(std.posix.AT.FDCWD, src, 0, 0);
    if let Err(e) = s { return Err(e); }
    var sfd: i32 = 0;
    if let Ok(v) = s { sfd = v; }
    # ...
    _ = close(sfd);   # explicit discard: this fd's close cannot matter
    return Ok(undefined);
}
```

Use the canonical tier unless you are writing a loop that owns its own
EINTR policy (`read_full`/`write_full` below are the only places in
lib/std that do) or a hot path that must not branch twice.

What the canonical tier guarantees:

- **A failure is always an `Err`, and a success is always an `Ok`.**
  EOF is `Ok(0)`, a seek to offset 0 is `Ok(0)`, and a futex that
  reports EAGAIN is a normal `Err(EAGAIN)` that lock loops re-check.
- **No entry fabricates an errno.** An over-long path is
  `Err(EINVAL)`; it used to return `0xFFFFFFFFFFFFFFFF`, which decodes
  as `EPERM`.
- **The errno is a named value.** `Errno { kind, code }` keeps the exact
  kernel number even for a code outside `ErrnoKind`, and `Errno.name()`
  renders it (`"ENOSPC"`, or `"errno 4094"`).
- **`_ = name(...)` is the only way to ignore a result**, so a site that
  means to discard a failure says so in the source.

Shapes worth knowing:

- `openat(dirfd, path, flags: u32, mode: u32) -> Result(i32, Errno)` —
  path is copied into a 4096-byte sentinel buffer (the .zag surface has
  no `[N:0]u8` literal). `flags` reaches zig via `bitcast` (the packed
  `O` bitfield).
- `read` / `write` / `pread` / `pwrite` -> `Result(usize, Errno)`;
  `lseek -> Result(i64, Errno)` (so a legit `Ok(0)` is not mistaken for
  the old negative-error marker).
- `close` / `fsync` / `fdatasync` / `ftruncate` / `mkdirat` / `munmap` /
  `nanosleep` / `futex_*` -> `Result(void, Errno)`. `mkdirat` returns
  `Err(Errno.of(EEXIST))` rather than swallowing it — `std.fs.mkdir`
  coalesces it for `mkdir -p` semantics.
- `getcwd() -> Result([]const u8, Errno)` and `getenv(name) -> ?str`
  both return slices into fixed module-level buffers
  (`var cwd_buf: [4096]u8`, `var env_buf: [32768]u8`). `getcwd` is a
  `Result` because a failure has no sensible empty-string spelling;
  `getenv` stays `?str` because "unset" is a normal answer, not a
  syscall failure. `getenv` scans `/proc/self/environ` and never
  allocates.
- `clock_gettime(clk_id: i32) -> Result(i64, Errno)` — nanosecond time
  via `enum_from_int` (runtime int → `clockid_t`); `std.time.now`
  delegates to it and panics on failure, because a broken monotonic
  clock makes every `Timer`/`Duration` in the process meaningless.
- `exit(code: i32) -> noreturn` — raw `std.os.linux.exit`.
- `spawn(argv: []const []const u8) -> Result(i32, Errno)` —
  fork/execve/waitpid in .zag (the last preamble retirement). argv
  strings land in a fixed module-level arena, each NUL-terminated;
  `arg_ptrs`/`env_ptrs` are `[64:null]`/`[256:null]` sentinel pointer
  arrays (the `.zag` type-text pass-through gets the sentinel array via
  `[N:S]T` annotations — the parser's sentinel-size carve-out). The
  child inherits the parent environment (an envp walk over a fresh
  /proc/self/environ read) and execve's; execve failure exits 127.
  `Ok(exit code)` for a child that exited; `Err(errno)` only when the
  SPAWN failed, so a child's `Ok(255)` is no longer ambiguous with a
  setup failure. NOTE: callers must pass a SLICED array (`args[0..2]`) —
  zig 0.16 removed the by-value array→slice coercion, so a bare
  `exec(args)` fails ("array literal requires address-of operator").

`std.fs`, `std.env`, `std.time`, and `std.process` import from this
facade; `std.process.exit` re-exports it under the alias
`exit as sys_exit`, and `std.process.exec` delegates to `spawn`.

`std.mem.memcpy(dst: []u8, src: []const u8, len)` is the pure
byte-copy primitive (the retired `__zag_memcpy` preamble helper) —
the arena copies in `spawn`, `String.push_str`, `fmt`'s format
helpers, and `std.strings.slices`' join/replace all route through
it.

## Generic containers

`std.collections` is built on generic *structs* (docs/17 §Generic
Types). HashMap key semantics are implemented in pure .zag via the
compiler's comptime type dispatch: `type_eq(K, str)` (a builtin that
emits a zig type-equality `K == []const u8`) selects CONTENT
semantics for `str` keys (byte-wise `str_eq` + content FNV-1a over
the slice bytes) and VALUE semantics for byte keys (FNV-1a over
`size_of(K)` bytes reached through `addr_of` — the retired preamble
`__zag_key_hash`/`__zag_keys_eq` helpers moved into
lib/std/collections/hash_map.zag). String-keyed maps work including
equal strings in different buffers:

```zag
var m: HashMap<str, i32> = HashMap<str, i32>.new();
m.put("alpha", 1);
m.get("alpha");   # 1
```

The container structs thunk to `fn ArrayList(comptime T:
type) type`, impl methods become orphan free fns
(`ArrayList_T_push(comptime T, self: *ArrayList(T), value: T)`), and
call sites dispatch automatically — `list.push(5)` rewrites to
`@import("std/collections/array_list.zig").ArrayList_push(i32, &list, 5)`.
Value receivers get address-of at the call site; declare the binding
`var` when methods mutate. Both dispatch branches are comptime-known
per instantiation, so zig's comptime-if evaluates exactly one —
`a == b` on a slice never type-checks because the str branch wins
first, and the value byte-walk never touches a string.

## Generic functions (turbofish)

Generic *functions* round out the stdlib — `sort<T>` and friends name
the type argument explicitly at the call site:

```zag
var arr: [5]i32 = { 5, 2, 4, 1, 3 };
sort<i32>(arr[0..]);
let idx: ?usize = binary_search<i32>(arr[0..], 4);
```

The codegen rewrites `sort<i32>(...)` to the zig form
`sort(i32, ...)` with `comptime T: type` in the signature.

## Heap-returning functions

`std.encoding`'s encode/decode helpers return heap slices the caller
owns and must free:

```zag
import std.encoding.{base64_encode}

let b64: []u8 = base64_encode("hello");
defer free(b64);
```

The escape analysis treats these as escaping allocations by design
(no leak warning); the bench counters charge the allocation so
`std.bench.Counters.live()` stays accurate across free sites.

## Hash arithmetic and wrapping

zag's checked operators (`+` / `*`) panic on overflow in Debug
builds, so the hash/random implementations use the wrapping forms
(`+%` / `*%` — docs/05 §Wrapping Arithmetic) with digest-width state:

```zag
var hash: u32 = 2166136261;          # fnv1a32's offset basis
hash = (hash ^ (data[i] as u32)) *% 16777619;   # mod-2^32 wrap
```

`sha256` keeps all state variables as `u32` with `+%` adds (the
spec defines every add mod 2^32), and `XorShift64Star`'s final
multiply is `*%` (mod 2^64). The pre-wrapping v0.1 forms accumulated
in `u64`/`u128` and folded with an explicit `% 2^N` — equivalent
arithmetic, now spelled directly. Digests are checked against the
canonical test vectors in `examples/stdlib/hash_core.zag`:

| Function | Input | Expected |
|---|---|---|
| `fnv1a32` | `"hello"` | `0x4F9F2CAB` |
| `crc32` | `"123456789"` | `0xCBF43926` |
| `sha256` | `"abc"` | `ba 78 16 bf …` |
| `base64_encode` | `"hello"` | `aGVsbG8=` |

## Verified test vectors

Run `examples/stdlib/hash_core.zag` (via `zig build` + project mode)
to check the vectors above; the same program exercises `sort`,
`binary_search`, and `XorShift64Star`.
