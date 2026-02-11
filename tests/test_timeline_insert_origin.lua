#!/usr/bin/env luajit

-- Regression: inserting at the playhead in a fresh project should place the
-- clip at time zero, and the viewport math must render it at the origin.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

local test_env = require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Command = require('command')
local Media = require('models.media')

local DB_PATH = "/tmp/jve/test_timeline_insert_origin.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require('import_schema')))

-- Seed a default project/sequence/tracks (mirrors layout.lua defaults)
assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'), '{}');

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'default_sequence', 'default_project', 'Sequence 1', 'timeline',
        24, 1, 48000,
        1920, 1080,
        0, 240, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]]))

-- Prepare media: 1h16m22s@25fps (approx clip from the report)
local media = Media.create({
    id = "media_insert_origin",
    project_id = "default_project",
    file_path = "/tmp/jve/long_clip.mov",
    name = "long_clip.mov",
    duration_frames = 114567, -- 01:16:22:17 @ 25fps (as reported)
    fps_numerator = 25,
    fps_denominator = 1,
    width = 2048,
    height = 1080,
    audio_channels = 2,
    codec = "h264"
})
assert(media:save(db), "failed to save media")

-- Create masterclip sequence for this media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    "default_project", "Long Clip Master", 25, 1, 114567, "media_insert_origin")

command_manager.init("default_sequence", "default_project")
timeline_state.init("default_sequence")

local playhead = timeline_state.get_playhead_position()
assert(playhead == 0, "playhead should start at frame 0 for new sequence")

local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("master_clip_id", master_clip_id)
insert_cmd:set_parameter("sequence_id", "default_sequence")
insert_cmd:set_parameter("track_id", "video1")
insert_cmd:set_parameter("insert_time", playhead)
insert_cmd:set_parameter("duration", media.duration)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", media.duration)
insert_cmd:set_parameter("advance_playhead", true)

local result = command_manager.execute(insert_cmd)
assert(result.success, result.error_message or "Insert failed")

local clips = database.load_clips("default_sequence")
-- Note: Audio clip creation is handled by import_media, not Insert command.
-- This test validates Insert places video clip at correct position.
assert(clips and #clips >= 1, string.format("expected at least 1 clip, got %d", clips and #clips or 0))
-- Find the video clip (on video1 track)
local clip
for _, c in ipairs(clips) do
    if c.track_id == "video1" then
        clip = c
        break
    end
end
assert(clip, "video clip not found")

assert(clip.timeline_start == 0, string.format("clip should start at frame 0, got %s", tostring(clip.timeline_start)))

-- Verify rendering math keeps the clip at the origin for a 1000px viewport
timeline_state.set_viewport_start_time(0)
local px = timeline_state.time_to_pixel(clip.timeline_start, 1000)
assert(px >= -1 and px <= 1, string.format("clip should render at viewport origin, got pixel=%s", tostring(px)))

-- Playhead should advance to the end of the inserted clip when requested
local final_playhead = timeline_state.get_playhead_position()
-- clip.duration is now in TIMELINE frames (not source frames)
-- Source: 114567 frames at 25fps = 4582.68 seconds
-- Timeline: 24fps → 4582.68 * 24 = 109984 frames
local expected_timeline_duration = math.floor(media.duration * 24 / 25 + 0.5)
assert(final_playhead == expected_timeline_duration,
    string.format("playhead should advance to timeline end (%d), got %s",
        expected_timeline_duration, tostring(final_playhead)))

print("✅ Insert at playhead origin renders at timeline start")
os.remove(DB_PATH)
