# Kyn language design

## Philosophy

> **Explicit Control. Verifiable Safety. Predictable Performance.**

These are constraints on design decisions, not slogans.

- **Explicit control.** Allocation, pointer arithmetic, mutability and numeric
  conversion are written in the source. The compiler does not invent hidden
  allocations, hidden copies, hidden synchronization or hidden control flow.
- **Verifiable safety.** Properties that can be decided at compile time are
  checked and reported with stable diagnostic codes. Checks that require
  runtime information are intended to be explicit, profile-controlled and
  observable — never silently removed.
- **Predictable performance.** Source constructs map to a small, explainable
  set of machine operations. The language has no garbage collector, no
  ownership inference and no implicit reference counting. Native optimization
  is delegated to LLVM, not to source-level trickery.

## Goals

1. Systems programming: kernels, drivers, firmware, runtimes, compilers,
   databases and performance-sensitive user space.
2. A small core that can be specified, tested and audited.
3. C ABI interoperability without a translation layer.
4. Hybrid Kyn + C + Zig projects through one build tool.
5. Diagnostics that name the problem, the location and a stable code.
6. A compiler that is itself understandable: explicit stages, explicit data
   structures, no generated parser or hidden metaprogramming.

## Non-goals for v0.1

- Garbage collection, tracing or reference counting inserted by the language.
- A borrow checker or ownership inference. Aliasing rules, where they exist,
  are documented and checked conservatively or left to `unsafe`-style future
  boundaries. v0.1 has no `unsafe` keyword because it has no safe/unsafe split
  yet; all manual memory operations are explicit.
- Source compatibility with C, C++, Rust, Zig or Go. Kyn learns from them but
  is not a dialect of any of them.
- Hiding machine costs behind implicit conversions, implicit copies or
  implicit allocation.
- Claiming features that are planned but absent.

## Why C-like syntax

Kyn uses braces, semicolons, `if (cond)`, `while (cond)` and `fn`. This is a
deliberate choice for a systems language:

- the mapping from source to familiar control-flow shapes is immediate;
- C and Zig programmers can read Kyn without learning a new indentation model;
- a context-free grammar with explicit terminators is simpler to parse and to
  recover from;
- diagnostics can point at a single token without whitespace sensitivity.

Kyn differs from C where C is ambiguous or unsafe by default:

- conditions must be `bool`; `if (1)` is an error;
- `let` is immutable and `var` is mutable, both lexically scoped;
- pointers encode constness in the type (`*const T`) and field access through
  a pointer uses `->`;
- there is no implicit integer narrowing or widening; use `as`;
- enums are distinct types with an explicit integer backing type;
- arrays carry their length in the type and array literals are checked
  element by element.

## Compilation model

```
source (.kyn)
   │
   ├─ source manager      file text, spans, line/column mapping
   ├─ lexer               tokens + lexical diagnostics
   ├─ parser              AST + syntax diagnostics and recovery
   ├─ name resolution     scopes, symbols, signatures
   ├─ type checker        types, lvalues, assignability, calls
   ├─ static analyzer     initialization, constant folding facts, reachability
   ├─ IR                  typed control-flow graph
   ├─ LLVM emitter        textual LLVM IR
   └─ clang               object file / executable / linker
```

The compiler does not link against LLVM's C++ API. It emits textual LLVM IR
and invokes `clang` as a tool. This keeps the compiler build small, makes the
generated IR inspectable, and lets the project evolve its own IR without being
coupled to LLVM internals. Kyn semantics remain defined by this repository.

## Language shape in v0.1

- Top-level declarations: functions, `extern` functions, `export` functions,
  structs, enums, globals (`const`, `let`, `var`).
- Statements: local declarations, expression statements, blocks, `if`/`else`,
  `while`, `return`, `break`, `continue`, empty statement.
- Expressions: literals, identifiers, unary and binary operators, assignment
  and compound assignment, calls, casts, field access, indexing, struct
  literals and fixed-size array literals.
- Types: `void`, `bool`, `char`, signed and unsigned integers (8–128 bits),
  `f32`, `f64`, `usize`, `isize`, pointers, fixed arrays, structs, enums and
  function types (used for direct calls; function values are not first-class
  in v0.1).

Compilation roots can explicitly import relative `.kyn` files. Import graphs
are loaded deterministically, and each source file owns its top-level symbol
table. Imports may use an explicit alias for qualified value/type references.
Unaliased imports open public declarations through the transitive closure of
unaliased edges; aliased edges are not re-exported unqualified. Local declarations
shadow opened names, and conflicting public names report `E0471` when used.
Same-named declarations in different modules are distinct. Top-level declarations
are public by default and `private` restricts cross-file access.

## Control and cost

- Locals live in stack slots (`alloca` in LLVM IR) and are loaded/stored
  explicitly. There is no hidden heap allocation.
- Aggregate values are initialized field by field into their destination.
  Whole-aggregate copies and by-value parameters/returns lower to native
  aggregate loads/stores and calls; LLVM's optimizer decides the actual
  machine representation.
- Aggregate copies have a real memory cost and are not hidden control flow or
  allocation, but they are not free.
- Short-circuit `&&` and `||` lower to real control flow, so side effects are
  skipped exactly as written.
- Integer operations lower to LLVM integer instructions with the signedness
  encoded in the instruction (`sdiv`/`udiv`, `ashr`/`lshr`, and signed or
  unsigned comparisons).
- String literals become private, null-terminated constant byte arrays with
  type `*const u8`. They are suitable for C APIs such as `puts`.
- Globals are emitted as LLVM globals with explicit linkage and constant
  initializers; a non-constant global initializer is a compile error.

## Evolution rules

1. New syntax must have a grammar production, a semantic rule and tests.
2. New diagnostics get a stable code and a negative test.
3. New optimizations must be semantics-preserving or profile-gated with an
   observable effect. No profile may silently remove a check.
4. Documentation distinguishes **implemented**, **planned** and **rejected**.
5. The compiler remains buildable with the pinned Zig version and a recent
   Clang; dependencies stay minimal.

## Related documents

- [Language reference](language-reference.md)
- [Grammar](grammar.ebnf)
- [Type system](type-system.md)
- [Memory model](memory-model.md)
- [Safety model](safety-model.md)
- [Compiler architecture](compiler-architecture.md)
