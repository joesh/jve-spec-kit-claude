#!/usr/bin/env luajit

-- Regression: inserting into a non-default sequence must undo cleanly.
-- The pre-fix bug routed undo/redo through the default sequence, so the
-- inserted clip persisted after undo.

package.path = package.path .. ";./tests/?.lua;./tests/?/init.lua;./src/lua/?.lua;./src/lua/?/init.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require("models.media")
local Clip = require("models.clip")
local Rational = require("core.rational")

local TEST_DB = "/tmp/jve/test_insert_undo_imported_sequence.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES
        ('default_sequence', 'default_project', 'Default Sequence', 'timeline',
         30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d),
        ('imported_sequence', 'default_project', 'Imported Sequence', 'timeline',
         30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES
        ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('imported_v1', 'imported_sequence', 'Imported V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now, now, now))

local media_existing = Media.create({
    id = "media_existing",
    project_id = "default_project",
    name = "Existing Clip",
    file_path = "synthetic://existing",
    duration = 5000,
    frame_rate = 30,
    width = 1920,
    height = 1080,
    created_at = now,
    modified_at = now
})
assert(media_existing and media_existing:save(db))

local media_insert = Media.create({
    id = "media_insert",
    project_id = "default_project",
    name = "Insert Clip",
    file_path = "synthetic://insert",
    duration = 4500000,
    frame_rate = 30,
    width = 1920,
    height = 1080,
    created_at = now,
    modified_at = now
})
assert(media_insert and media_insert:save(db))

local base_clip = Clip.create("Existing Clip", "media_existing", {
    id = "clip_existing",
    project_id = "default_project",
    track_id = "imported_v1",
    owner_sequence_id = "imported_sequence",
    timeline_start = Rational.new(0, 30, 1),
    duration = Rational.new(5000, 30, 1),
    source_in = Rational.new(0, 30, 1),
    source_out = Rational.new(5000, 30, 1),
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = 1
})
assert(base_clip and base_clip:save(db))

local timeline_state = {
    playhead_value = 111400,
    playhead_position = 111400,
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
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(val) timeline_state.playhead_position = val end
function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.set_edge_selection(edges) timeline_state.selected_edges = edges or {} end
function timeline_state.normalize_edge_selection() return false end
function timeline_state.reload_clips(sequence_id)
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
        local rate_stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        assert(rate_stmt, "timeline_state: failed to prepare frame rate lookup")
        rate_stmt:bind_value(1, sequence_id)
        assert(rate_stmt:exec() and rate_stmt:next(), "timeline_state: sequence missing for reload")
        local num = rate_stmt:value(0) or 0
        local den = rate_stmt:value(1) or 1
        rate_stmt:finalize()
        assert(num > 0 and den > 0, "timeline_state: invalid frame rate during reload")
        timeline_state.sequence_frame_rate = num / den
    end
end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    if sequence_id and sequence_id ~= "" then
        timeline_state.sequence_id = sequence_id
        local rate_stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        assert(rate_stmt and rate_stmt:bind_value(1, sequence_id), "timeline_state: failed to bind frame rate lookup")
        assert(rate_stmt:exec() and rate_stmt:next(), "timeline_state: sequence missing during apply_mutations")
        local num = rate_stmt:value(0) or 0
        local den = rate_stmt:value(1) or 1
        rate_stmt:finalize()
        assert(num > 0 and den > 0, "timeline_state: invalid frame rate during apply_mutations")
        timeline_state.sequence_frame_rate = num / den
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
        local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        assert(stmt, "timeline_state: failed to prepare frame rate lookup")
        stmt:bind_value(1, timeline_state.sequence_id)
        assert(stmt:exec() and stmt:next(), "timeline_state: missing sequence for frame rate")
        local num = stmt:value(0) or 0
        local den = stmt:value(1) or 1
        stmt:finalize()
        assert(num > 0 and den > 0, "timeline_state: invalid frame rate")
        timeline_state.sequence_frame_rate = num / den
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
