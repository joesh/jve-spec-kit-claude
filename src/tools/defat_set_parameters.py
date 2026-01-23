#!/usr/bin/env python3
"""
defat_set_parameters.py

Mechanical codemod:
- Adds/uses Command:set_parameters by collapsing consecutive cmd:set_parameter(...) runs into cmd:set_parameters({...}).
- Intended to reduce boilerplate without changing semantics.

Usage:
  python3 tools/defat_set_parameters.py path/to/lua/root

Notes:
- This script assumes :set_parameter is only defined on command objects (true in this codebase at time of writing).
- It only collapses runs where the var name and indentation are consistent.
"""
from __future__ import annotations
import sys
import re
from pathlib import Path

SET_LINE_RX = re.compile(r'^(\s*)(\w+)\s*:\s*set_parameter\(\s*([\'"][^\'"]+[\'"])\s*,\s*(.+?)\s*\)\s*$')

def collapse_sequences_in_text(text: str, min_len: int = 2, allow_blanks: bool = True) -> tuple[str, bool]:
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    changed = False

    while i < len(lines):
        m = SET_LINE_RX.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue

        indent, var = m.group(1), m.group(2)

        j = i
        items: list[tuple[str, str]] = []
        while j < len(lines):
            if allow_blanks and lines[j].strip() == "":
                j += 1
                continue

            m2 = SET_LINE_RX.match(lines[j])
            if m2 and m2.group(2) == var and m2.group(1) == indent:
                key_lit = m2.group(3).strip()
                expr = m2.group(4)
                key = key_lit[1:-1]  # strip quotes
                items.append((key, expr))
                j += 1
                continue

            break

        if len(items) >= min_len:
            out.append(f"{indent}{var}:set_parameters({{")
            inner = indent + "    "
            for key, expr in items:
                out.append(f'{inner}["{key}"] = {expr},')
            out.append(f"{indent}}})")
            changed = True
            i = j
            continue

        out.append(lines[i])
        i += 1

    return "\n".join(out) + "\n", changed

def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 tools/defat_set_parameters.py <lua_root_dir>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1]).resolve()
    if not root.exists():
        print(f"Not found: {root}", file=sys.stderr)
        return 2

    lua_files = [p for p in root.rglob("*.lua") if p.is_file()]
    changed_files = 0

    for p in lua_files:
        if "__MACOSX" in str(p):
            continue
        original = p.read_text(errors="ignore")
        rewritten, changed = collapse_sequences_in_text(original)
        if changed and rewritten != original:
            p.write_text(rewritten)
            changed_files += 1

    print(f"Changed files: {changed_files}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
