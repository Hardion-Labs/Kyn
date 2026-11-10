# Technical continuity record

This document is the persistent engineering state record for `Hardion-Labs/Kyn`.
Before starting any future increment, read this record and cross-check every
entry against the actual source tree, test suite and `git log`. Never rely on
this file if the codebase disagrees; reconcile any discrepancy immediately.

## 1. Current real stage

- **Published toolchain baseline:** `v0.1.0-alpha.3` (`84093a2`), Zig `0.17.0`
  + Clang/LLVM opaque-pointer IR (`ptr`). Tag and Release were published
  2026-11-09T23:05:28Z; the release-readiness gate passed 17/17 checks for
  that SHA before tagging, and main CI run `42717072114` was green.
- **Active stage:** Post-`v0.1.0-alpha.3` incremental development. Any future
  pre-release boundary requires the same human-authorized procedure per
  [release-checklist.md](release-checklist.md).
- **Completed increment in current cycle:** Const-polymorphic slicing,
  open-ended subslice syntax (`[..]`, `[start..]`, `[..end]`, `[start..end]`),
  slice/array ergonomics (`.ptr`, `.len`, `->ptr`, `->len`), lvalue/mutability
  soundness fixes (`E0464`, immutable globals, read-only properties, `i32`
  default enum backing), pointer arithmetic fixes, static/runtime slice null
  and bounds safety, `< 8`-byte / `< 16`-byte C ABI aggregate packing hardening,
  executable slice C ABI verification, and specification reconciliation.
- **Latest ABI increment completed and locally validated:** exact reverse
  direct mixed-class structs `{ i32, f64 }` / `{ u32, f64 }` at natural offsets
  0/8, size 16. Clang and Kyn both use `i32, double` parameters and
  `{ i32, double }` returns. Nested, wider-integer, and other mixed layouts
  remain `E0473` unless separately specified.
- **Latest ABI increment completed and locally validated:** exactly two
  direct mixed-width `f32`/`f64` fields at natural offsets 0/8 (16 bytes).
  `{ f32, f64 }` lowers as `float, double` parameters and a
  `{ float, double }` return; the reverse `{ f64, f32 }` uses `double, float`
  and `{ double, float }`. Clang IR probe confirms the coercions; other
  mixed-class layouts remain `E0473`.
- **Previous ABI increment (merged, `2869235`):** exactly three
  adjacent direct `f32` fields (12-byte layout, `<2 x float>, float`
  arguments and a `{ <2 x float>, float }` return) and exactly four adjacent
  direct `f32` fields (16-byte layout, `<2 x float>, <2 x float>` arguments
  and a `{ <2 x float>, <2 x float> }` return). Clang IR probe confirms the
  parameter and return coercions; class merging remains `E0473` outside the
  supported shapes.
- **Latest merged module-system increment:** Per-source top-level namespaces
  layered on deterministic relative imports and aliases. Unaliased imports open
  public names through their transitive unaliased dependency closure; local
  declarations shadow opens; multiple distinct public candidates are ambiguous
  at use (`E0471`). Alias-only edges remain qualified-only. Same-module
  duplicates are `E0401`; same-spelled declarations across modules are
  distinct. `private` remains enforced (`E0467`), and backend names are
  module-qualified while C `extern`/`export` names retain ABI spellings.

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
    `struct { T *ptr; size_t len; }`), and aggregates with supported
    `INTEGER`-class eightbytes. Aggregates `<= 16` bytes use 1–2 `i64` registers
    (with zero-padded packing for partial eightbytes); larger supported layouts
    use `sret`/`byval` on `x86_64` Linux.
  - *Implemented & validated:* A one-field direct `f32`/`f64` struct crosses
    the boundary as a scalar SSE value. Exactly two adjacent direct `f32` fields
    use LLVM `<2 x float>` for SSE/SSEUP; exactly two direct `f64` fields use
    two SSE argument registers and an LLVM `{ double, double }` return; direct
    `{ f64, i32 }` / `{ f64, u32 }` use SSE `double` then INTEGER `i32`; and
    direct `{ i32, f64 }` / `{ u32, f64 }` use INTEGER `i32` then SSE `double`.
    Only these exact two-field mixed layouts are accepted; other unsupported
    small mixed-class layouts remain rejected with `E0473`.
  - *Implemented & validated (current cycle):* Exactly three adjacent direct
    `f32` fields (12 bytes) flatten as `<2 x float>, float` with a
    `{ <2 x float>, float }` return; exactly four adjacent direct `f32` fields
    (16 bytes) flatten as `<2 x float>, <2 x float>` with a
    `{ <2 x float>, <2 x float> }` return. Shapes verified against Clang IR;
    covered by `cabi_sse_f32_triple` and `cabi_sse_f32_quad` in both directions.
    Exactly two direct mixed-width `f32`/`f64` fields at natural offsets 0/8
    (16 bytes) are also accepted: `{ f32, f64 }` uses `float, double`
    arguments and a `{ float, double }` return; the reverse `{ f64, f32 }`
    uses `double, float` and `{ double, float }`. Clang IR probe confirms the
    coercions; covered by `cabi_mixed_f32_f64` and `cabi_mixed_f64_f32`.
  - *Not yet implemented:* Remaining System V `SSE`/`SSEUP` coercions,
    by-value fixed arrays, variadic `extern fn`, non-`x86_64-linux` calling
    conventions, and function pointers/callbacks.
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

