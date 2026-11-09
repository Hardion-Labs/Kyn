# Kyn roadmap

`v0.1.0-alpha.2` is the current principal release:
https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.2

Subsequent work builds from that published toolchain. No `alpha.3` or
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

## Implemented after `v0.1.0-alpha.2`

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

## Next direction

- Add multi-file Kyn modules, explicit `import` declarations, and deterministic
  module graph support in `kync` and `kyn-build`.
- Decide and specify general-purpose C ABI lowering for floating-point/SSE
  aggregate members and cross-compilation targets before exposing them across
  `extern`/`export` unconditionally.
- Add profile-differentiated runtime trap policy (`debug`, `safe`, `release`,
  `fast`) with explicit, documented and tested behavior.
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
