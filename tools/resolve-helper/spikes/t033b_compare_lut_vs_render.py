#!/usr/bin/env python3
"""Visual A/B: bake LUT and render the same Anamnesis clip at TC 01:12:13:11.

Spike that picks a SPECIFIC, real-graded Anamnesis clip (the countdown
leader from t033 was a poor sample — basically no grade). For that
clip:

  1. Resolve-bake its LUT → <tmp>/clip_<uid>.cube
  2. Resolve-render the timeline range for the same clip →
     <tmp>/resolve_render_<uid>.mov   (pixel-perfect ground truth)
  3. ffmpeg-apply the baked LUT to the original source media for the
     same source range → <tmp>/lut_applied_<uid>.mov
  4. Open both rendered files in QuickTime so Joe can A/B.

If the LUT-applied version visually matches Resolve's render, the LUT
bake path is viable for Anamnesis-grade timelines. If it deviates
visibly, we pivot to render+relink (or accept the loss honestly).
"""
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from resolve_handle import ResolveHandle  # noqa: E402

TARGET_TC = "01:12:13:11"  # Joe's pick — real-graded shot, not leader.


def describe_graph(item):
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


def tc_to_frames(tc_str, fps):
    """Non-DF TC → frame count at the given integer fps."""
    parts = tc_str.split(":")
    if len(parts) != 4:
        raise ValueError(f"unsupported TC shape: {tc_str!r}")
    hh, mm, ss, ff = (int(p) for p in parts)
    return ((hh * 3600 + mm * 60 + ss) * fps) + ff


