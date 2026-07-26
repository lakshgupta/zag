# Modules and Imports

## File-Path-Based Modules

No `module` declaration. The module path is the file path:

```
src/main.zag            -> module main
src/math/vec3.zag       -> module math.vec3
src/net/http/server.zag -> module net.http.server
```

A directory is a module if it contains `.zag` files.

## Imports

```
import math.vec3                    # import entire module
import math.vec3 as v               # alias
import math.{Vec3, Mat4}           # import specific items
```

## Visibility

- No modifier — module-private
- `pub` — visible outside the module

```
# In module math.vec3:
pub struct Vec3 { ... }      # visible to importers
pub fun length(...) { ... }  # visible
fun internal() { ... }       # private — not visible outside
```

## mod.toml

Optional file in a module directory to control submodule discovery:

```toml
[module]
name = "math"
version = "0.1.0"

# Explicit submodule list (opt-in). If omitted, all .zag files are modules.
submodules = ["vec3", "mat4", "quat"]

# Re-export control
[exports]
vec3 = true
mat4 = true
quat = false
```

If `mod.toml` is absent, all `.zag` files in the directory are submodules.

## Re-exports

A `mod.zag` file can re-export symbols:

```
# src/math/mod.zag
pub import math.vec3.{Vec3, Vec3::*};
pub import math.mat4.{Mat4, Mat4::*};
# quat not re-exported
```

## Cyclic Detection

The import resolver builds a module DAG and reports an error on cycles. This is a compile-time check.

## Dependencies

Third-party packages live in `deps/`:

```
zag install           # fetch dependencies
zag add json          # add a dependency
zag remove json       # remove a dependency
```

Packages are resolved from **Git URLs** declared in `zag.toml` — today the protocol is **git-only**, no central registry yet. `zag add` / `zag fetch` populate `deps/` from a remote git rev, and local sibling packages use `path = "..."`. The lock file (`zag.lock`) pins every dependency to an exact git SHA + content hash. A central `zagpm.dev` registry is deferred to v2+ and will be an alias layer over the git protocol. For the full operational guide, see [Project Layout](34-project-layout.md); for the manifest format, see [`zag.toml` Schema](35-zag-toml-schema.md).

## The Standard Library (`std.*`)

