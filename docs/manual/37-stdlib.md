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
| `std.sort` | `sort<T>`, `binary_search<T>` | none |
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

## Generic functions (turbofish)

Generic *functions* are the primary stdlib abstraction — generic
*structs* are still on the compiler roadmap. Call sites name the type
argument explicitly:

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
