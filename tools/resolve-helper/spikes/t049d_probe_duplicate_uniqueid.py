#!/usr/bin/env python3
"""T049d spike — does `Timeline:DuplicateTimeline()` preserve
`TimelineItem.GetUniqueId()` on the items?

Premise (spec 023, ConnectToResolveProject UX session 2026-06-03):
when the user runs Connect against a Resolve timeline that is a
*copy* of the originally-bound timeline (e.g. they duplicated to do
color work), JVE needs to recognize "this is a descendant" without
heuristics. T047 proved JVE `clip.id` (adopted from `Sm2Ti DbId` at
DRP import) equals `TimelineItem.GetUniqueId()` on the *original*
live timeline. If duplicate preserves item UniqueIds, then a simple
set-intersection of `{live timeline item UniqueIds}` ∩
`{JVE clip.ids in this sequence}` cleanly answers "descendant?" with
identity, no fingerprinting needed.

Procedure:
  1. Snapshot the currently-active timeline:
     {(track_type, track_index, record_start): item.GetUniqueId()}
  2. Call timeline.DuplicateTimeline("<probe_name>") via the API.
  3. Snapshot the duplicate's items, keyed the same way.
  4. Join on the position key and compare UniqueIds.
  5. Delete the duplicate (no side effects left in Joe's project).

The position key is unique within a timeline (Resolve enforces
non-overlap of media items on a track), and duplicate is a structural
copy so positions are preserved 1:1.

Usage:
    python3 tools/resolve-helper/spikes/t049d_probe_duplicate_uniqueid.py

Requires: Resolve Studio running with External Scripting enabled, a
project open with an active timeline that has at least a few video
items.
"""

from __future__ import annotations

import os
import sys


_DUP_TIMELINE_NAME = "JVE_T049d_probe_dup"


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


def _snapshot_video_items(timeline) -> dict[tuple[str, int, int], tuple[str, str]]:
    """{(track_type, track_index, record_start): (UniqueId, item_name)}.

    Video tracks only — the production matcher is V1-video-only too
    (FR-024). Audio support follows the same shape if the answer here
    is "preserved".
    """
    snap: dict[tuple[str, int, int], tuple[str, str]] = {}
    n = timeline.GetTrackCount("video")
    for tidx in range(1, n + 1):
        items = timeline.GetItemListInTrack("video", tidx) or []
        for item in items:
            uid = item.GetUniqueId()
            start = item.GetStart()
            name = item.GetName() or "(unnamed)"
            assert isinstance(uid, str) and uid, (
                f"track {tidx} item has empty UniqueId — API contract")
            assert isinstance(start, int), (
                f"track {tidx} item GetStart returned non-int: {start!r}")
            key = ("video", tidx, start)
            assert key not in snap, (
                f"duplicate position key {key} on a single timeline — "
                f"Resolve invariant violated")
            snap[key] = (uid, name)
    return snap


def _find_timeline_by_name(project, name: str):
    n = project.GetTimelineCount()
    for i in range(1, n + 1):
        tl = project.GetTimelineByIndex(i)
        if tl is not None and tl.GetName() == name:
            return tl
    return None


def main() -> int:
    resolve = _resolve_connect()
    project = resolve.GetProjectManager().GetCurrentProject()
    assert project is not None, "no current project in Resolve"
    print(f"project: {project.GetName()!r}")

    original = project.GetCurrentTimeline()
    assert original is not None, "no current timeline in Resolve"
    print(f"original: {original.GetName()!r} ({original.GetUniqueId()})")

    # Guard against running into a pre-existing probe leftover.
    # Resolve API quirk (verified 2026-06-03): DeleteTimelines lives on
    # MediaPool, NOT on Project — the latter only exposes render-related
    # Delete* methods. Confirmed by dir(project) vs dir(media_pool).
    media_pool = project.GetMediaPool()
    assert media_pool is not None, "project.GetMediaPool() returned None"

    existing = _find_timeline_by_name(project, _DUP_TIMELINE_NAME)
    if existing is not None:
        print(f"  (cleaning up leftover dup {_DUP_TIMELINE_NAME!r})")
        media_pool.DeleteTimelines([existing])

    before = _snapshot_video_items(original)
    print(f"original snapshot: {len(before)} video item(s)")
    assert len(before) > 0, (
        "original timeline has zero video items — pick a timeline with "
        "real content before running this probe")

    print(f"duplicating as {_DUP_TIMELINE_NAME!r}…")
    dup = original.DuplicateTimeline(_DUP_TIMELINE_NAME)
    assert dup is not None, (
        "DuplicateTimeline returned None — name collision or API failure")
    print(f"  duplicate: ({dup.GetUniqueId()})")
    assert dup.GetUniqueId() != original.GetUniqueId(), (
        "duplicate Timeline.GetUniqueId() == original — that would mean "
        "duplicate is not actually a separate entity")

    try:
        after = _snapshot_video_items(dup)
        print(f"duplicate snapshot: {len(after)} video item(s)")
        assert len(after) == len(before), (
            f"item count diverged across duplicate: "
            f"{len(before)} → {len(after)}")

        same = 0
        diff = 0
        sample_diff: list[str] = []
        for key, (orig_uid, name) in before.items():
            dup_uid, _ = after[key]
            if dup_uid == orig_uid:
                same += 1
            else:
                diff += 1
                if len(sample_diff) < 5:
                    sample_diff.append(
                        f"  V{key[1]} @ {key[2]}: {name!r} "
                        f"{orig_uid[:8]}… → {dup_uid[:8]}…")

        print()
        print(f"VERDICT: {same} preserved / {diff} changed (of {len(before)})")
        if diff == 0:
            print("→ DuplicateTimeline preserves TimelineItem.GetUniqueId().")
            print("  Signal A is viable: set-intersection of live item ids")
            print("  with JVE clip.ids cleanly identifies descendants.")
        else:
            print("→ DuplicateTimeline ASSIGNS NEW UniqueIds. Sample changes:")
            for line in sample_diff:
                print(line)
            print("  Signal A is NOT viable for unstamped sequences; the")
            print("  modal must rely on the position-match preview alone.")

    finally:
        print()
        print(f"cleanup: deleting {_DUP_TIMELINE_NAME!r}")
        # Resolve refuses to delete the current timeline — switch off it
        # first if we're sitting on the dup.
        cur = project.GetCurrentTimeline()
        if cur is not None and cur.GetUniqueId() == dup.GetUniqueId():
            project.SetCurrentTimeline(original)
        ok = media_pool.DeleteTimelines([dup])
        # Probe is read-intent; if cleanup fails Joe needs to know to
        # delete the dup manually so it doesn't pollute the project.
        if not ok:
            print(f"  WARNING: DeleteTimelines returned False — please "
                  f"delete {_DUP_TIMELINE_NAME!r} from Resolve manually.",
                  file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
