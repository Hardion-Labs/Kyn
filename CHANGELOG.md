# Changelog

All notable changes to Kyn are documented here. The project uses semantic
versioning with explicit pre-release identifiers. No source or ABI stability is
promised between alpha releases.

## [Unreleased]

### Added

- Explicit relative-path Kyn imports with deterministic dependency-first loading, once-only module graph traversal, source-aware diagnostics, and cycle/missing-file checks. Imported declarations currently share the global namespace.
- Transitive `.kyn` import contents are included in `kyn-build` SHA-256 cache stamps.
- Open-ended and bounded slice expressions (`base[..]`, `base[start..]`,
  `base[..end]`, `base[start..end]`) across fixed arrays, pointers to fixed
  arrays, and slices, with a zero-branch fast path for `base[..]`.
- Const-polymorphic slicing and one-way implicit `[]T -> []const T`
  assignability when `T` matches exactly, while keeping `[]const T`
  non-assignable to `[]T` and nested slice/pointer element types invariant.
- Read-only `slice.ptr` (`*T` / `*const T`), `array.len` (`usize`, usable in
  constant expressions on fixed-array identifiers and constant array literals),
  and `->len` / `->ptr` through pointers to slices and arrays.
- Diagnostic `E0464` rejecting `&` on non-lvalue expressions, plus accurate
  compound type formatting (`[]T`, `[]const T`, `*T`, `*const T`, `[N]T`) in
  semantic diagnostics.
- Compile-time bounds checking (`E0502`) on constant slice ranges and negative
  constant slice indices, and provable/runtime `null` checks (`E0506` / trap)
  when slicing or slice-casting pointers to arrays.
- Executable C ABI slice and `< 8`-byte global aggregate interoperability test
  (`tests/integration/abi/cabi_slice.{kyn,c}`) and persistent continuity record
  ([docs/continuity.md](docs/continuity.md)).

### Fixed

- Non-lvalue enforcement on `.len` and `.ptr` properties (`E0441` instead of
  reaching LLVM lvalue lowering).
- Immutable `const` and `let` global mutability tracking (`E0442` on mutation,
  `*const` / `[]const` on address-of and slicing).
- Default `enum` backing type aligned with the specification (`i32`).
- Pointer arithmetic with integer literals (`p + 1`, `p - 1`) and non-integer
  pointee types, plus pointer difference (`p - q`) on struct and slice
  pointers.
- Safe zero-padded register packing for `< 8`-byte and `< 16`-byte aggregates
  in `extern`/`export` C ABI calls and explicit natural alignment on padded
  aggregate `alloca` stack slots.

## [0.1.0-alpha.2] - 2026-11-09

C ABI boundary support for integer-like aggregates.

### Added

- C ABI lowering for integer-like aggregates (`struct` fields, `enum`,
  `usize`/`isize`, pointers, bool, char) up to 16 bytes by value on
  `x86_64-linux`.
- Support for slices (`[]T`, `[]const T`) and large aggregates across the
  `extern`/`export` boundary using the System V `byval`/`sret` form.
- Runtime checks for slices and large aggregate signatures at the C boundary.
- Integration tests for aggregate C ABI calls in both directions
  (`tests/integration/abi/cabi_small_pair.*`, `tests/integration/abi/cabi_big.*`).

### Changed

- `extern`/`export` functions may pass integer-like aggregates ≤16 bytes by
  value on x86_64-linux; arrays and floating-point aggregates remain rejected
  with `E0410`.
- Slice signatures at the C boundary are accepted when the layout matches
  `struct { ptr, usize }`.

### Fixed

- C ABI declarations and calls no longer mismatch `%` vs `byval`/`sret`
  pointer signatures for aggregate parameters and returns.

### Known limitations

- C ABI aggregate lowering covers x86_64-linux only; other targets and
  floating-point aggregates are rejected.
- Kyn internal ABI and C ABI lowering are distinct; Kyn cannot call C
  functions that take arrays by value, variadics, or floating-point aggregates.
- Slices at the C boundary require the C side to declare a compatible
  `struct { ptr, usize }` layout.

## [0.1.0-alpha.1] - 2026-11-09

First vertically functional compiler milestone. Published as the current
principal release: https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.1

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
  and aggregate copies. `extern`/`export` functions pass integer-like
  aggregates ≤16 bytes by value on x86_64-linux; arrays and floating-point
  aggregates are rejected (`E0410`).
- Global scalar and aggregate constants, including nested structs/arrays and
  enum globals, emitted as LLVM constants.
- Runtime bounds checks for fixed arrays and runtime integer division traps.
  Dynamic indexes outside `[0, len)`, a zero divisor, and signed `INT_MIN / -1`
  call `llvm.trap()` in every profile.
- Runtime integer arithmetic checks in every profile: addition, subtraction,
  multiplication and unary negation trap on signed and unsigned overflow.
  Dynamic shift amounts trap when negative or at/above the integer width.
- Initial slice support (`[]T`, `[]const T`): fat-pointer representation,
  fixed-array construction with `as` and the `slice[start..end]` /
  `array[start..end]` subslice syntax, `.len`, internal parameter/return
  passing and runtime slice bounds checks. Slice signatures at C ABI
  boundaries remain rejected.
- Runtime null dereference checks: `*p`, `p->field` and `p[index]` trap on an
  exactly-null pointer. Provable null dereferences are rejected at compile
  time with `E0506`.
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

- No modules, imports, packages, generics or traits.
- No variadic extern functions, aggregate parameters/returns across the C ABI,
  or indirect calls.
- No runtime null dereference checks or full definite-assignment checking.
- No standard library or runtime.
- `usize`/`isize` are currently fixed at 64 bits.
- C headers and Zig transitive imports are not part of the incremental cache.
