# Kyn roadmap

This is a technical sequence, not a promise of dates. Each milestone requires
implementation, tests and documentation before it is announced as available.

## v0.1.0-alpha.1 — vertically functional compiler

Status: implemented and validated on `main` by GitHub Actions. A clean-room
release-readiness gate is available at `tools/release-check.sh`. No tag or
GitHub release has been created yet.

- source manager, lexer, parser and AST;
- name resolution, type checking and lvalues;
- static analyzer for provable facts;
- typed IR and LLVM text backend;
- object/executable generation through Clang;
- `check`, `emit-llvm`, `emit-obj`, `build`, `run`;
- C ABI calls and exports;
- `kyn-build` hybrid Kyn/C/Zig projects with content-hash caching;
- unit, regression and integration tests;
- documentation of the implemented subset and limitations.

## v0.1.0-alpha.2 — frontend hardening

Status: the parser recovery, diagnostic reference/coverage, robustness corpus
and reproducible clean-build/CI checks from this milestone are implemented on
`main`. No tag or GitHub release has been created yet.

- expansion of parser recovery tests and diagnostic regression coverage;
- fuzz/robustness passes for lexer and parser;
- complete diagnostic reference and examples;
- build metadata and reproducible clean-build checks;
- no new unsafe runtime promises.

## v0.1.0-alpha.3 — memory and aggregates

Status: in progress. Aggregate parameters and returns by value inside Kyn and
aggregate copies/assignment are implemented and tested. `extern`/`export`
functions still reject aggregates (`E0410`) until C ABI lowering is specified
and validated. Explicit heap allocator experiments and slices are pending.

- aggregate parameters and returns by value with documented ABI lowering;
- aggregate copies and assignment;
- explicit heap allocator interface experiments;
- slices, only after pointer/array semantics are specified and tested.

## v0.1.0-beta.1 — safety checks

- explicit runtime check layer for bounds, overflow, division and null;
- profile policy that never silently removes a promised check;
- freestanding-compatible trap/handler strategy;
- positive (trap) and negative (proven-safe) tests per check category;
- documentation of remaining undefined behavior.

## v0.1.0-rc.1 — interoperability and toolchain

- variadic extern declarations or documented C wrappers;
- function pointers and indirect calls;
- header dependency scanning in `kyn-build`;
- cross-compilation options and target declarations;
- expanded C ABI conformance tests on supported targets.

## v0.1.0 — first stabilized experimental release

- modules, visibility and a package/build manifest;
- initial standard library and optional runtime;
- documented supported targets and ABI within the release line;
- release notes with exact compiler, Zig and LLVM versions.

## Explicitly deferred

- garbage collection;
- mandatory ownership/borrow checking;
- macros or a preprocessor;
- a self-hosted Kyn compiler before the Zig implementation is stable;
- replacing LLVM with a custom backend without a documented technical reason.

## Ordering rule

Do not advance to a later milestone while earlier invariants are unstable.
Correctness, diagnostics and tests take priority over feature count or
benchmarks.