def main():
    h = ResolveHandle()
    status = h.acquire()
    if status[0] != "ok":
        print(f"FAIL: handle.acquire returned {status!r}")
        return 1
    _, resolve, project = status
    tl = project.GetCurrentTimeline()
    if tl is None:
        print("FAIL: no current timeline.")
        return 1
    fps_str = tl.GetSetting("timelineFrameRate") or ""
    print(f"Timeline: {tl.GetName()!r}  fps={fps_str!r}")
    try:
        fps = int(round(float(fps_str)))
    except Exception as exc:
        print(f"FAIL: can't parse fps from {fps_str!r}: {exc}")
        return 1
    target_frame = tc_to_frames(TARGET_TC, fps)
    print(f"Target: TC={TARGET_TC} → frame {target_frame} @ {fps}fps")

    # Find the V1 item whose record range contains target_frame.
    items = tl.GetItemListInTrack("video", 1) or []
    target = None
    for it in items:
        try:
            start = it.GetStart()
            dur = it.GetDuration()
        except Exception:
            continue
        if start <= target_frame < start + dur:
            target = it
            break
    if target is None:
        print(f"FAIL: no V1 item covers frame {target_frame}.")
        return 1

    uid = target.GetUniqueId()
    print(f"Found item uid={uid}")
    print(f"  graph: {describe_graph(target)}")
    rec_in = target.GetStart()
    rec_dur = target.GetDuration()
    rec_out_inclusive = rec_in + rec_dur - 1
    src_in = target.GetSourceStartFrame()
    src_out = target.GetSourceEndFrame()
    print(f"  record: in={rec_in} dur={rec_dur} out_incl={rec_out_inclusive}")
    print(f"  source: in={src_in} out={src_out}")
    mp = target.GetMediaPoolItem()
    src_path = mp.GetClipProperty("File Path") if mp else None
    print(f"  source media: {src_path!r}")
    if not src_path or not os.path.isfile(src_path):
        print("FAIL: source media path missing or not a file.")
        return 1
    src_fps_str = (mp.GetClipProperty("FPS") if mp else "") or fps_str
    try:
        src_fps = float(src_fps_str)
    except Exception:
        src_fps = float(fps)
    print(f"  source fps reported: {src_fps_str!r} → using {src_fps}")

    tmpdir = tempfile.mkdtemp(prefix="t033b_compare_")
    print(f"\nOutput dir: {tmpdir}")

    # ── Bake LUT ─────────────────────────────────────────────────
    try:
        resolve.OpenPage("color")
    except Exception as exc:
        print(f"OpenPage('color') raised: {exc}")
    lut_path = os.path.join(tmpdir, f"clip_{uid}.cube")
    t0 = time.monotonic()
    rc = target.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, lut_path)
    bake_ms = (time.monotonic() - t0) * 1000.0
    print(f"\nBake: rc={rc!r} {bake_ms:.1f} ms  "
          f"size={os.path.getsize(lut_path) if os.path.isfile(lut_path) else 'absent'}")
    if not rc or not os.path.isfile(lut_path):
        print("FAIL: bake didn't land. Aborting.")
        return 1

    # ── Render Resolve's actual graded output for the timeline range ─
    render_dir = tmpdir
    try:
        project.DeleteAllRenderJobs()
    except Exception:
        pass
    settings = {
        "TargetDir": render_dir,
        "CustomName": f"resolve_render_{uid}",
        "MarkIn": rec_in,
        "MarkOut": rec_out_inclusive,
        "SelectAllFrames": False,
        "ExportVideo": True,
        "ExportAudio": False,
    }
    set_ok = project.SetRenderSettings(settings)
    print(f"\nResolve render: SetRenderSettings → {set_ok!r}")
    if not set_ok:
        print("FAIL: SetRenderSettings.")
        return 1
    job_id = project.AddRenderJob()
    print(f"  AddRenderJob → {job_id!r}")
    started = project.StartRendering([job_id])
    print(f"  StartRendering → {started!r}")
    render_start = time.monotonic()
    while time.monotonic() - render_start < 300:
        if not project.IsRenderingInProgress():
            break
        time.sleep(0.5)
    elapsed = time.monotonic() - render_start
    status = project.GetRenderJobStatus(job_id)
    print(f"  finished elapsed={elapsed:.1f}s status={status!r}")

    # Discover the actually-written render file.
    rendered = None
    for fn in sorted(os.listdir(render_dir)):
        if fn.startswith(f"resolve_render_{uid}"):
            rendered = os.path.join(render_dir, fn)
            break
    if rendered is None or not os.path.isfile(rendered):
        print("  WARNING: rendered file not found — Resolve render did "
              "not produce output. Continuing without ground-truth "
              "comparison; LUT-applied result will still be opened.")
        rendered = None
    else:
        print(f"  rendered: {rendered!r}")

    # ── Apply baked LUT to the source media for the same source
    # range via ffmpeg. Trim by source frame numbers using fps; emit
    # ProRes 422 LT so QuickTime plays it without re-encoding the
    # source codec quirks.
    lut_applied = os.path.join(tmpdir, f"lut_applied_{uid}.mov")
    start_s = src_in / src_fps
    duration_s = (src_out - src_in + 1) / src_fps
    cmd = [
        "ffmpeg", "-y",
        "-ss", f"{start_s:.6f}",
        "-i", src_path,
        "-t", f"{duration_s:.6f}",
        "-vf", f"lut3d={lut_path}",
        "-c:v", "prores_ks",
        "-profile:v", "1",
        "-pix_fmt", "yuv422p10le",
        "-an",
        lut_applied,
    ]
    print(f"\nffmpeg LUT-apply:\n  {' '.join(cmd)}")
    t0 = time.monotonic()
    # text=True + Python 3.14 defaults to ASCII for the captured stderr
    # decode and ffmpeg's output contains non-ASCII; capture bytes and
    # decode with errors="replace" so the spike doesn't crash on
    # diagnostics output.
    res = subprocess.run(cmd, capture_output=True)
    ff_elapsed = time.monotonic() - t0
    stderr = res.stderr.decode("utf-8", errors="replace")
    print(f"  ffmpeg exit={res.returncode} elapsed={ff_elapsed:.1f}s")
    if res.returncode != 0:
        print(f"  ffmpeg stderr tail:\n{stderr[-1500:]}")
        print("FAIL: ffmpeg LUT-apply.")
        return 1
    print(f"  lut-applied: {lut_applied}")

    # ── Open both in QuickTime for A/B. Joe can flip windows. ────
    print("\nOpening files in QuickTime…")
    subprocess.run(["open", "-a", "QuickTime Player", lut_applied])
    if rendered is not None:
        subprocess.run(["open", "-a", "QuickTime Player", rendered])

    print("\n── For Joe ──")
    print(f"  graph:           {describe_graph(target)}")
    print(f"  LUT bake:        {lut_path}")
    print(f"  Resolve render:  {rendered or '<failed — see status above>'}")
    print(f"  LUT-applied:     {lut_applied}")
    if rendered is None:
        print("  Only LUT-applied opened. Resolve's render failed — "
              "likely missing full-resolution media at the path "
              "reported above. You can render manually in Resolve "
              "(File → Quick Export) to get the ground-truth file, "
              "then A/B against the LUT-applied output.")
    else:
        print("  Two QuickTime windows opened — A/B them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
