# Changelog

All notable changes to Kyn are documented here. The project uses semantic
versioning with explicit pre-release identifiers. No source or ABI stability is
promised between alpha releases.

## [Unreleased]

Exported globals, the callee side of variadics, the aggregate extensions
(unions, packed structs, bitfields, explicit alignment, anonymous members), the
`match` statement, and three representation fixes (two constants and the
signed-division minimum).

### Added

- **`for` loops**, in C's shape: `for (var i: i32 = 0; i < n; i += 1) { ... }`.
  Every clause is optional, so `for (;;)` is an intentional infinite loop exited
  only by `break`, and an omitted condition means "always" rather than requiring a
  constant `bool`. The initializer may be a declaration, whose variable is scoped
  to the whole statement and gone afterwards -- the one thing this form gives over
  `while`. `continue` jumps to the step rather than past it, so the increment still
  runs; the lowering gives the step its own block for exactly that reason.
- **Tagged unions.** A variant may carry a payload -- `Circle(f64)` -- which makes
  the enum a sum type whose value is `{ tag, payload }`: an ordinary struct whose
  second member is a union of every payload. Measured against clang rather than
  assumed: 16 bytes, alignment 8, payload at offset 8 for `Circle(f64) |
  Rect(i32)`, and `{ i32, i64 }` at the boundary. `match` binds the payload in an
  arm (`Shape.Circle(r) => ...`), as a copy, so the arm may keep it. The
  discriminant is assigned, never declared (`E0507`), because it is what the tag
  holds and two variants sharing it could not be told apart. Construction checks
  arity and payload type (`E0509`); a payload-less variant cannot be bound
  (`E0510`); a payload with no known size is refused (`E0508`).
- **`match`** dispatches on an integer, `bool` or enum. The scrutinee is evaluated
  exactly once and compared against each arm in source order; the arm list must
  contain a wildcard (`E0495`), because Kyn has no fall-through and no implicit
  "do nothing". Enumerating every variant is deliberately not accepted as
  exhaustive — the variant list belongs to a declaration, and accepting it would
  need a second notion of exhaustiveness. One wildcard at most, nothing after it,
  and no repeated pattern value (`E0496`). The lowering is a chain of the `icmp
  eq` that `==` already emits, so no new IR instruction was added.
- An inline `struct { ... }` or `union { ... }` with no name is an **anonymous
  member**: it occupies its own space and its field names promote into the
  enclosing aggregate, transitively. `struct Packet { kind: u8, struct { length:
  u32 } }` is read and initialized as `p.length`, and the promoted name resolves to
  a path of field indices so a write lands in the member it came out of. Measured
  against clang for layout (`y` at 4, `z` at 8, size 12) and for the C ABI (an
  anonymous member is transparent to the classifier, unlike a named nested one). A
  promoted name colliding with a sibling is `E0493`, as in C; a struct-shaped
  anonymous member must still have every promoted field initialized (`E0458`).
- An aggregate with an explicit `align(N)` now crosses the C ABI **by value**;
  `E0473` used to refuse every one of them. Measured against clang: the
  sixteen-byte limit is the *padded* size, an eightbyte that holds no data
  consumes no register, and the register width follows the data — so
  `align(16) struct { long l; }` is 16 bytes and travels in one `i64`, not two,
  while `align(32)` goes by memory. Also fixes the `byval` alignment annotation,
  which carried the layout alignment through and wrote `align 1` where clang
  writes `align 8`.
- `align(N)` raises a `struct` or `union`'s alignment to at least `N` and rounds
  its size up to a multiple of it: `align(16) struct Buffer { kind: u8 }` is 16
  bytes with alignment 16, and the emitted LLVM type is the same
  `{ i8, [15 x i8] }` clang produces. It is a modifier like `packed`, accepted in
  either order, and it only ever *raises*: an alignment below the natural one is
  ignored, as `__attribute__((aligned(2)))` is. The two compose -- `packed` still
  decides the offsets, the larger requirement decides the alignment, and the size
  is rounded up to it. `E0490`/`E0491`/`E0492` cover a malformed, non-power-of-two
  or misplaced `align(`. Supports a second fix: `llvmAlignmentOfType` computed a
  struct's alignment from its fields alone, so a `packed` or `align(N)` aggregate
  was annotated with an alignment its layout does not have; it now reads the one
  layout implementation.
