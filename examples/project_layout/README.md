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

## What's intentionally simplified

The `.zag` source files here are **standalone programs** — they do not
`import internal_tls` or any other dep. The dep-resolver's
`path = "..."` plumbing is upcoming work in the v0.1 dep CLI. Until
that ships, the fixture's source layer runs cleanly under
`examples/run_all.sh`, and the project-layout story is carried by the
metafiles (`zag.toml`, `zag.lock`):

| Path in walkthrough | On-disk fixture path | Purpose |
|---|---|---|
| `src/lib.zag` | `src/lib.zag` | Per `[lib].root` |
| `src/main.zag` | `src/main.zag` | Per `[[bin]].root` |
| `tests/parse.zag` | `tests/parse.zag` | Conventional tests/ root |
| `internal-tls` (path-dep) | [`../sibling-tls/`](../sibling-tls/) | Local sibling, `path = "../sibling-tls"` |

`tests/parse.zag` ships with a stub `fun main()`. Replace it with real
`test "..."` blocks once `zag test` ships.

## How to use this as a template

```
cp -R examples/project_layout ~/work/my_new_project
cd ~/work/my_new_project
# edit [package].name, [package].version, [[bin]].name, deps...
zag test       # once `zag test` ships
```

## Companion: the sibling path-dep

[`../sibling-tls/`](../sibling-tls/) ships alongside this fixture as the
on-disk target for the `internal-tls = { path = "../sibling-tls" }` entry
in `zag.toml`. It is a one-function stub; the real `internal_tls` surface
ships when the dep-CLI work lands.
