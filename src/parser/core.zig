const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");

const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

/// Test-case naming convention for `test_file` mode: a top-level fun
/// whose name starts with `test_` is a test case. `main` can never
/// match (no prefix), so entry points stay plain functions even in
/// test files. File-scope free fn (not a Parser method) so both the
/// free-function `parse()` driver and any future method callers use
/// one spelling.
fn isTestCaseName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "test_");
}


pub fn init(tokens: []const Token, arena: *ast.Arena) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
            .allow_struct_lit = true,
            // Gap #2 closure (docs/manual/14-unions §Mixed Bare + Payload):
            // known_variant_names tracks every variant ident declared at
            // module scope (push sites: parseEnumDecl/parseUnionDecl). The
            // table powers parsePrimary's `.identifier` arm disambiguation
            // so `Pair { x: 2.0, y: 3.0 }` (unqualified brace) routes to
            // `enum_variant_ctor { enum_name = null, ... }` when `Pair` is
            // in the table, falling through to `.struct_lit` otherwise.
            // Reset to zero on init() so a Parser reused across multiple
            // codegen-pass calls (e.g. smoke+scaffold tests in one process)
            // doesn't carry stale variant names between files.
            .known_variant_names = undefined,
            .known_variant_count = 0,
            // BLOCKING #2 fix: known_struct_names tracking parallel to
            // known_variant_names. Populated by parseStructDecl on the
            // top-level decl-completion hook so parsePrimary can
            // prefer struct-literal when an ident matches BOTH a struct
            // decl AND a brace-named-field variant name. Reset to empty
            // on init() so a Parser reused across multiple codegen-pass
            // calls (smoke + scaffold + e2e in one process) starts
            // fresh — same pattern as the variant table reset above.
            .known_struct_names = undefined,
            .known_struct_count = 0,
            // Whole-module import expansion (v2 self-hosting): injectable
            // file reader the expansion pass uses to parse the target
            // stdlib module and synthesize selectors from its top-level
            // decls. Null (default: tests) disables expansion — a
            // whole-module import then binds nothing (the pre-expansion
            // behavior). main.zig injects a posix open/read wrapper so
            // production transpiles get the expansion.
            .read_source_file = null,
        };
    }


