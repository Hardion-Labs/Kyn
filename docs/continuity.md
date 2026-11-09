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
- **Latest module-system increment implemented, validated, and committed:**
  Per-source top-level namespaces layered on deterministic relative imports
  and aliases. Unaliased imports open public names through their
  transitive unaliased dependency closure; local declarations shadow opens;
  multiple distinct public candidates are ambiguous at use (`E0471`). Alias-only
  edges remain qualified-only. Same-module duplicates are `E0401`; same-spelled
  declarations across modules are distinct. `private` remains enforced
  (`E0467`), and backend names are module-qualified while C `extern`/`export`
  names retain ABI spellings.

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
    loading, dependency-first compilation, per-module duplicate detection and
    opened-name ambiguity checks, source-aware diagnostics, cycle detection (`E0231`), missing-source errors
    (`E0232`), and transitive import path/content inclusion in SHA-256 build
    stamps. Multi-language linking with C/Zig remains supported.
  - *Implemented and validated in this working tree:* Optional
    `import "path.kyn" as alias;`, qualified calls/globals/struct/enum/type use,
    and cross-file private checks (`E0467`), including private function and type
    access through an alias.
  - *Implemented in the current increment:* Independent module-owned symbol
    maps, alias-qualified target-only lookup, deterministic cached open-import
    resolution, use-site ambiguity diagnostics, and module-qualified internal
    linkage/type identifiers. Same-named private helpers and public types can
    coexist in distinct source modules.
  - *Contract:* only unaliased edges contribute to unqualified visibility,
    transitively; alias-only edges do not re-export their target's declarations.
    Local module declarations shadow opened imports. Repeated paths to the same
    module count as one candidate.

## 4. Pending items (ordered by technical dependency)

1. **Profile-specific runtime check policy** (explicit IR/backend configuration
   from `driver.Profile` without silent UB introduction).
2. **Explicit module re-exports** (if needed, specify a syntax and visibility
   model; current unaliased imports are transitively open, while aliased edges
   are not re-exported unqualified).
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
  `{ span: Span, path: []const u8, alias: ?[]const u8, target_module_id: u32 }`.
  The parser decodes the path; the loader fills the target module ID.
- `driver.ModuleLoader`: DFS over normalized paths with `.visiting`/`.complete`
  records and stable source/module IDs; declarations append dependency-first into
  one program. Imports retain the parent source ID in their span and the resolved
  target module ID for semantic alias lookup.
- `sema.Sema`: `module_globals` maps owner module IDs to local top-level symbol
  tables; `module_aliases` stores per-source aliases; `module_open_imports`
  stores only unaliased edges. Name resolution caches results per module/name
  and walks open edges with reusable generation marks and a retained stack,
  avoiding a quadratic precomputed transitive closure.
- `symbol.Symbol.link_name`: source `name` stays diagnostic/source-facing;
  internal Kyn function/global linker symbols include module ID, while external
  C symbols preserve their declared spelling. `types.StructInfo.llvm_name`
  similarly separates LLVM type identity from source-level struct names.
- `kyn-build.hashKynImports(arena, io, hasher, path, visited, hash_self)` uses
  the compiler's shared lexer/parser frontend and hashes each transitive import
  edge plus imported path/content once per listed root.
- `ast.Expr.Kind.SliceAccess`: `{ base: *Expr, start: ?*Expr, end: ?*Expr }`
  representing `[..]`, `[start..]`, `[..end]`, and `[start..end]`.
- `ast.Expr.Kind.Field`: `{ base: *Expr, name: []const u8, field_index: u32, is_enum_variant: bool, variant_value: i128, through_pointer: bool, sym: ?*Symbol }`
  used for struct fields, enum variants, `slice.ptr` (`0`), `slice.len` (`1`),
  and `array.len` (`1`).
- `sema.Sema.checkSlice(expr, slice_expr, expected)`: resolves slice bounds and
  propagates `expected` `[]const T` context for const-polymorphic slicing.
