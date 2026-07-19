# Traits

Traits provide **dynamic dispatch** — pluggable behavior without inheritance.

## Definition

```
trait Drawable {
    fun draw(self: *Self);                    # required — no body
    fun name(self: *Self) -> str {            # default — has body
        return "drawable";
    }
}
```

Methods without a body are **required** — the `impl` block must provide them. Methods with a body are **defaults** — used when the `impl` block omits them.

**Memory:** Traits are fat pointers (data pointer + vtable pointer). 16 bytes on 64-bit.

## How Trait Membership Is Established

Zag has **two orthogonal paths** that establish a Type's relationship with the rest of the world. Both are wire-up mechanisms; neither implies class-style "is-a" inheritance — zag has no class hierarchy, no base classes, and no `extends` keyword. The two paths are not competing alternatives — they answer different questions and stack freely on the same Type.

### Path 1 — Trait impl (`pub fun Trait.method`)

The Type implements the Trait by declaring individual methods as `pub fun Trait.method(self: *Type)`. The `Trait.method` prefix names the trait the method registers against, and each method registration produces one entry in the Type's per-trait vtable. This is the path that wires up **vtable dispatch** — `obj as Trait` reads the matching vtable slot and packages both the data pointer and the vtable pointer into a 16-byte fat pointer.

```
trait Drawable {
    fun draw(self: *Self);
}

struct Button {
    label: str,
}

impl Button {
    pub fun Drawable.draw(self: *Button) {
        print("Button: ");
        print(self.label);
    }
}

fun render(d: Drawable) {
    d.draw();          # indirect call through Drawable's vtable
}

let btn: Button = Button { label: "hi" };
render(btn as Drawable);
```

Use this path when you want `obj as Trait` to compile, when a generic bound `<T: Trait>` must hold for a Type, or when you need runtime dispatch over a heterogeneous list of values.

### Path 2 — Structural composition (struct field embedding)

The Type's struct body includes a bare `EmbedType,` row that promotes that type's fields and methods into the outer struct. This is composition **without** vtable dispatch — every call resolves through the embedded value at compile time.

```
struct Widget {
    pos: Position,
}

impl Widget {
    pub fun click(self: *Widget) {
        # ...
    }
}

struct Button {
    Widget,            # bare row — embeds Widget by value; promotes
                          # Widget's fields (pos) and impl methods (click)
                          # into Button's namespace.
    label: str,
}

fun main() {
    let btn: Button = Button { label: "press" };
    btn.click();       # direct call resolved through Widget slot
    let p = btn.pos;   # direct field read through Widget slot
}
```

Calls through embedding are **monomorphized** — no fat pointer, no vtable lookup, no indirect call. This is the path to choose for concrete-type field-and-method reuse.

### When to use each

Use Path 1 (trait impl) for vtable dispatch (`obj as Trait`) and generic bounds (`<T: Trait>`). Use Path 2 (embedding) for concrete field/method reuse where the Type is known at compile time. A single Type can freely use both if it needs dynamic dispatch and concrete field reuse — the example below demonstrates.

### A type can use both paths at once

Trait impl and embedding are complementary. A common pattern: define a `Widget` struct for concrete field-and-method reuse, then have specific Widget-shaped types embed it for structural reuse AND add a trait impl for runtime dispatch over a mixed-type list:

```
# Drawable defined above (Path 1); Widget defined above (Path 2).

struct Button {
    Widget,                        # path 2 — Widget's `pos` field and `click` method promoted
    label: str,
}

impl Button {
    pub fun Drawable.draw(self: *Button) {   # path 1 — Button's draw
                                              # registered on the Drawable vtable
        print("Button: ");
        print(self.label);
    }
    # Button.click() promoted through Widget embedding — no separate
    # trait impl required; vtable dispatch on Drawable still works
    # because the impl block declares Drawable.draw.
}

fun render_any(items: []Drawable) {
    for d in items {
        d.draw();                # vtable dispatch
    }
}
```

A Type is `Drawable` through trait impl, AND it's a Widget-shaped concrete type through embedding. Two separate, mutual mechanisms; neither implies subtype-of semantics.

