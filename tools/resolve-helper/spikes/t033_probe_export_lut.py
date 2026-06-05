#!/usr/bin/env python3
"""Spike: why does TimelineItem.ExportLUT return False for every Anamnesis clip?

Hypotheses tested:
  H1. Color page must be active. Try the same call with and without
      `resolve.OpenPage("color")` first.
  H2. The Anamnesis grade is mostly qualifiers / windows / OFX; Resolve
      may refuse to bake when the residual after dropping incompatibles
      is empty/identity. Sample a few items of varying complexity and
      compare.
  H3. App focus / sandboxing. Resolve in background may refuse certain
      operations. Reported but not testable from script alone.
  H4. Path issue (extension, dir permissions). Try multiple paths
      including tmpfile and a known-writable dir.

Run from a terminal while Resolve Studio is open with the Anamnesis
timeline loaded:

    /usr/bin/env python3 tools/resolve-helper/spikes/t033_probe_export_lut.py

Output: per-clip report with ExportLUT result + observed file state +
node-graph summary. Honest, no rationalization.
"""
import os
import sys
import tempfile

# Bootstrap matches resolve_handle.py.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/resolve-helper

from resolve_handle import ResolveHandle  # noqa: E402


def describe_graph(item):
    """Return a short summary of the node graph for an item."""
    try:
        graph = item.GetNodeGraph()
    except Exception as exc:
        return f"<GetNodeGraph raised: {exc}>"
    if graph is None:
        return "<no graph>"
    try:
        n = graph.GetNumNodes()
    except Exception as exc:
        return f"<GetNumNodes raised: {exc}>"
    tool_counts = {}
    for i in range(1, n + 1):
        try:
            tools = graph.GetToolsInNode(i) or []
        except Exception as exc:
            tools = [f"<raised {exc}>"]
        for t in tools:
            tool_counts[t] = tool_counts.get(t, 0) + 1
    return f"nodes={n} tools={tool_counts or '{}'}"


def try_export(item, lut_kind, kind_name, out_path, attempt_label):
    # Returns (rc, exists, size). rc is whatever ExportLUT returns.
    try:
        rc = item.ExportLUT(lut_kind, out_path)
    except Exception as exc:
        print(f"      [{attempt_label}] {kind_name} → raised "
              f"{type(exc).__name__}: {exc} path={out_path}")
        return (f"<raised {type(exc).__name__}: {exc}>", False, -1)
    exists = os.path.isfile(out_path)
    size = os.path.getsize(out_path) if exists else -1
    print(f"      [{attempt_label}] {kind_name} → rc={rc!r} "
          f"exists={exists} size={size} path={out_path}")
    return (rc, exists, size)


def main():
    h = ResolveHandle()
    status = h.acquire()
    if status[0] != "ok":
        print(f"FAIL: handle.acquire returned {status!r}")
        return 1
    _, resolve, project = status
    print(f"Connected. Resolve={resolve.GetProductName()!r} "
          f"version={resolve.GetVersionString()!r}")
    print(f"Project={project.GetName()!r}")

    tl = project.GetCurrentTimeline()
    if tl is None:
        print("FAIL: no current timeline. Open the Anamnesis timeline.")
        return 1
    print(f"Timeline={tl.GetName()!r}")

    # Take 5 video items from track 1; we don't need specific ones for
    # the spike — just enough variety to spot a pattern.
    items = tl.GetItemListInTrack("video", 1) or []
    if not items:
        print("FAIL: track 1 has no video items.")
        return 1
    sample = items[:5]
    print(f"\nSampling {len(sample)} items from V1 ({len(items)} total)\n")

    tmpdir = tempfile.mkdtemp(prefix="t033_probe_lut_")
    print(f"Output dir: {tmpdir}\n")

    # Cache the constant up-front so we know it resolves.
    try:
        cube_kind = resolve.EXPORT_LUT_33PTCUBE
        print(f"resolve.EXPORT_LUT_33PTCUBE = {cube_kind!r}")
    except AttributeError as exc:
        print(f"FAIL: resolve.EXPORT_LUT_33PTCUBE unavailable: {exc}")
        return 1

    # ── Pass 1: baseline (no OpenPage), each item, 33pt cube. ──────
    print("\n=== Pass 1: baseline (no OpenPage) ===")
    for idx, item in enumerate(sample):
        try:
            uid = item.GetUniqueId()
        except Exception:
            uid = f"<no-uid-{idx}>"
        print(f"  Item {idx}: uid={uid}")
        print(f"    graph: {describe_graph(item)}")
        out = os.path.join(tmpdir, f"p1_{idx}_{uid}.cube")
        try_export(item, cube_kind, "33pt", out, "p1-baseline")

    # ── Pass 2: OpenPage("color") first, same items. ───────────────
    print("\n=== Pass 2: OpenPage('color') then ExportLUT ===")
    try:
        opened = resolve.OpenPage("color")
        print(f"  resolve.OpenPage('color') → {opened!r}")
    except Exception as exc:
        print(f"  OpenPage raised: {exc}")
    for idx, item in enumerate(sample):
        try:
            uid = item.GetUniqueId()
        except Exception:
            uid = f"<no-uid-{idx}>"
        out = os.path.join(tmpdir, f"p2_{idx}_{uid}.cube")
        try_export(item, cube_kind, "33pt", out, "p2-color")

    # ── Pass 3: SetCurrentVideoItem before ExportLUT (per-item). ───
    print("\n=== Pass 3: timeline.SetCurrentVideoItem + ExportLUT ===")
    setter = getattr(tl, "SetCurrentVideoItem", None)
    if setter is None:
        print("  Timeline.SetCurrentVideoItem unavailable — skipping pass 3")
    else:
        for idx, item in enumerate(sample):
            try:
                uid = item.GetUniqueId()
            except Exception:
                uid = f"<no-uid-{idx}>"
            try:
                set_rc = setter(item)
            except Exception as exc:
                set_rc = f"<raised {exc}>"
            print(f"  Item {idx}: uid={uid} SetCurrentVideoItem → {set_rc!r}")
            out = os.path.join(tmpdir, f"p3_{idx}_{uid}.cube")
            try_export(item, cube_kind, "33pt", out, "p3-current")

    # ── Pass 4: 17pt + 65pt + VLUT on the first item, baseline. ────
    print("\n=== Pass 4: alternate LUT kinds (item 0) ===")
    item0 = sample[0]
    for attr in ("EXPORT_LUT_17PTCUBE", "EXPORT_LUT_65PTCUBE",
                 "EXPORT_LUT_PANASONICVLUT"):
        try:
            kind = getattr(resolve, attr)
        except AttributeError as exc:
            print(f"  {attr} unavailable: {exc}")
            continue
        ext = ".vlt" if "VLUT" in attr else ".cube"
        out = os.path.join(tmpdir, f"p4_item0_{attr}{ext}")
        try_export(item0, kind, attr, out, f"p4-{attr}")

    print(f"\nDone. Inspect {tmpdir} for any files that landed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
