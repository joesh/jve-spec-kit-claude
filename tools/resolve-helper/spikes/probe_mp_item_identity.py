#!/usr/bin/env python3
"""Probe: which MediaPoolItem accessor returns the pool DbId that equals
JVE's `master.import_uuid` (== the DRP `Sm2MpVideoClip@DbId`)?

WHY: spec 023 content-match channel (discovery.match → match_by_content)
links a JVE clip to a live Resolve timeline item by SOURCE-CLIP identity.
JVE's identity is `master.import_uuid`, adopted on DRP import from the pool
clip's `Sm2MpVideoClip@DbId` and re-emitted outbound. For the inbound
channel to fire, `read_timeline` must return that SAME id per item. The
helper currently emits `MediaPoolItem.GetUniqueId()` as `import_uuid`
(verbs.py `_read_video_item`) on the HYPOTHESIS that GetUniqueId() == the
Sm2MpVideoClip@DbId. A pool clip also carries a child `UniqueMediaPoolItemId`
(phase0-findings.md §K1) which the JVE exporter mints fresh — if GetUniqueId
returns THAT instead, content_match silently never fires. This probe
settles it against a known DRP. No mock — real Resolve, real pool items.

HOW TO RUN (Joe, with Resolve Studio open + External Scripting enabled):

  1. Open a DRP in Resolve whose pool DbIds you can read, e.g.:
         unzip -p "tests/fixtures/resolve/synced clip example.drp" \
             '*MpFolder*' | rg -o 'Sm2MpVideoClip DbId="[^"]+"'
     (note the DbId values — these are what import_uuid adopts.)
  2. Open the imported timeline so it's the current timeline.
  3. Run:
         python3 tools/resolve-helper/spikes/probe_mp_item_identity.py [timeline_name]

  For every video timeline item it prints the source pool item's name +
  every candidate identity accessor. Cross-check which accessor's value
  matches a Sm2MpVideoClip@DbId from step 1.

VERDICT TO RECORD (in specs/023-resolve-color-bridge/phase0-findings.md):
  Which accessor == Sm2MpVideoClip@DbId. If GetUniqueId() is correct, the
  helper is already right. If a different accessor wins, change the one
  line in verbs.py `_read_video_item` (import_uuid = ...) to match.
"""

from __future__ import annotations

import os
import sys


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
        "External Scripting (Local or Network) enabled in Preferences?"
    )
    return resolve


def _current_or_named_timeline(project, timeline_name):
    if timeline_name is None:
        tl = project.GetCurrentTimeline()
        assert tl is not None, (
            "no current timeline — open the imported timeline first, or pass "
            "its name as an argument"
        )
        return tl
    n = project.GetTimelineCount()
    for i in range(1, n + 1):
        tl = project.GetTimelineByIndex(i)
        if tl is not None and tl.GetName() == timeline_name:
            return tl
    names = [project.GetTimelineByIndex(i + 1).GetName()
             for i in range(n) if project.GetTimelineByIndex(i + 1)]
    raise SystemExit(
        f"timeline '{timeline_name}' not found. Visible: {names!r}")


# Every plausibly-identity-bearing accessor on the source MediaPoolItem.
# We DON'T assume which one is the DbId — that's the question. Each is
# guarded so an absent accessor reports "absent", never crashes the probe.
def _candidates(mp):
    out = {}

    def _try(label, fn):
        try:
            out[label] = fn()
        except Exception as exc:  # noqa: BLE001 — probe wants every surface
            out[label] = f"<raised: {exc}>"

    _try("GetUniqueId()", lambda: mp.GetUniqueId())
    _try("GetMediaId()", lambda: mp.GetMediaId())
    _try("GetClipProperty('Unique ID')",
         lambda: mp.GetClipProperty("Unique ID"))
    _try("GetClipProperty('File Path')",
         lambda: mp.GetClipProperty("File Path"))
    _try("GetName()", lambda: mp.GetName())
    return out


def main(argv):
    timeline_name = argv[1] if len(argv) > 1 else None
    resolve = _resolve_connect()
    print(f"product: {resolve.GetProductName()} "
          f"{resolve.GetVersionString()}")

    project = resolve.GetProjectManager().GetCurrentProject()
    assert project is not None, "no current project open in Resolve"
    print(f"project: {project.GetName()}")

    timeline = _current_or_named_timeline(project, timeline_name)
    print(f"timeline: {timeline.GetName()}  "
          f"video-tracks={timeline.GetTrackCount('video')}\n")

    count = 0
    for ti in range(1, timeline.GetTrackCount("video") + 1):
        for item in (timeline.GetItemListInTrack("video", ti) or []):
            count += 1
            mp = item.GetMediaPoolItem()
            print(f"--- V{ti} item {item.GetName()!r}  "
                  f"GetUniqueId(item)={item.GetUniqueId()!r}")
            if mp is None:
                print("  (no source MediaPoolItem — non-media item)\n")
                continue
            for label, value in _candidates(mp).items():
                print(f"  MediaPoolItem.{label:34s} = {value!r}")
            print()

    print("=" * 64)
    print(f"{count} video item(s). Compare the accessor values above to the "
          "Sm2MpVideoClip@DbId values\nfrom the DRP (see header). The accessor "
          "that matches is the one verbs.py\n_read_video_item must emit as "
          "import_uuid. Record the verdict in phase0-findings.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
