# `zag.toml` Schema Reference

`zag.toml` is the canonical package manifest for every zag project. This document is the formal schema reference. For the operational guide (init / build / test / dep workflow), see [Project Layout](34-project-layout.md).

The schema is deliberately decoupled from zig's `build.zig.zon`. `zag build` translates the relevant fields into a transient `build.zig.zon` under the hood; you only see it if you pass `--emit-build`.

## Top-Level Shape

```toml
[package]            # required
[project]            # recommended
[toolchain]          # optional: compiler path override (v2.1+)
[lib]                # optional (library package)
[[bin]]              # 0..N binary targets
[build]              # default build settings
[dependencies]       # runtime deps (table)
[dev-dependencies]   # test/bench DAG only (table)
[scripts]            # per-subcommand overrides
[modules]            # in-tree submodule allow / deny list
```

Other top-level keys (`[features]`, `[profile.*]`, etc.) are reserved for future expansion.

## `[package]`

Required. Project identity.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `name` | string | yes | Lowercase, alnum + `-` + `_`. Naming rules chosen to be portable to a future registry. |
| `edition` | string | no | Language edition. v0.1 only honors `"2024"`; included for forward-compat with future spec changes. |
| `version` | string | no | Semver; advisory unless this package is itself published externally. |

```toml
[package]
name    = "myproj"
edition = "2024"
version = "0.1.0"
```

## `[project]`

Recommended. Authoring + distribution metadata. Mirrors Cargo's `[package]` / npm's `package.json` metadata block.

| Field | Type | Notes |
|-------|------|-------|
| `description` | string | One-line summary |
| `license` | string \| array of strings | SPDX ident (e.g. `"MIT"`) or `["MIT", "Apache-2.0"]` |
| `repository` | string | URL |
| `authors` | array of strings | `["name <e@example.com>"]` |
| `keywords` | array of strings | Searchable tags (used by future registry) |
| `categories` | array of strings | Registry categories |

```toml
[project]
description = "demonstrate shared memory ring buffer"
license     = "MIT"
repository  = "https://github.com/example/ringbuf"
authors     = ["Lex <e@example.com>"]
keywords    = ["lock-free", "ring-buffer"]
categories  = ["data-structures"]
```

## `[toolchain]`

Optional. Lets a project pin the zig compiler binary that compiles its sources, overriding machine-wide and compile-time defaults. Today's sole field is `zig`:

| Field  | Type   | Default | Notes                                              |
|--------|--------|---------|----------------------------------------------------|
| `zig`  | string | _unset_ | Absolute path to the `zig` binary to invoke       |

```toml
[toolchain]
zig = "/opt/zig-0.16/zig"
```

### Resolution priority chain

`zag` resolves the compiler binary via this three-tier chain; a higher-tier value shadows lower-tier values:

