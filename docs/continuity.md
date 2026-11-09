# Technical continuity record

This document is the persistent engineering state record for `Hardion-Labs/Kyn`.
Before starting any future increment, read this record and cross-check every
entry against the actual source tree, test suite and `git log`. Never rely on
this file if the codebase disagrees; reconcile any discrepancy immediately.

## 1. Current real stage

- **Published toolchain baseline:** `v0.1.0-alpha.2` (`7f9cb2c`), Zig `0.17.0`
  + Clang/LLVM opaque-pointer IR (`ptr`).
- **Active stage:** Post-`v0.1.0-alpha.2` incremental development (version
  string remains `0.1.0-alpha.2` until a human-authorized release boundary is
  selected per [release-checklist.md](release-checklist.md)).
- **Completed increment in current cycle:** Const-polymorphic slicing,
  open-ended subslice syntax (`[..]`, `[start..]`, `[..end]`, `[start..end]`),
  slice/array ergonomics (`.ptr`, `.len`, `->ptr`, `->len`), lvalue/mutability
  soundness fixes (`E0464`, immutable globals, read-only properties, `i32`
  default enum backing), pointer arithmetic fixes, static/runtime slice null
  and bounds safety, `< 8`-byte / `< 16`-byte C ABI aggregate packing hardening,
  executable slice C ABI verification, and specification reconciliation.
- **Latest increment validated:** Explicit relative-path imports, deterministic
  dependency-first loading, per-source diagnostic spans, cycle/missing-file
  diagnostics, and transitive Kyn build-stamp hashing. Imported declarations
  share one unqualified global namespace. Qualified aliases and visibility
  remain pending; do not claim those as implemented.

## 2. Validated completed components

| Component | Primary files | Validation |
| --------- | ------------- | ---------- |
| Source buffers with stable per-file span IDs, line/col lookup & multi-source diagnostics (`E01xx`–`E06xx`, `W05xx`) | `compiler/source.zig`, `compiler/diagnostics.zig`, `docs/diagnostics.md` | `zig build test`, `check_diagnostic_docs.py`, import integration errors |
| UTF-8 lexer (keywords, hex/dec/float/char/string literals, nested `/* */` comments) | `compiler/token.zig`, `compiler/lexer.zig` | `zig build test`, `robustness.py` |
| Recursive-descent + precedence-climbing parser with error recovery, open-ended/bounded slicing and top-level imports | `compiler/ast.zig`, `compiler/parser.zig`, `docs/grammar.ebnf` | `zig build test`, `tests/integration/errors/*`, `robustness.py` |
| 3-phase semantic resolver & type checker (`Sema`), const-eval, lvalue/mutability, const-polymorphic slicing, `[]T -> []const T`, `.ptr`/`.len` | `compiler/symbol.zig`, `compiler/types.zig`, `compiler/sema.zig` | `zig build test`, `tests/integration/cases/*`, `tests/integration/errors/*` |
| Flow-sensitive static analyzer (`E0501`–`E0506`, `W0501`–`W0502`), including constant slice range bounds and provable null slice sources | `compiler/analyzer.zig` | `zig build test`, `tests/integration/errors/*` |
| Typed CFG IR + textual LLVM IR backend, runtime safety traps (`llvm.trap`), zero-branch `base[..]` fast path, pointer arithmetic, internal & `x86_64` Linux C ABI aggregate/slice lowering | `compiler/ir.zig`, `compiler/backend/llvm.zig` | `zig build test`, `tests/integration/cases/*`, `tests/integration/abi/*` |
| Compiler CLI (`check`, `emit-llvm`, `emit-obj`, `build`, `run`) and deterministic dependency-first import loader | `compiler/main.zig`, `compiler/driver.zig`, `compiler/modules.zig` | `tests/integration/run.sh` |
| Declarative hybrid Kyn/C/Zig builder with SHA-256 stamps including transitive Kyn imports | `build-system/main.zig`, `examples/hybrid/` | `zig build test`, `tests/integration/run.sh` |

## 3. Partial components (with exact scope boundaries)

- **C ABI interoperability (`compiler/sema.zig`, `compiler/backend/llvm.zig`, [abi.md](abi.md)):**
  - *Implemented & validated:* Scalars, pointers, enums (via explicit backing
    integers), slices (`[]T`, `[]const T` as two `i64` registers matching
    `struct { T *ptr; size_t len; }`), integer-only structs `<= 16` bytes in
    1–2 `i64` registers (with zero-padded packing for `< 8` / `< 16` bytes),
    and integer-only structs `> 16` bytes via `sret`/`byval` on `x86_64` Linux.
  - *Not yet implemented:* Floating-point/SSE struct fields at `extern`/`export`
    boundaries (rejected with `E0412`/`E0413`), by-value fixed arrays (`E0410`/
    `E0411`), variadic `extern fn`, non-`x86_64-linux` calling conventions, and
    function pointers/callbacks.
