#!/usr/bin/env python3
"""Check local Markdown links and same-repository anchors."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SKIP_PARTS = {'.git', '.zig-cache', 'zig-out', 'build'}
LINK = re.compile(r'(?<!\\)!?\[[^\]]+\]\(([^)]+)\)')


def github_anchor(heading: str) -> str:
    heading = heading.strip()
    lowered = heading.lower()
    anchor = ''.join(ch for ch in lowered if ch.isalnum() or ch in (' ', '-', '_'))
    return anchor.replace(' ', '-')


def markdown_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob('*.md'):
        if any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts):
            continue
        files.append(path)
    return files


def headings(text: str) -> set[str]:
    anchors: set[str] = set()
    in_fence = False
    for line in text.splitlines():
        if line.strip().startswith('```'):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = re.match(r'^(#{1,6})\s+(.*)$', line)
        if match:
            raw = match.group(2).strip()
            plain = re.sub(r'<[^>]+>', '', raw)
            plain = re.sub(r'[*_`]', '', plain).strip()
            anchors.add(github_anchor(plain))
    return anchors


def main() -> int:
    files = markdown_files()
    anchors = {path.resolve(): headings(path.read_text()) for path in files}
    failures: list[str] = []

    for path in files:
        text = path.read_text()
        in_fence = False
        for line_number, line in enumerate(text.splitlines(), start=1):
            if line.strip().startswith('```'):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for match in LINK.finditer(line):
                target = match.group(1).split()[0]
                if target.startswith(('http://', 'https://', 'mailto:')):
                    continue
                target_path, anchor = (target.split('#', 1) + [''])[:2]

                resolved = path if not target_path else (path.parent / target_path).resolve()
                try:
                    resolved.relative_to(ROOT)
                except ValueError:
                    failures.append(f'{path.relative_to(ROOT)}:{line_number}: link escapes repository: {target}')
                    continue
                # Existence and anchors must be tested on the resolved absolute
                # path. Testing the repository-relative spelling made the result
                # depend on the caller's working directory: run from
                # `tests/integration`, every relative target looked missing.
                if not resolved.exists():
                    failures.append(f'{path.relative_to(ROOT)}:{line_number}: missing target: {target}')
                    continue
                if anchor and resolved.suffix.lower() == '.md':
                    generated = anchors.get(resolved, set())
                    if anchor not in generated:
                        failures.append(f'{path.relative_to(ROOT)}:{line_number}: missing anchor: {target}')

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    print(f'document links verified across {len(files)} Markdown files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
