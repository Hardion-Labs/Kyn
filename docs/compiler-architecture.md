# Kyn compiler architecture (v0.1)

The compiler is implemented in Zig 0.17.0 and lives in `compiler/`. It is a
staged, recursive-descent compiler with an explicit typed IR and a textual
LLVM backend. There is no generated parser, no LLVM C++ linkage and no
third-party dependency.

## 1. Pipeline

```
argv
 │
 ▼
compiler/main.zig          CLI, options, command dispatch
 │
 ▼
compiler/driver.zig        orchestration, file I/O, external tool invocation
 │
 ├─ source.zig            source text, spans, line/column lookup
 ├─ lexer.zig             tokens and lexical diagnostics
 ├─ parser.zig            AST and syntax diagnostics
 ├─ ast.zig               AST node definitions
 ├─ symbol.zig            symbols, kinds, scopes
 ├─ types.zig             type representation and primitives
 ├─ sema.zig              name resolution, type checking, lvalues, calls
 ├─ analyzer.zig          static analysis on the typed AST
 ├─ ir.zig                typed CFG IR
 ├─ backend/llvm.zig      IR lowering, LLVM text emission
 └─ diagnostics.zig       diagnostic records and rendering
```

`driver.compile` loads the root source and its explicit import graph, then runs
the frontend once over the deterministic dependency-first declaration list. It
returns either rendered LLVM IR or a diagnostic failure. `main.zig` decides
whether to write IR, invoke `clang` for an object/executable, or run the result.

Each parsed source has a stable module/source ID for the compilation. Sema stores
top-level symbols by owner module and resolves open imports by a deterministic
DFS over unaliased edges; aliases look only in their target module. Internal
function/global and LLVM struct identifiers are mangled with the module ID, while
`extern`/`export` function names keep their C ABI spelling. Identical extern
prototypes may be shared; conflicting declarations or duplicate exported
symbols are diagnosed (`E0472`).

## 2. Source manager

`Source` owns:

- a stable source ID within the compilation;
- the file path;
- the source bytes;
- a span-to-line/column mapping.

UTF-8 is not required for source bytes as a whole; the lexer operates on bytes
and only interprets UTF-8 inside character literals. Spans are byte offsets.
`Span.join` creates a span covering two nodes for diagnostics while retaining
the originating source ID. `Reporter` resolves each diagnostic span against the
registered source files.

## 3. Lexer

`lexer.Lexer` scans bytes into `token.Token` values with `{ kind, span, lexeme }`.
It recognizes:

- whitespace and `//` / `/* */` comments;
- identifiers and keywords;
- integer and float literals in decimal, hex, binary and octal forms;
- string and character literals, including escapes;
- all operators and punctuation;
- end of file.

Lexical errors use `E01xx` and are reported through `Reporter`. Tokenization
continues after an error when possible so the parser can report more than one
problem.

## 4. Parser

`parser.Parser` is a hand-written recursive-descent parser with precedence
climbing for binary expressions. It produces `ast.Program`, a list of declarations and top-level import
paths. Imports are resolved relative to the containing source. The loader uses
normalized paths, depth-first source order, once-only visits, and an explicit
visiting/completed state to reject cycles. Imported declarations currently share
one global namespace with the root declarations.

Key properties:

- every expression and statement has a `Span`;
- syntax errors do not abort the whole file; the parser synchronizes at
  semicolons and declaration keywords;
- an invalid expression node is a zero integer literal with an error span so
  later stages can keep running without null checks;
- statements and declarations are stored as pointers allocated from the
  compilation arena.

Precedence is encoded by a chain of functions:

```
parseAssign
 └ parseLogicalOr
   └ parseLogicalAnd
     └ parseBitOr
       └ parseBitXor
         └ parseBitAnd
           └ parseEquality
             └ parseRelational
               └ parseShift
                 └ parseAdditive
                   └ parseMultiplicative
                     └ parseCast
                       └ parseUnary
                         └ parsePostfix
                           └ parsePrimary
```

## 5. AST

`ast.zig` defines tagged unions for declarations, statements, expressions and
type expressions. Semantic annotations are stored directly on nodes:

- `Expr.ty` is filled by sema;
- `Expr.Kind.Ident.sym` points at the resolved symbol;
- `Expr.Kind.Field` stores the resolved field index or enum variant value;
- `Expr.Kind.SliceAccess` stores optional `start` and `end` bounds (`[..]`,
  `[start..]`, `[..end]`, `[start..end]`);
- `VarDecl.ty` / `Param.ty` / `FnDecl.ty` hold resolved types;
- `TypeExpr.resolved` caches resolved named types.

The analyzer and backend consume this annotated AST. The backend never
re-resolves names or infers types.

## 6. Semantic analysis

`sema.Sema` performs several passes:

1. **Collect declarations.** Build symbols for functions, structs, enums and
   globals; detect duplicate top-level names (`E0401`).
2. **Resolve signatures and layouts.** Resolve parameter/return types, struct
   fields and enum variants, with cycle detection for by-value recursion.
3. **Check bodies.** Resolve locals, type expressions, expressions and
   statements; enforce lvalue rules, mutability, assignability, call arity,
   casts, comparisons, pointer arithmetic, missing returns, and control-flow
   validity.

Types are allocated in the arena and compared structurally, except structs and
enums which are nominal. `Sema` also exposes constant evaluation used by enum
values, array lengths and initializer checks.

## 7. Static analyzer

`analyzer.Analyzer` walks the typed AST with a per-function initialization
state (`AutoHashMap(symbol id, bool)`). It reports:

