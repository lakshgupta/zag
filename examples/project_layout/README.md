# cfgtool — Project Layout Fixture

This directory is the **byte-for-byte artifact** of the
[Worked Example (end-to-end) section](../../docs/manual/34-project-layout.md)
in `docs/manual/34-project-layout.md`.

`zag.toml`, `src/lib.zag`, `src/main.zag`, and `tests/parse.zag`
here correspond line-for-line to the manual's worked-example blocks.
`zag.lock` byte-matches the walked-example lockfile body from the manual,
with one fixture-only addition: a trailing `# NOTE:` block flagging the
illustrative SHA values as placeholders (verify by `diff` against the
fenced code blocks). Use this directory as a copy-paste template for
new v0.1 zag projects.

## Dependencies (working)

Both dep kinds in `zag.toml` resolve and are usable from source:

- **path dep** — `internal-tls = { path = "../sibling-tls" }`:
  compiled straight from that directory, no fetch.
- **remote git dep** — declared with `zag pkg add <url>`, cloned to
  `deps/<name>/` by `zag install`.

Import them with the dep key, dashes rewritten to underscores:

```zag
import internal_tls.{tls_marker}
import lib.{lib_marker}
```

The dep's entry point is its own `[lib].root` (default
`src/lib.zag`); other modules in the dep are reachable as
`<dep>.<module path>`. Transitive deps (a dep's own manifest
entries) are not resolved in v1.

## What's intentionally simplified

The remote deps in `zag.toml` (`json`, `log`, `zig-assert`) are
manifest-only — nothing imports them, so no fetch is needed to build
this fixture. The dep machinery itself is exercised by the path-dep
above. Everything else mirrors the manual:

| Path in walkthrough | On-disk fixture path | Purpose |
|---|---|---|
| `src/lib.zag` | `src/lib.zag` | Per `[lib].root` |
| `src/main.zag` | `src/main.zag` | Per `[[bin]].root` |
| `tests/parse.zag` | `tests/parse.zag` | Conventional tests/ root |
| `internal-tls` (path-dep) | [`../sibling-tls/`](../sibling-tls/) | Local sibling, `path = "../sibling-tls"` |

`tests/parse.zag` is the conventional tests/ root: `fun test_*`
cases (no `@[test]` annotation needed — location implies suite
membership) testing `src/lib.zag` and the path-dep via
`import lib.{lib_marker}` / `import internal_tls.{tls_marker}`.
Run it with `zag test` from the project root; `examples/run_all.sh`
skips `tests/` dirs (suites aren't runnable programs).

## How to use this as a template

```
cp -R examples/project_layout ~/work/my_new_project
cd ~/work/my_new_project
# edit [package].name, [package].version, [[bin]].name, deps...
zag test       # discovers tests/, builds one binary per file, runs
```

## Companion: the sibling path-dep

[`../sibling-tls/`](../sibling-tls/) ships alongside this fixture as the
on-disk target for the `internal-tls = { path = "../sibling-tls" }` entry
in `zag.toml` — a real, importable path-dep (see "Dependencies
(working)" above). It is a one-function stub; the real TLS surface
is out of scope for the fixture role.
