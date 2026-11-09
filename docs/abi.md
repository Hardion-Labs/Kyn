# C ABI and interoperability (v0.1)

Kyn is designed to interoperate with C at the ABI level. There is no runtime
bridge, marshalling layer or name mangling: Kyn declarations map to native
symbols and platform calling conventions.

## 1. Declaring external functions

```kyn
extern fn puts(s: *const u8) i32;
extern fn c_add(a: i32, b: i32) i32;
extern fn malloc(size: usize) *u8;
extern fn free(ptr: *u8);
```

- `extern fn` has no body and ends with `;`.
- The Kyn name is used verbatim as the linker symbol. There is no mangling.
- Parameters and return types must have a C-compatible representation.
- Calls use the default C calling convention.
- Aggregate parameters and returns, including slices, are supported on
  `x86_64` Linux when their layout is classifiable by the current lowering.
  Aggregates up to 16 bytes whose occupied System V eightbytes merge to the
  `INTEGER` class use one or two 64-bit integer registers, with safe zero-padded
  packing for partial eightbytes. This includes a float field when an integer
  field in the same eightbyte causes the merged class to be `INTEGER`. A struct
  containing one direct `f32`/`f64` field uses scalar SSE; exactly two
  adjacent direct `f32` fields use one `<2 x float>` SSE/SSEUP value; and
  exactly two direct `f64` fields use two SSE registers (LLVM arguments are
  two `double`s and return coercion is `{ double, double }`). A direct
  `{ f64, i32 }` or `{ f64, u32 }` struct with natural fields at offsets 0 and
  8 uses one `double` and one LLVM `i32` argument and returns as
  `{ double, i32 }`. Larger supported
  structs use hidden `byval`/`sret` pointers. Fixed arrays and other
  unsupported small SSE layouts remain rejected at C boundaries (`E0473`).
  Slice boundaries match a C struct
  `{ T *ptr; size_t len; }`.
- Only the x86_64 System V calling convention is supported in v0.1.
- Variadic declarations are not supported yet. Declare a fixed prototype that
  matches the arguments you actually pass, or write a C wrapper.

## 2. Exporting Kyn functions

```kyn
export fn kyn_add(a: i32, b: i32) i32 {
    return a + b;
}
```

`export fn` emits the function with external linkage under its Kyn name. It can
be called from C, Zig or another Kyn compilation unit:

```c
extern int kyn_add(int a, int b);

int main(void) {
    return kyn_add(2, 3) == 5 ? 0 : 1;
}
```

`fn main` is also emitted with external linkage so the platform entry point is
available. Other `fn` declarations use internal linkage.

## 3. Type mapping

| Kyn type | C type (typical LP64) | LLVM IR |
| -------- | --------------------- | ------- |
| `void` | `void` | `void` |
| `bool` | `_Bool` | `i1` |
| `char` | `uint32_t` (Unicode scalar) | `i32` |
| `i8`/`u8` | `int8_t`/`uint8_t` | `i8` |
| `i16`/`u16` | `int16_t`/`uint16_t` | `i16` |
| `i32`/`u32` | `int32_t`/`uint32_t` | `i32` |
| `i64`/`u64` | `int64_t`/`uint64_t` | `i64` |
| `i128`/`u128` | `__int128`/`unsigned __int128` | `i128` |
| `f32` | `float` | `float` |
| `f64` | `double` | `double` |
| `usize`/`isize` | `size_t`/`ssize_t` (currently 64-bit) | `i64` |
| `*T`, `*const T` | `T *`, `const T *` | `ptr` |
| `[N]T` | `T[N]` (layout only) | `[N x T]` |
| `struct S` | `struct S` (by value when its ABI classes are supported) | `%struct.S` |
| `[]T`, `[]const T` | `struct { T *ptr; size_t len; }` | `%kyn.slice` (`{ ptr, i64 }`) |
| `enum E: U` | integer backing type `U` | backing integer |

Caveats:

- `char` is a 32-bit Unicode scalar in Kyn, not C `char`. For byte strings use
  `u8`/`*const u8`.
