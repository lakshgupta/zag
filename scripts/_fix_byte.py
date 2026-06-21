#!/usr/bin/env python3
"""Byte-level fix using explicit numeric byte values (no string escapes).

Find broken chunk: aggregator (10) + ' (1) + \ (1) + ' (1) + ' (1) + s (1) = 15 bytes
Replace with:      aggregator (10) + \ (1) + ' (1) + s (1)                  = 13 bytes

Use numeric byte literals so there's zero ambiguity about what we're matching.
"""
import sys

PATH = 'scripts/lexer_split.py'

# Each byte by its code-point (ASCII):
BROKEN_BYTES = bytes([
    97, 103, 103, 114, 101, 103, 97, 116, 111, 114,  # aggregator
    39,                                                   # '
    92,                                                   # \
    39,                                                   # '
    39,                                                   # '
    115,                                                  # s
])
# = 15 bytes:  b"aggregator'\\''s"

FIXED_BYTES = bytes([
    97, 103, 103, 114, 101, 103, 97, 116, 111, 114,  # aggregator
    92,                                                   # \
    39,                                                   # '
    115,                                                  # s
])
# = 13 bytes:  b"aggregator\\'s"

# Sanity-check by also expressing as Python bytes literals (via repr-encoding).
assert BROKEN_BYTES == b"aggregator'\\''s", f'BROKEN mismatch: got {BROKEN_BYTES!r}'
assert FIXED_BYTES  == b"aggregator\\'s",  f'FIXED mismatch:  got {FIXED_BYTES!r}'

with open(PATH, 'rb') as f:
    raw = f.read()

n = raw.count(BROKEN_BYTES)
print(f'Occurrences of broken sequence (15 bytes): {n}')

# Also check for the fixed sequence already present (in case a previous run succeeded).
m = raw.count(FIXED_BYTES)
print(f'Pre-existing occurrences of fixed sequence (13 bytes): {m}')

if n == 0:
    print('NOTHING to fix.')
else:
    new_raw = raw.replace(BROKEN_BYTES, FIXED_BYTES)
    with open(PATH, 'wb') as f:
        f.write(new_raw)
    print(f'FIXED: replaced {n} occurrence(s).')

# Compile check.
try:
    src = new_raw.decode('utf-8') if 'new_raw' in dir() else raw.decode('utf-8')
    compile(src, PATH, 'exec')
    print('PYTHON PARSE: OK')
except SyntaxError as e:
    print(f'PYTHON PARSE: line {e.lineno}: {e.msg}')
    lines = src.split('\n')
    if e.lineno and e.lineno <= len(lines):
        print(f'  line {e.lineno}: {lines[e.lineno - 1]!r}')
    sys.exit(1)