- **Safety profiles (`compiler/driver.zig`, [safety-model.md](safety-model.md)):**
  - *Implemented & validated:* All four profiles (`debug`, `safe`, `release`,
    `fast`) map to Clang optimization flags and emit the full set of runtime
    traps (array/slice/subslice bounds, integer `+`/`-`/`*`/negation overflow,
    `/`/`%` zero and `INT_MIN / -1`, dynamic shift range, exact-`null` pointer
    dereference/index/field/slice).
  - *Not yet implemented:* Profile-selective trap elision or configurable panic
    handlers.
- **Multi-file import graph (`compiler/driver.zig`, `compiler/ast.zig`,
  `compiler/parser.zig`, `build-system/main.zig`):**
  - *Implemented & validated:* `import "relative/path.kyn";`, paths resolved
    relative to the containing file, normalized-path once-only depth-first
    loading, dependency-first shared compilation, global duplicate detection,
    source-aware diagnostics, cycle detection (`E0231`), missing-source errors
    (`E0232`), and transitive import path/content inclusion in SHA-256 build
    stamps. Multi-language linking with C/Zig remains supported.
  - *Not yet implemented:* Module aliases, qualified value/type lookup, or
    per-module visibility; all imported declarations are currently unqualified
    members of the global namespace.

## 4. Pending items (ordered by technical dependency)

1. **Qualified Kyn modules & visibility** (module aliases, qualified value/type
   lookup, explicit visibility rules, while preserving deterministic imports and
   SHA-256 transitive dependency tracking already implemented).
2. **Profile-specific runtime check policy** (explicit IR/backend configuration
   from `driver.Profile` without silent UB introduction).
3. **Extended C ABI classification** (`x86_64` System V SSE/EIGHTBYTE class
   merging for float-bearing structs, function pointers, and target ABI
   selection instead of host-assumed `64`-bit `usize`).
4. **Tagged unions / explicit error-return types** (`Result`-style value flow
   without hidden exceptions or unwinding).
5. **Freestanding `std` core (`std/`) and optional runtime (`runtime/`)** built
   atop validated multi-file modules and slice ergonomics.

## 5. Active contracts, invariants & architectural decisions

- **Strict pipeline separation:** `Source -> Lexer -> Parser -> Sema -> Analyzer -> Lowering (IR) -> Emitter (LLVM IR) -> Clang`. Later stages never re-parse
  or guess types; any diagnostic error halts compilation before native codegen.
- **Arena-allocated compilation unit:** AST, `Symbol`s, `Type`s, `ir.Module`,
  and formatted compound type names share the compilation arena with zero leaks.
- **Type & conversion invariants:**
  - Zero implicit numeric widening/narrowing and zero implicit `*T -> *const T`
    pointer conversion (explicit `as` required).
  - Sound one-way slice mutability weakening: `[]T` is assignable to
    `[]const T` iff `Type.eql(elem_a, elem_b)` (inner element types are
    invariant, rejecting `[][]T -> [][]const T` and `[]*T -> []*const T`).
  - Built-in `.len` and `.ptr` properties on slices and arrays are rvalues
    (`isLvalue == false`); `&operand` requires `isLvalue(operand)` (`E0464`).
  - `const` and `let` bindings (both local and global) have `sym.mutable = false`.
  - Unannotated `enum` declarations default to `i32` backing, matching
    [language-reference.md](language-reference.md) and
    [type-system.md](type-system.md).
- **Automated repository gates (must stay green on every commit):**
  1. `zig fmt --check build.zig compiler build-system`
  2. `zig build` and `zig build -Doptimize=ReleaseSafe`
  3. `zig build test`
  4. `tests/integration/run.sh` (includes `check_diagnostic_docs.py`,
     `check_docs_links.py`, `check_versions.py`, `robustness.py`, all 4
     profiles, C ABI tests, `examples/hybrid`, and transitive Kyn cache tests).

## 6. Core structures & module interfaces

- `source.Span`: `{ start: u32, end: u32, source_id: u32 = 0 }`; lexer spans
  retain their owning source ID, and `diagnostics.Reporter` resolves the ID to
  the registered `Source` for path/line/column rendering.
- `ast.Program`: `{ decls: []*Decl, imports: []ImportDecl }`; `ImportDecl` is
  `{ span: Span, path: []const u8 }` with the path decoded from a string token.
- `driver.ModuleLoader`: DFS over normalized paths with `.visiting`/`.complete`
  states; declarations append dependency-first into a unified program. Import
  declarations are removed from the semantic input after resolution.
- `kyn-build.hashKynImports(arena, io, hasher, path, visited, hash_self)` uses
  the compiler's shared lexer/parser frontend and hashes each transitive import
  edge plus imported path/content once per listed root.
