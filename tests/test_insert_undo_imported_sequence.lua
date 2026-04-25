#!/usr/bin/env luajit

-- Regression: inserting into a non-default sequence must undo cleanly.
-- The pre-fix bug routed undo/redo through the default sequence, so the
-- inserted clip persisted after undo.
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require("models.media")
local Clip = require("models.clip")
require('ui.timeline.timeline_state')  -- ensure real module loaded before command_manager.init

local TEST_DB = "/tmp/jve/test_insert_undo_imported_sequence.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES
        ('default_sequence', 'default_project', 'Default Sequence', 'nested',
         30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d),
        ('imported_sequence', 'default_project', 'Imported Sequence', 'timeline',
         30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES
        ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('imported_v1', 'imported_sequence', 'Imported V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now, now, now))

local media_existing = Media.create({
    id = "media_existing",
    project_id = "default_project",
    name = "Existing Clip",
    file_path = "synthetic://existing",
    duration_frames = 150,
    frame_rate = 30,
    width = 1920,
    height = 1080,
    created_at = now,
    modified_at = now
})
assert(media_existing and media_existing:save(db))

-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_existing")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_existing", "default_project")

local media_insert = Media.create({
    id = "media_insert",
    project_id = "default_project",
    name = "Insert Clip",
    file_path = "synthetic://insert",
    duration_frames = 135000,
    frame_rate = 30,
    width = 1920,
    height = 1080,
    created_at = now,
    modified_at = now
})
assert(media_insert and media_insert:save(db))

-- IS-a refactor: create masterclip sequence for the media
local Sequence = require("models.sequence")
local Track = require("models.track")

local masterclip_seq = Sequence.create("Insert Clip Master", "default_project",
    { fps_numerator = 30, fps_denominator = 1},
    1920, 1080,
    { audio_rate = 48000,id = "masterclip_insert", kind = "master"})
assert(masterclip_seq:save())

local master_video_track = Track.create_video("V1", masterclip_seq.id, {id = "masterclip_insert_v1"})
assert(master_video_track:save())

local stream_clip = Clip.create({
        name = "Insert Clip Video",
        id = "masterclip_insert_stream",
        project_id = "default_project",
        track_id = master_video_track.id,
        owner_sequence_id = masterclip_seq.id,
        timeline_start_frame = 0,
        duration_frames = 4543560,
        source_in_frame = 0,
        source_out_frame = 4543560,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
assert(stream_clip:save({skip_occlusion = true}))

local base_clip = Clip.create({
        name = "Existing Clip",
        id = "clip_existing",
        project_id = "default_project",
        nested_sequence_id = MC_TEST,
        track_id = "imported_v1",
        owner_sequence_id = "imported_sequence",
        timeline_start_frame = 0,
        duration_frames = 5000,
        source_in_frame = 0,
        source_out_frame = 5000,
        enabled = 1,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
assert(base_clip and base_clip:save(db))

command_manager.init('default_sequence', 'default_project')

local function clip_count(sequence_id)
    local stmt = db:prepare([[
        SELECT COUNT(*)
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
    ]])
    assert(stmt, "Failed to prepare clip count query")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next(), "Failed to execute clip count query")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local baseline = clip_count('imported_sequence')
assert(baseline == 1, string.format("Expected baseline clip count 1, got %d", baseline))

local insert_cmd = Command.create("Insert", 'default_project')
insert_cmd:set_parameter("nested_sequence_id", "masterclip_insert")
insert_cmd:set_parameter("sequence_id", "imported_sequence")
insert_cmd:set_parameter("track_id", "imported_v1")
insert_cmd:set_parameter("timeline_start_frame", 111400)
insert_cmd:set_parameter("duration", 4543560)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 4543560)
insert_cmd:set_parameter("advance_playhead", true)

local execute_result = command_manager.execute(insert_cmd)
assert(execute_result.success, "Insert command should succeed")

local after_insert = clip_count('imported_sequence')
assert(after_insert == baseline + 1,
    string.format("Insert should add a clip (expected %d, got %d)", baseline + 1, after_insert))

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed")

local after_undo = clip_count('imported_sequence')
assert(after_undo == baseline,
    string.format("Undo should restore clip count to baseline (expected %d, got %d)", baseline, after_undo))

local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed")

local after_redo = clip_count('imported_sequence')
assert(after_redo == baseline + 1,
    string.format("Redo should reapply insert (expected %d, got %d)", baseline + 1, after_redo))

print("✅ Insert undo/redo respects active imported sequence")
