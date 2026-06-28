# Zag

A small, statically-typed systems programming language for games, databases, HTTP servers, and high-performance AI. Targets the Zig toolchain: the compiler emits Zig source and uses `zig` for native code generation and linking.

## Design Principles

- **Small core** — minimal keywords, orthogonal features
- **No hidden control flow** — no destructors, no implicit allocations, no hidden copies
- **Predictable performance** — no garbage collector, no surprise pauses
- **Safety by tools** — the core language is unsafe by default; safety checks are opt-in
- **Zero-cost async** — async/await compiles to state machines; no heap allocation per task
- **First-class SIMD** — vector types for AI kernels and game hot paths

## Hello World

```zag
fun main() {
    print("hello, world\n");
}
```

Save as `main.zag` and run:

```bash
zag run
```

## Project Structure

| Directory | Description |
|-----------|-------------|
| [`manual/`](docs/manual/) | Language manual — comprehensive guide covering all features |
| [`spec.md`](docs/spec.md) | Language specification — formal reference for implementors |
| [`examples/`](examples/) | Runnable example programs, categorized by feature area |
| [`dist/`](dist/) | Release packages, versioned (e.g. `dist/0.1.0/`) |
| [`scripts/`](scripts/) | Build, install, and packaging tooling |

## Quick Links

- **[Language Manual](docs/manual/index.md)** — start here to learn Zag
- **[Examples](examples/)** — runnable `.zag` files with a test harness
- **[Installation](docs/manual/00-overview.md#installation)** — install pre-built binary or build from source
- **[Specification](docs/spec.md)** — formal language reference

## Installation

Zag ships as a pre-built binary on Linux, macOS, and Windows. A working Zig toolchain is the only prerequisite, since the compiler emits Zig source for native code generation and linking.

### Prerequisites

Install Zig 0.16+ from [ziglang.org/download](https://ziglang.org/download/) and verify it is on your `PATH`:

```
zig version
```

### Install a pre-built binary

Linux or macOS:

```
curl -sS https://zag-lang.org/install.sh | bash
```

Windows (PowerShell):

```
powershell -c "irm https://zag-lang.org/install.ps1 | iex"
```

The installer downloads the platform release into `~/.zag/bin/zag`, appends `export PATH="$PATH:$HOME/.zag/bin"` to your shell profile (`.bashrc`, `.zshrc`, `.profile`, or `~/.config/fish/config.fish`), and prints `Zag installed successfully!`. To pin a version, download first and pass `--version`:

```
curl -sSO https://zag-lang.org/install.sh
bash install.sh --version 0.1.0
```

Or with a custom install location:

```
ZAG_HOME=$HOME/local bash install.sh
```

### Build from source

If no release binary is available for your platform, clone the repository and use the build scripts:

```
git clone https://github.com/zag-lang/zag
cd zag
./scripts/build.sh --release     # debug build by default; --release sets -Doptimize=ReleaseFast
./scripts/install-local.sh       # copy zig-out/bin/zag-<os>-<arch> to ~/.zag/bin and configure PATH
```

`build.sh` runs `zig build`, copies the result into `zig-out/bin/zag-<os>-<arch>`, and `install-local.sh` configures your `PATH` the same way `install.sh` does.

### Verify

Restart your shell (or `source ~/.bashrc`), then:

```
zag version
```

You should see the installed version string.

### Uninstall

```
bash install.sh --uninstall             # Linux / macOS
./scripts/install.ps1 -Uninstall        # Windows (PowerShell)
./scripts/install-local.sh --uninstall  # Build-from-source install
```

Removes `~/.zag` and the `# Zag Language` / `# zag` PATH entry from your shell profile.
