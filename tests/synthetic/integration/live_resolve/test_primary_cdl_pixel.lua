-- T033 — LIVE primary-CDL pixel compare (spec 023, FR-016;
--          research.md §5.4 "never assume the formula"; quickstart
--          step 2). Pins the CDL math convention.
--
-- What is pinned: that JVE's production CDL primitive (EMP
-- apply_cdl — ASC S-2014-009-01 sop^power then BT.709-luma
-- saturation, exposed to tests as qt_cdl_apply_pixel) computes the
-- SAME transform Resolve applies for a primary CDL grade.
--
-- How the spec-024 gap is kept out of the blast radius: JVE-vs-Resolve
-- whole-pipeline renders are KNOWN to differ for reasons unrelated to
-- CDL (project-level color management Resolve applies outside the
-- clip grade — t033c probe, spikes/README). So this test never
-- compares a JVE render to a Resolve render. It renders the SAME
-- JVE-sent clip in Resolve twice — ungraded and with a known primary
-- CDL — and asserts
--
--     jve_apply_cdl(resolve_ungraded_pixels) ≈ resolve_graded_pixels
--
-- Both images share Resolve's entire decode + color-management path;
-- the ONLY delta between them is the CDL op, so the comparison
-- isolates exactly the convention under test (working signal the CDL
-- sees, sat order, clamping).
--
-- The known CDL is the data-model.md §ClipGrade reference grade (the
-- same one test_cdl_apply_pixel pins offline):
--   slope (1.05, 0.98, 0.92), offset (0.01, 0.00, -0.02),
--   power (1.10, 1.00, 0.95), sat 0.85
--
-- Tolerance (set here per tasks.md): per-channel |Δ| ≤ 3/255 per
-- sampled pixel, mean |Δ| ≤ 1/255 across all samples. Budget: the
-- TIFF→rgb24 conversion quantizes both renders identically to 8 bits
-- (±0.5/255 input), slope≈1/power≈1 propagates that ≈1:1, plus
-- output rounding (±0.5/255) and Resolve's internal 32-float
-- precision. A systematic convention mismatch (wrong sat order, wrong
-- clamp, wrong working signal) produces errors far above this on real
-- footage; do NOT widen the tolerance to make a failure pass — a
-- failure here IS the discovery this test exists for.
--
-- ⚠ State-changing on the VM Resolve (imports a timeline, queues
-- renders, briefly changes render format — saved and restored): run
-- against the VM test environment only.
--
-- Run via (absolute path, on the VM):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_primary_cdl_pixel.lua

local test_env = require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local ClipGrade = require("models.clip_grade")
local command_manager = require("core.command_manager")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local driver = require(
    "synthetic.integration.live_resolve.command_driver")

local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108
local SEQ = "jve-t033"
local CLIP_ID = "0c33c0de-aaaa-4aaa-8aaa-000000000001"
local CLIP = { seq_start = 0, dur = 48, src_in = 10 }
local RENDER_FRAME = 24   -- mid-clip, timeline-absolute (sequence at 0)

-- The data-model reference CDL (mirrors test_cdl_apply_pixel).
local CDL = {
    slope  = { 1.05, 0.98, 0.92 },
    offset = { 0.01, 0.00, -0.02 },
    power  = { 1.10, 1.00, 0.95 },
    sat    = 0.85,
}

local MAX_DELTA  = 3.0 / 255.0
local MEAN_DELTA = 1.0 / 255.0

-- ── DB fixture: one clip over one master/media ──────────────────────
local DB_PATH = "/tmp/jve/test_primary_cdl_pixel.db"
os.remove(DB_PATH)
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "schema init failed")
local db = database.get_connection()
db:exec(require("import_schema"))

Project.create("p", {
    id = "p1", fps_mismatch_policy = "passthrough",
    settings = { master_clock_hz = 705600000,
                 default_fps = { num = FPS_NUM, den = FPS_DEN } },
}):save()
Sequence.create("m", "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "m", kind = "master" }):save()
Sequence.create(SEQ, "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = SEQ, kind = "sequence",
                  audio_sample_rate = 48000 }):save()
