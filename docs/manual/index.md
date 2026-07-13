# Zag Language Manual

A comprehensive guide to the Zag programming language.

## Getting Started

- [Overview](00-overview.md) — Language philosophy and hello world
- [Hello World](01-hello-world.md) — Quickstart: run your first program
- [Comments](02-comments.md) — Line comments and doc comments

## Literals and Types

- [Literals](03-literals.md) — Integer, float, string, array, and SIMD literals
- [Variables](04-variables.md) — let, var, const, and scope
- [Types](07-types.md) — Type system overview, copy vs move
- [Primitives](08-primitives.md) — Integer, float, bool, char, void

## Compound Types

- [Arrays and Slices](10-arrays-and-slices.md) — Fixed-size arrays, slicing, SIMD conversion
- [Strings](11-strings.md) — String vs str, interpolation, memory
- [Structs](12-structs.md) — Structs, embedding, methods, derive
- [Enums](13-enums.md) — Bare enumerations
- [Unions](14-unions.md) — Tagged unions, Option, Result
- [Tuples](15-tuples.md) — Tuple types and destructuring

## Operations

- [Operators](05-operators.md) — Arithmetic, comparison, assignment
- [Operator Overloading](30-operator-overloading.md) — Custom operators via dunder methods

## Control Flow

- [Control Flow](06-control-flow.md) — if, while, for, match, defer, return
- [Pattern Matching](27-pattern-matching.md) — match, destructuring, guards

## Functions and Generics

- [Functions](15-functions.md) — Declaration, parameters, closures
- [Methods and impl](28-methods.md) — Methods, self parameter, impl blocks
- [Method Overloading](29-method-overloading.md) — Compile-time overload resolution
- [Generics](16-generics.md) — Generic functions and types, trait bounds
- [Traits](17-traits.md) — Dynamic dispatch, trait implementation

## Error Handling

- [Error Handling](18-error-handling.md) — Result, Option, ?, catch, Context
- [Defer and Errdefer](20-defer.md) — Cleanup patterns

## Memory

- [Memory Model](19-memory.md) — Allocation, ownership, safety tooling
- [Pointers](09-pointers.md) — Pointer types, dereferencing, slicing

## Concurrency

- [Concurrency](21-concurrency.md) — Threads, async/await, channels, scopes

## Language Features

- [Modules and Imports](22-modules.md) — File-based modules, visibility, mod.toml
- [Compile-Time Execution](26-compile-time.md) — const blocks, builtins
- [SIMD and Assembly](23-simd.md) — Vector types, inline asm, intrinsics
- [FFI and Interop](24-ffi.md) — C ABI, repr(C), extern fun

## Tooling

- [Testing](25-testing.md) — Tests, benchmarks, safety checks
- [Building and Releasing](31-building.md) — Build from source, release builds, distribution
- [Project Layout & Dependencies](34-project-layout.md) — Directory structure, `zag install / add / vendor` workflow, build/test/bench CLI
- [`zag.toml` Schema](35-zag-toml-schema.md) — Formal reference for the package manifest

## Memory Allocation Quick Reference

| Type | Storage | Allocation | Deallocation |
|------|---------|------------|--------------|
| Primitives (`i32`, `f64`, etc.) | Stack | Automatic | Automatic |
| Structs | Stack | Automatic | Automatic |
| Arrays `[N]T` | Stack | Automatic | Automatic |
| Tuples | Stack | Automatic | Automatic |
| Slices `[]T` | Stack (ptr+len) | Automatic | Automatic |
| `String` | Heap | `new String(...)` | `free(s)` |
| `new T(...)` | Heap | `new T(...)` | `free(p)` |
| Arena | Heap | `new(arena, T(...))` | `arena.free_all()` |
| `const` | Static | Compile-time | Never |
| Module-level `var` | Static | Compile-time | Never |

## Safety Checks

| Check | Flag | What it catches |
|-------|------|-----------------|
| Ownership | `-Downership-check` | Double-free, use-after-move |
| Leak | `-Dleak-check` | Missing `free` calls |
| Bounds | `-Dbounds-check` | Out-of-bounds access |
| Ref | `-Dref-check` | Dangling references |
| Init | `-Dinit-check` | Uninitialized reads |
| Thread | `-Dthread-safety` | Data races |
| Async ref | `-Dasync-ref-check` | Invalid async captures |
