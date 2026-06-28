# Language Specification

Name: **Zag**

A small, statically-typed systems programming language for games, databases, HTTP servers, and high-performance AI. Targets the Zig toolchain: the compiler emits Zig source and uses `zig` for native code generation and linking.

---

## 1. Design Principles

- **Small core** — minimal keywords, orthogonal features
- **No hidden control flow** — no destructors, no implicit allocations, no hidden copies
- **Explicit returns** — `return` keyword required, no implicit return of trailing expression
- **Predictable performance** — no garbage collector, no surprise pauses
- **Safety by tools, not by language complexity** — the core language is unsafe by default; safety checks are opt-in flags and separate tools
- **Zig backend** — the compiler emits Zig source and relies on the Zig toolchain; no custom native backend or linker in v1
- **Trait-based polymorphism** — explicit traits for dynamic dispatch; struct embedding for data and method reuse
- **Method overloading** — compile-time only resolution (Julia-style); no runtime dispatch cost
- **No borrow checker in core** — pointers work like Zig; optional static analyzers can be added later
- **Zero-alloc async** — async/await compiles to state machines; no heap allocation per task
- **First-class SIMD + inline asm** — vector types and inline assembly for AI kernels and game hot paths
- **Composition over inheritance** — ECS and data-oriented design via struct composition, not class hierarchies

---

## 2. Lexical Structure

### 2.1 Keywords

```
as        async     await     break     catch     const     continue
defer     else      enum      errdefer  extern    false     for
fun       if        impl      import    in        let       match
null      pub       return    select    struct    trait     true
type      undefined union     unsafe    var       void      while
```

`Self` is a contextual identifier referring to the current type in an `impl` block. `self` is the conventional name for a method's first parameter.

### 2.2 Literals

| Kind | Examples |
|---|---|
| Integer | `0`, `42`, `0xFF`, `0o77`, `0b1010` |
| Float | `3.14`, `1.0e10` |
| Boolean | `true`, `false` |
| Character | `'a'`, `'\n'`, `'\x00'` |
| String | `"hello"`, `"line\nbreak"`, `r"raw"` |
| Byte string | `b"bytes"` — `[]u8` literal |
| Null | `null` — value of any nullable pointer type (`?*T`, `?*const T`, `?*raw T`) |
| Undefined | `undefined` — explicitly uninitialized memory; reading is UB |

**String interpolation:** String literals support `{expr}` interpolation. The expression is converted to a string using the `to_string()` method. Format specifiers follow the syntax `{expr:spec}` where `spec` is a Python/Rust-style format mini-language: `:.N` for N decimal places, `:>N` for right-align in N chars, `:<N` for left-align, `:b`/`:x`/`:o` for binary/hex/octal integer formatting, and `:?` for debug representation. Use `{{` and `}}` for literal braces:

```
"error: {err}"
"value = {x + y}, status = {status}"
"pi = {PI:.5}"
"{{ curly braces }"   # "{ curly braces }"
```

**Interpolation context determines the type:**
- Inside `print` / `eprint`: interpolation writes directly to the `fmt.Writer` — **zero-alloc**. The expression is formatted via `Display` into the writer buffer.
- As a standalone expression: produces a heap-allocated `String`. `"error: {err}"` is a `String`.

**Important:** String interpolation always produces `[]const u8` when the result is assigned to a `[]const u8` binding, but the intermediate representation depends on context. Inside `print`/`eprint`, no intermediate `String` is created. As a standalone expression, a `String` is heap-allocated. If you need zero-alloc formatting outside `print`, use `Display` directly with a pre-allocated buffer or `String.with_writer`.

```
print("error: {err}\n");           # zero-alloc — writes to stdout
let msg: []u8 = "error: {err}";
let greeting: []u8 = "hello {name}";

# Zero-alloc alternative outside print:
var buf = String.with_capacity(64);
buf.write("error: {err}");         # format into pre-allocated buffer
```

**Zero-alloc formatting:** For hot paths (game loops, AI kernels, HTTP response serialization) where `to_string()` would allocate, types can implement the `Display` trait for stack-based output (see §4.5). `Display` is the canonical formatting interface; it is zero-alloc by design. The compiler's string interpolation and `print`/`eprint` use `Display` directly, and the compiler synthesizes a `Display` implementation for primitive types.

### 2.3 Operators

```
+  -  *  /  %  &  |  ^  ~  <<  >>
== != <  >  <=  >=  &&  ||  !
=  += -= *=  /=  %=  &=  |=  ^=  <<=  >>=
.  ,  (  )  [  ]  {  }  ..  ...
```

`..` is a half-open range `[a, b)` — `start` is `a`, `end` is `b`.
`...` is the array-fill operator inside array literals: `[N]T { value ... }`.
`->` is the return type arrow in function signatures: `fun add(a: i32, b: i32) -> i32`.

**Operator precedence** (highest to lowest):

| Priority | Operators | Associativity |
|----------|-----------|---------------|
| 1 | `!`, `-` (unary) | Right |
| 2 | `as` | Left |
| 3 | `*`, `/`, `%` | Left |
| 4 | `+`, `-` | Left |
| 5 | `<<`, `>>` | Left |
| 6 | `&` (bitwise AND) | Left |
| 7 | `^` (bitwise XOR) | Left |
| 8 | `\|` (bitwise OR) | Left |
| 9 | `==`, `!=`, `<`, `>`, `<=`, `>=` | None |
| 10 | `&&` (logical AND) | Left |
| 11 | `\|\|` (logical OR) | Left |
| 12 | `..`, `...` | None |
| 13 | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=` | Right |

`&&` and `||` **short-circuit** — the right-hand side is only evaluated if the left-hand side does not determine the result.

`_` is the **throwaway pattern** — matches any value and discards it. Used in `match` arms, variable bindings (`let _ = ...`), and function parameters.

### 2.4 Comments

```
# line comment
## doc comment (attached to the next declaration)
```

### 2.5 Attributes

```
#[...]  applied to the next declaration
```

Standard attributes: `#[inline]`, `#[inline(always)]`, `#[inline(never)]`, `#[cold]`, `#[packed]`, `#[align(N)]`, `#[allow_leak]`, `#[blocking]`, `#[test]`, `#[bench]`, `#[no_mangle]`, `#[export]`, `#[export("name")]`, `#[unused]`, `#[must_use]`, `#[deprecated]`, `#[deprecated("message")]`, `#[derive(Clone)]`, `#[derive(Default)]`, `#[derive(Zero)]`, `#[clone(skip)]`.

`#[clone(skip)]` is a field-level attribute used inside a struct that opts into `#[derive(Clone)]`. It marks a field that the synthesized `Clone` impl should **not** copy — the cloned value receives whatever the field's `default()` produces (or `undefined` if the field is non-`Default` and the user has accepted the cost). Use it for owning `*T` fields that need a hand-written `Clone` (deep copy via `T.clone()` or `Rc.clone` / `Arc.clone`) or for fields that should be left in a known-empty state until the user initializes them. The attribute is only valid on struct fields in a `#[derive(Clone)]` block; using it elsewhere is a compile error.

```
struct Graph {
    nodes: List<Node>,
    #[clone(skip)]               # deep-cloned by hand in the impl below
    adjacency: *Adjacency,
}

impl Graph {
    pub fun clone(self: *const Graph) -> Graph {
        var out = Graph { nodes: self.nodes.clone(), adjacency: undefined };
        out.adjacency = self.adjacency.deep_clone();
        return out;
    }
}
```

In the example, `#[derive(Clone)]` would otherwise attempt a shallow copy of `adjacency` and produce a use-after-free. `#[clone(skip)]` excludes the field from the synthesized `Clone`, and the hand-written `impl Graph { pub fun clone(...) }` provides the deep-copy semantics.

**`#[derive(...)]` in v1.** Only `Clone`, `Default`, and `Zero` are derivable in v1. The compiler synthesizes the trait `impl` for the annotated `struct` or `enum` automatically:

| Attribute | Synthesizes | Notes |
|---|---|---|
| `#[derive(Clone)]` | `impl T { fun clone(self: *const T) -> T }` that copies every field | Recursive: each field's type must also be `Clone`. The compiler synthesizes `Clone` for primitives, `[]T`, `String`, `*T` (shallow copy), `Option<T>` (when `T: Clone`), `Result<T,E>` (when `T: Clone`). User `Clone` impls win over the generated one. |
| `#[derive(Default)]` | `impl T { fun default() -> T }` that zero-initializes the struct or returns the first enum variant | Recursive: each field's type must be `Default`. Primitive types are `Default` with the value `0`, `false`, `'\0'`, or `{}` (for `void`). |
| `#[derive(Zero)]` | Marker impl `impl T { fun zero() -> T }` that writes all-zero bytes via `std.mem.zero` | The struct must be `Zero`-compatible — every field type must be `Zero` (no embedded slices, `String`, `Option<T>` where `T` is not `Zero`, or other non-`Zero` types). This is a **fast path** for bulk initialization in tight loops (game frames, AI kernels, page-table zeroing). The compiler emits a single `memset` call. |

Derive is a compile-time expansion — the synthesized methods are visible in the type system (overload resolution, `Clone`-as-trait dispatch) and can be specialized by the user with a hand-written `impl`. Other `#[derive(...)]` variants (`Debug`, `JSON`, `Eq`, `Hash`, `Ord`) are deferred to v2 (§19) along with the full macro framework.

**`Clone` and the no-hidden-allocation rule.** A generated `Clone` implementation may allocate when the struct contains a `String` or another non-`Copy` heap-allocating type. This is the **single exception** in v1 to the no-hidden-allocation principle (§1): the allocation is visible at the syntactic level (the user wrote `#[derive(Clone)]` and the field type is `String`), so it is treated as an explicit declaration rather than a hidden cost. To make the allocation site unambiguous at the call site, the `Clone` trait also provides `clone_into(self, dest: *T)` for the case where the caller already has a destination buffer.

**`Clone` does not deep-copy owning pointers.** If a struct field has type `*T` (owning single-item pointer, §3.2), the synthesized `clone()` produces a **shallow** copy of the pointer value — both the source and the clone believe they own the pointee, and freeing one leaves the other dangling. The `#[derive(Clone)]` attribute is therefore a **compile error** when the struct contains a `*T` field that is not annotated `#[clone(skip)]`. Use a hand-written `Clone` impl that performs a deep copy (`self.data.clone()`) or uses `Rc<T>` / `Arc<T>` for shared ownership. Non-owning pointer forms (`*const T`, `*raw T`, slices, nullable pointers) are `Copy` and clone by value.

```
struct Particle {
    position: [3]f32,
    velocity: [3]f32,
    age:      u32,
}

impl Particle {
    ## Integrate one step.
    pub fun step(self: *Particle, dt: f32) {
        self.position[0] += self.velocity[0] * dt;
        self.position[1] += self.velocity[1] * dt;
        self.position[2] += self.velocity[2] * dt;
        self.age += 1;
    }
}

var particles: [1024]Particle = [1024]Particle { Particle.zero() ... };
#                     ^^^^^^^^^^ generated by #[derive(Zero)]; emits a single memset
```

`#[export]` uses the Zag function name as the linker symbol. `#[export("name")]` uses the given symbol name.

`#[packed]` removes padding between struct fields (layout = C `__attribute__((packed))`).
`#[align(N)]` sets a minimum byte alignment for a struct, field, or global variable.
`#[allow_leak]` suppresses the leak-check error for `task.detach()` and `scope.detach(task)` on the annotated function.
`#[blocking]` marks a function as blocking; the compiler warns if called from async context without `task.spawn_blocking`.
`#[must_use]` emits a warning when the return value of the annotated function or method is discarded. For functions whose return type is `Result<T, E>` or `Option<T>`, this attribute is **implied** — the warning can be silenced by explicitly discarding with `let _ = ...`.
`#[deprecated]` and `#[deprecated("message")]` emit a warning at every call site; the message form includes the explanation in the diagnostic.

---

## 3. Types

### 3.1 Primitive Types

| Type | Size | Notes |
|---|---|---|
| `i8` `i16` `i32` `i64` | 1/2/4/8 B | two's complement |
| `u8` `u16` `u32` `u64` | 1/2/4/8 B | |
| `isize` | ptr B | signed pointer-width integer |
| `usize` | ptr B | unsigned pointer-width integer |
| `i128` | 16 B | signed 128-bit integer |
| `u128` | 16 B | unsigned 128-bit integer |
| `f16` | 2 B | IEEE 754 half (storage + compute) |
| `f32` | 4 B | IEEE 754 single |
| `f64` | 8 B | IEEE 754 double |
| `bf16` | 2 B | Brain Float 16 (AI compute) |
| `bool` | 1 B | |
| `char` | 4 B | Unicode scalar |

`void` (also spelled `()`, the unit tuple — see §3.3) is a zero-byte unit type. Functions without `-> T` return `void` implicitly; `-> void` may also be written explicitly. `void` can be used as a value: `let _: void = {};`.

**`void` semantics:**
- `void` has exactly one value: `{}` (an empty block expression)
- `return;` is equivalent to `return {};` in a `void`-returning function
- `void` is `Copy` and has zero size — it occupies no stack space
- Generic instantiations like `List<void>` are valid but degenerate (zero-sized elements)
- A `match` arm that produces `void` need not bind a value; the arm body runs for its side effects

SIMD vector types (`f16xN`, `f32xN`, `bf16xN`, `i8xN`, etc.) are built-in types with compiler support for lowering to target ISA. See §4.8.

**Hardware arithmetic for `f16` and `bf16`.** Scalar `f16` and `bf16` arithmetic is **library-only** in v1 — the compiler does not require the target to expose scalar half-precision FMA, and the standard x86-64 / aarch64 ABIs do not pass or return half-precision scalars in hardware registers. Use the SIMD vector types (`f16x8`, `bf16x8`, etc.; §4.8) for hardware-accelerated FMA: the compiler lowers these to the target's native vector instructions (AVX-512 FP16 on recent x86, NEON-FP16 on aarch64, V-extension F16 on RISC-V). The intrinsics in `std.arch` provide portable access to the half<->single conversion instructions (`vcvt`, `_mm256_cvtph_ps`, etc.). AI workloads should always prefer SIMD vector types over scalar `bf16` for performance.

**Worked example — `bf16` SIMD multiply:** The narrow/widen forms in §3.7 (`[N]T as TXN`, `TXN as [N]T`) make `bf16x8` a drop-in for hot inner loops:

```zag
# Multiply two 8-f32 arrays in hardware bf16, return widened f32 array
fun mul_bf16(a: [8]f32, b: [8]f32) -> [8]f32 {
    let a_bf: bf16x8 = a as bf16x8;        # f32 array ? bf16 SIMD
    let b_bf: bf16x8 = b as bf16x8;
    let prod: bf16x8 = a_bf * b_bf;        # hardware BF16 FMA
    return prod as [8]f32;                 # widen back to f32 array
}
```

The element-wise multiply lowers to the target's native BF16 FMA: AVX-512 BF16 (`vfmadd231bf16` / `_mm256_dpbf16_ps`), aarch64 NEON (`bfdot`), RISC-V V (`vfwma`). For ML-style f32 accumulation, cast the product to `f32x8` and add to an `f32x8` accumulator — the compiler folds the FMA at the `bf16` level where the target supports it.

### 3.2 Pointer Types

| Type | Meaning |
|---|---|
| `*T` | Single-item pointer, mutable |
| `*const T` | Single-item pointer, immutable |
| `?*T` | Nullable single-item pointer, mutable; `null` is the null value; `Copy` |
| `?*const T` | Nullable single-item pointer, immutable; `null` is the null value; `Copy` |
| `?*raw T` | Nullable raw pointer; `null` is the null value; `Copy` |
| `[]T` | Slice, mutable |
| `[]const T` | Slice, immutable |
| `*raw T` | C-style raw pointer; no ownership, no alignment guarantee, no null safety; use only inside `unsafe` |

Pointers are not borrow-checked in the core language. The programmer ensures they remain valid. `*T` may be owning or non-owning; ownership is enforced by optional tools, not by syntax. `*const T`, `*raw T`, `[]T`, `[]const T`, and all nullable pointer forms (`?*T`, `?*const T`, `?*raw T`) are non-owning views and are `Copy`. Only the non-nullable mutable single-item pointer `*T` and the owning `String` are not `Copy`.

The unary `&` operator takes the address of a value, producing `*T` or `*const T` depending on whether the value is mutable. The binary `&` operator is bitwise AND.

`null` initializes any nullable pointer. `undefined` leaves memory uninitialized; reading it is undefined behavior unless overwritten first.