1. **Explicit module re-exports** (if needed, specify a syntax and visibility
   model; current unaliased imports are transitively open, while aliased edges
   are not re-exported unqualified).
2. **Extended C ABI classification** (remaining System V SSE/SSEUP coercions
   beyond the f32 run shapes and f64 pair, complete eightbyte-class merging,
   function pointers, and target ABI selection instead of host-assumed
   `64`-bit `usize`).
3. **Tagged unions / explicit error-return types** (`Result`-style value flow
   without hidden exceptions or unwinding).
4. **Freestanding `std` core (`std/`) and optional runtime (`runtime/`)** built
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
  classifies supported C ABI aggregates into `.small_1` (`<= 8B`), `.small_2`
  (`9..16B`), or `.memory` (`> 16B` `sret`/`byval`). The classifier tracks
  integer/SSE presence per eightbyte and accepts SSE+INTEGER merges into
  `INTEGER`. One direct `f32`/`f64` field maps to scalar SSE; exactly two
  adjacent direct `f32` fields map to `<2 x float>` SSE/SSEUP; exactly three
  adjacent direct `f32` fields map to `<2 x float>, float` arguments and a
  `{ <2 x float>, float }` return; exactly four adjacent direct `f32` fields
  map to `<2 x float>, <2 x float>` arguments and a
  `{ <2 x float>, <2 x float> }` return; exactly two direct `f64` fields map
  to the `{ double, double }` return pair and two scalar `double` arguments.
  A direct `{ f64, i32 }` at offsets 0/8 maps to
  `double, i32` parameters and `{ double, i32 }` returns. A direct
  `{ f32, f64 }` at offsets 0/8 maps to `float, double` parameters and a
  `{ float, double }` return; the reverse `{ f64, f32 }` maps to
  `double, float` and `{ double, float }`. Other unsupported
  SSE/SSEUP and split-class layouts remain rejected.

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

## 9. Runtime-check policy increment

- Added `ir.RuntimeCheckPolicy` with independent bounds, integer-overflow,
  division, shift, and exact-null dereference switches. All switches default to
  enabled and `driver.Profile.runtimeCheckPolicy()` explicitly returns the full
  policy for `debug`, `safe`, `release`, and `fast`.
- `compiler.main` passes the selected profile to `driver.compile`; compilation
  passes its policy to `llvm.Lowering`. Trap-emission paths consult the
  corresponding policy category. Direct lowering unit construction explicitly
  uses `.all`.
- Extended the profile matrix to exercise overflow, fixed-array bounds, slice
  bounds, division, shift-range, null dereference, and null slicing traps in
  every profile. Existing profiles and all checks remain behaviorally unchanged.
- Updated `docs/safety-model.md` to document the explicit policy and its tested
  scope. This increment does not introduce a check-removal mode or alter module
  visibility, C ABI behavior, or optimization flags.

## 10. Validation and Git snapshot at the module/profile increment

- Toolchain: Zig `0.17.0`; Clang `22.1.8` through `zig cc`.
- `zig fmt --check build.zig compiler build-system`, Debug and ReleaseSafe
  builds/unit tests, and Debug/ReleaseSafe `tests/integration/run.sh` passed.
  Both integration runs reported `131 passed, 0 failed`, including ABI
  diagnostics, the four-profile trap matrix, docs gates, 900 robustness cases,
  LLVM/object generation, Kyn+C+Zig interop, and cache tests.
