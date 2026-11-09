
<div align="center">

# ⚡ Kyn

### **Explicit Control. Verifiable Safety. Predictable Performance.**

*A systems programming language for kernels, drivers, embedded systems, runtimes, and high-performance native software.*

[![License](https://img.shields.io/badge/license-MIT-3DA639?style=for-the-badge&logo=opensourceinitiative&logoColor=white)](LICENSE)
[![Status](https://img.shields.io/badge/status-alpha-critical?style=for-the-badge)](#-current-limitations)
[![Version](https://img.shields.io/badge/version-0.1.0--alpha.1-blue?style=for-the-badge)](#)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen?style=for-the-badge)](https://github.com/Hardion-Labs/Kyn/pulls)

---

> 🧪 **Status:** `v0.1.0-alpha.1` — *Early experimental. Actively developed.*  
> A working compiler pipeline and end-to-end tests exist.  
> Features listed under [Current Limitations](#-current-limitations) are **not implemented**.

</div>

---

## 📑 Table of Contents

- [Philosophy](#-philosophy)
- [Quick Start](#-quick-start)
- [A First Look](#-a-first-look)
- [Toolchain](#-toolchain)
- [Safety Profiles](#-safety-profiles)
- [Current Limitations](#-current-limitations)
- [Documentation](#-documentation)
- [Building & Testing](#-building--testing)
- [Repository Layout](#-repository-layout)
- [Roadmap](#-roadmap)
- [License](#-license)

---

## 🎯 Philosophy

Kyn favors **explicitness over inference**, **provable correctness over convenience**, and **predictable code generation over hidden runtime machinery**.

| Principle | What it means |
|:---|:---|
| 🎛️ **Explicit Control** | Allocation, pointers, mutability and conversions are written in the source. No hidden allocations or control flow. |
| 🛡️ **Verifiable Safety** | Compile-time checks for what can be proven. Runtime checks, when added, will **never** be silently removed. |
| ⚙️ **Predictable Performance** | No GC, no ownership inference, no implicit reference counting. Source carries predictable machine costs. |

---

## 🚀 Quick Start

### Requirements

| Tool | Version |
|:---|:---|
| **Zig** | `0.17.0` |
| **Clang** | Recent, with opaque-pointer LLVM IR support |
| **ar + POSIX shell** | Available on PATH |

### Install & Build

```bash
git clone https://github.com/Hardion-Labs/Kyn.git
cd Kyn
zig build
```

### Try It

```bash
# Run an example
./zig-out/bin/kync run examples/hello.kyn

# Type-check only
./zig-out/bin/kync check examples/hello.kyn

# Build a native binary (keeps generated artifacts outside the repo)
./zig-out/bin/kync build examples/hello.kyn -o /tmp/kyn-hello --profile safe
/tmp/kyn-hello
```

---

## 👀 A First Look

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

### Design choices visible here

- `let` is immutable; `var` is mutable.
- Pointers are always explicit: `*T` and `*const T`.
- Field access through pointers uses `->`; field access on values uses `.`.
- Conditions must be `bool`.
- Numeric conversions require `as`.
- Kyn and C can call each other through the C ABI; v0.1 supports the scalar call surface, not variadics or aggregate-by-value extern arguments.

---

## 🛠️ Toolchain

### `kync` — Compiler Driver

```bash
kync check <file.kyn>          # Parse + type-check
kync emit-llvm <file.kyn>      # Emit LLVM IR
kync build <file.kyn> -o out   # Build native executable
kync run <file.kyn>            # Build and execute
```

`kync` performs lexing, parsing, name resolution, type checking and static
analysis before emitting LLVM IR. Clang is used to assemble and link that IR;
Kyn semantics are implemented in this repository, not by Clang.

### `kyn-build` — Project System

Supports mixed Kyn + C + Zig projects with content-addressed incremental builds.

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

Example:

```bash
./zig-out/bin/kyn-build --file examples/hybrid/kyn.build
./examples/hybrid/build/hybrid/hybrid
```

---

## 🧬 Safety Profiles

| Profile | Native Optimization | Static Analyzer |
|:---:|:---:|:---:|
| 🔵 `debug` | `-O0 -g` | ✅ Always on |
| 🟢 `safe` | `-O2` | ✅ Always on |
| 🟡 `release` | `-O3` | ✅ Always on |
| 🟠 `fast` | `-O3` | ✅ Always on |

> ⚠️ Profiles currently affect native optimization only.  
> No check is removed silently: the static analyzer always runs.

---

## ⚠️ Current Limitations

Kyn v0.1 deliberately implements a small, verified core. The following are **available with limits**:

| Limitation | Status |
|:---|:---|
| ❌ Modules, imports or package system | Planned |
| ❌ Slices, generics or traits | Planned |
| ❌ `defer`, `for`, `switch`/`match`, closures or exceptions | Planned |
| ❌ Variadic extern functions | Planned / C wrapper required |
| ❌ Indirect calls and first-class function values | Planned |
| ❌ Runtime bounds / overflow / null checks | Planned; not implemented |
| ❌ Standard library and runtime | Planned |

Aggregate by-value support exists **inside Kyn only**:

- Struct and array parameters/returns inside Kyn: ✅
- Aggregate assignment and copies inside Kyn: ✅
- Aggregate parameters/returns across `extern`/`export` C ABI boundaries: ❌ (`E0410`); pass a pointer

Unsupported constructs are rejected with diagnostics, rather than silently compiled as undefined behavior.
See [Diagnostic codes](docs/diagnostics.md) for the stable codes.

---

## 📚 Documentation

| Document | Description |
|:---|:---|
| [🧠 Language Design](docs/language-design.md) | Philosophy and design decisions |
| [📖 Language Reference](docs/language-reference.md) | Syntax and semantics |
| [🧩 Grammar](docs/grammar.md) · [EBNF](docs/grammar.ebnf) | Grammar and precedence |
| [🔎 Type System](docs/type-system.md) | Types and assignment rules |
| [🧱 Memory Model](docs/memory-model.md) | Memory, pointers and layout |
| [🛡️ Safety Model](docs/safety-model.md) | Checks and undefined behavior |
| [🤝 C ABI](docs/abi.md) | Interop and calling conventions |
| [🏗️ Compiler Architecture](docs/compiler-architecture.md) | Frontend, IR and backend |
| [🛠️ Build System](docs/build-system.md) | `kyn-build` and incremental builds |
| [🔎 Diagnostics](docs/diagnostics.md) | Stable diagnostic codes |
| [🚦 Release Checklist](docs/release-checklist.md) | Release readiness gate |
| [🗺️ Roadmap](docs/roadmap.md) | Planned milestones |

---

## 🧪 Building & Testing

```bash
zig build                 # Build kync + kyn-build
zig build test            # Unit + regression tests
zig build integration     # End-to-end tests
zig fmt --check build.zig compiler build-system
```

The integration suite covers:

- Positive programs whose exit status and stdout are verified
- The four safety profiles
- Negative programs with required diagnostic codes
- Diagnostic documentation coverage against compiler sources
- Deterministic lexer/parser robustness corpus
- Version metadata consistency across build files and installed tools
- `emit-llvm` and `emit-obj` smoke tests
- A Kyn + C + Zig executable built by `kyn-build`
- Aggregate by-value behavior inside Kyn

Release readiness can be audited without creating a tag or release:

```sh
tools/release-check.sh 0.1.0-alpha.1 "$(git rev-parse HEAD)"
```

---

## 📁 Repository Layout

```text
compiler/            Lexer, parser, AST, sema, analyzer, IR, LLVM backend
build-system/        kyn-build implementation
tests/integration/   End-to-end positive, negative, robustness and interop tests
tools/               Release-readiness tooling
examples/            hello.kyn, pointers.kyn and a hybrid Kyn + C + Zig project
docs/                Language, safety, ABI, architecture and release docs
runtime/             Planned optional runtime support
std/                 Planned standard library
build.zig            Builds the toolchain and wires test steps
```

---

## 🗺️ Roadmap

| Milestone | Status |
|:---|:---|
| `v0.1.0-alpha.1` — Vertically functional compiler | ✅ In `main`, not released |
| `v0.1.0-alpha.2` — Frontend hardening | ✅ In `main`, not released |
| `v0.1.0-alpha.3` — Aggregates and ABI | 🚧 In progress |
| `v0.1.0-beta.1` — Runtime safety checks | 🔜 Planned |
| `v0.1.0-rc.1` — Interop and toolchain | 🔜 Planned |
| `v0.1.0` — First stabilized alpha-quality release | 🔜 Planned |

See [docs/roadmap.md](docs/roadmap.md) for the exact scope and ordering.

---

## 📄 License

MIT — see [LICENSE](LICENSE).

---

<div align="center">

**Hardion Labs**  
Engineered to the core.

[![GitHub](https://img.shields.io/badge/GitHub-Hardion--Labs-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/Hardion-Labs)
[![Repo](https://img.shields.io/badge/Repo-Kyn-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/Hardion-Labs/Kyn)

</div>
