// Auto-extracted from src/main.zig. Tests live here so main.zig
// stays focused on CLI plumbing. Zigs `test "..." {}` discovery
// follows the comptime imports at the bottom of main.zig.

const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const codegen_mod = @import("../codegen.zig");
const ast = @import("../ast.zig");

test "lexer: hello world" {
    const src = "fun main() {\n    print(\"hello, world\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var count: usize = 0;
    for (tokens) |tok| {
        if (tok.tag != .newline) count += 1;
    }

    try std.testing.expectEqual(@as(usize, 11), count);
    try std.testing.expectEqual(lexer_mod.TokenTag.fun, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.lparen, tokens[2].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.rparen, tokens[3].tag);
}

test "lexer: line comment is skipped" {
    const src = "# a comment\nfun main() {\n    print(\"hi\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var has_doc = false;
    for (tokens) |tok| {
        if (tok.tag == .doc_comment) has_doc = true;
    }
    try std.testing.expect(!has_doc);
    try std.testing.expectEqual(lexer_mod.TokenTag.newline, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.fun, tokens[1].tag);
}

test "lexer: single-line doc comment" {
    const src = "## greets the user\nfun main() {\n    print(\"hi\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    try std.testing.expectEqual(lexer_mod.TokenTag.doc_comment, tokens[0].tag);
    try std.testing.expect(std.mem.indexOf(u8, tokens[0].text, " greets the user") != null);
}

test "lexer: multi-line doc comment with continuation" {
    const src = "## reads a file\n# returns error on missing\nfun read() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    try std.testing.expectEqual(lexer_mod.TokenTag.doc_comment, tokens[0].tag);
    try std.testing.expect(std.mem.indexOf(u8, tokens[0].text, "reads a file") != null);
    try std.testing.expect(std.mem.indexOf(u8, tokens[0].text, "returns error on missing") != null);
}

test "lexer: consecutive ## starts new doc block" {
    const src = "## first\n## second\nfun f() {\n    print(\"\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();

    var doc_count: usize = 0;
    var expected_first = false;
    var expected_second = false;
    for (tokens) |tok| {
        if (tok.tag == .doc_comment) {
            doc_count += 1;
            if (std.mem.indexOf(u8, tok.text, "first") != null) expected_first = true;
            if (std.mem.indexOf(u8, tok.text, "second") != null) expected_second = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), doc_count);
    try std.testing.expect(expected_first);
    try std.testing.expect(expected_second);
}

test "lexer: hex integer prefix" {
    const src = "0xFF";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("0xFF", tokens[0].text);
}

test "lexer: octal integer prefix" {
    const src = "0o77";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("0o77", tokens[0].text);
}

test "lexer: binary integer prefix" {
    const src = "0b1010";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("0b1010", tokens[0].text);
}

test "lexer: integer with underscores" {
    const src = "1_000_000";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("1_000_000", tokens[0].text);
}

test "lexer: float literal decimal" {
    const src = "3.14";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.float_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("3.14", tokens[0].text);
}

test "lexer: float literal exponent" {
    const src = "1.0e10";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.float_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("1.0e10", tokens[0].text);
}

test "lexer: float literal without fractional" {
    const src = "1e10";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.float_literal, tokens[0].tag);
}

test "lexer: dot after integer is not float" {
    // `42.method()` style: the . should not be consumed as a float
    const src = "42";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
}

test "lexer: true/false/null/undefined as keywords" {
    const src = "true false null undefined";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.true_kw, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.false_kw, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.null_kw, tokens[2].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.undefined_kw, tokens[3].tag);
}

test "lexer: char literal simple" {
    const src = "'a'";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.char_literal, tokens[0].tag);
}

test "lexer: char literal escape" {
    const src = "'\\n'";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.char_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("'\\n'", tokens[0].text);
}

test "lexer: byte string literal" {
    const src = "b\"hello\"";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.byte_string_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("hello", tokens[0].text);
}

test "lexer: lbracket and rbracket and ellipsis tokens" {
    var l = lexer_mod.Lexer.init("[1]i32 { 10 ... }");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.lbracket, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.rbracket, tokens[2].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.lbrace, tokens[4].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[5].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.ellipsis, tokens[6].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.rbrace, tokens[7].tag);
}