- Diagnostic documentation covers 127 codes; Markdown links across 19 files
  and version metadata (`0.1.0-alpha.2`) passed.
- Sanitizers were not run; the repository has no sanitizer gate. New ABI paths
  were verified by native Clang C↔Kyn integration and generated LLVM output.
- Historical Git snapshot at this point in the timeline: branch
  `arena/2b67c8fb-kyn` had PR #1 open against `main`; the mixed-class ABI
  implementation was committed as `4274907`. This was superseded by later
  merges recorded in the final continuity section.

## 11. C ABI diagnostic correction increment

- Inspection found unsupported aggregate C ABI signatures were reported as
  `E0410`, which is also the documented and implemented void-parameter error.
  ABI documentation incorrectly attributed these cases to `E0412`/`E0413`,
  which actually describe global initializer errors.
- Added `E0473` for aggregate parameters/returns whose `aggregateBoundaryClass`
  is unavailable for the current target/layout. This covers fixed-array-by-value
  and currently unsupported ABI layouts while preserving rejection. `E0410`
  remains the void-parameter diagnostic.
- Added regressions for void parameters, float aggregate parameters and
  returns, plus array parameters; integration fixtures assert `E0473`.
  Documentation and changelog corrections were committed in `7ea4f50` and
  `f165fd8`.

## 12. Mixed INTEGER-class float aggregate ABI increment

- `aggregateLayoutGuess` now computes natural layout for `f32`/`f64` fields.
  The target-gated x86_64 Linux classifier tracks INTEGER/SSE presence per
  eightbyte. For aggregates up to 16 bytes, it accepts an eightbyte when its
  merged class is INTEGER, including float+integer members in that same
  eightbyte; an SSE-only eightbyte still yields `E0473`. Larger supported
  layouts continue through the existing memory (`sret`/`byval`) ABI path.
- Extended C↔Kyn fixtures verify both field orders (`{ float, i32 }`,
  `{ i32, float }`) in register-passed arguments and returns, plus a
  float-bearing large aggregate through `sret`/`byval`. Added an invalid SSE-only
  mixed aggregate regression.
- Fixed two paths exposed by those fixtures: LLVM float constants now emit
  correctly rounded hexadecimal encodings, and `lowerCall` preserves the hidden
  sret pointer before transferring its argument list to owned storage.
- Updated `README.md`, `CHANGELOG.md`, `docs/abi.md`, `docs/type-system.md`,
  `docs/language-reference.md`, `docs/roadmap.md`, and this record. Full SSE/SSEUP
  coercion for small SSE-only aggregates, fixed arrays, function pointers, and
  non-x86_64 Linux targets remain unsupported.

## 13. Scalar SSE aggregate ABI increment (completed)

- A struct with exactly one direct `f32` or `f64` field uses an LLVM scalar
  float/double for C ABI parameters and returns. The backend reconstructs
  incoming values and materializes results without changing the internal Kyn
  aggregate ABI.
- C↔Kyn tests cover argument and return paths for both widths. Multi-field
  float layouts remained rejected at this increment's boundary.
- At that stage formatting, Debug/ReleaseSafe unit tests and integration passed;
  both integration runs reported `133 passed, 0 failed` using Zig's bundled
  Clang frontend (`zig cc`).

## 14. Two-f32 SSE/SSEUP aggregate ABI increment (completed)

- Scope: only a struct with exactly two adjacent direct `f32` fields, occupying
  eight bytes, is classified as SSE/SSEUP and lowered as LLVM `<2 x float>`.
  The backend keeps this transport-only type internal, emits explicit `align 4`
  for vector loads/stores to honor the struct's natural C alignment, and leaves
  source-level field access and the internal Kyn ABI unchanged.
- C↔Kyn argument/return regression coverage was added. Existing two-f32
  rejection fixtures now exercise three-f32 aggregates; nested pairs and the
  reverse mixed-class order (`{ i32, f64 }`) remain rejected with `E0473`.
- Validation complete: `zig fmt --check build.zig compiler build-system`,
  Debug/ReleaseSafe unit tests, and full Debug/ReleaseSafe integration pass.
  Each integration run reports `134 passed, 0 failed`, including the new
  `cabi_sseup_f32_pair` exit-57 fixture, diagnostics, docs checks, 900 robustness
  cases, runtime-check profile matrix, and Kyn+C+Zig interop. Zig `0.17.0` and
  its bundled Clang frontend (`zig cc`) were installed under `/tmp` because no
  system Zig or standalone Clang was present. No sanitizer gate is configured.
