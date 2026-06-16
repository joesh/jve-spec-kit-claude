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
local Clip            = require("models.clip")
local payload_builder = require("core.resolve_bridge.payload_builder")
local drt_writer      = require("exporters.drt_writer")
local fixture         = require(
    "synthetic.integration.live_resolve.live_fixture")
local db_fixture      = require(
    "synthetic.integration.live_resolve.live_db_fixture")

-- 23.976fps A005 fixture with real embedded TC (108 video frames) — the
-- writer's author_a005_compatible path requires 23.976 media. Frame rate and
-- media frame-count are the build_a005_trimmed_db defaults.
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")

-- The shared played source window (file-relative frames) and its length.
local LO  = 20                 -- lowest played source frame
local DUR = 60                 -- frames; HI = LO + DUR - 1 = 79
local HI  = LO + DUR - 1
local FWD_START = 120          -- forward clip's timeline position
local REV_START = 300          -- reverse twin's timeline position (separated)

-- ── DB fixture ──────────────────────────────────────────────────────────
-- The shared scaffold (project / master+editing sequence / track / A005 media
-- / media_refs) AND the forward clip come from build_a005_trimmed_db — the
-- forward clip's played window IS [LO..HI], exactly the fixture's trimmed
-- clip. We then add ONLY the reverse twin on the same media.
local ctx = db_fixture.build_a005_trimmed_db({
    db_path = "/tmp/jve/test_drt_reverse_roundtrip_live.db",
    media_path = MEDIA_PATH, in_offset = LO, dur = DUR, seq_start = FWD_START,
})
local db = ctx.db
local TC_ORIGIN = ctx.tc_origin

-- REVERSE twin: same source frames played backward. source_in = highest played
-- (inclusive), source_out = lowest played minus one (exclusive).
local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
assert(Clip.create({
    id = "0b50c0de-7007-4aaa-8aaa-000000000002", project_id = "p1",
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

local media_paths = fixture.unique_media_paths(payload)

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

-- D + E. SOURCE RANGE (live, now that the DRT source-range path is fixed).
-- The clamp that collapsed every clip's GetSourceStartFrame/EndFrame to the
-- media frame-count is resolved (Sm2MpVideoClip <Time> Timecode entry now
-- synthesized from the media's source-TC origin — commits 13cff8b8/3db28783,
-- todo_023_drt_source_range_readback_degenerate). So Resolve maps the authored
-- file-relative <In> onto the source and we can finally assert it.
--
-- Resolve's GetSourceStartFrame reads ~1 below the authored frame (its OWN
-- in=N clip reads N−1 — test_drt_source_in_resolve_authored / the
-- test_drt_mptime_timecode_clamp control), so every source bound is compared
-- with a ±1 tolerance. Values are file-relative (the writer subtracts
-- media.start_tc_frame): both clips play [LO..HI], so each must read back that
-- region. Both bounds of both clips are checked against the DOMAIN constants
-- (LO/HI) independently — not relative to each other — so a shared truncation
-- (e.g. both clips clamped to a wrong high bound) cannot hide.
local function region(it)
    local a, b = it.source_in, it.source_out
    if a <= b then return a, b else return b, a end
end
local fwd_lo, fwd_hi = region(fwd)
local rev_lo, rev_hi = region(rev)
print(string.format(
    "  source-range readback: fwd=[%d,%d] rev=[%d,%d] (LO=%d HI=%d)",
    fwd_lo, fwd_hi, rev_lo, rev_hi, LO, HI))

local function assert_region(label, lo, hi)
    assert(math.abs(lo - LO) <= 1 and math.abs(hi - HI) <= 1, string.format(
        "%s source region [%d,%d] != authored [%d,%d] (±1 Resolve rounding) — "
        .. "the file-relative <In>/<Out> was not honored on import",
        label, lo, hi, LO, HI))
end

-- D. Forward clip occupies the authored played window [LO..HI].
assert_region("forward", fwd_lo, fwd_hi)
-- E. Reverse twin plays the SAME source frames, so it occupies [LO..HI] too.
assert_region("reverse twin", rev_lo, rev_hi)
-- Cross-check (already implied by D+E, kept as a direct equality signal): the
-- two twins land on the same region.
assert(math.abs(rev_lo - fwd_lo) <= 1 and math.abs(rev_hi - fwd_hi) <= 1,
    string.format("reverse region [%d,%d] != forward [%d,%d]",
        rev_lo, rev_hi, fwd_lo, fwd_hi))

-- Records (does NOT gate) whether Resolve mirrored in/out for the reverse clip.
if rev.source_in > rev.source_out then
    print("  reverse clip reports source_in > source_out — Resolve mirrored "
        .. "the in/out ordering (live direction confirmation).")
else
    print("  reverse clip reports source_in <= source_out — Resolve did NOT "
        .. "mirror in/out ordering; direction carried only by the MTBA curve.")
end

print("✅ test_drt_reverse_roundtrip_live.lua passed — live Resolve ACCEPTS a "
    .. "JVE reverse-clip .drt (keyed, not unrelinked), places it with the "
    .. "correct timeline duration, honors the forward in-point (LO), and the "
    .. "reverse twin occupies the same source region as its forward twin.")
