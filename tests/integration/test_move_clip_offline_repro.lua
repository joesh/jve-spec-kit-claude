-- Integration repro: moving an OFFLINE clip cross-track must keep it offline.
--
-- Drives the FULL live path (which pure Lua tests can't reach):
--   * real timeline_state tab cache (clips loaded via db.load_clips),
--   * a real media_status_changed flip (offline=true) → timeline_core_state
--     stamps clip.offline on the cached clip,
--   * the real MoveClipToTrack command routed through
--     timeline_state.apply_mutations into the tab cache,
--   * the renderer's per-frame ensure_clip_status call.
--
-- Reported symptom (Joe, 2026-05-28): cross-track (vertical) move clears the
-- offline indicator permanently. This test asserts it does NOT. Run with:
--   JVE_LOG=media:event,timeline:event \
--     ./build/bin/jve.app/Contents/MacOS/jve --test \
--     tests/integration/test_move_clip_offline_repro.lua
-- and grep the output for "OFFLINE-DBG" to see which writer clears offline.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

local database        = require("core.database")
local command_manager = require("core.command_manager")
local media_status    = require("core.media.media_status")
local timeline_state  = require("ui.timeline.timeline_state")

print("=== test_move_clip_offline_repro.lua ===")

local DB_PATH = "/tmp/jve/test_move_clip_offline_repro_" .. os.time() .. ".db"
os.remove(DB_PATH)
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH))
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local MEDIA_PATH = "/tmp/jve/gone_" .. os.time() .. ".mov"

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('e', 'p', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0),
           ('m', 'p', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1),
           ('e-v2', 'e', 'V2', 'VIDEO', 2),
           ('m-v1', 'm', 'V1', 'VIDEO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
    VALUES ('med', 'p', 'gone.mov', '%s', 2000, 24, 1, 0, 0, 0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'p', 'm', 'm-v1', 'med', 0, 2000, 0, 2000, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, name,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, fps_mismatch_policy, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('clip1', 'p', 'e', 'e-v1', 'm', 'clip1', 100, 200, 0, 200,
        NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
]], MEDIA_PATH))

-- Load the sequence into the live timeline (real tab cache).
command_manager.init("e", "p")
timeline_state.init("e", "p")

local strip = timeline_state.get_tab_strip()
assert(strip, "tab strip must exist after timeline_state.init")

local function tab_clip()
    local c = strip:clip_by_id("clip1")
    assert(c, "clip1 must be in the displayed tab cache")
    return c
end

assert(tab_clip().media_path == MEDIA_PATH, string.format(
    "fixture: cached clip must carry media_path (got %s)", tostring(tab_clip().media_path)))

-- Flip the media offline through the real status path (mirrors the FS
-- watcher / TMB flip). timeline_core_state's media_status_changed handler
-- stamps clip.offline on every open tab's cached clips.
media_status.update_from_tmb(MEDIA_PATH, true, "FileNotFound")
assert(tab_clip().offline == true, string.format(
    "precondition: cached clip must be offline after media_status flip (got %s)",
    tostring(tab_clip().offline)))
print("  ✓ clip is offline in the tab cache before the move")

-- Cross-track (vertical) move V1 → V2 through the real command + dispatch.
command_manager.begin_command_event("script")
local r1, r2 = command_manager.execute("MoveClipToTrack", {
    project_id      = "p",
    sequence_id     = "e",
    clip_id         = "clip1",
    target_track_id = "e-v2",
})
command_manager.end_command_event()
local res = r1 or r2
assert(res and res.success, "MoveClipToTrack should succeed: "
    .. tostring(res and res.error_message))

local moved = tab_clip()
assert(moved.track_id == "e-v2", "clip should be on V2 after move, got " .. tostring(moved.track_id))

-- The renderer calls this per frame; simulate one cycle.
media_status.ensure_clip_status(moved)

assert(moved.offline == true, string.format(
    "BUG REPRODUCED (move): cross-track move cleared offline "
    .. "(offline=%s, media_path=%s) — see OFFLINE-DBG logs",
    tostring(moved.offline), tostring(moved.media_path)))
print("  ✓ clip remains offline in the tab cache after cross-track move")

-- ── Undo path: delete the offline clip, then UNDO. The restored clip must
-- still read offline in the tab cache. (Undo-restore re-inserts the clip
-- into the cache via an insert-entry builder; if that entry omits the
-- media-status denorm, the restored clip wrongly renders online.) ─────────
command_manager.begin_command_event("script")
local d1, d2 = command_manager.execute("DeleteClip", {
    project_id = "p", sequence_id = "e", clip_id = "clip1",
})
command_manager.end_command_event()
local dres = d1 or d2
assert(dres and dres.success, "DeleteClip should succeed: " .. tostring(dres and dres.error_message))
assert(strip:clip_by_id("clip1") == nil, "clip removed from tab cache after delete")

command_manager.begin_command_event("script")
local u1, u2 = command_manager.undo()
command_manager.end_command_event()
local ures = u1 or u2
assert(ures and ures.success, "undo should succeed: " .. tostring(ures and ures.error_message))

local restored = strip:clip_by_id("clip1")
assert(restored, "clip restored to tab cache after undo")
media_status.ensure_clip_status(restored)
assert(restored.offline == true, string.format(
    "BUG REPRODUCED (undo): undo of delete cleared offline "
    .. "(offline=%s, media_path=%s) — see OFFLINE-DBG logs",
    tostring(restored.offline), tostring(restored.media_path)))
print("  ✓ clip remains offline in the tab cache after delete+undo")

print("\n✅ test_move_clip_offline_repro.lua passed")
