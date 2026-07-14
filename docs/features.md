# Zag features — implementation status

Maintained checklist of every feature documented in `docs/manual/`,
grouped in chapter order. A feature is **checked** `[x]` iff BOTH of:

1. **Implementation** — `src/parser/` accepts it and `src/codegen/`
   emits valid zig for it.
2. **Coverage** — a test in `src/tests/` OR a runnable example in
   `examples/` exercises it.

Features that are documented but **not yet implemented** stay
unchecked `[ ]` with a short reason.

How to use this file:

- When you implement a feature in the parser/codegen, change its
  box from `[ ]` to `[x]` and add a one-line citation of the
  test/example that proves coverage.
- When you re-validate (after a `zig build test`), run a presence
  check on the box state — every `[x]` should still have its
  underlying test compile, every `[ ]` should still be missing
  from `src/tests/`.
- Every box has an inline link back to the manual chapter covering
  it (the chapter header). Sub-feature granularity matches what
  the manual itself uses, so the doc and this checklist stay
  in lockstep when a chapter is added or rewritten.

Re-validation cadence: regenerate after every parser/codegen
land. The check is mechanical — grep for the `[x]` / `[ ]`
distribution and audit each new line against `src/`.

---

## 00. Overview ([manual/00-overview.md](../manual/00-overview.md))

- [x] Program entry-point convention — `fun main()` recognised by
  `src/main.zig`'s `cmdRun` / `cmdCheck` / `cmdBuild` dispatch.
  Verified by every example under `examples/basics/`.
- [x] `print(...)` builtin — `src/codegen/primary.zig:genPrintCall`
  routes to `std.debug.print(...)`. Pinned by
  `src/tests/codegen.zig`'s "codegen: hello world".
- [x] `.zag` source extension — file dispatcher in `src/main.zig`
  greps for `.zag`. Implicit (no separate test needed).
- [ ] `zag init` new-project scaffolding beyond basic hello —
  `src/main.zig`'s `cmdInit` writes a hello boilerplate, but no
  below covers `zag init --<features>` (tests, build config).
  Deferred until users request it.
- [ ] Compiler flag matrix from manual overview (`-D<feature>=...`)
  — only `-Dz_install`, `-Dzig_payload`, `-Dasync-ref-check` are
  wired; the rest of the documented flag surface is deferred
  ([manual/31-building.md](../manual/31-building.md) covers the
  full list).

## 01. Hello World ([manual/01-hello-world.md](../manual/01-hello-world.md))

- [x] Single-file hello program — `examples/basics/hello.zag`
  runs end-to-end via `zag run`. Pinned by
  `src/tests/codegen.zig` "codegen: hello world".

## 02. Comments ([manual/02-comments.md](../manual/02-comments.md))

- [x] Line comment (`# ...`) — `src/lexer/core.zig` skips
  `#`-prefixed runs to the next newline. Pinned by
  `src/tests/lexer.zig` "lexer: line comment is skipped".
- [x] Single-line doc comment (`## ...`) — captured as
  `Token.doc_comment`. Pinned by "lexer: single-line doc comment".
- [x] Multi-line doc continuation (`## a\n# b` ⇒ one doc block) —
  pinned by "lexer: multi-line doc comment with continuation".
- [x] Empty doc-comment gated by source-line control flow —
  captured by `src/parser/core.zig:parse` doc accumulator.
  Pinned by "parser: doc attached to fun decl".
- [x] Doc comment emitted as zig `/// ` — codegen via
  `src/codegen/stmt.zig:genDocComment`. Pinned by
  "codegen: doc comment emitted as zig ///".
- [x] Doc comment attached to non-fun decls (struct/enum/trait) —
  `StructDecl.doc` / `EnumDecl.doc` / `TraitDecl.doc` threaded
  by `src/parser/core.zig`'s top-level accumulator + emitted
  via `genDocComment` in `src/codegen/decl.zig`'s `genStructDecl`
  / `genEnumDecl` / `genTraitDecl` immediately before each
  container's `pub const NAME = ...` emit. Pinned by
  `"codegen: doc comment emitted as zig /// on struct"`,
  `"codegen: doc comment emitted as zig /// on enum"`, and
  `"codegen: doc comment emitted as zig /// on trait"`.
  *impl-block doc deferred*: an `impl NAME { ... }` desugars to
  either nested-in-struct methods (so the doc would attach above
  the struct, NOT above the impl body) or module-level free fns
  via `genFreeMethod` (no single zig container to anchor `///`
  onto). Designing the right ritual here is a followup.

## 03. Literals ([manual/03-literals.md](../manual/03-literals.md))

- [x] Decimal integer (`42`, `1_000_000`) — pinned by
  "lexer: integer with underscores".
- [x] Hex integer (`0xFF`) — "lexer: hex integer prefix".
- [x] Octal integer (`0o77`) — "lexer: octal integer prefix".
- [x] Binary integer (`0b1010`) — "lexer: binary integer prefix".
- [x] Float decimal (`3.14`) — "lexer: float literal decimal".
- [x] Float exponent (`1.0e10`, `1e10`) — "lexer: float literal exponent".
- [x] Bool literals (`true`, `false`) — "lexer: true/false/null/undefined
  as keywords" and "parser: bool literal".
- [x] `null` literal — same lexer test.
- [x] `undefined` literal — same lexer test.
- [x] Char literal (`'a'`) — "lexer: char literal simple";
  `src/parser/primary.zig` surfaces `Expr.char_lit`.
- [x] Char escape (`'\n'`) — "lexer: char literal escape".
- [x] Byte string literal (`b"..."`) — "lexer: byte string literal";
  `Expr.byte_string_lit` AST.
- [x] String literal (`"..."`) — `Expr.string_lit` AST; preserved
  verbatim by codegen.
- [x] Tuple literal (`(a, b)`) — "parser: tuple literal";
  codegen emits `.{ a, b }` (anonymous-struct).
- [x] Tuple mixed types (`(1, 2.5, true)`) — "codegen: tuple emits
  anonymous struct".
