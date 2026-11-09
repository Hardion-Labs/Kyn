# `kyn-build` (v0.1)

`kyn-build` is the project tool for Kyn, C and Zig. It is implemented in
`build-system/main.zig` and installed next to `kync` as `zig-out/bin/kyn-build`.

Its job is deliberately narrow: parse a declarative build file, compile every
source in a target, link the target and skip work that is already up to date.

## 1. Invocation

```sh
kyn-build [options]

Options:
  --file <path>      Build file (default: kyn.build)
  --target <name>    Build only one target
  --profile <name>   debug | safe | release | fast
  --kync <path>      Kyn compiler to use
  --cc <path>        C compiler (default: clang)
  --zig <path>       Zig compiler (default: zig)
  --clean            Remove the build directory first
  --force            Rebuild even when the stamp matches
  --verbose          Print each tool invocation
  -h, --help         Show help
  --version          Show version
```

Examples:

```sh
kyn-build
kyn-build --file examples/hybrid/kyn.build --profile release
kyn-build --target hybrid --force --verbose
```

Paths in the build file are resolved relative to the directory containing the
build file. Tool invocations run with the project directory as their working
directory.

If `--kync` is omitted, `kyn-build` looks for a `kync` executable next to
itself (the normal `zig-out/bin` layout) and otherwise falls back to `kync` on
`PATH`.

## 2. Build file format

The format is line-oriented and intentionally small:

```kyn
project "hybrid"

target "hybrid" {
    kind: "exe"
    sources: ["src/main.kyn"]
    c_sources: ["src/math.c"]
    zig_sources: ["zig/math.zig"]
    include_dirs: ["include"]
    libs: ["m"]
    lib_dirs: ["vendor/lib"]
    cflags: ["-DKYN_BUILD=1"]
    profile: "safe"
    output: "bin/hybrid"
}
```

Rules:

- `project "name"` sets the project name (default `kyn-project`).
- `target "name" { ... }` opens a target block. Blocks do not nest.
- `key: value` sets a target property.
- Lines are trimmed; `//` starts a comment outside quoted strings.
- Strings are double-quoted. Arrays are comma-separated lists of quoted
  strings in `[...]`. Trailing commas inside arrays are accepted.
- Unknown keys, unknown target kinds and malformed values are errors.
- At least one target is required.
- There are no variables, conditionals, loops, includes or expressions in the
  build language.

### 2.1 Keys

| Key | Type | Meaning |
| --- | ---- | ------- |
| `kind` | `"exe"`, `"staticlib"`, `"sharedlib"` | target kind (default `exe`) |
| `sources` | array | Kyn source files (`.kyn`) |
| `c_sources` | array | C source files |
| `zig_sources` | array | Zig source files |
| `include_dirs` | array | C include directories (`-I`) |
| `libs` | array | libraries to link (`-l`) |
| `lib_dirs` | array | library search directories (`-L`) |
| `cflags` | array | extra flags passed to the C compiler |
| `profile` | string | default profile for this target |
| `output` | string | explicit output path |

`--profile` overrides a target's `profile`. `--target` selects one target by
name; other targets are skipped. If no target matches, the build fails.

### 2.2 Output paths

Without `output`:

| Kind | Default path |
| ---- | ------------ |
| `exe` | `build/<target>/<target>` |
| `staticlib` | `build/<target>/lib<target>.a` |
| `sharedlib` | `build/<target>/lib<target>.so` |

With `output`, the path is resolved relative to the project directory.
Intermediate objects are written to `build/<target>/`.

## 3. Build process

For each selected target:

1. Compute a SHA-256 digest over:
   - target name and kind;
   - profile;
   - each Kyn/C/Zig source path and its full content;
   - each transitive `.kyn` import path and full content;
   - `cflags`, `include_dirs`, `libs`, `lib_dirs`;
   - the `kync`, `cc` and `zig` executable paths.
2. Compare the digest with `build/<target>/.kyn-stamp`. If it matches and the
   output exists, print `up to date` and skip the target. `--force` disables
   this.
