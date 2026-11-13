# Design: the callee side of variadics

Status: **design, not implemented.** This document decides the language surface,
the ABI and the diagnostics for receiving a variable argument list. It is the
third item on the roadmap and the first that needed a written design rather than
a sweep, because it is the first feature that adds to the *type system* and the
*calling convention* at once.

Nothing here is claimed as done. §9 lists the validation that already exists —
measurements taken so the design rests on facts — and what remains to be built.

## 1. Why this needs a design

`extern fn printf(format: *const u8, ...) i32;` already works: Kyn *calls* a C
variadic, and the call site promotes each trailing argument to the C default
promotions (`abi.md` §7). Receiving such a call is a different problem, and three
of its questions have no answer in the current language:

1. **What type is a retrieved argument?** `va_arg` needs a type at the call site.
   If Kyn had generics this would be `va_arg::<i32>()`. It does not.
2. **What is the state the retrieval advances?** C's `va_list` is a mutable
   cursor. Kyn has no mutable-value parameters and no implicit copying rules for
   an opaque handle, so its ownership has to be stated.
3. **Which functions may be variadic?** Today only `extern` may, and the reason
   recorded in the code is that a Kyn function "has a fixed signature". That
   reason stops being true once a body can read the list, so the rule must be
   restated rather than quietly relaxed.

## 2. Measurements the design rests on

Taken on this repository's toolchain (LLVM via `clang` 22.1.8, `x86_64` Linux),
by compiling C and inspecting the IR and by hand-writing the IR Kyn would emit
and calling it from C. These are facts about the target, not opinions:

