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
import time

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

    # ── Pass 5: timing pass. Bake N items, measure per-call latency. ──
    # Color page is already active from Pass 2. We want REAL numbers
    # so we can size the bake wall-clock budget on Anamnesis-style
    # timelines instead of guessing.
    N = 20
    timing_sample = items[:min(N, len(items))]
    print(f"\n=== Pass 5: timing {len(timing_sample)} bakes (33pt cube) ===")
    durations_ms = []
    sizes_kb = []
    failures = 0
    timing_dir = os.path.join(tmpdir, "timing")
    os.makedirs(timing_dir, exist_ok=True)
    overall_start = time.monotonic()
    for idx, item in enumerate(timing_sample):
        try:
            uid = item.GetUniqueId()
        except Exception:
            uid = f"<no-uid-{idx}>"
        out = os.path.join(timing_dir, f"timing_{idx}_{uid}.cube")
        t0 = time.monotonic()
        try:
            rc = item.ExportLUT(cube_kind, out)
        except Exception as exc:
            print(f"  Item {idx}: RAISED {type(exc).__name__}: {exc}")
            failures += 1
            continue
        elapsed_ms = (time.monotonic() - t0) * 1000.0
        if rc and os.path.isfile(out):
            size_kb = os.path.getsize(out) / 1024.0
            durations_ms.append(elapsed_ms)
            sizes_kb.append(size_kb)
            print(f"  Item {idx}: rc={rc!r}  {elapsed_ms:7.1f} ms  "
                  f"{size_kb:7.1f} KB  uid={uid}")
        else:
            failures += 1
            print(f"  Item {idx}: rc={rc!r}  {elapsed_ms:7.1f} ms  "
                  f"FAILED  uid={uid}")
    overall_elapsed = time.monotonic() - overall_start
    n = len(durations_ms)
    if n > 0:
        durations_ms.sort()
        median = durations_ms[n // 2]
        avg = sum(durations_ms) / n
        worst = durations_ms[-1]
        best = durations_ms[0]
        avg_size = sum(sizes_kb) / len(sizes_kb)
        print(f"\n  ── Stats on {n} successful bakes "
              f"({failures} fail) ──")
        print(f"  per-call:  best={best:.1f}ms  median={median:.1f}ms  "
              f"avg={avg:.1f}ms  worst={worst:.1f}ms")
        print(f"  cube size: avg={avg_size:.1f} KB")
        print(f"  total elapsed for {len(timing_sample)} items: "
              f"{overall_elapsed:.1f} s")
        if avg > 0:
            est_1069 = (avg / 1000.0) * 1069
            print(f"  EXTRAPOLATION to 1069 Anamnesis bake-targets "
                  f"(avg×count): {est_1069:.0f} s = {est_1069/60:.1f} min")
            print(f"  EXTRAPOLATION to 1069 (overhead-included, "
                  f"per-call wall-clock from this pass): "
                  f"{overall_elapsed/len(timing_sample)*1069:.0f} s = "
                  f"{overall_elapsed/len(timing_sample)*1069/60:.1f} min")
    else:
        print("  No successful bakes — cannot extrapolate.")

    # ── Pass 6: one specific clip rendered out so Joe can compare ─────
    # Pick the first item that's known-bakeable (rc=True in Pass 5).
    # Bake its LUT to a stable path; render Resolve's actual graded
    # output for the same in/out range to a second stable path.
    # Comparison left to Joe outside the spike — but we print
    # everything needed for an apples-to-apples visual A/B.
    print("\n=== Pass 6: bake + render one clip for visual comparison ===")
    target_item = None
    target_uid = None
    target_idx = None
    for idx, item in enumerate(timing_sample):
        try:
            test_path = os.path.join(tmpdir, f"_probe_{idx}.cube")
            if item.ExportLUT(cube_kind, test_path) \
                    and os.path.isfile(test_path):
                target_item = item
                target_uid = item.GetUniqueId()
                target_idx = idx
                # leave the probe file; we'll overwrite to the named path
                break
        except Exception:
            continue
    if target_item is None:
        print("  No bakeable item in timing sample — skipping Pass 6.")
    else:
        compare_dir = os.path.join(tmpdir, "compare")
        os.makedirs(compare_dir, exist_ok=True)
        lut_out = os.path.join(compare_dir, f"clip_{target_uid}.cube")
        rc = target_item.ExportLUT(cube_kind, lut_out)
        print(f"  Target clip: idx={target_idx} uid={target_uid}")
        print(f"  Baked LUT:   {lut_out}  "
              f"(rc={rc!r}, size={os.path.getsize(lut_out) if os.path.isfile(lut_out) else 'absent'})")
        # Source media path so Joe can apply the LUT to the original
        # in any tool to compare against the render.
        try:
            mp_item = target_item.GetMediaPoolItem()
            if mp_item is not None:
                src_path = mp_item.GetClipProperty("File Path") or "<unknown>"
            else:
                src_path = "<no media-pool item>"
        except Exception as exc:
            src_path = f"<GetMediaPoolItem raised: {exc}>"
        print(f"  Source media: {src_path}")
        try:
            mark_in = target_item.GetStart()
            duration = target_item.GetDuration()
            mark_out = mark_in + duration - 1
            try:
                src_in = target_item.GetSourceStartFrame()
                src_out = target_item.GetSourceEndFrame()
            except Exception:
                src_in = src_out = None
            print(f"  Timeline range (record): in={mark_in} "
                  f"duration={duration} out_inclusive={mark_out}")
            print(f"  Source range: in={src_in} out={src_out}")
        except Exception as exc:
            print(f"  Range query raised: {exc}")
            mark_in = mark_out = None

        # Render the clip's graded output via Resolve's render queue.
        if mark_in is not None:
            render_dir = compare_dir
            print(f"\n  Rendering graded clip to {render_dir}/")
            try:
                project.DeleteAllRenderJobs()
            except Exception as exc:
                print(f"    DeleteAllRenderJobs raised (continuing): {exc}")
            settings = {
                "TargetDir": render_dir,
                "CustomName": f"resolve_render_{target_uid}",
                "MarkIn": mark_in,
                "MarkOut": mark_out,
                "SelectAllFrames": False,
                "ExportVideo": True,
                "ExportAudio": False,
            }
            try:
                set_ok = project.SetRenderSettings(settings)
                print(f"    SetRenderSettings → {set_ok!r}")
            except Exception as exc:
                print(f"    SetRenderSettings raised: {exc}")
                set_ok = False
            if set_ok:
                try:
                    job_id = project.AddRenderJob()
                    print(f"    AddRenderJob → {job_id!r}")
                except Exception as exc:
                    print(f"    AddRenderJob raised: {exc}")
                    job_id = None
                if job_id:
                    try:
                        started = project.StartRendering([job_id])
                        print(f"    StartRendering → {started!r}")
                    except Exception as exc:
                        print(f"    StartRendering raised: {exc}")
                        started = False
                    render_start = time.monotonic()
                    if started:
                        # Poll until the queue says we're done. Cap
                        # at 5 minutes to keep the spike bounded —
                        # if a single clip takes longer than that,
                        # the render path is unviable anyway.
                        deadline = render_start + 300
                        while time.monotonic() < deadline:
                            try:
                                in_progress = project.IsRenderingInProgress()
                            except Exception as exc:
                                print(f"    IsRenderingInProgress "
                                      f"raised: {exc}")
                                break
                            if not in_progress:
                                break
                            time.sleep(0.5)
                        render_elapsed = time.monotonic() - render_start
                        try:
                            status = project.GetRenderJobStatus(job_id)
                        except Exception as exc:
                            status = f"<raised {exc}>"
                        print(f"    Render finished: elapsed="
                              f"{render_elapsed:.1f}s status={status!r}")
        print("\n  ── For Joe: visual comparison ──")
        print(f"    LUT (apply to source media for that range): {lut_out}")
        print(f"    Source media: {src_path}")
        print(f"    Resolve graded render (search this dir): "
              f"{compare_dir}/")
        print("    A/B those two against each other for the same in/out")
        print("    range; any visible deviation IS the LUT-bake fidelity")
        print("    loss for that clip.")

    print(f"\nDone. Inspect {tmpdir} for any files that landed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