- `ast.Expr.Kind.SliceAccess`: `{ base: *Expr, start: ?*Expr, end: ?*Expr }`
  representing `[..]`, `[start..]`, `[..end]`, and `[start..end]`.
- `ast.Expr.Kind.Field`: `{ base: *Expr, name: []const u8, field_index: u32, is_enum_variant: bool, variant_value: i128, through_pointer: bool }`
  used for struct fields, enum variants, `slice.ptr` (`0`), `slice.len` (`1`),
  and `array.len` (`1`).
- `sema.Sema.checkSlice(expr, slice_expr, expected)`: resolves slice bounds and
  propagates `expected` `[]const T` context for const-polymorphic slicing.
- `sema.aggregateBoundaryClass(ty)` / `sema.aggregateLayoutGuess(ty)`:
  classifies C ABI aggregates into `.small_1` (`<= 8B`), `.small_2` (`9..16B`),
  or `.memory` (`> 16B` `sret`/`byval`), returning `null` for float-bearing
  aggregates.

## 7. Files modified / added in the latest validated increment

- **Compiler/source infrastructure:** `build.zig`, `compiler/source.zig`,
  `compiler/diagnostics.zig`, `compiler/token.zig`, `compiler/lexer.zig`,
  `compiler/ast.zig`, `compiler/parser.zig`, `compiler/driver.zig`, and new
  `compiler/modules.zig` (shared lexer/parser exports for `kyn-build`).
- **Build system:** `build-system/main.zig` parses Kyn imports to hash
  transitive paths/content; build target imports the shared compiler frontend.
- **Tests:** `tests/integration/cases/import_modules.{kyn,exit}` and nested
  transitive fixtures; `tests/integration/errors/import_{syntax,cycle,missing}`
  and `imported_unknown` cases plus nested fixtures; `tests/integration/run.sh`
  checks multi-source diagnostics and transitive cache invalidation.
- **Documentation:** `README.md`, `CHANGELOG.md`, `docs/build-system.md`,
  `docs/compiler-architecture.md`, `docs/continuity.md`, `docs/diagnostics.md`,
  `docs/grammar.ebnf`, `docs/language-design.md`, `docs/language-reference.md`,
  and `docs/roadmap.md`.

## 8. Known limitations

- Imports currently flatten declarations into one global, unqualified namespace;
  aliases, qualified references, and module visibility boundaries remain pending.
- Import paths are resolved lexically relative to the importing file; no
  package registry, search path, or symlink-canonical module identity exists.
- `usize` / `isize` and C ABI lowering assume 64-bit `x86_64` Linux System V.
- Floating-point structs, fixed-size arrays by value, variadic functions, and
  function pointers are rejected across `extern`/`export` C ABI boundaries.
- Runtime pointer safety checks exact `null` values and slice/array bounds, not
  temporal lifetimes (`free`/dangling pointers) or raw pointer arithmetic
  bounds.

## 9. Next logical task for resumption

Complete the module system by designing and implementing explicit import aliases,
qualified type/value resolution, and visibility boundaries. Current imports are
usable and validated but flatten all declarations into the existing global
namespace; do not report qualified namespaces or privacy as implemented. Keep
import traversal deterministic and preserve source-aware spans and transitive
SHA-256 cache invalidation. Add integration tests for qualified functions/types,
private access failures, cross-file duplicate behavior, import path edge cases,
and cycle diagnostics; update this record against source/Git before continuing.

## 10. Latest validation and Git state

- Toolchain: Zig `0.17.0`; Clang `22.1.8` through `zig cc`.
- `zig fmt --check build.zig compiler build-system`: passed.
- `zig build`, `zig build test`, and `zig build -Doptimize=ReleaseSafe`: passed.
- `tests/integration/run.sh`: `73 passed, 0 failed` against the Debug build and
  `73 passed, 0 failed` against the ReleaseSafe build. This includes all four
  native profiles, ABI interop, 900 robustness cases, source-aware imported
  diagnostics, cycle/missing-import diagnostics, and transitive cache invalidation.
- Documentation gates: 119 diagnostic codes synchronized; 19 Markdown files
  link-checked; version metadata remains `0.1.0-alpha.2`.
- Sanitizers were not run; the repository does not currently expose a sanitizer
  gate. Static/dynamic regression coverage is the existing unit, integration,
  ABI and robustness suites.
- Git branch: `arena/2b67c8fb-kyn`. Implementation/tests/spec changes are in
  commit `74e17b2` (`feat(modules): add deterministic relative imports and cache
  tracking`); this continuity update is a documentation-only follow-up on the
  same branch. No `main` merge or release/version change was made. Confirm the
  final follow-up commit and remote synchronization with `git log`/`git status`.