- [x] Empty tuple (`()`) — "parser: empty tuple" + "codegen: tuple
  emits anonymous struct" (the `= {};` branch).
- [x] Single-element tuple (`(42,)`) — trailing-comma disambiguator
  via `parser/primary.zig`; pinned by "parser: (42,) routes to
  single_tuple_lit" and "codegen: single_tuple_lit emits .{ EXPR }".
- [x] Named-field tuple (`(x: 10, y: 20)`) — "parser: (x: 10, y: 20)
  routes to named_tuple_lit" + codegen mirror.
- [x] Array explicit list (`[3]i32 { 1, 2, 3 }`) — "parser: array
  lit explicit" + "codegen: array explicit emits [N]T{...}".
- [x] Array fill mode (`[5]i32 { 0 ... }`) — "parser: array lit
  fill" + "codegen: array fill emits [1]T{...}**N".
- [x] Array progression mode (`[4]i32 { 1, 2 ... }`) — "parser:
  array lit progression" + "codegen: array progression emits
  blk+__pat pattern".
- [x] Ident-sized arrays (`[N]T {...}`) — `parser/primary.zig`'s
  identifier-size branch + codegen prefer `size_text`. Pinned by
  `examples/generics/generic_fun.zag`'s `[N]T { val ... }`.

## 04. Variables ([manual/04-variables.md](../manual/04-variables.md))

- [x] `let` immutable binding — "parser: let with type annotation".
- [x] `let` without annotation (literal-typed inference) —
  "parser: let without type annotation". The
  `isLiteralInit` carve-out accepts int/float/bool/char/string/
  byte_string/null/undefined/tuple/array/template/struct/tuple/
  named-tuple/closure literals.
- [x] `var` mutable binding — "parser: var with type annotation".
- [x] `var` without annotation — "parser: var without type annotation".
- [x] `const` compile-time binding — "parser: const with type
  annotation" + "codegen: const emits zig const".
- [x] Bare reassignment (`y = expr;`) — "parser: bare assignment is
  recognised as .assign" + "codegen: bare assignment emits
  `name = expr;`".