- `sema.aggregateBoundaryClass(ty)` / `sema.aggregateLayoutGuess(ty)`:
  classifies C ABI aggregates into `.small_1` (`<= 8B`), `.small_2` (`9..16B`),
  or `.memory` (`> 16B` `sret`/`byval`), returning `null` for float-bearing
  aggregates.

## 7. Files modified / added in the current increment

- **Semantics:** `compiler/sema.zig` now owns per-module top-level tables,
  unaliased import edges, cached resolution results, and collision checks for
  external function link names.
- **Backend/types:** `compiler/symbol.zig` already carried `link_name`; this
  increment assigns and consumes unique internal names in
  `compiler/backend/llvm.zig`. `compiler/types.zig` separates source struct names
  from unique LLVM identified-struct names.
- **Integration coverage:** `module_namespaces`, `module_open_shadow`,
  `module_open_diamond`, `open_transitive`, `module_extern_dedup`, and
  `module_export_pair`, plus negative ambiguity, alias-only visibility,
  external declaration/definition cases under `tests/integration/errors/`.
- **Specifications:** `CHANGELOG.md`, `README.md`, `docs/compiler-architecture.md`,
  `docs/diagnostics.md`, `docs/language-design.md`, `docs/language-reference.md`,
  `docs/roadmap.md`, and this continuity record.

Earlier import, alias, visibility and slice implementations remain in the
branch history; this increment does not redo them.

## 8. Known limitations

- Module namespaces are source-file identities only. There is no package
  registry, search path, module re-export syntax, or symlink-canonical identity.
  Same-name opened public declarations are ambiguous at use (`E0471`); aliases
  are the current disambiguation mechanism.
- Top-level declarations are public by default; `private` blocks cross-module
  references, including alias-qualified access. Import paths remain lexical and
  relative to the importing file.
- `usize` / `isize` and C ABI lowering assume 64-bit `x86_64` Linux System V.
- Floating-point structs, fixed-size arrays by value, variadic functions, and
  function pointers are rejected across `extern`/`export` C ABI boundaries.
- Runtime pointer safety checks exact `null` values and slice/array bounds, not
  temporal lifetimes (`free`/dangling pointers) or raw pointer arithmetic
  bounds.

## 9. Next logical task for resumption

Implement the profile-specific runtime-check policy. First pass an explicit
profile/check policy from `driver.Profile` through compilation and IR lowering;
define which checks each profile keeps or removes without silently introducing
undefined behavior. Preserve the current all-checks-by-default contract until a
check category has a documented policy and positive/negative tests in every
relevant profile. Keep C ABI behavior, module visibility and deterministic
imports independent of optimization profiles.

## 10. Latest validation and Git state

- Toolchain: Zig `0.17.0`; Clang `22.1.8` through `zig cc`.
- `zig fmt --check build.zig compiler build-system`: passed.
- `zig build`, `zig build test`, and `zig build -Doptimize=ReleaseSafe`: passed.
- `tests/integration/run.sh`: `97 passed, 0 failed` against the Debug build and
  `97 passed, 0 failed` against the ReleaseSafe build. New module coverage checks
  same-name functions/globals/types across modules, private helpers, open-import
  shadowing, transitive and diamond imports, ambiguity, alias-only visibility,
  and extern/export linkage. Existing profiles, ABI interop, 900 robustness
  cases, imported diagnostics and cache invalidation also passed.
- Documentation gates: 126 diagnostic codes synchronized; 19 Markdown files
  link-checked; version metadata remains `0.1.0-alpha.2`.
- Sanitizers were not run; the repository does not currently expose a sanitizer
  gate. Static/dynamic regression coverage is the existing unit, integration,
  ABI and robustness suites.
- Git: branch `arena/2b67c8fb-kyn`; module isolation is committed as
  `2cd25da` (`feat(sema): isolate module namespaces and name linkage`). Earlier
  aliases/visibility, imports and slicing work remains in branch history,
  including merge reconciliation `f31533e`. This continuity update is a
  documentation-only follow-up; push both commits only to the session branch.
  No `main` merge or release/version change was made.
