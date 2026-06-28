# FFI and Interop

## extern fun

Declare C ABI functions:

```
#[export("printf")]
extern fun printf(fmt: *raw u8, ...) -> i32;

extern fun open(path: *raw u8, flags: i32) -> i32;
```

**Memory:** FFI calls cross the ABI boundary. No automatic memory management.

## Struct Layout Control

```
#[repr(C)]
struct CCompatible {
    a: i32,
    b: f64,        # offset 8 (platform padding rules)
    c: i16,
}

#[repr(C, packed)]
struct PackedC {
    a: i32,
    b: f64,        # offset 4 (no padding)
    c: i16,
}

#[repr(C, opaque)]
extern struct OpaqueHandle;   # size known, layout hidden
```

## Explicit Field Offsets

```
#[repr(C)]
struct GpuVertex {
    #[offset(0)]  pos: [3]f32,
    #[offset(12)] normal: [3]f32,
    #[offset(24)] uv: [2]f32,
    #[offset(32)] color: [4]u8,
}
```

## C-Compatible Enums

```
#[repr(C, i32)]
enum CError {
    Ok = 0,
    NotFound = 1,
    Permission = 2,
}
```

`enum` is the right keyword here because all variants are bare. For tagged unions crossing the FFI boundary, `#[repr(C, T)] union X { VariantA, VariantB(T) }` works the same way: the discriminant type follows `T` (default `u8` if omitted), and only explicitly assigned variants pin a specific tag — bare unassigned variants take the next successive value, payload-bearing unassigned variants still get distinct tag values per the ADT contract. **C ABI detail:** the C consumer of a `union` FFI type sees only the discriminant field; decoding a payload variant on the C side requires the caller to know the variant shape, which is why the explicit `= N` pins matter for any variant whose tag is part of the C-visible contract.

## Importing C Libraries

```
# In zag.toml:
[dependencies]
libc = { git = "https://github.com/ziglibc/zig-libc" }

# In source:
import libc

fun main() {
    libc.printf("hello from C\n");
}
```

## Safe Wrappers

Always wrap unsafe FFI in safe functions:

```
extern "C" fun raw_open(path: *raw u8, flags: i32) -> i32;

fun open(path: str) -> Result<i32, Error> {
    let fd = raw_open(path.ptr as *raw u8, 0);
    if fd < 0 {
        return Err(Error.Io);
    }
    return Ok(fd);
}
```

## C Variadics

C variadics (`...`) are inherently unsafe:

```
extern fun printf(fmt: *raw u8, ...) -> i32;

# Must be called inside unsafe:
unsafe {
    printf("hello %s\n", name.ptr);
}
```

## Memory Across FFI

When passing memory across FFI:

```
# Allocating for C
let buf = alloc(1024);
unsafe {
    c_function(buf);
}
free(buf as *raw c_void);

# Receiving from C
extern fun c_malloc(size: usize) -> *raw u8;
extern fun c_free(ptr: *raw u8);

let p = c_malloc(1024);
defer c_free(p);    # must use C's free, not Zag's
```

**Memory:** Never mix allocators. `free` uses the global allocator; C's `malloc`/`free` is separate.
