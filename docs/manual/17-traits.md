# Traits

A trait declares shared behavior. Use a trait when a Type must be usable wherever the trait is expected — function parameter, list element, or generic bound.

**One canonical syntax** for trait implementation: `impl Type with Trait1 (m1, m2), Trait2, Trait3 (m3) { ... }`. The header names the type and one or more traits (comma-separated). Each trait optionally lists zero or more method names in parens — the diamond disambiguator that owners that method body's vtable slot. The body supplies required method definitions; default methods are optional overrides.

**Memory:** Traits are fat pointers (data pointer + vtable pointer). 16 bytes on 64-bit. Vtable dispatch is one indirect call.

This chapter uses one running example (`Button` + `Drawable`) and progressively extends it through each section.

> **Parser status.** The v2 parser does NOT yet parse `impl Type with Trait { ... }` — that form requires an `ImplBlock.trait_specs : []TraitSpec` AST field plus a `with_kw` TokenTag in the lexer. Both land alongside the per-file commits listed in § Implementation Plan below. Until the parser-side commit lands, write source using the per-method prefix (`pub fun Trait.method`) or the nested `with Trait { ... }` group-clause. Both accepted forms emit byte-identical zig to the canonical form would. § Trait Rules maps the accepted forms to the canonical source shape.

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

## Implementing

The canonical form names the type and one or more traits at the block header:

```
impl Button with Drawable {
    pub fun draw(self: *Button) {
        print("Button: ", self.label);
    }
    # Drawable.name is inherited as the default — no need to write
    # it unless you want different behavior.
}
```

### Multi-trait single block

Comma-separate the trait names when a Type implements multiple traits at once:

```
impl Button with Drawable, Clickable {
    pub fun draw(self: *Button) { ... }       # unique to Drawable — dispatches automatically
    pub fun click(self: *Button) { ... }      # unique to Clickable — dispatches automatically
}
```

When a method name is unique to one of the comma-separated traits, the compiler dispatches the body to that trait's vtable automatically. When the name appears in more than one trait (the diamond shape), the parenthesised `(method_name, ...)` list on the trait names owns the body.

### Diamond disambiguation via parenthesised preferred_methods

```
impl Button with Drawable (print), Show {
    pub fun print(self: *Button) { ... }      # binds to Drawable's vtable only;
                                              # Show's `print` slot stays unfulfilled
}
```

The `(print)` after `Drawable` declares: "the `print` body in this block registers on Drawable's vtable only." `Show`'s `print` slot remains unfulfilled (a partial impl). When you want BOTH traits to register the same body on their respective vtables, list the method name in parens on multiple traits:

```
impl Button with Drawable (print), Show (print) {
    pub fun print(self: *Button) { ... }      # registers on BOTH vtables — one body, two fns
}
```

Rules:

- Comma-separated trait names in the `with Trait (methods)?` clause — one or more.
- Required methods (no body in trait) MUST appear in the impl block. Missing one is a compile error.
- Default methods are optional. Omit them to inherit the trait's body; supply them to override.
- For methods with parens-listed preferred_methods on a trait, the parens own the dispatch. For methods without parens, the compiler resolves by uniqueness across the block's traits (compile error if ambiguous).
- The compiler emits one `Button_Trait_method` free fn per (Type, Trait) registration and threads each body into the matching vtable slot.

### Structural embedding (composition without dispatch)

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

## Using Traits

A trait value is a fat pointer. Calling a method on it goes through the vtable. Convert a concrete Type to a Trait with `as`:

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

## Multiple Traits

Comma-separate the trait names in the block header:

```
trait Printable {
    pub fun print(self: *Self);
}
trait Serializable {
    pub fun serialize(self: *Self) -> str;
}

impl Button with Printable, Serializable {
    pub fun print(self: *Button)         { /* Display body */ }
    pub fun serialize(self: *Button) -> str { /* Sequence body */ }
}
```

**Diamond.** Two traits sharing a method name is the diamond shape. Pick one of three resolutions:

1. **Body diverges per trait** (Display must HTML-escape; Show must print raw). Parenthesise the method on the trait whose body should diff — the non-parenthesised trait's slot stays unfulfilled:

```
impl Button with Display (print), Show (render) {
    pub fun print(self: *Button) {
        print(self.label.html_escape());   # Display body — HTML-escaped
    }
    pub fun render(self: *Button) {
        print(self.label.raw());           # Show body — raw
    }
}
```

