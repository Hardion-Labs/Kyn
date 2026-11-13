# Design: unions, bitfields and packed structs

Status: **implemented (§55, §56 and §57).** Unions, packed structs, bitfields and
explicit `align(N)` are all implemented end to end, with ABI fixtures for each.
§7 was corrected against measurement during the alignment increment, §4.1 during
the bitfield one; §10 records what landed.

This document decides the three aggregate extensions `abi.md` §9 lists as
unsupported, in the order they should be built.
Each one lands in the same four places — parser, type model, layout/classifier,
backend — so deciding them together is cheaper than three designs that discover
the same constraints.

Every layout and ABI statement below was **measured** with the project's own
toolchain before being written down; §9 lists the commands and the numbers. None
of it is inferred from memory of the C standard.

## 1. Why these three, and why now

Everything mechanical on the roadmap is done: the documented tables are swept
(§48–§50), variadics work in both directions (§52), the pointer/function-value
cast gap is closed (§44), and the integer minimum no longer breaks the compiler
(§53). What is left is this bundle, and it has been postponed three times
(§44, §46, §50) for one reason: it is the first change that touches the
**layout** of a value rather than only its transport.

Three forces make it a single decision:

1. **All three are "a struct whose fields are not all separate".** A union
   overlaps them; a bitfield splits one storage unit between several members; a
   packed struct removes the padding between them. Every consumer that assumes
   "field *i* is its own `Field` at the natural offset" — the layout guess, the
   leaf walk, the LLVM type name, the initializer checker, the `byval`/`sret`
   alignment — is affected by all three in the same way.
2. **The ABI part is small and the language part is large.** Measured (§9):
   clang classifies a union exactly as the struct formed by its members, and a
   packed struct exactly as if its members were laid out without padding. So the
   *classifier* needs no new rules, only the right **layout numbers**; it is the
   parser, the type model and the initializer rules that need design.
3. **They are the last thing that makes Kyn's `struct`-only type system visibly
   thinner than C's** at a boundary the project already claims to support
   (`abi.md` §9 is the only list that still says "no").

## 2. What exists today, and what each one collides with

Read from the code, not assumed:

| Place | File | What it assumes |
| --- | --- | --- |
| Field list | `types.StructInfo.fields` | an ordered list of `(name, ty)`; every field is separate storage |
| Layout | `sema.aggregateLayoutGuess` | natural alignment, `alignForward` per field, size rounded to `align_` |
| Leaf walk | `sema.collectAggregateLeaves` | visits every field at its natural offset, flattening nested structs and arrays |
| LLVM type | `backend/llvm.zig` `structLlvmName` / `emitType` | `%struct.<name> = type { <fields> }`, non-packed |
| `sret`/`byval` | `backend/llvm.zig` `emitParameters` | alignment from `llvmAlignmentOfType`, which walks fields |
| Initializer | `sema.checkStructInit` | exactly one value per field, order-free |
| Recursion check | `sema` `E0403` | "cannot contain itself by value" walks field types |

Each of the three features perturbs a different subset: unions break "every
field is storage", bitfields break "every field is a whole `Field`", packed
breaks "offset == alignForward(size)". None breaks the leaf walk's *interface* —
it already takes an explicit `base_offset` — which is why the transport does not
need new classes.

## 3. Unions

### 3.1 Surface

```kyn
union Value {
    integer: i64,
    real: f64,
    bytes: [8]u8,
}

fn main() i32 {
    var v: Value = Value { real: 1.5 };
    v.integer = 7;            // legal: a union is not a tagged union
    return v.integer as i32;
}
```

- The keyword is `union`; the body syntax is the struct's (fields, trailing
  comma, `E0404` on a duplicate name).
- **No tag is added.** A tag would make this a sum type, which is a different
  feature that the project has deliberately not scheduled (§8). A union is the C
  type: the program decides which member is live, exactly as `va_arg()` trusts
  the program to know its argument list.
- An initializer names **exactly one** member (`Value { real: 1.5 }`), because
  naming more than one would claim two live members. An empty initializer with
  no member is rejected rather than leaving the value uninitialized: Kyn's
  initialization rules do not have an "uninitialized but fine" state.
- Reading a member that is not the live one is **undefined behaviour**, stated
  in `safety-model.md` §3 and not checked. This is the one place where Kyn
  knowingly lets a value be reinterpreted, and it is the same trust boundary
  `abi.md` already draws for `extern` calls.

