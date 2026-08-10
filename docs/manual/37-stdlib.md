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
| `std.mem` | `alloc`, `free` keyword | heap |
| `std.argv` | `get` | heap |
| `std.env` | `get_env` (borrowed view) | none |
| `std.fs` | `read_file`, `write_file`, `mkdir` | heap |
| `std.process` | `exec`, `exit` | heap |
| `std.posix` | `openat`, `read`, `write`, `close`, `mkdirat`, `getdents64`, `clock_gettime`, `getcwd`, `getenv`, `spawn`, `exit` | none |
| `std.debug` | `panic` | none |

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

Conventions, mirroring the retired preamble:

- `openat(dirfd, path, flags: u32, mode: u32) -> usize` — path is
  copied into a 4096-byte sentinel buffer (the .zag surface has no
  `[N:0]u8` literal); callers treat the high bit as the error marker
  (`(fd & 0x8000000000000000) != 0`), same convention as the
  preamble. `flags` reaches zig via `bitcast` (the packed `O`
  bitfield).
- `read(fd, buf, len) -> isize` / `write(fd, buf, len) -> isize` —
  the returned raw `usize` is sign-cast back to `isize` so callers
  can branch on `<= 0` for EOF/error.
- `getcwd() -> []const u8` / `getenv(name) -> ?str` — return slices
  into fixed module-level buffers (`var cwd_buf: [4096]u8`,
  `var env_buf: [32768]u8`); `getenv` scans `/proc/self/environ` so
  the returned slice is NUL-terminated-free; `getenv` never
  allocates, so lookups are safe in signal-ish contexts.
- `clock_gettime(clk_id: i32) -> i64` — nanosecond monotonic time via
  `enum_from_int` (runtime int → `clockid_t`); `std.time.now`
  delegates to it.
- `exit(code: i32) -> noreturn` — raw `std.os.linux.exit`.
- `spawn(argv: []const []const u8) -> i32` — fork/execve/waitpid in
  .zag (the last preamble retirement). argv strings land in a fixed
  module-level arena, each NUL-terminated; `arg_ptrs`/`env_ptrs` are
  `[64:null]`/`[256:null]` sentinel pointer arrays (the `.zag`
  type-text pass-through gets the sentinel array via `[N:S]T`
  annotations — the parser's sentinel-size carve-out). The child
  inherits the parent environment (an envp walk over a fresh
  /proc/self/environ read) and execve's; execve failure exits 127.
  The parent waitpid-decodes via `(status & 0x7F) == 0` → exit code
  is `(status >> 8)`; signal kills / errors map to 255. NOTE:
  callers must pass a SLICED array (`args[0..2]`) — zig 0.16 removed
  the by-value array→slice coercion, so a bare `exec(args)` fails
  ("array literal requires address-of operator").

`std.fs`, `std.env`, `std.time`, and `std.process` import from this
facade; `std.process.exit` re-exports it under the alias
`exit as sys_exit`, and `std.process.exec` delegates to `spawn`.

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
