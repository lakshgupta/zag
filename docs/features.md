## 05. Operators ([manual/05-operators.md](../manual/05-operators.md))

Two runnable examples cover the surface: `examples/operators/operators.zag`
(compound / bitwise / comparison / logical / index-shape coverage) and
`examples/operators/precedence.zag` (pure-arithmetic / precedence /
parens / left-associative / range-expression). Citations are
file-name-only — line numbers go stale on every edit.

- [x] Addition (`a + b`) — codegen emits `(a + b)`. Runnable
  example: `examples/operators/precedence.zag` (pure-binary
  arithmetic block).
- [x] Subtraction (`a - b`) — codegen emits `(a - b)`. Runnable
  example: `examples/operators/precedence.zag` (pure-binary
  arithmetic block).
- [x] Multiplication (`a * b`) — codegen emits `(a * b)`. Runnable
  example: `examples/operators/precedence.zag` (pure-binary
  arithmetic block).
- [x] Division (`a / b`) — codegen shims runtime-int cases through
  `@divTrunc` (pinned by "codegen: x/2 emits @divTrunc shim").
  Float cases stay bare (pinned by codegen float tests). Runnable
  example: `examples/operators/precedence.zag` (runtime-int division
  `100 / 7` triggers the shim).
- [x] Modulo (`a % b`) — `@rem` shim symmetric to `div`. Runnable
  examples: `examples/operators/operators.zag` (`17 % 5` literal-init
  carve-out) + `examples/operators/precedence.zag` (runtime-int path).
- [x] Bitwise AND (`a & b`) — `Expr.BinaryOp.bitand`. Runnable
  example: `examples/operators/operators.zag` (`0b1100 & 0b1010`).
- [x] Bitwise OR (`a | b`) — `BinaryOp.bitor`. Runnable
  example: `examples/operators/operators.zag` (`0b1100 | 0b1010`).
- [x] Bitwise XOR (`a ^ b`) — `BinaryOp.bitxor`. Runnable
  example: `examples/operators/operators.zag` (`0b1100 ^ 0b1010`).
- [x] Bitwise NOT (`~x`) — `UnaryOp.bnot`. Codegen emits `~x`.
  Runnable example: `examples/operators/operators.zag` (`~not_source`
  — bound via a `: i32` intermediate because zig rejects `~` on
  `comptime_int` bit literals).
- [x] Shift left (`a << b`) — `BinaryOp.shl`. Runnable
  example: `examples/operators/operators.zag` (`0b0001 << 2`).
- [x] Shift right (`a >> b`) — `BinaryOp.shr`. Runnable
  example: `examples/operators/operators.zag` (`0b1000 >> 2`).
- [x] Negation (`-x`) — `UnaryOp.neg`. Codegen emits `-x`. Runnable
  example: `examples/operators/operators.zag` (unary `-m`).
- [x] Equality (`a == b`) — `BinaryOp.eq`. Runnable
  example: `examples/operators/operators.zag` (`1 + 1 == 2`).
- [x] Inequality (`a != b`) — `BinaryOp.ne`. Runnable
  example: `examples/operators/operators.zag` (`1 != 2`).
- [x] Less than (`a < b`) — `BinaryOp.lt`. Parser rejects chained
  `a < b < c` (pinned by parser error path). Runnable
  examples: `examples/operators/operators.zag` (`1 < 2`) +
  `examples/operators/precedence.zag` (chained via `&&`).
- [x] Greater than (`a > b`) — `BinaryOp.gt`. Chaining rejected.
  Runnable example: `examples/operators/operators.zag` (`2 > 1`).
- [x] Less or equal (`a <= b`) — `BinaryOp.le`. Runnable
  example: `examples/operators/operators.zag` (`1 <= 1`).
- [x] Greater or equal (`a >= b`) — `BinaryOp.ge`. Runnable
  example: `examples/operators/operators.zag` (`2 >= 1`).
- [x] Logical AND (`a && b`) — `BinaryOp.land`. Emits zig `and`.
  Runnable examples: `examples/operators/operators.zag`
  (`true && false`) + `examples/operators/precedence.zag` (chained
  via `&&`).
- [x] Logical OR (`a || b`) — `BinaryOp.lor`. Emits zig `or`.
  Runnable example: `examples/operators/operators.zag`
  (`true || false`).
- [x] Logical NOT (`!x`) — `UnaryOp.lnot`. Emits zig `!`. Runnable
  example: `examples/operators/operators.zag` (`!true`).
- [x] Precedence (`*` binds tighter than `+`) — parser/codegen
  pins via "precedence — mul binds tighter than add" +
  "precedenced arithmetic emits nested parens"; runnable
  example: `examples/operators/precedence.zag` (`1 + 2 * 3 = 7`
  proves the additive/multiplicative precedence).
