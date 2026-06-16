-- REGRESSION — a JVE-authored .drt for a trimmed clip must import into live
-- Resolve with a MEDIA-RELATIVE source range, NOT clamped to media-end.
--
-- Root cause (decode-confirmed 2026-06-14, now fixed): the Sm2MpVideoClip
-- media-pool item's <Time> blob must carry a `Timecode` entry = the media's
-- embedded source-TC origin ("01:00:00:00" for the A005 fixture). JVE used to
-- borrow the blob verbatim from a zero-origin template (5 entries, no
-- Timecode), so Resolve couldn't map the timeline item's media-relative <In>
-- onto the source and pinned GetSourceStartFrame to NumFrames (108 on the
-- 108-frame fixture). The fix synthesizes the Time blob with the Timecode
-- entry from media.start_tc_frame (drt_binary.encode_bt_video_time +
-- drt_writer.build_media_pool_video_item). Bisection that isolated the field:
-- /tmp/blobwork/decode_mptime.lua; live before/after: 108 → 29.
--
-- Resolve's GetSourceStartFrame runs ~1 below the authored frame (its OWN
-- in=30 clip reads 29 — test_drt_source_in_resolve_authored), so the
-- media-relative target is IN_OFFSET or IN_OFFSET-1; what matters is that it
-- is media-internal, never the media-end clamp.
--
-- ⚠ State-changing (imports + deletes a throwaway timeline). VM only.
-- Run via: scripts/run_live_resolve_test.sh test_drt_mptime_timecode_clamp

local test_env = require("test_env")
local payload_builder = require("core.resolve_bridge.payload_builder")
local drt_writer      = require("exporters.drt_writer")
local fixture  = require("synthetic.integration.live_resolve.live_fixture")
local db_fixture = require("synthetic.integration.live_resolve.live_db_fixture")

local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local IN_OFFSET, DUR, MEDIA_FRAMES = 30, 24, 108

-- ── author the JVE .drt through the real export path ────────────────
local ctx = db_fixture.build_a005_trimmed_db({
    db_path = "/tmp/jve/test_mptime_timecode.db", media_path = MEDIA_PATH,
    in_offset = IN_OFFSET, dur = DUR,
})
local DRT = "/tmp/jve/mptime_regression.drt"
os.remove(DRT)
local payload = payload_builder.build(ctx.db, "p1", "e1")
local authored = drt_writer.author_a005_compatible(DRT, payload)

local media_paths, seen = {}, {}
for _, ref in ipairs(payload.media_refs) do
    if not seen[ref.file_path] then
        seen[ref.file_path] = true
        media_paths[#media_paths + 1] = ref.file_path
    end
end

-- ── import + read source ────────────────────────────────────────────
local fix = fixture.start("/tmp/jve-live-mptime.sock")
fixture.skip_unless_live(fix, "test_drt_mptime_timecode_clamp")

local imp = fixture.expect_ok(fixture.request(fix, "import_timeline", {
    drt_path = DRT, media_paths = media_paths,
    clip_positions = authored.emit_order,
    change_token = { project_id = "p1", sequence_id = "e1",
                     mutation_generation = 1 },
}), "import")
local tl = fixture.expect_ok(fixture.request(fix, "read_timeline", {}), "read")
local src_in
for _, it in ipairs(tl.items) do
    if it.kind == "media" then src_in = it.source_in end
end
fixture.expect_ok(fixture.request(fix, "delete_timeline", {
    resolve_timeline_id = imp.resolve_timeline_id,
    change_token = { project_id = "p1", sequence_id = "e1",
                     mutation_generation = 2 },
}), "delete")
fixture.stop(fix)

print(string.format("  GetSourceStartFrame = %s (authored in=%d, media=%d frames)",
    tostring(src_in), IN_OFFSET, MEDIA_FRAMES))

-- ── verdict ─────────────────────────────────────────────────────────
assert(src_in ~= MEDIA_FRAMES, string.format(
    "REGRESSION: source clamped to media-end (%d) — the Sm2MpVideoClip Time "
    .. "blob lost its Timecode entry (drt_binary.encode_bt_video_time / "
    .. "drt_writer.build_media_pool_video_item)", MEDIA_FRAMES))
assert(src_in == IN_OFFSET or src_in == IN_OFFSET - 1, string.format(
    "source=%s is neither %d nor %d (Resolve's media-relative ±1) — "
    .. "unexpected mapping", tostring(src_in), IN_OFFSET, IN_OFFSET - 1))
print(string.format(
    "✅ source range media-relative (%d), NOT clamped to media-end %d — "
    .. "Timecode synthesis holds.", src_in, MEDIA_FRAMES))
