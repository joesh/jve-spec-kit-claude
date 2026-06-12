#!/usr/bin/env python3
"""Spike: can JVE capture the TIMELINE-level grade as a .cube with no
user intervention, via lattice still-frame readout?

FINAL VERDICT (2026-06-11, 13 VM runs): scripted writes to a TIMELINE
node graph are RENDER-INERT — Graph.SetLUT reads back cleanly yet
never reaches ExportCurrentFrameAsStill, gallery grabs, or queue
renders, and Graph.ApplyGradeFromDRX is refused on timeline graphs
(while both work on ITEM graphs: an item-level scripted LUT renders
into stills, and item-graph ApplyGradeFromDRX returns True). This
also invalidates t052's instrument: its "ExportLUT ignores timeline
grades" verdict was measured against a timeline LUT that never
rendered anywhere, so whether per-item bakes carry REAL (UI-authored)
timeline grades is UNPROVEN either way. The capture machinery itself
is proven sound: lattice -> still -> readback is bit-exact, page-free
(modal-immune), and carries item-level grades. Closing the question
needs a one-time manually-authored timeline grade on the VM.

Original premise: t052 reported ExportLUT ignores timeline grades and
the scripting README has no Timeline/Graph LUT export, leaving
empirical capture as the remaining programmatic path:

  1. duplicate the gold timeline (inherits its timeline node graph —
     a fresh CreateEmptyTimeline has a 0-node graph SetLUT refuses)
  2. append a synthetic identity-lattice frame (17^3 color patches);
     a fresh-from-pool item has no clip grade, so the rendered frame
     is timelineGrade(lattice)
  3. Project.ExportCurrentFrameAsStill (README:197) at the lattice
  4. read patches back -> synthesize the timeline grade as a .cube

Questions this probe answers:
  Q1. Does ExportCurrentFrameAsStill include the timeline-level grade?
      Verdict: place Kodak 2383 on the duplicate's timeline graph
      (t052-proven settable) and check graded-still patches match
      trilinear samples of the Kodak cube at the baseline-still patch
      values. Pairing baseline->graded at identical pixel positions
      makes the verdict robust even if geometric tools stay active.
  Q2. Does Graph.SetNodeEnabled (README:533) work on a TIMELINE graph?
      (Wanted in production to mute geometric nodes like the gold
      timeline's Sizing during capture — a LUT cannot carry geometry.)
  Q3. Does the whole capture work WITHOUT OpenPage("color")? The
      missing-DCTL modal fires on Color-page entry (t052 wedge); a
      page-free capture path would be immune to it.
  Q4. What still formats/bit depths does the still export produce?

STATE-CHANGING (creates/deletes a probe timeline + media-pool item,
switches current timeline, may switch pages) — run against the VM
Resolve Studio via scripts/run_timeline_lut_capture_probe.sh, never
against a host Resolve holding real work.
"""
import os
import shutil
import struct
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/resolve-helper

from resolve_handle import ResolveHandle  # noqa: E402
from spikes.cube_util import load_cube, trilerp  # noqa: E402

PROBE_TIMELINE = "jve-t053-probe"
LUT_NODE = 2            # node 1 = the failed missing-DCTL node (muted)
WORK_DIR = "/tmp/jve-t053"
LATTICE_PNG = os.path.join(WORK_DIR, "lattice.png")
LATTICE_N = 17          # 17 lattice points/axis; i/16 grid is an exact
CELL = 16               # subset of a 33pt cube's i/32 grid
STOCK_LUT = ("/Library/Application Support/Blackmagic Design/"
             "DaVinci Resolve/LUT/Film Looks/DCI-P3 Kodak 2383 D60.cube")


