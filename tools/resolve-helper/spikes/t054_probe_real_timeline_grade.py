#!/usr/bin/env python3
"""Spike t054: do REAL (UI-authored) timeline grades reach stills and
per-item ExportLUT bakes?

FINAL VERDICT (2026-06-12, VM live, Primary Offset hand-authored on
the gold timeline in the copied project): YES to both. Q-A: the
graded still differs from the source lattice (mean 0.073, max 0.176;
capture bit-deterministic) — ExportCurrentFrameAsStill carries real
timeline grades, so t053's lattice capture is production-viable.
Q-B: the 33pt ExportLUT bake of the ungraded lattice item reproduces
the graded still to max 0.0023/channel (bake-vs-identity stats match
still-vs-source almost exactly) — per-item bakes carry the timeline
grade; no new JVE carrier is needed. CDL extraction still does NOT
include it (the EDL CDL holds only the item's own primary), so the
read_grades warning narrows to CDL-only/carrier-less clips rather
than disappearing. Operational: ExportLUT refused from the edit page
and succeeded after OpenPage("color") — consistent with t033's
Color-page requirement.

Closes the question t053 left open: scripted timeline-graph writes are
render-inert (t053 FINAL VERDICT, e5d43f20), so neither t052's
"ExportLUT ignores timeline grades" nor the lattice capture path could
be judged against a grade that actually rendered. Joe has now hand-
authored an obvious timeline-level grade on a duplicate of the gold
timeline in the VM Resolve UI; this probe measures against THAT.

  Q-A. Does ExportCurrentFrameAsStill carry the real timeline grade?
       Method: append a fresh lattice item (17^3 patches, no clip
       grade) to the graded timeline, still-capture it, compare patch
       readback against the source lattice values. Any delta is the
       timeline graph's render contribution (the lattice item itself
       is ungraded; the inherited Sizing node is no-op and the missing
       DCTL is bypassed — t053).
       yes -> the t053 lattice capture is a production-viable carrier
              for timeline grades.
       no  -> still capture omits even real timeline grades; capture
              path is dead.
  Q-B. Does TimelineItem.ExportLUT bake the real timeline grade?
       Method: ExportLUT the same fresh lattice item (33pt). With no
       clip grade, the cube is identity unless the timeline grade is
       baked in. Judged two ways: distance from identity, and
       consistency with the Q-A still (trilerp(cube, src) vs still
       patches).
       yes -> per-item bakes already carry timeline grades — JVE needs
              NO new carrier; t052's warning can be retired.
       no  -> t052's verdict is reinstated, now proven against a real
              grade; JVE's "displayed look may be incomplete" warning
              stands.

Usage: pass the hand-graded timeline's name as argv[1]. Without it the
probe lists every timeline in the project (+ timeline-graph tools) and
exits 2 — discovery mode for finding the duplicate's exact name.

STATE-CHANGING (imports a lattice into the media pool, appends/removes
one item at the END of the hand-graded timeline, moves its playhead,
switches current timeline) — run against the VM Resolve Studio via
scripts/run_real_timeline_grade_probe.sh, never against a host Resolve
holding real work. The hand-authored grade itself is never touched.
"""
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/resolve-helper

from resolve_handle import ResolveHandle  # noqa: E402
from spikes.cube_util import load_cube, trilerp, cubes_identical  # noqa: E402
from spikes.t053_probe_timeline_lut_capture import (  # noqa: E402
    LATTICE_N, capture_still, frames_to_tc, patch_stats, patch_value,
    read_patches, write_lattice_png,
)

WORK_DIR = "/tmp/jve-t054"
LATTICE_PNG = os.path.join(WORK_DIR, "lattice.png")
BAKE_CUBE = os.path.join(WORK_DIR, "lattice_item_bake.cube")
BAKE2_CUBE = os.path.join(WORK_DIR, "lattice_item_bake2.cube")
VISIBLE = 2 / 255  # same visibility threshold as t053


def list_timelines(project):
    cur = project.GetCurrentTimeline()
    cur_name = cur.GetName() if cur else None
    count = project.GetTimelineCount()
    print(f"{count} timeline(s) in project:")
    for i in range(1, count + 1):
        tl = project.GetTimelineByIndex(i)
        name = tl.GetName()
        mark = "  <- current" if name == cur_name else ""
        print(f"  [{i}] {name!r}{mark}")
        try:
            dump_timeline_graph(tl, indent="      ")
        except Exception as exc:  # surfaced, per-timeline — listing
            print(f"      graph dump RAISED: {exc!r}")  # must complete


