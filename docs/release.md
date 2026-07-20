# Zag Release Process

> **Current scope:** Linux artifacts only (`zag-linux-x86_64.tar.gz` and `zag-linux-arm64.tar.gz`). macOS and Windows targets cross-compile cleanly under zig 0.16, but binary signing / notarization / code-signing for those platforms is not yet wired up. The CI workflow at `.github/workflows/release.yml` still builds all 6 (OS, arch) targets on `v*` tag push — the manual path described here is the workaround for the Linux-only publishing scope. To publish Linux-only via CI, narrow that workflow's matrix to the `linux-gnu` rows; otherwise follow the manual steps below.

This document walks through the maintainer-facing steps for cutting a Zag release: bump the version, run the tests, build Linux binaries, package with checksums, tag, and publish on GitHub Releases.

---

## Prerequisites

Install these locally before starting:

| Tool | Version | Verify |
|---|---|---|
| Zig | 0.16.0 | `zig version` |
| GitHub CLI | any recent | `gh --version` |
| git | any recent | `git --version` |

You also need push access to `origin` of `zag-lang/zag` and a GitHub account with `contents: write` on the repo.

---

## Step 1 — Pick the version

Zag follows [SemVer](https://semver.org/). Pick the next bump:

| Bump | When | Example |
|---|---|---|
| `0.MINOR.0` | New features, public API changes | `0.2.0` |
| `0.MINOR.PATCH` | Bug fixes only | `0.1.1` |
| `0.MINOR.PATCH-pre.N` | Pre-release / nightly | `0.2.0-rc.1` |

Export the version for the rest of the session — the **bare** form goes into `build.zig.zon`, the `v`-prefixed form is the git tag and GitHub Release name:

```bash
export VERSION="0.2.0"           # the bare version number — no leading 'v'
export TAG="v${VERSION}"         # the git tag + GitHub Release name
```

---

## Step 2 — Bump the version string

The canonical version lives on one line at the top of `build.zig.zon`:

```bash
grep '^\.version' build.zig.zon                # show current
sed -i "s/^\.version = \".*\"/\.version = \"${VERSION}\"/" build.zig.zon
grep '^\.version' build.zig.zon                # confirm the new value
git diff -- build.zig.zon                      # eyeball the diff
```

Commit the bump:

```bash
git add build.zig.zon
git commit -m "Bump version to ${VERSION}"
git push origin HEAD
```

---

## Step 3 — Run the unit tests

Skip this and you'll regret it:

```bash
zig build test
```

Expected: no `error: ...` lines, every `test "..."` block reports `ok`. Anything else is a release blocker — fix and rerun before continuing.

---

## Step 4 — Build the Linux release binaries

Zag ships two Linux glibc builds. Cross-compile from any host that has zig 0.16:

| `-Dtarget` | Output filename | Audience |
|---|---|---|
| `x86_64-linux-gnu` | `zag-linux-x86_64` | Linux desktops, CI runners, most cloud VMs |
| `aarch64-linux-gnu` | `zag-linux-arm64` | AWS Graviton, Apple Silicon under Linux, Raspberry Pi 4+, mobile Linux |

Build each, then stage the binaries under the canonical `zag-<os>-<arch>` names that `scripts/package.sh` expects:

```bash
mkdir -p /tmp/zag-staging/bin

zig build install -Dtarget=x86_64-linux-gnu   -Doptimize=ReleaseFast --prefix /tmp/zag-staging/x86
zig build install -Dtarget=aarch64-linux-gnu  -Doptimize=ReleaseFast --prefix /tmp/zag-staging/arm

cp /tmp/zag-staging/x86/bin/zag   /tmp/zag-staging/bin/zag-linux-x86_64
cp /tmp/zag-staging/arm/bin/zag   /tmp/zag-staging/bin/zag-linux-arm64
chmod +x  /tmp/zag-staging/bin/zag-linux-{x86_64,arm64}

# Sanity-check: both report the freshly-bumped version
/tmp/zag-staging/bin/zag-linux-x86_64 version
/tmp/zag-staging/bin/zag-linux-arm64 version
```

If both report `${VERSION}` (per the `build.zig.zon` edit in Step 2), you're good. If either segfaults or reports an old version, the `cp` or `chmod` steps above missed; redo them.

If you only have an x86_64 host, the `aarch64-linux-gnu` build is a pure cross-compile via zig's bundled LLVM — no QEMU, no chroot, just a slow linker step. Smoke-test the arm64 binary on real arm64 hardware or under QEMU user-mode emulation before publishing (see Step 6).

---

## Step 5 — Package with `scripts/package.sh`

The packager lays each binary into a versioned archive alongside a `VERSION` file, and emits a SHA256 `checksums.txt` covering every archive:

```bash
./scripts/package.sh "${VERSION}" --bin-dir /tmp/zag-staging/bin
```

Expected output:

```
═══ Zag Distribution Packager v0.2.0 ═══
  ✓ zag-linux-x86_64.tar.gz     (~180 MB)
  ✓ zag-linux-arm64.tar.gz      (~175 MB)
  ✓ checksums written to dist/0.2.0/checksums.txt
```

The on-disk layout after a clean run:

```
dist/${VERSION}/
  zag-linux-x86_64.tar.gz       # binary + VERSION file
  zag-linux-arm64.tar.gz        # binary + VERSION file
  checksums.txt                 # sha256 lines for every *.tar.gz
```

Each `.tar.gz` extracts as:

```
zag              # the compiler
VERSION          # contains "${VERSION}"
```

The packager's `TARGETS` array (`scripts/package.sh` lines 60–67) is the single source of truth for which (OS, arch) pairs the on-disk layout expects. If you add a target here, also add a row to the GitHub Actions matrix in `.github/workflows/release.yml` so the CI path stays in lockstep.

> **Why both tar.gz AND checksums.txt?** `checksums.txt` is the audit trail: users on slow connections can verify their download with `sha256sum -c checksums.txt` against the listed hashes. The `<version>` directory keeps multiple releases side-by-side without overwriting each other.

---

## Step 6 — Smoke-test the artifacts

Before publishing, exercise each archive on a clean extract to catch a broken binary before users do:

```bash
# Run these commands from the repo root (the `dist/` path is relative).

# x86_64
mkdir -p /tmp/verify-x86
tar -xzf dist/${VERSION}/zag-linux-x86_64.tar.gz -C /tmp/verify-x86
file /tmp/verify-x86/zag                      # -> ELF 64-bit LSB executable, x86-64
/tmp/verify-x86/zag version                   # -> ${VERSION}
rm -rf /tmp/verify-x86

# arm64 (best on real arm64 hardware; QEMU user-mode is acceptable for a quick check)
mkdir -p /tmp/verify-arm
tar -xzf dist/${VERSION}/zag-linux-arm64.tar.gz -C /tmp/verify-arm
file /tmp/verify-arm/zag                      # -> ELF 64-bit LSB executable, ARM aarch64
/tmp/verify-arm/zag version                   # -> ${VERSION}
rm -rf /tmp/verify-arm
```

A failure here means the binary is broken before users see it — debug locally on the target arch before publishing. The `file` output proves the cross-compile landed in the right ELF class. Running `zig version` (rather than a `.zag` compile) keeps the smoke check fast and self-contained.

---

## Step 7 — Tag the release

The git tag is the canonical handle for the release — the GitHub Release will use the same name:

```bash
git tag -a "${TAG}" -m "Zag ${TAG}"
git push origin "${TAG}"
```

> **Don't push the tag until you've finished Steps 5 and 6.** The tag push is a one-shot — once the tag is reachable on `origin`, you should bump to a new version (`v${VERSION}-1`, typically a hotfix) and start over from Step 2. Re-tagging a published release by `--force` is technically possible but visually disruptive to anyone who's already bookmarked the tag.

---

## Step 8 — Publish on GitHub Releases

Create the release and attach the three artifacts in one shot:

```bash
gh release create "${TAG}" \
    --title "Zag ${TAG}" \
    --generate-notes \
    dist/${VERSION}/zag-linux-x86_64.tar.gz \
    dist/${VERSION}/zag-linux-arm64.tar.gz \
    dist/${VERSION}/checksums.txt
```

What each flag does:

| Flag | Effect |
|---|---|
| `--title "Zag ${TAG}"` | Sets the human-readable release name (the tag itself stays `v0.2.0` per `--tag_name` semantics implicit in positional) |
| `--generate-notes` | Auto-populates the Markdown body with PR titles since the last tag — saves a manual changelog write |
| The three trailing paths | The exact archive files + checksums.txt that GitHub hosts under the release |

Expected: GitHub responds with the release URL. The artifacts appear immediately under `https://github.com/zag-lang/zag/releases/tag/${TAG}`.

> **CI race-avoidance.** `.github/workflows/release.yml` also triggers on `v*` tag push with `concurrency: release-${github.ref}` + `cancel-in-progress: true`. If you push the tag AND let CI run, CI will *also* try to mint a release and re-upload all 6 (OS, arch) targets — including macOS and Windows. To keep the manual Linux-only path clean, either (a) disable the workflow's `on: push: tags` trigger for this release, or (b) accept CI's broader release and skip this manual step. If you intend to publish Linux-only on a permanent basis, the better long-term fix is to narrow the workflow's `matrix` to the two `linux-gnu` rows.

---

## Step 9 — Verify on github.com

Open `https://github.com/zag-lang/zag/releases/tag/${TAG}` and confirm:

- ✅ All three files are attached (`zag-linux-x86_64.tar.gz`, `zag-linux-arm64.tar.gz`, `checksums.txt`)
- ✅ `checksums.txt` has one SHA256 line per attached `.tar.gz`
- ✅ The release notes under "What's Changed" list the PRs since the last tag (auto-generated by `--generate-notes`)
- ✅ Download the artifacts on a *different* Linux machine and rerun Step 6's `file` + `version` checks — this is your last chance to catch a broken URL or a partially-uploaded archive.

---

## Recap — the full command sequence

For ease of copy-paste, here is the entire release flow as one script-shaped block. Each `export` is sticky for the shell session; rerun exports if you start a new shell.

```bash
export VERSION="0.2.0"
export TAG="v${VERSION}"

# Step 2 — bump the version
sed -i "s/^\.version = \".*\"/\.version = \"${VERSION}\"/" build.zig.zon
git add build.zig.zon && git commit -m "Bump version to ${VERSION}" && git push origin HEAD

# Step 3 — tests
zig build test

# Step 4 — build Linux binaries
mkdir -p /tmp/zag-staging/bin
zig build install -Dtarget=x86_64-linux-gnu   -Doptimize=ReleaseFast --prefix /tmp/zag-staging/x86
zig build install -Dtarget=aarch64-linux-gnu  -Doptimize=ReleaseFast --prefix /tmp/zag-staging/arm
cp /tmp/zag-staging/x86/bin/zag   /tmp/zag-staging/bin/zag-linux-x86_64
cp /tmp/zag-staging/arm/bin/zag   /tmp/zag-staging/bin/zag-linux-arm64
chmod +x  /tmp/zag-staging/bin/zag-linux-{x86_64,arm64}

# Step 5 — package
./scripts/package.sh "${VERSION}" --bin-dir /tmp/zag-staging/bin

# Step 6 — smoke-test (un-comment / adapt for arm64 verification)
# mkdir -p /tmp/verify-x86
# tar -xzf dist/${VERSION}/zag-linux-x86_64.tar.gz -C /tmp/verify-x86
# /tmp/verify-x86/zag version && rm -rf /tmp/verify-x86

# Step 7 — tag
git tag -a "${TAG}" -m "Zag ${TAG}"
git push origin "${TAG}"

# Step 8 — publish
gh release create "${TAG}" \
    --title "Zag ${TAG}" \
    --generate-notes \
    dist/${VERSION}/zag-linux-x86_64.tar.gz \
    dist/${VERSION}/zag-linux-arm64.tar.gz \
    dist/${VERSION}/checksums.txt
```

---

## Cross-reference

- `build.zig.zon` — canonical `.version = "..."` line (Step 2 edits this)
- `scripts/build.sh` — local-host build with canonical `<os>-<arch>` naming
- `scripts/package.sh` — archives binaries + writes `checksums.txt` into `dist/<version>/`
- `scripts/install.sh`, `zag-install.sh`, `scripts/install.ps1` — user-facing curl-pipe installers (consume these artifacts)
- `.github/workflows/release.yml` — CI release workflow (currently all 6 platforms)
- `docs/manual/31-building.md` § Distribution — the user-view of install
