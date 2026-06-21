#!/usr/bin/env python3
"""Rewrite SUBFILE_IMPORTS['core.zig'] in scripts/lexer_split.py to have
apostrophe-free comments. The original block has an apostrophe escape
sequence inside a single-quoted Python string that cannot be parsed by
the shell-driven heredoc setup we keep using; rephrasing to avoid the
apostrophe entirely removes the fragility.
"""
import re

PATH = 'scripts/lexer_split.py'

# Replacement value for the 'core.zig' dict entry (no apostrophes anywhere).
# We keep the structural shape (single-quoted Python strings implicitly
# concatenated, each ending with `'\n'` properly closed) to match the
# surrounding code style.
NEW_CORE_VALUE = (
    "    'core.zig':      ('const std = @import(\"std\");\\n'"
    "                     'const ast = @import(\"../ast.zig\");\\n'"
    "                     '\\n'"
    "                     '// Module-scope aliases ONLY: no inner pub const\\n'"
    "                     '// for Token or TokenTag on the Lexer struct\\n'"
    "                     '// (would conflict with the module-scope const).\\n'"
    "                     '// External callers reach Token or TokenTag via\\n'"
    "                     '// the AGGREGATOR module-scope re-exports\\n'"
    "                     '// and the bottom-of-file field tokens_buf\\n'"
    "                     '// resolves to this module-scope const.\\n'"
    "                     'const token = @import(\"token.zig\");\\n'"
    "                     'const TokenTag = token.TokenTag;\\n'"
    "                     'const Token = token.Token;'),"
)

with open(PATH, 'r', encoding='utf-8') as f:
    src = f.read()

# Find the existing 'core.zig' dict value via regex.
# The value starts at `'core.zig':      (`  and ends at the matching `),`.
pattern = re.compile(
    r"    'core\.zig':\s+\((.*?)\),",
    re.DOTALL,
)
m = pattern.search(src)
if not m:
    print('NO MATCH for SUBFILE_IMPORTS[core.zig] dict value')
    raise SystemExit(1)

# Replace the entire match (including outer parens).
old_full = m.group(0)
print(f'OLD block: {len(old_full)} chars')
print(f'OLD block starts: {old_full[:80]!r}')
print(f'OLD block ends:   {old_full[-80:]!r}')

new_src = src[:m.start()] + NEW_CORE_VALUE + src[m.end():]
with open(PATH, 'w', encoding='utf-8') as f:
    f.write(new_src)
print(f'WROTE new_src: replaced {len(old_full)} chars with {len(NEW_CORE_VALUE)} chars')

# Final compile check.
try:
    compile(new_src, PATH, 'exec')
    print('PYTHON PARSE: OK')
except SyntaxError as e:
    print(f'PYTHON PARSE: line {e.lineno}: {e.msg}')
    if e.lineno:
        ls = new_src.split('\n')
        print(f'  line {e.lineno}: {ls[e.lineno - 1]!r}')
    raise SystemExit(1)
