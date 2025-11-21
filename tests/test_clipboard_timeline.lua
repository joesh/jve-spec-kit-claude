#!/usr/bin/env luajit

require('test_env')

local event_log_stub = {
    init = function() return true end,
    record_command = function() return true end
}
package.loaded["core.event_log"] = event_log_stub

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')
local clipboard = require('core.clipboard')
local json = require('dkjson')

local SCHEMA_SQL = require("import_schema")

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 24.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('video1', 'default_sequence', 'V1', 'VIDEO', 'video_frames', 24.0, 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('video2', 'default_sequence', 'V2', 'VIDEO', 'video_frames', 24.0, 2, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('video3', 'default_sequence', 'V3', 'VIDEO', 'video_frames', 24.0, 3, 1);
]]

local db = nil

local function reload_clips_into_state(state)
    state.clips = {}
    state.clip_lookup = {}
    local stmt = db:prepare([[
        SELECT id, track_id, start_value, duration_value, source_in_value, source_out_value, media_id, parent_clip_id
        FROM clips
        ORDER BY start_value
    ]])
    assert(stmt:exec())
    while stmt:next() do
        local entry = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            start_value = stmt:value(2),
            duration_value = stmt:value(3),
            duration = stmt:value(3),
            source_in_value = stmt:value(4),
            source_in = stmt:value(4),
            source_out_value = stmt:value(5),
            source_out = stmt:value(5),
            media_id = stmt:value(6),
            parent_clip_id = stmt:value(7),
            clip_kind = "timeline"
        }
        state.clips[#state.clips + 1] = entry
        state.clip_lookup[entry.id] = entry
    end
end

local timeline_state = {
    playhead_value = 0,
    selected_clips = {},
    clip_lookup = {},
    project_id = "default_project",
    sequence_id = "default_sequence",
    sequence_frame_rate = 24.0,
    last_mutations = nil,
    last_mutations_attempt = nil
}

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.get_clip_by_id(id) return timeline_state.clip_lookup[id] end
function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.get_project_id() return timeline_state.project_id end
function timeline_state.get_sequence_frame_rate() return timeline_state.sequence_frame_rate end
function timeline_state.get_playhead_value() return timeline_state.playhead_value end
function timeline_state.set_playhead_value(ms) timeline_state.playhead_value = ms end
function timeline_state.reload_clips()
    reload_clips_into_state(timeline_state)
end
function timeline_state.get_clips()
    timeline_state.reload_clips()
    return timeline_state.clips
end
function timeline_state.persist_state_to_db() end
function timeline_state.apply_mutations(sequence_id, mutations)
    timeline_state.last_mutations_attempt = {
        sequence_id = sequence_id or timeline_state.sequence_id,
        bucket = mutations
    }
    timeline_state.last_mutations = mutations
    return true
end
function timeline_state.capture_viewport()
    return {
        start_value = 0,
        duration_value = 240,
        timebase_type = "video_frames",
        timebase_rate = 24.0
    }
end
function timeline_state.restore_viewport(snapshot) end
function timeline_state.push_viewport_guard() return 0 end
function timeline_state.pop_viewport_guard() return 0 end

package.loaded["ui.timeline.timeline_state"] = timeline_state

local focus_manager = {
    focused = "timeline"
}
function focus_manager.get_focused_panel() return focus_manager.focused end
function focus_manager.set_focused_panel(panel) focus_manager.focused = panel end
package.loaded["ui.focus_manager"] = focus_manager
package.loaded["ui.project_browser"] = false

local clipboard_actions = require('core.clipboard_actions')

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec(BASE_DATA_SQL))

    local executors = {}
    local undoers = {}
    command_impl.register_commands(executors, undoers, db)
    command_manager.init(db, 'default_sequence', 'default_project')

    timeline_state.playhead_value = 0
    timeline_state.selected_clips = {}
    timeline_state.clip_lookup = {}
    reload_clips_into_state(timeline_state)
    clipboard.clear()
end

local function reopen_database(path)
    assert(database.set_path(path))
    db = database.get_connection()

    local executors = {}
    local undoers = {}
    command_impl.register_commands(executors, undoers, db)
    command_manager.init(db, 'default_sequence', 'default_project')

    timeline_state.playhead_value = 0
    timeline_state.selected_clips = {}
    timeline_state.clip_lookup = {}
    reload_clips_into_state(timeline_state)
