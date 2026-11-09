
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
- [Roadmap](#-roadmap)
- [License](#-license)

---

## 🎯 Philosophy

Kyn favors **explicitness over inference**, **provable correctness over convenience**, and **predictable code generation over hidden runtime machinery**.

| Principle | What it means |
|:---|:---|
| 🎛️ **Explicit Control** | Allocation, pointers, mutability and conversions are written in the source. No hidden allocations or control flow. |
| 🛡️ **Verifiable Safety** | Compile-time checks for what can be proven. Runtime checks (when added) will **never** be silently removed. |
| ⚙️ **Predictable Performance** | No GC, no ownership inference, no implicit reference counting. Source maps cleanly to machine operations. |

---

## 🚀 Quick Start

### Requirements

| Tool | Version |
|:---|:---|
| **Zig** | `0.17.0` |
| **Clang** | recent — with opaque pointer support |
| **ar + POSIX shell** | available on PATH |

### Install & Build

```bash
git clone https://github.com/Hardion-Labs/Kyn.git
cd Kyn
zig build
```

Try It

```bash
# Run an example
./zig-out/bin/kync run examples/hello.kyn

# Type-check only
./zig-out/bin/kync check examples/hello.kyn

# Build a native binary
./zig-out/bin/kync build examples/hello.kyn -o hello --profile safe
```

---

👀 A First Look

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

Design choices visible here

· 🔹 let is immutable, var is mutable
· 🔹 Pointers are always explicit — *T / *const T
· 🔹 Field access through pointers uses ->
· 🔹 Conditions must be bool
· 🔹 Numeric conversions require as
· 🔹 Full C ABI interoperability

---

🛠️ Toolchain

kync — Compiler Driver

```bash
kync check <file.kyn>          # Parse + type-check
kync emit-llvm <file.kyn>      # Emit LLVM IR
kync build <file.kyn> -o out   # Build native executable
kync run <file.kyn>            # Build and execute
```

kyn-build — Project System

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

---

🧬 Safety Profiles

Profile Optimization Static Analyzer
🔵 debug -O0 -g ✅ Always on
🟢 safe -O2 ✅ Always on
🟡 release -O3 ✅ Always on
🟠 fast -O3 ✅ Always on

⚠️ Note: Profiles currently only affect native optimization.
No check is ever silently removed.

---

⚠️ Current Limitations

Kyn v0.1 deliberately implements a small, verified core.
The following are not available yet:

<table>
<tr><td>

· ❌ Modules, imports or package system
· ❌ Slices, generics or traits
· ❌ defer, for, switch/match, closures
· ❌ Runtime bounds / overflow / null checks

</td><td>

· ❌ Standard library and runtime
· ❌ Aggregate by-value parameters and copies
· ❌ Function pointers

</td></tr>
</table>

🧭 Unsupported constructs are rejected with diagnostics, never compiled as undefined behavior.

---

📚 Documentation

Document Description
🧠 Language Design Philosophy and design decisions
📖 Language Reference Syntax and semantics
🧩 Type System Types and rules
🧱 Memory Model Memory and pointers
🛡️ Safety Model Checks and undefined behavior
🗺️ Roadmap Planned milestones

---

🧪 Building & Testing

```bash
zig build                 # Build kync + kyn-build
zig build test            # Unit + regression tests
zig build integration     # End-to-end tests
```

---

🗺️ Roadmap (High Level)

# Milestone Status
1 Runtime check layer (profile-controlled) 🔜
2 Modules + package system 🔜
3 Slices and aggregate ABI 🔜
4 Function pointers 🔜
5 defer + richer control flow 🔜
6 Initial standard library 🔜

---

📄 License

MIT — see LICENSE.

---

<div align="center">

Hardion Labs

Engineered to the core.

https://img.shields.io/badge/GitHub-Hardion--Labs-181717?style=flat-square&logo=github&logoColor=white
https://img.shields.io/badge/Repo-Kyn-181717?style=flat-square&logo=github&logoColor=white

</div>