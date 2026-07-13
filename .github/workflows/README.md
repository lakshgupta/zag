# zag/.github/workflows

This directory holds GitHub Actions workflows for the zag compiler.

  - `release.yml` — build + publish a GitHub Release for zag when a
    `v*` tag is pushed (or on manual `workflow_dispatch`). Produces
    six prebuilt binaries (linux/macos/windows × x86_64/arm64),
    packages them as `tar.gz` or `zip` archives matching the URL
    convention in `zag-install.sh`, generates SHA256 checksums, and
    uploads them to the Release via `softprops/action-gh-release@v2`.