3. Compile Kyn sources with `kync emit-obj` into `build/<target>/kyn-<n>.o`.
4. Compile C sources with `<cc> -c ... -fPIC -fno-strict-aliasing` plus the
   profile flags and `-I` entries, into `build/<target>/c-<n>.o`.
5. Compile Zig sources with `<zig> build-obj <source> -O <mode> -fPIC` into
   `build/<target>/zig-<n>.o`.
6. Link:
   - `exe`/`sharedlib`: `<cc>` or `zig cc` with all objects, `-L`, `-l` and
     `-o`; `-shared` for shared libraries.
   - `staticlib`: `ar rcs <output> <objects>`.
7. Write the digest to the stamp file.

If any step fails, the target fails and `kyn-build` exits non-zero. The stamp
is written only after a successful build.

### 3.1 Why `zig cc` for Zig objects

Zig-generated objects may reference compiler/runtime support symbols such as
`__zig_probe_stack`. Linking them with Zig's own driver (`zig cc`) supplies the
required support. Targets without Zig sources link with the configured C
compiler.

### 3.2 Profiles

| Profile | C flags | Zig mode |
| ------- | ------- | -------- |
| `debug` | `-O0 -g` | `Debug` |
| `safe` | `-O2` | `ReleaseSafe` |
| `release` | `-O3` | `ReleaseFast` |
| `fast` | `-O3` | `ReleaseFast` |

The Kyn compiler receives the same profile name. It selects native
optimization flags and an explicit runtime-check policy; all currently
implemented runtime checks remain enabled in every profile. The static analyzer
always runs.

## 4. Incremental behavior

The cache is content-based, not timestamp-based:

- editing a listed source or any transitively imported `.kyn` source changes the digest and rebuilds the target;
- changing a flag, include directory, library or tool path changes the digest;
- running twice with no changes prints `up to date` for each target;
- `--force` rebuilds regardless;
- `--clean` deletes the entire `build/` directory before the build.

Limitations of the current cache:

- C headers included by `c_sources` are **not** hashed. Editing a header does
  not trigger a rebuild; use `--force` or touch/change a listed source.
- The Kyn compiler's own version is not part of the digest, only its path.
- Zig's transitive imports are not hashed; only listed `zig_sources`.
- Builds are sequential; there is no parallel job scheduling.
- There is no dependency graph between multiple targets; every target is built
  independently.

These are known limitations, not hidden behavior. They are candidates for the
next build-system iteration.

## 5. Hybrid example

`examples/hybrid/kyn.build`:

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

Kyn:

```kyn
extern fn c_add(a: i32, b: i32) i32;
extern fn zig_mul(a: i32, b: i32) i32;

fn main() i32 {
    return c_add(2, 3) + zig_mul(4, 5);
}
```

C:

```c
int c_add(int a, int b) {
    return a + b;
}
```

Zig:

```zig
export fn zig_mul(a: i32, b: i32) i32 {
    return a * b;
}
```

Build and run:

```sh
./zig-out/bin/kyn-build --file examples/hybrid/kyn.build
./examples/hybrid/build/hybrid/hybrid
# exit status 25
```

## 6. Relationship to `zig build`

`zig build` builds the Kyn toolchain itself (`kync` and `kyn-build`) and runs
compiler unit tests. `kyn-build` builds **Kyn projects**. They are different
tools with different inputs:

```sh
zig build              # build the toolchain
zig build test         # compiler unit/regression tests
zig build integration  # end-to-end and interop tests
kyn-build              # build a Kyn/C/Zig project described by kyn.build
```

## 7. Not supported in v0.1

- variables, expressions, conditionals or templating in `kyn.build`;
- multiple build files, includes or target inheritance;
- cross-compilation flags beyond passing a custom `--cc`/`--zig`;
- parallel builds and partial-target dependency graphs;
- header dependency scanning;
- install rules, packaging, test targets or run targets;
- custom linker scripts or response files;
- reproducible-toolchain pinning in the manifest.