- `va_list` on `x86_64` System V is **`[1 x %struct.__va_list_tag]`** where
  `%struct.__va_list_tag = type { i32, i32, ptr, ptr }` — a 24-byte struct with
  8-byte alignment. It is passed to the `llvm.va_start.p0` / `llvm.va_end.p0`
  intrinsics **by pointer** (a `ptr` to the array's first element), not by value.
- `va_arg ptr %ap, <ty>` is a **first-class instruction** in this LLVM version
  (no `llvm.va_arg` intrinsic is needed, and the older intrinsic would be
  rejected). It lowers to the register-save-area / overflow-area walk shown in
  `clang`'s own output.
- A prototype was assembled and executed: an `export`-style variadic summing
  three `i32` arguments returned 42 with **three, zero and negative** arguments;
  a mixed `i32` then `f64` prototype returned 42.5 correct to the bit, which
  exercises both the integer-register and the SSE-register paths of the
  register save area.
- The C ABI requires the callee to have a fixed parameter before `...`; ISO C
  says the same. Both `clang` and this compiler already enforce it.

The consequence for the design is the important one: **the whole feature is
reachable with two intrinsics (`va_start`, `va_end`) and one instruction
(`va_arg`)**, all of which this toolchain accepts. No runtime library, no helper
function, no platform-specific code generator is required.

## 3. Language surface

Two declarations and one expression, and nothing else.

### 3.1 A variadic function may be `export`

```kyn
export fn sum(count: i32, ...) i32 {
    var total: i32 = 0;
    var i: i32 = 0;
    while (i < count) {
        let value: i32 = va_arg();
        total += value;
        i += 1;
    }
    return total;
}
```

`export` is the only way a Kyn function may be variadic, and `extern` keeps its
current meaning (a declaration with no body). `E0474` narrows accordingly: it
now fires for a *non-exported* variadic with a body, rather than for every
variadic with a body. This is not a relaxation of the old rule — the old rule
existed because there was no way to read the arguments, so a Kyn variadic would
have had a fixed signature in fact if not in form. Once `va_arg` exists, the
exported function really does have an unspecified inbound list, and `export` is
exactly the declaration that says "C calls me".

`fn` (internal linkage) and a bare `extern` body stay rejected, because neither
has a C caller to supply an argument list: an internal function's callers are
all in Kyn and could pass a fixed list, so allowing it would legalise a function
whose variadic tail is provably never used.

### 3.2 `va_arg()` is an expression typed by its context

```kyn
let value: i32 = va_arg();
total += va_arg();              // context: i32
let ratio: f64 = va_arg();      // context: f64
```

This is the decision the design exists for. Three candidates were considered:

- **(a) `va_arg()` with the type taken from context** — chosen.
- (b) `va_arg::<i32>()` turbofish — rejected: it would add generic syntax to the
  language for one builtin, and Kyn has no other use for angle brackets in
  expression position.
- (c) One builtin per type (`va_arg_i32()`, `va_arg_f64()`, …) — rejected as
  duplication: it is a spelling of the type system in the standard surface, and
  each new primitive would need a new name.

Option (a) fits the rule the language already uses everywhere else: an integer
literal takes its type from context, a `null` takes its pointer type from
context, and an empty `va_arg()` takes its type from context in exactly the same
way. **No new type-system machinery is needed** — the expression's type is the
type the checker is already prepared to assign, which is why this is a
`builtin` expression and not a generic call.

Requiring context is what makes the retrieval well-defined rather than inferred
after the fact. A `va_arg()` in a position with no expected type has no
defensible default (guessing `i32` would silently misread a `double`), so it is
rejected — see `E0478` below.

### 3.3 `va_list` is not a user-visible type

There is no `va_list` type in the language, no value to name, and nothing to
pass to another function. `va_start`/`va_end` are implicit: the compiler emits
them at function entry and before each `return` (and on the trap path), so the
programmer never writes them and cannot pair them wrongly. This is deliberate —
an explicit handle would need ownership rules that Kyn has no other reason to
have, and the save-area is a target detail (`abi.md` §2) rather than a language
concept.

Consequences, stated so they cannot be discovered as surprises:

- A variadic body cannot forward its list to another function. Forwarding is
  spelled `v`-style in C (`vprintf`) and needs a `va_list` parameter type; that
  is a **separate, later feature** (§8).
- `va_arg()` may be called any number of times, including zero; reading past the
  arguments the caller actually passed is undefined behaviour, exactly as in C,
  and the language does not pretend to check it (§7).

## 4. Semantics of a retrieval

`va_arg()` retrieves the next argument that the caller passed and advances the
cursor. Two rules follow from the caller side that already exists:

- **The retrieval type must be a promoted type.** A caller of an `extern`
  variadic passes `i8`/`i16`/`bool`/`enum` as `i32`, `u8`/`u16` as `u32`,
  `f32` as `f64`, and `char` as `u32` (`sema.promoteVariadic`, `abi.md` §7). A
  callee that retrieved one of those as `i8` would read the right bytes of the
  register save area but interpret them with the wrong width, so the retrieval
  types are restricted to what a caller can actually have passed: the integer
  types `i32 i64 u32 u64 isize usize`, the floats `f32 f64`, `*T`, `**u8` and
  the function-value types. Narrower integers and `bool`/`char`/`enum` are
  rejected with a message that names the promoted width to use.
- **The retrieval type fixes the ABI class.** An integer or pointer type reads
  from the general-purpose area, `f32`/`f64` from the SSE area. Mixing them is
  legal and is what the measured prototype did (`i32` then `f64`), because the
  two areas advance independently — which is why `va_arg ptr %ap, i32` is the
  right spelling and a bitcast of a `double` slot is not.

## 5. ABI

For an `export fn` with `...`:

- the LLVM definition carries the `...` marker, so C sees a variadic symbol;
- at entry the function allocates `[1 x %struct.__va_list_tag]`, aligned 16 —
  **the array, not the tag** — and calls `llvm.va_start.p0` with a pointer to
  its first element;
- each `va_arg()` emits one `va_arg` instruction with the retrieval type;
- `llvm.va_end.p0` runs before every `return` and on the trap path, so the
  compiler's own bookkeeping is symmetric even though the programmer never
  writes it;
- the module declares `%struct.__va_list_tag`, `llvm.va_start.p0` and
  `llvm.va_end.p0` only when a variadic body exists, so a module without one
  keeps emitting exactly what it does today (determinism of existing output is a
  property the test suite asserts).

The aggregate-parameter rules are unchanged: a fixed parameter that is an
aggregate still uses the boundary classifier (`abi.md` §5), because fixed
parameters are not affected by `...`.

## 6. Diagnostics

| Code | Message | When |
| ---- | ------- | ---- |
| `E0474` (narrowed) | variadic declaration must be `export` or `extern` | a variadic `fn` with a body, or a variadic with no fixed parameter |
| `E0478` (new) | `va_arg` needs a concrete scalar type from context | `va_arg()` where no expected type exists, or where the expected type is an aggregate, slice, `void`, or an unconstrained literal type |
| `E0479` (new) | `va_arg` retrieves the promoted width | a retrieval type of `i8`/`i16`/`u8`/`u16`/`bool`/`char`/an enum, with the promoted type named in the message |
| `E0480` (new) | `va_arg` outside a variadic function | any use in a function that is not variadic `export` |

`E0478` and `E0479` are checked in the checker, where the expected type is
known; `E0480` needs only the enclosing declaration. All three are reachable
from the parser's builtin expression, so none of them is dead code.

## 7. What this does not check

Said plainly so the safety model can stay honest:

- **Arity is not checked.** A callee that reads more arguments than the caller
  passed reads the register save area past its contents. This is undefined in C
  and stays undefined here; `safety-model.md` §3 gains a line for it.
- **The retrieval type is not checked against the passed type.** `va_arg()` in a
  variadic `export` retrieving `f64` from a call that passed `i32` is a
  programmer error with no runtime evidence to detect it — the two live in
  different save areas.
- No trap, no diagnostic, no runtime support is generated for either. The
  language's position is the same as for pointer provenance: the compiler gives
  the mechanism, the programmer owns the protocol.

## 8. Explicitly out of scope

- A `va_list` parameter type and `v`-style forwarding.
- `va_copy`.
- Retrieving an aggregate by value from the list (C allows a struct passed by
  value to be retrieved with `va_arg(ap, struct S)` on some ABIs; the class
  rules for that are a separate piece of ABI work).
- `sysv` / `aapcs` differences — the design is `x86_64` System V only, matching
  the existing aggregate rules, and a non-System V target continues to reject
  aggregate boundaries with `E0473`.
- Platform-specific `va_list` shapes other than the measured one. On a target
  where `va_list` is not `{ i32, i32, ptr, ptr }` the feature must be gated the
  same way aggregate boundaries are — by target — rather than emitting the
  wrong struct.

## 9. Validation already performed (measurements, not implementation)

- The IR shape in §5 was hand-written, assembled, linked against C and
  **executed**: three arguments → 42, zero arguments → 0, negative arguments →
  correct, and a mixed `i32`+`f64` retrieval → 42.5 exact. Both register save
  area paths were therefore exercised before any compiler code exists.
- `va_arg` as an instruction (not the removed intrinsic) was confirmed to be
  accepted by the toolchain this repository pins.
- The existing caller side (`extern` variadic declarations, promotions, `E0474`
  / `E0475`) was read in place and its promotion table is what §4 restates.

## 10. Implementation plan, in order

1. `ast`: a `builtin` expression kind for `va_arg()` (lexer/parser: a call to a
   reserved name, no new token).
2. `sema`: `E0480` in the declaration check, `E0478` from the expected type,
   `E0479` for a non-promoted retrieval type; narrow `E0474` to allow
   `export` + `...`.
3. `ir`: a `va_start` / `va_arg` / `va_end` instruction set, or an intrinsic-call
   variant, whichever keeps the emitter's `switch` exhaustive without a special
   case per target.
4. `backend`: the declaration, the entry allocation, the three emissions, and
   the `q` module additions behind a "has a variadic body" flag.
5. Tests: a unit test per diagnostic, an ABI fixture in `tests/integration/abi/`
   where C calls a variadic Kyn function with three, zero and negative
   arguments plus a `f64` in the SSE area, and a documentation pass over
   `language-reference.md` §3.3, `abi.md`, `safety-model.md` §3, `roadmap.md`
   and `CHANGELOG.md`.

Each step is independently testable, and step 4 cannot land without step 5's
fixture passing, which is the rule this project has followed for every ABI
change.
