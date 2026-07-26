# Testing

## Test Functions

Mark tests with `@[test]`:

```
@[test]
fun add_works() {
    assert(add(1, 2) == 3);
}

@[test]
fun divide_by_zero() {
    let result = divide(10.0, 0.0);
    match result {
        Err(_) => {},    # expected
        _ => panic("should have failed"),
    }
}
```

Run with `zag test`.

## Assertions

```
assert(condition);                     # assert with no message
assert(condition, "description");      # assert with message
```

**Memory:** Assertions are stack-only. No allocation.

## Test Organization

```
src/
  main.zag
  lib.zag
test/
  lib_test.zag
  math_test.zag
```

Tests can be in separate files or alongside source.

## Benchmarks

Mark benchmarks with `@[bench]`:

```
import std.bench

@[bench]
fun bench_matrix_multiply() {
    let a = Matrix4x4.identity();
    let b = Matrix4x4.identity();
    let c = a * b;
}
```

Run with `zag bench`:

```
bench_matrix_multiply
  iterations:    1
  total time:    42.50 us
  avg time:      42.50 us
  bytes alloc:   0
  allocations:   0
```

**Memory:** Benchmarks track bytes allocated and allocation count. The runtime allocator maintains counters.

## Compile-Time Checks

```
zag check              # ownership + leak checks (default)
zag check --quick      # all -D flags (compile-time only)
zag check --runtime    # default + -fsanitize=undefined
zag check --strict     # all checks + all sanitizers
zag check --leaks      # leak-focused
zag check --races      # race-focused
```

## Safety Flags

| Flag | Detects |
|------|---------|
| `-Dbounds-check` | Out-of-bounds access |
| `-Dinit-check` | Uninitialized reads |
| `-Dleak-check` | Missing `free` |
| `-Downership-check` | Double-free, use-after-move |
| `-Dref-check` | Dangling references |
| `-Dasync-ref-check` | Invalid async captures |
| `-Dthread-safety` | Data races |

## CI Profile

```
# Pre-commit (fast):
zag check

# CI (thorough):
zag check --strict
zag test
```