- [x] Compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`,
  `|=`, `^=`, `<<=`, `>>=`) — `src/parser/stmt.zig:compoundOpForTag`
  + codegen desugar via `x = x OP rhs`. Pinned by
  "codegen: var + assign sequence end-to-end".
- [x] Tuple destructuring (`let (a, b) = (1, 2)`) — "parser: tuple
  destructuring" + "codegen: tuple destructuring emits temp +
  per-leaf".
- [x] Array destructuring (`let [a, b, c] = arr`) — "parser: array
  destructuring" + "codegen: array destructuring emits temp +
  per-leaf indexed".
- [x] Wildcard leaves (`let (_, y, _) = ...`) — "parser:
  destructuring with wildcard discard" + "codegen: wildcard
  leaves skip emission".
- [x] Rest binding (`let (first, ...rest) = ...`) — "parser:
  (first, ...rest) produces BindingPattern.rest with before_count"
  + "codegen: rest-binding materializes leftover elements via
  temp index".
- [x] Array rest binding (`let [a, ...rest] = [...]`) — pinned
  by "parser: array [a, ...rest]" + "codegen: array rest-binding".
- [x] Nested destructuring (`let (a, (b, c)) = (...)`) — pinned
  by parser + codegen nested tests.
- [x] Nested rest binding (`let (a, (b, ...ir)) = ...`) — pinned
  by "parser: nested (a, (b, ...ir))" + "codegen: nested
  rest-binding emits __destruct_0[1][1..2]".
- [x] Runtime-RHS rest binding (slice form `__destruct_0[1..]`) —
  pinned by "codegen: runtime RHS rest emits slice form".

## 05. Operators ([manual/05-operators.md](../manual/05-operators.md))

- [x] Addition (`a + b`) — codegen emits `(a + b)`.
- [x] Subtraction (`a - b`) — codegen emits `(a - b)`.
- [x] Multiplication (`a * b`) — codegen emits `(a * b)`.
- [x] Division (`a / b`) — codegen shims runtime-int cases through
  `@divTrunc` (pinned by "codegen: x/2 emits @divTrunc shim").
  Float cases stay bare (pinned by codegen float tests).
- [x] Modulo (`a % b`) — `@rem` shim symmetric to `div`.
- [x] Bitwise AND (`a & b`) — `Expr.BinaryOp.bitand`.
- [x] Bitwise OR (`a | b`) — `BinaryOp.bitor`.
- [x] Bitwise XOR (`a ^ b`) — `BinaryOp.bitxor`.
- [x] Bitwise NOT (`~x`) — `UnaryOp.bnot`. Codegen emits `~x`.
- [x] Shift left (`a << b`) — `BinaryOp.shl`.
- [x] Shift right (`a >> b`) — `BinaryOp.shr`.
- [x] Negation (`-x`) — `UnaryOp.neg`. Codegen emits `-x`.
- [x] Equality (`a == b`) — `BinaryOp.eq`.
- [x] Inequality (`a != b`) — `BinaryOp.ne`.
- [x] Less than (`a < b`) — `BinaryOp.lt`. Parser rejects chained
  `a < b < c` (pinned by parser error path).
- [x] Greater than (`a > b`) — `BinaryOp.gt`. Chaining rejected.
- [x] Less or equal (`a <= b`) — `BinaryOp.le`.
- [x] Greater or equal (`a >= b`) — `BinaryOp.ge`.
- [x] Logical AND (`a && b`) — `BinaryOp.land`. Emits zig `and`.
- [x] Logical OR (`a || b`) — `BinaryOp.lor`. Emits zig `or`.
- [x] Logical NOT (`!x`) — `UnaryOp.lnot`. Emits zig `!`.
- [x] Precedence (`*` binds tighter than `+`) — pinned by parser
  + codegen tests "precedence — mul binds tighter than add" and
  "precedenced arithmetic emits nested parens".
- [x] Parenthesised override — "parser: precedence — parens override".
- [x] Left-associative chain — "parser: left-associative chain".

## 06. Control flow ([manual/06-control-flow.md](../manual/06-control-flow.md))

- [x] `if` statement form — "parser: if-stmt parses as Stmt.if_stmt".
- [x] `if` / `else` statement form — "parser: if-stmt with else-if
  chain walks nested if_kind" (else body shape).
- [x] Chained `else if … else if … else` — pinned by "parser:
  if-stmt with else-if chain" + "codegen: if-stmt with else-if
  chain emits chained zig emission".
- [x] `if` expression form (`let z: i32 = if ... { ... } else { ... }`) —
  "parser: if-expression parses as Expr.if_expr (RHS of let)" +
  "codegen: if-expression emits labeled blk + break :blk".
- [x] `while` plain form — "parser: while-stmt parses as
  Stmt.while_stmt" + "codegen: while-stmt emits zig while verbatim".
- [ ] `while let` pattern form — deferred (see [manual/06-control-flow.md](../manual/06-control-flow.md));
  needs enum-variant-pattern surface expansion that lives in the
  v2 enum/union taxonomy rework.
- [x] `for i in 0..10` half-open range — "parser: for-range
  parses as Stmt.for_stmt" + "codegen: for-range emits zig
  start..end[+1]".
- [x] `for i in 0...10` inclusive range — "parser: for-incl
  range sets inclusive flag" + "codegen: for-incl range emits
  end+1".
- [x] `for x in expr()` non-range iter — "parser: for-iter
  non-range parses" + "codegen: for-iter non-range emits verbatim
  iter call".
- [x] `for _ in 0..3` wildcard pattern — pinned by parser
  `Pat.discard` path (codegen defaults to `|_|`).
- [ ] `for (k, v) in map` tuple destructuring — needs tuple-pattern
  walker for `for`; deferred per docs/06.
- [x] `match` on literals — "parser: match-stmt with literal arms
  parses as Stmt.match_stmt" + "codegen: match-stmt emits labeled
  laddered if-else".
- [x] `match` on ranges (`0..10`) — "parser: match-stmt with
  range arm and guard" + "codegen: match-stmt with range arm emits
  bounds check".
- [x] `match` on ident (`x => x + 1`) — "parser: match-stmt with
  ident-pattern arm binds name" + "codegen: match-stmt identifies
  ident arm emits const binding".
- [x] `match` on wildcard (`_ => ...`) — pinned across match tests.
- [x] `match` arm guards (`pat if cond =>`) — pinned via arm
  `guard` field on both parser and codegen sides.
- [x] Exhaustive match with wildcard final arm — pinned by
  "codegen: match-stmt with non-wildcard last emits else unreachable;"
  (per-arm tail stays bare when `_` is last).
- [x] Wildcard fallback omission — pinned by "codegen: match-stmt
  with non-wildcard LAST arm emits ';' + unreachable fallback"
  (autopopulated `else unreachable` when no `_`).
- [x] `break;` innermost-loop exit — "parser: break-stmt parses
  as Stmt.break_stmt" + "codegen: break-stmt emits zig break;".
- [x] `continue;` innermost-loop skip — "parser: continue-stmt
  parses as Stmt.continue_stmt" + codegen mirror.
- [x] `return expr;` value form — pinned across parser/codegen
  return tests.
- [x] `return;` bare form — "parser: bare return parses as
  Stmt.return_stmt with null value" + "codegen: bare return
  emits `return;`".

## 07. Types ([manual/07-types.md](../manual/07-types.md))

- [x] Transparent type alias for `str` → `[]const u8` —
  `src/codegen/decl.zig:zagTypeToZig` resolves at every AST
  type-bearing emit site. Pinned by 9 alias-resolution tests in
  `src/tests/codegen.zig` (closure params + return, `as` cast,
  `new` allocator, `<const>` const-generic, turbofish type-arg,
  struct field, enum payload, simple binding, const-block
  binding).
- [ ] User-defined type aliases (`type Foo = Bar;`) — parser
  doesn't accept the `type` keyword; deferred.
- [ ] Numeric type aliases (`type MyInt = i64`) — same; deferred.

## 08. Primitives ([manual/08-primitives.md](../manual/08-primitives.md))

- [x] Signed integers (`i8`, `i16`, `i32`, `i64`) — pass through
  as `type_text`; zig native.
- [x] Unsigned integers (`u8`, `u16`, `u32`, `u64`) — pass through.
- [x] Floats (`f16`, `f32`, `f64`) — pass through. `isFloatIdentType`
  used to skip integer shim on float-typed bindings.
- [x] `bool` — pass through.
- [x] `char`/`u8` — char-literal `Expr.char_lit`.
- [x] `str` (= `[]const u8`) — alias-resolution pin (see §07
  above).
- [x] `?T` nullable — `Expr.cast.type_text` carries `?T`
  verbatim; codegen emits `@as(?T, expr)`.
- [x] Raw pointers (`*raw T`) — emitted verbatim via
  `collectCastType`.

## 09. Pointers ([manual/09-pointers.md](../manual/09-pointers.md))

- [x] Address-of (`&x`) — `parser/expr.zig:parseUnary.addr` +
  codegen emits `&x`. Pinned by "codegen: address-of `&x` emits
  zig `&x`".
- [x] Deref (`*p`) — `UnaryOp.deref`. Codegen emits `p.*`
  (caret-shim form `(&p).*` only for the `.deref` Expr arm,
  see codegen expr.zig).
- [x] Destructuring deref write (`*p_mut = 42`) — exercised via
  `examples/memory/pointers.zag`.
- [x] Half-open slice (`arr[1..3]`) — "parser: slicing `arr[1..3]`
  produces Expr.slice with explicit bounds" + "codegen: half-open
  slice `arr[1..3]` emits `arr[1..3]`".
- [x] Inclusive slice (`arr[1...3]`) — emit form `arr[1..3 + 1]`.
  Pinned by "codegen: inclusive slice `arr[1...3]` emits
  `arr[1..3 + 1]`".
- [x] No-bound full slice (`arr[..]`) — pinned by codegen +
  parser tests.
- [x] Start-only slice (`arr[2..]`) — pinned by "codegen:
  `arr[2..]` slice emits verbatim".
- [x] End-only slice (`arr[..3]`) — pinned by "codegen:
  `arr[..3]` slice emits verbatim".
- [x] Nullable pointer (`?*T` / `?i32`) — codegen tests
  `[]const u8` and `?*T` round-trip in let binding.
- [x] Slicing on slices (re-slice a slice) — chained `.slice`
  via postfix loop.
- [x] Const pointer binding (`let p: *const i32 = &ro;`) —
  exercised via `examples/memory/pointers.zag`.

## 10. Arrays and slices ([manual/10-arrays-and-slices.md](../manual/10-arrays-and-slices.md))

- [x] Single-dim array literal — see §03 array literals.
- [x] Multi-dim array literal (`[3][3]i32 {...}`) — exercised by
  `examples/arrays/multi_dim.zag`.
- [x] Single-dim slice via `arr[a..b]` — see §09.
- [x] `arr.len` on arrays and slices — `examples/arrays/multi_dim.zag`
  prints `numbers.len = 5` and `matrix.len = 3`.
- [x] Fill / progression modes — see §03.
- [x] Slice indexing via `slice[i]` — exercised in
  `examples/memory/pointers.zag`.
- [x] Index assignment (`scratch[0] = 11`) — pinned by
  `Stmt.index_assign` AST + codegen tests.

## 11. Strings ([manual/11-strings.md](../manual/11-strings.md))

- [x] `str` borrowed view alias — see §07.
- [x] Plain string literal interpolation `{name}` — "parser:
  string with braces becomes template_lit" + codegen mirror.
- [x] Format spec interpolation (`{PI:.5}`) — "parser: format
  spec preserved on interpolation" + "codegen: format spec
  emitted in placeholder". The matching-brace gate in
  `src/parser/primary.zig:looksLikeTemplateLiteral` accepts the
  `.` char inside the braces.
- [x] Width spec (`{n:5}`) — "codegen: integer width spec flows through".
  Coverage: `examples/basics/strings.zag` (`print("n = |{n:5}|\n")` +
  `{m:5}`). Compiles to valid zig `{any:5}`.
- [x] Expression content in interpolation (`{a + b}`, `{obj.f()}`) —
  matching-brace gate accepts dots, spaces, operators, and parens
  inside `{...}`; buildTemplate stores the inner text as `.ident`
  and codegen's `.ident` arm emits it verbatim at the format-arg
  site. Pinned by "parser: expression operator {a + b} gate
  accepts spaces and plus" + "parser: method call {obj.f()} gate
  accepts dot and parens inside braces" + "parser: float precision
  {pi:.5} gate accepts dot inside braces".
- [x] Gate rejects nested-brace strings (function bodies, JSON
  objects, etc.) — pinned by "parser: nested-brace string stays
  string_lit (embedded-code case)".
  Coverage: `examples/basics/strings.zag` (`print("n = |{n:5}|\n")` +
  `{m:5}`). Compiles to valid zig `{any:5}`.
- [x] Embedded LF/CR/Tab escapes preserved — "codegen: template
  preserves LF byte in literal via \\n escape".
- [x] Multipart template literal — codegen emits single
  `{any}` per interpolation; pinned by "multi-arg
  interpolation" test.
- [x] Empty-key interpolation refresher — same shape as
  single-placeholder.
- [x] Byte string storage (`b"..."`) — `Expr.byte_string_lit` AST
  + codegen emits verbatim.

## 12. Structs ([manual/12-structs.md](../manual/12-structs.md))

- [x] Named-field struct decl (`struct Vec3 { x: f64, y: f64, z: f64 }`) —
  "parser: struct decl produces StructDecl with named fields".
- [x] Embed-form field (`struct Button { Widget, label: String }`) —
  "parser: struct decl accepts embed-form field". Codegen
  promotes via `<embed>: <embed> = .{},` (indirection form
  per docs/12; strict-forward-promotion deferred).
- [x] Empty fields (`struct Foo {}`) — implicit
  (`fields.len == 0` ⇒ emit empty struct body).
- [x] Struct literal (`Vec3 { x: 1.0, y: 2.0, z: 3.0 }`) —
  "parser: struct-literal produces Expr.struct_lit" + "codegen:
  struct-literal emits Vec3{ .f = v } form".
- [x] Field read (`v.x`) — "parser: postfix dot chain produces
  member_access" + "codegen: member_access emits target.name
  verbatim".
- [x] Field write (`v.x = 10.0;`) — "parser: parseFieldAssign
  triggers on name.field = value" + "codegen: field_assign emits
  target.field = value;".
- [x] Method call (`v.length()`) — "parser: postfix dot chain
  produces method_call" + "codegen: method_call emits
  target.name(args) verbatim".
- [x] Type-static constructor (`Vec3.new(1.0, 2.0, 3.0)`) —
  same parser/codegen path; verified by
  `examples/structs/vec3.zag`.
- [x] Method nested in struct decl — "codegen: impl method
  nests pub fn inside struct decl".
- [x] `self: *const T` receiver — "parser: impl block produces
  ImplBlock with methods" (is_self discrimination).
- [x] Constructor without `self` (`Vec3.new(...)`) — same test.
- [x] Field visibility private-by-default — privacy enforcement
  deferred (codegen-side `pub fn` always emitted regardless of
  source `pub`); no enforcement gate today.

## 13. Enums ([manual/13-enums.md](../manual/13-enums.md))

- [x] Bare enum decl (`enum Direction { North, South, East, West }`) —
  "parser: bare enum decl with single variant" + "codegen: bare
  enum decl emits pub const NAME = enum { ... }".
- [x] Multi-bare-variant enum — "parser: enum decl with multiple
  bare variants".
- [x] Single-arg payload enum (`enum Shape { Circle(f64) }`) —
  "parser: enum decl with single-arg payload" + "codegen: payload
  enum decl emits union(enum)".
- [x] Multi-arg payload enum (`enum R { Pair(i32, f64) }`) —
  "parser: enum decl with multi-arg payload joined verbatim".
- [x] Qualified variant ctor (`Direction.North`) — "parser:
  qualified enum-variant-ctor expression with no args" +
  codegen mirror.
- [x] Qualified payload variant ctor (`Shape.Circle(2.5)`) —
  "parser: qualified enum-variant-ctor with payload args" +
  codegen mirror emits `Shape{ .Circle = 2.5 }` (zig
  tagged-union-init form).
- [x] Match on bare variant (`Direction.North => ...`) —
  parser emits `enum_variant` pattern; codegen emits
  `__m == .North` zig form.
- [x] Match on payload variant with binding (`Some(x) => x`) —
  "parser: enum-variant pattern with bindings" + codegen mirror.
- [x] Catch-all match (`_ => ...`) — pinned across match tests.
- [ ] **Backed enums `enum(T)`** (`enum(str) Level { Low = "low" }`) —
  the docs surface (docs/13 + specs) is captured in
  `README.md`-aligned docs but PARSER/CODegen don't yet accept the
  `enum(T)` syntax or synthesise tagged-equality operators.
  Deferred to the v2.1 enum/union pass.
- [ ] Synthesised operations on backed enums (`__eq__` value-based,
  `from_str` for `T = str`, `Display::write`) — same phase.

## 14. Unions ([manual/14-unions.md](../manual/14-unions.md))

- [ ] **`union` keyword for tagged unions** — the v1 compiler
  parses both bare enumerations and payload-bearing tagged unions
  via the `enum` keyword. v2 splits the surface: `union` becomes
  the keyword for tagged unions (variants may carry payloads,
  be bare, or mix), `enum` becomes bare-only. The current parser
  does NOT accept `union X { ... }`; payload-bearing shapes are
  still authored under `enum X { ... }`. The migration map is
  documented but the parser doesn't yet dispatch on `union_kw`.
  Awaiting the v2 enum/union parser pass.
- [x] Mixed bare + payload variants via `enum` keyword — `enum Mixed
  { Bare, Payloaded(f64), Other(Bare2) }` parses and codegens to
  zig's `union(enum)` shape. The source-side surface works today
  via `enum`'s broadened payload support; `parseEnumDecl`'s
  `lparen` peek handles each variant's payload verbatim
  (single-arg vs multi-arg routed via comma-count). Only the
  union-keyword migration is deferred (the bullet above this one)
  — `enum` continues to accept both shapes until v2 lands the
  `union` keyword.
- [ ] `#[repr(C, T)] union` FFI repr — docs/14 §"FFI"; parser
  doesn't currently accept `#[repr]` attribute syntax (only
  attribute-skipped on `#[ ... ]` for derive-style; see lexer).