Thread-local storage and volatile pointers are provided by the stdlib (`std.thread.thread_local`, `std.arch.volatile`).

### 3.3 Compound Types

**Arrays** — fixed size, contiguous, value type
```
[10]i32
[3]f64
```

Array literal: `[N]T { value ... }` fills all `N` slots with `value`.
```
[3]i32 { 0 ... }   # [0, 0, 0]
```

Element-wise initialization uses a list: `[3]i32 { 1, 2, 3 }`.

**Slicing** produces a view into an existing array without copying:

```
let arr: [10]i32 = ...;
let slice: []i32 = arr[2..7];    # elements at indices 2, 3, 4, 5, 6
let view: []const i32 = arr[..];  # full array view
```

**Slice layout:** `[]T` is `{ ptr: *T, len: usize }`. `[]const T` is `{ ptr: *const T, len: usize }`. Built-in compound types (`String`, slices, arrays) expose their layout fields directly; user-defined structs do not.

**Tuples**
```
(i32, f64)
```

Tuples may have named fields (compile-time only — names vanish at the ABI level):

```
let point = (x: 10, y: 20);
print(point.x);     # named access
print(point.0);     # positional access (same value)
```

A `(min: i32, max: i32)` and an `(i32, i32)` are identical in memory and interchangeable.

**String** — a mutable, growable, heap-allocated UTF-8 string provided by `std.string` (not a compiler-builtin type). Layout `{ ptr: *u8, len: usize, cap: usize }` — the compiler knows the layout for interop, but `String` is a library type.

```
import std.string

let s: String = new String("hello");
let view: []const u8 = s.as_str();   # borrow as []const u8
```

String literals produce `[]const u8`. Use `new String(literal)` to heap-allocate an owned copy:

```
let greeting: []const u8 = "hello";
let owned = new String("hello");          # String (heap-allocated)
```

Indexing a string literal yields `u8` (byte), not a Unicode codepoint; use `std.unicode` for codepoint iteration.

`String` exposes `len` and `cap` as read-only fields and provides these stdlib methods: `push(self, c: char)`, `push_str(self, s: []const u8)`, `with_capacity(self, cap: usize) -> String` (creates an empty `String` with reserved capacity — the canonical way to build a `String` whose final length is roughly known up front), `reserve(self, extra: usize)`, `clear(self)`, `as_str(self) -> []const u8` (borrows as `[]const u8`), `as_writer(self) -> *fmt.Writer` (returns a pointer to a `fmt.Writer` view that appends bytes to the `String`; the writer is valid until the next non-`const` method call on the `String` and is the standard way to format into a `String` via `Display` without an intermediate buffer), `with_writer(self, f: fun(*fmt.Writer) -> void)` (scoped writer — calls `f` with a writer bound to the closure scope; the writer cannot escape the closure, enforced by `-Dref-check`).

**`as_writer` lifetime contract.** The returned `*fmt.Writer` is invalidated by any non-`const` method call on the source `String` (`push`, `push_str`, `reserve`, `clear`, a reentrant `as_writer`, or any `Display` call that re-formats into the same `String`) — the writer holds an internal pointer into the `String`'s buffer, and a reallocation or mutation leaves the pointer dangling. Using a writer after it has been invalidated is **undefined behavior** (read of freed memory, or a write to a freed `cap` region). The compiler does not enforce this in the type system — Zag has no borrow checker (§5.3.1) — so the discipline is on the caller. **Preferred alternative:** use `with_writer` which enforces the lifetime via closure scope and `-Dref-check`:

```zag
# SAFE — with_writer enforces lifetime via closure
s.with_writer(|w| {
    w.write("value: ");
    w.write(x);
});

# UNSAFE — as_writer requires manual lifetime discipline
let w = s.as_writer();
w.write("value: ");
w.write(x);
# s.push('!');  — would invalidate w, causing UB
```

```
fun build_greeting(name: str) -> String {
    var s: String = String.with_capacity(64);
    let w: *fmt.Writer = s.as_writer();
    Display.write("hello, ", w);
    Display.write(name, w);
    Display.write("!\n", w);
    return s;          # w is out of scope here; safe to return s
}
```

**`with_writer` — scoped, checked alternative.** `with_writer` takes a closure and passes a writer that is guaranteed not to escape the closure scope. The `-Dref-check` compile-time check (enabled by default in `zag check`) verifies the writer does not escape:

```
fun build_greeting(name: str) -> String {
    var s: String = String.with_capacity(64);
    s.with_writer(|w| {
        Display.write("hello, ", w);
        Display.write(name, w);
        Display.write("!\n", w);
    });
    return s;          # writer cannot escape; checked at compile time
}
```

Use `with_writer` for all new code; `as_writer` remains for interop and unusual patterns where the closure-based API doesn't fit.

**Structs** — value types with optional struct embedding (data + method reuse)
```
struct Vec3 {
    x: f64,
    y: f64,
    z: f64,
}

struct Button {
    Widget,            # embedded struct — Button has x, y fields and Widget's methods
    label: String,
}
```

A struct may embed at most one other struct by naming it as a field. The embedded struct's fields are promoted to the parent — they can be accessed directly without qualification. The embedded struct's methods are also promoted and participate in overload resolution. Struct embedding replaces inheritance: there are no virtual methods, no subtyping, and no upcasting. Polymorphism is provided by traits (§4.7).

**Copy semantics:** An aggregate type (struct, array, tuple, or enum) is `Copy` iff all its fields/elements/variants are `Copy`. Copy types duplicate on assignment; non-Copy types transfer ownership (move). `*T` and `String` are **not** `Copy` — they are moved on assignment. `*const T`, `*raw T`, `[]T`, `[]const T`, `?*T`, `?*const T`, `?*raw T`, `char`, and `void` are `Copy`.

**Struct update (spread)** creates a shallow copy with selected fields replaced:

```
let base = Vec3 { x: 1.0, y: 2.0, z: 3.0 };
let modified = Vec3 { ...base, z: 10.0 };   # { x: 1.0, y: 2.0, z: 10.0 }
```

**Field visibility:** Struct fields are **private by default**. Access from outside the module requires getter/setter methods. There is no `pub` on fields — this keeps structs encapsulated and makes OOP boundaries explicit. Because all fields are private, struct literals (`Button { x: 0, y: 0, ... }`) can only be constructed **within the same module**. External construction requires a constructor method (a `pub` function that returns the struct).

**Enums** — bare enumerations; variants are PascalCase. `Color`, `Direction`, and `Error` are typical cases. Variants carry no payload — for any variant that holds data, or for a type with a mix of bare and payload variants, use `union` (§3.3 Unions). The v1 compiler currently accepts the older `enum X { Variant(T) }` syntax as a payload-bearing tagged union; v2 splits this surface so bare enumerations stay under `enum` and the payload-bearing forms migrate to `union`.
```
enum Color {
    Red,
    Green,
    Blue,
}

enum Direction {
    North,
    South,
    East,
    West,
}
```

**Unions** — tagged unions / sum types. Variants may carry payloads, be bare, or a mix of both. Constructor syntax follows the variant name: `Variant()` for a bare variant, `Variant(arg1, arg2, …)` for a payload variant. Pattern matching destructures the payload per variant. Variants are PascalCase.
```
union Option<T> {
    Some(T),
    None,
}

union Result<T, E> {
    Ok(T),
    Err(E),
}

union Shape {
    Circle(f64),
    Rect(f64, f64),
    Empty,
}
```

**Error type** — the canonical error type is an `enum` defined in the stdlib (§11.1). Its variants are all bare, so it is written with `enum`, not `union`. `Error` has variants `NotFound`, `Permission`, `Io`, `Parse`, `InvalidInput`, `Unavailable`, and `Other`. The compiler enforces exhaustiveness in `catch |err|` blocks that match on `err` directly. `Error` is **zero-alloc** — no heap-allocated message field. For custom error types that carry data, use `union MyError { NotFound, Timeout, Custom(str) }` — see below.

**Error context** — for cases needing context (HTTP handlers, database queries), use `std.error.Context`, a separate type that wraps an `Error` with an optional message. It is only allocated when explicitly created:

```zag
# std.error
struct Context {
    msg: Option<String>,      # None = no context added
    source: Option<*Error>,   # pointer to original error (no ownership)
}

trait ErrorExt {
    fun context(self: *Error, msg: String) -> Context;
    fun context_str(self: *Error, msg: str) -> Context;
}

# Usage
fun read_config(path: str) -> Result<Config, Context> {
    let data = fs.read(path)?
        .context_str("failed to read config file")?;  # returns Context, ? propagates
    parse(data)?
        .context("failed to parse config")?
}

# Pattern matching on underlying Error still works:
catch |ctx: Context| {
    match ctx.source.? {
        Error.NotFound => ...
        Error.Io => ...
    }
    if let Option.Some(msg) = ctx.msg {
        eprint("context: {msg}");
    }
}
```

`Result<T, Context>` works with `?` because `Context` wraps `Error`. The `catch |ctx: Context|` form binds the full context.

Defining a custom error type — use `union` because one of the variants carries a payload:
```zag
union MyError {
    NotFound,
    Timeout,
    Custom(str),
}
```

Custom error types work with `Result<T, MyError>` and `catch |err| { match err { ... } }` identically to the built-in `Error`. They can also be wrapped in `Context` via the same `ErrorExt` trait (implemented for any error enum).

