# Kyn language reference (v0.1)

This document describes the language as implemented by Kyn v0.1. If a
construct is not described here or is listed under
[Unsupported constructs](#7-unsupported-constructs), it is not part of the
current language.

## 1. Lexical structure

### 1.1 Source files

- Each module is a UTF-8 source file with the `.kyn` extension.
- A root compilation may use explicit `import "relative/path.kyn";` declarations;
  each imported file is resolved relative to the file containing that import.
- Imported modules are parsed once per normalized path and own independent
  top-level namespaces. Optional `as alias` imports support qualified
  value/type references. Unaliased imports open their public declarations,
  including the transitive closure of other unaliased imports. A same-module
  declaration shadows opened names; two distinct opened public declarations
  with the same spelling are ambiguous at use (`E0471`). Aliased-only edges do
  not open names. Duplicate declarations within one module produce `E0401`.
  `private` restricts cross-module names/types (`E0467`). Import cycles are
  rejected (`E0231`), and unreadable files produce `E0232`. There is no implicit
  prelude or glob import.
- Source text is processed as bytes. Invalid bytes inside comments, strings and
  characters are diagnosed by the lexer.
- Line endings may be `\n` or `\r\n`.

### 1.2 Comments

```kyn
// line comment
/* block comment, which may span lines */
```

Block comments nest. An unterminated block comment is `E0106`.

### 1.3 Identifiers

Identifiers begin with an ASCII letter or `_` and continue with ASCII letters,
digits or `_`. Keywords are reserved and cannot be used as identifiers.

### 1.4 Keywords

```
as      break   const   continue    else    enum    export  extern
false   fn      for     if          import  let     null    private  return
struct
true    var     while
```

`for` is reserved for future use and is not accepted by the parser.

### 1.5 Primitive type names

```
void  bool  char
i8 i16 i32 i64 i128
u8 u16 u32 u64 u128
f32 f64
usize isize
```

### 1.6 Literals

**Integer literals**

- Decimal: `0`, `42`, `1_000_000`
- Hexadecimal: `0xFF`, `0x2A`
- Binary: `0b1010`
- Octal: `0o755`
- Underscores are ignored in the value.

Integer literals have the unconstrained type `comptime_int` until context gives
them a concrete integer type. If no context exists, the type is materialized as
`i64`. A literal that does not fit its required type is `E0426`.

**Float literals**

- `1.5`, `0.25`, `1e9`, `6.022e23`
- A float requires digits on both sides of the decimal point.
- An unconstrained float literal is materialized as `f64`.

**Boolean literals:** `true`, `false`.

**Null literal:** `null`. Its type is `null`; it is assignable to any pointer
type and to `null`-typed comparisons with pointers. There is no integer zero
conversion to pointers.

**Character literals:** `'a'`, `'\n'`, `'\x41'`, `'é'`. The type is `char`,
an unsigned 32-bit Unicode scalar value.

**String literals:** `"text"`, `"line\n"`, `"\x41"`. A string literal has type
`*const u8`, points to a private null-terminated byte array, and is immutable.

Supported escapes in strings and characters: `\n`, `\r`, `\t`, `\0`, `\\`,
`\"`, `\'`, `\xNN` (exactly two hexadecimal digits).

### 1.7 Operators and punctuation

```
( ) { } [ ] , ; : . .. ... -> @
+ - * / % & | ^ ~ ! = == != < <= > >= << >>
+= -= *= /= %= &= |= ^= <<= >>=
&& ||
```

`..` is the range operator of a slice expression and `...` the variadic marker
of an `extern` declaration; the three-dot form is its own token, never a `..`
followed by a `.`. `@` is lexed but has no grammar rule in v0.1.

## 2. Types

Function types are written `fn(P) R` and declare a first-class function value:

```kyn
fn add(a: i32, b: i32) i32 { return a + b; }

fn apply(op: fn(i32, i32) i32, a: i32, b: i32) i32 {
    return op(a, b);
}

fn main() i32 {
    let chosen: fn(i32, i32) i32 = add;
    let unset: fn(i32, i32) i32 = null;
    if (unset == null) { return apply(chosen, 20, 22); }
    return 0;
}
```

- A function name in value position decays to a function value with that
  signature, so it can be stored, passed and returned by the same rules as any
  other value. Calling a **declared** function still calls its symbol directly;
  calling through a value is an indirect call.
- `null` is assignable to a function type, and `==`/`!=` compare a function value
  with `null`, which is how an optional callback is tested.
- Two function types are compatible only when the parameter list and the return
  type agree; the diagnostic prints both signatures. A missing return type means
  `void`, and a `void`-returning value is called as a statement.
- Function types nest, so a callback can itself take a callback
  (`fn(fn(i32) i32, i32) i32`).
- At the C boundary a function value is one `ptr` in an INTEGER register, so it
  can be passed to and received from C directly. Calling through a null function
  pointer traps instead of jumping to address zero.

The concrete type grammar is:

```
Type       = PointerType | SliceType | ArrayType | NamedType | PrimitiveType
PointerType = "*" [ "const" ] Type
SliceType   = "[" "]" [ "const" ] Type
ArrayType   = "[" IntegerLiteral "]" Type
NamedType   = Identifier
```

- `*T` is a mutable pointer to `T`.
- `*const T` is a pointer to immutable `T`; mutation through it is rejected.
- Dereferencing a pointer exactly `null` traps; invalid non-null pointers are
  not checked and remain undefined behavior.
- `[N]T` is a fixed-size array of exactly `N` elements. `N` must be a positive
  constant integer known at compile time (`array.len` yields `N` as `usize`).
- `[]T` is a slice: a fat pointer holding a data pointer and a `usize` length.
  Slices are constructed with open-ended or bounded slice expressions
  (`base[..]`, `base[start..]`, `base[..end]`, `base[start..end]`) on arrays,
  array pointers or slices, or with an explicit cast from a pointer to a
  fixed-size array (`&values as []i32`). Slicing is const-polymorphic: mutable
  bases produce `[]T` (or `[]const T` when expected by context), while
  immutable bases produce `[]const T`. `[]T` is implicitly assignable to
  `[]const T` when the element type `T` matches exactly; `[]const T` never
  implicitly converts to `[]T`.
- Struct, enum and primitive names resolve to their declarations.
- `void` is valid only as a function return type; parameters and variables
  cannot have type `void`.
- Function types exist internally for direct calls but cannot be written in
  source yet.

There are no implicit pointer conversions other than `null` to a pointer type,
and no pointer mutability conversion (`*T` to `*const T` requires an explicit
cast in v0.1). Mutable slices `[]T` convert implicitly to `[]const T` when
`T` is identical.

## 3. Top-level declarations

A program consists of top-level imports and declarations. Each source file owns
its top-level namespace. Declarations are public by default for compatibility;
prefix a top-level declaration with `private` to restrict its names and types
to the declaring source module. Same-spelled declarations in different modules
are distinct; an open-import ambiguity is diagnosed only when the name is used.

### 3.1 Imports

An import is written at file scope with a quoted path; an optional alias enables
qualified access:

```kyn
import "math/vector.kyn";
import "math/vector.kyn" as vector;

fn main() i32 {
    return vector.sum(vector.Pair { x: 20, y: 22 });
}
```

Paths resolve relative to the importing file. The compiler traverses imports in
depth-first source order, loads each normalized path once, then analyzes its
declarations before the importer. An optional `as alias` enables explicit
qualified references such as `math.add(...)` and `math.Vector`, resolving only
declarations owned by that imported module.

Without an alias, an import opens public names in the importing module. Open
imports are transitive through other unaliased imports; aliased edges are not
re-exported unqualified. Names declared locally shadow opened names. If two
different opened modules provide the same public name, using that name without
qualification reports `E0471`; qualify it through an alias to disambiguate.
Private declarations do not participate in unqualified lookup from other
modules. Same-named declarations in separate modules are distinct, while a
duplicate within one module reports `E0401`. Cycles (`E0231`) and unreadable
files (`E0232`) are errors.

### 3.2 Functions

```kyn
fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn log_message() {
    // no return type means void
}
```

- Parameters are `name: Type`, separated by commas.
- The return type follows the parameter list. Omitted means `void`.
- Aggregate parameters and aggregate return types use the internal Kyn ABI by
  default. In `extern`/`export` signatures on `x86_64` Linux, aggregates up to
  16 bytes are supported when each occupied System V eightbyte merges to the
  `INTEGER` class; these use up to two `i64` registers with zero-padded partial
  eightbytes. A float field may participate when an integer field in the same
  eightbyte makes the merged class `INTEGER`. A one-field direct `f32`/`f64`
  struct uses scalar SSE; exactly two adjacent direct `f32` fields use one
  `<2 x float>` SSE/SSEUP value; exactly three adjacent direct `f32` fields
  use one `<2 x float>` SSE/SSEUP value plus one `float` SSE value, returning
  `{ <2 x float>, float }`; exactly four adjacent direct `f32` fields use
  two `<2 x float>` values, returning `{ <2 x float>, <2 x float> }`;
  exactly two direct `f64` fields use two SSE registers with LLVM
  `{ double, double }` return coercion; a direct `{ f32, f64 }` struct with
  fields at offsets 0 and 8 uses `float, double` arguments and a
  `{ float, double }` return; the reverse `{ f64, f32 }` uses `double, float`
  and `{ double, float }`; a direct `{ f32, i64 }` or `{ f32, u64 }` uses
  `float, i64` arguments and `{ float, i64 }` return; the reverse
  `{ i64, f32 }` / `{ u64, f32 }` uses `i64, float` and `{ i64, float }`;
  `{ f64, i64 }` / `{ f64, u64 }` use `double, i64` and `{ double, i64 }`;
  `{ i64, f64 }` / `{ u64, f64 }` use `i64, double` and `{ i64, double }`;
  direct `{ i8/u8, f64 }` / `{ i16/u16, f64 }` use member-width `i8`/`i16`
  parameters and `{ i8, double }` / `{ i16, double }` returns; the reverse
  `{ f64, i8/u8 }` / `{ f64, i16/u16 }` uses `double, i8` / `double, i16`
  `{ double, i8 }` / `{ double, i16 }` returns; singleton
  `i8`/`i16`/`i32`/`i64` aggregates pass in one single exact-width INTEGER
  argument register (1→`i8`, 2→`i16`, ≤4→`i32`, otherwise `i64`); aggregates with two or
  more smaller-INTEGER members packed into one eightbyte followed by a
  single `f32` or `f64` (only the scalar in the next eightbyte) pass as
  `( i64, float )` or `( i64, double )`; sub-32-bit integer
  members and `bool` are also accepted inside `INTEGER`-merged eightbytes
  (packed `i64` passed irrespective of member widths), direct
  `{ bool, f64 }` / `{ f64, bool }` use a full `i8` parameter and
  `{ i8, double }` / `{ double, i8 }` returns, a struct whose two eightbytes
  each carry exactly one scalar leaf passes each leaf at its own width in its
  own register, returning the matching pair
  (`{ i8/u8, i64 }` → `i8, i64` / `{ i8, i64 }`, `{ i16/u16, i64 }` →
  `i16, i64` / `{ i16, i64 }`, `{ i32, i64 }` → `i32, i64` /
  `{ i32, i64 }`, `{ ptr, i64 }` → `ptr, i64`, `{ i8, ptr }` → `i8, ptr`,
  `{ i32, i32, ptr }` → `i64, ptr`, and the reversed layouts → `i64, i8` /
  `i64, i16` / `i64, i32` / `i64, ptr` with the matching pair returns; the
  register of an eightbyte is decided by the leaves it carries — an integer
  leaf at its width, a pointer leaf as `ptr` and never narrowed, several
  leaves as a packed `i64`, a single `f32`/`f64` as that scalar, and two
  `f32` leaves as `<2 x float>` — with nested structs flattened into their
  members exactly as Clang does, and a two-`f32` slot paired with a narrow
  leaf keeping its packing as `<2 x float>, i16` / `i8` and the mirrored
  `{ i16, f32, f32 }` / `{ i32, f32, f32 }` orders), while a singleton
  `enum` member with a sub-32-bit backing passes as an `i8`/`i16`/`i32`/`i64` at its backing width;
  the exact multi-member layouts `{ f32, f32, i32 }`,
  `{ f32, f32, i64 }`, `{ i32/u32, f32, f32 }`, `{ f32, i32/u32, f32 }`,
  `{ i32/u32, f32, f64 }`, `{ f32, i32/u32, f64 }`, `{ f64, i32/u32, i32/u32 }`,
  `{ f64, i32/u32, f32 }`, `{ i64/u64, f32, f32 }`, `{ f32, f32, f64 }` and
  `{ f64, f32, f32 }`, and their four-member variants
  `{ f32, f32, i32, f32 }` / `{ i32/u32, f32, f32, f32 }` /
  `{ f32, i32/u32, f32, f32 }`, use their probed Clang coercions with
  `<2 x float>`, `float`, `double` or `i64` as the merged-INTEGER/SSE-slot
  parameters; and a direct
  `{ f64, i32 }` or `{ f64, u32 }` struct with fields at offsets 0 and 8 uses
  `double, i32` arguments and `{ double, i32 }` return coercion; the reverse
  `{ i32, f64 }` or `{ u32, f64 }` uses `i32, double` and
  `{ i32, double }`. Larger supported structs use hidden `sret`/`byval`
  pointers. Slices match a C struct
  `{ T *ptr; size_t len; }`. Fixed arrays and other unsupported small
  target/class layouts are rejected with `E0473`.
- A function with a non-void return type must return on every path; otherwise
  `E0414`.
- `return;` is valid only in a `void` function.

### 3.3 External and exported functions

```kyn
extern fn puts(s: *const u8) i32;
extern fn c_add(a: i32, b: i32) i32;

export fn zig_mul(a: i32, b: i32) i32 {
    return a * b;
}
```

- `extern fn` declares a function defined elsewhere with C ABI linkage. It has
  no body and ends with `;`.
- `export fn` defines a function with external linkage under its Kyn name.
- `fn main` also has external linkage, so the native linker can find it.
- All other Kyn functions have internal linkage.
- `export` may also prefix a global declaration (`export var`, `export let`,
  `export const`), which gives that object external linkage under its Kyn name
  and makes its type a C ABI boundary (`E0476` when the layout is not
  representable). See [exporting globals](abi.md#exporting-globals).

An `extern` declaration may end its parameter list with `...`, which declares a
C variadic function and lets a call pass extra arguments after the fixed ones:

```kyn
extern fn printf(format: *const u8, ...) i32;

fn main() i32 {
    let count: i32 = 3;
    return printf("count=%d\n", count);
}
```

At least one fixed parameter must precede `...`. The trailing arguments go
through the C default argument promotions (`i8`/`bool`/`enum` → `i32`,
`u8`/`u16` → `u32`, `f32` → `f64`; `i64`, `u64`, `f64` and pointers
unchanged), and an aggregate, a slice or a bare `null` is rejected rather than
passed in a form the callee would misread.

`export fn` may also be variadic, which is how a Kyn function receives a call C
makes. The trailing arguments are read with `va_arg()`, a builtin expression
whose type comes from context — `let value: i32 = va_arg();` — because a
default would silently misread a `double`:

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

Only the promoted widths a caller can actually pass can be retrieved, the type
must come from context (`E0478`) and `va_arg()` is valid only inside a variadic
function (`E0480`); a narrow type such as `i8` is rejected and the promoted
width is named instead (`E0479`). There is no `va_list` value to name and no
`va_start`/`va_end` to write: the compiler emits both. A plain Kyn function
(called only from Kyn, with a fixed signature) stays rejected with `E0474`.
See [the ABI guide](abi.md#variadic-declarations) and
[receiving a C variadic argument list](abi.md#receiving-a-c-variadic-argument-list)
for the full contract.

### 3.4 Structs

```kyn
struct Point {
    x: i32,
    y: i32,
}
```

- Fields are `name: Type`, separated by commas. A trailing comma is allowed.
- Field order determines layout and the LLVM struct type.
- A struct cannot contain itself by value (`E0403`), directly or through an
  array. Recursion through a pointer is allowed.
- Struct values are created with a struct initializer. Every field must be
  specified exactly once; order does not matter. A field's value may be any
  expression of its type — a literal, a variable, a field read, a call result —
  and an aggregate field is copied in whole. A repeated field name is
  `E0404` rather than the last value silently winning, and the rule applies to
  nested initializers as well.
- Field access is `.` on a value and `->` on a pointer.

### 3.5 Unions

```kyn
union Value {
    integer: i64,
    real: f64,
}

fn main() i32 {
    var v: Value = Value { real: 1.5 };
    v.integer = 7;
    return v.integer as i32;
}
```

- A `union` has the same body syntax as a `struct`, but its members **overlap**:
  every one starts at offset 0, the size is the largest member's and the
  alignment the most aligned member's.
- An initializer names **exactly one** member, because naming one is what says
  which is live; naming none or several is `E0485`. A repeated field name is
  `E0404`, as in a struct.
- There is **no tag**. The program decides which member is live and reading a
  different one reinterprets the same storage — undefined behaviour, exactly as
  in C, and not checked.
- A union cannot contain itself by value (`E0403`), and a diagnostic about one
  says "union", not "struct".

### 3.6 Packed structs and unions

```kyn
packed struct Packet {
    kind: u8,
    length: u32,
}
```

- `packed` before `struct` or `union` removes the padding between members and
  makes the aggregate's alignment 1, so `{ kind: u8, length: u32 }` is 5 bytes
  with `length` at offset 1 instead of 8 bytes at offset 4.
- It is a modifier, so anything other than an aggregate after it is `E0484`.
- A packed aggregate crosses the C ABI **by memory** even when it is small,
  because it has no guaranteed alignment; that matches what a C compiler does
  with `__attribute__((packed))`.

### 3.7 Explicit alignment

```kyn
align(16) struct Buffer {
    kind: u8,
}

align(4) packed struct Record {
    tag: u8,
    value: i32,
}
```

- `align(N)` before `struct` or `union` raises the aggregate's alignment to at
  least `N` and rounds its size up to a multiple of `N`. `Buffer` is 16 bytes
  with alignment 16, not 1.
- It is a modifier, like `packed`, and the two may appear in either order:
  `align(4) packed struct` and `packed align(4) struct` are the same declaration.
- **`align` only ever raises.** An alignment below the type's natural one is
  ignored, not rejected: `align(2)` on `{ u8, i32 }` leaves it 8 bytes with
  alignment 4, which is what a C compiler does with
  `__attribute__((aligned(2)))`.
- **`align` and `packed` compose.** The packing still decides the offsets, the
  alignment is the larger of the two requirements, and the size is then rounded up
  to it. `align(4) packed struct Record` above is 8 bytes with `value` at offset 1
  and alignment 4.
- `N` must be a power of two no larger than 4096 (`E0491`); `align(N)` that is not
  attached to a `struct` or `union` is `E0492`; a non-integer inside `align(` is
  `E0490`.
- `align` is not a keyword, so a variable or a function may still be named
  `align`; only `align(` before an aggregate is the modifier.
- A field's alignment is its type's. There is no field-level annotation: a field
  that needs more alignment is a field of an `align(N)` type.
- An aligned aggregate may cross the C ABI **by value** like any other; `abi.md`
  §10.1 gives the measured transport rule. Its size includes the padding, so
  `align(32)` can push a small aggregate from registers to memory — that is the
  same choice a C compiler makes for the same shape.

### 3.8 Bitfields

```kyn
struct Wire {
    kind: u3,
    tag: u5,
}
```

- An integer type may have any width from 1 to 128: `u1`…`u128`, `i1`…`i128`.
  A width that is not a whole number of bytes makes the field a **bitfield**, and
  adjacent bitfields pack into one storage unit.
- The width lives in the **type**, not in a colon suffix. There is no
  `name: u32: 3` syntax, so `w.kind` really is a `u3` and the ordinary promotion
  rules apply to it.
- Layout rules, which are deterministic and identical on every target:
  1. A field's unit is the smallest of 1, 2, 4 or 8 bytes that can hold its
     width.
  2. A field never straddles a boundary of its own unit width. `{kind: u3, tag:
     u5}` is one byte; `{a: u3, b: u5, c: u12}` places `c` at **bit 16**, not bit
     8, because bits 8..19 do not fit the 2-byte block that starts at byte 0.
  3. A non-bitfield member closes the run's byte range, and a later bitfield
     resumes after it.
  4. A `packed` aggregate inserts no padding, so its run takes a unit wide enough
     for the whole run and a field may cross a boundary the aligned form forbids.
- Layouts the emitted type cannot mirror are **rejected** with `E0489` rather
  than laid out in a way that would silently disagree with the code generator. The
  one common shape this refuses is two runs whose units would overlap, such as
  `{a: u31, b: u33}`; C accepts that shape by making both runs share one 8-byte
  unit, and Kyn does not claim that rule.
- **C compatibility is limited and stated:** a bitfield struct is C compatible
  when its widths sum to at most 8 bits, with no non-bitfield member, matched
  against the C struct that declares each member `unsigned char`. Wider runs are
  laid out by the rules above and are deterministic, but a boundary that depends
  on them is outside what the project promises. Fixture `cabi_bitfields` covers
  the compatible subset in both directions.
- A union member cannot be a bitfield (`E0487`): overlapping runs have no defined
  bit positions.

### 3.9 Anonymous members

```kyn
struct Packet {
    kind: u8,
    struct {
        length: u32,
        flags: u8,
    },
}
```

- An inline `struct { ... }`/`union { ... }` with **no name** is an anonymous
  member. It occupies its own space, laid out by the ordinary rules, and its field
  names are **promoted** into the enclosing aggregate: `p.length` reaches the field
  inside it, and `Packet { kind: 1, length: 2, flags: 3 }` initializes it by those
  names.
- Promotion is **transitive**: an anonymous member inside an anonymous member
  promotes its names all the way out (`struct { struct { b: i32 } }` makes `b`
  reachable at the top).
- The member is a real member for layout and for the C ABI: measured against clang,
  `struct { i32 x; struct { i32 y; i8 z; } }` puts `y` at byte 4 and `z` at 8 with
  size 12, and the anonymous struct's own trailing padding is part of it.
- A **promoted name may not collide** with anything at its level — a sibling field,
  or a name promoted by another anonymous member — and that is `E0493`. C rejects
  the same shapes.
- An initializer must still name **every** promoted field of a struct-shaped
  anonymous member (`E0458` otherwise). A union-shaped one follows the union rule:
  naming one of its fields is what makes it live.
- Only an aggregate can be anonymous: `struct S { a: i32, i32 }` is a parse error,
  because a type with no name would declare nothing.
- A **named** member of an aggregate type does not promote: `inner: struct { ... }`
  is reached as `s.inner.field`. Only the nameless form promotes.

### 3.10 Enums

```kyn
enum Color: u8 {
    Red,
    Green = 4,
    Blue,
}
```

- The backing type must be an integer type; it defaults to `i32`.
- Values are explicit or continue from the previous value plus one.
- Variants are referenced as `Color.Blue` and have type `Color`.
- An enum is a distinct type; it does not implicitly convert to or from its
  backing integer. Use `as`.
- Values must fit the backing type (`E0408`).

### 3.11 `match`

```kyn
match (color) {
    Color.Red => { return 1; },
    Color.Green => { return 2; },
    _ => { return 3; },
}
```

- The scrutinee is evaluated **exactly once**, and its value is compared with
  each pattern in source order. That matters if the scrutinee calls a function:
  the side effect happens once, not once per arm.
- A pattern is an expression compared for equality, so it must have the same
  type as the scrutinee — the rule `==` uses (`E0431`/`E0432` apply, and a
  mismatch is `E0494`). Patterns are constants: literals and enum variants.
- The scrutinee must be an integer, `bool` or enum (`E0494`).
- **The arm list must be exhaustive**, which means it must contain `_ => { ... }`
  (`E0495`). There is no fall-through and no implicit "do nothing", so a match
  that could silently miss a value is a hole. Listing every variant of an enum
  is not by itself accepted as exhaustive: the variant list belongs to a
  declaration, and accepting it would need a second notion of exhaustiveness.
- At most one wildcard arm, and no arm may follow it: both would be unreachable
  (`E0496`). A repeated pattern value is also unreachable (`E0496`).
- `break` and `continue` inside an arm act on the enclosing loop, exactly as they
  would without the match.
- Like `if` and `while`, a match needs no trailing `;`.
- An exhaustive match whose arms all return terminates its function, so it can be
  the last statement of a non-`void` function.

### 3.12 Globals

```kyn
const GREETING: *const u8 = "Kyn";
const ORIGIN: Point = Point { x: 1, y: 2 };
const VALUES: [4]i32 = [1, 2, 3, 4];
const COLOR: Color = Color.Red;
var counter: i32 = 0;
let version: i32 = 1;
```

- `const` and `let` globals are immutable; `var` globals are mutable.
- Globals require an initializer (`E0413`).
- Global initializers must be constant expressions: literals, unary/binary
  operations on constants, casts, enum variants, `array.len` on fixed-size
  arrays, string literals, and struct or array initializers whose contents are
  also constant. Function calls, address-of, dereference and non-enum value
  reads are rejected (`E0412`).
- Globals are emitted as LLVM globals with explicit storage; no constructor or
  runtime initialization is generated. Aggregate constants are emitted in the
  same constant section.
- A non-exported global is private to its compilation unit: its symbol is
  module-mangled and not link-visible. `export` opts a global into C linkage
  under its source name, with `var` emitting writable storage and `let`/`const`
  read-only storage.

## 4. Statements

```
statement =
    block
  | "if" "(" expr ")" block [ "else" ( if-statement | block ) ]
  | "while" "(" expr ")" block
  | "match" "(" expr ")" "{" match-arm { "," match-arm } "}"
  | "for" ...                                 ; reserved, not implemented
  | "return" [ expr ] ";"
  | "break" ";"
  | "continue" ";"
  | ("let" | "var" | "const") ident [ ":" Type ] [ "=" expr ] ";"
  | expr ";"
  | ";"

match-arm = ( "_" | expr ) "=>" block
```

### 4.1 Local declarations

```kyn
let answer: i32 = 42;   // immutable
var count: i32 = 0;     // mutable
const limit: i32 = 10;  // immutable, same rules as let locally
var buffer: [64]u8;     // typed, uninitialized
```

- A local needs a type, an initializer, or both (`E0420`). The type of a local
  with an initializer and no declared type is the initializer's type, and a
  literal with no other context materializes as `i64`/`f64`; write the type when
  you want a narrower one, since there is no implicit numeric conversion.
- Without an initializer, the stack slot is uninitialized. Reading it before
  assignment is diagnosed by the static analyzer (`E0501`) when the compiler
  can prove the read may happen. Unproven cases are not checked yet.
- `let`/`const` locals cannot be assigned (`E0442`).
- A declaration's scope begins after the declaration and ends with the
  enclosing block. Shadowing an outer declaration is allowed; redeclaring the
  same name in the same scope is `E0421`.

### 4.2 Blocks and control flow

```kyn
if (count > 0) {
    count -= 1;
} else if (count == 0) {
    count = 10;
} else {
    count = 0;
}

while (count < 10) {
    count += 1;
    if (count == 5) {
        continue;
    }
    if (count == 9) {
        break;
    }
}
```

- Conditions must have type `bool` (`E0463`). There is no truthiness.
- `else` may be omitted or followed by `if` or a block.
- `break` and `continue` are valid only inside a loop (`E0415`).
- There is no `for`, `switch`, `match`, `goto` or labeled control flow.

## 5. Expressions

### 5.1 Precedence and associativity

From lowest to highest:

| Level | Operators                         | Associativity |
| ----- | --------------------------------- | ------------- |
| 1     | `=` `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | right |
| 2     | `\|\|`                            | left          |
| 3     | `&&`                              | left          |
| 4     | `\|`                              | left          |
| 5     | `^`                               | left          |
| 6     | `&`                               | left          |
| 7     | `==` `!=`                         | left          |
| 8     | `<` `<=` `>` `>=`                 | left          |
| 9     | `<<` `>>`                         | left          |
| 10    | `+` `-`                           | left          |
| 11    | `*` `/` `%`                       | left          |
| 12    | `as`                              | left, postfix |
| 13    | unary `-` `!` `~` `&` `*`         | right         |
| 14    | calls, index, field access        | left          |

Parentheses group expressions. `as` binds tighter than arithmetic, so
`a * b as u64` parses as `a * (b as u64)`.

### 5.2 Arithmetic and bitwise operators

- `+ - * / %` require numeric operands of the same type. An integer literal is
  adapted to the concrete operand type when it fits.
- Integer `+ - *` and unary `-` trap at runtime on signed and unsigned
  overflow. `%` and shifts are also checked at runtime.
- `/` and `%` on signed integers truncate toward zero; on unsigned integers
  they use unsigned division. A dynamic zero divisor traps. Signed division
  and remainder also trap on `INT_MIN / -1`, at every width including `i128` —
  the trap is a run-time property of the program, not a compile-time error.
- The minimum of a signed type is written as a unary minus in front of its
  magnitude (`-128` for an `i8`, `-170141183460469231731687303715884105728` for
  an `i128`), and that spelling is accepted at its own width rather than being
  computed as a subtraction that would overflow.
- Mixing different concrete numeric types is an error (`E0439`); use `as`.
- `& | ^` require integer operands.
- `<< >>` require integer operands; the left operand determines the result
  type. A constant shift amount outside `[0, bits)` is `E0504`; a dynamic
  out-of-range or negative shift amount traps.
- Pointer arithmetic: `p + n` and `p - n` produce a pointer of the same type,
  scaled by the pointee size. `p - q` for pointers to the same element type
  produces `isize`. `n + p` is not allowed.
- Pointer ordering comparisons (`<`, `<=`, `>`, `>=`) are allowed.
- Pointer equality with `null` is allowed (`p == null`, `p != null`).

### 5.3 Logical operators

`&&` and `||` require `bool` operands and return `bool`. They short-circuit:
the right operand is evaluated only when needed, including all side effects.

`!` requires `bool`.

### 5.4 Comparison

- `==` and `!=` are defined for numeric types, pointers, `bool` and enums of
  the same type.
- Ordering is defined for numeric types and pointers.
- Comparing different types is an error; there are no implicit promotions.

### 5.5 Assignment

```kyn
value = 10;
value += 1;
value <<= 2;
*p = 3;
point.x = 4;
point_ptr->y = 5;
array[index] = 6;
```

- The target must be an lvalue: a local/global variable, a dereference, a
  struct field of an lvalue (or through a pointer via `->`), or an index of an
  lvalue/pointer/slice. Built-in `.len` and `.ptr` properties on slices and
  arrays are read-only values, not lvalues (`E0441`).
- Assigning to an immutable location is `E0442`.
- Simple assignment permits identical types, `[]T` to `[]const T` (with
  identical `T`), an integer literal that fits, a float literal to `f32`/`f64`,
  and `null` to a pointer. Everything else requires an explicit cast (`E0462`).
- Compound assignment is defined for numeric operands and shifts; both sides
  must have the same concrete type. Pointer `+=`/`-=` is not supported in
  v0.1.
- Aggregate assignment copies the complete value when source and destination
  have the same type (or `[]T` to `[]const T`).

### 5.6 Calls

```kyn
puts("hello");
let sum: i32 = add(1, 2);
```

- The callee is either a direct function name or a value of function type
  (`fn(P) R`), which is called indirectly: `let f: fn(i32) i32 = double; f(1)`.
  An indirect call checks its arguments and result against that signature,
  since there is no declaration to read them from.
- Argument count must match (`E0446`) and each argument must be assignable to
  its parameter type.
- Arguments are evaluated left to right.
- Aggregate arguments by value are passed by value within Kyn. `extern` and
  `export` functions support integer-class aggregates on `x86_64-linux`,
  including float/integer members merged within one eightbyte, one-field
  `f32`/`f64` structs via scalar SSE, two-adjacent-`f32` structs via
  `<2 x float>` SSE/SSEUP, three-adjacent-`f32` structs via
  `<2 x float>, float`, four-adjacent-`f32` structs via `<2 x float>, <2 x float>`,
  two-direct-`f64` structs via two SSE argument
  registers, direct `{ f32, f64 }` and `{ f64, f32 }` structs via their two SSE
  argument registers, direct `{ f32, i64 }` / `{ f32, u64 }` and `{ f64, i64 }` /
  `{ f64, u64 }` structs via one SSE and one INTEGER argument register, and the
  reverse `{ i64, f32 }` / `{ i64, f64 }` layouts via INTEGER then SSE,
  direct `{ i8/u8, f64 }` / `{ i16/u16, f64 }` structs via exact-width INTEGER
  plus SSE argument registers (the reverse `{ f64, i8/u8 }` / `{ f64, i16/u16 }`
  order is supported likewise), direct `{ bool, f64 }` / `{ f64, bool }`
  via an `i8` argument register, singleton `i8`/`i16`/`i32`/`i64` aggregates
  in one exact-width INTEGER argument register (1→`i8`, 2→`i16`, ≤4→`i32`,
  otherwise `i64`), aggregates with two or more smaller-INTEGER
  members packed into one eightbyte followed by a single `f32` or `f64`
  (only the scalar in the next eightbyte) via one `i64` and one SSE argument
  register, sub-32-bit integer members and `bool` inside
  merged `INTEGER` eightbytes via a packed `i64` register,
  exact multi-member layouts with an SSE-only slot and an INTEGER/merged slot
  (`{ f32, f32, i32 }`, `{ f32, f32, i64 }`, `{ i32/u32, f32, f32 }`,
  `{ f32, i32/u32, f32 }`, `{ i32/u32, f32, f64 }`, `{ f32, i32/u32, f64 }`,
  `{ f64, i32/u32, i32/u32 }`, `{ f64, i32/u32, f32 }`,
  `{ i64/u64, f32, f32 }`, `{ f32, f32, f64 }`, `{ f64, f32, f32 }`, and
  four-member `{ f32, f32, i32, f32 }` / `{ i32/u32, f32, f32, f32 }` /
  `{ f32, i32/u32, f32, f32 }`) via their probed Clang coercions,
  direct `{ f64, i32 }` structs via SSE `double` plus INTEGER `i32`,
  direct `{ i32, f64 }` structs via INTEGER `i32` plus SSE `double`, and larger
  aggregates passed via `byval`; fixed arrays and other unsupported small
  layouts are rejected with `E0473`.

### 5.7 Casts

```kyn
let wide: i64 = small as i64;
let byte: u8 = value as u8;       // truncates
let raw: usize = ptr as usize;    // pointer to integer
let ptr: *u8 = raw as *u8;        // integer to pointer
let code: u8 = Color.Blue as u8;  // enum to integer
let color: Color = 3 as Color;    // integer to enum
```

Allowed conversions:

| From                       | To                                              |
| -------------------------- | ----------------------------------------------- |
| integer, char, bool, float | integer, char, bool, float (numeric pairs)      |
| integer, char              | pointer                                         |
| pointer                    | pointer, integer, bool                          |
| `*[N]T`                    | `[]T`, `[]const T`                              |
| `*const [N]T`              | `[]const T`                                     |
| `[]T`                      | `[]T`, `[]const T`                              |
| `[]const T`                | `[]const T`                                     |
| enum                       | integer, enum                                   |
| float                      | integer, bool, float                            |
| null                       | pointer                                         |
| pointer                    | function value (`fn(P) R`)                      |
| function value (`fn(P) R`) | pointer, integer                                |
| integer, char              | function value (`fn(P) R`)                      |

Other casts between aggregates and functions are rejected (`E0447`): `as` never
converts between two function *signatures*, because a signature is a meaning
and not a representation, and an aggregate never becomes one address. Casting a
provably `null` array pointer to a slice is rejected (`E0506`), and a dynamic
`null` array pointer cast to a slice traps at runtime. Numeric casts do not
insert runtime range checks in v0.1; converting an out-of-range numeric value
is the programmer's responsibility.

Every pair above is compiled, including the `bool`/float ones, which are not a
single machine conversion in either direction:

- **`bool` → float** is `false` → `0.0` and `true` → `1.0`, exactly. The bit
  widens to a 32-bit integer first, because no floating conversion accepts a
  one-bit operand.
- **float → `bool`** is `false` only for a zero (of either sign) and `true`
  otherwise. A NaN is **true**, matching C's `(_Bool)` conversion: the test is
  "not equal or unordered", not "ordered and not equal".
- **`bool` → integer** is `0` or `1`; **integer → `bool`** is `false` only for
  zero. These agree with C.

A constant cast folds into the *destination* category, so a global such as
`const WIDE: f64 = 3 as f64` holds a float constant. A chain truncates at each
step and the outer cast sees the already-converted value: `3.9 as i32 as f64`
is `3.0`, not `3.9`.

### 5.8 Field access

```kyn
let x: i32 = point.x;
point.y = 3;
let x: i32 = pointer->x;
let x: i32 = (*pointer).x;  // equivalent
let n: usize = slice.len;
let data: *i32 = slice.ptr;
let fixed_n: usize = array.len;
```

- `.` accesses struct fields, enum variants on an enum type name, `slice.len` /
  `slice.ptr` on slices, and `array.len` on fixed-size arrays.
- `->` accesses struct fields, `->len` / `->ptr` on pointers to slices, and
  `->len` on pointers to fixed-size arrays.
- `slice.ptr` has type `*T` for `[]T` and `*const T` for `[]const T`. Both
  `slice.len` and `slice.ptr` (and `array.len`) are read-only non-lvalue
  properties (`E0441` on assignment, `E0464` on `&`).
- Enum variants use `.` on the enum type name.
- Accessing a missing field or variant is `E0453` / `E0449`.

### 5.9 Indexing and slicing

```kyn
let value: i32 = array[2];
array[2] = 9;
let value: i32 = pointer[3];
let total: i32 = slice.len as i32;
let element: i32 = slice[index];
let all: []i32 = array[..];
let tail: []i32 = slice[start..];
let head: []const i32 = slice[..end];
let mid: []i32 = slice[start..end];
```

- Indexing `base[index]` accepts an lvalue array, an array literal, a pointer,
  or a slice.
- Slicing `base[..]`, `base[start..]`, `base[..end]`, and `base[start..end]`
  accepts an lvalue array, a pointer to a fixed-size array (`*[N]T` or
  `*const [N]T`), or a slice (`[]T` or `[]const T`).
- Index and slice bound expressions must have an integer type (`E0454`).
- `start` defaults to `0` when omitted; `end` defaults to the base length when
  omitted. Bounds are inclusive-exclusive (`[start, end)`).
- Constant out-of-bounds array indices, negative constant slice indices, and
  constant invalid slice ranges (`start < 0`, `end < 0`, `start > end`, or a
  bound exceeding a statically known array length) are rejected at compile time
  (`E0502`).
- Dynamic array/slice indices and slice ranges are checked at runtime and trap
  on out-of-range access. Slicing a `null` array pointer is diagnosed at
  compile time when provable (`E0506`) and traps at runtime otherwise.
- Slicing is const-polymorphic: mutable bases yield `[]T` (or `[]const T` when
  contextualized by `[]const T`), and immutable bases yield `[]const T`.
- Indexed assignment through `[]const T` is rejected (`E0442`).

### 5.10 Struct and array literals

```kyn
let p: Point = Point { x: 1, y: 2 };
let values: [3]i32 = [1, 2, 3];
```

- Struct initializers must name every field of the struct, with no duplicates.
- Array literals cannot be empty (`E0459`) and all elements must share a type.
  Integer literal elements adapt to a concrete element type.
- Aggregate values can be initialized into a local, passed as arguments and
  copied into an existing lvalue of the same type. Aggregate copies are not
  partial or field-wise unless the value is itself an aggregate literal being
  stored field by field.

## 6. Entry point and process behavior

The native entry point is:

```kyn
fn main() i32 {
    return 0;
}
```

The return value becomes the process exit status.

Because `main` is the function the C runtime calls, its signature is checked
rather than assumed — the loader passes `argc` and the argument vector, and reads
an `int` back, so a shape it cannot satisfy is `E0477`:

```kyn
fn main() i32 { ... }
fn main(argc: i32) i32 { ... }
fn main(argc: i32, argv: **u8) i32 { ... }
fn main(argc: i32, argv: **const u8) i32 { ... }
```

- The return type is `i32`. A `f64` or `void` would make the exit status
  meaningless (`E0477`).
- `argc` is `i32`: the C `int` the loader passes. `u64` and other widths are
  rejected rather than read from the wrong half of a register.
- `argv` is `**u8` — the C `char **` — or `**const u8` when the program does not
  write through it. `argv[argc]` is the null terminator, so the vector is
  readable up to and including it.
- At most two parameters: a third would read a register the loader never set.
- Only the *unmarked* `main` of the root module is the entry point. An
  `export fn main` or an `extern fn main` is an ordinary function with C
  linkage, and a library target may expose a `main` of any shape; neither is
  checked, because neither is what the loader calls.

Command-line arguments reach a `run` invocation after `--`, and the integration
suite covers them with a `.args` fixture file (one argument per line, empty lines
meaningful).

## 7. Unsupported constructs

The following are rejected or simply not part of v0.1:

- isolated module namespaces, package registries and module re-exports (basic relative-path and qualified-alias imports are implemented);
- `for`, `switch`, `match`, `do`, `goto`, labels;
- `defer`, `errdefer`, exceptions, closures, lambdas;
- const-polymorphic slice constructors and additional slice ergonomics;
- generics, traits, interfaces, operator overloading;
- variadic Kyn functions without a C caller (a variadic declaration must be
  `export` or `extern`), and forwarding a received argument list (`v`-style
  callees need a `va_list` parameter type) — see
  [the ABI guide](abi.md#variadic-declarations);
- arrays as value parameters/returns; aggregates containing floating-point
  fields across `extern`/`export` boundaries;
- unions, packed structs, bitfields, alignment/attribute syntax;
- implicit numeric conversions and implicit pointer mutability conversion;
- runtime alignment and full initialization checks;
- a preprocessor or macros;
- threads, atomics and inline assembly syntax.

These are future work, not silently accepted extensions.

## 8. Examples

See `tests/integration/cases/` for executable examples and
`tests/integration/errors/` for programs that must fail with a specific
diagnostic.
