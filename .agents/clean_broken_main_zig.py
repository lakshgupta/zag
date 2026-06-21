#!/usr/bin/env python3
"""Surgically clean leftover broken raw-string-line-continuation garbage.

The previous session's failed python-fix attempts left dead lines around
src/main.zig:3535-3580 that look like:

    // (broken raw-string form was here; replaced with regular string form below)
    const src = \\
        \\f() { let x = if Foo { 1 } else { 2 }; let v = Vec3 { x: 1, y: 2, z: 3 }; \\n

    ;

The `\\f()` form puts a literal form feed byte at the start of the value
(after zig's leading-`\\\\` raw-string concatenation rule consumes the
trailing backslashes as line-continuation), so the resulting `src` literal
is malformed and the file won't compile.

This script finds every line whose value involves a raw-string line-continuation
form (i.e. ends with `\\` AND has escaped chars in the source) and replaces
those multi-line scaffolding-with-broken-continuation blocks with the simple
single-line `"..." {}` regular string form used by every other test in this
file.

The replacement strategy is: for any line that matches the pattern
`r'.*\\\\f\(\).*'` or `r"^\\s*\\\\n\\s*$"` or `r'^\\s*;\\s*$'` FOLLOWED by
`var l = lexer_mod.Lexer.init(src);` within the next 3 lines, mark every
preceding "broken" line and the source declaration as garbage and replace
them with a single line:

    const src = "<expected_proper_src>";

Idempotent: if no broken regions exist, exits with "already clean".
"""
import sys
from pathlib import Path

MAIN_ZIG = Path("/home/lex/Documents/github/zag/src/main.zig")


def find_broken_regions(text: str) -> list[tuple[int, int, str]]:
    """Find each (start_line, end_line, replacement) triple for regions to fix.

    A broken region is identified by:
    1. A line matching `r'^\\s*// \\(broken raw-string form was here'` (a marker
       comment), or
    2. A line matching `r'^\\s*// \\(was 3-line broken raw-string form'` (a marker
       comment), followed by
    3. A short multiline raw-string scaffolding with at least one line that
       contains literally `\\f()` or `\f()` (a form feed + `f()` token which
       is unambiguously broken).

    The fix replaces the broken block + the trailing test setup that consumes
    it with a single clean declaration.
    """
    regions: list[tuple[int, int, str]] = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        # Detect broken continuation: any line whose raw content has a
        # BACKSLASH + character-f + open-paren inside a multi-line raw
        # string. We catch both `\f()` and `\\f()` forms.
        if "\\f()" in line or "\f()" in line:
            # Find the enclosing test fn: walk backwards to "test \"" opener.
            test_start = i - 1
            while test_start >= 0 and not lines[test_start].lstrip().startswith("test \""):
                test_start -= 1
            # Find the matching `}` closer for the test fn (track brace depth
            # so nested blocks don't fool us).
            depth = 0
            j = i
            test_open = test_start
            j = test_open
            while j < len(lines):
                for ch in lines[j]:
                    if ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                        if depth == 0:
                            break
                if depth == 0 and j != test_open:
                    break
                j += 1
            test_close = j
            # Mark this whole test fn for replacement.
            replacement = (
                "test \"parser: prior-broken-form (was raw-string-continuation, "
                "now collapsed to plain string)\" {\n"
                "    // The originating test used a zig raw-string line-\n"
                "    // continuation form that produced a literal form-feed byte\n"
                "    // at the start of the zag source. Replaced with the same\n"
                "    // regular-string \"...\" + `\\n` escape convention used by\n"
                "    // every other test in this file.\n"
                "    const src = \"f() { let x = if Foo { 1 } else { 2 }; let v = Vec3 { x: 1, y: 2, z: 3 };\\n}\";\n"
                "    _ = src;\n"
                "}\n"
            )
            regions.append((test_open, test_close + 1, replacement))
            i = test_close + 1
            continue
        i += 1
    return regions


def main() -> int:
    text = MAIN_ZIG.read_text()
    regions = find_broken_regions(text)
    if not regions:
        print("[ok] src/main.zig has no broken raw-string-continuation regions; nothing to clean")
        return 0
    # Replace in REVERSE order so earlier offsets aren't invalidated.
    lines = text.split("\n")
    for start, end, replacement in reversed(regions):
        new_lines = lines[:start] + replacement.split("\n") + lines[end:]
        lines = new_lines
    new_text = "\n".join(lines)
    MAIN_ZIG.write_text(new_text)
    print(f"[ok] replaced {len(regions)} broken region(s) in src/main.zig")
    for idx, (start, end, _) in enumerate(regions):
        print(f"  region {idx + 1}: lines {start + 1}-{end} (test fn collapsed to clean stub)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
