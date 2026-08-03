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
| `std.env` | `get_env` | heap |
| `std.fs` | `read_file`, `write_file`, `mkdir` | heap |
| `std.process` | `exec`, `exit` | heap |
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

## Generic containers

`std.collections` is built on generic *structs* (docs/17 §Generic
Types). HashMap keys hash and compare via the preamble
`__zag_key_hash` / `__zag_keys_eq` helpers — `str` keys get CONTENT
semantics (std.mem.eql + content FNV), so string-keyed maps work
including equal strings in different buffers:

```zag
var m: HashMap(str, i32) = HashMap(str, i32).new();
m.put("alpha", 1);
m.get("alpha");   # 1
```

The container structs thunk to `fn ArrayList(comptime T:
type) type`, impl methods become orphan free fns
(`ArrayList_T_push(comptime T, self: *ArrayList(T), value: T)`), and
call sites dispatch automatically — `list.push(5)` rewrites to
`@import("std/collections/array_list.zig").ArrayList_push(i32, &list, 5)`.
Value receivers get address-of at the call site; declare the binding
`var` when methods mutate. `HashMap` hashes keys via FNV-1a over
`size_of(K)` bytes with `==` equality (value keys are
content-correct; `str` keys hash the slice descriptor — content-key
equality is a follow-up).

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

zig's checked operators panic on overflow in Debug builds, and the
wrapping operators (`+%` / `*%`) are not expressible in `.zag`
source. The hash/random implementations therefore accumulate in a
wider type (`u64` or `u128`) and fold with an explicit modulo:

```zig
hash = hash * 16777619;      // fits u64 (below 2^57)
hash = hash % 4294967296;    // fold back to 32-bit FNV semantics
```

The same modulo idiom appears in `sha256` (all state variables are
mod-2^32) and `XorShift64Star` (mod-2^64). Digests are checked
against the canonical test vectors in `examples/stdlib/hash_core.zag`:

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
