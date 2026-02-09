#!/usr/bin/env luajit

-- Regression: inserting at the playhead in a fresh project should place the
-- clip at time zero, and the viewport math must render it at the origin.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

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

command_manager.init("default_sequence", "default_project")
timeline_state.init("default_sequence")

local playhead = timeline_state.get_playhead_position()
assert(playhead == 0, "playhead should start at frame 0 for new sequence")

local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("media_id", media.id)
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
-- Expect 1 video clip + 2 audio clips (one per audio channel)
assert(clips and #clips == 3, string.format("expected 3 clips (1 video + 2 audio), got %d", clips and #clips or 0))
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
-- Playhead advances by clip.duration (integer frames in sequence timebase)
-- The Insert command uses the provided duration directly without rescaling
assert(final_playhead == media.duration,
    string.format("playhead should advance to clip end (%d), got %s", media.duration, tostring(final_playhead)))

print("✅ Insert at playhead origin renders at timeline start")
os.remove(DB_PATH)
