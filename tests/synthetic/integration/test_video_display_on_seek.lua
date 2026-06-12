-- Integration: the video the operator SEES on a park-seek, against REAL
-- bindings (real engine, real TMB, real decoded media, real GPU surface).
--
-- REPLACES (from tests/synthetic/lua/):
--   test_playback_video_display.lua
--
-- The original was black-box in intent (observe the surface) but mocked the
-- whole world: a fake SURFACE_SET_FRAME captured "frame_<N>" strings, a fake
-- Renderer manufactured those strings, a fake Sequence/Track supplied clip
-- coverage, and a fake PLAYBACK.SEEK re-ran the fake renderer. It verified
-- mock routing, not real frame delivery.
--
-- This version drives the real PlaybackEngine over a real timeline and
-- records what the engine actually hands the VIEW through its real
-- on_show_frame / on_show_gap callbacks — the genuine MVC park-pull seam
-- (seek → PARK → Renderer pull → on_show_frame|on_show_gap). The frame
-- handles are opaque userdata decoded from real media; we never inspect
-- their contents, only identity (same vs different) and presence, which is
-- exactly what the surface would show.
--
-- DOMAIN RULES PINNED (MVC park-pull):
--   VD-1  Seeking onto clip coverage delivers a real (non-nil) video frame
--         to the view — the operator sees picture, not black.
--   VD-2  Seeking to a DIFFERENT in-coverage position delivers a DIFFERENT
--         frame — the picture tracks the playhead (no stale freeze-frame).
--   VD-3  Seeking past content (into a gap) delivers a gap to the view —
--         the operator sees black, not the last clip's stale frame.
--
-- SCENARIOS MAP (original → here):
--   §1 "seek after load → non-black frame"  → VD-1
--   §2 "seek → surface frame changes"        → VD-2
--   §3 "seek into gap → black"               → VD-3
--   (original Test 3 "play shows advancing frames" was already deleted in the
--    stub because C++ CVDisplayLink drives play; play-delivery is pinned by
--    test_playback_av_sync.lua. Nothing to carry.)
--
-- OPEN QUESTIONS:
--   None.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_video_display_on_seek.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_video_display_on_seek.lua ===")

require("test_env")
local database     = require("core.database")
local transport    = require("core.playback.transport")
local qt_constants = require("core.qt_constants")

-- ── Fixture: a timeline with a VIDEO clip covering [0,96) and a gap after.
local DB = "/tmp/jve/test_video_display_seek.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
local media_path = ienv.test_media_path(ienv.STANDARD_MEDIA)
assert(db:exec(string.format([[
    INSERT INTO projects (id,name,fps_mismatch_policy,settings,created_at,modified_at)
      VALUES ('p','P','resample','{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO media (id,project_id,file_path,name,duration_frames,fps_numerator,fps_denominator,
        width,height,audio_channels,audio_sample_rate,created_at,modified_at)
      VALUES ('m1','p',%q,'A005',108,24000,1001,640,360,2,48000,%d,%d);
    INSERT INTO sequences (id,project_id,name,kind,fps_numerator,fps_denominator,audio_sample_rate,
        width,height,playhead_frame,view_start_frame,view_duration_frames,start_timecode_frame,created_at,modified_at)
      VALUES ('rec','p','Rec','sequence',24000,1001,48000,640,360,0,0,300,0,%d,%d);
    INSERT INTO tracks (id,sequence_id,name,track_type,track_index,enabled)
      VALUES ('rec_v1','rec','V1','VIDEO',1,1);
]], now, now, media_path, now, now, now, now)))
local master_id = require("test_env").create_test_masterclip_sequence(
    "p", "A005", 24000, 1001, 108, "m1")
-- VIDEO clip covers timeline [0,96); source span offset from zero (4..100) so
-- the source mapping is non-trivial. Everything at/after frame 96 is a gap.
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, fps_mismatch_policy, volume, playhead_frame, created_at, modified_at)
    VALUES ('c_v','p','V','rec_v1','%s','rec',0,96,4,100,1,'resample',1.0,0,%d,%d)
]], master_id, now, now)))

