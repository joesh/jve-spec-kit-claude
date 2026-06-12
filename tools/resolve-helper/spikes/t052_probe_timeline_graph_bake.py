#!/usr/bin/env python3
"""Spike: does TimelineItem.ExportLUT bake TIMELINE-level grades, and
does the timeline node graph expose its tools to scripting?

VERDICT DOWNGRADED by t053 (2026-06-11), then REFUTED by t054
(2026-06-12): this probe's instrument was render-inert — scripted
timeline-graph SetLUT reads back cleanly but never reaches stills,
gallery grabs, or queue renders — so the "ExportLUT IGNORES timeline
grades" result below was measured against a grade that never
rendered. Against a REAL (UI-authored) timeline grade, ExportLUT DOES
bake it (t054: 33pt bake reproduces the timeline-graded still to max
0.0023/channel). Q2 (scripting sees timeline-graph tools) stands.

Follow-on to t051 (group grades — H1, baked). The timeline node graph
(`Timeline.GetNodeGraph()`, README:400) applies to every clip and is
the remaining classification blind spot of the same shape
(helper-protocol.md §read_grades fidelity bullet). Two questions:

  Q1. Does the per-item ExportLUT cube include the timeline grade?
      yes → classification fix mirrors the group one (timeline tools ⇒
            every item bake-eligible; existing LUT carrier covers it).
      no  → timeline grades cannot be carried per-item — JVE must at
            least warn that the displayed look is incomplete.
  Q2. Do Graph.GetToolsInNode / Graph.GetLUT on the timeline graph
      report what's there? (Decides what classification can SEE.)
      Already half-answered on the gold fixture: its timeline graph
      reports ['OFX: DCTL'] + ['Sizing'] — the very DCTL whose
      missing-file modal wedged the 2026-06-11 probe runs. Scripting
      sees timeline-level tools.

Method: DUPLICATE the gold timeline and mutate only the throwaway
duplicate (a fresh CreateEmptyTimeline starts with a 0-node timeline
graph and Graph.SetLUT refuses on it — observed on the second probe
run; the duplicate inherits the gold's 2-node graph, so there is a
node to set a LUT on). Place the stock Kodak 2383 on the duplicate's
timeline-graph node 1, ExportLUT its first V1 item before/after, diff
(deterministic-baseline gate as in t051). Cleanup deletes the
duplicate and restores the current timeline + page; every step
reports. The gold timeline itself is never mutated.

STATE-CHANGING (creates/deletes a probe timeline, switches current
timeline + page) — run against the VM Resolve Studio via
scripts/run_timeline_graph_probe.sh, never against a host Resolve
holding real work.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/resolve-helper

from resolve_handle import ResolveHandle  # noqa: E402
from spikes.cube_util import cubes_identical, sample_gray  # noqa: E402

PROBE_TIMELINE = "jve-t052-probe"
WORK_DIR = "/tmp/jve-t052"
BASELINE_CUBE = os.path.join(WORK_DIR, "baseline.cube")
BASELINE2_CUBE = os.path.join(WORK_DIR, "baseline2.cube")
TLGRADED_CUBE = os.path.join(WORK_DIR, "timeline_graded.cube")
STOCK_LUT = ("/Library/Application Support/Blackmagic Design/"
             "DaVinci Resolve/LUT/Film Looks/DCI-P3 Kodak 2383 D60.cube")


def main():
    os.makedirs(WORK_DIR, exist_ok=True)
    if not os.path.isfile(STOCK_LUT):
        raise RuntimeError(f"stock LUT missing on this machine: {STOCK_LUT}")

    handle = ResolveHandle()
    status = handle.acquire()
    if status[0] != "ok":
        raise RuntimeError(f"acquire failed: {status!r}")
    _, resolve, project = status

    gold = project.GetCurrentTimeline()
    if gold is None:
        raise RuntimeError("no current timeline in VM Resolve — open one first")
    print(f"current timeline: {gold.GetName()}")

    # Q2 documentation pass (read-only): what the gold timeline's graph
    # reports. The 2026-06-11 first run refused here — node 1 carries
    # the MONO-Balance DCTL whose missing file is the modal source.
    gold_graph = gold.GetNodeGraph()
    if gold_graph:
        n = gold_graph.GetNumNodes()
        print(f"gold timeline graph nodes: {n}")
        for i in range(1, (n or 0) + 1):
            print(f"  node {i}: tools={gold_graph.GetToolsInNode(i)!r}")

    pool = project.GetMediaPool()
    probe_tl = gold.DuplicateTimeline(PROBE_TIMELINE)
    print(f"DuplicateTimeline({PROBE_TIMELINE!r}): {probe_tl is not None}")
    if probe_tl is None:
        raise RuntimeError("timeline duplication failed (name collision "
              "from an earlier run? delete it in Resolve and re-run)")

    prior_page = resolve.GetCurrentPage()
    print(f"GetCurrentPage at start: {prior_page!r}")
    rc = 1
    try:
        ok = project.SetCurrentTimeline(probe_tl)
        print(f"SetCurrentTimeline(probe): {ok}")
        if not ok:
            return 1
        dup_items = probe_tl.GetItemListInTrack("video", 1) or []
        if not dup_items:
            raise RuntimeError("duplicate's V1 has no items")
        item = dup_items[0]
        print(f"probe item: {item.GetName()!r}")

        tl_graph = probe_tl.GetNodeGraph()
        if tl_graph is None:
            print("RESULT: probe timeline has no node graph — cannot "
                  "place a timeline grade via scripting; inconclusive")
            return 1
        n = tl_graph.GetNumNodes()
        print(f"probe timeline graph nodes (pre-color-page): {n}")

        ok = resolve.OpenPage("color")
        page_now = resolve.GetCurrentPage()
        print(f"OpenPage('color'): {ok}, page now: {page_now!r}")
        if page_now != "color":
            raise RuntimeError("Color page switch did not take (modal "
                  "blocking?) — dismiss in the VM Resolve and re-run")

        # A fresh timeline's graph reports 0 nodes (observed on the
        # first throwaway run); the Color page may materialize node 1
        # when it first shows a graph. Re-read after the switch.
        n = tl_graph.GetNumNodes()
        print(f"probe timeline graph nodes (on color page): {n}")

        # Baseline bakes BEFORE any timeline grade is placed.
        ok = item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, BASELINE_CUBE)
        print(f"baseline ExportLUT: {ok}")
        if not ok or not os.path.isfile(BASELINE_CUBE):
            raise RuntimeError("baseline bake failed — cannot compare")
        ok = item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, BASELINE2_CUBE)
        print(f"baseline ExportLUT (repeat): {ok}")
        if not ok or not cubes_identical(BASELINE_CUBE, BASELINE2_CUBE):
            raise RuntimeError("repeated baseline bakes differ — "
                  "identical-vs-different verdict unavailable")
        print("baseline determinism: OK")

        # Place the probe grade on the inherited graph's node 1
        # (carries the inert missing-DCTL OFX on the VM; adding a LUT
        # to it is fine — the duplicate is a throwaway).
        ok = tl_graph.SetLUT(1, STOCK_LUT)
        print(f"probe timeline graph SetLUT(1, Kodak 2383): {ok}, "
              f"nodes now: {tl_graph.GetNumNodes()}")
        if not ok:
            print("RESULT: SetLUT refused on the duplicate's timeline "
                  "graph — Q1 inconclusive via scripting")
            return 1
        # Q2 on the probe graph: what scripting sees after the set.
        print(f"Q2 after SetLUT: tools={tl_graph.GetToolsInNode(1)!r} "
              f"lut={tl_graph.GetLUT(1)!r}")

        ok = item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, TLGRADED_CUBE)
        print(f"timeline-graded ExportLUT: {ok}")
        if not ok or not os.path.isfile(TLGRADED_CUBE):
            print("RESULT Q1: bake FAILED outright with a timeline "
                  "grade present — treat as not-baked")
            return 1

        print("\nprobe  baseline            timeline-graded")
        for v in (0.25, 0.5, 0.75):
            base = sample_gray(BASELINE_CUBE, v)
            tlg = sample_gray(TLGRADED_CUBE, v)
            print(f"g{v:<5} ({base[0]:.3f} {base[1]:.3f} {base[2]:.3f})"
                  f"   ({tlg[0]:.3f} {tlg[1]:.3f} {tlg[2]:.3f})")
        if cubes_identical(BASELINE_CUBE, TLGRADED_CUBE):
            print("\nRESULT Q1: ExportLUT IGNORES timeline-level grades "
                  "(cube identical to deterministic baseline)")
        else:
            print("\nRESULT Q1: ExportLUT BAKES timeline-level grades "
                  "(cube differs from deterministic baseline)")
        rc = 0
    finally:
        # Cleanup — every step reports; failures leave the VM project
        # dirty and MUST be visible.
        ok = project.SetCurrentTimeline(gold)
        print(f"cleanup SetCurrentTimeline(gold): {ok}")
        ok = pool.DeleteTimelines([probe_tl])
        print(f"cleanup DeleteTimelines(probe): {ok}")
        if prior_page is not None:
            try:
                resolve.OpenPage(prior_page)
                print(f"cleanup page restore to {prior_page!r}: "
                      f"{resolve.GetCurrentPage() == prior_page}")
            except Exception as exc:
                print(f"cleanup page restore RAISED: {exc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