test "lexer: arithmetic operators are tokens" {
    var l = lexer_mod.Lexer.init("a + b - c * d / e");
    const tokens = l.tokenize();
    const seq = [_]lexer_mod.TokenTag{
        .identifier, .plus, .identifier, .minus, .identifier, .star, .identifier, .slash, .identifier,
    };
    var i: usize = 0;
    // `tokens` includes an `.eof` sentinel at the end — without the break,
    // the loop accesses `seq[9]` past the 9-element array and panics. Same
    // treatment for `.newline` so the loop counts only meaningful tokens.
    for (tokens) |tok| {
        if (tok.tag == .eof) break;
        if (tok.tag == .newline) continue;
        try std.testing.expectEqual(seq[i], tok.tag);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), i);
}

test "lexer: minus between variables is binary operator" {
    // Regression: previously `-` after a non-digit was routed to readNumber
    // and emitted a bogus `integer_literal "-"`. Confirm we now emit `.minus`.
    var l = lexer_mod.Lexer.init("x - y");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.minus, tokens[1].tag);
    try std.testing.expectEqualStrings("-", tokens[1].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[2].tag);
}

test "lexer: plus between variables is binary operator" {
    // Regression: previously `+` fell into the unhandled-char `else` branch
    // and was silently self.advance()'d, dropping the operator entirely.
    var l = lexer_mod.Lexer.init("x + y");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.plus, tokens[1].tag);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[2].tag);
}

test "lexer: positive number prefix still parses" {
    // Symmetry: `+5` should still lex as one integer literal, not as `+` then `5`.
    var l = lexer_mod.Lexer.init("+5");
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.integer_literal, tokens[0].tag);
    try std.testing.expectEqualStrings("+5", tokens[0].text);
}

test "lexer: var is a keyword" {
    const src = "var x = 1";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.var_kw, tokens[0].tag);
    try std.testing.expectEqualStrings("var", tokens[0].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("x", tokens[1].text);
}

test "lexer: const is a keyword" {
    const src = "const x = 1";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.const_kw, tokens[0].tag);
    try std.testing.expectEqualStrings("const", tokens[0].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("x", tokens[1].text);
}

test "lexer: errdefer_kw, unsafe_kw, as_kw are keywords" {
    const src = "errdefer unsafe as";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    try std.testing.expectEqual(lexer_mod.TokenTag.errdefer_kw, tokens[0].tag);
    try std.testing.expectEqualStrings("errdefer", tokens[0].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.unsafe_kw, tokens[1].tag);
    try std.testing.expectEqualStrings("unsafe", tokens[1].text);
    try std.testing.expectEqual(lexer_mod.TokenTag.as_kw, tokens[2].tag);
    try std.testing.expectEqualStrings("as", tokens[2].text);
}

test "lexer: control-flow keywords (if/else/while/for/in/match/break/continue)" {
    // Per docs/06-control-flow.md. Each is reserved with `_kw` suffix
    // because the underlying zigzag is reserved in Zig 0.16 (mirrors the
    // `var_kw`/`as_kw`/`return_kw` naming), so a future AST/parser/codegen
    // pass for the docs/06 surface can dispatch on `.if_kw` etc. without
    // colliding with zig's grammar.
    const src = "if else while for in match break continue";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    const expected_tags = [_]lexer_mod.TokenTag{
        .if_kw,    .else_kw,
        .while_kw, .for_kw,
        .in_kw,    .match_kw,
        .break_kw, .continue_kw,
    };
    const expected_texts = [_][]const u8{
        "if",    "else",
        "while", "for",
        "in",    "match",
        "break", "continue",
    };
    // Use a simple counter instead of @intFromPtr arithmetic — pointer
    // math on a `for`-loop iteration variable computes gibberish because
    // `tag` lives on the stack, NOT as an element of `expected_tags`.
    // (This previously panicked at runtime with `index out of bounds`.)
    var i: usize = 0;
    for (expected_tags, expected_texts) |tag, text| {
        try std.testing.expectEqual(tag, tokens[i].tag);
        try std.testing.expectEqualStrings(text, tokens[i].text);
        i += 1;
    }
}

