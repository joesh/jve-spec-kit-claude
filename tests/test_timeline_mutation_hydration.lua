#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Command = require('command')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/jve/test_timeline_mutation_hydration.db"

local function setup_db()
    os.remove(TEST_DB)
    assert(database.init(TEST_DB))
    local conn = database.get_connection()
    assert(conn:exec(require('import_schema')))

    assert(conn:exec([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'Media A', '/tmp/jve/a.mov', 4000, 30, 1, 1920, 1080, 0, 'prores', '{}', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_b', 'default_project', 'Media B', '/tmp/jve/b.mov', 4000, 30, 1, 1920, 1080, 0, 'prores', '{}', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_a', 'default_sequence',
        0, 4000, 0, 4000, 30, 1, 1, 0, strftime('%s','now'), strftime('%s','now'));

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_b', 'default_project', 'timeline', 'Clip B', 'track_v1', 'media_b', 'default_sequence',
        4000, 4000, 0, 4000, 30, 1, 1, 0, strftime('%s','now'), strftime('%s','now'));
    ]]))

-- command_impl.register_commands({}, {}, conn)
command_manager.init(conn, 'default_sequence', 'default_project')
end

setup_db()

local timeline_state = require('ui.timeline.timeline_state')
local original_reload = timeline_state.reload_clips
local reload_count = 0
timeline_state.reload_clips = function(sequence_id, opts)
    reload_count = reload_count + 1
    if original_reload then
        return original_reload(sequence_id, opts)
    end
    return true
end

assert(timeline_state.init('default_sequence'))

assert(timeline_state.get_clip_by_id('clip_b') ~= nil, "clip_b should load initially")
timeline_state._internal_remove_clip_from_command('clip_b')
assert(timeline_state.get_clip_by_id('clip_b') == nil, "clip_b should be missing before mutation")

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_b",
    edge_type = "out",
    track_id = "track_v1"
})
ripple_cmd:set_parameter("delta_frames", -8) -- 250ms at 30fps rounds to 8 frames
ripple_cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit should succeed")
assert(reload_count == 0, "Hydrated mutation should not trigger reload fallback")

local hydrated_clip = timeline_state.get_clip_by_id('clip_b')
assert(hydrated_clip, "clip_b should be hydrated back into state")
assert(hydrated_clip.duration.frames < 4000, "Ripple trim should update hydrated clip")

print("✅ Timeline state hydrates missing clips during mutation replay without reload fallback")
