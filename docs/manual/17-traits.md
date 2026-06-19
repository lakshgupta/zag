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
