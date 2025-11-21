#!/usr/bin/env luajit

-- Regression: inserting into a non-default sequence must undo cleanly.
-- The pre-fix bug routed undo/redo through the default sequence, so the
-- inserted clip persisted after undo.

package.path = package.path .. ";./tests/?.lua;./tests/?/init.lua;./src/lua/?.lua;./src/lua/?/init.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_insert_undo_imported_sequence.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                          timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES
        ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240),
        ('imported_sequence', 'default_project', 'Imported Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);

    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index)
    VALUES
        ('video1', 'default_sequence', 'V1', 'VIDEO', 'video_frames', 30.0, 1),
        ('imported_v1', 'imported_sequence', 'Imported V1', 'VIDEO', 'video_frames', 30.0, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec)
    VALUES
        ('media_existing', 'default_project', 'Existing Clip', 'synthetic://existing', 5000, 'video_frames', 30.0, 30.0, 1920, 1080, 0, 'raw'),
        ('media_insert', 'default_project', 'Insert Clip', 'synthetic://insert', 4500000, 'video_frames', 30.0, 30.0, 1920, 1080, 0, 'raw');

    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate)
    VALUES ('clip_existing', 'imported_v1', 'media_existing', 0, 5000, 0, 5000, 'video_frames', 30.0);
]])

local timeline_state = {
    playhead_value = 111400,
    sequence_id = 'imported_sequence',
    project_id = 'default_project',
    selected_clips = {},
    selected_edges = {},
    viewport_start_value = 0,
    viewport_duration_frames_value = 240,
    sequence_frame_rate = nil
}

function timeline_state.get_project_id() return timeline_state.project_id end
function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.set_sequence_id(new_id) timeline_state.sequence_id = new_id end
function timeline_state.get_default_video_track_id() return 'imported_v1' end
function timeline_state.get_playhead_value() return timeline_state.playhead_value end
function timeline_state.set_playhead_value(val) timeline_state.playhead_value = val end
function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.set_edge_selection(edges) timeline_state.selected_edges = edges or {} end
function timeline_state.normalize_edge_selection() return false end
function timeline_state.reload_clips(sequence_id)
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
        local rate_stmt = db:prepare("SELECT frame_rate FROM sequences WHERE id = ?")
        assert(rate_stmt, "timeline_state: failed to prepare frame rate lookup")
        rate_stmt:bind_value(1, sequence_id)
        assert(rate_stmt:exec() and rate_stmt:next(), "timeline_state: sequence missing for reload")
        local rate = rate_stmt:value(0)
        rate_stmt:finalize()
        assert(rate and rate > 0, "timeline_state: invalid frame rate during reload")
        timeline_state.sequence_frame_rate = rate
    end
end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
        local rate_stmt = db:prepare("SELECT frame_rate FROM sequences WHERE id = ?")
        assert(rate_stmt and rate_stmt:bind_value(1, sequence_id), "timeline_state: failed to bind frame rate lookup")
        assert(rate_stmt:exec() and rate_stmt:next(), "timeline_state: sequence missing during apply_mutations")
        local rate = rate_stmt:value(0)
        rate_stmt:finalize()
        assert(rate and rate > 0, "timeline_state: invalid frame rate during apply_mutations")
        timeline_state.sequence_frame_rate = rate
    end
    return mutations ~= nil
end
function timeline_state.consume_mutation_failure()
    return nil
end
function timeline_state.capture_viewport()
    return {
        start_value = timeline_state.viewport_start_value,
        duration_value = timeline_state.viewport_duration_frames_value
    }
end
function timeline_state.restore_viewport(snapshot)
    if not snapshot then return end
    if snapshot.start_value then timeline_state.viewport_start_value = snapshot.start_value end
    if snapshot.duration_value then timeline_state.viewport_duration_frames_value = snapshot.duration_value end
end
local viewport_guard = 0
function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end
function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then viewport_guard = viewport_guard - 1 end
    return viewport_guard
end
function timeline_state.get_sequence_frame_rate()
    if not timeline_state.sequence_frame_rate then
        local stmt = db:prepare("SELECT frame_rate FROM sequences WHERE id = ?")
        assert(stmt, "timeline_state: failed to prepare frame rate lookup")
        stmt:bind_value(1, timeline_state.sequence_id)
        assert(stmt:exec() and stmt:next(), "timeline_state: missing sequence for frame rate")
        local rate = stmt:value(0)
        stmt:finalize()
        assert(rate and rate > 0, "timeline_state: invalid frame rate")
        timeline_state.sequence_frame_rate = rate
    end
    return timeline_state.sequence_frame_rate
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init(db, 'default_sequence', 'default_project')

local function clip_count(sequence_id)
    local stmt = db:prepare([[
        SELECT COUNT(*)
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
    ]])
    assert(stmt, "Failed to prepare clip count query")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next(), "Failed to execute clip count query")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

local baseline = clip_count('imported_sequence')
assert(baseline == 1, string.format("Expected baseline clip count 1, got %d", baseline))

local insert_cmd = Command.create("Insert", 'default_project')
insert_cmd:set_parameter("media_id", "media_insert")
insert_cmd:set_parameter("sequence_id", "imported_sequence")
insert_cmd:set_parameter("track_id", "imported_v1")
insert_cmd:set_parameter("insert_time", 111400)
insert_cmd:set_parameter("duration", 4543560)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 4543560)
insert_cmd:set_parameter("advance_playhead", true)

local execute_result = command_manager.execute(insert_cmd)
assert(execute_result.success, "Insert command should succeed")

local after_insert = clip_count('imported_sequence')
assert(after_insert == baseline + 1,
    string.format("Insert should add a clip (expected %d, got %d)", baseline + 1, after_insert))

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed")

local after_undo = clip_count('imported_sequence')
assert(after_undo == baseline,
    string.format("Undo should restore clip count to baseline (expected %d, got %d)", baseline, after_undo))

local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed")

local after_redo = clip_count('imported_sequence')
assert(after_redo == baseline + 1,
    string.format("Redo should reapply insert (expected %d, got %d)", baseline + 1, after_redo))

print("✅ Insert undo/redo respects active imported sequence")