2. **Body is genuinely shared across the diamond.** Parenthesise the method on every trait whose vtable should register it. Same body twice, distinct per vtable:

```
impl Button with Display (print), Show (print) {
    pub fun print(self: *Button) { /* Display-format body */ }
    # Same body registers on both vtables (the compiler emits two free fns).
}
```

3. **Body per trait differs in style but shares work.** Factor shared work into a private helper; call from each block. The parens still disambiguate which vtable registers which body:

```
fun button_format(self: *Button) -> str { /* shared work */ }

impl Button with Display (print), Show (print) {
    pub fun print(self: *Button) {
        print(button_format(self));
    }
}
```

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

Trait declarations are synchronous. Async impl uses `async fun` on the impl block's methods — the compiler generates a state machine and wraps the return type in `Future<T>`:

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

## Trait Rules

| Surface                              | Mapping                                                                                                                       |
|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Canonical impl form (v2.1)           | `impl Type with T1 (m1, m2)?, T2 (m3)?, T3 { ... }`                                                                          |
| v2 accepted form A (current parser)  | `impl Type { pub fun T1.m1(self: *Type) { ... } pub fun T2.m1(self: *Type) { ... } ... }`                                     |
| v2 accepted form B (current parser)  | `impl Type { with T1 { pub fun m1(self: *Type) { ... } } with T2 { pub fun m1(self: *Type) { ... } } ... }`                   |
| Method body dispatch                 | If `pub fun T.m` form A prefix set, bind to T. Else if `with T(m)` parenthesised on T, bind to T. Else pick the unique trait that declares the method; compile error if ambiguous |
| Required in impl block?              | Yes for trait methods without a body; missing is a compile error                                                              |
| Optional in impl block?              | Yes for trait methods with a body (defaults); same-named body in the impl block overrides                                      |
| Multiple traits on one Type          | Comma-separate trait names: `with T1, T2, T3`                                                                                  |
| Diamond disambiguation               | Per-trait parenthesised method list: `with T1(m1), T2(m1) { fun m1(...) ... }` — each parenthesised name binds to that specific trait's vtable; missing entries leave the slot unfulfilled or fall back to trait uniqueness |
| Fat pointer construction             | `obj as Trait`                                                                                                                |
| Structural composition (no vtable)   | Bare `EmbedType,` row in struct body — promotes fields and methods at compile time                                            |
| Async                                | `async fun` on impl-block method; caller awaits                                                                               |
| Associated types                     | Not in v1                                                                                                                     |

## Implementation Plan

The canonical form lands through a staged sequence of per-file commits. Each step is small, backward-compatible, and individually shippable; the doc's "Parser status" callout tracks the unblocked surface as each commit lands.

1. **Lexer (`src/lexer/token.zig`).** Add `with_kw` TokenTag + `with` keyword to the lexer keyword table. No source-code semantic change yet — just lex recognition.
2. **AST (`src/ast/decl.zig` + `src/ast.zig`).** Add `pub const TraitSpec = struct { name: []const u8, preferred_methods: []const []const u8 = &[_][]const u8{} }`. Add `trait_specs : []const TraitSpec = &[_]TraitSpec{}` field to `ImplBlock`. Re-export `TraitSpec` from `src/ast.zig` alongside the existing decl-side types.
3. **Parser (`src/parser/decl.zig` `parseImplBlock`).** After consuming the target_type ident and before the `{`, optionally consume `with` + one-or-more comma-separated `IDENT (method_list)?` specs, terminated by `{`. Empty `with` clause falls through to legacy Form A/Form B parsing — preserves the v2 accepted forms.
4. **Codegen (`src/codegen/decl.zig` `genTraitRegistration`).** Per-method dispatch rule: (a) `MethodDecl.trait_name` non-null → bind to that trait (Form A path); (b) any block-level `TraitSpec.preferred_methods` contains `method.name` → bind to that spec's name; (c) `trait_specs` empty AND exactly one trait in scope declares the method → bind to that trait; (d) else compile error with the diamond-disambiguator hint.
5. **Tests (`src/tests/codegen_decl.zig` + `src/tests/parser_decl.zig`).** Add four fixture cases covering the four dispatch paths: Form A prefix, preferred_methods single-trait lopsided case, trait-uniqueness inference, ambiguity compile-error.
