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
dist/0.1.0/
  zag-linux-x86_64.tar.gz    zag-linux-arm64.tar.gz
  zag-darwin-x86_64.tar.gz   zag-darwin-arm64.tar.gz
  zag-windows-x86_64.zip     zag-windows-arm64.zip
  checksums.txt
```

Upload these to GitHub Releases for distribution.

### Installing from release archives

End users install Zag with a single command. The project domain isn't currently hosted — fetch the installer directly from this repo on GitHub raw:

```bash
curl -fsSL https://raw.githubusercontent.com/zag-lang/zag/main/zag-install.sh | bash
```

Or from a local archive:

```bash
# macOS / Linux / Windows (Git Bash)
./scripts/install.sh

# Windows (PowerShell)
.\dist\install.ps1
```

The installer:
- Detects OS and architecture
- Downloads the appropriate binary
- Installs to `~/.zag/bin`
- Adds Zag to your shell PATH

## CI/CD Workflow

A typical CI build-and-test pipeline (all commands run from the repository root):

```bash
# 1. Build in release mode and run tests
./examples/run_all.sh --clean --release --build

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