- Git/PR state verified: the working branch is `arena/2b67c8fb-kyn` at
  `7f9cb2c` (published base); PR #1 is open and its remote head is `b3e8909`.
  The PR implementation already exists in this checkout as a large set of
  uncommitted tracked/untracked files, along with this increment. Preserve the
  divergence; no reset, commit, push, or merge was performed. The GitHub CI
  success belongs to the prior PR head, not this local working tree.

## 15. Two-f64 SSE aggregate ABI increment (completed)

- Scope: support only a struct with exactly two direct `f64` fields and natural
  size 16. The classifier identifies the two SSE eightbytes; declarations and
  definitions flatten parameters to two LLVM `double`s and represent the
  return as LLVM `{ double, double }`. The backend uses field-pointer loads and
  stores for arguments and direct aggregate-memory coercion for the return.
- Nested `{ f64, f64 }` wrappers and other unsupported SSE layouts remain
  rejected rather than being accepted based only on size or SSE presence.
- Added C↔Kyn parameter and return coverage in both directions and sema
  acceptance/rejection regressions. Debug and ReleaseSafe unit and integration
  gates pass; each integration run reports `135 passed, 0 failed`, including
  `cabi_sse_f64_pair` (exit 39), docs/diagnostic gates, 900 robustness cases,
  runtime-check profiles, and Kyn+C+Zig linking. `zig fmt --check` also passes.
- No sanitizer run was performed; no sanitizer gate is configured. Zig 0.17.0
  and its bundled Clang (`zig cc`) reside under `/tmp` for this validation.
- Git divergence recorded for section 14 remains: local HEAD is `7f9cb2c`, PR
  #1 remote head `b3e8909`, and prior implementation is an uncommitted patchset.
  Preserve that state; no reset, commit, push or merge was performed.

## 16. Direct f64+i32 SSE/INTEGER aggregate ABI increment (completed)

- Scope: only a two-field struct with direct `f64` at offset 0 followed by
  `i32`/`u32` at offset 8 and natural size 16. It classifies to SSE then
  INTEGER. LLVM declarations/definitions flatten arguments as `double, i32`
  and coerce returns as `{ double, i32 }`; this mapping was checked against
  Clang 22 IR.
- The backend uses an internal ABI-only composite type for the return and
  field-pointer loads/stores for flattened parameters. Internal Kyn aggregate
  calls are unchanged. Reverse field order, nested wrappers and other split
  SSE/INTEGER layouts remain rejected with `E0473`.
- C↔Kyn tests and semantic coverage include both `i32` and `u32` signatures;
  the C interoperability fixture verifies `i32`. Debug and ReleaseSafe unit
  and integration gates pass; each integration run reports `136 passed, 0
  failed`, including `cabi_mixed_sse_integer` (exit 43), docs/diagnostic gates,
  900 robustness cases, runtime-check profiles and Kyn+C+Zig linking. Formatting
  checks pass.
- No sanitizer run was performed; no sanitizer gate is configured. The checkout/
  PR divergence recorded in section 15 remains unchanged; preserve every
  existing uncommitted file and do not reset, commit, push or force-push.

## 17. Direct f64+i32 SSE/INTEGER aggregate ABI increment (completed)

- Scope: exactly two direct fields, `f64` at offset 0 and `i32`/`u32` at
  offset 8, natural size 16; LLVM parameters `double, i32`, return
  `{ double, i32 }`. This exact layout passed C↔Kyn argument/return tests.
- Other split mixed layouts were rejected until independently specified.

## 18. Reverse i32+f64 INTEGER/SSE aggregate ABI increment (completed)

- Scope: exactly two direct fields, `i32`/`u32` at offset 0 and `f64` at
  offset 8, natural size 16. Clang 22 IR probe confirms parameters
  `i32, double` and return `{ i32, double }`.
- Sema classifies only this direct shape after verifying INTEGER then SSE in
  separate eightbytes. The backend flattens parameters in field order and uses
  the internal transport type `{ i32, double }` for returns. The internal Kyn
  ABI is unchanged; nested wrappers, 64-bit integer fields and other layouts
  remain rejected with `E0473`.
- Tests cover semantic acceptance for signed/unsigned 32-bit fields, rejection
  of nested and wider variants in both parameter and return positions, and
  C↔Kyn arguments/returns in both directions. The C fixture asserts offsets
  0/8 and size 16 and exits 43. Generated Kyn IR is
  `i32, double` arguments and `{ i32, double }` return.
