# Zag Language Manual

Zag is a small, statically-typed systems programming language for games, databases, HTTP servers, and high-performance AI. It targets the Zig toolchain — the compiler emits Zig source and uses `zig` for native code generation and linking.

## Design Principles

- **Small core** — minimal keywords, orthogonal features
- **No hidden control flow** — no destructors, no implicit allocations, no hidden copies
- **Predictable performance** — no garbage collector, no surprise pauses
- **Safety by tools** — the core language is unsafe by default; safety checks are opt-in
- **Zero-cost async** — async/await compiles to state machines; no heap allocation per task
- **First-class SIMD** — vector types for AI kernels and game hot paths

## Hello World

```
fun main() {
    print("hello, world\n");
}
```

Save this as `main.zag` and run:

```
zag run
```

## Memory Philosophy

Zag has **no garbage collector**. Every allocation is explicit:

```
fun main() {
    let p = new i32(42);     # heap allocate
    defer free(p);            # freed when scope exits
    print("{*p}\n");
}
```

- Stack values (primitives, structs) are automatically managed
- Heap values (`new`) require explicit `free`
- `defer` runs cleanup when the scope exits
- Arena allocators enable bulk deallocation in O(1)

## Next Steps

- [Comments](02-comments.md)
- [Literals](03-literals.md)
- [Variables](04-variables.md)
- [Types](07-types.md)
- [Memory Model](19-memory.md)
