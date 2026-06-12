#!/usr/bin/env python3
"""Spike t055: does ExportLUT of a clip that HAS its own grade include
the timeline-level grade too (composition), and does
Graph.SetNodeEnabled actually work on a TIMELINE graph?

FINAL VERDICT (2026-06-12, VM live, run 6): YES to both. Q-A:
SetNodeEnabled(1, False) on the timeline graph made the lattice read
back the source exactly (mean 0.00000) and re-enable restored it —
timeline-graph enable-toggles ARE render-effective (unlike SetLUT /
ApplyGradeFromDRX writes, t053). Q-B: bake of the Kodak-graded item
with the timeline grade enabled tracks tl∘kodak to mean 0.00109 (vs
0.06973 for Kodak alone, 0.05975 for kodak∘tl) and matches the
composed still to mean 0.00099 — ExportLUT composes the clip grade
with the timeline grade, TIMELINE APPLIED AFTER the clip grade;
force-bake is sound. The tl_off control bake reproduced the Kodak
cube to max 0.00001. Operational discovery (runs 2-5 refusals): the
Color page must be OPENED while the playhead's current clip is valid
and online — opened on offline media or a gap, EVERY subsequent
ExportLUT refuses (for all items, parked or not) until the page is
re-opened in a good state. Offline media alone also refuses that
item's bake. Production read_grades is exposed to both.

t054 proved an UNGRADED item's bake carries the timeline grade. The
force-bake design (timeline tools OR into `any_non_cdl_tools`, so
every clip under a timeline grade is baked) additionally relies on a
GRADED item's bake composing clipGrade with the timeline grade — an
inference until now. Joe's hand-authored Primary Offset on the gold
timeline (copied VM project) makes it testable: bake a real graded
item with the timeline node enabled vs disabled and diff the cubes.

  Q-A. Does SetNodeEnabled(node, False) on a TIMELINE graph actually
       change the render? (t053 left this open — its toggle target
       was the bypassed missing-DCTL node, so no observable change
       was expected either way.) Verified via lattice still capture:
       disabled timeline grade => lattice reads back ~= source.
       If the toggle is render-inert (still reads graded), the probe
       STOPS — its instrument is broken, same trap t052 fell into.
  Q-B. Bake an item that has its OWN grade with the timeline node
       disabled (cube_off = clip grade alone) and enabled (cube_on).
       cube_on != cube_off => the bake of a graded item includes the
       timeline grade — composition holds and force-bake is sound.
       cube_on == cube_off => composition FAILS for graded items.
       The graded probe item is the LATTICE item carrying an
       item-level Kodak 2383 LUT set via scripting — render-effective
       (t053 Q1d control) and captured by bakes (t051) — NOT a real
       clip: runs 2-3 found every real clip in the copied VM project
       is OFFLINE on the guest (File Path /Users/joe/Local/Anamnesis/
       ..., absent) and ExportLUT REFUSES offline items regardless of
       playhead position. Using the freshly-imported (online) lattice
       item makes the probe media-independent, and the known Kodak
       cube + the Q-A capture of the timeline transform at every
       lattice point let the probe also measure composition ORDER
       (timeline applied after vs before the clip grade).

Usage: argv[1] = the graded timeline's name (discovery: run t054 with
no argument).

STATE-CHANGING (imports a lattice into the media pool, appends/removes
one item at the END of the graded timeline, toggles the timeline
grade node off and back ON, moves the playhead, switches current
timeline + page) — run against the VM Resolve Studio via
scripts/run_graded_item_bake_probe.sh, never against a host Resolve
holding real work. The finally re-enables the timeline node even on
failure; if the probe dies hard, re-enable node 1 of the timeline
graph in the VM Resolve UI.
"""
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/resolve-helper

from resolve_handle import ResolveHandle  # noqa: E402
from spikes.cube_util import cubes_identical, load_cube, trilerp  # noqa: E402
from spikes.t053_probe_timeline_lut_capture import (  # noqa: E402
    LATTICE_N, STOCK_LUT, capture_still, frames_to_tc, patch_stats,
    patch_value, read_patches, write_lattice_png,
)
from spikes.t054_probe_real_timeline_grade import (  # noqa: E402
    VISIBLE, find_timeline,
)

WORK_DIR = "/tmp/jve-t055"
LATTICE_PNG = os.path.join(WORK_DIR, "lattice.png")
TL_NODE = 1  # the hand-authored Primary Offset node (t054 graph dump)


def lattice_patches_now(project, width, height, tag):
    png = os.path.join(WORK_DIR, f"lattice_{tag}.png")
    if not capture_still(project, png):
        raise RuntimeError(f"still capture failed ({tag})")
    return read_patches(png, width, height)


def bake_item(resolve, item, tag):
    """Returns the cube path, or None on refusal (caller decides
    whether refusal is fatal)."""
    path = os.path.join(WORK_DIR, f"item_bake_{tag}.cube")
    ok = item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, path)
    print(f"ExportLUT({item.GetName()!r}) -> "
          f"{os.path.basename(path)}: {ok}")
    return path if ok and os.path.isfile(path) else None