## Implementing

```
struct Button {
    Widget,
    label: String,
}

impl Button {
    pub fun Drawable.draw(self: *Button) {
        print("Button: ");
        print(self.label);
    }

    # name() not provided — uses default "drawable"
}
```

The `fun Trait.method` prefix makes the binding unambiguous. Only required methods (no body in the trait) must appear in the `impl` block. Default methods are optional — override them when you need custom behavior:

```
impl Button {
    pub fun Drawable.draw(self: *Button) {
        print("Button: ");
        print(self.label);
    }

    pub fun Drawable.name(self: *Button) -> str {   # override default
        return self.label;
    }
}
```

## With-Clause Sugar

`with Trait { ... }` is sugar for Path 1 (trait impl). The `Trait.method` prefix is auto-applied to every method declared inside the `with` block:

```
impl Button {
    with Drawable {
        fun draw(self: *Button) {                  # auto-bound: Drawable::draw
            print("button: ");
            print(self.label);
        }
        fun name(self: *Button) -> str {           # auto-bound: Drawable::name
            return self.label;
        }
    }
}
```

At codegen time the parser maps each `with`-block method to `pub fun Trait.method(self) { ... }` — the existing pipeline picks up the `trait_name` slot unchanged. The with-clause does not introduce new AST fields; it is a parser-side grouping affordance over the existing per-method prefix surface.

### All-impl form

When a Type implements every required method for a Trait (no defaults inherited), the `with` block groups them under one header instead of repeating the `Trait.` prefix per method:

```
impl List<T> {
    with Display {                  # all 3 -> Display::vtable
        fun fmt(self: *List<T>) { ... }
        fun pretty(self: *List<T>) { ... }
        fun print(self: *List<T>) { ... }
    }
    with Show {                     # all 1 -> Show::vtable
        fun print(self: *List<T>) { ... }
    }
}
```

`obj as Display` and `obj as Show` both compile: the `with Display` block registers `fmt`, `pretty`, and `print` on List's Display vtable; `with Show` registers `print` on List's Show vtable. The two registrations of `print` are independent (distinct entries on distinct vtables), just as they would be in the per-method prefix form.

### Partial-impl opt-out: `with Display(print)`

When two traits share a method name, write the with-clause with the parenthesised name on the trait that should KEEP that method's body — the other trait's slot becomes unfulfilled (a partial impl):

```
impl List<T> {
    with Display(print) {           # print -> Display::vtable only;
                                   # Show::print stays unfulfilled
        fun fmt(self: *List<T>) { ... }
        fun print(self: *List<T>) { ... }
    }
    with Show {                     # Show is fully implemented except print
        fun render(self: *List<T>) { ... }
    }
}
```

The parenthesised name inside `with Trait(name)` declares an **explicit decl-site qualifier**: this concrete method body belongs to the with-trait only and is not also used to satisfy the same method name on adjacent trait vtables. zig sees Display::print as fulfilled and Show::print as unfulfilled; `obj as List<T> as Show` is rejected by the type checker because the Show contract is missing one of its required methods.

If the user wants `print` to satisfy BOTH Display::print AND Show::print (the classic diamond problem of registering the same body in two vtables), write two with-clauses — one per trait — and accept that there are now two method bodies side-by-side:

```
impl List<T> {
    with Display {
        fun print(self: *List<T>) { /* Display-formatted body */ }
    }
    with Show {
        fun print(self: *List<T>) { /* same body or variant */ }
    }
}
```

The with-clause, like the per-method prefix, requires a method body per trait-method registration.

### Coherence: Rust's per-(Type, Trait) pair rule

Rust enforces **at most one `impl Trait for Type` block per (Type, Trait) pair**: every method inside `impl Display for List<T> { ... }` is implicitly bound to Display's vtable; the user cannot write two competing `impl Display for List<T>` blocks in the same crate. zag's `with` clause is a sugar for the same surface:

```
# Rust                              # zag equivalent (with sugar)
impl Display for List<T> {          impl List<T> { with Display {
    fn fmt(&self)       { ... }          fun fmt   (self: *List<T>) { ... }
    fn pretty(&self)   { ... }          fun pretty(self: *List<T>) { ... }
    fn print(&self)    { ... }          fun print (self: *List<T>) { ... }
}                                  } }
```

