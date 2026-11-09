# Kyn safety model (v0.1)

Kyn's safety philosophy is **Verifiable Safety**: report what can be proven at
compile time, keep runtime costs explicit, and never claim a check that does
not exist.

## 1. Profiles

`kync` and `kyn-build` accept four profiles:

| Profile   | Native flags | Static analyzer | Runtime checks |
| --------- | ------------ | --------------- | -------------- |
| `debug`   | `-O0 -g`     | always on       | always on      |
| `safe`    | `-O2`        | always on       | always on      |
| `release` | `-O3`        | always on       | always on      |
| `fast`    | `-O3`        | always on       | always on      |

Profiles currently control Clang optimization only. Implemented runtime checks
are enabled in every profile; no profile removes a check silently. The
remaining unimplemented categories (for example checked initialization and
use-after-free) still belong in the future runtime-check layer.

> A profile may change the cost of a check, or make it explicit, but no
> profile may silently remove a check that the language promises.

The intended profile distinction, if and when differing policies are added,
is:

- `debug`: all checks, no optimization, debug info.
- `safe`: all checks, optimization as permitted by LLVM.
- `release`: all checks, unless a check is documented as removable under a
  specific profile.
- `fast`: only checks required for defined behavior; any removal must be
  documented, opt-in and observable.

Until a differing policy is specified, implemented runtime checks are enabled
in every profile.

### 1.1 Runtime checks implemented today

The backend emits checks before the affected operation:

- Dynamic fixed-array and slice indexes are bounds-checked. An index below
  zero or at or above the array/slice length calls `llvm.trap()`.
- Subslice bounds (`base[start..]`, `base[..end]`, `base[start..end]`) are
  checked against the base length; invalid ranges trap. Full-range `base[..]`
  uses the base length directly without a redundant bounds branch.
- Integer addition, subtraction and multiplication trap on signed and unsigned
  overflow. Integer negation is checked as `0 - x`.
- Integer division and remainder check the divisor. A zero divisor traps.
- Signed integer division and remainder also trap on `INT_MIN / -1`.
- Dynamic shift amounts are checked against the integer width. A negative or
  out-of-range amount traps.
- Dereferencing or slicing a pointer that is exactly `null` traps. This
  includes `*p`, `p->field`, `p[index]`, `p[..]` / `p[start..end]`, and
  `p as []T`. Provable null dereferences are diagnosed at compile time with
  `E0506`; variable provenance is not tracked yet, so dynamic null cases trap
  at runtime.

Traps use LLVM's `llvm.trap()` intrinsic, which lowers to a CPU trap and
terminates the process. There is no unwinding, recovery or handler in v0.1.
On Linux x86-64, the integration suite observes SIGILL and records the
process status as `132`.

## 2. Compile-time checks that are implemented

The static analyzer (`compiler/analyzer.zig`) runs after type checking and
before IR generation. A program with analyzer **errors** fails compilation.

### 2.1 Possibly uninitialized reads (`E0501`)

The analyzer tracks definite initialization per local symbol through
statements and branches:

- declarations with an initializer mark the symbol initialized;
- assignments mark the target initialized;
- after `if`/`else`, a symbol counts as initialized only if it is initialized
  on both paths;
- after a loop body, the state from before the loop is kept, because the body
  may execute zero times;
- function parameters are treated as initialized.

A read of a local that may be uninitialized is `E0501`. This is a conservative
may-analysis, not a proof of correctness. It intentionally does not attempt
interprocedural analysis, and it does not track initialization through
arbitrary pointer writes.

### 2.2 Provable division by zero (`E0503`)

If the right operand of `/` or `%` is a constant zero after literal decoding,
the expression is rejected.

### 2.3 Constant overflow (`E0505`)

For typed integer expressions whose operands are compile-time constants, the
analyzer computes the result in a wider integer and rejects it if it does not
fit the expression's type. Unary negation is checked the same way.

### 2.4 Shift range (`E0504`)

A constant shift amount outside `[0, bits)` for the left operand type is
rejected.

### 2.5 Constant array and slice bounds (`E0502`)

