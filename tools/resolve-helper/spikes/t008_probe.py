#!/usr/bin/env python3
"""T008 spike — probe Resolve for the identity carriers seeded by
`t008_author_drt.lua`.

Run AFTER Joe imports `/tmp/jve/t008_identity.drt` into Resolve via
File > Import > Timeline...

Usage:
    python3 tools/resolve-helper/spikes/t008_probe.py [project_name]

Default project_name = 'JVE_T008_identity_spike'.

Output: for every timeline item, prints which sentinels (DBID/NAME/LIS)
the Resolve API exposed and whether each survived byte-clean. Verdict
prints at the end ('which carriers can be trusted for the join field').
"""

from __future__ import annotations

import os
import re
import sys


SENTINEL_RE = re.compile(r"^JVE_(DBID|NAME|LIS)_(\d+)$")
DEFAULT_PROJECT = "JVE_T008_identity_spike"
DEFAULT_TIMELINE = "JVE_T008_seq"


def _resolve_connect():
    """Mirror of `phase0-findings.md` §(a) connection mechanism.

    Asserts loudly if the env isn't set or the module won't load — the
    spike is useless without a live Resolve session.
    """
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
        "External Scripting (Local or Network) enabled in Preferences?"
    )
    return resolve


def _find_project(resolve, project_name: str):
    """Resolve API has no global 'find-project-by-name' — we walk the
    project manager. Fail-fast if not found; ambiguous nil hides the
    real bug ("did I import into the wrong db?")."""
    pm = resolve.GetProjectManager()
    current = pm.GetCurrentProject()
    if current is not None and current.GetName() == project_name:
        return current

    # Try LoadProject on the literal name — works when the project exists
    # but isn't the active one.
    loaded = pm.LoadProject(project_name)
    if loaded is not None:
        return loaded

    listed = pm.GetProjectListInCurrentFolder() or []
    raise SystemExit(
        f"project '{project_name}' not found in current folder. "
        f"Visible: {listed!r}. Did the DRP import land in a sub-folder, "
        f"or did Resolve auto-rename it on collision?"
    )


def _find_timeline(project, timeline_name: str):
    n = project.GetTimelineCount()
    for i in range(1, n + 1):
        tl = project.GetTimelineByIndex(i)
        if tl is not None and tl.GetName() == timeline_name:
            return tl
    names = [
        project.GetTimelineByIndex(i + 1).GetName()
        for i in range(n)
        if project.GetTimelineByIndex(i + 1) is not None
    ]
    raise SystemExit(
        f"timeline '{timeline_name}' not found in '{project.GetName()}'. "
        f"Visible: {names!r}."
    )


def _markers_with_carriers(item) -> list[str]:
    """Return any marker note/customData strings shaped like a sentinel."""
    markers = item.GetMarkers() or {}
    out = []
    for frame, m in markers.items():
        for field in ("note", "name", "customData"):
            val = m.get(field) if isinstance(m, dict) else None
            if isinstance(val, str) and SENTINEL_RE.match(val):
                out.append(f"frame={frame} {field}={val!r}")
    return out


def _read_carriers(item) -> dict[str, str | None]:
    """Pull every plausibly-identity-bearing string off a TimelineItem
    and classify each against the sentinel format.

    Resolve API surface used (all read-only):
      - GetName()                 → the visible item name
      - GetUniqueId()             → Resolve-internal item id (added in 18+)
      - GetSourceMediaPoolItem()  → upstream MediaPool item (then .GetUniqueId,
                                    .GetClipProperty)
      - GetMarkers()              → per-item markers (frame → fields)
    """
    name = item.GetName() if hasattr(item, "GetName") else None
    item_uid = item.GetUniqueId() if hasattr(item, "GetUniqueId") else None

    mp_uid = None
    mp_name = None
    mp = item.GetSourceMediaPoolItem() if hasattr(
        item, "GetSourceMediaPoolItem") else None
    if mp is not None:
        if hasattr(mp, "GetUniqueId"):
            mp_uid = mp.GetUniqueId()
        if hasattr(mp, "GetName"):
            mp_name = mp.GetName()

    return {
        "item.GetName()": name,
        "item.GetUniqueId()": item_uid,
        "MediaPoolItem.GetUniqueId()": mp_uid,
        "MediaPoolItem.GetName()": mp_name,
    }


def _classify(value: str | None) -> str:
    if value is None:
        return "absent"
    m = SENTINEL_RE.match(value.strip())
    if not m:
        return f"non-sentinel ({value!r})"
    return f"{m.group(1)}_{m.group(2)}"


def main(argv: list[str]) -> int:
    project_name = argv[1] if len(argv) > 1 else DEFAULT_PROJECT
    timeline_name = argv[2] if len(argv) > 2 else DEFAULT_TIMELINE

    resolve = _resolve_connect()
    print(f"product: {resolve.GetProductName()} {resolve.GetVersionString()}")

    project = _find_project(resolve, project_name)
    print(f"project: {project.GetName()}")
    timeline = _find_timeline(project, timeline_name)
    print(f"timeline: {timeline.GetName()}  tracks(video)="
          f"{timeline.GetTrackCount('video')}")

    items = []
    for ti in range(1, timeline.GetTrackCount("video") + 1):
        for it in (timeline.GetItemListInTrack("video", ti) or []):
            items.append((ti, it))

    print(f"\nfound {len(items)} timeline item(s) on video tracks")
    print()

    # Track per-carrier survival across all items: every item should have
    # one DBID_<n> sentinel and one NAME_<n> sentinel. LIS is writer-stubbed
    # (see t008_author_drt.lua) — its absence is expected.
    survival = {"DBID": 0, "NAME": 0, "LIS": 0}
    expected = len(items)

    for ti, item in items:
        print(f"--- track {ti} item: {item.GetName()!r}")
        carriers = _read_carriers(item)
        for field, value in carriers.items():
            cls = _classify(value)
            print(f"  {field:32s} = {cls}")
            m = SENTINEL_RE.match((value or "").strip())
            if m:
                survival[m.group(1)] = survival.get(m.group(1), 0) + 1

        marker_hits = _markers_with_carriers(item)
        if marker_hits:
            print(f"  markers carrying sentinels: {marker_hits}")
        else:
            print("  markers: (none with sentinel-shaped text)")
        print()

    print("=" * 60)
    print("Carrier survival across the timeline (writer emitted DBID + NAME; "
          "LIS is writer-stubbed):")
    for carrier in ("DBID", "NAME", "LIS"):
        n = survival[carrier]
        verdict = ("BYTE-CLEAN" if n == expected
                   else "writer-stubbed" if carrier == "LIS" and n == 0
                   else f"PARTIAL ({n}/{expected})" if n > 0
                   else "LOST")
        print(f"  {carrier}: {n}/{expected} items — {verdict}")
    print("=" * 60)
    print("\nRecord the result in specs/023-resolve-color-bridge/"
          "phase0-findings.md per T008.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
