#!/usr/bin/env python3
"""Deterministic robustness corpus for the Kyn frontend.

The corpus is intentionally fixed-seed. It does not prove the absence of
crashes or hangs; it guards known fragile regions and fails loudly with a
reproducer when one is found.
"""

from pathlib import Path
import argparse
import random
import subprocess
import sys
import tempfile

SEED_PROGRAM = '''extern fn puts(s: *const u8) i32;
struct Point { x: i32, y: i32 }
enum Color: u8 { Red, Green = 3, Blue }
fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }
fn main() i32 {
    var p: Point = Point { x: 1, y: 2 };
    let q: *Point = &p;
    q->x += 1;
    var values: [3]i32 = [1, 2, 3];
    let s: []const i32 = values[..];
    let sub: []const i32 = s[1..];
    let head: []const i32 = values[..2];
    let c: Color = Color.Green;
    if (c == Color.Green) { puts("ok"); }
    let total: i32 = values[0] + sub[0] + head[1] + (*(s.ptr)) - 1 + (s.len as i32) - 3;
    return total + q->x - 6;
}
'''

TOKENS = [
    'fn', 'extern', 'export', 'struct', 'enum', 'const', 'let', 'var', 'if', 'else',
    'while', 'return', 'break', 'continue', 'as', 'true', 'false', 'null',
    'i32', 'u8', 'bool', 'void', 'main', 'x', 'y', 'Point', 'len', 'ptr',
    '{', '}', '(', ')', '[', ']', ',', ';', ':', '.', '..', '->',
    '+', '-', '*', '/', '%', '&', '|', '^', '~', '!', '=', '==', '!=',
    '<', '<=', '>', '>=', '<<', '>>', '+=', '<<=', '&&', '||',
    '0', '1', '42', '0x1F', '1_000', '1.5', '"str"', '"a\\n"', r"'c'",
    '/*', '*/', '//', '\n', ' ',
]


def check_case(kync: str, path: Path) -> str | None:
    try:
        result = subprocess.run(
            [kync, 'check', str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return 'timeout'

    if result.returncode < 0 or result.returncode >= 128:
        return f'crash (signal/exit {result.returncode})'
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--kync', required=True)
    args = parser.parse_args()

    failures: list[tuple[str, str]] = []
    counts = {'mutation': 0, 'token_soup': 0, 'binary': 0}

    with tempfile.TemporaryDirectory(prefix='kyn-robustness.') as directory:
        root = Path(directory)

        # 1. Localized mutations of a valid program.
        tokens = SEED_PROGRAM.split()
        random.seed(112233)
        for index in range(300):
            mutated = tokens.copy()
            for _ in range(random.randint(1, 12)):
                mutated[random.randrange(len(mutated))] = random.choice(tokens)
            path = root / f'mutation_{index}.kyn'
            path.write_text(' '.join(mutated))
            error = check_case(args.kync, path)
            counts['mutation'] += 1
            if error:
                failures.append((str(path), error))

        # 2. Deterministic token soup.
        random.seed(20261109)
        for index in range(400):
            text = ' '.join(random.choice(TOKENS) for _ in range(random.randint(1, 80)))
            path = root / f'token_soup_{index}.kyn'
            path.write_text(text)
            error = check_case(args.kync, path)
            counts['token_soup'] += 1
            if error:
                failures.append((str(path), error))

        # 3. Deterministic arbitrary bytes.
        random.seed(99)
        for index in range(200):
            data = bytes(random.randrange(256) for _ in range(random.randint(1, 200)))
            path = root / f'binary_{index}.kyn'
            path.write_bytes(data)
            error = check_case(args.kync, path)
            counts['binary'] += 1
            if error:
                failures.append((str(path), error))

    if failures:
        print('robustness corpus found failures:', file=sys.stderr)
        for path, error in failures:
            print(f'  {path}: {error}', file=sys.stderr)
        return 1

    total = sum(counts.values())
    print(f'robustness corpus: {total} cases ({counts["mutation"]} mutations, '
          f'{counts["token_soup"]} token soup, {counts["binary"]} binary)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
