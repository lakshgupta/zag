# Traits

A trait declares shared behavior. Use a trait when a Type must be usable wherever the trait is expected — function parameter, list element, or generic bound.

**One canonical syntax.** Name the type and one or more traits at the `impl` block header. Each trait optionally lists method names in parens — the diamond disambiguator that binds a method body to that trait's vtable:

```
impl Type with Trait1 (m1, m2), Trait2, Trait3 (m3) {
    pub fun m1(self: *Type, ...) { ... }     # binds to Trait1's vtable
    pub fun m2(self: *Type, ...) { ... }     # binds to Trait1's vtable
    pub fun m3(self: *Type, ...) { ... }     # binds to Trait3's vtable
    pub fun regular(self: *Type, ...) { ... }# no trait (regular type method)
}
```

**Memory.** Traits are fat pointers (data pointer + vtable pointer). 16 bytes on 64-bit. Vtable dispatch is one indirect call.

> **Status.** This chapter is the design spec — the canonical `impl Type with Trait (m) { ... }` form is the single target surface. The parser does NOT yet recognise the `with` clause; rollout is staged in § Implementation Plan. Until that lands, the rest of the language (the trait declarations, the `obj as Trait` cast, the vtable dispatch) behaves as described here.

This chapter uses one running example (`Button` + `Drawable`) and progressively extends it.

## Definition

A trait declares method signatures. Methods without a body are REQUIRED — the impl block must supply one. Methods with a body are DEFAULTS — the impl block may inherit or override them:

```
trait Drawable {
    pub fun draw(self: *Self);                # required
    pub fun name(self: *Self) -> str {        # default
        return "drawable";
    }
}
```

Trait methods have a **fixed signature per trait** — overloading is not supported on trait methods (regular type methods can overload; see § 29). This keeps the diamond a pure name collision, resolved by the `(method)` disambiguator with no signature-level lookup.

## Implementing

The canonical form names the type and one or more traits at the block header. A method with a unique name across the listed traits dispatches automatically:

```
impl Button with Drawable {
    pub fun draw(self: *Button) {
        print("Button: ", self.label);
    }
    # Drawable.name is inherited as the default — no need to write
    # it unless you want different behavior.
}
```

Required methods (no body in the trait) MUST appear in the impl block — missing one is a compile error. Default methods (with a body in the trait) are optional — omit them to inherit the default, supply them to override.

## Multiple Traits in One Block

Comma-separate the trait names in the header. When a method name is unique to one of the listed traits, the compiler binds the body to that trait's vtable automatically:

```
impl Button with Drawable, Clickable {
    pub fun draw(self: *Button)  { ... }   # unique to Drawable
    pub fun click(self: *Button) { ... }   # unique to Clickable
}
```

A method whose name appears in no listed trait is a regular type method — no vtable entry. It is callable as `btn.log()` but not through `btn as SomeTrait`.

## Diamond Disambiguation

When the same method name appears in more than one listed trait (the diamond shape), the parenthesised `(method, ...)` list on a trait name owns the body. The impl block only needs to provide a body if the owning trait doesn't define a default.

**Lopsided — one trait owns `print`:**

```
impl Button with Drawable (print), Show {
    pub fun print(self: *Button) { ... }      # Drawable is the source of truth for print;
                                              # Show's `print` slot stays unfulfilled
}
```

Drawable owns `print`. Show's `print` slot is unfulfilled — a second `impl` block may complete it.

**Shared — both traits register the same body:**

```
impl Button with Drawable (print), Show (print) {
    pub fun print(self: *Button) { ... }      # one body, two vtable entries
}
```

Both traits own `print`. The single body registers on both vtables (compiler emits two free fns).

**Distinct — each trait owns a different method:**

```
impl Button with Display (print), Show (render) {
    pub fun print(self: *Button)  { ... }     # Display owns print
    pub fun render(self: *Button) { ... }     # Show owns render
}
```

