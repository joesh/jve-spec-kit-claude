#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Command = require('command')

-- Stub timeline_state so we can observe reload attempts.
local timeline_state = {
    sequence_id = "default_sequence",
    reload_calls = 0,
    applied_mutations = 0
}

function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.get_project_id() return "default_project" end
function timeline_state.get_playhead_position() return 0 end
function timeline_state.set_playhead_position(_) end
function timeline_state.set_selection(_) end
function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.clear_edge_selection() end
function timeline_state.clear_gap_selection() end
function timeline_state.persist_state_to_db() end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 400, timebase_type = "video_frames", timebase_rate = 30.0} end
function timeline_state.get_sequence_frame_rate() return 30.0 end
function timeline_state.get_sequence_audio_sample_rate() return 48000 end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 0 end
function timeline_state.pop_viewport_guard() return 0 end
function timeline_state.consume_mutation_failure() return nil end
function timeline_state.apply_mutations()
    timeline_state.applied_mutations = timeline_state.applied_mutations + 1
    return false
end
function timeline_state.reload_clips()
    timeline_state.reload_calls = timeline_state.reload_calls + 1
end

package.loaded["ui.timeline.timeline_state"] = timeline_state

local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local function setup_db(path)
    os.remove(path)
    assert(database.init(path))
    local conn = database.get_connection()
    local SCHEMA_SQL = require("import_schema")
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
        INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 400);
        INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 'video_frames', 30.0, 1, 1);
        INSERT INTO media (id, project_id, file_path, name, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_a', 'default_project', '/tmp/jve/media_a.mov', 'Media A', 4000, 'video_frames', 30.0, 30.0, 1920, 1080, 0, 'prores', strftime('%s','now'), strftime('%s','now'), '{}');
        INSERT INTO media (id, project_id, file_path, name, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_b', 'default_project', '/tmp/jve/media_b.mov', 'Media B', 4000, 'video_frames', 30.0, 30.0, 1920, 1080, 0, 'prores', strftime('%s','now'), strftime('%s','now'), '{}');
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, media_id, clip_kind, enabled, offline)
        VALUES ('clip_a', 'default_project', 'track_v1', 'default_sequence', 0, 4000, 0, 4000, 'video_frames', 30.0, 'media_a', 'timeline', 1, 0);
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, media_id, clip_kind, enabled, offline)
        VALUES ('clip_b', 'default_project', 'track_v1', 'default_sequence', 4000, 4000, 0, 4000, 'video_frames', 30.0, 'media_b', 'timeline', 1, 0);
    ]]))

    command_impl.register_commands({}, {}, conn)
    command_manager.init(conn, 'default_sequence', 'default_project')
end

local TEST_DB = "/tmp/jve/test_ripple_noop.db"
setup_db(TEST_DB)

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_a",
    edge_type = "gap_after",
    track_id = "track_v1"
})
ripple_cmd:set_parameter("delta_ms", 1000) -- No actual gap, so delta clamps to 0
ripple_cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit no-op should succeed")
assert(timeline_state.reload_calls == 0, "No-op ripple should not trigger timeline reload fallback")
assert(not command_manager.can_undo(), "No-op ripple should not add undo history")

print("✅ RippleEdit no-op skips timeline reload and undo recording")
