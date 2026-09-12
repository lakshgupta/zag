# Debugging

Zag transpiles to zig, which compiles to native code with debug symbols. You can debug zag programs with **gdb** or **lldb** just like any C/zig program.

## Implementation status

| Layer | Status |
|---|---|
| L1 — expression-level `loc` + source path through codegen | ✅ |
| L2 — `.zag.map` side files + embedded `__zag_map` (Debug-only) | ✅ |
| L3a — runtime panic stack remapping (zag-native backtraces) | ✅ — `pub const panic = std.debug.FullPanic(...)` override; every frame resolves zig line → `__zag_map` → `src/main.zag:line:col` + source line + caret; explicit `panic(msg)` records the exact site; suppressed when the module imports or defines a `panic` binding |
| L3b B1 — `zag debug` + `tools/zag_gdb.py` / `zag_lldb.py` | ✅ |
| L3b B2 — DWARF path patch (`remapDwarfElf`) | ✅ |

## Quick Start

```
zag build                 # debug build (default, with symbols)
gdb build/gen/zig-out/bin/<name>    # start debugging (project mode binary)

# Or just use the one-command flow (builds, DWARF-patches, launches
# gdb with the .zag assistant):
zag debug
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

In the binary these are module-qualified (`main.sum`, `main.main`) and
impl-block methods stay `Target_method`:

```
(gdb) break main.sum
(gdb) break Button_draw
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

## Walkthrough: Debugging a Zag Program

This section walks through debugging a real zag application with gdb. The
flow below is **verified end-to-end** (gdb 15 + zig 0.16 + the
`tools/zag_gdb.py` assistant): breakpoints, variable inspection, memory
allocation inspection, and a backtrace that shows **zag code only**.

### Example program

Save this as `src/main.zag` in a zag project (note: bindings whose
initializer is a call need an explicit `: T` annotation, and passing an
array to a `[]i32` param uses `&nums`):

```zag
fun sum(arr: []i32) -> i32 {
    var total: i32 = 0;
    for i in 0..arr.len {
        total = total + arr[i];
    }
    return total;
}

fun main() {
    var nums: [3]i32 = [3]i32 { 10, 20, 30 };
    let result: i32 = sum(&nums);
    let p = new i32(42);          # heap allocation — inspected below
    defer free(p);
    print("{result} {p}\n");
    assert(result == 60);
}
```

### gdb

Build and launch with `zag debug` (from the project root — the generated
`build/gen/gdbinit` loads the Python assistant; if the assistant lives in
the zag install rather than the project, point gdb at it once per shell
with `export ZAG_TOOLS_DIR=<zag-install>/tools` or copy the `tools/`
directory into the project):

```
$ zag debug
build ok
[zag] gdb with .zag source mapping ready
```

This builds the project, writes `build/gen/gdbinit`, patches the binary's
DWARF file paths so gdb speaks `.zag`, and launches gdb.

#### Setting breakpoints

Zag function names in the binary are module-qualified — `main.sum` /
`main.main` (impl-block methods keep their `Target_method` names):

```
(gdb) break main.sum          # entry of sum()
(gdb) break main.main         # entry of main()
```

