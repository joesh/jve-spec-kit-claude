#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys
from typing import List, Tuple

LICENSE_KEYWORDS = (
    "copyright",
    "permission is hereby granted",
    "apache license",
    "gnu general public license",
    "mit license",
    "bsd license",
)

HEADER_TEMPLATE = """--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~{loc} LOC
-- Volatility: unknown
--
-- @file {filename}
"""

def is_comment(line: str) -> bool:
    return line.lstrip().startswith("--")

def is_blank(line: str) -> bool:
    return line.strip() == ""

def looks_like_license(lines: List[str]) -> bool:
    blob = " ".join(l.lower() for l in lines)
    return any(k in blob for k in LICENSE_KEYWORDS)

def extract_header(lines: List[str]) -> Tuple[List[str], List[str]]:
    """
    Returns (header_lines, rest_of_file)
    Header is contiguous comment block at top (after optional shebang).
    """
    idx = 0
    header = []

    if lines and lines[0].startswith("#!"):
        header.append(lines[0])
        idx = 1

    while idx < len(lines):
        line = lines[idx]
        if is_comment(line) or is_blank(line):
            header.append(line)
            idx += 1
        else:
            break

    rest = lines[idx:]
    return header, rest

def compute_loc(lines: List[str]) -> int:
    count = 0
    for l in lines:
        if is_blank(l):
            continue
        if is_comment(l):
            continue
        count += 1
    return count

def normalize_file(path: pathlib.Path, dry_run: bool) -> bool:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    header, body = extract_header(lines)

    shebang = []
    header_comments = []

    if header and header[0].startswith("#!"):
        shebang = [header[0]]
        header_comments = header[1:]
    else:
        header_comments = header

    comment_lines = [l for l in header_comments if is_comment(l)]
    preserved_text = [l[2:].rstrip() for l in comment_lines if l.strip().startswith("--")]

    if preserved_text and looks_like_license(preserved_text):
        preserved_text = []

    loc = compute_loc(lines)

    new_header = []
    if shebang:
        new_header.extend(shebang)

    new_header.append(
        HEADER_TEMPLATE.format(
            loc=loc,
            filename=path.name
        )
    )

    if preserved_text:
        new_header.append("-- Original intent (unreviewed):\n")
        for l in preserved_text:
            if l.strip():
                new_header.append(f"-- {l.strip()}\n")
            else:
                new_header.append("--\n")

    new_text = "".join(new_header) + "".join(body)

    if new_text == text:
        return False

    if dry_run:
        print(f"[DRY-RUN] would update {path}")
    else:
        path.write_text(new_text, encoding="utf-8")
        print(f"[UPDATED] {path}")

    return True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--apply", action="store_true", help="Write changes (default is dry-run)")
    args = ap.parse_args()

    root = pathlib.Path(args.root)
    changed = 0

    for path in root.rglob("*.lua"):
        if normalize_file(path, dry_run=not args.apply):
            changed += 1

    print(f"\nFiles affected: {changed}")

if __name__ == "__main__":
    main()
