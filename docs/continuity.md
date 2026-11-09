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

## 2. Validated completed components

| Component | Primary files | Validation |
| --------- | ------------- | ---------- |
| Source buffer, byte spans, line/col lookup & structured diagnostics (`E01xx`–`E06xx`, `W05xx`) | `compiler/source.zig`, `compiler/diagnostics.zig`, `docs/diagnostics.md` | `zig build test`, `check_diagnostic_docs.py` |
| UTF-8 lexer (keywords, hex/dec/float/char/string literals, nested `/* */` comments) | `compiler/token.zig`, `compiler/lexer.zig` | `zig build test`, `robustness.py` |
| Recursive-descent + precedence-climbing parser with error recovery and open-ended/bounded slicing | `compiler/ast.zig`, `compiler/parser.zig`, `docs/grammar.ebnf` | `zig build test`, `tests/integration/errors/*`, `robustness.py` |
| 3-phase semantic resolver & type checker (`Sema`), const-eval, lvalue/mutability, const-polymorphic slicing, `[]T -> []const T`, `.ptr`/`.len` | `compiler/symbol.zig`, `compiler/types.zig`, `compiler/sema.zig` | `zig build test`, `tests/integration/cases/*`, `tests/integration/errors/*` |
| Flow-sensitive static analyzer (`E0501`–`E0506`, `W0501`–`W0502`), including constant slice range bounds and provable null slice sources | `compiler/analyzer.zig` | `zig build test`, `tests/integration/errors/*` |
| Typed CFG IR + textual LLVM IR backend, runtime safety traps (`llvm.trap`), zero-branch `base[..]` fast path, pointer arithmetic, internal & `x86_64` Linux C ABI aggregate/slice lowering | `compiler/ir.zig`, `compiler/backend/llvm.zig` | `zig build test`, `tests/integration/cases/*`, `tests/integration/abi/*` |
| Compiler CLI (`check`, `emit-llvm`, `emit-obj`, `build`, `run`) and profile driver (`debug`, `safe`, `release`, `fast`) | `compiler/main.zig`, `compiler/driver.zig` | `tests/integration/run.sh` |
| Declarative hybrid Kyn/C/Zig builder with SHA-256 stamp caching | `build-system/main.zig`, `examples/hybrid/` | `zig build test`, `tests/integration/run.sh` |

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
- **Single-unit compilation (`compiler/driver.zig`, `compiler/sema.zig`):**
  - *Implemented & validated:* Single `.kyn` translation unit per `kync`
    invocation; multi-language linking with C and Zig via `kyn-build`.
  - *Not yet implemented:* Multi-file `.kyn` `import`/module resolution.

## 4. Pending items (ordered by technical dependency)

1. **Multi-file Kyn module system & explicit imports** (`import`, deterministic
   file resolution, cycle detection, module-qualified symbol lookup, and
   `kyn-build` dependency tracking across `.kyn` files).
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
     profiles, C ABI tests, and `examples/hybrid` incremental rebuild).

## 6. Core structures & module interfaces

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

- **Compiler:** `compiler/ast.zig`, `compiler/parser.zig`, `compiler/sema.zig`,
  `compiler/analyzer.zig`, `compiler/backend/llvm.zig`.
- **Tests:** `tests/integration/cases/slice_ergonomics.{kyn,exit}`,
  `tests/integration/cases/runtime_open_subslice_bounds.{kyn,exit}`,
  `tests/integration/cases/runtime_null_slice.{kyn,exit}`,
  `tests/integration/abi/cabi_slice.{kyn,c,exit}`,
  `tests/integration/errors/address_of_rvalue.{kyn,code}`,
  `tests/integration/errors/slice_out_of_bounds.{kyn,code}`,
  `tests/integration/errors/slice_len_assign.{kyn,code}`,
  `tests/integration/errors/const_slice_coercion_mismatch.{kyn,code}`,
  `tests/integration/robustness.py`.
- **Documentation:** `README.md`, `CHANGELOG.md`, `docs/abi.md`,
  `docs/compiler-architecture.md`, `docs/continuity.md`, `docs/diagnostics.md`,
  `docs/grammar.ebnf`, `docs/grammar.md`, `docs/language-reference.md`,
  `docs/memory-model.md`, `docs/roadmap.md`, `docs/safety-model.md`,
  `docs/type-system.md`.

## 8. Known limitations

- Single `.kyn` source file per `kync` compilation unit (multi-file Kyn
  modules are the next planned increment).
- `usize` / `isize` and C ABI lowering assume 64-bit `x86_64` Linux System V.
- Floating-point structs, fixed-size arrays by value, variadic functions, and
  function pointers are rejected across `extern`/`export` C ABI boundaries.
- Runtime pointer safety checks exact `null` values and slice/array bounds, not
  temporal lifetimes (`free`/dangling pointers) or raw pointer arithmetic
  bounds.

## 9. Next logical task for resumption

Implement **deterministic multi-file Kyn modules (`import`)**:

1. Specify minimal, explicit file/module import syntax in `docs/grammar.ebnf`
   and `docs/language-reference.md` (no glob imports, no implicit prelude,
   deterministic path resolution, compile-time import cycle diagnostic).
2. Extend `driver.zig`, `ast.zig`, `parser.zig`, `symbol.zig`, and `sema.zig`
   to load, parse, and resolve imported `.kyn` modules in a shared arena and
   emit unified IR in `backend/llvm.zig`.
3. Update `kyn-build` (`build-system/main.zig`) so SHA-256 build stamps include
   transitively imported `.kyn` files.
4. Validate with unit tests, multi-file positive/negative integration cases
   (including circular-import and visibility errors), and documentation updates.
