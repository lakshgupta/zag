# Project Layout & Dependencies

A zag project is a directory containing `zag.toml` plus `src/`. This guide covers the canonical directory layout, the dependency workflow, and the `zag build / test / bench / run / check` CLI surface. The internals of the manifest itself live in [zag.toml Schema](35-zag-toml-schema.md).

## Quick Start

The smallest possible zag project is two files: a manifest and an entry point.

```
myproj/
├── zag.toml
└── src/
    └── main.zag
```

`src/main.zag`:

```zag
fun main() {
    print("hello, world\n");
}
```

From the project root:

```
zag run        # compile + execute
zag build      # compile only → ./zig-out/myproj
```

`zag init` scaffolds the whole tree (manifest, `.gitignore` for `deps/`, an `examples/hello.zag`).

## The Manifest: `zag.toml`

Every project has a `zag.toml` at its root. It's the canonical source of truth for project metadata, dependencies, and build settings. The minimum viable manifest is two fields:

```toml
[package]
name    = "myproj"
version = "0.1.0"
```

The full schema is in [zag.toml Schema](35-zag-toml-schema.md). The summary you need to read a project, without writing one:

| Section | Purpose |
|---------|---------|
| `[package]` | Required. Project identity |
| `[lib]` | Library root (when the project is a library) |
| `[[bin]]` | One per binary target |
| `[build]` | Default compile flags |
| `[dependencies]` | Runtime deps |
| `[dev-dependencies]` | Test/bench DAG only |
| `[scripts]` | Per-subcommand overrides (test filter, bench warmup, ...) |
| `[modules]` | In-tree submodule allow / deny list (optional) |

## Directory Layout (canonical)

```
myproj/
├── zag.toml                 # required
├── zag.lock                 # auto-generated, do not hand-edit
├── src/
│   ├── main.zag             # required for binary packages
│   └── lib.zag              # required for library packages
├── tests/                   # `zag test` discovers here
├── benches/                 # `zag bench` discovers here
├── examples/                # runnable demos (safe to omit)
├── deps/                    # gitignored; populated by `zag install`
└── vendor/                  # opt-in, checked in; populated by `zag vendor`
```

| Path | Required? | Purpose |
|------|-----------|---------|
| `zag.toml` | yes | package manifest |
| `src/main.zag` | for bin packages | entry point with `fun main()` |
| `src/lib.zag` | for lib packages | library root |
| `tests/` | no (recommended) | unit + integration tests |
| `benches/` | no | benchmarks |
| `examples/` | no | runnable demos |
| `deps/` | generated | third-party checkouts |
| `vendor/` | opt-in | offline-build root for `zag vendor` |

A single project may declare both a `lib` and one or more binaries:

```toml
[lib]
root = "src/lib.zag"

[[bin]]
name = "myproj"
root = "src/main.zag"

[[bin]]
name = "myproj-bench"
root = "examples/bench_main.zag"
```

## CLI Surface

| Command | Effect |
|---------|--------|
| `zag init` | Scaffold a new project tree (`zag.toml`, `.gitignore`, `src/main.zag`) |
| `zag build` | Compile per `[build]` settings to `./zig-out/` |
| `zag test` | Discover + run `test "..."` blocks under `tests/` |
| `zag bench` | Discover + run benchmarks under `benches/` |
| `zag run <file.zag>` | Compile then execute in one pass |
| `zag check` | Type-check + import resolve only; no codegen |
| `zag add <url>` | Fetch a new dep + record in `zag.toml` |
| `zag remove <name>` | Drop an entry from `zag.toml` and `deps/<name>/` |
| `zag install` | Sync `deps/` from `zag.lock` |
| `zag update` | Re-resolve advisory ranges and rewrite `zag.lock` |
| `zag outdated` | List deps whose upstream can move forward |
| `zag fetch <url>` | Populate `~/.zag/cache/` without touching `zag.toml` |
| `zag vendor` | Copy `deps/` content into `vendor/` for checked-in offline builds |
| `zag doc <module>` | Emit docs for a module path |

All build subcommands (`build`, `test`, `bench`, `run`) share `zig build`'s incremental cache under the hood — re-runs after a 1-line edit complete in seconds.

