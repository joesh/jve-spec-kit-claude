#!/usr/bin/env python3
"""T008 probe — read back Resolve's current timeline and report the
identity carriers (DbId, Name, GetUniqueId-or-equivalent) for every
timeline item. Joe runs this AFTER importing
tests/fixtures/resolve/jve_authored_single_clip.drp and switching to the
imported project in Resolve.

Goal: confirm that the JVE-written Sm2TiVideoClip DbId
(12345678-1234-4123-8123-1234567890ab) is what Resolve's Python API hands
back for the imported clip. If it does, FR-011b (adopt the Sm2Ti DbId as
clip.id, bidirectional) is empirically validated. If it does NOT, we
know Resolve mints fresh DbIds at import time and a separate persistence
ledger (clip_link table) is required."""
import os
import sys

try:
    import DaVinciResolveScript as dvr
except ImportError:
    api = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
    os.environ.setdefault("RESOLVE_SCRIPT_API", api)
    os.environ.setdefault(
        "RESOLVE_SCRIPT_LIB",
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/"
        "Contents/Libraries/Fusion/fusionscript.so")
    sys.path.insert(0, os.path.join(api, "Modules"))
    import DaVinciResolveScript as dvr


# Matches what t008_author.lua writes into
# tests/fixtures/resolve/jve_authored_single_clip.drp.
WANT_PROJECT = "single_clip"
WANT_TIMELINE = "single_clip"
WANT_DBID = "12345678-1234-4123-8123-1234567890ab"
WANT_NAME = "A005_C052_0925BL_001 — JVE-exported"


def main():
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        print("FAIL: cannot connect to Resolve (is it running with external "
              "scripting enabled?)")
        return 1
    pm = resolve.GetProjectManager()
    proj = pm.GetCurrentProject()
    print(f"current project: {proj.GetName()}")
    print(f"looking for imported timeline: '{WANT_TIMELINE}'")

    # Enumerate every timeline in the project and pick the one matching
    # the .drt's timeline name. The user can have any timeline open in the UI.
    count = proj.GetTimelineCount()
    print(f"\nproject has {count} timeline(s):")
    tl = None
    for i in range(1, count + 1):
        t = proj.GetTimelineByIndex(i)
        n = t.GetName()
        print(f"  [{i}] {n}")
        if n == WANT_TIMELINE:
            tl = t
    if tl is None:
        print(f"\nFAIL: timeline '{WANT_TIMELINE}' not found in current "
              f"project. Did you import "
              f"tests/fixtures/resolve/jve_authored_single_clip.drp "
              f"yet? (File > Import > Project...)")
        return 2
    print(f"\nprobing timeline: {tl.GetName()}")

    track_count = tl.GetTrackCount("video")
    print(f"\nvideo tracks: {track_count}")
    found_dbid_match = False
    for tidx in range(1, track_count + 1):
        items = tl.GetItemListInTrack("video", tidx) or []
        print(f"  V{tidx}: {len(items)} item(s)")
        for it in items:
            api_methods = [m for m in dir(it)
                           if not m.startswith("_") and "Id" in m]
            name = it.GetName()
            print(f"    name='{name}'  GetName()='{name}'")
            # Try every identity-shaped accessor the API exposes
            for m in api_methods:
                try:
                    v = getattr(it, m)()
                    print(f"      {m}() -> {v!r}")
                    if isinstance(v, str) and v == WANT_DBID:
                        found_dbid_match = True
                except Exception as e:
                    print(f"      {m}() -> error: {e}")

    print()
    if found_dbid_match:
        print("PASS: JVE-written DbId survived round-trip "
              f"(found {WANT_DBID} on imported clip)")
        return 0
    print(f"FAIL: JVE-written DbId {WANT_DBID} not found in any "
          "identity accessor on the imported clip — Resolve appears to "
          "mint fresh DbIds at import time; a clip_link ledger is required")
    return 2


if __name__ == "__main__":
    sys.exit(main())
