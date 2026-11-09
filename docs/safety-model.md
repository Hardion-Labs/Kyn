# Kyn safety model (v0.1)

Kyn's safety philosophy is **Verifiable Safety**: report what can be proven at
compile time, keep runtime costs explicit, and never claim a check that does
not exist.

## 1. Profiles

`kync` and `kyn-build` accept four profiles:

| Profile   | Native flags | Static analyzer |
| --------- | ------------ | --------------- |
| `debug`   | `-O0 -g`     | always on       |
| `safe`    | `-O2`        | always on       |
| `release` | `-O3`        | always on       |
| `fast`    | `-O3`        | always on       |

Profiles currently control Clang optimization only. Runtime checks are not
implemented yet, so there is nothing for a profile to disable. The rule for
future work is strict:

> A profile may change the cost of a check, or make it explicit, but no
> profile may silently remove a check that the language promises.

When runtime checks are added, the intended distinction is:

- `debug`: all checks, no optimization, debug info.
- `safe`: all checks, optimization as permitted by LLVM.
- `release`: all checks, unless a check is documented as removable under a
  specific profile.
- `fast`: only checks that are required for defined behavior; any removal must
  be documented, opt-in and observable.

This table describes intent, not current functionality. Only the static
analyzer runs today.

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

### 2.5 Constant array bounds (`E0502`)

Indexing an array with a constant index outside `[0, length)` is rejected. The
check applies to array types known at the indexing expression; pointer
indexing is not statically bounded.

### 2.6 Unreachable statements (`W0501`)

Statements after a `return`, `break` or `continue` in the same block are
reported as warnings. Trivial empty statements are skipped. Warnings do not
fail compilation.

### 2.7 Constant conditions (`W0502`)

An `if` or `while` condition that folds to a constant boolean is reported as a
warning. It is not an error.

## 3. Checks that do not exist yet

The following are **not** checked at runtime or, in the dynamic case, at
compile time:

- dynamic array/pointer bounds;
- runtime integer overflow;
- runtime division/remainder by zero;
- null pointer dereference;
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

Until that layer exists, the documentation and README must not describe Kyn as
memory-safe or bounds-safe. The correct description is: statically typed,
explicitly checked where provable, with documented undefined behavior
elsewhere.

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
