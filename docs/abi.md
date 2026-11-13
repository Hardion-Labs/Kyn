# C ABI and interoperability (v0.1)

Kyn is designed to interoperate with C at the ABI level. There is no runtime
bridge, marshalling layer or name mangling: Kyn declarations map to native
symbols and platform calling conventions.

## 1. Declaring external functions

```kyn
extern fn puts(s: *const u8) i32;
extern fn c_add(a: i32, b: i32) i32;
extern fn malloc(size: usize) *u8;
extern fn free(ptr: *u8);
```

- `extern fn` has no body and ends with `;`.
- The Kyn name is used verbatim as the linker symbol. There is no mangling.
- Parameters and return types must have a C-compatible representation.
- Calls use the default C calling convention.
- Aggregate parameters and returns, including slices, are supported on
  `x86_64` Linux when their layout is classifiable by the current lowering.
  Every register is decided per eightbyte by the *leaves* that eightbyte
  carries, after nested structs are flattened exactly as Clang flattens them;
  the classification is described once in
  [the type system](type-system.md#8-aggregates) and the exact
  supported shapes are listed below. An eightbyte whose leaves merge to the
  `INTEGER` class uses one 64-bit integer register, with safe zero-padded
  packing for partial eightbytes. This includes a float field when an integer
  field in the same eightbyte causes the merged class to be `INTEGER`. A struct
  containing one direct `f32`/`f64` field uses scalar SSE; exactly two
  adjacent direct `f32` fields use one `<2 x float>` SSE/SSEUP value; exactly
  three adjacent direct `f32` fields (12 bytes) use one `<2 x float>` SSE/SSEUP
  value plus one `float` SSE value, and four adjacent direct `f32` fields
  (16 bytes) use two `<2 x float>` values; and exactly two direct `f64`
  fields use two SSE registers (LLVM arguments are two `double`s and return
  coercion is `{ double, double }`). A three-field `f32` struct returns as
  `{ <2 x float>, float }` and a four-field `f32` struct returns as
  `{ <2 x float>, <2 x float> }` (both verified against Clang IR). A direct
  `{ f32, f64 }` struct with natural fields at offsets 0 and 8 uses
  `float, double` arguments and returns as `{ float, double }`; the reverse
  `{ f64, f32 }` layout uses `double, float` and `{ double, float }`. A
  direct `{ f32, i64 }` or `{ f32, u64 }` uses `float, i64` arguments and
  returns as `{ float, i64 }`; the reverse `{ i64, f32 }` / `{ u64, f32 }`
  uses `i64, float` and `{ i64, float }`; `{ f64, i64 }` / `{ f64, u64 }`
  use `double, i64` and `{ double, i64 }`; and `{ i64, f64 }` / `{ u64, f64 }`
  use `i64, double` and `{ i64, double }`. A struct whose two eightbytes each
  carry exactly one scalar *leaf* passes each leaf in its own register at its own
  width and returns as the matching pair. The register of an eightbyte follows
  the leaves it carries, exactly as Clang classifies them: one integer leaf
  travels at that leaf's width (`i8`/`i16`/`i32`/`i64`), one `f32`/`f64` leaf
  travels as a `float`/`double` SSE value, one pointer leaf travels as `ptr` and
  is never narrowed to an integer width, and an eightbyte carrying two or more
  leaves merges to a full `i64` — which is what Clang does even when one of
  those leaves is a float. Nested structs are flattened into their leaves first,
  so `{ struct { ptr inner; } value; f64 }` classifies exactly like
  `{ ptr, f64 }` and a nested `f64` pair classifies like a direct one.
  Consequently `{ i8/u8, i64 }` uses `i8, i64` and `{ i8, i64 }`,
  `{ i16/u16, i64 }` uses `i16, i64` and `{ i16, i64 }`, `{ i32, i64 }` /
  `{ u32, u64 }` uses `i32, i64`, `{ ptr, i64 }` uses `ptr, i64`,
  `{ i8, ptr }` uses `i8, ptr`, `{ ptr, f64 }` uses `ptr, double`,
  `{ f32, ptr }` uses `float, ptr`, and `{ i32, i32, ptr }` merges its first
  eightbyte to `i64, ptr`. The reversed `{ i64, i8/u8 }`, `{ i64, i16/u16 }`,
  `{ i64, i32/u32 }` and `{ i64, ptr }` layouts use `i64, i8` / `i64, i16` /
  `i64, i32` / `i64, ptr` with matching pair returns. A 12-byte aggregate whose
  second slot is narrower than a register writes only its own bytes, leaving the
  padding bytes of the 16-byte slot untouched. A
  direct `{ i8/u8, f64 }` or
  `{ i16/u16, f64 }` uses the member-width integer and `double`, and returns
  `{ i8, double }` / `{ i16, double }`; the reverse `{ f64, i8/u8 }` /
  `{ f64, i16/u16 }` uses `double, i8` / `double, i16` and returns
  `{ double, i8 }` / `{ double, i16 }`. Members smaller than 32 bits (`i8`,
  `u8`, `i16`, `u16`) and `bool` are also accepted inside `INTEGER`-merged
  eightbytes, where Clang passes the packed `i64` irrespective of member
  widths; singleton small members are passed at their own width, singleton `bool` members pass as a full `i8`, and singleton `enum` members pass at their backing integer width (`i8`/`i16`/`i32`/`i64`), like their backing integral type. Singleton `i8`/`i16`/`i32`/`i64` aggregates pass in one exact-width INTEGER argument register (size 1→`i8`, 2→`i16`, ≤4→`i32`, otherwise `i64`). Aggregates with two or more smaller-INTEGER members packed into one eightbyte followed by a single `f32` or `f64` (only the scalar in the next eightbyte) pass as `( i64, float )` or `( i64, double )`, verified against Clang probes. Exact multi-member layouts
  whose eightbytes split into an SSE-only slot and an INTEGER/merged slot
  are also supported with their probed Clang coercions: `{ f32, f32, i32 }`
  (`<2 x float>, i32` arguments and `{ <2 x float>, i32 }` returns),
  `{ f32, f32, i64 }` (`<2 x float>, i64` and `{ <2 x float>, i64 }`),
  `{ i32, f32, f32 }` and `{ f32, i32, f32 }` (merged `INTEGER` passed as
  `i64`, then `float`; `{ i64, float }` returns), `{ i32, f32, f64 }` /
  `{ f32, i32, f64 }` (merged `INTEGER` as `i64`, then `double`; `{ i64, double }`
  returns), `{ f64, i32, i32 }` / `{ f64, i32, f32 }` (`double` then merged
  `INTEGER`; `{ double, i64 }` returns), `{ i64, f32, f32 }` (`i64, <2 x float>`;
  `{ i64, <2 x float> }` returns), and `{ i32, f32, f32, f32 }` /
  `{ f32, i32, f32, f32 }` (same signature). Four-member `{ f32, f32, i32, f32 }`
  uses `<2 x float>, i64` and `{ <2 x float>, i64 }`. When one eightbyte carries
  two `f32` leaves and the other carries a single leaf narrower than a register,
  the SSE slot keeps its `<2 x float>` packing: `{ f32, f32, i16 }` uses
  `<2 x float>, i16`, `{ f32, f32, i8 }` and `{ f32, f32, bool }` use
  `<2 x float>, i8`, `{ f32, f32, ptr }` uses `<2 x float>, ptr`, and the
  reversed `{ i16, f32, f32 }` / `{ ptr, f32, f32 }` / `{ i32, f32, f32 }` runs
  use `i16, <2 x float>` / `ptr, <2 x float>` / `i32, <2 x float>`. Layouts
  outside these
  direct
  `{ f64, i32 }` or `{ f64, u32 }` struct with natural fields at offsets 0 and
  8 uses `double, i32` arguments and returns as `{ double, i32 }`; the reverse
  `{ i32, f64 }` / `{ u32, f64 }` layout uses `i32, double` and
  `{ i32, double }`. Larger supported structs use hidden `byval`/`sret`
  pointers. Slice boundaries match a C struct `{ T *ptr; size_t len; }`.
- Only the x86_64 System V calling convention is supported in v0.1.
- The C aggregate ABI is defined for the `x86_64` Linux target only. Compiling
  for another target with `--target` is supported, but an aggregate passing
  through `extern`/`export` is then rejected with `E0473` instead of being
  lowered with the host convention. Scalar boundaries and all non-`extern`
  code cross-compile unchanged.

### Variadic declarations

A C function that takes a trailing unspecified argument list is declared with
`...` after at least one fixed parameter, exactly like the C prototype:

```kyn
extern fn printf(format: *const u8, ...) i32;
extern fn snprintf(buffer: *u8, size: u64, format: *const u8, ...) i32;
```

Three rules follow from the C standard, and Kyn enforces each of them rather
than lowering something the callee would misread:

- **The fixed parameters are typed normally.** `format` is a `*const u8` and is
  passed exactly as declared, including its aggregate classification.
- **The trailing arguments go through the C default argument promotions.** An
  integer narrower than `i32` widens to `i32` keeping its signedness (`i8` →
  `i32`, `u8` → `u32`), `bool` → `i32`, an `enum` → `i32`, `char` → `u32`
  (Kyn's `char` is a 32-bit type, so it is already the promoted width), and
  `f32` → `f64`. An `i64`, `u64`, `f64` and a pointer travel unchanged. The
  promotion is not optional: a `f32` that stayed `float` would be read by `%f`
  as a `double`, and a `bool` that stayed one byte would leave the register
  half-defined. The promoted type is what the call site actually passes, so the
  emitted call and the callee agree by construction.
- **Only values C can pass are accepted.** An aggregate, a fixed array or a
  slice has no default promotion, so passing one is rejected with `E0475`
  instead of being copied onto the stack in an order the callee never agreed to;
  pass a pointer to it. A bare `null` is rejected for the same reason — it needs
  an explicit pointer type — and so is a slice, whose two words would arrive as
  an unrelated pair. Calling with only the fixed parameters is legal, since zero
  variadic arguments is a valid C call.

Every variadic declaration is a C boundary, across one direction or the other:
`extern` (Kyn calls out, with the promotions above applied at each call site)
or `export` (C calls in — see the next section). A plain Kyn function is called
only from Kyn, where the signature is fixed and checked, so it has no caller to
supply a tail and a body is rejected with `E0474`; so is a declaration with no
fixed parameter at all (the same rule ISO C applies, and without one there would
be nothing to anchor the call).

### Receiving a C variadic argument list

An `export fn` may end in `...`, and retrieves the trailing arguments with one
builtin expression, `va_arg()`:

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

- **The type comes from context.** `va_arg()` has no type of its own: it takes
  the expected type where it is written, the same way an integer literal or a
  `null` does. A position with no expected type is rejected (`E0478`) rather
  than defaulted — guessing `i32` would read a `double` out of the wrong half of
  the save area and return a plausible wrong number instead of a diagnostic.
- **Only promoted widths can be retrieved.** The caller passed `i8`/`i16`/`bool`
  as `i32`, `u8`/`u16` as `u32`, `f32` as `f64` and `char` as `u32`, so asking
  for anything narrower is rejected (`E0479`, naming the type to use). What can
  be retrieved is exactly what a caller can have passed: `i32 i64 u32 u64 isize
  usize`, `f32 f64`, `*T`, `**u8` and function values.
- **`va_arg()` is only valid in a variadic function.** The enclosing frame is
  the one thing that owns a `va_list`, so any other use is `E0480`.
- **There is no `va_list` type and no `va_start`/`va_end`.** The compiler emits
  `llvm.va_start` at entry and `llvm.va_end` before every `return` and on the
  trap path, so the program cannot pair them wrongly. A list cannot be forwarded
  to another function yet, because that would need a `va_list` parameter type.
- **The emitted representation is the x86_64 System V one:** a 24-byte, 8-aligned
  `%struct.__va_list_tag { i32, i32, ptr, ptr }` wrapped in a one-element array;
  the intrinsics take a pointer to the array, and each retrieval is a single
  `va_arg` instruction (`llvm.va_arg` no longer exists). The type and the two
  intrinsic declarations appear in the module only when a variadic body exists,
  so a program without one keeps emitting byte-identical IR.

Reading past the arguments the caller actually passed is undefined behaviour,
exactly as in C; the language does not pretend to check it. Forwarding a list
and the `v`-style convention (`vprintf`) are out of scope for v0.1. The full
rationale and the measurements behind it are in
[the callee-variadics design](design-callee-variadics.md).

### Function pointers

A function value (`fn(P) R`) has the C representation of a function pointer: one
word in an INTEGER register. It can be passed to an `extern` function, received
from one, stored in an aggregate and called indirectly:

```kyn
extern fn c_apply(op: fn(i32, i32) i32, a: i32, b: i32) i32;

export fn kyn_add(a: i32, b: i32) i32 { return a + b; }

fn main() i32 {
    return c_apply(kyn_add, 20, 22);
}
```

- The signature is part of the type, so a callback with the wrong parameter list
  or return type is rejected instead of being called with the wrong ABI.
- An indirect call names its own signature in the IR, because there is no
  declaration to read it from: `call i32 %v3(i32 21)`.
- Calling through a `null` function value traps under the same runtime-check
  policy that guards null dereferences, rather than jumping to address zero.
- A *declared* function is still called by its symbol, so an ordinary direct call
  keeps its declaration and the linker resolves it normally.

A C library usually hands a callback out as `void *`, so the signature is named
with a cast where the pointer is received, and a function value casts back to a
raw pointer (or to an integer address) where C expects one:

```kyn
extern fn get_callback() *u8;
extern fn call_through(ptr: *u8, value: i32) i32;

export fn kyn_double(x: i32) i32 { return x * 2; }

fn main() i32 {
    let handler: fn(i32) i32 = get_callback() as fn(i32) i32;
    let erased: *u8 = kyn_double as *u8;
    return call_through(erased, handler(0));
}
```

Both directions are a change of *meaning*, not of representation — a function
value is one `ptr` — so no instruction is emitted. The cast is the only way to
cross: `as` never converts between two function signatures (`E0447`), because
reinterpreting one address as a different signature would call the callee with
an argument list it never agreed to, and an aggregate never casts to one.

## 2. Exporting Kyn functions

```kyn
export fn kyn_add(a: i32, b: i32) i32 {
    return a + b;
}
```

`export fn` emits the function with external linkage under its Kyn name. It can
be called from C, Zig or another Kyn compilation unit:

```c
extern int kyn_add(int a, int b);

int main(void) {
    return kyn_add(2, 3) == 5 ? 0 : 1;
}
```

`fn main` is also emitted with external linkage so the platform entry point is
available, which is why its signature is constrained to what the C runtime
passes and reads back (`argc: i32`, `argv: **u8`, returning `i32`; `E0477`
otherwise). Other `fn` declarations use internal linkage.

### Exporting globals

`export` also applies to a global variable, which then becomes a C object
rather than a Kyn-private one:

```kyn
export var counter: i32 = 41;
export let threshold: i32 = 7;
export const limits: Limits = Limits { lo: 3, hi: 4 };
```

```c
extern int32_t counter;              /* writable */
extern const int32_t threshold;      /* read-only */
extern const struct Limits limits;   /* read-only struct */
```

- The symbol is the source spelling, exactly as for `export fn`. A global that
  is *not* exported keeps its module-mangled private name, so ordinary Kyn
  globals stay invisible to the linker.
- Mutability decides the LLVM storage class and therefore the C spelling:
  `export var` emits a writable `global`, while `export let` and
  `export const` emit `constant`. Writing through the Kyn name is checked by
  the normal immutability rules (`E0442`) rather than by the object's section,
  so a `let` cannot be reassigned from either side of the boundary.
- Because the object is C-visible, its type is a boundary: one the current
  target cannot classify is rejected with `E0476` instead of being laid out at
  offsets C would disagree with. A bare fixed-size array is the case that
  reaches that check today (the same shape `E0473` rejects as a parameter);
  pass a pointer, or wrap the data in a struct with a supported layout.
- `void` is already rejected as storage by the ordinary global rules
  (`E0411`), and a function value is an ordinary pointer, which C represents
  natively.

## 3. Type mapping

| Kyn type | C type (typical LP64) | LLVM IR |
| -------- | --------------------- | ------- |
| `void` | `void` | `void` |
| `bool` | `_Bool` | `i1` |
| `char` | `uint32_t` (Unicode scalar) | `i32` |
| `i8`/`u8` | `int8_t`/`uint8_t` | `i8` |
| `i16`/`u16` | `int16_t`/`uint16_t` | `i16` |
| `i32`/`u32` | `int32_t`/`uint32_t` | `i32` |
| `i64`/`u64` | `int64_t`/`uint64_t` | `i64` |
| `i128`/`u128` | `__int128`/`unsigned __int128` | `i128` |
| `f32` | `float` | `float` |
| `f64` | `double` | `double` |
| `usize`/`isize` | `size_t`/`ssize_t` (currently 64-bit) | `i64` |
| `*T`, `*const T` | `T *`, `const T *` | `ptr` |
| `[N]T` | `T[N]` (struct member; a bare parameter decays to a pointer) | `[N x T]` |
| `struct S` | `struct S` (by value when its ABI classes are supported) | `%struct.S` |
| `[]T`, `[]const T` | `struct { T *ptr; size_t len; }` | `%kyn.slice` (`{ ptr, i64 }`) |
| `enum E: U` | integer backing type `U` | backing integer |

Caveats:

- `char` is a 32-bit Unicode scalar in Kyn, not C `char`. For byte strings use
  `u8`/`*const u8`.
- `bool` lowers to `i1`. Some C ABIs expect `_Bool` arguments to carry
  zero-extension attributes; v0.1 does not emit such attributes. Prefer
  `u8`/`i32` in `extern` signatures when interoperating with code that is
  sensitive to this.
- `usize`/`isize` are currently fixed at 64 bits; see the type-system document.
- Plain C-layout structs up to 16 bytes are passed by value when their classes
  are supported. INTEGER-class eightbytes include float+integer fields in the
  same eightbyte; a one-field `f32`/`f64` struct uses scalar SSE, a three-field
  direct `f32` struct uses `<2 x float>, float` parameters and a
  `{ <2 x float>, float }` return, a four-field direct `f32` struct uses
  `<2 x float>, <2 x float>` parameters and a `{ <2 x float>, <2 x float> }`
  return, and a two-field direct `f32` struct uses `<2 x float>` for
  SSE/SSEUP, and a two-field direct `f64` struct uses two SSE registers.
  Exact direct layouts `{ f32, f64 }` use `float, double` parameters and
  `{ float, double }` returns; `{ f64, f32 }` use `double, float` and
  `{ double, float }`. Exact direct layouts `{ f32, i64 }` / `{ f32, u64 }` use
  `float, i64` parameters and `{ float, i64 }` returns; `{ i64, f32 }` /
  `{ u64, f32 }` use `i64, float` and `{ i64, float }`; `{ f64, i64 }` /
  `{ f64, u64 }` use `double, i64` and `{ double, i64 }`; and `{ i64, f64 }` /
  `{ u64, f64 }` use `i64, double` and `{ i64, double }`. Exact direct
  layouts `{ f64, i32 }` / `{ f64, u32 }`
  use `double, i32`
  parameters and `{ double, i32 }` returns; `{ i32, f64 }` / `{ u32, f64 }` use
  `i32, double` and `{ i32, double }`. Exact direct layouts `{ i8/u8, f64 }`
  pass the member at its width with `double`, returning `{ i8, double }`;
  `{ i16/u16, f64 }` the same with `i16`; the reverse `{ f64, i8/u8 }` /
  `{ f64, i16/u16 }` use `double, i8` / `double, i16` and `{ double, i8 }` /
  `{ double, i16 }` returns. A direct `{ bool, f64 }` or `{ double, bool }`
  passes the singleton `bool` as a full `i8`, with `{ i8, double }` /
  `{ double, i8 }` returns. A struct whose two eightbytes each carry exactly
  one scalar leaf passes each leaf at its own width in its own register,
  returning the matching pair: `{ i8/u8, i64 }` /
  `{ u8/u8, i64 }` uses `i8, i64` and `{ i8, i64 }`; `{ i16/u16, i64 }` /
  `{ u16/u16, i64 }` uses `i16, i64` and `{ i16, i64 }`; `{ i32, i64 }` /
  `{ u32, u64 }` uses `i32, i64` and `{ i32, i64 }`; and the reversed layouts
  `{ i64, i8/u8 }`, `{ i64, i16/u16 }` and `{ i64, i32/u32 }` use
  `i64, i8` / `i64, i16` / `i64, i32` with the matching pair returns. The
  register of an eightbyte is decided by the *leaves* it carries, with
  nested structs flattened into their members exactly as Clang does: an
  eightbyte with a single integer leaf travels at that leaf's width, one with a
  single pointer leaf travels as `ptr` and is never narrowed to an integer
  member width, one with several leaves travels as a full `i64` (even when a
  float is among them), an eightbyte with a single `f32` or `f64` travels as
  that scalar, and one with two `f32` leaves travels as `<2 x float>`. Nested
  members therefore follow the same rules as direct
  ones: `{ struct { short x; } a; long b; }` uses `i16, i64` and
  `{ i16, i64 }`, `{ struct { float f; } a; long b; }` uses `float, i64` and
  `{ float, i64 }`, `{ struct { char *p; } a; long b; }` uses `ptr, i64`, and
  `{ struct { double x; double y; } pair; }` uses
  `double, double` and `{ double, double }`. Exact
  multi-member layouts whose
  eightbytes split into an SSE-only slot and an INTEGER/merged slot use their
  probed Clang coercions (`{ f32, f32, i32 }`, `{ f32, f32, i64/u64 }`,
  `{ i32/u32/i64/u64, f32, f32 }`, `{ f32, i32/u32, f32 }`, `{ i32/u32, f32, f64 }`,
  `{ f32, i32/u32, f64 }`, `{ f64, i32/u32, i32/u32 }`, `{ f64, i32/u32, f32 }`
  and `{ i32/u32, f32, f32, f32 }` / `{ f32, i32/u32, f32, f32 }`).
  Larger supported aggregates use the hidden-pointer `byval`/`sret` form.
  A single-member aggregate is one eightbyte, so its leaf alone decides the
  register: a lone `*u8` member rides a full INTEGER register (emitted as an
  integer, which is bit-identical to `ptr`), and `{ i16 }`, `{ f32 }` and
  `{ f64 }` use the scalar rules above. Nested struct wrappers are classified
  by their flattened leaves, so they follow the same rules as the direct
  layouts they expand to.
  A fixed array field contributes one leaf per element, exactly as that many
  consecutive members would, so `{ [2]i8, f64 }` is a packed INTEGER
  eightbyte followed by an SSE double (`i64, double`), `{ [3]i16 }` is a
  single INTEGER eightbyte, `{ [2]f32 }` is `<2 x float>`, `{ [2]f64 }` is
  `double, double`, `{ [2]*const u8 }` is `ptr, ptr`, and any layout wider
  than 16 bytes uses `byval`/`sret`. An array whose element is itself an
  aggregate expands recursively, so nested arrays and arrays of structs follow
  the same rules. An eightbyte whose members fill only part of it transports
  at the width they occupy, which is what makes `{ [6]i16 }` (four occupied
  bytes in its second eightbyte) a `{ i64, i32 }` pair.
  A *bare* array is not an aggregate: C decays an array parameter to a
  pointer, so `extern fn take(values: [2]i32)` is rejected (`E0473`) — write
  `*const i32` (or a struct wrapping the array) instead. Arrays nested inside
  a struct are supported.
  A struct whose only member is a 16-byte integer (`{ a: i128 }`) fills both
  eightbytes, so it is one 16-byte INTEGER and travels as `i128` — exactly how
  Clang classifies `struct { __int128 a; }`. The remaining unsupported shape is
  a struct whose only field is a slice (`E0473`); name the fields or pass a
  pointer instead.
  One deliberate deviation from Clang: an eightbyte whose only leaf is a lone
  `f32` array element (`{ [1]i64, [1]f32 }`) is spelled `float` here, where
  Clang spells it `<2 x float>`. GCC spells it `float` too. Both carry the
  value in the low lane of the same SSE register with the upper lane padding,
  so the two spellings interoperate in both directions with either compiler;
  the fixture `cabi_array_members` pins that down.
- Slices are passed by value as pointer+length, matching a C
  `struct { ptr base; size_t len; }` layout.
- Enums are passed as their backing integer, but a C enum's width is
  implementation-defined. Declare the same backing width explicitly on both
  sides.

## 4. Strings and buffers

String literals are private null-terminated byte arrays of type `*const u8`:

```kyn
extern fn puts(s: *const u8) i32;

fn main() i32 {
    puts("Hello from Kyn!");
    return 0;
}
```

They are suitable for C functions that read `const char *` and do not retain
the pointer beyond the call unless the storage outlives the process (string
literals have static duration). Mutable buffers must be allocated explicitly
(stack arrays or `malloc`).

## 5. Linking model

The compiler emits textual LLVM IR and invokes an external toolchain:

```sh
kync emit-llvm file.kyn -o file.ll
kync emit-obj  file.kyn -o file.o --profile safe --cc clang
kync build     file.kyn -o program --profile safe --cc clang
```

`clang` assembles the IR and links the result. Kyn itself does not implement a
linker or an object format.

When combining Kyn with C, link all objects together:

```sh
kync emit-obj main.kyn -o main.o
clang -c helper.c -o helper.o
clang main.o helper.o -o program
```

When combining with Zig objects, link with `zig cc` instead of `clang`. Zig
runtime objects may reference compiler-rt support symbols such as
`__zig_probe_stack` that are provided by Zig's linker driver. `kyn-build`
selects `zig cc` automatically when a target contains Zig sources.

## 6. Hybrid project example

`examples/hybrid` contains:

```
kyn.build
src/main.kyn     extern c_add, extern zig_mul, main returns c_add(2,3)+zig_mul(4,5)
src/math.c       int c_add(int a, int b)
zig/math.zig     export fn zig_mul(a: i32, b: i32) i32
```

```sh
./zig-out/bin/kyn-build --file examples/hybrid/kyn.build
./examples/hybrid/build/hybrid/hybrid
# exit status 25
```

The Kyn side uses the same function signatures as the C and Zig definitions.
There are no generated headers or bridge functions.

## 7. Symbols and visibility

- `extern fn` emits an LLVM `declare`.
- `export fn` and `fn main` emit definitions with external linkage.
- Other `fn` definitions use internal linkage and are not visible to the
  linker.
- Globals are emitted with their Kyn name and module-level visibility. They are
  not marked `static`, so the linker may resolve them across objects unless a
  future visibility syntax says otherwise.
- There is no C++ name mangling, `extern "C"` block or symbol alias syntax.

You can inspect the result with standard tools:

```sh
kync emit-obj hello.kyn -o hello.o --keep-ir
nm hello.o
clang hello.o -o hello
```

## 8. Compilation targets

`kync --target <triple>` selects the machine code produced by `emit-obj`,
`build` and `run`. The triple uses Zig's spelling (`x86_64-linux-gnu`,
`aarch64-linux-gnu`, `riscv64-linux-gnu`); the vendor-qualified spelling Clang
and GCC print (`x86_64-unknown-linux-gnu`) is accepted and normalised, and an
unparseable triple is a `kyn: unknown target` error with exit status 2 rather
than a confusing failure from the assembler.

The mechanism is worth stating because it constrains the design. The emitted
module carries **no `target triple` and no `target datalayout`**: an assembler
consuming such a module overrides the layout from its own `-target`, and it does
so silently — a deliberately big-endian `datalayout` written into the module is
discarded. So the IR cannot direct code generation, and the compiler does not
pretend otherwise: `--target` is passed to the external assembler, which is what
actually selects the machine code. One IR therefore compiles to `ELF64`
`x86-64` or `ELF64` `AArch64` objects depending only on that flag, which the
integration suite verifies by reading `e_machine` from the produced object.

The target is resolved once, validated, and then carried explicitly to the two
consumers that need it:

- the type checker, which decides whether an aggregate has a C ABI at all
  (see §1) — there is deliberately no code path that consults the *build*
  target, because two sources of truth would let a cross-compilation lower the
  host convention silently;
- the external assembler, through `-target`.

`run` with a cross target produces an object for another machine and is not
executable locally; `--target` therefore mainly matters for `emit-obj` and
`build`.

## 9. Not supported in v0.1

- bare fixed-size array parameters and returns by value (C decays them to a
  pointer; a struct wrapping the array works), and aggregate layouts not
  supported by the selected target/classifier (including a struct whose only
  field is a slice and singleton `enum` members with 1-bit backings)
  (`E0473`);
- explicit alignment — designed but not implemented: see
  [the aggregate-extensions design](design-unions-bitfields-packed.md).
  Unions, packed structs and bitfields are implemented; see §10 and §11;
- calling conventions other than `x86_64` Linux System V;
- linking against Kyn-specific runtime support (there is none yet).

These restrictions are diagnosed where the type checker can see them, rather
than producing a silently incompatible ABI.

## 10. Unions and packed structs at the boundary

Both follow from one measured fact: **clang classifies a union exactly as the
struct formed by its members, and a packed aggregate always by memory.**

- **A union** has the size of its largest member and the alignment of its most
  aligned one, with every member at offset 0. It therefore travels in the same
  class the equivalent struct would: measured, `union { char c; int i; double d; }`
  is 8 bytes and arrives in one `i64`, `union { char c; }` in an `i8`, and
  `union { double d[3]; }` by `sret`/`byval`. Kyn emits it as a struct holding its
  most aligned member — LLVM has no union type — and every member access uses
  that member's index, so the emitted IR is valid for both names.
- **A packed struct or union** is `size = sum of members`, `align = 1`, and it
  crosses the boundary by memory **even when it is small**. Measured: a 5-byte
  packed `{ char c; int i; }` is passed with `byval`/`sret` where the unpacked
  8-byte form travels in one `i64`. The emitted definition uses the packed
  `<{ ... }>` form, without which LLVM would re-insert the padding the source
  removed.
- Reading a union member other than the live one is undefined behaviour, as in
  C; the language has no tag and does not claim to check it.
- **An `align(N)` aggregate** keeps the class its members would have — the
  alignment changes the size and the alignment, not the transport — so a 16-byte
  `align(16) { u8 }` still travels by memory. Measured against clang for the same
  two shapes: `align(16) { char }` is `size=16, align=16` and
  `packed, aligned(4) { char; int }` is `size=8, align=4`; `cabi_align` prints
  both from the C side and compares them with what Kyn emits, and checks at
  run time that a Kyn local really is on a 16-byte boundary rather than merely
  typed as one.

### 10.1 `align(N)` and the by-value classifier

Explicit alignment **does not change how an aggregate travels** — it changes its
size and its alignment — but it changes *whether* a shape travels at all, because
padding can push it over the sixteen-byte limit. Measured with `zig cc`:

| C form | size | data ends | transport |
|---|---|---|---|
| `align(16) { char }` | 16 | 1 | one `i8` |
| `align(16) { char; int }` | 16 | 8 | one `i64` |
| `align(16) { long }` | 16 | 8 | one `i64` |
| `align(16) { long; char }` | 16 | 9 | `i64, i8` |
| `align(32) { char }` | 32 | 1 | memory |
| `align(32) { long; char }` | 32 | 9 | memory |

Two rules follow, and both are now implemented:

1. **The sixteen-byte limit is the padded size.** A shape whose data ends at byte
   9 but whose size is 32 goes by memory.
2. **An eightbyte that holds no data consumes no register.** `align(16) { long }`
   is 16 bytes and still travels in one `i64`, not two; the second eightbyte is
   trailing padding and clang drops it. The register width follows the *data*, so
   `align(16) { char }` is an `i8` and not an `i16` or an `i64`.

"Data end" is the layout size minus the trailing padding `align(N)` adds, computed
from the members by `sema.aggregateDataEnd` and not from the size; that is what
keeps the classification independent of the modifier.

### 10.2 The `byval` alignment annotation

Measured: clang annotates every `byval` with **at least 8** — `packed { char; int }`
(alignment 1) and `packed, aligned(1..4)` all come out `align 8`, `packed,
aligned(16)` comes out `align 16`, and the `align(32)` of an aligned struct is
capped at 16. The annotation is the alignment the callee may assume of the copy,
which the stack always provides, so a layout alignment of 1 does not lower it.
`sema`-based emission used to carry the layout alignment straight through, which
put `align 1` where clang puts `align 8`; `byvalAlign` now states the bound.

### 10.3 Anonymous members

An anonymous member is **transparent to the classifier**: measured, clang
classifies `struct { int x; struct { int y; int z; }; }` as `i64, i32` — exactly as
if `y` and `z` had been declared directly, and unlike a *named* nested member,
whose own class would be a leaf of its own. The leaf walk in `sema` already
recursed through every field's type, so this is emergent rather than special-cased:
an anonymous member is an ordinary field whose type is an aggregate, and walking it
adds its leaves at their real offsets. `abi/cabi_anon_members` echoes two shapes
through C in both directions and compares the sizes the C side reports.

### 10.4 Tagged unions

A tagged union crosses the boundary as the struct it is: `{ tag, payload }`, with
the payload a union of the variants' payloads. Measured against clang for
`enum Shape { Circle(f64), Rect(i32), Empty }`, i.e. C's `struct { int tag; union
{ double; int; } payload; }`:

| | measured |
| --- | --- |
| size / alignment | 16 / 8 |
| payload offset | 8 |
| register transport | `{ i32, i64 }` — tag INTEGER, payload bitcast into the second INTEGER |

The transport is the ordinary aggregate rule, not a special case: with
`isAggregate` reading a tagged enum's `value_ty`, the existing leaf walk classifies
`{ i32, double }` as two INTEGER eightbytes and the emitter's `small_2` path
already packs them. Before that, the value was classified as a bare scalar and
travelled as one struct register — which is why `abi/cabi_tagged_union` echoes the
value through C in both directions and reads the tag *and* the payload back.

`E0508` refuses a payload with no known size, so a value that cannot be laid out is
never emitted with a layout it does not have.

### 10.5 What is still refused

Nothing for `align(N)`: an aligned aggregate crosses by value like any other, and
`abi/cabi_align_byval` echoes five shapes (including the by-memory one) through C
in both directions. A **bare array** parameter is still refused, and so is a
shape the leaf walk cannot classify.

One divergence that is **spelling only**, recorded rather than changed: for a
struct that is exactly one 16-byte integer member, clang writes the parameter as
`i128` and Kyn writes `i64, i64`. Measured to interoperate in both directions
(`{ a: __int128 }` echoed through C returns the value intact), because an `i128`
register pair and two `i64` registers are the same convention for an INTEGER
class argument; LLVM splits and rejoins it at the boundary.

## 11. Bitfields at the boundary

A bitfield is not an `i3` leaf at the ABI level. Measured: clang passes
`struct Wire { unsigned kind:3; unsigned tag:5; }` as one `i32`, not as an `i8`
— the transport unit is the **storage unit**, and the members merge inside it.
Kyn therefore records a bitfield run as one leaf of the storage unit's width,
and uses each field's own width only for the masking that reads and writes it.

- Layout is the deterministic rule of `language-reference.md` §3.8: a unit of 1,
  2, 4 or 8 bytes, no field straddling a boundary of its own unit width.
- **C compatibility is the narrow, stated subset:** widths summing to at most 8
  bits, no non-bitfield member, matched against the C struct that declares each
  member `unsigned char`. In that subset `{u3, u5}` is one byte and `{u4, u6}` is
  two, byte-for-byte identical to C — covered by `cabi_bitfields`, whose C side
  both writes and reads the value.
- A wider run is laid out by the same rules and is deterministic, but is **not**
  claimed to match C. Measured: `{u3, u5, u12}` is 4 bytes at alignment 2 in both
  languages, yet C's `unsigned` spelling puts `c` at bit 8 while Kyn (and C's
  `unsigned short` spelling) puts it at bit 16. Agreement on *size* alone would
  therefore have hidden a disagreement about *contents*, which is why the subset
  is the 8-bit one and not "anything up to 32 bits".
- `E0489` refuses a run whose unit would overlap bytes already emitted. C accepts
  `{a: u31, b: u33}` by making both runs share one 8-byte unit; Kyn does not claim
  that rule and rejects the shape rather than emitting a type that disagrees with
  its own layout.
