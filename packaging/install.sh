#!/bin/sh
# Kyn toolchain installer for Linux, macOS and Git Bash / MSYS2 on Windows.
#
# Installs the prebuilt `kync` and `kyn-build` binaries shipped in this
# archive into a prefix (default: /usr/local when run as root, otherwise
# ~/.local). On Windows, prefer install.ps1 unless you are using Git Bash.
#
# Usage:
#   ./install.sh                 Install into the default prefix
#   ./install.sh --prefix DIR    Install into DIR (binaries go to DIR/bin)
#   ./install.sh --uninstall     Remove the installed Kyn binaries
#   ./install.sh --uninstall --prefix DIR   Uninstall from DIR
#   ./install.sh --help          Show this help

set -eu

usage() {
    cat <<'USAGE'
Kyn installer

Usage:
  ./install.sh [--prefix DIR] [--uninstall] [-h|--help]

Options:
  --prefix DIR   Installation prefix (default: /usr/local as root, else ~/.local)
  --uninstall    Remove the Kyn binaries from the prefix
  -h, --help     Show this help

Environment:
  KYN_PREFIX     Same as --prefix when --prefix is not given
USAGE
}

PREFIX=""
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { echo "error: --prefix requires a directory" >&2; exit 2; }
            PREFIX=$2
            shift 2
            ;;
        --prefix=*)
            PREFIX=${1#--prefix=}
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$PREFIX" ]; then
    if [ -n "${KYN_PREFIX:-}" ]; then
        PREFIX=$KYN_PREFIX
    elif [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
        PREFIX=/usr/local
    else
        PREFIX="$HOME/.local"
    fi
fi

# Resolve the directory this script lives in (the archive root).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_BIN="$SCRIPT_DIR/bin"
DST_BIN="$PREFIX/bin"

TOOLS="kync kyn-build"

src_for() {
    # Print the source path for a tool, honoring the .exe suffix used on Windows.
    if [ -f "$SRC_BIN/$1" ]; then
        printf '%s\n' "$SRC_BIN/$1"
    elif [ -f "$SRC_BIN/$1.exe" ]; then
        printf '%s\n' "$SRC_BIN/$1.exe"
    else
        return 1
    fi
}

dst_name_for() {
    # Keep the .exe suffix when installing Windows binaries under Git Bash.
    case $(src_for "$1") in
        *.exe) printf '%s.exe\n' "$1" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

if [ "$UNINSTALL" = "1" ]; then
    echo "Uninstalling Kyn from $DST_BIN"
    removed=0
    for tool in $TOOLS; do
        for candidate in "$DST_BIN/$tool" "$DST_BIN/$tool.exe"; do
            if [ -f "$candidate" ] || [ -L "$candidate" ]; then
                rm -f "$candidate"
                echo "removed $candidate"
                removed=$((removed + 1))
            fi
        done
    done
    if [ "$removed" -eq 0 ]; then
        echo "nothing to remove (no Kyn binaries found in $DST_BIN)"
    else
        echo "uninstalled $removed file(s). To remove the prefix as well, delete: $PREFIX"
    fi
    exit 0
fi

for tool in $TOOLS; do
    if ! src_for "$tool" >/dev/null; then
        echo "error: '$tool' not found in $SRC_BIN" >&2
        echo "run this installer from the extracted release archive root" >&2
        exit 1
    fi
done

mkdir -p "$DST_BIN"

for tool in $TOOLS; do
    src=$(src_for "$tool")
    dst=$(dst_name_for "$tool")
    cp "$src" "$DST_BIN/$dst"
    chmod 755 "$DST_BIN/$dst"
    echo "installed $DST_BIN/$dst"
done

# Verify the installation actually works, not just that the files copied.
status=0
for tool in $TOOLS; do
    dst=$(dst_name_for "$tool")
    if ! version_out=$("$DST_BIN/$dst" --version 2>&1); then
        echo "error: installed '$dst' does not run:" >&2
        echo "$version_out" >&2
        status=1
    else
        echo "ok: $version_out"
    fi
done
if [ "$status" -ne 0 ]; then
    echo "error: installation verification failed" >&2
    exit 1
fi

case ":$PATH:" in
    *":$DST_BIN:"*) ;;
    *)
        echo
        echo "note: $DST_BIN is not on your PATH"
        echo "add it with:  export PATH=\"$DST_BIN:\$PATH\""
        echo "(persist it in your shell profile, e.g. ~/.profile or ~/.bashrc)"
        ;;
esac

echo
echo "Kyn installed successfully. Try: kync --version"
echo "Uninstall any time with: $0 --uninstall --prefix \"$PREFIX\""
