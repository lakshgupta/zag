# Zag

A small, statically-typed systems programming language for games, databases, HTTP servers, and high-performance AI. Targets the Zig toolchain: the compiler emits Zig source and uses `zig` for native code generation and linking.

## Development Approach

Zag is being developed with **heavy use of AI tools**. The compiler source (`src/`), the example catalog (`examples/`), the language manual (`docs/manual/`), the test suite (`src/tests/`), and most architectural decisions are drafted by AI coding assistants (Claude, GPT, Gemini) under the maintainer's design review. AI is the primary drafting layer; humans own the design proposals, the language semantics, and the per-topic commit discipline that decides how a change splits across commits.

**To be explicit about scope**: the *use of AI* is in the *development process*, not in the compiler itself. Zag is a regular compiler — no in-compiler inference, no AI-driven codegen, no autonomous refactoring at compile time, no ML-based type elision. The compiler emits Zig source and uses `zig` for native codegen + linking exactly as documented in the Installation section. AI assists the humans who write the compiler, but produces no runtime behaviour that a human-authored compiler would not produce.

Every change still lands via the standard validation cycle (`zig build` + `zig build test` + `zag run` on the affected examples), so the authoring style — human or AI-assisted — is indistinguishable at the artefact level. The commit graph is the working evidence: feature commits, regression fixes, per-topic discipline, and the fixture/test splits that pin surface contracts are landed the same way regardless of whether the draft was first written by a human or by a model. Each commit body explains the per-topic discipline, the alternative paths considered, and the empirical validation that motivated the change.

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

The `zag-lang.org` website is not hosted yet — all install URLs below source directly from this GitHub repo. The installer script itself downloads the release archive from `github.com/zag-lang/zag/releases/latest/download/...` at runtime, so a tagged release must exist on the [Releases page](https://github.com/zag-lang/zag/releases) for the install to succeed.

Linux or macOS (defaults to the `main` branch — bleeding edge):

```
curl -fsSL https://raw.githubusercontent.com/zag-lang/zag/main/zag-install.sh | bash
```

Windows (PowerShell):

```
powershell -c "irm https://raw.githubusercontent.com/zag-lang/zag/main/scripts/install.ps1 | iex"
```

The canonical Linux / macOS installer lives at [`zag-install.sh`](zag-install.sh) at this repo's root; the canonical Windows PowerShell installer lives at [`scripts/install.ps1`](scripts/install.ps1). For tagged releases, pin a specific version via the GitHub raw URL (substitute the same `vX.Y.Z` tag for both occurrences below):

```
curl -fsSL https://raw.githubusercontent.com/zag-lang/zag/v0.1.0/zag-install.sh | bash -s -- --version v0.1.0
```

The two `v0.1.0` strings are intentionally the same: one names the script file on the GitHub raw filesystem at that tag, and one tells the script which release to download. Mismatched tags are rejected because the user-pinned version must exist as a GitHub Release tag for the trailing download URL to resolve.

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
