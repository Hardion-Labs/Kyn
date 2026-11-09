#!/usr/bin/env python3
"""Verify version strings across build metadata and installed tools."""

from pathlib import Path
import argparse
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ZON = ROOT / 'build.zig.zon'


def read_version(path: Path, pattern: re.Pattern[str]) -> str:
    text = path.read_text()
    match = pattern.search(text)
    if not match:
        raise ValueError(f'could not find version in {path}')
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--kync', required=True)
    parser.add_argument('--kyn-build', required=True)
    args = parser.parse_args()

    zon_version = read_version(ZON, re.compile(r'\.version\s*=\s*"([^"]+)"'))
    kync_source = read_version(ROOT / 'compiler' / 'main.zig', re.compile(r'const version = "([^"]+)"'))
    builder_source = read_version(ROOT / 'build-system' / 'main.zig', re.compile(r'const version = "([^"]+)"'))

    expected = {zon_version, kync_source, builder_source}
    if len(expected) != 1:
        print('version mismatch: build.zig.zon={} compiler/main.zig={} build-system/main.zig={}'.format(
            zon_version, kync_source, builder_source), file=sys.stderr)
        return 1

    checks = [
        (args.kync, f'kync {zon_version}\n'),
        (args.kyn_build, f'kyn-build {zon_version}\n'),
    ]
    for executable, expected_output in checks:
        result = subprocess.run(
            [executable, '--version'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        output = result.stdout.decode()
        if result.returncode != 0 or output != expected_output:
            print(f'{executable} --version failed: expected {expected_output!r}, got {output!r} (exit {result.returncode})', file=sys.stderr)
            return 1

    print(f'versions consistent at {zon_version}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
