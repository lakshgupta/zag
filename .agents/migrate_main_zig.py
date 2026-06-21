#!/usr/bin/env python3
"""Migrate inner bare bindings inside `const src = \"...\";` string
declarations in src/main.zig (test sources) to typed form.

Strategy: match `\\n    (let|var|const) NAME = LITERAL;\\n` (literal
backslash+n in BOTH directions) — guarantees the binding is EMBEDDED
inside a multi-line string body, NOT the outer `const src = \"...\";`
declaration (which is on a single line).

Patterns applied in order (more specific first):
  - template literals (have {…})       -> []u8
  - plain string literals              -> []const u8
  - byte string literals (b"…")        -> []const u8
  - bool (true/false)                  -> bool
  - char ('X' or escape)               -> u8
  - float (decimal + optional exponent) -> f64
  - integer (decimal/hex/oct/bin)      -> i32
  - null / undefined                   -> ?i32 / i32
  - arithmetic: /\d+ [+-*/%] \d+/       -> i32
"""

import re
import sys


PATTERNS = [
    # template literal (must come BEFORE plain string)
    (r'\\n    (let|var|const) (\w+) = "([^"]*\{[^"]*)";\\n',
     r'\\n    \1 \2: []u8 = "\3";\\n'),
    # plain string
    (r'\\n    (let|var|const) (\w+) = "([^"]*)";\\n',
     r'\\n    \1 \2: []const u8 = "\3";\\n'),
    # byte string
    (r'\\n    (let|var|const) (\w+) = (b"[^"]*");\\n',
     r'\\n    \1 \2: []const u8 = \3;\\n'),
    # bool literals
    (r'\\n    (let|var|const) (\w+) = (true|false);\\n',
     r'\\n    \1 \2: bool = \3;\\n'),
    # char literal  (single char or escape)
    (r"\\n    (let|var|const) (\w+) = '([^']{1,4})';\\n",
     r"\\n    \1 \2: u8 = '\3';\\n"),
    # float with optional exponent
    (r'\\n    (let|var|const) (\w+) = (\d+\.\d+(?:[eE][+-]?\d+)?);\\n',
     r'\\n    \1 \2: f64 = \3;\\n'),
    (r'\\n    (let|var|const) (\w+) = (\d+[eE][+-]?\d+);\\n',
     r'\\n    \1 \2: f64 = \3;\\n'),
    # hex / oct / bin (must come before plain int)
    (r'\\n    (let|var|const) (\w+) = (0x[\da-fA-F_]+);\\n',
     r'\\n    \1 \2: i32 = \3;\\n'),
    (r'\\n    (let|var|const) (\w+) = (0o[0-7_]+);\\n',
     r'\\n    \1 \2: i32 = \3;\\n'),
    (r'\\n    (let|var|const) (\w+) = (0b[01_]+);\\n',
     r'\\n    \1 \2: i32 = \3;\\n'),
    # plain int (with underscores)
    (r'\\n    (let|var|const) (\w+) = (\d+(?:_\d+)*);\\n',
     r'\\n    \1 \2: i32 = \3;\\n'),
    # null / undefined
    (r'\\n    (let|var|const) (\w+) = null;\\n',
     r'\\n    \1 \2: ?i32 = null;\\n'),
    (r'\\n    (let|var|const) (\w+) = undefined;\\n',
     r'\\n    \1 \2: i32 = undefined;\\n'),
    # arithmetic with two integer literals
    (r'\\n    (let|var|const) (\w+) = (\d+ [+\-*/%] \d+);\\n',
     r'\\n    \1 \2: i32 = \3;\\n'),
]


def migrate(path):
    with open(path, 'r') as f:
        text = f.read()

    counts = {}
    unmatched = []

    new_text = text
    for pat, repl in PATTERNS:
        compiled = re.compile(pat)
        n = len(compiled.findall(new_text))
        if n > 0:
            new_text = compiled.sub(repl, new_text)
            counts[pat] = n

    if new_text != text:
        with open(path, 'w') as f:
            f.write(new_text)

    # Detect still-unmigrated inner bindings as a sanity check
    barere = re.compile(r'\\n\s*(let|var|const)\s+(\w+)\s*=\s*([^;]+);\\n')
    for m in barere.finditer(new_text):
        # filter out the patterns we DID migrate (look for ": T =" pattern)
        if ':' not in m.group(3) and 'tuple_lit' not in m.group(3):
            unmatched.append(m.group(0))

    return counts, unmatched


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else 'src/main.zig'
    counts, unmatched = migrate(path)
    print("Counts:")
    for k, v in counts.items():
        print("  %d: %s" % (v, k[:60]))
    print()
    if unmatched:
        print("Still-missing inner bindings (%d):" % len(unmatched))
        for u in unmatched[:60]:
            print("  %s" % u)
    else:
        print("All inner bindings migrated.")
