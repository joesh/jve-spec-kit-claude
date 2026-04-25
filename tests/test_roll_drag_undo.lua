#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local SCHEMA_SQL = require('import_schema')

local function init_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('default_project', 'Default Project', 'resample', 0, 0);
        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            created_at, modified_at
        )
        VALUES ('default_sequence', 'default_project', 'Default Sequence', 'nested', 1000, 1, 48000, 1920, 1080, 0, 250, 0, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 0, 0);
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_a', 'default_project', 'A', '/tmp/jve/a.mov', 10000, 1000, 1, 1920, 1080, 2, 'prores', 0, 0, '{}');
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_b', 'default_project', 'B', '/tmp/jve/b.mov', 10000, 1000, 1, 1920, 1080, 2, 'prores', 0, 0, '{}');
        -- V13 master sequence + track + media_ref for media_a
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('master_media_a', 'default_project', 'media_a_master', 'master', 30, 1, 48000, 1920, 1080, strftime('%s','now'), strftime('%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media_a', 'master_media_a', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media_a' WHERE id = 'master_media_a';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media_a', 'default_project', 'master_media_a', 'master_v_media_a', 'media_a', 0, 10000, 0, 10000, 1, 1.0, 0, strftime('%s','now'), strftime('%s','now'));

-- V13 master sequence + track + media_ref for media_b
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('master_media_b', 'default_project', 'media_b_master', 'master', 30, 1, 48000, 1920, 1080, strftime('%s','now'), strftime('%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media_b', 'master_media_b', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media_b' WHERE id = 'master_media_b';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media_b', 'default_project', 'master_media_b', 'master_v_media_b', 'media_b', 0, 10000, 0, 10000, 1, 1.0, 0, strftime('%s','now'), strftime('%s','now'));

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_a', 'default_project', 'Clip A', 'track_v1', 'master_media_a', 'default_sequence', 0, 3000, 1000, 4000, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
        INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_b', 'default_project', 'Clip B', 'track_v1', 'master_media_b', 'default_sequence', 3000, 2000, 500, 2500, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
    ]]))
    return db
end

local TEST_DB = "/tmp/jve/test_roll_drag_undo.db"
local db = init_database(TEST_DB)
command_manager.init("default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

-- Simulate roll selection across clip_a out / clip_b in (adjacent)
local edges = {
    {clip_id = "clip_a", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_b", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
}

-- Perform roll drag: move boundary left by 500ms
local roll_cmd = Command.create("BatchRippleEdit", "default_project")
roll_cmd:set_parameter("sequence_id", "default_sequence")
roll_cmd:set_parameter("edge_infos", edges)
roll_cmd:set_parameter("delta_frames", -500) -- fps 1000 => 1ms/frame

local result = command_manager.execute(roll_cmd)
assert(result.success, result.error_message or "Roll execution failed")

-- Validate post-roll state
local function fetch_clip(id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt and stmt:exec() and stmt:next(), "Failed to load clip " .. id)
    local start_value = tonumber(stmt:value(0))
    local duration = tonumber(stmt:value(1))
    stmt:finalize()
    return start_value, duration
end

local a_start, a_dur = fetch_clip("clip_a")
assert(math.abs(a_start - 0) < 1, "clip_a start should stay fixed after roll")
assert(math.abs(a_dur - 2500) < 1, "clip_a duration should shrink by 500")

local b_start, b_dur = fetch_clip("clip_b")
assert(math.abs(b_start - 2500) < 1, "clip_b start should move left by 500 in roll")
assert(math.abs(b_dur - 2500) < 1, "clip_b duration should grow by 500 in roll")

-- Undo the roll
local undo = command_manager.undo()
assert(undo.success, undo.error_message or "Undo failed for roll")

a_start, a_dur = fetch_clip("clip_a")
assert(math.abs(a_start - 0) < 1, "clip_a start should restore to 0 after undo")
assert(math.abs(a_dur - 3000) < 1, "clip_a duration should restore after undo")

b_start, b_dur = fetch_clip("clip_b")
assert(math.abs(b_start - 3000) < 1, "clip_b start should restore after undo")
assert(math.abs(b_dur - 2000) < 1, "clip_b duration should restore after undo")

local function clip_count()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline'")
    assert(stmt:exec() and stmt:next(), "Failed to count clips")
    local count = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return count
end

assert(clip_count() == 2, "Undo roll should leave the original two clips only")

os.remove(TEST_DB)
print("✅ Roll drag undo restores original clip states and clip count")
