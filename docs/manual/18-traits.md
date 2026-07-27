# Traits

A trait declares shared behavior. Use a trait when a Type must be usable wherever the trait is expected — function parameter, list element, or generic bound.

**Memory.** Traits are fat pointers (data pointer + vtable pointer). 16 bytes on 64-bit. Vtable dispatch is one indirect call.

This chapter uses one running example (`Button` + `Drawable`) and progressively extends it.

## Definition

A trait declares method signatures. Methods without a body are **required** — every impl block must supply one. Methods with a body are **defaults** — the impl block may inherit or override them:

```
trait Drawable {
    pub fun draw(self: *Self);                # required
    pub fun name(self: *Self) -> str {        # default
        return "drawable";
    }
}
```

Trait methods have a **fixed signature per trait.** Overloading within a single trait works — two methods with the same name but different parameter types are distinct:

```
trait Renderer {
    pub fun render(self: *Self);
    pub fun render(self: *Self, scale: f64);
}
```

## Implementing

Name the type and one or more traits at the `impl` block header. A method whose name is unique across the listed traits dispatches automatically:

```
impl Button with Drawable {
    pub fun draw(self: *Button) {
        print("Button: ", self.label);
    }
    # Drawable.name is inherited from the default — no body needed.
}
```

Required methods MUST appear in the impl block. Default methods are optional — omit them to inherit the default, supply them to override.

### Dot-qualified methods

When a method name is not unique (e.g. two traits declare `draw`), qualify it with `Trait.method`:

```
impl Button with Drawable, Clickable {
    pub fun Drawable.draw(self: *Button)  { ... }    # → Drawable's vtable
    pub fun Clickable.draw(self: *Button) { ... }    # → Clickable's vtable
}
```

The compiler registers each body on the named trait's vtable. Unqualified methods that are unique across the `with` list still bind automatically — the qualifier is only required for disambiguation.

### Overloaded trait methods

When a trait has multiple methods with the same name, the compiler matches by signature — no extra syntax:

```
impl Button with Renderer {
    pub fun Renderer.render(self: *Button) { ... }             # → render()
    pub fun Renderer.render(self: *Button, scale: f64) { ... } # → render(f64)
}
```

### Resolving methods

When two traits share a method name, you can write an unqualified body alongside the qualified ones. The unqualified method resolves the ambiguity at the call site:

```
impl Button with Drawable, Clickable {
    pub fun draw(self: *Button) { self.Drawable.draw(); }      # resolver
    pub fun Drawable.draw(self: *Button)  { ... }              # vtable
    pub fun Clickable.draw(self: *Button) { ... }              # vtable
}
```

`btn.draw()` calls the resolver, which delegates to the preferred trait. The resolver is a regular type method — it has no vtable entry — and compiles to a direct call with zero overhead.

### Default methods + qualifiers

When one overload has a default and another is required, qualify the required one and inherit the default:

```
trait Drawable {
    pub fun draw(self: *Self);              # required
    pub fun draw(self: *Self, x: f64) {     # default
        self.draw();
    }
}

impl Button with Drawable {
    pub fun Drawable.draw(self: *Button) { ... }    # → required
    # draw(self, x: f64) inherited from the trait default — no body needed
}
```

## Multiple Traits in One Block

Comma-separate the trait names in the `with` header:

```
impl Button with Drawable, Clickable, Hoverable {
    pub fun draw(self: *Button)  { ... }   # unique to Drawable — automatic
    pub fun click(self: *Button) { ... }   # unique to Clickable — automatic
    pub fun reset(self: *Button) { ... }   # not in any trait — regular method
}
```

Multiple `impl` blocks on the same type accumulate — each block can list a subset of traits.

## Using Traits

A trait value is a fat pointer. Calling a method on it goes through the vtable. Convert a concrete Type to a trait with `as`:

```
fun render(d: Drawable) {
    d.draw();                  # vtable dispatch
}

let btn: Button = Button { label: "click me" };
render(btn as Drawable);      # constructs the fat pointer
```

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
impl FileLogger with Logger {
    pub fun log(self: *FileLogger, msg: str) {
        self.file.write(msg);
    }
    pub fun Logger.warn(self: *FileLogger, msg: str) {    # override default
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

Prefer generic bounds `<T: Drawable + Serializable>` over chain-cast (`x as A as B`) when possible — the bound resolves both vtables at compile time, the chain-cast falls back to runtime.

A fat pointer stores exactly one vtable pointer. Casting `obj as Drawable` constructs that pointer; casting the result `as Serializable` requires a runtime resolve against the underlying Type's Serializable vtable slot. The fix is generic bounds, which compile to direct calls with both vtables inlined at monomorphization time.

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

# btn.click() resolves through the Widget slot — no vtable.
# btn.pos reads through the Widget slot — no vtable.
```

Use embedding for monomorphized field/method reuse when the Type is known at the call site. Use trait impl when you need fat-pointer dispatch (`obj as Trait`) or generic bounds (`<T: Trait>`). Both stack on the same Type.

## Reference

| Surface | Syntax |
|---|---|
| Trait declaration | `trait NAME { pub fun m(self: *Self, ...) -> RET { ... } }` |
| Required method | No body in the trait — MUST appear in the impl block |
| Default method | Body in the trait — optional in the impl block; same-named body overrides |
| Single trait impl | `impl TYPE with TRAIT { ... }` |
| Multiple traits | Comma-separated: `impl TYPE with T1, T2 { ... }` |
| Multiple impl blocks | Accumulate — each block lists a subset of the type's traits |
| Dot-qualified method | `fun Trait.method(self: *TYPE, ...)` — binds to that trait's vtable slot |
| Unqualified method | `fun method(...)` — binds by uniqueness; error if ambiguous |
| Resolving method | Bare `fun method(...)` alongside qualified methods — resolves diamond at call site |
| Fat pointer construction | `obj as Trait` |
| Dynamic dispatch | `trait_value.method(...)` — one indirect call through the vtable |
| Overloaded trait methods | Different signatures = distinct slots; matched by signature at impl time |
| Structural embedding | Bare `EmbedType,` row in struct body — promotes fields and methods at compile time |
| Async impl methods | `async fun` on impl-block method; caller awaits |
| Associated types | Not in v1 |
