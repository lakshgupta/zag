# sibling-tls — Path-Dep Stub

This directory is the `path = "../sibling-tls"` target referenced from
[`../project_layout/zag.toml`](../project_layout/zag.toml) under the
`internal-tls` key.

It ships as a one-function stub because the v0.1 dep-CLI work — and the
real sibling-package TLS surface — is upcoming. The marker function
`tls_marker() -> bool` proves the on-disk tree resolves to compilable
zag source so `examples/run_all.sh` stays green if it walks into this
directory.

Real TLS implementation is out of scope for the fixture role; this
directory is a **shape exemplar only**.