pub fn parse(self: *Parser) ast.Program {
        var functions_buf: [256]ast.FunDecl = undefined;
        var fun_count: usize = 0;
        var structs_buf: [256]ast.StructDecl = undefined;
        var struct_count: usize = 0;
        var impls_buf: [256]ast.ImplBlock = undefined;
        var impl_count: usize = 0;
        var enums_buf: [256]ast.EnumDecl = undefined;
        var enum_count: usize = 0;
        var traits_buf: [256]ast.TraitDecl = undefined;
        var trait_count: usize = 0;
        var imports_buf: [256]ast.ImportDecl = undefined;
        var import_count: usize = 0;
        var uses_buf: [64]ast.UseDecl = undefined;
        var use_count: usize = 0;
        var externs_buf: [256]ast.ExternDecl = undefined;
        var extern_count: usize = 0;
        var consts_buf: [256]ast.ConstDecl = undefined;
        var const_count: usize = 0;

        while (!self.eof()) {
            if (self.peek().tag == .newline) {
                self.advance();
                continue;
            }
            var doc: ?[]const u8 = null;
            while (self.peek().tag == .doc_comment) {
                doc = self.peek().text;
                self.advance();
                while (self.peek().tag == .newline) self.advance();
            }
            if (self.eof()) break;
            // Check for `@[test]` annotation before declarations.
            var is_test = false;
            if (self.peek().tag == .test_annotation) {
                is_test = true;
                self.advance();
                while (self.peek().tag == .newline) self.advance();
            }
            // `pub` marker for the decl about to be parsed. Consumed by
            // the `.pub_kw` dispatcher below and read by the decl arms
            // that carry an `is_pub` AST slot (`const` / `var` — so
            // `pub const NAME = ...` emits zig's `pub const` and the
            // binding is reachable from importing modules).
            var is_pub = false;
            // Top-level dispatch: structs and impl blocks live alongside
            // top-level functions. The dispatch is order-independent at
            // codegen time (codegen re-walks and interleaves struct fields
            // with their matching impl-method-NESTED-inside emission), so
            // the parser simply records each decl in its appropriate slice
            // and preserves source order across all three.
            const lead = self.peek().tag;
            // `pub` prefix carve-out at the dispatcher. The individual
            // decl-parsers (parseStructDecl / parseImplBlock /
            // parseEnumDecl / parseTraitDecl / parseFunDecl) all start
            // with `expect(.struct_kw)` / `.impl_kw` / etc. and reject
            // a leading `.pub_kw` with `expected <kw>, got 'pub'`.
            // Without the advance below, the lib/std/X.zag stubs
            // (which uniformly write `pub struct` / `pub enum` /
            // `pub trait` / `pub fun`) hit that error and crash the
            // scaffold tests. Mirrors the `pub` carve-out in
            // `parseMethod` (inside impl blocks) which already
            // accept-and-ignore `pub` before `expect(.fun)`. Privacy
            // enforcement is deferred — `pub` is preserved at the
            // AST surface for any future use but codegen does not
            // gate emission on `pub` (all generated decls already
            // emit zig's `pub fn` / `pub const`).
            if (lead == .pub_kw) {
                // Peek the second token to route to the right parser.
                // Mirrors the impl-block shape `pub fun NAME(...)`
                // that parseMethod handles; the top-level form is
                // the same parser surface, just at module scope.
                const after_pub = self.peekAhead(1);
                if (after_pub == .struct_kw or after_pub == .impl_kw or
                    after_pub == .enum_kw or after_pub == .union_kw or
                    after_pub == .trait_kw or after_pub == .fun or
                    after_pub == .const_kw or after_pub == .var_kw)
                {
                    self.advance(); // consume pub
                    is_pub = true;
                    switch (after_pub) {
                        .struct_kw => {
                            structs_buf[struct_count] = self.parseStructDecl();
                            structs_buf[struct_count].doc = doc;
                            struct_count += 1;
                        },
                        .impl_kw => {
                            impls_buf[impl_count] = self.parseImplBlock();
                            impl_count += 1;
                        },
                        .enum_kw => {
                            enums_buf[enum_count] = self.parseEnumDecl();
                            enums_buf[enum_count].doc = doc;
                            enum_count += 1;
                        },
                        .union_kw => {
                            // v2 split (docs/14 §\"Definition\"): `pub union`
                            // is the payload-bearing sibling of `pub enum`.
                            // Same enum-record slot in `enums_buf` (both
                            // keywords produce an EnumDecl-shaped AST
                            // because codegen reuses the union(enum) / enum(T)
                            // emit logic). Doc threading mirrors the enum
                            // path (`pub union { ... }` → doc attaches via
                            // `enums_buf[i].doc = doc`).
                            enums_buf[enum_count] = self.parseUnionDecl();
                            enums_buf[enum_count].doc = doc;
                            enum_count += 1;
                        },
                        .trait_kw => {
                            traits_buf[trait_count] = self.parseTraitDecl();
                            traits_buf[trait_count].doc = doc;
                            trait_count += 1;
                        },
                        .fun => {
                            var fd = self.parseFunDecl();
                            fd.is_test = is_test or (self.test_file and isTestCaseName(fd.name));
                            fd.doc = doc;
                            functions_buf[fun_count] = fd;
                            fun_count += 1;
                        },
                        .const_kw => {
                            var cd = self.parseConstDecl();
                            cd.is_pub = true;
                            consts_buf[const_count] = cd;
                            const_count += 1;
                        },
                        .var_kw => {
                            var vd = self.parseVarDecl();
                            vd.is_var = true;
                            vd.is_pub = true;
                            consts_buf[const_count] = vd;
                            const_count += 1;
                        },
                        else => unreachable,
                    }
                    continue;
                }
                // pub_kw without a recognized following keyword is
                // an error; fall through to the unrecognized-branch
                // surface below where parseFunDecl surfaces the
                // `expected fun, got 'pub'` diagnostic.
            }
            if (lead == .struct_kw) {
            // Struct decls: the captured doc reaches codegen via
            // `StructDecl.doc`; every decl-kind that emits a single
            // zig container (`struct`, `enum`, `trait`) carries doc,
            // matching the FunDecl wiring above.
            structs_buf[struct_count] = self.parseStructDecl();
            structs_buf[struct_count].doc = doc;
            struct_count += 1;
            continue;
            }
            if (lead == .impl_kw) {
                // Same rationale as the struct-decl branch — impl blocks
                // don't carry doc at module scope.
                impls_buf[impl_count] = self.parseImplBlock();
                impl_count += 1;
                continue;
            }
            if (lead == .enum_kw) {
                // Top-level enum decl — recorded into `enums` so codegen
            // emits `pub const NAME = enum { ... };` and consumers
            // (functions, impls, other top-level decls) reference
            // the name naturally. doc slots through to codegen.
            enums_buf[enum_count] = self.parseEnumDecl();
            enums_buf[enum_count].doc = doc;
            enum_count += 1;
            continue;
            }
            if (lead == .union_kw) {
                // v2 split (docs/14 §\"Definition\"): bare `union X { ... }`
                // is the payload-bearing counterpart to bare `enum`. The
                // recorded slot is `enums_buf` (the shared EnumDecl AST
                // shape carries both surfaces; codegen branches on the
                // backing-type + payload presence to pick the emit form).
                // doc threads through to codegen the same way as the
                // `enum` arm above.
                enums_buf[enum_count] = self.parseUnionDecl();
                enums_buf[enum_count].doc = doc;
                enum_count += 1;
                continue;
            }
            if (lead == .trait_kw) {
                // Top-level trait decl (docs/17 §"Definition"). Phase 1
                // scaffolds the AST/parser surface only; Phase 2 wires
                // the codegen (vtable struct + dispatch shims). Trait
                // decls at module scope don't carry a doc slot — same
            // rationale as the `struct` branch above. Recorded in
            // source-order alongside structs/enums/impls so codegen
            // can walk the slice in declaration order at emit time.
            // doc slots through `TraitDecl.doc` to codegen.
            traits_buf[trait_count] = self.parseTraitDecl();
            traits_buf[trait_count].doc = doc;
            trait_count += 1;
            continue;
            }
            // Module imports (docs/manual/22-modules.md §Imports).
            // Two surface shapes at this dispatch site:
            //   1. `pub_kw` followed by `.import_kw` → set is_pub, advance past `pub`
            //   2. bare `.import_kw` → is_pub defaults to false
            // Either branch hands off to `parseImportDecl` which captures
            // the path components + optional `{A, B as C}` selective list
            // onto the AST. v1 only captures the AST shape; a followup
            // codegen pass (Phase 2) walks `prog.imports` at generate()
            // entry and routes each entry through KNOWN_STD_MODULES via
            // `resolveStdImport`. The scaffold tests in
            // `tests/scaffold.zig` exercise the table directly via
            // `parser_mod.Parser.resolveStdImport(...)` and assert the
            // lookup returns the expected `lib/std/X.zag` paths.
            if (lead == .pub_kw and self.peekAhead(1) == .import_kw) {
                self.advance();
                imports_buf[import_count] = self.parseImportDecl(true);
                import_count += 1;
                continue;
            }
            if (lead == .import_kw) {
                imports_buf[import_count] = self.parseImportDecl(false);
                import_count += 1;
                continue;
            }
            // Module re-exports (docs/manual/22 §Re-exports):
            // `pub use std.types as types` / `use std.fs as fs`.
            if (lead == .pub_kw and self.peekAhead(1) == .use_kw) {
                self.advance();
                uses_buf[use_count] = self.parseUseDecl(true);
                use_count += 1;
                continue;
            }
            if (lead == .use_kw) {
                uses_buf[use_count] = self.parseUseDecl(false);
                use_count += 1;
                continue;
            }
            if (lead == .extern_kw) {
                externs_buf[extern_count] = self.parseExternDecl();
                extern_count += 1;
                continue;
            }
            if (lead == .const_kw) {
                var cd = self.parseConstDecl();
                cd.is_pub = is_pub;
                consts_buf[const_count] = cd;
                const_count += 1;
                continue;
            }
            if (lead == .var_kw) {
                // Module-level `var NAME: TYPE = EXPR;` — the mutable
                // sibling of the top-level const (module state, e.g.
                // lib/std/posix.zag's getenv scan buffer). Same
                // ConstDecl slot; `is_var` routes codegen to zig `var`.
                consts_buf[const_count] = self.parseVarDecl();
                consts_buf[const_count].is_var = true;
                const_count += 1;
                continue;
            }
            // Async fns (docs/manual/18-traits.md §"Async Trait
            // Methods" + the overview's "Zero-cost async" goal):
            // `async fun NAME(...)` — the emitted zig fn wraps the
            // return type in `Future(T)` and the body's `await`
            // sites lower to the future-drive form (see
            // codegen/expr.zig's .await_expr arm). v1 surface:
            // top-level async funs; async impl methods parse-error
            // (see genMethod's guard).
            if (lead == .async_kw and self.peekAhead(1) == .fun) {
                self.advance();
                var afd = self.parseFunDecl();
                afd.is_async = true;
                afd.doc = doc;
                functions_buf[fun_count] = afd;
                fun_count += 1;
                continue;
            }
            var fd = self.parseFunDecl();
            fd.is_test = is_test or (self.test_file and isTestCaseName(fd.name));
            fd.doc = doc;
            functions_buf[fun_count] = fd;
            fun_count += 1;
        }

        const functions = self.arena.alloc(ast.FunDecl, fun_count);
        @memcpy(functions, functions_buf[0..fun_count]);
        const structs = self.arena.alloc(ast.StructDecl, struct_count);
        @memcpy(structs, structs_buf[0..struct_count]);
        const impls = self.arena.alloc(ast.ImplBlock, impl_count);
        @memcpy(impls, impls_buf[0..impl_count]);
        const enums = self.arena.alloc(ast.EnumDecl, enum_count);
        @memcpy(enums, enums_buf[0..enum_count]);
        const traits = self.arena.alloc(ast.TraitDecl, trait_count);
        @memcpy(traits, traits_buf[0..trait_count]);
        const imports = self.arena.alloc(ast.ImportDecl, import_count);
        @memcpy(imports, imports_buf[0..import_count]);
        const uses = self.arena.alloc(ast.UseDecl, use_count);
        @memcpy(uses, uses_buf[0..use_count]);
        const externs = self.arena.alloc(ast.ExternDecl, extern_count);
        @memcpy(externs, externs_buf[0..extern_count]);
        const consts = self.arena.alloc(ast.ConstDecl, const_count);
        @memcpy(consts, consts_buf[0..const_count]);
        return .{ .functions = functions, .structs = structs, .impls = impls, .enums = enums, .traits = traits, .imports = imports, .uses = uses, .externs = externs, .consts = consts };
    }


