#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local Media = require("models.media")
local Clip = require("models.clip")
local Rational = require("core.rational")

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

local db = setup_database("/tmp/jve/test_insert_rescales_master_clip.db")

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

local master = Clip.create("Master", media.id, {
    id = "master_clip_25fps",
    clip_kind = "master",
    project_id = "default_project",
    timeline_start = Rational.new(0, 25, 1),
    duration = Rational.new(2500, 25, 1),
    source_in = Rational.new(0, 25, 1),
    source_out = Rational.new(2500, 25, 1),
    fps_numerator = 25,
    fps_denominator = 1,
})
assert(master:save(db, {skip_occlusion = true}))

local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("media_id", media.id)
insert_cmd:set_parameter("track_id", "video1")
insert_cmd:set_parameter("insert_time", 0)
insert_cmd:set_parameter("master_clip_id", master.id)
insert_cmd:set_parameter("project_id", "default_project")
insert_cmd:set_parameter("sequence_id", "default_sequence")
insert_cmd:set_parameter("advance_playhead", false)

local result = command_manager.execute(insert_cmd)
assert(result.success, result.error_message or "Insert failed")

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

assert(duration_frames == 2500, string.format("Expected timeline duration to conform (2500 frames @24fps), got %s", tostring(duration_frames)))
assert(source_in_frame == 0 and source_out_frame == 2500, string.format("Expected source bounds to remain 0-2500 @25fps, got %s-%s", tostring(source_in_frame), tostring(source_out_frame)))
assert(fps_num == 25 and fps_den == 1, string.format("Expected clip rate to preserve source fps 25/1, got %s/%s", tostring(fps_num), tostring(fps_den)))

print("✅ Insert conforms master clip (preserves frame count, plays at sequence fps)")