> **Status — partial implementation.** The file tree described in the next subsection (`<zag-install>/lib/std/`) is now staged on disk as a first wave of stub files (`lib/std/{mod,string,error,fmt,time,atomic,bench}.zag`, plus `lib/std/{async/stream,arch/x86/avx2}.zag`). Each file declares the planned type surface in zag syntax; the method bodies are stubs pending the real impl (most route through zig's stdlib once the codegen router is wired). The `KNOWN_STD_MODULES` table in `src/parser/decl.zig` has not yet landed — `import std.X` resolves against the local file tree today, the same path a user module would take. Once the table lands, the resolver will recognize `std.X` against these staged stubs and route to them alongside the user program.

Every zag program starts with `import std.X` — for `String`, `fmt`, atomics, timers, async streams, the canonical `Error` type, the allocator. The `std.*` namespace is resolved differently from user modules: the compiler recognizes the `std.` prefix and routes the request to a translation layer, not the file-tree walk above. This section documents that resolution, where the stdlib lives on disk, and how a maintainer adds a new module.

### Where the stdlib lives

The stdlib is shipped with the zag toolchain itself, at:

```
<zag-install>/lib/std/
  string.zag          # String — heap-allocated UTF-8
  error.zag           # Error + Context + ErrorExt trait
  fmt.zag             # fmt.Writer + Display routing
  time.zag            # Duration + timer.after / timer.interval
  atomic.zag          # zag-side wrappers around zig's std.atomic
  bench.zag           # benchmarking + allocation counters
  arch/
    x86/avx2.zag      # compiler intrinsics on x86_64
    aarch64/asimd.zag # NEON / SVE intrinsics
  async/stream.zag    # AsyncStream<T> trait + combinators
  ...
```

`<zag-install>` is the path produced by `zig build install`'s `b.installArtifact` step (look in `build.zig` for the install prefix); a `zig build install -Dwith_stdlib=true` flag is the staging point once the install rule extends to ship the stdlib tree. The resolver consults the user-writeable `$ZAG_HOME` overlay before the toolchain-shipped path so a maintainer can shadow a std module locally without rebuilding the toolchain — the cache-resolution chain (`$ZAG_HOME` > `$XDG_CACHE_HOME` > `$HOME` > `build_options.z_install`) is computed once at startup and pinned in the build options.

### Two distinct std paths — hand-emit vs explicit import

Three call patterns live under the `std.X` umbrella and reach zig's stdlib through different mechanisms; conflating them is the most common documentation trap, so they are listed up front:

- **Compiler-emit primitives** — codegen routes source keywords like `print` (`src/codegen/primary.zig:65`), `new` (`src/codegen/expr.zig:223`), and `==` on `[]const u8` (`src/codegen/stmt.zig:673`) directly to zig stdlib. No `import` required from the user.
- **Explicit-import pass-through** — the resolver emits a zig `@import("std").X` re-export alias when the user writes `import std.arch.x86.avx2`, `import std.Thread.Pool`, etc. The table below shows the planned alias shape.
- **Zag-source library** — a normal `.zag` module under `<zag-install>/lib/std/<path>.zag`, parsed and type-checked like any user program. Examples: `std.string.String`, `std.error.Error`, `std.async.stream.AsyncStream<T>`, `std.time.Duration`, `std.bench`.

The mechanism-on-disk / user-action / examples breakdown for all three kinds lives one section below — see [Layering](#layering).

> **Not yet wired.** `std.os.linux.*` and similar syscall-level refs are the COMPILER's own internal runtime (the compiler itself is a zig program that uses `std.os.linux.*` in `tests/smoke.zig`, `src/env_path.zig`, `src/toolchain.zig`, and `build.zig`), not a user-zag stdlib surface — wrapping them through the zag resolver is a separate, later op.

### How `import std.X` resolves

Once the resolver lands (current predecessor: the import-DAG machinery already in place for user modules), it will route every `std.X` import through a `KNOWN_STD_MODULES` table in `src/parser/decl.zig`. The table maps each path to one of two forms:

**Zag-source module** — path `std.string` resolves to `<zag-install>/lib/std/string.zag` (or `<zag-install>/lib/std/string/mod.zag` for a subtree). The parser produces the same AST, the type-checker adds it to the import DAG (inheriting cyclic-DAG detection above), and codegen emits alongside the user's program. The zag-source-library row above is the fully-wired shape.

**Explicit-import pass-through** — path `std.arch.x86.avx2` (and the rest of the explicit-import row above) cannot yet be cleanly expressed in zag source until the bootstrap compiler is mature enough. The table records the path as a re-export of an underlying zig module; the resolver emits one alias per pass-through path at the top of the user's output:

```zig
const __zag_std_arch_x86_avx2 = struct {
    const avx2 = @import("std").arch.x86.avx2;
};
```

so a zag `std.arch.x86.avx2._mm256_fmadd_ps(a, b, c)` call desugars to `__zag_std_arch_x86_avx2.avx2._mm256_fmadd_ps(a, b, c)`. The zag-side types and the zig-side types must agree at the boundary — checked at the call site via the same trait-bound machinery as a regular generic call. This form is partly current (the compiler emit), partly planned (the resolver table); the call-site semantics are what the user sees.

### Layering

The three kinds of access stay decoupled cleanly:

| Kind | Mechanism on disk | User action | Examples |
|---|---|---|---|
| Compiler-emit primitive | Codegen hand-emit paths in `src/codegen/{primary,expr,stmt}.zig | Just call the source keyword — no `import` needed | `print`, `new`, `==` on strings, string interpolation `fmt.Writer` calls |
| Explicit-import pass-through | Resolver entry in `KNOWN_STD_MODULES` (planned for `src/parser/decl.zig`); pass-through `.zig` files at `<zag-install>/lib/std/<path>.zig` exposing `pub const X = @import("std").X;` aliases | `import std.arch.x86.avx2` once at file top; call `std.arch.x86.avx2._mm256_*(…)` thereafter | `std.arch.x86.avx2`, `std.arch.aarch64.asimd`, `std.event.loop`, `std.Thread.Pool` |
| Zag-source library | `.zag` source files at `<zag-install>/lib/std/<path>.zag` or `<path>/mod.zag`; standard parser + type-checker + codegen pipeline | `import std.X` (or `import std.X.{Type}` selective, or `import std.X as s` aliased) | `std.string.String`, `std.error.Error`, `std.error.Context`, `std.async.stream.AsyncStream<T>`, `std.time.Duration`, `std.bench` |

The `KNOWN_STD_MODULES` table — once it lands — is the single source of truth for the explicit-import and zag-source rows. A path that doesn't resolve is a compile error pointing at the import site, so a typo (`import std.stirng`) fails fast rather than silently walking the file tree. New entries for compiler-emit primitives are added in `src/codegen/`, not in `KNOWN_STD_MODULES` — the two evolution sites stay decoupled (codegen additions don't need to touch the resolver, and vice versa).

### User-side usage is unchanged

From the program side, `import std.X` follows exactly the import rules above — same syntax, same visibility, same cyclic-DAG guarantees. Only the prefix differs. All three forms work:

```zag
import std.string                  # whole namespace
import std.string.{String, Display}  # selective import
import std.string as s             # alias the namespace

let greeting: String = new String("hello");
s.push_str(greeting, ", world");
Display::write(greeting, &writer);
```

```zag
import std.atomic
var counter: std.atomic.AtomicI32 = std.atomic.AtomicI32.init(0);
counter.fetch_add(1, std.atomic.Ordering.AcqRel);
```

```zag
import std.time
async fun greet(name: str) -> str {
    await std.time.timer.after(std.time.Duration.from_millis(10));
    return "hello, {name}";
}
```

For compiler-emit primitives, there's no import at all — the source-level keyword *is* the call. For explicit-import pass-through and zag-source paths, the user-side call site looks identical: `std.arch.x86.avx2._mm256_fmadd_ps(…)` vs `std.string.String.with_capacity(64)` differ only in the prefix and what the implementation does behind it.

### Adding a new std module

A maintainer adding a new module once the resolver lands:

1. **Drop the source file** at `<zag-install>/lib/std/<path>.zag` (or `<path>.zig` for an explicit-import pass-through). Module paths use lowercase (`std.foo`) — uppercase is reserved for type names within a module.
2. **Register the entry** in `KNOWN_STD_MODULES` in `src/parser/decl.zig` (the table that the resolver consults). For zag-source modules, point at the `.zag` path; for explicit pass-throughs, point at the `.zig` file that re-exports the zig namespace.
3. **Exercise the import site** — run `examples/run_all.sh` to compile every example; any missing `KNOWN_STD_MODULES` entry surfaces as a compile error at the first unmatched `import std.X` in any program under `examples/`. (`zig build test` covers parser keywords and codegen smoke — it does NOT yet walk `KNOWN_STD_MODULES` entries, so the runtime exercise is the gate until the test harness grows stdlib-path coverage in `src/tests/parser.zig`.)

If the new module depends on another `KNOWN_STD_MODULES` entry, that's fine — cyclic-DAG detection above catches accidental ordering errors before codegen. If the new module's name collides with an existing entry, the resolver surfaces the conflict at parse time and the maintainer either renames or merges.

For compiler-emit primitives (the first row in the Layering table above), the development loop is different — the maintainer adds a keyword routing in `src/codegen/` and a zig-side emission, and verifies via `zig build test` after asking the parser to recognise the keyword. No `KNOWN_STD_MODULES` involvement.

### What is NOT in std

A few namespaces show up in docs and examples but are *not* stdlib modules:

- `std.collections.*` — `List<T>`, `Map<K, V>`, `Set<T>` — implementations of these live as **user-space libraries** (see [Dependencies](#dependencies)), not in the toolchain-shipped std tree. The reason: collections are the canonical surface where language evolution matters most, and locking them into the toolchain's release cycle clashes with that.
- `std.comptime` / `std.reflect` — deferred to v2 alongside the macro framework (§19).
- `std.c` — bindings for the C standard library are generated at FFI declaration time, not pre-built. Use `extern fun printf(...)` (with `@[repr(C, opaque)]` for opaque types; §5.6) directly in user code rather than going through a std.c indirection.

The `std.` prefix is reserved — third-party packages use their own prefix (`json.*`, `http.*`, `math.*` in this manual) and live in `deps/` (see [Dependencies](#dependencies) above).

```
# src/main.zag
import std.string
import math.vec3
import net.http.server

fun main() {
    let s = new String("hello");
    let v = vec3.Vec3 { x: 1.0, y: 2.0, z: 3.0 };
    server.serve("0.0.0.0:8080");
}
```