- [ ] `= N` discriminant pinning — parser doesn't record a fixed
  numeric discriminant (documentation describes the runtime ADT
  contract for distinct unassigned variants; codegen emits zig's
  union(enum) form which auto-assigns).

## 15. Functions ([manual/15-functions.md](../manual/15-functions.md))

- [x] Full-signature decl (`fun add(a: i32, b: i32) -> i32`) —
  "parser: fun NAME(params) -> RET_TYPE captures full signature"
  + "codegen: full signature emits pub fn NAME(p: T, ...) RET_TYPE".
- [x] Void return type — "codegen: void fun emits pub fn NAME(...)
  void".
- [x] Inferred void (no arrow) — codegen falls through to `void`.
- [x] Multi-arg form — pinned by `examples/functions/basic.zag`.
- [x] `var` parameter semantics — "codegen: var param injection
  emits var x = x; at body entry" + `examples/functions/basic.zag`.
- [ ] **Variadic params** (`fun sum(values: i32...) -> i32`) —
  parser sets `is_variadic=true` ("parser: variadic ... suffix
  sets is_variadic flag") but codegen does NOT slice the args
  on the zig side; the parameter still emits at its declared
  type. Deferred to a Phase-3 codegen followup.
- [ ] **Default-value params** (`fun connect(host: str, port: u16 = 8080)`) —
  parser sets `default_value` ("parser: default value = expr
  captures default_value") but codegen does NOT shape the
  call-site thunk (`@callOptional`-shaped emission).
  Deferred (also needs a type-resolver for arg-count validation).
- [x] `pub` visibility keyword — accepted-and-ignored at parse
  time on top-level decls + impl methods.
- [x] Documented function (`## adds\nfun add() {}`) — `doc`
  field on `FunDecl` populated + emitted as zig `/// ` by
  codegen.
- [x] Closures (`|x: i32| -> i32 { return x * 2; }`) — "parser:
  closure expression |x:T|->T{} produces Expr.closure" +
  "codegen: closure emit shapes anonymous struct with call
  method".
- [x] Closure call rewrite (`double(5)` → `double.call(5)`) —
  "codegen: closure-typed call site rewrites double(5) to
  double.call(5)" + "codegen: unannotated closure binding still
  rewrites call to .call(...)".
- [x] Empty-params closure (`|| { ... }`) — codegen accepts the
  empty `params` slice.

## 16. Generics ([manual/16-generics.md](../manual/16-generics.md))

- [x] Generic function decl (`fun max<T: Ordered>(a: T, b: T) -> T`) —
  parser threads `parseTypeParam` + the `<T>` decl-side preamble
  in `genTypeParamsPreamble`.
- [x] Generic turbofish call site (`max<i32>(3, 5)`) — "parser:
  The first `<T>` introduces…" (no separate test, full decision
  unit on parser primary.zig) + "codegen: turbofish arguments
  emitted before runtime args".
- [x] Single turbofish slot + multi turbofish slot — `name<T>(...)
  + name<T, U>(...)`. Pinned by `examples/generics/generic_fun.zag`.
  `<T: Default>`, `<T: Zero>`, `<T: Display>`, `<T: Iterator>`,
  `<T: AsyncStream>`) — codegen emits `@hasDecl` runtime guard
  per bound via `boundToMethodName` map. Runs
  `examples/generics/generic_fun.zag`'s `max<f64>(1.5, 2.5)`.
