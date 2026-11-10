# Kyn type system (v0.1)

Kyn is statically typed. Every expression is typed before code generation; the
backend never guesses a type at emission time. The type checker is implemented
in `compiler/sema.zig`, and types are represented in `compiler/types.zig`.

## 1. Type categories

### 1.1 Primitive types

| Kyn type | Meaning                          | Current LLVM representation |
| -------- | -------------------------------- | --------------------------- |
| `void`   | absence of a value               | `void`                      |
| `bool`   | boolean                          | `i1`                        |
| `char`   | Unicode scalar value             | `i32`                       |
| `i8` … `i128` | signed integers             | `i8` … `i128`               |
| `u8` … `u128` | unsigned integers           | `i8` … `i128`               |
| `f32`, `f64` | IEEE-754 binary floating point | `float`, `double`        |
| `usize`  | unsigned size integer            | currently `i64`             |
| `isize`  | signed size integer              | currently `i64`             |

`usize` and `isize` are currently fixed to 64 bits. Making them track the
target data model is planned; do not rely on them being pointer-sized on
32-bit targets yet.

`void` is only valid as a function return type. Locals, parameters, fields,
array elements and pointers to `void` are rejected.

### 1.2 Pointers

```
*T          mutable pointer to T
*const T    pointer to immutable T
```

Pointers are explicit and are not nullable at the type level: `null` is a
separate type assignable to any pointer. There are no references and no
nullable references in v0.1; slices are documented separately.

Mutability is part of the pointer type:

- `&mutable_lvalue` produces `*T`.
- `&immutable_lvalue` produces `*const T`.
- `*p = value` is allowed only when `p` is `*T`.
- `p->field = value` and `p[index] = value` follow the same rule.

Pointer arithmetic is scaled by the pointee type. `p - q` requires identical
element types and yields `isize`.

### 1.3 Slices

```
[]T
[]const T
```

A slice stores two values at runtime:

- a raw pointer to `T` elements;
- a `usize` length.

Slices are aggregate values and may be passed, returned and copied inside Kyn.
`extern`/`export` signatures may use slices when the C counterpart uses a
matching `struct { T *ptr; size_t len; }`; boundary lowering follows the
System V x86_64 calling convention on Linux. Slices are constructed with
open-ended or bounded slice syntax (`base[..]`, `base[start..]`, `base[..end]`,
`base[start..end]`) on lvalue arrays, pointers to arrays or existing slices, or
with an explicit `as` cast from a pointer to a fixed-size array.

`[]const T` prevents assignment to the pointed-at elements; `[]T` preserves
mutability when the source is mutable and adapts to `[]const T` when expected
by context or implicitly assigned to `[]const T` (provided `T` is identical).
`slice.len` returns the length as `usize`, and `slice.ptr` returns `*T` for
`[]T` or `*const T` for `[]const T` (both are read-only non-lvalue properties;
`->len` and `->ptr` work on pointers to slices). Slice indexing and subslicing
are bounds-checked at compile time when constant (`E0502`) and at runtime
otherwise.

### 1.4 Arrays

```
[N]T
```

`N` must be a positive integer constant; zero-length and inferred-length
arrays are rejected. Arrays are value types with contiguous storage, and their
length is part of the type (`array.len` returns `N` as `usize` and is usable
in constant expressions when the base is a fixed-array identifier or constant
array literal). `[3]i32` and `[4]i32` are different types.

Array indexing accepts any integer index type; it does not implicitly convert
the index to `usize`. Constant indexes are checked against the length during
static analysis.

### 1.5 Structs

Structs are nominal types. Two structurally identical declarations are still
different types, because each declaration owns a distinct `StructInfo`.
Fields are stored in declaration order. LLVM inserts target-required padding;
Kyn v0.1 has no `packed`, `align` or explicit layout syntax.

A struct cannot contain itself by value, directly or through an array
(`E0403`). Recursion through a pointer is allowed.

### 1.6 Enums

Enums are nominal types with an explicit integer backing type (default `i32`).
The backing type determines representation; the enum itself is distinct from
that integer. Variants are compile-time constants of the enum type. `as`
converts between enum and integer types.

### 1.7 Function types

Function signatures are represented internally as `fn(params...) -> ret`.
They are used to type declarations and calls. Function types cannot be written
in source, function values are not first-class, and indirect calls are not
supported in v0.1.

