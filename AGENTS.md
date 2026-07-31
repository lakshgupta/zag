# AGENTS.md — Zag compiler

Zag is a systems language that emits Zig source and uses `zig` for native codegen + linking.

## Build & test

```
zig build                              # production binary → zig-out/bin/zag-<os>-<arch> (build.zig's b.fmt emits the platform-suffixed name; .exe appended on Windows)
zig build -Doptimize=ReleaseFast       # release build
zig build -Dzig_payload=<path>         # embed a zig binary (default: auto-detect vendor/zig/zig)

zig build test                         # unit tests (336/337 pass; 1 pre-existing failure)
zig build scaffold_tests               # parse-only regression on lib/std stubs
zig build e2e                          # end-to-end integration (fork+execve; opt-in)
zig build runtime_smoke                # runtime vtable correctness (opt-in)
zig build smoke                        # materialize-path integration (needs vendor/zig/zig.test fixture)

./scripts/build.sh [--release]         # build + platform-name (scripts/ pattern)
./scripts/install-local.sh             # install ~/.zag/bin/zag + configure PATH
./examples/run_all.sh [--check] [cat/] # run/check all .zag examples
```

`zig build test` is the fast (~1s) in-process test. `zig build e2e`, `runtime_smoke`, `smoke` are separate executables that fork child processes — always verify at least `test` + `scaffold_tests` before committing.

## Architecture

- **Pipeline**: `src/main.zig` → `lexer.zig` → `parser.zig` → `ast.zig` → `codegen.zig` → Zig source → `zig build-exe`
- **Two modes**: file mode (`zag run <file.zag>`) and project mode (`zag run` reads `zag.toml`, transpiles `src/main.zag`, emits `build/bin/<name>`, generated zig in `build/gen/`)
- **Zig resolution chain**: embedded ELF-validated payload → `$ZAG_ZIG_PATH` env var → error with clear message
- **`--leaf-process` is legacy** (dead code from the old bootstrap round-trip); CLI dispatch is now inline in `main()`

## Source layout

| Path | Role |
|---|---|
| `src/main.zig` | CLI entrypoint, subprocess fork/exec, parse args + dispatch |
| `src/toolchain.zig` | `zig_payload` embedding + `materializeZigToCache()` |
| `src/env_path.zig` | `readEnviron()`, `getenv()`, `resolveZagCacheDir()` — shared by main + test binaries |
| `src/project.zig` | `detectProject()` (read `zag.toml`), `createProject()` (scaffold `src/main.zag`) |
| `src/lexer.zig`, `parser.zig`, `ast/`, `codegen/` | Compiler pipeline |
| `src/tests.zig` | Test module root — imports 14 test files from `src/tests/` |
| `tests/` | Integration runners (separate executables, opt-in steps): `smoke.zig`, `e2e.zig`, `runtime_smoke.zig`, `scaffold.zig` |
| `lib/std/` | Zag stdlib stubs (parsed by scaffold tests) |
| `docs/manual/` | 36-chapter language manual |
| `examples/` | Runnable `.zag` programs by feature category |

## Build-system quirks (zig 0.16)

- **`std.fs.*` surface is sparse** — codebase uses `posix.openat` + `std.os.linux.*` syscalls everywhere (raw for I/O primitives; `std.posix.*` facade for catch-needing sites — see `## zig 0.16 pitfalls` §2). No `std.fs.cwd()`, no `std.process.Child`, no `@embedFile` across module boundaries.
- **Test module is separate** from the production module to avoid 3-4× binary bloat from `zig_payload` slice-inlining. The test binary is NOT installed.
- **Module wiring** in `build.zig` is intricate: `env_path` is a shared module, `build_options` is threaded through `addOptions` with careful key naming to avoid zig 0.16's auto-numbering collision (`build_options` / `build_options0`).
- If you add a new source file under `src/` that imports `build_options`, make sure it's NOT transitively pulled into the production module unless intended.
- **`build.zig` has ~650 lines** with extensive doc comments — read it before adding new build steps or modules.

## Conventions

- No `std.fs.*` — use `posix.openat` + `std.os.linux.{read,write,close,fchmod}` for the I/O primitives that don't need error-union ergonomics. Catch-needing sites flip to the `std.posix.*` facade — see `## zig 0.16 pitfalls` §2.
- Subprocess via fork+execve, not `std.process.Child`
- Path formatting into stack buffers via `std.fmt.bufPrint` into `[4096:0]u8` scratch (sentinel slot at index 4096 — required for any `*Z`-suffixed posix call like `openatZ`; see `## zig 0.16 pitfalls` §7).
- ELF magic (`\x7fELF`, 4-byte header check) to validate embedded zig binary
- Integration tests use SKIP-on-missing-fixture convention (exit 0 when prereqs absent)
- Comments are extensive and document architectural history — preserve them when editing

## zig 0.16 pitfalls

Encountered during the v0.1 `lib/std/fs.zag` migration. Each entry shows the canonical zig-0.16 form + a project-wide grep one-liner so the next contributor doesn't re-discover the same landmine.

