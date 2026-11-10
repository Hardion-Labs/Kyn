# Changelog

All notable changes to Kyn are documented here. The project uses semantic
versioning with explicit pre-release identifiers. No source or ABI stability is
promised between alpha releases.

## [Unreleased]

### Added

- C ABI support on `x86_64` Linux for exactly three adjacent direct `f32`
  fields (12-byte layout): arguments flatten to `<2 x float>, float` and the
  return coerces to `{ <2 x float>, float }`, matching Clang's System V
  `SSE`/`SSEUP` lowering as verified against Clang IR. Exactly four adjacent
  direct `f32` fields (16 bytes) use two `<2 x float>` registers and a
  `{ <2 x float>, <2 x float> }` return. Nested wrappers, mixed
  float/integer runs, and other small mixed-class layouts remain rejected with
  `E0473`. Integration fixtures `tests/integration/abi/cabi_sse_f32_triple`
  and `cabi_sse_f32_quad` cover both directions; the negative
  `E0473` fixtures (`abi_float_param`/`abi_float_return`) now exercise a
  mixed float/integer aggregate instead of the newly supported triple layout.
- C ABI support on `x86_64` Linux for exactly two direct mixed-width `f32`/`f64`
  fields at natural offsets 0/8 (16 bytes): `{ f32, f64 }` uses `float, double`
  arguments and a `{ float, double }` return coercion; the reverse `{ f64, f32 }`
  layout uses `double, float` and `{ double, float }`, matching Clang's
  System V lowering as verified against Clang IR. Integration fixtures
  `cabi_mixed_f32_f64` and `cabi_mixed_f64_f32` cover argument and return
  paths in both directions; other mixed-class layouts remain rejected with
  `E0473`.
- C ABI support on `x86_64` Linux for exactly two direct mixed-width
  float/`i64`-or-`u64` fields at natural offsets 0/8 (16 bytes), signedness
  irrelevant: `{ f32, i64 }` / `{ f32, u64 }` use `float, i64` arguments and a
  `{ float, i64 }` return; the reverse `{ i64, f32 }` / `{ u64, f32 }` uses
  `i64, float` and `{ i64, float }`; `{ f64, i64 }` / `{ f64, u64 }` use
  `double, i64` and `{ double, i64 }`; and `{ i64, f64 }` / `{ u64, f64 }`
  use `i64, double` and `{ i64, double }`. Verified against Clang IR probes
  for all eight signatures. Integration fixtures `cabi_mixed_f32_i64`,
  `cabi_mixed_i64_f32`, `cabi_mixed_f64_i64` and `cabi_mixed_i64_f64` cover
  argument and return paths in both directions; other mixed-class layouts
  remain rejected with `E0473`.
- C ABI support on `x86_64` Linux for exactly two direct small integer members
  at natural offsets 0/8 (16 bytes), signedness irrelevant: `{ i8/u8, f64 }`
  passes as `i8, double` with a `{ i8, double }` return; `{ i16/u16, f64 }`
  uses `i16, double` and `{ i16, double }`; the reverse `{ f64, i8/u8 }` and
  `{ f64, i16/u16 }` use `double, i8` / `double, i16` and the matching
  `{ double, i8 }` / `{ double, i16 }` returns. Clang IR probes confirm
  member-width lowerings. Integration fixtures `cabi_small_i8_f64`,
  `cabi_small_f64_i16` and `cabi_small_i8_merged` cover argument and return
  paths in both directions. Additionally, sub-32-bit integer members (`i8`,
  `u8`, `i16`, `u16`) and `bool` are now accepted inside merged-INTEGER
  eightbytes for the existing multi-member layouts (Clang passes the packed
  `i64` irrespective of member widths); singleton-member small-integer
  layouts use their member width, and singleton `bool` remains rejected with
  `E0473`. Negative `E0473` fixtures moved from a now-supported `{ i16, f64 }`
  to a rejected singleton-`bool` layout.
- C ABI support on `x86_64` Linux for exact multi-member 12/16-byte layouts
  whose eightbytes split into an SSE-only slot and an INTEGER/merged slot,
  verified against Clang IR probes: `{ f32, f32, i32/u32 }`
  (`<2 x float>, i32` and `{ <2 x float>, i32 }`), `{ f32, f32, i64/u64 }`
  (`<2 x float>, i64` and `{ <2 x float>, i64 }`), `{ i32/u32, f32, f32 }` and
  `{ f32, i32/u32, f32 }` (merged `INTEGER` as `i64`, then `float`),
  `{ i32/u32, f32, f64 }` and `{ f32, i32/u32, f64 }` (merged `INTEGER` as
  `i64`, then `double`), `{ f64, i32/u32, i32/u32 }` and `{ f64, i32/u32, f32 }`
  (`double` then merged `INTEGER`), `{ i64/u64, f32, f32 }`
  (`i64, <2 x float>` and `{ i64, <2 x float> }`), and
  `{ i32/u32, f32, f32, f32 }` / `{ f32, i32/u32, f32, f32 }` (same signature).
  Four-member `{ f32, f32, i32/u32, f32 }` uses `<2 x float>, i64` and
  `{ <2 x float>, i64 }`. All signatures verified against Clang IR probes.
  Integration fixtures `cabi_multi_f32x2_i32`, `cabi_multi_f32x2_i64`,
  `cabi_multi_i32_f32pair`, `cabi_multi_i64_f32pair`, `cabi_multi_f64_v2f32`
  and `cabi_multi_f32pair_f64` cover argument and return paths in both
  directions; layouts outside these exact shapes remain rejected with `E0473`.

## [0.1.0-alpha.3] - 2026-11-09

Modules, slices ergonomics and expanded x86_64-linux C ABI coverage.

### Added

- Dedicated diagnostic `E0473` for aggregate parameters and returns whose layout
  is unsupported at the selected C ABI boundary; `E0410` remains specific to
  void parameters.
- C ABI support for small aggregates whose System V eightbytes merge float and
  integer members into the `INTEGER` class; structs with exactly one direct
  `f32`/`f64` field use scalar SSE arguments/returns; a struct with exactly
  two adjacent direct `f32` fields uses one `<2 x float>` SSE/SSEUP value, and
  exactly two direct `f64` fields use two SSE argument registers with an LLVM
  `{ double, double }` return coercion. Direct `{ f64, i32 }` / `{ f64, u32 }`
  structs at offsets 0/8 use `double, i32` arguments and `{ double, i32 }`
  returns; the reverse `{ i32, f64 }` / `{ u32, f64 }` layouts use
  `i32, double` arguments and `{ i32, double }` returns. Larger supported
  float-bearing aggregates continue through the existing
  memory (`sret`/`byval`) form, while other unsupported layouts remain
  diagnosed with `E0473`.
- Explicit relative-path Kyn imports with deterministic dependency-first loading, once-only module graph traversal, source-aware diagnostics, and cycle/missing-file checks. Each source owns a top-level namespace; aliases qualify declarations and unaliased imports open public names transitively. Ambiguous opens are diagnosed; top-level `private` declarations are enforced across source files.
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