end

local function create_media_record(media_id, duration_value)
    local Media = require('models.media')
    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. media_id .. '.mov',
        file_name = media_id .. '.mov',
        duration_value = duration_value,
        frame_rate = 24
    })
    assert(media:save(db))
end

local function insert_clip_via_command(params)
    create_media_record(params.media_id, params.duration_value)
    local insert_cmd = Command.create("Insert", "default_project")
    insert_cmd:set_parameter("media_id", params.media_id)
    insert_cmd:set_parameter("track_id", params.track_id)
    insert_cmd:set_parameter("sequence_id", "default_sequence")
    insert_cmd:set_parameter("insert_time", params.start_value)
    insert_cmd:set_parameter("duration_value", params.duration_value)
    insert_cmd:set_parameter("source_in_value", 0)
    insert_cmd:set_parameter("source_out_value", params.duration_value)
    insert_cmd:set_parameter("clip_id", params.clip_id)
    insert_cmd:set_parameter("advance_playhead", false)
    local result = command_manager.execute(insert_cmd)
    assert(result.success, result.error_message or "Insert command failed")
end

local function get_clip_start_value(clip_id)
    local stmt = db:prepare("SELECT start_value FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local start_value = stmt:value(0)
    stmt:finalize()
    return start_value
end

local function execute_batch(specs)
    local batch_cmd = Command.create("BatchCommand", "default_project")
    batch_cmd:set_parameter("commands_json", json.encode(specs))
    batch_cmd:set_parameter("sequence_id", "default_sequence")
    batch_cmd:set_parameter("__snapshot_sequence_ids", {"default_sequence"})
    local result = command_manager.execute(batch_cmd)
    assert(result.success, result.error_message or "BatchCommand failed")
end

----------------------------------------------------------------------
-- Test 1: Basic copy/paste + undo
----------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_clipboard_timeline_basic.db"
setup_database(TEST_DB)

insert_clip_via_command({
    clip_id = "clip_original",
    media_id = "media_original",
    track_id = "video1",
    start_value = 1000,
    duration_value = 800
})

timeline_state.reload_clips()
local base_clip = timeline_state.clip_lookup["clip_original"]
timeline_state.set_selection({base_clip})
focus_manager.set_focused_panel("timeline")

local ok, err = clipboard_actions.copy()
assert(ok, err or "copy failed")
local payload = clipboard.get()
assert(payload and payload.kind == "timeline_clips", "clipboard should contain timeline payload")

timeline_state.set_playhead_value(4000)
timeline_state.set_selection({})

local paste_ok, paste_err = clipboard_actions.paste()
assert(paste_ok, paste_err or "paste failed")

local verify_stmt = db:prepare([[
    SELECT COUNT(*) AS cnt, MIN(start_value)
    FROM clips
    WHERE clip_kind = 'timeline' AND id != 'clip_original'
]])
assert(verify_stmt:exec() and verify_stmt:next())
local pasted_count = verify_stmt:value(0)
local pasted_start = verify_stmt:value(1)
verify_stmt:finalize()

assert(pasted_count == 1, "expected exactly one pasted clip")
assert(pasted_start == 4000, string.format("pasted clip start_value should be 4000ms (got %s)", tostring(pasted_start)))

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo Paste should succeed")

local count_stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline'")
assert(count_stmt:exec() and count_stmt:next())
assert(count_stmt:value(0) == 1, "undo should restore original clip only")
count_stmt:finalize()

print("✅ Timeline clipboard copy/paste duplicates clips at the playhead and undoes cleanly")

----------------------------------------------------------------------
-- Test 2: Undo/Redo regression - downstream clip must stay put
----------------------------------------------------------------------

local REGRESSION_DB = "/tmp/jve/test_clipboard_timeline_regression.db"
setup_database(REGRESSION_DB)

-- Build baseline timeline with multiple commands (mirrors real-world history)
insert_clip_via_command({clip_id = "clip_src", media_id = "media_src", track_id = "video1", start_value = 0, duration_value = 2000})
insert_clip_via_command({clip_id = "clip_mid", media_id = "media_mid", track_id = "video1", start_value = 4543560, duration_value = 1500})
insert_clip_via_command({clip_id = "clip_tail", media_id = "media_tail", track_id = "video1", start_value = 9087120, duration_value = 1500})

execute_batch({
    {
        command_type = "MoveClipToTrack",
        parameters = {
            clip_id = "clip_src",
            target_track_id = "video2",
            project_id = "default_project"
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount_ms = -1636537,
            selected_clip_ids = {"clip_src"},
            project_id = "default_project",
            sequence_id = "default_sequence"
        }
    }
})

local baseline_other_start = get_clip_start_value("clip_tail")

timeline_state.reload_clips()
local src_clip = timeline_state.clip_lookup["clip_src"]
timeline_state.set_selection({src_clip})
focus_manager.set_focused_panel("timeline")

local copy_ok, copy_err = clipboard_actions.copy()
assert(copy_ok, copy_err or "copy failed")

timeline_state.set_playhead_value(16000000)
timeline_state.set_selection({})
local paste_result, paste_error = clipboard_actions.paste()
assert(paste_result, paste_error or "paste failed")

local undo_clipboard = command_manager.undo()
assert(undo_clipboard.success, "Undo after paste should succeed")

reopen_database(REGRESSION_DB)

local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo after paste failed")

local post_redo_other_start = get_clip_start_value("clip_tail")
assert(
    post_redo_other_start == baseline_other_start,
    string.format(
        "Undo/Redo after timeline paste should not move other tracks (expected %d, got %d)",
        baseline_other_start,
        post_redo_other_start
    )
)

print("✅ Redo after timeline clipboard paste preserves downstream clips on other tracks")

----------------------------------------------------------------------
-- Test 3: Cut emits timeline mutations without forcing reload
----------------------------------------------------------------------

local CUT_DB = "/tmp/jve/test_clipboard_cut_mutations.db"
setup_database(CUT_DB)

insert_clip_via_command({
    clip_id = "cut_clip",
    media_id = "cut_media",
    track_id = "video1",
    start_value = 5000,
    duration_value = 1200
})

timeline_state.reload_clips()
local cut_clip = timeline_state.clip_lookup["cut_clip"]
timeline_state.set_selection({cut_clip})
timeline_state.last_mutations = nil

local cut_cmd = Command.create("Cut", "default_project")
assert(command_manager.execute(cut_cmd).success, "Cut command should succeed")
assert(timeline_state.last_mutations, "Cut should emit timeline mutations")
assert(timeline_state.last_mutations.deletes and timeline_state.last_mutations.deletes[1] == "cut_clip",
    "Cut mutations must include deleted clip id")

print("✅ Cut emits delete mutations and keeps timeline cache hot")

----------------------------------------------------------------------
-- Test 4: RippleDeleteSelection emits delete/update mutations + undo inserts
----------------------------------------------------------------------

local RIPPLE_DB = "/tmp/jve/test_clipboard_ripple_delete.db"
setup_database(RIPPLE_DB)

insert_clip_via_command({
    clip_id = "ripple_clip_a",
    media_id = "ripple_media_a",
    track_id = "video1",
    start_value = 0,
    duration_value = 1000
})
insert_clip_via_command({
    clip_id = "ripple_clip_b",
    media_id = "ripple_media_b",
    track_id = "video1",
    start_value = 2000,
    duration_value = 1500
})

timeline_state.reload_clips()
timeline_state.last_mutations = nil

local ripple_cmd = Command.create("RippleDeleteSelection", "default_project")
ripple_cmd:set_parameter("clip_ids", {"ripple_clip_a"})
ripple_cmd:set_parameter("sequence_id", "default_sequence")
assert(command_manager.execute(ripple_cmd).success, "RippleDeleteSelection command failed")

local ripple_mutations = timeline_state.last_mutations
assert(ripple_mutations, "Ripple delete should emit timeline mutations")
assert(ripple_mutations.deletes and ripple_mutations.deletes[1] == "ripple_clip_a",
    "Ripple delete mutations must include deleted clip id")
assert(ripple_mutations.updates and #ripple_mutations.updates > 0,
    "Ripple delete mutations must include shifted clips")

timeline_state.last_mutations = nil
assert(command_manager.undo().success, "Undo RippleDeleteSelection should succeed")
local undo_mutations = timeline_state.last_mutations
assert(undo_mutations and undo_mutations.inserts and #undo_mutations.inserts > 0,
    "Undo ripple delete should emit insert mutations")

print("✅ RippleDeleteSelection emits mutations for delete/update and undo insert")