### 3.2 Layout and alignment

Size = the maximum member size, alignment = the maximum member alignment, and
every member is at offset 0. Measured: `union { char; int; double }` is
`size=8, align=8` on this target. This is exactly the struct rule with "sum of
sizes" replaced by "maximum size", so `aggregateLayoutGuess` gains one branch on
a `StructInfo.is_union` flag rather than a parallel code path.

### 3.3 ABI

Measured, and the reason this feature is small:

```
union U { char c; int i; double d; };   // size 8, align 8
union U pass_u(int, union U);           // → define i64 @pass_u(i32, i64)
double   take_u(union U);               // → define double @take_u(i64)
union U  give_u(double);                // → define i64 @give_u(double)
union Small { char c; };                // size 1
union Small take_small(union Small);    // → define i8 @take_small(i8)
union F { float x; int i; };            // size 4
double take_f(union F);                 // → define double @take_f(i32)
union Big { double d[3]; };             // size 24 > 16
union Big take_big(union Big);          // → sret + byval, align 8
```

So: **clang classifies a union exactly as the struct with the same members.**
The existing leaf walk already produces the right answer if it visits all
members at offset 0, because an eightbyte's class is the merge of the classes of
everything in it, and merging more members into the same eightbyte can only keep
an `INTEGER` where the widest member had one. `.small_1`/`.small_2` for the
"non-struct aggregate" branch stays as it is; a union is a struct with a flag.

The backend names it `%struct.<name>` like any aggregate: LLVM has no union type
and a named struct whose layout the compiler computed is the right
representation. `byval`/`sret` keep their alignment from the same
`llvmAlignmentOfType`, which must read the union's alignment and not the first
field's.

### 3.4 What it does not give

- no tag, no `match`, no checked member access;
- no union inside a union member access chain beyond the ordinary `.`/`->`;
- no union constructor from a byte buffer — `Value { bytes: b }` where `b` is
  `[8]u8` works, but there is no `transmute`.

## 4. Bitfields

### 4.1 Surface

```kyn
struct Flags {
    a: u3,
    b: u5,
    mode: u4,
}

struct Wire {
    kind: u3,
    tag: u5,
}
```

Decision: the width lives **in the type**, as the integer types `u1`..`u128` and
`i1`..`i128`, and a struct packs adjacent bit-width fields automatically. There
is no `a: u32: 3` syntax.

Why this way and not the C colon syntax:

1. `IntInfo` **already carries `bits: u16`** and already accepts widths that are
   not a byte multiple (`E0426` is a range check, and `memberBoundaryBits` maps a
   sub-32-bit member to its transport width). The compiler's type model needs no
   new field; the C syntax would need one.
2. A colon syntax attaches storage to a *declaration*, which then has to answer
   "what is the type of `x.a`?" — C says `int`, and the width is invisible to the
   type system, so `x.a + 1` promotes and the width is lost. With `u3`, the width
   is the type and the existing promotion rules apply unchanged.
3. It removes a keyword and a grammar production instead of adding one, which is
   the cheaper change in both places it touches.

Packing rules, stated in the form that will be implemented and then **checked
against clang** rather than assumed. The layout keeps a *bit cursor*
`(offset, bits_used, unit_width)` where `unit_width` is one of 8/16/32/64:

1. A bitfield that names no storage type takes a unit width of 8/16/32/64 — the
   smallest of those that can hold its width. A bitfield whose field type is
   itself a fixed-width integer (`u8`, `u16`, …) takes that type's width. This is
   the one place the declared type changes the *layout* rather than only the
   access, and it is what separates C's `unsigned a:3` (a 4-byte unit) from its
   `unsigned char a:3` (a 1-byte unit).
2. **A bitfield never straddles a boundary of its own unit size.** It is placed at
   `bits_used` if it fits before the next such boundary, otherwise the cursor
   jumps forward to that boundary. Note what this does *not* say: the field is not
   pushed into a new unit of its own width. Measured: `{u3, u5, u12}` places `c`
   at **bit 16**, not at bit 8, because 12 bits starting at 8 would straddle bit
   16. So the run's layout is `(0, 8)`, `(3, 8)`, `(16, 16)` — the unit widths
   differ within one run and the aggregate's alignment is the largest of them.