## 2. Literal typing

Kyn separates unconstrained literal types from concrete types:

- An integer literal starts as `comptime_int` and becomes a concrete integer
  type when context requires one. If no context exists, it materializes as
  `i64`.
- A float literal starts as `comptime_float` and becomes `f32`/`f64` from
  context, or `f64` without context.
- `true`/`false` have type `bool`.
- A character literal has type `char`.
- A string literal has type `*const u8` and refers to a private constant,
  null-terminated byte array.
- `null` has type `null` and is assignable to pointers.

Literal adaptation is not a general implicit conversion. It only applies to
literal values and only when the value fits the target type. For example:

```kyn
let a: u8 = 255;        // ok
let b: u8 = 256;        // E0426, does not fit
let c: i32 = 1 + 2;     // the whole constant expression takes i32
let d: i64 = 1;         // ok, literal adapts
let e: i64 = 1 as i32;  // E0462, concrete i32 does not implicitly widen
```

## 3. Type equality

- Primitive types are equal when their kind, width and signedness match.
- Pointer types are equal when constness and element types match.
- Array types are equal when length and element types match.
- Struct and enum types are equal only when they refer to the same declaration.
- Function types are equal when parameter lists and return types are
  structurally equal.

There is no nominal subtyping or deep variance; the only implicit mutability
weakening is top-level `[]T` to `[]const T` when `T` is identical.

## 4. Assignability

A value of type `S` is assignable to a location of type `T` when one of the
following holds:

1. `S` and `T` are the same type.
2. `S` is `[]U`, `T` is `[]const U`, and `U` is the exact same type (`[][]T`
   does not implicitly convert to `[][]const T`).
3. `S` is `comptime_int`, `T` is an integer type, and the literal value fits
   `T` (including the minimum signed value written as a negated literal).
4. `S` is `comptime_float` and `T` is a floating type.
5. `S` is `null` and `T` is a pointer type.

No other implicit conversions exist. Assignment, initialization, arguments and
`return` all use these rules. Concrete numeric types require an explicit
`as` cast even when the conversion is lossless.

## 5. Operators and result types

| Operators | Operand requirement | Result |
| --------- | ------------------- | ------ |
| `+ - * / %` | numeric, same concrete type (literals adapt) | operand type |
| `& \| ^` | integer, same concrete type | operand type |
| `<< >>` | integer; right operand may differ | left operand type |
| `== !=` | same type; numeric, pointer, bool, enum | `bool` |
| `< <= > >=` | same type; numeric or pointer | `bool` |
| `&& \|\|` | `bool` | `bool` |
| `!` | `bool` | `bool` |
| unary `-` | numeric | operand type |
| unary `~` | integer | operand type |
| `&` | lvalue (`E0464` otherwise) | pointer to operand type (`*T` or `*const T`) |
| `*` | pointer | pointee type |
| `as` | allowed cast pair | target type |

`comptime_int`/`comptime_float` unify with concrete numeric operands when the
literal fits. Mixing two different concrete types is always `E0439` (or
`E0444` for compound assignment).

## 6. Lvalues and mutability

An expression is an lvalue when it denotes storage:

- an identifier bound to a local or global;
- `*p`;
- `base.field` on a struct where `base` is an lvalue;
- `base->field` on a pointer to a struct;
- `base[index]` where `base` is an lvalue, a pointer, or a slice.

Built-in properties (`slice.len`, `slice.ptr`, `array.len`, and their `->`
forms) are computed values, not lvalues (`E0441` on assignment, `E0464` on
address-of).

Mutability is checked separately:

- a `let`/`const` binding is immutable;
- a `var` binding is mutable;
- dereference, `->` and pointer indexing are mutable only when the pointer is
  not `*const`;
- a field of a struct is as mutable as its base.

This means `let p: *T` still permits `p->field = x`: the binding is immutable,
but the pointee is mutable. Conversely `*const T` blocks mutation through the
pointer regardless of how the pointer variable itself was declared.

## 7. Control-flow typing

- `if` and `while` conditions must be `bool`.
- `return expr` requires `expr` to be assignable to the declared return type.
- A non-void function must return on every path. The check is conservative:
  it accepts blocks that end in `return` and `if`/`else` where both branches
  always return. A `while` loop never satisfies the check, even with a constant
  `true` condition.
