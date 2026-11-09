# Kyn grammar

The authoritative grammar is [grammar.ebnf](grammar.ebnf). It describes the
syntax accepted by the v0.1 parser.

## Quick summary

```
program     := declaration*
declaration := fn | extern fn | export fn | struct | enum | global
fn          := "fn" IDENT "(" params? ")" type? block
struct      := "struct" IDENT "{" (field ("," field)* ","?)? "}"
enum        := "enum" IDENT (":" type)? "{" (variant ("," variant)* ","?)? "}"
global      := ("const"|"let"|"var") IDENT (":" type)? ("=" expr)? ";"
type        := "*" ["const"] type | "[" "]" ["const"] type | "[" expr "]" type | IDENT | primitive
statement   := block | if | while | return | break | continue | local | expr ";"
expression  := assignment, with precedence documented in the language reference
```

## Notes and accepted quirks

- Statements end with `;`; blocks use braces.
- Conditions are parenthesized: `if (cond)`, `while (cond)`.
- Trailing commas are accepted in struct declarations, enum declarations and
  struct initializers. They are not accepted in parameter lists, call
  arguments or array literals.
- `else if` is parsed as a nested `if` statement, not a special production.
- An omitted function return type means `void`.
- `extern fn` has no body and ends with `;`.
- `for` is a reserved keyword but has no production.
- Expressions have no comma operator and no ternary operator.
- Assignment is right-associative and is checked as an expression, so
  `a = b = c` parses; the checker still requires each target to be an lvalue
  and the types to be assignable.
- `as` binds tighter than binary arithmetic, e.g. `a * b as u64` is
  `a * (b as u64)`.
- Postfix operations (call, index `[expr]`, slice `[..]`, `[start..]`,
  `[..end]`, `[start..end]`, `.field`, `->field`) chain left to right.
- Struct initializers are recognized only as `IDENT { ... }` in expression
  position, so a block cannot start with a bare identifier followed by `{` in
  an expression statement without being parsed as an initializer.

## Relationship to diagnostics

Syntax errors use `E02xx` codes. The parser recovers at semicolons and at
declaration keywords; it does not stop at the first error. See
[diagnostics.md](diagnostics.md).

## Relationship to semantics

The grammar accepts some programs that the type checker rejects (for example
unknown identifiers or mismatched types), and it cannot express rules such as
definite return, lvalue mutability or aggregate-copy restrictions. Those rules
live in [language-reference.md](language-reference.md),
[type-system.md](type-system.md) and [safety-model.md](safety-model.md).