- [x] Const-generic params (`<const N: usize>`) — codegen emits
  `comptime N: usize` preamble. Verified by
  `examples/generics/generic_fun.zag`'s `fill<i32, 4>(0)`.
- [x] Const-generic + array-size annotation (`[N]T`) — pinned by
  followup that closed the parse-time bracket-ident hole in
  `collectCastType`.
- [x] Generic struct thunk form (`struct List<T> { ... }`) —
  codegen emits `pub fn List(comptime T: type) type { return
  struct { ... }; }`. Verified via the orphan-impl routing
  in `generate()` (skipped nesting → free-fn emission).
- [x] Generic struct impl-method (`impl<T> List<T> { pub fun
  List_T_push(self: *List(T), value: T) void { ... } }`) —
  codegen emits rewritten receiver via `rewriteReceiverType`.

- [ ] Generic struct **nested methods** (`pub fn inside thunk`)
  — deferred because the returned struct type cannot host
  methods directly (zig compiles each monomorphization to a
  fresh anonymous type). Packages ship via orphan-impl routing
  today.
- [ ] Generic enum nested methods — same reason; deferred.
- [x] **Block-form const eval** (`const MAX: i32 = const { ...
  return EXPR; };`) — parser dedents `= const { … }` on
  `.const_binding` (see `parser/stmt.zig:parseBinding`'s
  dispatch `kind == .const_binding AND peek == .equals AND
  peekAhead(1) == .const_kw`) and codegen emits
  `const NAME: T = blk: { ...stmts...; break :blk EXPR; };` via
  `genBinding`'s block-form path. Pinned by
  `src/tests/codegen.zig` "codegen: block-form const
  `const x: str = const { ... }` expands `: str` to `: []const u8`"
  — covered end-to-end.
