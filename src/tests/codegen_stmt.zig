// Source-mirror test bucket for src/stmt.zig.zig.
// Tests here pin the stmt-codegen's surface. Routing is by test-name
// prefix (see /tmp/zag_split_v3.py's rubric). All test names and bodies
// are byte-identical to the pre-split versions in src/tests/codegen.zig
// (now deleted) / src/tests/parser.zig (now deleted) — only the file
// boundary moved. Total across 11 source-mirror files: 254 tests +
// 3 unchanged small files (lexer.zig, env_path.zig, toolchain.zig) = 302.

const std = @import("std");
const lexer_mod = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const codegen_mod = @import("../codegen.zig");
const ast = @import("../ast.zig");


test "codegen: errdefer stmt emits errdefer verbatim" {
    // Mirrors zig 0.16's `errdefer` keyword one-to-one so zig's semantics
    // (runs the expression ONLY on `?`-propagation or `Err` early-return)
    // match the zag docs' Pattern 2 framing.
    //
    // `errdefer <expr>` triggers genExpr on `expr`. For `print(string_lit)`
    // the call-emit is `__zag_print("...", .{})` (the literal-string
    // specialization). So the errdefer output is
    // `    errdefer __zag_print("cleanup\n", .{});`.
    // Pre-existing test was written when codegen emitted the user's
    // `print(...)` verbatim (a simpler print codegen). Updated to the
    // current stamp-shape substring.
    const src = "fun f() {\n    errdefer print(\"cleanup\\n\");\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    errdefer __zag_print(\"cleanup\\n\", .{})") != null);
}

test "codegen: unsafe block emits body in plain block with comment markers" {
    // zig 0.16 has no block-form `unsafe` keyword — the block is purely a
    // source-level audit marker. Codegen emits the body wrapped in plain
    // `{ ... }` with `// unsafe {` and `// }` comments so the structure is
    // visible to `-Dunsafe-block-check` tooling without affecting the
    // emitted zig semantics (raw pointer ops are already unconditional).
    //
    // The body's `print(string_lit)` codegen emits `__zag_print(...)`,
    // NOT the user's `print(...)` verbatim. Pre-existing test was written
    // when codegen was simpler — updated to the current emission shape.
    const src = "fun f() {\n    unsafe {\n        print(\"inside\\n\");\n    }\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // unsafe {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_print(\"inside\\n\", .{})") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    // }") != null);
}