| Tier | Source                                  | Scope                  |
|------|-----------------------------------------|------------------------|
| 1    | `[toolchain].zig` from project's `zag.toml` | this project        |
| 2    | `$ZAG_ZIG_PATH` env var                  | machine-wide         |
| 3    | `/usr/bin/zig`, `/usr/local/bin/zig`     | system auto-detect   |
| 4    | Embedded payload (`-Dzig_payload=<path>` at `zag`'s build time) | compile-time vendoring |

The tier order means a project that needs a specific zig (for example, a project pinned to zig 0.13 for ABI-compat with vendored libraries) keeps its setting even when your shell exports `$ZAG_ZIG_PATH` to something different — just like Cargo's `[source.crates-io]` overrides `CARGO_REGISTRIES_*` and rustup's `rust-toolchain.toml` overrides `RUSTUP_TOOLCHAIN`.

The path value is **verbatim** — no shell expansion. If your path lives under `$HOME`, write `$HOME/zig-bin/zig` literally, or set `$ZAG_ZIG_PATH` for a machine-wide alias. The runtime does not pre-flight the path: if the resolved binary is missing or non-executable, the spawned `zig` invocation surfaces its own `execve` error — match the upstream message of `zig build-exe` / `zig run` / `zig test` for debugging. (A future commit may add an upfront stat-and-warn check; today the
trust-then-fail contract matches `$ZAG_ZIG_PATH`'s behaviour.)

Resolution happens at every `zag run / build / check / test` invocation after the file-vs-project dispatch is decided; in file-mode (no `zag.toml` in scope) tier 1 is skipped and the chain collapses to env > embedded — same as pre-v2.1 behaviour.

## `[lib]`

Library root declaration. A package without `[lib]` and without any `[[bin]]` is malformed: declare a publishing shape or the build will not produce a target.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `root` | string | yes | Path to the entry `.zag` file, relative to `zag.toml`. |

```toml
[lib]
root = "src/lib.zag"
```

## `[[bin]]`

A binary target. Multiple `[[bin]]` tables with distinct `name` fields produce multiple binaries in one package. Each binary has its own `fun main()` entry point.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `name` | string | yes | Output file name (sans extension) |
| `root` | string | yes | Path to the entry `.zag` file with `fun main()` |

```toml
[[bin]]
name = "myproj"
root = "src/main.zag"

[[bin]]
name = "myproj-bench"
root = "examples/bench_main.zag"
```

## `[build]`

Default compile settings; per-command flags on the CLI take precedence.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `target` | string | `"native"` | Zig target triple (e.g. `"x86_64-linux-gnu"`) or `"native"` |
| `optimize` | string | `"Debug"` | One of `"Debug"`, `"ReleaseFast"`, `"ReleaseSafe"`, `"ReleaseSmall"` |
| `output` | string | `"zig-out"` | Build output directory |
| `check` | array of strings | `[]` | Opt-in safety checks (see [Testing](25-testing.md)) |

```toml
[build]
target   = "native"
optimize = "ReleaseFast"
output   = "zig-out"
check    = ["bounds", "ref"]
```

## `[dependencies]`

Runtime dependencies. The key is the **in-source module name**; the value pins the upstream source. Each entry takes the form:

```toml
[dependencies.<name>]
git      = "<url>"           # required (or `path = "..."`)
rev      = "<ref>"           # tag / branch / SHA
branch   = "<name>"          # alternative to `rev`
version  = "<semver-range>"  # alternative to `rev`
path     = "<local-path>"    # mutually exclusive with `git`
optional = bool              # default false
```

Field semantics:

| Field | Use |
|-------|-----|
| `git` | Upstream HTTPS URL. Required unless `path` is set. |
| `rev` | Pin a specific tag, branch, or SHA. Resolved to a SHA in `zag.lock`. |
| `branch` | Track a branch head at resolve time; pinned to the head's SHA in `zag.lock`. |
| `version` | Advisory semver range; resolved to the latest matching tag's SHA in `zag.lock`. |
| `path` | Local sibling package. Not in `zag.lock` (integrity is verified against the local filesystem each build). |
| `optional` | Gates the dep behind a CLI feature flag (v0.1: `--features <name>`). |

Examples:

```toml
[dependencies]
# Pinned tag:
json = { git = "https://github.com/zag-lang/json", rev = "v0.2.4" }

# Tracking branch head (no `rev`):
http = { git = "https://github.com/zag-lang/http", branch = "main" }

# Advisory semver range:
log  = { git = "https://github.com/zag-lang/log",  version = "^0.3" }

# Local sibling package (workspace-style):
internal-tls = { path = "../internal-tls" }
```

### `optional`

Optional deps are still declared in `[dependencies]`, gated behind the corresponding CLI feature flag:

```toml
[dependencies]
fancy-bench = { git = "https://github.com/zag/fancy-bench", rev = "v0.1.0", optional = true }
```

Run with `zag build --features fancy-bench` to enable. The full dep key is the CLI flag value; multiple `--features` may be supplied comma-separated.

## `[dev-dependencies]`

Dependencies that are part of the `zag test` and `zag bench` DAG, but NOT the `zag build` DAG. Same per-entry shape as `[dependencies]`.

```toml
[dev-dependencies]
# Test fixtures only:
zig-assert = { git = "https://github.com/example/zig-assert", rev = "v0.3.1" }
# Benchmark scaffolding:
bench-harness = { git = "https://github.com/example/bench-harness", rev = "v0.1.0" }
```

`zag build` skips `[dev-dependencies]` entirely; `zag test` and `zag bench` pull them in. Entries that remain unused after `zag test` + `zag bench` runs are dropped from `zag.lock` by `zag install --gc`.

## `[scripts]`

Per-subcommand overrides. Today, `build / test / bench` all default to `[build]` settings; `[scripts]` lets you specialize them.

| Subtable | Field | Notes |
|----------|-------|-------|
| `[scripts.build]` | `deps` | Build-step dependencies (rare; leave empty for default) |
| `[scripts.build]` | `command` | Empty = default zig build; supply `command` to fully override |
| `[scripts.test]` | `filter` | Regex; only test blocks whose name matches this filter run (e.g. `"api.*"`) |
| `[scripts.test]` | `failures` | `"fail-fast"` (default) or `"continue"` (run all, report all) |
| `[scripts.bench]` | `warmup` | Warmup iterations before measurement (default 10) |
| `[scripts.bench]` | `runs` | Measured iterations (default 100) |

```toml
[scripts]
build = { deps = [], command = "" }
test  = { deps = ["build"], filter = ".*",      failures = "fail-fast" }
bench = { deps = ["build"], warmup = 10, runs = 100 }
```

## `[modules]`

Submodule allow / deny list — a v0.1 stand-in for per-directory `mod.toml` (the latter is deferred to v0.2+). Surgically restricts which `deps/<name>/` paths are visible to the import resolver.

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `include` | array of globs | `[]` | Glob patterns accepted (allow-list). Empty + no `[modules."<glob>"]` table = all visible |
| `exclude` | array of globs | `[]` | Glob patterns denied (applied after `include`) |

```toml
[modules]
include = ["math/*", "net/*"]
exclude = ["**/internal/**", "**/.skip/**"]

# Per-glob override block (optional):
[modules."math/*"]
visibility = "public"
```

Default behavior (section absent or `[modules]` with both lists empty): every `.zag` file under `deps/<name>/` is reachable from the import DAG, modulo the cyclic-DAG detector (see [Modules](22-modules.md)).

## Resolving Dependencies

The v0.1 protocol is git-only.

| Source declaration | Resolution |
|--------------------|------------|
| `git = "..."` + `rev = "<tag>"` | Pin to the SHA the tag points at |
| `git = "..."` + `branch = "<name>"` | Pin to the current branch HEAD at resolver time; rewritten to SHA in `zag.lock` |
| `git = "..."` + `version = "<range>"` | Latest semver-valid tag matching the range; pinned to SHA in `zag.lock` |
| `path = "..."` | No SHA resolution; integrity is verified against the local filesystem each build |

A future central registry (`zagpm.dev`) will be an alias layer over the git protocol; existing `zag.toml` files will not need to change.

## Reserved Keys

- The `__zag_` prefix is reserved for compiler-emitted code (e.g. `__zag_imported_0`). Don't name modules, deps, or scripts with this prefix.
- `features` is reserved for the future feature-flag system; v0.1 only honors `optional = true` deps behind the CLI's `--features` flag.
- `workspace` is reserved for the future multi-package system; v0.1 is single-package only.

## Validation

`zag validate` (forthcoming subcommand) re-reads every field and reports schema errors with file + line. Until that ships, parse-time errors from `zag build` are the gate — every required field missing or mis-typed produces a `parse: ...` diagnostic pointing at the manifest location.

## Compatibility Notes

**Why a separate file from `build.zig.zon`?**
- Zig's `.zon` schema is still evolving under zig 0.16+. Decoupling our dep surface buys forward-compat against zig's lexicon changes.
- freedom to add zag-specific fields (`bench`, `dev-dependencies`, `modules`, full lockfile metadata) without zig community review.
- `zag build` translates `zag.toml` into a transient `build.zig.zon` under `./.zig-cache/zag-build/`; users do not normally see or interact with it.

**Trade-offs**
- One extra TOML parser in the compiler instead of free reuse of zig's `.zon` parser.
- Build router must keep the `zag.toml → build.zig.zon` translation table updated across zig versions.