- `break`/`continue` are valid only inside loops.

## 8. Aggregates

- Struct and array values are constructed in place.
- Struct and array values may be passed as aggregate arguments, returned from
  functions and assigned/copied when source and destination have the same
  type.
- Aggregate copies lower to contiguous loads/stores; LLVM's optimizer may
  promote or lower them according to the internal ABI.
- `extern`/`export` functions pass aggregates through the System V x86_64 ABI
  on Linux when the current classifier supports their layout. Aggregates ≤16
  bytes are passed in `INTEGER`-class registers; float and integer fields may
  share an eightbyte when the merged class is `INTEGER`. Larger supported
  aggregates use `sret`/`byval` memory passing.
- A struct containing one direct `f32`/`f64` field crosses `extern`/`export`
  boundaries as one scalar SSE value. Exactly two adjacent direct `f32` fields
  use one `<2 x float>` SSE/SSEUP value; exactly three adjacent direct `f32`
  fields (12 bytes) use one `<2 x float>` SSE/SSEUP value plus one `float` SSE
  value and a `{ <2 x float>, float }` return; exactly four adjacent direct
  `f32` fields (16 bytes) use two `<2 x float>` values and a
  `{ <2 x float>, <2 x float> }` return; exactly two direct `f64` fields use
  two SSE registers and an LLVM `{ double, double }` return coercion. A direct
  `{ f32, f64 }` struct at natural offsets 0/8 uses `float, double` arguments
  and `{ float, double }` returns; the reverse `{ f64, f32 }` layout uses
  `double, float` and `{ double, float }`. A direct `{ f32, i64 }` or
  `{ f32, u64 }` uses `float, i64` arguments and `{ float, i64 }` returns;
  the reverse `{ i64, f32 }` / `{ u64, f32 }` uses `i64, float` and
  `{ i64, float }`; `{ f64, i64 }` / `{ f64, u64 }` use `double, i64` and
  `{ double, i64 }`; and `{ i64, f64 }` / `{ u64, f64 }` use `i64, double`
  and `{ i64, double }`. A direct `{ i8/u8, f64 }` or `{ i16/u16, f64 }`
  uses the member-width integer and `double` and returns `{ i8, double }` /
  `{ i16, double }`; the reverse `{ f64, i8/u8 }` / `{ f64, i16/u16 }`
  uses `double, i8` / `double, i16` and `{ double, i8 }` / `{ double, i16 }`
  returns. A direct `{ bool, f64 }` or `{ double, bool }` passes the singleton
  `bool` as a full `i8` parameter, with `{ i8, double }` / `{ double, i8 }`
  returns. A struct whose two eightbytes each carry exactly one scalar leaf
  passes each leaf at its own width in its own register, returning the
  matching pair: `{ i8/u8, i64 }` / `{ u8/u8, i64 }` uses `i8, i64` and
  `{ i8, i64 }`; `{ i16/u16, i64 }` / `{ u16/u16, i64 }` uses `i16, i64` and
  `{ i16, i64 }`; `{ i32, i64 }` / `{ u32, u64 }` uses `i32, i64` and
  `{ i32, i64 }`; `{ ptr, i64 }` uses `ptr, i64`, `{ i8, ptr }` uses
  `i8, ptr`, and `{ i32, i32, ptr }` merges its first eightbyte to
  `i64, ptr`; and the reversed layouts `{ i64, i8/u8 }`,
  `{ i64, i16/u16 }`, `{ i64, i32/u32 }` and `{ i64, ptr }` use `i64, i8` /
  `i64, i16` / `i64, i32` / `i64, ptr` with the matching pair returns. The
  register of an eightbyte is decided by the *leaves* it carries, with nested
  structs flattened into their members exactly as Clang does: an eightbyte with
  a single integer leaf travels at that leaf's width, one with a single pointer
  leaf travels as `ptr` and is never narrowed to an integer member width, one
  with several leaves travels as a full `i64` (even when a float is among
  them), an eightbyte with a single `f32` or `f64` travels as that scalar, and
  one with two `f32` leaves travels as `<2 x float>`. A two-`f32` slot paired
  with a narrow second leaf keeps its packing, so `{ f32, f32, i16 }` uses
  `<2 x float>, i16` and `{ f32, f32, i8 }` / `{ f32, f32, bool }` use
  `<2 x float>, i8`; the mirrored `{ i16, f32, f32 }` and `{ i32, f32, f32 }`
  orders reverse the registers. A narrow second slot writes only its own bytes.
  Nested members therefore follow the same rules as direct ones.
  Sub-32-bit integer members (`i8`, `u8`, `i16`, `u16`) and `bool`
  are also accepted inside `INTEGER`-merged eightbytes, where the packed
  `i64` is passed irrespective of member widths; singleton small members pass
  at their own width; and a singleton `enum` member or singleton `bool` passes as an `i8`/`i16`/`i32`/`i64` at its backing width. Singleton `i8`/`i16`/`i32`/`i64` aggregates are passed in a single exact-width INTEGER argument register (1→`i8`, 2→`i16`, ≤4→`i32`, otherwise `i64`), matching Clang's IR exact-size registers.
  Additionally, aggregates with two or more smaller-INTEGER members packed
  into one eightbyte followed by a single `f32` or `f64` (only the scalar in
  the next eightbyte) pass as `( i64, float )` or `( i64, double )`, verified
  against Clang probes.
  Exact multi-member layouts whose eightbytes split
  into an SSE-only slot and an INTEGER/merged slot use their probed Clang
  coercions: `{ f32, f32, i32 }` (`<2 x float>, i32` and `{ <2 x float>, i32 }`),
  `{ f32, f32, i64 }` (`<2 x float>, i64` and `{ <2 x float>, i64 }`),
  `{ i32/u32, f32, f32 }` and `{ f32, i32/u32, f32 }` (merged `INTEGER` as
  `i64`, then `float`; `{ i64, float }` returns), `{ i32/u32, f32, f64 }` and
  `{ f32, i32/u32, f64 }` (merged `INTEGER` as `i64`, then `double`;
  `{ i64, double }` returns), `{ f64, i32/u32, i32/u32 }` / `{ f64, i32/u32, f32 }`
  (`double` then merged `INTEGER`; `{ double, i64 }` returns), and
  `{ i64/u64, f32, f32 }` (`i64, <2 x float>`; `{ i64, <2 x float> }`
  returns). Four-member `{ f32, f32, i32, f32 }` / `{ i32, f32, f32, f32 }` /
  `{ f32, i32, f32, f32 }` use `i64` or `<2 x float>` in the merged-INTEGER slot
  with their probed coercions. A direct
  `{ f64, i32 }` / `{ f64, u32 }` structs use `double, i32` arguments and
  `{ double, i32 }` returns; `{ i32, f64 }` / `{ u32, f64 }` use `i32, double`
  and `{ i32, double }`. These rules cover only adjacent direct fields with
  natural offsets. Nested or other unsupported small SSE/INTEGER layouts, fixed
  arrays by value, and unsupported targets are rejected with `E0473`.
