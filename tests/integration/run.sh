#!/usr/bin/env bash
#
# Kyn integration test suite.
#
# Positive cases compile, link and execute real programs and compare their
# exit status (and stdout, when a .out file exists).
# Negative cases must fail with a specific diagnostic code.
# The interop check builds a Kyn + C + Zig project through kyn-build.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
KYNC=${KYNC:-"$ROOT/zig-out/bin/kync"}
KYNBUILD=${KYNBUILD:-"$ROOT/zig-out/bin/kyn-build"}
PROFILE=${PROFILE:-safe}
BUILD=1

usage() {
    cat <<'EOF'
Usage: tests/integration/run.sh [options]

Options:
  --kync <path>      Compiler under test (default: zig-out/bin/kync)
  --kyn-build <path> Build tool under test (default: zig-out/bin/kyn-build)
  --profile <name>   Profile used for positive cases (default: safe)
  --no-build         Do not build the toolchain when binaries are missing
  -h, --help         Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kync)
            KYNC=$2
            shift 2
            ;;
        --kyn-build)
            KYNBUILD=$2
            shift 2
            ;;
        --profile)
            PROFILE=$2
            shift 2
            ;;
        --no-build)
            BUILD=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -x "$KYNC" ] || [ ! -x "$KYNBUILD" ]; then
    if [ "$BUILD" -eq 0 ]; then
        echo "error: toolchain binaries are missing; build with 'zig build' first" >&2
        exit 2
    fi
    echo "building toolchain..."
    (cd "$ROOT" && zig build) || exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/kyn-integration.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}

bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/       /'
    fi
}

echo "positive cases (profile: $PROFILE)"

