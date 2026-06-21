#!/usr/bin/env python3
"""Apply the thinker-recommended fix to scripts/lexer_split.py.

Diagnosis: a previous regex botched the trailing `\\n'` on lines 117-124 of
SUBFILE_IMPORTS['core.zig'], so each of those lines has only an opening
apostrophe and Python reports 'unterminated string literal detected at
line 117'.

Fix strategy: rewrite the 9-line SUBFILE_IMPORTS['core.zig'] comment block
to use DOUBLE-QUOTED Python strings — apostrophes inside `"..."` need no
escape, sidestepping the `\\'` fragility entirely.

The OLD/NEW blocks are stored as Python triple-quoted strings without
embedded `\\n`-escape mangling so we can do exact byte comparisons.
"""
import sys

PATH = 'scripts/lexer_split.py'

# The OLD broken block (what the file currently has).
# Each of the first 8 lines is missing its closing `'\n`; only the 9th
# line (`'// alias here.\n`) has the proper closing.
OLD = """\
                     '// Module-scope aliases only — there is NO inner
                     '// `pub const Token/TokenTag` on the Lexer struct
                     '// (would conflict with `const Token =` if we also
                     '// added it as a struct-member alias). External
                     '// callers reach `Token`/`TokenTag` via the
                     '// aggregator\\'s module-scope re-exports; the
                     '// bottom-of-files field `tokens_buf: [4096]Token`
                     '// resolves to the module-scope `const Token = ...`
                     '// alias here.\\n\
"""

# The NEW fixed block: each line is a properly-terminated double-quoted
# Python string. Apostrophes inside double-quoted strings (line 6:
# `aggregator's`) need no escape.
NEW = '''\
                     "// Module-scope aliases only — there is NO inner\\n"
                     "// `pub const Token/TokenTag` on the Lexer struct\\n"
                     "// (would conflict with `const Token =` if we also\\n"
                     "// added it as a struct-member alias). External\\n"
                     "// callers reach `Token`/`TokenTag` via the\\n"
                     "// aggregator's module-scope re-exports; the\\n"
                     "// bottom-of-files field `tokens_buf: [4096]Token`\\n"
                     "// resolves to the module-scope `const Token = ...`\\n"
                     "// alias here.\\n"\
'''

with open(PATH, 'r', encoding='utf-8') as f:
    src = f.read()

n = src.count(OLD)
print(f'OLD block occurrences: {n}')
if n != 1:
    # Diagnostics: show first 'aggregator' or 'Module-scope' line in the file.
    for marker in ['Module-scope aliases only', '`aggregator\\\'s`', 'aggregator\\\\\\\'s']:
        idx = src.find(marker)
        if idx >= 0:
            print(f'  marker {marker!r} @ char {idx}')
    sys.exit(1)

new_src = src.replace(OLD, NEW, 1)
with open(PATH, 'w', encoding='utf-8') as f:
    f.write(new_src)
print(f'WROTE replacement ({len(OLD)} -> {len(NEW)} chars)')

# Final compile check.
try:
    compile(new_src, PATH, 'exec')
    print('PYTHON PARSE: OK')
except SyntaxError as e:
    print(f'PYTHON PARSE: line {e.lineno}: {e.msg}')
    if e.lineno:
        ls = new_src.split('\n')
        print(f'  line {e.lineno}: {ls[e.lineno - 1]!r}')
    sys.exit(1)
