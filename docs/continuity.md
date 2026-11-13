# Technical continuity record

This document is the persistent engineering state record for `Hardion-Labs/Kyn`.
Before starting any future increment, read this record and cross-check every
entry against the actual source tree, test suite and `git log`. Never rely on
this file if the codebase disagrees; reconcile any discrepancy immediately.

## 1. Current real stage

- **Published toolchain baseline:** `v0.1.0-alpha.5`, cut from `af7cfff` and
  published as a prerelease (§42). It carries the three increments that had
  accumulated on `main` after `alpha.4`: explicit code-generation targets (§39,
  PR #25 → `47763af`), variadic `extern` declarations (§40, PR #27 →
  `a0d00f4`) and first-class function values with indirect calls (§41, PR #29 →
  `5b9dc00`).
- **Previous published baseline:** `v0.1.0-alpha.4` (`d6e7302`), replacing
  `v0.1.0-alpha.3` (`84093a2`); its archives could not be attached (see §38),
  and that uploader blocker was re-checked for `alpha.5` in §42.
- **Previous published baseline:** `v0.1.0-alpha.3` (`84093a2`), Zig `0.17.0`
  + Clang/LLVM opaque-pointer IR (`ptr`). Tag and Release were published
  2026-11-09T23:05:28Z; the release-readiness gate passed 17/17 checks for
  that SHA before tagging, and main CI run `42717072114` was green.
- **Unreleased work on the current branch (§55):** unions and packed structs are
  **implemented** end to end — overlapping members with no tag, `packed` removing
  padding and forcing the memory class at the C ABI, `E0484`/`E0485`, and two
  fixtures that call Kyn from C in both directions plus one that reads the layout
  back through Kyn's own field access. Bitfields and `align(N)` remain
  unimplemented; the design covering them is `docs/design-unions-bitfields-packed.md`.
  The same increment fixed a pre-existing defect where an aggregate field could
  only be initialized from a literal.
- **Merged (`4e3973f` .. `bb19a1b`, §54):** the aggregate extensions design. It measures the layout and ABI
  shape of each, decides that bitfield widths live in the type (`u3`), that a
  union carries no tag, and that `packed` means "no padding, align 1" while
  `align(N)` stays out of the increment; it claims only a measured C-compatible
  bitfield subset and pins the rest as a deterministic documented rule.
- **Merged (`5b2e2e5` .. `e04501a`, §53):** signed division at the widest
  minimum. `i128` division no longer panics the compiler (`emitDivisionByZeroTrap`
  built `INT_MIN` as `-(1 << 127)`), and the most negative literal of a signed
  type folds to the value its type denotes instead of trapping as a checked
  `0 - magnitude`. Both are lowering fixes with IR-level tests and two
  integration fixtures. The callee side of variadics (§52) is merged.
- **Merged (`00837d5` .. `c15a185`, §52):** the callee side of variadics is
  **implemented** from the §51 design. `export fn` may be variadic,
  `va_arg()` is a context-typed builtin (`E0478` no expected or non-scalar type,
  `E0479` a width the caller promoted away, `E0480` outside a variadic
  function), `E0474` narrowed to `export`/`extern`, and the backend emits
  `[1 x %struct.__va_list_tag]` with `llvm.va_start.p0`, one `va_arg` per
  retrieval and `llvm.va_end.p0` before every exit — all gated on a variadic
  body existing, so other modules emit identical IR. Fixture
  `cabi_variadic_callee` links C against the exported definitions.
- **Merged (`db81d81` .. `e5520ee`, §50):** the remaining documented tables were
  swept against the real compiler — the slice half of the cast table, the
  constant-expression rules, and the safety model's static checks
  (`E0501`–`E0506`, `W0501`, `W0502`). All behave as documented; the one defect
  was documentation: §3.8 named `E0419` where the compiler emits `E0412`.
- **Merged (`961ccbc` .. `5e0bdaa`, §49):** folded constant integers now lower
  with their real signedness, so literal `-` no longer traps where the
  named-variable form works, and a shift by a constant no longer traps always;
  the duplicate `E0216`/`E0420` check is deduplicated in favour of the documented
  `E0420`. Both found by sweeping the documented tables in §5.1 and §4.1.
- **Merged (`fe9c964` .. `e34bda9`, §48):** `bool` ↔ float casts now compile —
  one direction raised an "internal" error and the other emitted invalid IR —
  and a constant cast in a global initializer folds into the destination
  category instead of keeping the source representation. Found by a
  differential sweep of every numeric cast pair. Three stale doc lines that
  described features as "not supported yet" after they shipped were corrected in
  the same pass.
- **Merged (`b3df054` .. `99b6495`, §47):** `kyn-build` hashes the transitive
  quoted C headers of a target, so editing a header rebuilds instead of silently
  leaving a stale binary (a documented caveat that was a correctness bug).
- **Merged (`8028fb6` .. `c87a197`, §46):** a struct initializer that repeats a
  field is now `E0404` — the documented "specified exactly once" rule was
  unenforced and the last value silently won.
- **Merged (`7ddd626` .. `f50733a`, §45):** the `argc`/`argv` entry point — already delivered correctly by the C ABI but undocumented, untested,
  and unconstrained: any `main` signature passed the type checker. Now
  documented, covered by a fixture with program arguments, and checked
  (`E0477`).
- **Merged (`d2a20d2` .. `eee8a50`, §44):** raw pointer / integer /
  function-value casts in both directions, and the `inttoptr` lowering they
  needed (an integer-to-pointer cast was documented and accepted but reached the
  back end as an internal error).
- **Merged, `main` (`c001d05` .. `456ea85`, §43):** exported globals
  (`export var`/`export let`/`export const`, `E0476` guard) plus two
  pre-existing `u128`-constant defects fixed in the back end and in literal
  adaptation. Validated locally — 97/97 unit, 188/0 integration in Debug and
  ReleaseSafe.
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

## 36. Fixed-array member ABI increment (completed and merged as PR #19)

- Scope: array fields were the last common C struct shape rejected with
  `E0473`. §35 taught the classifier about pointers and narrow second slots
  but still refused `[N]T` members outright.
- Implementation (`compiler/sema.zig`): `aggregateLayoutGuess` gained an
  `.array` case whose size is `element.size * len` (guarded by
  `std.math.mul`, deliberately *not* capped at 16 bytes so an oversized
  aggregate correctly falls into the memory class) and whose alignment is the
  element's. `collectAggregateLeaves` expands it into `len` element leaves at
  `base + i * element.size`, so nested arrays and arrays of aggregates expand
  recursively through the same recursion that already flattened nested
  structs. No backend change was needed for the shapes themselves.
- Defect found and fixed while validating: `.call` emission printed the
  aggregate as the result type *and* passed `sret`, which is invalid IR and
  silently zeroed results. A `sret` call now returns `void`
  (`compiler/backend/llvm.zig`).
- Regression I introduced and then fixed: after generalising arrays, a *bare*
  array parameter (`extern fn take(values: [2]i32)`) was accepted and passed
  by value. In C an array parameter decays to a pointer, so this had to stay
  rejected; an early `if (ty.* == .array) return null;` in
  `aggregateBoundaryClass` restores `E0473` while arrays nested in structs
  remain accepted.
- A suspected `.pair` transport bug was *not* a compiler bug: the "garbage
  `double`" came from a hand-written `dbg(f64, i32)` harness that declared
  `%f`/`%d` against the wrong register class. Verified through a real C
  function instead (`exit 42`, `c = [2, 4] d = 3`). Lesson: never trust a
  hand-written debug harness when a real C callee can answer the question.
- The last open divergence was `{ [1]i64, [1]f32 }`: Clang emits
  `{ i64, <2 x float> }`, Kyn emits `{ i64, float }`. Characterised with
  targeted Clang sweeps rather than guessed:
  - the trigger is specifically a *lone `f32` coming from an array element*;
    a direct `f32` member in the same position stays `float`, and a
    two-element `f32` array is already `<2 x float>` by the existing two-lane
    rule;
  - it is not padding: `{ i64, f32 }` and `{ i64, f32[1] }` are both 16 bytes
    yet differ;
  - it is not a SysV rule: GCC emits `float` for both forms (`movd` in both
    cases) and follows the generic `{ i64, f32 }` classification;
  - Clang's own choice is size-sensitive in a way the ABI does not require
    (12-byte `{ i16[3], f32[1] }` ⇒ `float`, 16-byte `{ i16[3], f32[2] }` ⇒
    `<2 x float>`), so reproducing it would add target-specific
    complexity for no interoperability gain.
  Kyn therefore keeps the SysV (`float`) spelling, matching GCC, and the
  equivalence is *proved in execution*: a caller/callee pair built from Kyn
  and C routes the value through the low SSE lane in both directions and
  against both Clang and GCC, returning the expected value in all four
  combinations. The fixture pins this with `c_lane_check`.
- Fixtures: `tests/integration/abi/cabi_array_members.{kyn,c}` covers ten
  array shapes (`{ [2]i8, f64 }`, `{ [2]i32 }`, `{ [3]i32 }`, `{ [4]i8 }`,
  `{ [3]i16 }`, `{ [6]i16 }`, `{ [2]f32 }`, `{ [2]f64 }`,
  `{ [2]*const u8 }`, `{ [4]i64 }` ⇒ `sret`/`byval`) plus
  `{ [1]i64, [1]f32 }`, in both directions, with a C-side reverse check.
  Guard codes 80–101. `{ [6]i16 }` is the one shape whose second eightbyte is
  only partially occupied *and* merged from several leaves, so it pins the
  occupied-width transport rather than a full `i64`. Two stale error
  fixtures were rewritten to layouts that are still rejected
  (`abi_float_param.kyn` and `abi_float_return.kyn` now use `{ i128 }`),
  keeping the `E0473` coverage rather than deleting it.
- Mutation checks: forcing one leaf per array and setting the array size to
  `element.size` both break compilation; changing the `.pair` second-slot
  offset from 8 to 4 breaks at runtime (exit 82) plus five older fixtures;
  dropping the C-side `tail += 1.0f` trips guard 99; changing the Kyn-side
  `head + 1` trips the C reverse check. The guards are not vacuous.
- Validation: `zig build` OK; `zig build test --summary all` **78/78**;
  integration **168 passed / 0 failed** in Debug *and* ReleaseSafe;
  `zig fmt --check build.zig compiler build-system` clean.
  Differential probe over **552 shapes**: 358 exact, 68 covering-width,
  112 rejected (bare arrays and `i128`, both intentional), and 14 remaining
  diffs, all classified: 9 are width/padding noise (`i40` vs `i64`,
  `{ i64, i32 }` vs `i128` — the same register pair) and 5 are the SSEUP
  `float` vs `<2 x float>` spelling analysed above.
- Also fixed an unrelated but real defect found while running the gates:
  `tests/integration/check_docs_links.py` tested `exists()` on a path it had
  already made repository-relative, so the result depended on the caller's
  working directory — the suite passed from the repo root and reported 56
  broken links when run from `tests/integration`. It now resolves once and
  indexes anchors by resolved path.
- Investigated and dismissed during validation: `{ [6]i16 }` and
  `{ [10]i8 }` look different in IR from Clang (`i128` versus `{ i64, i32 }`),
  but that is only how the *two-register* pair is spelled. Kyn packs both
  registers into one `i128` value whose byte layout matches the aggregate, and
  the C callee reads exactly the bytes it expects. Verified in execution in
  both directions against Clang and GCC (`exit 42` each time, members read
  individually as `a*1 + b*10 + … + f*100000`), so no change was made. This is
  the same class as the width noise in the differential probe: a different
  spelling of the same register pair.
- Limitations: the target remains `x86_64` Linux only. Still rejected with
  `E0473`: a bare array parameter, a struct whose only field is a slice, and
  singleton `enum` members with 1-bit backings. `Clang`'s `<2 x float>`
  spelling for a lone `f32` array element is not reproduced (deliberate, see
  above). No sanitizer gate is configured, so none was run.

## 37. Wide-integer increment (completed and merged as PR #20)

- Scope: §36 closed the array shapes and left "a lone `i128` member" on the
  unsupported list. A fresh space probe showed that the classifier was in fact
  complete for every aggregate of at most 16 bytes: of 13 370 shapes over
  eight member types, Kyn rejected **zero** that Clang accepts. The remaining
  diffs were `i128` vs `{ i64, i64 }` (the same register pair, already proven
  equivalent in §36) and one `i64` vs `ptr` spelling. So the next coherent step
  was not more shapes but the two real defects the probe surfaced.
- Implementation (`compiler/sema.zig`): a struct whose only member is a
  128-bit integer fills both eightbytes with one leaf, so no per-eightbyte
  `singleton` exists and the old path returned `null` (`E0473`). Clang
  classifies `struct { __int128 a; }` as `i128`, which is exactly the packed
  two-register transport `.small_2` already emits, so the ABI itself needed no
  back-end change. The first version of this tested the *type* (`struct` with
  one `i128` field), which missed the nested and array spellings; it was redone
  as an `EightbyteLeaf.covering` flag set by `recordAggregateLeaf` when one
  non-float leaf starts at offset 0 with size 16. Because the leaf walk already
  sees through nesting and arrays, `{ a: Inner }`, `{ a: [1]i128 }` and
  `{ a: i128 }` all classify identically without a case each, and the checker
  is derived from the same data the classifier uses.
- Defect 1, compiler crash on any 128-bit literal (`compiler/types.zig`):
  `IntInfo.max()` computed `1 << 128` and `IntInfo.min()` negated `i128`'s
  minimum. Both overflow, so `let x: i128 = 1;` aborted with an
  integer-overflow panic — reachable from ordinary source, not just `extern`
  code. `max` now returns `u128` (the literal domain) and clamps at 128 bits;
  `min` clamps at 128 bits; a new `minMagnitude` returns `1 << (bits-1)` by
  shifting instead of negating, because the widest signed minimum has no
  positive `i128` counterpart. The range predicate had been written once per
  call site; it now lives on `IntInfo` as `fits` and runs in the unsigned
  domain past the lower bound, so the two copies cannot drift.
- Defect 2, `u128` maximum aborted the back end (`compiler/backend/llvm.zig`):
  literals arrive as `u128` and were `@intCast` into `ir.Value.int`'s `i128`,
  which has no spelling for `maxInt(u128)`. The literal now travels as its
  two's-complement bit pattern (`@bitCast`), and `emitValue` renders it back in
  the unsigned domain only for an unsigned 128-bit declared type, so every
  narrower and every signed case keeps the existing rendering.
- Fixtures: new `tests/integration/abi/cabi_wide_integer.{kyn,c}` covers
  Kyn→C→Kyn with both halves of a wide value, a value built entirely by C,
  a C→Kyn callback that checks the arithmetic, the `u128` extremes, both
  signed extremes, and the nested and one-element-array spellings. Guards
  80–92, mutation-checked: dropping the high half on either side gives 80/81,
  a wrong C expectation gives 82, an inverted unsigned comparison gives 83, and
  truncating only the C-side expected value gives 91.
- `tests/integration/errors/abi_float_param.kyn` and `abi_float_return.kyn`
  asserted the old `i128` rejection. They were **not** deleted: both were
  rewritten to the shape that is still rejected (a struct whose only field is
  a slice), so `E0473` coverage survives, and the new positive fixture covers
  the accepted side.
