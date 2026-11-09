# Changelog

All notable changes to Kyn are documented here. The project uses semantic
versioning with explicit pre-release identifiers. No source or ABI stability is
promised between alpha releases.

## [0.1.0-alpha.1] - 2026-11-08

First vertically functional compiler milestone.

### Added

- Zig implementation of the Kyn compiler with explicit stages: source manager,
  lexer, parser, AST, name resolution, type checker, static analyzer, typed
  CFG IR, LLVM text emitter and driver.
- CLI commands: `check`, `emit-llvm`, `emit-obj`, `build`, `run`.
- Safety profiles: `debug`, `safe`, `release`, `fast`.
- Kyn language subset: functions, `extern`/`export`, structs, enums, globals,
  locals, pointers, fixed arrays, `if`/`else`, `while`, `break`, `continue`,
  `return`, explicit casts, direct calls, struct/array literals, pointer
  arithmetic, short-circuit boolean operators.
- Static analysis: uninitialized reads, provable division by zero, constant
  overflow, shift range, constant array bounds, unreachable statements and
  constant conditions.
- `kyn-build` with a declarative `kyn.build` file, Kyn/C/Zig targets,
  `exe`/`staticlib`/`sharedlib` kinds and content-hash incremental rebuilds.
- C ABI interoperability through `extern fn` / `export fn`, including a
  verified Kyn + C + Zig example.
- Aggregate parameters and returns by value inside Kyn, aggregate assignment
  and aggregate copies. `extern`/`export` functions reject aggregates in v0.1;
  pass pointers across the C ABI.
- Global scalar and aggregate constants, including nested structs/arrays and
  enum globals, emitted as LLVM constants.
- Runtime bounds checks for fixed arrays and runtime integer division traps.
  Dynamic indexes outside `[0, len)`, a zero divisor, and signed `INT_MIN / -1`
  call `llvm.trap()` in every profile.
- Runtime integer arithmetic checks in every profile: addition, subtraction,
  multiplication and unary negation trap on signed and unsigned overflow.
  Dynamic shift amounts trap when negative or at/above the integer width.
- Initial slice support (`[]T`): fat-pointer representation, fixed-array
  construction with `as`, `.len`, internal parameter/return passing and
  runtime bounds checks. Slice signatures at C ABI boundaries remain rejected.
- Unit and regression tests for every compiler stage, including parser
  precedence, associativity and malformed-input recovery.
- End-to-end integration suite covering execution, stdout, exit status,
  profiles, negative diagnostics, code generation, hybrid builds, documentation
  coverage (diagnostic codes and Markdown links/anchors), version metadata
  consistency and a deterministic lexer/parser robustness corpus.
- Language, type-system, memory, safety, ABI, build-system and compiler
  architecture documentation.
- GitHub Actions CI for formatting, build, unit tests and integration tests.
- `tools/release-check.sh`, a non-destructive release-readiness gate that
  validates branch state, exact CI success, clean-room build/tests, metadata,
  changelog, tag absence and release absence. Its CI lookup filters by exact
  commit.

### Fixed

- Parser recovery no longer loops without consuming input when a declaration
  keyword appears inside a struct, enum or struct initializer after a previous
  syntax error. Regression tests cover the failure mode.
- Documentation now states that block comments nest, matching the lexer and
  its tests.
- Documentation and integration tests now cover aggregate by-value support
  within Kyn and its rejection at C ABI boundaries.
- Scalar enum global initializers (for example `const C: Color = Color.Red`)
  are now accepted; constant validation runs after expression resolution.
- README factually documents aggregate support, documentation links and the
  release-readiness gate after the visual refresh.
- `kync --version` and `kyn-build --version` now print exactly the version
  line on stdout; help output is no longer printed after `--version`.
- Trap blocks now emit `unreachable` after `llvm.trap()` so the LLVM parser
  recognizes the terminating path.
- Constant expression adaptation handles arbitrary integer constant expressions,
  not only bare literals, when guided by an expected integer type.

### Known limitations

- No modules, imports, packages, slices, generics or traits.
- No variadic functions, aggregate parameters/returns, aggregate copies or
  indirect calls.
- No runtime bounds, overflow, null or initialization checks.
- No standard library or runtime.
- `usize`/`isize` are currently fixed at 64 bits.
- C headers and Zig transitive imports are not part of the incremental cache.
