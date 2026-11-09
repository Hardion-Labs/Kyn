# Kyn

**Explicit Control. Verifiable Safety. Predictable Performance.**

Kyn is a systems programming language and toolchain built by
[Hardion Labs](https://github.com/Hardion-Labs). It targets kernels, drivers,
embedded systems, runtimes and high-performance native software: static types,
manual memory management, explicit pointers and no hidden runtime machinery.

The compiler, the `kyn-build` project tool and the test suite are implemented
in Zig. C is used for ABI interoperability and for integrating existing native
code. LLVM is the initial native backend.

> **Status: v0.1.0-alpha.1, under active development.** This repository
> contains a working compiler pipeline and real end-to-end tests. Features
> listed under [Current limitations](#current-limitations) are not implemented
> yet and are not advertised as if they were.

## Quick start

Requirements:

- Zig 0.17.0
- Clang (tested with Clang 23; any recent Clang with opaque-pointer LLVM IR
  support should work)
- `ar` and a POSIX shell for library builds and integration tests

```sh
git clone https://github.com/Hardion-Labs/Kyn.git
cd Kyn
zig build

./zig-out/bin/kync run examples/hello.kyn
# Hello from Kyn!
```

Compile without running:

```sh
./zig-out/bin/kync build examples/hello.kyn -o /tmp/kyn-hello --profile safe
/tmp/kyn-hello
```

Check types and safety properties only:

```sh
./zig-out/bin/kync check examples/hello.kyn
# ok: examples/hello.kyn
```

## A first look

```kyn
extern fn puts(s: *const u8) i32;

struct Point {
    x: i32,
    y: i32,
}

fn sum(p: *Point) i32 {
    return p->x + p->y;
}

fn main() i32 {
    var p: Point = Point { x: 10, y: 20 };
    let q: *Point = &p;
    q->x += 5;
    puts("explicit, checked, native");
    return sum(q) - 30;
}
```

Design choices visible in this snippet:

- `let` is immutable, `var` is mutable; mutability is part of the type checker.
- Pointers are written `*T` and `*const T`, and are always explicit.
- Field access through a pointer uses `->`; value access uses `.`.
- Conditions must be `bool`; integers do not silently become booleans.
- Numeric conversions require `as`; there are no implicit narrowing conversions.
- Functions and `extern` declarations use the platform C ABI.

## Toolchain

### `kync`

```
kync <command> [options] <file.kyn>

Commands:
  check       Parse and type-check only
  emit-llvm   Emit textual LLVM IR
  emit-obj    Emit a native object file
  build       Build a native executable (default)
  run         Build and execute a native executable

Options:
  -o <path>          Output path
  --profile <name>   debug | safe | release | fast (default: safe)
  --cc <path>        C compiler used for assembly/linking (default: clang)
  --keep-ir          Keep the generated .ll file
  --                 Pass the remaining arguments to the program (run)
```

`kync` performs lexing, parsing, name resolution, type checking and static
analysis before emitting LLVM IR. `clang` is used only to turn that IR into an
object file or executable; Kyn semantics are implemented in this repository.

### `kyn-build`

`kyn-build` orchestrates projects that mix Kyn, C and Zig:

```kyn
project "hybrid"

target "hybrid" {
    kind: "exe"
    sources: ["src/main.kyn"]
    c_sources: ["src/math.c"]
    zig_sources: ["zig/math.zig"]
    profile: "safe"
}
```

```sh
./zig-out/bin/kyn-build --file examples/hybrid/kyn.build
./examples/hybrid/build/hybrid/hybrid
```

Supported keys: `kind` (`exe`, `staticlib`, `sharedlib`), `sources`,
`c_sources`, `zig_sources`, `include_dirs`, `libs`, `lib_dirs`, `cflags`,
`profile`, `output`. Rebuilds are content-addressed: a target is skipped only
when the hash of its configuration and every input matches the stored stamp.

## Safety profiles

| Profile   | Native optimization | Compile-time analyzer |
| --------- | ------------------- | --------------------- |
| `debug`   | `-O0 -g`            | always enabled        |
| `safe`    | `-O2`               | always enabled        |
| `release` | `-O3`               | always enabled        |
| `fast`    | `-O3`               | always enabled        |

Profiles currently select native optimization only. **They do not disable or
silently remove any check**, because runtime checks are not generated yet. The
static analyzer always runs: uninitialized reads, provable division by zero,
constant overflow, out-of-range shifts, constant out-of-bounds indexes and
unreachable code are diagnosed regardless of profile. A future runtime-check
layer must follow the same rule: profiles may change cost, never silently
remove a check.

## Building and testing

```sh
zig build                 # build kync and kyn-build into zig-out/bin
zig build test            # unit and regression tests for every compiler stage
zig build integration     # compile, link and execute real programs
zig fmt --check build.zig compiler build-system
```

The integration suite covers:

- positive programs whose exit status and stdout are verified;
- the four safety profiles;
- negative programs that must fail with a specific diagnostic code;
- diagnostic documentation coverage against compiler sources;
- deterministic lexer/parser robustness corpus;
- version metadata consistency across `build.zig.zon`, compiler sources and
  installed tools.
- `emit-llvm` and `emit-obj` smoke tests;
- a Kyn + C + Zig executable built by `kyn-build`, plus incremental rebuild.

## Repository layout

```
compiler/            Lexer, parser, AST, sema, analyzer, IR, LLVM backend, driver
build-system/        kyn-build implementation
tests/integration/   End-to-end positive, negative and interop tests
examples/            hello.kyn and a hybrid Kyn + C + Zig project
docs/                Language, type system, memory, safety, ABI and compiler docs
runtime/             Planned optional runtime support
std/                 Planned standard library
build.zig            Builds the toolchain and wires the test steps
```

## Documentation

- [Language design](docs/language-design.md)
- [Language reference](docs/language-reference.md)
- [Grammar](docs/grammar.md) ([EBNF](docs/grammar.ebnf))
- [Type system](docs/type-system.md)
- [Memory model](docs/memory-model.md)
- [Safety model](docs/safety-model.md)
- [C ABI and interoperability](docs/abi.md)
- [Compiler architecture](docs/compiler-architecture.md)
- [Build system](docs/build-system.md)
- [Diagnostic codes](docs/diagnostics.md)
- [Roadmap](docs/roadmap.md)

## Current limitations

Kyn v0.1 deliberately implements a small, verified core. It does not yet
support:

- modules, imports or a package system;
- slices, generics or traits;
- variadic extern functions and variadic Kyn functions;
- aggregate parameters/returns across `extern`/`export` C ABI boundaries
  (internal Kyn functions may use aggregates by value);
- indirect calls through function pointers;
- `defer`, `for`, `switch`/`match`, closures or exceptions;
- runtime bounds, overflow and null checks;
- an optimizer in the Kyn compiler itself (LLVM performs native optimization);
- a standard library or runtime.

Unsupported constructs are rejected with diagnostics rather than compiled with
undefined behavior. See [docs/diagnostics.md](docs/diagnostics.md) for the
stable codes.

## Roadmap

1. Runtime check layer driven by explicit safety profiles.
2. Modules, visibility and a package/build manifest.
3. Slices and aggregate ABI lowering.
4. Function pointers and indirect calls.
5. `defer`, richer control flow and compile-time evaluation.
6. Initial `std` and optional `runtime`.

## License

MIT. See [LICENSE](LICENSE).
