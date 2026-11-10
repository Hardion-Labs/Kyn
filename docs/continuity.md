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
- **Latest ABI increment completed and merged (`48b2189`, PR #15):** the
  `.small_2s` boundary class now follows Clang's leaf-flattening rule, so
  nested integer members are classified by their leaves:
  `{ struct { short x; } a; long b; }` lowers to `i16, i64` parameters and a
  `{ i16, i64 }` return instead of the packed `.small_2` form. The semantic
  analyzer owns the leaf model (`sema.smallPairLeaves`), so the
  classification and the boundary lowering cannot drift apart.
  `cabi_nested_pair_widths` covers the nested layouts in both directions.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/Safe/Release/Fast integration matrix
  — all report `166 passed, 0 failed`. See §33 for the full scope,
  implementation map and validation results.
- **Latest ABI increment completed and merged (`f58dd99`, PR #16):** the C ABI
  boundary classification now derives every eightbyte register from the
  *leaf* model, with nested structs flattened into their members exactly as
  Clang does. A nested integer member travels at its own width
  (`{ struct { short x; } a; long b; }` → `i16, i64`), a nested `f32` travels
  as a scalar and a nested `f64` pair as two scalars. The rule set shrank by
  roughly 400 lines. `cabi_nested_sse_widths` covers the nested layouts in
  both directions. Post-merge gates on `main` pass: `zig fmt --check`,
  Debug/ReleaseSafe builds and unit tests, and the Debug/Safe/Release/Fast
  integration matrix — all report `165 passed, 0 failed`. See §34 for the
  full scope, implementation map and validation results.
- **Latest ABI increment completed and merged (`1a76dbb`, PR #14):** two-member
  structs whose members occupy one eightbyte each and are both integer scalars
  now lower as `.small_2s` — each member passes in its own register at its own
  width and the aggregate returns as the matching pair (`{ i8, i64 }`,
  `{ i16, i64 }`, `{ i32, i64 }` and the reversed layouts), matching Clang's
  System V lowering for all six probed signatures. `cabi_small_pair_widths`
  covers both directions for all six layouts. Post-merge gates on `main` pass:
  `zig fmt --check`, Debug/ReleaseSafe builds and unit tests, and the
  Debug/Safe/Release/Fast integration matrix — all report
  `165 passed, 0 failed`. See §32 for the full scope, implementation map and
  validation results.
- **Latest ABI increment completed and merged (`9bb08c4`, PR #13):** singleton
  `i8`/`i16`/`i32`/`i64` aggregates pass in one exact-width INTEGER argument
  register (size-derived: 1→`i8`, 2→`i16`, ≤4→`i32`, otherwise `i64`),
  matching Clang's exact-size register widths for the INTEGER class.
  `cabi_small_singleton` and `cabi_small_singleton_u8` cover both directions.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `164 passed, 0 failed`.
- **Previous ABI increment completed and merged (`027315b`, PR #12):** aggregates with two
  or more smaller-INTEGER members packed into one eightbyte (only INTEGER
  members, size ≤ 8) followed by a single `f32` or `f64` in the next eightbyte
  pass (only that scalar) now lower as `( i64, float )` or
  `( i64, double )` parameters with `{ i64, float }` / `{ i64, double }`
  returns, matching Clang's packed-`INTEGER` eightbyte then `SSE` scalar slot
  exactly. Clang IR probes confirm all eight signatures (u3/u5/V1/V2/V4/V5/V6/
  V7 probe). The lowering routes through the already-implemented
  `.sse_i64_f32x` and `.sse_i64_f64x` classes (two parameters, packed transport),
  so no new BoundaryClass variants or transport types are introduced.
  Previously rejected with `E0473`; now accepted with exact-shape acceptance
  checks inside `classifyMixedRunAggregate`. Integration matrix reports
  `162 passed, 0 failed` in all four profiles; CI runs for the merge and the
  docs record are both green.
- **Previous ABI increment completed and merged (`9f0affa`, PR #11):** singleton
  `enum` members at natural offsets 0 or 8 (16 bytes) pass at the boundary
  at their backing integer width. Integration matrix reports
  `160 passed, 0 failed` in all four profiles.
- **Previous ABI increment completed and merged (`2ba5000`, PR #10):** singleton
  `bool` members at natural offsets 0 or 8 (16 bytes) pass at the boundary
  as a full `i8` parameter. Integration matrix reports
  `157 passed, 0 failed` in all four profiles.
- **Previous increment completed and merged (`f869fb1`, PR #9): bool zero-extension fix.** Previously
  `bool` fields/locals were stored into memory as raw `i1`, leaving the upper
  seven bits of their byte undefined. Passed across an `extern`/`export`
  C ABI boundary as part of a packed `i64` (current lowering for
  merged-INTEGER eightbytes) those garbage bits made the byte
  indistinguishable from a full `i8` to the C side, which reads `_Bool` as a
  full byte. Every bool memory store now emits `zext i1 -> i8` followed by an
  `i8` store, restoring the full-byte definition Clang requires at the C
  ABI; verified by generated IR (`zext i1 -> i8` + `store i8`) and by the new
  `cabi_multi_merge_bool` fixture. No behavior change for non-bool stores;
  integration matrix reports `155 passed, 0 failed` in all four profiles.
- **Previous ABI increment completed and merged (`b0a149f`, PR #8):** exactly two
  direct small integer members (`i8`/`u8` or `i16`/`u16`) at natural offsets
  0/8 (16 bytes), signedness irrelevant: `{ i8/u8, f64 }` lowers as
  `i8, double` parameters and a `{ i8, double }` return; `{ i16/u16, f64 }`
  uses `i16, double` and `{ i16, double }`; the reverse `{ f64, i8/u8 }` /
  `{ f64, i16/u16 }` uses `double, i8` / `double, i16` and the matching
  `{ double, i8 }` / `{ double, i16 }` returns. Sub-32-bit integer members
  (`i8`, `u8`, `i16`, `u16`) and `bool` are also accepted inside
  `INTEGER`-merged eightbytes (packed `i64` irrespective of member widths),
  verified against Clang IR probes; singleton `bool` remains rejected (`E0473`).
  Post-merge gates on `main` pass (`154 passed, 0 failed` in all profiles).
- **Previous ABI increment completed and merged (`edda8b9`, PR #7):** exact multi-member
  12/16-byte layouts whose eightbytes split into an SSE-only slot and an
  INTEGER/merged slot. `{ f32, f32, i32 }` (`<2 x float>, i32` and
  `{ <2 x float>, i32 }`), `{ f32, f32, i64/u64 }` (`<2 x float>, i64` and
  `{ <2 x float>, i64 }`), `{ i32/u32, f32, f32 }` / `{ f32, i32/u32, f32 }`
  (merged `INTEGER` passed as `i64`, then `float`), `{ i32/u32, f32, f64 }` /
  `{ f32, i32/u32, f64 }` (merged `INTEGER` as `i64`, then `double`),
  `{ f64, i32/u32, i32/u32 }` / `{ f64, i32/u32, f32 }` (`double` then
  merged `INTEGER`), `{ i64/u64, f32, f32 }` (`i64, <2 x float>`),
  all-SSE triples `{ f32, f32, f64 }` (`<2 x float>, double`) and
  `{ f64, f32, f32 }` (`double, <2 x float>`), and four-member
  `{ f32, f32, i32, f32 }` / `{ i32/u32, f32, f32, f32 }` /
  `{ f32, i32/u32, f32, f32 }`. Clang IR probes confirm every signature.
- **Previous ABI increment completed and merged (`224e8f3`, PR #6):** exactly two
  direct mixed-width float/64-bit-integer fields at natural offsets 0/8
  (16 bytes), signedness irrelevant: `{ f32, i64 }` / `{ f32, u64 }` lower as
  `float, i64` parameters and a `{ float, i64 }` return; the reverse
  `{ i64, f32 }` / `{ u64, f32 }` uses `i64, float` and `{ i64, float }`;
  `{ f64, i64 }` / `{ f64, u64 }` use `double, i64` and `{ double, i64 }`;
  and `{ i64, f64 }` / `{ u64, f64 }` use `i64, double` and `{ i64, double }`.
  Clang IR probes confirm all eight signatures; other mixed-class layouts
  remain `E0473`. See section 24.
- **Previous ABI increment completed and merged (`511350d`, PR #5):** exactly two
  direct mixed-width `f32`/`f64` fields at natural offsets 0/8 (16 bytes).
  `{ f32, f64 }` lowers as `float, double` parameters and a
  `{ float, double }` return; the reverse `{ f64, f32 }` uses `double, float`
  and `{ double, float }`. Clang IR probe confirms the coercions; other
  mixed-class layouts remain `E0473`. Main CI for the merge and post-merge
  validation are both green (see section 23).
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
    Exactly two direct mixed-width float/64-bit-integer fields at natural
    offsets 0/8 (16 bytes) are accepted as well, signedness irrelevant:
    `{ f32, i64 }` / `{ f32, u64 }` use `float, i64` and `{ float, i64 }`;
    `{ i64, f32 }` / `{ u64, f32 }` use `i64, float` and `{ i64, float }`;
    `{ f64, i64 }` / `{ f64, u64 }` use `double, i64` and `{ double, i64 }`;
    and `{ i64, f64 }` / `{ u64, f64 }` use `i64, double` and `{ i64, double }`.
    Clang IR probes confirm all eight signatures; covered by
    `cabi_mixed_f32_i64`, `cabi_mixed_i64_f32`, `cabi_mixed_f64_i64` and
    `cabi_mixed_i64_f64`.
    Exact multi-member 12/16-byte layouts whose eightbytes split into an
    SSE-only slot and an INTEGER/merged slot are also accepted, with their
    probed Clang coercions: `{ f32, f32, i32 }` (`<2 x float>, i32`),
    `{ f32, f32, i64 }` (`<2 x float>, i64`), `{ i32/u32, f32, f32 }` /
    `{ f32, i32/u32, f32 }` (merged `INTEGER` passed as `i64`, then `float`),
    `{ i32/u32, f32, f64 }` / `{ f32, i32/u32, f64 }` (merged `INTEGER` as
    `i64`, then `double`), `{ f64, i32/u32, i32/u32 }` / `{ f64, i32/u32, f32 }`
    (`double` then merged `INTEGER`), `{ i64/u64, f32, f32 }`
    (`i64, <2 x float>`), and four-member
    `{ f32, f32, i32, f32 }` / `{ i32/u32, f32, f32, f32 }` /
    `{ f32, i32/u32, f32, f32 }`. All signatures verified against Clang
    IR probes; covered by `cabi_multi_f32x2_i32`, `cabi_multi_f32x2_i64`,
    `cabi_multi_i32_f32pair`, `cabi_multi_i64_f32pair`, `cabi_multi_f64_v2f32`
    and `cabi_multi_f32pair_f64`.
    Aggregates with two or more smaller-INTEGER members packed into one
    eightbyte followed by a single `f32` or `f64` (only the scalar in the
    next eightbyte) now also lower as `( i64, float )` or `( i64, double )`
    parameter pairs with `{ i64, float }` / `{ i64, double }` returns —
    reusing the existing `.sse_i64_f32x` / `.sse_i64_f64x` lowering with the
    multi-member acceptance checks; covered by `cabi_packed_i64_f64` and
    `cabi_packed_i64_xs_i16_f64`.
    Singleton `i8`/`i16`/`i32`/`i64` aggregates are additionally passed at
    their exact member-width scalar width at the boundary (1→`i8`, 2→`i16`,
    ≤4→`i32`, otherwise `i64`), replacing the previous always-`i64` choice;
    covered by `cabi_small_singleton` and `cabi_small_singleton_u8` in both
    directions.
    Exactly two direct small integer members (`i8`/`u8` or `i16`/`u16`) at
    natural offsets 0/8 (16 bytes) are accepted, signedness irrelevant:
    `{ i8/u8, f64 }` uses `i8, double` and `{ i8, double }`;
    `{ i16/u16, f64 }` uses `i16, double` and `{ i16, double }`; the
    reverse `{ f64, i8/u8 }` / `{ f64, i16/u16 }` uses `double, i8` /
    `double, i16` and `{ double, i8 }` / `{ double, i16 }`. Sub-32-bit
    integer members (`i8`, `u8`, `i16`, `u16`) and `bool` are also accepted
    inside `INTEGER`-merged eightbytes (packed `i64` irrespective of member
    widths); a singleton `bool` member at offsets 0 or 8 now passes as a full
    `i8` parameter, matching Clang IR's `(i8, double)` / `(double, i8)`
    parameter signatures exactly; covered by `cabi_small_bool_f64` and
    `cabi_small_f64_bool`. A singleton `enum` member with a sub-32-bit
    backing remains rejected (`E0473`). Clang IR
    probes confirm all signatures; covered by `cabi_small_i8_f64`,
    `cabi_small_f64_i16` and `cabi_small_i8_merged`.
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
   `64`-bit `usize`). The INTEGER and SSE classes now follow Clang's
   leaf-flattening rule, so nested members are covered as well (§32, §33,
   §34); the remaining gaps are the register pairs Clang supports that Kyn
   still rejects (for example `(float, float)` for a 16-byte aggregate with
   one `f32` per eightbyte, or a pointer member, which has no integer
   transport type).
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
  `double, float` and `{ double, float }`. A direct `{ f32, i64 }` at offsets
  0/8 maps to `float, i64` and `{ float, i64 }`; the reverse `{ i64, f32 }`
  maps to `i64, float` and `{ i64, float }`; `{ f64, i64 }` maps to
  `double, i64` and `{ double, i64 }`; and `{ i64, f64 }` maps to
  `i64, double` and `{ i64, double }` (signedness irrelevant throughout).
  `classifyMixedRunAggregate(fields, eightbytes)` handles exact three/four-member
  layouts whose eightbytes split into an SSE-only slot and an INTEGER/merged
  slot, with the probed Clang signatures (`{ f32, f32, i32 }`,
  `{ f32, f32, i64 }`, merged-INTEGER-plus-single-f32/f64 runs,
  `{ i64/u64, f32, f32 }`, all-SSE `{ f32, f32, f64 }` / `{ f64, f32, f32 }`,
  the four-member runs, and the no-member-packed-integer-EB0 layouts where
  EB0 comprises only smaller-INTEGER members and EB1 holds a single SSE
  f32/f64 (scalarizing the EB1 register with the packed EB0 as one `i64`))); sub-32-bit integer members (`i8`, `u8`, `i16`,
  `u16`) and `bool` are admitted inside `INTEGER`-merged eightbytes (packed
  `i64` irrespective of member widths). A direct singleton small integer
  member (`i8`/`u8`/`i16`/`u16`) in an INTEGER-only eightbyte passes at its
  member width; a singleton `bool` member passes as a full `i8` parameter.
  A singleton `enum` member with a sub-32-bit backing remains rejected
  (`E0473`). Any other member or layout falls through to the existing paths
  or is rejected with `E0473`.
  Other unsupported
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

## 23. Mixed-width f32/f64 aggregate ABI increment (completed and merged)

- Scope: only aggregates with exactly two direct fields of mixed float
  widths at natural offsets 0/8 with 16-byte layout: `{ f32, f64 }` and
  `{ f64, f32 }`. No other behavior changed: internal Kyn aggregate calls,
  the module system, and the runtime-check policy are untouched, and all
  previously supported shapes are bit-identical (the new exact-shape checks
  return before the shared SSE-only scan).
- Merged into `main` as PR #5 (merge commit `511350d`); implementation
  commit `ed9f9a9`. CI run for the PR (`42733863688`, 3m27s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `141 passed, 0 failed`. Release artifacts and tags are untouched.
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

## 24. Mixed-width float/64-bit-integer aggregate ABI increment (completed and merged)

- Merged into `main` as PR #6 (merge commit `224e8f3`); implementation
  commit `19a5908`. CI run for the PR (`42736702408`, 3m13s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `145 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: only aggregates with exactly two direct fields of one float
  (`f32`/`f64`) and one 64-bit integer (`i64`/`u64`) at natural offsets 0/8
  with 16-byte layout, signedness irrelevant: `{ f32, i64 }` / `{ f32, u64 }`,
  `{ i64, f32 }` / `{ u64, f32 }`, `{ f64, i64 }` / `{ f64, u64 }` and
  `{ i64, f64 }` / `{ u64, f64 }`. No other behavior changed: internal Kyn
  aggregate calls, the module system, and the runtime-check policy are
  untouched, and all previously supported shapes keep their exact lowering
  (the new exact-shape checks return before the shared SSE-only eightbyte
  scan). The 12-byte `{ f64, i32 }` layout does not exist (alignment pads to
  16) and is already supported as `sse_f64_i32`; `{ f32, i32 }` / `{ i32, f32 }`
  are 8-byte merged-`INTEGER` eightbytes handled by `small_1`.
- Clang 23 IR probes confirm all eight signatures:
  - `{ f32, i64 }` / `{ f32, u64 }`: parameters `(float, i64)`, return `{ float, i64 }`;
  - `{ i64, f32 }` / `{ u64, f32 }`: parameters `(i64, float)`, return `{ i64, float }`;
  - `{ f64, i64 }` / `{ f64, u64 }`: parameters `(double, i64)`, return `{ double, i64 }`;
  - `{ i64, f64 }` / `{ u64, f64 }`: parameters `(i64, double)`, return `{ i64, double }`.
- Implementation: transport types `.abi_f32_i64`, `.abi_i64_f32`,
  `.abi_f64_i64` and `.abi_i64_f64` added to `compiler/types.zig` and
  `compiler/backend/llvm.zig`; new `BoundaryClass` variants `sse_f32_i64`,
  `sse_i64_f32`, `sse_f64_i64` and `sse_i64_f64` in both sema and backend.
  The size-16 exact-shape block runs the four new checks after the existing
  `f64`/`i32`/`f32`/`f64` checks. Parameters, definition-side unpacking and
  call-side argument lowering reuse the shared per-field flatten arm (field
  order equals parameter order); returns use the new transport types with
  `align 8` loads/stores, matching Clang.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass (74 tests; the `WideInt`/`{ f64, i64 }` unit fixture that previously
  asserted `E0473` now asserts clean acceptance with `u64` mirrors, with
  nested/mixed rejection coverage unchanged); `zig fmt --check` is clean;
  integration suite passes in all four profiles with the new
  `cabi_mixed_f32_i64` (exit 45), `cabi_mixed_i64_f32` (exit 39),
  `cabi_mixed_f64_i64` (exit 49) and `cabi_mixed_i64_f64` (exit 55) C↔Kyn
  fixtures, covering argument and return paths in both directions. Emitted
  Kyn IR signatures match the Clang probe exactly. Total integration count:
  145 passed, 0 failed.
- Two `.exit` status files were corrected during the increment after the
  compiler and C side were verified consistent (arithmetic slip in the
  expected byte values, not in implementation or fixtures). No sanitizer run
  was performed; no sanitizer gate is configured. Interop used the installed
  `clang` (v23.1.2).
- Git state: merged into `main` (see the merge record at the top of this
  section). Release artifacts and tags are untouched.

## 25. Multi-member ABI increment (completed and merged)

- Merged into `main` as PR #7 (merge commit `edda8b9`); implementation
  commit `9530e63`. CI run for the PR (`42742224537`, 3m35s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `151 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: exact three- and four-member aggregates (12 or 16 bytes) whose
  eightbytes split strictly into an SSE-only slot and an INTEGER/pure-or-
  merged slot. Verified against Clang 23 IR probes (parameters and returns
  for every shape, including u32/u64 variants): `{ f32, f32, i32/u32 }`
  (`<2 x float>, i32`, ret `{ <2 x float>, i32 }`), `{ f32, f32, i64/u64 }`
  (`<2 x float>, i64`, ret `{ <2 x float>, i64 }`), `{ i32/u32, f32, f32 }`
  and `{ f32, i32/u32, f32 }` (merged INTEGER as `i64` then `float`, ret
  `{ i64, float }`), `{ i32/u32, f32, f64 }` and `{ f32, i32/u32, f64 }`
  (merged INTEGER as `i64` then `double`, ret `{ i64, double }`),
  `{ f64, i32/u32, i32/u32 }` and `{ f64, i32/u32, f32 }` (`double` then
  merged INTEGER, ret `{ double, i64 }`), `{ i64/u64, f32, f32 }`
  (`i64, <2 x float>`, ret `{ i64, <2 x float> }`),
  all-SSE triples `{ f32, f32, f64 }` (`<2 x float>, double`;
  ret `{ <2 x float>, double }`) and `{ f64, f32, f32 }` (`double, <2 x float>`;
  ret `{ double, <2 x float> }`), and four-member
  `{ f32, f32, i32/u32, f32 }` (`<2 x float>, i64`; ret `{ <2 x float>, i64 }`),
  `{ i32/u32, f32, f32, f32 }` and `{ f32, i32/u32, f32, f32 }`
  (`i64, <2 x float>`; ret `{ i64, <2 x float> }`).
- Implementation: new transport types `.abi_v2f32_i32`, `.abi_v2f32_i64`,
  `.abi_i64_v2f32`, `.abi_f64_v2f32` and `.abi_v2f32_f64`; new
  `BoundaryClass` variants `sse_f32x2_i32`, `sse_f32x2_i64`, `sse_i64_f32x`,
  `sse_i64_f64x`, `sse_f64_i64x`, `sse_i64_v2f32`, `sse_f64_v2f32` and
  `sse_v2f32_f64` in both sema and backend. `classifyMixedRunAggregate`
  walks the member multiset (f32/f64/i32/i64 and `char`, 32/64-bit enum
  backings count as int-like), rejects everything else, and is only reached
  for aggregates ≤16 bytes after the existing exact-shape checks; it returns
  to the existing all-SSE / INTEGER-only paths when it matches nothing.
  Parameters/definitions/calls reuse the shared per-field flatten arms,
  augmented by two-slot load/store arms built on `byte_offset`; returns
  coerce through the new transports with `align 8` loads/stores, matching
  Clang's emitted IR.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass (74 tests; new multi-member acceptance test and mirror blocks; the
  `FloatIntFloat { f32, i32, f32 }` unit fixture was accepted, and the
  `{ f32, f32, i32, f32 }` four-member accepted across two iterations of
  merged-eightbyte condition fixes); `zig fmt --check` clean; integration
  passes in all four profiles with six new C↔Kyn fixtures
  (`cabi_multi_f32x2_i32` 50, `cabi_multi_f32x2_i64` 92,
  `cabi_multi_i32_f32pair` 54, `cabi_multi_i64_f32pair` 52,
  `cabi_multi_f64_v2f32` 64, `cabi_multi_f32pair_f64` 56). Emitted Kyn IR
  signatures match the Clang probe for every multi-member shape, including
  the order-sensitive all-SSE triples. Total integration count: 151 passed,
  0 failed.
- Two classification bugs were caught and fixed during the increment: a
  merged eightbyte carrying an `f32` was incorrectly required to have
  `has_sse == false` (it must be merged INTEGER and accepted), and the
  all-SSE `{ f32, f32, f64 }` vs `{ f64, f32, f32 }` discrimination needed
  field-order checks rather than member counts. No sanitizer run was
  performed; no sanitizer gate is configured. Interop used the installed
  `clang` (v23.1.2).
- Git state: merged into `main` (see the merge record at the top of this
  section). Release artifacts and tags are untouched.

## 27. Boolean store zero-extension increment (completed and merged)

- Merged into `main` as PR #9 (merge commit `f869fb1`); implementation
  commit `2e36a02`. CI run for the PR (`42749585854`, 2m8s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `155 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: fix the byte-level `bool` memory representation at every `store` in
  the backend. Previously a `bool` field/local was stored into memory as
  `i1`, leaving the upper seven bits of its byte undefined; passed across an
  `extern`/`export` C ABI boundary as part of a packed `i64` (current lowering
  for merged-INTEGER eightbytes) those garbage bits made the byte
  indistinguishable from a full `i8` to the C side, which reads `_Bool` as a
  full byte. The bug was latent: no existing fixture read the high bits of a
  merged-INTEGER bool byte, so the integration suite still passed before the
  fix — the defect only surfaced under direct IR inspection of the emitted
  bool stores.
- Implementation: `Lowering` now owns `emitValueStore(args)` which, for
  `ty.* == .bool`, emits `zext i1 %v to i8` + `store i8` with the same
  pointer; otherwise it emits the unchanged `.store` instruction. All
  32 store emission sites in the backend were routed through this helper.
  Alloca choice is unchanged (`alloca i1`); loads of i1 from the now-defined
  byte are bit-compatible.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass; `zig fmt --check` clean; integration suite passes in all four
  profiles with the new `cabi_multi_merge_bool` fixture (exit 53), for a
  total of 155. Every bool store in generated IR now shows `zext i1 -> i8`
  + `store i8`, matching Clang's full-byte `_Bool` representation. Docs
  (changelog Unreleased and this continuity section) updated.
- Regression coverage: `cabi_multi_merge_bool` exercises a `bool` member
  inside a merged-INTEGER eightbyte crossing the boundary in both directions.
- Git state: merged into `main` (see the merge record at the top of this
  section). Release artifacts and tags are untouched.

## 26. Small integer member ABI increment (completed and merged)

- Merged into `main` as PR #8 (merge commit `b0a149f`); implementation
  commit `6b56ad3`. CI run for the PR (`42746184920`, 2m3s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `154 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: exactly two direct small integer members (`i8`/`u8` or `i16`/`u16`)
  at natural offsets 0/8 (16 bytes), signedness irrelevant: `{ i8/u8, f64 }`
  uses `i8, double` parameters and a `{ i8, double }` return; `{ i16/u16, f64 }`
  uses `i16, double` and `{ i16, double }`; the reverse `{ f64, i8/u8 }` /
  `{ f64, i16/u16 }` uses `double, i8` / `double, i16` and the matching
  `{ double, i8 }` / `{ double, i16 }` returns. Additionally, sub-32-bit
  integer members (`i8`, `u8`, `i16`, `u16`) and `bool` are admitted inside
  `INTEGER`-merged eightbytes in the existing multi-member layouts (packed
  `i64` irrespective of member widths, matching Clang). A singleton `bool`
  member remains rejected with `E0473` (Clang passes it as `i8` zeroext;
  Kyn's bool is `i1`, which would need a dedicated zeroext emission).
- Clang 23 IR probes confirm all signatures: singleton `{ i8, double }` ->
  `(i8, double)` and `{ i8, double }` return; `{ short, double }` ->
  `(i16, double)` and `{ i16, double }`; the reverse orders likewise. Merged
  eightbytes carrying `i8`/`u8`/`i16`/`u16`/`bool` members probe as `i64`
  (e.g. `{ _Bool, float, float }` -> `(i64, float)`).
- Implementation: new transport types `.abi_i8_f64`, `.abi_i16_f64`,
  `.abi_f64_i8` and `.abi_f64_i16`; new `BoundaryClass` variants `sse_i8_f64`,
  `sse_i16_f64`, `sse_f64_i8` and `sse_f64_i16` in both sema and backend.
  The size-16 exact-shape block runs the four new checks after the existing
  `{ f64, i32/u32 }` checks. Parameters, definition-side unpacking and
  call-side argument lowering reuse the shared per-field arms (field order
  equals parameter order, signedness irrelevant); returns use the new
  transport types with `align 8` loads/stores, matching Clang. In
  `classifyMixedRunAggregate`, members with 8/16 bits are now counted with
  the 32-bit `i32` bucket (and `bool` counted alike), which admits them into
  the merged-INTEGER accepted layouts; a singleton `bool` member passes as
  an `i8` at the boundary (parameter, argument, unpack and return layout),
  matching Clang's IR. Any other unsupported member shape
  still falls through to the existing paths or `E0473`.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass (74 tests; new `C ABI small integer members accept exact layouts`
  acceptance test; the negative `E0473` fixtures moved from a now-supported
  `{ i16, f64 }` to a singleton-`bool` `SmallBoolDouble` to preserve
  coverage); `zig fmt --check` clean; integration suite passes in all four
  profiles with the new `cabi_small_i8_f64` (exit 31), `cabi_small_f64_i16`
  (exit 39) and `cabi_small_i8_merged` (exit 56) C<->Kyn fixtures, covering
  argument and return paths in both directions. Emitted Kyn IR signatures
  match the Clang probes exactly (`{ i8, double }`, `{ i16, double }`,
  `{ double, i8 }`, `{ double, i16 }`). Total integration count:
  154 passed, 0 failed.
- No sanitizer run was performed; no sanitizer gate is configured. The
  interop tests used the installed `clang` (v23.1.2).

## 29. Singleton enum aggregate ABI increment (completed and merged)

- Merged into `main` as PR #11 (merge commit `9f0affa`); implementation
  commit `f5349a9`. CI run for the PR (`42754654970`, 1m43s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `160 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: singleton `enum` members at natural offsets 0 or 8 (16 bytes),
  signedness irrelevant, passing at their backing integer width. The eight
  two-field exact layouts are now `{ enum:i8/I8/u8, f64 }` family and its
  reverse. Clang IR probes confirm all signatures. Singleton enum members
  with sub-32-bit backings are now accepted; the backings in scope are
  i8/u8 (1 byte), i16/u16 (2 bytes), i32/u32 (4 bytes) and i64/u64 (8 bytes).
  An enum member whose backing is a bool-sized 1 bit remains rejected
  (`E0473`).
- Implementation: `isIntLikeWithWidth(ty, bits)` generalizes the exact-shape
  `int` checks to also match `char` (32 bits), `.bool` mapped to 8 bits, and
  `enum` members by backing width — `enum` members with 32/64-bit backings
  share the previously-supported `{ i32, f64 }` / `{ f64, i32 }` /
  `{ i64, f64 }` / `{ f64, i64 }` coercions. In `classifyMixedRunAggregate`,
  `.enum_type` members with 8/16/32-bit backings are counted as `i32_count`
  and 64-bit backings as `i64_count`, so four-member mixed runs with enum
  members now accepted (e.g. `{ enum:u8, f32, f32 }` as merged-INTEGER then
  SSE-float). Everywhere previously gated on `.int` with a specific bit width
  now admits an `enum` member of that backing width, and the small-member
  two-field checks were generalized the same way.
- Validation: `zig build test` passes (75 tests; new acceptance test
  `C ABI enum members accept exact layouts` covers param/return positions
  for all four widths and the mixed-run acceptances); `zig fmt --check` is
  clean; integration suite passes in all four profiles with the new
  `cabi_enum_e8_f64` (exit 50), `cabi_enum_e64_f64` (exit 56) and
  `cabi_enum_e8_f32f32` (exit 67) C<->Kyn fixtures. Emitted Kyn IR signatures
  match the Clang probes exactly (`{ i8, double }` … `{ i64, double }`).
  Total integration count: 160 passed, 0 failed.
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, and `CHANGELOG.md` (`[Unreleased]`) updated; this continuity
  record is the source of truth for the post-increment stage.
- Negative fixtures preserving `E0473` acceptance moved from
  singleton-`enum:u8` to singleton-`[2]i8` arrays in `abi_float_param.kyn`,
  `abi_float_return.kyn` and the two unit tests to keep the negative
  coverage true to intent.

## 28. Singleton bool aggregate ABI increment (completed and merged)

- Merged into `main` as PR #10 (merge commit `2ba5000`); implementation
  commit `6c58e84`. CI run for the PR (`42752155719`, 2m35s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `157 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: singleton `bool`-member layouts at natural offsets 0 or 8 (16 bytes),
  signedness irrelevant: `{ bool, f64 }` lowers as `i8, double` parameters
  and a `{ i8, double }` return; the reverse `{ f64, bool }` lowers as
  `double, i8` and a `{ double, i8 }` return. Clang 23 IR probes confirm both
  signatures at the LLVM boundary. A singleton `enum` member with a sub-32-bit
  backing remains rejected (`E0473`).
- Implementation: singleton `bool` members at indices 0/1 in a two-field
  16-byte layout are now accepted by `aggregateBoundaryClass` via two new
  two-field checks fourth in the size-16 block (after the existing
  `{ f64, i32/u32 }` checks and the small-integer checks). Parameters,
  definition-side unpacking and call-side argument lowering reuse the shared
  per-field arms; `Lowering.boundaryMemberType` substitutes an unsigned `i8`
  for any `.bool` member at the boundary (no zeroext attribute is emitted,
  matching Clang's IR; the full byte is always defined because every bool
  store emits `zext i1 -> i8`). Internal Kyn by-value calls are unchanged.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass (75 tests; new unit acceptance blocks; negative `E0473` fixtures moved
  to singleton-`enum:u8` layouts in `abi_float_param.kyn`,
  `abi_float_return.kyn` and the unit tests to preserve coverage);
  `zig fmt --check` clean; integration suite passes in all four profiles with
  the new `cabi_small_bool_f64` (exit 50) and `cabi_small_f64_bool` (exit 56)
  C<->Kyn fixtures covering both directions. Emitted Kyn IR signatures match
  the Clang probes exactly. Total integration count: 157 passed, 0 failed.
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, `CHANGELOG.md` (`[Unreleased]`) updated; singleton `bool`
  acceptance removed from the rejected list across specification and reference
  docs.
- No sanitizer run was performed; no sanitizer gate is configured. The interop
  tests used the installed `clang` (v23.1.2).

## 30. Multi-member packed INTEGER eightbyte ABI increment (completed and merged)

- Merged into `main` as PR #12 (merge commit `027315b`); implementation
  commit `a6a6fda`. CI run for the PR (`42758453505`, 2m11s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `162 passed, 0 failed`. Release artifacts and tags are untouched.
- Scope: aggregates with two or more smaller-INTEGER members packed into
  one eightbyte (size ≤ 8) followed by a single `f32` or `f64` scalar in
  the next eightbyte, where the scalar occupies that eightbyte alone (no
  INTEGER member in the SSE slot). Clang passes the packed EB0 as one
  `i64` register and the EB1 as its scalar SSE register. The accepted
  signatures are:
  - `( i64, float )` / `{ i64, float }` returns
  - `( i64, double )` / `{ i64, double }` returns

  Clang IR probes confirm all cases (`{ i32, i32, f64 }`, `{ i16, i16, f64 }`,
  `{ i8, i8, f64 }`, `{ i32, i32, f32 }`, `{ i16, i16, i16, i16, f64 }`,
  `{ i16, i16, i16, i16, f32 }`, `{ i16, i16, f64 }`, and the multi-member
  reverse). Kyn now passes `{ i32, i32, f64 }` as `( i64, double )`, matching
  Clang's EB0/EB1 assignment exactly.
- Implementation: `classifyMixedRunAggregate` gains two new exact-shape
  acceptance checks at the top (before the member-count loop), gated on
  `eb0_int && !eb0_sse && eb1_sse && !eb1_int && fields.len >= 3`. The
  lowering reuses the already-verified `.sse_i64_f32x` / `.sse_i64_f64x`
  boundary classes (typeString `{ i64, float }` / `{ i64, double }`,
  two-slot arms, definition-side unpack, call-site arg lowering, return
  coercions), so no new `BoundaryClass` variants, transport types, or
  backend arms are introduced. This makes the entire increment local to
  sema.zig.
- The previously-rejected `{ i32, i32, f64 }`, `{ i8, i8, f64 }` and
  `{ i16, i16, i16, i16, f64 }` layouts now pass.
  Negative `E0473` fixtures (nested wrappers, arrays) unchanged.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass; `zig fmt --check` clean; integration suite passes in all four
  profiles with the new `cabi_packed_i64_f64` (exit 55) and
  `cabi_packed_i64_xs_i16_f64` (exit 63) C↔Kyn fixtures.
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, `CHANGELOG.md` (`[Unreleased]`) and this continuity record
  updated.
- No sanitizer run was performed; no sanitizer gate is configured. The
  interop tests used the installed `clang` (v23.1.2).
- Git state: implementation is merged into `main`. Release artifacts and
  tags are untouched.

## 31. Small-1 singleton integer ABI increment (completed and merged)

- Merged into `main` as PR #13 (merge commit `9bb08c4`); implementation
  commit `ad6c6f3`. CI run for the PR (`42761244208`, 1m59s) was green.
  Post-merge gates on `main` pass: `zig fmt --check`, Debug/ReleaseSafe
  builds and unit tests, and the Debug/ReleaseSafe integration matrix —
  all report `164 passed, 0 failed`. Release artifacts and tags are untouched.

- Scope: singleton INTEGER-only aggregates (`.small_1` eightbyte classification,
  size ≤ 8) now pass at the **member's own natural width** (LLVM `i8` for a
  size-1 struct, `i16` for a size-2 struct, `i32` for size ≤ 4, otherwise
  `i64`), instead of always passing as one packed `i64`. Clang's INTEGER-class
  ABI always uses the smallest register covering each eightbyte; Kyn now
  matches exactly (probed):
  - `{ i8 }` → `i8` (`@f1(i8) -> i8`)
  - `{ i16 }` → `i16` (`@f2(i16) -> i16`)
  - `{ i32 }` → `i32` (`@f3(i32) -> i32`)
  - `{ i64 }` → `i64` (`@f4(i64) -> i64`)
  - `{ i8, i8 }` → `i16`, `{ i16, i16 }` → `i32`
  - multi-member singles that fit one eightbyte keep the old `i64` lowering
    exactly as before (merged INTEGER eightbyte, matches Clang)
- Implementation: new `pub fn smallRegisterBits(size)` in `compiler/sema.zig`
  returns 8/16/32/64 bits for size ≤ 1/2/4; `8 byte+ returns 64`. The backend
  uses it everywhere `i64_ty` was hard-coded for `.small_1`:
  - `createFunction`: parameter now allocated at the exact width
  - `.ret_ty` switch (return of §3-member): same switch at the new width
  - `.ret_ty` switch (return of §4-member / call site): same switch at the new width
  - `lowerPackedAggregate` now takes `source_ty` explicitly (before always `i64`);
    the two-field `lowerCall` arm now compares register load width based on
    `aggregateSize` instead of always `i64`
  - the `.small_1` arm of `lowerCall` now packs the partial eightbyte at
    `bits / 8` as its size, and loads at the same width
  - return path storage type matches the size for `.small_1`
  - `lowerPackedAggregate` is no longer called with i64-only assumptions
- The previously preserved but wrong signature (`call i32 @take_small(i64 `)
  moves to `(i32 )` — one test updated to match the new correct signature.
- Validation: `zig build test` and `zig build test -Doptimize=ReleaseSafe`
  pass (77 tests total, one previously-flagging test updated because its
  assertion hard-coded the old i64 signature);
  `zig fmt --check` clean; integration suite passes in all four profiles with
  the new `cabi_small_singleton` (exit 38) and `cabi_small_singleton_u8`
  (exit 42) C↔Kyn fixtures.
- No new `BoundaryClass` variants or transport types; existing tests extended
  with acceptance blocks for the seven new singles (`i8`/`i16`/`i32`/`u8`/`u16`
  sizes 1..8) and for the previously-failing IR signature case.
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, `CHANGELOG.md` (`[Unreleased]`) and this record updated.
- No sanitizer run was performed; no sanitizer gate is configured. Interop
  used the installed `clang` (v23.1.2).

## 32. Two-member integer-pair aggregate ABI increment (completed and merged)

- Scope: two-member structs whose members occupy one eightbyte each and are
  both integer scalars now lower as `.small_2s`: each member passes in its own
  register at its own width and the aggregate returns as the matching pair.
  Clang's System V lowering was probed for every reachable shape before
  implementing (Clang 23.1.2 IR):
  - `{ i8, i64 }` → `(i8, i64)` params, `{ i8, i64 }` return
  - `{ i64, i8 }` → `(i64, i8)` params, `{ i64, i8 }` return
  - `{ i16, i64 }` → `(i16, i64)` params, `{ i16, i64 }` return
  - `{ i64, i16 }` → `(i64, i16)` params, `{ i64, i16 }` return
  - `{ i32, i64 }` → `(i32, i64)` params, `{ i32, i64 }` return
  - `{ i64, i32 }` → `(i64, i32)` params, `{ i64, i32 }` return
  - `{ i64, i64 }` stays on `.small_2` (`i128`), unchanged
  - two members inside one eightbyte (e.g. `{ char, char, long }`) stay on
    `.small_2` (merged INTEGER eightbyte), unchanged
  - nested-struct members (e.g. `{ struct { short x; } a; long b; }`) stay on
    `.small_2`, because Clang flattens the nested struct into its leaves and
    the current `.small_2` lowering is already ABI-compatible there (the
    register pair carries the same bytes); matching Clang's flattened
    `(i16, i64)` exactly is not attempted in this increment
- Implementation:
  - `compiler/sema.zig`: new `pub fn memberBoundaryBits(ty)` returns the
    INTEGER-class boundary width of an integer member (`int` → its own bits,
    `bool` → 8, `char` → 32, `enum` → its backing width); `isIntLikeWithWidth`
    now delegates to it, removing the duplicated width table. New private
    `smallPairWidths(ty)` recognises the eligible two-member shapes (both
    members integer-like, each fitting one eightbyte, the second starting at
    offset ≥ 8) and returns the two widths; `aggregateBoundaryClass` maps
    those shapes to `.small_2s` when exactly one of the widths is narrower
    than 64 bits.
  - `compiler/types.zig`: six new transport variants `abi_pair_i8_i64`,
    `abi_pair_i16_i64`, `abi_pair_i32_i64`, `abi_pair_i64_i8`,
    `abi_pair_i64_i16` and `abi_pair_i64_i32`, with `eql` and `displayName`
    entries (`<internal ABI pair>` in the semantic analyzer).
  - `compiler/backend/llvm.zig`: new `BoundaryClass.small_2s`; the backend's
    duplicated member-width table was replaced by the sema helper
    (`boundaryMemberBits` now delegates to `sema_mod.memberBoundaryBits`), so
    classification and lowering cannot drift apart. `pairTransportType` now
    takes the two widths and selects the transport type. The class is handled
    in every switch that needed it: parameter allocation (`createFunction`),
    return type (`.ret_ty`), boundary-class passthrough, parameter
    unpacking in a callee (`lowerFunction`), the `return` statement
    (`lowerStmt`), argument passing and result handling in a call
    (`lowerCall`), plus the emitter's type string and alignment tables.
- Validation: `zig build`, `zig build -Doptimize=ReleaseSafe`, `zig build test`
  and `zig fmt --check build.zig compiler build-system` pass; the integration
  suite passes in all four profiles (`debug`, `safe`, `release`, `fast`) with
  `165 passed, 0 failed`, including the new `cabi_small_pair_widths` fixture
  (exit 5) that exercises all six layouts in both directions. A separate
  ad-hoc C↔Kyn check also confirmed `bool` and `enum` members behave as Clang
  does (`(i8, i64)` and `(i64, i8)`).
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, `CHANGELOG.md` (`[Unreleased]`) and this record updated.
- No sanitizer run was performed; no sanitizer gate is configured. Interop
  used the installed `clang` (v23.1.2).
- Merged into `main` as PR #14 (merge commit `1a76dbb`); implementation
  commit `39b01f9` and documentation commit `fcdc4bf`. CI run for the PR
  (`42775672895`, 2m4s) was green. Post-merge gates on `main` pass:
  `zig fmt --check`, Debug/ReleaseSafe builds and unit tests, and the
  Debug/Safe/Release/Fast integration matrix — all report
  `165 passed, 0 failed`. Release artifacts and tags are untouched.
- Next task: the remaining INTEGER-class gap is Clang's leaf-flattening of
  nested-struct members (e.g. `{ struct { short x; } a; long b; }` →
  `(i16, i64)`), which today stays on the ABI-compatible `.small_2`
  lowering; matching Clang's flattened form exactly requires leaf
  extraction across nested aggregates at the boundary.

## 33. Nested integer-leaf flattening ABI increment (completed and merged)

- Scope: the `.small_2s` boundary class now follows Clang's leaf-flattening
  rule. Clang decides the register width of an eightbyte from the *leaves* it
  carries, flattening nested structs into their scalar members, so a nested
  integer member is passed at its own width instead of the packed form. The
  rule was probed with Clang 23.1.2 before implementing:
  - `{ struct { short x; } a; long b; }` → `(i16, i64)`, `{ i16, i64 }`
  - `{ struct { int x; } a; long b; }` → `(i32, i64)`, `{ i32, i64 }`
  - `{ long a; struct { short x; } b; }` → `(i64, i16)`, `{ i64, i16 }`
  - `{ struct { struct { short x; } i; } a; long b; }` → `(i16, i64)`
  - `{ struct { char p; char q; } a; long b; }` → `(i64, i64)` (two leaves
    merge the eightbyte, so the packed `.small_2` form is kept)
  - `{ char c; struct { short x; } a; long b; }` → `(i64, i64)` (same merge)
  - `{ struct { short x; } a; struct { short y; } b; }` → `(i32)` (4 bytes,
    whole-aggregate rule)
- Implementation:
  - `compiler/sema.zig`: new `pub const EightbyteLeaf` and the leaf walker
    `collectAggregateLeaves`, which counts the scalar leaves per eightbyte
    (nested structs are walked through) and records the width and byte offset
    of a lone integer leaf. `pub fn smallPairLeaves` returns the two leaves
    when each eightbyte carries exactly one integer scalar leaf and exactly
    one of them is narrower than 64 bits; `aggregateBoundaryClass` maps that
    shape to `.small_2s`. Floating-point and pointer leaves are never
    narrowable, so they keep the existing SSE/INTEGER behaviour.
  - `compiler/backend/llvm.zig`: the four `.small_2s` sites now read the
    widths and offsets from `sema.smallPairLeaves` instead of re-deriving
    them from the direct members, so the classification and the lowering
    cannot drift apart. The callee stores each incoming register into the
    byte slot that holds its leaf and the caller loads each leaf from that
    slot, which works for direct and nested leaves alike. The backend's
    duplicated member-width helper was removed and the vestigial element
    type parameter of `byteOffset` was dropped.
- Validation: `zig build`, `zig build -Doptimize=ReleaseSafe`, `zig build test`
  and `zig fmt --check build.zig compiler build-system` pass; the integration
  suite passes in all four profiles (`debug`, `safe`, `release`, `fast`) with
  `166 passed, 0 failed`, including the new `cabi_nested_pair_widths` fixture
  (exit 96) that exercises the nested layouts in both directions. The
  generated IR for the nested shapes was compared against the Clang probes and
  matches, and an ad-hoc C↔Kyn program confirmed both directions still
  interoperate.
- Compatibility: the previous packed `.small_2` lowering of the nested shapes
  was already ABI-compatible (the register pair carries the same bytes), so
  this increment changes the IR shape, not the machine-level contract.
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, `CHANGELOG.md` (`[Unreleased]`) and this record updated.
- No sanitizer run was performed; no sanitizer gate is configured. Interop
  used the installed `clang` (v23.1.2).
- Merged into `main` as PR #15 (merge commit `48b2189`); implementation
  commit `441dea8` and documentation commit `36f2a16`. CI run for the PR
  (`42780610552`, 2m6s) was green. Post-merge gates on `main` pass:
  `zig fmt --check`, Debug/ReleaseSafe builds and unit tests, and the
  Debug/Safe/Release/Fast integration matrix — all report
  `166 passed, 0 failed`. Release artifacts and tags are untouched.
- Next task: the SSE-side leaf flattening of nested members
  (e.g. `{ struct { float f; } a; long b; }` → `(float, i64)`) is the
  remaining leaf-flattening gap; it needs its own boundary classes because
  the current SSE classes only recognise direct members, and until then the
  nested SSE shapes stay rejected with `E0473`.

## 34. Leaf-based C ABI boundary classification increment (completed and merged)

- Scope: the register of an eightbyte is now decided by the *leaves* it
  carries, with nested structs flattened into their members exactly as Clang
  does. Previously the classification matched the aggregate's direct members,
  so a nested member was rejected with `E0473` even when Clang supports the
  layout. The rule was probed with Clang 23.1.2 before implementing, over 31
  shapes:
  - nested integer: `{ struct { short x; } a; long b; }` → `(i16, i64)`,
    `{ struct { int x; } a; long b; }` → `(i32, i64)`,
    `{ long a; struct { short x; } b; }` → `(i64, i16)`
  - nested float: `{ struct { float f; } a; long b; }` → `(float, i64)`,
    `{ struct { float f; } a; }` → `(float)`
  - nested double pair: `{ struct { double x; double y; } pair; }` →
    `(double, double)`
  - a nested member with several leaves merges its eightbyte and keeps the
    packed form, exactly as Clang does
- Implementation:
  - `compiler/sema.zig`: the leaf model grew into the single source of truth
    for the boundary. `EightbyteLeaf` now counts the leaves of an eightbyte
    and records the lone leaf (kind, width, byte offset); `EightbyteRegister`
    names the register an eightbyte travels in (an integer width, `f32`,
    `f64` or `<2 x float>`). `collectAggregateLeaves` walks nested structs and
    `classifyRegisterPair` maps a register pair to the boundary class. The
    previous member-shape rules and the separate multi-member classifier were
    removed: the register-pair table subsumes them, which removed roughly 400
    lines of classification rules.
  - `compiler/backend/llvm.zig`: the argument registers and the return
    transport now come from the boundary class (`sseBoundaryParams` and
    `sseReturnTransport`) instead of the aggregate's direct members, so a
    nested member is loaded from and stored into the byte slot that holds
    it. Every two-register class uses the same slot layout (bytes 0-7 then
    bytes 8-15), which also replaced the field-index lowering. Three classes
    that shared a transport with another class (`.sse_i64_f32x`,
    `.sse_i64_f64x` and `.sse_f64_i64x`) were removed, and the dead
    `boundaryMemberType` helper went with them.
- Validation: `zig build`, `zig build -Doptimize=ReleaseSafe`, `zig build test`
  and `zig fmt --check build.zig compiler build-system` pass; the integration
  suite passes in all four profiles (`debug`, `safe`, `release`, `fast`) with
  `165 passed, 0 failed`. The generated signatures of 31 probed shapes were
  compared against Clang and match, and the new `cabi_nested_sse_widths`
  fixture (exit 57) exercises the nested layouts in both directions.
- Test changes: the negative fixtures `abi_sse_integer_param` and
  `abi_sseup_pair` asserted a limitation that no longer exists, so they
  became the positive fixture `cabi_nested_sse_widths`; the matching unit
  expectations moved from `E0473` to accepted layouts. No other test changed.
- Docs: `abi.md`, `type-system.md`, `language-reference.md`, `roadmap.md`,
  `README.md`, `CHANGELOG.md` (`[Unreleased]`) and this record updated.
- No sanitizer run was performed; no sanitizer gate is configured. Interop
  used the installed `clang` (v23.1.2).
- Merged into `main` as PR #16 (merge commit `f58dd99`); implementation
  commit `9f20e8b` and documentation commit `1ea9105`. CI run for the PR
  (`42788650639`, 3m17s) was green. Post-merge gates on `main` pass:
  `zig fmt --check`, Debug/ReleaseSafe builds and unit tests, and the
  Debug/Safe/Release/Fast integration matrix — all report
  `165 passed, 0 failed`. Release artifacts and tags are untouched.
- Next task: the register pairs Clang supports that Kyn still rejects are the
  remaining gap — for example `(float, float)` for a 16-byte aggregate with
  one `f32` per eightbyte. Pointer members, also listed here as a gap, were
  closed by §35.

## 35. Pointer-leaf and narrow-slot ABI increment (completed and merged)

- Scope: three gaps left open by §34. (a) A pointer member had no leaf kind of
  its own, so an eightbyte carrying one was classified through the integer
  table and a pointer expected in a full-width `ptr` register was either
  narrowed to a neighbouring integer width or rejected. (b) A 12-byte
  aggregate whose second eightbyte carries a single leaf narrower than a
  register wrote the whole 8-byte slot instead of only the leaf's bytes.
  (c) Single-member aggregates had no coverage at all: the shape-space probe
  only generated 2–4 member shapes, so a lone-pointer struct was never compared
  against Clang. It is ABI-correct (`i64` and `ptr` are the same INTEGER
  register, verified bit-exactly in execution), and it is now covered
  explicitly so a future change cannot break it unnoticed.
- Rule (probed with Clang 23.1.2 before implementing, 17 shapes):
  - a single pointer leaf travels as `ptr`, never narrowed: `{ ptr, i64 }`,
    `{ i8, ptr }`, `{ ptr, ptr }`, `{ ptr, f64 }`, `{ f32, ptr }`
  - an eightbyte with several leaves merges to `i64` even when one of them is
    a float (`{ i32, f32 }` → `i64`, `{ f32, i32, bool }` → `{ i64, i8 }`,
    `{ i32, i32, ptr }` → `{ i64, ptr }`) — this corrected a wrong assumption
    that Clang rejects mixed int/float eightbytes; it packs them
  - a two-`f32` SSE slot paired with a narrower second leaf keeps its packing:
    `{ f32, f32, i16 }` → `<2 x float>, i16`, `{ f32, f32, i8 }` /
    `{ f32, f32, bool }` → `<2 x float>, i8`, `{ f32, f32, ptr }` →
    `<2 x float>, ptr`, plus the mirrored `{ i16, f32, f32 }` / `{ ptr, f32, f32 }` /
    `{ i32, f32, f32 }` orders
- Implementation:
  - `compiler/types.zig`: `AbiScalar` became `AbiSlot` (adds `f32x2`, plus
    `bits()` and `isFloat()`), `AbiPair` is now two `AbiSlot`s, and the
    duplicated scalar block was removed. `AbiSlot.bits()` is the single source
    of truth for register width, so a narrow slot writes only its own width.
  - `compiler/sema.zig`: `eightbyteSlot` replaced `eightbyteScalar`; the
    two-eightbyte branch maps `i64+i64` → `.small_2`, `f64+f64` →
    `.sse_f64x2`, `f32x2+f32` → `.sse_f32x3`, `f32x2+f32x2` → `.sse_f32x4`,
    anything else → `.pair`. `BoundaryClass` was trimmed to the classes that
    actually lower differently (`none`, `small_1`, `small_2`, `sse_float`,
    `sse_double`, `sse_f32x2`, `sse_f32x3`, `sse_f32x4`, `sse_f64x2`, `pair`,
    `memory`) plus the `eql`/`crosses`/`isPair` helpers; three previously
    distinct classes that shared a transport are now the single `pair`.
  - `compiler/backend/llvm.zig`: `BoundaryParams`, `sseReturnTransport`,
    `abiSlotType`, `pairTransport`, `sseBoundaryParams` and `abiSlotName`
    drive every transport from `AbiSlot`, so `pair` needs no per-shape code
    path; `.f32x2` emits `<2 x float>`. Pair slots are zero-padded to 16 bytes;
    `<2 x float>` is 4-byte aligned while the others are 8-byte aligned.
  - `lowerPackedAggregate` copies `source_ty.int.bits/8` bytes (fallback 8),
    clamped to `size - offset` — this is the actual narrow-slot write fix.
- Tests:
  - unit: `C ABI boundary classification follows Clang's leaf registers`
    asserts the exact register sequence for 21 shapes, including the four
    rejection rows. Its power was verified by mutation: narrowing a merged
    eightbyte to `i16` makes the test fail.
  - integration: `cabi_pointer_members` (exit 199) and
    `cabi_pair_slot_widths` (exit 215) cover both directions.
    `cabi_pointer_members` exercises 7 pointer shapes plus 6 single-member or
    odd-width shapes (lone `*u8`, `i16`, `f32`, `f64`, `{i16,i16,i16}`,
    `{i8,i8,i8}`), which the shape-space probe never generated. Pointer
    identity is verified from C, because a by-value aggregate is copied at the
    call (a Kyn-side `anchor != anchor2` folds statically), and the fixture
    magnitudes are kept below 256 so a wrong sum cannot wrap into the expected
    exit code.
  - mutation check: both integration fixtures were confirmed to detect a real
    classifier regression. Forcing the second slot to `i64` fails 21 tests with
    wrong exits (215→132 and 199→151), so the fixtures are not vacuous. A
    `ptr`→`i64` mutation is *not* detectable, and correctly so: both are one
    INTEGER register and bit-identical.
- Validation (re-run from a cleaned `.zig-cache`): `zig build` OK;
  `zig build test` **78/78**; integration **167/0** in Debug and **167/0** in
  ReleaseSafe; `zig fmt --check build.zig
  compiler build-system` clean; differential probe over **1872 shapes**:
  1872 accepted, **0 real gaps** after filtering the known noise (`i128` vs
  `{i64,i64}`, `i24/i40/i48/i56` vs covering width, `sret(%struct.X)` naming,
  `%argN` names, `dead_on_unwind noalias writable`). The original probe only
  built 2–4 member shapes, so a focused second probe was written for
  single-member and pointer-bearing aggregates: **1293 shapes, 1212 exact
  matches, 81 covering-width matches, 0 real gaps, 0 rejections**. The
  covering-width equivalence was verified in execution, not assumed
  (`{i16,i16,i16}` is Clang `i48` and Kyn `i64`; the round trip returns the
  exact value, exit 242).
- Expectation errors worth remembering: two "failures" during this increment
  were arithmetic mistakes in the expected exit code, not compiler defects.
  The C side performs the transform for Kyn→C calls while `c_check_kyn`
  checks the Kyn export, so the two sums differ (`count *= 3` → 63 on one
  path, `count * 2` → 42 on the other; the fixture exits 215, not 194).
  Re-derive the expectation from the code before treating a mismatch as a bug.
- Docs: `abi.md` §1 and §3 (leaf model, pointer slot, narrow slot, and the
  stale "nested wrappers are unsupported" claim corrected — nested wrappers
  are supported, fixed arrays and `i128` are the actual limitation),
  `type-system.md` §8, `language-reference.md` §3.2, `roadmap.md` "Next
  direction", `README.md`, `CHANGELOG.md` (`[Unreleased]`) and this record.
- Limitations: the target is `x86_64` Linux only; variadics remain
  unsupported; fixed array fields and `i128` still have no boundary register
  and are rejected with `E0473`; `SSE`-class aggregates beyond the enumerated
  shapes (for example `{ f32, f32, f32, f32, f32 }`) keep using memory/sret.
  No sanitizer gate is configured, so none was run.
- Merged into `main` as PR #18 (merge commit `9501802`); implementation commit
  `a460991` and documentation commit `11a3c4b`. CI run (`42904164029`, 1m43s)
  was green before the merge. Post-merge gates on `main` pass from a cleaned
  cache: `zig build`, `zig build test` **78/78**, `zig fmt --check`, and the
  Debug and ReleaseSafe integration suites — both **167/0**.
- Next task: continue the remaining Clang register pairs still rejected —
  `(float, float)` for a 16-byte aggregate with one `f32` per eightbyte is the
  most visible one — and specify cross-compilation targets before exposing
  further layouts across `extern`/`export`.

Explicit module re-export syntax remains a language-design decision, not an
assumed feature.