The per-(Type, Trait) coherence rule still holds in zag: at most one `with Trait` clause per Type per impl block; a second `with Display { ... }` for the same Type in the same impl block is a compile error ("Display already bound for List<T>"). The sugar does not relax coherence — it simply paints the rule with a less-verbose syntax.

## Default Methods

Default methods reduce boilerplate. A trait can provide a fallback implementation that types inherit unless they override it:

```
trait Logger {
    fun log(self: *Self, msg: str);                  # required

    fun warn(self: *Self, msg: str) {                # default
        self.log("WARN: " ++ msg);
    }

    fun error(self: *Self, msg: str) {               # default
        self.log("ERROR: " ++ msg);
    }
}
```

A type only needs to implement `log` — `warn` and `error` use the defaults:

```
impl Console {
    pub fun Logger.log(self: *Console, msg: str) {
        print(msg);
    }
    # warn() and error() inherited from trait
}
```

Override a default when the type needs different behavior:

```
impl FileLogger {
    pub fun Logger.log(self: *FileLogger, msg: str) {
        self.file.write(msg);
    }

    pub fun Logger.warn(self: *FileLogger, msg: str) {   # override
        self.file.write("WARN [" ++ self.level ++ "]: " ++ msg);
    }
}
```

Default methods can call other methods on the trait (including other defaults) through `Self`:

```
trait Sortable {
    fun less(self: *Self, other: *const Self) -> bool;   # required

    fun swap(self: *Self, i: usize, j: usize) {          # default
        let tmp = self.at(i);
        self.set(i, self.at(j));
        self.set(j, tmp);
    }
}
```

## Using Traits

```
fun render(d: Drawable) {
    d.draw();          # indirect call via vtable
    let n = d.name();  # indirect call via vtable (uses default if not overridden)
}

let btn = Button { ... };
render(btn as Drawable);    # fat pointer conversion
```

**Memory:** Calling a trait method is one indirect call (vtable lookup). Use in hot paths only if indirection is measurable.

## Trait Rules

- Traits declare method signatures. Methods without a body are **required**; methods with a body are **defaults**.
- `Self` refers to the implementing type
- A type implements a trait by declaring methods in `impl Type { ... }` with `fun Trait.method` prefix
- The compiler validates all required methods are present; default methods are optional
- Trait values are fat pointers
- A type can implement multiple traits
- No associated types in v1

## Performance

```
# Monomorphized — no vtable, inlined
fun render_all<T: Drawable>(items: []T) {
    for item in items {
        item.draw();     # direct call, inlined
    }
}

# Dynamic dispatch — vtable lookup
fun render_any(items: []Drawable) {
    for item in items {
        item.draw();     # indirect call
    }
}
```

Prefer generics for tight loops. Use traits for pluggable boundaries (HTTP handlers, drivers).

## Async Trait Methods

Trait declarations are synchronous. Async impl uses `async fun` on the impl side — the compiler desugars the return type to `Future<Output>`:

```
trait Handler {
    fun handle(self: *Self, req: *Request) -> *Response;
}

impl MyHandler {
    async fun Handler.handle(self: *MyHandler, req: *Request) -> *Response {
        let data = await read_data(req)?;
        return process(data);
    }
}
```

The `async` keyword tells the compiler to generate a state machine and wrap the return type in `Future<T>` for the vtable. The trait declares `-> *Response`; the impl writes `-> *Response`; the compiler rewrites it to `-> Future<*Response>` internally. The caller through a trait value sees `*Response` and must `await` the result.

## Multiple Traits

```
trait Printable {
    fun print(self: *Self);
}

trait Serializable {
    fun serialize(self: *Self) -> String;
}

impl MyType {
    pub fun Printable.print(self: *MyType) { ... }
    pub fun Serializable.serialize(self: *MyType) -> String { ... }
}

# MyType implements both traits
let p: Printable = my_val as Printable;
let s: Serializable = my_val as Serializable;
```
