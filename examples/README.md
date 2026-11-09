# Examples

| File | Demonstrates |
| ---- | ------------ |
| `hello.kyn` | C ABI call to `puts`, string literal, `i32` main |
| `pointers.kyn` | mutable pointers, address-of, dereference, swapping |
| `hybrid/` | Kyn + C + Zig project built by `kyn-build` |

Run an example:

```sh
zig build
./zig-out/bin/kync run examples/hello.kyn
./zig-out/bin/kync run examples/pointers.kyn
```

`kync run` writes the executable to the current directory before executing it.
To keep the working tree clean, pass `-o /tmp/kyn-<name>` or remove the
generated binary afterwards. `kync run` returns the program's exit status, so
`pointers.kyn` exits with 0 on success.

Build the hybrid example:

```sh
./zig-out/bin/kyn-build --file examples/hybrid/kyn.build
./examples/hybrid/build/hybrid/hybrid
echo $?   # 25
```
