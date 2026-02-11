#!/usr/bin/env luajit

-- IS-a refactor: masterclips are now sequences with kind="masterclip"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local Media = require("models.media")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")

local SCHEMA_SQL = require("import_schema")

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline',
            24, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES
        ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]]

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec(BASE_DATA_SQL))
    command_manager.init("default_sequence", "default_project")
    return db
end

local db = setup_database("/tmp/jve/test_overwrite_rescales_master_clip.db")

-- Create media at 25fps
local media = Media.create({
    id = "media_25fps",
    project_id = "default_project",
    file_path = "/tmp/jve/media_25fps.mov",
    name = "25fps media",
    duration_frames = 2500,
    fps_numerator = 25,
    fps_denominator = 1,
})
assert(media:save(db))

-- IS-a refactor: create masterclip sequence (not a Clip with clip_kind="master")
local masterclip_seq = Sequence.create("Master 25fps", "default_project",
    {fps_numerator = 25, fps_denominator = 1},
    1920, 1080,
    {id = "masterclip_seq_25fps", kind = "masterclip"})
assert(masterclip_seq:save())

-- Create video track in masterclip sequence
local master_video_track = Track.create_video("V1", masterclip_seq.id, {id = "masterclip_video_track"})
assert(master_video_track:save())

-- Create stream clip in masterclip sequence
local stream_clip = Clip.create("25fps Video", media.id, {
    id = "masterclip_stream_clip",
    project_id = "default_project",
    track_id = master_video_track.id,
    owner_sequence_id = masterclip_seq.id,
    timeline_start = 0,
    duration = 2500,
    source_in = 0,
    source_out = 2500,
    fps_numerator = 25,
    fps_denominator = 1,
})
assert(stream_clip:save({skip_occlusion = true}))

local overwrite_cmd = Command.create("Overwrite", "default_project")
overwrite_cmd:set_parameter("track_id", "video1")
overwrite_cmd:set_parameter("overwrite_time", 0)
overwrite_cmd:set_parameter("master_clip_id", masterclip_seq.id)  -- Now a sequence ID
overwrite_cmd:set_parameter("project_id", "default_project")
overwrite_cmd:set_parameter("sequence_id", "default_sequence")
overwrite_cmd:set_parameter("advance_playhead", false)

local result = command_manager.execute(overwrite_cmd)
assert(result.success, result.error_message or "Overwrite failed")

local q = db:prepare([[
    SELECT duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator
    FROM clips
    WHERE track_id = 'video1' AND clip_kind = 'timeline'
]])
assert(q:exec() and q:next(), "Expected exactly one timeline clip on video1")

local duration_frames = q:value(0)
local source_in_frame = q:value(1)
local source_out_frame = q:value(2)
local fps_num = q:value(3)
local fps_den = q:value(4)
assert(not q:next(), "Expected exactly one timeline clip on video1")
q:finalize()

-- clip.duration is in TIMELINE frames (sequence timebase), not source frames
-- Source is 2500 frames at 25fps = 100 seconds
-- Timeline is 24fps, so 100 seconds = 2400 timeline frames
local expected_timeline_duration = math.floor(2500 * 24 / 25 + 0.5)  -- 2400
assert(duration_frames == expected_timeline_duration, string.format(
    "Expected timeline duration %d (source 2500@25fps on 24fps timeline), got %s",
    expected_timeline_duration, tostring(duration_frames)))
-- Source bounds stay in source units (for playback)
assert(source_in_frame == 0 and source_out_frame == 2500, string.format("Expected source bounds to remain 0-2500 @25fps, got %s-%s", tostring(source_in_frame), tostring(source_out_frame)))
-- clip.rate preserves source fps (needed for source_in/out interpretation)
assert(fps_num == 25 and fps_den == 1, string.format("Expected clip rate to preserve source fps 25/1, got %s/%s", tostring(fps_num), tostring(fps_den)))

print("✅ Overwrite converts duration to timeline frames, preserves source bounds and rate")

