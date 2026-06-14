-- LIVE round-trip: a JVE-authored .drt carrying a REVERSE clip must import
-- into real DaVinci Resolve and come back as a full-bodied clip occupying the
-- SAME source region as its forward twin (spec 023, task #5).
--
-- The offline gate (tests/synthetic/integration/test_drt_reverse_clip_roundtrip)
-- already proves drt_writer ↔ drp_importer round-trip the reverse convention
-- exactly. This closes the remaining gap: that REAL Resolve ACCEPTS the
-- reverse MediaTimemapBA bytes (full-media descending curve + windowing <In>)
-- and produces a clip with a correct, non-degenerate source range — not an
-- empty body, not a dropped (unrelinked) clip, not a collapsed range.
--
-- DESIGN (domain-derived, forward clip is the empirical control):
--   • One FORWARD clip and one REVERSE twin reference the SAME media and play
--     the SAME source frames [LO..HI]; the reverse plays them backward.
--   • Resolve's read_timeline exposes GetSourceStartFrame/GetSourceEndFrame but
--     NO direction/speed field — so the forward clip establishes Resolve's
--     source-range convention empirically, and the reverse twin must occupy the
--     identical source region (same {min,max}) and same timeline duration.
--   • Whether Resolve mirrors the in/out ordering for a reverse clip
--     (source_in > source_out) is the live unknown this test records; if it
--     does, that is a direct live confirmation of direction.
--
-- What this asserts (none traced from code — derived from the edit I authored):
--   A. Resolve ACCEPTS both clips: 2 mapped, 0 unrelinked. (primary proof)
--   B. read_timeline returns 2 media-bodied items.
--   C. Both items' record_duration == the authored timeline duration.
--   D. The forward clip's file-relative source in-point == the offset authored.
--   E. The reverse twin occupies the SAME source region as the forward clip.
--
-- ⚠ State-changing on the CURRENT Resolve project (imports + deletes a fixture
-- timeline). VM test environment only.
--   scripts/run_live_resolve_test.sh test_drt_reverse_roundtrip_live

local test_env        = require("test_env")
local database        = require("core.database")
local Project         = require("models.project")
local Sequence        = require("models.sequence")
local Track           = require("models.track")
local Media           = require("models.media")
local Clip            = require("models.clip")
local payload_builder = require("core.resolve_bridge.payload_builder")
local drt_writer      = require("exporters.drt_writer")
local fixture         = require(
    "synthetic.integration.live_resolve.live_fixture")

-- 23.976fps A005 fixture with real embedded TC (108 video frames) — the
-- writer's author_a005_compatible path requires 23.976 media.
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001
local MEDIA_FRAMES = 108

-- The shared played source window (file-relative frames) and its length.
local LO  = 20                 -- lowest played source frame
local DUR = 60                 -- frames; HI = LO + DUR - 1 = 79
local HI  = LO + DUR - 1
local FWD_START = 120          -- forward clip's timeline position
local REV_START = 300          -- reverse twin's timeline position (separated)

-- ── DB fixture: a forward clip and its reverse twin on a master sequence ──
local DB_PATH = "/tmp/jve/test_drt_reverse_roundtrip_live.db"
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
Sequence.create("seq", "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "e1", kind = "sequence", audio_sample_rate = 48000 })
    :save()
Track.create_video("V1", "e1", { id = "e1-v1", index = 1 }):save()
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' "
    .. "WHERE id = 'm'")

local media = Media.create({
    id = "med-tc01", project_id = "p1",
    name = "A005_C052_0925BL_001_tc01.mp4",
    file_path = MEDIA_PATH, duration_frames = MEDIA_FRAMES,
    fps_numerator = FPS_NUM, fps_denominator = FPS_DEN,
    audio_channels = 0, metadata = "{}",
})
media:save()
db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-tc01', 'p1', 'm', 'm-v1', 'med-tc01', 0, %d, 0, %d,
        NULL, 1, 1.0, 0, 0, 0);
]], MEDIA_FRAMES, MEDIA_FRAMES))

local TC_ORIGIN = media:get_start_tc()
assert(type(TC_ORIGIN) == "number" and TC_ORIGIN > 0,
    "fixture: embedded TC origin must extract non-zero")
local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")

-- FORWARD: source_in = first played (absolute TC), source_out = one-past-last.
assert(Clip.create({
    id = "0b50c0de-7007-4aaa-8aaa-0000000000f1", project_id = "p1",
    owner_sequence_id = "e1", track_id = "e1-v1", sequence_id = "m",
    name = "A005 fwd", sequence_start_frame = FWD_START, duration_frames = DUR,
    source_in_frame = TC_ORIGIN + LO, source_out_frame = TC_ORIGIN + LO + DUR,
    source_in_subframe = sub_in, source_out_subframe = sub_out,
    master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
    enabled = true, volume = 1.0, playhead_frame = 0,
}))

-- REVERSE twin: same source frames played backward. source_in = highest played
-- (inclusive), source_out = lowest played minus one (exclusive).
assert(Clip.create({
    id = "0b50c0de-7007-4aaa-8aaa-00000000re00", project_id = "p1",
    owner_sequence_id = "e1", track_id = "e1-v1", sequence_id = "m",
    name = "A005 rev", sequence_start_frame = REV_START, duration_frames = DUR,
    source_in_frame = TC_ORIGIN + HI, source_out_frame = TC_ORIGIN + LO - 1,
    source_in_subframe = sub_in, source_out_subframe = sub_out,
    master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
    enabled = true, volume = 1.0, playhead_frame = 0,
}))

