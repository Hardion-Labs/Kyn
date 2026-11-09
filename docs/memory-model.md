# Kyn memory model (v0.1)

Kyn has manual memory management. The language does not insert allocation,
garbage collection, reference counting, ownership transfer or hidden copies.
Memory is obtained and released explicitly, and the programmer is responsible
for lifetime and aliasing discipline.

## 1. Storage classes

### 1.1 Locals

Every local variable and parameter is stored in a stack slot. The LLVM backend
emits an `alloca` for each local and lowers reads/writes to explicit `load` and
`store` instructions. There is no register-allocation requirement at the
source level; LLVM's optimizer may promote stack slots to registers when it can
prove that doing so preserves semantics.

A local declared without an initializer is **uninitialized**. Its stack slot
contains whatever the program left there. The static analyzer reports reads
that it can prove may happen before assignment (`E0501`), but this analysis is
conservative and not a complete definite-assignment checker. Programs must not
read uninitialized storage.

```kyn
fn main() i32 {
    var value: i32;   // uninitialized
    value = 10;       // definite assignment
    return value;
}
```

### 1.2 Globals

Globals have static storage duration and are emitted as LLVM globals with a
constant initializer. They are initialized before `main` by the platform's
loader; Kyn does not emit constructors. A global without an initializer is a
compile error (`E0413`).

`const` and `let` globals are immutable. `var` globals are mutable and may be
read and written from any code in the compilation unit.

### 1.3 String literals

A string literal is emitted as a private, null-terminated constant byte array
and has type `*const u8`. The storage is static, immutable and shared by
references to the same literal within a module. It is suitable for C APIs that
expect `const char *`:

```kyn
extern fn puts(s: *const u8) i32;

fn main() i32 {
    puts("static string data");
    return 0;
}
```

### 1.4 Heap memory

There is no Kyn allocation runtime in v0.1. Heap memory is obtained through
external functions, normally the C allocator. Declare the exact signatures you
need:

```kyn
extern fn malloc(size: usize) *u8;
extern fn free(ptr: *u8);

fn main() i32 {
    let buffer: *u8 = malloc(64);
    if (buffer == null) {
        return 1;
    }
    buffer[0] = 0;
    free(buffer);
    return 0;
}
```

The compiler does not track ownership, does not insert `free`, and does not
diagnose leaks, double frees or use-after-free. Those are programmer
responsibilities. A future optional runtime may provide allocator abstractions,
but it must not make allocation implicit.

## 2. Pointers

- `*T` points to a mutable `T`; `*const T` points to an immutable `T`.
- Pointers are raw addresses. They have no hidden metadata, no bounds, no
  lifetime tag and no nullability state at runtime.
- `null` is a separate type assignable to pointers; dereferencing `null` is
  undefined behavior and is not checked in v0.1.
- Pointer arithmetic (`p + n`, `p - n`) is scaled by `sizeof(T)`. It is only
  valid within the same allocated object or one past its end.
- `p - q` requires pointers to the same element type and computes element
  distance as `isize`.
- Pointers can be cast to and from integer types with `as`. Such casts do not
  establish provenance or alignment.

Aliasing is not restricted by the type system. The compiler passes
`-fno-strict-aliasing` to Clang so that the generated code does not assume
that pointers of different types never alias. This is a conservative
correctness choice for v0.1, not a promise about future optimization levels.

## 3. Aggregate layout

### 3.1 Structs

Fields are laid out in declaration order using the target ABI's natural
alignment. LLVM may insert padding between fields and at the end of the
struct. v0.1 has no `packed`, `align`, `repr` or explicit-offset syntax, so the
layout is whatever the target data layout specifies for the emitted LLVM
struct type.

Struct values are constructed directly in their destination:

- a local initializer writes each field through a GEP;
- a struct initializer assigned to an existing struct writes each field;
- passing a struct by value is rejected; pass `*Struct` instead.

### 3.2 Arrays

Arrays are contiguous sequences of `N` elements with no header and no length
stored at runtime. The length is a compile-time property of the type. Array
literals are written element by element into their destination.

Indexing a pointer or array computes `base + index * sizeof(element)`. Dynamic
indexes are not bounds-checked in v0.1; constant out-of-bounds indexes are
diagnosed (`E0502`).

### 3.3 Enums and characters

Enums use their declared integer backing type as their representation.
`char` is represented as an unsigned 32-bit integer. `bool` is represented as
`i1` in LLVM IR.

## 4. Initialization and destruction

- Locals with initializers are fully initialized before the declaration
  completes.
- Locals without initializers are not zeroed.
- Struct and array initializers must specify all fields/elements; there are no
  implicit zero values.
- There are no destructors, `defer`, RAII or automatic cleanup. Resources must
  be released explicitly on every path, including error paths.

## 5. Concurrency and atomics

v0.1 has no threads, atomics, memory-ordering annotations or `volatile`
syntax. Programs that call into platform threading APIs do so through
`extern` declarations and are responsible for synchronization. The compiler
does not reorder source-level loads and stores beyond what LLVM's optimizer is
allowed to do for the generated IR.

## 6. Undefined behavior

The following are not checked at runtime in v0.1 and must be avoided:

- reading uninitialized storage;
- dereferencing `null` or a dangling pointer;
- out-of-bounds array/pointer access with a dynamic index;
- signed integer overflow at runtime;
- division or remainder by zero at runtime;
- shifting by a runtime value outside `[0, bits)`;
- freeing memory twice or using it after `free`;
- data races in code that uses external threading;
- violating the alignment requirements of a pointer cast.

Compile-time-provable instances of several of these are diagnosed by the
static analyzer. The [safety model](safety-model.md) describes exactly what is
checked and what is planned.

## 7. Cost model

| Construct | Runtime cost in generated code |
| --------- | ------------------------------ |
| local read/write | `load`/`store` on a stack slot (optimizable) |
| field access | GEP plus load/store |
| array/pointer index | address arithmetic plus load/store |
| pointer arithmetic | integer add/sub scaled by element size |
| function call | native call; no hidden allocation |
| string literal | static read-only data, no runtime construction |
| struct/array literal | field/element stores into destination |
| `free`/`malloc` | cost of the external allocator, fully explicit |

There is no hidden heap allocation, no hidden copy of aggregates, no exception
unwinding table generated by Kyn, and no runtime type information.
