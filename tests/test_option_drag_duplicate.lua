#!/usr/bin/env luajit

require('test_env')

local json = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require('models.media')

local SCHEMA_SQL = require("import_schema")

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                           timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('video1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('video2', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 2, 1);
]]

local db = nil

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec(BASE_DATA_SQL))
    command_manager.init(db, 'default_sequence', 'default_project')
end

local function create_clip(params)
    local media = Media.create({
        id = params.media_id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. params.media_id .. '.mov',
        file_name = params.media_id .. '.mov',
        duration_value = params.duration_value,
        frame_rate = 30,
    })
    assert(media)
    assert(media:save(db))

    local clip = require('models.clip').create(params.name or params.clip_id, params.media_id)
    clip.id = params.clip_id
    clip.track_id = params.track_id
    clip.start_value = params.start_value
    clip.duration_value = params.duration_value
    clip.source_in_value = params.source_in_value or 0
    clip.source_out_value = params.source_out_value or params.duration_value
    clip.timebase_type = "video_frames"
    clip.timebase_rate = 30.0
    clip.owner_sequence_id = 'default_sequence'
    clip.project_id = 'default_project'
    clip.parent_clip_id = params.parent_clip_id
    assert(clip:save(db, {skip_occlusion = true}))
    return clip
end

local SINGLE_DB = "/tmp/jve/test_option_drag_duplicate_single.db"
setup_database(SINGLE_DB)

create_clip({clip_id = 'clip_src', media_id = 'media_src', track_id = 'video1', start_value = 0, duration_value = 1000})
create_clip({clip_id = 'clip_tgt', media_id = 'media_tgt', track_id = 'video2', start_value = 3000, duration_value = 1000})

local overwrite_cmd = Command.create('Overwrite', 'default_project')
overwrite_cmd:set_parameter('media_id', 'media_src')
overwrite_cmd:set_parameter('track_id', 'video2')
overwrite_cmd:set_parameter('overwrite_time', 1000)
overwrite_cmd:set_parameter('duration_value', 1000)
overwrite_cmd:set_parameter('source_in_value', 0)
overwrite_cmd:set_parameter('source_out_value', 1000)
overwrite_cmd:set_parameter('project_id', 'default_project')
overwrite_cmd:set_parameter('sequence_id', 'default_sequence')
overwrite_cmd:set_parameter('advance_playhead', false)

local result = command_manager.execute(overwrite_cmd)
assert(result.success, result.error_message or 'Overwrite failed')

local stmt = db:prepare([[SELECT start_value FROM clips WHERE id = 'clip_tgt']])
assert(stmt:exec() and stmt:next())
local start_value = stmt:value(0)
stmt:finalize()

assert(start_value == 3000, string.format('Expected clip_tgt start_value to remain 3000, got %d', start_value))

local dup_stmt = db:prepare([[SELECT COUNT(*) FROM clips WHERE track_id = 'video2' AND start_value = 1000 AND id != 'clip_tgt']])
assert(dup_stmt:exec() and dup_stmt:next())
local duplicate_count = dup_stmt:value(0)
dup_stmt:finalize()

assert(duplicate_count == 1, string.format('Expected exactly one duplicated clip at 1000ms, found %d', duplicate_count))

print('✅ Option-drag duplicate preserved downstream alignment (single clip)')

-- Multi-clip duplicate regression: ensure BatchCommand of Overwrite specs leaves downstream clips untouched.
local MULTI_DB = "/tmp/jve/test_option_drag_duplicate_multi.db"
setup_database(MULTI_DB)

create_clip({clip_id = 'clip_src_a', media_id = 'media_src_a', track_id = 'video1', start_value = 0, duration_value = 1000})
create_clip({clip_id = 'clip_src_b', media_id = 'media_src_b', track_id = 'video1', start_value = 2500, duration_value = 1200})
create_clip({clip_id = 'clip_existing_dest', media_id = 'media_dest', track_id = 'video2', start_value = 6000, duration_value = 1000})

local command_specs = {
    {
        command_type = "Overwrite",
        parameters = {
            media_id = 'media_src_a',
            track_id = 'video2',
            overwrite_time = 500,
            duration_value = 1000,
            source_in_value = 0,
            source_out_value = 1000,
            master_clip_id = 'clip_src_a',
            project_id = 'default_project',
            sequence_id = 'default_sequence',
            advance_playhead = false,
        }
    },
    {
        command_type = "Overwrite",
        parameters = {
            media_id = 'media_src_b',
            track_id = 'video2',
            overwrite_time = 3200,
            duration_value = 1200,
            source_in_value = 0,
            source_out_value = 1200,
            master_clip_id = 'clip_src_b',
            project_id = 'default_project',
            sequence_id = 'default_sequence',
            advance_playhead = false,
        }
    }
}

local batch_cmd = Command.create('BatchCommand', 'default_project')
batch_cmd:set_parameter('commands_json', json.encode(command_specs))

local batch_result = command_manager.execute(batch_cmd)
assert(batch_result.success, batch_result.error_message or 'Batch overwrite failed')

local existing_stmt = db:prepare([[SELECT start_value, duration_value FROM clips WHERE id = 'clip_existing_dest']])
assert(existing_stmt:exec() and existing_stmt:next())
local dest_start = existing_stmt:value(0)
local dest_duration_value = existing_stmt:value(1)
existing_stmt:finalize()

assert(dest_start == 6000, string.format('Expected destination clip to remain at 6000ms, got %d', dest_start))
assert(dest_duration_value == 1000, string.format('Expected destination clip duration_value to remain 1000ms, got %d', dest_duration_value))

local function count_clips_at(time_ms, duration_ms)
    local q = db:prepare([[SELECT COUNT(*) FROM clips WHERE track_id = 'video2' AND start_value = ? AND duration_value = ?]])
    q:bind_value(1, time_ms)
    q:bind_value(2, duration_ms)
    assert(q:exec() and q:next())
    local count = q:value(0)
    q:finalize()
    return count
end

assert(count_clips_at(500, 1000) == 1, "Expected exactly one duplicated clip at 500ms on track video2")
assert(count_clips_at(3200, 1200) == 1, "Expected exactly one duplicated clip at 3200ms on track video2")

print('✅ Option-drag duplicate preserved downstream alignment (multiple clips)')
