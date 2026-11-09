# Kyn language reference (v0.1)

This document describes the language as implemented by Kyn v0.1. If a
construct is not described here or is listed under
[Unsupported constructs](#7-unsupported-constructs), it is not part of the
current language.

## 1. Lexical structure

### 1.1 Source files

- A compilation unit is one UTF-8 source file with the `.kyn` extension.
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
false   fn      for     if          let     null    return  struct
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
- `[N]T` is a fixed-size array of exactly `N` elements. `N` must be a positive
  constant integer known at compile time.
- `[]T` is a slice: a fat pointer holding a data pointer and a `usize` length.
  A mutable slice is constructed with an explicit cast from a pointer to a
  fixed-size array, such as `&values as []i32`. `[]const T` is constructed in
  the same way from an immutable array pointer, or cast from a mutable slice.
- Struct, enum and primitive names resolve to their declarations.
- `void` is valid only as a function return type; parameters and variables
  cannot have type `void`.
- Function types exist internally for direct calls but cannot be written in
  source yet.

There are no implicit pointer conversions other than `null` to a pointer type,
and no pointer mutability conversion (`*T` to `*const T` requires an explicit
cast in v0.1).

## 3. Top-level declarations

A program is a sequence of declarations. Top-level names share one namespace
within the compilation unit.

### 3.1 Functions

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
- Aggregate parameters and aggregate return types use the internal Kyn ABI.
  They are not supported across `extern`/`export` C ABI boundaries in v0.1;
  pass a pointer instead. Arrays are also not valid C prototypes.
- A function with a non-void return type must return on every path; otherwise
  `E0414`.
- `return;` is valid only in a `void` function.

### 3.2 External and exported functions

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
  operations on constants, casts, enum variants, string literals, and struct
  or array initializers whose contents are also constant. Function calls,
  address-of, dereference and identifiers other than enum variants are
  rejected (`E0412`).
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
  field of an lvalue (or any field through a mutable pointer), or an index of
  an lvalue/pointer.
- Assigning to an immutable location is `E0442`.
- Simple assignment permits identical types, an integer literal that fits, and
  `null` to a pointer. Everything else requires an explicit cast (`E0462`).
- Compound assignment is defined for numeric operands and shifts; both sides
  must have the same concrete type. Pointer `+=`/`-=` is not supported in
  v0.1.
- Aggregate assignment copies the complete value when source and destination
  have the same type.

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
  `export` functions reject aggregate arguments and returns in v0.1; pass a
  pointer instead.

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
| enum                       | integer, enum                                   |
| float                      | integer, bool, float                            |
| null                       | pointer                                         |

Casts between aggregates and functions are rejected (`E0447`). Casts do not
insert runtime checks in v0.1; converting an out-of-range value is the
programmer's responsibility.

### 5.8 Field access

```kyn
let x: i32 = point.x;
point.y = 3;
let x: i32 = pointer->x;
let x: i32 = (*pointer).x;  // equivalent
```

- `.` requires a struct value or enum type name.
- `->` requires a pointer to a struct.
- Enum variants use `.` on the enum type name.
- Accessing a missing field or variant is `E0453` / `E0449`.

### 5.9 Indexing

```kyn
let value: i32 = array[2];
array[2] = 9;
let value: i32 = pointer[3];
let total: i32 = slice.len as i32;
let element: i32 = slice[index];
```

- The base may be an lvalue array, an array literal, a pointer, or a slice.
- The index must be an integer type; it is not automatically converted.
- Constant indexes outside the array bounds are `E0502`.
- Dynamic indexes into fixed arrays and slices are bounds-checked at runtime
  and trap on out-of-range access.
- `slice.len` returns the slice length as `usize`.
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

- modules, imports, namespaces and packages;
- `for`, `switch`, `match`, `do`, `goto`, labels;
- `defer`, `errdefer`, exceptions, closures, lambdas;
- slice construction beyond `&array as []T`, subslice syntax, and const-polymorphic slice operations;
- generics, traits, interfaces, operator overloading;
- variadic functions and variadic `extern` declarations;
- aggregate parameters/returns across `extern`/`export` C ABI boundaries;
- indirect calls and first-class function values;
- unions, packed structs, bitfields, alignment/attribute syntax;
- implicit numeric conversions and implicit pointer mutability conversion;
- runtime null, alignment and full initialization checks;
- a preprocessor or macros;
- threads, atomics and inline assembly syntax.

These are future work, not silently accepted extensions.

## 8. Examples

See `tests/integration/cases/` for executable examples and
`tests/integration/errors/` for programs that must fail with a specific
diagnostic.
