# Kyn roadmap

`v0.1.0-alpha.5` is the current principal release:
https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.5

`v0.1.0-alpha.4` remains published and untouched. Subsequent work builds from
the `alpha.5` toolchain. No `beta.1` artifact exists and no next version number
is selected. Milestones below are directions, not release promises.

## After `v0.1.0-alpha.5` — on `main`, unreleased

- `kyn-build` hashes transitive quoted C headers, so editing a header rebuilds
  instead of silently leaving a stale binary.
- `bool` ↔ float casts compile (and fold correctly when constant), closing two
  defects that a differential sweep of every numeric cast pair found: one
  "internal" error and one invalid-IR emission.
- Folded constant integers lower with their real signedness, so literal
  arithmetic no longer traps where the named-variable form works; and the
  duplicate `E0216`/`E0420` check is deduplicated in favour of the documented
  `E0420`. Both came from sweeping the tables in §5.1 and §4.1.
- The callee side of variadics is implemented from its design
  ([design-callee-variadics.md](design-callee-variadics.md)): `export fn` may be
  variadic, `va_arg()` takes its type from context, `va_start`/`va_end` are
  implicit, and the ABI was measured and executed by hand before any compiler
  code was written. Narrowed `E0474` plus new `E0478`–`E0480`; a C fixture links
  against the exported definitions and executes them under both profiles.
- The slice half of the cast table (§5.7), the constant-expression rules (§3.5)
  and the safety model's static checks (`E0501`–`E0506`, `W0501`, `W0502`) were
  swept against the real compiler and all behave as documented; one wrong
  diagnostic code in §3.5 was corrected. The checks now have unit coverage
  pinning each documented `E0506` context and each `W0501` terminator.

- A struct initializer that repeats a field is `E0404`; the documented "exactly
  once" rule was previously unenforced and the last value won.

- `argc`/`argv` entry point: the C ABI already delivered both, but nothing
  documented or tested it and any signature was accepted. The entry point is now
  checked (`E0477`) and the suite runs a case with `.args`.

- Raw pointer / integer / function-value casts in both directions, plus the
  `inttoptr` lowering they needed: an integer-to-pointer cast was documented and
  accepted by the type checker but reached the back end as an internal error.

- Exported globals: `export var`/`export let`/`export const` publish a C object
  under its source spelling, with mutability deciding writable vs read-only
  storage, and the type checked as an ABI boundary (`E0476`).
- Two constant-representation defects fixed, both predating the release: a
  `u128` constant above `i128`'s maximum crashed the back end instead of being
  emitted, and the same value was rejected as `E0440` when it appeared beside an
  already-typed `u128` operand.

## v0.1.0-alpha.5 — published preview

- Explicit code-generation targets: `kync --target <triple>` reaches the
  external assembler, which is what selects the machine code, and a target
  without the System V aggregate ABI refuses an aggregate boundary (`E0473`)
  instead of lowering the host convention for another machine.
- Variadic `extern` declarations, with the C default argument promotions applied
  to the trailing arguments and aggregates, slices and bare `null` rejected
  (`E0474`/`E0475`).
- First-class function values (`fn(P) R`) and indirect calls, with a null-call
  trap and signatures compared structurally in diagnostics.

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

## v0.1.0-alpha.4 — published preview

- Leaf-based System V classification: the register of each eightbyte follows
  the scalar leaves it carries, with nested structs, fixed arrays and singleton
  enums flattened the way Clang flattens them.
- Pointer leaves travel at pointer width and are never narrowed to a
  neighbouring integer member width; narrow second slots write only their own
  bytes.
- Fixed-array struct members contribute one leaf per element, expanding
  recursively for nested arrays and arrays of aggregates, with overflow-checked
  sizing rather than an arbitrary size cap.
- A struct whose only member is a 16-byte integer travels as one `i128`,
  matching Clang's `struct { __int128 a; }` classification.
- `packaging/`: release-archive tooling plus Linux and Windows installers.
- 128-bit integer constants are representable end to end: the type-checker
  bounds no longer overflow, and a `u128` maximum survives to the back end.

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

- Unions, bitfields and packed structs now have a **written design**
  ([design-unions-bitfields-packed.md](design-unions-bitfields-packed.md)): the
  layout and ABI of each were measured with the project toolchain before it was
  written, `packed` forces the memory class, a union classifies as the struct of
  its members, bitfield widths live in the type (`u3`) rather than in a colon
  syntax, and `align(N)` is deliberately excluded. It is not implemented; the
  plan and the C-compatible bitfield subset are in the document.
- Decide whether to add explicit re-export syntax; current unaliased imports expose only the transitive closure of unaliased dependency edges.
- First-class function values and indirect calls are implemented: `fn(P) R`
  names a signature, a function name decays to a value in value position, the
  value can be stored in aggregates, passed to and received from C, compared with
  `null`, and called indirectly (with a null-call trap). A direct call keeps
  calling the symbol. A raw pointer, an integer address and a function value
  cast between each other in every direction (`ptr` is the one representation),
  which is how a C callback handed out as `void *` becomes callable; `as` never
  converts between two signatures. Function values as *aggregate members at the
  C boundary* are covered indirectly (they are one `ptr` leaf) rather than by a
  dedicated classifier — a struct of only function pointers travels as an
  aggregate like any other and follows the existing eightbyte rules.