**Byte reinterpretation** — use `unsafe transmute<T, U>(val: T) -> U` for type-punning. `transmute` reinterprets the bytes of a value as a different type. The source and target types must have the same size. (Renamed from "Unions" so the section title isn't confused with the new `union` keyword (§3.3 Unions) for tagged-union types.)

```
unsafe {
    let int: i32 = 42;
    let bytes: [4]u8 = transmute<i32, [4]u8>(int);
}
```

### 3.4 Type Aliases

```
type str = []const u8;
```

`str` is lowercase to follow the Rust/Go convention for borrowed string views and to keep the heap-allocated `String` and the borrowed `str` view visually distinct (one owns memory, the other does not). `type` declarations create **true aliases**, not distinct nominal types — `str` and `[]const u8` are the same type to the type checker, and either spelling is accepted wherever the other is expected. Redeclaring `type str` in the same module is a compile error. This is the one exception to the PascalCase type-name rule; the rule exists to keep `String` and `str` distinct at a glance.

### 3.5 Compile-Time Constants

`const` declares a value that is evaluated at compile time.

```
const PI: f64 = 3.141592653589793;
const MASK: u32 = 0xFF;
```

`const` is also used for compile-time value parameters in generics (§4.1) and compile-time-only functions (§8.3).

### 3.6 Module-Level Variables

Module-level `var` declares global mutable state with static storage duration:

```
var global_counter: i32 = 0;
var config: Config = ...;
```

Module-level `let` is not allowed — use `const` for immutable globals.

### 3.7 Type Conversions

The `as` keyword converts between compatible types:

| Expression | Conversion |
|---|---|
| `i32 as f64` | Integer to wider float (widening) |
| `f64 as i32` | Float to integer (truncates fractional part) |
| `i32 as u32` | Between same-size integer signs (reinterpret bits) |
| `i32 as i64` | Integer to wider integer (sign-extends) |
| `i64 as i32` | Integer to narrower integer (truncates) |
| `usize as i32` | Between different-width integers (truncates or extends) |
| `*T as *raw U` | Safe pointer to raw pointer |
| `*raw T as usize` | Pointer to integer (in `unsafe`) |
| `usize as *raw T` | Integer to pointer (in `unsafe`) |
| `*T as usize` | Pointer to integer (in `unsafe`) |
| `[N]T as TXN` | Array to SIMD vector — `N` must equal the lane count; lane `i` receives `arr[i]` (natural order) |
| `[]T as TXN` | Slice to SIMD vector — `slice.len` must equal the lane count and `slice.ptr` must be aligned for `T`; otherwise the `as` is a **compile error** (use `slice[..N]` with a length check to fail safely) |
| `TXN as [N]T` | SIMD vector to array — `N` must equal the lane count; lane `i` produces `arr[i]` (natural order) |
| `TXN as TXM` | SIMD vector to a different lane count of the same element type — natural order; truncates the high lanes if `N > M` |
| `i8xN as i32xN` | Sub-byte integer vector to wider integer vector of the same lane count — sign-extends each lane (`u8xN as u32xN` zero-extends). Hardware-accelerated on every supported target |
| `i32xN as i8xN` | Wider integer vector to sub-byte integer vector of the same lane count — truncates each lane. For saturating narrow (clamp to the destination type's range), use the explicit `std.simd.sat_narrow` function |
| `f16` | `f32` | Widening — implicit (register move or `vcvtph2ps`) |
| `bf16` | `f32` | Widening — implicit (shift mantissa into place) |
| `f32` | `f16` | Narrowing — explicit `as` (truncates, hardware `vcvtss2ph` when available) |
| `f32` | `bf16` | Narrowing — explicit `as` (truncates upper 16 bits of mantissa) |

**Partial loads are not allowed.** `as` between SIMD and arrays requires an exact lane count. To load a sub-vector, zero-pad the array first — e.g. `let padded: [4]f32 = [4]f32 { arr[0], arr[1], arr[2], 0.0 }; let v = padded as f32x4;`. **Mask vectors are not a distinct type** — the result of comparison operators (`a > b`) is the integer vector type with bit values 0 / -1 (matching the target ISA mask convention). Use `select(mask, a, b)` for per-lane selection (§4.8).

Assigning a narrower type to a wider type (`i32` ? `i64`, `f32` ? `f64`) is implicit. All other conversions require the `as` keyword. Pointer-to-integer and integer-to-pointer conversions require an `unsafe` block.

### 3.8 Destructuring

`let` bindings support destructuring tuples, structs, arrays, and enums:

```
let (x, y) = point;
let Vec3 { x, y, z } = v;
let [a, b, c] = arr;
```

The `_` pattern discards values:

```
let (_, y, _) = v;
```

**Rest binding** collects remaining tuple elements:

```
let (first, ...rest) = (1, 2, 3, 4);
# first = 1, rest = (2, 3, 4)
```

Destructuring in a plain `let` requires an **exhaustive pattern** — the compiler must know it always matches. For optional patterns, use `if let` or `match`.

---

## 4. Type System

### 4.1 Generics

Generic functions and types use angle brackets. **Trait bounds** constrain type parameters to types that implement specific traits (structural — no explicit `impl` needed for compiler-known traits). No boxing, no hidden vtables.

```
fun max<T: Ordered>(a: T, b: T) -> T {
    if a > b {
        return a;
    }
    return b;
}

let m = max<i32>(3, 5);
```

**Structural trait bounds.** The following compiler-known traits are automatically satisfied when a type defines the corresponding methods — no explicit `impl Trait for Type` required:

| Trait | Required methods | Auto-implemented when |
|-------|------------------|----------------------|
| `Clone` | `fun clone(self: *const Self) -> Self` | `#[derive(Clone)]` or manual `impl` |
| `Default` | `fun default() -> Self` | `#[derive(Default)]` or manual `impl` |
| `Zero` | `fun zero() -> Self` | `#[derive(Zero)]` (all fields `Zero`) |
| `Ordered` | `__lt__`, `__le__`, `__gt__`, `__ge__` | All four operator overloads defined |
| `Display` | `fun write(self: *const Self, w: *fmt.Writer) -> Result<(), fmt.Error>` | Manual `impl` |
| `Iterator<T>` | `fun next(self: *Self) -> Option<T>` | Manual `impl` |
| `AsyncStream<T>` | `fun poll_next(self: *Self) -> Option<T>` | Manual `impl` |

Multiple bounds use `+`:

```
fun sort<T: Ordered + Clone>(slice: []T) { ... }
fun print_all<T: Display>(items: []T) { ... }
```

Generic types:

```
struct List<T> {
    data: *T,
    len: usize,
    cap: usize,
}

let nums: List<i32> = ...;
```

Const-value parameters use `const`:

```
fun fill<T, const N: usize>(val: T) -> [N]T {
    var out: [N]T = [N]T { val ... };
    return out;
}

let zeros = fill<i32, 10>(0);
```

**Trait bounds on associated types.** In v1, trait bounds only apply to type parameters (`T: Trait`). Associated types (e.g., `Iterator::Item`) cannot be constrained in bounds — this is deferred to v2 (§19).

### 4.2 Struct Embedding

A struct may embed at most one other struct by naming it as an unnamed field:

```
struct Widget { x: i32, y: i32 }

struct Button {
    Widget,            # embedded — Button directly has .x and .y
    label: String,
}
```

**Rules:**
- An embedded struct's fields are promoted to the parent — accessed directly without qualification
- An embedded struct's methods are promoted and participate in overload resolution (§4.4)
- Method override: a parent method that has the exact same signature as an embedded method takes priority
- Struct embedding replaces inheritance: there are no virtual methods, no subtyping, and no implicit upcasting
- Polymorphism is provided by traits (§4.7)

### 4.3 Methods

Methods are declared in `impl` blocks.

```
impl Vec3 {
    pub fun length(self: *const Vec3) -> f64 {
        return sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
}
```

Method call syntax: `v.length()` desugars to `Vec3.length(&v)`.

Generic impl blocks work with any type parameter:

```
impl<T> List<T> {
    pub fun push(self: *List<T>, value: T) { ... }
    pub fun pop(self: *List<T>) -> Option<T> { ... }
}
```

A method can take `self` by value, by immutable pointer, or by mutable pointer:

```
impl Widget {
    pub fun area(self: *const Widget) -> i32 { ... }      # immutable
    pub fun move(self: *Widget, dx: i32, dy: i32) { ... } # mutable
    pub fun consume(self: Widget) { ... }                 # by value
}
```

**Trait method prefix:** A method declaration inside an `impl Type { ... }` block can implement a trait method by prefixing the method name with the trait: `fun Trait.method(self: *T, ...)`. The trait name is the namespace; the method name is the trait's method. The compiler validates that for every trait mentioned in the impl block, all of the trait's **required** methods (those without a body in the trait definition) are present — a missing required method is a compile error pointing at the impl block. Default methods (those with a body) may be omitted from the impl block; the trait's default is used.

### 4.4 Method Overloading

Multiple methods in the same type may share a name if their parameter types differ. Resolution is purely compile-time with zero runtime cost.

```
impl Printer {
    pub fun print(self, x: i32) { ... }
    pub fun print(self, s: String) { ... }
    pub fun print(self, v: Vec3) { ... }
}
```

**Resolution order (inspired by Julia):**
1. Check the type's own methods for an exact signature match
2. Check promoted (embedded) methods for an exact signature match
3. If still ambiguous (multiple overloads match at the same distance), **compile error** — the caller must disambiguate with an explicit cast

**No implicit conversions in overload resolution.** Unlike Julia, Zag does not try implicit widening or narrowing in step 3. If `move(i32, i32)` and `move(f32, f32)` both exist, calling `move(1, 2)` unambiguously selects `move(i32, i32)`. Calling `move(1.0, 2.0)` unambiguously selects `move(f32, f32)`. If neither matches exactly, it is a compile error — the caller must cast explicitly: `move(1.0 as i32, 2.0 as i32)`.

```
impl Widget {
    pub fun move(self: *Widget, dx: i32, dy: i32) { ... }
}

impl Button {
    pub fun move(self: *Button, dx: f32, dy: f32) { ... }
    pub fun move(self: *Button, dx: i32, dy: i32, dz: i32) { ... }
}

button.move(1, 2);        # Widget.move — exact match on (i32, i32)
button.move(1.0, 2.0);    # Button.move — exact match on (f32, f32)
button.move(1, 2, 3);     # Button.move — exact match on (i32, i32, i32)
```

Overload resolution does not cross trait boundaries. A trait method and an overload with the same name on the same type are distinct — the trait method is only dispatched through the trait object.

**Overload scope:** All overloads of a type method live in the same `impl Type { ... }` block — `impl Printer { fun print(i32); fun print(String); ... }` is one namespace. Trait methods have a fixed signature per trait and cannot be overloaded: an `impl Type` block can have at most one `fun Trait.method(...)` declaration per trait method.

### 4.5 Operator Overloading

Operators desugar to specially named methods. Define these methods in an `impl` block.

| Operator | Method |
|---|---|
| `a + b` | `__add__(a, b)` |
| `a - b` | `__sub__(a, b)` |
| `a * b` | `__mul__(a, b)` |
| `a / b` | `__div__(a, b)` |
| `a % b` | `__mod__(a, b)` |
| `-a` | `__neg__(a)` |
| `a == b` | `__eq__(a, b)` |
| `a != b` | `__ne__(a, b)` |
| `a < b` | `__lt__(a, b)` |
| `a > b` | `__gt__(a, b)` |
| `a <= b` | `__le__(a, b)` |
| `a >= b` | `__ge__(a, b)` |
| `a[i]` | `__index__(a, i)` |
| `a[i] = v` | `__index_set__(a, i, v)` |

```
impl Vec3 {
    pub fun __add__(a: Vec3, b: Vec3) -> Vec3 {
        return Vec3 { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
    }
}

let c = a + b;   # desugars to Vec3.__add__(a, b)
```

**String conversion (`to_string`):** String interpolation (§2.2) and the `print` / `eprint` stdlib functions invoke a method named `to_string` on each interpolated value. The compiler synthesizes `to_string` for primitive types:

| Receiver | Result |
|---|---|
| `i8`..`i128`, `u8`..`u128`, `isize`, `usize` | base-10 decimal |
| `f16`, `f32`, `f64`, `bf16` | shortest round-trip decimal; `NaN` and `+/-inf` use Rust-style spellings |
| `bool` | `"true"` or `"false"` |
| `char` | the UTF-8 encoding of the scalar |
| `*T`, `*const T`, `*raw T` | the address in hexadecimal (`0x...`) |
| `?*T`, `?*const T`, `?*raw T` | `"null"` or the address of the underlying pointer |
| `String`, `[]const u8` | the string contents |
| `[N]T`, `[]T` | Rust-style: `[v0, v1, ..., vN-1]`. Empty arrays/slices render as `[]`. Nested arrays/slices use the same rules recursively. The element separator is `", "` (comma + single space); element values are themselves converted with their own `to_string()` |
| tuples `(T0, T1, ..., Tn)` | Parentheses with comma: `()` for the unit tuple, `(v0,)` for single-element, `(v0, v1, ...)` otherwise. Defined for completeness; tuples are not commonly interpolated |

For any other type the user must provide `pub fun to_string(self: *const T) -> String` (or `-> []const u8`); interpolation of a value whose type has no such method is a compile error. A user-defined `to_string` may accept an optional allocator as a second parameter (`pub fun to_string(self: *const T, alloc: *Allocator) -> String`); if omitted, the global allocator is used. The compiler-generated `to_string` for primitive types always uses the global allocator.

**`Display` trait — zero-alloc formatting (canonical interface):** `Display` is the canonical interface for converting a value to text. It is **zero-alloc by design** — implementations write into a caller-provided `*fmt.Writer` (a fixed buffer, a `*String` with reserved capacity, an I/O stream, or stdout/stderr).

```
trait Display {
    fun write(self: *const Self, writer: *fmt.Writer) -> Result<(), fmt.Error>;
}
```

`fmt.Writer` is a byte-sink struct backed by a fixed buffer, a `String`, or an I/O stream. Format specifiers (e.g. `{x:.2}`, `{x:>10}`) are forwarded to `write`. The `fmt` package lives in `std.fmt`. Primitive types (`i8`..`i128`, `u8`..`u128`, `isize`/`usize`, `f16`/`f32`/`f64`/`bf16`, `bool`, `char`, pointer forms, `String`, `[]const u8`, arrays, slices, tuples) have a synthesized `Display` implementation. The compiler emits a `Display` shim that delegates to the type's `Display` for the element type.

**`to_string` is defined in terms of `Display`.** The compiler synthesizes a default `to_string` for any type whose `Display` is available. Conceptually:

```
# What the compiler synthesizes for a type T that implements Display
fun T_to_string(self: *const T) -> String {
    var s: String = String.with_capacity(64);
    let writer: *fmt.Writer = s.as_writer();    # s acts as a fmt.Writer
    Display.write(self, writer);                 # zero-alloc write into s
    return s;
}
```

Calling `to_string()` allocates exactly one `String`. Hot paths call `Display.write(value, &writer)` directly into a stack buffer, a `*String` with reserved capacity, or an I/O stream — no allocation occurs. The string interpolation in §2.2 calls `Display` (and only `Display`); `to_string` is the convenience wrapper that the compiler synthesizes from `Display`. For user-defined types that do not implement `Display`, calling `to_string()` is a compile error. Primitive types always have `Display` (synthesized), so `to_string()` is always available for them.

Operator methods participate in overload resolution (§4.4).

### 4.6 Pattern Matching

`match` is an expression. Arms are `pattern => expr`, with optional `if guard`.

```
match value {
    Option.Some(x) => return x,
    Option.None    => return 0,
}

match cmd {
    Read(path) if path.len > 0 => open(path),
    Read(_)                    => panic("empty path"),
    Write(data)                => flush(data),
    Close                      => shutdown(),
}

match x {
    0      => "zero",
    1..9   => "digit",
    _      => "other",
}
```

Enum variants can be written unqualified (`Read(path)`) when the enum type is inferred from the matched expression. Use qualified names (`Option.Some(x)`) when the type is ambiguous or for clarity.

Range syntax is `a..b` (half-open `[a, b)`) everywhere.

### 4.7 Traits (Dynamic Dispatch)

Traits provide **dynamic dispatch** without requiring inheritance. They are for pluggable boundaries (HTTP handlers, database drivers, plugins) where you need flexibility over monomorphization.

```zag
trait Handler {
    fun handle(self: *Self, req: *Request) -> *Response;   # required
    fun name(self: *Self) -> str {                         # default
        return "handler";
    }
}

struct MyHandler { config: Config }

impl MyHandler {
    pub fun Handler.handle(self: *MyHandler, req: *Request) -> *Response {
        # implementation
    }
    # name() not provided — uses default
}

# Trait value = fat pointer (data + vtable)
fun process(h: Handler, req: *Request) {
    let resp = h.handle(req);  # indirect call via vtable
}
```

**Rules:**
- A trait declares method signatures. Methods without a body are **required**; methods with a body are **defaults** (used when the `impl` block does not provide them).
- `Self` inside a trait refers to the implementing type, just as it does in `impl` blocks.
- A type implements a trait by declaring its methods inside an `impl Type { ... }` block, prefixed with the trait name: `fun Trait.method(self: *T, ...)` for each method the trait requires.
- The compiler validates trait satisfaction: for each `impl Type` block and each trait that block mentions, every **required** method (no body) must be present. Missing required methods is a compile error pointing at the impl block. Default methods (with body) are optional — if omitted, the trait's default is used.
- Trait values are **fat pointers** (data pointer + vtable pointer).
- Calling a trait method is one indirect call (data + vtable lookup).
- A type can implement multiple traits by mentioning more than one trait in the same `impl Type` block (e.g., `fun TraitA.foo(...); fun TraitB.bar(...)`).
- Traits cannot have fields or associated types.
- Trait implementation is **explicit** — the `fun Trait.method` prefix makes the binding unambiguous.
- Type names and trait names share the same namespace; declaring both `struct X` and `trait X` in the same module is a compile error.

**Performance:** One indirect call (vtable lookup). Use in hot paths only if the indirection is measurable; prefer monomorphized generics for tight loops.

**Async trait methods:** Trait declarations are always synchronous — `trait Handler { fun handle(self: *Self) -> Output; }`. To provide an async impl, the `impl Type` block adds `async` to the `fun` keyword: `async fun Handler.handle(self: *MyType) -> Future<Output> { ... }`. The `async` keyword is on the **impl side only**; the trait signature has no `async`. The compiler **desugars** the impl return type: when a trait method is implemented with `async fun`, the compiler rewrites the return type to `Future<Output>` in the vtable. The caller through a trait value sees the original `Output` type — the `Future` wrapping is internal. Calling an async trait method through a trait value returns the underlying `Future<T>` and must be `await`ed at the call site. The vtable entry is a thin shim that constructs a concrete-type-monomorphized `Future<T>` (per §6.2 / §6.7); calling it incurs one indirect call plus one state-machine construction, with no per-call generic re-instantiation. `async fun` traits compose with `select`, `task.scope`, and `for await` without changes.

### 4.8 SIMD and Inline Assembly

**SIMD vector types** are first-class and map directly to target ISA registers. Syntax: `{elem}{width}x{lanes}` where `elem` ? {i, u, f, bf}, `width` ? {8, 16, 32, 64}, and `lanes` is a power-of-two that fits in the target vector register. Common types:

```
f32x4       f32x8       f64x2       f64x4
f16x8       bf16x8
i8x16       i16x8       i32x4       i64x2
u8x16       u16x8       u32x4       u64x2

**Packed sub-byte types (int4 / int8 GEMM / quantize–dequantize).** AI inference in 2026 runs predominantly on int4 and int8 dot products, often through the VNNI / SME / matrix-engine units on modern CPUs. To make Zag a first-class inference language, the SIMD type system extends `width` to include the sub-byte and packed forms:

| Type | Element | Element bits | Common lanes | Target ISA | Use case |
|---|---|---|---|---|---|
| `i4x16`  | signed 4-bit | 4  | 16 (64 b)  | SSE / NEON / SVE | int4 weight matmul, ternary networks |
| `u4x16`  | unsigned 4-bit | 4 | 16 (64 b)  | SSE / NEON / SVE | int4 weight matmul (unsigned) |
| `i4x32`  | signed 4-bit | 4  | 32 (128 b) | AVX2 / NEON / SVE | int4 batched matmul |
| `u4x32`  | unsigned 4-bit | 4 | 32 (128 b) | AVX2 / NEON / SVE | int4 batched matmul (unsigned) |
| `i8x16`  | signed 8-bit | 8  | 16 (128 b) | SSE / NEON / SVE | int8 inference, AVX2 VNNI (already in common-types list above) |
| `i8x32`  | signed 8-bit | 8  | 32 (256 b) | AVX2 / AVX-VNNI | int8 inference, AVX-512 VNNI |
| `i8x64`  | signed 8-bit | 8  | 64 (512 b) | AVX-512 / SVE | int8 inference, AVX-512 VNNI |
| `u8x32`  | unsigned 8-bit | 8 | 32 (256 b) | AVX2 / NEON | uint8 image / audio |
| `u8x64`  | unsigned 8-bit | 8 | 64 (512 b) | AVX-512 / SVE | uint8 image / audio |

The lane count is the **storage** count — the ISA treats the 256-bit register as 32 packed `i8` lanes, and Zag names the type accordingly. Conversion between sub-byte SIMD and arrays uses the `as` form, with the same exact-lane-count rule as the wider types:

```
# Load 32 int8 weights into a single AVX-512 register
let w: [32]i8 = ...;
let w_vec: i8x32 = w as i8x32;

# Per-lane mul, accumulate into i32
let a: i8x32 = ...;
let prod: i8x32 = a * w_vec;
let widened: i32x32 = prod as i32x32;       # sign-extend each lane (see §3.7)
let dot: i32 = widened.sum();               # horizontal reduce
```

Sub-byte types use the same element-wise operators as the wider SIMD types. **Comparison results on sub-byte SIMD widen to the next standard signed-int vector type** (e.g. `i4x16 == i4x16` → `i32x16` mask, `i8x32 > i8x32` → `i32x32` mask) — 0/-1 must be representable in every lane, so the 4-bit result is not usable as a mask. The widened mask is the input to `select(mask, a, b)`. The `as` form between a sub-byte SIMD type and an array requires the array length to equal the lane count, exactly as for `f32x8` ↔ `[8]f32`.

**`as` rules for sub-byte types.** Partial loads/stores are not allowed (same as the wider SIMD types, §3.7). To load a sub-vector, use a `mask` and `select`, or load into a same-width array first and `as` it into the vector. Sign extension on widen (`i8x32 as i32x32`) and truncation on narrow (`i32x32 as i8x32`) are hardware-accelerated on every supported target.

**Slices can be `as`-cast to SIMD.** When the source is `[]T` instead of `[N]T`, the compiler checks that the slice's `len` equals the lane count and that the pointer is properly aligned for `T`. Slice-to-SIMD is otherwise identical to array-to-SIMD and is a common way to feed SIMD kernels from dynamically-sized buffers (HTTP response bodies, mmap'd files, AI activation tensors).

**Worked example — int8 GEMM with AVX-512 VNNI.** The narrow/widen forms make int8 inference a drop-in for the hot inner loop. This is the smallest meaningful matmul: a 16-row × 16-column output tile, multiplied by 64-element K-dimension blocks, accumulated in `i32` (the standard int8 inference output dtype):

```zag
# Compute one 16x16 int8 output tile by int8 dot product
fun int8_gemm_16x16(
    a: [16][64]i8,         # activations  (16 rows, 64 cols)
    w: [64][16]i8,         # weights      (64 rows, 16 cols)
) -> [16][16]i32 {
    var c: [16][16]i32 = [16][16]i32 { [16]i32 { 0 ... } ... };

    for i in 0..16 {
        for j in 0..16 {
            # Dot product of a[i] and w[*][j], block by 32 lanes
            var acc: i32x32 = i32x32 { 0 ... };
            for k_block in 0..2 {
                let k = k_block * 32;

                # Load 32 packed i8 lanes from each input
                let a_vec: i8x32 = a[i][k..k+32] as i8x32;
                let w_vec: i8x32 = w[k..k+32][j] as i8x32;

                # Hardware int8 dot product (signed×unsigned byte -> i32).
                # AVX-512 VNNI: VPDPBUSD (4 partial sums / register)
                # aarch64 SVE/SME: usdot / sudot
                # RISC-V V: integer dot-product extension
                let prod: i32x32 = a_vec.dot(w_vec);

                # Accumulate into the i32 result
                acc = acc + prod;
            }
            c[i][j] = acc.sum();    # horizontal reduce
        }
    }
    return c;
}
```

The `i8x32.dot(i8x32)` form lowers to a single hardware dot-product instruction on every supported target (VNNI on x86, usdot/sudot on aarch64, integer dot on RISC-V V). The kernel is portable source — the hardware dispatch is automatic, like Zig's `@Vector` operations. The result `c` is a `[16][16]i32` matrix suitable for requantization, softmax, or storage.

**SIMD methods in v1.** The methods defined on SIMD vector types in v1 are: `sum()`, `max()`, `min()`, `dot(other) -> element_type` (the horizontal dot product; for sub-byte and small-int vectors, the per-lane products are first widened to `i32` to avoid overflow), and the element-wise operators from the `__op__` desugaring (§4.5). Comparisons return the matching integer vector type with 0 / -1 lanes (§3.7). `select(mask, a, b)` is a free function in `std.simd`, not a method.

**Single-instruction guarantee.** The following operations lower to a **single hardware instruction** on all supported targets that have the required ISA extension:

| Operation | x86-64 | aarch64 | RISC-V V |
|-----------|--------|---------|----------|
| Element-wise `+`, `-`, `*`, `/` | `addps`/`vaddps` etc. | `fadd`/`add` etc. | `vadd.vv` etc. |
| Comparisons (`==`, `!=`, `<`, `>`) | `cmpeqps`/`vcmpeqps` etc. | `cmeq`/`cmgt` etc. | `vmseq.vv` etc. |
| `select(mask, a, b)` | `blendvps`/`vpblendvb` | `bsl` | `vmerge.vv` |
| `dot()` for int8 (VNNI/sdot) | `vpdpbusd` | `usdot` | integer dot extension |

**Fallback for wide reductions.** Horizontal reductions (`sum`, `max`, `min`) on vectors wider than 128 bits may require multiple instructions on some targets (e.g., `f32x8.sum()` on x86-64 requires two `haddps` + one `addps`). The compiler emits the minimum number of instructions needed — it is forbidden from synthesizing loops or function calls. For `i8x32.dot(i8x32)`, the operation lowers to a single `vpdpbusd` / `usdot` instruction on targets with VNNI/SVE; on targets without the extension, the compiler synthesizes the equivalent sequence but never calls a library function.

**Sub-byte SIMD note:** Comparison results on sub-byte types widen to the next standard signed-int vector type (e.g., `i4x16 == i4x16` produces `i32x16`). The widening is a register-level operation (zero-extend or sign-extend), not a memory operation.
```

**Element-wise operators** work directly:

```
let a = f32x4 { 1.0, 2.0, 3.0, 4.0 };
let b = f32x4 { 5.0, 6.0, 7.0, 8.0 };
let c = a + b;         # element-wise
let mask = a > b;      # i32x4 mask
let d = select(mask, a, b);  # per-lane select
```

**Horizontal reductions**:

```
let sum = c.sum();     # f32
let max = c.max();     # f32
```

**Inline assembly** for platform-specific optimization:

```
asm {
    # x86-64 AVX2 FMA
    ("vfmadd231ps {dst}, {src}, {acc}"
     : {dst} = "=x"(out)
     : {src} = "x"(a), {acc} = "x"(b)
     :
    )
}
```

Constraints follow the target's asm dialect (AT&T for x86, ARM asm for aarch64). The compiler validates register classes and clobbers.

**Inline assembly constraint classes:**

| Constraint | Meaning |
|------------|---------|
| `"r"` | General-purpose register (GPR) |
| `"x"` | x87 / SSE / AVX register (x86) |
| `"=r"` | Output in GPR |
| `"+r"` | Read-write in GPR |
| `"m"` | Memory operand |
| `"i"` | Immediate integer constant |
| `"=m"` | Output memory |
| `"+m"` | Read-write memory |
| `:*"` | Clobber list — comma-separated register names |

**Operand syntax:** `{name}` in the asm template refers to an input/output operand. Examples:

```
asm {
    ("add {dst}, {dst}, {src}"
     : {dst} = "+r"(x)
     : {src} = "i"(42)
     :
    )
}
```

Inline assembly may not appear in `const` blocks. The compiler validates that operands fit the constraint class and that clobbered registers do not overlap with outputs.

**Compiler intrinsics** in `std.arch` provide portable access to ISA-specific operations without inline asm:

```
import std.arch.x86.avx2

let a = avx2._mm256_fmadd_ps(x, y, z);  # guaranteed FMA
```

---

### 4.9 Composition over Inheritance (ECS Pattern)

Struct embedding is for **is-a** relationships (UI widgets, base types). For **has-a** relationships (game entities, database rows, AI tensors), use **composition**:
```zag
# Components = plain data structs
struct Position { x: f32, y: f32 }
struct Velocity { dx: f32, dy: f32 }
struct Sprite { texture: *Texture, frame: u32 }
struct Health { current: i32, max: i32 }

# Entity = ID + component storage (in archetype tables)
struct Entity { id: u64 }

# Systems = functions operating on component arrays
fun physics_system(
    positions: []Position,
    velocities: []Velocity,
    dt: f32
) {
    for i in 0..positions.len {
        positions[i].x += velocities[i].dx * dt;
        positions[i].y += velocities[i].dy * dt;
    }
}

fun render_system(
    positions: []Position,
    sprites: []Sprite
) {
    for i in 0..positions.len {
        draw_sprite(sprites[i], positions[i]);
    }
}

# Query = filter archetypes, get component arrays
fun run_frame(world: *World, dt: f32) {
    let (pos, vel) = world.query<Position, Velocity>();
    physics_system(pos, vel, dt);

    let (pos2, spr) = world.query<Position, Sprite>();
    render_system(pos2, spr);
}
```

**Why this beats inheritance for games:**
- No vtable overhead in hot loops
- Cache-friendly: component arrays are contiguous
- Flexible: add/remove components at runtime
- Parallelizable: systems on disjoint components run concurrently
- Testable: systems are pure functions on data

---

## 5. Memory Model

### 5.1 Allocation

No garbage collector. Heap objects are created with `new` and freed with `free`.

```
let p = new i32(42);
defer free(p);

let b = new Button { x: 0, y: 0, label: "OK" };
free(b);
```

`new` allocates memory, initializes it, and returns an owning pointer `*T`. It accepts an optional first allocator argument; when omitted the global allocator is used:

```
let p = new i32(42);             # global allocator (default)
let q = new(arena, i32(42));     # arena allocator (explicit)
```

The `new(arena, T(value))` syntax is sugar for `arena.alloc<T>(value)` (§11.3). Both produce the same owning `*T`.

`free(ptr)` frees memory allocated by `new` via the global allocator. The pointer must come from `new` or `alloc` (global); freeing a stack address (`&local`) is undefined behavior.

For arena-allocated memory, use `arena.free(ptr)` to free a single allocation or `arena.free_all()` to reset the entire arena in O(1). The global `free` does **not** know about arena allocations — mixing `free` with `new(arena, ...)` is undefined behavior.

**Warning:** `arena.free_all()` does **not** recursively free inner allocations. If the arena holds types with their own heap-allocated buffers (e.g., `String`, `List<T>`, `Map<K,V>`), those inner buffers are **leaked** — only the arena's backing memory is reclaimed. Either call per-element cleanup before `free_all()`, or use arena only for flat types (`i32`, structs containing `*T` that point to the same arena, POD arrays).

```
let arena = Arena.new();
let p = new(arena, i32(42));    # arena allocation
arena.free(p);                   # ok: arena knows about p
# free(p);                      # WRONG: free uses global allocator
arena.free_all();                # reset entire arena in O(1)
```

The global allocator is `std.mem.global_allocator`.

**Allocator trait:**

```
trait Allocator {
    fun alloc(self: *Self, size: usize, alignment: usize) -> *raw u8;
    fun free(self: *Self, ptr: *raw u8, size: usize, alignment: usize);
    fun realloc(self: *Self, ptr: *raw u8, old_size: usize, new_size: usize, alignment: usize) -> *raw u8;
}
```

**Raw allocation** for FFI or custom allocators:

```
let buf: *raw u8 = alloc(1024);
unsafe {
    *buf = 0;
}
free(buf as *raw c_void);
```

`alloc(size: usize) -> *raw u8` and `free(ptr: *raw c_void)` are convenience wrappers around `std.mem.global_allocator`. They use the global allocator and 1-byte alignment.

**Resizing:** `realloc(ptr, new_size: usize) -> *raw u8` resizes an allocation from `alloc` or `realloc`. It may move the allocation; the old pointer is invalidated.

The runtime allocator maintains counters for benchmarking and diagnostics: total bytes allocated, total allocations, and current live bytes. These are exposed via `std.bench` and `std.mem`.

### 5.2 Ownership

A pointer returned by `new` has a single owner. Assignment moves ownership for non-`Copy` types. The source becomes uninitialized.

```
let s = new String("hello");
let t = s;          # ownership moved
# print(*s);        # error: s is moved
free(t);
```

`Copy` types duplicate on assignment. See §3.3 for the structural Copy rules.

A pointer returned by `new` or `alloc` is considered **owning**. Pointers and slices created with `&` or slicing are **non-owning views** and are `Copy`. Ownership analysis tools (§5.7) use this distinction: `free` of a non-owning view is a compile error under `-Downership-check`, and failing to `free` an owning pointer is a leak under `-Dleak-check`.

**Inter-procedural ownership:** `-Downership-check` is intraprocedural (§5.3.1). At a call site, a function returning `*T` is treated as returning a **potentially owning** pointer — the analysis conservatively allows `free` on it. This is correct for factory functions (`new_X`) but may suppress false positives for accessor functions (`get_X`). For full inter-procedural reasoning, use `-fsanitize=memory` at runtime.

### 5.3 Pointer Safety

`*T` and `*const T` may be owning or non-owning. They are not borrow-checked in the core language; the programmer ensures they remain valid.

```
fun print(s: *const String) { ... }
fun bump(s: *String) { ... }

var x: i32 = 10;
let r1 = &x;
let r2 = &x;
```

Non-null pointers cannot be null. Use `?*T` for nullable pointers.

### 5.3.1 What Zag Does Not Catch

Zag's "no hidden control flow" principle means the language is **explicitly permissive at the type level** and pushes safety to optional, opt-in tools. This section calls out the guarantees the language **does not** make, so the programmer knows which classes of bug require `-D<check>` or `-fsanitize=<kind>` to surface:

| Class of bug | What the core language does | Required to detect |
|---|---|---|
| Use-after-free of a `*T` or `*raw T` | Allowed in the type system; the pointer is treated as a valid `*T` until it is freed | `-fsanitize=memory` (recommended) |
| Double-free of an owning `*T` | Allowed in the type system; the freed pointer is still a valid `*T` | `-Downership-check` (compile time) or `-fsanitize=memory` (runtime) |
| Leak of an owning `*T` (never `free`d) | Allowed; the pointer is just data | `-Dleak-check` (compile time) or `-fsanitize=leak` (runtime) |
| Aliasing two `*T` (mutable) pointers to the same data | Allowed; the language does not track unique ownership of mutable pointers | Programmer discipline; no opt-in check in v1 |
| Dangling `&T` / `&mut T` to a stack frame that has returned | Allowed; `&local` produces a `*T` whose lifetime the compiler does not track | `-Dref-check` (intraprocedural) |
| Async capture pointing to caller stack memory | Allowed; `async fun` captures are not lifetime-checked against the caller | `-Dasync-ref-check` |
| Data race on a non-atomic shared `*T` | Allowed; the language does not track `Send` / `Sync`-like properties | `-Dthread-safety` (compile time) or `-fsanitize=thread` (runtime) |
| Integer overflow (signed wrap) | Allowed; wraps silently on the target | `-fsanitize=undefined` |
| Out-of-bounds array/slice access | Allowed; indexing is unchecked in `-O0`/`-O1`/`-O2`/`-O3` | `-Dbounds-check` (compile time, inserts guards) or `-fsanitize=undefined` |
| Misaligned load/store via `*raw T` cast | Allowed; UB on most targets | `-fsanitize=undefined` |
| Calling a blocking function from `async fun` | Allowed; blocks the event loop | `#[blocking]` attribute warning (compile time) |
| Panicking across FFI boundaries | Allowed; aborts the process | Discipline (use `catch` at the FFI boundary) |
| Iterator invalidation during `for` | Allowed; the language does not track container mutation | Discipline; use `copy` or collect before mutating |

**The default `zag check` profile (§14.1) runs `-Downership-check` and `-Dleak-check` automatically** — these are the two checks that compensate for the absence of a borrow checker / destructor, and they are cheap to run on every build. The remaining checks are opt-in and should be enabled in CI.

**`Downership-check` is the closest thing Zag has to a borrow checker.** It is an intraprocedural flow analysis that tracks owner transfer through `*T`: a moved-from `*T` cannot be read or freed, and a `free` of a non-owning view (one produced by `&` or slicing) is a compile error. The analysis is conservative — it does not prove aliasing is impossible, but it catches the common cases (use-after-move, double-free, `free(&local)`). For full inter-procedural reasoning, use `-fsanitize=memory` at runtime.

**Zag is not a memory-safe language out of the box.** It is a *predictable* language: the programmer knows which checks are off and can turn them on explicitly. Choosing `-O0 -Dall-checks -fsanitize=memory,thread,undefined,leak` is the closest setting to "Rust-level safety," and even then it does not catch aliasing.

### 5.4 Unsafe

`unsafe` blocks disable safety checks for raw pointer operations. All operations that require `unsafe` are listed here for reference:

| Operation | Where described |
|---|---|
| Dereferencing `*raw T` | §5.4, §5.5 |
| Pointer arithmetic on `*raw T` (`.add`, `.sub`, `.offset`) | §5.5 |
| Pointer-to-integer / integer-to-pointer casts (`as`) | §3.7 |
| `transmute<T, U>(val)` — reinterpret bytes between types | §3.3 |
| Calling C variadic functions (`extern fun ...`) | §5.6 |
| Raw pointer access to shared memory across tasks | §6.8 |
| Implementing lock-free data structures via `std.atomic` | §6.8 |
| FFI calls across threads for non-thread-safe C functions | §6.8 |
| `task.detach()` outside `task.scope` / `#[allow_leak]` | §6.2 |
| `scope.detach(task)` outside `#[allow_leak]` | §6.4.1 |

```
unsafe {
    let p: *raw i32 = ...;
    *p = 42;
}
```

`unsafe` can appear inside `async fun`, `const` blocks, and regular functions. An `unsafe` block is a scope — safety checks are restored at the closing `}`.

### 5.5 Raw Pointers

`*raw T` has no ownership and no checks. Dereference is `unsafe`. Use `?*raw T` or `Option<*raw T>` for nullable raw pointers.

```
let p: *raw i32 = alloc(4) as *raw i32;
unsafe {
    let val = *p;
    *p = 42;
}
```

Pointer arithmetic on `*raw T` requires `unsafe`:

```
unsafe {
    let q = p.add(5);     # p + 5 * sizeof(T)
    let r = p.sub(2);     # p - 2 * sizeof(T)
    let n = q.offset(p);  # (q - p) / sizeof(T)
}
```

### 5.6 FFI

```
#[export("printf")]
extern fun printf(fmt: *raw u8, ...) -> i32;

extern fun open(path: *raw u8, flags: i32) -> i32;
```

`extern fun` declares a function defined externally (C ABI). For v1, this is the only supported FFI ABI. `#[export("name")]` sets the exported linker symbol, either on a Zag function (making it callable from C) or on an `extern` declaration (specifying the library symbol name).

C variadic `...` in FFI declarations is distinct from Zag's variadic `T...` syntax (§8.1). C variadics accept any number of arguments of any type and are inherently unsafe — use only inside `unsafe` blocks or with a safe wrapper.

**Struct layout control for FFI.** The following attributes control struct layout for C interop, GPU buffers, and hardware registers. They map directly to Zig's layout system.

| Attribute | Meaning |
|-----------|---------|
| `#[repr(C)]` | C-compatible layout: fields in declaration order, platform padding/alignment rules |
| `#[repr(C, packed)]` | C-compatible packed: no padding between fields (like `__attribute__((packed))`) |
| `#[repr(C, opaque)]` | Opaque FFI type — size/alignment known, layout hidden; only usable via pointers |
| `#[offset(N)]` | Field attribute: explicit byte offset for the field (must be monotonically increasing) |
| `#[repr(C, int)]` | On enums: discriminant type (e.g., `i32`, `u8`); enum variants must have explicit values |

```
# Force C-compatible layout (no padding reordering)
#[repr(C)]
struct CCompatible {
    a: i32,
    b: f64,        # offset 8 (not 4) — matches C struct layout
    c: i16,
}

#[repr(C, packed)]  # packed = no padding
struct PackedC {
    a: i32,
    b: f64,        # offset 4 — unaligned, matches C __attribute__((packed))
    c: i16,
}

# Explicit field offsets (for GPU buffers, hardware registers)
#[repr(C)]
struct GpuVertex {
    #[offset(0)]  pos: [3]f32,
    #[offset(12)] normal: [3]f32,
    #[offset(24)] uv: [2]f32,
    #[offset(32)] color: [4]u8,
}

# Opaque FFI types — size/alignment known, layout hidden
#[repr(C, opaque)]
extern struct OpaqueHandle;

# C-compatible enums (discriminant = int)
#[repr(C, i32)]
enum CError {
    Ok = 0,
    NotFound = 1,
    Permission = 2,
}
```

`#[repr(C)]` structs can be passed by value across FFI boundaries. `#[repr(C, opaque)]` types can only be used behind pointers (`*OpaqueHandle`, `*const OpaqueHandle`).

### 5.7 Safety Tooling

Safety is provided by optional tools, not core language rules. Use `zag check` (§14.1) to run them all in one go.

**Compile-time checks** (opt-in via `-D<check>` flag):

| Check | Flag | What it detects |
|---|---|---|
| Bounds | `-Dbounds-check` | Out-of-bounds array/slice access — inserts a runtime guard before every index operation |
| Init | `-Dinit-check` | Use of uninitialized local variables — compile-time definite-assignment analysis |
| Leak | `-Dleak-check` | Paths where a `new` return value is never `free`d — intraprocedural flow analysis: every `new` call site must reach a `free` on all paths |
| Ownership | `-Downership-check` | Double-free, use-after-move — tracks `*T` owner transfer; flags use of moved-from pointers and duplicate `free` |
| Ref validity | `-Dref-check` | Dangling `&T` / `&mut T` references — intraprocedural analysis: a reference must not outlive the scope it points into |
| Async ref | `-Dasync-ref-check` | Captured pointer or reference inside an `async fun` does not outlive the returned `Future<T>` — validates that no capture points to caller stack memory |
| Thread safety | `-Dthread-safety` | Types crossing thread boundaries (`thread.spawn`, `channel<T>`) must contain no aliased mutable pointers or non-atomic reference counts — conservative static check |

**Runtime sanitizers** (opt-in via `-fsanitize=<kind>`):

| Sanitizer | Detects |
|---|---|
| `-fsanitize=leak` | Memory leaks — intercepts `alloc`/`free`, reports unreachable live allocations on exit |
| `-fsanitize=memory` | Use-after-free and uninitialized reads |
| `-fsanitize=thread` | Data races — catches concurrent unsynchronized writes from different threads |
| `-fsanitize=undefined` | Integer overflow, misaligned access, invalid casts, and other UB |

**Static analysis** (separate invocation, same as `-Downership-check`):

- `zag check --ownership` — runs ownership and double-free analysis over the entire package without running the program

---

## 6. Concurrency

### 6.1 Threads

```
import std.thread

let handle = thread.spawn {
    heavy_computation();
};
handle.join();
```

### 6.2 Async/Await

Async functions return a `Future<Output>` — a **tagged-union state machine struct** with zero heap allocation. The compiler lowers `async fun` to this state machine. The runtime uses Zig's `std.event.loop` for I/O readiness and `std.Thread.Pool` for task scheduling.

```
async fun handle_conn(c: Conn) -> Result<(), Error> {
    let req = await c.read_request()?;
    let resp = process(req);
    await c.write_response(resp)?;
    return Ok(());
}

async fun serve(addr: SocketAddr) -> Result<(), Error> {
    let listener = await TcpListener.bind(addr)?;
    while true {
        let conn = await listener.accept()?;
        let task = task.spawn(handle_conn(conn));  # returns Task<()>
        # task.detach() or await task.join() to wait
    }
}
```

- `async fun` returns `Future<Output>` (the state machine struct)
- `await` suspends the current task, yields to event loop
- `task.spawn(future)` ? `Task<T>` handle for joining/cancellation
- `task.spawn_blocking { ... }` runs blocking code in thread pool
- `task.detach()` — fire-and-forget; drops the join handle without waiting. Requires `#[allow_leak]` on the enclosing function or wrapping in `unsafe`; a plain call produces a compile error unless the task was spawned inside a `task.scope` (where the scope tracks it)
- `task.join()` — **async**; returns `Future<T>`. Must be `await`ed to get the result
- Dropping a `Task` cancels it (runs its `defer` cleanups) without waiting
- `?` propagates `Result.Err` and `Option.None` through async boundaries

**Cancellation:** Dropping a `Future` or `Task` cancels it (runs its `defer` cleanups). If a `defer` block panics during cancellation, the panic is caught and the remaining cleanups still run; the first panic is rethrown after all cleanups complete. Use `task.shield { ... }` to protect critical sections from cancellation. Use `await task.join()` to wait for a task's result; calling `task.join()` without `await` is a compile error.

### 6.3 Select

`select` waits on multiple futures simultaneously. It can be used as an **expression** (returns the branch result) or **statement** (early return with `=> return ...`):

```zag
# As expression - returns the branch result
let result = select {
    data = socket.read() => data,
    _ = timer.after(Duration.from_secs(5)) => Err("timeout"),
};

# As statement - early return
async fun handle_with_timeout(req: Request) -> Result<Response> {
    select {
        resp = handler.process(req) => return Ok(resp),
        _ = timer.after(Duration.from_secs(5)) => return Err("timeout"),
        _ = shutdown_signal.recv() => return Err("shutdown"),
    }
}
```

- Each branch: `pattern = future => expression`
- The first future to complete executes its branch; others are cancelled
- **Polling order:** Round-robin. Branches are polled in order; the branch polled first advances by one after each full round. This guarantees fairness — no branch is starved.
- Patterns can be `let x = ...`, `x = ...`, or `_ = ...`
- At least one branch is required
- If used as expression, all branches must return the same type

### 6.4 Channels

Bounded MPSC channels for thread/task communication:

```
let (tx, rx) = channel<i32>(1024);

thread.spawn {
    tx.send(42);           # blocks if full, returns Result<(), SendError>
    tx.try_send(42);       # non-blocking, returns Result<(), SendError>
};

let v = rx.recv();         # blocks until value or closed, returns Option<i32>
let v = rx.try_recv();     # non-blocking, returns Result<i32, RecvError>
```

- `send` / `recv` block until operation succeeds or channel closes; `send` returns `Result<(), SendError>`, `recv` returns `Option<T>`
- `try_send` / `try_recv` return immediately with `Result`
- `rx.recv()` returns `None` when all senders dropped
- `tx.close()` / `rx.close()` explicitly close the channel; subsequent `send` returns `SendError.Closed`, `recv` returns `None` after buffer drains
- `close()` is idempotent — closing an already-closed channel is a no-op
- In-flight `send` calls on close: if the buffer still has space, the item is enqueued; the sender receives `SendError.Closed` only if the channel is closed before the item can be written
- Channels work across threads and async tasks
- No heap allocation — ring buffer is inline in the channel struct
- **Warning:** `channel<T>(N)` stores `N` values inline. For large `T` (e.g., `channel<MyStruct>(1024)` where `MyStruct` is 1 KB), the channel is 1 MB. If allocated on the stack, this can cause stack overflow. Use `channel.heap<T>(cap)` for large types or large capacities — it allocates the ring buffer on the heap.
- **Channel size is a `const` integer literal.** `channel<T>(N)` requires `N` to be a compile-time constant so the ring buffer can be stored inline in the channel struct. The channel itself is a value type — it lives wherever the caller stores it (on the stack by default, on the heap if `new`'d). For runtime-sized channels use `channel.heap<T>(cap)` (in `std.sync`; see §11.3), which allocates the ring buffer on the heap — one allocation at construction, no per-send overhead

### 6.4.1 Structured Concurrency: `task.scope`

`task.scope` creates a structured concurrency scope where all spawned tasks are guaranteed to complete (or be cancelled) before the scope exits. The `{ scope => ... }` syntax is a **special form** (not a general closure): `scope` is a scope object bound by the runtime, providing `.spawn()`, `.join_all()`, and `.detach()` methods.

```zag
async fun handle_request(req: Request) -> Result<Response> {
    let result = task.scope { scope =>
        scope.spawn(fetch_user(req.user_id));
        scope.spawn(fetch_posts(req.user_id));
        scope.spawn(fetch_notifications(req.user_id));

        # All three run concurrently; scope waits for all
        let (user, posts, notifications) = await scope.join_all();
        return Ok(Response { user, posts, notifications });
    };
    return result;
}
```

**Return type:** `task.scope { ... }` evaluates to the final expression of the block. The block must return a value; if `scope.join_all()` is the last expression, the return type is the tuple of all child result types. If the block returns early (e.g. `return Err(...)`), the scope still awaits all children before the enclosing function returns.

**Behavior:**
- `scope.spawn(future)` returns a `Task<T>` handle for that child
- `scope.join_all()` awaits all children, returns tuple of results
- On error: the first child to return `Err` cancels all remaining children; `join_all` returns that error. Panics in children are caught and converted to errors
- On scope exit (normal return, `?` propagation, or panic), all remaining children are cancelled and joined — the scope never leaks tasks
- `scope.detach(task)` removes a task from scope management; the task leaks unless manually joined later. Produces a **compile error** unless the call is wrapped in `unsafe` or the enclosing function is annotated with `#[allow_leak]`
- A scope runs on the event loop; `await scope.join_all()` yields to the event loop while waiting, so nested awaits inside children do not block the parent
- `scope` cannot outlive the async function it is declared in (statically enforced)

### 6.4.2 Cancellation Tokens

`CancellationToken` provides explicit, composable cancellation across task boundaries:

```zag
async fun long_running(token: CancellationToken) {
    select {
        _ = token.cancelled() => return,
        result = do_work() => handle(result),
    }
}

async fun parent() {
    let token = CancellationToken.new();
    task.spawn(long_running(token.child()));  # child token linked to parent
    task.spawn(long_running(token.child()));

    await timer.after(Duration.from_secs(5));
    token.cancel();  # cancels all children
}
```

**API:**
- `CancellationToken.new()` — root token
- `token.child()` — derived token; cancelled when parent cancels
- `token.cancel()` — triggers cancellation for this token and all children
- `token.cancelled()` — future that completes when cancelled
- `token.is_cancelled()` — synchronous check
- `task.shield { ... }` — runs body with cancellation disabled (existing)

### 6.4.3 Async Iteration

`for await` desugars to repeated `.poll_next()` calls on any type implementing the `AsyncStream<T>` trait from `std.async.stream`. The compiler does not define `AsyncStream`, `yield`, or generators — streams are pure library code built on `Future<T>`.
The trait (see §11.3 for the full declaration):

```zag
trait AsyncStream<T> {
    fun poll_next(self: *Self) -> Option<T>;
}
```

`poll_next()` returns `Option.Some(item)` for the next element, or `Option.None` to signal end-of-stream. **Streams are non-fallible at the trait level** — error propagation happens inside the stream implementation (typically by capturing an error and returning `None`, or by embedding a `Result<T, E>` in the item type `T`). This keeps `for await` simple and matches Rust's `Stream` design.

```zag
for await line in stream {
    process(line);
}
```

Desugars to:

```zag
while let Option.Some(line) = stream.poll_next() {
    process(line);
}
```

`for await` is a statement, not an expression — it cannot be `?`'d. To exit early, use `break`; to propagate errors from the loop body, return them from the enclosing function.

All combinators (`map`, `filter`, `take`, `skip`, `chain`, `zip`, `buffered`, `timeout`, `collect`) and timer-produced streams (`timer.interval`) are provided by `std.async.stream` and `std.time`. Combinators are monomorphized at compile time; the underlying poll loop is the same shape for every stream.

### 6.4.4 Timers

Timers are provided by the stdlib in `std.time`. Common functions:

- `timer.after(dur)` — future that completes after a duration
- `timer.deadline(dur)` — future that completes at a deadline
- `timer.interval(dur)` — `AsyncStream<Instant>` yielding on each tick

Timers are backed by the event loop's built-in timer wheel (no heap allocation per timer). See `std.time` for the full API.

### 6.5 Atomics

Atomic types are distinct nominal types. Operations live in `std.atomic`.

```
struct AtomicI32 { _opaque: i32 }
struct AtomicI64 { _opaque: i64 }
struct AtomicUsize { _opaque: usize }
struct AtomicBool { _opaque: bool }
struct AtomicPtr<T> { _opaque: *T }
```

Memory orderings: `Relaxed`, `Acquire`, `Release`, `AcqRel`, `SeqCst`.

**Atomics are not `Copy`** — they have interior mutability. Atomics are `*const`-safe (shared reference is valid for reads). Atomic alignment: `AtomicI32` is 4-byte aligned, `AtomicI64` / `AtomicUsize` / `AtomicPtr` are 8-byte aligned on 64-bit targets.

**Operations (each maps to a single hardware instruction):**

| Method | Instruction | Description |
|--------|-------------|-------------|
| `load(order)` | `mov` (with fence) | Atomic read |
| `store(val, order)` | `mov` (with fence) | Atomic write |
| `swap(val, order)` | `lock xchg` | Atomic exchange, returns old value |
| `compare_exchange(expected, desired, success, failure)` | `lock cmpxchg` | CAS — returns `Result<old, old>` |
| `fetch_add(val, order)` | `lock xadd` | Atomic add, returns old value |
| `fetch_sub(val, order)` | `lock xadd` (negated) | Atomic subtract, returns old value |
| `fetch_and(val, order)` | `lock and` | Atomic bitwise AND, returns old value |
| `fetch_or(val, order)` | `lock or` | Atomic bitwise OR, returns old value |
| `fetch_xor(val, order)` | `lock xor` | Atomic bitwise XOR, returns old value |

**`compare_exchange` signature:**

```
fun compare_exchange(
    self: *AtomicI32,
    expected: i32,
    desired: i32,
    success: Ordering,
    failure: Ordering,
) -> Result<i32, i32>
```

Returns `Ok(old_value)` on success (old value matched `expected`), `Err(old_value)` on failure (old value did not match `expected`). On success, `success` ordering is applied; on failure, `failure` ordering is applied (must be `Relaxed` or `Acquire`).

**Multi-word atomics.** For operations on values wider than a single machine word, `std.atomic` provides `atomic_cas128` and `atomic_load128` / `atomic_store128` (128-bit atomics on 64-bit targets). These are lock-free on x86-64 (`cmpxchg16b`) and aarch64 (`casxp`):

```
import std.atomic

var big: AtomicU128 = AtomicU128.new(0);

# 128-bit compare-and-swap
let old = big.compare_exchange(expected, desired, AcqRel, Relaxed);

# 128-bit load/store (atomic but not ordered without fences)
let val = big.load(Relaxed);
big.store(new_val, Relaxed);
```

For wider multi-word values (arbitrary size), `std.atomic` provides `atomic_cas_multi` which uses a lock-free algorithm (hazard-pointer-protected CAS) without requiring the caller to manage memory reclamation:

```
# Arbitrary-width atomic CAS — lock-free, no hazard pointers needed
let old = std.atomic.cas_multi(&my_struct, expected, desired, AcqRel, Relaxed);
```

This avoids the complexity of manual hazard-pointer management while providing lock-free progress guarantees. Based on the "big-atomics" technique (Blelloch, 2025) — a single CAS on a descriptor object eliminates per-node coordination.

### 6.6 Parallel Primitives

`ThreadPool`, `parallel_for`, `parallel_sort`, `parallel_reduce` live in `std.thread` and are library functions.

**API:**

```
struct ThreadPool { ... }

fun ThreadPool.new(thread_count: usize) -> ThreadPool
fun ThreadPool.shutdown(self: *ThreadPool)

fun parallel_for<T>(pool: *ThreadPool, items: []T, f: fun(*T) -> void)
fun parallel_sort<T: Ordered>(pool: *ThreadPool, items: []T)
fun parallel_reduce<T>(pool: *ThreadPool, items: []T, f: fun(T, T) -> T) -> T
```

**Semantics:**
- `parallel_for` divides `items` into chunks, one per thread. Each chunk runs `f` on its elements. No return value — use `parallel_reduce` for aggregation.
- `parallel_sort` performs a parallel merge-sort. Preserves relative order of equal elements (stable).
- `parallel_reduce` partitions `items` into chunks, reduces each chunk in parallel, then reduces the partial results sequentially. The reduction function `f` must be associative.
- All primitives block until complete. No heap allocation — work is distributed via work-stealing on the thread pool.

#### Design Note: Simplicity in Concurrency

Recent research (Ripple, PLDI 2025) demonstrates that concurrency can be expressed with just two primitives: `async` (spawn a concurrent task) and `atomic` (synchronize via shared memory). Zag follows this philosophy — its concurrency primitives are minimal by design:

| Primitive | Purpose |
|-----------|---------|
| `async fun` | Spawn a concurrent task (state machine, zero-alloc) |
| `await` | Suspend until a future completes |
| `atomic` operations | Synchronize via shared memory (no locks needed) |
| `channel<T>` | Message passing between tasks |
| `task.scope` | Structured concurrency (all children complete before scope exits) |

This is sufficient for all concurrent patterns: data parallelism (`parallel_for`), pipeline parallelism (channels), request parallelism (`task.spawn`), and lock-free algorithms (atomics). No mutexes, no semaphores, no condition variables needed for new code — these exist only in `std.sync` for C FFI interop.

**Example:**

```
import std.thread

let pool = thread.ThreadPool.new(8);

var data: []i32 = ...;

# Parallel map
thread.parallel_for(&pool, data, |item| { item.* *= 2; });

# Parallel sort
thread.parallel_sort(&pool, data);

# Parallel sum
let total = thread.parallel_reduce(&pool, data, |a, b| { a + b; });
```

### 6.7 Async Compilation Model

The Zag compiler lowers `async fun` to a **tagged-union state machine**. The emitted Zig code uses:

- **`std.event.loop`** for I/O readiness (io_uring on Linux, kqueue on macOS, IOCP on Windows)
- **`std.Thread.Pool`** for task scheduling and blocking compute

Each `async fun` becomes a value type (struct) with a state tag and local variables. No heap allocation occurs per task. `await` yields the state machine back to the event loop and resumes when the I/O operation completes.

```zig
// Zag source:
async fun handle_conn(c: Conn) -> Result<(), Error> {
    let req = await c.read_request()?;
    let resp = process(req);
    await c.write_response(resp)?;
    return Ok(());
}

// Zig emission (conceptual):
const HandleConn = struct {
    state: enum { start, read_req, write_resp, done },
    conn: Conn,
    result: ?Result<(), Error> = null,

    fn resume(self: *HandleConn) void {
        while (true) {
            switch (self.state) {
                .start => {
                    self.state = .read_req;
                    // register with event loop for read readiness
                    return;
                },
                .read_req => {
                    self.state = .write_resp;
                    // register with event loop for write readiness
                    return;
                },
                .write_resp => {
                    self.result = .{ .ok = {} };
                    self.state = .done;
                    return;
                },
                .done => return,
            }
        }
    }
};
```

**Runtime mapping:**

| Zag construct | Zig backend |
|---|---|
| `async fun` | Tagged-union state machine struct |
| `await expr` | Yield state, register continuation with `std.event.loop` |
| `task.spawn(future)` | Submit state machine to `std.Thread.Pool`, returns `Task<T>` |
| `task.spawn_blocking { ... }` | Submit closure to `std.Thread.Pool` |
| `task.shield { ... }` | Disable cancellation for scope |
| `task.scope { ... }` | Scope struct tracking child tasks; auto-join/cancel on drop |
| `CancellationToken` | Atomic flag + child token list; `cancel()` sets flag, wakes waiters |
| `select` | Compiler-generated multiplexer polling multiple state machines |
| `for await` (on `std.async.stream.AsyncStream<T>`) | `while let Option.Some(x) = stream.poll_next()` desugaring (§6.4.3); combinators are monomorphized at compile time |
| `thread.spawn { ... }` | `std.Thread.spawn` (OS thread) |
| `channel<T>` | `std.Thread.Mutex` + `std.Thread.Condition` + ring buffer |
| `timer.after(d)` / `timer.deadline(d)` / `timer.interval(d)` | `std.event.Loop` timer utilities (stdlib `std.time`)
| atomics | `std.atomic` directly |

**Blocking calls in async:** Calling a blocking function (file I/O, legacy C lib, heavy compute) directly from `async fun` blocks the event loop. Use `task.spawn_blocking { ... }` or annotate the function:

```
#[blocking]
fun blocking_db_query(query: String) -> Result<Rows, Error> { ... }

async fun handler() {
    let rows = await task.spawn_blocking { blocking_db_query(sql) }?;
}
```

The `#[blocking]` attribute allows the compiler to warn if called without `task.spawn_blocking` from async context.

### 6.8 Memory Model

Zag adopts the **DRF => SC** (Data-Race Freedom implies Sequential Consistency) memory model. This is the same model used by C11, Java, and the Zig backend.

#### Data Races

A **data race** occurs when two threads access the same non-atomic memory location concurrently, and at least one access is a write, and neither access *happens-before* the other. Programs with data races have **undefined behavior**.

Atomic operations are **not** data races — they are well-defined under the specified memory ordering, even when concurrent. This is the C11 redefinition: only non-atomic conflicting actions constitute data races.

```
# Data race — undefined behavior
var x: i32 = 0;
thread.spawn { x = 1; };   # write
thread.spawn { let r = x; };  # read — race!

# No data race — atomic operations are well-defined
var x: AtomicI32 = AtomicI32.new(0);
thread.spawn { x.store(1, Release); };   # atomic write
thread.spawn { let r = x.load(Acquire); };  # atomic read — OK
```

#### Happens-Before

The *happens-before* (hb) relation defines the ordering constraints between operations. If A happens-before B, then A is visible to B and B sees A's effects. If neither A hb B nor B hb A, the operations are *concurrent*.

**Program order:** Within a single thread or async task, operations execute in program order. Operation A happens-before operation B if A appears before B in the source.

**Synchronizes-with:** The following operations establish a synchronizes-with (sw) edge. If A sw B, then A hb B:

| A | B | Condition |
|---|---|---|
| `Release` store on atomic `M` | `Acquire` load on `M` | Load reads value stored by A (or a later store in the release sequence) |
| `AcqRel` RMW on `M` | `Acquire` load on `M` | A reads the value stored, and A's store is read by B |
| `SeqCst` store on `M` | `SeqCst` load on `M` | A precedes B in the single total order |
| `thread.spawn(f)` | First operation of thread `f` | — |
| Last operation of thread `f` | `handle.join()` return | — |
| `task.spawn(future)` | First operation of task `future` | — |
| `await expr` completion | Continuation after `await` | The event loop's internal mutex/scheduling establishes hb |
| Last operation of task `T` | `task.join(T)` return | — |
| `channel.send(val)` | `channel.recv()` returning `Some(val)` | The channel's internal mutex establishes hb |
| `channel.close()` | `channel.recv()` returning `None` | The channel's internal mutex establishes hb |
| `select` winning branch | Losing branches' cancellation cleanup | The runtime polls in round-robin order; once a winner is chosen, the runtime synchronizes the winner's completion with the cancellation of all losing branches |
| `CancellationToken.cancel()` | `token.cancelled()` future completion | — |
| `task.scope` child task completion | `scope.join_all()` return | — |
| `Mutex.lock()` → `Mutex.unlock()` | Next `Mutex.lock()` | The mutex's atomic state establishes sw |
| `RwLock.read()` → `RwLock.read_unlock()` | Next `RwLock.write_lock()` | Read unlock sw write lock |
| `RwLock.write()` → `RwLock.write_unlock()` | Next `RwLock.read_lock()` or `RwLock.write_lock()` | Write unlock sw next lock |
| `channel.close()` | `channel.send()` returning `SendError.Closed` | The channel's internal mutex establishes hb |

**Transitivity:** If A hb B and B hb C, then A hb C.

**Key consequences:**

- When you `channel.send(val)`, the value is visible to the receiving task — no additional atomics needed.
- When `task.scope` joins all children, all child writes are visible to the parent — no atomics needed.
- After `await`, writes before the `await` are visible after the `await` (even if the task resumed on a different thread) — the event loop synchronization guarantees this.
- `select` winning branch hb losing branches' cancellation cleanup — no side effects in cancelled branches may bleed past the select.

#### DRF => SC Guarantee

A program without data races executes as if all memory operations are sequentially consistent — there is a single global total order of all atomic operations that is consistent with program order for each thread, and non-atomic operations appear in this order as if they were atomic.

This means: if your program has no data races, you can reason about it as if threads execute in some interleaving, and the compiler and hardware preserve this interleaving.

#### What This Means for Optimization

The compiler is **not** free to break concurrent programs through thread-oblivious optimizations. Specifically:

1. **Speculative execution across synchronization:** The compiler must not introduce data races by speculatively executing code that was guarded by atomic operations.
2. **Register promotion across atomics:** The compiler must not hoist non-atomic reads/writes out of critical sections guarded by `Acquire`/`Release` atomics.
3. **Adjacent field merging:** The compiler must not merge adjacent struct fields into a wider store if concurrent non-atomic access to those fields is possible. (In practice, Zag structs are always accessed at their declared type width.)
4. **Atomic ordering preservation:** The compiler must not reorder atomic operations in ways that violate the specified memory ordering. `Relaxed` operations may be reordered freely; `Acquire` prevents preceding loads/stores from moving past it; `Release` prevents subsequent loads/stores from moving before it; `SeqCst` imposes a total order.

These constraints are not aspirational — they are part of the language specification. Violations are compiler bugs, not user bugs.

#### Hardware-Level Ordering

The constraints above apply to the **compiler**. The Zig backend is responsible for emitting the correct hardware fences and memory barriers to enforce these orderings on the target architecture. The Zag spec does not specify which instructions the backend emits — only that the observable behavior matches DRF => SC. In practice:

- `Acquire` loads emit an `acquire` fence (x86: `mov` with dependency; aarch64: `ldar`)
- `Release` stores emit a `release` fence (x86: `mov` + `sfence` if needed; aarch64: `stlr`)
- `SeqCst` operations emit a full barrier (x86: `mfence` or `lock` prefix; aarch64: `dmb ish`)

Users do not need to reason about hardware fences — the compiler and backend handle this.

#### Out-of-Thin-Air Reads

The Zig backend (and LLVM) are prohibited from introducing values that were not present in the source program. Concretely: if a variable `x` is only written as `x = 1` in one thread and `x = 2` in another, no thread may read `x` as `42` — even under relaxed ordering. This is enforced by the backend's optimization constraints, which prohibit cyclic reasoning that would conjure values from nothing. The Zag spec inherits this constraint from the Zig/LLVM backend.

#### Safe Concurrency Primitives (no `unsafe` needed)

- `Mutex<T>`, `RwLock<T>` — scoped locking, auto-unlock on scope exit
- `Atomic*` types — all operations are safe; memory orderings are compile-time checked
- `channel<T>` — safe send/recv across threads and tasks
- `task.scope` — structured concurrency with automatic lifecycle management
- `CancellationToken` — safe cancellation propagation

#### Unsafe Concurrency

The following operations require `unsafe` blocks:

- **Raw pointer access to shared memory:** Dereferencing `*raw T` that points to data shared between tasks
- **Lock-free data structures:** Implementing custom atomic-based data structures using `std.atomic`
- **FFI across threads:** Calling C functions that are not thread-safe from multiple tasks
- **Manual task memory management:** Directly manipulating the memory of a state machine struct

**Runtime guarantees:**
- The event loop is single-threaded; task scheduling is thread-safe via `std.Thread.Pool`
- Atomics follow the DRF => SC model with acquire/release semantics
- No hidden allocations in any safe concurrency primitive

---

## 7. Control Flow

### 7.1 Conditionals

`if` / `else` are expressions.

```
let x = if cond { 1 } else { 2 };
```

`if` without `else` is a statement.

**Pattern matching in conditions:** `if let` destructures a value and executes the block only if the pattern matches:

```
if let Option.Some(val) = risky() {
    process(val);
}
```

This is equivalent to:

```
match risky() {
    Option.Some(val) => process(val),
    _ => {},
}
```

### 7.2 Loops

```
while cond { ... }
for i in 0..100 { ... }
for item in iter { ... }
```

`break` exits the innermost loop. `continue` skips to the next iteration. Both may return a value from the loop expression.

`for i in 0..100` desugars to iteration over `Range<usize>` (`{ start: usize, end: usize }`), which implements `Iterator<usize>`. The range `a..b` is half-open `[a, b)`: `start` is `a`, `end` is `b`, iteration yields `a` through `b-1`. `for item in iter` works with any type implementing `Iterator<T>` (§11.4).

**Tuple destructuring in `for`:** When the iterator yields a tuple value, the binding pattern may destructure it — the primary use case is `Map<K, V>` iteration:

```zag
for (k, v) in map.iter() {
    print("{k} -> {v}");
}
```

This desugars to:

```zag
let __it = map.iter();
while let Option.Some((k, v)) = __it.next() {
    print("{k} -> {v}");
}
```

The pattern may be a single name (`val`), a parenthesized tuple (`(k, v)`, `(a, b, c)`, `(a, b, c, d)`), or contain wildcards inside the tuple (`(k, _)` to take only the key and discard the value, `(_, v)` to take only the value, `(_, _)` to discard both). A bare `_` as the whole pattern discards the element without binding. The pattern's arity must match the iterator's element tuple; a mismatch is a compile error. **Nested tuple patterns** (`for ((a, b), c) in iter`) and struct, enum, or array patterns in `for` are deferred to v2 — see §19. Exhaustiveness is checked the same way as `let` patterns (§3.8).

**Pattern matching in loops:** `while let` repeatedly destructures a value, exiting the loop when the pattern no longer matches:

```
while let Option.Some(line) = reader.read_line() {
    process(line);
}
```

This is equivalent to:

```
while true {
    match reader.read_line() {
        Option.Some(line) => process(line),
        Option.None       => break,
    }
}
```

### 7.3 Return

`return expr;` exits the current function. Required.

```
fun add(a: i32, b: i32) -> i32 {
    return a + b;
}
```

Functions with no `-> T` return `void`.

### 7.4 Defer

`defer` runs when the current scope exits, in reverse order of declaration. Runs on early return and on `?` propagation.

```
fun read_file(path: String) -> Result<[]u8, String> {
    let fd = match open(path) {
        Ok(f) => f,
        Err(e) => return Err(e),
    };
    defer close(fd);

    let buf = alloc(1024);
    defer free(buf);

    return Ok(buf);
}
```

`errdefer` runs only when the scope exits via `?` propagation or `return Err(...)`. Useful for error-path cleanup without duplicating `free` calls:

```
fun read_into(path: String) -> Result<[]u8, Error> {
    let fd = open(path)?;
    defer close(fd);

    let buf = alloc(1024);
    errdefer free(buf);

    let n = read(fd, buf)?;
    return Ok(buf[0..n]);
}
```

`defer` always runs; `errdefer` runs only on error paths. Both execute in reverse order of declaration.

### 7.5 Match

Match expressions use `match` with pattern arms. Patterns include destructuring, range, and guard clauses. See §4.6 for full syntax.

### 7.6 Panic

```
panic("out of memory")
```

`panic` terminates the current thread. Deferred cleanups run. There is no stack unwinding across thread boundaries.

### 7.7 Error Propagation

`?` propagates `Result.Err` and `Option.None` early. The function's return type must be compatible with the propagated value (`Result<T, E>` for `Result`, `Option<T>` for `Option`).

**Cross-type `?` is not implicit.** `?` only propagates values whose outer type matches the function's return type:
- A function returning `Result<T, E>` may `?` only on `Result<U, E>` (the error variant `E` must match exactly)
- A function returning `Option<T>` may `?` only on `Option<U>`
- `?` on `Option<T>` inside a function returning `Result<T, E>`, or vice versa, is a **compile error**

**`?` with tuple returns.** When the function returns a tuple containing a `Result` or `Option`, `?` applies to the `Result`/`Option` element and the remaining elements bind normally:

```
fun parse(input: str) -> (Result<Config, Error>, u32) {
    # ...
}

let (config, consumed) = parse(data)?;
# ? propagates the Result, binds the u32
```

To convert between `Option` and `Result` at a `?` site, call an explicit method first:

```
# Option -> Result: caller-provided default error
let val: T = maybe().ok_or(MyError.not_found)?;

# Result -> Option: drop the error
let val: T = risky().ok()?;
```

`ok()` and `ok_or(err)` are inherent methods on `Result<T, E>` and `Option<T>` respectively, defined in `std.result` and `std.option` (§11.3). `Result.ok()` discards the error and returns `Option<T>`; `Option.ok_or(err)` returns `Result<T, E>` substituting `err` for `None`.

Implicit cross-type propagation was considered and rejected: it hides the error type from the function signature and makes the `?` operator behave differently depending on context, which violates the no-hidden-control-flow principle (§1).

```
fun read_file(path: String) -> Result<[]u8, Error> {
    let fd = open(path)?;   # open returns Result<..., Error>
    let buf = read(fd)?;    # read returns Result<..., Error>
    return Ok(buf);
}
```

#### `catch` — handle errors inline

`catch` works with both `Result` and `Option`. With `Result` the error value is bound; with `Option` no binding is available (just a block or default value).

```
# Block form — error value bound
let val = risky() catch |err| {
    eprint("error: {err}");
    return 0;
};

# Default value form
let val = risky() catch 0;

# With Option — no binding, just block or default
let val = maybe() catch {
    return 0;
};
let val = maybe() catch 0;

# match on the error enum directly
let val = risky() catch |err| {
    match err {
        Error.NotFound => return 0,
        _              => return err,
    }
};
```

---

## 8. Functions

### 8.1 Declaration

```
fun add(a: i32, b: i32) -> i32 {
    return a + b;
}
```

**Tuple spread** expands a tuple into positional arguments:

```
fun add(a: i32, b: i32) -> i32 { return a + b; }
fun pair() -> (i32, i32) { return (3, 5); }

let result = add(...pair());   # desugars to add(3, 5)
```

**Variadic parameters:** The last parameter may be suffixed with `...` to accept zero or more trailing arguments of that type:

```
fun sum(values: i32...) -> i32 {
    var total: i32 = 0;
    for v in values {
        total += v;
    }
    return total;
}
```

Inside the function, a variadic parameter is treated as a slice (`[]T`). Variadic calls are lowered to passing a slice; no heap allocation is required when the caller's arguments are already contiguous.

### 8.2 Higher-Order Functions

```
fun apply<T, U>(f: fun(T) -> U, value: T) -> U {
    return f(value);
}
```

Function types use lowercase `fun`. Closures capture by reference by default; use `move` to take ownership. **Explicit capture lists** (recommended) make captures visible and enable compile-time checking via `-Dref-check` / `-Dasync-ref-check`:

```
let offset: i32 = 10;
let add_offset = [&offset] |x: i32| -> i32 { return x + offset; };   # explicit borrow

let s = new String("hello");
let f = [s = move s] |x: i32| -> String { return s + " " + x.to_string(); };  # explicit move
```

**Capture list syntax:** `[&x, &y, z = move z, w = copy w]` — each capture is:
- `&name` — borrow (reference), checked by `-Dref-check` to not outlive the referent
- `name = move name` — take ownership, `name` is moved into the closure
- `name = copy name` — duplicate (requires `Copy`), closure owns the copy

Without a capture list, the compiler infers captures (reference by default, `move` keyword on the closure forces all captures to be moves). Explicit lists are preferred for clarity and checking.

**Async closures** follow the same rules; `-Dasync-ref-check` ensures no stack pointers are captured:

```
async fun spawn_task() {
    let local: i32 = 42;
    # ERROR with -Dasync-ref-check: captures &local which points to stack
    let bad = task.spawn(async [&local] { await do_work(local); });
    
    # OK: move captures owned data
    let owned = new String("hello");
    let good = task.spawn(async [owned = move owned] { 
        await process(owned); 
    });
}
```

### 8.3 Compile-Time Execution

The `const` keyword is the sole comptime mechanism. It evaluates code at compile time in three forms:

**1. `const` variable — already computed at compile time:**

```
const PI: f64 = 3.141592653589793;
const MASK: u32 = 0xFF;
```

**2. `const` block — arbitrary code evaluated at compile time:**

```
const TABLE: [256]u32 = const {
    var t: [256]u32 = undefined;
    for i in 0..256 {
        t[i] = (i * 2654435761) as u32;
    }
    return t;
};
```

A `const` block may contain loops, conditionals, and local variables. It is executed at compile time and the result is embedded in the binary.

**3. `const` type parameter — monomorphize at compile time:**

```
fun fill<T, const N: usize>(val: T) -> [N]T {
    var out: [N]T = [N]T { val ... };
    return out;
}

let zeros = fill<i32, 10>(0);
```

**Rules:**
- `const` blocks can call only other `const` blocks. A `fun` declaration with no I/O, no allocation, and no FFI is **implicitly `const`-evaluable** — the compiler treats it as a compile-time function. Calling a function that is *not* implicitly `const`-evaluable from a `const` block is a compile error pointing at the call site.
- I/O, heap allocation, and syscalls are forbidden inside `const` blocks.
- `const` evaluation uses the compiler's interpreter; results are embedded directly into the binary (like Zig's `comptime`).
- `const type` allows passing types as values for metaprogramming.

**4. Compile-time builtins** — the compiler exposes type-level metadata as built-in functions usable inside `const` blocks and `const` parameters:

| Builtin | Returns | Example |
|---|---|---|
| `fields(T)` | Struct field descriptors (name, type, offset) | `fields(Vec3)` yields `[{name: "x", type: f64, offset: 0}, ...]` |
| `size_of(T)` | Size in bytes | `size_of(i32)` → `4` |
| `align_of(T)` | Alignment in bytes | `align_of(f64)` → `8` |
| `type_name(T)` | Type name as `[]const u8` | `type_name(Vec3)` → `"Vec3"` |

Example — compile-time struct serialization:

```
fun serialize<T>(val: *const T, buf: *raw u8) -> usize {
    var offset: usize = 0;
    const flds = fields(T);
    for fld in flds {
        let src = (val as *raw u8).add(fld.offset);
        for j in 0..fld.size {
            buf[offset] = src.add(j).*;
            offset += 1;
        }
    }
    return offset;
}
```

`fields` returns a compile-time array of `FieldDesc { name: []const u8, type: type, offset: usize, size: usize }`. This enables generic serialization, ECS component registration, and debug printing without manual `to_string` implementations.

**Common use cases.** Compile-time tables are the workhorse pattern: declare a `[N]T` array, fill it in a `for` loop with a pure expression, return the array. The result is embedded in the binary as a static global — no runtime cost, no initialization step, no per-call allocation. The example above is a Knuth multiplicative-hash table (the magic constant `2654435761` is `2^32 / 0.618...`). The same shape handles:
- Trigonometric and sigmoid lookup tables for graphics and ML inference
- State-machine transition tables for parsers, regex engines, lexers
- Encoding tables (Base64, UTF-8 validation, CRC32 polynomial division)
- Compile-time-generated SIMD shuffle masks for `bf16` / `f16` quantize/dequantize

### 8.4 Async Functions

See §6.2 for async/await syntax and semantics.

### 8.5 Inline Assembly

Inline assembly syntax is described in §4.8.

---

## 9. Modules and Imports

### 9.1 File-Path-Based Modules

No `module` declaration. The module path is the file path.

```
src/main.zag            -> module main
src/math/vec3.zag       -> module math.vec3
src/net/http/server.zag -> module net.http.server
```

A directory is a module if it contains `.zag` files. `mod.toml` may declare submodules explicitly.

**`mod.toml`** — optional file in a module directory to control submodule discovery and exports:

```toml
# mod.toml
[module]
name = "math"              # optional, defaults to directory name
version = "0.1.0"

# Explicit submodule list (opt-in). If omitted, all .zag files in the directory are modules.
submodules = ["vec3", "mat4", "quat"]

# Re-export control — whether each submodule is re-exported from the parent
[exports]
vec3 = true                # public: import math.vec3 works
mat4 = true
quat = false               # private: only math.quat, not re-exported from math
```

If `mod.toml` is absent, all `.zag` files in the directory are treated as submodules and all are re-exported.

**Cyclic module detection.** The import resolver builds a module DAG and reports an error on cycles. This is a compile-time check (no runtime cost).

**Re-exports in `mod.zag`.** A `mod.zag` file in a module directory can re-export symbols for convenience:

```zag
# src/math/mod.zag
pub import math.vec3.{Vec3, Vec3::*};
pub import math.mat4.{Mat4, Mat4::*};
# quat not re-exported (private per mod.toml)
```

### 9.2 Imports

```
import math.vec3
import math.vec3 as v
import math.{Vec3, Mat4}
```

### 9.3 Visibility

- No modifier — module-private
- `pub` — visible outside the module

### 9.4 Dependencies

Third-party packages live in `deps/`. Run `zag install` to fetch them.

Packages are resolved from a central package registry at `zagpm.dev`. Dependencies can also be specified as Git URLs in `zag.toml` for packages not yet published to the registry. The lock file (`zag.lock`) pins exact versions and hashes.

---

## 10. Documentation

Doc comments use `##`.

```
## Adds two integers.
fun add(a: i32, b: i32) -> i32 {
    return a + b;
}
```

Sections: `# Arguments`, `# Returns`, `# Errors`, `# Examples`, `# Safety`.

---

## 11. Standard Library

The language has a small core. Everything in this section is standard library.

### 11.1 Core Types

| Type | Description |
|---|---|
| `Option<T>` | `enum { Some(T), None }` |
| `Result<T, E = Error>` | `enum { Ok(T), Err(E) }`. `E` defaults to `Error`, so `Result<T>` is shorthand for `Result<T, Error>` |
| `Error` | `enum { NotFound, Permission, Io, Parse, InvalidInput, Unavailable, Other }` — the canonical error type (§3.3). Zero-alloc; no heap-allocated message field |
| `Context` | `struct { msg: Option<String>, source: Option<*Error> }` — error with optional context message (§3.3). Only allocated when explicitly created via `ErrorExt.context()` |
| `[]T` | slice |
| `Range<T>` | `struct { start: T, end: T }`; implements `Iterator<T>`, produced by `a..b` syntax. `a..b` is half-open `[a, b)`: `start` is `a`, `end` is `b`, iteration yields `a` through `b-1` |
| `c_void` | Opaque FFI type; zero-sized, only used through pointers (`*c_void`, `*raw c_void`) |
| `c_int`, `c_long`, `c_short`, `c_char` | C-compatible integer types (size matches the target C ABI) |

### 11.2 Core Functions

| Function | Description |
|---|---|
| `new T(value)` / `new T { ... }` | Heap allocate and initialize |
| `new(allocator, T(value))` | Heap allocate with custom allocator |
| `free(ptr: *T)` / `free(ptr: *raw c_void)` | Free a heap-allocated or raw pointer |
| `alloc(size: usize) -> *raw u8` | Raw allocation via global allocator |
| `realloc(ptr: *raw u8, new_size: usize) -> *raw u8` | Resize an allocation, may move |
| `transmute<T, U>(val: T) -> U` | Reinterpret bytes of `val` as type `U`. Requires `unsafe`. Both types must be the same size |
| `print(msg: []const u8...)` | Print to stdout, accepts interpolated strings |
| `eprint(msg: []const u8...)` | Print to stderr, accepts interpolated strings |
| `exit(code: i32)` | Terminate process |
| `panic(msg: String)` | Unrecoverable error |
| `assert(cond, msg: str)` | Runtime check with optional message |


### 11.3 Stdlib Packages

Packages the bootstrap stdlib must provide:

- `std.mem` — `Allocator`, `global_allocator`, `Arena`, `Rc<T>`, `Arc<T>`, `Cell<T>`, `RefCell<T>`. `Arena` is a bump allocator for scoped lifetimes: `Arena.new()` creates a new arena (initial capacity 0, grows on demand), `Arena.with_capacity(size: usize)` pre-reserves an initial region of the given size (avoids the first few grow calls — useful for game-frame allocators that know the per-frame budget up front, or per-request HTTP arenas), `arena.alloc<T>(value)` allocates a `T` from the arena, `arena.free_all()` resets the arena to empty in O(1) (does not run destructors — meant to be called between frames in a game loop or at the end of a request in an HTTP handler). **Arena leak trap:** `free_all()` does not reclaim inner allocations of types like `String`, `List<T>`, or `Map<K,V>` — see §5.1 for the full warning. `Arena` satisfies the `Allocator` trait, so `new(arena, T(value))` (§5.1) works out of the box. `Rc`/`Arc` use `unsafe` internally for shared ownership; `Cell`/`RefCell` use `unsafe` for interior mutability. Their public APIs are safe
- `std.collections` — `List<T>`, `Map<K, V>`, `Set<T>`, `Deque<T>`. `List.iter()`, `Set.iter()`, and `Deque.iter()` return `Iterator<T>`; `Map<K, V>.iter()` returns `Iterator<(K, V)>` — this is the contract that enables `for (k, v) in map` destructuring in §7.2
- `std.thread` — `thread.spawn`, `ThreadPool`, `parallel_for`
- `std.async` — `Future<T>`, `Task<T>`, `task.spawn`, `task.spawn_blocking`, `task.shield`, `task.detach`, `task.join`, `task.scope`, `CancellationToken`, `TcpListener`, `TcpStream`
- `std.async.stream` — `trait AsyncStream<T> { fun poll_next(self: *Self) -> Option<T>; }`, concrete stream types (`ChannelStream<T>`, `TcpStream`, etc.), and combinators (`map`, `filter`, `take`, `skip`, `chain`, `zip`, `buffered(n)` — limits concurrent inner futures to `n`, `timeout`, `collect`)
- `std.sync` — `Mutex<T>`, `RwLock<T>`, channels
- `std.atomic` — atomic operations
- `std.simd` — vector types and operations
- `std.arch` — target-specific intrinsics (x86, ARM, etc.)
- `std.fmt` — `fmt.Write` trait for zero-alloc formatting (§4.5), `fmt.Writer` byte-sink struct, format specifier parsing
- `std.time` — `Duration`, `Instant`, `timer.after`, `timer.interval`, `timer.deadline`
- `std.unicode` — codepoint/UTF-8 encoding operations
- `std.source` — `Location { file: str, line: u32, column: u32 }`, `Function { name: str }`. Users obtain a `Location` via the magic identifier `#location` (resolves at the call site to the current source location). `Function` is populated by the compiler and can be retrieved via `std.source.caller()` for the enclosing function name. Both are passed implicitly to `panic` and `assert`
- `std.string` — `String` (growable UTF-8, layout `{ ptr: *u8, len: usize, cap: usize }`), `push`, `push_str`, `reserve`, `clear`, `as_str`, `as_writer`, `with_writer` (§3.3)
- `std.error` — `Context` struct, `ErrorExt` trait (`context(msg: String) -> Context`, `context_str(msg: str) -> Context`) for adding context to any error type (§3.3)
- `std.traits` — compiler-known structural traits: `Ordered` (requires `__lt__`, `__le__`, `__gt__`, `__ge__`), `Clone`, `Default`, `Zero`, `Display`, `Iterator<T>`, `AsyncStream<T>`. These are auto-implemented when a type defines the required methods (§4.1).
- `std.default` — `Default` trait and `Zero` trait:
  - `trait Default { fun default() -> Self; }` — produces a type-appropriate "zero" value (`0`, `false`, `{}`, `'\0'`, `Option.None`, the first enum variant). `Default` is implemented for all primitive types and for any `struct` annotated with `#[derive(Default)]` (§2.5). Use it to give a struct a canonical empty value without writing a constructor. `Default` is the right choice when the type may contain non-`Copy` fields (e.g. `String`) that need a non-zero empty state. Because Zag has no trait bounds on generics (§4.1), `Default` is invoked through method call syntax (`T.default()`) — there is no top-level generic `default<T>()` function
  - `trait Zero { fun zero() -> Self; }` — marker for "all-zero bytes is a valid value." `Zero` is implemented for all primitive types, `[N]T` where the element is `Zero`, and any `#[derive(Zero)]` struct where every field is `Zero` (no embedded slices, `String`, `Option<T>` where `T` is not `Zero`, or other non-`Zero` types). **Use `Zero` in hot loops** (game frames, AI kernels, page-table zeroing) where the compiler can emit a single `memset`; use `Default` when the struct is heterogeneous or contains `String` / `Option` / `Result`. `Zero` is a stronger precondition than `Default` — not every `Default` type is `Zero`, but every `Zero` type is `Default` (a `zero` value is a valid `default` value). Same caveat as `Default`: invoke via `T.zero()` method syntax, not generic helpers
- `std.net`, `std.fs`, `std.io`, `std.json`, `std.bytes`, `std.math`

**Deferred stdlib packages (planned, not in v1):** `std.crypto` (cryptographic primitives), `std.regex` (regular expressions), `std.ui` (GUI toolkit). See §19 for the full deferral list.

**Method signature conventions.** When a collection-style API takes a value of element type `T` (e.g. `List<T>.push(self: *List<T>, value: T)`, `Map<K, V>.insert(self: *Map<K, V>, key: K, value: V)`, channel `send`), the value is passed **by value** and the standard move/copy rules apply: `Copy` types are duplicated, non-`Copy` types are moved from the caller. The stdlib never silently clones. To insert a value that the caller still needs, use `value.clone()` (or `Rc.clone` / `Arc.clone` for shared ownership) explicitly — the allocation is visible at the call site, in keeping with the no-hidden-allocation principle (§1).

### 11.4 Iterator Protocol

```
trait Iterator<T> {
    fun next(self: *Self) -> Option<T>;
}
```

`for x in collection` desugars to calling `next()` on any type implementing `Iterator<T>`.

---

## 12. Compiler

### 12.1 Backend

The compiler emits **Zig source code** and invokes the Zig toolchain to produce native binaries. There is no custom native backend or linker in v1.

Target architectures (via Zig):

```
x86_64-linux
aarch64-linux
x86_64-macos
wasm32-wasi
riscv64-linux
```

### 12.2 Bootstrap

1. **Bootstrap compiler** — written in Zig (~10-15k LOC). Parses Zag to AST, resolves imports, type-checks (including struct embedding promotion, trait implementation validation), resolves method overloads (Julia-style exact-match-first), monomorphizes generics and `const` parameters, lowers `async fun` to state machine structs, desugars `for await` to method calls, and emits Zig source.
2. **Self-hosted compiler** — full Zag compiler written in Zag, compiled with the bootstrap compiler. Still emits Zig source, which is always the canonical backend.

### 12.3 Pipeline

```
Source
  -> Lexer / Parser -> AST
  -> Import resolution (with cyclic module detection)
  -> Type checker + overload resolver
  -> Trait bounds resolution (structural trait satisfaction)
  -> Struct embedding promotion (field/method dot access lowering)
  -> Capture list analysis (for closures)
  -> Comptime evaluator (const blocks, const parameters)
  -> Async lowering (async fun -> state machine structs; for await -> poll_next calls)
  -> Pattern match compiler (exhaustiveness check + decision tree)
  -> Trait dispatch lowering (vtable synthesis for fat-pointer calls)
  -> Zig emitter
  -> zig build-exe / zig build-lib
  -> Executable
```

### 12.4 Compilation Flags

| Flag | Effect |
|---|---|
| `-O0` | no optimization (default) |
| `-O1` `-O2` `-O3` | optimization levels |
| `-Od` | debug checks enabled |
| `-g` | debug info |
| `-o <file>` | output file |
| `-c` | compile only, no link |
| `--target <triple>` | Cross-compile target (LLVM triple format, e.g. `x86_64-linux-gnu`, `aarch64-macos-none`, `wasm32-wasi`) |
| `-D<check>` | enable compile-time check (see §5.7) |
| `-Dasync-ref-check` | async capture validity analysis (subset of `-D` checks) |
| `-Dthread-safety` | thread-safety static analysis (subset of `-D` checks) |
| `-Dbounds-check` | inserts runtime bounds checks on array/slice access |
| `-Dinit-check` | definite-assignment analysis for locals |
| `-Dleak-check` | intraprocedural leak detection |
| `-Downership-check` | double-free / use-after-move detection |
| `-Dref-check` | dangling reference detection (includes closure capture checking) |
| `-fsanitize=<kind>` | enable runtime sanitizer |

---

## 13. Testing

```
#[test]
fun add_works() {
    assert(add(1, 2) == 3);
}
```

Run with `zag test`.

### 13.1 Benchmarking

Benchmark functions are marked with `#[bench]`. They take no arguments and return `void`. The `zag bench` command runs each benchmark a fixed number of iterations (1 by default, configurable via `--iterations` on the CLI) and prints timing and allocation statistics.

```
import std.bench

#[bench]
fun bench_matrix_multiply() {
    let a = Matrix4x4.identity();
    let b = Matrix4x4.identity();
    let c = a * b;
}
```

`std.bench` measures:
- **Elapsed wall-clock time** via `std.time.Instant`
- **Bytes allocated** by recording the allocator counter before and after
- **Number of allocations**

Example output:

```
bench_matrix_multiply
  iterations:    1
  total time:    42.50 us
  avg time:      42.50 us
  bytes alloc:   0
  allocations:   0
```

**Allocation tracking:** The runtime allocator maintains counters for total bytes and total allocation calls. `std.bench` snapshots these counters around the benchmark body. Allocations outside the benchmark body (e.g., test harness setup) are not counted.

---

## 14. CLI

### 14.1 Commands

| Command | Description |
|---|---|
| `zag new <name>` | Create a new package |
| `zag init` | Initialize package in current directory |
| `zag build` | Build current package |
| `zag run` | Build and run the main executable |
| `zag test` | Run tests |
| `zag bench` | Run benchmark functions |
| `zag fmt` | Format source files |
| `zag fmt --check` | Check formatting without modifying |
| `zag clean` | Remove build artifacts |
| `zag install` | Download dependencies to `deps/` |
| `zag add <pkg>` | Add a dependency |
| `zag remove <pkg>` | Remove a dependency |
| `zag update [pkg]` | Re-resolve dependencies |
| `zag check` | Run the **default safety profile** in sequence: `-Downership-check` + `-Dleak-check` + `-Dref-check` (compile time, no runtime overhead). These three compile-time checks are the language's standing answer to the absence of a borrow checker / destructor / GC (§5.3.1). Fast enough for pre-commit on every commit; recommended for every commit and PR. |
| `zag check --quick` | Compile-time checks only (fast, no runtime overhead): enables **all** `-D` flags (ownership, leak, ref, async-ref, bounds, init, thread-safety) |
| `zag check --runtime` | The default profile + `-fsanitize=undefined` (cheap runtime UB detector). Slowed by 1.5-3x depending on workload; intended for CI on every PR |
| `zag check --strict` | Maximum coverage: all `-D` flags + all `-fsanitize` flags (`memory`, `thread`, `leak`, `undefined`). Slowest (5-20x); intended for nightly CI and fuzz runs |
| `zag check --leaks` | Leak-focused: `-Dleak-check` + `-Downership-check` + `-fsanitize=leak` + `-fsanitize=memory` |
| `zag check --races` | Race-focused: `-Dasync-ref-check` + `-Dthread-safety` + `-Downership-check` + `-fsanitize=thread` |
| `zag check <name>` | Run a specific check by name (e.g. `zag check async-ref`, `zag check bounds`, `zag check ownership`) |
| `zag version` | Show version information |

### 14.2 Package Layout

```
my_project/
??? src/
?   ??? main.zag
?   ??? lib.zag
??? test/
?   ??? lib_test.zag
??? deps/
??? build/
?   ??? debug/
?   ??? release/
??? zag.toml
??? zag.lock
??? .gitignore
```

### 14.3 Manifest (`zag.toml`)

```toml
[package]
name = "my_project"
version = "0.1.0"
description = "A short description"

[dependencies]
math = "^1.0.0"
json = ">=1.2.0, <2.0.0"

[dev-dependencies]
test_utils = "0.1.0"

[build]
target = "bin"   # or "lib"
```

Dependencies may also specify a Git URL:

```toml
[dependencies]
my_pkg = { git = "https://github.com/user/my_pkg", tag = "v1.0.0" }
```

---

## 15. File Extension

Source files use `.zag`. Manifests use `zag.toml`. Module description files use `mod.toml`.

---

## 16. Example: UI Widgets

```
struct Widget {
    x: i32,
    y: i32,
}

impl Widget {
    pub fun move(self: *Widget, dx: i32, dy: i32) {
        self.x += dx;
        self.y += dy;
    }
}

trait Drawable {
    fun draw(self: *Self);
    fun size(self: *Self) -> i32;
}

struct Button {
    Widget,          # embedding — inherits x, y and .move()
    label: String,
}

impl Button {
    pub fun Drawable.draw(self: *Button) {
        print("Button: ");
        print(self.label);
    }

    pub fun Drawable.size(self: *Button) -> i32 {
        return self.label.len;
    }
}

struct Label {
    Widget,          # embedding
    text: String,
}

impl Label {
    pub fun Drawable.draw(self: *Label) {
        print(self.text);
    }

    pub fun Drawable.size(self: *Label) -> i32 {
        return self.text.len;
    }
}

fun render(d: Drawable) {
    d.draw();
}

fun main() -> void {
    let ok = new Button { x: 0, y: 0, label: "OK" };
    let msg = new Label { x: 0, y: 30, text: "Hello" };

    render(ok as Drawable);
    render(msg as Drawable);

    free(ok);
    free(msg);
}
```

---

## 17. Example: Matrix Type

```
struct Matrix4x4 {
    data: [16]f64,
}

impl Matrix4x4 {
    pub fun identity() -> Matrix4x4 {
        var m = Matrix4x4 { data: [16]f64 { 0.0 ... } };
        m.data[0]  = 1.0;
        m.data[5]  = 1.0;
        m.data[10] = 1.0;
        m.data[15] = 1.0;
        return m;
    }

    pub fun __mul__(a: Matrix4x4, b: Matrix4x4) -> Matrix4x4 {
        var r = Matrix4x4 { data: [16]f64 { 0.0 ... } };
        for i in 0..4 {
            for j in 0..4 {
                var sum: f64 = 0.0;
                for k in 0..4 {
                    sum += a.data[i + k * 4] * b.data[k + j * 4];
                }
                r.data[i + j * 4] = sum;
            }
        }
        return r;
    }
}
```

---

## 18. Example: Doubly Linked List

```
struct Node<T> {
    prev: ?*Node<T>,
    next: ?*Node<T>,
    data: T,
}

struct List<T> {
    head: ?*Node<T>,
    tail: ?*Node<T>,
    len: usize,
}

impl<T> List<T> {
    pub fun new() -> List<T> {
        return List {
            head: null,
            tail: null,
            len: 0,
        };
    }

    pub fun push_front(self: *List<T>, value: T) {
        let node = new Node<T> {
            prev: null,
            next: self.head,
            data: value,
        };
        if let Option.Some(existing) = self.head {
            existing.prev = node;
        } else {
            self.tail = node;
        }
        self.head = node;
        self.len += 1;
    }

    pub fun push_back(self: *List<T>, value: T) {
        let node = new Node<T> {
            prev: self.tail,
            next: null,
            data: value,
        };
        if let Option.Some(existing) = self.tail {
            existing.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.len += 1;
    }

    pub fun pop_front(self: *List<T>) -> Option<T> {
        if let Option.Some(node) = self.head {
            self.head = node.next;
            if let Option.Some(next) = node.next {
                next.prev = null;
            } else {
                self.tail = null;
            }
            self.len -= 1;
            let value = node.data;
            free(node);
            return Option.Some(value);
        }
        return Option.None;
    }

    pub fun pop_back(self: *List<T>) -> Option<T> {
        if let Option.Some(node) = self.tail {
            self.tail = node.prev;
            if let Option.Some(prev) = node.prev {
                prev.next = null;
            } else {
                self.head = null;
            }
            self.len -= 1;
            let value = node.data;
            free(node);
            return Option.Some(value);
        }
        return Option.None;
    }

    pub fun iter(self: *const List<T>) -> ListIter<T> {
        return ListIter { current: self.head };
    }

    pub fun len(self: *const List<T>) -> usize {
        return self.len;
    }
}

impl<T> ListIter<T> {
    pub fun Iterator<T>.next(self: *ListIter<T>) -> Option<T> {
        if let Option.Some(node) = self.current {
            self.current = node.next;
            return Option.Some(node.data);
        }
        return Option.None;
    }
}

struct ListIter<T> {
    current: ?*Node<T>,
}

fun main() {
    var list = List<i32>.new();
    list.push_front(1);
    list.push_front(2);
    list.push_back(3);

    for val in list.iter() {
        print("{val}");
    }

    while let Option.Some(val) = list.pop_front() {
        print("{val}");
    }
}

---

## 19. v1 Scope and Deferred Features

The v1 language and bootstrap compiler deliberately omit several features commonly found in mature systems languages. Listing them here makes the scope of v1 explicit and helps contributors pick post-v1 work.

**Deferred to v2+ (require language changes):**

| Feature | Why deferred | Expected target |
|---|---|---|
| Full compile-time reflection / `#[derive(Debug, JSON, Eq, Hash, Ord)]` | v1 has `#[derive(Clone)]`, `#[derive(Default)]`, `#[derive(Zero)]` (§2.5) plus the `fields`, `size_of`, `align_of`, `type_name` builtins (§8.3). The remaining derives need a const-accessible AST API and user-defined derive macro hooks | v2 |
| Macros / syntax extensions | Hygiene and resolution rules need experience with the type system in the field first | v2 |
| Nested-tuple / struct / enum / array patterns in `for` | Single-level tuple destructuring is in v1 (§7.2); full pattern coverage awaits a v2 syntactic-sugar addition | v2 |
| Associated types in traits | Currently expressible via generic type parameters; the syntactic sugar is non-trivial | v2 |
| Trait inheritance (`trait Foo: Bar`) | Use composition (`trait Foo { fun bar(self: *Self): Bar; }`) until a real use case appears | v2 |
| Generic associated types (GATs) | Awaiting concrete need from the stdlib | v2 |
| `const` generics with `*` patterns (`const N: usize where N > 0`) | Parsing complexity outpaces current benefit | v2 |
| Built-in benchmark filtering / `criterion`-style statistics | `std.bench` returns raw timing; richer stats are a library addition | v2 |
| Built-in test coverage instrumentation | Awaiting profiler/LLVM coverage format choice | v2 |
| Built-in fuzz harness (`#[fuzz]`) | Awaiting feedback on a safe `unsafe`-aware fuzz API | v2 |
| Source maps for panic messages across FFI boundaries | Requires a stable emission format | v2 |
| Cyclic module dependency checker (module DAG) | v1 enforces a strict DAG; cycles produce a clear error | v2 |

**Out of scope entirely (libraries, not language):**

| Feature | Where it should live |
|---|---|
| GUI / widget toolkit | `std.ui` or a third-party crate |
| SQL / database engines | Third-party crates built on `std.collections` and `std.fs` |
| HTTP server framework | Third-party crate on top of `std.net` |
| AI model format loaders (ONNX, GGUF) | Third-party crates; the language's `bf16` + SIMD primitives are sufficient |
| Regular expressions | A stdlib regex crate |
| Crypto primitives | `std.crypto` (post-v1) |

**Design decisions explicitly rejected for v1:**

- **No borrow checker.** Pointers work like Zig; safety tools are opt-in.
- **No garbage collector.** `new` / `free` is the only memory model.
- **No method-resolution via inheritance.** Use struct embedding + traits.
- **No implicit numeric conversions** beyond widening. Use `as`.
- **No custom operators** beyond the desugaring to `__op__` methods.
- **No `yield` / built-in generators.** Streams are the `std.async.stream.AsyncStream<T>` trait.
- **No variadic generics** beyond trailing `T...`. The stdlib is built around slices, not heterogeneous tuples.
- **No hidden allocation in `for` / `match` / string interpolation.** All allocations are explicit (`new` / `String.with_capacity`).
- **No separate compilation-unit declaration.** Each `.zag` file is compiled independently; a directory is the module boundary (§9.1) and the build system links the produced object files into the final binary.

This list is updated as v1 stabilizes. Items are promoted to v2 only when there is a concrete user need backed by a real program in the v1 stdlib.
