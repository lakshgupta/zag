# AGENTS.md — Zag compiler

Zag is a systems language that emits Zig source and uses `zig` for native codegen + linking.

## Build & test

```
zig build                              # production binary → zig-out/bin/zag
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

- **`std.fs.*` surface is sparse** — codebase uses `posix.openat` + `std.os.linux.*` syscalls everywhere. No `std.fs.cwd()`, no `std.process.Child`, no `@embedFile` across module boundaries.
- **Test module is separate** from the production module to avoid 3-4× binary bloat from `zig_payload` slice-inlining. The test binary is NOT installed.
- **Module wiring** in `build.zig` is intricate: `env_path` is a shared module, `build_options` is threaded through `addOptions` with careful key naming to avoid zig 0.16's auto-numbering collision (`build_options` / `build_options0`).
- If you add a new source file under `src/` that imports `build_options`, make sure it's NOT transitively pulled into the production module unless intended.
- **`build.zig` has ~650 lines** with extensive doc comments — read it before adding new build steps or modules.

## Conventions

- No `std.fs.*` — use `posix.openat` + `std.os.linux.{read,write,mkdirat,close,fchmod}`
- Subprocess via fork+execve, not `std.process.Child`
- Path formatting into stack buffers via `std.fmt.bufPrint` into `[4096]u8` scratch
- ELF magic (`\x7fELF`, 4-byte header check) to validate embedded zig binary
- Integration tests use SKIP-on-missing-fixture convention (exit 0 when prereqs absent)
- Comments are extensive and document architectural history — preserve them when editing

## Known pre-existing issues

- 1 test failure (336/337 pass): `cast \`*T-typed x as Trait\` emits @ptrCast(x) without address-of` — a `@ptrCast` vs `@constCast` mismatch in trait-cast codegen
- The `d.draw<Button>()` turbofish syntax is a comptime codegen limitation — not a bug, known limitation
- `vendor/zig/zig` is a 100-byte placeholder stub (not a real zig binary) in fresh checkouts — populated by `scripts/install.sh`