def dump_timeline_graph(timeline, indent="  "):
    graph = timeline.GetNodeGraph()
    if not graph:
        print(f"{indent}timeline graph: none")
        return
    n = graph.GetNumNodes() or 0
    print(f"{indent}timeline graph: {n} node(s)")
    for i in range(1, n + 1):
        print(f"{indent}  node {i}: tools={graph.GetToolsInNode(i)!r} "
              f"lut={graph.GetLUT(i)!r}")


def find_timeline(project, name):
    for i in range(1, project.GetTimelineCount() + 1):
        tl = project.GetTimelineByIndex(i)
        if tl.GetName() == name:
            return tl
    raise RuntimeError(f"timeline {name!r} not found in the project — "
                       f"re-run with no argument to list timelines")


def deterministic_capture(project, width, height, attempt=1):
    """Two stills must agree (graph re-evaluation is async — t053 run
    7/9); one loud settle-and-retry. Returns the patch readback."""
    a = os.path.join(WORK_DIR, f"graded_a{attempt}.png")
    b = os.path.join(WORK_DIR, f"graded_b{attempt}.png")
    if not (capture_still(project, a) and capture_still(project, b)):
        raise RuntimeError("still capture failed")
    pa, pb = (read_patches(p, width, height) for p in (a, b))
    mean, p95, mx = patch_stats(pa, pb)
    print(f"capture determinism (#{attempt}): mean={mean:.5f} "
          f"p95={p95:.5f} max={mx:.5f}")
    if mx <= VISIBLE:
        return pb
    if attempt == 1:
        print("capture transient — settling 3s and retrying")
        time.sleep(3)
        return deterministic_capture(project, width, height, attempt=2)
    raise RuntimeError("still capture non-deterministic after retry")


def bake_lattice_item(resolve, item):
    """ExportLUT the ungraded lattice item twice (determinism gate, as
    t052) and return the loaded cube. ExportLUT requires the Color
    page (t033, 2026-06-04; reconfirmed here — refused from the edit
    page on the first t054 run), so escalate there on refusal
    (caller's cleanup restores the page)."""
    def bake(path):
        ok = item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, path)
        print(f"ExportLUT -> {os.path.basename(path)} from page "
              f"{resolve.GetCurrentPage()!r}: {ok}")
        return ok and os.path.isfile(path)

    if not bake(BAKE_CUBE):
        if resolve.GetCurrentPage() == "color":
            raise RuntimeError("lattice-item ExportLUT failed on the "
                               "Color page")
        print("escalating to the Color page (ExportLUT refused)")
        resolve.OpenPage("color")
        if resolve.GetCurrentPage() != "color":
            raise RuntimeError("Color page switch did not take (modal "
                               "blocking? dismiss it in the VM, re-run)")
        if not bake(BAKE_CUBE):
            raise RuntimeError("lattice-item ExportLUT failed on the "
                               "Color page too")
    if not bake(BAKE2_CUBE):
        raise RuntimeError("repeat bake failed after the first "
                           "succeeded")
    if not cubes_identical(BAKE_CUBE, BAKE2_CUBE):
        raise RuntimeError("repeated bakes differ — verdict unavailable")
    print("bake determinism: OK")
    return load_cube(BAKE_CUBE)


