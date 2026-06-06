#!/usr/bin/env python3
"""T049c spike — does the DRP's `Sm2Timeline DbId` equal the live
scripting API's `Timeline.GetUniqueId()`?

Premise (spec 023, ConnectToResolveProject session 2026-06-03): JVE
needs to bind a JVE sequence to a specific Resolve timeline so the
position matcher can't silently fire false positives against whatever
timeline happens to be open in Resolve's UI. The DRP carries
`Sm2Timeline DbId` per timeline (drp_importer.lua:1076 currently
drops it); the live API exposes `Timeline.GetUniqueId()`. T047 proved
that for fresh exports `Sm2Ti DbId == TimelineItem.GetUniqueId()` at
the *item* level (inbound-findings.md:18). This spike answers the
analogous question at the *timeline* level.

If equal → the DRP importer can adopt `Sm2Timeline DbId` directly as
the JVE sequence's `resolve_timeline_id`, and ConnectToResolveProject
can verify the live API's `GetUniqueId()` against it.

If not equal → first-connect binding is the only safe path (helper
returns the live id; JVE persists on first successful connect).

Usage:
    python3 tools/resolve-helper/spikes/t049c_probe_timeline_dbid.py <drp_path>

Resolve project side: uses whatever's currently open (mirrors how
ConnectToResolveProject works in production — there's no project
selector on the helper). The DRP must have been exported from the
currently-open project for the comparison to be meaningful.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# ─── DRP side ─────────────────────────────────────────────────────────

def _extract_drp(drp_path: str) -> Path:
    tmp = Path(tempfile.mkdtemp(prefix="t049c_drp_"))
    subprocess.run(
        ["unzip", "-q", drp_path, "-d", str(tmp)],
        check=True,
    )
    return tmp


# Resolve emits namespace-style tag names like `ListMgt::LmVersionTable`
# which Python's stdlib ET rejects as invalid tokens. The production
# importer uses qt_xml_parse (more permissive). For this spike we only
# need two fields per timeline (DbId attr + child <Name>), so a regex
# pass is exact and avoids dragging in lxml as a spike dependency.
# Per drp_importer.lua:1019, <Name> is a DIRECT child of <Sm2Timeline>
# but not necessarily the FIRST child — Resolve puts <FieldsBlob/>
# before it. Accept any siblings in between, but stop at the first
# nested <Sm2Timeline> (defensive — Resolve doesn't nest timelines,
# but if it ever did we'd want each pair attributed to its own DbId,
# not to the outer one's Name).
_SM2_TIMELINE_RE = re.compile(
    r'<Sm2Timeline\s+DbId="([0-9a-fA-F-]+)"[^>]*>'
    r'(?:(?!<Sm2Timeline\b).)*?'
    r'<Name>([^<]+)</Name>',
    re.DOTALL,
)


def _parse_drp_timelines(drp_path: str) -> list[tuple[str, str]]:
    """Returns [(timeline_name, Sm2Timeline.DbId), ...].

    Walks every MpFolder.xml under MediaPool/, regex-extracts each
    `<Sm2Timeline DbId="..."><Name>...</Name>` pair. Mirrors the fields
    drp_importer.lua:1013 (extract_timeline_metadata) reads — same DbId
    attr and first-child Name element.
    """
    tmp = _extract_drp(drp_path)
    try:
        out: list[tuple[str, str]] = []
        seen_db_ids: set[str] = set()
        mp_dir = tmp / "MediaPool"
        if not mp_dir.exists():
            raise SystemExit(
                f"DRP has no MediaPool/ dir at {tmp} — not a valid Resolve "
                f"project archive?")
        for mp_xml in mp_dir.rglob("MpFolder.xml"):
            text = mp_xml.read_text(encoding="utf-8", errors="replace")
            for m in _SM2_TIMELINE_RE.finditer(text):
                db_id = m.group(1)
                name = m.group(2).strip()
                if not name:
                    continue
                if db_id in seen_db_ids:
                    continue
                seen_db_ids.add(db_id)
                out.append((name, db_id))
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ─── Live Resolve side (pattern from t008_probe.py) ───────────────────

def _resolve_connect():
    api_dir = os.environ.get("RESOLVE_SCRIPT_API") or (
        "/Library/Application Support/Blackmagic Design/"
        "DaVinci Resolve/Developer/Scripting"
    )
    lib = os.environ.get("RESOLVE_SCRIPT_LIB") or (
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/"
        "Contents/Libraries/Fusion/fusionscript.so"
    )
    modules = os.path.join(api_dir, "Modules")
    if modules not in sys.path:
        sys.path.insert(0, modules)
    os.environ["RESOLVE_SCRIPT_API"] = api_dir
    os.environ["RESOLVE_SCRIPT_LIB"] = lib

    import DaVinciResolveScript as dvr  # type: ignore[import-not-found]
    resolve = dvr.scriptapp("Resolve")
    assert resolve is not None, (
        "scriptapp('Resolve') returned None — is Resolve Studio running with "
        "External Scripting (Local or Network) enabled in Preferences?")
    return resolve


def _live_timelines(project) -> list[tuple[str, str]]:
    """Returns [(timeline_name, Timeline.GetUniqueId()), ...]."""
    out: list[tuple[str, str]] = []
    n = project.GetTimelineCount()
    for i in range(1, n + 1):
        tl = project.GetTimelineByIndex(i)
        assert tl is not None, (
            f"GetTimelineByIndex({i}) returned None within "
            f"GetTimelineCount={n} — Resolve API contract violation")
        name = tl.GetName() or ""
        uid = tl.GetUniqueId() or ""
        assert name, f"timeline[{i}].GetName() returned empty"
        assert uid, f"timeline[{i}].GetUniqueId() returned empty"
        out.append((name, uid))
    return out


# ─── Driver ───────────────────────────────────────────────────────────

def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    drp_path = sys.argv[1]
    if not os.path.isfile(drp_path):
        raise SystemExit(f"DRP not found: {drp_path}")

    print(f"DRP:  {drp_path}")
    drp_timelines = _parse_drp_timelines(drp_path)
    print(f"      {len(drp_timelines)} timeline(s) extracted")

    resolve = _resolve_connect()
    project = resolve.GetProjectManager().GetCurrentProject()
    assert project is not None, "no current project in Resolve"
    print(f"Live: project {project.GetName()!r}")
    live_timelines = _live_timelines(project)
    print(f"      {len(live_timelines)} timeline(s) enumerated")

    drp_by_name = {n: d for n, d in drp_timelines}
    live_by_name = {n: u for n, u in live_timelines}
    all_names = sorted(set(drp_by_name) | set(live_by_name))

    print()
    print(f"{'TIMELINE':<40} {'DRP DbId':<40} {'LIVE UniqueId':<40} EQ")
    print("─" * 130)
    equal = 0
    diff = 0
    only_drp = 0
    only_live = 0
    for name in all_names:
        drp_id = drp_by_name.get(name)
        live_id = live_by_name.get(name)
        if drp_id and live_id:
            eq = (drp_id == live_id)
            equal += int(eq)
            diff += int(not eq)
            mark = "✓" if eq else "✗"
        elif drp_id:
            mark = "(drp only)"
            only_drp += 1
        else:
            mark = "(live only)"
            only_live += 1
        print(f"{name[:40]:<40} {(drp_id or '—'):<40} {(live_id or '—'):<40} {mark}")

    print()
    print(f"VERDICT: {equal} equal / {diff} different / "
          f"{only_drp} drp-only / {only_live} live-only "
          f"(of {len(all_names)} unique timeline names)")
    if diff == 0 and equal > 0 and only_drp == 0 and only_live == 0:
        print("→ Sm2Timeline.DbId == Timeline.GetUniqueId() — DRP importer can")
        print("  adopt the DbId directly as sequences.resolve_timeline_id.")
    else:
        print("→ NOT a clean match — first-connect binding is the safe path.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
