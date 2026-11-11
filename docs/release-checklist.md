# Release checklist

Kyn releases are cut only from a validated commit on `main`. A release is a
public promise, even for an alpha. Tags are never moved and releases are never
published for a different commit.

## Command

From the repository root:

```sh
tools/release-check.sh <version> [expected-sha]
```

Example:

```sh
tools/release-check.sh 0.1.0-alpha.4 <approved-sha>
```

If `expected-sha` is omitted, the script uses the current `HEAD`.

## What the gate verifies

1. The checkout is on `main` and the working tree is clean.
2. `HEAD` matches the requested SHA.
3. `origin/main` matches the same SHA.
4. The local clone is not shallow.
5. GitHub Actions ran the Kyn workflow successfully for that exact SHA.
6. `CHANGELOG.md` contains the requested version.
7. The tag and GitHub Release do not already exist.
8. A fresh clone of the requested SHA:
   - passes `zig fmt --check`;
   - builds the toolchain;
   - passes unit/regression tests;
   - has consistent metadata and `--version` output;
   - passes the full integration and robustness suite.

## What the gate does not decide

The gate cannot authorize a release. A human still decides:

- whether the release boundary is correct;
- whether the release notes accurately describe implemented functionality;
- whether `AGENTE.md` and other repository files should be public;
- whether the tag should be created and pushed;
- whether the GitHub Release should be published.

## Creating the release

After the gate passes and the decision is made:

```sh
git tag -a v0.1.0-alpha.4 <approved-sha> -m "Kyn v0.1.0-alpha.4"
git push origin v0.1.0-alpha.4
```

Then create the GitHub Release from the tag with notes that state:

- release version and commit;
- tested Zig and Clang/LLVM versions;
- platform and architecture coverage;
- implemented syntax and semantics;
- commands to build and run examples;
- known limitations and excluded features;
- experimental status and lack of source/ABI stability guarantees.

If any step fails, do not tag and do not release. Fix the problem or record
the blocker explicitly.

## Current alpha status

`v0.1.0-alpha.4` is implemented, CI-validated and published as the current
principal release: https://github.com/Hardion-Labs/Kyn/releases/tag/v0.1.0-alpha.4

`v0.1.0-alpha.3` remains published and untouched. New work builds from
`alpha.4`. No `alpha.5` or `beta.1` pre-release exists. The release-readiness
gate remains enforced by `tools/release-check.sh` for any future release.
