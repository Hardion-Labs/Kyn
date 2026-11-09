# Kyn roadmap

`v0.1.0-alpha.1` is the current principal release:
https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.1

Subsequent work builds from that published toolchain. There are no published
`alpha.2`, `alpha.3` or `beta.1` pre-release artifacts and no selected next
version number yet. Milestones below are directions, not release promises.

## v0.1.0-alpha.1 — published preview

- Source manager, lexer, parser and AST.
- Name resolution, type checking and lvalues.
- Static analyzer for provable facts.
- Typed CFG IR and textual LLVM backend.
- `check`, `emit-llvm`, `emit-obj`, `build` and `run`.
- C ABI calls and exports, plus a hybrid Kyn/C/Zig example.
- Global scalar/aggregate/enum constants.
- Aggregates by value inside Kyn and slices (`[]T`, `[]const T`).
- Runtime fixed-array and slice bounds checks.
- Integer addition/subtraction/multiplication overflow traps.
- Division/remainder by zero traps and checked shifts.
- Diagnostics with stable codes and documented coverage.
- Fuzzing/robustness corpus and clean-room release gate.
- Documented limitations and no hidden runtime.

## Next direction

- Decide and specify C ABI lowering for aggregates and slices before exposing
  them across `extern`/`export`.
- Add const-polymorphic slicing and a safe subslice construction syntax.
- Add remaining runtime checks: null dereference and a documented policy for
  any future profile-specific behavior.
- Add modules and a deterministic package manifest.
- Keep the compiler and docs aligned: grammar, reference, type system, memory,
  safety, ABI, architecture, build system and release notes.
- Evaluate explicit allocator abstractions and a minimal runtime only after
  their ownership and failure model is specified.

## Explicitly deferred

- garbage collection;
- mandatory ownership/borrow checking;
- macros or a preprocessor;
- a self-hosted compiler before the Zig implementation is stable;
- replacing LLVM with a custom backend without a clear technical reason.

## Ordering rule

Correctness, diagnostics and tests take priority over features or benchmarks.
No milestone is complete until implementation, tests and documentation agree.
