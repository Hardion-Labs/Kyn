# Kyn roadmap

`v0.1.0-alpha.3` is the current principal release:
https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.3

Subsequent work builds from that published toolchain. No `alpha.4` or
`beta.1` pre-release artifacts exist and no next version number is selected.
Milestones below are directions, not release promises.

## v0.1.0-alpha.2 — published preview

- Source manager, lexer, parser and AST.
- Name resolution, type checking and lvalues.
- Static analyzer for provable facts.
- Typed CFG IR and textual LLVM backend.
- `check`, `emit-llvm`, `emit-obj`, `build` and `run`.
- C ABI calls and exports, plus a hybrid Kyn/C/Zig example.
- C ABI lowering for integer-like aggregates and slices on x86_64-linux.
- Global scalar/aggregate/enum constants.
- Aggregates by value inside Kyn and slices (`[]T`, `[]const T`).
- Runtime fixed-array and slice bounds checks.
- Integer addition/subtraction/multiplication overflow traps.
- Division/remainder by zero traps and checked shifts.
- Diagnostics with stable codes and documented coverage.
- Fuzzing/robustness corpus and clean-room release gate.
- Documented limitations and no hidden runtime.

## v0.1.0-alpha.3 — published preview

- Open-ended and bounded slice syntax (`base[..]`, `base[start..]`,
  `base[..end]`, `base[start..end]`) with zero-branch lowering for `base[..]`.
- Const-polymorphic slicing and one-way implicit `[]T -> []const T`
  assignability (for identical `T`), plus read-only `slice.ptr`, `slice.len`,
  `array.len`, and `->len` / `->ptr` through pointers.
- Lvalue and mutability hardening: `.len`/`.ptr` rejected as lvalues (`E0441`),
  `&` restricted to lvalues (`E0464`), immutable `const`/`let` globals
  enforced (`E0442`), and default `enum` backing aligned to `i32`.
- Compile-time constant slice range checks (`E0502`), provable/runtime `null`
  checks (`E0506` / trap) on array-pointer slicing/casting, pointer arithmetic
  with integer literals and non-integer pointees, and safe `< 8`-byte /
  `< 16`-byte C ABI aggregate register packing with executable slice ABI tests.

- Explicit `import "relative/path.kyn" [as alias];` declarations, deterministic
  dependency-first loading, once-only normalized-path visits, source-aware
  diagnostics, cycle/missing-file diagnostics (`E0231`/`E0232`), aliases for
  qualified function/value/type references, and `private` checks (`E0467`).
  `kyn-build` hashes transitive Kyn imports in target stamps.
- Each source module has its own top-level symbol table. Qualified aliases
  resolve only declarations in their target; unaliased imports open public names
  through unaliased dependency edges. Local names shadow opens, and ambiguous
  imported names/types report `E0471` at use. Duplicate names are allowed across
  modules but rejected within one module (`E0401`). Declarations are public by
  default; `private` restricts cross-module access.
- Expanded x86_64-linux C ABI aggregate lowering: INTEGER-class eightbyte
  merging for float/int members, scalar SSE for exactly one direct `f32`/`f64`
  field, `<2 x float>` for two adjacent `f32` fields, two SSE argument registers
  and `{ double, double }` return for two `f64` fields, direct `{ f64, i32 }` /
  `{ f64, u32 }` and `{ i32, f64 }` / `{ u32, f64 }` layouts at offsets 0/8,
  plus `E0473` for unsupported boundary layouts.
- Runtime-check policy is explicit from `driver.Profile` through LLVM lowering.
  All current profiles retain all implemented checks (bounds, overflow,
  division, shifts, and exact-null dereference); no profile-specific removal is
  implemented or promised.

## Next direction

- Decide whether to add explicit re-export syntax; current unaliased imports expose only the transitive closure of unaliased dependency edges.
- Complete System V C ABI coercions for remaining `SSE`/`SSEUP` aggregate
  classes and specify cross-compilation targets before exposing those layouts
  across `extern`/`export`. Implemented subsets: one direct `f32`/`f64` field
  via scalar SSE, exactly two direct `f32` fields via `<2 x float>`, exactly
  three adjacent direct `f32` fields via `<2 x float>, float` with a
  `{ <2 x float>, float }` return, exactly four adjacent direct `f32` fields
  via `<2 x float>, <2 x float>` with a `{ <2 x float>, <2 x float> }` return,
  exactly two direct `f64` fields via two SSE parameter registers and an LLVM
  pair return, and direct `{ f64, i32 }` / `{ i32, f64 }` layouts at offsets
  0/8 via their corresponding SSE+INTEGER register order.
- Keep the all-checks-enabled runtime policy stable across profiles unless a
  separate language-level decision explicitly specifies observable profile
  differences and adds profile-specific regressions.
- Keep the compiler and docs aligned: grammar, reference, type system, memory,
  safety, ABI, architecture, build system, [continuity.md](continuity.md) and
  release notes.
- Evaluate explicit allocator abstractions and minimal freestanding `std`
  primitives only after multi-file modules and ownership/failure rules are
  settled.

## Explicitly deferred

- garbage collection;
- mandatory ownership/borrow checking;
- macros or a preprocessor;
- a self-hosted compiler before the Zig implementation is stable;
- replacing LLVM with a custom backend without a clear technical reason.

## Ordering rule

Correctness, diagnostics and tests take priority over features or benchmarks.
No milestone is complete until implementation, tests and documentation agree.
