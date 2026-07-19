# Traits

A trait declares shared behavior. Use a trait when a Type must be usable wherever the trait is expected — function parameter, list element, or generic bound.

**One syntax** for trait implementation: `impl Type with Trait { ... }`. The block header names both the type and the trait; the body supplies every required method. Default methods are optional overrides.

**Memory:** Traits are fat pointers (data pointer + vtable pointer). 16 bytes on 64-bit. Vtable dispatch is one indirect call.

This chapter uses one running example (`Button` + `Drawable`) and progressively extends it through each section.

> **Parser status.** The v2 parser does NOT yet parse `impl Type with Trait { ... }` — that form requires an `ImplBlock.trait_name` AST field that is planned for v2.1. Until the parser-side commit lands, write source using the per-method prefix (`pub fun Trait.method`) or the nested `with Trait { ... }` group-clause. Both routes emit byte-identical zig to the canonical form would. § Trait Rules lists the equivalent source for every canonical declaration. New code should follow the canonical form's review so the future migration to v2.1 source is mechanical.

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

Until v2.1 lands, write implementation using ONE of these two accepted forms:

```
# Form A — per-method prefix (current v2 surface)
impl Button {
    pub fun Drawable.draw(self: *Button) {
        print("Button: ", self.label);
    }
    # Drawable.name is inherited as the default.
}

# Form B — nested with-clause (parser sugar)
impl Button {
    with Drawable {
        pub fun draw(self: *Button) {
            print("Button: ", self.label);
        }
    }
}
```

The canonical v2.1 form (target — not yet parseable) is one block header that names both type and trait:

```
impl Button with Drawable {
    pub fun draw(self: *Button) {
        print("Button: ", self.label);
    }
}
```

Rules:

- One trait per block in v2. To implement multiple traits on the same Type, write multiple blocks.
- Required methods (no body in trait) MUST appear in the impl block. Missing one is a compile error.
- Default methods are optional. Omit them to inherit the trait's body; supply them to override.
- The compiler registers each method on the matching vtable slot. `obj as Trait` packages the data pointer + vtable pointer into a 16-byte fat pointer at the use site.

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
impl Console {
    pub fun Logger.log(self: *Console, msg: str) {
        print(msg);
    }
}

# FileLogger overrides ONE default while leaving the other inherited:
impl FileLogger {
    pub fun Logger.log(self: *FileLogger, msg: str) {
        self.file.write(msg);
    }

    pub fun Logger.warn(self: *FileLogger, msg: str) {    # override default
        self.file.write("WARN [" ++ self.level ++ "]: " ++ msg);
    }
    # Logger.error is inherited from the trait default
}
```

Default methods inherit `Self` as the implementing type and may call other trait methods (including other defaults) through it.

## Multiple Traits

Write one `impl` block per trait. Each block registers methods on that block's vtable only:

```
trait Printable {
    pub fun print(self: *Self);
}
trait Serializable {
    pub fun serialize(self: *Self) -> str;
}

impl Button {
    pub fun Printable.print(self: *Button) { /* Display body */ }
    pub fun Serializable.serialize(self: *Button) -> str { /* Sequence body */ }
}
```

**Diamond.** Two traits sharing a method name is the diamond shape. Two cases:

1. **Body diverges per trait** (Display must HTML-escape; Show must print raw). Write one impl block per trait — each block's method body is independent:

```
impl Button {
    pub fun Display.print(self: *Button) {
        print(self.label.html_escape());    # HTML-escaped body
    }
    pub fun Show.print(self: *Button) {
        print(self.label.raw());            # raw body — different from Display's
    }
}
```

The compiler keeps both bodies side-by-side, registration is per (Type, Trait) by Form A's per-method prefix (or Form B's with-clause association). Revising one body does not touch the other.

2. **Body is genuinely shared across traits.** Factor the work into a private helper function and call it from each block. Compiler does not deduplicate bodies across vtables; a helper avoids drift if the shared work changes:

```
fun button_format(self: *Button) -> str { /* shared work */ }

impl Button {
    pub fun Display.print(self: *Button) {
        print(button_format(self));
    }
    pub fun Show.print(self: *Button) {
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

impl MyHandler {
    async fun Handler.handle(self: *MyHandler, req: *Request) -> *Response {
        let data = await read_data(req)?;
        return process(data);
    }
}
```

The trait declares `-> *Response`; the impl writes `-> *Response`; the compiler rewrites the impl-side return type to `Future<*Response>` internally. The caller through a trait value sees `*Response` and must `await` the result.

## Trait Rules

| Surface                              | Mapping                                                                                                                       |
|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Canonical impl form (v2.1)           | `impl Type with Trait { ... }`                                                                                                 |
| v2 accepted form A (current parser)  | `impl Type { pub fun Trait.method(self: *Type) { ... } ... }`                                                                 |
| v2 accepted form B (current parser)  | `impl Type { with Trait { pub fun method(self: *Type) { ... } ... } }`                                                        |
| Method binding                       | The block's trait registers the method on the matching vtable slot                                                            |
| Required in impl block?              | Yes for trait methods without a body; missing is a compile error                                                              |
| Optional in impl block?              | Yes for trait methods with a body (defaults); same-named body in the impl block overrides                                      |
| Multiple traits on one Type          | One impl block per trait                                                                                                      |
| Fat pointer construction             | `obj as Trait`                                                                                                                |
| Diamond (two traits sharing a method)| One impl block per trait; diverge per-block or share via helper function                                                       |
| Structural composition (no vtable)   | Bare `EmbedType,` row in struct body — promotes fields and methods at compile time                                            |
| Async                                | `async fun` on impl-block method; caller awaits                                                                               |
| Associated types                     | Not in v1                                                                                                                     |