pub fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }


pub fn advance(self: *Parser) void {
        self.pos += 1;
    }


pub fn eof(self: *Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].tag == .eof;
    }


pub fn peekAhead(self: *Parser, n: u32) TokenTag {
        const idx = self.pos + n;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].tag;
    }


pub fn expect(self: *Parser, tag: TokenTag) void {
        if (self.peek().tag != tag) {
            const tok = self.peek();
            std.debug.print("error:{d}:{d}: expected {s}, got '{s}'\n", .{
                tok.loc.line,
                tok.loc.col,
                @tagName(tag),
                tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
    }

    /// Consume a `.string_literal` token and return its verbatim
    /// text (the template/constraint/clobber slots of the inline-asm
    /// spec use it — see parseAsmExpr in src/parser/primary.zig).
    pub fn expectStringLiteral(self: *Parser) []const u8 {
        const tok = self.peek();
        if (tok.tag != .string_literal) {
            std.debug.print("error:{d}:{d}: expected string literal, got '{s}'\n", .{
                tok.loc.line,
                tok.loc.col,
                tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
        return tok.text;
    }


pub fn isLiteralInit(self: *Parser, expr: Expr) bool {
        return switch (expr.payload) {
            // NOTE: `.single_tuple_lit` (Phase 1 single-element tuple) and
            // `.named_tuple_lit` (Phase 1 named-field tuple) intentionally
            // read as "literal init" here even though their runtime type is
            // an anonymous struct (`.{ EXPR }` / `.{ .name = expr }`). The
            // carve-out above is only needed to surface a clear parser error
            // when binding a NON-LITERAL expression whose type zig cannot
            // infer to a primitive (specifically: `comptime_int` values that
            // would silently coerce into the wrong shape downstream — see
            // `codegen.needsIntDivShim` for the failure surface). Anonymous
            // structs have a fully decidable type that zig accepts in any
            // expression position, so allowing bare binding of these two
            // variants is safe — the resulting zig code round-trips through
            // downstream uses (print, member access, comparisons).
            .int_lit, .float_lit, .bool_lit, .char_lit, .string_lit, .byte_string_lit, .null_lit, .undefined_lit, .tuple_lit, .array_lit, .template_lit, .new_expr, .struct_lit, .single_tuple_lit, .named_tuple_lit, .closure => true,
            // .closure is also a literal init because codegen tracks
            // closure-typed bindings via type_info_buf.is_closure = true
            // (see collectTypedBindings in src/codegen/stmt.zig), so
            // the closure's zig type is decidable at the binding site
            // without an explicit : T annotation. Same-self-describe
            // rationale as the anonymous-struct (single/named-tuple-lit)
            // variants above, just dispatched through a different
            // codegen slot.
            //
            // .call: when the callee is in the per-fn `closure_bindings`
            // set (populated by parseBinding when init == .closure), the
            // call expression is also self-describing. Codegen's genExpr
            // `.call` arm (src/codegen/expr.zig) routes `name(args)` to
            // `name.call(args)` because `name`'s type_info_buf.is_closure
            // = true. The runtime shape is determined without an explicit
            // `: T` annotation, matching the `.closure` case directly
            // above. The per-fn scoping of closure_bindings (reset at
            // parseFunDecl / parseMethod body entry) keeps bindings
            // visible only inside their declaring fn/method body,
            // mirroring codegen's per-fn type_info_buf scoping.
            .call => |c| isClosureBound(self, c.name),
            else => false,
        };
    }


pub fn isClosureBound(self: *Parser, name: []const u8) bool {
        // Linear scan over the per-fn closure_bindings stack. The stack
        // is small (typically 0-5 entries per fn for the common
        // single-closure pattern; the 256-slot cap is a defensive bound
        // against pathological cases) so a simple while-loop is the
        // right shape vs. a hash-set or sorted insertion. Mirrors the
        // codegen-side isClosureBound lookup (src/codegen/expr.zig
        // genExpr's `.call` arm) which iterates type_info_buf the same
        // way.
        var i: u32 = 0;
        while (i < self.closure_binding_count) : (i += 1) {
            if (std.mem.eql(u8, self.closure_bindings[i], name)) return true;
        }
        return false;
    }


pub fn isTypeishName(self: *Parser, name: []const u8) bool {
    _ = self;
    if (name.len == 0) return false;
    if (name[0] >= 'A' and name[0] <= 'Z') return true;
    const builtins = [_][]const u8{
        "u8",   "u16",  "u32",  "u64", "u128", "usize",
        "i8",   "i16",  "i32",  "i64", "i128", "isize",
        "f16",  "f32",  "f64",  "bool", "str", "void",
        "u6",   "u7",   "u5",   "comptime_int", "comptime_float",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

pub fn isKnownVariant(self: *Parser, name: []const u8) bool {
        // Gap #2 closure (docs/manual/14-unions §Mixed Bare + Payload):
        // linear scan over `known_variant_names` populated at module
        // scope by parseEnumDecl / parseUnionDecl. The lookup is O(N)
        // (matching the codegen-side lookupVariantFieldsByName helper
        // in src/codegen/core.zig) with N bounded by 256, so for a
        // typical v1 program (a handful of unions/enums) the cost is
        // trivial. Returns true when `name` matches any registered
        // variant ident — callers (parsePrimary's `.identifier` arm in
        // src/parser/primary.zig) use this to decide whether an
        // unqualified brace ctor `T { ... }` should route to
        // `.enum_variant_ctor { enum_name = null, ... }` (when matched)
        // or fall through to `.struct_lit` (when not matched). The
        // hit-rate is high for source files that declare and use
        // variants in source order (the typical case); the miss-rate
        // costs a struct_lit instead of a variant ctor (false-positive
        // on struct-literal direction is acceptable because it
        // preserves legacy behavior). Mirror of the codegen-side
        // lookupVariantFieldsByName call so the parser and codegen
        // agree on the same name-table content.
        // Preamble union ctors (Result/Option — the codegen preamble
        // in src/codegen/core.zig): Ok/Err/Some/None count as
        // registered variant names even though no module decl declares
        // them — the unqualified `Ok(v)` ctor must route to the
        // `.enum_variant_ctor` path so the emit produces
        // `.{ .Ok = v }` (zig infers the union from the binding's
        // `: T` annotation). Without the registration `Ok(v)` emits
        // as a bare call and zig rejects the undeclared identifier.
        if (std.mem.eql(u8, name, "Ok") or std.mem.eql(u8, name, "Err") or
            std.mem.eql(u8, name, "Some") or std.mem.eql(u8, name, "None"))
        {
            return true;
        }
        var i: u32 = 0;
        while (i < self.known_variant_count) : (i += 1) {
            if (std.mem.eql(u8, self.known_variant_names[i], name)) return true;
        }
        return false;
    }


pub fn isKnownStruct(self: *Parser, name: []const u8) bool {
        // BLOCKING #2 fix (docs/manual/14-unions §Mixed Bare + Payload):
        // linear scan over `known_struct_names` populated at module
        // scope by parseStructDecl. The lookup is O(N) with N bounded by
        // 256 (the same defensive bound used by `known_variant_names`),
        // so for typical v1 programs (typically < 16 structs per file)
        // the cost is trivial. Returns true when `name` matches any
        // registered struct decl — callers (parsePrimary's
        // `.identifier` arm in src/parser/primary.zig) use this for the
        // STRUCT-WINS-FIRST tie-breaker when an ident could be either a
        // struct type OR a brace-named-field variant. The hit-rate is
        // high for source files that declare and use structs in source
        // order (the typical case); the miss-rate falls through to the
        // existing variant-lookup branch preserving legacy behavior.
        // Companion to `isKnownVariant` (same O(N) shape; both tables
        // are independent and bounded by the same 256-slot cap).
        var i: u32 = 0;
        while (i < self.known_struct_count) : (i += 1) {
            if (std.mem.eql(u8, self.known_struct_names[i], name)) return true;
        }
        return false;
    }

    /// SIMD vector type names (docs/manual/24-simd.md §"SIMD Vector
    /// Types"): the `{elem}{width}x{lanes}` spelling — `f32x4`,
    /// `i8x16`, `bf16x8`, `u4x32`, ... Element = one or two lowercase
    /// letters (f, i, u, b, bf, u4-style digit suffix), then the
    /// `x`-separated lane count. Vector names start LOWERCASE, so
    /// they fail the struct-literal uppercase gate in parsePrimary's
    /// `.identifier` arm — this shape check is the disambiguation
    /// contract that lets `f32x4 { 1.0, 2.0 }` route into
    /// parseStructLit while bare lowercase locals stay idents.
    pub fn isSimdTypeName(self: *Parser, name: []const u8) bool {
        _ = self;
        if (name.len < 4) return false;
        const first = name[0];
        if (!(first == 'f' or first == 'i' or first == 'u' or first == 'b')) return false;
        var i: usize = 1;
        // Element letters (max one more: `bf16`'s `f`).
        if (i < name.len and (name[i] == 'f' or name[i] == 'i' or name[i] == 'u' or name[i] == 'b')) i += 1;
        // Element width digits (at least one).
        const width_start = i;
        while (i < name.len and name[i] >= '0' and name[i] <= '9') : (i += 1) {}
        if (i == width_start) return false;
        // `x` separator + lane digits (at least one).
        if (i >= name.len or name[i] != 'x') return false;
        i += 1;
        const lane_start = i;
        while (i < name.len and name[i] >= '0' and name[i] <= '9') : (i += 1) {}
        return i > lane_start and i == name.len;
    }


pub fn expectIdent(self: *Parser) []const u8 {
        const tok = self.peek();
        // Method/struct names can be any user-facing identifier PLUS
        // the keyword tokens `print`/`new`/`free` because the docs/12
        // common pattern is `impl Vec3 { pub fun new(...) -> Vec3 }`
        // where `new` is the conventional constructor name. Without
        // this concession the parser rejects `pub fun new(...)` even
        // though the user's surface clearly distinguishes the method
        // name from heap allocation via the surrounding `fun NAME(...)`
        // syntax. Same reasoning for `print` (already accepted) and
        // `free` (the docs/19 example `defer free(p)` uses `free` as
        // both a heap-op and a potential method name without clash).
        // `async`/`await` join the carve-out because module path
        // components are ordinary idents (`std.async.stream` in the
        // KNOWN_STD_MODULES surface) and the keywords must still
        // parse in dotted paths and as method names.
        if (tok.tag != .identifier and tok.tag != .print and
            tok.tag != .new and tok.tag != .free and
            tok.tag != .async_kw and tok.tag != .await_kw)
        {
            std.debug.print("error:{d}:{d}: expected identifier, got '{s}'\n", .{
                tok.loc.line, tok.loc.col, tok.text,
            });
            std.process.exit(1);
        }
        self.advance();
        return tok.text;
    }

pub const Parser = struct {

    tokens: []const Token,
    pos: u32,
    arena: *ast.Arena,
    /// Whole-module import expansion (v2 self-hosting): injectable file
    /// reader used by `expandWholeModuleImport` (decl.zig) to parse the
    /// target stdlib module and synthesize import selectors from its
    /// top-level decls. Null (the init() default) DISABLES expansion —
    /// whole-module imports then bind nothing, the pre-expansion
    /// behavior every existing test pins. main.zig's transpileEx
    /// injects a posix open/read wrapper so production transpiles
    /// expand. Injectable rather than hardwired so parser tests can
    /// run hermetically without a stdlib tree on disk.
    read_source_file: ?*const fn (path: []const u8) ?[]const u8 = null,
    /// Test-file convention (project `tests/` + file-mode `tests/` paths):
    /// a top-level `fun test_*` is a test case WITHOUT needing the
    /// `@[test]` annotation — location implies suite membership, so
    /// per-fn annotation is redundant. Explicit `@[test]` keeps
    /// working everywhere (OR-ed in at the assignment sites), and
    /// non-`test_` funs (helpers, `main`) stay plain functions.
    /// False by default: `src/` files and the stdlib never opt in,
    /// so existing code is byte-identical. Set by transpileEx from
    /// the source path (see isTestFilePath in src/main.zig).
    test_file: bool = false,
    /// Parse-context flag for struct-literal disambiguation in
    /// `parsePrimary`. True (default) in every expression position
    /// EXCEPT those where `{` MUST mean block-start: if-condition,
    /// while-condition, for-iter, match-scrutinee. In those positions
    /// the call site temporarily sets the flag to false (via a scoped
    /// save/false/`defer`-restore pattern around the single parseExpr
    /// call) so `if Foo { ... }` and `match Foo { ... }` parse as
    /// `<cond>` + `{ <body> }` rather than swallowing the block as a
    /// struct-literal.
    ///
    /// Why default-true (vs the earlier default-false): the user's
    /// contract explicitly says struct-literal parsing should fire in
    /// binding-init positions, return-value positions, field-assign
    /// positions, AND any other expression-yielding position. The
    /// principled carve-out is therefore the EXACT list of positions
    /// where `{` must be block-start, NOT a whitelist of positions
    /// where struct-literal is allowed. Implementing it via "suppress
    /// at the boundaries" rather than "opt-in everywhere else" keeps
    /// the precedence ladder untouched (no flag threading through
    /// parseExpr → parsePrimary) and avoids the regression where
    /// expressions like `return Vec3 { ... }` or
    /// `print(Vec3 { ... })` — common idioms in the user's example
    /// code — silently stop parsing as struct-literals.
    ///
    /// Two-gate disambiguation in parsePrimary: (a) this flag must be
    /// true AND (b) the leading identifier must start with an
    /// uppercase letter. The uppercase sub-clause is defense-in-depth
    /// (Rust/Zig-style PascalCase-types convention) so an accidental
    /// flag flip doesn't allow lower-case locals like `vec { ... }`
    /// to silently swallow blocks.
    allow_struct_lit: bool,

    /// Per-function set of binding names that hold closure-typed values
    /// (`let NAME = |...| -> T { ... };`). Populated by parseBinding
    /// when init == .closure; consulted by isLiteralInit's `.call` arm
    /// so subsequent closure-typed call sites (`let r = NAME(args)`)
    /// parse without an explicit `: T` annotation. Reset at
    /// parseFunDecl / parseMethod body entry (src/parser/decl.zig) so
    /// closure_bindings accumulates only within the declaring scope --
    /// mirrors codegen's per-fn type_info_buf scoping (see
    /// collectTypedBindings in src/codegen/stmt.zig).
    closure_bindings: [256][]const u8 = undefined,
    closure_binding_count: u32 = 0,
    /// Gap #2 closure (docs/manual/14-unions §Mixed Bare + Payload):
    /// variant-name table populated by parseEnumDecl / parseUnionDecl.
    /// Powers the parsePrimary `.identifier` arm disambiguation so
    /// `Pair { x: 2.0, y: 3.0 }` (unqualified brace ctor) routes to a
    /// `.enum_variant_ctor { enum_name = null, variant_name = \"Pair\", ... }`
    /// AST node when `Pair` is in the table, falling through to the
    /// existing `.struct_lit` arm otherwise. Tracks ONLY the variant
    /// names — not the union or struct names — so a struct type named
    /// `Pair` and a variant named `Pair` can coexist (struct-literal
    /// wins because the registration path requires a brace form, which
    /// struct-literal also consumes if the variant check fails). For
    /// one-program, single-Parser runs, the table size matches the
    /// 256-bound on `prog.enums` declared at module scope; the bound
    /// is a defensive ceiling against pathological large files.
    known_variant_names: [256][]const u8 = undefined,
    known_variant_count: u32 = 0,
    /// BLOCKING #2 fix (docs/manual/14-unions §Mixed Bare + Payload):
    /// struct-name table populated by parseStructDecl. Powers the
    /// struct-wins-first tie-breaker in parsePrimary's `.identifier`
    /// arm — when the leading ident is BOTH a registered struct decl
    /// AND matches a brace-named-field variant name, `parseStructLit`
    /// wins (a struct literal can be type-checked against ANY matching
    /// struct shape, while a brace-ctor only fits a specific variant
    /// payload). The same per-Parser reset applies (init() zero-entries
    /// it) so a Parser reused across multiple codegen-pass calls
    /// starts fresh.
    known_struct_names: [256][]const u8 = undefined,
    known_struct_count: u32 = 0,


    // ----- Method aliases -----

    pub const peekAhead = @import("core.zig").peekAhead;
    pub const expectIdent = @import("core.zig").expectIdent;
    pub const init = @import("core.zig").init;
    pub const expect = @import("core.zig").expect;
    pub const expectStringLiteral = @import("core.zig").expectStringLiteral;
    pub const advance = @import("core.zig").advance;
    pub const peek = @import("core.zig").peek;
    pub const isLiteralInit = @import("core.zig").isLiteralInit;
    pub const eof = @import("core.zig").eof;
    pub const parse = @import("core.zig").parse;
    // Gap #2 closure re-exports (docs/manual/14-unions §Mixed Bare +
    // Payload): parsePrimary's `.identifier` arm (src/parser/primary
    // .zig) calls `self.isKnownVariant(name)` to decide whether
    // `T { ... }` should route to a brace-named-field variant ctor AST
    // node or fall through to the legacy `.struct_lit` arm; and
    // `self.parseEnumVariantCtorBrace(name)` to actually build the
    // `.enum_variant_ctor { enum_name = null, variant_name, args }`
    // node once the brace-form gate fires. Both helpers live in
    // their respective files (src/parser/core.zig::isKnownVariant and
    // src/parser/primary.zig::parseEnumVariantCtorBrace) and are
    // surfaced here as `Parser.isKnownVariant` / `Parser
    // .parseEnumVariantCtorBrace` via the same `@import`-based
    // re-export pattern used by `parsePrimary` / `parseStructLit`
    // above. Without these bindings, zig surfaces a `no field or
    // member function named 'isKnownVariant' / 'parseEnumVariantCtorBrace'
    // in 'parser.core.Parser'` compile error at the call site.    pub const isKnownVariant = @import("core.zig").isKnownVariant;
    pub const isSimdTypeName = @import("core.zig").isSimdTypeName;
    pub const isTypeishName = @import("core.zig").isTypeishName;

    // Gap #2 closure helper re-export: parsePrimary's `.identifier` arm
    // (src/parser/primary.zig) calls `self.isKnownStruct(name)` (added by the
    // BLOCKING #2 fix) to decide whether to route to `parseStructLit` (when
    // the leading ident matches a registered struct decl) BEFORE
    // consulting the variant-lookup. Same re-export pattern as
    // `isKnownVariant` / `isClosureBound` — file-scope helper in
    // core.zig::isKnownStruct surfaced as `Parser.isKnownStruct` via this
    // const. Without this binding zig surfaces a `no field or member
    // function named 'isKnownStruct' in 'parser.core.Parser'` compile
    pub const isKnownVariant = @import("core.zig").isKnownVariant;
    pub const isKnownStruct = @import("core.zig").isKnownStruct;
    // --- decl.zig ---
    pub const parseClosureExpr = @import("decl.zig").parseClosureExpr;
    pub const parseEnumDecl = @import("decl.zig").parseEnumDecl;
    pub const parseUnionDecl = @import("decl.zig").parseUnionDecl;
    pub const parseBackedEnumValue = @import("decl.zig").parseBackedEnumValue;
    pub const parseEnumVariantPayload = @import("decl.zig").parseEnumVariantPayload;
    pub const parseTraitDecl = @import("decl.zig").parseTraitDecl;
    pub const parseTraitMethodDecl = @import("decl.zig").parseTraitMethodDecl;
    pub const parseFunDecl = @import("decl.zig").parseFunDecl;
    pub const parseImplBlock = @import("decl.zig").parseImplBlock;
    pub const parseMethod = @import("decl.zig").parseMethod;
    pub const parseMethodParam = @import("decl.zig").parseMethodParam;
    // Generics (docs/16). parseTypeParam / parseTypeParams /
    // parseTurbofishArgs live in decl.zig next to parseFunDecl
    // because they share the same `Parser` API (expect / expectIdent
    // / collectCastType / arena.alloc). Registering them here gives
    // `self.parseTypeParams()` access path the wired parseFunDecl /
    // parseStructDecl / parseImplBlock sites rely on.
    pub const parseTypeParam = @import("decl.zig").parseTypeParam;
    pub const parseTypeParams = @import("decl.zig").parseTypeParams;
    pub const parseTurbofishArgs = @import("decl.zig").parseTurbofishArgs;
    pub const parseStructDecl = @import("decl.zig").parseStructDecl;
    // Module imports (docs/manual/22-modules.md §Imports). parseImportDecl
    // is referenced from the top-level `Parser.parse` dispatch when the
    // leading token is `pub_kw` (peekAhead == `.import_kw`) or
    // bare `.import_kw`. Registered here so `self.parseImportDecl(is_pub)`
    // reaches the function registered in decl.zig without pulling the
    // decl.zig file's internals into a separate `@import` site.
    pub const parseImportDecl = @import("decl.zig").parseImportDecl;
    pub const parseUseDecl = @import("decl.zig").parseUseDecl;
    // FFI (docs/24). parseExternDecl parses `extern fun NAME(...) -> RET;`
    // declarations at the top level.
    pub const parseExternDecl = @import("decl.zig").parseExternDecl;
    // Compile-time (docs/26). parseConstDecl parses `const NAME: TYPE = EXPR;`.
    pub const parseConstDecl = @import("decl.zig").parseConstDecl;
    // Module-level mutable state: `var NAME: TYPE = EXPR;` (the mutable
    // sibling of the top-level const — see lib/std/posix.zag's getenv
    // scan buffer). Shares the ConstDecl slot; codegen emits zig `var`.
    pub const parseVarDecl = @import("decl.zig").parseVarDecl;
    // Module imports (docs/manual/22-modules.md §Imports).
    // `joinDottedPath` is defined as a file-scope Parser struct
    // member further down in this same file (sibling to
    // `resolveStdImport` and `KNOWN_STD_MODULES`), so it is
    // automatically exposed as `Parser.joinDottedPath` via the
    // struct aggregator — no separate `@import("core.zig")
    // .joinDottedPath` re-export needed (and adding one creates a
    // "duplicate struct member name" zig 0.16 compile error
    // because both arms end up inside the Parser struct body).
    // The first-commit version of this code shipped that duplicate
    // line; this comment block replaces it with a documented
    // explanation so a future reader doesn't try to "register"
    // the function the same way `KNOWN_STD_MODULES` /
    // `resolveStdImport` are aliased-registered above.

    // KNOWN_STD_MODULES — Comptime-baked lookup table mapping the
    // canonical dotted path (`std.types`) to the on-disk `.zag` source
    // path that backs it (`lib/std/types.zag`). The entries here
    // match the staged stub files at commit-of-landing; adding a new
    // `lib/std/X.zag` requires extending this slice and re-running
    // `zig build scaffold_tests` to confirm parseability.
    //
    // Lookup is `O(N)` linear-scan over the array (`path_to_path` walks
    // each entry's `name` field). The `name` slot is the canonical
    // dotted form (`std.types`); the joined `path_nodes` slice from
    // `ast.ImportDecl` is rebuilt into the same dotted form on the
    // caller side via a `joinDottedPath` helper defined below so the
    // comparison is shape-stable across both `import std.types` and
    // `import std.async.stream` (2-element and 3-element paths).
    //
    // No I/O at parse time — this is a pure comptime data table.
    // Codegen reads the resolved path and emits a `const X = @import(
    // "lib/std/types.zag");` preamble line at the top of the produced
    // zig module. The `lib/std/*.zag` files themselves are NOT
    // re-parsed at codegen time; v1 consumes only the type-name
    // surface (struct/enum/trait decl names) at the `import` use sites.
    pub const KNOWN_STD_MODULES = &[_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "std", .path = "lib/std/mod.zag" },
        .{ .name = "std.types", .path = "lib/std/types/mod.zag" },
        .{ .name = "std.types.string", .path = "lib/std/types/string.zag" },
        .{ .name = "std.error", .path = "lib/std/error.zag" },
        .{ .name = "std.env", .path = "lib/std/env.zag" },
        .{ .name = "std.posix", .path = "lib/std/posix.zag" },
        .{ .name = "std.argv", .path = "lib/std/argv.zag" },
        .{ .name = "std.process", .path = "lib/std/process.zag" },
        .{ .name = "std.fs", .path = "lib/std/fs.zag" },
        .{ .name = "std.fmt", .path = "lib/std/fmt.zag" },
        .{ .name = "std.time", .path = "lib/std/time.zag" },
        .{ .name = "std.atomic", .path = "lib/std/atomic.zag" },
        .{ .name = "std.bench", .path = "lib/std/bench.zag" },
        .{ .name = "std.mem", .path = "lib/std/mem.zag" },
        .{ .name = "std.collections", .path = "lib/std/collections/mod.zag" },
        .{ .name = "std.collections.array_list", .path = "lib/std/collections/array_list.zag" },
        .{ .name = "std.collections.hash_map", .path = "lib/std/collections/hash_map.zag" },
        .{ .name = "std.strings", .path = "lib/std/strings/mod.zag" },
        .{ .name = "std.strings.slices", .path = "lib/std/strings/slices.zag" },
        .{ .name = "std.io", .path = "lib/std/io.zag" },
        .{ .name = "std.bytes", .path = "lib/std/bytes.zag" },
        .{ .name = "std.math", .path = "lib/std/math.zag" },
        .{ .name = "std.json", .path = "lib/std/json.zag" },
        .{ .name = "std.sort", .path = "lib/std/sort.zag" },
        .{ .name = "std.encoding", .path = "lib/std/encoding.zag" },
        .{ .name = "std.hash", .path = "lib/std/hash.zag" },
        .{ .name = "std.random", .path = "lib/std/random.zag" },
        .{ .name = "std.debug", .path = "lib/std/debug.zag" },
        .{ .name = "std.async", .path = "lib/std/async/mod.zag" },
        .{ .name = "std.async.loop", .path = "lib/std/async/loop.zag" },
        .{ .name = "std.async.stream", .path = "lib/std/async/stream.zag" },
        .{ .name = "std.arch.x86.avx2", .path = "lib/std/arch/x86/avx2.zag" },
        .{ .name = "std.concurrent.atomic", .path = "lib/std/concurrent/atomic.zag" },
        .{ .name = "std.concurrent.thread", .path = "lib/std/concurrent/thread.zag" },
        .{ .name = "std.concurrent.mutex", .path = "lib/std/concurrent/mutex.zag" },
        .{ .name = "std.concurrent.rwlock", .path = "lib/std/concurrent/rwlock.zag" },
        .{ .name = "std.concurrent.once", .path = "lib/std/concurrent/once.zag" },
        .{ .name = "std.concurrent.semaphore", .path = "lib/std/concurrent/semaphore.zag" },
    };

    pub fn resolveStdImport(dotted: []const u8) ?[]const u8 {
        // Linear-scan over KNOWN_STD_MODULES — returns the resolved
        // file path on hit, null on miss. Miss is the v1 default for
        // paths not in the table (user modules, future optional
        // stdlib extensions). Lookups are O(N) but N=9 today so a
        // hash-set upgrade waits until the table grows past 16.
        for (KNOWN_STD_MODULES) |entry| {
            if (std.mem.eql(u8, entry.name, dotted)) return entry.path;
        }
        return null;
    }

    /// Join path_components into the canonical dotted form
    /// (`["std", "types"]` → `"std.types"`). Codegen-consumed so
    /// the lookup into `KNOWN_STD_MODULES` always sees the SAME
    /// joined shape regardless of which call path produced the
    /// identifiers (parse-time `ImportDecl.path_nodes` preservation
    /// vs. any future codegen-side alternate path). Mirrors the
    /// naming that users see in source (`import std.types` →
    /// `"std.types"` lookup key) so the table and the lookup are
    /// round-trippable by-eye.
    ///
    /// The scratch buffer is caller-provided — `joinDottedPath`
    /// returns a slice into the buffer the caller owns, NOT a slice
    /// into a stack-local var that would dangle past the function's
    /// return. The lifetime of the returned slice is bounded by
    /// `scratch`'s lifetime at the call site; the codegen-emit
    /// caller passes a stack-allocated buffer and consumes the
    /// returned slice via `resolveStdImport` + `self.write(...)`
    /// before any intermediate-state reuse. This avoids the prior
    /// dangling-pointer bug (a stack-local buffer returned by
    /// reference that the previous attempt shipped and the
    /// reviewer flagged).
    ///
    /// Buffer-size caveat: a 256-byte scratch is enough for every
    /// v1 KNOWN_STD_MODULES entry (longest is `std.arch.x86.avx2`
    /// at 18 bytes including separators). Future entries with
    /// longer paths truncate silently — the truncated slice then
    /// mismatches any table entry and `resolveStdImport` returns
    /// null, which the codegen skips. The lookup-vs-table shape
    /// drift is benign (no false-positive resolution) but a longer
    /// scratch should be passed once a v2 entry pushes past 256.
    pub fn joinDottedPath(scratch: []u8, nodes: []const []const u8) []const u8 {
        var length: usize = 0;
        var i: usize = 0;
        while (i < nodes.len) : (i += 1) {
            if (i > 0 and length < scratch.len) {
                scratch[length] = '.';
                length += 1;
            }
            const node = nodes[i];
            if (length + node.len <= scratch.len) {
                @memcpy(scratch[length..][0..node.len], node);
                length += node.len;
            }
        }
        return scratch[0..length];
    }

    // --- stmt.zig ---
    pub const compoundOpForTag = @import("stmt.zig").compoundOpForTag;
    pub const parseAssign = @import("stmt.zig").parseAssign;
    pub const parseBinding = @import("stmt.zig").parseBinding;
    pub const parseBindingPattern = @import("stmt.zig").parseBindingPattern;
    pub const parseBlock = @import("stmt.zig").parseBlock;
    pub const parseCompoundAssign = @import("stmt.zig").parseCompoundAssign;
    pub const parseDefer = @import("stmt.zig").parseDefer;
    pub const parseErrDefer = @import("stmt.zig").parseErrDefer;
    pub const parseFieldAssign = @import("stmt.zig").parseFieldAssign;
    pub const parseForStmt = @import("stmt.zig").parseForStmt;
    pub const parseIfBranch = @import("stmt.zig").parseIfBranch;
    pub const parseIndexAssign = @import("stmt.zig").parseIndexAssign;
    pub const parseIndexAssignField = @import("stmt.zig").parseIndexAssignField;
    pub const parseMatchExpr = @import("stmt.zig").parseMatchExpr;
    pub const parsePattern = @import("stmt.zig").parsePattern;
    pub const parsePatternBinding = @import("stmt.zig").parsePatternBinding;
    // gap #6 brace-named-field walker registration (docs/manual/14-unions
    // §\"Definition\" + docs/manual/13-enums §\"Choosing Between enum and
    // union\"): `parsePatternField` parses one
    // `Variant { name: bind, ... }` slot (consumes IDENT + `:` +
    // `parsePatternBinding` for the capture). Without this re-export,
    // the brace-form parser walker in `src/parser/stmt.zig` calls
    // `self.parsePatternField()` and zig reports
    // `no field or member function named 'parsePatternField' in
    // 'parser.core.Parser'` (the same diagnostic as the equivalent
    // codegen-side gap #2 `lookupVariantFields` re-export fix; the
    // parser-side mirror is needed because brace-named-field is a
    // parser-generated AST shape that an unqualified brace ctor would
    // also call into).
    pub const parsePatternField = @import("stmt.zig").parsePatternField;
    pub const parseReturnStmt = @import("stmt.zig").parseReturnStmt;
    pub const parseStmt = @import("stmt.zig").parseStmt;
    pub const parseStmtList = @import("stmt.zig").parseStmtList;
    pub const parseUnsafeBlock = @import("stmt.zig").parseUnsafeBlock;
    pub const parseWhileStmt = @import("stmt.zig").parseWhileStmt;

    // --- expr.zig ---
    pub const collectCastType = @import("expr.zig").collectCastType;
    pub const isExprStart = @import("expr.zig").isExprStart;
    pub const makeBinary = @import("expr.zig").makeBinary;
    pub const makeRange = @import("expr.zig").makeRange;
    pub const parseAdditive = @import("expr.zig").parseAdditive;
    pub const parseBitAnd = @import("expr.zig").parseBitAnd;
    pub const parseBitOr = @import("expr.zig").parseBitOr;
    pub const parseBitXor = @import("expr.zig").parseBitXor;
    pub const parseCast = @import("expr.zig").parseCast;
    pub const parseCatchExpr = @import("expr.zig").parseCatchExpr;
    pub const parseComparison = @import("expr.zig").parseComparison;
    pub const parseExpr = @import("expr.zig").parseExpr;
    pub const parseIfExpr = @import("expr.zig").parseIfExpr;
    pub const parseLogicalAnd = @import("expr.zig").parseLogicalAnd;
    pub const parseLogicalOr = @import("expr.zig").parseLogicalOr;
    pub const parseMultiplicative = @import("expr.zig").parseMultiplicative;
    pub const parseRange = @import("expr.zig").parseRange;
    pub const parseShift = @import("expr.zig").parseShift;
    pub const parseUnary = @import("expr.zig").parseUnary;
    pub const rejectRangeChaining = @import("expr.zig").rejectRangeChaining;

    // --- primary.zig ---
    pub const buildTemplate = @import("primary.zig").buildTemplate;
    pub const parseArrayLit = @import("primary.zig").parseArrayLit;
    pub const parseCallExpr = @import("primary.zig").parseCallExpr;
    pub const parseFree = @import("primary.zig").parseFree;
    pub const parseNew = @import("primary.zig").parseNew;
    pub const parsePostfix = @import("primary.zig").parsePostfix;
    pub const parsePrimary = @import("primary.zig").parsePrimary;
    pub const parseStructLit = @import("primary.zig").parseStructLit;
    pub const parseStructLitWithArgs = @import("primary.zig").parseStructLitWithArgs;
    // Gap #2 closure (docs/manual/14-unions §Mixed Bare + Payload) ctor
    // parser re-export: parsePrimary's `.identifier` arm routes brace-
    // form ctors `Variant { f1: v1, f2: v2 }` to
    // `self.parseEnumVariantCtorBrace(name)` so the unqualified variant
    // ctor surface round-trips through the same AST shape as the
    // qualified form `Enum.Variant(args)`. Mirrors the existing
    // `parsePrimary`/`parseStructLit` re-exports via `@import` indirection.
    pub const parseEnumVariantCtorBrace = @import("primary.zig").parseEnumVariantCtorBrace;
    pub const parseEnumVariantCtorParen = @import("primary.zig").parseEnumVariantCtorParen;
    // A2 newline-skip helper re-export (commit 2 of v1.5 multi-dim split,
    // docs/10 §"Multi-Dim Arrays"): parseArrayLit's element-collection
    // loop calls `self.skipNewlines()` to walk past `.newline` tokens
    // emitted by the zag lexer between source lines (leading-newline
    // after `{`, inter-comma newlines, trailing-before-`}` newlines).
    // Surfaced as `Parser.skipNewlines` via the standard
    // `@import("primary.zig").X` re-export pattern so the helper stays
    // a single file-scope definition in primary.zig (matching the
    // `looksLikeTemplateLiteral` precedent for file-scope parsers)
    // while `self.skipNewlines()` resolves from any Parser call site
    // — no cross-file import plumbing at the use sites.
    pub const skipNewlines = @import("primary.zig").skipNewlines;

};
