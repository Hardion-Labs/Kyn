#!/usr/bin/env bash
#
# Build the Kyn release archives:
#   dist/kyn-<version>-linux-x86_64.tar.gz
#   dist/kyn-<version>-windows-x86_64.zip
#
# Both archives contain prebuilt kync / kyn-build binaries, the LICENSE,
# INSTALL.md (requirements + manual install) and the platform installers.
# The Linux archive is verified end-to-end by extracting it, installing with
# install.sh and running both binaries; the Windows archive is structurally
# validated (contents, PE magic) since it cannot execute on Linux.
#
# Usage:
#   packaging/make-dist.sh [version]
#
# Environment:
#   ZIG   zig compiler to use (default: zig; requires Zig 0.17.0)
#   DIST  output directory for the archives (default: <repo>/dist)
#   CC    C compiler for the installed-linux smoke test
#         (default: clang, falling back to a `zig cc` wrapper when available)

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: packaging/make-dist.sh [version]

Builds dist/kyn-<version>-linux-x86_64.tar.gz and
dist/kyn-<version>-windows-x86_64.zip from a clean ReleaseSafe build.
The version defaults to build.zig.zon's .version.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ $# -gt 1 ]; then
    usage >&2
    exit 2
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

VERSION=${1:-$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon | head -n 1)}
if [ -z "$VERSION" ]; then
    echo "error: could not determine version (pass it explicitly)" >&2
    exit 2
fi

ZIG=${ZIG:-zig}
DIST=${DIST:-"$ROOT/dist"}
NAME_LINUX="kyn-${VERSION}-linux-x86_64"
NAME_WINDOWS="kyn-${VERSION}-windows-x86_64"

command -v "$ZIG" >/dev/null 2>&1 || { echo "error: zig not found (set ZIG=/path/to/zig)" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "error: tar is required" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "error: zip is required" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "error: unzip is required" >&2; exit 1; }
echo "zig:    $("$ZIG" version)"
echo "root:   $ROOT"
echo "version: $VERSION"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/kyn-dist.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

echo
echo "== building x86_64-linux-gnu (ReleaseSafe)"
"$ZIG" build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix "$STAGE/linux"
for tool in kync kyn-build; do
    [ -x "$STAGE/linux/bin/$tool" ] || { echo "error: missing $STAGE/linux/bin/$tool" >&2; exit 1; }
done

echo
echo "== building x86_64-windows (ReleaseSafe)"
"$ZIG" build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe --prefix "$STAGE/windows"
for tool in kync.exe kyn-build.exe; do
    [ -f "$STAGE/windows/bin/$tool" ] || { echo "error: missing $STAGE/windows/bin/$tool" >&2; exit 1; }
done

echo
echo "== staging archives"
PKG="$STAGE/pkg"
LINUX_DIR="$PKG/$NAME_LINUX"
WINDOWS_DIR="$PKG/$NAME_WINDOWS"
mkdir -p "$LINUX_DIR/bin" "$WINDOWS_DIR/bin"

cp "$STAGE/linux/bin/kync" "$STAGE/linux/bin/kyn-build" "$LINUX_DIR/bin/"
chmod 755 "$LINUX_DIR/bin/kync" "$LINUX_DIR/bin/kyn-build"
cp LICENSE packaging/INSTALL.md packaging/install.sh "$LINUX_DIR/"
chmod 755 "$LINUX_DIR/install.sh"

# Ship only the .exe binaries (not the .pdb debug symbols).
cp "$STAGE/windows/bin/kync.exe" "$STAGE/windows/bin/kyn-build.exe" "$WINDOWS_DIR/bin/"
cp LICENSE packaging/INSTALL.md packaging/install.sh packaging/install.ps1 packaging/install.bat "$WINDOWS_DIR/"

mkdir -p "$DIST"
rm -f "$DIST/$NAME_LINUX.tar.gz" "$DIST/$NAME_WINDOWS.zip"

TAR_FLAGS=( -czf )
if tar --version 2>/dev/null | grep -qi GNU; then
    TAR_FLAGS=( --owner=0 --group=0 --numeric-owner -czf )
fi
tar "${TAR_FLAGS[@]}" "$DIST/$NAME_LINUX.tar.gz" -C "$PKG" "$NAME_LINUX"
(cd "$PKG" && zip -X -q -r "$DIST/$NAME_WINDOWS.zip" "$NAME_WINDOWS")

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
    else shasum -a 256 "$1"; fi
}

echo
echo "== verifying linux archive (extract, install, run)"
VERIFY="$STAGE/verify"
mkdir -p "$VERIFY"
tar -xzf "$DIST/$NAME_LINUX.tar.gz" -C "$VERIFY"
"$VERIFY/$NAME_LINUX/install.sh" --prefix "$VERIFY/prefix"
"$VERIFY/prefix/bin/kync" --version
"$VERIFY/prefix/bin/kyn-build" --version

# Smoke test: compile and run an example with the *installed* compiler.
CC_BIN=${CC:-$(command -v clang || true)}
if [ -z "$CC_BIN" ] && command -v "$ZIG" >/dev/null 2>&1; then
    CC_BIN="$STAGE/zig-cc"
    printf '#!/bin/sh\nexec "%s" cc "$@"\n' "$(command -v "$ZIG")" > "$CC_BIN"
    chmod +x "$CC_BIN"
fi
if [ -n "$CC_BIN" ]; then
    "$VERIFY/prefix/bin/kync" build examples/hello.kyn -o "$VERIFY/hello" --cc "$CC_BIN"
    "$VERIFY/hello"
else
    echo "note: no clang or zig found; skipping native smoke test (set CC=/path/to/clang)"
fi

echo
echo "== verifying windows archive (structure, PE magic)"
unzip -l "$DIST/$NAME_WINDOWS.zip"
for tool in kync.exe kyn-build.exe; do
    magic=$(unzip -p "$DIST/$NAME_WINDOWS.zip" "$NAME_WINDOWS/bin/$tool" | head -c 2)
    if [ "$magic" != "MZ" ]; then
        echo "error: $tool is not a PE binary (bad magic)" >&2
        exit 1
    fi
done
echo "windows binaries have a valid PE header (not executed: cross-target)"

echo
echo "== release archives"
sha256 "$DIST/$NAME_LINUX.tar.gz"
sha256 "$DIST/$NAME_WINDOWS.zip"
echo "done → $DIST"
