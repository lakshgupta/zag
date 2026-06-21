#!/usr/bin/env python3
"""Surgical revert of false-positive migration script additions.

The earlier `.agents/migrate_main_zig.py` walked inner-binding patterns
inside `const src = \"...\";` strings and added `: T` annotations to bare
init expressions. For some tests this was WRONG because those tests
explicitly assert `type_name == null` (the test of \"no annotation\"
behavior). Revert those specific test sources.

Also update two assertion lines that now need to include `: i32` because
the underlying zag source was hand-annotated with `: i32` (codegen
preserves the type annotation).
"""

import re


# Each entry: (old, new) — exact text matches the file bytes verbatim.
# The file bytes have real newlines (LF == 0x0A), so we write Python
# multi-line strings with real newlines here.
FIXES = [
    # 1. parser: let without type annotation  — let x = 42 should be bare
    (
        "fun f() {\n    let x: i32 = 42;\n}\n",
        "fun f() {\n    let x = 42;\n}\n",
    ),
    # 2. parser: let with multiple lets each annotated — `let z = true` should be bare
    (
        "fun f() {\n    let x: i32 = 1;\n    let y: f64 = 2.0;\n    let z: bool = true;\n}\n",
        "fun f() {\n    let x: i32 = 1;\n    let y: f64 = 2.0;\n    let z = true;\n}\n",
    ),
    # 3. parser: var without type annotation  — var n = 0 should be bare
    (
        "fun f() {\n    var n: i32 = 0;\n}\n",
        "fun f() {\n    var n = 0;\n}\n",
    ),
    # 4. parser: const without type annotation  — const k = 7 should be bare
    (
        "fun f() {\n    const k: i32 = 7;\n}\n",
        "fun f() {\n    const k = 7;\n}\n",
    ),
    # 5. codegen: let without annotation emits bare const x = ...  — let x = 42 should be bare
    (
        "fun f() {\n    let x: i32 = 42;\n}\n",
        "fun f() {\n    let x = 42;\n}\n",
    ),
    # 6. parser: top-level wildcard  — `let _ = 42` should be bare (NOT `let _: i32 = 42`)
    (
        "fun f() {\n    let _: i32 = 42;\n}\n",
        "fun f() {\n    let _ = 42;\n}\n",
    ),
    # 7. codegen: const without annotation  — const answer = 42 should be bare
    (
        "fun f() {\n    const answer: i32 = 42;\n}\n",
        "fun f() {\n    const answer = 42;\n}\n",
    ),
    # Assertion updates — codegen now preserves `: i32` from the user
    # annotation, so the output zigzag has `: i32` after the binding
    # keyword.
    (
        'try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (1 + 2);") != null);',
        'try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + 2);") != null);',
    ),
    (
        'try std.testing.expect(std.mem.indexOf(u8, zig, "    const z = (1 + (2 * 3));") != null);',
        'try std.testing.expect(std.mem.indexOf(u8, zig, "    const z: i32 = (1 + (2 * 3));") != null);',
    ),
]


def main():
    path = "/home/lex/Documents/github/zag/src/main.zig"
    with open(path, "r") as f:
        text = f.read()
    new = text
    for old, repl in FIXES:
        if old not in new:
            print("SKIP (not found): %r" % old[:60])
            continue
        count = new.count(old)
        new = new.replace(old, repl, 1)
        print("APPLIED: %r -> %r  (count=%d)" % (old[:60], repl[:60], count))
    if new != text:
        with open(path, "w") as f:
            f.write(new)
        print("WROTE %d changes." % (len(FIXES) - 0))
    else:
        print("No changes.")


if __name__ == "__main__":
    main()