- Variadics are implemented in both directions: `extern` declarations with the
  C default argument promotions applied to the trailing arguments (aggregates,
  slices and bare `null` rejected), and `export` definitions that retrieve them
  with a context-typed `va_arg()` over an implicit `va_start`/`va_end` pair.
  What remains unaddressed is *forwarding* a list — a `v`-style callee needs a
  `va_list` parameter type, which would be a language handle Kyn has no other
  use for. A variadic function that is neither `export` nor `extern` stays
  rejected (`E0474`).
- Cross-compilation targets are specified and implemented at the
  code-generation level: `kync --target <triple>` reaches the external
  assembler, which is what selects the machine code, and the type checker
  refuses to lower a C aggregate boundary for a target whose ABI it does not
  know (`E0473`) instead of silently applying the host convention. What is not
  yet specified: linking a cross-compiled object into a full executable for
  another platform (that needs a target sysroot and linker), and per-target
  variations of the C ABI, which would be a new classifier rather than a flag. Implemented subsets: one direct `f32`/`f64` field
  via scalar SSE, exactly two direct `f32` fields via `<2 x float>`, exactly
  three adjacent direct `f32` fields via `<2 x float>, float` with a
  `{ <2 x float>, float }` return, exactly four adjacent direct `f32` fields
  via `<2 x float>, <2 x float>` with a `{ <2 x float>, <2 x float> }` return,
  exactly two direct `f64` fields via two SSE parameter registers and an LLVM
  pair return, two-`f32` SSE slots paired with a narrow INTEGER or pointer
  second slot (`{ f32, f32, i16/i8/bool/ptr }` and the mirrored orders), direct
  `{ f32, f64 }` / `{ f64, f32 }` layouts at offsets 0/8
  via two SSE registers, direct `{ f32, i64 }` / `{ f32, u64 }` and
  `{ f64, i64 }` / `{ f64, u64 }` layouts at offsets 0/8 via SSE+INTEGER
  registers, direct `{ i8/u8, f64 }` / `{ i16/u16, f64 }` and the reverse
  `{ f64, i8/u8 }` / `{ f64, i16/u16 }` layouts at offsets 0/8 via exact-width
  INTEGER+SSE registers, singleton `bool` members (`{ bool, f64 }` /
  `{ f64, bool }` via `i8`), singleton `enum` members (`i8`/`i16`/`i32`/`i64`
  backings) via a member-width INTEGER and an SSE register, aggregates
  with two or more smaller-INTEGER members packed into one eightbyte
  followed by a single `f32` or `f64` (only scalar in the next eightbyte)
  passed as `( i64, float )` or `( i64, double )`, singleton
  `i8`/`i16`/`i32`/`i64` aggregates in a single exact-width INTEGER argument register, sub-32-bit integer members and `bool` inside merged
  `INTEGER` eightbytes (packed `i64`), exact multi-member layouts with an
  SSE-only slot and an INTEGER/merged slot (`{ f32, f32, i32 }`,
  `{ f32, f32, i64 }`, `{ i32/u32, f32, f32 }`, `{ f32, i32/u32, f32 }`,
  `{ i32/u32, f32, f64 }`, `{ f32, i32/u32, f64 }`,
  `{ f64, i32/u32, i32/u32 }`, `{ f64, i32/u32, f32 }`,
  `{ i64/u64, f32, f32 }`, `{ f32, f32, f64 }`, `{ f64, f32, f32 }`, and
  the four-member runs) via their probed coercions, and direct `{ f64, i32 }` / `{ i32, f64 }` layouts at
  offsets 0/8 via their corresponding SSE+INTEGER register order.
- Aggregates whose two eightbytes each carry exactly one scalar leaf: each
  leaf passes in its own register at its own width and the aggregate returns as
  the matching pair, for integer leaves (`{ i8/u8, i64 }`, `{ i16/u16, i64 }`,
  `{ i32, i64 }` / `{ u32, u64 }` and the reversed `{ i64, i8/u8 }`,
  `{ i64, i16/u16 }`, `{ i64, i32/u32 }`), pointer leaves (`{ ptr, i64 }`,
  `{ i8, ptr }`, `{ ptr, ptr }`, `{ ptr, f64 }`, `{ f32, ptr }`, plus
  `{ i32, i32, ptr }` merging to `i64, ptr`) and narrow second slots of a
  12-byte aggregate (`{ f32, f32, i16 }`, `{ f32, f32, i8 }`,
  `{ f32, f32, bool }`, `{ f32, f32, ptr }` and the mirrored
  `{ i16/ptr/i32, f32, f32 }` orders). A pointer leaf is never narrowed to an
  integer member width, and a narrow slot writes only its own bytes.
- Boundary classification by leaves: the register of an eightbyte follows the
  scalar leaves it carries, with nested structs flattened into their members
  exactly as Clang does, so nested integer, `f32` and `f64` members follow
  the same rules as direct ones.
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