- Zig 0.17.0 formatting/build/unit gates and Debug/ReleaseSafe integration
  gates pass. Each full integration run reports `137 passed, 0 failed`, with
  diagnostics, docs, 900 robustness inputs, codegen and Kyn+C+Zig linking.
  `git diff --check` passes. Sanitizers were not run; no sanitizer gate exists.

## 19. Repository snapshot before merging the reverse mixed-class increment

- PR #1 was merged into `main` at `da20545`, and its main CI passed. Its old
  remote Arena branch was deleted. This session works on
  `arena/6aa18c81-kyn`, based on that merge commit. The checkout is shallow.
- The implementation was committed as `a1cc73c` and pushed only to the session
  branch as PR #2. PR CI passed before merge. No release/version metadata was
  changed. Sanitizers have no configured project gate.

## 20. Current repository state after the reverse mixed-class merge

- PR #2, `feat(abi): support reverse mixed SSE aggregate order`, is merged into
  `main` at `da2e5f6`. Main CI passed for that exact merge commit. Post-merge
  local Debug/ReleaseSafe formatting, builds, unit tests and full integrations
  passed; each integration run reported `137 passed, 0 failed`.
- The current session remains on `arena/6aa18c81-kyn` at `a1cc73c`; its tree
  matches `origin/main`. The working tree was clean at this state update. The
  checkout is shallow and the local `main` ref is not advanced; do not switch
  branches or push to any branch other than this session branch.
- Superseded by section 21: the `v0.1.0-alpha.3` tag and Release were created
  for commit `84093a2` after a 17/17 gate pass. The next ABI increment still
  requires its own Clang evidence and exact-shape tests. Explicit module
  re-export remains a language-design decision.

## 21. v0.1.0-alpha.3 release record

- Release preparation commit `84093a2` (`release: prepare v0.1.0-alpha.3`)
  bumped version metadata (`build.zig.zon`, `compiler/main.zig`,
  `build-system/main.zig`), renamed the changelog `[Unreleased]` section to
  `[0.1.0-alpha.3] - 2026-11-09` and synchronized README, roadmap,
  release-checklist, `tools/release-check.sh` and the version badge.
- Main CI for `84093a2` (run `42717072114`, 1m57s) is green. Clean-room
  release-readiness gate passed 17/17 (`./tools/release-check.sh
  0.1.0-alpha.3`), including fresh clone fmt/build/unit/integration checks and
  version metadata consistency.
- Tag `v0.1.0-alpha.3` is annotated at `84093a2` and pushed to origin.
  GitHub Release `Kyn v0.1.0-alpha.3` is published and marked Latest:
  https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.3
- `v0.1.0-alpha.1` and `v0.1.0-alpha.2` tags/releases remain untouched.
  `docs/continuity.md` was updated after publication to remove the stale
  "no release exists" snapshot. No source/ABI stability is promised between
  alpha releases.

## 22. Adjacent f32 runs ABI increment (completed and merged)

- Merged into `main` as PR #4 (merge commit `2869235`); implementation
  commit `0ceb1f4`. CI run for the PR (`42731516995`, 1m55s) was green.

- Scope: only aggregates with exactly three adjacent direct `f32` fields
  (12 bytes, natural layout) and exactly four adjacent direct `f32` fields
  (16 bytes, natural layout). Nested wrappers, mixed float/integer runs, and
  other small mixed-class layouts remain rejected with `E0473`. No other
  behavior changed: internal Kyn aggregate calls, the internal Kyn ABI, the
  module system, and the runtime-check policy are all untouched.
- System V AMD64 eightbyte classification does not produce a single
  `<3 x float>` or `<4 x float>` argument/return register for these shapes.
  Clang 23 IR probes confirm and govern the lowering:
  - `struct { f32, f32, f32 }`: parameters `<2 x float>, float`, return
    `{ <2 x float>, float }`;
  - `struct { f32, f32, f32, f32 }`: parameters `<2 x float>, <2 x float>`,
    return `{ <2 x float>, <2 x float> }`.
