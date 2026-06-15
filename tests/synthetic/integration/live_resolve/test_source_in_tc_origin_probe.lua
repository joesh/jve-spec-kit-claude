-- PROBE — empirically pin the source_in coordinate space across the
-- bridge (spec 023, FR-011c position channel).
--
-- The question this answers (and that NO existing test could, because
-- every other test drives source_in == 0-origin values):
--   JVE stores clip.source_in as ABSOLUTE source TC in native frames
--   (drp_importer: source_in_native = media_tc_origin + in_offset;
--   payload_builder.lua:20-21 says the same; the media's TC origin is
--   media:get_start_tc()). Resolve's TimelineItem:GetSourceStartFrame()
--   — what read_timeline returns as item.source_in — is documented
--   "start frame in source media": a 0-based MEDIA-RELATIVE frame
--   INDEX, independent of the file's embedded TC tag.
--   => Whenever a media's TC origin is non-zero the two diverge by
--      exactly media_tc_origin, and the position channel (which
--      compares them raw) can never content-match. This probe MEASURES
--      that delta on a live Resolve to confirm the transform before the
--      fix lands.
--
-- Media: the 23.976fps A005 fixture, which carries a REAL embedded TC of
--   01:00:00:00. The shared db_fixture builds the clip with empty
--   metadata, so media:get_start_tc() extracts that origin from the file
--   itself (EMP) — the same origin the send path passes and Resolve reads
--   off the same file. The clip is trimmed IN_OFFSET frames in, so its
--   JVE absolute source_in = TC_ORIGIN + IN_OFFSET. After SendToResolve +
--   read_timeline we expect Resolve to report source_in == IN_OFFSET
--   (media-relative). If instead it reports the absolute value, the
--   diagnosis is wrong and NO normalization is needed — either way the
--   printed numbers are the ground truth.
--
-- ⚠ State-changing on the CURRENT Resolve project (imports + deletes a
-- fixture timeline): VM test environment only.
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_source_in_tc_origin_probe

local test_env = require("test_env")
local command_manager = require("core.command_manager")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local driver = require(
    "synthetic.integration.live_resolve.command_driver")
local db_fixture = require(
    "synthetic.integration.live_resolve.live_db_fixture")

-- 23.976fps A005 fixture carrying a REAL embedded TC of 01:00:00:00.
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local IN_OFFSET = 30                       -- trim 30 frames into media

-- ── DB fixture: one clip trimmed IN_OFFSET frames into the media, so
-- its absolute source_in = media_tc_origin + IN_OFFSET (the helper
-- asserts the embedded origin extracts non-zero) ────────────────────
local ctx = db_fixture.build_a005_trimmed_db({
    db_path = "/tmp/jve/test_source_in_tc_origin_probe.db",
    media_path = MEDIA_PATH, in_offset = IN_OFFSET,
})
local TC_ORIGIN = ctx.tc_origin
local ABS_SOURCE_IN = ctx.abs_source_in

command_manager.init("e1", "p1")
supervisor.configure(
    driver.repo_root() .. "/tools/resolve-helper/helper.py")
driver.skip_unless_live("test_source_in_tc_origin_probe")

print(string.format(
    "  JVE side: media embedded TC origin=%d frames, clip absolute "
    .. "source_in=%d (== origin + in_offset %d)",
    TC_ORIGIN, ABS_SOURCE_IN, IN_OFFSET))

-- ── send the single clip, then read the live timeline back ──────────
local send = driver.run_bridge_command("SendToResolve",
    "send_to_resolve_completed", { project_id = "p1", sequence_id = "e1" })
assert(#send.result.mapping == 1 and #send.result.unrelinked == 0,
    string.format("probe send: expected 1 mapped / 0 unrelinked, got "
        .. "%d/%d", #send.result.mapping, #send.result.unrelinked))
local tl = send.result.resolve_timeline_id
local resolve_item_id = send.result.mapping[1].resolve_item_id
print("  ✓ send: 1 clip mapped, timeline " .. tl)

local rt = driver.helper_request("read_timeline", {})
local probe_item
for _, item in ipairs(rt.items) do
    if item.resolve_item_id == resolve_item_id then probe_item = item end
end
assert(probe_item, "probe: sent item not found in read_timeline")

local resolve_source_in = probe_item.source_in
local delta = ABS_SOURCE_IN - resolve_source_in
print(string.format(
    "  Resolve side: GetSourceStartFrame (read_timeline source_in)=%s",
    tostring(resolve_source_in)))
print(string.format(
    "  DELTA (JVE absolute %d − Resolve %s) = %s   [tc_origin=%d]",
    ABS_SOURCE_IN, tostring(resolve_source_in), tostring(delta),
    TC_ORIGIN))

-- ── teardown BEFORE the verdict assert, so a failed expectation does
-- not leak the fixture timeline on the live Resolve ─────────────────
local del = driver.helper_request("delete_timeline", {
    resolve_timeline_id = tl,
    change_token = driver.fresh_token("p1", "e1"),
})
assert(del.deleted == true, "probe teardown: delete failed")
print("  ✓ teardown: fixture timeline deleted")
-- Shut the supervisor down BEFORE the verdict asserts too, so a failed
-- expectation never leaks the helper subprocess.
supervisor.shutdown()

-- ── verdict ─────────────────────────────────────────────────────────
-- Expectation derived from Resolve API semantics + TC math (NOT by
-- tracing JVE code): GetSourceStartFrame is media-relative, so it must
-- equal IN_OFFSET, and the delta must equal the embedded TC origin.
assert(resolve_source_in == IN_OFFSET, string.format(
    "PROBE RESULT: expected media-relative source_in == in_offset %d, "
    .. "got %s. If this fired, Resolve's source_in is NOT plain "
    .. "media-relative — re-examine the transform before coding the fix.",
    IN_OFFSET, tostring(resolve_source_in)))
assert(delta == TC_ORIGIN, string.format(
    "PROBE RESULT: JVE-absolute minus Resolve-relative must equal the "
    .. "embedded TC origin %d; got %d", TC_ORIGIN, delta))

print(string.format(
    "✅ PROBE CONFIRMED: Resolve source_in is media-relative; JVE "
    .. "absolute source_in exceeds it by exactly media_tc_origin (%d "
    .. "frames). Position channel must normalize "
    .. "clip.source_in − media_tc_origin before comparing.", TC_ORIGIN))
