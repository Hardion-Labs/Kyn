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

    stdout_file="$TMP/$name.stdout"
    stderr_file="$TMP/$name.stderr"
    status=0
    (cd "$TMP/work" && "$KYNC" run "$case_file" --profile "$PROFILE" >"$stdout_file" 2>"$stderr_file") || status=$?

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
else
    bad "kyn+c+zig build" "$(cat "$build_log")"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