- possible reads of uninitialized locals (`E0501`);
- constant out-of-bounds array indexes, negative slice indexes, and invalid
  constant slice ranges (`E0502`);
- provable division by zero (`E0503`);
- constant shifts outside the type width (`E0504`);
- constant arithmetic overflow (`E0505`);
- provable null pointer dereferences and null array-pointer slicing/casting
  (`E0506`);
- unreachable statements (`W0501`);
- constant `if`/`while` conditions (`W0502`).

Branch states are merged by intersection: a variable is initialized after an
`if` only when it is initialized on every path. Loop bodies do not make a
variable definitely initialized after the loop.

## 8. IR

`ir.zig` defines a small typed CFG:

- `Function` has parameters, locals (stack slots), blocks and a return type.
- `Block` contains instructions and a terminated flag.
- Locals are identified by symbol id; temporaries are SSA-style register ids.
- `Value` covers constants, locals, globals, strings, registers and parameters.
- Instructions: `binary`, `unary`, `icmp`, `fcmp`, `cast`, `call`, `field_ptr`,
  `elem_ptr`, `load`, `store`, `br`, `cbr`, `ret`, `unreachable_`.

The IR is deliberately close to LLVM but independent of LLVM headers. It is
the boundary between language semantics and native code generation.

## 9. LLVM backend

`backend/llvm.zig` has two responsibilities:

1. **Lowering** (`Lowering`): walk the typed AST and emit IR.
   - Each function starts with an entry block.
   - Parameters are stored into locals.
   - Locals become `alloca` slots in the emitter.
   - `if`/`while` create explicit blocks and branches.
   - `break`/`continue` use explicit block stacks.
   - Short-circuit `&&`/`||` lower to branches.
   - Dynamic fixed-array and slice indexes and pointer dereferences are
     bounds/null-checked at runtime.
   - Integer division violations lower to explicit branches to `llvm.trap()`.
   - Struct/array literals are stored field by field into their destination.
   - Calls carry argument and return types for the emitter.
2. **Emission** (`Emitter`): print deterministic textual LLVM IR
   (`; ModuleID`, globals, string constants, struct types, function
   definitions). The emitter uses opaque `ptr` and does not require LLVM
   library linkage.

The generated IR is consumed by `clang`. Kyn does not implement instruction
selection, register allocation, assembly or linking.

## 10. Diagnostics

`diagnostics.zig` defines `Reporter` and `Diagnostic`:

- each diagnostic has a severity, stable code, span and formatted message;
- rendering is separate from production;
- rendered form is:
  `path:line:column: error[CODE]: message`, followed by the source line and a
  caret;
- errors and warnings are counted separately;
- warnings do not fail compilation.

Stable ranges: `E01xx` lexer, `E02xx` parser, `E04xx` sema, `E05xx`/`W05xx`
analyzer, `E06xx` backend-internal.

## 11. Driver and external tools

`driver.zig`:

- reads the source file with a 64 MiB limit;
- runs lexer → parser → sema → analyzer → lowering → emitter;
- returns rendered IR;
- invokes `clang` for `emit-obj`, `build` and `run`;
- forwards program stdout through a buffered stdout writer and returns the
  program exit code for `run`;
- prints tool stderr on failure.

`main.zig` parses CLI options, chooses the output paths, optionally keeps the
`.ll` file and maps failures to non-zero exit codes.

`build-system/main.zig` is a separate executable (`kyn-build`) that parses
`kyn.build`, hashes inputs, drives `kync` for Kyn sources, invokes C and Zig
compilers for their sources, links the result and stores a content stamp for
incremental rebuilds.

## 12. Memory management inside the compiler

- The CLI creates an arena allocator for the whole invocation.
- Source text, tokens, AST nodes, types, symbols, IR nodes, strings and
  diagnostics are allocated from that arena.
- Long-lived per-invocation structures do not require manual frees.
- The unit tests use Zig's testing allocator and explicit deinit where the
  structure owns memory.

This keeps ownership simple and avoids use-after-free in compiler data
structures at the cost of holding memory until the process exits.

## 13. Testing

- `compiler/tests.zig` imports every module so `zig build test` runs all
  inline tests.
- Lexer tests cover token streams, literals and lexical errors.
- Parser tests cover declarations, expressions, precedence and recovery.
- Sema tests cover acceptance and rejection with exact diagnostic codes.
- Analyzer tests cover initialization, constant facts and warnings.
- Integration tests under `tests/integration` compile and execute real
  binaries, assert stdout/exit status, assert negative diagnostic codes, verify
  diagnostic documentation coverage, resolve Markdown links across the
  repository, run a deterministic lexer/parser robustness corpus, check version
  metadata consistency, and exercise `kyn-build` with a hybrid project.

## 14. Extension checklist

When adding a language feature:

1. Add tokens if needed (`token.zig`, `lexer.zig`).
2. Add AST nodes (`ast.zig`).
3. Add grammar production and parsing (`parser.zig`, `docs/grammar.ebnf`).
4. Add resolution/typing rules (`sema.zig`, `types.zig`).
5. Add static-analysis rules if applicable (`analyzer.zig`).
6. Add IR instructions and lowering (`ir.zig`, `backend/llvm.zig`).
7. Add diagnostics with stable codes (`docs/diagnostics.md`).
8. Add positive execution and negative diagnostic tests.
9. Update language reference and design docs; mark limitations honestly.
10. Keep `zig fmt` clean and run all test steps.
