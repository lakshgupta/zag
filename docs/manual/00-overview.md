# Zag Language Manual

Zag is a small, statically-typed systems programming language for games, databases, HTTP servers, and high-performance AI. It targets the Zig toolchain — the compiler emits Zig source and uses `zig` for native code generation and linking.

## Installation

Zag ships as a pre-built binary on Linux, macOS, and Windows. A working Zig toolchain is the only prerequisite, since the compiler emits Zig source for native code generation and linking.

### Prerequisites

Install Zig 0.16+ from [ziglang.org/download](https://ziglang.org/download/) and verify it is on your `PATH`:

```
zig version
```

### Install a pre-built binary

All install URLs below source directly from this GitHub repo (the project domain isn't currently hosted — fetch the canonical installer from GitHub raw). The installer script itself downloads the release archive from `github.com/zag-lang/zag/releases/latest/download/...` at runtime, so a tagged release must exist on the [Releases page](https://github.com/zag-lang/zag/releases) for the install to succeed.

Linux or macOS (defaults to the `main` branch — bleeding edge):

```
curl -fsSL https://raw.githubusercontent.com/zag-lang/zag/main/zag-install.sh | bash
```

Windows (PowerShell):

```
powershell -c "irm https://raw.githubusercontent.com/zag-lang/zag/main/scripts/install.ps1 | iex"
```

The installer downloads the platform release into `~/.zag/bin/zag`, appends `export PATH="$PATH:$HOME/.zag/bin"` to your shell profile (`.bashrc`, `.zshrc`, `.profile`, or `~/.config/fish/config.fish`), and prints `Zag installed successfully!`. To pin a version, download first and pass `--version`:

```
curl -sSO https://raw.githubusercontent.com/zag-lang/zag/main/zag-install.sh
bash zag-install.sh --version v0.1.0
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

## Design Principles

- **Small core** — minimal keywords, orthogonal features
- **No hidden control flow** — no destructors, no implicit allocations, no hidden copies
- **Predictable performance** — no garbage collector, no surprise pauses
- **Safety by tools** — the core language is unsafe by default; safety checks are opt-in
- **Zero-cost async** — async/await compiles to state machines; no heap allocation per task
- **First-class SIMD** — vector types for AI kernels and game hot paths

## Memory Philosophy

Zag has **no garbage collector**. Every allocation is explicit:

```
fun main() {
    let p = new i32(42);     # heap allocate
    defer free(p);            # freed when scope exits
    print("{*p}\n");
}
```

- Stack values (`Type { fields }`, `Type.init(args)`) are automatically freed
- Heap values (`new T(value)`) require explicit `free`
- `defer` runs cleanup when the scope exits
- Arena allocators enable bulk deallocation in O(1)

## Next Steps

- [Hello World](01-hello-world.md) — Quickstart: run your first program
- [Comments](02-comments.md)
- [Literals](03-literals.md)
- [Variables](04-variables.md)
- [Types](07-types.md)
- [Memory Model](19-memory.md)
