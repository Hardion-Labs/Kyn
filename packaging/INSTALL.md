# Installing Kyn from a release archive

This archive contains the prebuilt Kyn toolchain:

| Binary | Purpose |
|:---|:---|
| `kync` | Kyn compiler driver — `check`, `emit-llvm`, `emit-obj`, `build`, `run` |
| `kyn-build` | Project system for mixed Kyn + C + Zig projects |

No build from source is required. You do **not** need Zig to use the
prebuilt binaries (only for building Kyn itself, or for `kyn-build` targets
that compile `zig_sources`).

## Linux (`kyn-<version>-linux-x86_64.tar.gz`)

Requirements:

- x86_64 Linux (the binaries are statically linked).
- `clang` on `PATH` — required by `kync build` / `kync run` and by
  `kyn-build`, which assemble and link the generated LLVM IR. Any recent
  clang with opaque-pointer LLVM IR support works. `kync check` and
  `kync emit-llvm` do not need clang.
- Optionally, `zig` 0.17.0 on `PATH` — only for `kyn-build` targets with
  `zig_sources`, or to pass to `kyn-build --zig <path>`.

Install:

```sh
tar -xzf kyn-0.1.0-alpha.3-linux-x86_64.tar.gz
cd kyn-0.1.0-alpha.3-linux-x86_64
./install.sh                 # /usr/local as root, otherwise ~/.local
./install.sh --prefix /opt/kyn   # custom prefix
```

The installer copies the binaries to `<prefix>/bin`, marks them executable,
and verifies them by running `--version`. Make sure `<prefix>/bin` is on your
`PATH` (the installer prints a hint if it is not).

Uninstall:

```sh
./install.sh --uninstall                  # same default prefix logic
./install.sh --uninstall --prefix /opt/kyn
```

## Windows (`kyn-<version>-windows-x86_64.zip`)

Requirements:

- 64-bit Windows 10 or later.
- Windows PowerShell (ships with Windows) for `install.ps1`.
- **Supported surface on Windows:** `kync check`, `kync emit-llvm`,
  `kyn-build --version` and project-system bookkeeping. Native code
  generation in `v0.1.0-alpha.3` is validated on x86_64 Linux only; on
  Windows, `kync build` / `kync run` invoke a `clang` from `PATH` to
  assemble and link the generated IR, and this path is not part of the
  tested release surface. Use Linux for building and running Kyn programs.

Install (PowerShell):

```powershell
Expand-Archive kyn-0.1.0-alpha.3-windows-x86_64.zip -DestinationPath .
cd kyn-0.1.0-alpha.3-windows-x86_64
.\install.ps1                    # installs to %LOCALAPPDATA%\Programs\Kyn
.\install.ps1 -Prefix C:\tools\kyn
```

`install.bat` does the same thing for users who prefer double-clicking;
`install.sh` also works under Git Bash / MSYS2. The installer copies the
binaries to `<prefix>\bin`, adds that directory to your **user** `PATH`,
and verifies the installation by running both binaries. Open a new terminal
for the `PATH` change to take effect (the installing session is refreshed
automatically). Use `-NoPath` to skip the `PATH` change.

Uninstall:

```powershell
.\install.ps1 -Uninstall
.\install.ps1 -Uninstall -Prefix C:\tools\kyn
```

## Manual install

Both archives can be installed by hand: copy `bin/kync` (`kync.exe`) and
`bin/kyn-build` (`kyn-build.exe`) into any directory on your `PATH`.

## Verify

```sh
kync --version        # kync 0.1.0-alpha.3
kyn-build --version   # kyn-build 0.1.0-alpha.3
```

## Notes

Kyn is alpha-quality software. No source or ABI stability is promised
between alpha releases. See the repository README for current limitations:
https://github.com/Hardion-Labs/Kyn
