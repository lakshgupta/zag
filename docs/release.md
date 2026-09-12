# Zag Release Process

Cutting a release is a three-action job: **bump the version, commit, push a tag**.
Everything else — running the test suites, cross-compiling all 4 (OS, arch)
targets, packaging the archives, writing SHA256 checksums, and publishing the
GitHub Release with all assets — is done by the CI workflow at
`.github/workflows/release.yml`, which triggers on every `v*` tag push.

## How the workflow works

When a tag matching `v*` lands on `origin`, the `release` workflow runs four
jobs in sequence on the **tagged commit**:

1. **`test`** — `zig build test` (unit suite + the discarded-result audit) and
   `zig build example_tests` on ubuntu-latest. A failure here aborts the
   release before any binary is built.2. **`build`** — cross-compiles all 4 targets (`x86_64`/`aarch64` ×
   `linux-gnu` / `macos-none`) with `zig build install
   -Doptimize=ReleaseFast`, restages each binary under the canonical
   `zag-<os>-<arch>` name, and sanity-runs `<binary> version` per leg.
   Windows targets are **not** built: the compiler runtime is posix-deep
   and cannot build on windows-gnu yet (see the WINDOWS note in the
   workflow).
3. **`package`** — aggregates the binaries into `dist/<version>/`, archives
   each one (`tar.gz`) with a `VERSION` file plus the two installers bundled
   inside, copies `zag-install.sh` and `install.ps1` in as standalone assets,
   and writes `checksums.txt`.
4. **`publish`** — creates the GitHub Release `Zag v<version>` (with
   auto-generated notes) and attaches 7 assets: 4 archives + `checksums.txt` +
   the 2 standalone installers.

There is deliberately no `workflow_dispatch`: the tag itself is the single
canonical trigger, and CI always builds exactly the commit you tagged.

## Prerequisites

- Zig 0.16.0 (only needed to run the local pre-tag checks in Step 3)
- git + push access to `origin` (`lakshgupta/zag`)
- `gh` (optional, but strongly recommended for Steps 5–6)

A **clean working tree** is a hard prerequisite: everything you want in the
release must be committed and pushed before you tag, because CI checks out the
tagged commit and builds that — nothing from your local, uncommitted state
makes it into the release.

---

## Step 1 — Pick the version

Zag follows [SemVer](https://semver.org/):

| Bump | When | Example |
|---|---|---|
| `0.MINOR.0` | New features, public API changes | `0.2.0` |
| `0.MINOR.PATCH` | Bug fixes only | `0.1.1` |
| `0.MINOR.PATCH-rc.N` | Pre-release smoke run | `0.2.0-rc.1` |

The **bare** version goes into the source files; the `v`-prefixed form is the
git tag and release name:

```bash
export VERSION="0.2.0"           # bare version — no leading 'v'
export TAG="v${VERSION}"         # git tag + GitHub Release name
```

## Step 2 — Bump the version

One bump site: the `.version` line in `build.zig.zon`. `zag version` reads it
from there — `build.zig` extracts the string at config time (`zonVersion()`
→ `build_options.zag_version`) and `src/main.zig` prints it, so every binary
CI builds reports the tagged version with no second copy to keep in sync.

```bash
sed -i "s/\.version = \".*\"/.version = \"${VERSION}\"/" build.zig.zon

# Verify it landed
grep -n '\.version' build.zig.zon          # -> .version = "0.2.0",
git diff --stat                            # exactly 1 file changed
```

If the `grep` still shows the old version, fix it by hand — don't tag a
release whose binary reports the wrong number.

## Step 3 — Test, commit, push

```bash
zig build test             # ~1s unit suite; also runs the discard audit
zig build example_tests    # `zag test` over the example catalog
```

Both must pass before tagging — the CI `test` job runs the same steps and any
failure there kills the release after the fact.

Then commit the bump and push it to the branch you'll tag:

```bash
git add build.zig.zon
git commit -m "chore: bump version to ${VERSION}"
git push origin HEAD
```

> The tag **must point at a commit that contains this bump** (and that is
> already on `origin`). Tagging the pre-bump commit produces a release whose
> binaries all report the previous version — CI will happily build and publish
> it anyway.

## Step 4 — Tag and push

```bash
git tag -a "${TAG}" -m "Zag ${TAG}"
git push origin "${TAG}"
```

The tag push is the release button: CI starts building the moment it lands.
A tag is one-shot — **never force-push a tag that has a release attached**.
If the tag was pushed by mistake before any release exists, delete it
(`git push origin :refs/tags/${TAG}`) and redo Steps 2–4; if a release already
exists, bump to a new version instead.

## Step 5 — Watch CI build and publish

```bash
gh run list --workflow release.yml --limit 3
gh run watch   # or: gh run watch <run-id>
```

Rough timing: the `test` job is a few minutes; the 6-target `build` matrix
adds ~5–8 more; `package` + `publish` are fast. When the run goes green, the
release exists at
`https://github.com/lakshgupta/zag/releases/tag/${TAG}` with 7 assets:

```
zag-${VERSION}-linux-x86_64.tar.gz
zag-${VERSION}-linux-arm64.tar.gz
zag-${VERSION}-darwin-x86_64.tar.gz
zag-${VERSION}-darwin-arm64.tar.gz
checksums.txt                         zag-install.sh    install.ps1
```

Each archive is self-contained: `zag` + `VERSION` + `zag-install.sh` +
`install.ps1`.

## Step 6 — Verify the release

```bash
gh release view "${TAG}"

# Download + smoke-test one archive from a clean extract
gh release download "${TAG}" -p 'zag-'"${VERSION}"'-linux-x86_64.tar.gz' -O /tmp/zag.tgz
mkdir -p /tmp/verify && tar -xzf /tmp/zag.tgz -C /tmp/verify
file /tmp/verify/zag                # -> ELF 64-bit LSB executable, x86-64
/tmp/verify/zag version             # -> zag ${VERSION}

# Verify checksums (one sha256 line per archive)
gh release download "${TAG}" -p checksums.txt -R lakshgupta/zag -O - | head
```

Also confirm the user-facing install paths resolve to the new release:

```bash
# Latest-release installer (resolves `latest` via the GitHub API)
curl -fsSL https://raw.githubusercontent.com/lakshgupta/zag/main/zag-install.sh | bash

# Pinned to this release
bash zag-install.sh --version "${TAG}"
```

## If the run fails

- `fail-fast: false` — one broken matrix leg doesn't block the others; check
  the failed leg's logs for the specific `-Dtarget`.
- The `test` job failing means `main` was tagged broken: fix, then follow the
  no-force-push rule above (delete the unreleased tag or bump).
- A `package`/`publish` failure after binaries built is the cheap case: fix
  the workflow, delete the unreleased tag, re-tag.