- [x] Parenthesised override — "parser: precedence — parens override";
  runnable example: `examples/operators/precedence.zag`
  (`(1 + 2) * 3 = 9` proves user-written parens retarget the AST).
- [x] Left-associative chain — "parser: left-associative chain";
  runnable example: `examples/operators/precedence.zag`
  (`10 - 3 - 2 = 5` proves left-to-right same-class precedence).
- [ ] **Standalone `.range` Expr as value** (`let r = 0..10; // r
  is .{0, 10, false}`) — codegen wires the `.range` arm at
  `src/codegen/expr.zig` (emits `.{ start, end, inclusive }`)
  but the standalone-bind surface is currently exercised only
  indirectly via the for-loop iter shape in
  `examples/control-flow/for_loop.zag` (`for i in 0..5`).
  Adding a focused standalone-value test would close the gap.
  Deferred — sized as a small example addition, not a parser
  change; the codegen arm already round-trips.
- [ ] **Numeric postfix-dot** (`(0..10).0`, `(tuple).1`) —
  zag's postfix-dot parser requires `.IDENT` after `.`, not
  `.INT_LIT`, so accessing anonymous-struct positional fields
  via numeric dot is rejected with `expected identifier, got
  'X'`. The fix would widen `parser/primary.zig:parsePostfix`
  to accept integer literals in the postfix-dot arm; the
  codegen `.member_access` arm already round-trips via the
  existing `.ident`-named member access. Deferred — small
  parser carve-out, separate from the §05 precedence-shape
  audit.
- [ ] **Address-of `&x` and `as` conversion** — docs/05
  precedence table rows 1 and 2. Both have their own chapters
  (§09 Pointers for `&`, §07 Types for `as`) where the
  full surface lives; this audit doesn't duplicate the
  coverage citations.