For statement-level breakpoints on a zag source line, use `zag-addr`
(available after `zag debug`; it resolves the `.zag` line through the
`.zag.map` to a generated-zig line, then to a binary ADDRESS via
`readelf`'s DWARF line dump, and sets `break *ADDRESS` — plain
`break file:line` is unreliable on gdb 15 + zig 0.16 because gdb cannot
resolve the user module's line table entries):

```
(gdb) zag-addr src/main.zag:14     # the print line
[zag] break *0x11da353
```

#### Running and stepping

```
(gdb) run
Breakpoint 1, 0x00000000011da353 in main.main (init=...)
```

`next`/`step` (statement stepping) requires gdb to resolve line info,
which gdb 15 cannot do for the generated user module — use `nexti` /
`stepi` (instruction stepping) to move statement by statement, or set
breakpoints at several functions and `run` between them. `finish` runs
to the end of the current function.

#### Inspecting variables

```
(gdb) print result            # $1 = 60
(gdb) print nums              # $2 = {10, 20, 30}
(gdb) print nums[0]           # $3 = 10
(gdb) print total             # (inside main.sum) uninitialized at entry
(gdb) info locals             # all locals of the current frame
```

Variable names match the zag source directly.

#### Inspecting memory allocations

Heap allocations (`new`) and the always-on allocation counters make it
easy to check what is live and where:

```
(gdb) print p                       # $4 = (i32 *) 0x7ffff7afe000   ← heap address
(gdb) print *p                      # $5 = 42                        ← the pointee
(gdb) x/dw p                        # 0x7ffff7afe000: 42             ← raw memory dump
(gdb) print 'main.__zag_bench_bytes_live'      # $6 = 4              ← live heap bytes
(gdb) print 'main.__zag_bench_allocations'     # $7 = 1              ← live allocations
```

The `__zag_bench_*` globals are the std.bench counters (emitted in every
binary): after `new i32(42)` you see 4 live bytes / 1 allocation; after
`free(p)` they drop back to 0. Compare with a stack value — `print &nums`
shows a low stack address, while `p` (from `page_allocator`) is a fresh
mmap region high in the address space. Freed allocations are returned to
the OS — accessing `*p` after `free` faults instead of returning stale
data.

#### Backtrace

```
(gdb) bt
#0  0x00000000011da353 in main.main () at src/main.zag:10
```

The frame filter remaps every resolvable frame to `src/main.zag:line` —
no `build/gen/*.zig` paths. Frames the map cannot resolve (deep stdlib
internals) fall back to their raw zig locations.

#### Leak check at compile time

The escape analysis warns before you even run gdb. It tracks all three
allocation families, so a never-freed slice is caught too:

```
$ zag build
warning: `new i32` at src/main.zag:12:9 in main is never freed (leak) — add an explicit `free` or `defer free`
warning: `alloc` at src/main.zag:14:24 in main is never freed (leak) — add an explicit `free` or `defer free`
warning: `alloc_raw` at src/main.zag:16:26 in main is never freed (leak) — add an explicit `release(p, n)` or `defer release(p, n)`
```

Each warning names the construct and points at the allocation site; the
analysis is conservative (anything passed to a user call counts as
escaping) and changes no emitted code — the fix is always your explicit
`free` / `release`. See the memory chapter for the escape rules and the
runtime ledger that measures the same thing exactly.

#### Commands reference

| Command | Description |
|---------|-------------|
| `zag debug` | Build + DWARF-patch + launch gdb with the .zag assistant |
| `zag-addr src/main.zag:N` | Break at the address of a zag source line |
| `zag-break src/main.zag:N` | Break via zig file:line (best-effort — see above) |
| `zag-list` | Show the zag source around the current frame |
| `bt` / `backtrace` | Zag-only backtrace (frame filter remaps) |
| `print EXPR` | Inspect a variable (`*p`, `nums[0]`, ...) |
| `x/dw ADDR` | Raw memory dump |
| `nexti` / `stepi` | Instruction stepping (statement stepping is gdb-version dependent) |
| `quit` | Exit gdb |


### lldb

`zag debug` writes gdb-specific init.  For lldb, build separately then
load the Python assistant (the project binary lands at
`build/gen/zig-out/bin/<name>` — the generated build-file's install
prefix — not `zig-out/bin/`):

```
$ zag build
build ok

$ lldb build/gen/zig-out/bin/<name>
(lldb) command script import tools/zag_lldb.py
[zag] loaded 6 map entries from build/gen
[zag] LLDB integration ready. Commands: zag-break, zag-bt, zag-where
```

DWARF patch runs automatically during `zag debug` but not during
`zag build`.  Run it manually if you need vanilla-lldb `.zag` paths:

```
(lldb) quit
$ zag debug           # triggers DWARF patch, then Ctrl-C out of gdb
^C
$ lldb ./zig-out/bin/main    # binary now has .zag paths in DWARF
```

Or source the Python assistant and use `zag-break` / `zag-where`.

#### Setting breakpoints

```
(lldb) zag-break src/main.zag:2
[zag] +breakpoint 1: src/main.zag:2 (zig main.zig:94)

(lldb) zag-break src/main.zag:10
[zag] +breakpoint 2: src/main.zag:10 (zig main.zig:110)
```

Or use plain lldb breakpoints on the module-qualified function names:

```
(lldb) breakpoint set -n main.sum
(lldb) breakpoint set -n main.main
```

The same caveat as gdb applies to statement stepping: lldb must resolve
line info for the generated user module, which the zig 0.16 DWARF5
output makes unreliable — prefer function breakpoints + `frame variable`
+ `expression` inspection, and `thread step-inst` for instruction-level
stepping.

#### Running and stepping

```
(lldb) run
Process launched
* thread #1, stop reason = breakpoint 2.1
    frame #0: main at src/main.zag:10
   10     let nums = [3]i32 { 10, 20, 30 };

(lldb) next
Process resumed
* thread #1, stop reason = step over
    frame #0: main at src/main.zag:11
   11     let result = sum(nums);

(lldb) step
* thread #1, stop reason = step in
    frame #0: sum at src/main.zag:2
   2      var total: i32 = 0;
```

#### Inspecting variables

```
(lldb) frame variable total
(i32) total = 0

(lldb) frame variable arr
([]const i32) arr = (ptr = ..., len = 3)

(lldb) expression arr.len
(usize) 3
```

#### Backtrace

```
(lldb) zag-bt
[0] sum  -> src/main.zag:2:20 in sum
[1] main  -> src/main.zag:11:26 in main
```

Use `zag-where` for the current frame only:

```
(lldb) zag-where
[zag] src/main.zag:4:9
```

#### Commands reference

| Command | Purpose |
|---------|---------|
| `zag-break <file>:<line>` | Set breakpoint by zag source location |
| `zag-bt` | Backtrace with zag locations |
| `zag-where` | Show zag location for current frame |
| `breakpoint set -n <func>` | Break on function name |
| `frame variable <var>` | Print variable value |
| `expression <expr>` | Evaluate expression |
| `thread step-in` / `thread step-over` | Step into / over |
| `continue` | Resume execution |
| `gui` | TUI mode with source display |
| `quit` | Exit lldb |

### Debugging panics

When `panic("message")` is hit at runtime:

```
$ zag run
panic: division by zero
  at src/main.zag:5:9
```

The file, line, and column point to the zag source.  In release builds
(`--release`), only the message appears — no location.

### Debugging without `zag debug`

If you built with `zag build` (not `zag debug`), the DWARF paths still
point at `build/gen/*.zig` and the DWARF patch has not run. The Python
assistant works either way (it reads the `.zag.map` files, which every
build writes):

```
$ gdb build/gen/zig-out/bin/<name>
(gdb) source tools/zag_gdb.py        # or: the generated gdbinit handles
                                     #     ZAG_TOOLS_DIR automatically
(gdb) zag-addr src/main.zag:12       # line breakpoints via address
(gdb) run
(gdb) bt                             # frames remapped to src/main.zag
```

`zag debug` additionally rewrites the binary's DWARF paths to `.zag`, so
`list`/`frame` display zag files directly. If you see zig lines in a
backtrace despite the assistant, compare `build/gen/main.zig` with the
`.zag.map` side file to map lines manually.

## Common Issues

**"no debug symbols"**
→ Built with `--release`. Rebuild without `--release`.

**"function not found" in gdb**
→ Check the generated zig for the actual symbol name. Zag mangles method names: `impl Button`'s `draw` becomes `Button_draw`.

**"source file not found" in gdb**
→ `zag debug` patches DWARF paths automatically.  To do it manually after
`zag build`, run `zag debug` and Ctrl-C out of gdb, or use the Python
assistant: `source tools/zag_gdb.py`.

## Native Zag Debugging

> **Status: partially implemented.** `panic(msg)` shows zag source locations,
> `zag debug` launches gdb with .zag mapping, DWARF paths are remapped.
> Safety-check panics (OOB, overflow) still show zig locations.

### Goal UX

```
$ zag run
panic: division by zero
  src/math.zag:14:9: 0x10a2b3 in divide
    panic("division by zero");
    ^
  src/main.zag:22:5: 0x10a3f1 in main
    _ = divide(10, 0);
    ^
```

```
$ zag debug ./build/bin/app
(gdb) break src/main.zag:22
(gdb) run
(gdb) list          # shows .zag source
(gdb) step          # steps by zag expressions
```

Users never need `build/gen/*.zig` for normal debugging.

### Constraints

| Fact | Implication |
|------|-------------|
| Pipeline is Zag → Zig → native | DWARF debug info points at generated `.zig` |
| Zig has **no `#line`** directive | Cannot teach the zig compiler zag paths directly |
| `ast.Loc` exists (`line`, `col`, `offset`) | Foundation for location tracking is present |
| Decls carry `loc`; Stmt/Expr do not | Must plumb `Loc` expression-deep through AST |
| `transpile(source)` drops the file path | Codegen never sees `src/foo.zag` today |
| Zig root can override panic via `std.debug.FullPanic` | Runtime stack remapping is first-class |
| gdb/lldb read DWARF `.debug_line` | Need path+line rewrite or a debugger frontend |

### Architecture (3 layers)

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1 — Loc on every Expr/Stmt + source path in CG   │
├─────────────────────────────────────────────────────────┤
│  Layer 2 — Dense zig↔zag sourcemap (in binary + file)   │
├─────────────────────────────────────────────────────────┤
│  Layer 3a Runtime          │  Layer 3b Debugger         │
│  custom panic + map lookup │  DWARF patch OR zag debug  │
└─────────────────────────────────────────────────────────┘
```

#### Layer 1 — Expression-level locations

**AST**
- Add `loc: Loc` to every `Expr` variant payload (or a thin envelope: `struct { loc: Loc, data: ExprData }` — per-payload `loc` matches existing `FunDecl.loc` style).
- Add `loc: Loc` on every `Stmt` variant.
- Parser: when building any node, record `tok.loc` from the leading token (already available everywhere).
- `transpile()` signature becomes `transpile(path: []const u8, source: []const u8)` so Codegen knows the source path.

**Codegen contract**
- Track `current_zig_line` while writing (count `\n` in the buffer, or maintain a counter on each `write`/`writeln`).
- **One zig statement per line** — never pack unrelated zag expressions on one zig line (needed for map fidelity).
- Before emitting each expr or stmt with a loc, record a map entry: `zig_line → (zag_file, zag_line, zag_col, symbol_name)`.

#### Layer 2 — Sourcemap format

Two representations of the same data:

**a) Embedded** in generated zig (for runtime panic lookup):
```zig
const __ZagMapEntry = struct {
    zig_line: u32,
    zag_line: u32,
    zag_col: u32,
    file: []const u8,   // "src/math.zag"
    symbol: []const u8, // "divide" / "Button_draw"
};
const __zag_map = [_]__ZagMapEntry{ ... }; // sorted by zig_line
```

**b) Side file** `build/gen/<module>.zag.map` (for debugger / DWARF patcher):
```
zig_line  zag_line  zag_col  symbol  source_file
120       14        9        divide  src/math.zag
121       14        9        divide  src/math.zag
122       15        5        divide  src/math.zag
```

Lookup: binary search by `zig_line` from the DWARF-resolved frame address.
Multi-line expansions (1 zag expression → N zig lines) all share the same
zag location; the lookup returns the greatest `zig_line ≤ target`.

**Release builds:** omit the map from the binary. Use a slim panic handler.

#### Layer 3a — Runtime panics (zag stacks)

The generated zig root module declares a custom panic handler:

```zig
pub const panic = std.debug.FullPanic(__zag_panic);

fn __zag_panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // 1. Print "panic: {msg}" to stderr
    // 2. Walk the stack via std.debug (same as defaultPanic)
    // 3. For each frame: DWARF → zig file:line → __zag_map lookup → print zag file:line:col
    // 4. Print zag source line + caret column marker (read .zag from project root)
    // 5. @trap() / exit(1)
}
```

**`panic(msg)` builtin** keeps the `@panic(msg)` path (hits the handler above).
Additionally it can lower to a direct call:
```zig
__zag_panic_at(msg, "src/math.zag", 14, 9)
```
so the top frame is exact even if DWARF resolution is fuzzy.

This path covers:
- Explicit `panic(...)` calls
- `assert(cond)` — repoint from `unreachable` to shared helper
- Zig safety checks: OOB, overflow, div0, unwrap null
- `Result.unwrap()` / `Option.unwrap()` panics in the generated preamble

#### Layer 3b — gdb / lldb on `.zag`

Two complementary mechanisms:

##### B1 — `zag debug` (ship first; always works)

```
zag debug [--] <binary> [args...]
```

- Writes `build/gen/gdbinit` and loads `tools/zag_gdb.py` (similar for lldb).
- **Python frame filter / stop-hook:**
  - Read frame PC → zig `file:line` from DWARF
  - Map lookup → zag `file:line:col`
  - `backtrace` prints zag locations; `list` shows `.zag` source
- **Breakpoints:** `break src/main.zag:22` → reverse map lookup → set breakpoint
  on all zig lines that correspond to that zag line.
- **Reverse map:** `(zag_file, zag_line) → [zig_lines]` built by scanning
  the side-file `.zag.map` at debugger startup.

##### B2 — DWARF patch (vanilla gdb/lldb without Python)

Post-link step (debug builds only):

```
zag build          # emits binary + .zag.map
zag embed-debug    # or automatic after link
```

Tool (`tools/dwarf_remap` or a step in the generated `build.zig`):
1. Parse ELF/Mach-O `.debug_line` and `.debug_info` sections
2. For each line-program entry whose file is under `build/gen/`, replace:
   - file name → zag source path
   - line number → zag line (from map)
   - column → zag column (from map)
3. Rewrite sections; produce a new `.debug` companion file or patch in-place

**Risk:** DWARF rewrites are format-sensitive (DWARF 5, split DWARF, Mach-O
subtleties). B1 is the priority; B2 enables vanilla `gdb`/`lldb` without a
wrapper tool.

### End-to-end flow

```
src/main.zag
    │ lexer (Loc per token)
    │ parser (Loc on every Expr/Stmt)
    ▼
