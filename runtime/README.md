# Kyn runtime (planned)

Kyn v0.1 has no runtime library. Generated programs link directly against the
platform C library and any objects you provide. There is no Kyn startup code,
garbage collector, panic handler, unwinder or type-information table.

This directory is reserved for an **optional** runtime. Planned pieces:

- configurable runtime check handlers (bounds, overflow, division by zero,
  null dereference);
- a minimal freestanding entry/exit shim for targets without libc;
- allocator abstractions that remain explicit and opt-in;
- diagnostics/backtrace hooks for debug profiles;
- platform abstraction layers that can be omitted for kernels and firmware.

Rules for the future runtime:

1. Linking it is opt-in and documented per profile.
2. A program that does not use runtime features must not pay for them.
3. Runtime checks must be observable and testable; profiles may not silently
   remove promised checks.
4. Freestanding builds must remain possible with no runtime dependency.
5. No garbage collection and no hidden allocation.

Current behavior is documented in [../docs/memory-model.md](../docs/memory-model.md)
and [../docs/safety-model.md](../docs/safety-model.md).