- Robustness corpus gap: `tests/integration/robustness.py` could not have found
  either crash, because its single seed program never mentioned a 128-bit type.
  It now mutates two seeds in alternating slices (the original plus a
  `WIDE_SEED_PROGRAM` built from the `i128`/`u128` extremes) and also checks
  both seeds verbatim, so the corpus grew 900 → 902 cases. Verified by
  re-introducing the `min()` overflow: the corpus then reports
  `wide_seed.kyn: crash (signal/exit -6)` instead of passing.
- Docs: `abi.md` §1/§3/§8 (removed the stale "fixed arrays … remain rejected"
  sentence left by §36, recorded the `i128` classification rule and trimmed
  `i128` from the unsupported list), `CHANGELOG.md` under Added/Fixed including
  the truncated sentence an earlier edit had left in the pointer-slot entry.
- Validation: `zig build` OK; `zig build test --summary all` **79/79** (the
  classifier row for `{ a: i128 }` moved from `null` to `.small_2`, plus a new
  `types.zig` test pinning the 128-bit bounds and magnitudes);
  integration **169 passed / 0 failed** in Debug; `zig fmt --check` clean;
  `check_docs_links.py` and `check_diagnostic_docs.py` clean; robustness corpus
  902 cases clean.
- Limitations: unchanged target (`x86_64` Linux only). The fixture also
  exercises a scalar `u128` parameter and return (`c_echo_unsigned`, guards
  89/90), so the wide constant is covered outside a struct as well.
- Method note: a mutation that truncates *both* sides of a comparison proves
  nothing, which is how the first attempt at checking guard 91 appeared to pass
  while passing vacuously. Mutate one side only.
- Merge: PR #20 squash-free merge commit `d1ee24c`, CI green; `main` re-validated
  in a clean worktree (79/79 unit, 169/0 integration). Commits `839c58e`
  (implementation and fixtures) and `e19b06d` (this record).
- State of the classifier: the 13 370-shape space probe over aggregates of at
  most 16 bytes now yields zero Kyn rejections, and the surviving IR diffs are
  all register-pair spellings proven equivalent in execution (`i128` vs
  `{ i64, i64 }`, `i64` vs `ptr`, `float` vs `<2 x float>`). Further work here
  is no longer shape coverage.
- Next task: specify cross-compilation targets, then the remaining
  `SSE`-class fallbacks (`{ f32, f32, f32, f32, f32 }` and similar
  memory-class shapes) before exposing further layouts across `extern`/`export`.
  Worth revisiting the 30 mutation seeds in `robustness.py`: the 128-bit crash
  survived because a type the corpus never mentioned was never exercised, so
  widening the seed vocabulary (unsigned widths, enums with unusual backings,
  slices of slices) is likely to pay off again.

## 38. Release increment: v0.1.0-alpha.4 (in progress on `arena/4ec0f017-kyn`)