3. A non-bitfield member **closes the cursor** to the end of the storage its unit
   occupies. A later bitfield then resumes inside that same unit when bits remain
   (measured: `{a:3, char c, b:5}` puts `b` at bit 16 and the aggregate is 4
   bytes, not the 3 a fresh unit would give) and otherwise starts a new one.
4. An `iN` bitfield is signed and sign-extends on read; a `uN` zero-extends.
   Widths are the declared ones, so a run may mix them.

The measured answers that fix these rules:

| C declaration | size, align | what it pins |
| --- | --- | --- |
| `struct Wire { unsigned k:3; unsigned t:5; }` | 4, 4 | two fields share one 4-byte unit |
| `struct B1c { unsigned char k:3; unsigned char t:5; }` | 1, 1 | the same with a 1-byte unit: 8 bits fit in one byte |
| `struct A { unsigned a:20; unsigned b:20; }` | 8, 4 | 20+20 straddles bit 32, so `b` moves to bit 32 |
| `struct B { unsigned char a:4; unsigned char b:6; }` | 2, 1 | 10 bits straddle bit 8, so `b` moves to bit 8 |
| `struct D { unsigned a:31; unsigned b:2; }` | 8, 4 | 33 bits straddle bit 32 |
| `struct K { unsigned char a:3; char c; unsigned short b:12; }` | 4, 2 | a run that grows after a non-bitfield member resumes at bit 16, and the alignment is the largest unit in the run (2), not the last field's |
| `struct MixChar { unsigned char a:3; char c; unsigned char b:5; }` | 3, 1 | a non-bitfield member does not open a fresh block: `b` resumes in the same 1-byte unit after `c` |
| `struct Mix { unsigned a:3; char c; unsigned b:5; }` | 4, 4 | the same shape in a 4-byte unit: `b` resumes there too, and the 4-byte unit is what raises the alignment |
| `struct C { unsigned a:3; double d; unsigned b:5; }` | 24, 8, `d` at 8 | a `double` forces alignment 8 and leaves 3 bytes that the cursor does not reuse |

**Correction to an earlier version of this document.** It claimed the unit width
of a field is "the smallest of `u8`/`u16`/`u32`/`u64` that can hold its declared
width" and cited `Mix` = 4 as confirming it. Two things were wrong. First, `Mix`
is 4 bytes because its declared type is `unsigned`, a 4-byte unit — with
`unsigned char` members the same shape is 3 bytes, measured. Second, the rule
implied a run grows by taking a wider *common* unit, which would put `c` at bit 8
in `{u3, u5, u12}`; the measured position is bit 16, because a field never
straddles the boundary of its own width. Rule 2 above is the measured one.

Reading a bitfield yields the field's own type, sign-extended when `iN` and
zero-extended when `uN`; writing it masks to the width and leaves the other bits
of the storage unit untouched. Both are existing `cast` + `binary` lowering, so
the backend gains no instruction.

### 4.2 The honest definition problem

C only defines bitfield layout for `int`-family members of implementation-defined
width; it does not define it across compilers for the general case. This design
therefore does **not** claim C compatibility for arbitrary bitfield structs.
It claims:

- **a documented, deterministic layout**, identical on every target (a pure
  function of the declared widths);