- Slices may also cross the C ABI boundary when their layout matches a C
  `struct { ptr, usize }`.
- A pointer to an aggregate remains the preferred way to avoid large copies.

## 9. Explicit casts

Casts are checked for the allowed source/destination pairs described in the
[language reference](language-reference.md#57-casts). Numeric casts wrap or
truncate according to the target width; v0.1 inserts no runtime range check.
Pointer/integer casts are permitted but are not provenance-checked.

## 10. Diagnostics

Type errors use the `E04xx` range. The most important codes:

| Code | Meaning |
| ---- | ------- |
| `E0401` | duplicate top-level declaration |
| `E0403` | struct contains itself by value |
| `E0410` | void parameter |
| `E0473` | unsupported aggregate parameter/return at a C ABI boundary |
| `E0414` | function may reach the end without returning |
| `E0426` | integer literal does not fit |
| `E0427` | unknown identifier |
| `E0431`/`E0433` | comparison operand mismatch |
| `E0439` | mismatched numeric operand types |
| `E0441` | assignment target is not an lvalue |
| `E0442` | assignment to immutable location |
| `E0446` | wrong argument count |
| `E0447` | invalid cast |
| `E0453` | unknown struct field |
| `E0458` | missing struct initializer field |
| `E0462` | incompatible assignment without a cast |
| `E0463` | condition is not `bool` |

See [diagnostics.md](diagnostics.md) for the full list.
