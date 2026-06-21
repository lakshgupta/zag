#!/usr/bin/env python3
"""Revert over-annotated test source bindings in src/main.zig.

The test sources are in single-line Zig string literals like:
    const src = "fun f() {\n    let x: i32 = 42;\n}\n";

So the raw bytes are: 5C 6E (backslash + n), NOT a single LF byte (0x0A).
This script uses Python bytes literals with escaped backslashes.
"""
import sys

PATH = "src/main.zig"

# Each tuple: (raw_bytes_to_find, raw_bytes_to_replace)
# raw_bytes encode backslash+n as 5C 6E (i.e. the literal characters '\' and 'n')
# i.e. Python: b'\\n'
EDITS = [
    # parser: let without type annotation
    (
        b"const src = \"fun f() {\\n    let x: i32 = 42;\\n}\\n\";",
        b"const src = \"fun f() {\\n    let x = 42;\\n}\\n\";",
    ),
    # parser: let with multiple lets each annotated
    (
        b"const src = \"fun f() {\\n    let x = 1;\\n    let y = 2;\\n    let z: bool = true;\\n}\\n\";",
        b"const src = \"fun f() {\\n    let x = 1;\\n    let y = 2;\\n    let z = true;\\n}\\n\";",
    ),
    # parser: var without type annotation
    (
        b"const src = \"fun f() {\\n    var n: i32 = 0;\\n}\\n\";",
        b"const src = \"fun f() {\\n    var n = 0;\\n}\\n\";",
    ),
    # parser: const without type annotation
    (
        b"const src = \"fun f() {\\n    const k: i32 = 7;\\n}\\n\";",
        b"const src = \"fun f() {\\n    const k = 7;\\n}\\n\";",
    ),
    # parser: top-level wildcard
    (
        b"const src = \"top {\\n    let _: i32 = 42;\\n}\\n\";",
        b"const src = \"top {\\n    let _ = 42;\\n}\\n\";",
    ),
    # codegen: let without annotation (and const variant)
    (
        b"const src = \"fun f() {\\n    let x = 42;\\n    const answer: i32 = 42;\\n}\\n\";",
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
            print(f"MISS  not found: {old[:60]!r}...")
            continue
        if cnt > 1:
            print(f"AMBIG count={cnt}: skipping  {old[:60]!r}...")
            continue
        data = data.replace(old, new, 1)
        n_applied += 1
        print(f"OK    replaced: {old[:60]!r}...")

    with open(PATH, "wb") as f:
        f.write(data)

    print(f"\nApplied {n_applied}/{len(EDITS)} edits")

if __name__ == "__main__":
    main()