def main():
    if len(sys.argv) < 2:
        raise RuntimeError("usage: t055 <graded-timeline-name> "
                           "(discovery: run t054 with no argument)")
    target_name = sys.argv[1]

    if os.path.isdir(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR)

    handle = ResolveHandle()
    status = handle.acquire()
    if status[0] != "ok":
        raise RuntimeError(f"Resolve acquire failed: {status!r}")
    _, resolve, project = status

    target = find_timeline(project, target_name)
    fps = float(target.GetSetting("timelineFrameRate"))
    width = int(target.GetSetting("timelineResolutionWidth"))
    height = int(target.GetSetting("timelineResolutionHeight"))
    if abs(fps - round(fps)) >= 1e-6:
        raise RuntimeError(f"non-integer fps {fps} unsupported by probe")
    fps = int(round(fps))
    print(f"target: {target_name!r} {width}x{height}@{fps}")

    n_patches = write_lattice_png(LATTICE_PNG, width, height)
    src = [tuple(c / 255 for c in patch_value(p))
           for p in range(n_patches)]

    pool = project.GetMediaPool()
    imported = pool.ImportMedia([LATTICE_PNG]) or []
    if not imported:
        raise RuntimeError("ImportMedia(lattice.png) returned nothing")
    mp_item = imported[0]

    prior_tl = project.GetCurrentTimeline()
    prior_page = resolve.GetCurrentPage()
    print(f"page at start: {prior_page!r}")
    lattice_item = None
    node_disabled = False
    tl_graph = None
    rc = 1
    try:
        if not project.SetCurrentTimeline(target):
            raise RuntimeError("SetCurrentTimeline(target) failed")
        tl_graph = target.GetNodeGraph()
        if tl_graph is None:
            raise RuntimeError("graded timeline has no node graph")
        print(f"timeline graph: {tl_graph.GetNumNodes()} node(s), "
              f"node {TL_NODE} tools="
              f"{tl_graph.GetToolsInNode(TL_NODE)!r}")

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
        lattice_item = appended[0]
        mid = (lattice_item.GetStart() + lattice_item.GetEnd()) // 2
        if not target.SetCurrentTimecode(frames_to_tc(mid, fps)):
            raise RuntimeError("cannot park playhead on the lattice item")

        # ExportLUT needs the Color page (t033) — and runs 4-5 vs t054
        # showed the OPEN ORDER matters: opening Color BEFORE the
        # lattice item existed (playhead on offline media / a gap)
        # left every ExportLUT refusing, while t054's open AFTER
        # append+park (Color loads the online lattice as its current
        # clip) baked fine. Mirror t054's order exactly.
        resolve.OpenPage("color")
        if resolve.GetCurrentPage() != "color":
            raise RuntimeError("Color page switch did not take (modal "
                               "blocking? dismiss it in the VM, re-run)")

        # ---- Q-A: does the timeline-node toggle change the render? --
        graded = lattice_patches_now(project, width, height, "on")
        mean, _, mx = patch_stats(graded, src)
        print(f"node ON, still vs source: mean={mean:.5f} max={mx:.5f}")
        if mx <= VISIBLE:
            raise RuntimeError("timeline grade not visible with node "
                               "enabled — wrong timeline?")

        ok = tl_graph.SetNodeEnabled(TL_NODE, False)
        node_disabled = True
        print(f"SetNodeEnabled({TL_NODE}, False): {ok}")
        time.sleep(2)  # graph re-eval is async (t053 run 7)
        off = lattice_patches_now(project, width, height, "off")
        mean_off, _, mx_off = patch_stats(off, src)
        print(f"node OFF, still vs source: mean={mean_off:.5f} "
              f"max={mx_off:.5f}")
        if mx_off > VISIBLE:
            print("RESULT Q-A: SetNodeEnabled on a TIMELINE graph is "
                  "RENDER-INERT (grade still visible) — instrument "
                  "unusable, Q-B not attempted; needs a manual toggle")
            return 1
        print("RESULT Q-A: SetNodeEnabled WORKS on a timeline graph "
              "(grade vanished from the still)")

        # ---- Q-B: graded item's bake, timeline node off vs on -------
        # The lattice item becomes the graded probe item: real clips
        # in the copy project are all offline on the guest and
        # ExportLUT refuses offline items (runs 2-3; playhead parking
        # irrelevant). Item-level SetLUT is render-effective (t053
        # Q1d) — verified again below before any verdict.
        kodak_size, kodak_data = load_cube(STOCK_LUT)
        kodak_pred = [trilerp(kodak_size, kodak_data, *v) for v in src]
        ok = lattice_item.SetLUT(1, STOCK_LUT)
        print(f"lattice item SetLUT(1, Kodak): {ok}, readback="
              f"{lattice_item.GetLUT(1)!r}")
        if not ok:
            raise RuntimeError("item-level SetLUT refused")
        time.sleep(2)
        item_only = lattice_patches_now(project, width, height,
                                        "item_only")
        mean_i, _, mx_i = patch_stats(item_only, kodak_pred)
        print(f"item grade live (still vs Kodak prediction, timeline "
              f"OFF): mean={mean_i:.5f} max={mx_i:.5f}")
        if mx_i > 2 * VISIBLE:
            raise RuntimeError("item LUT not rendering as Kodak — "
                               "instrument broken, no verdict")
        # Control bake (clip grade alone). Allowed to refuse without
        # killing the verdict — the Kodak cube file IS the clip-grade-
        # alone ground truth (the item_only still just verified it
        # renders as such). Runs 4-5 refused here, which turned out to
        # be the Color-page open-order gate (see docstring), fixed by
        # opening Color after append+park.
        cube_off = bake_item(resolve, lattice_item, "tl_off")
        if cube_off is None:
            print("note: tl_off bake refused; proceeding — Kodak file "
                  "is ground truth for the clip grade alone")
        else:
            size_off, data_off = load_cube(cube_off)
            off_pred = [trilerp(size_off, data_off, *v) for v in src]
            mean_b, _, mx_b = patch_stats(off_pred, kodak_pred)
            print(f"bake(tl_off) vs Kodak: mean={mean_b:.5f} "
                  f"max={mx_b:.5f}")

        ok = tl_graph.SetNodeEnabled(TL_NODE, True)
        print(f"SetNodeEnabled({TL_NODE}, True): {ok}")
        time.sleep(2)
        node_disabled = False
        composed = lattice_patches_now(project, width, height,
                                       "composed")
        _, _, mx_back = patch_stats(composed, kodak_pred)
        if mx_back <= VISIBLE:
            raise RuntimeError("timeline grade did not come back after "
                               "re-enable — CHECK THE VM: node "
                               f"{TL_NODE} may need manual re-enable")
        print("timeline grade re-enabled (still departed from "
              "Kodak-only)")
        cube_on = bake_item(resolve, lattice_item, "tl_on")
        if cube_on is None:
            raise RuntimeError("tl_on bake refused — t054 baked this "
                               "item shape with the node enabled; "
                               "no verdict")
        size_on, data_on = load_cube(cube_on)
        on_pred = [trilerp(size_on, data_on, *v) for v in src]

        # Verdict: cube_on against clip-grade-alone (Kodak) vs the two
        # composition orders. `graded` (Q-A capture) sampled the
        # timeline transform at every lattice point — the patch list
        # IS a 17pt cube (same r-fastest layout as load_cube data).
        # post = timeline applied AFTER the clip grade: tl(kodak(v));
        # pre  = timeline BEFORE the clip grade: kodak(tl(v)).
        alone_err = patch_stats(on_pred, kodak_pred)
        post_pred = [trilerp(LATTICE_N, graded, *kv) for kv in kodak_pred]
        pre_pred = [trilerp(kodak_size, kodak_data, *tv) for tv in graded]
        post_err = patch_stats(on_pred, post_pred)
        pre_err = patch_stats(on_pred, pre_pred)
        still_err = patch_stats(on_pred, composed)
        print(f"bake(tl_on) vs Kodak alone:  mean={alone_err[0]:.5f} "
              f"max={alone_err[2]:.5f}")
        print(f"bake(tl_on) vs tl∘kodak:     mean={post_err[0]:.5f} "
              f"max={post_err[2]:.5f}")
        print(f"bake(tl_on) vs kodak∘tl:     mean={pre_err[0]:.5f} "
              f"max={pre_err[2]:.5f}")
        print(f"bake(tl_on) vs composed still: mean={still_err[0]:.5f} "
              f"max={still_err[2]:.5f}")
        if alone_err[0] <= min(post_err[0], pre_err[0]):
            print("\nRESULT Q-B: bake matches the clip grade ALONE — "
                  "ExportLUT does NOT compose the timeline grade for "
                  "an item with its own grade; composition FAILS and "
                  "force-bake must not assume it")
        else:
            order = ("timeline AFTER clip grade (post)"
                     if post_err[0] < pre_err[0]
                     else "timeline BEFORE clip grade (pre)")
            print("\nRESULT Q-B: bake departs from the clip grade "
                  "alone and tracks the composed transform — ExportLUT "
                  "composes clip grade with the timeline grade; "
                  "force-bake is sound. Best-fit composition order: "
                  f"{order}")
        rc = 0
    finally:
        # Cleanup — every step reports. Re-enabling Joe's grade node is
        # the critical one; say so loudly if it fails.
        if node_disabled and tl_graph is not None:
            try:
                ok = tl_graph.SetNodeEnabled(TL_NODE, True)
                print(f"cleanup SetNodeEnabled({TL_NODE}, True): {ok}")
            except Exception as exc:
                print(f"cleanup re-enable RAISED: {exc} — RE-ENABLE "
                      f"NODE {TL_NODE} MANUALLY IN THE VM")
        if lattice_item is not None:
            ok = target.DeleteClips([lattice_item], False)
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
