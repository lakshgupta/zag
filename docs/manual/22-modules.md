# Modules and Imports

## File-Path-Based Modules

No `module` declaration. The module path is the file path:

```
src/main.zag            -> module main
src/math/vec3.zag       -> module math.vec3
src/net/http/server.zag -> module net.http.server
```

A directory is a module if it contains `.zag` files.

## Imports

```
import math.vec3                    # import entire module
import math.vec3 as v               # alias
import math.{Vec3, Mat4}           # import specific items
```

## Visibility

- No modifier — module-private
- `pub` — visible outside the module

```
# In module math.vec3:
pub struct Vec3 { ... }      # visible to importers
pub fun length(...) { ... }  # visible
fun internal() { ... }       # private — not visible outside
```

## mod.toml

Optional file in a module directory to control submodule discovery:

```toml
[module]
name = "math"
version = "0.1.0"

# Explicit submodule list (opt-in). If omitted, all .zag files are modules.
submodules = ["vec3", "mat4", "quat"]

# Re-export control
[exports]
vec3 = true
mat4 = true
quat = false
```

If `mod.toml` is absent, all `.zag` files in the directory are submodules.

## Re-exports

A `mod.zag` file can re-export symbols:

```
# src/math/mod.zag
pub import math.vec3.{Vec3, Vec3::*};
pub import math.mat4.{Mat4, Mat4::*};
# quat not re-exported
```

## Cyclic Detection

The import resolver builds a module DAG and reports an error on cycles. This is a compile-time check.

## Dependencies

Third-party packages live in `deps/`:

```
zag install           # fetch dependencies
zag add json          # add a dependency
zag remove json       # remove a dependency
```

Packages are resolved from `zagpm.dev` or Git URLs in `zag.toml`.

## Example

```
# src/main.zag
import std.string
import math.vec3
import net.http.server

fun main() {
    let s = new String("hello");
    let v = vec3.Vec3 { x: 1.0, y: 2.0, z: 3.0 };
    server.serve("0.0.0.0:8080");
}
```
