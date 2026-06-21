#!/usr/bin/env python3
"""Robust surgical fix for the broken `expression-form if-condition`
regression test in src/main.zig. Replaces two earlier failed scripts.

Why this script is more robust:
  - Uses SMALL, unambiguous anchor patterns (length-tolerant markers)
  - Wraps everything in try/finally so the file is ALWAYS written back,
    even if a runtime sanity-check raises (so partial fixes aren't lost).
  - Splits the const-src block detection into flank-marker searches
    (matching `    const src =\\n` and `    ;\\n`) instead of asserting
    on a single multi-line byte pattern that may not match exactly.
"""
import sys

PATH = 'src/main.zig'

with open(PATH, 'rb') as f:
    original = f.read()

# Work on a copy and write back unconditionally in the finally block.
data = original

try:
    # === Edit 1: stray `b'` Python literal marker in a comment line ===
    broken_b = b"    b'used as an EXPRESSION"
    fixed_b = b"    // used as an EXPRESSION"
    n_b = data.count(broken_b)
    print(f"  Edit 1: stray `b'` markers found in file: {n_b}")
    if n_b == 1:
        data = data.replace(broken_b, fixed_b, 1)
        print(f"  Edit 1: replaced stray `b'` with `//` ({len(broken_b)} bytes)")

    # === Edit 2: broken 3-line `const src =` raw-string-continuation form ===
    # The broken file has:
    #     const src =\n
    #         \\f() { ... }; \\n\n
    #     ;\n
    # Both `\\` (literal 2-byte backslashes) and the broken `\\f()` form
    # are unique to this specific test. We flank-detect via two SHORT
    # unambiguous anchors (`    const src =\n` and `    ;\n`), then
    # claim everything between them as the broken block.
    start_marker = b"    const src =\n"
    end_marker = b"    ;\n"
    start = data.find(start_marker)
    if start != -1:
        # Search for the matching `    ;\n` AFTER the start.
        end = data.find(end_marker, start + len(start_marker))
        if end != -1:
            end += len(end_marker)
            broken_size = end - start
            # Show the broken content for diagnostic visibility:
            print(f"  Edit 2: detected broken block at bytes {start}..{end-1} "
                  f"({broken_size} bytes)")
            single_line_replacement = (
                b'    // (was 3-line broken raw-string form; collapsed to single-line)\n'
                b'    const src = "f() { let x = if Foo { 1 } else { 2 }; let v = '
                b'Vec3 { x: 1, y: 2, z: 3 };\\n}";\n'
            )
            data = data[:start] + single_line_replacement + data[end:]
            print(f"  Edit 2: collapsed to single-line regular-string form "
                  f"({len(single_line_replacement)} bytes)")
        else:
            print(f"  Edit 2: WARN  found `    const src =\\n` at {start} but "
                  f"NO matching `    ;\\n` after it (skipping)")
    else:
        print("  Edit 2: WARN  no `    const src =\\n` anchor found (already fixed?)")

    # === Sanity checks (post-edit, do not crash if Edit 2 skipped) ===
    if b"b'used" in data:
        print("  Sanity: WARN  `b'used` marker still present (Edit 1 failed)")
    else:
        print("  Sanity: OK    no `b'used` marker remains")
    if b"\\\\f()" in data:
        print("  Sanity: WARN  `\\\\f()` form still present (Edit 2 failed)")
    else:
        print("  Sanity: OK    no `\\\\f()` form remains")
    expected_correct = b'const src = "f() { let x = if Foo { 1 } else { 2 }'
    if expected_correct in data:
        print("  Sanity: OK    correct single-line declaration present")
    else:
        print(f"  Sanity: WARN  expected declaration not found, searched for: "
              f"{expected_correct!r}")

finally:
    # ALWAYS write back, even if sanity checks reported warnings. Whether
    # or not the edits took effect, the worst case is a no-op write.
    # This is the critical safety belt that the prior scripts lacked —
    # they bailed out on assertion failure BEFORE reaching the write.
    if data != original:
        with open(PATH, 'wb') as f:
            f.write(data)
        print(f"  Wrote {len(data)} bytes ({len(data)-len(original):+d} delta)")
    else:
        print("  No changes; file left untouched")