- Implementation: new transport types `.abi_v2f32_f32` and `.abi_v2f32_v2f32`
  in `compiler/types.zig` (LLVM `{ <2 x float>, float }` and
  `{ <2 x float>, <2 x float> }`), new `BoundaryClass` variants `sse_f32x3`
  and `sse_f32x4` in both `compiler/sema.zig` and `compiler/backend/llvm.zig`.
  The classifier scan now counts SSE-only eightbytes (`has_sse && !has_integer`)
  instead of tracking a single index: zero SSE-only eightbytes keep the
  existing `small_1`/`small_2` path unchanged, exactly one SSE-only eightbyte
  at size 8 keeps `sse_f32x2`, two SSE-only eightbytes with 3 or 4 direct
  `f32` fields return the new classes, and every other mixture is `E0473`.
  Argument lowering and function-definition unpacking split the aggregate into
  its vector half(s) and trailing scalar; returns and call results use the
  new transport types with `align 4` load/store, matching Clang's alignment.
- Validation: `zig build test` passes (74 tests, 1 updated expect-clean);
  `zig fmt --check` is clean; integration suite passes in both `safe` and
  `release` profiles with the new `cabi_sse_f32_triple` (exit 65) and
  `cabi_sse_f32_quad` (exit 50) C↔Kyn fixtures, exercising argument and
  return paths in both directions. Emitted Kyn IR signatures match Clang's
  exactly. The previously-rejected `FloatTriple` unit fixtures now assert
  acceptance, and negative `E0473` coverage moved to a mixed
  `{ f32, i32, f32 }` aggregate (integration `abi_float_param.kyn` /
  `abi_float_return.kyn` and the unit test both updated accordingly).
  Total integration count: 139 passed, 0 failed.
- No sanitizer run was performed; no sanitizer gate is configured. Zig 0.17.0
  and its bundled Clang via `zig cc` are used for the toolchain; the
  integration interop tests used the installed `clang` (v23.1.2).
- Git state: implementation is merged into `main` at `2869235` via PR #4.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, Debug/ReleaseSafe integration matrix — all report
  `139 passed, 0 failed`. Release artifacts and tags are untouched.

## 23. Mixed-width f32/f64 aggregate ABI increment (completed, not yet committed)

- Scope: only aggregates with exactly two direct fields of mixed float
  widths at natural offsets 0/8 with 16-byte layout: `{ f32, f64 }` and
  `{ f64, f32 }`. No other behavior changed: internal Kyn aggregate calls,
  the module system, and the runtime-check policy are untouched, and all
  previously supported shapes are bit-identical (the new exact-shape checks
  return before the shared SSE-only scan).
- System V AMD64 eightbyte classification does not merge these two eightbytes
  into one register pair for the struct; Clang 23 IR probes show Clang lowers
  them directly as scalar parameters in field order and returns the struct
  pair. Clang IR evidence:
  - `struct { float a; double b; }`: parameters `(float, double)`, return
    `{ float, double }`;
  - `struct { double a; float b; }`: parameters `(double, float)`, return
    `{ double, float }`.
- Implementation: transport types `.abi_f32_f64` and `.abi_f64_f32`
  (`{ float, double }` and `{ double, float }`) added to `compiler/types.zig`
  and `compiler/backend/llvm.zig`; new `BoundaryClass` variants `sse_f32_f64`
  and `sse_f64_f32` in both sema and backend. The size-16 exact-shape block
  now runs the two new checks after the existing `{ f64, i32 }` / `{ i32, f64 }`
  checks. Parameters flatten in field order (matching the existing
  per-field flatten arm), definition-side unpacking and call-side argument
  lowering reuse the same per-field store/load path, and returns use the new
  transport types with `align 8` loads/stores and an LLVM-alloca-friendly
  natural alignment, matching Clang.
- Validation: `zig build test` passes (74 tests, two new expect-clean blocks);
  `zig fmt --check` is clean; integration suite passes in all four profiles
  with the new `cabi_mixed_f32_f64` (exit 38) and `cabi_mixed_f64_f32`
  (exit 36) C↔Kyn fixtures, covering argument and return paths in both
  directions. Emitted Kyn IR signatures match Clang's exactly. Unit coverage
  extended with two mirror blocks in the `C ABI mixed INTEGER and SSE
  eightbytes accept exact direct layouts` test. Total integration count:
  141 passed, 0 failed.
- No sanitizer run was performed; no sanitizer gate is configured. The
  interop tests used the installed `clang` (v23.1.2).
- Git state: implementation is on a session branch; push, PR, CI and merge
  pending at the time of writing. Release artifacts and tags are untouched.

Explicit module re-export syntax remains a language-design decision, not an
assumed feature.
