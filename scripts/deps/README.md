# `scripts/deps/zag-deps` -- v0.1 dep-CLI bash skeleton

This directory holds the **reference implementation** of the v0.1 dep
sub-commands documented in
[`docs/manual/34-project-layout.md`](../../docs/manual/34-project-layout.md).
Not production-grade -- the git-fetch + SHA-resolution steps are
stubs that emit deterministic fixture SHA prefixes derived from
`sha256(input)`. Real implementations depend on `git ls-remote`,
network fallback, and the future central-registry plumbing.

## Sub-commands

| Command | Skeleton behaviour |
|---|---|
| `zag init` | Scaffold `zag.toml` + `.gitignore` + `src/main.zag` + empty `zag.lock`. |
| `zag add <git-url>[@rev]` | Stub-resolve to a `sha256(url@rev)`-derived SHA; cache at `~/.zag/cache/git/<host>/<path>/<sha>/`; materialise at `deps/<name>/`; append to `[dependencies]`; stamp a new `[[package]]` in the lockfile. |
| `zag fetch <git-url>[@rev]` | Populate `~/.zag/cache/` only -- no touch to project state. |
| `zag install` | Walk the lockfile closure; emits the resolved closure names. Skeleton does NOT hardlink cached trees into `deps/` (v2 implementation). |
| `zag update [name]` | Re-stamp `locked-at` timestamp on the lockfile. Skeleton uses deterministic stubbed SHAs. |
| `zag vendor` | Copy `deps/` into `vendor/` per-dir via atomic-rename. |
| `zag outdated` | List deps with a "would advance" placeholder. Skeleton does not query upstream. |
| `zag lock-ls` | Dump the lockfile closure in human-readable form. |
| `zag validate` | Manifest + lockfile integrity check. |
| `zag --help` | Print the banner. |

## Skeleton limits

**Stub SHA resolution.** `stub_sha()` derives a 13-char hex prefix
from `sha256(input)`. Real `[dependencies]` resolution uses
`git ls-remote <url> <ref>`. The skeleton's hashes are deterministic
from URL+rev and survive offline operation, but they DO NOT match
real upstream SHAs -- that's intentionally a fixture-vs-reality gap
that v2 closes.

**Atomic-write pattern.** Every file-creation call routes through
`atomic_write(path, content)`: a `mktemp` temp file is created in the
same directory, the content is written to it, then `mv` (POSIX
rename(2)) commits the change in one syscall. A crashed mid-write
leaves the previous file intact instead of half-cooked state. Same
idiom as `scripts/install.sh::mirror_zig_into_vendor`.

**Cache layout.** Mirrors the canonical spec:
`~/.zag/cache/git/<host>/<owner>/<repo>/<sha>/`. Each cache directory
holds a `SOURCE` marker (`git+<url>`) and a `RESOLVED_REV` marker
(the resolved SHA). Skeleton populates only markers -- v2 populates
the full bare-mirror + checked-out working tree.

## Running on the in-tree fixture

The `examples/project_layout/` fixture is the byte-aligned target
of the worked example in `docs/manual/34-project-layout.md`. To
exercise the dispatcher against it:

```
cd examples/project_layout
bash ../../scripts/deps/zag-deps outdated
bash ../../scripts/deps/zag-deps lock-ls
bash ../../scripts/deps/zag-deps validate
```

The skeleton's `cmd_outdated` walks the lockfile closure; `cmd_lock_ls`
dumps the lockfile; `cmd_validate` checks manifest + lockfile integrity.

To demo `cmd_add` (writes to the working tree), use a scratch dir
outside the fixture tree so the byte-aligned reference isn't
overwritten:

```
mkdir -p /tmp/zag-skel-demo
cd /tmp/zag-skel-demo
bash /path/to/repo/scripts/deps/zag-deps init
bash /path/to/repo/scripts/deps/zag-deps add 'https://github.com/zag-lang/log@v0.3.1'
bash /path/to/repo/scripts/deps/zag-deps outdated
bash /path/to/repo/scripts/deps/zag-deps validate
```

## Reference architecture

- `$1` dispatches through to a per-command `cmd_<name>` function.
- The manifest is parsed with Python's `tomllib` standard library
  via a small inline `parse_toml_field` helper (PEP 680, py3.11+).
  Python 3.11 is the project's baseline (mirrors `minimum_zig_version =
  "0.16.0"` which ships with Python 3.11 distributions).
- The lockfile is read with grep+awk for the entries this skeleton
  needs (no full TOML round-trip on the read side; v2 uses tomllib
  for write as well).
- All on-disk writes route through `atomic_write` (mktemp + mv)
  so a crashed mid-write leaves no half-cooked state.
- ANSI color codes copy `scripts/install.sh` verbatim so error /
  warn / success glyphs are visually consistent across the repo.

## Companion artifacts

`scripts/deps/zag-deps` is a single-file dispatcher (~360 lines).
It is intentionally NOT split into per-command files so the entire
v0.1 dep flow reads top-to-bottom in one file -- the type of artifact
that doubles as a living executable specification for the
behaviour described in the manual.