- [ ] **Compile-time type parameters** (`const T: type = ...` carrying
  the resolved type for compile-time use elsewhere) — parser's
  block form stores the body, but full docs/16 §6 semantics (using
  the resolved type as a Type elsewhere in source) are not
  test-covered. Deferred until the block-form codegen surface is
  exercised at compile-time-typ sites (e.g. binding another
  binding's type annotation to the const-block result).
- [ ] Compile-time type parameters (`const T = ...` carrying the
  resolved type rather than a value) — parser's compile-time
  block form stores the block, but full docs/16 §6 semantics
  (compile-time `const T: type = ...`, used as a type elsewhere)
  are not fully test-covered.

## 17. Traits ([manual/17-traits.md](../manual/17-traits.md))

- [x] Trait declaration (`trait Drawable { fun draw(self: *Self); }`) —
  `parseTraitDecl` + `Prog.traits` slice. "parser: trait decl
  records name + methods on Program.traits".
- [x] Required-only trait methods (`body == null`) — "parser:
  trait method captures required-only signature with null body".
  Parser REJECTS default-method bodies (the `expected '{ body
  }'` error path enforces it).
- [x] Self type-annotation (`self: *Self`) — captured verbatim
  via `MethodParam.type_text` (`*Self` captured as a string).
  No `.self_kw` TokenTag exists; the rewrite is at codegen time.
- [x] Trait return-type annotation (`fun name(self: *Self) -> str`) —
  "parser: trait method captures…return_type".
- [x] Impl-block `Trait.method`-qualified method (`pub fun
  Drawable.draw(self: *Button) { ... }`) — "parser: Trait.method-
  prefixed impl method sets MethodDecl.trait_name".
- [x] VTable registration per (trait, target_type) — codegen
  emits `<Trait>_VTable_for_<Type>: <Trait>.VTable = .{ ... };`
  via `src/codegen/decl.zig:genTraitRegistration`. Verified by
  Phase 2 trait-orphan free-fn emission.
- [x] VTable struct with function-pointer slots — codegen emits
  `<Trait>.VTable` per trait decl.
- [x] Dispatch shim (`<Trait>._<Method>` with `comptime T: type`,
  `_ = T;`, `return self.vtable.<method>(self.ptr, ...)`) —
  emitted by `genTraitDecl`.
- [x] Trait-cast expression (`x as Trait`) — codegen
  `genExpr .cast` isTrackedTrait branch emits fat-pointer
  container `{ .ptr = ..., .vtable = &<Trait>_VTable_for_<T> }`.
- [x] Method-call turbofish at trait dispatch (`d.draw<Button>()`) —
  codegen `genExpr .method_call` accepts `type_args` slice
  (routed through `parseTurbofishArgs`).
- [ ] Default-method bodies — parser explicitly rejects:
  "error: trait method ... is REQUIRED-only in v1 minimum subset;
  default-method bodies are deferred".
- [ ] Trait inheritance / composition (`trait Foo: Bar`) —
  parser doesn't accept; deferred.
- [ ] Trait impl on trait (`impl<T> Trait<T> for OtherType`) —
  deferred; current impl form is `<Type>` only.

## 18. Error handling ([manual/18-error-handling.md](../manual/18-error-handling.md))

- [x] `Result<T, E>` type — exercised via matching pattern:
  `examples/error-handling/result.zag` uses `Ok(...)`/`Err(...)`
  unqualified ctors. (The actual `union Result<T, E> { Ok(T),
  Err(E) }` decl lives in stdlib, not in this project's bootstrap.)
- [x] `Option<T>` type — `Some(...)`/`None` ctors exercised by
  same example.
- [x] `?`-propagation on `Result<T, E>` (`return err?`) — examples
  use `compute_a()?` form. The compiler-side shim is just "emit
  `?` verbatim on a Result value"; zig 0.16's `?` propagates
  errors of the inferred error-set.
- [x] `?`-propagation on `Option<T>` (`return maybe_ptr?`) — same
  wiring (zig accepts `?T` propagating on `?`-typed bindings).
- [x] `catch |err| { ... }` block on errors — pinned by docs
  examples (codegen emits the trailing block verbatim).
- [x] Match-on-error exhaustivity — pinned by "match on enum
  unit → exhaustive" tests.
- [ ] Custom error union type with bare + payload variants
  (`union MyError { Io, Permission, Custom(msg: str) }`) —
  requires the `union` keyword; same Phase as §14.
- [ ] `?`-propagation into `catch`-block (`try` sugar that branches
  on error) — docs surface; codegen-side surface is mostly zig
  passthrough.
- [x] Stdlib declarations — out of bootstrap scope; types are
  implicitly available in user code (the parser is not gated on
  builtins).

## 19. Memory ([manual/19-memory.md](../manual/19-memory.md))

- [x] New heap alloc (`let p = new i32(42)`) — "codegen: new T(v)
  emits page_allocator.create heap alloc (bug fix)" + parser
  AST pin.
- [x] Free heap alloc (`free(p)`) — codegen emits
  `std.heap.page_allocator.destroy(p)`; pinned by same test.
- [x] Arena allocation sugar (`new(<arena>, T(v))`) — "parser:
  new(<alloc>, T(v)) sugar sets allocator field" + "codegen:
  new(<arena>, T(v)) emits <arena>.create(T) (allocator sugar)".
- [x] `defer` statement — codegen emits `defer expr;` verbatim.
  Pinned by alloc test + `examples/memory/allocation.zag`.
- [x] `errdefer` statement — "parser: errdefer parses as
  Stmt.errdefer_stmt" + "codegen: errdefer stmt emits errdefer
  verbatim".
- [x] Multiple `defer` (reverse-order execution) — pinned via
  `examples/memory/allocation.zag`.
- [x] `unsafe { ... }` audit block — "parser: unsafe { } parses
  as Stmt.unsafe_block" + "codegen: unsafe block emits body in
  plain block with comment markers".
- [x] `as` cast (`expr as T`) — "parser: x as Type parses as
  Expr.cast" + "codegen: as cast emits @as builtin".
- [x] Multi-token `as` cast dest (`x as *raw c_void`) — "parser:
  p as *raw c_void captures multi-token type".
- [x] `Arena.new()` (deferred + lifecycle) — exercised via
  `examples/memory/arena.zag` (codegen accepts the API call
  shape relying on zig's std); the actual allocator type lives
  in stdlib.
- [ ] Lifetime / ownership check — described in docs/19 + specs as
  gated by `-Dasync-ref-check` and friends. Not implemented.

## 20. Defer ([manual/20-defer.md](../manual/20-defer.md))

See §19 for full defer / errdefer coverage; this chapter documents
the same surface with stress on stack-guard interactions.

- [x] `defer expr;` block-scoped cleanup — see §19.
- [x] `errdefer expr;` error-path-only cleanup — see §19.
- [x] Multiple stacked defers (LIFO) — see §19.

## 21. Concurrency ([manual/21-concurrency.md](../manual/21-conions.md))

- [ ] `async fun` declaration — no `.async_kw` TokenTag;
  parser REJECTS `async fun`.
- [ ] `await expr` — no `.await_kw` TokenTag.
- [ ] `task.spawn_blocking` — no parser/codegen surface.
- [ ] `CancellationToken` — no parser/codegen surface.
- [ ] `task.scope` (structured concurrency) — no parser/codegen
  surface.
- [ ] `for await` — no parser/codegen surface.
- [ ] `Promise<T>` / `Future<T>` types — no parser/codegen
  surface. (Note: docs/21 §\"Async trait methods\" describes the
  future trait-binding via trait-cast — that surface lives in
  §17's trait-cast, but the `Task`/`Future` stdlib types are
  not in this bootstrap.)

`examples/concurrency/async_basic.zag` is therefore not expected to
compile on the v1 surface — keep it as a forward-looking fixture.

## 22. Modules ([manual/22-modules.md](../manual/22-modules.md))

- [ ] `mod foo {}` module declaration — parser doesn't accept.
- [ ] `use foo::bar` import — no parser surface.
- [ ] `pub use` re-export — no parser surface.
- [ ] Module-path aliases (`use foo as f`) — no parser surface.
- [ ] Conditional compilation (`#[cfg(...)]`) — lexer strips
  `#[ ... ]` attributes wholesale (`src/lexer/core.zig`) without
  honouring marker carrying through to AST/codegen. Derive-style
  is therefore currently a no-op.

## 23. SIMD ([manual/23-simd.md](../manual/23-simd.md))

- [ ] Vector types (`[N]i32`, `[N][N]f32`) — multi-dim arrays
  exist as fixed arrays, but the docs/23 SIMD vector/reduction
  surface isn't separately implemented; codegen emits the
  array-literal form and lets zig's vector lowering handle
  the typed-array interpretation.
- [ ] `simd_add`, `simd_dot`, `simd_reduce_sum` intrinsic calls —
  no parser keyword.
- [ ] Vector swizzling/swizzle ops — no surface.

## 24. FFI ([manual/24-ffi.md](../manual/24-ffi.md))

- [ ] `#[repr(C, T)]` attribute on struct/enum/union — lexer
  skips `#[...]` attributes wholesale. The reflection
  (struct emitted, repr-side coercion) is therefore not gated.
- [ ] `extern "C" fun foo(...)` — no parser surface.
- [ ] `extern "C" struct Foo { ... }` — no parser surface.
- [ ] FFI variadic args (`fun printf(fmt: [*:0]const u8, ...)`) —
  no parser surface.
- [ ] `c_int`, `c_long`, `c_void`, `*raw T` raw-pointer FFI
  surface — emitted verbatim through `collectCastType` so
  user-written `*raw c_void` round-trips, but no synthesized
  headers / type aliases are present.
- [ ] `#[link(...)], #[link_name(...)]` link directives — no
  parser surface.

## 25. Testing ([manual/25-testing.md](../manual/25-testing.md))

- [x] `test "name" { ... }` block (internal `src/tests/*.zig`) —
  covered by src/tests.zig-side count of test blocks; user-
  authored `.zag` test runners are not present.
- [x] `zig build test` invocation — `src/tests.zig` is the test
  root wired into `build.zig`'s `b.addTest`.
- [x] `-Dasync-ref-check`, `-Dbounds-check`, etc. flag pins in
  docs/25 — flagged but not all wired; only the manual's
  example-pinned ones have build options (`-Dasync-ref-check`,
  `-Dbounds-check`, `-Dunsafe-block-check`).
- [ ] User-facing `.zag` test blocks — `test "..."; ...` source-
  level construct (separate from the unit-tests-binary) is deferred.
- [ ] `assert` keyword — no parser surface (zig's `std.debug.assert`
  is the canonical test escape, but no zig-side alias shipped).

## 26. Compile-time evaluation ([manual/26-compile-time.md](../manual/26-compile-time.md))

- [ ] `comptime` keyword — no parser surface.
- [ ] `comptime T: type` parameter — emitted only via the
  generics-thunk path (§16); the bare `comptime` keyword
  on a parameter is rejected.
- [ ] `comptime { ... }` block — no parser surface.
- [x] `const NAME: T = const { ... return EXPR; };` block-form
  compile-time binding — parser dedents and codegen emits the
  labeled-block form. Pinned via "codegen: block-form const
  `const x: str = const { ... }` expands `: str` to
  `: []const u8`" (single test through alias path; full
  §6 surface verification still warranted — see §16 [ ]).

## 27. Pattern matching ([manual/27-pattern-matching.md](../manual/27-pattern-matching.md))

See §06 for the match-side coverage; this chapter adds:
- [x] Pattern destructuring in `let`/`if let`/`while let` —
  partial: `let` patterns are wired (§04), but `if let` and
  `while let` are NOT. See §06 deferred notes.
- [x] Range pattern guards (`x if x > 0 =>`) — wired via
  `MatchArm.guard`.
- [x] Identifier-binding pattern (`x =>`) — wired (see §06).
- [ ] Or-patterns (`1 | 2 | 3 =>`) — no parser surface.
- [ ] At-patterns (`x @ Some(_) =>`) — no parser surface.

## 28. Methods ([manual/28-methods.md](../manual/28-methods.md))

See §12 + §17 for the bulk of `impl`-block coverage. This chapter
emphasises the OO-shape:
- [x] `impl Type { pub fun method(self, ...) }` — see §12.
- [x] Value-receiver (`self: T`) and reference-receiver
  (`self: *T` / `self: *const T`) — see §12.
- [ ] **Operator overloading** — see §30; deferred.
- [ ] **Method overloading by argument shape** — see §29; deferred.
- [x] Inherent methods + trait methods side-by-side — verified
  by parser tests showing both shape coexist in `impl` blocks.

## 29. Method overloading ([manual/29-method-overloading.md](../manual/29-method-overloading.md))

- [ ] Method-overload by argument count (`append(item: T)` vs
  `append(items: []T)`) — no parser codepath; zag's parser
  treats an `impl Type` block as a flat list of uniquely-named
  methods. Documented as a Phase 2 surface.
- [ ] Method-overload by argument type — same Phase 2 surface.
- [ ] Default arguments + overloading — see §15 [ ] for default
  args; overloading not wired.

## 30. Operator overloading ([manual/30-operator-overloading.md](../manual/30-operator-overloading.md))

- [ ] `impl Add for Vec3 { fun add(self, other) -> Vec3 }` — no
  parser/codegen surface. Slot reserved for Phase 2.
- [ ] `impl Index for Matrix { fun index(self, i: i32, j: i32) -> f64 }` —
  same; deferred.
- [ ] `impl IndexAssign`, `impl Mul`, etc. — same; deferred.

## 31. Building ([manual/31-building.md](../manual/31-building.md))

- [x] `zag run <file>.zag` — `src/main.zig:cmdRun`.
- [x] `zag check <file>.zag` — `cmdCheck`.
- [x] `zag build <file>.zag` — `cmdBuild`.
- [x] `zag init [name]` — `cmdInit` (basic hello boilerplate).
- [x] `zag version` / `zag help` — `main()`.
- [ ] `-Dasync-ref-check` flag wired in tests only (not in
  main build flag bridge): docs/25 — `src/tests/toolchain.zig`
  pins the flag, but production runtime doesn't gate on it yet.
- [x] `-Dz_install=<path>` — covered in build.zig path resolution.
- [x] `-Dzig_payload=<path>` — covered via build.zig auto-detect
  + `-Dzig_payload` override.
- [ ] `-Dbounds-check` — not wired (production runs
  zig's default optimisations).
- [ ] `-Dunsafe-block-check` — not wired.
- [x] Pipeline: zag lexer → parser → zig emitter → zig
  build-exe → run — exercised by `examples/run_all.sh`.
- [ ] CI workflow file for zag-pr-build (`.github/workflows/ci.yml`)
  — deferred.
- [ ] Cross-platform build (Linux/macOS/Windows zig-plugin matrix) —
  deferred.

---

## Cross-cutting evidence

Beyond per-chapter checks, three project-wide invariants maintain
the checklist's accuracy:

- **Parser dispatch**: every `parseXxx` in `src/parser/decl.zig`
  carries a `parseXxx` method-alias in `src/parser/core.zig`'s
  `Parser` pub-const block; every `genXxx` in `src/codegen/{expr,
  stmt, decl, primary}` is aliased the same way. New features
  MUST add both the parser method and the codegen method, plus
  a `test "feature-name"` in one of the `src/tests/X.zig` files,
  OR the box for that sub-feature must remain `[ ]`.
- **Alias resolution**: every emit site that carries a `type_text`
  routes through `src/codegen/decl.zig:zagTypeToZig`. Adding a
  new type alias requires appending to `zagTypeToZig`'s matching
  table (currently `str → []const u8`).
- **Token additions**: every new reserved keyword requires (a)
  a new TokenTag in `src/lexer/token.zig`, (b) a recognition arm
  in `src/lexer/ident.zig:readIdent`, (c) a parse-handler on the
  appropriate `Parser` method, (d) a codegen arm that emits the
  zig-side surface (often `verbatim`), and (e) a `test "..."` pin.

When you implement a new feature, change its box from `[ ]` to
`[x]` and append the test-name that pins it. If the test is
removed or moves, restore the box to `[ ]`.

When you mark something `[x]` that should be `[ ]`, treat that
as a regression and roll back the change.
