#!/usr/bin/env python3
"""Surgical revert of false-positive migration script additions.

The earlier migration script (`.agents/migrate_main_zig.py`) over-annotated
test sources that asserted `type_name == null` behavior. This script
reverts those specific sources to bare form.

Operates byte-level: reads with mode='rb' to get exact byte sequence,
applies explicit byte replacements, writes back with mode='wb'.

Each replacement uses trailing LF (`b'\\n'`) as anchor to ensure
uniqueness against similar binding lines without trailing newlines.
"""

import sys


PATH = "/home/lex/Documents/github/zag/src/main.zig"


# (old_bytes, new_bytes) — replace the corrupted form with bare form.
# Trailing \\n (LF) anchors uniqueness. Original lines had no annotation
# (test asserts `type_name == null`); migration script incorrectly added
# `: i32` etc. Revert them.
REVERTS = [
    (
        b"    let x: i32 = 42;\n",
        b"    let x = 42;\n",
    ),
    (
        b"    var n: i32 = 0;\n",
        b"    var n = 0;\n",
    ),
    (
        b"    const k: i32 = 7;\n",
        b"    const k = 7;\n",
    ),
    (
        b"    let _: i32 = 42;\n",
        b"    let _ = 42;\n",
    ),
]


def main():
    with open(PATH, "rb") as f:
        raw = f.read()

    applied = 0
    for old, repl in REVERTS:
        n = raw.count(old)
        if n == 1:
            raw = raw.replace(old, repl, 1)
            print("APPLIED: %s -> %s" % (old, repl))
            applied += 1
        elif n == 0:
            print("NOT FOUND: %s" % old)
        else:
            # Multiple matches — use full context to disambiguate
            print("MULTI (%d): %s" % (n, old))

    if applied:
        with open(PATH, "wb") as f:
            f.write(raw)
        print("WROTE %d changes." % applied)
    else:
        print("No changes written.")


if __name__ == "__main__":
    main()