Track.create_video("V1", SEQ, { id = SEQ .. "-v1", index = 1 }):save()
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")
Media.create({
    id = "med-a005", project_id = "p1", name = "A005_C052_0925BL_001.mp4",
    file_path = MEDIA_PATH, duration_frames = MEDIA_FRAMES,
    fps_numerator = FPS_NUM, fps_denominator = FPS_DEN,
    audio_channels = 0,
    metadata = string.format(
        '{"start_tc_value":0,"start_tc_rate":%d}', FPS_NUM),
}):save()
db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-a005', 'p1', 'm', 'm-v1', 'med-a005', 0, %d, 0, %d,
        NULL, 1, 1.0, 0, 0, 0);
]], MEDIA_FRAMES, MEDIA_FRAMES))

local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
assert(Clip.create({
    id = CLIP_ID, project_id = "p1", owner_sequence_id = SEQ,
    track_id = SEQ .. "-v1", sequence_id = "m",
    name = "t033 graded",
    sequence_start_frame = CLIP.seq_start, duration_frames = CLIP.dur,
    source_in_frame = CLIP.src_in,
    source_out_frame = CLIP.src_in + CLIP.dur,
    source_in_subframe = sub_in, source_out_subframe = sub_out,
    master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
    enabled = true, volume = 1.0, playhead_frame = 0,
}) == CLIP_ID)

command_manager.init(SEQ, "p1")
supervisor.configure(
    driver.repo_root() .. "/tools/resolve-helper/helper.py")
driver.skip_unless_live("test_primary_cdl_pixel")

-- ── send ─────────────────────────────────────────────────────────────
local send = driver.run_bridge_command("SendToResolve",
    "send_to_resolve_completed",
    { project_id = "p1", sequence_id = SEQ })