**Shared work across both bodies** — factor into a private helper; the parens still disambiguate which trait each body registers on:

```
fun button_format(self: *Button) -> str { /* shared work */ }

impl Button with Display (print), Show (print) {
    pub fun print(self: *Button) {
        print(button_format(self));
    }
}
```

Rules:

- One or more comma-separated `Trait (methods)?` clauses in the `with` header.
- A parenthesised method name binds the matching body to that trait's vtable.
- A method with no parens dispatches by uniqueness across the block's traits; ambiguous → compile error with a hint to add the parens.
- The compiler emits one `Type_Trait_method` free fn per (Type, Trait) registration and threads each body into the matching vtable slot.

## Using Traits

A trait value is a fat pointer. Calling a method on it goes through the vtable. Convert a concrete Type to a trait with `as`:

```
fun render(d: Drawable) {
    d.draw();                  # indirection through Drawable's vtable
}

let btn: Button = Button { label: "click me" };
render(btn as Drawable);      # constructs the fat pointer
```

The `Drawable` parameter accepts any value whose Type implements `Drawable`. The vtable lookup picks the right `draw` body per Type.

## Default Methods

A trait method WITH a body is a default — the impl block may inherit or override it. A trait method WITHOUT a body is required — every impl block must supply it:

```
trait Logger {
    pub fun log(self: *Self, msg: str);                              # required

    pub fun warn(self: *Self, msg: str) {                            # default
        self.log("WARN: " ++ msg);
    }

    pub fun error(self: *Self, msg: str) {                           # default
        self.log("ERROR: " ++ msg);
    }
}

# Console implements one required method — the two defaults are inherited:
impl Console with Logger {
    pub fun log(self: *Console, msg: str) {
        print(msg);
    }
}

# FileLogger overrides ONE default while leaving the other inherited:
impl FileLogger with Logger (warn) {
    pub fun log(self: *FileLogger, msg: str) {
        self.file.write(msg);
    }

    pub fun warn(self: *FileLogger, msg: str) {    # override default
        self.file.write("WARN [" ++ self.level ++ "]: " ++ msg);
    }
    # Logger.error is inherited from the trait default
}
```

Default methods inherit `Self` as the implementing type and may call other trait methods (including other defaults) through it.

## Performance

Monomorphized direct calls are free. Vtable calls go through indirection. Fat pointer construction (`obj as Trait`) is cheap; chain-cast through fat pointers (`x as A as B`) requires a runtime lookup unless the compiler can prove the underlying Type implements both:

```
# Monomorphized — no vtable, inlined
fun render_all<T: Drawable>(items: []T) {
    for item in items {
        item.draw();            # direct call, inlined
    }
}

# Dynamic dispatch — vtable lookup
fun render_any(items: []Drawable) {
    for item in items {
        item.draw();            # indirect call
    }
}
```

Prefer generic bounds `<T: A + B>` over chain-cast (`x as A as B`) when possible — the bound resolves both vtables at compile time, the chain-cast falls back to runtime.

**Multi-trait vtable overhead.** A fat pointer stores exactly one vtable pointer. Casting `obj as Drawable` constructs that pointer; casting the result `as Serializable` requires a runtime resolve against `obj`'s underlying Type's Serializable vtable slot. The fix is generic bounds (`<T: Drawable + Serializable>`), which compile to direct calls with both vtables inlined at monomorphization time.

## Async Trait Methods

Trait declarations are synchronous. Async impl uses `async fun` on the impl block's method — the compiler generates a state machine and wraps the return type in `Future<T>`:

```
trait Handler {
    pub fun handle(self: *Self, req: *Request) -> *Response;
}

impl MyHandler with Handler {
    async fun handle(self: *MyHandler, req: *Request) -> *Response {
        let data = await read_data(req)?;
        return process(data);
    }
}
```

The trait declares `-> *Response`; the impl writes `-> *Response`; the compiler rewrites the impl-side return type to `Future<*Response>` internally. The caller through a trait value sees `*Response` and must `await` the result.

