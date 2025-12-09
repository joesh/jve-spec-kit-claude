#!/usr/bin/env luajit

-- Basic BatchRippleEdit tests using real command manager.

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

function qt_json_encode(_) return "{}" end
function qt_create_single_shot_timer(_, cb) cb(); return {} end

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function run_test(name, layout, edges, delta_frames, expectations)
    local path = os.tmpname() .. ".jvp"
    os.remove(path)
    assert(database.set_path(path))
    local db = database.get_connection()
    _G.db = db

    local SCHEMA_SQL = require("import_schema")
    assert(db:exec(SCHEMA_SQL))

    local inserts = {
        "INSERT INTO projects VALUES ('default_project','Test',0,0,'{}')",
        "INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, selected_clip_ids, selected_edge_infos, viewport_start_value, viewport_duration_frames_value) VALUES ('default_sequence','default_project','Seq','timeline',24,48000,1920,1080,0,0,'[]','[]',0,240)"
    }

    for _, track in ipairs(layout.tracks) do
        table.insert(inserts, string.format(
            "INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('%s', 'default_sequence', 'Track', '%s', 'video_frames', 24.0, %d, 1,0,0,0,1.0,0.0)",
            track.id, track.name or track.id, track.index
        ))
    end

    for _, media in ipairs(layout.media) do
        table.insert(inserts, string.format(
            "INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata) VALUES ('%s','default_project','%s','/tmp/%s.mov',%d,'video_frames',24.0,24.0,1920,1080,2,'prores',0,0,'{}')",
            media.id, media.name or media.id, media.id, media.duration
        ))
    end

    for _, clip in ipairs(layout.clips) do
        table.insert(inserts, string.format(
            "INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, enabled, offline) VALUES ('%s','default_project','timeline','', '%s','%s',NULL,NULL,'default_sequence',%d,%d,%d,%d,'video_frames',24.0,1,0)",
            clip.id, clip.track_id, clip.media_id, clip.start_value or clip.start_value, clip.duration or clip.duration_value,
            clip.source_in or clip.source_in_value or 0, clip.source_out or clip.source_out_value or (clip.source_in or clip.source_in_value or 0) + (clip.duration or clip.duration_value)
        ))
    end

    for _, sql in ipairs(inserts) do
        local s = db:prepare(sql)
        assert(s)
        assert(s:exec(), sql)
        s:finalize()
    end

    command_manager.init(db)

    local cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", edges)
    cmd:set_parameter("delta_frames", delta_frames)
    cmd:set_parameter("sequence_id", "default_sequence")

    local result = command_manager.execute(cmd)
    if not result.success then
        os.remove(path)
        error(string.format("%s failed: %s", name, tostring(result.error_message)))
    end

    local load = require("core.database").load_clips
    local clips = load("default_sequence")
    for clip_id, expected in pairs(expectations) do
        for _, clip in ipairs(clips) do
            if clip.id == clip_id then
                if expected.start_value ~= nil then
                    assert_eq(name .. " start_value", clip.start_value, expected.start_value)
                end
                if expected.duration_value ~= nil then
                    assert_eq(name .. " duration_value", clip.duration_value, expected.duration_value)
                end
                if expected.source_out_value ~= nil then
                    assert_eq(name .. " source_out_value", clip.source_out_value, expected.source_out_value)
                end
            end
        end
    end

    os.remove(path)
end

-- Basic single-track scenario
run_test(
    "single_track_out_trim_left",
    {
        tracks = {
            {id = "video1", index = 1}
        },
        media = {
            {id = "media_v1", duration = 480000}
        },
        clips = {
            {id = "clip_one", track_id = "video1", media_id = "media_v1", start_value = 0, duration_value = 1000, source_in_value = 0, source_out_value = 1000},
            {id = "clip_two", track_id = "video1", media_id = "media_v1", start_value = 1100, duration_value = 1000, source_in_value = 1000, source_out_value = 2000}
        }
    },
    {
        {clip_id = "clip_one", edge_type = "out", track_id = "video1"}
    },
    -12, -- 500ms at 24fps
    {
        clip_one = {start_value = 0, duration_value = 500, source_out_value = 500},
        clip_two = {start_value = 600}
    }
)

print("✅ basic BatchRippleEdit tests passed")