for case_file in "$ROOT"/tests/integration/cases/*.kyn; do
    name=$(basename "$case_file" .kyn)
    expected_exit=0
    if [ -f "${case_file%.kyn}.exit" ]; then
        expected_exit=$(tr -d '[:space:]' <"${case_file%.kyn}.exit")
    fi

    # A `.args` file holds the program arguments, one per line, so a case can
    # exercise the `argc`/`argv` entry point. Empty lines are meaningful (an
    # empty argument) and a missing file means no arguments at all.
    case_args=()
    if [ -f "${case_file%.kyn}.args" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case_args+=("$line")
        done <"${case_file%.kyn}.args"
    fi

    stdout_file="$TMP/$name.stdout"
    stderr_file="$TMP/$name.stderr"
    status=0
    run_args=()
    if [ ${#case_args[@]} -gt 0 ]; then
        run_args=(-- "${case_args[@]}")
    fi
    (cd "$TMP/work" && "$KYNC" run "$case_file" --profile "$PROFILE" "${run_args[@]}" >"$stdout_file" 2>"$stderr_file") || status=$?

    if [ "$status" -ne "$expected_exit" ]; then
        bad "$name: expected exit $expected_exit, got $status" "$(cat "$stderr_file")"
        continue
    fi

    if [ -f "${case_file%.kyn}.out" ]; then
        if ! diff -u "${case_file%.kyn}.out" "$stdout_file" >"$TMP/$name.diff"; then
            bad "$name: stdout mismatch" "$(cat "$TMP/$name.diff")"
            continue
        fi
    fi

    ok "$name"
done

echo "profile matrix"

for profile in debug safe release fast; do
    case_file="$ROOT/tests/integration/cases/structs.kyn"
    status=0
    (cd "$TMP/work" && "$KYNC" run "$case_file" --profile "$profile" >/dev/null 2>"$TMP/profile-$profile.stderr") || status=$?
    if [ "$status" -eq 30 ]; then
        ok "structs ($profile)"
    else
        bad "structs ($profile): expected exit 30, got $status" "$(cat "$TMP/profile-$profile.stderr")"
    fi

    for check_case in overflow_add_i32 runtime_bounds runtime_slice_bounds runtime_division overflow_shift runtime_null_deref runtime_null_slice; do
        check_file="$ROOT/tests/integration/cases/$check_case.kyn"
        expected=$(tr -d '[:space:]' <"$ROOT/tests/integration/cases/$check_case.exit")
        status=0
        (cd "$TMP/work" && "$KYNC" run "$check_file" --profile "$profile" >/dev/null 2>"$TMP/profile-$profile-$check_case.stderr") || status=$?
        if [ "$status" -eq "$expected" ]; then
            ok "runtime check $check_case ($profile)"
        else
            bad "runtime check $check_case ($profile): expected exit $expected, got $status" "$(cat "$TMP/profile-$profile-$check_case.stderr")"
        fi
    done
done

echo "negative cases"

for case_file in "$ROOT"/tests/integration/errors/*.kyn; do
    name=$(basename "$case_file" .kyn)
    code_file="${case_file%.kyn}.code"
    if [ ! -f "$code_file" ]; then
        bad "$name: missing $code_file"
        continue
    fi
    code=$(tr -d '[:space:]' <"$code_file")

    stderr_file="$TMP/error-$name.stderr"
    status=0
    "$KYNC" check "$case_file" >/dev/null 2>"$stderr_file" || status=$?

    if [ "$status" -eq 0 ]; then
        bad "$name: expected failure, compiler succeeded"
        continue
    fi
    if ! grep -qF "error[$code]" "$stderr_file"; then
        bad "$name: expected diagnostic $code" "$(cat "$stderr_file")"
        continue
    fi
    ok "$name ($code)"
done

imported_diag="$TMP/imported-diagnostic.stderr"
status=0
"$KYNC" check "$ROOT/tests/integration/errors/imported_unknown.kyn" >/dev/null 2>"$imported_diag" || status=$?
if [ "$status" -ne 0 ] && grep -qF "modules/unknown.kyn:" "$imported_diag" && grep -qF "error[E0427]" "$imported_diag"; then
    ok "diagnostics retain imported source locations"
else
    bad "diagnostics retain imported source locations" "$(cat "$imported_diag")"
fi

echo "diagnostic documentation"

if "${PYTHON:-python3}" "$ROOT/tests/integration/check_diagnostic_docs.py" >"$TMP/diagnostic-docs.log" 2>&1; then
    ok "diagnostic codes documented"
else
    bad "diagnostic codes documented" "$(cat "$TMP/diagnostic-docs.log")"
fi

if "${PYTHON:-python3}" "$ROOT/tests/integration/check_docs_links.py" >"$TMP/docs-links.log" 2>&1; then
    ok "documentation links resolve"
else
    bad "documentation links resolve" "$(cat "$TMP/docs-links.log")"
fi

echo "tool metadata"

if "${PYTHON:-python3}" "$ROOT/tests/integration/check_versions.py" --kync "$KYNC" --kyn-build "$KYNBUILD" >"$TMP/tool-metadata.log" 2>&1; then
    ok "version metadata consistent"
else
    bad "version metadata consistent" "$(cat "$TMP/tool-metadata.log")"
fi

echo "robustness corpus"

if "${PYTHON:-python3}" "$ROOT/tests/integration/robustness.py" --kync "$KYNC" >"$TMP/robustness.log" 2>&1; then
    ok "$(cat "$TMP/robustness.log")"
else
    bad "deterministic robustness corpus" "$(cat "$TMP/robustness.log")"
fi

echo "code generation"

ll_file="$TMP/hello.ll"
if "$KYNC" emit-llvm "$ROOT/tests/integration/cases/hello.kyn" -o "$ll_file" >/dev/null 2>"$TMP/emit-llvm.stderr" \
    && grep -q "define.*@main" "$ll_file"; then
    ok "emit-llvm"
else
    bad "emit-llvm" "$(cat "$TMP/emit-llvm.stderr")"
fi

obj_file="$TMP/hello.o"
if "$KYNC" emit-obj "$ROOT/tests/integration/cases/hello.kyn" -o "$obj_file" >/dev/null 2>"$TMP/emit-obj.stderr" \
    && [ -s "$obj_file" ]; then
    ok "emit-obj"
else
    bad "emit-obj" "$(cat "$TMP/emit-obj.stderr")"
fi

echo "compilation targets"

# The module carries no triple or datalayout, so the external assembler decides
# the machine code from `-target`. These checks pin the observable consequences.
target_obj="$TMP/target-aarch64.o"
target_machine=""
if "$KYNC" emit-obj "$ROOT/tests/integration/cases/hello.kyn" --target aarch64-linux-gnu \
    -o "$target_obj" >/dev/null 2>"$TMP/target-aarch64.stderr" && [ -s "$target_obj" ]; then
    # e_machine lives at offset 18 of an ELF64 header: 0x00b7 is AArch64.
    target_machine=$(od -An -tx1 -j18 -N2 "$target_obj" | tr -d ' \n')
fi
if [ "$target_machine" = "b700" ]; then
    ok "cross-compiles to aarch64"
else
    bad "cross-compiles to aarch64" "$(cat "$TMP/target-aarch64.stderr")"
fi

# A target that is not x86_64 Linux has no System V aggregate ABI here, so an
# aggregate across the C boundary must be diagnosed instead of lowered wrongly.
# The probe uses one shape the x86_64 classifier accepts, so the only variable
# is the target: rejected here, accepted there.
target_probe="$TMP/target-probe.kyn"
cat >"$target_probe" <<'EOF'
struct Pair { a: i32, b: i32 }
extern fn take(v: Pair) Pair;
fn main() i32 { return 0; }
EOF

target_reject="$TMP/target-reject.stderr"
status=0
"$KYNC" check "$target_probe" --target aarch64-linux-gnu >/dev/null 2>"$target_reject" || status=$?
if [ "$status" -ne 0 ] && grep -qF "error[E0473]" "$target_reject"; then
    ok "non-SystemV target rejects aggregate C boundaries"
else
    bad "non-SystemV target rejects aggregate C boundaries" "$(cat "$target_reject")"
fi

status=0
"$KYNC" check "$target_probe" --target x86_64-linux-gnu \
    >/dev/null 2>"$TMP/target-accept.stderr" || status=$?
if [ "$status" -eq 0 ]; then
    ok "System V target accepts the same boundary"
else
    bad "System V target accepts the same boundary" "$(cat "$TMP/target-accept.stderr")"
fi

scalar_obj="$TMP/target-scalar-aarch64.o"
if "$KYNC" emit-obj "$ROOT/tests/integration/cases/hello.kyn" --target x86_64-unknown-linux-gnu \
    -o "$scalar_obj" >/dev/null 2>"$TMP/target-vendor.stderr" && [ -s "$scalar_obj" ]; then
    ok "accepts the vendor-qualified spelling"
else
    bad "accepts the vendor-qualified spelling" "$(cat "$TMP/target-vendor.stderr")"
fi

status=0
"$KYNC" emit-obj "$ROOT/tests/integration/cases/hello.kyn" --target bogus-linux-gnu \
    -o "$TMP/target-bogus.o" >"$TMP/target-bogus.stdout" 2>"$TMP/target-bogus.stderr" || status=$?
if [ "$status" -eq 2 ] && grep -qF "unknown target" "$TMP/target-bogus.stderr"; then
    ok "rejects an unknown target"
else
    bad "rejects an unknown target" "$(cat "$TMP/target-bogus.stderr")"
fi

echo "interop (Kyn + C + Zig)"

fixture_dir="$ROOT/tests/integration/abi"
CC=${CC:-clang}

interop_dir="$TMP/hybrid"
mkdir -p "$interop_dir"
cp -R "$ROOT/examples/hybrid/src" "$ROOT/examples/hybrid/zig" "$interop_dir/"
cp "$ROOT/examples/hybrid/kyn.build" "$interop_dir/kyn.build"
for case_file in "$fixture_dir"/*.kyn; do
    name=$(basename "$case_file" .kyn)
    expected_exit=0
    if [ -f "${case_file%.kyn}.exit" ]; then
        expected_exit=$(tr -d '[:space:]' <"${case_file%.kyn}.exit")
    fi

    c_file="${case_file%.kyn}.c"

    kyn_obj="$TMP/$name-kyn.o"
    c_obj="$TMP/$name-c.o"
    executable="$TMP/$name-fixture"
    fixture_status=0

    "$KYNC" emit-obj "$case_file" -o "$kyn_obj" >/dev/null 2>"$TMP/$name-kyn.stderr" || fixture_status=$?
    if [ "$fixture_status" -eq 0 ]; then
        "$CC" -c "$c_file" -o "$c_obj" 2>"$TMP/$name-c.stderr" || fixture_status=$?
    fi
    if [ "$fixture_status" -eq 0 ]; then
        "$CC" "$kyn_obj" "$c_obj" -o "$executable" 2>"$TMP/$name-link.stderr" || fixture_status=$?
    fi

    if [ "$fixture_status" -eq 0 ]; then
        run_status=0
        "$executable" >/dev/null 2>&1 || run_status=$?
        if [ "$run_status" -eq "$expected_exit" ]; then
            ok "$name (exit $expected_exit)"
        else
            bad "$name: expected exit $expected_exit, got $run_status" "$(cat "$TMP/$name-kyn.stderr" "$TMP/$name-c.stderr" "$TMP/$name-link.stderr")"
        fi
    else
        bad "$name: compile or link failed" "$(cat "$TMP/$name-kyn.stderr" "$TMP/$name-c.stderr" "$TMP/$name-link.stderr")"
    fi
done

build_log="$TMP/interop-build.log"
status=0
"$KYNBUILD" --file "$interop_dir/kyn.build" --kync "$KYNC" --force >"$build_log" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then
    interop_status=0
    "$interop_dir/build/hybrid/hybrid" >/dev/null 2>&1 || interop_status=$?
    if [ "$interop_status" -eq 25 ]; then
        ok "kyn+c+zig executable"
    else
        bad "kyn+c+zig executable: expected exit 25, got $interop_status" "$(cat "$build_log")"
    fi

    status=0
    second_log=$("$KYNBUILD" --file "$interop_dir/kyn.build" --kync "$KYNC" 2>&1) || status=$?
    if [ "$status" -eq 0 ] && printf '%s' "$second_log" | grep -q "up to date"; then
        ok "incremental rebuild"
    else
        bad "incremental rebuild" "$second_log"
    fi

    import_project="$TMP/import-build"
    mkdir -p "$import_project/src/modules"
    cat >"$import_project/kyn.build" <<'EOF'
project "import-cache"
target "import-cache" {
    kind: "exe"
    sources: ["src/main.kyn"]
}
EOF
    cat >"$import_project/src/main.kyn" <<'EOF'
import "modules/api.kyn";
fn main() i32 { return imported_value(); }
EOF
    cat >"$import_project/src/modules/api.kyn" <<'EOF'
import "value.kyn";
fn imported_value() i32 { return imported_constant; }
EOF
    echo 'const imported_constant: i32 = 11;' >"$import_project/src/modules/value.kyn"
    status=0
    "$KYNBUILD" --file "$import_project/kyn.build" --kync "$KYNC" >"$TMP/import-build-first.log" 2>&1 || status=$?
    import_status=0
    "$import_project/build/import-cache/import-cache" >/dev/null 2>&1 || import_status=$?
    echo 'const imported_constant: i32 = 12;' >"$import_project/src/modules/value.kyn"
    status_after_edit=0
    "$KYNBUILD" --file "$import_project/kyn.build" --kync "$KYNC" >"$TMP/import-build-second.log" 2>&1 || status_after_edit=$?
    import_status_after_edit=0
    "$import_project/build/import-cache/import-cache" >/dev/null 2>&1 || import_status_after_edit=$?
    if [ "$status" -eq 0 ] && [ "$import_status" -eq 11 ] \
        && [ "$status_after_edit" -eq 0 ] && [ "$import_status_after_edit" -eq 12 ] \
        && grep -q "building" "$TMP/import-build-second.log"; then
        ok "transitive Kyn import invalidates build cache"
    else
        bad "transitive Kyn import invalidates build cache" "$(cat "$TMP/import-build-first.log" "$TMP/import-build-second.log")"
    fi

    # A C header is an input like any other: editing one has to rebuild, or the
    # build reports success while running the previous object.
    header_project="$TMP/header-build"
    mkdir -p "$header_project/src" "$header_project/inc"
    cat >"$header_project/kyn.build" <<'EOF'
project "header-cache"
target "header-cache" {
    kind: "exe"
    sources: ["src/main.kyn"]
    c_sources: ["src/value.c"]
    include_dirs: ["inc"]
}
EOF
    cat >"$header_project/src/main.kyn" <<'EOF'
extern fn c_value() i32;
fn main() i32 { return c_value(); }
EOF
    printf '#include "inner.h"\n#define OUTER INNER\n' >"$header_project/inc/outer.h"
    printf '#define INNER 21\n' >"$header_project/inc/inner.h"
    # Two levels of quoting: the source includes outer.h, which includes inner.h.
    printf '#include "outer.h"\nint c_value(void) { return OUTER; }\n' >"$header_project/src/value.c"
    status=0
    "$KYNBUILD" --file "$header_project/kyn.build" --kync "$KYNC" >"$TMP/header-build-first.log" 2>&1 || status=$?
    header_status=0
    "$header_project/build/header-cache/header-cache" >/dev/null 2>&1 || header_status=$?
    # Editing the transitively included header must invalidate the target.
    printf '#define INNER 22\n' >"$header_project/inc/inner.h"
    status_after_header=0
    "$KYNBUILD" --file "$header_project/kyn.build" --kync "$KYNC" >"$TMP/header-build-second.log" 2>&1 || status_after_header=$?
    header_status_after=0
    "$header_project/build/header-cache/header-cache" >/dev/null 2>&1 || header_status_after=$?
    # And a build with nothing changed must still be skipped.
    status_idle=0
    "$KYNBUILD" --file "$header_project/kyn.build" --kync "$KYNC" >"$TMP/header-build-third.log" 2>&1 || status_idle=$?
    if [ "$status" -eq 0 ] && [ "$header_status" -eq 21 ] \
        && [ "$status_after_header" -eq 0 ] && [ "$header_status_after" -eq 22 ] \
        && grep -q "building" "$TMP/header-build-second.log" \
        && [ "$status_idle" -eq 0 ] && grep -q "up to date" "$TMP/header-build-third.log"; then
        ok "transitive C header invalidates build cache"
    else
        bad "transitive C header invalidates build cache" "$(cat "$TMP/header-build-first.log" "$TMP/header-build-second.log" "$TMP/header-build-third.log")"
    fi
else
    bad "kyn+c+zig build" "$(cat "$build_log")"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
