# Kyn diagnostic codes

Diagnostics are stable, machine-readable identifiers. Integration tests assert
specific codes for invalid programs, so a code should not be reused for a
different meaning.

Rendered form:

```
path:line:column: error[E0427]: unknown identifier 'missing'
    return missing;
           ^^^^^^^
```

Duration: errors fail compilation; warnings are reported and do not change the
exit status. Backend `E06xx` diagnostics normally indicate either an explicitly
unsupported construct or an internal compiler invariant violation.

| Code | Meaning |
| ---- | ------- |
| `E0001` | reserved sentinel used by compiler unit-test diagnostics; production stages do not emit it |

## Lexer (`E01xx`)

| Code | Meaning |
| ---- | ------- |
| `E0101` | invalid byte in source |
| `E0102` | expected digits after a base prefix |
| `E0103` | expected exponent digits |
| `E0104` | unterminated string literal |
| `E0105` | unterminated character literal |
| `E0106` | unterminated block comment |

## Parser (`E02xx`)

| Code | Meaning |
| ---- | ------- |
| `E0201` | expected a specific token, found another |
| `E0202` | expected `fn` after `extern` |
| `E0203` | expected `fn` after `export` |
| `E0204` | expected a declaration |
| `E0205` | expected a function name |
| `E0206` | expected a parameter name |
| `E0207` | expected a struct name |
| `E0208` | expected a struct field name |
| `E0209` | expected an enum name |
| `E0210` | expected an enum variant name |
| `E0211` | expected a global variable name |
| `E0212` | global needs a type or an initializer |
| `E0213` | expected a type |
| `E0214` | declaration inside a function body |
| `E0215` | expected a local variable name |
| `E0217` | expected `if` or a block after `else` |
| `E0218` | expected a field name after `.`/`->` |
| `E0219` | malformed or oversized integer literal |
| `E0220` | malformed float literal |
| `E0221` | expected an expression |
| `E0222` | expected a field name in a struct initializer |
| `E0223` | incomplete hex escape in a string |
| `E0224` | invalid hex escape in a string |
| `E0225` | unknown escape sequence in a string |
| `E0226` | empty character literal |
| `E0227` | incomplete hex escape in a character literal |
| `E0228` | unknown escape sequence in a character literal |
| `E0229` | invalid UTF-8 in a character literal |
| `E0230` | expected a quoted path after `import` |
| `E0231` | cyclic import |
| `E0232` | source file cannot be read |
| `E0236` | expected a module alias after `as` |

## Name resolution and type checking (`E04xx`)

