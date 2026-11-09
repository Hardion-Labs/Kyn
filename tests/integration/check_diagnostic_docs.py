#!/usr/bin/env python3
"""Verify that documented diagnostic codes match the compiler sources."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE_CODE = re.compile(r'"([EW]0[0-9]{3})"')
DOC_CODE = re.compile(r'`([EW]0[0-9]{3})`')

source_codes: set[str] = set()
for path in (ROOT / 'compiler').rglob('*.zig'):
    source_codes.update(SOURCE_CODE.findall(path.read_text()))

doc_path = ROOT / 'docs' / 'diagnostics.md'
doc_codes = set(DOC_CODE.findall(doc_path.read_text()))

missing_docs = sorted(source_codes - doc_codes)
missing_source = sorted(doc_codes - source_codes)

if missing_docs or missing_source:
    if missing_docs:
        print('diagnostics used by the compiler but missing from docs/diagnostics.md:', file=sys.stderr)
        for code in missing_docs:
            print(f'  {code}', file=sys.stderr)
    if missing_source:
        print('diagnostics documented but unused by the compiler sources:', file=sys.stderr)
        for code in missing_source:
            print(f'  {code}', file=sys.stderr)
    sys.exit(1)

print(f'diagnostic documentation covers {len(source_codes)} codes')
