# Packaging Kyn releases

This directory contains everything needed to produce the Kyn release
archives — `kyn-<version>-linux-x86_64.tar.gz` and
`kyn-<version>-windows-x86_64.zip` — with tested, ready-to-use installers.

## Contents

| File | Purpose |
|:---|:---|
| `make-dist.sh` | Build script: cross-compiles both targets with Zig, stages the archives, verifies them, prints SHA-256 sums |
| `install.sh` | POSIX installer for Linux / macOS / Git Bash (also shipped inside both archives) |
| `install.ps1` | Windows PowerShell installer: installs to `%LOCALAPPDATA%\Programs\Kyn`, adds `bin` to the user `PATH`, verifies the binaries |
| `install.bat` | cmd.exe wrapper around `install.ps1` |
| `INSTALL.md` | End-user documentation shipped inside the archives (requirements, manual install, uninstall) |

## Building the archives

Requirements: `bash`, `tar`, `zip`, `unzip` and Zig `0.17.0` (on `PATH` or
via `ZIG=/path/to/zig`). No network access is needed; no downloads happen.

```sh
packaging/make-dist.sh                 # version from build.zig.zon
ZIG=/path/to/zig packaging/make-dist.sh 0.1.0-alpha.3
```

Artifacts land in `dist/` (git-ignored):

```text
dist/kyn-0.1.0-alpha.3-linux-x86_64.tar.gz
dist/kyn-0.1.0-alpha.3-windows-x86_64.zip
```

## What the script verifies

1. **Linux archive** — extracted into a scratch directory, installed with
   `install.sh --prefix <scratch>`, and both `kync --version` and
   `kyn-build --version` are run from the installed prefix. If `clang`
   (or `zig`, used as a `zig cc` stand-in via `CC`) is available, the script
   also compiles and runs `examples/hello.kyn` with the *installed* compiler.
2. **Windows archive** — the zip listing is checked and both `.exe` files
   are confirmed to carry a PE (`MZ`) header. They cannot be executed on
   Linux; the Windows install path is validated by running `install.ps1`
   on Windows.
3. **Layout** — every archive carries `bin/kync` + `bin/kyn-build`
   (`.exe` on Windows), `LICENSE`, `INSTALL.md` and the installers at the
   archive root, under a single top-level `kyn-<version>-<platform>` directory.

SHA-256 sums of both archives are printed at the end; attach them to the
GitHub Release notes.

## Installer contract

Both installers must remain functional after any change here:

- copy `bin/kync[.exe]` and `bin/kyn-build[.exe]` into `<prefix>/bin`;
- mark/verify they are executable;
- on Windows, add `<prefix>\bin` to the **user** `PATH` (unless `-NoPath`);
- verify the installed binaries with `--version` and fail loudly otherwise;
- support `--uninstall` (`install.sh`) / `-Uninstall` (`install.ps1`),
  removing only the Kyn binaries and the PATH entry they added;
- default prefix: `/usr/local` as root, otherwise `~/.local` (`install.sh`),
  or `%LOCALAPPDATA%\Programs\Kyn` (`install.ps1`).

Bump nothing else: `make-dist.sh` derives the version from `build.zig.zon`,
so archives always match the repository version.