# ---------------------------------------------------------------- PNG IO
def write_rgb8_png(path, width, height, rows):
    """rows: list of bytes objects, each 3*width long."""
    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + r for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height,
                                           8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def read_png(path):
    """Returns (width, height, channels, maxval, pixels) where pixels is
    a flat list of ints, row-major, channel-interleaved. Supports color
    types 2 (RGB) / 6 (RGBA), bit depths 8 / 16, no interlace."""
    with open(path, "rb") as f:
        blob = f.read()
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, width, height, depth, ctype, idat = 8, None, None, None, None, []
    while pos < len(blob):
        (length,) = struct.unpack(">I", blob[pos:pos + 4])
        tag = blob[pos + 4:pos + 8]
        payload = blob[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, ctype, _, _, interlace = \
                struct.unpack(">IIBBBBB", payload)
            if interlace != 0 or depth not in (8, 16) or ctype not in (2, 6):
                raise ValueError(f"{path}: unsupported PNG (depth={depth} "
                                 f"colortype={ctype} interlace={interlace})")
        elif tag == b"IDAT":
            idat.append(payload)
        elif tag == b"IEND":
            break
    channels = 3 if ctype == 2 else 4
    bpp = channels * depth // 8
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat))
    if len(raw) != (stride + 1) * height:
        raise ValueError(f"{path}: bad IDAT size")

    out = bytearray(stride * height)
    prior = bytes(stride)
    for y in range(height):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if ftype == 1:    # Sub
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xFF
        elif ftype == 2:  # Up
            for x in range(stride):
                line[x] = (line[x] + prior[x]) & 0xFF
        elif ftype == 3:  # Average
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + (left + prior[x]) // 2) & 0xFF
        elif ftype == 4:  # Paeth
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prior[x]
                c = prior[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 0xFF
        elif ftype != 0:
            raise ValueError(f"{path}: unknown PNG filter {ftype}")
        out[y * stride:(y + 1) * stride] = line
        prior = bytes(line)

    if depth == 8:
        pixels = list(out)
        maxval = 255
    else:
        pixels = [(out[i] << 8) | out[i + 1] for i in range(0, len(out), 2)]
        maxval = 65535
    return width, height, channels, maxval, pixels


def read_tiff(path):
    """Minimal TIFF reader: single image, uncompressed (tag 259 == 1),
    contiguous planar RGB(A) 8/16-bit. Returns same tuple as read_png.
    Raises with the offending tag value on anything else."""
    with open(path, "rb") as f:
        blob = f.read()
    if blob[:2] == b"II":
        e = "<"
    elif blob[:2] == b"MM":
        e = ">"
    else:
        raise ValueError(f"{path}: not a TIFF")
    (ifd_off,) = struct.unpack(e + "I", blob[4:8])
    (n_tags,) = struct.unpack(e + "H", blob[ifd_off:ifd_off + 2])
    tags = {}
    for i in range(n_tags):
        off = ifd_off + 2 + i * 12
        tag, ttype, count = struct.unpack(e + "HHI", blob[off:off + 8])
        if ttype == 3 and count == 1:
            (val,) = struct.unpack(e + "H", blob[off + 8:off + 10])
        elif ttype == 4 and count == 1:
            (val,) = struct.unpack(e + "I", blob[off + 8:off + 12])
        else:
            (val,) = struct.unpack(e + "I", blob[off + 8:off + 12])
            if ttype == 3 and count > 1:
                val = list(struct.unpack(
                    e + f"{count}H", blob[val:val + 2 * count]))
            elif ttype == 4 and count > 1:
                val = list(struct.unpack(
                    e + f"{count}I", blob[val:val + 4 * count]))
        tags[tag] = val
    width, height = tags[256], tags[257]
    comp = tags.get(259, 1)
    if comp != 1:
        raise ValueError(f"{path}: compressed TIFF (compression={comp}) "
                         "unsupported — pick an uncompressed codec")
    bits = tags[258]
    bits = bits if isinstance(bits, list) else [bits]
    depth = bits[0]
    if any(b != depth for b in bits) or depth not in (8, 16):
        raise ValueError(f"{path}: per-channel bits {bits} unsupported")
    if tags.get(284, 1) != 1:
        raise ValueError(f"{path}: planar config {tags[284]} unsupported")
    channels = len(bits)
    if channels not in (3, 4):
        raise ValueError(f"{path}: {channels} channels unsupported")
    offsets = tags[273]
    counts = tags[279]
    offsets = offsets if isinstance(offsets, list) else [offsets]
    counts = counts if isinstance(counts, list) else [counts]
    raw = b"".join(blob[o:o + c] for o, c in zip(offsets, counts))
    expect = width * height * channels * depth // 8
    if len(raw) != expect:
        raise ValueError(f"{path}: strip data {len(raw)} != {expect}")
    if depth == 8:
        return width, height, channels, 255, list(raw)
    fmt = e + f"{width * height * channels}H"
    return width, height, channels, 65535, list(struct.unpack(fmt, raw))


def read_image(path):
    return (read_tiff if path.lower().endswith((".tif", ".tiff"))
            else read_png)(path)


# ------------------------------------------------------------- lattice
def lattice_geometry(width, height):
    cols = width // CELL
    n_patches = LATTICE_N ** 3
    if cols * (height // CELL) < n_patches:
        raise RuntimeError(f"timeline res {width}x{height} too small "
                           f"for {n_patches} {CELL}px patches")
    return cols, n_patches


def patch_value(p):
    i, j, k = p % LATTICE_N, (p // LATTICE_N) % LATTICE_N, p // LATTICE_N ** 2
    return (round(i * 255 / (LATTICE_N - 1)),
            round(j * 255 / (LATTICE_N - 1)),
            round(k * 255 / (LATTICE_N - 1)))


def write_lattice_png(path, width, height):
    cols, n_patches = lattice_geometry(width, height)
    rows = []
    for y in range(height):
        cy, row = y // CELL, bytearray()
        for x in range(width):
            p = cy * cols + x // CELL
            r, g, b = patch_value(p) if p < n_patches else (0, 0, 0)
            row += bytes((r, g, b))
        rows.append(bytes(row))
    write_rgb8_png(path, width, height, rows)
    return n_patches


def read_patches(still_path, lattice_w, lattice_h):
    """Average the central 8x8 of every patch cell. Returns a list of
    (r, g, b) floats in [0, 1]."""
    w, h, channels, maxval, px = read_image(still_path)
    if (w, h) != (lattice_w, lattice_h):
        raise RuntimeError(f"{still_path}: still is {w}x{h}, lattice is "
                           f"{lattice_w}x{lattice_h} — capture is not 1:1")
    cols, n_patches = lattice_geometry(w, h)
    pad = (CELL - 8) // 2
    out = []
    for p in range(n_patches):
        x0, y0 = (p % cols) * CELL + pad, (p // cols) * CELL + pad
        acc = [0, 0, 0]
        for dy in range(8):
            base = ((y0 + dy) * w + x0) * channels
            for dx in range(8):
                for ch in range(3):
                    acc[ch] += px[base + dx * channels + ch]
        out.append(tuple(a / (64 * maxval) for a in acc))
    return out


def patch_stats(pairs_a, pairs_b):
    """Per-channel abs deltas between two patch lists -> (mean, p95, max)."""
    deltas = sorted(abs(a - b)
                    for ta, tb in zip(pairs_a, pairs_b)
                    for a, b in zip(ta, tb))
    mean = sum(deltas) / len(deltas)
    return mean, deltas[int(len(deltas) * 0.95)], deltas[-1]


# ----------------------------------------------------------------- probe
def frames_to_tc(frame, fps):
    f = frame % fps
    s = frame // fps
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}:{f:02d}"


def capture_still(project, path):
    ok = project.ExportCurrentFrameAsStill(path)
    print(f"ExportCurrentFrameAsStill({os.path.basename(path)}): {ok}")
    return ok and os.path.isfile(path)


def render_one_frame(resolve, project, timeline, frame, width, height):
    """Queue a 1-frame render of the current timeline at `frame`,
    wait for it, and return its patches (or None if no usable
    uncompressed format/codec combination exists). Restores the page
    if rendering changed it (StartRendering can jump to Deliver,
    which breaks later ExportCurrentFrameAsStill calls — run 10)."""
    page_before = resolve.GetCurrentPage()
    formats = project.GetRenderFormats() or {}
    print(f"render formats: {formats!r}")
    ext = next((v for v in formats.values() if v == "tif"), None)
    if ext is None:
        print("no TIFF render format available")
        return None
    codecs = project.GetRenderCodecs(ext) or {}
    print(f"render codecs for {ext!r}: {codecs!r}")
    codec = next((v for k, v in sorted(codecs.items())
                  if "16" in k and "LZW" not in k.upper()), None)
    if codec is None:
        codec = next((v for k, v in sorted(codecs.items())
                      if "LZW" not in k.upper()), None)
    if codec is None:
        print("no uncompressed TIFF codec available")
        return None
    if not project.SetCurrentRenderFormatAndCodec(ext, codec):
        raise RuntimeError(f"SetCurrentRenderFormatAndCodec({ext!r}, "
                           f"{codec!r}) refused")
    print(f"render codec chosen: {codec!r}")
    project.SetCurrentRenderMode(1)
    if not project.SetRenderSettings({
            "TargetDir": WORK_DIR, "CustomName": "jve_t053_render",
            "MarkIn": frame, "MarkOut": frame,
            "ExportVideo": True, "ExportAudio": False}):
        raise RuntimeError("SetRenderSettings refused")
    job = project.AddRenderJob()
    if not job:
        raise RuntimeError("AddRenderJob returned nothing")
    before = set(os.listdir(WORK_DIR))
    if not project.StartRendering([job], False):
        project.DeleteRenderJob(job)
        raise RuntimeError("StartRendering refused")
    deadline = time.monotonic() + 180
    status = {}
    while time.monotonic() < deadline:
        status = project.GetRenderJobStatus(job) or {}
        if status.get("JobStatus") in ("Complete", "Failed", "Cancelled"):
            break
        time.sleep(2)
    print(f"render job status: {status!r}")
    project.DeleteRenderJob(job)
    if status.get("JobStatus") != "Complete":
        raise RuntimeError(f"render did not complete: {status!r}")
    page_after = resolve.GetCurrentPage()
    print(f"page after render: {page_after!r}")
    if page_after != page_before:
        resolve.OpenPage(page_before)
        print(f"page restored to {page_before!r}: "
              f"{resolve.GetCurrentPage() == page_before}")
    fresh = sorted(set(os.listdir(WORK_DIR)) - before)
    print(f"rendered files: {fresh!r}")
    if len(fresh) != 1:
        raise RuntimeError(f"expected exactly 1 rendered file: {fresh!r}")
    return read_patches(os.path.join(WORK_DIR, fresh[0]), width, height)


def main():
    # Fresh scratch dir — stale outputs from a prior run would defeat
    # the before/after listdir diffs used to find exported files.
    if os.path.isdir(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR)
    if not os.path.isfile(STOCK_LUT):
        raise RuntimeError(f"stock LUT missing: {STOCK_LUT}")
    kodak_size, kodak_data = load_cube(STOCK_LUT)
    print(f"reference cube: Kodak 2383, {kodak_size}pt")

    handle = ResolveHandle()
    status = handle.acquire()
    if status[0] != "ok":
        raise RuntimeError(f"Resolve acquire failed: {status!r}")
    _, resolve, project = status

    gold = project.GetCurrentTimeline()
    if gold is None:
        raise RuntimeError("no current timeline in VM Resolve — open one")
    fps = float(gold.GetSetting("timelineFrameRate"))
    width = int(gold.GetSetting("timelineResolutionWidth"))
    height = int(gold.GetSetting("timelineResolutionHeight"))
    if abs(fps - round(fps)) >= 1e-6:
        raise RuntimeError(f"non-integer fps {fps} unsupported by probe")
    fps = int(round(fps))
    print(f"gold: {gold.GetName()!r} {width}x{height}@{fps}")

    n_patches = write_lattice_png(LATTICE_PNG, width, height)
    print(f"lattice: {n_patches} patches ({LATTICE_N}^3), {CELL}px cells")

    pool = project.GetMediaPool()
    imported = pool.ImportMedia([LATTICE_PNG]) or []
    if not imported:
        raise RuntimeError("ImportMedia(lattice.png) returned nothing")
    mp_item = imported[0]

    probe_tl = gold.DuplicateTimeline(PROBE_TIMELINE)
    print(f"DuplicateTimeline({PROBE_TIMELINE!r}): {probe_tl is not None}")
    if probe_tl is None:
        pool.DeleteClips([mp_item])
        raise RuntimeError("timeline duplication failed (stale probe "
                           "timeline from an earlier run? delete it in "
                           "Resolve, re-run)")

    prior_page = resolve.GetCurrentPage()
    print(f"page at start: {prior_page!r}")
    page_switched = False
    grab_stills, grab_album = [], None
    rc = 1
    try:
        if not project.SetCurrentTimeline(probe_tl):
            raise RuntimeError("SetCurrentTimeline(probe) failed")
        record = probe_tl.GetEndFrame() + 2 * fps
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
        ok = probe_tl.SetCurrentTimecode(frames_to_tc(mid, fps))
        print(f"SetCurrentTimecode({frames_to_tc(mid, fps)}): {ok}")
        if not ok:
            raise RuntimeError("cannot park playhead on the lattice item")

        tl_graph = probe_tl.GetNodeGraph()
        n_nodes = tl_graph.GetNumNodes() if tl_graph else 0
        print(f"probe timeline graph nodes: {n_nodes}")
        if n_nodes < 2:
            raise RuntimeError("duplicate lacks the 2-node timeline graph")
        for i in range(1, n_nodes + 1):
            print(f"  node {i}: tools={tl_graph.GetToolsInNode(i)!r}")
        # Node 1 carries an OFX whose DCTL file is MISSING on the VM.
        # Run 5 showed a node-1 probe LUT invisible to stills, gallery
        # grabs, AND renders despite a clean GetLUT readback — a failed
        # node appears to bypass every tool in it. Mute node 1 and
        # probe on node 2 (Sizing — functional). Q2: SetNodeEnabled on
        # a timeline graph.
        ok = tl_graph.SetNodeEnabled(1, False)
        print(f"Q2 SetNodeEnabled(1, False) on timeline graph: {ok}")
        # Node ops re-evaluate the graph asynchronously — run 7's first
        # post-disable still raced it (a/b differed by mean 0.5).
        time.sleep(2)

        def black_share(patches):
            return sum(1 for t in patches if max(t) < 1 / 255) / len(patches)

        def baseline_pair(tag, attempt=1):
            a = os.path.join(WORK_DIR, f"baseline_{tag}_a{attempt}.png")
            b = os.path.join(WORK_DIR, f"baseline_{tag}_b{attempt}.png")
            if not (capture_still(project, a) and capture_still(project, b)):
                return None
            pa, pb = (read_patches(p, width, height) for p in (a, b))
            mean, p95, mx = patch_stats(pa, pb)
            print(f"baseline determinism ({tag}#{attempt}): mean={mean:.5f} "
                  f"p95={p95:.5f} max={mx:.5f}; black-share "
                  f"a={black_share(pa):.2f} b={black_share(pb):.2f}")
            if mx <= 2 / 255:
                return pb
            if attempt == 1:
                # One loud settle-and-retry: graph re-evaluation is
                # async and the first capture can race it.
                print("baseline transient — settling 3s and retrying")
                time.sleep(3)
                return baseline_pair(tag, attempt=2)
            return None

        baseline = baseline_pair("edit")
        if baseline is None:
            raise RuntimeError("baseline capture failed or non-"
                               "deterministic")
        src = [tuple(c / 255 for c in patch_value(p))
               for p in range(n_patches)]
        mean, p95, mx = patch_stats(baseline, src)
        print(f"identity drift (baseline vs source lattice): "
              f"mean={mean:.5f} p95={p95:.5f} max={mx:.5f}")

        def set_and_report_lut():
            ok = tl_graph.SetLUT(LUT_NODE, STOCK_LUT)
            print(f"SetLUT({LUT_NODE}, Kodak) from page "
                  f"{resolve.GetCurrentPage()!r}: {ok}, readback "
                  f"GetLUT({LUT_NODE})={tl_graph.GetLUT(LUT_NODE)!r}, "
                  f"tools={tl_graph.GetToolsInNode(LUT_NODE)!r}")
            return ok

        def graded_patches(tag):
            png = os.path.join(WORK_DIR, f"graded_{tag}.png")
            if not capture_still(project, png):
                # Grade writes invalidate the frame; the first capture
                # can race the re-render (run 9). One loud retry.
                print(f"still capture transient ({tag}) — settling 3s "
                      "and retrying")
                time.sleep(3)
                if not capture_still(project, png):
                    raise RuntimeError(f"still capture failed ({tag})")
            return read_patches(png, width, height)

        def visible_against(graded, base, label):
            mean, p95, mx = patch_stats(graded, base)
            print(f"grade visibility ({label}): mean={mean:.5f} "
                  f"p95={p95:.5f} max={mx:.5f}")
            return mx > 2 / 255

        lut_set = set_and_report_lut()
        graded = lut_set and graded_patches("edit")
        if lut_set and visible_against(graded, baseline, "edit page"):
            print("Q3: capture worked with NO page switch")
        else:
            # Either SetLUT refused on the edit page, or it reported
            # True without taking effect there. Escalate: the Color
            # page is where t052 proved timeline-graph SetLUT works.
            print("escalating to the Color page (edit-page capture "
                  "showed no grade)")
            resolve.OpenPage("color")
            page_switched = True
            if resolve.GetCurrentPage() != "color":
                raise RuntimeError("Color page switch did not take "
                                   "(missing-DCTL modal? dismiss it in "
                                   "the VM and re-run)")
            baseline = baseline_pair("color")
            if baseline is None:
                raise RuntimeError("color-page baseline failed")
            if not set_and_report_lut():
                print("RESULT: SetLUT refused on both pages — Q1 "
                      "inconclusive via scripting")
                return 1
            graded = graded_patches("color")
            if not visible_against(graded, baseline, "color page"):
                print("RESULT Q1a: ExportCurrentFrameAsStill NEVER "
                      "includes the timeline grade (LUT readback above "
                      "proves the set took)")
                # Q1b: gallery grab — the color-page viewer is graded,
                # so a grabbed-and-exported still may carry it.
                grab_album = project.GetGallery().GetCurrentStillAlbum()
                grab_still = probe_tl.GrabStill()
                print(f"GrabStill: {grab_still is not None}")
                if grab_still is None:
                    print("RESULT Q1b: GrabStill returned nothing — "
                          "gallery path inconclusive")
                    return 1
                grab_stills.append(grab_still)
                before = set(os.listdir(WORK_DIR))
                ok = grab_album.ExportStills([grab_still], WORK_DIR,
                                             "jve_t053_grab", "png")
                fresh = [f for f in set(os.listdir(WORK_DIR)) - before
                         if f.endswith(".png")]
                print(f"ExportStills(png): {ok}, files: {fresh!r}")
                if len(fresh) != 1:
                    raise RuntimeError(f"expected exactly 1 exported "
                                       f"grab, got {fresh!r}")
                grab = read_patches(os.path.join(WORK_DIR, fresh[0]),
                                    width, height)
                if visible_against(grab, baseline, "gallery grab"):
                    graded = grab
                    print("gallery grab CARRIES the timeline grade — "
                          "scoring accuracy against the reference cube")
                else:
                    print("RESULT Q1b: gallery grab is ALSO ungraded — "
                          "no still path carries the timeline grade; "
                          "trying the render queue")
                    graded = render_one_frame(resolve, project,
                                              probe_tl, mid,
                                              width, height)
                    if graded is None:
                        print("\nRESULT Q1c: render-queue capture "
                              "unavailable (see codec/format output "
                              "above) — no programmatic carrier found")
                        rc = 0
                        return rc
                    if not visible_against(graded, baseline,
                                           "rendered frame"):
                        print("RESULT Q1c: even the RENDERED frame "
                              "omits the timeline grade — nothing "
                              "carries a SCRIPT-SET timeline LUT")
                        # Q1d CONTROL: an ITEM-level scripted LUT on
                        # the lattice item. If THIS shows in a still,
                        # capture includes grading in general and only
                        # timeline-graph scripting writes are inert —
                        # i.e. the instrument is broken, not the
                        # capture idea (production captures Joe's
                        # UI-set timeline grade, never a scripted one).
                        ok = item.SetLUT(1, STOCK_LUT)
                        print(f"CONTROL item.SetLUT(1, Kodak): {ok}, "
                              f"readback={item.GetLUT(1)!r}")
                        if not ok:
                            print("\nRESULT Q1d: item-level SetLUT "
                                  "refused — control unavailable")
                            rc = 0
                            return rc
                        time.sleep(2)
                        ctrl = graded_patches("item_control")
                        if not visible_against(ctrl, baseline,
                                               "item-level control"):
                            print("\nRESULT Q1d: even an item-level "
                                  "scripted LUT is invisible to stills "
                                  "— scripted LUTs don't reach the "
                                  "render path at all on this setup")
                            rc = 0
                            return rc
                        print("RESULT Q1d: item-level LUT IS captured "
                              "— stills include grades; the timeline-"
                              "graph SetLUT write is render-inert "
                              "(instrument problem, poisons t052 too)")
                        # Q1e: forge a REAL grade onto the timeline
                        # graph: grab the graded item as a DRX still,
                        # swap in a fresh ungraded lattice item, apply
                        # the DRX to the TIMELINE graph, re-test.
                        drx_still = probe_tl.GrabStill()
                        print(f"GrabStill (graded item): "
                              f"{drx_still is not None}")
                        if drx_still is None:
                            raise RuntimeError("DRX grab failed")
                        grab_stills.append(drx_still)
                        before = set(os.listdir(WORK_DIR))
                        ok = grab_album.ExportStills(
                            [drx_still], WORK_DIR, "jve_t053_drx", "drx")
                        fresh = [f for f in
                                 set(os.listdir(WORK_DIR)) - before
                                 if f.endswith(".drx")]
                        print(f"ExportStills(drx): {ok}, files: {fresh!r}")
                        if len(fresh) != 1:
                            raise RuntimeError(
                                f"expected 1 exported drx: {fresh!r}")
                        drx_path = os.path.join(WORK_DIR, fresh[0])

                        ok = probe_tl.DeleteClips([item], False)
                        print(f"DeleteClips(graded lattice item): {ok}")
                        if not ok:
                            raise RuntimeError("could not remove the "
                                               "graded lattice item")
                        appended = pool.AppendToTimeline([{
                            "mediaPoolItem": mp_item,
                            "startFrame": 0, "endFrame": 2 * fps - 1,
                            "trackIndex": 1, "recordFrame": record,
                            "mediaType": 1,
                        }]) or []
                        if not appended:
                            raise RuntimeError("fresh lattice re-append "
                                               "failed")
                        item = appended[0]
                        if not probe_tl.SetCurrentTimecode(
                                frames_to_tc(mid, fps)):
                            raise RuntimeError("cannot re-park playhead")
                        time.sleep(2)
                        baseline = baseline_pair("drx")
                        if baseline is None:
                            raise RuntimeError("DRX-stage baseline "
                                               "failed")
                        ok = False
                        for mode in (0, 1, 2):
                            ok = tl_graph.ApplyGradeFromDRX(drx_path,
                                                            mode)
                            print(f"timeline graph ApplyGradeFromDRX"
                                  f"(mode={mode}): {ok}")
                            if ok:
                                break
                        if not ok:
                            # Controls: is the DRX itself valid, and
                            # does an output-LUT-style setting exist as
                            # an alternative instrument?
                            item_ok = item.GetNodeGraph()\
                                .ApplyGradeFromDRX(drx_path, 0)
                            print(f"CONTROL item graph "
                                  f"ApplyGradeFromDRX: {item_ok}")
                            tl_set = probe_tl.GetSetting() or {}
                            lut_keys = {k: v for k, v in tl_set.items()
                                        if "lut" in k.lower()}
                            print(f"timeline settings w/ 'lut': "
                                  f"{lut_keys!r}")
                            print("\nRESULT Q1e: ApplyGradeFromDRX "
                                  "refused on the timeline graph — no "
                                  "scripted way to plant a real "
                                  "timeline grade; verification needs "
                                  "a one-time manual grade on the VM")
                            rc = 0
                            return rc
                        time.sleep(2)
                        graded = graded_patches("tl_drx")
                        if not visible_against(graded, baseline,
                                               "timeline DRX grade"):
                            print("\nRESULT Q1e: DRX-applied timeline "
                                  "grade is ALSO render-inert — "
                                  "scripted timeline grades never "
                                  "render; verification of capture "
                                  "needs a one-time manual grade")
                            rc = 0
                            return rc
                        print("timeline DRX grade RENDERS — re-testing "
                              "the per-item bake (t052 re-verdict)")
                        bake_path = os.path.join(WORK_DIR, "rebake.cube")
                        ok = item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE,
                                            bake_path)
                        print(f"ExportLUT with live timeline grade: {ok}")
                        if ok and os.path.isfile(bake_path):
                            bsize, bdata = load_cube(bake_path)
                            deltas = sorted(
                                abs(a - b)
                                for ta, tb in zip(bdata, kodak_data)
                                for a, b in zip(ta, tb))
                            p95b = deltas[int(len(deltas) * 0.95)]
                            print(f"bake vs Kodak cube: p95={p95b:.5f} "
                                  f"max={deltas[-1]:.5f}")
                            print("RESULT Q1f: per-item ExportLUT "
                                  + ("INCLUDES" if p95b <= 0.02 else
                                     "OMITS")
                                  + " a real timeline grade — t052 "
                                  "verdict "
                                  + ("REVERSED" if p95b <= 0.02 else
                                     "stands"))
                        else:
                            print("RESULT Q1f: ExportLUT FAILED with a "
                                  "live timeline grade present")
                    print("rendered frame CARRIES the timeline grade — "
                          "scoring accuracy against the reference cube")

        expected = [trilerp(kodak_size, kodak_data, *b) for b in baseline]
        mean, p95, mx = patch_stats(graded, expected)
        print(f"capture accuracy (graded vs Kodak(baseline)): "
              f"mean={mean:.5f} p95={p95:.5f} max={mx:.5f}")
        if p95 <= 0.02:
            print("\nRESULT Q1: the capture path above INCLUDES the "
                  "timeline grade and matches the reference cube — "
                  "programmatic timeline-LUT capture is feasible"
                  + ("" if page_switched else " WITHOUT the Color page"))
        else:
            print("\nRESULT Q1: capture differs from baseline but does "
                  "NOT match the reference cube — extra processing in "
                  "the path; investigate before building on it")
        rc = 0
    finally:
        if grab_stills:
            ok = grab_album.DeleteStills(grab_stills)
            print(f"cleanup DeleteStills(x{len(grab_stills)}): {ok}")
        ok = project.SetCurrentTimeline(gold)
        print(f"cleanup SetCurrentTimeline(gold): {ok}")
        ok = pool.DeleteTimelines([probe_tl])
        print(f"cleanup DeleteTimelines(probe): {ok}")
        ok = pool.DeleteClips([mp_item])
        print(f"cleanup DeleteClips(lattice): {ok}")
        if page_switched and prior_page is not None:
            resolve.OpenPage(prior_page)
            print(f"cleanup page restore to {prior_page!r}: "
                  f"{resolve.GetCurrentPage() == prior_page}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