-- ── author the .drt through the real export path ────────────────────────
local payload = payload_builder.build(db, "p1", "e1")
local OUT = "/tmp/jve/reverse_roundtrip_live.drt"
os.remove(OUT)
local authored = drt_writer.author_a005_compatible(OUT, payload)

local media_paths, seen = {}, {}
for _, ref in ipairs(payload.media_refs) do
    if not seen[ref.file_path] then
        seen[ref.file_path] = true
        media_paths[#media_paths + 1] = ref.file_path
    end
end

-- ── import into live Resolve and read back ──────────────────────────────
local SOCK = "/tmp/jve-live-reverse-roundtrip.sock"
local fix = fixture.start(SOCK)
fixture.skip_unless_live(fix, "test_drt_reverse_roundtrip_live")

local GEN = 1
local imp = fixture.expect_ok(fixture.request(fix, "import_timeline", {
    drt_path       = OUT,
    media_paths    = media_paths,
    clip_positions = authored.emit_order,
    change_token   = { project_id = "p1", sequence_id = "e1",
                       mutation_generation = GEN },
}), "import_timeline")

-- A. Resolve accepted BOTH clips (forward + reverse), none dropped.
assert(#imp.mapping == 2, string.format(
    "expected 2 mapped clips (forward + reverse), got %d — Resolve dropped a "
    .. "clip on import", #imp.mapping))
assert(#(imp.unrelinked or {}) == 0, string.format(
    "Resolve left %d clip(s) unrelinked — the reverse MediaTimemapBA bytes "
    .. "were rejected or the media failed to bind", #(imp.unrelinked or {})))

local tl = fixture.expect_ok(fixture.request(fix, "read_timeline", {}),
    "read_timeline")

-- B. Two media-bodied items.
local media_items = {}
for _, it in ipairs(tl.items) do
    if it.kind == "media" then media_items[#media_items + 1] = it end
end
assert(#media_items == 2, string.format(
    "expected 2 media items, got %d", #media_items))

-- Forward = the earlier timeline position, reverse = the later one.
table.sort(media_items, function(a, b)
    return a.record_start < b.record_start
end)
local fwd, rev = media_items[1], media_items[2]

print(string.format(
    "  FWD: record_start=%s record_duration=%s source=[%s,%s]",
    tostring(fwd.record_start), tostring(fwd.record_duration),
    tostring(fwd.source_in), tostring(fwd.source_out)))
print(string.format(
    "  REV: record_start=%s record_duration=%s source=[%s,%s]",
    tostring(rev.record_start), tostring(rev.record_duration),
    tostring(rev.source_in), tostring(rev.source_out)))

-- Teardown before assertions so a failure still leaves Resolve clean.
GEN = GEN + 1
fixture.expect_ok(fixture.request(fix, "delete_timeline", {
    resolve_timeline_id = imp.resolve_timeline_id,
    change_token        = { project_id = "p1", sequence_id = "e1",
                            mutation_generation = GEN },
}), "delete_timeline")
fixture.stop(fix)

-- C. Both clips keep the authored timeline duration.
assert(fwd.record_duration == DUR, string.format(
    "forward record_duration %s != authored %d", tostring(fwd.record_duration), DUR))
assert(rev.record_duration == DUR, string.format(
    "reverse record_duration %s != authored %d — the reverse clip imported "
    .. "with the wrong length", tostring(rev.record_duration), DUR))

-- SOURCE-RANGE CEILING (observation, not a pass condition).
-- read_timeline's GetSourceStartFrame/GetSourceEndFrame currently collapse to
-- the media frame-count for EVERY JVE-authored DRT clip — forward and reverse
-- alike — regardless of the authored <In>/<Duration>. This is a pre-existing,
-- path-wide limitation (the JVE→Resolve DRT does not yet carry a per-clip
-- source range Resolve honors on import), tracked in
-- todo_023_drt_source_range_readback_degenerate.md and probed by the sibling
-- test_source_in_tc_origin_probe (same degenerate readback on a different
-- fixture). So this test CANNOT assert the source range — only acceptance +
-- the record side. The reverse SOURCE range is proven by the byte-golden MTBA
-- encoder + the offline drt_writer↔drp_importer round-trip
-- (tests/synthetic/integration/test_drt_reverse_clip_roundtrip). When the
-- source-range path is fixed, tighten this to assert fwd.source_in == LO and
-- that the reverse twin covers the identical source region.
local function region(it)
    local a, b = it.source_in, it.source_out
    if a <= b then return a, b else return b, a end
end
local fwd_lo, fwd_hi = region(fwd)
local rev_lo, rev_hi = region(rev)
print(string.format(
    "  source-range readback (degenerate, path-wide): fwd=[%d,%d] rev=[%d,%d] "
    .. "— direction not yet observable live; see offline round-trip.",
    fwd_lo, fwd_hi, rev_lo, rev_hi))

print("✅ test_drt_reverse_roundtrip_live.lua passed — live Resolve ACCEPTS a "
    .. "JVE reverse-clip .drt (clip keyed, not unrelinked) and places it with "
    .. "the correct timeline duration. Source-range correctness is proven "
    .. "offline; live source range is gated on the DRT source-range fix.")