Codegen(path="src/main.zag")
    │ emit zig, 1 fragment/line
    │ record __zag_map + write main.zag.map
    ▼
build/gen/main.zig  +  main.zag.map
    │ zig build-exe -ODebug
    ▼
binary (DWARF → .zig)  +  embedded __zag_map
    │
    ├─ run/panic ──► __zag_panic remaps frames → .zag UX
    └─ zag debug ──► gdb/lldb python (or DWARF patch) → .zag UX
```

### Multi-module projects

Multi-file zag projects (`src/main.zag`, `src/math.zag`, `src/net/http.zag`)
each produce:

```
build/gen/main.zig   +   main.zag.map
build/gen/math.zig   +   math.zag.map
build/gen/http.zig   +   http.zag.map
```

The root panic handler (in `main.zig`) imports all `__zag_map` tables at
codegen time. The global lookup:

```zig
const __zag_map_all = __zag_map_main ++ __zag_map_math ++ __zag_map_http;
```

Walked via binary search. The side-file `.zag.map` per module supports
per-module lookup in the debugger.

### Inlined and monomorphized generics

Zig generics (`comptime T: type`) are monomorphized per call site. Each
specialization produces its own DWARF entries and its own zig lines.
The sourcemap encodes the **original** zag location of the generic
function body, not the call site. This means:

- A panic inside `fun push<T>(self: *Vec<T>, val: T)` shows
  `src/vec.zag:42` (the push body), not the call site at `src/main.zag:15`.
- gdb steps through the generic body in zag terms.

This is the correct behavior and matches how Rust/Go/C++ debug generics.

### Error-return traces

Zag does not yet have error-return traces (zig's `@errorReturnTrace()`).
When/if zag exposes them, the same sourcemap lookup applies: the error
trace frames are resolved through the map to zag source locations.

---

## Implementation task breakdown

### Phase 0 — Design doc (this document) ✅
### Phase 1 — Loc plumbing ✅
### Phase 2 — Map emission + runtime zag traces ✅
### Phase 3 — `zag debug` CLI + GDB Python ✅
### Phase 4 — DWARF string remap (in-place binary patch) ✅
### Phase 5 — Release stripping, multi-module, LLDB ✅

**Remaining (Phase 2+):**
- [ ] `__zag_panic` full handler: walk stack frames via DWARF, resolve each through map
- [ ] `assert(cond)` → zig safety checks unified through `__zag_panic_at`
- [ ] Mach-O DWARF support for macOS
- [ ] Error-return traces remapped through sourcemap

---

## Current state

`panic(msg)` shows zag source locations in debug builds:

```
$ zag run
panic: division by zero
  at src/math.zag:14:9
```

In release builds (`--release`), only the message appears — no source location.

```zag
fun divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        panic("division by zero");
    }
    return a / b;
}
```

`assert(cond)` still uses `std.testing.expect` — to be unified in a followup.

### `zag debug`

```
$ zag debug              # project mode: builds + launches gdb
$ zag debug file.zag     # file mode
```

- Writes `build/gen/gdbinit` that loads `tools/zag_gdb.py`
- Patches DWARF file paths in the binary (`.zag` sources visible without Python)
- For lldb: `command script import tools/zag_lldb.py` after build

### Map file

`build/gen/<module>.zag.map` — tab-separated zig↔zag mapping:
```
zig_line  zag_line  zag_col  symbol  source_file
79        2         5        main    src/main.zag
```

### `panic(msg)` — builtin

`panic(msg)` emits zig's `@panic(msg)`. In debug builds (default), a
stack trace prints with function names and file paths from the generated
zig. In release builds (`--release`), only the message appears — no trace.

### `assert(cond)` — builtin

`assert(cond)` emits `std.testing.expect(cond) catch unreachable`, which
triggers a zig panic on failure. In `zag test` mode, this produces a stack
trace with the generated zig file and line.