- `bool` lowers to `i1`. Some C ABIs expect `_Bool` arguments to carry
  zero-extension attributes; v0.1 does not emit such attributes. Prefer
  `u8`/`i32` in `extern` signatures when interoperating with code that is
  sensitive to this.
- `usize`/`isize` are currently fixed at 64 bits; see the type-system document.
- Plain C-layout structs up to 16 bytes are passed by value when their classes
  are supported. INTEGER-class eightbytes include float+integer fields in the
  same eightbyte; a one-field `f32`/`f64` struct uses scalar SSE, a two-field
  direct `f32` struct uses `<2 x float>` for SSE/SSEUP, and a two-field direct
  `f64` struct uses two SSE registers, and a direct `{ f64, i32 }` or
  `{ f64, u32 }` struct with the integer at offset 8 uses an SSE `double` plus
  INTEGER `i32` register.
  Larger supported aggregates use the hidden-pointer `byval`/`sret` form. Fixed
  arrays and other unsupported SSE/INTEGER layouts remain unsupported; pass a
  pointer instead.
- Slices are passed by value as pointer+length, matching a C
  `struct { ptr base; size_t len; }` layout.
- Enums are passed as their backing integer, but a C enum's width is
  implementation-defined. Declare the same backing width explicitly on both
  sides.

## 4. Strings and buffers

String literals are private null-terminated byte arrays of type `*const u8`:

```kyn
extern fn puts(s: *const u8) i32;

fn main() i32 {
    puts("Hello from Kyn!");
    return 0;
}
```

They are suitable for C functions that read `const char *` and do not retain
the pointer beyond the call unless the storage outlives the process (string
literals have static duration). Mutable buffers must be allocated explicitly
(stack arrays or `malloc`).

## 5. Linking model

The compiler emits textual LLVM IR and invokes an external toolchain:

```sh
kync emit-llvm file.kyn -o file.ll
kync emit-obj  file.kyn -o file.o --profile safe --cc clang
kync build     file.kyn -o program --profile safe --cc clang
```

`clang` assembles the IR and links the result. Kyn itself does not implement a
linker or an object format.

When combining Kyn with C, link all objects together:

```sh
kync emit-obj main.kyn -o main.o
clang -c helper.c -o helper.o
clang main.o helper.o -o program
```

When combining with Zig objects, link with `zig cc` instead of `clang`. Zig
runtime objects may reference compiler-rt support symbols such as
`__zig_probe_stack` that are provided by Zig's linker driver. `kyn-build`
selects `zig cc` automatically when a target contains Zig sources.

## 6. Hybrid project example

`examples/hybrid` contains:

```
kyn.build
src/main.kyn     extern c_add, extern zig_mul, main returns c_add(2,3)+zig_mul(4,5)
src/math.c       int c_add(int a, int b)
zig/math.zig     export fn zig_mul(a: i32, b: i32) i32
```

```sh
./zig-out/bin/kyn-build --file examples/hybrid/kyn.build
./examples/hybrid/build/hybrid/hybrid
# exit status 25
```

The Kyn side uses the same function signatures as the C and Zig definitions.
There are no generated headers or bridge functions.

## 7. Symbols and visibility

- `extern fn` emits an LLVM `declare`.
- `export fn` and `fn main` emit definitions with external linkage.
- Other `fn` definitions use internal linkage and are not visible to the
  linker.
- Globals are emitted with their Kyn name and module-level visibility. They are
  not marked `static`, so the linker may resolve them across objects unless a
  future visibility syntax says otherwise.
- There is no C++ name mangling, `extern "C"` block or symbol alias syntax.

You can inspect the result with standard tools:

```sh
kync emit-obj hello.kyn -o hello.o --keep-ir
nm hello.o
clang hello.o -o hello
```

## 8. Not supported in v0.1

- variadic extern functions;
- fixed-size array parameters and returns by value, and aggregate layouts not
  supported by the selected target/classifier (including small `SSE`-only
  eightbytes) (`E0473`);
- unions, bitfields, packed structs and explicit alignment;
- calling conventions other than `x86_64` Linux System V;
- function pointers and callbacks;
- exported globals with controlled visibility;
- linking against Kyn-specific runtime support (there is none yet).

These restrictions are diagnosed where the type checker can see them, rather
than producing a silently incompatible ABI.
