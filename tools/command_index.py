#!/usr/bin/env python3
"""Generate commands.json with explicit command style (direct vs registry)."""

import json
import re
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
IMPL_FILE = ROOT / "src/lua/core/command_implementations.lua"
REG_FILE = ROOT / "src/lua/core/command_registry.lua"
COMMANDS_DIR = ROOT / "src/lua/core/commands"
OUT_PATH = ROOT / "docs/symbol-index/commands.json"

def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")

def extract_modules(lua: str):
    m = re.search(r"command_modules\s*=\s*\{([\s\S]*?)\}", lua)
    blob = m.group(1) if m else lua
    mods = re.findall(r'["\']([a-z0-9_]+)["\']', blob)
    return list(dict.fromkeys(mods))

def extract_aliases(lua: str):
    aliases = {}
    for name in ("module_aliases", "aliases"):
        m = re.search(rf"{name}\s*=\s*\{{([\s\S]*?)\}}", lua)
        if not m:
            continue
        for k,v in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*['\"]([^'\"]+)['\"]", m.group(1)):
            if v.startswith("core.commands."):
                aliases[k] = v
    return aliases

def ep(lua: str, name: str) -> Optional[str]:
    pats = [
        rf"function\s+([\w\.]+)\.{name}\s*\(",
        rf"{name}\s*=\s*function\s*\(",
        rf"function\s+{name}\s*\(",
    ]
    for p in pats:
        m = re.search(p, lua)
        if m:
            return f"{m.group(1)}.{name}" if m.lastindex else name
    return None

def bind(lua: str, key: str) -> Optional[str]:
    m = re.search(rf"return\s*\{{[\s\S]*?{key}\s*=\s*([^,}}\n]+)", lua)
    return m.group(1).strip() if m else None

def scan(mod: str):
    f = COMMANDS_DIR / f"{mod}.lua"
    if not f.exists():
        return {"file":None,"execute_entrypoint":None,"undo_entrypoint":None,"redo_entrypoint":None,
                "executor_binding":None,"undoer_binding":None,"redoer_binding":None,"style":"unknown"}
    lua = read(f)
    ex = ep(lua,"execute")
    un = ep(lua,"undo")
    rd = ep(lua,"redo")
    eb = bind(lua,"executor")
    ub = bind(lua,"undoer")
    rb = bind(lua,"redoer")
    style = "direct" if ex else ("registry" if eb else "unknown")
    return {
        "file": str(f.relative_to(ROOT)),
        "execute_entrypoint": ex,
        "undo_entrypoint": un,
        "redo_entrypoint": rd,
        "executor_binding": eb,
        "undoer_binding": ub,
        "redoer_binding": rb,
        "style": style,
    }

mods = extract_modules(read(IMPL_FILE))
aliases = extract_aliases(read(REG_FILE)) if REG_FILE.exists() else {}

commands = []
for m in mods:
    info = scan(m)
    commands.append({"command":m,"module":f"core.commands.{m}",**info})

by_module = {c["module"]:c for c in commands}

for a,mp in aliases.items():
    t = by_module.get(mp)
    commands.append({
        "command":a,"module":mp,
        "file":t["file"] if t else None,
        "execute_entrypoint":t["execute_entrypoint"] if t else None,
        "undo_entrypoint":t["undo_entrypoint"] if t else None,
        "redo_entrypoint":t["redo_entrypoint"] if t else None,
        "executor_binding":t["executor_binding"] if t else None,
        "undoer_binding":t["undoer_binding"] if t else None,
        "redoer_binding":t["redoer_binding"] if t else None,
        "style":t["style"] if t else "unknown",
        "alias_of":mp,
    })

OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
OUT_PATH.write_text(json.dumps({"version":6,"commands":commands}, indent=2) + "\n")
print(f"Wrote {len(commands)} command entries to {OUT_PATH}")