test "codegen: if-stmt with else emits zig if/else" {
    // Statement form with else: codegen emits `if (cond) { … } else { … }`.
    const src =
        \\fun f() {
        \\    if x > 0 {
        \\        print("pos\n");
        \\    } else {
        \\        print("neg\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if (x > 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    __zag_print(\"neg\\n\", .{});") != null);
}

test "codegen: if-stmt with else-if chain emits chained zig emission" {
    // A multi-arm else-if chain should emit as a single `if/else if/
    // else` zigzag statement — no nested `(blk: { ... })` blocks for the
    // pure statement form.
    const src =
        \\fun f() {
        \\    if a {
        \\        print("a\n");
        \\    } else if b {
        \\        print("b\n");
        \\    } else {
        \\        print("other\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Ident conds now wrap in explicit parens (writeCond — zig 0.16
    // rejects `if a {`), so the pins carry `(a)` / `(b)`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    if (a) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else if (b) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    } else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    __zag_print(\"other\\n\", .{});") != null);
}

test "codegen: if-expression emits labeled block + break" {
    // The expression form must surface as a labeled block yielding a value:
    // `(__blk_N: { if (cond) break :__blk_N <then> else break :__blk_N <else>; })`.
    // The outer parens make the rhs parenthesised so it can sit in
    // any expression position (e.g. RHS of a `let` binding).
    const src =
        \\fun f() {
        \\    let z: i32 = if x > 0 { 1 } else { 0 };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "(__blk_0: { if (x > 0) break :__blk_0 1 else break :__blk_0 0; })") != null);
}

test "codegen: while-stmt emits zig while verbatim" {
    // The cond and body emit directly via zig's native syntax — no shim
    // is needed because zig's `while` semantics match zag's.
    const src =
        \\fun f() {
        \\    while i < 10 {
        \\        i = i + 1;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    while (i < 10) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    i = (i + 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    }") != null);
}

test "codegen: for-range emits zig `start..end[+1]`" {
    // The range shape gets INLINE-emitted as `start..end[ + 1]` so zig's
    // native range syntax (half-open) encodes the inclusive flag without
    // the anonymous-tuple round-trip.
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        print("i\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (0..10) |i| {") != null);
    // Sanity: the .iter not as anonymous struct.
    try std.testing.expect(std.mem.indexOf(u8, zig, "for (.{ 0,") == null);
}

test "codegen: for-incl range emits end+1" {
    // Inclusive range (3-arm `.end + 1`) flips the half-open semantics
    // into inclusive so `for i in 0...10` iterates 0,1,…,10 (not 0,…,9).
    const src =
        \\fun f() {
        \\    for i in 0...10 {
        \\        print("i\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (0..10 + 1) |i| {") != null);
}

test "codegen: for-iter non-range emits verbatim iter call" {
    // For-loop iter that isn't a range emits the user's expression
    // verbatim — codegen bypasses the inline range rewrite.
    const src =
        \\fun f() {
        \\    for x in items() {
        \\        print("x\n");
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    for (items()) |x| {") != null);
}

test "codegen: match-stmt emits labeled laddered if-else" {
    // Each arm gets emitted as an `if (<cond>) { break :<lbl> <body>; }`,
    // chained via `else`. The scrutinee is bound to a `__m_<N>` temp so
    // arm conditions can refer to the value without re-evaluation.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\        _ => "other",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The match's labeled block is uniquely named (`__blk_0`) so a nested
    // match can't collide on a literal `blk`.
    try std.testing.expect(std.mem.indexOf(u8, zig, "(__blk_0: { const __m_0 = n;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__m_0 == 1) { break :__blk_0 \"one\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (__m_0 == 2) { break :__blk_0 \"two\"; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (true) { break :__blk_0 \"other\"; }") != null);
    // Sanity: trail is appended as a `;` (stmt-position append in
    // genStmt `.match_stmt` arm).
    try std.testing.expect(std.mem.indexOf(u8, zig, "});") != null);
}

test "codegen: match-stmt with non-wildcard last emits `else unreachable;`" {
    // When the last arm is NOT a wildcard, codegen appends `else unreachable;`
    // so zig's exhaustive-match check is satisfied and the user gets a
    // compile-time error if they missed a case.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        _ => "other",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // The trailing arm IS a wildcard, so no fallback expected:
    try std.testing.expect(std.mem.indexOf(u8, zig, "unreachable") == null);
}

test "codegen: match-stmt with non-wildcard LAST arm emits \";}\" + unreachable fallback" {
    // The user-confirmed shape: when the chain has NO wildcard arm, codegen
    // must append `else unreachable;` after the last `if (...)` so zig's
    // exhaustive-match check doesn't fail. This pins the exhaustiveness
    // intent explicitly.
    const src =
        \\fun f() {
        \\    match n {
        \\        1 => "one",
        \\        2 => "two",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "} else unreachable;") != null);
}

test "codegen: match-stmt with range arm emits bounds check" {
    // The range arm builds a bounds check on the scrutinee temp. Half-open
    // range `0..10` emits `(>= 0) and (< 10)` so the ladder condition
    // uses zig's native `and` keyword.
    const src =
        \\fun f() {
        \\    match n {
        \\        0..10 => "low",
        \\        _ => "high",
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "((__m_0 >= 0) and (__m_0 < 10))") != null);
}

test "codegen: match-stmt identifies ident arm emits const binding" {
    // An ident-pattern arm (`x => x + 1`) must emit
    // `const x = __m_<N>;` BEFORE the arm body's `break :<lbl>` so the
    // body can reference `x`.
    const src =
        \\fun f() {
        \\    match n {
        \\        x => x + 1,
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "if (true) { const x = __m_0; break :__blk_0 (x + 1); }") != null);
}

test "codegen: match-counter increments per match" {
    // Two match expressions in the same body produce distinct `__m_<N>`
    // names so zig's no-redeclaration rule is satisfied.
    const src =
        \\fun f() {
        \\    match a {
        \\        1 => 10,
        \\        _ => 0,
        \\    };
        \\    match b {
        \\        2 => 20,
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_0 = a") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_1 = b") != null);
}

test "codegen: nested same-name match captures do not shadow" {
    // zig 0.16 rejects an inner local that shadows an outer one, so two
    // matches nested with the SAME capture name cannot both emit
    // `const x = ...`. The arm bodies must keep referring to the source
    // name, so the inner capture is emitted under a unique
    // `__zag_shadow_<N>` spelling and the lookup in `identEmitName`
    // rewrites the body's references to match. Without the rename the
    // generated zig fails with a diagnostic pointing INTO generated code
    // (surfaced while building examples/error-handling/io_robustness.zag,
    // which nests `Err(e)` arms).
    const src =
        \\fun f(a: i32, b: i32) {
        \\    match a {
        \\        x => {
        \\            match b {
        \\                x => x,
        \\                _ => 0,
        \\            };
        \\        },
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Outer capture keeps the source spelling...
    try std.testing.expect(std.mem.indexOf(u8, zig, "const x = __m_0;") != null);
    // ...the inner one is renamed, and the inner body's reference follows.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __zag_shadow_0 = __m_1;") != null);
}

test "codegen: non-colliding match capture emits no shadow rename" {
    // The rename is drawn only on an actual collision, so an ordinary
    // single-level match emits exactly what it did before the fix. This
    // is the property every other pinned match test rests on.
    const src =
        \\fun f(a: i32) {
        \\    match a {
        \\        x => x + 1,
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "const x = __m_0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__zag_shadow_") == null);
}

test "codegen: match { 3 => 99, _ => 0 } yields 99 for scrutinee 3 and 0 otherwise" {
    // Pairs with examples/control-flow/match_expr.zag's `safe` block:
    //   let safe: i32 = match val { 3 => 99, _ => 0 };
    // Pins the non-wildcard literal arm BEFORE the wildcard — codegens
    // to `if (__m_0 == 3) { break :__blk_0 99; }` (literal arm) followed
    // by `break :__blk_0 0;` (wildcard fallback). Mirrors the established
    // match-stmt codegen test convention but specifically targets the
    // new non-wildcard-literal-arm shape that was added to the example
    // to exercise scrutinee capture (and to confirm the `3` arm doesn't
    // get conflated with the wildcard by the codegen).
    //
    // Load-bearing pin: the literal `3` from the AST's literal-arm
    // payload must reach codegen unchanged (as `__m_0 == 3`). A
    // regression that stored the pattern as the scrutinee identifier
    // would surface as `__m_0 == __m_0`.
    const src =
        \\fun f() {
        \\    let x: i32 = 3;
        \\    let result: i32 = match x { 3 => 99, _ => 0 };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Scrutinee bind: captures x to a temp at the start of the match.
    try std.testing.expect(std.mem.indexOf(u8, zig, "const __m_0 = x") != null);
    // The non-wildcard literal arm emits an equality check against the
    // literal `3` — the load-bearing pin (see docstring above).
    try std.testing.expect(std.mem.indexOf(u8, zig, "__m_0 == 3") != null);
    // Literal arm body emits `break :__blk_0 99` so the match expression
    // yields 99 when x == 3.
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :__blk_0 99") != null);
    // Wildcard fallback emits `break :__blk_0 0` — no equality test (the
    // wildcard matches any value, no condition needed). The presence
    // of `break :__blk_0 0` distinguishes this arm from the literal arm above.
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :__blk_0 0") != null);
    // Negative pins (closes reviewer finding's rigor gap):
    // - "literal 3 actually reached codegen" — a regression that
    //   substituted the scrutinee identifier `__m_0` for the
    //   literal-arm payload would emit `__m_0 == __m_0` somewhere.
    //   Forbid that shape so a future degenerate codegen path is loud.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__m_0 == __m_0") == null);
    // - "match counter is fresh per Codegen.init()" — this test has
    //   only ONE match-stmt, so the per-match counter must stay at
    //   `__m_0`. A regression that prematurely increments the counter
    //   within a single init() would surface as `__m_1` (or higher)
    //   appearing in the output despite only one match being present.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__m_1") == null);
}

test "codegen: nested match emits distinct block labels" {
    // A match inside another match's arm must not reuse the match block's
    // label — a literal `blk` produced zig's "redefinition of label
    // 'blk'". Each match now draws a unique `__blk_<N>` from the shared
    // per-function counter, so the inner match gets `__blk_1`.
    const src =
        \\fun f() {
        \\    match a {
        \\        1 => match b {
        \\            2 => 20,
        \\            _ => 0,
        \\        },
        \\        _ => 0,
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__blk_0: { const __m_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "__blk_1: { const __m_1") != null);
    // No literal `blk:` label survives the rename.
    try std.testing.expect(std.mem.indexOf(u8, zig, "(blk:") == null);
}

test "codegen: match arm with tail return emits a real return" {
    // A `return` inside an arm returns from the FUNCTION, not from the
    // match block. The old code lowered a tail `return EXPR` to
    // `break :blk EXPR`, which made a statement-position match whose arms
    // disagreed on value type (returning arm vs void arm) miscompile.
    const src =
        \\fun f() {
        \\    match a {
        \\        1 => {
        \\            return 7;
        \\        },
        \\        _ => {
        \\            print("x");
        \\        },
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "return 7;") != null);
    // The returning arm must NOT be turned into a match-value break.
    try std.testing.expect(std.mem.indexOf(u8, zig, "break :__blk_0 7") == null);
}

test "codegen: break-stmt emits zig break;" {
    // Codegen emits zig's bare `break;` (no label, no value).
    const src =
        \\fun f() {
        \\    while true {
        \\        break;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    break;") != null);
}

test "codegen: continue-stmt emits zig continue;" {
    const src =
        \\fun f() {
        \\    for i in 0..10 {
        \\        continue;
        \\    }
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    continue;") != null);
}

test "codegen: return-stmt with value emits `return <expr>;`" {
    const src = "fun f() {\n    return 42;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return 42;") != null);
    // Sanity: not the bare form.
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return;") == null);
}

test "codegen: bare return emits `return;`" {
    const src = "fun f() {\n    return;\n}\n";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    return;") != null);
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |pos| {
        count += 1;
        rest = rest[pos + needle.len ..];
    }
    return count;
}

test "codegen: match whose arms all end in real statements emits an UNLABELED block" {
    // A match arm only emits `break :<lbl>` when it carries the match's
    // VALUE. When every arm ends in a real statement instead — an
    // assignment, a `return`/`break`/`continue` — nothing breaks the
    // label, and zig rejects the leftover one with "unused block
    // label". That made an ordinary statement-position match fail to
    // compile:
    //
    //   match r {
    //       Ok(n) => { total = total + n; },
    //       Err(e) => { return Err(e); },
    //   }
    //
    // The fix emits `({ ... })` with no label at all in that case.
    const src =
        \\fun f() {
        \\    match a {
        \\        1 => {
        \\            x = 1;
        \\        },
        \\        _ => {
        \\            x = 2;
        \\        },
        \\    };
        \\}
        \\
    ;
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // Unlabeled: `({ const __m_0 = ...`
    try std.testing.expect(std.mem.indexOf(u8, zig, "({ const __m_0") != null);
    // And no label was invented for it.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__blk_0: { const __m_0") == null);
    // Both arms are still emitted in full.
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig, "x = 2;") != null);
}

test "codegen: match with more than 16 arms emits every arm" {
    // parseMatchExpr's arm buffer was a hardcoded `[16]`, indexed without
    // a bounds check: a match with 17+ arms — an ordinary thing to write,
    // e.g. one arm per variant of an enum — ran past the end of the
    // buffer and aborted the COMPILER with `index out of bounds` and no
    // diagnostic. The cap is now the same 256 the parser uses for other
    // list-shaped constructs, with a guard that reports a parse error.
    var src_buf: [1024]u8 = undefined;
    var n: usize = 0;
    n += (std.fmt.bufPrint(src_buf[n..], "fun f() -> i32 {{\n    return match a {{\n", .{}) catch unreachable).len;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        n += (std.fmt.bufPrint(src_buf[n..], "        {d} => {d},\n", .{ i, i * 2 }) catch unreachable).len;
    }
    n += (std.fmt.bufPrint(src_buf[n..], "        _ => 0,\n    }};\n}}\n", .{}) catch unreachable).len;
    const src = src_buf[0..n];

    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    // All 20 numbered arms were parsed and emitted as scrutinee tests.
    try std.testing.expectEqual(@as(usize, 20), countOccurrences(zig, "__m_0 == "));
    // 21 value breaks: the 20 numbered arms plus the `_ => 0` arm, which
    // yields a value too (only real-statement tails skip the break).
    try std.testing.expectEqual(@as(usize, 21), countOccurrences(zig, "break :__blk_0 "));
    // And the highest-numbered literal arm really was emitted.
    try std.testing.expect(std.mem.indexOf(u8, zig, "__m_0 == 19") != null);
}

test "codegen: defer stmt emits defer verbatim" {
    // Mirrors zig 0.16 defer keyword one-to-one so zig semantics
    // (runs the expression on scope exit regardless of return path)
    // match the zag docs Pattern 1 framing. The peer errdefer test
    // in this file documents the errdefer half of the audit pair.
    //
    // `defer <expr>` triggers genExpr on `expr`. For an integer literal
    // like `42` the genExpr arm emits the literal verbatim, so the
    // defer output is `    defer 42;`.
    const src = "fun f() { defer 42; }";
    var l = lexer_mod.Lexer.init(src);
    const tokens = l.tokenize();
    var arena = ast.Arena.init();
    var p = parser_mod.Parser.init(tokens, &arena);
    const prog = p.parse();
    var cg = codegen_mod.Codegen.init();
    const zig = cg.generate(prog);
    try std.testing.expect(std.mem.indexOf(u8, zig, "    defer 42;") != null);
}