-- ── Record what the engine delivers to the VIEW (real callbacks). These are
--    the exact callbacks SequenceMonitor wires; we record, not fake.
local last_frame_handle = nil
local frame_deliveries  = 0
local gap_deliveries    = 0

if transport.is_bootstrapped() then transport.shutdown() end
transport.init("p")
transport.bind_role_to_sequence("record", "rec")
local rec = transport.engine_for_role("record")

-- Override the engine's view callbacks with recorders that ALSO mirror what
-- the real SequenceMonitor does (push the handle at a real GPU surface), so
-- the full delivery path runs. We replace only this engine instance's
-- closures (its own observable seam), not any shared module function.
local surf = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
assert(surf, "GPU surface creation failed — environment defect")
rec:set_surface(surf)
rec._on_show_frame = function(frame_handle, _meta)
    assert(frame_handle ~= nil, "on_show_frame called with nil handle")
    last_frame_handle = frame_handle
    frame_deliveries = frame_deliveries + 1
    qt_constants.EMP.SURFACE_SET_FRAME(surf, frame_handle)
end
rec._on_show_gap = function()
    last_frame_handle = nil
    gap_deliveries = gap_deliveries + 1
    qt_constants.EMP.SURFACE_SET_FRAME(surf, nil)
end

-- Park-pull is synchronous on seek, but the underlying reader decodes on a
-- worker; retry the seek until a real frame is delivered (or until we're
-- confident it's a gap). Returns the handle delivered for the position.
local function seek_and_get_frame(frame)
    local before_f, before_g = frame_deliveries, gap_deliveries
    local handle
    ienv.wait_until(function()
        rec:seek(frame)
        if frame_deliveries > before_f then
            handle = last_frame_handle
            return true
        end
        if gap_deliveries > before_g then
            -- A gap delivery is a definitive negative; let the caller decide.
            return true
        end
        return false
    end, 5, "frame delivery for seek(" .. frame .. ")")
    return handle
end

-- ════════════════════════════════════════════════════════════════════════════
-- VD-1  Seek onto coverage → real video frame reaches the view.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (VD-1) seek onto coverage delivers a real frame --")
local frame_at_10
do
    frame_at_10 = seek_and_get_frame(10)
    assert(frame_deliveries >= 1,
        "VD-1: engine must deliver a video frame to the view after seek onto coverage")
    assert(frame_at_10 ~= nil,
        "VD-1: delivered frame handle must be non-nil (operator sees picture, not black)")
    print("  PASS: seek(10) delivered a real frame to the view")
end

-- ════════════════════════════════════════════════════════════════════════════
-- VD-2  Seek to a different in-coverage position → different frame.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (VD-2) seek elsewhere delivers a different frame --")
do
    local frame_at_60 = seek_and_get_frame(60)
    assert(frame_at_60 ~= nil,
        "VD-2: seek to second position must deliver a non-nil frame")
    assert(frame_at_60 ~= frame_at_10, string.format(
        "VD-2: a different playhead must yield a different frame — the picture "
        .. "must track the playhead, not freeze. seek(10) and seek(60) gave the "
        .. "same handle (%s)", tostring(frame_at_10)))
    print("  PASS: seek(60) delivered a frame distinct from seek(10)")
end

-- ════════════════════════════════════════════════════════════════════════════
-- VD-3  Seek past content (into a gap) → black, not a stale frame.
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (VD-3) seek into gap delivers black --")
do
    local gaps_before = gap_deliveries
    -- Frame 200 is past the clip's [0,96) coverage but within the sequence's
    -- 300-frame view extent — a genuine gap.
    rec:seek(200)
    -- Park-pull resolves the gap synchronously (no clip to decode), so one
    -- pump is enough to flush any queued work; assert the gap reached the view.
    qt_constants.CONTROL.PROCESS_EVENTS()
    assert(gap_deliveries > gaps_before,
        "VD-3: seeking into a gap must deliver a gap (black) to the view")
    assert(last_frame_handle == nil,
        "VD-3: after a gap delivery the view must hold no stale frame handle")
    print("  PASS: seek(200) delivered a gap (black) to the view")
end

rec:stop()
transport.shutdown()
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")

print("\nPASS test_video_display_on_seek.lua")
os.exit(0)