### Build flags

```
zag build -Doptimize=ReleaseFast          # matches zig build's OptimizeMode
zag build -Dtarget=x86_64-linux-gnu       # cross-compile
zag build -Dbounds-check                  # opt-in safety tools (see [Testing](25-testing.md))
```

`zag build --emit-build` writes the transient `build.zig.zon` + `build.zig` it normally keeps inside `./zig-cache/zag-build/`. Useful for debugging the build flow; leave it off otherwise.

## Dependencies

### Adding

```
zag add https://github.com/zag-lang/json           # latest default branch head
zag add https://github.com/zag-lang/json@v0.2.4    # pinned tag
zag add ../sibling/tls                              # local workspace-style path
```

Each `zag add`:
1. Resolves the URL into an exact git revision (tag → SHA, branch → HEAD's SHA, semver range → latest matching tag's SHA).
2. Fetches the SHA into `~/.zag/cache/`.
3. Materializes `deps/<package>/` from the cached working tree.
4. Writes the URL + revision into `zag.toml`.
5. Records the SHA + content hash in `zag.lock`.

### Fetching without adding

```
zag fetch https://github.com/zag-lang/json@v0.2.4
```

Populates `~/.zag/cache/` without touching `zag.toml`, `zag.lock`, or `deps/`. Useful for pre-warming a CI machine.

### Installing from `zag.lock`

```
zag install
```

Walks `zag.lock`, syncing `deps/<name>/` to the recorded SHAs. Idempotent: running twice in a row does nothing the second time. Use this when cloning a project on a fresh machine, in CI, or after `git pull`.

### Removing

```
zag remove json
```

Drops the entry from `zag.toml`, deletes `deps/json/`, and removes the `[[package]]` entry from `zag.lock`. Cache entries stay; use `zag install --gc` to drop unused ones.

### Updating

```
zag update                  # all entries
zag update -p json          # one package
zag update --dry-run        # print what would change without writing zag.lock
```

Re-resolves each advisory range against upstream. Writes a new `zag.lock`. Always review the diff with `git diff zag.lock` and re-run `zag test` before committing.

### Auditing freshness

```
zag outdated
```

Lists each `[dependencies]` entry with the local `zag.lock` revision, the latest matching revision upstream, and whether a `zag update` would advance it.

### Vendoring for offline builds

```
zag vendor
```

Copies every `deps/<name>/` into `vendor/<name>/`. Intended to be checked in.

Why both `deps/` and `vendor/`?
- `deps/` is the regular development workflow: fetches from the network, fast, gitignored.
- `vendor/` is the offline / hermetic build root: everything sourced from local path, no network calls, can be checked in.

`zag build` automatically prefers `vendor/` over `deps/` if both exist. The default is `deps/`.