- Trigger: `v0.1.0-alpha.3` was tagged at `84093a2`. **Eighteen** pull requests
  have merged since, spanning the whole `Unreleased` section: the pointer-leaf
  increment (§35), fixed-array members (§36), the 16-byte integer and the two
  128-bit crashes (§37), plus the earlier leaf-based classification series
  (PRs #4–#16) and `packaging/` (PR #17). `dist/` archive tooling therefore had
  no published artifact, and the toolchain reported a version older than its
  content.
- Scope decision: this increment is the *release*, not new compiler work. The
  classifier space is exhausted per §37 (13 370 shapes, zero rejections), so a
  feature increment here would have been speculative.
- Version sources, all four updated together: `compiler/main.zig` and
  `build-system/main.zig` (`const version`), `build.zig.zon` (`.version`), and
  the `README.md` badge/status/archive-name/release-check example. Verified by
  `check_versions.py` (reports `versions consistent at 0.1.0-alpha.4`) and by
  both binaries printing `0.1.0-alpha.4`.
- `CHANGELOG.md`: `[Unreleased]` promoted to `[0.1.0-alpha.4] - 2026-11-10`
  with its 15 Added and 3 Fixed entries intact; the `alpha.3` section is
  unchanged (verified: the diff against the tag only inserts).
- Docs updated with the release boundary: `docs/release-checklist.md`
  (command examples plus the "current alpha status" paragraph now names
  `alpha.4` and keeps `alpha.3` as published and untouched),
  `docs/roadmap.md` (new `alpha.4` section listing leaf-based classification,
  pointer leaves, fixed arrays, 16-byte integers, `packaging/` and 128-bit
  constants; `alpha.3` section retained below it), `README.md` roadmap table
  (two rows moved from 🟡 Partial to ✅ shipped, three new ones added),
  `tools/release-check.sh` usage examples.
- Packaging validated, not assumed: `packaging/make-dist.sh` produced
  `dist/kyn-0.1.0-alpha.4-linux-x86_64.tar.gz` and
  `dist/kyn-0.1.0-alpha.4-windows-x86_64.zip`, verified the Linux archive
  end-to-end (extract → `install.sh` → run), and validated the Windows archive
  structurally (9 entries, PE magic). `dist/` is gitignored, so no artifact is
  committed.
- Environment note: the sandbox clone was **shallow**, which fails gate item 4
  of the release checklist. `git fetch --unshallow --tags` fixed it; the clone
  now reports `is-shallow-repository: false` and the three existing tags are
  local.
- Validation at preparation time: `zig build` OK; `zig build test` **79/79**;
  integration **169 passed / 0 failed** in Debug and ReleaseSafe;
  `zig fmt --check build.zig compiler build-system` clean; `check_docs_links.py`
  21 files; `check_diagnostic_docs.py` 127 codes; `check_versions.py` consistent.
- Gate defect found while auditing `main` at `01191c6`: the CI step ran
  `gh run list --commit <sha>`, and this `gh` has no `--commit` flag, so the
  step failed unconditionally — it had been failing since `alpha.3`, meaning the
  gate could never have passed. `gh` also writes that error to stdout and exits
  0, so the empty result looked like "no successful run". The filter now happens
  in jq against `headSha`, with `--limit 50` to cover a merge's own push run and
  commits a few merges behind `main`. Verified: the step reports
  `CI succeeded for expected SHA (run 43027891490)`.
- **Released.** Gate passed **17/0** on `main` at `d6e7302`: on `main`, clean
  tree, HEAD matches, `origin/main` matches, not shallow, CI green for that
  exact SHA (run 43029050168), CHANGELOG contains the version, no pre-existing
  tag or release, and the full clean-room clone build/test/robustness pass.
  Then:
  - annotated tag `v0.1.0-alpha.4` → `d6e7302b9d0423c6c4fafa49da0ee8ae751fb0a4`;
  - GitHub Release `Kyn v0.1.0-alpha.4` published (currently "Latest");
  - `alpha.1`–`alpha.3` untouched, as the checklist requires.
- Blocker, recorded not hidden: the two release archives could not be attached.
  GitHub asset uploads go through `uploads.github.com`, which is unreachable
  from this sandbox (`SSL_ERROR_SYSCALL`; `api.github.com` answers 200), so
  `gh release upload` fails with `EOF` before any byte is sent. The archives
  were built and verified from the tagged commit, and the release notes say how
  to reproduce them from the tag. Attaching them is a follow-up that needs a
  network path to `uploads.github.com`.
- Next task: attach the two `dist/` archives to the existing release once
  uploads are reachable (no re-tag; content is unchanged), then proceed with
  cross-compilation targets and the remaining `SSE`-class fallbacks per the
  roadmap.

## 39. Compilation-target increment (completed and merged as PR #25)

- Scope: the roadmap asked to *specify cross-compilation targets* before
  exposing further C ABI layouts. `v0.1.0-alpha.4` was already published, so the
  uploader blocker on its archives is not actionable from here (see §38): the
  sandbox still cannot reach `uploads.github.com` (`HTTP 000`).
- Measurement first, because the design depended on it. The emitted module
  carries **no** `target triple` and **no** `target datalayout`, and an
  assembler silently overrides both from its own `-target`: a deliberately
  big-endian `datalayout` written into a module was discarded and the output
  came back little-endian `x86_64`. So a triple in the IR cannot direct code
  generation. What does is the `-target` the external assembler receives — the
  same IR compiled with `-target aarch64-linux-gnu` produced a valid
  `ELF64`/`AArch64` object. This is why the design passes the flag through
  instead of pretending the IR is authoritative, and why an earlier attempt to
  fix a `clang` "overriding the module target triple" warning by writing the
  triple into the module changed nothing.
- Implementation: new `compiler/target.zig` holds `Target` (parsed query plus
  the triple as written), `parse` (accepts Zig's spelling and normalises the
  vendor-qualified `x86_64-unknown-linux-gnu` that `std.Target.Query.parse`
  rejects as an unknown OS), `native`, `cpuArch`, `osTag` and
  `supportsSystemVAbi`. `compiler/main.zig` gains `--target`, resolves it once,
  reports an unusable triple as `kyn: unknown target ...` on **stderr** with
  exit 2, and appends `-target <triple>` to every assembler invocation.
- One source of truth: `aggregateBoundaryClass` (which read the *build* target
  through `builtin`) was removed and replaced by
  `aggregateBoundaryClassFor(ty, systemv)`. `Sema.target_supports_c_abi` and
  `Lowering.target_supports_c_abi` are set from the resolved target by the
  driver. Keeping both would have let a cross-compilation lower the host
  convention silently — exactly the failure this increment exists to prevent.
- Contract: a target that is not `x86_64` Linux rejects an aggregate crossing
  `extern`/`export` with `E0473`; scalar boundaries and all non-`extern` code
  cross-compile unchanged. Verified by a discriminating probe (one `{ i32, i32 }`
  pair: 2 diagnostics for `aarch64-linux-gnu`, 0 for `x86_64-linux-gnu`).
- Tests: four unit tests in `target.zig` (spellings, the System V predicate
  across five triples, rejection of unusable triples, native round-trip) —
  unit total 79 → **83**. Five integration checks in a new "compilation targets"
  section: cross-compiles to aarch64 (reads `e_machine` at ELF offset 18 for
  `b700`), non-System V rejects, System V accepts the same boundary,
  vendor-qualified spelling accepted, unknown target rejected. Integration
  169 → **174**.
- Mutation-checked, and the method note matters more than the result: the first
  attempts appeared to pass while proving nothing, because the mutation left the
  build **failing** (`unused function parameter`) and the previous binary
  answered the probe. Always assert `zig build` returned 0 before believing a
  mutation result. With a valid mutation (`_ = self;` and a hard-coded `true`),
  the build succeeds and aarch64 starts accepting the boundary, so the
  integration check fails as intended.
- Docs: `abi.md` gains §8 "Compilation targets" (mechanism, spelling, the
  single-source-of-truth rule, and the `E0473` contract) with the old list
  renumbered to §9 and §1 noting the target restriction; `roadmap.md` replaces
  the "specify cross-compilation targets" task with what is now implemented and
  what is still unspecified (linking a cross-compiled executable needs a target
  sysroot and linker; per-target ABI variants would be a new classifier);
  `build-system.md` §7 clarifies that `kyn.build` itself has no per-target
  setting; `CHANGELOG.md` under `[Unreleased]`.
- Validation: `zig build` OK; `zig build test` **83/83**; integration **174/0**
  in Debug and ReleaseSafe; `zig fmt --check` clean; `check_docs_links.py`
  21 files; `check_diagnostic_docs.py` 127 codes; robustness corpus 902 clean.
- Limitations: `run` with a cross target builds for another machine and cannot
  execute locally, so `--target` mainly matters for `emit-obj` and `build`.
  Linking a cross-compiled executable (as opposed to an object) is not
  implemented. `kyn-build` has no per-target setting.
- Merge: PR #25 → `47763af`, CI green; `main` re-validated in a clean worktree
  (83/83 unit, 174/0 integration). Implementation commit `dcab8b4`.
- Release status: `v0.1.0-alpha.4` is tagged at `d6e7302`, which predates this
  increment, so `main` now carries `--target` without a release of its own.
  This is recorded rather than acted on: a release is a public promise and the
  change is a single coherent increment, so the next release boundary is the
  user's call. The uploader blocker of §38 is still open and independent
  (`uploads.github.com` unreachable, `HTTP 000`).
- The §39 claim that `{ f32, f32, f32, f32, f32 }` and other `SSE`/`SSEUP`
  shapes still use `sret` was **verified to be obsolete** against the actual
  compiler before starting new ABI work: an exhaustive differential harness
  (below) shows the current classifier and lowering already match Clang for
  every probed shape. That entry is corrected here rather than implemented
  again.

## 40. Variadic `extern` declarations (implemented on `arena/998c03dc-kyn`)

- Starting point: context recovery confirmed the aggregate ABI had no remaining
  gap, so the next coherent step came from the documented-but-unimplemented
  list in `language-reference.md` §7 and `abi.md` §9: `extern` variadics. That
  entry blocks every C function with a trailing `...` (`printf`, `snprintf`,
  `syslog`, `open` with a mode, `execl`), which is the single most common FFI
  shape still missing.
- Scope decision, made by measurement rather than assumption: an exhaustive
  differential harness was built first (see "Validation" below) to confirm the
  aggregate ABI was complete, so this increment is **only** the variadic
  declaration and its argument promotions. Nothing in the classifier changed.
- Syntax: `...` is a new token (`ellipsis`), lexed by a dedicated `lexDot` so
  one, two and three dots stay distinct; `..` ranges are unaffected and the
  existing range tests still pass. `ast.FnDecl.is_variadic` records the marker,
  which is *not* a parameter: `extern fn printf(format: *const u8, ...) i32;`
  has exactly one parameter, so the fixed-arity check keeps working.
- Type rule: the promotion lives in the analyzer (`sema.promoteVariadic`), not
  in the backend, and `ast.Expr.Kind.Call.arg_types` records the type each
  argument is *passed as* — the declared parameter type for a fixed parameter,
  the promoted type for a variadic one. `Lowering.lowerArgument` converts to
  that recorded type, so the promotion is written once. This removed a latent
  duplication: before it, the call path re-derived the argument type from the
  expression and would have had to re-derive the promotion in two places
  (fixed-parameter and variadic branches).
- Promotions, exactly the C defaults: `i8`/`i16` → `i32`, `u8`/`u16` → `u32`
  (signedness kept), `bool` → `i32`, `enum` → `i32`, `char` → `u32` (already
  32-bit in Kyn), `f32` → `f64`, `comptime_int` → `i32`,
  `comptime_float` → `f64`; `i32`/`u32`/`i64`/`u64`/`f64`/`isize`/`usize` and
  pointers unchanged.
- Rejections, each matching a real C constraint: an aggregate, a fixed array or
  a slice in the variadic tail is `E0475` (none has a default promotion, and
  each would arrive in a shape the callee never agreed to); a bare `null` is
  `E0475` (no pointer type to promote to); a variadic declaration that is not
  `extern`, or that has no fixed parameter, is `E0474` (ISO C requires a named
  parameter before `...`, and a Kyn body has a fixed signature).
- IR: `ir.Function.variadic` makes the emitter print `...` in a declaration;
  without it an LLVM call carrying extra arguments would not match the
  declaration. A definition can never be variadic (rejected earlier), so the
  flag is only meaningful on declarations.
- Interaction with the C ABI work: fixed parameters keep their aggregate
  classification and the variadic tail is never an aggregate, so the System V
  register classes and the `--target` guard (`E0473`) are untouched.
- Validation: `zig build` OK; `zig build test` **90/90** (83 → 90: one lexer
  test for `.`/`..`/`...`, two parser tests, three semantic tests, one IR
  emitter test); integration **180/0** in Debug and ReleaseSafe (174 → 180: the
  `cabi_variadic` fixture plus five error fixtures); `zig fmt --check` clean;
  `check_docs_links.py` 21 files; `check_diagnostic_docs.py` **129** codes;
  robustness corpus 902 clean; `check_versions.py` consistent at
  `0.1.0-alpha.4`.
- Differential verification of the *aggregate* claim: a generated harness
  emitted 347 struct shapes with up to three scalar members and 1,350 with up to
  four (`f32`/`f64`/`i8`/`i16`/`i32`/`i64`/`bool`/pointer, size ≤ 16 bytes),
  each passed through Kyn into C and back with C comparing every field, plus 16
  layouts wider than 16 bytes exercising `sret`/`byval`, plus nested
  struct/enum/array/`i128` members, plus System V register exhaustion (a
  two-eightbyte aggregate arriving after five INTEGER or eight SSE arguments,
  where the whole aggregate must move to the stack). All matched. Two of these
  confirmed subtleties worth keeping: `u8` promotes to `u32`, not `i32`, and a
  fixture must account for a value crossing *both* directions.
- Mutation check: replacing the `f32` → `f64` promotion with an identity
  conversion leaves `zig build` succeeding (rc=0, asserted before believing the
  result) and fails **three independent tests** — the semantic promotion test,
  the IR emitter test and `cabi_variadic` — proving the guard is real and not
  incidental. Restored and re-verified. The `export` rejection was verified
  separately: `export fn f(v: i32, ...) i32 { ... }` reports `E0474`.
- Limitations: only the *caller* side exists. A variadic function cannot be
  defined in Kyn or exported, and there is no `va_list` type, so a C variadic
  callback into Kyn remains impossible. A variadic argument that is a
  `comptime`-only value materialises to the promoted default rather than being
  inferred from context. Format-string interpretation is of course not checked.
- Merge: PR #27 → `a0d00f4`, CI green (`43133353138`, 2m3s). `main`
  re-validated in a clean worktree: 90/90 unit, 180/0 integration.
  Implementation commit `0250b3c`. (The follow-up commit that recorded this
  merge, `3a413c4`, was pushed as PR #28 but did not reach `main` before that
  branch was retired; this paragraph replaces it.)
- Next task: the callee side of variadics (`va_list`, `va_start`-like
  primitives and an `export`ed variadic) if it is wanted, which is a language
  and ABI design decision rather than a lowering gap; otherwise the remaining
  documented gaps are function pointers/callbacks (since implemented, §41),
  unions/bitfields/packed structs, and the `alpha.4` archive uploader blocker of
  §38.

## 41. First-class function values and indirect calls (implemented on `arena/35db4ee4-kyn`)

- Starting point: with variadics done, the largest remaining construct that the
  documentation listed as absent and that the backend actively refused was
  indirect calls — `lowerCall` returned `E0604 "indirect calls are not supported
  yet"` for any callee that was not a declared function symbol, which blocked
  every callback shape.
- Design decision: a function value is a **new type**, `fn_ptr: *FnInfo`, not a
  `.pointer` to a `.fn_type`. The distinction is not cosmetic — a function
  pointer must not be dereferenceable as data or usable for pointer arithmetic —
  but its C representation is one `ptr`, so it slots into the existing
  INTEGER-eightbyte classifier with no new ABI path. `typeName` renders the
  signature so a mismatch names both sides.
- Syntax: `fn(P) R` as a type expression (`ast.TypeExpr.Kind.fn_type`), parsed
  in `parseType` and included in `isTypeStart`, so it works anywhere a type does
  (locals, parameters, returns, struct fields, nested). A missing return type
  means `void`, matching a declaration.
- Semantics: `resolveType` builds one `FnInfo` and wraps it with `makeFnPtr`, so
  there is exactly one signature representation in the compiler and a
  `fn(..) R` annotation compares equal to the declaration it is initialised
  from. `checkIdent` decays a function name to a value *in value position*;
  `checkCall` accepts either `fn_type` or `fn_ptr` and runs the argument checks
  once for both. `isAssignable` allows declaration → value, value → value (whole
  signature compared via the new `types.fnInfoEql`, which also replaced a
  duplicated loop inside `Type.eql`), and `null` → value. `==`/`!=` against
  `null` compares at the pointer's own type.
- **A bug found and fixed by the regression suite**, worth recording: the first
  version set an `ast.Call.is_indirect` flag from the callee's *type*, but
  `checkIdent` had just decayed every function name to `fn_ptr`, so every direct
  call looked indirect. 21 ABI fixtures failed at once. The fix was to delete the
  flag entirely and let the backend keep deciding from the symbol: a direct call
  is one whose callee resolves to a `function` symbol, and that is the same
  evidence the backend already had. Mutation-checking then confirmed the flag had
  been redundant, so removing it was the smaller, correct design rather than a
  workaround.
- Lowering: `ir.Value.func` (a symbol address) is the only new value kind, and
  `ir.Inst.call.callee` is set for an indirect call. `lowerIndirectCall` lowers
  the callee, runs `emitNullCheck` on it, converts each argument to the type the
  analyzer recorded, and emits `call <ret> %vN(<args>)` — the signature is
  spelled out because an indirect call has no declaration to read it from. No
  `bitcast ptr to ptr` is emitted: a function value already has pointer
  representation. `emitNullCheck` now accepts `.fn_ptr` as well as `.pointer`,
  so calling an unset callback traps under the existing null-check policy.
- Validation: `zig build` OK; `zig build test` **95/95** (90 → 95: one parser
  test for function types, three semantic tests, one IR emitter test);
  integration **185/0** in Debug and ReleaseSafe (180 → 185: the
  `function_pointers` case, the `cabi_function_pointer` fixture and three error
  fixtures); `zig fmt --check` clean; `check_docs_links.py` 21 files;
  `check_diagnostic_docs.py` 129 codes; robustness corpus 902 clean;
  `check_versions.py` consistent at `0.1.0-alpha.4`.
- Mutation checks, each with `zig build` asserted at rc=0 first: replacing the
  indirect branch with the old `E0604` error fails `function_pointers` and
  `cabi_function_pointer`; dropping `.fn_ptr` from `emitNullCheck` removes the
  trap (measured: the mutated binary exits 96 from an uninitialised register
  where the correct one exits 132 = SIGILL from `llvm.trap`). A third attempted
  mutation — decaying the function name back to `fn_type` — did **not** fail,
  which is itself the evidence that the decay and the `fn_ptr` wrapper are two
  spellings of one signature rather than a behavioural switch.
- Boundary coverage: `cabi_function_pointer` calls a Kyn callback from C,
  round-trips its return, stores a Kyn function pointer in a static C variable
  and calls it later, and calls a C function through a value that arrived from C
  and was stored in a struct field.
- Limitations: no cast between a raw pointer and a function value (declare the
  signature instead); no variadic function values (a `...` declaration cannot be
  given a `fn(P) R` type yet); indirect calls to aggregates follow the ordinary
  boundary classifier, which was already verified exhaustively in §40.
- Merge: PR #29 → `5b9dc00`, CI green (`43229943298`, 2m8s); `main` re-validated
  in a clean worktree (95/95 unit, 185/0 integration). Implementation commit
  `7c17df3`.
- Next task: unions/bitfields/packed structs, or the callee side of variadics
  (`va_list` + `export`ed variadic), whichever is wanted; both are language
  design decisions rather than lowering gaps. The `alpha.4` archive uploader
  blocker of §38 remains open and independent.

## 42. Release increment: v0.1.0-alpha.5 (implemented on `arena/4417f623-kyn`)

- Why this was the next coherent step rather than another language feature: the
  `CHANGELOG.md` on `main` recorded the three increments above under
  `## [0.1.0-alpha.4]`, a section that is **already tagged and published**, and a
  `git diff v0.1.0-alpha.4 HEAD -- CHANGELOG.md` showed all three entries were
  pure additions made after the tag. A reader of the published release was
  therefore told that `--target`, variadic `extern` declarations and function
  values ship in a version that predates them. That is a factual error in a
  public document, and three validated increments had accumulated since the last
  boundary, so the release boundary was the honest place to fix it.
- `CHANGELOG.md`: the four post-`alpha.4` bullets were moved out of
  `[0.1.0-alpha.4]` into a new `[0.1.0-alpha.5] - 2026-11-12` section, which also
  records the correction itself under "Fixed". `[0.1.0-alpha.4]` now lists only
  what the tag actually contains — verified by diffing the file against
  `v0.1.0-alpha.4`, where every line was an addition and none a modification.
- Version metadata moved together, and `check_versions.py` enforces that they
  stay equal: `build.zig.zon` (`.version`), `compiler/main.zig` (the `--version`
  string), `build-system/main.zig` (the `kyn-build --version` string). All three
  now report `0.1.0-alpha.5`.
- Docs: `README.md` status banner, archive names, the `release-check.sh` example,
  and the roadmap table — which gains the `alpha.5` milestone, keeps `alpha.4`
  as the previous published preview, and moves the `SSE` aggregate C ABI row
  from 🟡 Partial to ✅ Implemented, because §40 verified it exhaustively against
  Clang rather than leaving it as an unproven claim. `docs/roadmap.md` gains an
  `alpha.5` section; `docs/release-checklist.md` names `alpha.5` as current and
  keeps `alpha.4`/`alpha.3` published and untouched; `tools/release-check.sh`
  examples follow.
- Validation before tagging: `zig build` OK; `zig build test` **95/95**;
  integration **185/0** in Debug and ReleaseSafe; `zig fmt --check` clean;
  `check_docs_links.py` 21 files; `check_diagnostic_docs.py` 129 codes;
  robustness corpus 902 clean; `check_versions.py` reports
  `versions consistent at 0.1.0-alpha.5`, which is the check that would have
  caught a partially-updated version string.
- Merge: PR #31 → `38d1849`, CI green (`43234150814`, 2m5s). `main` re-validated
  in a clean worktree **before** tagging — 95/95 unit, 185/0 integration, both
  binaries reporting `0.1.0-alpha.5` — so the tag only ever pointed at a
  commit proven green. Implementation commit `f92400f`.
- Tag `v0.1.0-alpha.5` was created on `38d1849` and pushed; the GitHub Release
  was published as a prerelease (`443040775`, `2026-11-12T14:13:41Z`) with notes
  scoped to the three increments. The tag is never moved; a later fix gets a new
  version.
- Release archives: `packaging/make-dist.sh 0.1.0-alpha.5` produced and verified
  both archives locally — the Linux one through extract, `install.sh`, and a
  `hello.kyn` run printing `Hello from Kyn!`, the Windows one structurally
  (contents and PE magic). **They are not attached.** `gh release upload` fails
  with `Post ".../assets": EOF`, an `HTTP POST` probe to
  `uploads.github.com/.../assets` returns `000`, and the release still reports
  `assets: 0`. `api.github.com` answers `200` from the same shell, so this is a
  network block on the upload host specifically, not an authentication or
  permission problem — §38's blocker reproduced, now on a second release.
  `dist/` is generated output and already ignored by Git, so nothing stale was
  committed.
- Next task: unions/bitfields/packed structs, or the callee side of variadics
  (`va_list` + `export`ed variadic); both are language design decisions rather
  than lowering gaps.

Explicit module re-export syntax remains a language-design decision, not an
assumed feature.

## 43. Exported globals, and two constant-representation defects (on `arena/332f179d-kyn`)

- Base: `main` at `78bcb87` (the §42 record merged; code baseline
  `v0.1.0-alpha.5`, `38d1849`). Chosen increment: `export` on a global
  declaration — the documented gap in `abi.md` §9 ("exported globals with
  controlled visibility") and the symmetric completion of `export fn`. Unions,
  bitfields and packed structs, the other candidates, need a type-system design
  decision rather than a lowering; they stay unscheduled.
- **Recovery note, important for the next session.** This increment had been
  implemented and validated once in the previous sandbox, but that sandbox was
  replaced before `git push` succeeded (GitHub was unreachable at the time:
  `HTTP 000`, `gnutls_handshake` terminated). Only the §42 documentation commit
  had been pushed, and it reached `main` as PR #32 → `78bcb87`, merged and
  re-verified in this session. The three §43 commits were therefore lost with
  the old sandbox and the implementation was redone here from the same design;
  the numbers below are from this session's runs. Lesson: push before ending a
  turn that has produced commits, or the work survives only as long as the
  sandbox.
- Design: `export` is an *opt-in to C linkage*, and the symbol is the source
  spelling, exactly as `export fn` already does. A non-exported global keeps the
  module-mangled `__kyn_g_m<N>_<name>` symbol, so no existing program changes
  meaning. Mutability already decided the storage class (`global` vs `constant`),
  so it now also decides the C spelling: `export var` is `extern int32_t
  counter`, `export let`/`export const` are `extern const ...`. No new IR,
  backend or ABI code was needed — the emitter already printed `@{link_name}`
  with external linkage — which is why the feature is a parser + sema change
  plus one guard.
- What was added: `ast.VarDecl.is_export`, `parser.parseDecl` accepting
  `const`/`let`/`var` after `export` (the error text now names all three),
  `sema.declareTopLevel` passing `vd.is_export` as `is_external_name` and
  recording `sym.is_export`, and the boundary guard in `sema.resolveGlobal`: an
  exported aggregate whose `boundaryClass` is null is `E0476`. The guard reuses
  the classifier `E0473` uses; it does not restate the ABI rules.
- What was deliberately *not* added: a `void`/function-type arm in the guard.
  `void` is already rejected as storage by `E0411`, and `fn(P) R` resolves to
  `.fn_ptr`, i.e. a plain pointer C represents natively — both arms would be
  unreachable, so they are not written. `private export let` is accepted and
  means what `private export fn` already means: the name is module-private, the
  object is link-visible.
- Two **pre-existing** defects were found while testing the feature, both
  reproduced on this tree before being touched:
  1. `const w: u128 = 340282366920938463463374607431768211455;` panicked in
     `lowerConst` (`@intCast(lit.value)`, `llvm.zig`), an abort instead of a
     diagnostic, and reachable through this feature as `export let w: u128 = ...`.
     Fixed by preserving the bit pattern (`@bitCast`), matching what the runtime
     path in the same file already did; `emitValue` already renders an unsigned
     128-bit constant in the unsigned domain.
  2. The same literal was rejected `E0440` next to an already-typed `u128`
     operand, because `applyLiteralType` went through `literalIntValue`, which
     returns null above `i128`'s maximum. Fixed by consulting a new
     `types.IntInfo.fitsUnsigned` through `sema.literalUnsignedValue` first.
     `IntInfo.fits` keeps its exact prior semantics, and values that genuinely
     do not fit are still rejected (checked case by case: `u64` one past its
     maximum, `u8` 256, `i8` -129, `u128` one past its maximum).
  The `alpha.4` changelog claimed 128-bit constants were representable "end to
  end"; for a global they were not. The fix is recorded under `[Unreleased]` and
  the published claim was not retro-edited.
- Files changed: `compiler/ast.zig`, `compiler/parser.zig`, `compiler/sema.zig`
  (declaration, guard, two unit tests), `compiler/backend/llvm.zig` (constant
  bit pattern), `compiler/types.zig` (`fitsUnsigned` + bounds test), docs
  (`abi.md` new "Exporting globals" section with the §9 line removed,
  `language-reference.md` §3.3/§3.8, `diagnostics.md` `E0476`, `grammar.md`,
  `grammar.ebnf`, `roadmap.md`, `README.md`, `CHANGELOG.md`), and fixtures
  `abi/cabi_exported_globals.{kyn,c,exit}` (scalars, struct, `u8`, C→Kyn→C
  mutation of the same object), `abi/cabi_exported_wide_global.{kyn,c,exit}`
  (`u128` maxima both directions), `errors/export_global_array.{kyn,code}`.
- Validation from a clean cache: `zig build` OK; `zig build test` **97/97**
  (95 → 97); integration **188/0** in Debug and ReleaseSafe (185 → 188: three
  new fixtures); `zig fmt --check` clean; `check_docs_links.py` 21 files;
  `check_diagnostic_docs.py` **130** codes (129 → 130, `E0476`); robustness
  corpus 902 cases clean; `check_versions.py` consistent at `0.1.0-alpha.5`.
  Both Kyn-`main` fixtures were also linked by hand against `clang` and return
  42. Not done, and not claimed: no sanitizer gate exists in this repo, so none
  ran; the Windows archive path was not re-exercised.
- Git, final for this increment: implementation commits `e8ffac3` (feature),
  `2164f06` (`u128` fixes) and `4e97cad` (docs + this record) on
  `arena/332f179d-kyn`; pushed *before* the turn ended, then PR #33 → CI
  `43243815984` green (2m1s) → merged as **`c001d05`**. `main` was re-validated
  in a fresh clone of `c001d05`: 97/97 unit, 188/0 integration, `zig build` OK.
- Release decision, recorded rather than implied: `v0.1.0-alpha.5` was published
  2026-11-12T14:13:41Z and this increment landed about an hour later, so no
  `alpha.6` tag was cut for it. The `[Unreleased]` changelog section stays open
  until enough work accumulates to justify a release, at which point the
  standing authorization to tag and publish applies again.
- Release assets for `v0.1.0-alpha.5` remain unattached (§38/§42): the archives
  build and self-verify, but `uploads.github.com` was unreachable from this
  sandbox. Not retried this session.
- Next task: the callee side of variadics (`va_list` + an exported variadic), or
  the still-unscheduled type-system decision on unions/bitfields/packed structs.
- Contract kept: no test was modified to pass; every new behaviour above has a
  passing fixture or unit test, and the two defect fixes are pinned by
  `cabi_exported_wide_global` and the `u128` unit tests so a regression reopens
  a failure rather than a crash.

## 44. Pointer, integer and function-value casts (on `arena/cdf27e39-kyn`)

- Base: `main` at `456ea85`; `v0.1.0-alpha.5` remains the published baseline and
  its tag has not moved. Chosen increment: the cast gap listed in `abi.md` §9
  ("casts between a raw pointer and a function value") — the last mechanically
  blocked item in that list, as opposed to the design decisions (unions,
  bitfields, `va_list`) that stay unscheduled.
- Why it is mechanical and not a design decision: a function value is already
  one `ptr` at the ABI level (`types.Type.fn_ptr`, `llvm.typeString` → `"ptr"`),
  an indirect call already names its own signature, and the null-call trap
  already covers the result. So the cast is a change of *meaning*, not of
  representation, and the backend needed a table entry, not new IR.
- Design, kept deliberately asymmetric to match what the language already does:
  a *pointer* casts to a function type (`ptr as fn(P) R`) — that is how a C
  callback retrieved as `void *` becomes callable — while a *function name* is
  written as a plain expression, with `as *T` (or `as usize`) naming which
  pointer it is. `as` never converts between two signatures and never reinterprets
  an aggregate as an address (`E0447`); the restriction already applied to `*T`
  in `isPointerCast` and is now stated for the function side in
  `sema.isFunctionPointerCast`.
- Changes: `sema.checkCast` grew an `.fn_ptr` source arm and lets
  pointer/integer sources reach a `fn_ptr` target (through
  `sema.isFunctionPointerCast`, which reuses `isPointer`/`isInteger` rather than
  restating a representation table); `backend.isSameRepresentation` states that
  `.fn_ptr` and `.pointer` share one representation, so no instruction is
  emitted for that pair; `backend.castKind` gained the pointer/function-value
  source arm and — the actual defect — a destination-pointer arm.
- **Pre-existing defect found and fixed:** `let p: *u8 = n as *u8;` with `n:
  usize` was documented in `language-reference.md` §5.7 and accepted by the type
  checker, but every compile failed with `E0605 internal: unsupported cast from
  the semantic layer`, because `castKind` had no `to.isPointer()` arm even
  though the emitter already knew `inttoptr`. Reproduced on a stashed clean tree
  before being touched, so it is not introduced here; it blocked the integer half
  of this increment and is now pinned by the new fixture.
- Also checked and deliberately left alone: `let b: bool = x as bool` on an
  `i32` is accepted, which is documented as an allowed numeric pair; it is
  pre-existing, unrelated, and changing it would be a policy change rather than
  a fix for this increment.
- Files changed: `compiler/sema.zig` (cast policy + one unit test),
  `compiler/backend/llvm.zig` (representation and lowering table), docs
  (`abi.md`: new paragraph plus the §9 line removed, `language-reference.md`
  §5.7 table rows and §7 line, `roadmap.md`, `README.md`, `CHANGELOG.md`), and
  fixtures `abi/cabi_function_pointer_cast.{kyn,c,exit}` (C pointer → Kyn
  function value → indirect call; Kyn function value → `*u8` → C calls it;
  pointer returned by C; address ↔ integer round-trip; function value passed to
  C as its own type), `errors/fn_ptr_cast_signature.{kyn,code}`,
  `errors/aggregate_to_fn_ptr_cast.{kyn,code}`.
- Validation from a clean cache: `zig build` OK; `zig build test` **98/98**
  (97 → 98); integration **191/0** in Debug and ReleaseSafe (188 → 191: three new
  fixtures); `zig fmt --check` clean; docs links 21; documented codes **130**
  (unchanged — no new code was needed); robustness corpus 902 clean; versions
  consistent at `0.1.0-alpha.5`. The Kyn-`main` fixture was also linked by hand
  against `clang` and returns 42, and the documentation example in `abi.md` was
  compiled to confirm it is accepted.
- Rejected-behaviour checks (so nothing was loosened): `fn(i32) i32 as
  fn(i64) i64`, `Pair as fn(i32) i32`, `fn_value as []const u8` and a
  non-representable `*T` cast all still report `E0447`.
- Git, final for this increment: implementation commit `e668134` and record
  `571b18c` on `arena/cdf27e39-kyn`, pushed before the turn ended; PR #35 → CI
  green → merged as **`d2a20d2`**; `main` re-validated in a fresh clone of
  `d2a20d2` (98/98 unit, 191/0 integration).
- Release decision: `v0.1.0-alpha.5` (published 2026-11-12T14:13:41Z) still
  covers the tag; §43 and §44 accumulate under `[Unreleased]`. No new tag was cut
  for this increment — the two are small and land within an hour of the release,
  so a version boundary would carry no information. The standing authorization
  to tag and publish applies once the unreleased section is worth a release.
- Not done, and not claimed: no sanitizer gate exists in this repo; the Windows
  archive path was not re-exercised; `v0.1.0-alpha.5` release assets remain
  unattached (§38/§42, `uploads.github.com` unreachable).
- Next task: the callee side of variadics (`va_list` + an exported variadic), or
  the still-unscheduled type-system decision on unions/bitfields/packed structs.
- Contract kept: no test was modified to pass; the defect fix and both new cast
  directions are pinned by fixtures, so a regression reopens a failure.

## 45. The `argc`/`argv` entry point, and its checked signature (on `arena/0c7eb404-kyn`)

- Base: `main` at `eee8a50`; `v0.1.0-alpha.5` remains the published baseline.
  §9 of `abi.md` now lists only design decisions (unions, bitfields, packed
  structs, `va_list`, non-System-V conventions) plus two documented ceilings
  (bare array parameters, C-only runtime support), so this increment was chosen
  from probing documented contracts rather than from that list.
- How it was found, which is the reusable part: the remaining work is not
  visible as a TODO, so the contracts in the docs and the actual behaviour were
  compared by probe. Scoping, block shadowing, same-scope duplicate locals,
  loop `break`/`continue`, nested loops, aggregate copy semantics with nested
  aliasing through `*T`, large-aggregate returns, `getenv`, and exit-status
  propagation all behaved exactly as documented. The entry point did not.
- Two findings, one of them a real defect:
  1. `argc`/`argv` already work — `fn main(argc: i32, argv: **u8) i32` receives
     the vector from the C runtime, `argv[argc] == null`, empty arguments and
     `argv[0]` mutation all behave correctly — but **nothing documented it and
     nothing tested it**, so it was an undocumented capability with no contract.
  2. **Any `main` signature was accepted.** `fn main() f64`, `fn main(x: f64)`,
     `fn main(argc: i32, argv: *u8)`, `fn main(argc: i32, argv: **u8, envp:
     **u8)` and `fn main() void` all passed the type checker and then linked.
     The language reference even said a return-type-less `main` "is accepted by
     the language but will not match the C `main` signature expected by the
     linker" — the consequence was documented instead of diagnosed, which is
     the kind of silent ABI mismatch this compiler diagnoses everywhere else.
- Design: `main` is checked where its signature is resolved (`sema.
  resolveSignature` → `sema.checkEntryPoint`), against what the C runtime can
  actually pass and read: `i32` return, at most `argc: i32` and `argv: **u8`
  (or `**const u8`). Rejections are `E0477`. Deliberately *not* checked: an
  `extern fn main` (a C declaration, not a definition), an `export fn main` and
  a non-root module's `main` — none of them is what the loader calls, and a
  library target may legitimately expose a `main` of another shape. `argc: u64`
  is rejected rather than read from the wrong half of a register, and a third
  parameter is rejected rather than reading a register the loader never set.
- `isArgvType` states the `**u8` shape once, next to the other type predicates,
  instead of open-coding a two-level pointer walk at the check site.
- Test harness: `tests/integration/run.sh` gained a minimal `.args` convention —
  a file beside the case, one argument per line, because the suite had no way to
  pass program arguments at all. Empty lines are meaningful (an empty argument),
  a missing file means no arguments, and the `--` separator is only inserted
  when there are arguments, so every existing case is byte-for-byte unaffected.
- Files changed: `compiler/sema.zig` (entry-point check, `isArgvType`, one unit
  test), `tests/integration/run.sh` (`.args`), docs
  (`language-reference.md` §6 rewritten as a contract, `abi.md` §2 note,
  `diagnostics.md` `E0477`, `roadmap.md`, `README.md`, `CHANGELOG.md`), fixtures
  `cases/argv.{kyn,args,exit}` (argc, the null terminator, two argument lengths,
  one of them empty) and `errors/main_{bad_return,bad_argv,too_many_params}
  .{kyn,code}`.
- Validation from a clean cache: `zig build` OK; `zig build test` **99/99**
  (98 → 99); integration **195/0** in Debug and ReleaseSafe (191 → 195: one
  positive case plus three negative ones); `zig fmt --check` clean; docs links
  21; documented codes **131** (130 → 131, `E0477`); robustness corpus 902
  clean; versions consistent at `0.1.0-alpha.5`. The four accepted signatures in
  the rewritten documentation section were each compiled, so the doc matches the
  code; the `.args` path was exercised by `run.sh` (`ok argv`) and by hand with
  an empty argument.
- Behaviour change worth naming: `fn main()` without a return type is now
  `E0477` instead of being accepted with a documented caveat. No fixture,
  example or test depended on the old permissiveness (the two `diagnostics.zig`
  tests that use such a string only render diagnostics and never compile it).
- Git, final for this increment: implementation commit `6eec487` and record
  `2262bfd` on `arena/0c7eb404-kyn`, pushed before the turn ended; PR #37 → CI
  green → merged as **`7ddd626`**; `main` re-validated in a fresh clone of
  `7ddd626` (99/99 unit, 195/0 integration).
- Not done, and not claimed: no sanitizer gate exists in this repo; `envp` is
  not passed to `main` (C's third parameter) — a program that needs the
  environment calls `getenv`, which works; the Windows archive path was not
  re-exercised; `v0.1.0-alpha.5` assets remain unattached (§38/§42).
- Next task: the callee side of variadics (`va_list` + an exported variadic), or
  the still-unscheduled type-system decision on unions/bitfields/packed structs.
- Contract kept: no test was modified to pass; the new behaviour is pinned by
  one unit test, one positive fixture and three negative ones.

## 46. Struct-initializer field uniqueness, and a contract sweep (on `arena/ecb80055-kyn`)

- Base: `main` at `f50733a`; `v0.1.0-alpha.5` remains the published baseline.
  With `abi.md` §9 listing only design decisions, the increment was chosen by
  **sweeping documented contracts against real behaviour** rather than by reading
  a TODO list, and the one defect the sweep found was fixed.
- The sweep, and what it cleared: signed division and remainder on
  `INT_MIN / -1` (traps, 132), shift-amount bounds (132) and arithmetic `>>` on
  a negative value, struct layout and alignment against C `offsetof`/`sizeof`
  for a mixed `u8`/`i64`/`u8`/`i32` aggregate with writes in both directions,
  `enum` backings (`u8` with 255, `i8` with -1, comparisons), string literals
  (`*const u8`, writable only through an array slice), `E0501`/`W0501`/`E0506`
  static analyses, the runtime null traps for pointer indexing and
  array-pointer slicing, `kyn-build` exit codes (build-file errors 2,
  compile failure 3) and `staticlib` output, struct/enum trailing commas, array
  literal length and element-type mismatches, and recursive structs through a
  pointer versus by value. All matched their documentation.
- **Defect found and fixed:** `Point { x: 1, y: 2, x: 3 }` was accepted, with the
  last value silently winning (`p.x == 3`). The language reference has always
  said "every field must be specified exactly once", and `E0404` already existed
  for a duplicate *declaration* field, so the initializer path simply never
  consulted `assigned[]` before setting it. Fixed by checking that flag — no new
  diagnostic code, because a duplicate field is one concept.
- Scope note: the check lives in `sema.checkStructLiteral`, which runs for every
  initializer, so nested initializers are covered by construction rather than by
  a second code path. Verified that a duplicate does not also cascade into
  `E0458 missing field`, and that declaration order still does not matter.
- Not changed, and deliberately so: `E0506` does not propagate through
  variables (`let p: *i32 = null; p[0]`), which `safety-model.md`
  §2.8 documents explicitly as "proven from the expression text" with "variable
  provenance is not tracked yet" — the runtime trap covers it. Array literals do
  not accept a trailing comma while struct fields do; the grammar and the
  reference only promise the latter, so both sides agree.
- Files changed: `compiler/sema.zig` (initializer check + one unit test), docs
  (`language-reference.md` §3.3, `roadmap.md`, `README.md`, `CHANGELOG.md`), and
  fixture `errors/struct_init_duplicate_field.{kyn,code}`.
- Validation from a clean cache: `zig build` OK; `zig build test` **100/100**
  (99 → 100); integration **196/0** in Debug and ReleaseSafe (195 → 196);
  `zig fmt --check` clean; docs links 21; documented codes **131** (unchanged —
  `E0404` was already documented for the declaration case); robustness corpus
  902 clean; versions consistent at `0.1.0-alpha.5`.
- Git, final for this increment: implementation commit `3fe9dce` and record
  `d22c906` on `arena/ecb80055-kyn`, pushed before the turn ended; PR #39 → CI
  green → merged as **`8028fb6`**; `main` re-validated in a fresh clone of
  `8028fb6` (100/100 unit, 196/0 integration).
- Not done, and not claimed: no sanitizer gate exists in this repo;
  `v0.1.0-alpha.5` release assets remain unattached (§38/§42); the Windows
  archive path was not re-exercised.
- Next task: the callee side of variadics (`va_list` + an exported variadic), or
  the still-unscheduled type-system decision on unions/bitfields/packed structs.
  A future sweep could extend to `kyn-build` target graphs (multiple targets,
  `--target` selection, `sharedlib` runtime loading), which this increment only
  touched for `staticlib` and exit codes.
- Contract kept: no test was modified to pass; the new behaviour is pinned by
  one unit test and one fixture, and the sweep's negative results are recorded
  above so the next session does not repeat them.

## 47. `kyn-build` hashes transitive C headers (on `arena/a236b746-kyn`)

- Base: `main` at `c87a197`; `v0.1.0-alpha.5` remains the published baseline.
  This increment follows the direction §46 recorded (`kyn-build` target graphs),
  narrowed to the one item there that was a **correctness** problem rather than
  a missing feature.
- Swept first, and cleared: `sharedlib` targets produce a loadable `.so` whose
  exported symbol C can resolve and call (checked by linking a C program against
  it with `-rpath`), multiple targets in one build file, `--target` selection
  skipping the others, `--clean`, `--force`, and selective invalidation (edit
  one target's source, only that target rebuilds). Build-file errors exit 2 and
  compile failures exit 3.
- **Defect found and fixed:** editing a C header did not invalidate the target.
  The digest covered `c_sources` and `include_dirs` but never the headers those
  sources include, so `kyn-build` printed `up to date` and left the previous
  object linked — a build that reports success while the binary runs old code.
  `docs/build-system.md` listed this as a known limitation, but a stale binary is
  a correctness failure, not a performance trade-off, so it was fixed rather
  than restated.
- Design: `hashCIncludes` mirrors the existing `hashKynImports` — a `visited`
  set of resolved absolute paths for once-only traversal, a `\x00`-separated
  marker before each entry so `a.h`/`ab.h` cannot collide, and recursion into
  every newly seen header. Resolution matches the C compiler's search order for
  quoted includes: the including file's directory first, then the target's
  `include_dirs`. Only `"..."` is followed; an angle-bracket include names a
  system header, which belongs to the toolchain whose version is not part of the
  digest either. A header named only inside a `//` comment or a string literal is
  not followed, because `parseQuotedInclude` requires `#` as the first
  non-whitespace byte — the same rule the preprocessor applies.
- `parseQuotedInclude` accepts `#include` and `#  include` (the preprocessor
  accepts both) and rejects an empty name. A missing header is left to the
  compiler's diagnostic instead of being reported by the digest walk, so a build
  that would fail anyway does not fail earlier and differently.
- Files changed: `build-system/main.zig` (digest hook, `hashCIncludes`,
  `parseQuotedInclude`, `resolveInclude`), `tests/integration/run.sh` (new
  `transitive C header invalidates build cache` check: two-level quoted include,
  edit the inner header, expect a rebuild and the new value, then an idle run
  expecting `up to date`), docs (`build-system.md` §3.1 step and the limitation
  removed, `roadmap.md`, `README.md`, `CHANGELOG.md`).
- The new integration check was **proven to measure the fix**: reverting only
  `build-system/main.zig` (keeping the test) makes it FAIL, and restoring the fix
  makes it pass. That negative control is why the check is trusted.
- Validation from a clean cache: `zig build` OK; `zig build test` **100/100**
  (unchanged — the build tool has no unit-test harness of its own); integration
  **197/0** in Debug and ReleaseSafe (196 → 197); `zig fmt --check` clean; docs
  links 21; documented codes 131 (unchanged — no diagnostic was added);
  robustness corpus 902 clean; versions consistent at `0.1.0-alpha.5`.
  Adversarial include shapes were checked by hand: `#  include`, a commented-out
  directive, and an `#include` inside a string literal neither crash nor
  over-invalidate.
- Remaining known cache limitations, documented and unchanged: the Kyn
  compiler's own version is not in the digest (only its path); Zig's transitive
  imports are not hashed; builds are sequential; there is no dependency graph
  between targets.
- Git, final for this increment: implementation commit `dbe5f53` and record
  `1d2ff00` on `arena/a236b746-kyn`, pushed before the turn ended; PR #41 → CI
  green → merged as **`b3df054`**; `main` re-validated in a fresh clone of
  `b3df054` (100/100 unit, 197/0 integration).
- Not done, and not claimed: no sanitizer gate exists in this repo;
  `v0.1.0-alpha.5` release assets remain unattached (§38/§42); the Windows
  archive path was not re-exercised.
- Next task: the callee side of variadics (`va_list` + an exported variadic), or
  the still-unscheduled type-system decision on unions/bitfields/packed structs.
  Another `kyn-build` candidate is hashing Zig's transitive imports and folding
  the compiler's version into the digest — both are performance/correctness
  questions of a smaller order than the one fixed here.
- Contract kept: no test was modified to pass; the one existing assertion about
  headers was deleted from the docs because the behaviour now matches the
  stronger statement.

## 48. `bool` ↔ float casts, and constant-cast folding (on `arena/9aa72244-kyn`)

- Base: `main` at `99b6495`; `v0.1.0-alpha.5` remains the published baseline.
  §47's next-task note offered the callee side of variadics or the
  unions/bitfields/packed-structs decision. Both are design decisions that need
  a spec before code, so instead of opening one of them this increment did what
  §46 did and swept documented contracts against the real compiler first — which
  is what found the defects below.
- **Method: a differential sweep, not a single probe.** `language-reference.md`
  §5.7 lists the allowed cast pairs in a table. Rather than spot-checking, a
  harness generated **every** pair among `i8 u8 i16 u16 i32 u32 i64 u64 isize
  usize f32 f64 bool char` (182 ordered pairs), compiled each through
  `kync emit-obj`, and again with every initializer placed in a global
  (72 ordered pairs, a separate path). Exactly 4 of 182 failed — all of them
  `bool` ↔ float, in both widths — and 6 of 72 globals. Everything else
  compiled. The sweep is the reason the fix covers the whole class instead of
  the one pair that a first probe happened to hit.
- **Defect 1 — `float as bool` was accepted and then rejected.** `checkCast`
  allows `.float` → `.bool`, and the table documents it, but `backend.castKind`
  had no arm for it, so `lowerCast` fell through to
  `E0605 internal: unsupported cast from the semantic layer`. A documented cast
  that can never compile, reported as an internal error.
- **Defect 2 — `bool as f32` / `bool as f64` emitted invalid IR.** The
  `from.* == .bool` arm returned `.bool_to_int` unconditionally, which the
  emitter spells `zext i1 ... to <dest>`; `zext i1 %x to double` is not valid
  LLVM, so the module failed to assemble and nothing containing such a cast
  could be built. `kync check` accepted it, which is why a type-check-only sweep
  would have missed this.
- **Fix, backend only.** Two new `ir.CastKind` members:
  `float_to_bool` is `fcmp une <ty> %x, 0.0` — unordered-or-not-equal, so a NaN
  is **true**, which is C's `(_Bool)` conversion (an ordered compare would make
  a NaN false); `bool_to_float` is `zext i1 %x to i32` followed by
  `uitofp i32 ... to <float>`, because no floating conversion accepts an `i1`
  operand. The `i32` intermediate is spelled in the two instructions rather than
  added to the emitter's type table, since the emitter has no type arena and the
  value is exact either way. `castKind` gained a `from.isFloat()` arm under
  `to.* == .bool` and a `to.isFloat()` arm under `from.* == .bool`.
- **Defect 3 — a constant cast kept the source representation.** `lowerConst`'s
  `.cast` arm handled only `int` and `float` and ignored the destination
  category, so `const WIDE: f64 = 3 as f64` emitted `constant i32 3` (which LLVM
  rejects: "integer constant must have integer type") and `const FLAG: bool =
  1.5 as bool` emitted the float's bit pattern as an `i1`. The arm is now driven
  by the destination type: int→float is `@floatFromInt`, anything→`bool` is
  `!= 0` (a NaN included), `bool`→float is `0.0`/`1.0`, and the integer cases
  still truncate.
- **A mistake in the first version of that fix, caught by a chain probe.** The
  recursive call passed the outer destination type inward, so
  `3.9 as i32 as f64` folded the operand at `f64` and produced `3.9` instead of
  `3.0`. The recursion now passes `cast.operand.ty` — each step folds in its own
  type — and chains through ints, floats and `bool` were re-checked:
  `3.9 as i32 as f64` = 3.0, `0 as f64 as bool` = false,
  `true as f64 as i32` = 1, `300 as i32 as u8` = 44, `1000 as i16 as i8` = -24.
- **Runtime semantics checked, not assumed.** Before trusting the fix, the
  already-working directions were re-verified against real execution:
  `bool`→int is 0/1, int→`bool` is false only for zero (including negatives),
  float→int truncates toward zero for both signs. `-0.0 as bool` is false.
  NaN and infinity were produced **by C**, not by a Kyn constant fold, and
  linked across the boundary: NaN→true, inf→true, `0.0`→false. The C fixture
  keeps those values so the check is reproducible.
- Files changed: `compiler/backend/llvm.zig` (`castKind` arms, the two emitter
  cases, the destination-driven constant `.cast` arm, two new unit tests),
  `compiler/ir.zig` (two `CastKind` members), the
  `tests/integration/abi/cabi_bool_float_convert.{kyn,c,exit}` fixture, and docs
  (`language-reference.md` §5.7 semantics paragraph, `CHANGELOG.md`, `roadmap.md`,
  `README.md`).
- **Three stale documentation lines corrected in the same pass**, all describing
  shipped behaviour as absent: `language-reference.md` §5.6 said "indirect calls
  through function pointers are not supported yet" (§41 shipped them in
  alpha.5), `abi.md` said "variadic declarations are not supported yet" four
  lines above its own `### Variadic declarations` section that documents them
  (§40), and `diagnostics.md` still described `E0604` as "indirect call is not
  supported yet" when the code emits "callee has no function signature". These
  are not new work — they are the documented contract disagreeing with the
  compiler, which is the same class of defect as the one being fixed.
- Negative controls, run rather than assumed: reverting only the `castKind` arms
  makes the new unit test fail (`101 pass, 1 fail`) and makes the new fixture
  fail with `E0605`; restoring them makes both pass. Invalid casts were
  re-checked and are still rejected: slice→bool, struct→float, ptr→float,
  float→ptr, bool→ptr, bool→slice all report `E0447`, so no check was weakened.
- Validation from a clean cache: `zig build` OK; `zig build test` **102/102**
  (100 → 102); integration **198/0** in Debug and ReleaseSafe (197 → 198);
  `zig fmt --check` clean; docs links 21; documented codes 131; robustness
  corpus 902 clean; versions consistent at `0.1.0-alpha.5`.
- Limitations: numeric casts still insert no runtime range check in v0.1, which
  is documented and unchanged. `bool`→float is exact and lossless in both
  directions only because a `bool` is 0 or 1; there is no `f16`/`f128` in the
  type system, so those widths could not be swept. No sanitizer gate exists in
  this repo, so none ran.
- Next task: the callee side of variadics (`va_list` + an exported variadic) or
  the unions/bitfields/packed-structs decision — both need a written design
  before implementation. A future sweep could cover the remaining documented
  tables the same way: the operator table in §5.1 against precedence and
  associativity, and the local-declaration rules in §4.1.
- Contract kept: no test was modified to pass; the doc lines that were wrong
  about shipped features were corrected to match the compiler, not the compiler
  to match the doc.
- Git, final for this increment: implementation commit `4469484` and record
  `6d990bc` on `arena/9aa72244-kyn`, pushed before the turn ended; PR #43 → CI
  green → merged as **`fe9c964`**; `main` re-validated in a fresh clone of
  `fe9c964` (102/102 unit, 198/0 integration).
- The differential-sweep method used here was inexpensive and found three
  defects in a table that had been read but never exercised, so the two
  remaining documented tables are the cheapest next targets: the operator table
  in §5.1 against real precedence and associativity, and the local-declaration
  rules in §4.1.

## 49. Folded-constant signedness, and `E0420` deduplication (on `arena/9888b78f-kyn`)

- Base: `main` at `e34bda9`; `v0.1.0-alpha.5` remains the published baseline.
  §48 recorded two remaining documented tables worth sweeping and this
  increment was those sweeps: precedence/associativity (§5.1) and the
  local-declaration rules (§4.1).
- **Method: an independent oracle, in the style §48 established for casts.**
  The precedence table was transcribed into a Python precedence-climbing parser
  (left-associative means "recurse at prec+1", right means "at prec"), which
  computes the grouping the documentation promises. An expression that shares
  operators across levels is then evaluated twice: once by the oracle with exact
  integers, once by running the compiled Kyn program and reading its exit
  status. Any disagreement is a parser bug or a doc bug. 346 generated cases
  (every adjacent operator pair in both orders, same-level left associativity,
  comparisons against arithmetic, and 120 random three-operator chains) all
  agree after the fix; before it, 107 disagreed — all of them trapping.
- **Defect 1 — every folded `-` trapped.** `1 - 2 + 3` exits 132 (the overflow
  trap) while `a - b + c` over `i32` variables exits 2. The emitted instruction
  was `@llvm.usub.with.overflow.i64(i64 1, i64 2)`: an **unsigned** subtract of
  a negative result, which is an overflow. Root cause: a `comptime_int` carries
  no width or sign in the type system, and `Type.intInfo()` answers
  `bits = 0, signed = false` for it, so `Emitter`'s `checked_binary` arm fell to
  the `u` prefix. Everything that read `intInfo()` directly on a possibly-folded
  type had the same blind spot.
- **Defect 2 — a shift by a constant always trapped.** `3 | 1 << 2` exits 132
  for the same reason: `emitShiftBoundsCheck` compared the amount against
  `lhs_ty.intInfo().bits`, which is `0` for `comptime_int`, so any amount
  `>= 0` failed the bound. `1 << 2` alone worked only because the sema
  materializes a lone literal expression to `i32` first.
- **Fix: one helper, not two patches.** `loweredIntInfo(ty)` answers "how wide
  and how signed is this lowered" — `comptime_int` is `i64`/signed (which is
  what `typeString` already emits for it), `char` is 32-bit unsigned, an enum
  answers for its backing, and a non-integer is `null`. Both `checked_binary`'s
  sign choice and `emitShiftBoundsCheck` use it, so the two cannot drift. The
  four other `intInfo()` call sites (index bounds, division check, slice
  bounds, `castIntegerValue`) were probed rather than assumed: all four already
  behave correctly, because their operands are contextual or explicitly typed
  by the time they reach lowering, so they were **left alone** — the fix is
  placed where the defect is, not sprayed across every similar-looking line.
- **Defect 3 — a duplicated declaration check with two codes.** §4.1 documents
  "a local needs a type, an initializer, or both (`E0420`)", and `sema` has that
  check, but `parser.parseVarDecl` reported the same condition as `E0216` before
  the analyzer ever ran. `E0420` was therefore **unreachable**, and one rule had
  two documented codes in `diagnostics.md`. The parser now accepts both forms
  and the analyzer reports the documented `E0420`, which is where the rest of
  the declaration rules live. Verified the old behaviour produced exactly one
  diagnostic (`E0216`) and the new one exactly one (`E0420`).
- **A false negative in my own test, caught and fixed.** The first unit test
  asserted `E0420` was present; it passed even with the parser check restored,
  because `expectSemanticError` returns on the *first* matching diagnostic and
  the parser's `E0216` short-circuits compilation. A new `expectOnlyError`
  helper asserts the program fails with exactly that code and nothing else, and
  with it the negative control fails as it should (105 pass, 1 fail).
- Deliberately **not** changed, after checking each against the docs:
  `let x = 5` infers `i64` and assigning that to `i32` is `E0462`, which is
  exactly what `type-system.md` §2 says ("if no context exists, it materializes
  as `i64`") and what "there are no implicit promotions" means — my probe was
  wrong, not the compiler. `let x: i32 = 1 << 31 >> 31` gives 255 while
  `(1 << 31 >> 31) as i32` gives 1; both follow the documented contextual typing
  rule (the whole expression takes the expected type), so this stands.
- Files changed: `compiler/backend/llvm.zig` (`loweredIntInfo` plus its two call
  sites, two unit tests), `compiler/parser.zig` (duplicate check removed with a
  comment explaining where the rule lives), `compiler/sema.zig` (unit tests and
  the `expectOnlyError` helper), `tests/integration/cases/precedence.{kyn,exit}`
  (executes the table: tightness of `*` over `+`, left associativity, `<<`
  below `+`, `&`/`^`/`|` order, `<<` over `|`, signed intermediates on folded
  operands, a shift amount checked against the operand width), and docs
  (`language-reference.md` §4.1 clarifies inferred local types,
  `diagnostics.md` drops the duplicate `E0216`, `CHANGELOG.md`, `roadmap.md`,
  `README.md`).
- Negative controls, run rather than assumed: reverting `loweredIntInfo`'s
  `comptime_int` arm makes both new unit tests fail (102/104 at that point) and
  makes the integration case trap (132 instead of 42); restoring it makes all
  pass. Restoring the parser check fails the tightened `E0420` test (105/106).
  The two folded defects were **reproduced on a clean stashed tree** before any
  edit, so they are pre-existing, not introduced here.
- Validation from a clean cache: `zig build` OK; `zig build test` **106/106**
  (104 → 106); integration **199/0** in Debug and ReleaseSafe (198 → 199);
  `zig fmt --check` clean; docs links 21; documented codes **130** (131 → 130,
  the removed duplicate); robustness corpus 902 clean; versions consistent at
  `0.1.0-alpha.5`.
- Limitations: the precedence sweep compares *values*, so a grouping bug that
  happens to be value-preserving for the chosen operands would not show; the
  cases use operands chosen so each grouping changes the answer, and printing
  the tree for every case would be the stronger check. `comptime_int` is
  documented as `i64` at lowering time rather than being given a width in the
  type system; giving it one would be a larger type-system change and is not
  attempted here. No sanitizer gate exists in this repo, so none ran.
- Next task: the callee side of variadics (`va_list` + an exported variadic) or
  the unions/bitfields/packed-structs decision — both still need a written
  design before implementation. The sweep of §5.1/§4.1 is complete; the
  remaining tables that could be swept the same way are the cast table's
  interaction with slices (`isSliceCast`) and the constant-expression rules in
  §3.8 (then §3.5; the section numbers were renumbered in §55).
- Contract kept: no test was modified to pass; a probe that disagreed with the
  docs was investigated and the docs won (`let x = 5` → `i64`), and a
  behaviour that looked wrong in isolation (`1 << 31 >> 31`) was traced to a
  documented rule and left alone.
- Git, final for this increment: implementation commit `e3870b9` and record
  `063df54` on `arena/9888b78f-kyn`, pushed before the turn ended; PR #45 → CI
  green → merged as **`961ccbc`**; `main` re-validated in a fresh clone of
  `961ccbc` (106/106 unit, 199/0 integration).
- The precedence sweep found two defects in 107 of 346 cases, which makes the
  remaining unswept tables the cheapest next targets after the two design
  decisions: the slice half of the cast table (`isSliceCast`, §5.7) and the
  constant-expression rules in §3.8. The harness itself is throwaway (it lives
  in `/tmp` and is not in the repo), so a future sweep rewrites it from the
  same idea: derive the oracle from the documented table and compare against
  real execution.

## 50. Exhausting the documented tables: slices, constants, static checks (on `arena/785da054-kyn`)

- Base: `main` at `5e0bdaa`; `v0.1.0-alpha.5` remains the published baseline.
  §49 listed three remaining tables to sweep; this increment swept all three.
  Unlike §48/§49 it found **no behavioural defect** — the finding is that the
  documented contracts hold, plus one wrong diagnostic code in the docs.
- **Slice half of the cast table (§5.7).** Every documented row was probed
  through `emit-obj`: `*[N]T → []T`, `*[N]T → []const T`, `*const [N]T →
  []const T`, `[]T → []T`, `[]T → []const T`, `[]const T → []const T` all
  compile; `*const [N]T → []T`, `[]const T → []T`, element mismatches, the
  reverse `[]T → *[N]T` and slice→integer all report `E0447`. Runtime behaviour
  was checked too, not just compilation: a slice obtained from `*[4]i32` writes
  back into the original array, keeps its length, reads correctly through the
  const widening, and a `null` array pointer cast to a slice traps (132). A
  `[0]i32` probe was rejected with `E0424` — zero-length arrays do not exist —
  which is a correct rejection of my probe, not a defect.
- **Constant-expression rules (§3.8).** Every documented constant form compiles
  and evaluates correctly at runtime: literals, unary and binary folds, casts,
  enum variants, `array.len`, string literals, struct and array initializers,
  including nested aggregates and a `const` aggregate read into a mutable copy
  (the copy is a value). Every documented rejection fires: `E0412` for a call,
  address-of, dereference and non-enum value read in a global initializer, and
  `E0413` for a missing initializer. Mutability matches the docs — `let`/`const`
  globals reject assignment and field/element mutation with `E0442`, `var`
  globals accept both, and `var` global state persists across calls. Crossed
  the C boundary in both directions: C reads and writes an `export var`, and a
  Kyn function observes the write; `export let` lands in read-only storage
  (`R`) while `export var` lands in `D`.
- **Static checks (safety-model §2).** `E0501` was swept rule by rule: a
  declared-then-assigned local reads clean, a read before assignment diagnoses,
  both arms of an `if`/`else` are required, a loop body is assumed to maybe not
  run, function parameters count as initialized, and compound assignment both
  reads and initializes (`x += 1` on an uninitialized `x` is `E0501`). `E0502`
  (constant bounds, including a negative constant start), `E0503` (constant
  division by zero), `E0504` (constant shift out of range), `E0505` (constant
  overflow and unary negation), `E0506` (all five documented contexts plus the
  array-pointer-to-slice cast), `W0501` (after `return`, `break` and
  `continue`, with an empty statement skipped) and `W0502` (constant `if` and
  `while` conditions) all behave exactly as documented. The `E0506` limit — a
  `null` held in a variable is not proven — is documented as "from the
  expression text" and was verified to be exactly that: the inline form is
  rejected, the variable form compiles and traps at runtime.
- **Defect found: one wrong diagnostic code in the docs.** §3.8 said a
  non-constant global initializer is `E0419`; the compiler emits `E0412`, and
  `E0419` is the code for a *local of type `void`*, which does fire correctly
  for its own case. `diagnostics.md` already had both codes right, so only the
  language reference was wrong. Corrected in the reference rather than changing
  the compiler, because `E0412` is the more specific and already-documented code.
- Files changed: `docs/language-reference.md` (the `E0419` → `E0412`
  correction), `compiler/analyzer.zig` (three unit tests: the five documented
  `E0506` contexts, the "not proven through a variable" limit, and one `W0501`
  per terminator), docs (`CHANGELOG.md`, `roadmap.md`, `README.md`).
- Validation from a clean cache: `zig build` OK; `zig build test` **109/109**
  (106 → 109); integration **199/0** in Debug and ReleaseSafe (unchanged — this
  increment added no fixture, because the integration suite already covers these
  areas and a duplicate case would test the same path twice); `zig fmt --check`
  clean; docs links 21; documented codes 130 (unchanged); robustness corpus 902
  clean; versions consistent at `0.1.0-alpha.5`. Cross-compilation still emits
  the right `e_machine` for x86_64 and aarch64 after the changes.
- Negative controls, run rather than assumed: disabling the `W0501` emission
  fails the new terminator test and the pre-existing unreachable-statement test
  (107/109); disabling one `E0506` site fails the new context test and the
  pre-existing null-dereference test. A false alarm of my own is worth
  recording: a probe printed `E0501` but my `grep -m1` picked up an earlier
  `W0502`, which briefly looked like a missing diagnostic — the check was there.
- Limitations: this sweep, like §48/§49, compares observable behaviour, so a
  check that fires for the wrong *reason* while producing the right code would
  not be caught; the unit tests assert codes rather than spans or messages.
  `E0506` remains text-based by design. No sanitizer gate exists in this repo.
- Next task: the callee side of variadics (`va_list` + an exported variadic) or
  the unions/bitfields/packed-structs decision — both need a written design
  before implementation, and both are now the only substantial items left on the
  roadmap. The documented tables have been swept: §5.1, §4.1, §5.7 (both halves),
  §3.8 and safety-model §2. A future increment should write one of those designs
  rather than look for another table.
- Contract kept: no test was modified to pass; a probe that disagreed with the
  docs was investigated and, where the compiler was right, the probe was
  discarded (`let x = 5` → `i64`, `[0]i32`, the `grep -m1` false alarm), and
  where the docs were wrong the docs were corrected (`E0412`).
- Git, final for this increment: implementation commit `e8570aa` and record
  `d0ecb4a` on `arena/785da054-kyn`, pushed before the turn ended; PR #47 → CI
  green → merged as **`db81d81`**; `main` re-validated in a fresh clone of
  `db81d81` (109/109 unit, 199/0 integration).
- The documented tables are now swept: §5.1, §4.1, §5.7 (both halves), §3.8
  (then §3.5) and safety-model §2. The next increment should therefore **write a design** rather
  than look for another table; the two candidates are below. If a future session
  finds itself looking for a fifth table, that is the signal that the remaining
  work is the design work, not more sweeping.

## 51. Design for the callee side of variadics (on `arena/0eb15e2d-kyn`)

- Base: `main` at `e5520ee`; `v0.1.0-alpha.5` remains the published baseline.
  §50 closed with the instruction that the next increment should **write a
  design rather than look for another table**, and named two candidates. This is
  the first: receiving a C variable argument list.
- **What this increment is, and is not.** It is a specification:
  `docs/design-callee-variadics.md`. It is **not** an implementation, and
  nothing in the record claims otherwise. No compiler source file changed, which
  is why the unit and integration counts are unchanged (109/109, 199/0) — the
  only gates that could move are the documentation ones, and the links count
  moved from 21 to 22 with the new document.
- **Measure first, in the style §39 established.** The design rests on
  measurements taken on this repository's toolchain before any design text was
  written, because the whole shape of the feature depends on them:
  - `va_list` on this target is `[1 x %struct.__va_list_tag]` with
    `%struct.__va_list_tag = { i32, i32, ptr, ptr }` (24 bytes, 8-byte aligned),
    and the `llvm.va_start.p0`/`llvm.va_end.p0` intrinsics take a **pointer to
    it**, which is why the entry allocation is the array and not the tag;
  - `va_arg ptr %ap, <ty>` is a first-class instruction in this LLVM, so the
    older `llvm.va_arg` intrinsic (which was removed) is not needed and must not
    be emitted;
  - a prototype of the exact IR shape the design specifies was hand-written,
    assembled, linked against C and **executed**: three `i32` arguments → 42,
    **zero** arguments → 0, negative arguments correct, and a mixed `i32` then
    `f64` retrieval → 42.5 exact, which exercises both the general-purpose and
    the SSE register save areas.
  This is the same discipline as §39's `-target` experiment: the design does not
  assume the ABI, it reports what the target does.
- **The three questions the design had to answer**, none of which the language
  settled before:
  1. *What type is a retrieved argument?* Chosen: **`va_arg()` takes its type
     from context**, like an integer literal or a `null`. Two alternatives were
     considered and rejected in writing — turbofish (`va_arg::<i32>()`, which
     would add generic syntax for one builtin) and one builtin per type
     (`va_arg_i32()`, …), which is duplication of the type system in the
     standard surface. The chosen form needs **no new type-system machinery**,
     because the checker already has an expected type in every position where
     retrieval is meaningful; a `va_arg()` with no expected type is rejected
     rather than defaulted, because guessing `i32` would silently misread a
     `double`.
  2. *What is the state it advances?* Chosen: **no user-visible `va_list`.**
     `va_start`/`va_end` are implicit, emitted at entry and before each `return`
     (and on the trap path), so the programmer cannot mis-pair them and no
     ownership rule is invented for a type that exists nowhere else. The cost is
     stated in the design: a variadic body cannot forward its list, which is a
     separate later feature.
  3. *Which functions may be variadic?* Chosen: **`export` and `extern` only.**
     The current rule rejects every body, on the recorded ground that a Kyn
     function "has a fixed signature"; that ground disappears once a body can
     read the list. `E0474` is therefore **narrowed**, not relaxed: an internal
     `fn` stays rejected because all its callers are Kyn and could pass a fixed
     list, so its variadic tail would be provably never used.
- **A consequence that had to be designed, not discovered later.** The caller
  side already promotes `i8`/`i16`/`bool`/`enum` → `i32`, `u8`/`u16` → `u32`,
  `f32` → `f64`, `char` → `u32`. A callee retrieving `i8` would read the right
  bytes with the wrong width, so the retrieval types are restricted to the
  promoted ones and a narrow request is `E0479` with the promoted type named in
  the message. That rule is derived from `sema.promoteVariadic`, which was read
  in place rather than restated from memory.
- **Diagnostics allocated:** `E0478` (no concrete scalar type from context),
  `E0479` (retrieval type is not a promoted width), `E0480` (`va_arg` outside a
  variadic function), and the narrowed `E0474`. All three new codes were checked
  to be **unused** in the compiler and undocumented before being assigned, so
  none collides. `va_arg` was also verified to be an ordinary identifier today
  (a bare `va_arg()` currently reports `E0427 unknown identifier`), so the
  parser needs no new token.
- **Every factual claim in the document was verified against the code before the
  document was committed**, since a design that misstates the present is worse
  than none: `E0474` really does fire for `export` with a body today; `va_arg`
  is not reserved; `E0478`–`E0480` are free; a non-System V target still rejects
  an aggregate boundary with `E0473` while `x86_64` accepts the same program.
- **Scope deliberately excluded**, each with a reason in the document: a
  `va_list` parameter type and `v`-style forwarding, `va_copy`, retrieving an
  aggregate by value, and `va_arg` on non-System V targets (where `va_list` may
  not be the measured struct — the design requires gating by target rather than
  emitting the wrong shape, mirroring how aggregate boundaries are gated).
- **Honesty about what stays unchecked**, recorded for `safety-model.md` §3:
  arity and the retrieval type are not checked, cannot be checked from the
  callee side, and stay undefined exactly as in C. The language supplies the
  mechanism and the programmer owns the protocol — the same position it already
  takes on pointer provenance.
- Files changed: `docs/design-callee-variadics.md` (new, 10 sections including
  the implementation plan), `docs/abi.md` (the "`export` is likewise rejected"
  paragraph now says why, and points at the design), `docs/roadmap.md`,
  `README.md` (documentation table row). No compiler source file was touched.
- Validation: `zig build` OK; `zig build test` **109/109** and integration
  **199/0** in Debug and ReleaseSafe, both unchanged and expected to be — a
  documentation increment cannot move them, and running them is how that claim
  is checked rather than assumed; `zig fmt --check` clean; docs links **22**
  (21 → 22 with the new document); documented codes 130 (unchanged; the three
  new codes are allocated in the design, not yet emitted, so they are not added
  to `diagnostics.md` yet); versions consistent at `0.1.0-alpha.5`.
- **The hand-assembled prototype is not in the repository.** It was a scratch
  measurement in `/tmp`, deliberately not committed: it is not a test, it does
  not run in CI, and committing IR that no build produces would suggest
  coverage that does not exist. The design records its exact results so the
  measurement can be repeated, and step 5 of the plan replaces it with a real
  fixture once the compiler emits the IR itself.
- Limitations: this is a design with no implementation, so nothing here is
  usable from Kyn source today. The measurements cover `x86_64` Linux only,
  which is the only target the existing aggregate ABI supports. The design does
  not specify `va_arg` for a target whose `va_list` differs; it requires one to
  be gated, which is a constraint on future work rather than a decision about
  it. No sanitizer gate exists in this repo.
- Next task: **implement the design**, in the order of its §10 — AST builtin
  expression, checker diagnostics, IR instruction set, backend emission, then
  the C-interop fixture that C calls with three / zero / negative / `f64`
  arguments. The second candidate, unions/bitfields/packed structs, remains
  undesigned and is the natural follow-on once this one is code.
- Contract kept: no test was modified; no compiler behaviour was changed to fit
  the document; every claim about current behaviour in the document was checked
  against the compiler rather than inferred from the older prose, and one piece
  of older prose (`abi.md`'s flat "`export` is likewise rejected") was corrected
  to say *why* it is rejected today and where the design goes.
- Git, final for this increment: design commit `4b8f4a0` and record `ffc0431` on
  `arena/0eb15e2d-kyn`, pushed before the turn ended; PR #49 → CI green →
  merged as **`e0170ed`**; `main` re-validated in a fresh clone of `e0170ed`
  (109/109 unit, 199/0 integration, 22 documentation links).
- The design is now the specification the next increment implements; its §10
  gives the order, and step 4 (backend emission) cannot land without step 5's
  C-interop fixture, which is the rule this project has followed for every ABI
  change. The unions/bitfields/packed-structs decision remains undesigned.

## 52. Callee variadics implemented (on `arena/d757f468-kyn`)

- Base: `main` at `e1de4b3`; `v0.1.0-alpha.5` remains the published baseline.
  §51 closed with a design and the instruction to **implement it in the order of
  its §10**. This increment does exactly that, in one pass.
- **What landed, step by step (design §10).** (1) `ast.Expr.Kind.va_arg` with a
  `ty: ?*Type` field, produced by the parser when a call's callee is the bare
  identifier `va_arg` with no arguments — no token is reserved, and `args` is
  never allocated for it. (2) `E0480` (no variadic enclosing function), `E0478`
  (no expected type, or an expected type that cannot travel through `...`),
  `E0479` (a width the caller promoted away); `E0474` narrowed in **both** places
  it is emitted — the parser's body rejection and the checker's signature check.
  (3) Three `ir.Inst` members: `va_start`, `va_arg { dst, ty }`, `va_end`. (4)
  Backend: `%struct.__va_list_tag` + `%kyn.va_list` + the two intrinsic
  declarations emitted from a `hasVariadicBody()` flag; `alloca %kyn.va_list,
  align 16` in `entry`; `va_arg ptr %vN, <ty>` per retrieval. (5) Tests and the
  C-interop fixture.
- **Verified against the measured ABI from §51, not from memory.** The emitted
  module matches the hand-written prototype that executed in §51: the
  intrinsics take a pointer to the **array**, not the tag; each retrieval is a
  first-class `va_arg` instruction, never `llvm.va_arg` (removed from LLVM); a
  module with no variadic body contains none of the four new declarations.
- **Three places the implementation differs from the design sketch**, recorded
  in the design document itself: `va_end` is attached to the single `emit` hook
  (covering explicit `return`, implicit end of a `void` function **and** the
  trap path in one place) rather than to each `return` site; a variadic
  *definition* must carry the `...` marker in the `define` line, because without
  it the function is not varargs and the LLVM verifier rejects `llvm.va_start`
  outright; and function values are `.fn_ptr` in the type union, so both
  `.fn_type` and `.fn_ptr` are accepted retrieval types.
- **Gate (all from a cold `.zig-cache`):** `zig build`; `zig fmt --check` clean;
  unit **120/120** (was 109: 6 sema, 2 parser, 2 backend, plus the existing
  counts unchanged); integration **202/0** in Debug **and** ReleaseSafe (was
  199/0: `cabi_variadic_callee` plus two new error fixtures —
  `variadic_retrieve_narrow` `E0479`, `variadic_arg_outside` `E0480`); the old
  `variadic_export` fixture asserted that exporting a variadic fails, which this
  increment makes false, so it was **repurposed** to `E0478` (a legal export
  whose body retrieves without a context type) rather than deleted; robustness
  corpus 902 cases clean; documentation links 22; documented diagnostic codes
  **133** (was 130: `E0478`–`E0480` are now real and documented); versions
  `0.1.0-alpha.5`.
- **Behaviour confirmed by execution, not only by IR inspection.** The fixture
  is called from C with three arguments (42), zero arguments (0), negative
  values (−2), `i64` values beyond 32 bits (1000000000005), three `f64`s (7.0),
  a mixed `i32`+`f64` list (42.5) and a retrieved function value invoked
  afterwards (21), and exits 63 under both profiles through the
  `cabi_variadic_callee.exit` oracle. The fixture bodies are never called
  directly from Kyn: `main` only calls C, which owns the argument lists.
- **One real portability defect, found by CI and not by the local gate.** The
  first CI run failed only `cabi_variadic_callee`, with
  `undefined reference to 'llvm.va_start.p0'`. The cause was the design's own
  spelling: `.p0`-suffixed intrinsic names exist from **LLVM 19** on, and the
  CI image installs LLVM 18, while this sandbox's clang is 22 — so the local
  gate could never have caught it. The fix is the suffix-free spelling
  (`llvm.va_start`, `llvm.va_end`), which is the same intrinsic in every
  version Kyn targets; it was verified end to end on LLVM 22 here and on
  LLVM 18 in CI. Because the job log is not retrievable from this sandbox, the
  workflow now reports a failing integration case **and its indented reason** as
  annotations, which is how the message was obtained at all.
- **A pre-existing defect found while testing, deliberately not fixed here.**
  Signed `i128` division panics the *compiler* in the checked profile
  (`emitDivisionByZeroTrap` computes `-(1 << 127)` in an `i128`), independent of
  variadics. It reproduces on `main` with `var a: i128 = 1000; const q = a / 7;`.
  It is out of scope for this increment and is recorded as the next candidate
  rather than bundled in, which would make one increment two unrelated changes.
- **Contract kept:** no existing behaviour was changed except the one the design
  specified (`E0474` narrowing); non-variadic modules emit identical IR, which is
  asserted by a unit test rather than assumed; every diagnostic is reachable
  from a real program and covered by a test at the level where it is emitted.
- Git, final for this increment: `8621823` (implementation) plus three CI
  commits on `arena/d757f468-kyn`, pushed before the turn ended; PR #51 → CI
  green on the fourth run → merged as **`00837d5`**. The three earlier runs failed
  only on the `.p0` intrinsic spelling described above; the workflow change that
  made the reason visible is part of the merge. `main` was then re-validated in a
  fresh clone of `00837d5`: `zig build` clean, unit **120/120**, integration
  **202/0**, `zig fmt --check` clean, 22 documentation links, 133 documented
  codes, versions `0.1.0-alpha.5`.
- Next task: fix the `i128` division panic (small, isolated, with a regression
  test per width and signedness), or take the remaining undesigned candidate
  (unions/bitfields/packed structs). Forwarding a variadic list (`v`-style) stays
  out of scope: it needs a `va_list` parameter type, which is a language handle
  Kyn has no other use for.

## 53. Signed division at the widest minimum (on `arena/eb0df533-kyn`)

- Base: `main` at `c15a185`; `v0.1.0-alpha.5` remains the published baseline.
  §52 closed by naming this defect explicitly — found while testing callee
  variadics, deliberately not bundled in — so this increment fixes exactly it.
- **The defect.** `emitDivisionByZeroTrap` computed the `INT_MIN / -1` guard's
  bound as `-(@as(i128, 1) << @intCast(info.bits - 1))`, which overflows for a
  128-bit type: **any** `i128` division panicked the compiler in the checked
  profile. The check exists to trap that quotient at run time, so the fix was one
  line: take the value from `IntInfo.min()`, the helper that already special-cased
  128 bits for exactly this reason. Verified for `i8`/`i16`/`i32`/`i64`/`i128`
  and for all four profiles.
- **A second defect in the same family, found while validating the first.** The
  most negative literal of a signed type reached the IR as a checked
  `0 - magnitude`, so `let m: i128 = -170141183460469231731687303715884105728;`
  trapped at run time *in a checked build* even though the checker accepts that
  spelling on purpose (`IntInfo.minMagnitude`). Negating an integer *literal* now
  folds to the value the type denotes. My first attempt returned the `i128`
  minimum for every width, which the integration check caught immediately
  (`-128` became `-2^127`); the fixed form returns the magnitude's negation and
  special-cases only the widest type, which is the only one whose magnitude has
  no positive counterpart.
- **Scope discipline.** Two audit passes confirmed no other site shares the
  pattern: `truncateInt` and the constant cast evaluator both return early at 128
  bits, and `types.zig` min/max already used the unsigned domain. The change is
  the two lowering sites plus tests; no diagnostic, no language surface, no ABI
  moved.
- **Gate:** unit **122/122** (was 120: two backend tests, one per behaviour, both
  asserting the emitted IR rather than the absence of a panic); integration
  **204/0** (was 202: `division_minimum_widths` asserting exact halving at five
  widths and exiting 10, and `runtime_division_i128_min` expecting the trap,
  exit 132); `zig fmt --check` clean; 22 documentation links; 133 documented
  codes; versions `0.1.0-alpha.5`.
- Git, final for this increment: `1240b1a` (the fix) plus `3fc1343` removing a
  stray `kync run` binary that the first commit had picked up, pushed before the
  turn ended; PR #53 → CI green → merged as **`5b2e2e5`**, and `main` re-validated
  in a fresh clone of it (122/122 unit, 204/0 integration, fmt clean, 22 links,
  133 codes, no stray artifact in the tree).
- Lesson re-learned, worth keeping: `kync run <file>` names its binary after the
  file stem **and writes it to the working directory**, so `git add -A` after a
  run can sweep it into a commit. Build to `/tmp` with `-o` instead.
- Next task: the remaining undesigned candidate (unions/bitfields/packed structs)
  or a documented-table sweep; forwarding a variadic list stays out of scope.

## 54. Design for unions, bitfields and packed structs (on `arena/6a7eb579-kyn`)

- Base: `main` at `e04501a`; `v0.1.0-alpha.5` remains the published baseline.
  §53 closed by naming the undesigned candidate, and §50's rule was that the next
  substantial increment should **write a design rather than look for another
  table**. This is that design: `docs/design-unions-bitfields-packed.md`, 12
  sections, covering all three features in one document because they perturb the
  same four places.
- **This is a specification, not an implementation.** No compiler source file
  changed. Unit and integration counts are therefore unchanged (122/122,
  204/0); the only gate that moved is the documentation link count, 22 → 23.
  The four diagnostic codes it allocates (`E0481`–`E0484`) are intentionally
  **not** in `diagnostics.md`, because that file is checked against the compiler
  sources and a code no program can produce does not belong there yet (the same
  rule §51 followed).
- **Measure first, then write.** Eight declarations were compiled and executed
  with the project toolchain before any rule was written, and the measured
  numbers are in the document: unions are `size/align` of their largest member
  and classify exactly as the struct of their members (`union U{char;int;double}`
  → `i64` in one register, `union Small{char}` → `i8`, `union Big{double[3]}` →
  `sret`/`byval`); a packed struct is `size=5, align=1` and forces
  `sret`/`byval` even when small; bitfield runs share a storage unit
  (`{k:3;t:5}` → 4 bytes, `{a:20;b:20}` → 8, `{a:4;b:6}` over `unsigned char`
  → 2); and the claimed C-compatible bitfield subset
  (`{unsigned a:3; b:5; c:12}`) is one `i32` that passes as `i32`.
- **The design was re-checked after being written, and that changed it twice.**
  The first draft asserted that a non-bitfield member *ends* a bitfield run;
  `struct Mix { unsigned a:3; char c; unsigned b:5; }` measures **4 bytes**, not
  8, so the rule was replaced with the layered statement now in §4.1 and pinned
  by six measured declarations. The `E0482` description was also corrected from
  a "packed context" rule that does not exist to what the check can actually
  see (a zero width, or a width with no storage unit). Both corrections are
  recorded in the document's §11, not just here.
- **Every claim about current behaviour was verified in this tree:**
  `union U { … }` is `E0204`, `packed struct` is not a production, `a: u3` is
  `E0422`, `E0481`–`E0484` are unused, `E0403` covers structs only, `IntInfo`
  already carries an arbitrary `bits: u16` (so `u5` needs no new type
  machinery), `memberBoundaryBits` already maps a sub-32-bit member to its
  transport width, and `collectAggregateLeaves` already takes an explicit
  `base_offset` (so unions need no new leaf walk).
- **Three decisions worth carrying forward:** (1) bitfield width lives in the
  **type** as `uN`/`iN`, not in C's colon syntax, because `IntInfo` already holds
  a width and a colon would attach storage to a declaration that the type system
  cannot see; (2) a union has **no tag** — a tag would be a sum type, which is a
  separate unscheduled feature; (3) `packed` is one modifier meaning "no padding,
  align 1", with **`align(N)` deliberately excluded** from this increment
  because the two interact (the larger alignment wins) and deserve their own
  rules and diagnostics.
- **The only genuinely new algorithm** is the bitfield storage-unit rule. C
  leaves bitfield layout implementation-defined, so the design does not claim C
  compatibility in general: it specifies a total, deterministic rule, claims a
  measured C-compatible subset (adjacent, ≤32 bits, one signedness), and puts
  the rest behind a documented rule with a fixture that pins it. That is the
  honest version of the feature and the reason the document says so twice.
- Gate: `zig build` OK; 122/122 unit; 204/0 integration; `zig fmt --check` clean;
  23 documentation links (22 → 23); 133 documented codes (unchanged);
  versions `0.1.0-alpha.5`.
- Git, final for this increment: `d472f88` on `arena/6a7eb579-kyn`, pushed
  before the turn ended; PR #55 → CI green → merged as **`4e3973f`**, and `main`
  re-validated in a fresh clone of it (122/122 unit, 204/0 integration, 23
  documentation links, 133 documented codes, both design documents present).
- Next task: **implement this design in the order of its §10** — type model
  (`is_union`/`is_packed`, layout branches), parser and resolver (`union`,
  `packed`, `uN` widths, `E0481`–`E0484`), leaf walk and classifier (union
  members at offset 0, bitfield runs as one storage-unit leaf, packed forced to
  memory), backend (packed `<{ }>`, `byval`/`sret` alignment, mask-and-shift bit
  access), then the three ABI fixtures and the documentation pass. Step 4 cannot
  land without step 5, as with every ABI change here.

## 55. Unions and packed structs implemented (on `arena/4ba95935-kyn`)

- Base: `main` at `bb19a1b`; `v0.1.0-alpha.5` remains the published baseline.
  §54 wrote the design for the three aggregate extensions; this increment
  implements **two of them end to end** and leaves bitfields, whose storage-unit
  packing is the one genuinely new algorithm and needs the `uN`/`iN` width types
  first.
- **What landed, in the design's §10 order.** (1) `StructInfo.is_union` /
  `is_packed`, the union branch of `aggregateLayoutGuess` (all members at offset
  0, size and alignment as maxima) and the packed branch (no per-member
  alignment, alignment 1). (2) `union` as a declaration and `packed` as a
  modifier before `struct`/`union`, `E0484` for a `packed` that is not followed
  by an aggregate, `E0485` for a union initializer that does not name exactly one
  member, and the `E0403`/`E0404` messages now say "union" when the aggregate is
  one (a new `aggregateLabel` helper, not a second code). (3) Union members are
  walked at the base offset and a packed aggregate is forced to `.memory` in the
  classifier. (4) The backend emits packed definitions as `<{ ... }>` and a union
  as a struct holding its most aligned member, with `field_ptr` mapping every
  union member to index 0 **in the emitter** so no producer knows the
  representation. (5) Two ABI fixtures, three error fixtures, five unit tests and
  one parser pair.
- **`E0481` from the design was not needed and was not allocated.** The existing
  `E0403` recursion check already covers a union because it walks the same field
  list; adding a second code would have been a synonym. The design's §10 now
  records this rather than leaving a code reserved that no program can reach.
- **A genuine correctness simplification.** `sizeInBytes` re-derived struct and
  array layout in the backend while `aggregateLayoutGuess` derived it in sema.
  With union and packed rules that would have been two copies of the same rules,
  so the backend now delegates to the one implementation. This is not a
  refactor for its own sake: it removed a place where the two could disagree.
- **A pre-existing defect found while testing the feature, and fixed.** An
  aggregate field could only be initialized from a *literal*; `Wrap { inner: i }`
  with `i` a variable, or `Wrap { arr: a }` with an array, failed with
  `E0606: internal: expected an aggregate initializer`. Verified on a fresh clone
  of `main` before being touched, so it is pre-existing and independent of
  unions — but a union's natural use (`U { inner: existing }`) reaches it
  immediately. The fallback now copies the value byte-wise, the same move the ABI
  uses for a by-memory aggregate. Fixture `aggregate_from_value`.
- **One source-compatibility consequence, handled deliberately.** `packed`
  became a keyword, which broke a local named `packed` in the existing
  `cabi_array_members` fixture. The binding was renamed (the value it holds is
  unchanged) rather than weakening the keyword: the design decides `packed` is a
  modifier, and reserving a word is exactly what a modifier does. The single
  occurrence in the tree confirms the cost is negligible.
- **Section numbering repaired.** `language-reference.md` §3 had two
  pre-existing duplicate numbers (§3.3 and §3.5). Adding two sections made that
  worse, so the sequence was renumbered 3.1–3.8 and the three references in this
  record that pointed at the old §3.5 (constant-expression rules) now point at
  §3.8.
- **Gate:** unit **131/131** (was 122: five sema, two parser, one backend); integration
  **210/0** in Debug **and** ReleaseSafe (was 204: `cabi_union_packed`,
  `cabi_union_packed_layout`, `aggregate_from_value`, and three error
  fixtures); `zig fmt --check` clean; 902 robustness cases clean; 23
  documentation links; **135** documented codes (was 133: `E0484`, `E0485`);
  versions `0.1.0-alpha.5`.
- **Validated by execution, not only by IR inspection:** the C harness calls the
  Kyn exports with a union by value (8-byte, `i64` class), a packed struct by
  value (`byval`, `align 1`), a union nested in a struct, and receives a union
  *returned* from Kyn; and a second fixture reads the layout back through Kyn's
  own field access at bytes 1 and 4 of a packed struct and byte 8 of a nested
  union, which is what proves the layouts agree rather than that they are both
  self-consistent.
- **Limitations, stated rather than implied:** bitfields are not implemented (no
  `u3` width type, no `uN` packing, `E0482`/`E0483` unallocated); `align(N)` is
  not implemented; a union has no tag, so reading a non-live member is undefined
  behaviour and is recorded in `safety-model.md` §3; the packed layout and its
  ABI are specified for `x86_64` Linux only, like the rest of the aggregate ABI.
- Git, final for this increment: `a17047c` on `arena/4ba95935-kyn`, pushed before
  the turn ended; PR #57 → CI green → merged as **`f690e98`**, and `main`
  re-validated in a fresh clone of it (131/131 unit, 210/0 integration, fmt
  clean, 23 documentation links, 135 documented codes, both union fixtures
  present).
- Next task: the bitfield half — `uN`/`iN` width types, the storage-unit run rule
  of design §4.1 (`E0482`/`E0483`), a bitfield run as one leaf of the storage
  unit's width in the classifier, and mask-and-shift access in the backend — then
  `align(N)` as a fourth flag.

## 56. Bitfields implemented (on `arena/b79eca8b-kyn`)

- Base: `main` at `f690e98` (which carries §55). This increment completes the
  third aggregate extension from `docs/design-unions-bitfields-packed.md`: the
  width lives in the type, an adjacent run packs into one storage unit, and the
  backend reads and writes it with shifts and masks. `align(N)` stays out of scope
  and is not claimed anywhere.
- **The design was wrong in two places, and measurement caught both.** §4.1 said
  the layout picks "the smallest unit that holds the field's width", citing
  `Mix` = 4 bytes. Measured: `Mix` is 4 only because its declared type is
  `unsigned`; the same shape with `unsigned char` members is **3** bytes. The rule
  also implied a growing run takes a wider *common* unit, which would put `c` at
  bit 8 in `{u3, u5, u12}`; byte-level measurement (`ff 00 ff 0f`) puts it at bit
  **16**, because a field never straddles a boundary of its own width. §4.1 now
  carries the cursor rule and the byte measurements that fix it, labelled as a
  correction.
- **The C-compatible subset was narrowed, not widened.** §4.2 claimed "widths
  summing to at most 32 bits". That holds only for C's `unsigned a:3`, whose unit
  is 4 bytes; a bare width's unit is 1 byte for `{u3, u5}`, measured as C's
  `unsigned char` form. The subset is now widths summing to at most 8 bits with no
  non-bitfield member, and the fixture compares **bytes**, not sizes — because
  `{u3, u5, u12}` agrees with C on size (4/2) while disagreeing on contents, which
  is exactly the agreement a size-only fixture would have reported as success.
- **One shape is refused rather than guessed.** `{a: u31, b: u33}` needs an
  8-byte unit beginning at byte 3, inside bytes the first unit already owns. C
  fuses the runs into one 8-byte unit; Kyn does not implement that rule and emits
  `E0489` instead of a type that disagrees with its own layout. Stated in
  `abi.md` §11, `language-reference.md` §3.7 and `safety-model.md` §3.
- **One layout walk, not two.** An earlier draft had `placeFields` computing
  positions while `aggregateLayoutGuess` computed sizes — the exact split that lets
  a bitfield's size and its bit offset drift apart. There is now one cursor walk
  that produces both, stores them on the `StructInfo`, and is the only thing the
  emitter, the classifier and `field_ptr` read. `sizeInBytes` already delegated to
  it from §55.
- **The emitted type is built from units, not fields.** A run collapses into one
  integer and a gap becomes an explicit `[N x i8]` padding member, so LLVM's own
  layout reproduces the byte positions the cursor computed. Emitting one member
  per source field gave every bitfield its own byte and made the IR disagree with
  `aggregateLayoutGuess` — found by dumping `%struct = type` for `{u3, u5}` and
  seeing `{ i3, i5 }`.
- **Three defects found by testing the edge cases, all fixed:**
  (1) a by-value recursive struct crashed in `placeFields` because placement ran
  before the recursion check and walked the unfinished member — placement is now
  skipped for a declaration that failed, tracked with a per-declaration flag so an
  unrelated error elsewhere in the file cannot suppress a valid type's layout;
  (2) `aggregateLayoutGuess` did not know `fn_type`/`fn_ptr`, so a struct of
  function pointers reported `E0488` and broke `function_pointers` and
  `cabi_function_pointer`;
  (3) `emitConstant` emitted one initializer per declared field while the type has
  emitted members, so a global aggregate failed to assemble — it now emits by
  emitted member, shifting and masking bitfield values and zeroing padding.
- **Gate:** unit **134/134** (was 132), integration **217/0** in Debug and
  ReleaseSafe (was 210: `cabi_bitfields`, `bitfield_wide_units`,
  `bitfield_semantics`, and four error fixtures), 902 robustness cases, `zig fmt`
  clean, 23 documentation links, **139** documented codes (`E0486`–`E0489`),
  versions `0.1.0-alpha.5`.
- **Unallocated on purpose:** `E0481`–`E0483` from the design's §10 step list were
  never used. The bitfield cases needed three different diagnostics, and reserving
  numbers before the checks existed would have been a guess;
  `check_diagnostic_docs.py` enforces that `diagnostics.md` lists exactly what the
  compiler can emit.
- Git, final for this increment: `930e54f` on `arena/b79eca8b-kyn`, pushed before
  the turn ended; PR #59 → CI green → merged as **`eef6c24`**, and `main`
  re-validated in a fresh clone of it (134/134 unit, 217/0 integration, fmt clean,
  23 documentation links, 139 documented codes).
- Next task: `align(N)`, the one idea of the design still unimplemented — a fourth
  flag beside `is_union`/`is_packed` that overrides an aggregate's alignment, with
  the same treatment: measure clang's `_Alignas`, state the rule, refuse what the
  emitted type cannot mirror.

## 57. Explicit alignment — `align(N)`

- **Scope.** §57 built the last idea of
  [design-unions-bitfields-packed.md](design-unions-bitfields-packed.md) §7:
  `align(N)` on a `struct`/`union` declaration, as the design predicted — a fourth
  flag, not a redesign. The three prior increments (unions, packed, bitfields)
  were not touched; the alignment paths are additive.
- **Measured before stating the rule, and the design's sentence was wrong on one
  point.** §7 said "`align` increases, `packed` decreases, so the maximum wins".
  Measured with `zig cc` (`.scratch/al.c`, deleted before the commit):
  `aligned(16)` on `{char}` is 16/16; **`aligned(2)` on a 4-aligned struct is
  ignored, not an error** (8/4 and unchanged); **`packed, aligned(4)` on
  `{char,int}` is 8/4** with `i` still at byte 1 — the two *compose*, so the
  maximum wins on alignment while packing still decides the offsets, and the size
  is rounded up to the alignment. "Maximum wins" alone would have suggested packing
  was cancelled. §7 now states the corrected rule, the table, and both
  corrections.
- **The chosen surface is narrower than the design's.** The design allowed
  `align(N)` on a field as well as a type. The language has **type-level only**: a
  field's alignment is its type's, and a field needing more is a field of an
  aligned type. One rule instead of two. `align` is not a keyword — recognised only
  as an identifier immediately followed by `(` in declaration position, so
  `fn align(x: i32) i32` still works.
- **Emission needed more than a number.** LLVM derives a struct's alignment from
  its members, so annotating the layout is not enough: the emitted definition takes
  a trailing `[k x i8]` member that brings its size up to a multiple of the
  alignment. For the ordinary cases this is text-identical to clang
  (`align(16) {u8}` → `{ i8, [15 x i8] }`). For `packed`+`align(N)` clang writes
  `<{ i8, i32 }>` and relies on `align 4` at the *use* site; an emitted *type* has
  no such slot, so Kyn writes `<{ i8, i32, [3 x i8] }>`. Both measure 8/4.
  §7.2 records the difference rather than hiding it.
- **A second layout implementation was deleted, not extended.**
  `llvmAlignmentOfType` computed a struct's alignment as the maximum over its
  fields, which ignores `packed` and `align(N)` — so an alloca or a `byval` of a
  packed aggregate was annotated with an alignment its layout does not have. It now
  calls `aggregateLayoutGuess`. This was a latent defect from §55 that only became
  observable once an alignment could exceed every field's.
- **Two emitter bugs were found by the extreme cases, not by the fixtures I first
  wrote.** (1) A *global* of an aligned type emitted a constant with the wrong
  number of elements, because the trailing padding member had no initializer — the
  LLVM parser rejected it, so this was a compile failure, not a wrong layout.
  (2) A *union* took no padding at all, so `align(16) union { char; int }` came out
  4 bytes instead of 16 and would have silently disagreed with C. Both are now
  asserted in `cases/align_layout` (checks 7 and 8).
- **Diagnostics:** `E0490` (non-integer inside `align(`), `E0491` (not a power of
  two, or > 4096), `E0492` (`align(N)` not before a `struct`/`union`). There is
  **deliberately no** diagnostic for an alignment below the natural one: C ignores
  it and so does Kyn, and rejecting it would refuse a well-defined declaration.
  `align(0)` is `E0491`.
- **Fixtures.** `cases/align_layout.kyn` (exit 8) pins the measured numbers, a
  nested aligned aggregate, a union, and a global; `abi/cabi_align.{kyn,c,exit}`
  (exit 30) has the C side print `sizeof`/`_Alignof` for the same shapes and checks
  at run time that a Kyn local is really 16-byte aligned, not merely typed as one;
  `errors/align_not_power_of_two`, `align_too_large`, `align_not_aggregate` pin the
  three diagnostics.
- **Stated limitation:** an `align(N)` aggregate passed **by value** to C is still
  refused by `E0473`, because the classifier does not take the explicit alignment
  into account. `abi.md` §10 and `safety-model.md` §3 say so; nothing is emitted
  that would disagree.
- **Gate:** unit **135/135** (was 134), integration **222/0** in Debug and
  ReleaseSafe (was 217: five new fixtures), 902 robustness cases, `zig fmt` clean,
  23 documentation links, **142** documented codes (was 139), versions
  `0.1.0-alpha.5`.
- Git, final for this increment: `dad99f2` on `arena/bd943679-kyn`, pushed;
  PR #61 → CI green → merged as **`fc3206c`**, and `main` re-validated in a fresh
  clone of it (135/135 unit, 222/0 integration, fmt clean).
- Next task: none of the four aggregate extensions remains unimplemented. The
  natural follow-ups are the ones the design lists as out of scope (§8): anonymous
  members, tagged unions, and taking `align(N)` into the ABI classifier so that an
  aligned aggregate can cross the boundary by value instead of being refused.
