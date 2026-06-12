#!/usr/bin/env python3
"""Spike: does TimelineItem.ExportLUT bake COLOR-GROUP grades?

Background (2026-06-11, anamnesis frame 01:02:31:13): a clip whose whole
look lives in its color group's pre/post-clip graphs classified
fidelity="none" — read_grades inspects only the ITEM node graph + the
EDL CDL, both blind to group grades. The fix direction depends on one
empirical fact this spike answers:

  H1. ExportLUT bakes group pre/post-clip grades into the cube.
      → classification fix: group-with-tools ⇒ bake-eligible (never
        "none"); the existing LUT carrier covers it.
  H2. ExportLUT bakes only the item graph.
      → group grades need their own carrier (bigger design).

Method: on the SAME item, bake a baseline cube TWICE (determinism
gate), then assign the item to a fresh color group whose pre-clip
graph carries a stock Resolve LUT (Kodak 2383 — SetLUT only accepts
LUTs from Resolve's installed LUT tree; an arbitrary /tmp path returns
False, observed on the first probe run), bake again, and diff. Verdict
needs only identical-vs-different: identical ⇒ H2, different ⇒ H1.
Cleanup restores group-less state and the user's page; every step
reports.

STATE-CHANGING (group create/assign, page switch) — run against the VM
Resolve Studio via scripts/run_group_bake_probe.sh, never against a
host Resolve holding real work.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/resolve-helper

from resolve_handle import ResolveHandle  # noqa: E402
from spikes.cube_util import cubes_identical, sample_gray  # noqa: E402

GROUP_NAME = "jve-t051-probe"
WORK_DIR = "/tmp/jve-t051"
BASELINE_CUBE = os.path.join(WORK_DIR, "baseline.cube")
BASELINE2_CUBE = os.path.join(WORK_DIR, "baseline2.cube")
GROUPED_CUBE = os.path.join(WORK_DIR, "grouped.cube")
# SetLUT (item or graph) accepts only LUTs from Resolve's installed
# LUT tree — same constraint T034 hit; reuse its stock pick.
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

    timeline = project.GetCurrentTimeline()
    if timeline is None:
        raise RuntimeError("no current timeline in VM Resolve — open one first")
    print(f"timeline: {timeline.GetName()}")

    items = timeline.GetItemListInTrack("video", 1) or []
    if not items:
        raise RuntimeError("V1 has no items")
    item = items[0]
    print(f"item: {item.GetName()!r} uid={item.GetUniqueId()}")
    if item.GetColorGroup() is not None:
        raise RuntimeError("item already in a color group — refusing "
              "(cleanup could clobber fixture state)")

    prior_page = resolve.GetCurrentPage()
    print(f"GetCurrentPage at start: {prior_page!r}")
    if prior_page is None:
        # Observed 2026-06-11 on the VM: page None while the timeline
        # API still answers — likely a modal/Project Manager window in
        # front. Try explicit navigation and report what sticks.
        ok = resolve.OpenPage("edit")
        print(f"recovery OpenPage('edit'): {ok}, "
              f"page now: {resolve.GetCurrentPage()!r}")
        prior_page = resolve.GetCurrentPage()
        if prior_page is None:
            raise RuntimeError("Resolve reports no current page even after "
                  "OpenPage('edit') — a modal window is likely blocking "
                  "the VM Resolve UI; dismiss it and re-run")
    ok = resolve.OpenPage("color")
    print(f"OpenPage('color'): {ok}, page now: "
          f"{resolve.GetCurrentPage()!r}")
    cube_kind = resolve.EXPORT_LUT_33PTCUBE

    group = None
    rc = 1
    try:
        ok = item.ExportLUT(cube_kind, BASELINE_CUBE)
        print(f"baseline ExportLUT: {ok}")
        if not ok or not os.path.isfile(BASELINE_CUBE):
            raise RuntimeError("baseline bake failed — cannot compare")
        # Determinism gate: identical-vs-different is only meaningful
        # if two bakes of the SAME state agree.
        ok = item.ExportLUT(cube_kind, BASELINE2_CUBE)
        print(f"baseline ExportLUT (repeat): {ok}")
        if not ok or not cubes_identical(BASELINE_CUBE, BASELINE2_CUBE):
            raise RuntimeError("repeated baseline bakes differ — "
                  "identical-vs-different verdict unavailable")
        print("baseline determinism: OK")

        group = project.AddColorGroup(GROUP_NAME)
        print(f"AddColorGroup: {group is not None}")
        if group is None:
            return 1
        ok = item.AssignToColorGroup(group)
        print(f"AssignToColorGroup: {ok}")
        if not ok:
            return 1

        applied_on = None
        for label, getter in (("pre-clip", group.GetPreClipNodeGraph),
                              ("post-clip", group.GetPostClipNodeGraph)):
            graph = getter()
            n = graph.GetNumNodes() if graph else None
            print(f"group {label} graph nodes: {n}")
            if graph and n and n >= 1:
                ok = graph.SetLUT(1, STOCK_LUT)
                print(f"group {label} SetLUT(1, Kodak 2383): {ok}")
                if ok:
                    applied_on = label
                    break
        if applied_on is None:
            raise RuntimeError("could not place the probe LUT on either "
                  "group graph — inconclusive")

        ok = item.ExportLUT(cube_kind, GROUPED_CUBE)
        print(f"grouped ExportLUT: {ok}")
        if not ok or not os.path.isfile(GROUPED_CUBE):
            print("RESULT: grouped bake FAILED outright — ExportLUT "
                  "refuses items with (this) group grade; treat as H2")
            return 1

        print("\nprobe  baseline            grouped")
        for v in (0.25, 0.5, 0.75):
            base = sample_gray(BASELINE_CUBE, v)
            grp = sample_gray(GROUPED_CUBE, v)
            print(f"g{v:<5} ({base[0]:.3f} {base[1]:.3f} {base[2]:.3f})"
                  f"   ({grp[0]:.3f} {grp[1]:.3f} {grp[2]:.3f})")
        if cubes_identical(BASELINE_CUBE, GROUPED_CUBE):
            print("\nRESULT: H2 — ExportLUT ignores group grades "
                  "(grouped cube identical to deterministic baseline)")
        else:
            print("\nRESULT: H1 — ExportLUT BAKES group grades "
                  "(grouped cube differs from deterministic baseline)")
        rc = 0
    finally:
        # Cleanup — every step reports; failures leave the VM fixture
        # dirty and MUST be visible.
        if group is not None:
            ok = item.RemoveFromColorGroup()
            print(f"cleanup RemoveFromColorGroup: {ok}")
            ok = project.DeleteColorGroup(group)
            print(f"cleanup DeleteColorGroup: {ok}")
        try:
            resolve.OpenPage(prior_page)
            print(f"cleanup page restore to {prior_page!r}: "
                  f"{resolve.GetCurrentPage() == prior_page}")
        except Exception as exc:
            print(f"cleanup page restore RAISED: {exc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