*Note: the Index operator's basic surface (`let val = arr[i];;
arr[i] = v`) lives in §10 Arrays and Slices; the
`__index__` / `__index_set__` overloading dunder hook lives
in §30 Operator Overloading.*

## 06. Control Flow ([manual/06-control-flow.md](../manual/06-control-flow.md))

Four runnable examples cover the surface, each focusing on a
single statement family: `examples/control-flow/while_loop.zag`
(plain while + value-less `break` + `continue`),
`examples/control-flow/for_loop.zag` (range half-open +
inclusive + iter-as-call + wildcard), and
`examples/control-flow/match_expr.zag` (literal arms + range
arms + ident-pattern arm + wildcard). The mixed sampler
`examples/control-flow/if_else.zag` exercises if-else-as-
expression, for-range sum, plain while loop, and a match
expression on a single `main`. The `if let`, `while let`,
tuple-destructure `for`, value-yielding `break val;`, and
`panic(msg)` shapes mentioned in `manual/06-control-flow.md`
are deferred — see the [ ] bullets at the end of this
section for the parser/codegen carve-outs each requires.
Citations are file-name-only — line numbers go stale on
every edit.

- [x] `if / else` as statement — "codegen: plain if-stmt
  emits zig if without else" + "codegen: if-stmt with else
  emits zig if/else"; runnable coverage: every example
  in `examples/control-flow/` exercises a conditional on
  its own. The `if_else.zag` mixed sampler uses `if 1 == 1`
  as a binary-cond shape rather than a bare `if true` because
  zig 0.16 rejects the bare-cond form when the surrounding
  expression-context requires a `blk:` + `break :blk`
  wrapper (codegen rule documented on the if-expression
  surfacing per the row below).
- [x] `else if` chains — "codegen: if-stmt with else-if chain
  emits chained zig emission". Runnable coverage is
  implicit (no example targets it explicitly — the chained
  form is structurally a nested `if / else` and the codegen
  validator pins the emission shape so introducing a chain
  example would be redundant once the bullet's codegen
  test passes).
- [x] `if / else` as expression (yields a value) —
  "codegen: if-expression emits labeled blk + break :blk";
  runnable example: `examples/control-flow/if_else.zag`
  (`let x: i32 = if 1 == 1 { 1 } else { 2 };`).
- [x] `while cond { … }` — "codegen: while-stmt emits zig
  while verbatim" + "parser: while-stmt parses as
  Stmt.while_stmt". Runnable examples:
  `examples/control-flow/while_loop.zag` (`while i < 3`
  — binary cond + `var` rebind in body) + the
  `while-loop` block of `examples/control-flow/if_else.zag`
  (`while count < 3` — same shape on the mixed sampler).
- [x] `for i in 0..N` (half-open range) — "codegen: for-range
  emits zig `start..end[+1]`" + "parser: for-range parses
  as Stmt.for_stmt with RangeExpr iter". Runnable example:
  `examples/control-flow/for_loop.zag` (`for i in 0..5` —
  accumulator is `usize` because zag's `as`-cast codegen
  emits `@as(i32, usize)` which zig 0.16 rejects; see the
  §07 deferred bullet on narrow-cast codegen for the fix
  that lets the accumulator become `i32`).
- [x] `for i in 0...N` (inclusive range) — "codegen: for-incl
  range emits end+1" + "parser: for-incl range sets
  inclusive flag". Runnable example:
  `examples/control-flow/for_loop.zag` (`for _ in 0...5` —
  wildcard capture so zig doesn't flag unused `_`).
- [x] `for x in iter()` (verbatim iter call shape) —
  "codegen: for-iter non-range emits verbatim iter call" +
  "parser: for-iter non-range parses with the user
  expression as iter". No runnable example today
  exercises a non-range iter (`for x in items()` or
  `for (k, v) in map.iter()`); the for-loop examples in
  `examples/control-flow/` all use range expressions as
  the iter source, so the iter-call row's coverage is
  anchored entirely by the codegen + parser tests rather
  than a runnable example. The codegen has a distinct
  arm from the for-range row: the iter-call path emits
  `for (<expr>) |x|` verbatim from the user expression,
  while the range  path emits `for (<start>..<end>[+1]) |x|`. Both arms share the
  surrounding `for (...) |...|` frame but differ in how
  the inner iter expression is assembled. Note: the
  tuple-destructure half of the iter-call codegen arm
  (`for (k, v) in map.iter() { … }`) is captured in
  the deferred `for (k, v) in map.iter()` bullet
  lower in this section — the [x] row above + that
  [ ] row together describe the full iter-call
  codegen surface.
- [x] `for _ in 0..N` (wildcard pattern) — zig's `for (0..N)
  |_|` discards the iteration variable without binding
  it; pinned by the for-range codegen test which also
  covers wildcard. Runnable example:
  `examples/control-flow/for_loop.zag` (`for _ in 0..3` —
  body increments a `tick` counter independent of the
  captured iteration var).
- [x] `match scrutinee { LiteralArm => …, _, }` — "codegen:
  match-stmt emits labeled laddered if-else" + "parser:
  match-stmt with literal arms parses as Stmt.match_stmt".
  Runnable example: `examples/control-flow/match_expr.zag`
  (the `is_small` block: `0 => "zero"`, `1 => "one"`,
  `2 => "two"`, `_ => "other"`).
- [x] `match RangeArm` (`start..end` / `start...end` literal
  range) — "codegen: match-stmt with range arm emits
  bounds check" + "parser: match-stmt with range arm and
  guard". Runnable example:
  `examples/control-flow/match_expr.zag` (the `bucket`
  block: `0..10 => "low"`, `10..100 => "mid"`, `_ => "high"` —
  exercises both half-open and inclusive range-arm shapes).
- [x] `match IdentPattern` (`x => …` binds the scrutinee) —
  "codegen: match-stmt identifies ident arm emits const
  binding" + "parser: match-stmt with ident-pattern arm
  binds name". Runnable example:
  `examples/control-flow/match_expr.zag` (the `doubled`
  block: `x => x * 2`, `_ => 0`).
- [x] `match _ { … }` (wildcard terminal fallback) — pinned
  by every match codegen test that uses a wildcard last
  arm (the `is_small`, `bucket`, `doubled`, and `safe`
  blocks of `match_expr.zag` each terminate in `_`).
  Runnable example: `examples/control-flow/match_expr.zag`
  (the `safe` block: `3 => 99, _ => 0`).
- [x] `match.expr` (yielding a value, not just a statement) —
  "parser: match-expression parses as Expr.match_expr". The
  codegen arm for value-yielding match is shared with the
  statement arm — the `__m_<N>` scrutinee temp + labeled
  `blk:` + `break :blk` ladder is identical, the only
  difference is whether the resulting expression is bound
  or discarded. Runnable example:
  `examples/control-flow/if_else.zag` (`let label: str =
  match val { 0 => "zero", 1..9 => "digit", 42 => "the
  answer", _ => "other" };`).
- [x] `match` exhaustiveness — non-wildcard LAST arm emits
  unpinned `else unreachable;` fallback — "codegen:
  match-stmt with non-wildcard last emits `else unreachable;`"
  + "codegen: match-stmt with non-wildcard LAST arm emits
  `;}` + unreachable fallback". Documented at the type
  system level by §13 / §14; the §06 row pins the codegen
  shape (intentional non-wildcard-last is not idiomatic in
  the runnable examples — every example terminates in `_`).
- [x] `break;` (statement-only, no value) — "codegen:
  break-stmt emits zig break;" + "parser: break-stmt parses
  as Stmt.break_stmt". Runnable example:
  `examples/control-flow/while_loop.zag` (`if countdown
  == 2 { break; }`).
- [x] `continue;` — "codegen: continue-stmt emits zig
  continue;" + "parser: continue-stmt parses as
  Stmt.continue_stmt". Runnable example:
  `examples/control-flow/while_loop.zag` (`if skipped ==
  2 { continue; }`).
- [x] `return val;` (with expression payload) — "codegen:
  return-stmt with value emits `return <expr>;`" + "parser:
  return-stmt with value parses as Stmt.return_stmt with
  expr". Runnable coverage is implicit — the
  value-yielding match arms in `examples/control-flow/
  match_expr.zag` are codegen-side equivalents of `return
  val` (each arm returns its expression via `break :blk`),
  and any function returning a value exercises this row at
  codegen time. No example surfaces a user-level `return
  val;` standalone because the §06 / §04 audit doesn't
  require it — the codegen test pins the emission shape.
- [x] `return;` (bare form, equivalent to `return {};`) —
  "codegen: bare return emits `return;`" + "parser: bare
  return parses as Stmt.return_stmt with null value".
- [x] `defer expr;` (runs on every scope-exit path) — codegen
  emits `defer <expr>;` verbatim from the
  `Stmt.defer_stmt` arm at `src/codegen/stmt.zig`. No
  dedicated codegen test (`codegen: defer stmt emits
  defer verbatim`) currently pins the emission shape
  — the only explicit codegen-side defer test is the
  errdefer row below (`codegen: errdefer stmt emits
  errdefer verbatim`).  The defer emission shape is exercised incidentally by
  the `free`-family tests whose source happens to
  include `defer free(...)`; those assert the `free`
  codegen shape, not the `defer` shape directly. Adding a dedicated `test "codegen: defer
  stmt emits defer verbatim"` is the next audit step
  (mirroring the errdefer test's shape) — deferred as
  a small test-addition followup.
  The stdlib Io lifecycle (`defer __io_threaded.deinit()`
  callsites emitted inside the `blk:` wrappers for
  Io-using functions at e.g. the codegen-side Io init
  path in `src/codegen/expr.zig`) is codegen-EMITTED,
  NOT user-written in zag source — the user's zag
  program never writes `defer __io_threaded.deinit()`.
  See §19 Memory + §21 Concurrency for the user-facing
  surface that the codegen-emitted lifecycle enables.
- [x] `errdefer expr;` (runs only on error / partial-init
  path) — "codegen: errdefer stmt emits errdefer verbatim"
  + "parser: errdefer parses as Stmt.errdefer_stmt". The
  user-facing surface lives in §19 Memory
  (`examples/memory/errdefer.zag`), which exercises the
  partial-init cleanup shape; §06 pins the codegen shape
  rather than re-listing the §19 example.

- [ ] **`if let Pat = expr { … }`** (destructure-execute on
  pattern match; equivalent to `match expr { Pat => …, _
  => {} }`) — `manual/06-control-flow.md` documents the
  form. zag's `Stmt.if_stmt` parser arm does not yet
  thread a `Pat` through the branch; the only repo-wide
  occurrence of `if let` is one design comment in
  `src/ast/stmt.zig` ("a more permissive `if let` pattern
  surface than the…"). Deferred — requires a parser
  carve-out plus a codegen label-blk + `break :blk` path
  mirroring the match-expression row above. Sized as a
  small parser + codegen addition; the codegen shape is
  identical to match.
- [ ] **`while let Pat = expr { … }`** (repeatedly
  destructures until pattern fails; equivalent to `while
  true { match expr { Pat => …, _ => break } }`) —
  `manual/06-control-flow.md` documents the form. zag's
  `Stmt.while_stmt` parser arm does not yet thread a
  `Pat`; the design comments in `src/ast/stmt.zig` lines
  near `Stmt.while_stmt` both note "while let is deferred".
  Deferred — same scope as the `if let` row above.
- [ ] **`for (k, v) in map.iter() { … }`** (tuple-destructure
  on the iteration var) — `manual/06-control-flow.md`
  documents the destructuring form with a `map.iter()`
  example. zag's `Stmt.for_stmt.pattern` is currently
  `.ident` only; widening it to accept `tuple` shapes
  (mirroring the match arm pattern surface and the
  existing `BindingPattern.tuple` walker used by `let`
  bindings) is the canonical path. Deferred — the codegen
  shape mirrors the existing match-expression body's
  destructure patterns (see §18 Error Handling where
  `for (k, v) in errors_iter() { … }` is the canonical
  form).
- [ ] **`break val;`** (value-yielding break from a `while
  true { … }` loop; `let result = while true { …; break
  val; };`) — `manual/06-control-flow.md` documents the
  form. zag's current `Stmt.break_stmt` parser arm does
  not thread an `expr` payload; `break;` is bare only.
  Deferred — requires a parser widening plus a
  codegen-side `blk:` + `break :blk val` emit shape
  mirroring the if-expression / match-expression surface.
  Adding a codegen unit test would close the gap; the
  underlying zig primitive (`break :blk` with a value
  payload) is already what match uses internally today.
- [ ] **`panic(msg)`** (terminate the program with a message)
  — `manual/06-control-flow.md` shows the call alongside
  `return` as a control-flow primitive. zag does not
  have a dedicated codegen arm for `panic`; the call form
  has no current surface. Deferred — sized as a small
  builtins addition (`src/codegen/builtins.zig` already
  houses the print-arg + fs_read_file sidecars, and a
  `panic(msg)` builtin would slot alongside them). The
  Io lifecycle catch paths (`break :blk 255` / `__child.wait`
  failure shapes in `src/codegen/expr.zig`) are an unrelated
  catch-handler fallback for a codegen-emitted
  `@import("std").Io` call — semantically adjacent to
  neither a user `panic(msg)` nor any control-flow
  primitive, so they are not a usable approximation.
  Adding a unit test would close the gap once the
  builtins arm lands.

*Note: the if-else / match / for / while / break / continue
/ return / defer / errdefer surfaces in this section are
codegen-tested independently of the runnable examples —
every codegen test here pins a specific zig-emission shape,
and every runnable example here exercises the user-level
syntax on a single `main`. The deferred bullets above (if
let / while let / tuple-destructure for / break with value
/ panic) are the surfaces where the parser-level wiring
has not landed yet —codegen-level closure of each is a small, scoped addition once the parser arm lands.*

## 07. Types ([manual/07-types.md](../manual/07-types.md))

Four runnable examples cover the surface, each on its own `main`:
`examples/types/primitives.zag` (`as`-cast widening/narrowing
across the primitive snapshot), `examples/types/literals.zag` (the
literal-init inference carve-out — the 11 literal Expr kinds all
bind without `: T`), `examples/types/type_aliases.zag` (focused
walk through `str` → `[]const u8` alias resolution at every AST
type-bearing emit site + `void` zero-byte-unit round-trip + the
three core `as`-cast forms), and the bracketed `[]str` / `[3]str`
alias surface which lives only in `lib/cli.zag` (e2e-pinned via
`tests/e2e.zig`). Citations are file-name-only — line numbers go
stale on every edit.

- [x] **Type Inference carve-out** (`let x = 42;` infers `i32`)
  — `parser/stmt.zig:isLiteralInit` accepts int / float / bool /
  char / str / byte_str / null / undefined / tuple / array /
  template / struct / named-tuple / closure literals. Pinned by
  `"parser: let without type annotation"` in `src/tests/parser.zig`.
  Runnable examples: `examples/types/literals.zag` (every literal
  form bound with bare-`let`) + `examples/types/type_aliases.zag`
  (the `auto_i` / `auto_f` / `auto_s` / `auto_b` block).
- [x] **Type Inference override (explicit `: T`)** — the
  annotation wins over the inferred literal-init default. Pinned
  by `"parser: let with type annotation"` + `"codegen: let with
  type annotation emits verbatim @as(T, expr)"` in
  `src/tests/codegen.zig`. Runnable example:
  `examples/types/primitives.zag` (annotated `i32` / `i64` /
  `u32` / `f64` / `f32` / `u8` / `bool` bindings) +
  `examples/types/type_aliases.zag` (`wide_i64: i64 = 42` +
  `narrow_f32: f32 = 3.14` pair).
- [x] **Type Categories** — primitives (§08), pointers (§09),
  slices/arrays (§10), strings/`str` alias (§11), structs (§12),
  enums (§13), unions (§14), tuples (§15), SIMD (§23). Each
  chapter owns its per-category rows in this checklist; this
  row only cross-references — no §07-specific surface is
  duplicated.
- [x] **`void` zero-byte-unit return type** (`-> void` explicitly
  OR arrow omitted) — codegen falls through to `pub fn NAME(...)
  void { ... }` in either case (the `if (m.return_type) |rt|
  self.write(zagTypeToZig(rt)) else self.write("void");` fallback
  in `src/codegen/decl.zig:genFun`). Pinned by `"codegen: void
  fun emits pub fn NAME(...) void"` (which transitively exercises
  the `str` param alias as a side-effect). Runnable examples:
  `examples/functions/basic.zag` (`log` / `log_implicit` —
  explicit-arrow + inferred-arrow pair) +
  `examples/types/type_aliases.zag` (`log` / `do_nothing` — same
  pair on the doc-example).
- [x] **`str` → `[]const u8` transparent alias (let-bind site)**
  — `codegen/decl.zig:zagTypeToZig` returns `[]const u8` for the
  `str` ident. Pinned by one of the 9 alias-resolution tests
  across AST type-bearing emit sites in `src/tests/codegen.zig`.
  Runnable examples: `examples/types/type_aliases.zag` (`let
  name_v: str = "zag"`) + `examples/control-flow/if_else.zag`
  (`let label: str` in match-expression body) +
  `examples/generics/generic_fun.zag` +
  `examples/generics/turbofish_alias.zag`.
- [x] **`str` → `[]const u8` transparent alias (fn-parameter emit
  site)** — same alias-resolve path, but on `MethodParam.type_text`
  / `FunDecl.params[].type_text` during `genMethod` / `genFun`.
  Runnable example: `examples/types/type_aliases.zag`
  (`print_echo`'s `name: str` parameter — the alias collapses to
  `[]const u8` in the generated fn signature).
- [x] **`str` → `[]const u8` transparent alias (fn-return emit
  site)** — same path, but on `MethodDecl.return_type` /
  `FunDecl.return_type`. Runnable example:
  `examples/types/type_aliases.zag` (`get_greeting()`'s `-> str`
  return — the alias collapses to `[]const u8` in the trailing
  return-type position).
- [x] **`[]str` / `[3]str` bracketed-alias surface** —
  zagTypeToZig returns `[][]const u8` / `[3][]const u8` for the
  bracketed forms. The only end-to-end runnable coverage lives
  in `lib/cli.zag` (both shapes in one body); the e2e harness
  in `tests/e2e.zig` pins the cascade. No dedicated single-file
  example exists for these — would be a small example-addition
  followup if user demand surfaces one.
- [x] **`as` int→float widening cast** — codegen emits
  `@as(f64, expr)` from `Expr.cast`. Runnable example:
  `examples/types/primitives.zag` (`int_val as f64`) +
  `examples/types/type_aliases.zag` (`int_v as f64`).
- [x] **`as` float→float narrowing cast** — codegen emits
  `@as(f32, expr)` from `Expr.cast`. Runnable example:
  `examples/types/primitives.zag` (`pi as f32`) +
  `examples/types/type_aliases.zag` (`widen_f64 as f32`).
- [x] **`as` float→int truncating cast** — codegen emits
  `@as(i32, expr)` from `Expr.cast`. Runnable example:
  `examples/types/type_aliases.zag` (`widen_f64 as i32` —
  narrow cast site alongside an explicit `: i32` annotation).
- [x] **`as` bit-literal type-fixup** (`x as i32`) — let the
  user coerce a `comptime_int` bit literal (e.g. `0b1100`) to a
  fixed-width primitive before applying unary `~` (zig rejects
  `~` on `comptime_int`). Runnable example:
  `examples/operators/operators.zag` (`~(0b1100 as i32)` — the
  `not_source` row).
- [x] **`as` pointer reinterpret cast** — codegen emits
  `@as(*raw T, expr)` from `Expr.cast`. Runnable example:
  `examples/memory/unsafe.zag` (`free(p as *raw c_void)`).
- [x] **Copy semantics on primitives** — every primitive type
  duplicates on assignment, so `let b = a;` keeps both bindings
  live. Implicit in the codegen emission of `b = a`; coverage
  spans every two-binding primitive example throughout the
  corpus. Cross-reference: manual/07 §"Copy rules".
- [x] **Copy semantics on slices / pointers** — `[]T`, `*const T`,
  `?*T` copy the slice-or-pointer (not the pointee). Implicit via
  the destructuring-flat named-let forms and the §09 pointer
  examples. No dedicated single-file example exercises a
  cross-pointer copy; coverage is generic across §04/§09.

- [ ] **User-defined type aliases** (`type Foo = Bar;` source
  shape) — v1 parser does NOT accept a top-level `type Foo = Bar;`
  decl; the `type_kw` token is currently reserved only for the
  generic-type-param `comptime X: type` shape inside
  `parseTypeParam` (`src/parser/decl.zig`). Adding a top-level
  `parseTypeAlias` arm that consumes the alias syntax and emits
  zig's `const Foo = Bar;` form (or `pub fn Foo(comptime T: type)
  type { return Bar(T); }` for the parametric case) is the
  canonical v2-extension path. Deferred to a separate parser
  pass.
- [ ] **Numeric type aliases** (`type MyInt = i64`) — same
  parser carve-out as the user-defined alias row above; the
  alias, once landed, would emit `const MyInt = i64;` through
  an extended `zagTypeToZig` lookup table on top of the
  parser-arm work.

*Note 1: the type categories table in manual/07-types.md
cross-references the per-category chapters — §08 (Primitives),
§09 (Pointers), §10 (Arrays and Slices), §11 (Strings —
home of the `str` alias), §12 (Structs), §13 (Enums),
§14 (Unions), §15 (Tuples — only `(T, U)` type-as-expression
and tuple literals), and §23 (SIMD). Each chapter owns its
per-category coverage rows in this checklist; this section
only annotates the §07-specific surfaces (type inference
carve-out + override, `as` casts, `void`, and the alias set).*

*Note 2: `examples/types/type_aliases.zag` exercises EVERY §07-
specific row above on a single `main` — a future regression
against any alias-resolution path will surface in that file
on the next `examples/run_all.sh types/` invocation, before
it reaches production. The first-cast surface (`int → float`
widening) is exercised by both `primitives.zag` and
`type_aliases.zag`; the more fragile variants (`float → int`
truncating + `float → float` narrowing) live only on
`type_aliases.zag` because they were previously uncovered.*

## 08. Primitives ([manual/08-primitives.md](../manual/08-primitives.md))

The canonical primitive-types tour lives on
`examples/types/primitives.zag`. The broader surface audit
this year extended this file from a 6-type tour to cover
every primitive type listed in `manual/08-primitives.md`.
Each `let v: T = N` line below binds one primitive type
and each `print(v)` line proves the runtime round-trip
through zag's `__zag_print("{any}", .{arg,})` builtin
path. Cross-references: the literal-init inference
counterpart (`let x = 42; -> i32` because of the carve-out,
not because of a `: T` annotation) is owned by §03/§07; the
`void` zero-byte-unit return type lives on the §07 row
titled "`void` zero-byte-unit return type"; the `as`-cast
surface is owned by §07. Citations are file-name-only —
line numbers go stale on every edit.

- [x] **Signed integer family** (`i8`, `i16`, `i32`,
  `i64`, `i128`, `isize`) — the parser's typename-
  identifier front in `src/parser/decl.zig` accepts all
  6; the codegen emits the `type_text` verbatim so each
  identifier round-trips identifier-by-identifier (no
  per-type carve-out needed because zig accepts each
  natively). Runnable example:
  `examples/types/primitives.zag` (the "Signed integers"
  block — every size bound + printed; the `let i64v: i64
  = i32v` line pins the **implicit i32 → i64 widening**
  rule, the canonical zig semantic and the only direction
  that round-trips implicitly — i64 → i32 requires an
  explicit `as` cast, see the §07 row). Pinned by the
  `let-bind type-annotation emits verbatim @as(T, expr)`
  codegen test in `src/tests/codegen.zig`.
  **Pointer-width signed `isize`** is what every `for i in
  0..N` iteration variable auto-infers to when no `: T`
  annotation is present
  (`examples/control-flow/for_loop.zag`).

- [x] **Unsigned integer family** (`u8`, `u16`, `u32`,
  `u64`, `u128`, `usize`) — same parser/codegen path as
  the signed family; explicit-typed let-binds round-trip
  identifier-by-identifier. Runnable example:
  `examples/types/primitives.zag` (the "Unsigned integers"
  block — every size bound + printed, with `u8v = 'Z'`
  doubling as the char-as-ASCII row below since v1 char
  IS u8). The `u32v = 0xFF` line transitively cites the
  §03 hex-literal row. **Pointer-width unsigned `usize`**
  is the type of every array length / `.len` accessor
  throughout the corpus (`examples/arrays/multi_dim.zag`'s
  `numbers.len` / `matrix.len` pair; every slice literal
  in §10).

- [x] **Float family** (`f16`, `f32`, `f64`) — same
  identifier-acceptance + verbatim-emit path. Runnable
  example: `examples/types/primitives.zag` (the "Floats"
  block). The §08 manual's "f16 library-only in v1" note
  describes the zig-scalar-arithmetic-hook gap, NOT the
  bind/print round-trip — zag's codegen delegates to zig
  for the actual scalar op, so the let-binding compiles +
  the value prints + the value can be assigned / compared
  inside the binding's scope. `isFloatIdentType` at
  `src/codegen/core.zig:581` distinguishes these 3
  identifiers from the integer family so the `@divTrunc` /
  `@rem` integer shims skip float-bound LHSes. Cross-
  reference: `examples/structs/vec3.zag`'s
  `struct Vec3 { x: f64, y: f64, z: f64 }` pins the same
  `f64` primitive in a compound type.

- [x] **Boolean** (`bool`) — 1-byte stack primitive. Both
  `true` and `false` literals are bound + printed on
  `examples/types/primitives.zag`. Cross-references: the
  §03 literal-init row on bool-keyword recognition; the
  §07 row on literal-init inference (`let auto_b = true;
  -> bool`). The implicit int→bool conversion is NOT
  supported — v1 only accepts `bool = true` / `bool =
  false` as a literal init.

- [x] **Char (v1 single-byte ASCII via u8)** — the
  `Expr.char_lit` parser arm produces a single-byte u8
  value from ASCII or `\xNN` escape forms. The `let u8v:
  u8 = 'Z'` binding on `primitives.zag` prints 90 at
  runtime — the ASCII byte for `'Z'`, the integer form
  (not a glyph render at v1 since u8 == char). The 4-byte
  Unicode char (`'\u2764'` per manual) is deferred to v2.

- [x] **`as` int→float widening + float→float narrowing**
  — `examples/types/primitives.zag`'s bottom block
  exercises both shapes end-to-end (`f64_pi as f32` and
  `i32_int as f64`). The third `as` cast profile
  (`float → int` truncating) lives only on
  `examples/types/type_aliases.zag` per §07's row.

- [ ] **`bf16` Brain Float 16** — zag's parser + codegen
  pass `bf16` through verbatim (the generated zigzag
  leaf contains `const v: bf16 = 0;` unchanged); the
  rejection is from zig 0.16 with `error: use of
  undeclared identifier 'bf16'`. The codegen
  `isFloatIdentType` map at `src/codegen/core.zig:581`
  also has no `bf16` entry, so binary arithmetic on a
  bf16-typed binding would emit an integer-shim
  `@divTrunc(v, x)` even AFTER zig gains `bf16` support
  (the predicate would still flag it as non-float). The
  fix path is two-sided: (a) `zagTypeToZig` 1-to-1
  mapping entry for `bf16` — paired with a clearer
  error message at the let-bind site TODAY pointing to
  this row (silent substitution is rejected because
  IEEE 754 half and brain-float have different
  mantissa/exponent layouts, so `zf16 → f16` would
  quietly break precision semantics); PLUS (b) a
  `bf16` whitelist entry in `isFloatIdentType` so the
  arithmetic shape stays float-typed once zig accepts
  the type. Deferred — small `zagTypeToZig` table +
  predicate widening; can ride along with any zig
  version that adds `bf16` as a real builtin.

- [ ] **v2 4-byte Unicode char** (per manual's `Char`
  row — "4 bytes (Unicode scalar value)") — runtime
  probe reveals THREE separate gaps: (a) the zag parser
  + codegen pass `char` through verbatim (rejected by
  zig 0.16 with `undeclared identifier 'char'`); (b)
  zag's lexer preserves `\u2764` as 6 raw characters
  in the leaf source — zig 0.16 wants the brace form
  `\u{NNNN}` (`expected '{', found '2'`); (c) EVEN IF
  the lexer rewrote `\u2764` → `\u{2764}` AND the parser
  accepted `char` as a 4-byte type, zag's `Expr.char_lit`
  codegen arm would STILL emit the raw byte stream
  rather than the codepoint-as-brace form — non-ASCII
  codepoints would hit the "char_lit text is bytes, not
  a codepoint" mismatch. The fix path therefore threads
  three layers: parser/AST (lift `char` to a 4-byte
  primitive matching the manual's representation table)
  + lexer (decode bare `\uNNNN` + braced `\u{NNNN}` to
  the codepoint byte sequence) + codegen `Expr.char_lit`
  arm (emit `\u{{0x{codepoint:X}}}` instead of the raw
  byte stream). Deferred — strictly larger than the
  bf16 row above; sized as a v2-round migration.

*Note 1: zag's literal-init inference carve-out (§07's first
row) only assigns `i32` for ANY int literal, so the wider
integer surface on this tour REQUIRES explicit `: T`
annotations to bind any non-`i32` type — this is why
`primitives.zag` annotates every binding inline rather
than relying on a bare `let x = 0;`. The bare-literal form
is exercised by `examples/types/literals.zag` (the `let
hex_val = 0xFF` / `let big: i32 = 1_000_000` lines pin the
carve-out).*

*Note 2: the c-compatible ABI types (`c_short`, `c_long`,
`c_ulong`, `c_int`) are accepted by zag's parser as type
identifiers and round-trip verbatim through codegen, but
they are NOT listed in `manual/08-primitives.md`'s
primitive table so no row references them above. Implicit
coverage pin in the generic "let-bind type-annotation
accepts any zig-native identifier" codegen test in
`src/tests/codegen.zig`.*

*Note 3: the `void` zero-byte-unit return type is NOT a
row here — its surface is fully owned by the §07 row
titled "`void` zero-byte-unit return type" (which
references `examples/types/type_aliases.zag`'s `log` /
`do_nothing` pair + `examples/functions/basic.zag`'s
same-shape pair). `void` is rejected as a let-bind type
(`let x: void = …` fails because `void` has no runtime
representation; it exists only in the fn-return
position).*
