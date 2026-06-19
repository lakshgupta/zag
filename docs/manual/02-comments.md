# Comments

Zag uses `#` for line comments and `##` for doc comments.

## Line Comments

```
# This is a comment
x = 1  # inline comment
```

## Doc Comments

Doc comments use `##` and are attached to the next declaration:

```
## Adds two integers.
fun add(a: i32, b: i32) -> i32 {
    return a + b;
}

## A 3D vector.
struct Vec3 {
    x: f64,
    y: f64,
    z: f64,
}
```

Doc comment sections: `# Arguments`, `# Returns`, `# Errors`, `# Examples`, `# Safety`.

## No Block Comments

Zag has no block comments. Use line comments for multi-line explanations:

```
# This function reads a file and parses it as JSON.
# It returns an error if the file doesn't exist
# or if the content is not valid JSON.
fun read_json(path: str) -> Result<Json, Error> {
    ...
}
```
