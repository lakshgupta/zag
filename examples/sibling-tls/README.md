# sibling-tls — Path-Dep Stub

This directory is the `path = "../sibling-tls"` target referenced from
[`../project_layout/zag.toml`](../project_layout/zag.toml) under the
`internal-tls` key, imported as:

```zag
import internal_tls.{tls_marker}
```

(The dep key's `-` becomes `_`; the entry point is this package's
`[lib] root = "src/lib.zag"`.) See
[`../project_layout/README.md`](../project_layout/README.md)
§"Dependencies (working)".

It ships as a one-function stub because the real TLS implementation is
unrelated to the fixture role. The `fun main()` is a harness-friendly
stub: `examples/run_all.sh` runs `zag run <file>` on every file it
finds, so this sibling needs an entry point to stay green there — its
production role is as an imported dependency.

Real TLS implementation is out of scope for the fixture role; this
directory is a **shape exemplar only**.
