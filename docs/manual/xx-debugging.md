# Debugging

Zag transpiles to zig, which compiles to native code with debug symbols. You can debug zag programs with **gdb** or **lldb** just like any C/zig program.

## Quick Start

```
zag build                 # debug build (default, with symbols)
gdb ./zig-out/bin/main    # start debugging

# Or with lldb:
lldb ./zig-out/bin/main
```

Release builds strip debug symbols — use `--release` only for production:

```
zag build --release       # no debug symbols
```

## Inspect Generated Zig

`zag generate` writes the transpiled zig to `build/gen/`. This is the intermediate representation — useful for understanding what zag emits:

```
zag generate
cat build/gen/main.zig    # see the generated zig
```

The generated zig preserves zag's structure: structs map to structs, impl blocks to pub fns, match to labeled if-else ladders. Line-by-line inspection helps narrow down codegen issues.

## Symbol Mapping

Zag symbols follow a predictable naming convention in the generated zig:

| Zag source | Generated zig |
|---|---|
| `fun main()` | `pub fn main()` |
| `impl Button { pub fun draw(...) }` | `pub fn Button_draw(...)` |
| `let x: i32 = 5` | `const x: i32 = 5` |
| `fun foo<T>(...)` | `pub fn foo(comptime T: type, ...)` |
| `trait Drawable { fun draw(...) }` | `pub const Drawable = struct { ... }` |

Set breakpoints on these symbols:

```
(gdb) break main
(gdb) break Button_draw
(gdb) break Drawable.draw
```

## Memory Debugging

Debug builds (default) enable zig's safety checks:
- **Out-of-bounds access** — panics with a trace
- **Integer overflow** — panics in debug mode
- **Null pointer dereference** — caught at runtime

For memory leak detection, use zig's general-purpose allocator in the generated build.zig (requires manual edit of `build/gen/build.zig`):

```zig
// Replace page_allocator with GPA for leak detection:
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
defer _ = gpa.deinit();  // reports leaks
```

## Debugging with zig directly

For finer control, bypass zag and use zig directly on the generated output:

```
zag generate                         # emit build/gen/
cd build/gen
zig build -Doptimize=Debug           # build with full debug info
gdb ./zig-out/bin/main               # debug
```

This gives you zig-native backtraces with zag's struct names intact.

## Memory Allocation Tracing

Zig's `page_allocator` (used by zag's `new` and `alloc`) doesn't track leaks in release mode. For leak detection:

1. `zag generate` — emit the zig project
2. Edit `build/gen/main.zig` — replace `page_allocator` references with a `GeneralPurposeAllocator`
3. `zig build` — the allocator reports unfreed memory on deinit

For production profiling, zig's `--debug-compile-log` flag traces comptime evaluation:

```
zig build -Doptimize=ReleaseFast --debug-compile-log
```

## Common Issues

**"no debug symbols"**
→ Built with `--release`. Rebuild without `--release`.

**"function not found" in gdb**
→ Check the generated zig for the actual symbol name. Zag mangles method names: `impl Button`'s `draw` becomes `Button_draw`.

**"source file not found" in gdb**
→ The debug info points to the generated `.zig` file in `build/gen/`. Use `dir` in gdb to add the source directory:
```
(gdb) dir build/gen/
```