| Code | Meaning |
| ---- | ------- |
| `E0401` | duplicate declaration in one module |
| `E0402` | function has no body and is not `extern` |
| `E0403` | struct contains itself by value |
| `E0404` | duplicate struct field |
| `E0405` | enum backing type is not an integer |
| `E0406` | duplicate enum variant |
| `E0407` | enum variant value is not a constant integer |
| `E0408` | enum value does not fit the backing type |
| `E0409` | duplicate parameter name |
| `E0410` | void parameter |
| `E0411` | global variable has type `void` |
| `E0412` | global initializer is not constant |
| `E0413` | global has no initializer |
| `E0414` | function may reach the end without returning a value |
| `E0415` | `break`/`continue` outside a loop |
| `E0416` | `return` outside a function |
| `E0417` | void function returns a value |
| `E0418` | missing return value |
| `E0419` | local variable has type `void` |
| `E0420` | local needs a type or an initializer |
| `E0421` | duplicate local variable in the same scope |
| `E0422` | unknown type |
| `E0423` | array length is not a constant integer |
| `E0424` | array length is not greater than zero |
| `E0425` | array type has no explicit length |
| `E0426` | integer literal does not fit the required type |
| `E0427` | unknown identifier |
| `E0428` | dereference of a non-pointer |
| `E0429` | unary `-` on a non-numeric operand |
| `E0430` | unary `~` on a non-integer operand |
| `E0431` | incomparable types for equality |
| `E0432` | type cannot be compared for equality |
| `E0433` | incomparable types for ordering |
| `E0434` | type does not support ordering |
| `E0435` | pointer subtraction with different element types |
| `E0436` | bitwise operator on non-integers |
| `E0437` | shift operator on non-integers |
| `E0438` | arithmetic operator on non-numeric operands |
| `E0439` | mismatched concrete numeric operand types |
| `E0440` | integer literal does not fit the unified operand type |
| `E0441` | assignment target is not an lvalue |
| `E0442` | assignment to an immutable location |
| `E0443` | shift assignment on non-integers |
| `E0444` | compound assignment operand mismatch |
| `E0445` | call of a non-function value |
| `E0446` | wrong argument count |
| `E0447` | invalid cast |
| `E0448` | `->` used on an enum |
| `E0449` | unknown enum variant |
| `E0450` | field access through a pointer without `->` |
| `E0451` | `->` used on a non-pointer |
| `E0452` | field access on a type without fields |
| `E0453` | unknown struct, slice or array field |
| `E0454` | non-integer index or slice bound |
| `E0455` | indexing or slicing an unsupported type |
| `E0456` | struct initializer for a non-struct type |
| `E0457` | unknown field in a struct initializer |
| `E0458` | missing field in a struct initializer |
| `E0459` | empty array literal |
| `E0460` | array literal element does not fit |
| `E0461` | array literal elements have different types |
| `E0462` | assignment without an explicit cast |
| `E0463` | condition is not `bool` |
| `E0464` | `&` applied to a non-lvalue expression |
| `E0465` | field access on a non-lvalue, non-pointer |
| `E0466` | indexing or slicing a non-lvalue, non-pointer, non-literal |
| `E0467` | private declaration or type accessed from another module |
| `E0468` | duplicate module alias in one source module |
| `E0469` | unknown module alias |
| `E0470` | imported module has no declaration with that name |
| `E0471` | unqualified imported name is ambiguous |
| `E0472` | external function symbol has conflicting declarations or definitions |
| `E0473` | aggregate parameter or return layout is unsupported at the C ABI boundary |
| `E0474` | variadic declaration is neither `export` nor `extern`, or has no fixed parameter |
| `E0475` | argument cannot be passed to a variadic `extern` function |
| `E0476` | exported global has a layout the C ABI target cannot represent |
| `E0477` | entry point `main` has a signature the C runtime cannot call |
| `E0478` | `va_arg` has no concrete scalar type in context |
| `E0479` | `va_arg` retrieval type is not the promoted width the caller passed |
| `E0480` | `va_arg` used outside a variadic function |
| `E0484` | `packed` modifier is not attached to a `struct` or `union` declaration |
| `E0485` | a union initializer does not name exactly one member |
| `E0486` | an integer type width is out of range (`u0`, `u200`); the width is 1 to 128 |
| `E0487` | a union member is a bitfield; overlapping runs have no defined bit positions |
| `E0488` | an aggregate has a member with no known size (internal consistency check) |
| `E0489` | a bitfield run would need a storage unit overlapping bytes already emitted; the layout is refused rather than emitted in a form that disagrees with it |
| `E0490` | `align(` is not followed by an integer |
| `E0491` | an alignment is not a power of two, or is larger than 4096 |
| `E0492` | `align(N)` is not attached to a `struct` or `union` declaration |
| `E0493` | a name promoted out of an anonymous member collides with another field of the same aggregate |
| `E0494` | a `match` scrutinee is not an integer, `bool` or enum, or a pattern's type cannot be compared with it |
| `E0495` | a `match` has no wildcard arm, so it is not exhaustive; or more than one wildcard |
| `E0496` | a `match` arm can never run: it follows the wildcard, or it repeats a value already matched |

## Static analyzer (`E05xx`, `W05xx`)

Errors:

| Code | Meaning |
| ---- | ------- |
| `E0501` | variable may be used before initialization |
| `E0502` | constant index or slice range out of bounds |
| `E0503` | provable division by zero |
| `E0504` | constant shift amount out of range |
| `E0505` | constant expression overflows its type |
| `E0506` | provable null pointer dereference |

Warnings:

| Code | Meaning |
| ---- | ------- |
| `W0501` | unreachable statement |
| `W0502` | condition/loop condition is always true or false |

## Backend (`E06xx`)

| Code | Meaning |
| ---- | ------- |
| `E0601` | internal: global has no resolved type |
| `E0602` | global initializer cannot be emitted as a constant |
| `E0603` | pointer difference on an element type without a known scalar size |
| `E0604` | callee has no function signature |
| `E0605` | internal: unsupported cast from the semantic layer |
| `E0606` | internal: expected an aggregate initializer |

`E0604` is a user-facing limitation: function pointers and indirect calls are
not implemented. The other backend codes should be unreachable for a program
that passed sema and the analyzer; seeing one indicates a compiler bug.