1. **`@memcpy` 3-arg form retired.** Use 2-arg slice form: `@memcpy(dest_slice, source_slice)` — both slices must have matching length. The 3-arg `@memcpy(dest_ptr, src_ptr, len)` form is rejected. The complication is `path_z[0..N].ptr` — drop the `.ptr` and pass the slice directly.
   ```zig
   // WRONG: zig 0.16
   @memcpy(path_z[0..toml_path.len].ptr, toml_path.ptr, toml_path.len);
   // RIGHT:
   @memcpy(path_z[0..toml_path.len], toml_path[0..]);
   ```
   Audit: `grep -rn '@memcpy.*\.ptr' src/ tests/ lib/`.

2. **Raw `std.os.linux.*` syscall returns `usize` (high-bit-set errno, not error union).** `catch |e|` is rejected because the raw syscall's return type is unsigned. Use `std.posix.*` facade functions for `catch` ergonomics — they wrap raw syscalls into `!T` error unions. AGENTS.md's "Conventions" section already prescribes `posix.openat` + raw `std.os.linux.{read,write,close,fchmod}`; the `catch`-needing sites (`openat`, `mkdirat`, `fstatat`, etc.) flip the convention.
   ```zig
   // WRONG: catches rejected on usize
   _ = std.os.linux.openat(...) catch ...;
   // RIGHT: caught error union
   _ = std.posix.openat(...) catch |e| { ... };
   ```
   Audit: `grep -rn 'std\.os\.linux\.[a-z]*at.*catch' src/ tests/`.

3. **Strict-shadow check enabled by default.** `const fd = ...` reused in an inner scope shadows the outer `const fd` and is an ERROR, not a warning. Two cleaner patterns than the rename workaround:
   ```zig
   // WORKAROUND (avoid): rename the inner const
   const toml_fd = std.posix.openat(...) catch return 0;

   // CLEAN: block-scope to allow shadow
   blk: {
       const fd = std.posix.openat(...) catch return 0;
       defer _ = std.os.linux.close(fd);
       const n = std.os.linux.write(fd, ...);
       if (n < ...) break :blk 0;
   }
   ```
   Audit: `grep -rn '\bconst \(fd\|n\|rc\)\b' src/ tests/` — flag any const whose name is reused in nested scopes.

4. **`stat` / `fstat` / `fstatat` / `std.posix.mkdirat` bindings dropped entirely in zig 0.16.** No replacement in `std.posix.*` either — `std.posix.fstatat` does not exist. Hand-roll the syscall via `std.os.linux.<raw>` with a sentinel buffer, or gate on the existing fd (e.g., ELF-magic check is sufficient for fs_smoke's placeholder-stub detection without stat-by-path).
   ```zig
   // WRONG: std.posix.fstatat / std.posix.mkdirat don't exist in 0.16
   // RIGHT: use std.os.linux.mkdirat with sentinel-terminated stack buffer
   var path_z: [4096:0]u8 = undefined;
   @memcpy(path_z[0..path.len], path);
   path_z[path.len] = 0;
   _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, &path_z, 0o755);
   ```

5. **`O` bitfield flag spelling: `.CREAT` matches kernel `O_CREAT`.** `.CREATE` (with the E) is rejected.
   ```zig
   .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }  // -- has `.CREAT` not `.CREATE`
   ```
   Audit: `grep -rn '\.CREATE' src/ tests/`.

6. **`std.debug.print` literal `{...}` in format string is interpreted as a placeholder;** comptime arg-matcher trips `@compileError("too few arguments")` inside `Io/Writer.zig:717`. Escape with `{{` / `}}`.
   ```zig
   // WRONG: literal {read_file} in the message is interpreted as a placeholder
   std.debug.print("... std.fs.{read_file} ...\n", .{workdir});
   // RIGHT: doubled braces for literal output
   std.debug.print("... std.fs.{{read_file}} ...\n", .{workdir});
   ```
   Audit: `grep -rn 'std\.debug\.print' src/ tests/` then visually scan for non-doubled `{ident}` inside the format string.

7. **`[N]u8` vs `[N:0]u8` sentinel-tag.** `std.posix.openatZ` (and every other `*Z` suffix with the posix facade: `openatZ`, `fstatat` variants when they exist) requires `*[N:0]const u8` — a sentinel-terminated address-of-pointer. `var path_z: [1024]u8` produces `&path_z: *[1024]u8`, which fails the sentinel constraint.
   ```zig
   // WRONG: ptr has no sentinel slot
   var path_z: [1024]u8 = undefined;
   const fd = std.posix.openatZ(AT.FDCWD, &path_z, .{...}, 0);  // rejects
   // RIGHT: sentinel slot at index N
   var path_z: [1024:0]u8 = undefined;
   path_z[len] = 0;
   const fd = std.posix.openatZ(AT.FDCWD, &path_z, .{...}, 0);  // ok
   ```
   Array length must also be comptime-known — `[path.len + 1:0]u8` (with runtime `path.len`) fails `unable to evaluate comptime expression`. Use a fixed-size buffer (`[4096:0]u8` covers any reasonable test-path length) and add `if (path.len >= 4096) return;` to fail-fast on long paths since fixed-size is fragile.

## Known pre-existing issues

- `vendor/zig/zig` is a 100-byte placeholder stub (not a real zig binary) in fresh checkouts — populated by `scripts/install.sh`
