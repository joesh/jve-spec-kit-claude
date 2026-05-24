-- Regression for Cat F (L2 dispatch findings): Copy/Paste of an AUDIO
-- clip must preserve subframe precision. Pre-fix symptom (TSO 2026-05-22):
-- pasting an audio clip raised "audio clip must have non-NULL
-- source_in_subframe and source_out_subframe" at apply_mutations because
-- the clipboard payload (and the paste clip_row builder) dropped both
-- subframe fields.
--
-- Black-box: after Copy + Paste, the pasted clip has the SAME subframes
-- as the original — independent of the implementation chosen (carry
-- through the clipboard, recompute from media_ref, whatever).

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.project_browser"] = false

local database = require("core.database")
local command_manager = require("core.command_manager")
local clipboard_actions = require("core.clipboard_actions")
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager = require("ui.focus_manager")

local db_path = "/tmp/jve/test_paste_audio_subframe_integrity.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Non-trivial subframes: 17321 and 39812 are arbitrary mid-frame fractions
-- (cannot be confused with 0). Master clock is 192000 Hz per project
-- settings; the values are within [0, master_clock_hz).
local SRC_IN_FRAME    = 50
local SRC_OUT_FRAME   = 170
-- Master clock 192000 Hz / 25 fps → 7680 ticks per frame. Subframes must
-- be in [0, 7680); pick non-zero/non-equal values that no implementation
-- would generate by accident.
local SRC_IN_SUBFRAME  = 1234
local SRC_OUT_SUBFRAME = 5678

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame, view_duration_frames,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq', 'proj', 'Timeline', 'sequence', 25, 1, 48000, 1920, 1080,
        0, 0, 8000, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med', 'proj', 'aud.wav', '/tmp/aud.wav', 1000,
        25, 1, 0, 0, 2, 'pcm_s16le', '{}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master_med', 'proj', 'med_master', 'master', 25, 1, NULL, NULL, NULL, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('master_a_med', 'master_med', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr_med', 'proj', 'master_med', 'master_a_med', 'med', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, %d, %d);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('clip_orig', 'proj', 'A', 'a1', 'seq', 'master_med',
        300, %d, %d, %d, %d, %d,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now,
    SRC_OUT_FRAME - SRC_IN_FRAME, SRC_IN_FRAME, SRC_OUT_FRAME,
    SRC_IN_SUBFRAME, SRC_OUT_SUBFRAME, now, now)))

command_manager.init("seq", "proj")

-- Sanity: the DB row really does carry the non-zero subframes.
local probe = db:prepare(
    "SELECT source_in_subframe, source_out_subframe FROM clips WHERE id='clip_orig'")
assert(probe:exec() and probe:next(), "precondition: clip_orig should exist in DB")
assert(probe:value(0) == SRC_IN_SUBFRAME and probe:value(1) == SRC_OUT_SUBFRAME,
    "precondition: clip_orig should carry the seeded subframes")
probe:finalize()

-- Pass a fully-formed clip stub to clipboard_actions: bypasses the
-- timeline_state population/refresh path so the test stays focused on
-- the Copy→Paste round-trip and the schema-level subframe contract.
local orig = {
    id              = "clip_orig",
    track_id        = "a1",
    sequence_id     = "master_med",
    owner_sequence_id = "seq",
    master_layer_track_id  = nil,
    master_audio_track_id  = nil,
    fps_mismatch_policy = "resample",
    track_type      = "AUDIO",
    sequence_start  = 300,
    duration        = SRC_OUT_FRAME - SRC_IN_FRAME,
    source_in       = SRC_IN_FRAME,
    source_out      = SRC_OUT_FRAME,
    source_in_subframe  = SRC_IN_SUBFRAME,
    source_out_subframe = SRC_OUT_SUBFRAME,
    name            = "A",
    frame_rate      = { fps_numerator = 25, fps_denominator = 1 },
}
timeline_state.get_selected_clips = function() return { orig } end
timeline_state.get_project_id     = function() return "proj" end
timeline_state.get_sequence_id    = function() return "seq" end
timeline_state.get_mark_in        = function() return nil end
timeline_state.get_mark_out       = function() return nil end
focus_manager.set_focused_panel("timeline")
focus_manager.set_focused_panel("timeline")
assert(clipboard_actions.copy(), "copy should succeed")

-- Paste at a new playhead position (frame 800)
timeline_state.set_playhead_position(800)
timeline_state.set_selection({})

local paste_ok, paste_err = clipboard_actions.paste()
assert(paste_ok, "Paste failed: " .. tostring(paste_err))

-- Find the pasted clip and verify subframes are preserved.
local stmt = db:prepare([[
    SELECT id, source_in_frame, source_out_frame,
           source_in_subframe, source_out_subframe
    FROM clips WHERE owner_sequence_id = 'seq' AND sequence_start_frame = 800
]])
assert(stmt:exec() and stmt:next(), "pasted clip should exist at frame 800")
local pasted_id        = stmt:value(0)
local pasted_in        = stmt:value(1)
local pasted_out       = stmt:value(2)
local pasted_in_sub    = stmt:value(3)
local pasted_out_sub   = stmt:value(4)
stmt:finalize()

assert(pasted_in == SRC_IN_FRAME, string.format(
    "pasted source_in_frame = %d, want %d", pasted_in, SRC_IN_FRAME))
assert(pasted_out == SRC_OUT_FRAME, string.format(
    "pasted source_out_frame = %d, want %d", pasted_out, SRC_OUT_FRAME))
assert(pasted_in_sub == SRC_IN_SUBFRAME, string.format(
    "pasted source_in_subframe = %s, want %d (Cat F bug: clipboard payload drops subframes)",
    tostring(pasted_in_sub), SRC_IN_SUBFRAME))
assert(pasted_out_sub == SRC_OUT_SUBFRAME, string.format(
    "pasted source_out_subframe = %s, want %d (Cat F bug)",
    tostring(pasted_out_sub), SRC_OUT_SUBFRAME))

print("✅ test_paste_audio_subframe_integrity passed (id=" .. pasted_id .. ")")
