#!/usr/bin/env python3
"""T049e spike — does Resolve preserve `Timeline.GetUniqueId()` and
`TimelineItem.GetUniqueId()` across a DRP export → fresh-project import?

This is the *cross-session* probe T047 and T049c did NOT run. Both
prior spikes only compared a just-exported DRP against the still-open
session (same instance handles). Joe's actual workflow — import an old
DRP into a fresh Resolve project, then connect from JVE — is the case
neither probe touched. The refined T047 finding ("3/3 in same session")
does not address it; the original T047 finding ("0/1003 stale fixture")
also does not address it cleanly because it compared two unrelated
projects.

If preserved → adoption-on-import is sound for both timelines and items
(simplifies FR-011b/c, kills the marker-stamp channel as unnecessary,
lets the importer pre-fill `sequences.resolve_timeline_id`).

If NOT preserved → DbId is a runtime instance handle as the original
T047 claimed; importer must not pre-bind. Timelines need first-connect
binding (live id captured on first successful connect into the new
column). Items continue to need the marker channel.

Designed to be *trustworthy on a NO*:
  • DRP parsing uses the PRODUCTION qt_xml_parse via `jve --test`
    (companion script `t049e_parse_drp.lua`), not a regex. Direct trust
    transfer from the importer Joe relies on day-to-day.
  • Every record carries full provenance: file path, parent timeline
    name, position key. The intermediate JSON files at /tmp/ are
    hand-auditable; verdict prints sample diffs.
  • Joins are exact: timelines by name, items by
    (timeline_name, track_type, track_index, record_start) — the same
    key the production matcher uses.

Usage:
    # 1. Snapshot live state + export DRP (no UI action — Export is read-only):
    python3 tools/resolve-helper/spikes/t049e_probe_xsession_uniqueid.py snapshot

    # 2. Parse the exported DRP via production importer:
    ./build/bin/jve.app/Contents/MacOS/jve --test \\
        $(pwd)/tools/resolve-helper/spikes/t049e_parse_drp.lua

    # 3. STOP. In Resolve: File → Close Current Project. Then
    #    File → Import → Project Archive, pick /tmp/t049e_export.drp.
    #    Leave the new project open.

    # 4. Snapshot the post-import state + verdict:
    python3 tools/resolve-helper/spikes/t049e_probe_xsession_uniqueid.py verify
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


_BEFORE_LIVE = "/tmp/t049e_before_live.json"
_DRP_EXPORT  = "/tmp/t049e_export.drp"
_DRP_PARSED  = "/tmp/t049e_drp_parsed.json"
_AFTER_LIVE  = "/tmp/t049e_after_live.json"


# ─── Resolve connection (canonical pattern from t008/t049c/t049d) ────

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
        "scriptapp('Resolve') returned None — is Resolve Studio running "
        "with External Scripting enabled?")
    return resolve


def _snapshot_live(project) -> dict:
    """Walk every timeline; per timeline, every VIDEO item.

    Returns a JSON-serializable dict shaped like:
        {
          "project_name": str,
          "timelines": [
            {
              "name": str,
              "uid": str,                   # Timeline.GetUniqueId()
              "items": [
                {
                  "track_type": "video",
                  "track_index": int,       # 1-based
                  "record_start": int,      # GetStart()
                  "name": str,              # GetName() (provenance only)
                  "uid": str,               # TimelineItem.GetUniqueId()
                },
                ...
              ],
            },
            ...
          ],
        }

    Video-only mirrors production scope (FR-024 V1). Audio adds noise to
    the diff without changing the answer.
    """
    out = {"project_name": project.GetName(), "timelines": []}
    n_tl = project.GetTimelineCount()
    for i in range(1, n_tl + 1):
        tl = project.GetTimelineByIndex(i)
        assert tl is not None, f"GetTimelineByIndex({i}) returned None"
        tl_name = tl.GetName() or ""
        tl_uid  = tl.GetUniqueId() or ""
        assert tl_name, f"timeline[{i}].GetName() returned empty"
        assert tl_uid,  f"timeline[{i}].GetUniqueId() returned empty"

        items = []
        n_video = tl.GetTrackCount("video")
        for tidx in range(1, n_video + 1):
            for item in (tl.GetItemListInTrack("video", tidx) or []):
                start = item.GetStart()
                uid   = item.GetUniqueId()
                name  = item.GetName() or ""
                assert isinstance(start, int) and not isinstance(start, bool), (
                    f"item.GetStart() not int on {tl_name!r} V{tidx}: {start!r}")
                assert isinstance(uid, str) and uid, (
                    f"item.GetUniqueId() empty on {tl_name!r} V{tidx} @ {start}")
                items.append({
                    "track_type":   "video",
                    "track_index":  tidx,
                    "record_start": start,
                    "name":         name,
                    "uid":          uid,
                })

        out["timelines"].append({
            "name":  tl_name,
            "uid":   tl_uid,
            "items": items,
        })
    return out


def _export_drp(resolve, project, out_path: str) -> None:
    """Project archive export via ProjectManager.ExportProject.

    Pattern + version notes from t008_export_reference_drp.py: in
    Resolve 20.x ExportProject lives on ProjectManager (not Project),
    signature `(project_name, file_path, with_stills_and_luts)`.
    """
    pm = resolve.GetProjectManager()
    assert pm is not None, "GetProjectManager() returned None"
    # Remove any prior export from this probe so a partial write doesn't
    # mask a fresh failure (rule 2.13 — no silent reuse of stale state).
    if os.path.exists(out_path):
        os.remove(out_path)
    ok = pm.ExportProject(project.GetName(), out_path, False)
    assert ok, (
        f"ProjectManager.ExportProject({project.GetName()!r}, "
        f"{out_path!r}) returned False. Resolve typically refuses if the "
        f"path is unwritable or the project name has changed mid-export.")
    assert os.path.exists(out_path) and os.path.getsize(out_path) > 0, (
        f"ExportProject reported success but file is missing/empty: {out_path}")


# ─── Subcommand: snapshot ────────────────────────────────────────────

def cmd_snapshot() -> int:
    resolve = _resolve_connect()
    project = resolve.GetProjectManager().GetCurrentProject()
    assert project is not None, "no current project in Resolve"
    print(f"project: {project.GetName()!r}")

    live = _snapshot_live(project)
    n_items = sum(len(t["items"]) for t in live["timelines"])
    print(f"live snapshot: {len(live['timelines'])} timeline(s), "
          f"{n_items} video item(s)")
    Path(_BEFORE_LIVE).write_text(json.dumps(live, indent=2))
    print(f"  wrote {_BEFORE_LIVE}")

    print(f"exporting DRP → {_DRP_EXPORT}…")
    _export_drp(resolve, project, _DRP_EXPORT)
    print(f"  wrote {_DRP_EXPORT} ({os.path.getsize(_DRP_EXPORT):,} bytes)")

    print()
    print("NEXT:")
    print("  1. Parse the DRP via the production importer:")
    print("       ./build/bin/jve.app/Contents/MacOS/jve --test \\")
    print(f"           {os.path.abspath(os.path.dirname(__file__))}"
          f"/t049e_parse_drp.lua")
    print()
    print("  2. In Resolve: File → Close Current Project, then File →")
    print(f"     Import → Project Archive, pick {_DRP_EXPORT}. Leave open.")
    print()
    print("  3. python3 ./tools/resolve-helper/spikes/"
          "t049e_probe_xsession_uniqueid.py verify")
    return 0


# ─── Subcommand: verify ──────────────────────────────────────────────

def _load_json(path: str, what: str) -> dict:
    assert os.path.isfile(path), (
        f"verify: missing {what} at {path} — did you run the prior step?")
    return json.loads(Path(path).read_text())


def _join_timelines(drp: dict, live: dict) -> tuple[list, list, list]:
    """Returns (paired, drp_only, live_only) by timeline NAME.

    drp shape (from t049e_parse_drp.lua):
        { "timelines": [{ "name", "sm2timeline_dbid", "items": [
            { "track_type", "track_index", "record_start", "sm2ti_dbid" } ] }] }
    live shape (from _snapshot_live): { "timelines": [{ "name", "uid",
        "items": [{ "track_type", "track_index", "record_start", "uid" }] }] }
    """
    drp_by_name  = {t["name"]: t for t in drp["timelines"]}
    live_by_name = {t["name"]: t for t in live["timelines"]}
    paired, drp_only, live_only = [], [], []
    for name in sorted(set(drp_by_name) | set(live_by_name)):
        d = drp_by_name.get(name)
        l = live_by_name.get(name)
        if d and l:
            paired.append((name, d, l))
        elif d:
            drp_only.append(name)
        else:
            live_only.append(name)
    return paired, drp_only, live_only


def _join_items(d_items: list, l_items: list) -> tuple[list, list, list]:
    """Returns (paired, drp_only, live_only) by (track_type, track_index,
    record_start) within ONE timeline."""
    def key(it): return (it["track_type"], it["track_index"], it["record_start"])
    d_by_key = {key(it): it for it in d_items}
    l_by_key = {key(it): it for it in l_items}
    paired, drp_only, live_only = [], [], []
    for k in sorted(set(d_by_key) | set(l_by_key)):
        d = d_by_key.get(k); l = l_by_key.get(k)
        if d and l: paired.append((k, d, l))
        elif d:     drp_only.append(k)
        else:       live_only.append(k)
    return paired, drp_only, live_only


def cmd_verify() -> int:
    drp    = _load_json(_DRP_PARSED, "parsed DRP")
    before = _load_json(_BEFORE_LIVE, "before-snapshot")

    resolve = _resolve_connect()
    project = resolve.GetProjectManager().GetCurrentProject()
    assert project is not None, "no current project in Resolve"
    print(f"current project: {project.GetName()!r} "
          f"(was {before['project_name']!r} at snapshot time)")
    after = _snapshot_live(project)
    Path(_AFTER_LIVE).write_text(json.dumps(after, indent=2))
    print(f"  wrote {_AFTER_LIVE}")

    # Sanity guard: the imported project should NOT be the same instance
    # we exported from. Same name is OK (Resolve preserves it on import),
    # but if Joe forgot to close+reimport, the live ids will trivially
    # match for the wrong reason. Warn loudly.
    if before["project_name"] == after["project_name"]:
        same_uids = (
            len(before["timelines"]) == len(after["timelines"]) and
            all(b["uid"] == a["uid"]
                for b, a in zip(before["timelines"], after["timelines"])))
        if same_uids:
            print()
            print("⚠  WARNING: before and after live snapshots have IDENTICAL")
            print("   timeline uids in the same order. The project was likely")
            print("   NOT closed+reimported between snapshot and verify.")
            print("   The verdict below is meaningless until you do so.")
            print()

    print()
    print("═══ TIMELINES (joined by name) ═══")
    tl_paired, tl_drp_only, tl_live_only = _join_timelines(drp, after)
    print(f"{'NAME':<40} {'DRP Sm2Timeline DbId':<40} "
          f"{'LIVE Timeline.GetUniqueId':<40} EQ")
    print("─" * 130)
    tl_eq = tl_ne = 0
    for name, d, l in tl_paired:
        eq = d["sm2timeline_dbid"] == l["uid"]
        tl_eq += int(eq); tl_ne += int(not eq)
        mark = "✓" if eq else "✗"
        print(f"{name[:40]:<40} {d['sm2timeline_dbid']:<40} "
              f"{l['uid']:<40} {mark}")
    for name in tl_drp_only: print(f"{name[:40]:<40} (drp only)")
    for name in tl_live_only: print(f"{name[:40]:<40} (live only)")
    print()
    print(f"TIMELINE VERDICT: {tl_eq} equal / {tl_ne} different / "
          f"{len(tl_drp_only)} drp-only / {len(tl_live_only)} live-only "
          f"(of {len(tl_paired) + len(tl_drp_only) + len(tl_live_only)} names)")

    print()
    print("═══ ITEMS (joined by (timeline_name, track_type, "
          "track_index, record_start)) ═══")
    item_eq = item_ne = item_drp_only = item_live_only = 0
    sample_diffs: list[str] = []
    for name, d, l in tl_paired:
        ip, do, lo = _join_items(d["items"], l["items"])
        item_drp_only  += len(do)
        item_live_only += len(lo)
        for _k, di, li in ip:
            eq = di["sm2ti_dbid"] == li["uid"]
            item_eq += int(eq); item_ne += int(not eq)
            if not eq and len(sample_diffs) < 10:
                sample_diffs.append(
                    f"  {name!r} V{di['track_index']} @ {di['record_start']}: "
                    f"DRP={di['sm2ti_dbid'][:12]}…  LIVE={li['uid'][:12]}…")
    print(f"ITEM VERDICT: {item_eq} equal / {item_ne} different / "
          f"{item_drp_only} drp-only / {item_live_only} live-only")
    if sample_diffs:
        print("first divergent items (provenance: timeline name, track, "
              "record_start):")
        for line in sample_diffs: print(line)

    print()
    print("═══ INTERPRETATION ═══")
    if tl_ne == 0 and item_ne == 0 and tl_eq > 0 and item_eq > 0:
        print("→ Sm2Timeline.DbId == Timeline.GetUniqueId() AND")
        print("  Sm2Ti.DbId == TimelineItem.GetUniqueId() across the")
        print("  export → import cycle. Adoption-on-import is sound for")
        print("  both timelines and items. Marker-stamp channel is")
        print("  belt-and-suspenders, not load-bearing.")
        return 0
    if tl_ne == 0 and tl_eq > 0 and item_ne > 0:
        print("→ TIMELINES preserve their id; ITEMS do NOT.")
        print("  Plan: importer adopts Sm2Timeline DbId →")
        print("  sequences.resolve_timeline_id; items continue to need")
        print("  the marker channel (current FR-011c spec stands for items).")
        return 0
    if item_ne > 0 or tl_ne > 0:
        print("→ Id is NOT preserved across the cycle.")
        print("  Importer must not pre-bind. resolve_timeline_id is")
        print("  populated only on first successful connect. Marker channel")
        print("  remains mandatory for items.")
        return 0
    print("→ Indeterminate (no paired records). Probe setup issue —")
    print("  inspect the JSON files at /tmp/t049e_*.json by hand.")
    return 2


# ─── Driver ──────────────────────────────────────────────────────────

def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("snapshot", "verify"):
        print(__doc__)
        return 2
    if sys.argv[1] == "snapshot":
        return cmd_snapshot()
    return cmd_verify()


if __name__ == "__main__":
    sys.exit(main())
