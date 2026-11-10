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
( ) { } [ ] , ; : . -> @
+ - * / % & | ^ ~ ! = == != < <= > >= << >>
+= -= *= /= %= &= |= ^= <<= >>=
&& ||
```

`@` is lexed but has no grammar rule in v0.1.

## 2. Types

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
  and `{ double, float }`; and a direct
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

### 3.3 Structs

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
  specified exactly once; order does not matter.
- Field access is `.` on a value and `->` on a pointer.

### 3.4 Enums

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

### 3.5 Globals

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
  reads are rejected (`E0419`).
- Globals are emitted as LLVM globals with explicit storage; no constructor or
  runtime initialization is generated. Aggregate constants are emitted in the
  same constant section.

## 4. Statements

```
statement =
    block
  | "if" "(" expr ")" block [ "else" ( if-statement | block ) ]
  | "while" "(" expr ")" block
  | "return" [ expr ] ";"
  | "break" ";"
  | "continue" ";"
  | ("let" | "var" | "const") ident [ ":" Type ] [ "=" expr ] ";"
  | expr ";"
  | ";"
```

### 4.1 Local declarations

```kyn
let answer: i32 = 42;   // immutable
var count: i32 = 0;     // mutable
const limit: i32 = 10;  // immutable, same rules as let locally
var buffer: [64]u8;     // typed, uninitialized
```

- A local needs a type, an initializer, or both (`E0420`).
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
  and remainder also trap on `INT_MIN / -1`.
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

- The callee must be a direct function name. Indirect calls through function
  pointers are not supported yet.
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
  argument registers, direct `{ f64, i32 }` structs via SSE `double` plus INTEGER `i32`,
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

Other casts between aggregates and functions are rejected (`E0447`). Casting a
provably `null` array pointer to a slice is rejected (`E0506`), and a dynamic
`null` array pointer cast to a slice traps at runtime. Numeric casts do not
insert runtime range checks in v0.1; converting an out-of-range numeric value
is the programmer's responsibility.

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

The return value becomes the process exit status. `fn main()` without a return
type is accepted by the language but will not match the C `main` signature
expected by the linker; use `i32` for executables.

## 7. Unsupported constructs

The following are rejected or simply not part of v0.1:

- isolated module namespaces, package registries and module re-exports (basic relative-path and qualified-alias imports are implemented);
- `for`, `switch`, `match`, `do`, `goto`, labels;
- `defer`, `errdefer`, exceptions, closures, lambdas;
- const-polymorphic slice constructors and additional slice ergonomics;
- generics, traits, interfaces, operator overloading;
- variadic functions and variadic `extern` declarations;
- arrays as value parameters/returns; aggregates containing floating-point
  fields across `extern`/`export` boundaries;
- indirect calls and first-class function values;
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
