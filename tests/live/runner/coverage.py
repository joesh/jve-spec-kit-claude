"""
coverage — static-analysis guards for the three test coverage axes.

Axis 1: every command in command_registry.lua + src/lua/core/commands/
        has a Command-tier test.
Axis 2: every (combo, scope) in keymaps/default.jvekeys has a Smoke test.
Axis 3: every menu item in menus.xml has a Smoke test.

Each axis exposes ``audit() -> list[str]`` returning a list of missing
entries. ``main()`` runs all three and exits non-zero if any returns
non-empty.

Hooked into ``make smoke-coverage`` and into CI.

Test discovery is name-pattern based:
- Command-tier: ``tests/command/test_<command_name_snake>.lua`` exists.
- Smoke (key):  any ``tests/live/cases/*.py`` mentions the combo string.
- Smoke (menu): any ``tests/live/cases/*.py`` mentions the command name
                in a ``menu_*`` test.
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[3]
KEYMAP_PATH      = REPO_ROOT / "keymaps" / "default.jvekeys"
REGISTRY_PATH    = REPO_ROOT / "src" / "lua" / "core" / "command_registry.lua"
COMMANDS_DIR     = REPO_ROOT / "src" / "lua" / "core" / "commands"
MENUS_PATH       = REPO_ROOT / "menus.xml"
COMMAND_TESTS    = REPO_ROOT / "tests" / "command"
SMOKE_CASES      = REPO_ROOT / "tests" / "live" / "cases"


# ─── parsing ────────────────────────────────────────────────────────────────


def list_registry_commands() -> set[str]:
    """Every command name reachable via command_registry — the alias table
    plus every snake_case file in commands/ that the auto-loader resolves."""
    names: set[str] = set()

    # 1. Aliases: lines of the form ``CommandName = "core.commands.<module>"``.
    alias_re = re.compile(r'^\s*(\w+)\s*=\s*"core\.commands\.', re.M)
    text = REGISTRY_PATH.read_text()
    names.update(alias_re.findall(text))

    # 2. Auto-loaded: snake_case file → CamelCase command name (the
    # auto-loader's convention). We surface the snake_case key here; the
    # registry resolves both spellings.
    for lua in COMMANDS_DIR.glob("*.lua"):
        stem = lua.stem
        if stem.startswith("_"):
            continue  # private helpers (e.g. _place_shared.lua)
        names.add(_snake_to_camel(stem))

    return names


def _snake_to_camel(snake: str) -> str:
    return "".join(p.capitalize() for p in snake.split("_"))


def _camel_to_snake(camel: str) -> str:
    out = []
    for i, c in enumerate(camel):
        if c.isupper() and i > 0 and not camel[i - 1].isupper():
            out.append("_")
        out.append(c.lower())
    return "".join(out)


# A (combo, scope) is uniquely identifying. scope=None means global.
class KeymapBinding:
    __slots__ = ("combo", "command", "scopes", "section")
    def __init__(self, combo: str, command: str, scopes: tuple[str, ...], section: str):
        self.combo = combo
        self.command = command
        self.scopes = scopes  # () == global
        self.section = section
    def __repr__(self) -> str:
        scope_str = "@" + "@".join(self.scopes) if self.scopes else "global"
        return f"{self.combo}={self.command}({scope_str})[{self.section}]"


def list_keymap_bindings() -> list[KeymapBinding]:
    """Parse keymaps/default.jvekeys.

    Format: ``[Section]`` headers, then ``"Combo" = "Command [args] [@scope ...]"``
    lines. Comments start with ``#``. Each binding is one line; scopes
    are tokens prefixed with ``@``.
    """
    bindings: list[KeymapBinding] = []
    section = ""
    line_re = re.compile(r'^\s*"([^"]+)"\s*=\s*"([^"]+)"\s*$')
    section_re = re.compile(r'^\s*\[([^\]]+)\]\s*$')

    for raw in KEYMAP_PATH.read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        sec = section_re.match(line)
        if sec:
            section = sec.group(1)
            continue
        m = line_re.match(line)
        if not m:
            continue
        combo, body = m.group(1), m.group(2)
        tokens = body.split()
        if not tokens:
            raise ValueError(f"empty binding body for {combo!r} in [{section}]")
        command = tokens[0]
        scopes = tuple(t[1:] for t in tokens[1:] if t.startswith("@"))
        bindings.append(KeymapBinding(combo, command, scopes, section))

    return bindings


class MenuItem:
    __slots__ = ("path", "command")
    def __init__(self, path: tuple[str, ...], command: str):
        self.path = path
        self.command = command
    def __repr__(self) -> str:
        return f"{'→'.join(self.path)}→{self.command}"


def list_menu_items() -> list[MenuItem]:
    """Parse menus.xml; return every leaf ``<item>`` with its menu path."""
    tree = ET.parse(MENUS_PATH)
    root = tree.getroot()
    out: list[MenuItem] = []

    def walk(elem: ET.Element, trail: tuple[str, ...]) -> None:
        for child in elem:
            if child.tag == "menu":
                name = child.get("name") or "?"
                walk(child, trail + (name,))
            elif child.tag == "item":
                cmd = child.get("command")
                name = child.get("name") or cmd or "?"
                if cmd:
                    out.append(MenuItem(trail + (name,), cmd))

    walk(root, ())
    return out


# ─── test discovery ─────────────────────────────────────────────────────────


def _smoke_cases_text() -> str:
    """Concatenated text of every Python file under tests/live/cases.

    Read once; cheap. Membership queries are substring/regex against this.
    """
    assert SMOKE_CASES.exists(), (
        f"coverage: SMOKE_CASES dir missing: {SMOKE_CASES} — "
        "audit would silently pass by finding zero smokes to match against")
    chunks = []
    for f in sorted(SMOKE_CASES.glob("**/*.py")):
        chunks.append(f.read_text())
    return "\n".join(chunks)


def _command_test_exists(command: str) -> bool:
    """A Command-tier test for ``command`` is any .lua file under
    ``tests/`` whose stem matches ``test_<snake>`` or ``test_<snake>_*``.

    Recognises the legacy variant-naming pattern (``test_extend_edit.lua``,
    ``test_extend_edit_redo.lua``, ``test_extend_edit_undo_selection.lua``).
    The Phase 1 reorg moves these to ``tests/command/`` but we accept both
    locations during the migration window.
    """
    snake = _camel_to_snake(command)
    prefix_dot = f"test_{snake}."
    prefix_us  = f"test_{snake}_"
    for tests_dir in (COMMAND_TESTS, REPO_ROOT / "tests"):
        if not tests_dir.exists():
            continue
        for f in tests_dir.glob("*.lua"):
            if f.name.startswith(prefix_dot) or f.name.startswith(prefix_us):
                return True
    return False


def _smoke_mentions(needle: str) -> bool:
    return needle in _smoke_cases_text_cache()


_smoke_text_cached = None  # Optional[str]; bare None keeps PEP 604 out of runtime parse


def _smoke_cases_text_cache() -> str:
    global _smoke_text_cached
    if _smoke_text_cached is None:
        _smoke_text_cached = _smoke_cases_text()
    return _smoke_text_cached


# ─── audits ────────────────────────────────────────────────────────────────


def audit_commands() -> list[str]:
    """Every registry command must have a Command-tier test."""
    missing = []
    for cmd in sorted(list_registry_commands()):
        if not _command_test_exists(cmd):
            missing.append(cmd)
    return missing


def audit_keymap() -> list[str]:
    """Every (combo, scope) must be referenced by some smoke test, OR
    appear in ``keymap_exempt.EXEMPT`` with an L1 reason. New bindings
    landing without a smoke test or an exemption fail the build."""
    from tests.live.runner.keymap_exempt import l1_exempt_reason
    missing = []
    for b in list_keymap_bindings():
        if l1_exempt_reason(b) is not None:
            continue
        # Match liberally: any smoke test that mentions the combo string.
        # Phase A binding tests are per-(combo, scope), so this is the
        # mechanical fingerprint.
        if not _smoke_mentions(f'"{b.combo}"') and not _smoke_mentions(f"'{b.combo}'"):
            missing.append(repr(b))
    return missing


def list_keymap_exemptions() -> list[tuple[str, str]]:
    """Audit-visible list of every active exemption. Returned as
    ``(binding_repr, reason)`` pairs sorted by binding repr. Used by
    the CLI report so a reader sees what's NOT being checked alongside
    what IS."""
    from tests.live.runner.keymap_exempt import l1_exempt_reason
    rows = []
    for b in list_keymap_bindings():
        reason = l1_exempt_reason(b)
        if reason is not None:
            rows.append((repr(b), reason))
    rows.sort()
    return rows


def audit_menus() -> list[str]:
    """Every menu item's command must be referenced by some smoke test
    whose filename contains 'menu' (so menu-specific coverage doesn't
    get spuriously satisfied by a keymap smoke that mentions the same
    command)."""
    assert SMOKE_CASES.exists(), (
        f"coverage: SMOKE_CASES dir missing: {SMOKE_CASES}")
    menu_text_parts = []
    for f in sorted(SMOKE_CASES.glob("**/menu_*.py")) + sorted(SMOKE_CASES.glob("**/test_menu_*.py")):
        menu_text_parts.append(f.read_text())
    menu_text = "\n".join(menu_text_parts)
    missing = []
    for item in list_menu_items():
        if item.command not in menu_text:
            missing.append(repr(item))
    return missing


# ─── CLI ────────────────────────────────────────────────────────────────────


def _report(axis: str, missing: Iterable[str]) -> bool:
    missing = list(missing)
    if not missing:
        print(f"  ✓ {axis}: complete")
        return True
    print(f"  ✗ {axis}: {len(missing)} missing")
    for m in missing[:30]:
        print(f"      {m}")
    if len(missing) > 30:
        print(f"      … and {len(missing) - 30} more")
    return False


def main() -> int:
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--axis", choices=("commands", "keymap", "menus", "all"),
                   default="all",
                   help="Run only one axis. 'keymap' is the one currently "
                        "wired into `make all` — the other axes are "
                        "informational until their EXEMPT lists are built.")
    p.add_argument("--show-exemptions", action="store_true",
                   help="Print every active L1 exemption with its reason. "
                        "Use to audit what isn't being covered.")
    args = p.parse_args()

    if args.show_exemptions:
        rows = list_keymap_exemptions()
        print(f"L1 exemptions ({len(rows)}):")
        for binding_repr, reason in rows:
            print(f"  {binding_repr}")
            print(f"      reason: {reason}")
        return 0

    print("Coverage audit:")
    results = []
    if args.axis in ("commands", "all"):
        results.append(_report(
            "Axis 1 (registered commands → Command-tier test)",
            audit_commands()))
    if args.axis in ("keymap", "all"):
        results.append(_report(
            "Axis 2 ((combo, scope) → Smoke test, minus EXEMPT)",
            audit_keymap()))
        # Surface the exemption count so a reader sees the EXEMPT list
        # is doing work — otherwise a green Axis 2 looks suspicious next
        # to a known-incomplete L3 surface.
        exempt_count = len(list_keymap_exemptions())
        if exempt_count:
            print(f"      ({exempt_count} L1-exempt; "
                  f"run --show-exemptions for the list)")
    if args.axis in ("menus", "all"):
        results.append(_report(
            "Axis 3 (menu item → Smoke test)",
            audit_menus()))
    return 0 if all(results) else 1


if __name__ == "__main__":
    # Support direct-script invocation (`python3 path/to/coverage.py`) as
    # well as module invocation (`python3 -m tests.live.runner.coverage`).
    # The Makefile uses the script form; smoke test cases that import
    # `keymap_exempt` use the module form. Both must work.
    if "tests.live.runner.coverage" not in sys.modules:
        sys.path.insert(0, str(REPO_ROOT))
    sys.exit(main())