Indexing a fixed-size array with a constant index outside `[0, length)`,
indexing a slice with a negative constant index, or slicing with constant
invalid bounds (`start < 0`, `end < 0`, `start > end`, or a bound exceeding a
statically known array length) is rejected. Pointer indexing is not statically
bounded.

### 2.6 Unreachable statements (`W0501`)

Statements after a `return`, `break` or `continue` in the same block are
reported as warnings. Trivial empty statements are skipped. Warnings do not
fail compilation.

### 2.7 Constant conditions (`W0502`)

An `if` or `while` condition that folds to a constant boolean is reported as a
warning. It is not an error.

### 2.8 Provable null dereferences (`E0506`)

When the operand of a dereference, field access through a pointer, pointer
index, array-pointer slice, or array-pointer-to-slice cast can be proven to be
exactly `null` from the expression text, the compiler rejects the program.
Example: `*(null as *i32)` or `(null as *[4]i32)[..]`. The analysis does not
prove arbitrary runtime pointer provenance, but any pointer exactly `null` is
trapped dynamically when dereferenced or sliced.

## 3. Checks that do not exist yet

The following are **not** checked at runtime or, in the dynamic case, at
compile time:

- pointer arithmetic bounds;
- dangling pointer and use-after-free;
- double free and leaks;
- pointer alignment;
- uninitialized reads that the conservative analysis cannot prove;
- data races;
- invalid pointer provenance after integer casts.

These are undefined behavior in v0.1. The compiler does not insert traps,
panic handlers, unwinding tables or a safety runtime. Programs that need these
guarantees must check explicitly:

```kyn
fn read(array: *const i32, length: usize, index: usize) i32 {
    if (index >= length) {
        return 0; // explicit bounds policy
    }
    return array[index];
}
```

## 4. Diagnostics and exit behavior

- Errors are printed to stderr as `path:line:column: error[CODE]: message`
  with a source excerpt and caret.
- Any error stops compilation before native code is produced.
- Warnings are printed but do not change the exit status.
- The compiler exits non-zero on diagnostics; `kync check` returns success only
  when no error was reported.
- Integration tests assert the exact diagnostic code for every negative case,
  so codes are part of the tested contract.

Diagnostic ranges:

| Range | Stage |
| ----- | ----- |
| `E01xx` | lexer |
| `E02xx` | parser |
| `E04xx` | name resolution and type checking |
| `E05xx` / `W05xx` | static analyzer errors / warnings |
| `E06xx` | compiler-internal backend errors |

## 5. Runtime check design (planned)

The planned runtime-check layer must satisfy these constraints:

1. **Explicit policy.** Each check category (bounds, overflow, division,
   null/deref, initialization) has a documented profile policy.
2. **Predictable lowering.** Checks lower to ordinary branches and a trap or
   call to a documented handler; no hidden unwinding through user frames.
3. **Observable removal.** If a profile removes a check, the removal is
   documented and testable; it is never an undocumented optimization.
4. **No silent UB introduction.** A profile that claims a check keeps it,
   unless the operation is already statically proven safe.
5. **Testable.** Every check category gets positive (traps) and negative
   (proven-safe) integration tests in each profile that enables it.

Implemented runtime checks (fixed-array and slice indexing/subslicing bounds,
signed and unsigned integer addition/subtraction/multiplication, checked
negation, checked division, shift bounds, and exact-`null` pointer checks) are
emitted in every profile. Dereferencing a dangling, misaligned or wild
non-null pointer remains undefined behavior.

## 6. Verification strategy

- Unit tests cover the lexer, parser, type checker and analyzer directly.
- Integration tests compile, link and execute positive programs and compare
  exit status/stdout.
- Negative tests assert that a specific code is emitted for a specific invalid
  program.
- The four profiles are run on a representative executable to ensure the
  pipeline works in each configuration.
- A hybrid Kyn + C + Zig project is built and executed, including an
  incremental no-op rebuild.
- CI runs formatting, build, unit tests and integration tests.

Passing tests demonstrate the covered behavior only. They are not a proof of
the absence of bugs, and they do not turn unchecked runtime operations into
safe ones.
