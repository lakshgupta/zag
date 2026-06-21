#!/usr/bin/env python3
"""Migrate bare bindings to typed form. Python 2/3 compatible (no f-strings)."""

import re
import sys


def infer_type(init):
    s = init.strip()
    if re.match(r'^b".*"$', s):
        return "[]const u8"
    if re.match(r"^'[^']'$", s) or re.match(r"^'\\.'$", s) or re.match(r"^'\\u[0-9a-fA-F]+'$", s):
        return "u8"
    if re.match(r'^0x[0-9a-fA-F_]+$', s):
        return "i32"
    if re.match(r'^0o[0-7_]+$', s):
        return "i32"
    if re.match(r'^0b[01_]+$', s):
        return "i32"
    if re.match(r'^[0-9_]+$', s):
        return "i32"
    if re.match(r'^[0-9_]+\.[0-9_]*([eE][0-9_]+)?$', s) \
       or re.match(r'^[0-9_]+[eE][0-9_]+$', s):
        return "f64"
    if re.match(r'^0x[0-9a-fA-F_]*\.[0-9a-fA-F_]*p[0-9_]+$', s):
        return "f64"
    if s in ("true", "false"):
        return "bool"
    if re.match(r'^"[^"]*"$', s) and '{' not in s:
        return "[]const u8"
    if re.match(r'^".*"$', s) and '{' in s:
        return "[]u8"
    if s == "null":
        return "?i32"
    if s == "undefined":
        return "i32"
    return None


def is_simple_tuple_lit(s):
    s = s.strip()
    return s.startswith('(') and s.endswith(')') and ',' in s and s.count('(') == 1


def split_tuple_lit(s):
    return [p.strip() for p in s.strip()[1:-1].split(',')]


BINDING_RE = re.compile(
    r'^(?P<indent>[ \t]*)'
    r'(?P<kw>let|var|const)'
    r'\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)'
    r'(?P<has_colon>:\s*[^=;]*?)?'
    r'\s*=\s*'
    r'(?P<init>[^;]*)'
    r';[ \t]*$'
)


def should_skip(name, has_colon):
    if name == "_":
        return True
    if name.startswith("__"):
        return True
    if has_colon:
        return True
    return False


def transform_line(line):
    m = BINDING_RE.match(line)
    if not m:
        return line, "no-match"
    indent = m.group('indent')
    kw = m.group('kw')
    name = m.group('name')
    init = m.group('init')
    has_colon = m.group('has_colon') is not None
    if should_skip(name, has_colon):
        return line, "skipped"

    if is_simple_tuple_lit(init):
        parts = split_tuple_lit(init)
        leaves = []
        for p in parts:
            t = infer_type(p)
            if t is None:
                return line, "tuple-leaf-uninferrable"
            leaves.append("%s: %s" % (p, t))
        body = ", ".join(leaves)
        new = "%s%s (%s) = %s;\n" % (indent, kw, body, init)
        return new, "tuple-destructured"

    t = infer_type(init)
    if t is None:
        return line, "uninferrable"
    new = "%s%s %s: %s = %s;\n" % (indent, kw, name, t, init)
    return new, "annotated:%s" % t


def transform(text):
    out_lines = []
    counts = {}
    unmatched = []
    for line in text.splitlines(keepends=True):
        new_line, status = transform_line(line)
        if status != "no-match":
            counts[status] = counts.get(status, 0) + 1
        if status == "uninferrable":
            unmatched.append(line.rstrip('\n'))
        out_lines.append(new_line)
    return "".join(out_lines), counts, unmatched


def process(path):
    with open(path, 'r') as f:
        text = f.read()
    new_text, counts, unmatched = transform(text)
    if new_text != text:
        with open(path, 'w') as f:
            f.write(new_text)
    return counts, unmatched


if __name__ == "__main__":
    paths = sys.argv[1:]
    grand_counts = {}
    grand_unmatched = []
    for p in paths:
        try:
            c, u = process(p)
        except Exception as e:
            print("ERROR on %s: %s" % (p, e))
            continue
        if c or u:
            print("\n%s" % p)
            for k, v in sorted(c.items()):
                print("  %s: %d" % (k, v))
            if u:
                print("  unmatched:")
                for x in u:
                    print("    %s" % x)
                grand_unmatched.extend(["%s: %s" % (p, x) for x in u])
        for k, v in c.items():
            grand_counts[k] = grand_counts.get(k, 0) + v

    print("\n=== TOTAL ===")
    for k, v in sorted(grand_counts.items()):
        print("  %s: %d" % (k, v))
    if grand_unmatched:
        print("\nGrand unmatched (%d):" % len(grand_unmatched))
        for x in grand_unmatched[:60]:
            print("  %s" % x)
