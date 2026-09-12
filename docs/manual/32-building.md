# Building and Releasing Zag

This guide covers building the Zag compiler from source, running tests, producing release builds, and packaging for distribution.

## Prerequisites

- **Zig** — Zag targets the Zig toolchain. Install a recent version of Zig from [ziglang.org](https://ziglang.org/download/).
- **Bash 4+** — the test harness and distribution scripts require bash.
- **tar / zip** — for packaging distribution archives.

## Quick Build

From the repository root:

```bash
zig build
```

The built binary lands in `zig-out/bin/zag-<os>-<arch>` (build.zig's `b.addExecutable` uses `b.fmt("zag-{s}-{s}", ...)` to emit a platform-suffixed name; `.exe` is auto-appended on Windows).

## Build Modes

### Debug (default)

```bash
zig build
```

No optimizations. Fast compile, slow runtime. Best for development.

### Release

```bash
zig build -Doptimize=ReleaseFast
```

Full optimizations. Slow compile, fast runtime. Use for benchmarks and production.

## Running the Test Harness

The `examples/run_all.sh` script builds the compiler and runs all example programs:

```bash
cd examples

# Run tests with existing binary
./run_all.sh

# Clean, build in release mode, then test
./run_all.sh --clean --release --build

# Compile-check only (don't run)
./run_all.sh --check

# Run only a specific category
./run_all.sh basics/

# Show compiler output per example
./run_all.sh --verbose
```

### Test harness flags

| Flag | Description |
|------|-------------|
| `--build` | Build the compiler from source before testing |
| `--clean` | Clean build artifacts before building |
| `--release` | Build in release mode (appends `-Doptimize=ReleaseFast`) |
| `--check` | Compile-check only (`zag check`), don't run |
| `--verbose` | Show per-file compiler output |

### Zig build-mode flags

`zag run` / `zag build` / `zag debug` accept three optimization flags (file
mode passes `-O<name>` to `zig build-exe`; project mode passes
`-Doptimize=<name>` through the generated `build.zig`):

| Flag | zig mode | Use for |
|------|----------|---------|
| `--release` | `ReleaseFast` | Max speed, safety checks off (legacy spelling) |
| `--release-safe` | `ReleaseSafe` | Optimized but safety checks (OOB, overflow, unwrap) stay on |
| `--release-small` | `ReleaseSmall` | Minimum binary size |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZAG_BIN` | auto-detected | Path to the zag binary |
| `ZAG_BUILD_CMD` | `zig build` | Command to build the compiler |
| `ZAG_CLEAN_CMD` | `zig build clean` | Command to clean build artifacts |
| `ZAG_BUILD_OUT` | `zig-out/bin` | Directory containing built binaries |
| `ZAG_RELEASE_FLAGS` | `-Doptimize=ReleaseFast` | Extra flags for `--release` |

### The discarded-result audit

`zig build audit` fails the build when a `lib/std` source line throws away the
result of a close/sync or transfer call (`close`, `sync`, the
`write`/`write_full`/`write_at`/`write_block`/`append` family, the
`read`/`read_full`/`read_at`/`read_block` family, and the `pread`/`pwrite`
forms) without naming the decision. `zig build test` depends on it, so a plain
`zig build test` runs it too.

A discard is *named* by putting the phrase `deliberate discard` in a comment on
the same line:

```zag
let r: Result(usize, Errno) = read_full(fd, buf[0..buf.len]);
_ = close(fd); # deliberate discard: read-only fd, no buffered write to report
```

The compiler's unused-value rule cannot catch this class of bug — `_ =` is how
a hole gets re-opened silently — so the audit's rule is not "never discard" but
"say why". The audit covers `lib/std/**/*.zag` and `src/**/*.zig` (the compiler's own Zig,
where `waitpid`/`dup2`/`lseek`/`ftruncate` are in the set too). See
[Errors from the Standard Library](19-error-handling.md) for the full callee set
and what is intentionally out of scope — `futex_wait`, `execve`, and
`mkdirat`-style calls whose non-error returns are expected.

### Per-example `@[test]` blocks

`run_all.sh` runs each example's `main`. The `@[test]` blocks in the same file
are a second, independent gate: `run_all.sh` deliberately skips `*/tests/*`
directories and does not execute test blocks, and `zig build test` is the
in-process Zig unit graph which never reads a `.zag` file. Run them with:

```bash
# The automatic path: `zag test` over every test-bearing fixture in the
# catalog, one subprocess each, exit code propagating. The fixture list
# is discovered at config time, not hand-maintained.
zig build example_tests

# A single fixture, by hand (file mode — the test sits in the same file
# as the fixture's `main`).
zag test examples/error-handling/posix_tier.zag
zag test examples/error-handling/io_robustness.zag

# Project mode — suites under a `tests/` directory import sibling `src`
# modules, which file mode cannot resolve. Run from the project root:
cd examples/project_layout && zag test
```

`zig build example_tests` is wired into CI's test job. It discovers fixtures
by two signals — a line opening with `@[test]`, and a `fun test_*` declaration
(the project-mode convention below) — and then picks each one's mode by
whether an ancestor directory holds a `zag.toml`. A fixture inside a project
runs as one `zag test` from the project root, because its imports resolve
against that root; a standalone fixture runs as `zag test <file>` from the
repository root.

The step passes the host `zig` to each spawned `zag test` as `ZAG_ZIG_PATH`
(the build script locates it on `$PATH`), because `zag`'s own toolchain
resolution does not search `$PATH` — without the pin a CI zig that arrives
only via `PATH` is invisible to it. On a host with no `/proc/self/environ` the
probe bows out and leaves the diagnostic; set `ZAG_ZIG_PATH=$(which zig)` if
the step reports it cannot find a toolchain. One caveat: a non-default
`--prefix` moves the binary off `zig-out/bin`, which project mode needs to
locate `lib/std` relative to the executable — set `ZAG_HOME=<repo>` in that
case.

An `@[test]` function takes no arguments and returns `void`; a failed `assert`
is reported with the test's name and makes the command exit non-zero. The
error-handling fixtures carry most of their coverage here, because the rows
assert *specific* values (`Err(ErrnoKind.Eisdir)`, a wrong-sized block buffer,
an operation on a closed handle) that a demo `main` can only print.

Two conventions those fixtures follow, so they stay runnable everywhere:

- **Skip on a missing fixture.** A row that needs a host feature skips itself
  rather than failing when the feature is absent: the `/dev/full` `ENOSPC` row
  still passes where the device node does not exist, and the permission rows
  degrade to a no-op under root, which bypasses the mode bits. This mirrors
  the SKIP-on-missing-prerequisite convention the integration runners use.
- **Never panic in a fixture.** Every injected failure is handled as a value;
  a fixture that panics is a failure of the fixture, not of the compiler.

## Distribution Packaging

The `scripts/` directory contains tooling for building, packaging, and distributing Zag binaries:

```bash
cd dist

# Package built binaries into release archives
./package.sh 0.1.0

# With custom binary source directory
./package.sh 0.1.0 --bin-dir ../zig-out/bin
```

This produces platform-specific archives in `dist/<version>/`:

```
dist/0.2.0/
  zag-0.2.0-linux-x86_64.tar.gz    zag-0.2.0-linux-arm64.tar.gz
  zag-0.2.0-darwin-x86_64.tar.gz   zag-0.2.0-darwin-arm64.tar.gz
  zag-0.2.0-windows-x86_64.zip     zag-0.2.0-windows-arm64.zip
  checksums.txt
  zag-install.sh             # standalone bash installer (release asset)
  install.ps1                # standalone PowerShell installer (release asset)
```

Each archive is **self-contained**: alongside the `zag` binary and a
`VERSION` file it carries the installers (`zag-install.sh` and
`install.ps1`). The same two scripts are also uploaded as standalone
release assets next to the archives.

Upload these files to GitHub Releases for distribution.

### Installing from release archives

End users install Zag with a single command. The project domain isn't currently hosted — fetch the installer directly from this repo on GitHub raw:

```bash
curl -fsSL https://raw.githubusercontent.com/lakshgupta/zag/main/zag-install.sh | bash
```

Or download a **specific release** (the release tag):

```bash
# downloads v0.1.0's archive for your OS and installs to ~/.zag/bin
curl -fsSL https://raw.githubusercontent.com/lakshgupta/zag/main/zag-install.sh | bash -s -- --version v0.1.0
```

Every release also ships `zag-install.sh` / `install.ps1` as release
assets, so you can download the script for a version and run it locally:

```bash
# macOS / Linux / Windows (Git Bash / WSL)
./zag-install.sh                  # latest
./zag-install.sh --version v0.1.0 # a specific version

# Windows (PowerShell)
.\install.ps1
```

Finally, the archive is self-contained: extract it and run the bundled
installer — it installs the binary already inside (no download) and
defaults to that release's version:

```bash
tar -xzf zag-0.2.0-linux-x86_64.tar.gz   # → zag, VERSION, zag-install.sh, install.ps1
./zag-install.sh
```

The installer:
- Detects OS and architecture
- Downloads the appropriate binary (or installs the bundled one from an archive)
- Installs to `~/.zag/bin`
- Adds Zag to your shell PATH

## CI/CD Workflow

A typical CI build-and-test pipeline (all commands run from the repository root):

```bash
# 1. Build in release mode and run tests
./examples/run_all.sh --clean --release --build
zig build example_tests

# 2. Package for distribution (using tag version, e.g. v0.1.0)
./scripts/package.sh "0.1.0"

# 3. Upload dist/<version>/* to GitHub Releases
```

## Safety Checks

Zag pushes safety to optional tools. Compile-time checks are opt-in via `-D<check>` flags:

```bash
# Individual compile-time checks
zag build -Downership-check    # double-free, use-after-move
zag build -Dleak-check         # missing free calls
zag build -Dbounds-check       # out-of-bounds access
zag build -Dref-check          # dangling references
zag build -Dinit-check         # uninitialized reads
zag build -Dthread-safety      # data races
zag build -Dasync-ref-check    # invalid async captures
```

Runtime sanitizers (`-fsanitize=<kind>`):

```bash
zag build -fsanitize=memory    # use-after-free, uninitialized reads
zag build -fsanitize=thread    # data races
zag build -fsanitize=leak      # memory leaks
zag build -fsanitize=undefined # integer overflow, misaligned access
```