- **a C-compatible subset**, measured and stated: adjacent members whose widths
  sum to at most 32 bits, all unsigned or all signed, in declaration order, and
  **summing to at most 8 bits to be C compatible as a whole**. The 8-bit ceiling
  is not arbitrary — it is the correction of this document's earlier claim.
  `struct Sub { unsigned a:3; unsigned b:5; unsigned c:12; }` is `{ i32 }` and
  passes as one `i32` only because each member's declared type is `unsigned`, a
  4-byte unit. Kyn declares the width without a storage type, so `a:u3;b:u5` is a
  1-byte unit (measured: C's `unsigned char a:3; unsigned char b:5` is 1 byte,
  align 1), and any run whose widths sum past 8 bits would take a wider unit than
  the C struct it is compared with. Measured: `{ u3, u5 }` is 1 byte where
  `{ unsigned, unsigned }` is 4.
  The compatible subset is therefore: **one run, widths summing to at most 8,
  no non-bitfield member in the aggregate** — matched against the C struct that
  declares each member `unsigned char`, which is the only C spelling whose units
  are the widths themselves. It is covered by a fixture whose C side both
  produces and reads back the value.
  Measured confirmation of the second half of the subset: `{u3, u5, u12}` in Kyn
  is 4 bytes at align 2, and C's `{unsigned char a:3; unsigned char b:5;
  unsigned short c:12;}` is also 4 at align 2 **but places `c` at bit 16 like the
  rule above while a C `unsigned`-typed run places it at bit 8**, so the byte
  contents agree only in the documented subset. The two agree on size in both
  cases, which is why the size table was not enough to find this.
  Everything from 9 to 32 bits is deterministic and documented but **not** C
  compatible, and the design says so rather than implying otherwise.
  (A future `align(N)` or a `packed` bitfield unit could widen this subset; it is
  out of scope here and is not claimed.)

Anything outside the subset is still laid out deterministically (the rules above
are total), but a Kyn↔C boundary that depends on it is outside what the project
promises. This is the same posture `abi.md` §9 takes for aggregate layouts it
does not support: state the rule, and reject or document rather than guess.

### 4.3 ABI

A struct with bitfields is an aggregate like any other; its *size and alignment*
come from the packed layout, and then the existing eightbyte classifier applies
to the integer leaves it produces — but with a difference: a bitfield is not a
`i3` leaf at the ABI level. Measured:

```
struct Wire { unsigned kind : 3; unsigned tag : 5; };  // size 4, align 4
```

clang passes that as one `i32`, not as `i8`: the transport unit is the storage
unit, and the members merge inside it. So `collectAggregateLeaves` must record a
bitfield run as **one** leaf of the storage unit's width at the run's offset,
with the field's own width used only for the access masking. This is the one
place the design changes the leaf walk rather than reusing it.

## 5. Packed structs

### 5.1 Surface

```kyn
packed struct Packet {
    kind: u8,
    length: u32,
    checksum: u16,
}
```

`packed` is a modifier on `struct` (and on `union`), placed before the keyword.
There is no `@repr`, no `align(N)` attribute, and no per-field attribute syntax
in this increment: one modifier, one meaning — *no padding between members and
alignment 1*. Explicit alignment is also supported -- see §7.

Measured: `struct __attribute__((packed)) { char c; int i; }` is `size=5,
align=1, offsetof(i)=1`, and clang emits `%struct.P = type <{ i8, i32 }>`.

### 5.2 Consequences

- **Layout:** offsets are the running sum with no `alignForward`, and the
  aggregate's alignment is 1. `aggregateLayoutGuess` needs the flag to skip both
  the per-member alignment and the final rounding.
- **LLVM type:** the emitted definition must use the **packed** form `<{ ... }>`,
  or LLVM will re-insert the padding the source asked it to remove. This is the
  one place `structLlvmName`/`emitType` cannot treat packed and non-packed
  identically, and it is a one-token difference in the emitted text.
- **A field access is unaligned.** Every load/store of an unaligned address is
  valid on x86_64, so the existing `load`/`store` emission stays correct; the
  design records that a future target requiring alignment would need aligned
  accesses or a byte-wise copy, and that this is why packed is specified per
  target rather than universally.
- **ABI:** measured, a packed aggregate goes through `byval`/`sret` even when
  small, because the classifier sees an unaligned aggregate and Clang 18+ treats
  it as memory class. Verified: `struct P { char; int; }` (5 bytes) → `sret` +
  `byval` with `align 1`, where the same struct unpacked (8 bytes) travels in
  `i64`. This is the point where "packed is just layout" is false, and the
  classifier must take the flag into account: a packed aggregate is always
  `.memory`.

## 6. Diagnostics

| Code | Message | When |
| --- | --- | --- |
| `E0481` (new) | `union` member cannot be the union itself of its own size | a union containing itself by value (the `E0403` analogue) |
| `E0482` (new) | bitfield width is zero or has no storage unit | a `u0`/`i0` field, or a width above 64 in an aggregate |
| `E0483` (new) | a bitfield member must be an unsigned or signed integer | a `f32`, pointer or struct used as a bitfield |
| `E0484` (new) | `packed` is only allowed on a `struct` or `union` | the modifier on an `enum` or a `fn` |
| `E0403` (extended) | recursive aggregate | also through a union member and through a packed struct |

`E0482` and `E0483` are checked where the field type is resolved, so a struct can
never reach layout with a member whose width it cannot express. No existing code
changes meaning, so nothing is renumbered.

## 7. Explicit alignment (built in §57)

`align(N)` is a modifier on a **declaration**, in the same slot as `packed` and
in either order (`align(16) packed struct` and `packed align(16) struct` are the
same declaration). Field-level `_Alignas`-style annotation is **not** part of the
language: a field's alignment is its type's, and a field that needs more is a
field of an aligned type. That keeps one rule instead of two and is why §7's
"on a field and on a type" is narrowed here.

`align` is not a keyword. The parser recognises it only as an identifier
followed by `(`, so a variable or a function may still be named `align`.

### 7.1 The rule, measured

The design's stated rule -- "`align` *increases*, `packed` *decreases*, so the
maximum wins" -- is **right about alignment and incomplete about size**. Measured
with `zig cc` on this target (`.scratch/al.c`):

| C form | size | align |
|---|---|---|
| `struct A { char c; } __attribute__((aligned(16)))` | 16 | 16 |
| `struct B { char c; int i; } __attribute__((aligned(2)))` | **8** | **4** |
| `struct C { char c; int i; } __attribute__((packed, aligned(4)))` | **8** | **4** |
| `struct P { char c; int i; } __attribute__((packed))` | 5 | 1 |
| `struct D { char c; _Alignas(16) int i; }` | 32 | 16, `off(i)`=16 |
| `struct E { _Alignas(8) char c; int i; }` | 8 | 8, `off(i)`=4 |

The two corrections to the design's sentence:

1. **A smaller-than-natural `align(N)` is ignored, not an error.** `B` keeps
   alignment 4 and size 8; the `aligned(2)` does nothing. So `align` is a floor on
   the aggregate's alignment, never a cap --------------------------------------------------------- `align_ = max(align_, N)`.
2. **`packed` and `align` compose; neither replaces the other.** `C` has no
   interior padding (`i` sits at byte 1) *and* alignment 4 *and* size 8 -- the
   maximum wins on alignment, packing still decides the offsets, and the size is
   then rounded up to the alignment. The design's "maximum wins" alone would have
   suggested the packing was cancelled.

So the implemented rule is:

- per-member offsets: exactly as without `align(N)` -- `packed` removes the
  inter-member padding, an ordinary aggregate keeps it;
- aggregate alignment: `max(natural alignment, N)`, and 1 when `packed` and no
  `align`;
- size: the members' end rounded up to that alignment.

### 7.2 Emitting it

LLVM derives a struct's alignment from its members, so the annotation alone
would not honour `align(16)` on `{ i8 }`. The emitted definition gets a trailing
`[k x i8]` member whose length brings the type's size up to a multiple of the
alignment, which is the same rule as the layout and is what makes LLVM align the
type to it. Measured against clang, the emitted text is identical:

```
clang: %struct.A = type { i8, [15 x i8] }     kyn: identical
clang: %struct.C = type <{ i8, i32 }>          -- packed+aligned(4), 5 bytes
```

`C` is the one place the two differ **in text but not in meaning**: LLVM gives
`<{ i8, i32 }>` size 5 and alignment 1, so Kyn emits `<{ i8, i32, [3 x i8] }>`
(8 bytes), which carries the measured 8/4. clang relies on the `align` on the
*global/alloca* to get there instead; an emitted *type* has no such slot, so the
padding is the only way to say it. Both agree on every measured `sizeof` and
`_Alignof`, which is what the ABI fixture checks.

`alloca` and `byval` also needed the alignment: `addLocal` used to reserve padding
and annotate it `max(alignment, 8)`, and `llvmAlignmentOfType` computed the
maximum of a struct's field alignments, which ignores `packed` and `align(N)`.
The latter now **delegates to `aggregateLayoutGuess`** rather than re-deriving the
rule, which removes the second implementation that the packed increment had left
in place.

### 7.3 Diagnostics

| Code | When |
|---|---|
| `E0490` | `align(` is not followed by an integer |
| `E0491` | the value is not a power of two, or exceeds 4096 |
| `E0492` | `align(N)` does not precede a `struct` or `union` |

There is deliberately **no** diagnostic for an alignment below the natural one:
C ignores it and so does Kyn, and rejecting it would refuse a declaration whose
meaning is well defined. `align(0)` is rejected as not a power of two.

### 7.4 What is not covered

A field-level annotation, an alignment that changes the *ABI class* of an
aggregate (all forms measured here stay `.memory` or keep their natural class),
and per-target values other than this one.

The by-value classifier **was** brought into this during the increment that
followed §57, because §57 left `E0473` refusing every aligned aggregate. Measured
then: the sixteen-byte limit is the padded size, an eightbyte that holds no data
consumes no register, and the register width follows the data. `abi.md` §10.1
states those rules and `abi/cabi_align_byval` pins them against C.

## 8. Out of scope

- tagged unions, sum types, `match` over a tag;
- anonymous struct/union members;
- `extern`-declared C bitfields beyond the documented subset;
- unions with a non-trivial drop or ownership rule (Kyn has neither);
- per-target packed layout (specified for `x86_64` Linux only, like the rest of
  the aggregate ABI);
- `transmute`-style reinterpreting casts.

## 9. Measurements taken before writing this

All with the project's toolchain (`zig cc`, clang 22 front end), on this target:

```c
struct Sub { unsigned a : 3; unsigned b : 5; unsigned c : 12; }; // { i32 }, passes as i32
union U { char c; int i; double d; };                 // size 8, align 8
union F { float x; int i; };                          // size 4, align 4
union Small { char c; };                              // size 1, align 1
union Big { double d[3]; };                           // size 24, align 8
struct BF { unsigned a : 3; unsigned b : 5; int c; }; // size 8, align 4, off(c)=4
struct A  { unsigned a : 20; unsigned b : 20; };      // size 8  (40 bits > 32)
struct B  { unsigned char a : 4; unsigned char b : 6; }; // size 2 (10 bits > 8)
struct Mix { unsigned a : 3; char c; unsigned b : 5; };// size 4 — run resumes
struct Cd { unsigned a : 3; double d; unsigned b : 5; };// size 24, off(d)=8
struct __attribute__((packed)) P { char c; int i; };  // size 5, align 1, off(i)=1
```

and the ABI shapes those produce (the `define` lines in §3.3 and §5.2). Two
further LLVM facts were measured rather than assumed: a named struct
`%U = type { double }` plus a packed `%P = type <{ i8, i32 }>` with
`sret(%P) align 1` and `byval(%P) align 8` assemble and link, and a lone `i8`
parameter is returned in `%al` by a one-register move — i.e. nothing beyond the
current emitter is needed for the small cases.

## 10. Implementation plan, in order

Each step is independently testable and leaves the tree consistent; step 4
cannot land without step 5's fixture, which is the rule every ABI change here
has followed.

1. **type model.** `StructInfo` gains `is_union: bool` and `is_packed: bool`;
   `aggregateLayoutGuess` gains the union branch (max size/align, all members at
   offset 0) and the packed branch (no per-member alignment, align 1). Unit tests
   pin the measured numbers in §9.
2. **parser + resolver.** `union` declaration (same body grammar as `struct`);
   `packed` modifier before `struct`/`union`; `uN`/`iN` widths accepted as field
   types with `E0482`/`E0483`. Struct initializer: exactly one member for a
   union; `E0403`/`E0481` extended.
3. **leaf walk + classifier.** Union members all at offset 0; a bitfield run
   recorded as one leaf of the storage unit's width; a packed aggregate forced to
   `.memory`. Unit tests assert the class each measured shape gets.
4. **backend.** Packed definition as `<{ ... }>`; union emitted as
   `%struct.<name>` with the computed layout; `byval`/`sret` alignment from the
   aggregate's own alignment (1 for packed); bitfield read/write as
   mask-and-shift over the storage unit.
5. **tests.** A unit test per diagnostic; an ABI fixture per feature in
   `tests/integration/abi/` (C passes and receives a union, a packed struct and a
   documented-subset bitfield struct); a case fixture pinning the deterministic
   layout of a bitfield struct that is outside the C subset, so the documented
   rule cannot drift silently; `safety-model.md` §3 gains the union
   misread and the out-of-subset bitfield layout.
6. **docs.** `abi.md` §9 loses the line and gains a §10 for the three features;
   `language-reference.md` §3.3/§3.4 gain the union, the bitfield width types and
   the `packed` modifier; `diagnostics.md` gains `E0481`–`E0484`; `roadmap.md`,
   `README.md` and `CHANGELOG.md` record the change.

### What landed in §57 (explicit alignment)

- **A fourth flag, exactly as this document predicted.** `StructInfo.explicit_align`
  (0 = absent) threaded parser → AST → resolver → `placeFields` → emitter, with no
  change to the union/packed/bitfield paths.
- **§7's rule was corrected against measurement, in two ways.** `align(N)` below
  the natural alignment is *ignored*, not an error (`aligned(2)` on a 4-aligned
  struct leaves 8/4), and `packed`+`align` *compose*: packing still removes the
  interior padding while the alignment is the maximum of the two and the size is
  rounded up to it (`packed, aligned(4)` on `{char,int}` is 8/4, with `i` at byte
  1). "The maximum wins" is right about alignment and incomplete about size.
- **A second layout implementation was removed, not extended.**
  `llvmAlignmentOfType` computed a struct's alignment as the maximum over its
  *fields*, which ignores `packed` and `align(N)`; it now calls
  `aggregateLayoutGuess`, so there is one rule again.
- **Two emitter bugs were found by the extreme cases and fixed.** A global of an
  aligned type emitted a constant with the wrong number of elements (the trailing
  padding member had no initializer, rejected by the LLVM parser), and a union
  took no padding at all, so `align(16) union { char; int }` came out 4 bytes
  instead of 16. Both now have assertions in `cases/align_layout`.
- **The emitted type is text-identical to clang's for the ordinary cases**
  (`{ i8, [15 x i8] }` for `align(16) { u8 }`). It differs for
  `packed`+`align(N)`, where clang writes `<{ i8, i32 }>` and puts `align 4` on the
  global/alloca; Kyn writes `<{ i8, i32, [3 x i8] }>`. Both measure 8/4, and an
  emitted *type* has no annotation slot, so the padding is the only available
  spelling -- §7.2 states why rather than hiding it.
- **The ABI fixture compares against C on both sides.** `cabi_align` prints
  `sizeof`/`_Alignof` from the C translation unit for the same two shapes and
  checks that a Kyn local really is 16-aligned at runtime (not merely typed so),
  exiting 30. §57 left an aligned aggregate *by value* tripping `E0473`; that was
  closed in the following increment by the measured rules of `abi.md` §10.1.

### What landed in §56 (bitfields)

- **Steps 1, 2, 3, 4 and 5 for bitfields.** `uN`/`iN` widths 1..128 resolved where
  a type is expected (`E0486` outside that range); `isBitfield` recognising a
  width that is not a whole number of bytes; `placeFields` laying out a run on a
  bit cursor *and* emitting one integer per run plus explicit padding for gaps;
  `bit_extract`/`bit_insert` in the IR, so a read is a load plus two shifts and a
  write is a load, mask, shift, and store; `E0487` for a union bitfield member and
  `E0489` for a layout the emitted type cannot mirror.
- **Two errors in §4.1 were corrected against measurement, not argued away.**
  (1) The rule was said to pick "the smallest unit that holds the field's width"
  and cited `Mix` = 4 as confirming it; `Mix` is 4 only because its declared type
  is `unsigned`, and the same shape with `unsigned char` members is 3. (2) The
  rule implied a growing run takes a wider *common* unit, which would put `c` at
  bit 8 in `{u3, u5, u12}`; the measured position is bit 16, because a field never
  straddles a boundary of its own width. §4.1 now states the cursor rule and lists
  the byte-level measurements that fix it.
- **The C-compatible subset was narrowed after measuring why the old one was
  wrong.** §4.2 claimed "widths summing to at most 32 bits"; that hold only
  because C's `unsigned a:3` uses a 4-byte unit, which the bare-width spelling
  does not. The subset is now widths summing to at most 8 bits with no
  non-bitfield member, matched against C's `unsigned char` spelling.
  `{u3, u5, u12}` agrees with C on *size* (4 bytes, alignment 2) while disagreeing
  on *contents*, which is exactly the kind of agreement that would have hidden a
  bug; the fixture compares bytes, not sizes.
- **One shape this increment refuses.** `{a: u31, b: u33}` needs an 8-byte unit
  starting at byte 3, overlapping bytes the first unit already owns. C accepts it
  by fusing the runs into one 8-byte unit; Kyn does not implement that rule and
  reports `E0489` instead of emitting a type that disagrees with its own layout.
  This is stated in `abi.md` §11, `language-reference.md` §3.7 and
  `safety-model.md` §3 rather than being left for a reader to discover.

### What landed in §55

- **Step 1 (type model):** `StructInfo.is_union` / `is_packed`, the union branch
  of `aggregateLayoutGuess` (max size/align, members overlapping at 0) and the
  packed branch (no per-member alignment, alignment 1). Unit tests pin the
  measured numbers.
- **Step 2 (parser + resolver):** `union` and the `packed` modifier, `E0484` for
  a `packed` that is not followed by an aggregate, `E0485` for a union
  initializer that does not name exactly one member, and the `E0403`/`E0404`
  messages now say "union" when the aggregate is one. `E0481` was **not**
  needed: the existing `E0403` "contains itself by value" check already covers
  a union, because it walks the same field list, so allocating a second code
  would have added a synonym — the diagnostic names the union instead.
- **Step 3 (leaf walk + classifier):** union members are walked at the base
  offset, and a packed aggregate is forced to `.memory`. Unit tests assert the
  class of each measured shape against clang's answer.
- **Step 4 (backend):** packed definitions are emitted as `<{ ... }>`; a union is
  emitted as a struct holding its most aligned member, and `field_ptr` maps every
  union member to index 0 **in the emitter**, so no producer has to know the
  representation. `sizeInBytes` now delegates to `aggregateLayoutGuess` instead of
  re-deriving struct/array layout — two copies of the union and packed rules
  would have been a correctness hazard, and this removes the second copy.
- **Step 5 (tests):** `cabi_union_packed` (C calls Kyn with and receives from
  Kyn a union by value, a packed struct by value, and a union nested in a
  struct; exit 255) and `cabi_union_packed_layout` (the layout is read back
  through Kyn's own field access and compared against C's offsets at bytes 1 and
  4 of a packed struct and byte 8 of a nested union; exit 15), plus three error
  fixtures and five unit tests.
- **Not landed in §55:** bitfields and `align(N)`; both are now covered — bitfields
  in §56 below, `align(N)` not at all. The four codes §10 reserved for this work
  (`E0481`–`E0483`) were **never allocated**: `E0403` already covers the union
  recursion case, and the bitfield cases needed three different diagnostics
  (`E0486` width out of range, `E0487` union member, `E0489` unrepresentable
  layout), so reserving numbers before the checks existed would have been a guess.
  `diagnostics.md` documents the codes the compiler can actually emit, which is
  what `check_diagnostic_docs.py` enforces.

## 11. How this document was checked before being published

The design was written against measured behaviour and then re-checked, which
changed it twice:

- **A stated rule was wrong and is now fixed.** The first draft said a
  non-bitfield member ends a bitfield run, so a later bitfield starts a fresh
  block. `struct Mix { unsigned a:3; char c; unsigned b:5; }` measures 4 bytes,
  not 8, so the rule is "close the unit, and a later run reuses the space inside
  the closed unit's alignment". §4.1 now states the layering rule, not the
  absolute one, and the six measured declarations in the table pin it.
- **The retrieval-code table was corrected** rather than left as a guess: `E0482`
  describes what it can actually check (a zero width, or a width with no storage
  unit), not a packed-context rule that does not exist.

Every claim about *current* behaviour was checked against this tree rather than
inferred: `union`, `packed`, `uN`/`iN` widths and bitfield syntax are all absent
today (`union U { … }` is `E0204`, `a: u3` is `E0422`), `E0481`–`E0484` are
unused, `E0403` exists for structs only, `IntInfo` already carries an arbitrary
`bits: u16` so `u5` needs no new type machinery, and `memberBoundaryBits` already
maps a sub-32-bit integer member to its transport width.

## 12. Risks, stated before implementation

- **The bitfield storage-unit rule is the only genuinely new algorithm.** C's
  rules are implementation-defined and the measured subset is narrow; the design
  therefore specifies the total rule it will implement, documents the subset it
  claims is C-compatible, and pins both with fixtures rather than claiming more.
- **`E0426` already rejects literals that do not fit a width**, and `u3` fields
  will make that reachable in more programs. The design keeps the existing rule
  and does not add a second one.
- **Packed + `sret`/`byval` alignment 1** is the shape most likely to be wrong on
  a target other than `x86_64`; the design scopes packed to `x86_64` Linux, and
  `E0473` already exists to reject an unsupported target boundary.