assert(#send.result.mapping == 1 and #send.result.unrelinked == 0,
    string.format("T033 send: expected 1 mapped / 0 unrelinked, got "
        .. "%d/%d", #send.result.mapping, #send.result.unrelinked))
local item_uid = send.result.mapping[1].resolve_item_id
local tl_id = send.result.resolve_timeline_id
print("  ✓ send: clip mapped, timeline " .. tl_id)

-- ── render probe (runs on the VM, separate fusionscript session) ────
-- Mirrors spikes/t053_probe_timeline_lut_capture.render_one_frame:
-- 1-frame TIFF render, page + render-format save/restore, job cleanup.
-- Then ffmpeg-converts the TIFF to rgb24 raw so Lua can read pixels.
local PROBE = [[
import os, subprocess, sys, time
api_dir = ("/Library/Application Support/Blackmagic Design/"
           "DaVinci Resolve/Developer/Scripting")
sys.path.insert(0, os.path.join(api_dir, "Modules"))
os.environ["RESOLVE_SCRIPT_API"] = api_dir
os.environ["RESOLVE_SCRIPT_LIB"] = (
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/"
    "Contents/Libraries/Fusion/fusionscript.so")
import DaVinciResolveScript as dvr

frame = int(sys.argv[1])
out_base = sys.argv[2]          # absolute, no extension
work_dir = os.path.dirname(out_base)

resolve = dvr.scriptapp("Resolve")
assert resolve is not None, "probe: scriptapp returned None"
project = resolve.GetProjectManager().GetCurrentProject()
page_before = resolve.GetCurrentPage()
fmt_before = project.GetCurrentRenderFormatAndCodec() or {}

formats = project.GetRenderFormats() or {}
ext = next((v for v in formats.values() if v == "tif"), None)
assert ext, "probe: no TIFF render format: %r" % (formats,)
codecs = project.GetRenderCodecs(ext) or {}
codec = next((v for k, v in sorted(codecs.items())
              if "16" in k and "LZW" not in k.upper()), None)
if codec is None:
    codec = next((v for k, v in sorted(codecs.items())
                  if "LZW" not in k.upper()), None)
assert codec, "probe: no usable TIFF codec: %r" % (codecs,)
assert project.SetCurrentRenderFormatAndCodec(ext, codec), \
    "probe: SetCurrentRenderFormatAndCodec refused"
project.SetCurrentRenderMode(1)
name = os.path.basename(out_base)
assert project.SetRenderSettings({
    "TargetDir": work_dir, "CustomName": name,
    "MarkIn": frame, "MarkOut": frame,
    "ExportVideo": True, "ExportAudio": False}), \
    "probe: SetRenderSettings refused"
job = project.AddRenderJob()
assert job, "probe: AddRenderJob returned nothing"
before = set(os.listdir(work_dir))
assert project.StartRendering([job], False), "probe: StartRendering refused"
deadline = time.monotonic() + 180
status = {}
while time.monotonic() < deadline:
    status = project.GetRenderJobStatus(job) or {}
    if status.get("JobStatus") in ("Complete", "Failed", "Cancelled"):
        break
    time.sleep(1)
project.DeleteRenderJob(job)
assert status.get("JobStatus") == "Complete", \
    "probe: render did not complete: %r" % (status,)

# Restore render format + page (StartRendering may jump to Deliver).
if fmt_before.get("format") and fmt_before.get("codec"):
    project.SetCurrentRenderFormatAndCodec(
        fmt_before["format"], fmt_before["codec"])
if resolve.GetCurrentPage() != page_before:
    resolve.OpenPage(page_before)

fresh = sorted(set(os.listdir(work_dir)) - before)
fresh = [f for f in fresh if f.startswith(name)]
assert len(fresh) == 1, "probe: expected 1 rendered file: %r" % (fresh,)
tif = os.path.join(work_dir, fresh[0])

# TIFF → rgb24 raw + a meta file with the geometry.
raw = out_base + ".raw"
probe_out = subprocess.run(
    ["/opt/homebrew/bin/ffprobe", "-v", "error", "-select_streams",
     "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0",
     tif], capture_output=True, text=True, check=True).stdout.strip()
w, h = (int(x) for x in probe_out.split(","))
subprocess.run(
    ["/opt/homebrew/bin/ffmpeg", "-y", "-v", "error", "-i", tif,
     "-f", "rawvideo", "-pix_fmt", "rgb24", raw], check=True)
expected = w * h * 3
got = os.path.getsize(raw)
assert got == expected, "probe: raw size %d != %d (w=%d h=%d)" % (
    got, expected, w, h)
open(out_base + ".meta", "w").write("%d %d\n" % (w, h))
os.remove(tif)
print("probe: rendered frame %d -> %s (%dx%d)" % (frame, raw, w, h))
]]

local function render_frame_raw(tag)
    local base = "/tmp/jve/t033_" .. tag
    local script = "/tmp/jve/t033_probe_render.py"
    local f = assert(io.open(script, "w"))
    f:write(PROBE)
    f:close()
    local rc = os.execute(string.format(
        "/usr/bin/python3 '%s' %d '%s'", script, RENDER_FRAME, base))
    assert(rc == 0, string.format(
        "T033 render probe (%s) failed rc=%s", tag, tostring(rc)))
    local meta = assert(io.open(base .. ".meta", "r"))
    local w, h = meta:read("*l"):match("^(%d+) (%d+)$")
    meta:close()
    local rawf = assert(io.open(base .. ".raw", "rb"))
    local bytes = rawf:read("*a")
    rawf:close()
    return bytes, tonumber(w), tonumber(h)
end

-- ── render #1: ungraded ground state ────────────────────────────────
local before_px, W, H = render_frame_raw("ungraded")
print(string.format("  ✓ ungraded render: %dx%d", W, H))

-- ── grade in Resolve + sync back ────────────────────────────────────
driver.helper_request("apply_test_grade", {
    resolve_item_id = item_uid, cdl = CDL,
    change_token = driver.fresh_token("p1", SEQ),
})
driver.run_bridge_command("SyncGradesFromResolve",
    "sync_grades_from_resolve_completed",
    { project_id = "p1", sequence_id = SEQ })
local g = ClipGrade.load(CLIP_ID, db)
assert(g and g.fidelity == "primary", string.format(
    "T033 sync: expected primary grade on the clip, got %s",
    tostring(g and g.fidelity)))
local function close(a, b)
    return math.abs(a - b) <= 1e-4   -- EDL CDL prints 6 decimals
end
assert(close(g.cdl.slope_r, CDL.slope[1])
    and close(g.cdl.slope_g, CDL.slope[2])
    and close(g.cdl.slope_b, CDL.slope[3])
    and close(g.cdl.offset_r, CDL.offset[1])
    and close(g.cdl.offset_g, CDL.offset[2])
    and close(g.cdl.offset_b, CDL.offset[3])
    and close(g.cdl.power_r, CDL.power[1])
    and close(g.cdl.power_g, CDL.power[2])
    and close(g.cdl.power_b, CDL.power[3])
    and close(g.cdl.saturation, CDL.sat),
    "T033 sync: synced CDL values differ from the applied grade")
print("  ✓ grade applied + synced back, values match")

-- ── render #2: graded ───────────────────────────────────────────────
local after_px, W2, H2 = render_frame_raw("graded")
assert(W2 == W and H2 == H, "T033: render geometry changed between runs")

-- ── pixel compare ───────────────────────────────────────────────────
assert(type(qt_cdl_apply_pixel) == "function",
    "qt_cdl_apply_pixel binding not registered (run via jve --test)")

local STRIDE = 251   -- prime; ~8.3k samples over 1920x1080
local n, sum_delta, max_delta = 0, 0.0, 0.0
local lum_min, lum_max = 1.0, 0.0
local diff_sum = 0.0
local total_px = W * H
for p = 0, total_px - 1, STRIDE do
    local o = p * 3
    local r0 = before_px:byte(o + 1) / 255.0
    local g0 = before_px:byte(o + 2) / 255.0
    local b0 = before_px:byte(o + 3) / 255.0
    local r1 = after_px:byte(o + 1) / 255.0
    local g1 = after_px:byte(o + 2) / 255.0
    local b1 = after_px:byte(o + 3) / 255.0

    local lum = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0
    if lum < lum_min then lum_min = lum end
    if lum > lum_max then lum_max = lum end
    diff_sum = diff_sum + math.abs(r1 - r0) + math.abs(g1 - g0)
        + math.abs(b1 - b0)

    local er, eg, eb = qt_cdl_apply_pixel(r0, g0, b0,
        CDL.slope[1], CDL.slope[2], CDL.slope[3],
        CDL.offset[1], CDL.offset[2], CDL.offset[3],
        CDL.power[1], CDL.power[2], CDL.power[3],
        CDL.sat)
    for _, d in ipairs({ math.abs(er - r1), math.abs(eg - g1),
                         math.abs(eb - b1) }) do
        sum_delta = sum_delta + d
        if d > max_delta then max_delta = d end
    end
    n = n + 1
end

-- Input-quality guards: a flat frame or an inert grade would make the
-- comparison vacuously pass — fail loudly instead.
assert(lum_max - lum_min >= 16.0 / 255.0, string.format(
    "T033: rendered frame too flat to pin CDL math (luma spread "
    .. "%.4f) — pick a different RENDER_FRAME", lum_max - lum_min))
assert(diff_sum / (n * 3) >= 1.0 / 255.0, string.format(
    "T033: graded render barely differs from ungraded (mean |Δ| "
    .. "%.5f) — SetCDL appears render-inert (cf. t053 timeline-graph "
    .. "inertness); the grade never reached the render",
    diff_sum / (n * 3)))

local mean = sum_delta / (n * 3)
print(string.format(
    "  pixel compare: %d samples, mean |Δ| %.5f (%.2f/255), "
    .. "max |Δ| %.5f (%.2f/255)", n, mean, mean * 255,
    max_delta, max_delta * 255))
assert(mean <= MEAN_DELTA and max_delta <= MAX_DELTA, string.format(
    "T033 FAILED: JVE CDL math does not reproduce Resolve's CDL "
    .. "(mean %.5f > %.5f or max %.5f > %.5f). The convention "
    .. "differs — investigate sat order / clamping / working signal; "
    .. "do NOT widen the tolerance.", mean, MEAN_DELTA, max_delta,
    MAX_DELTA))
print("  ✓ JVE apply_cdl(ungraded) ≈ Resolve graded render — "
    .. "convention pinned")

-- ── teardown ────────────────────────────────────────────────────────
local del = driver.helper_request("delete_timeline", {
    resolve_timeline_id = tl_id,
    change_token = driver.fresh_token("p1", SEQ),
})
assert(del.deleted == true, "T033 teardown: timeline delete failed")
for _, suffix in ipairs({ "ungraded.raw", "ungraded.meta",
                          "graded.raw", "graded.meta" }) do
    os.remove("/tmp/jve/t033_" .. suffix)
end
supervisor.shutdown()
print("✅ test_primary_cdl_pixel.lua passed")