## Structural Embedding (composition without dispatch)

If you want a Type to inherit fields and methods from another Type WITHOUT going through vtable dispatch, embed the source Type as a bare struct row:

```
struct Button {
    Widget,                    # promotes Widget's fields (pos) and methods (click)
    label: str,
}

# `btn.click()` resolves through the Widget slot — no vtable.
# `btn.pos` reads through the Widget slot — no vtable.
```

Use embedding for monomorphized field/method reuse when the Type is known at the call site. Use trait impl when you need fat-pointer dispatch (`obj as Trait`) or generic bounds (`<T: Trait>`). Both stack on the same Type.

## Trait Rules

| Surface                              | Mapping                                                                                                          |
|--------------------------------------|------------------------------------------------------------------------------------------------------------------|
| Trait declaration                    | `trait NAME { pub fun m1(self: *Self); pub fun m2(...) -> T { ... } }`                                           |
| Trait impl                           | `impl TYPE with T1 (m1, m2)?, T2 (m3)? { pub fun m1(...) { ... } ... }`                                          |
| Required trait method                | No body in the trait — MUST appear in the impl block; missing is a compile error                                 |
| Default trait method                 | Has a body in the trait — optional in the impl block; same-named body overrides                                  |
| Multiple traits on one Type          | Comma-separated `Trait (methods)?` clauses in the `with` header (or across multiple `impl` blocks)              |
| Diamond (same method name, 2 traits) | Parenthesised name on the owning trait: `with T1(m), T2(m)` registers the body on the listed traits' vtables    |
| Overloaded trait methods             | Not supported — trait methods have a fixed signature per trait (see § 29)                                        |
| Fat pointer construction             | `obj as Trait`                                                                                                  |
| Dynamic dispatch                     | `trait_value.method(...)` — one indirect call through the vtable                                                |
| Structural composition (no vtable)   | Bare `EmbedType,` row in struct body — promotes fields and methods at compile time                             |
| Async                                | `async fun` on impl-block method; caller awaits                                                                 |
| Associated types                     | Not in v1                                                                                                        |

## Implementation Plan

The canonical form lands through a staged sequence of per-file commits. Each step is small, backward-compatible, and individually shippable; the "Status" callout above tracks the unblocked surface as each commit lands.

1. **Lexer (`src/lexer/token.zig`).** Add `with_kw` TokenTag + `with` keyword to the lexer keyword table. No source-code semantic change yet — just lex recognition.
2. **AST (`src/ast/decl.zig` + `src/ast.zig`).** Add `pub const TraitSpec = struct { name: []const u8, preferred_methods: []const []const u8 = &[_][]const u8{} }`. Add `trait_specs : []const TraitSpec = &[_]TraitSpec{}` field to `ImplBlock`. Re-export `TraitSpec` from `src/ast.zig` alongside the existing decl-side types.
3. **Parser (`src/parser/decl.zig` `parseImplBlock`).** After consuming the target_type ident and before the `{`, optionally consume `with` + one-or-more comma-separated `IDENT (method_list)?` specs, terminated by `{`. Empty `with` clause falls back to the regular non-trait `impl Type { ... }` path.
4. **Codegen (`src/codegen/decl.zig` `genTraitRegistration`).** Per-method dispatch rule: (a) any block-level `TraitSpec.preferred_methods` contains `method.name` → bind to that spec's name; (b) `trait_specs` non-empty AND exactly one listed trait declares the method → bind to that trait; (c) `trait_specs` empty → emit as a regular type method (no vtable entry); (d) else compile error with the diamond-disambiguator hint.
5. **Tests (`src/tests/codegen_decl.zig` + `src/tests/parser_decl.zig`).** Add fixture cases covering the dispatch paths: preferred_methods single-trait lopsided case, shared-body case, trait-uniqueness inference, ambiguity compile-error.