def main():
    target_name = sys.argv[1] if len(sys.argv) > 1 else None

    # Fresh scratch dir — stale outputs would defeat verdicts (t053).
    if os.path.isdir(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR)

    handle = ResolveHandle()
    status = handle.acquire()
    if status[0] != "ok":
        raise RuntimeError(f"Resolve acquire failed: {status!r}")
    _, resolve, project = status

    if target_name is None:
        list_timelines(project)
        print("\nre-run with the hand-graded timeline's name as the "
              "argument")
        return 2

    target = find_timeline(project, target_name)
    fps = float(target.GetSetting("timelineFrameRate"))
    width = int(target.GetSetting("timelineResolutionWidth"))
    height = int(target.GetSetting("timelineResolutionHeight"))
    if abs(fps - round(fps)) >= 1e-6:
        raise RuntimeError(f"non-integer fps {fps} unsupported by probe")
    fps = int(round(fps))
    print(f"target: {target_name!r} {width}x{height}@{fps}")

    n_patches = write_lattice_png(LATTICE_PNG, width, height)
    print(f"lattice: {n_patches} patches ({LATTICE_N}^3)")

    pool = project.GetMediaPool()
    imported = pool.ImportMedia([LATTICE_PNG]) or []
    if not imported:
        raise RuntimeError("ImportMedia(lattice.png) returned nothing")
    mp_item = imported[0]

    prior_tl = project.GetCurrentTimeline()
    prior_page = resolve.GetCurrentPage()
    print(f"page at start: {prior_page!r}")
    item = None
    rc = 1
    try:
        if not project.SetCurrentTimeline(target):
            raise RuntimeError("SetCurrentTimeline(target) failed")
        dump_timeline_graph(target)  # document the hand-authored grade

        record = target.GetEndFrame() + 2 * fps
        appended = pool.AppendToTimeline([{
            "mediaPoolItem": mp_item,
            "startFrame": 0, "endFrame": 2 * fps - 1,
            "trackIndex": 1, "recordFrame": record, "mediaType": 1,
        }]) or []
        print(f"AppendToTimeline(lattice @ frame {record}): "
              f"{len(appended)} item(s)")
        if not appended:
            raise RuntimeError("lattice append failed")
        item = appended[0]
        mid = (item.GetStart() + item.GetEnd()) // 2
        if not target.SetCurrentTimecode(frames_to_tc(mid, fps)):
            raise RuntimeError("cannot park playhead on the lattice item")

        # ---- Q-A: still capture vs source lattice -------------------
        still = deterministic_capture(project, width, height)
        src = [tuple(c / 255 for c in patch_value(p))
               for p in range(n_patches)]
        mean, p95, mx = patch_stats(still, src)
        print(f"Q-A still vs source lattice: mean={mean:.5f} "
              f"p95={p95:.5f} max={mx:.5f}")
        still_graded = mx > VISIBLE
        print("RESULT Q-A: ExportCurrentFrameAsStill "
              + ("CARRIES the real timeline grade — t053's lattice "
                 "capture is a viable carrier"
                 if still_graded else
                 "OMITS even a real UI-authored timeline grade — the "
                 "capture path is dead"))

        # ---- Q-B: ExportLUT of the ungraded lattice item ------------
        size, data = bake_lattice_item(resolve, item)
        baked = [trilerp(size, data, *v) for v in src]
        ident = patch_stats(baked, src)
        print(f"Q-B bake vs identity: mean={ident[0]:.5f} "
              f"p95={ident[1]:.5f} max={ident[2]:.5f}")
        cons = patch_stats(baked, still)
        print(f"Q-B bake(source) vs graded still: mean={cons[0]:.5f} "
              f"p95={cons[1]:.5f} max={cons[2]:.5f}")
        bake_is_identity = ident[2] <= VISIBLE
        bake_matches_still = cons[2] <= 2 * VISIBLE
        if still_graded and bake_matches_still:
            print("RESULT Q-B: ExportLUT BAKES the real timeline grade "
                  "(cube reproduces the graded still) — per-item bakes "
                  "need no new carrier; retire the t052 warning")
        elif bake_is_identity:
            print("RESULT Q-B: ExportLUT IGNORES the real timeline "
                  "grade (cube is identity) — t052's verdict stands, "
                  "now proven against a UI-authored grade")
        else:
            print("RESULT Q-B: INCONCLUSIVE — bake is neither identity "
                  "nor consistent with the still; see stats above")
        rc = 0
    finally:
        # Cleanup — every step reports; failures leave the VM project
        # dirty and MUST be visible.
        if item is not None:
            ok = target.DeleteClips([item], False)
            print(f"cleanup DeleteClips(lattice item): {ok}")
        ok = pool.DeleteClips([mp_item])
        print(f"cleanup DeleteClips(pool lattice): {ok}")
        if prior_tl is not None:
            ok = project.SetCurrentTimeline(prior_tl)
            print(f"cleanup SetCurrentTimeline(prior): {ok}")
        if prior_page is not None:
            resolve.OpenPage(prior_page)
            print(f"cleanup page restore to {prior_page!r}: "
                  f"{resolve.GetCurrentPage() == prior_page}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
