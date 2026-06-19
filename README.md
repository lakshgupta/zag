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
- **[Building from Source](docs/manual/31-building.md)** — build, test, and release
- **[Specification](docs/spec.md)** — formal language reference

## Building

Zag targets the Zig toolchain. You'll need Zig installed, then:

```bash
# Build and test examples
cd examples && ./run_all.sh --release --build

# Package for distribution
./scripts/package.sh dev
```

See [manual/31-building.md](docs/manual/31-building.md) for detailed build instructions.