- Integer types may now have any width from 1 to 128, written `u1`..`u128` and
  `i1`..`i128`, and an adjacent run of such fields packs into one storage unit
  instead of one byte each: `struct Wire { kind: u3, tag: u5 }` is one byte,
  `w.kind` is a real `u3` and `w.tag = 3` leaves `w.kind` untouched. The layout is
  a deterministic documented rule — a unit of 1, 2, 4 or 8 bytes and no field
  straddling a boundary of its own unit width, which is why `{a: u3, b: u5, c:
  u12}` puts `c` at bit 16 rather than bit 8. Reads zero-extend for `uN` and
  sign-extend for `iN`; writes mask and merge. A union member cannot be a bitfield
  (`E0487`); a width of 0 or above 128 is `E0486`; a layout whose unit would
  overlap bytes already emitted is refused with `E0489` rather than emitted in a
  form that disagrees with it. The C-compatible subset is narrow and stated in
  `abi.md` §11 — widths summing to at most 8 bits with no non-bitfield member —
  because C's `unsigned a:3` uses a 4-byte unit where a bare width uses a 1-byte
  one, so a wider run agrees on size without agreeing on contents. `align(N)`
  remains unimplemented.
- Aggregates may now overlap and be unaligned. `union Value { integer: i64,
  real: f64 }` puts every member at offset 0 and takes its size and alignment
  from the largest, so `Value { real: 1.5 }` initializes one member and
  `v.integer = 7` reinterprets the same storage; an initializer must name
  exactly one member (`E0485`), and there is deliberately no tag — the program
  owns which member is live, as in C. `packed struct Packet { kind: u8, length:
  u32 }` removes the padding and sets alignment 1, so the struct is 5 bytes with
  `length` at offset 1; `packed` before anything but an aggregate is `E0484`.
  Both are laid out and cross the C ABI as measured against clang: a union
  classifies exactly as the struct of its members (8-byte `{char,int,double}` in
  one `i64`, 24-byte `{double[3]}` by `sret`/`byval`), and a packed aggregate
  goes by memory even when small, which is why it is emitted with the LLVM
  packed `<{ ... }>` form. Fixtures `cabi_union_packed` (C calls Kyn with and
  receives from Kyn a union, a packed struct and a nested union) and
  `cabi_union_packed_layout` (offsets read back through Kyn's own field access).
  Bitfields and `align(N)` are not implemented; the design covering them is in
  `docs/design-unions-bitfields-packed.md`.

- A Kyn function may now receive a C variadic argument list. `export fn` takes
  `...` after at least one fixed parameter, and the trailing arguments are read
  with `va_arg()`, a builtin expression whose type comes from context:
  `let value: i32 = va_arg();`. Three rules follow from what a caller can have
  passed and are diagnosed rather than defaulted: `va_arg()` needs an expected
  type (`E0478`), so a `double` is never read as an `i32`; only the promoted
  widths travel, so `let small: i8 = va_arg();` is `E0479` naming `i32`; and
  `va_arg()` outside a variadic function is `E0480`. `va_start`/`va_end` are
  implicit — the compiler emits them at entry and before every `return` and on
  the trap path — and there is no `va_list` value to name or pass, so a list
  cannot be forwarded yet. `E0474` narrows accordingly: a variadic function that
  is neither `export` nor `extern` stays rejected, because a Kyn-internal
  function has no C caller to supply the tail. The emitted representation is the
  `x86_64` System V one (`[1 x %struct.__va_list_tag]`, `llvm.va_start.p0`, a
  single `va_arg` per retrieval, `llvm.va_end.p0`), and its type and intrinsic
  declarations appear only when a variadic body exists, so every other program
  keeps emitting byte-identical IR. Fixture
  `tests/integration/abi/cabi_variadic_callee` links C against the exported
  definitions and exercises three, zero, negative, wide-integer, float, mixed
  integer/float and function-pointer lists under both profiles.

- `export` now applies to global variables. `export var counter: i32 = 41;`
  publishes a writable C object under its source spelling; `export let` and
  `export const` publish read-only storage. A global that is not exported keeps
  its module-mangled private symbol, so ordinary Kyn globals stay invisible to
  the linker, exactly as before. Because the object is C-visible, its type is
  checked as an ABI boundary and an unsupported layout is rejected with `E0476`
  instead of being laid out at offsets C would disagree with.

- Function values now cast to and from raw pointers and integer addresses.
  `get_callback() as fn(i32) i32` names the signature of a pointer C handed out
  as `void *`, and `kyn_double as *u8` (or `as usize`) erases a function value
  back to the address C expects. A function value is one `ptr`, so both
  directions change the meaning without emitting an instruction. `as` still
  refuses to convert between two signatures and from an aggregate to a
  function value (`E0447`).

- The entry point's signature is now checked (`E0477`). `main` is the function
  the C runtime calls, so it may take `argc: i32` and `argv: **u8` and must
  return `i32`; a `f64` return, a `*u8` `argv`, a `u64` `argc` or a third
  parameter previously passed the type checker and then misbehaved at run time.
  Only the unmarked `main` of the root module is checked — an `export fn main`,
  an `extern fn main` and a library's `main` are ordinary functions.
- `argc`/`argv` themselves were already delivered correctly by the C ABI and are
  now documented and covered: a program reads its command line, including
  `argv[argc] == null` and empty arguments, and `kync run ... -- args` passes
  them through.

### Fixed
- An aggregate initializer now accepts any expression of the aggregate's own
  type, not only a literal. `Wrap { inner: i }` where `i` is an `Inner` variable,
  and `Wrap { arr: a }` where `a` is an array, previously failed with an
  "internal: expected an aggregate initializer" error at lowering time — a
  pre-existing defect, independent of unions, that the union work made easy to
  reach. The value is copied byte-wise, the same move the C ABI uses for a
  by-memory aggregate, so there is no second representation to keep in step.
- Signed division by a type whose minimum has no positive counterpart no longer
  breaks compilation. Lowering the `INT_MIN / -1` guard computed the minimum as
  `-(1 << (bits - 1))`, which overflows for `i128` and made the **compiler**
  panic on any `i128` division (the check exists to trap that case at run time).
  The minimum now comes from the type, so `i128` division compiles and
  `i128` `INT_MIN / -1` traps like every narrower width. In the same family, the
  most negative literal of a signed type was lowered as `0 - magnitude` with an
  overflow check, so `let m: i128 = -170141183460469231731687303715884105728;`
  trapped at run time in a checked build; negating a literal now folds to the
  value the type denotes. Covered by `division_minimum_widths` (exact halving at
  five widths) and `runtime_division_i128_min` (the trap), plus a backend test
  per behaviour.


- `language-reference.md` §3.5 named the wrong diagnostic for a non-constant
  global initializer: it said `E0419`, which is the code for a local of type
  `void`, while the compiler emits `E0412` ("global initializer is not
  constant"). The table in `diagnostics.md` was already right and only the
  language reference disagreed, so the reference now matches the compiler.
- A folded constant integer now lowers with the signedness it actually has. A
  `comptime_int` carries no width or sign in the type system, and the overflow
  and shift checks read `intInfo()` directly, which answers `bits = 0, signed =
  false`. Concrete consequences: any `-` on literal operands emitted an unsigned
  `usub`, so `1 - 2 + 3` trapped instead of evaluating to 2 while the same
  expression over named variables was fine; and a shift by a constant compared
  its amount against `0`, so `3 | 1 << 2` always trapped. Both go through one
  helper that names the width and sign a value is lowered with, which also
  covers `char` and enums.
- `E0420` ("local needs a type or an initializer") is now the code that reports
  that condition. The parser checked it first and emitted `E0216`, so the
  analyzer's own check could never run: the documented `E0420` was unreachable
  and one rule had two codes. The rule lives in the analyzer, where the rest of
  the declaration rules are.
- `bool` ↔ float casts now compile, in both directions and at every width. The
  two were broken in different ways: `float as bool` was accepted by the type
  checker and then failed with `E0605 internal: unsupported cast from the
  semantic layer`, and `bool as f32` / `bool as f64` emitted `zext i1 ... to
  double`, which is not valid IR, so no module containing one could assemble. A
  `bool` now widens to `i32` and converts unsigned; a float compares
  unordered-or-not-equal against zero, so a NaN converts to `true` as C's
  `(_Bool)` does. A whole-program differential sweep of every numeric cast pair
  (182 local, 72 global) now compiles, and the values were checked at runtime
  across the C boundary.
- A constant cast in a global initializer now folds into the destination
  category instead of keeping the source representation. `const WIDE: f64 = 3
  as f64` emitted `constant i32 3` and failed to assemble, and the same applied
  to `1.5 as bool`, `true as f64` and any other pair that crosses from integer
  to float or to/from `bool`. A cast chain also truncates at each step, so
  `3.9 as i32 as f64` is `3.0`.
- `kyn-build` now hashes the C headers a target includes, transitively. Editing
  a header used to leave the previous object in place and print `up to date`, so
  the build reported success while the binary still ran the old code — the
  documented caveat is gone rather than restated. Quoted includes are resolved
  the way the C compiler resolves them (the including file's directory first,
  then `include_dirs`); angle-bracket includes name system headers and are not
  followed. `examples/` and existing projects rebuild only when something they
  actually include changes.
- A struct initializer naming the same field twice is now `E0404`. The
  documentation has always required "every field specified exactly once", but
  the type checker accepted the repetition and let the last value win, so
  `Point { x: 1, y: 2, x: 3 }` compiled to `x == 3` instead of reporting the
  mistake. The rule covers nested initializers too.
- An integer-to-pointer cast (`usize as *u8`), documented and accepted by the
  type checker, reached the back end as `E0605 internal: unsupported cast`:
  the lowering table had no destination-pointer arm even though the emitter
  already knew `inttoptr`. Integer-to-function-value casts were affected for the
  same reason and are covered by the new cast support.
- A `u128` constant above `i128`'s maximum crashed the back end
  (`integer does not fit in destination type`) instead of being emitted. The
  constant path now preserves the bit pattern, which the emitter already renders
  back in the unsigned domain, so a `u128` global maximum is representable.
- The same value was rejected with `E0440` when it appeared as a literal next to
  an already-typed `u128` operand
  (`top != 340282366920938463463374607431768211455`), because literal adaptation
  went through a signed extraction that has no spelling for it. Adaptation now
  consults the unsigned magnitude first; values that genuinely do not fit are
  still rejected.

## [0.1.0-alpha.5] - 2026-11-12

Explicit code-generation targets, variadic `extern` declarations and
first-class function values.

### Added

- `kync --target <triple>` selects the code-generation target for `emit-obj`,
  `build` and `run`. The triple uses Zig's spelling (`x86_64-linux-gnu`); the
  vendor-qualified spelling Clang and GCC print is accepted and normalised, and
  an unparseable triple is a `kyn: unknown target` error with exit status 2.
  The flag is passed to the external assembler, because the emitted module
  carries no triple or datalayout and an assembler overrides both silently from
  its own `-target` — so the IR cannot direct code generation. The same IR
  therefore yields an `ELF64` `x86-64` or `AArch64` object depending only on
  that flag, which the integration suite verifies by reading `e_machine` from
  the produced object.
- A target without the System V aggregate ABI rejects an aggregate crossing
  `extern`/`export` with `E0473` instead of lowering the host convention for
  another machine. Scalar boundaries and non-`extern` code cross-compile
  unchanged. The backend and the type checker read the target from one place:
  the previous build-target constant was removed, because a second source of
  truth would let a cross-compilation lower the wrong convention silently.
- First-class function values and indirect calls. `fn(P) R` is a type, a
  function name decays to a value where a value is expected, and the value can be
  stored in a struct, passed to and returned from Kyn functions, handed to and
  received from C, compared with `null`, and called. A function value is one
  `ptr` at the C boundary, so the same declaration serves both directions; a
  *declared* function is still called by its symbol, so direct calls keep their
  declaration and the linker resolves them as before. An indirect call carries
  its own signature in the IR because there is no declaration to read it from,
  and it goes through the same null check as a dereference, so calling an unset
  callback traps instead of jumping to address zero. Two function types are
  compatible only when the whole signature matches, and the diagnostic prints
  both signatures instead of the word `fn`. Nested signatures
  (`fn(fn(i32) i32, i32) i32`) and `void` returns work. Casting between a raw
  pointer and a function value remains unsupported.

- Variadic `extern` declarations: `extern fn printf(format: *const u8, ...) i32;`
  now parses, type-checks and links, so C functions with a trailing unspecified
  argument list are callable from Kyn. The trailing arguments go through the C
  default argument promotions — `i8`/`i16`/`bool`/`enum` → `i32`, `u8`/`u16` →
  `u32`, `f32` → `f64`, with `i64`/`u64`/`f64`/pointers unchanged — and the call
  passes exactly that promoted type, so `%f` reads the `double` it expects and a
  narrow integer fills its register. The fixed parameters keep their declared
  types and aggregate classification. An aggregate, a fixed array or a slice in
  the variadic tail is rejected (`E0475`), as is a bare `null`, because none has
  a default promotion and each would arrive in a form the callee never agreed
  to; calling with only the fixed parameters remains legal. A variadic
  declaration must be `extern` and must have at least one fixed parameter
  (`E0474`), since a Kyn body and an `export` both have a fixed signature and
  would have to receive an argument list of unknown shape. `...` is its own
  token, so `..` ranges are unaffected. Integration fixture `cabi_variadic`
  compares Kyn's formatting against C's own `snprintf` for the same arguments,
  and the promotion guard is mutation-checked at the unit and integration level.

### Fixed

- `CHANGELOG.md` recorded the three increments above under `[0.1.0-alpha.4]`,
  a section that is already tagged and published. The tag predates them, so a
  reader of the published release would have been told that `--target`,
  variadic `extern` declarations and function values ship in a version that
  does not contain them. They now live under the version that does.

## [0.1.0-alpha.4] - 2026-11-10

System V aggregate classification by scalar leaves, fixed-array and 16-byte
integer members, and prebuilt release installers.

### Added

- C ABI support on `x86_64` Linux for a struct whose only member is a
  sixteen-byte integer. `{ a: i128 }` fills both eightbytes, so the System V
  leaves make it one 16-byte INTEGER and it now travels as `i128`, matching
  Clang's classification of `struct { __int128 a; }` instead of being rejected.
  Integration fixture `cabi_wide_integer` passes values in both directions,
  including one built entirely by the C side, and calls back into Kyn to check
  the arithmetic; the `u128` extremes cross the boundary both inside a struct
  and as a plain scalar. Its guards are mutation-checked on each side.

- C ABI support on `x86_64` Linux for fixed-array struct members. An array
  field contributes one scalar leaf per element, exactly as that many
  consecutive members would, so `{ [2]i8, f64 }` is a packed INTEGER eightbyte
  followed by an SSE double (`i64, double`), `{ [3]i16 }` is one INTEGER
  eightbyte, `{ [3]i32 }` is `{ i64, i32 }`, `{ [2]f32 }` is `<2 x float>`,
  `{ [2]f64 }` is `double, double`, `{ [2]*const u8 }` is `ptr, ptr`, and a
  layout wider than 16 bytes (`{ [4]i64 }`) uses `byval`/`sret` with matching
  alignment. Nested arrays and arrays of aggregates expand recursively.
  Array length participates in the layout without an arbitrary size cap: the
  element size is multiplied with an overflow check instead. A *bare* array
  parameter stays rejected (`E0473`), because C decays an array parameter to a
  pointer, and a struct wrapping the array is the supported form.
  Integration fixture `cabi_array_members` covers nine array shapes plus a
  `{ [1]i64, [1]f32 }` case in both directions; its guards are mutation-checked
  against one-leaf-per-array, array-size-as-element-size and a pair-slot offset
  change. A `sret` call now returns `void` in the emitted IR instead of naming
  the aggregate result type, which had produced invalid IR and silently zeroed
  results.
- C ABI support on `x86_64` Linux for pointer registers and narrow second
  slots in two-eightbyte aggregates. The eightbyte classification now records a
  pointer leaf as its own register kind, so a pointer is never narrowed to a
  neighbouring integer member width: `{ *u8, i64 }` lowers to `ptr, i64`,
  `{ i8, *u8 }` to `i8, ptr`, `{ *u8, *u8 }` to `ptr, ptr`, `{ *u8, f64 }` to
  `ptr, double`, `{ f32, *u8 }` to `float, ptr`, and `{ i32, i32, *u8 }`
  merges its first eightbyte to `i64, ptr`. A 12-byte aggregate whose second
  eightbyte carries a single leaf narrower than a register transports only that
  width, so `{ f32, f32, i16 }` uses `<2 x float>, i16`, `{ f32, f32, i8 }`
  and `{ f32, f32, bool }` use `<2 x float>, i8`, and the mirrored
  `{ i16, f32, f32 }` / `{ *u8, f32, f32 }` / `{ i32, f32, f32 }` orders
  reverse the registers; the padding bytes of the 16-byte slot stay untouched.
  Integration fixtures `cabi_pointer_members` (exit 199) and
  `cabi_pair_slot_widths` (exit 215) cover both directions, including the
  single-member and odd-width layouts the shape-space probe never generated
  (lone `*u8`, `i16`, `f32`, `f64`, `{ i16, i16, i16 }`, `{ i8, i8, i8 }`).
  Pointer identity is verified through C, because a by-value aggregate is
  copied at the call. The shared `AbiSlot` model replaces the duplicated scalar
  enumeration, and a classifier unit test asserts the exact register sequence
  for 21 shapes.
- C ABI support on `x86_64` Linux for nested members in the C ABI: the
  register of an eightbyte is now decided by the *leaves* it carries, with
  nested structs flattened into their members exactly as Clang does. A nested
  integer member travels at its own width (`{ struct { short x; } a; long b; }`
  → `i16, i64` with a `{ i16, i64 }` return), a nested `f32` travels as a
  scalar (`{ struct { float f; } a; long b; }` → `float, i64`), and a nested
  `f64` pair travels as two scalars (`{ struct { double x; double y; } pair; }`
  → `double, double`). The boundary classification now derives every
  eightbyte register from the leaf model, which replaces the previous
  member-shape rules and also accepts the merged-INTEGER eightbyte shapes
  Clang supports. The negative fixtures `abi_sse_integer_param` and
  `abi_sseup_pair` became the positive fixture `cabi_nested_sse_widths`
  (exit 57), which covers the nested layouts in both directions.
- `packaging/`: release-archive tooling and installers for the prebuilt
  toolchain. `packaging/make-dist.sh` builds `dist/kyn-<version>-linux-x86_64.tar.gz`
  and `dist/kyn-<version>-windows-x86_64.zip` (ReleaseSafe, version read from
  `build.zig.zon`), stages `bin/kync` + `bin/kyn-build` with `LICENSE`,
  `INSTALL.md` and the installers, verifies the Linux archive end-to-end
  (extract, `install.sh --prefix`, installed `--version` runs and an optional
  `hello.kyn` smoke test) and validates the Windows zip structure and PE
  headers, printing SHA-256 sums. Ships `install.sh` (POSIX; Linux, macOS and
  Git Bash), `install.ps1` (Windows; per-user install under
  `%LOCALAPPDATA%\Programs\Kyn`, adds `bin` to the user `PATH` unless
  `-NoPath`, supports `-Uninstall`) and `install.bat` (cmd.exe wrapper).
  Both installers verify the installed binaries with `--version` and fail
  loudly otherwise. The Windows native build path remains untested; the
  supported native target is `x86_64-linux`.
- C ABI support on `x86_64` Linux for structs whose two eightbytes each carry
  exactly one integer leaf (`.small_2s` eightbyte classification, 16 bytes):
  each leaf is passed in its own register at its own width and the aggregate
  returns as the matching pair. `{ i8/u8, i64 }` lowers to `i8, i64`
  parameters and a `{ i8, i64 }` return, `{ i16/u16, i64 }` to `i16, i64` /
  `{ i16, i64 }`, `{ i32, i64 }` / `{ u32, u64 }` to `i32, i64` /
  `{ i32, i64 }`, and the reversed layouts `{ i64, i8/u8 }`,
  `{ i64, i16/u16 }` and `{ i64, i32/u32 }` to `i64, i8` / `i64, i16` /
  `i64, i32` with the matching pair returns, matching Clang's System V
  lowering as verified against Clang IR probes for all six signatures. Nested
  integer members are flattened into their leaves like Clang does, so
  `{ struct { short x; } a; long b; }` lowers to `i16, i64` parameters and a
  `{ i16, i64 }` return, while a nested member with more than one leaf keeps
  the packed form. Six boundary transport types (`{ i8, i64 }`, `{ i16, i64 }`,
  `{ i32, i64 }`, `{ i64, i8 }`, `{ i64, i16 }` and `{ i64, i32 }`) carry the
  pair values. The integration fixtures `cabi_small_pair_widths` (exit 5) and
  `cabi_nested_pair_widths` (exit 96) cover argument and return paths in both
  directions for the direct and the nested layouts.
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
- Boolean values stored into memory are zero-extended to a full `i8` at every
  `store` now. Previously a `bool` field or local was stored as a raw `i1`,
  leaving the upper seven bits of its byte undefined; passed across an
  `extern`/`export` C ABI boundary as part of a packed `i64` (the current
  lowering for merged-INTEGER eightbytes) those garbage bits made the byte
  indistinguishable from a full `i8` to the C side, which reads `_Bool` as a
  full byte. Every bool memory store now emits `zext i1 -> i8` followed by an
  `i8` store, restoring the full-byte definition Clang requires at the C ABI,
  verified by generated IR and by the `cabi_multi_merge_bool` fixture.
- C ABI support on `x86_64` Linux for exactly two direct small members at
  natural offsets 0/8 (16 bytes), signedness irrelevant, now including a
  singleton `bool` member: `{ bool, f64 }` lowers to `i8, double` parameters
  and a `{ i8, double }` return; the reverse `{ f64, bool }` uses
  `double, i8` and `{ double, i8 }`. Clang IR probes confirm both signatures.
  Singleton `enum` members also pass at their backing integer width (`i8`,
  `i16`, `i32`, `i64`; signedness irrelevant, `enum : uint8_t`/`uint16_t`
  and unannotated defaults), like their backing integral; verified with
  Clang IR probes for all eight signatures. Coverage fixtures
  `cabi_enum_e8_f64`, `cabi_enum_e64_f64` and `cabi_enum_e8_f32f32` cover
  argument and return paths in both directions.
- C ABI support on `x86_64` Linux for aggregates with two or more
  smaller-INTEGER members packed into one eightbyte followed by a single
  `f32` or `f64` in the next eightbyte, with no other member in that slot.
  Such layouts lower as `( i64, float )` parameters with a
  `{ i64, float }` return or `( i64, double )` parameters with a
  `{ i64, double }` return, matching Clang's packed-`INTEGER` eightbyte
  then `SSE` scalar slot.
- C ABI support on `x86_64` Linux for singleton INTEGER aggregates
  (`.small_1` eightbyte classification, size ≤ 8): passed and returned at
  the exact member-width scalar width (1→`i8`, 2→`i16`, ≤4→`i32`, otherwise
  `i64`), matching Clang's exact-size INTEGER registers for each of the 1024
  value combinations (`i8`, `i16`, `i32`, `i64`). No new boundary classes or
  transport types are introduced — the existing `.small_1` lowering now emits
  the sized scalar where it previously always emitted `i64`. Integration
  fixtures `cabi_small_singleton` (exit 38) and `cabi_small_singleton_u8`
  (exit 42) cover both directions in both widths. Clang IR probes confirm the signatures for three-
  and four-member runs (`{ i32, i32, f64 }`, `{ i16, i16, f64 }`,
  `{ i8, i8, f64 }`, `{ i32, i32, f32 }`, `{ i16, i16, i16, i16, f64 }`,
  `{ i16, i16, i16, i16, f32 }` and the reverse). Integration fixtures
  `cabi_packed_i64_f64` and `cabi_packed_i64_xs_i16_f64` cover
  argument and return paths in both directions. Negative `E0473` fixtures
  moved to singleton-arrays to preserve rejection coverage.
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
  layouts use their member width, and a singleton `bool` member is now
  accepted as a full `i8` at the boundary (see the bullet below). Negative
  `E0473` fixtures moved from a now-supported `{ i16, f64 }` first to a
  singleton-`bool` layout, then to a singleton-`enum` layout when singleton
  `bool` became supported as well.
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

### Fixed

- The compiler crashed on any 128-bit integer literal. `IntInfo.max()` shifted
  `1 << 128` and `IntInfo.min()` negated the minimum of `i128`, both of which
  overflow, so `let x: i128 = 1;` aborted with an integer-overflow panic. The
  bounds are now computed in the unsigned domain (`max` returns `u128`), and a
  `minMagnitude` accessor supplies the most negative literal without negating.
- A `u128` literal above `i128`'s maximum aborted the back end, because the
  value was truncated into the signed representation on the way to the IR. The
  bit pattern is now carried intact and rendered back in the unsigned domain
  for an unsigned 128-bit type, so `let x: u128 = 340282366920938463463374607431768211455;`
  compiles and compares correctly.
- The robustness corpus could not have found either crash: its seed program
  mentioned no 128-bit type. It now carries a second seed built from `i128` and
  `u128` extremes, mutated in alternating slices and also checked verbatim, so
  a regression in the bound arithmetic reports as a crash rather than passing.

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
