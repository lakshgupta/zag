#!/usr/bin/env python3
"""Revert over-annotated BARE-binding test sources in src/main.zig.

The test sources are in single-line Zig string literals:
    const src = "fun f() {\n    let x: i32 = 42;\n}\n";

The 2-byte `\n` (backslash + n, 0x5C 0x6E) is at the byte level — NOT a single
0x0A LF byte. We use Python bytes literals `b"\\n"` to match.

Reverts to apply: each test source containing `: i32` etc. where the test
name (or the assertion) demonstrates BARE-binding semantics.
"""
PATH = "src/main.zig"

EDITS = [
    # `parser: let without type annotation` (5 occurrences) — source must
    # be bare so `stmt.let.type_name == null` assertion holds.
    (
        b"const src = \"fun f() {\\n    let x: i32 = 42;\\n}\\n\";",
        b"const src = \"fun f() {\\n    let x = 42;\\n}\\n\";",
    ),
    # `parser: let with multiple lets each annotated` — assertion
    # `body[2].let.type_name == null`, so the 3rd binding must be bare.
    # First two stay annotated (they test annotations).
    (
        b"const src = \"fun f() {\\n    let x: i32 = 1;\\n    let y: f64 = 2.0;\\n    let z: bool = true;\\n}\\n\";",
        b"const src = \"fun f() {\\n    let x: i32 = 1;\\n    let y: f64 = 2.0;\\n    let z = true;\\n}\\n\";",
    ),
    # `parser: var without type annotation`
    (
        b"const src = \"fun f() {\\n    var n: i32 = 0;\\n}\\n\";",
        b"const src = \"fun f() {\\n    var n = 0;\\n}\\n\";",
    ),
    # `parser: const without type annotation`
    (
        b"const src = \"fun f() {\\n    const k: i32 = 7;\\n}\\n\";",
        b"const src = \"fun f() {\\n    const k = 7;\\n}\\n\";",
    ),
    # `codegen: const without annotation emits bare \`const x = …\``
    (
        b"const src = \"fun f() {\\n    const answer: i32 = 42;\\n}\\n\";",
        b"const src = \"fun f() {\\n    const answer = 42;\\n}\\n\";",
    ),
]

def main():
    with open(PATH, "rb") as f:
        data = f.read()

    n_applied = 0
    for old, new in EDITS:
        cnt = data.count(old)
        if cnt == 0:
            print(f"MISS  not found: {old[:60]!r}")
            continue
        # Apply to ALL occurrences (some tests are duplicated 5x).
        data = data.replace(old, new)
        n_applied += 1
        print(f"OK    replaced ({cnt}x): {old[:60]!r}")

    with open(PATH, "wb") as f:
        f.write(data)

    print(f"\nApplied {n_applied}/{len(EDITS)} edits")

if __name__ == "__main__":
    main()
