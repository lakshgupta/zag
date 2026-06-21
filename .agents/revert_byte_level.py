#!/usr/bin/env python3
"""Byte-level surgical revert of false-positive migration additions.

Operates on raw bytes (mode='rb') to avoid Python-escape / tool-escape
mismatches when comparing strings. Reads the file as bytes, runs `.replace()`
on byte substrings, writes back.

The exact byte substrings to find were extracted earlier via
`raw[src_start:src_end]` in binary mode — the bytes are real LF (newline)
separated, not the 2-char `\n` escape sequence.
"""

import os


PATH = "/home/lex/Documents/github/zag/src/main.zig"


# Each fix is (old_bytes, new_bytes). The bytes have actual LF \n
# (real newlines), identical to the file bytes. Source from the
# earlier basher extraction.
FIXES = [
    # 1. parser: let without type annotation
    (
        b'    let x: i32 = 42;\n    }\n}\ntest "parser:',
        b'    let x = 42;\n    }\n}\ntest "parser:',
    ),
    # 2. parser: var without type annotation
    (
        b'    var n: i32 = 0;\n    }\n}\ntest "parser:',
        b'    var n = 0;\n    }\n}\ntest "parser:',
    ),
    # 3. parser: const without type annotation
    (
        b'    const k: i32 = 7;\n    }\n}\ntest "parser:',
        b'    const k = 7;\n    }\n}\ntest "parser:',
    ),
    # 4. parser: top-level wildcard
    (
        b'    let _: i32 = 42;\n    }\n}\ntest "parser:',
        b'    let _ = 42;\n    }\n}\ntest "parser:',
    ),
]


def main():
    with open(PATH, "rb") as f:
        raw = f.read()

    counts = {}
    for old, repl in FIXES:
        n = raw.count(old)
        if n > 0:
            raw = raw.replace(old, repl, 1)
            counts[old.split(b'\n')[0]] = n

    if counts:
        with open(PATH, "wb") as f:
            f.write(raw)
        print("APPLIED (%d):" % len(counts))
        for k, v in counts.items():
            print("  %s -> %d" % (k, v))
    else:
        print("No matches found.")


if __name__ == "__main__":
    main()
