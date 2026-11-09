# Kyn standard library (planned)

This directory is reserved for the Kyn standard library. It is **empty in
v0.1**; no `std` module exists and the language has no import system yet.

Planned scope, once modules and packages exist:

- core scalar and memory utilities;
- allocator interfaces (explicit, no implicit allocation);
- byte and string utilities;
- OS abstractions for files, processes and time;
- collections with explicit allocation policies;
- formatting without hidden allocation;
- optional concurrency primitives built on documented atomics.

Design constraints:

1. No hidden allocation, hidden global state or hidden synchronization.
2. Every fallible operation returns an explicit status/error value.
3. No dependency on a garbage collector.
4. Freestanding-friendly pieces must be separable from OS-dependent pieces.
5. API documentation must state allocation and failure behavior per function.

Until a module system lands, examples and tests use `extern fn` declarations to
call platform C functions such as `puts`, `malloc` and `free`.
