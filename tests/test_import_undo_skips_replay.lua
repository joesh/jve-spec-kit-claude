#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

local test_env = require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local timeline_state = {
    sequence_id = "default_sequence",
    playhead = 0,
    reload_calls = 0,
    sequence_frame_rate = nil,
}
local function refresh_sequence_frame_rate(sequence_id)
    local db = database.get_connection()
    assert(db, "timeline_state: database not initialized")
    local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    assert(stmt, "timeline_state: failed to prepare frame rate lookup")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next(), string.format("timeline_state: missing sequence %s", tostring(sequence_id)))
    local num = stmt:value(0) or 0
    local den = stmt:value(1) or 1
    stmt:finalize()
    assert(num > 0 and den > 0, "timeline_state: invalid frame rate")
    timeline_state.sequence_frame_rate = num / den
end

function timeline_state.capture_viewport()
    return {start_value = 0, duration_value = 400, timebase_type = "video_frames", timebase_rate = 30.0}
end
function timeline_state.get_viewport_start_time() return 0 end  -- integer frames
function timeline_state.get_viewport_duration() return 400 end  -- integer frames
function timeline_state.push_viewport_guard() end
function timeline_state.pop_viewport_guard() end
function timeline_state.restore_viewport(_) end
function timeline_state.set_selection(_) end
function timeline_state.set_edge_selection(_) end
function timeline_state.set_gap_selection(_) end
function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.clear_edge_selection() end
function timeline_state.clear_gap_selection() end
function timeline_state.set_playhead_position(ms) timeline_state.playhead = ms end
function timeline_state.get_playhead_position() return timeline_state.playhead end
function timeline_state.get_project_id() return "default_project" end
function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.reload_clips(sequence_id)
    timeline_state.reload_calls = timeline_state.reload_calls + 1
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
        local ok = pcall(refresh_sequence_frame_rate, sequence_id)
        if not ok then
            -- Fallback if sequence was deleted during undo
            timeline_state.sequence_id = "default_sequence"
            timeline_state.sequence_frame_rate = nil
        end
    end
end
function timeline_state.normalize_edge_selection() return false end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations() return true end
function timeline_state.consume_mutation_failure() return nil end
function timeline_state.get_sequence_frame_rate()
    if not timeline_state.sequence_frame_rate then
        refresh_sequence_frame_rate(timeline_state.sequence_id)
    end
    return timeline_state.sequence_frame_rate
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local SCHEMA_SQL = require('import_schema')

local function init_db(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec([[
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
        VALUES (
            'default_sequence', 'default_project', 'Default', 'timeline',
            30, 1, 48000,
            1920, 1080,
            0, 400, 0,
            '[]', '[]', '[]',
            0, strftime('%s','now'), strftime('%s','now')
        );
    ]]))
    return db
end

local TEST_DB = "/tmp/jve/test_import_undo_skips_replay.db"
init_db(TEST_DB)

command_manager.init("default_sequence", "default_project")

local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_path", test_env.resolve_repo_path("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, exec_result.error_message or "ImportFCP7XML execution failed")

local import_record = command_manager.get_last_command('default_project')
assert(import_record, "Import command should exist")
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

timeline_state.sequence_id = imported_sequence_id
command_manager.activate_timeline_stack(imported_sequence_id)
timeline_state.reload_calls = 0
timeline_state.reload_calls = 0
timeline_state.reload_calls = 0

local replay_invoked = false
local original_replay = command_manager.replay_events
command_manager.replay_events = function(...)
    replay_invoked = true
    return original_replay(...)
end

local undo_result = command_manager.undo()
command_manager.replay_events = original_replay

assert(undo_result.success, undo_result.error_message or "Undo should succeed without replay")
assert(not replay_invoked, "Undoing ImportFCP7XML should skip replay_events")
assert(timeline_state.reload_calls > 0, "Undo should trigger timeline reload to refresh UI state")
assert(timeline_state.sequence_id == "default_sequence",
    string.format("Timeline should fall back to default sequence after undo (got %s)", tostring(timeline_state.sequence_id)))

os.remove(TEST_DB)
print("✅ ImportFCP7XML undo skips sequence replay and refreshes timeline")
