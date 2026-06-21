#!/usr/bin/env python3
"""Append regression tests for enum support to src/main.zig.

Adds 11 tests in two groups:
- 9 parser tests covering: bare decl, multi-variant decl, single-arg
  payload, multi-arg payload, qualified variant with no args,
  qualified variant with payload args, qualified variant pattern,
  unqualified variant pattern, variant pattern with bindings.
- 2 codegen tests covering: bare enum emits `pub const X = enum { }`,
  payload enum emits `pub const X = union(enum) { }`.

Run as `python3 .agents/append_enum_tests.py`. Idempotent: skips append
if a sentinel (the last test name) is already present.
"""
import sys
from pathlib import Path

MAIN_ZIG = Path("/home/lex/Documents/github/zag/src/main.zig")
SENTINEL = "test \"codegen: payload enum decl emits union(enum)\" {"

TESTS = r"""
test "parser: bare enum decl with single variant" {
    const src = "enum Color { Red }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.enums[0].name, "Color"));
    try std.testing.expect(prog.enums[0].variants.len == 1);
    try std.testing.expect(std.mem.eql(u8, prog.enums[0].variants[0].name, "Red"));
    try std.testing.expect(prog.enums[0].variants[0].payload_type == null);
}

test "parser: enum decl with multiple bare variants" {
    const src = "enum Direction { North, South, East, West }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    const ed = prog.enums[0];
    try std.testing.expect(std.mem.eql(u8, ed.name, "Direction"));
    try std.testing.expect(ed.variants.len == 4);
    try std.testing.expect(std.mem.eql(u8, ed.variants[0].name, "North"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[1].name, "South"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[2].name, "East"));
    try std.testing.expect(std.mem.eql(u8, ed.variants[3].name, "West"));
    // All bare: every payload_type slot is null.
    var i: usize = 0;
    while (i < ed.variants.len) : (i += 1) {
        try std.testing.expect(ed.variants[i].payload_type == null);
    }
}

test "parser: enum decl with single-arg payload" {
    const src = "enum Shape { Circle(f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    try std.testing.expect(prog.enums.len == 1);
    const v = prog.enums[0].variants[0];
    try std.testing.expect(std.mem.eql(u8, v.name, "Circle"));
    try std.testing.expect(v.payload_type != null);
    try std.testing.expect(std.mem.eql(u8, v.payload_type.?, "f64"));
}

test "parser: enum decl with multi-arg payload joined verbatim" {
    const src = "enum R { Pair(i32, f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const v = prog.enums[0].variants[0];
    try std.testing.expect(std.mem.eql(u8, v.name, "Pair"));
    try std.testing.expect(v.payload_type != null);
    try std.testing.expect(std.mem.eql(u8, v.payload_type.?, "i32, f64"));
}

test "parser: qualified enum-variant-ctor expression with no args" {
    const src =
        \\fun main() {
        \\    let d: Direction = Direction.North;
        \\    print(d);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .enum_variant_ctor);
    const evc = init.enum_variant_ctor;
    try std.testing.expect(std.mem.eql(u8, evc.enum_name, "Direction"));
    try std.testing.expect(std.mem.eql(u8, evc.variant_name, "North"));
    try std.testing.expect(evc.args.len == 0);
}

test "parser: qualified enum-variant-ctor with payload args" {
    const src =
        \\fun main() {
        \\    let s: Shape = Shape.Circle(2.5);
        \\    print(s);
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const init = prog.functions[0].body[0].let.init;
    try std.testing.expect(init == .enum_variant_ctor);
    const evc = init.enum_variant_ctor;
    try std.testing.expect(std.mem.eql(u8, evc.enum_name, "Shape"));
    try std.testing.expect(std.mem.eql(u8, evc.variant_name, "Circle"));
    try std.testing.expect(evc.args.len == 1);
    try std.testing.expect(evc.args[0] == .float_lit);
    try std.testing.expect(std.mem.eql(u8, evc.args[0].float_lit, "2.5"));
}

test "parser: qualified enum-variant pattern in match" {
    const src =
        \\fun main() {
        \\    match d {
        \\        Direction.North => 1,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].expr_stmt.match_expr.arms;
    try std.testing.expect(arms.len == 2);
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(std.mem.eql(u8, ev.enum_name, "Direction"));
    try std.testing.expect(std.mem.eql(u8, ev.variant_name, "North"));
    try std.testing.expect(ev.bindings == null);
    try std.testing.expect(arms[1].pat == .discard);
}

test "parser: unqualified enum-variant pattern in match" {
    const src =
        \\fun main() {
        \\    match d {
        \\        North => 1,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].expr_stmt.match_expr.arms;
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(std.mem.eql(u8, ev.enum_name, ""));
    try std.testing.expect(std.mem.eql(u8, ev.variant_name, "North"));
    try std.testing.expect(ev.bindings == null);
}

test "parser: enum-variant pattern with bindings" {
    const src =
        \\fun main() {
        \\    match v {
        \\        Some(x) => x,
        \\        _ => 0,
        \\    }
        \\}
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    const arms = prog.functions[0].body[0].expr_stmt.match_expr.arms;
    try std.testing.expect(arms[0].pat == .enum_variant);
    const ev = arms[0].pat.enum_variant;
    try std.testing.expect(ev.bindings != null);
    try std.testing.expect(ev.bindings.?.len == 1);
    try std.testing.expect(ev.bindings.?[0] != null);
    try std.testing.expect(std.mem.eql(u8, ev.bindings.?[0].?, "x"));
}

test "codegen: bare enum decl emits pub const NAME = enum { ... }" {
    const src = "enum Direction { North, South }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Direction") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "North") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "South") != null);
    // Bare (no payload) — uses regular `enum`, not `union(enum)`.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "union(enum)") == null);
}

test "codegen: payload enum decl emits union(enum)" {
    const src = "enum Shape { Circle(f64), Rect(f64, f64) }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig_src = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Shape") != null);
    // At least one variant has a payload → zig output must use union(enum).
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "Rect") != null);
}
"""

def main() -> int:
    text = MAIN_ZIG.read_text()
    if SENTINEL in text:
        print("[skip] enum tests already appended to src/main.zig")
        return 0
    if not text.endswith("\n"):
        text += "\n"
    text += TESTS
    MAIN_ZIG.write_text(text)
    added = TESTS.count("\ntest \"")
    print(f"[ok] appended {added} enum tests to src/main.zig ({len(text)} bytes)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
