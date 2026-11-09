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
```

A slice stores two values at runtime:

- a raw pointer to `T` elements;
- a `usize` length.

Slices are aggregate values and may be passed, returned and copied inside Kyn.
They are rejected at `extern`/`export` C ABI boundaries (`E0410`). A slice is
currently constructed with an explicit cast from a pointer to a fixed-size
array, such as `&values as []i32`, and carries mutability from that source.
`slice.len` returns the length as `usize`, and slice indexing is
bounds-checked at runtime.

### 1.4 Arrays

```
[N]T
```

`N` must be a positive integer constant; zero-length and inferred-length
arrays are rejected. Arrays are value types with contiguous storage, and their
length is part of the type. `[3]i32` and `[4]i32` are different types.

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

There is no subtyping, covariance or implicit mutability weakening.

## 4. Assignability

A value of type `S` is assignable to a location of type `T` when one of the
following holds:

1. `S` and `T` are the same type.
2. `S` is `comptime_int`, `T` is an integer type, and the literal value fits
   `T` (including the minimum signed value written as a negated literal).
3. `S` is `comptime_float` and `T` is a floating type.
4. `S` is `null` and `T` is a pointer type.

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
| `&` | lvalue | pointer to operand type |
| `*` | pointer | pointee type |
| `as` | allowed cast pair | target type |

`comptime_int`/`comptime_float` unify with concrete numeric operands when the
literal fits. Mixing two different concrete types is always `E0439` (or
`E0444` for compound assignment).

## 6. Lvalues and mutability

An expression is an lvalue when it denotes storage:

- an identifier bound to a local or global;
- `*p`;
- `base.field` where `base` is an lvalue;
- `base.field` through a non-const pointer using `->`;
- `base[index]` where `base` is an lvalue or a pointer.

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
  internal Kyn functions and assigned/copied when source and destination have
  the same type.
- Aggregate copies lower to contiguous loads/stores; LLVM's optimizer may
  promote or lower them according to the internal ABI.
- `extern` and `export` functions reject aggregate parameters and returns
  (`E0410`) in v0.1; pass a pointer across the C ABI.
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
| `E0410` | void parameter, or aggregate parameter/return at a C ABI boundary |
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
