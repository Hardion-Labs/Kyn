#!/usr/bin/env bash
#
# Release readiness gate for Kyn.
#
# This audit is read-only with respect to Git/GitHub metadata: it does not
# create tags, releases, branches or commits. It proves that the supplied
# commit is suitable for a human to release.

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: tools/release-check.sh <version> [expected-sha]

Examples:
  tools/release-check.sh 0.1.0-alpha.1
  tools/release-check.sh 0.1.0-alpha.1 fc243bb0629ac441b28c0698c219956bbe9a0589

The script checks:
  - current checkout is clean and on `main`;
  - HEAD matches the requested SHA and `origin/main`;
  - the CI workflow passed for that exact SHA;
  - a fresh clone of the commit builds, tests and runs integration/robustness;
  - `kync --version` and `kyn-build --version` match build metadata;
  - the tag and GitHub Release do not already exist;
  - CHANGELOG contains the requested version.
EOF
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage >&2
    exit 2
fi

VERSION=${1#v}
EXPECTED_SHA=${2:-}
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: not inside a Git repository" >&2
    exit 2
}
cd "$ROOT"

if [ -z "$EXPECTED_SHA" ]; then
    EXPECTED_SHA=$(git rev-parse HEAD)
fi
TAG="v${VERSION}"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}

bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
}

info() {
    printf '       %s\n' "$1"
}

echo "release readiness: $TAG"

current_branch=$(git branch --show-current)
if [ "$current_branch" = "main" ]; then
    ok "on main"
else
    bad "on main: current branch is '$current_branch'"
fi

if [ -z "$(git status --porcelain)" ]; then
    ok "working tree is clean"
else
    bad "working tree is clean"
    git status --short | sed 's/^/       /'
fi

head_sha=$(git rev-parse HEAD)
if [ "$head_sha" = "$EXPECTED_SHA" ]; then
    ok "HEAD matches expected SHA"
else
    bad "HEAD matches expected SHA: HEAD=$head_sha expected=$EXPECTED_SHA"
fi

remote_sha=$(git ls-remote origin refs/heads/main | awk '{print $1}')
if [ -n "$remote_sha" ] && [ "$remote_sha" = "$head_sha" ]; then
    ok "origin/main matches HEAD"
else
    bad "origin/main matches HEAD: remote=$remote_sha local=$head_sha"
fi

if [ "$(git rev-parse --is-shallow-repository)" = "false" ]; then
    ok "local repository is not shallow"
else
    bad "local repository is not shallow"
fi

echo "CI for $EXPECTED_SHA"
if ! command -v gh >/dev/null 2>&1; then
    bad "GitHub CLI is available"
else
    ci_run=$(gh run list --branch main --workflow CI --commit "$EXPECTED_SHA" --limit 10 \
        --json headSha,conclusion,databaseId \
        --jq '.[] | select(.conclusion == "success") | .databaseId' 2>/dev/null | head -n 1 || true)
    if [ -n "$ci_run" ]; then
        ok "CI succeeded for expected SHA (run $ci_run)"
    else
        bad "CI succeeded for expected SHA"
    fi
fi

echo "metadata"
if grep -Eq "^## \[$VERSION\]" CHANGELOG.md; then
    ok "CHANGELOG contains $VERSION"
else
    bad "CHANGELOG contains $VERSION"
fi

if ! git tag --list "$TAG" | grep -q .; then
    ok "tag $TAG does not exist locally"
else
    bad "tag $TAG does not exist locally"
fi

if ! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    ok "tag $TAG does not exist on origin"
else
    bad "tag $TAG does not exist on origin"
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
    ok "GitHub Release $TAG does not exist"
else
    bad "GitHub Release $TAG does not exist"
fi

echo "clean-room validation of $EXPECTED_SHA"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kyn-release-check.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if git clone --quiet --no-local --single-branch --branch main "$ROOT" "$TMP/repo"; then
    ok "clean clone created"
    git -C "$TMP/repo" checkout --quiet --detach "$EXPECTED_SHA"
    ok "clean clone checked out expected SHA"

    cd "$TMP/repo"

    if zig fmt --check build.zig compiler build-system >/dev/null 2>&1; then
        ok "zig fmt accepts the tree"
    else
        bad "zig fmt accepts the tree"
    fi

    if zig build >/dev/null 2>&1; then
        ok "clean build succeeds"
    else
        bad "clean build succeeds"
    fi

    if zig build test >/dev/null 2>&1; then
        ok "unit/regression tests pass"
    else
        bad "unit/regression tests pass"
    fi

    if python3 tests/integration/check_versions.py --kync zig-out/bin/kync --kyn-build zig-out/bin/kyn-build >/dev/null 2>&1; then
        ok "version metadata matches installed tools"
    else
        bad "version metadata matches installed tools"
    fi

    if zig build integration >/dev/null 2>&1; then
        ok "integration and robustness tests pass"
    else
        bad "integration and robustness tests pass"
    fi

    cd "$ROOT"
else
    bad "clean clone created"
fi

echo
printf 'checks passed: %d, failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