> **Mirrors the existing `vendor/zig/` pattern.** This repo already mirrors the bundled Zig toolchain into `vendor/zig/` (see `scripts/install.sh`'s `mirror_zig_into_vendor`). The user-facing `vendor/` here is the same conceptual slot: opt-in checked-in source, network-free compile path.

## The Lockfile (`zag.lock`)

`zag.lock` is auto-generated on every `zag install`, `zag update`, `zag add`, or `zag remove`. It pins each dependency to an exact git SHA + content hash. Manual edits are overridden by the next command that touches deps.

```toml
# zag.lock — pinned dependency closure.
# Generated by `zag install`. Edit only with `zag add` / `zag update`.

[metadata]
zag-version  = "0.1.0"
generated-at = "2026-07-12T14:32:11Z"
resolver     = "git-only"

[[package]]
name     = "json"
source   = "git+https://github.com/zag-lang/json#v0.2.4"
git-rev  = "abc123def456…"
git-tree = "f7a9…"
sha256   = "01ba4719c80b6fe911b091a7c05124b64eeece964e09c1ef59a417261e7fecf0"

[[package]]
name     = "http"
source   = "git+https://github.com/zag-lang/http#v1.0.0"
git-rev  = "deadbeef…"
git-tree = "01ab…"
sha256   = "9b71d5b0a3a2c2d18eea40b0bcb2a1f3…"
```

`zag build` re-hashes the resolved source tree on every run. If `deps/<name>/` differs from `zag.lock`'s recorded `sha256`, the build aborts with `deps dirty` or `zag.lock stale`. This is the "no hidden control flow" bound on the build pipeline: every byte the cipher compiles against is auditable from `zag.lock` + `~/.zag/cache/`.

## Cache

The cache lives at `~/.zag/cache/`:

```
~/.zag/cache/
├── git/<host>/<owner>/<repo>/<sha>/    # bare git checkouts at exact revisions
└── sha256/<hash>/                      # content-addressed blobs (vendor re-validation)
```

`zag install --gc` removes cache entries older than `cache.max_age_days` (default 30). The cache is shared across every project on your machine: `deps/` is per-project, but `~/.zag/cache/` is global.

## Maintenance Workflow

**Project maintainer**
1. `zag init` to scaffold.
2. `zag add <url>` to add deps. Run `zag test` after each add to catch breakage early.
3. `zag update` periodically. Always `git diff zag.lock` and `zag test` before merging a lockfile change.
4. `zag vendor` before tagging a release — gives downstream offline-build parity.

**Library author**
- Repo with its own `zag.toml` (declaring `[lib]`). Tag a release.
- Optional: publish to a future central registry once that ships. Until then, downstream users reference by git URL.

**CI**
- `zag install` (cache warm-up) → `zag test` → `zag build` → artifact upload. Mirror `vendor/` for hermetic builds.

## Migration Notes

**Coming from zig's `build.zig.zon`** — the `[dependencies]` table is a separate, richer layer (dev-dependencies, scripts, modules allow / deny list, lockfile with content hashes). The transient `build.zig.zon` written by `zag build` includes a `.dependencies` section for any deps `zag build` resolved; you do not need to touch it.

**Coming from Cargo** — `deps/` ≈ a per-project target dir for source, `vendor/` ≈ a true vendoring mode, `~/.zag/cache/` ≈ `~/.cargo/registry/`. Zag deliberately keeps cache and vendor separated, mirroring the existing `vendor/zig/` pattern in this repo.

**Coming from npm / Go modules** — `zag.lock` is mandatory and authoritative (no separate `--frozen-lockfile` flag needed); `node_modules` / Go's module cache are private to the cache dir, never in-project.

## Future Edges

- A central `zagpm.dev` registry will be an alias layer over the git protocol — existing `zag.toml`s do not need to change.
- Multi-package workspaces (`[workspace]` covering a tree of packages with one lockfile) are deferred to v0.2+.
- Per-directory `mod.toml` for module-level metadata is deferred; submodule allow-list lives in `zag.toml` under `[modules]` for v0.1.
- A signature / checksum layer for upstream integrity (`zag audit`) is on the roadmap.

### On-disk counterpart

The on-disk counterpart of this example lives at [`examples/project_layout/`](../../examples/project_layout/) (sibling path-dep at [`examples/sibling-tls/`](../../examples/sibling-tls/)) -- readers can `diff` that fixture against the blocks above to verify byte-level shape parity.

## What Lives Where (cheat sheet)

| Question | Answer |
|----------|--------|
| Where does my project declare itself? | `zag.toml` (`[package]`) |
| Where do tests go? | `tests/<name>.zag` (each file contains `test "..." { ... }` blocks) |
| Where do benchmarks go? | `benches/<name>.zag` |
| Where do deps live after `zag add`? | `deps/<name>/` |
| Where do deps live for offline builds? | `vendor/<name>/` |
| Where do deps live on disk across projects? | `~/.zag/cache/` |
| Where is the SHA + content hash for each dep? | `zag.lock` |

---

## Worked Example (end-to-end)

A small `cfgtool` project: a CLI that reads JSON config files using a remote `json` library and a sibling path-dep utility package. This walkthrough exercises the v0.1 dep protocol end-to-end — every artifact shown below is the byte-level shape the compiler will emit on disk.

### 1. Initial Layout

```
~/work/cfgtool/
├── src/
│   └── main.zag
├── tests/
│   └── parse.zag
└── deps/                     # not yet present; `zag install` will populate it
```

### 2. Initialise

```
zag init
```

Creates:

```
~/work/cfgtool/
├── .gitignore                # added: `deps/`, `.zig-cache/`, `zig-out/`
├── examples/
│   └── hello.zag
├── src/
│   └── main.zag              # edited below to fit
├── tests/                    # empty
└── zag.toml                  # minimum-viable manifest
```

### 3. Author the manifest

Edit `zag.toml` to declare the project identity, build settings, and three dependencies (one remote pinned tag, one remote tracking branch, one local sibling path-dep) plus one dev-dep:

```toml
[package]
name    = "cfgtool"
edition = "2024"
version = "0.1.0"

[project]
description = "Tiny CLI that reads JSON config files"
license     = "MIT"
repository  = "https://github.com/example/cfgtool"
authors     = ["Lex <e@example.com>"]

[lib]
root = "src/lib.zag"

[[bin]]
name = "cfgtool"
root = "src/main.zag"

[build]
target   = "native"
optimize = "Debug"
output   = "zig-out"
check    = ["bounds", "ref"]

[dependencies]
# Remote, pinned tag (will produce a deterministic SHA in zag.lock):
json = { git = "https://github.com/zag-lang/json", rev = "v0.2.4" }

# Remote, tracking a branch head (resolver will pin it to the current
# branch HEAD's SHA at `zag install` time):
log = { git = "https://github.com/zag-lang/log", branch = "main" }

# Local sibling package at ../sibling-tls (workspaces-style, never
# appears in zag.lock; integrity is verified against the local
# filesystem each build):
internal-tls = { path = "../sibling-tls" }

[dev-dependencies]
# Only on the `zag test` / `zag bench` DAG, not the `zag build` DAG:
zig-assert = { git = "https://github.com/example/zig-assert", rev = "v0.3.1" }

[scripts]
build = { deps = [], command = "" }
test  = { deps = ["build"], filter = ".*", failures = "fail-fast" }
bench = { deps = ["build"], warmup = 10, runs = 100 }

[modules]
include = ["json/*", "log/*"]          # restrict what's reachable from `deps/`
```

### 4. Add a dependency

```
zag add https://github.com/zag-lang/log@v0.3.1
```

What happens under the hood:

1. Resolve `v0.3.1` tag → exact git SHA (`a3f7b1c…`).
2. Fetch the SHA into `~/.zag/cache/git/github.com/zag-lang/log/<sha>/` (bare `git clone` + checkout).
3. Materialise `deps/log/` from the cached working tree.
4. Insert `log = { git = "https://github.com/zag-lang/log", rev = "v0.3.1" }` into `[dependencies]`.
5. Stamp a new `[[package]]` entry in `zag.lock` with the resolved SHA + content hash.

After the command, `zag run` works without any further setup — `deps/log/` is already populated.

### 5. Inspect `deps/` and `~/.zag/cache/`

```
$ ls deps/
log/

$ find deps/log -maxdepth 2
deps/log/
├── mod.zag
├── README.md
├── src/
└── tests/

$ ls ~/.zag/cache/git/github.com/zag-lang/log/
a3f7b1c.../    # working tree, ready to be hard-linked / copied into deps/
bare.git/     # bare git mirror -- shared across all projects using this SHA
```

The bare-mirror slot in `~/.zag/cache/` is what makes a second project depending on the same SHA zero-cost: the cache is shared.

### 6. Run `zag install` from a fresh checkout

After cloning this repo on a new machine:

```
git clone https://github.com/example/cfgtool
cd cfgtool
zag install
# → resolves every [[package]] in zag.lock, populates deps/{json,log,zig-assert}
```

Idempotent: a second run prints `nothing to do` and exits 0.

### 7. Resulting `zag.lock`

`zag.lock` matches the [spec's §9.4](manual/../spec.md#94-dependencies) lockfile shape byte-for-byte:

```toml
# zag.lock — pinned dependency closure.
# Generated by `zag install`. Edit only with `zag add` / `zag update`.

[metadata]
zag-version  = "0.1.0"
generated-at = "2026-07-12T14:32:11Z"
resolver     = "git-only"

[[package]]
name     = "json"
source   = "git+https://github.com/zag-lang/json#v0.2.4"
git-rev  = "abc123def456…"
git-tree = "f7a9…"
sha256   = "01ba4719c80b6fe911b091a7c05124b64eeece964e09c1ef59a417261e7fecf0"

[[package]]
name     = "log"
source   = "git+https://github.com/zag-lang/log#a3f7b1c…"
git-rev  = "a3f7b1c…"
git-tree = "01ab…"
sha256   = "9b71d5b0a3a2c2d18eea40b0bcb2a1f3…"

[[package]]
name     = "zig-assert"
source   = "git+https://github.com/example/zig-assert#v0.3.1"
git-rev  = "c4d9a81…"
git-tree = "b6f3…"
sha256   = "21e2c9…"
```

Notice what's NOT here: the local sibling `internal-tls` (`path = "..."`) never appears. Path-deps are resolved against the local filesystem at build time and are not part of the wire-pinned closure. The dev-dep `zig-assert` is in `zag.lock` because `zag test` pulled it into the closure; if you `zag install --gc` after pruning it from `[dev-dependencies]`, the entry disappears.

### 8. Tests + dev-deps

```
zag test
```

walks `tests/` for `test "..."` blocks, builds against the dev-dep DAG (including `zig-assert`), and reports results. The `[scripts.test].filter` regex is applied to test names — for example, `zag test --filter=parse` runs only `test "parse: ..."` blocks.

### 9. Update

```
zag update --dry-run
# json:   locked abc123def456…, upstream v0.2.5 at b9e2d14…     (would advance)
# log:    locked a3f7b1c…,      upstream: a3f7b1c…              (no change  — branch)
# zig-assert: locked c4d9a81…, upstream v0.3.2 at f1c4a73…     (would advance)

zag update -p json
# → rewrites the json SHA + hash; `git diff zag.lock` shows the diff

zag update
# → applies all advisories; `zig build test` before merging the lockfile change
```

For the `internal-tls` path-dep, `zag update` is a no-op — there's no upstream to consult.

### 10. Vendoring for offline builds

```
zag vendor
# → copies deps/{json,log}/ → vendor/{json,log}/
# → intended to be checked in for hermetic offline builds
```

After vendoring:

```
$ ls vendor/
json/    log/     # same contents as deps/ at the time of vendoring
```

`zag build` automatically prefers `vendor/` over `deps/` when both exist. The two-tree design is the same one zig uses in this repo's own `vendor/zig/` mirror: an "always-fresh" online path (`deps/`) and a "checked-in verbatim" offline path (`vendor/`). The local sibling `internal-tls` is NOT vendored (it's a path-dep, not a remote dep) — `vendor/` is reserved for remote-derived code only.

### 11. The complete cycle

```
┌─────────────────────────────────────────────────────────────────────┐
│  Author (you)                                                       │
│  ├ zag init                                                         │
│  ├ zag add <url>             # deps/, ~/.zag/cache/, zag.lock       │
│  ├ zag build / test / bench                                        │
│  ├ zag update -p <name>      # advance one dep                      │
│  └ zag vendor                # ship a hermetic build                │
│                                                                     │
│  Fresh CI:                                                          │
│  └ zag install              # hydrate deps/ from zag.lock + cache   │
│                                                                     │
│  Fresh machine, no network:                                         │
│  ├ vendor/ is committed         # contains the offline-ready tree   │
│  └ zag build → vendor/ preferred ─→ no fetch; hermetic build        │
└─────────────────────────────────────────────────────────────────────┘
```

This is the v0.1 dep loop: declared in `zag.toml`, pinned in `zag.lock`, hydrated into `deps/`, mirrored into `vendor/`, freshened in `~/.zag/cache/`, and exercised by `zag build / test / bench`. Each artifact has exactly one canonical home, and the byte-level shape of every one of them is in [zag.toml Schema](35-zag-toml-schema.md) or the [spec](manual/../spec.md#94-dependencies).
| Where is my build going? | `./zig-out/` |
| Where is `zig build`'s cache? | `./.zig-cache/` |
