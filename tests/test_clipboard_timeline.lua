#!/usr/bin/env luajit

-- Clipboard timeline operations: copy, paste, cut, ripple-delete.
-- Uses REAL timeline_state — no mock. Verifies DB side effects (black-box).

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mocks needed: panel_manager (Qt), project_browser (Qt)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.project_browser"] = false

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local clipboard = require('core.clipboard')
local json = require('dkjson')
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager = require("ui.focus_manager")

local SCHEMA_SQL = require("import_schema")

local now = os.time()
local BASE_DATA_SQL = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_a1', 'default_sequence', 'Audio 1', 'AUDIO', 1, 1);
]], now, now, now, now)

local clipboard_actions = require('core.clipboard_actions')

-- Cache masterclip IDs by media_id to avoid recreating
local masterclip_cache = {}

local function setup_database(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec([[
        CREATE TABLE IF NOT EXISTS properties (
            id TEXT PRIMARY KEY,
            clip_id TEXT NOT NULL,
            property_name TEXT NOT NULL,
            property_value TEXT,
            property_type TEXT,
            default_value TEXT
        );
    ]]))
    assert(conn:exec(BASE_DATA_SQL))
    command_manager.init('default_sequence', 'default_project')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    clipboard.clear()
    masterclip_cache = {}
end

local function reopen_database(path)
    assert(database.set_path(path))
    command_manager.init('default_sequence', 'default_project')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
end

local function create_media_and_masterclip(media_id, duration_value)
    if masterclip_cache[media_id] then
        return masterclip_cache[media_id]
    end
    local Media = require('models.media')
    local duration_frames = math.floor(duration_value * 30 / 1000)
    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. media_id .. '.mov',
        name = media_id,
        duration_frames = duration_frames,
        fps_numerator = 30,
        fps_denominator = 1,
    })
    media:save(database.get_connection())
    local master_clip_id = test_env.create_test_masterclip_sequence(
        'default_project', media_id .. ' Master', 30, 1, duration_frames, media_id)
    masterclip_cache[media_id] = master_clip_id
    return master_clip_id
end

local function insert_clip_via_command(params)
    local master_clip_id = create_media_and_masterclip(params.media_id, params.duration_value)
    local insert_cmd = Command.create("Insert", "default_project")
    insert_cmd:set_parameter("master_clip_id", master_clip_id)
    insert_cmd:set_parameter("track_id", params.track_id)
    insert_cmd:set_parameter("sequence_id", "default_sequence")
    insert_cmd:set_parameter("insert_time", params.start_value)
    insert_cmd:set_parameter("duration", params.duration_value)
    insert_cmd:set_parameter("source_in", 0)
    insert_cmd:set_parameter("source_out", params.duration_value)
    insert_cmd:set_parameter("clip_id", params.clip_id)
    insert_cmd:set_parameter("advance_playhead", false)
    local result = command_manager.execute(insert_cmd)
    assert(result.success, result.error_message or "Insert command failed")
end

local function get_clip_start_value(clip_id)
    local conn = database.get_connection()
    local stmt = conn:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    if not (stmt:exec() and stmt:next()) then
        stmt:finalize()
        error("clip not found: " .. tostring(clip_id))
    end
    local start_value = stmt:value(0) * 1000.0 / 30.0
    stmt:finalize()
    return start_value
end

local function execute_batch(specs)
    local batch_cmd = Command.create("BatchCommand", "default_project")
    batch_cmd:set_parameter("commands_json", json.encode(specs))
    batch_cmd:set_parameter("sequence_id", "default_sequence")
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
    track_id = "track_v1",
    start_value = 1000,
    duration_value = 800
})

-- Get clip from real timeline_state
local base_clip = timeline_state.get_clip_by_id("clip_original")
assert(base_clip, "clip_original should be in timeline after insert")
timeline_state.set_selection({base_clip})
focus_manager.set_focused_panel("timeline")

local ok, err = clipboard_actions.copy()
assert(ok, err or "copy failed")
local payload = clipboard.get()
assert(payload and payload.kind == "timeline_clips", "clipboard should contain timeline payload")

timeline_state.set_playhead_position(4000)
timeline_state.set_selection({})

local paste_ok, paste_err = clipboard_actions.paste()
assert(paste_ok, paste_err or "paste failed")

local verify_conn = database.get_connection()

-- IS-a refactor: filter by owner_sequence_id to exclude masterclip stream clips
local verify_stmt = verify_conn:prepare([[
    SELECT COUNT(*) AS cnt, MIN(timeline_start_frame)
    FROM clips
    WHERE owner_sequence_id = 'default_sequence' AND id != 'clip_original'
]])
assert(verify_stmt:exec() and verify_stmt:next())
local pasted_count = verify_stmt:value(0)
local pasted_start_frame = verify_stmt:value(1)
local pasted_start_ms = pasted_start_frame * 1000.0 / 30.0
verify_stmt:finalize()

assert(pasted_count == 1, "expected exactly one pasted clip")
assert(math.abs(pasted_start_ms - 4000) < 1, string.format("pasted clip start should be 4000ms (got %f)", pasted_start_ms))

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo Paste should succeed")

local count_conn = database.get_connection()
-- IS-a refactor: filter by owner_sequence_id to exclude masterclip stream clips
local count_stmt = count_conn:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'default_sequence'")
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
insert_clip_via_command({clip_id = "clip_src", media_id = "media_src", track_id = "track_v1", start_value = 0, duration_value = 2000})
insert_clip_via_command({clip_id = "clip_mid", media_id = "media_mid", track_id = "track_v1", start_value = 4543560, duration_value = 1500})
insert_clip_via_command({clip_id = "clip_tail", media_id = "media_tail", track_id = "track_v1", start_value = 9087120, duration_value = 1500})

-- Verify clip_tail exists before batch
local _ = get_clip_start_value("clip_tail") -- luacheck: ignore 211

execute_batch({
    {
        command_type = "MoveClipToTrack",
        parameters = {
            clip_id = "clip_src",
            target_track_id = "track_a1", -- Use existing audio track as target
            project_id = "default_project"
        }
    },
    {
        command_type = "Nudge",
        parameters = {
            nudge_amount = -49096, -- Frames
            selected_clip_ids = {"clip_src"},
            project_id = "default_project",
            sequence_id = "default_sequence"
        }
    }
})

local baseline_other_start = get_clip_start_value("clip_tail")

-- Copy clip_src and paste at a far position
local src_clip = timeline_state.get_clip_by_id("clip_src")
assert(src_clip, "clip_src should be in timeline")
timeline_state.set_selection({src_clip})
focus_manager.set_focused_panel("timeline")

local copy_ok, copy_err = clipboard_actions.copy()
assert(copy_ok, copy_err or "copy failed")

timeline_state.set_playhead_position(16000000)
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
-- Test 3: Cut removes clip from DB and places data on clipboard
----------------------------------------------------------------------

local CUT_DB = "/tmp/jve/test_clipboard_cut_mutations.db"
setup_database(CUT_DB)

insert_clip_via_command({
    clip_id = "cut_clip",
    media_id = "cut_media",
    track_id = "track_v1",
    start_value = 5000,
    duration_value = 1200
})

-- Select the clip for cutting
local cut_clip = timeline_state.get_clip_by_id("cut_clip")
assert(cut_clip, "cut_clip should be in timeline")
timeline_state.set_selection({cut_clip})

local cut_cmd = Command.create("Cut", "default_project")
assert(command_manager.execute(cut_cmd).success, "Cut command should succeed")

-- Black-box: clip should be removed from DB
local clips_after_cut = database.load_clips("default_sequence")
local cut_clip_exists = false
for _, c in ipairs(clips_after_cut) do
    if c.id == "cut_clip" then cut_clip_exists = true; break end
end
assert(not cut_clip_exists, "Cut clip should be removed from DB")

-- Black-box: clipboard should contain the cut clip data
local cut_payload = clipboard.get()
assert(cut_payload and cut_payload.kind == "timeline_clips",
    "Cut should place clip data on clipboard")

print("✅ Cut removes clip from DB and places data on clipboard")

----------------------------------------------------------------------
-- Test 4: RippleDeleteSelection deletes clip + shifts downstream, undo restores
----------------------------------------------------------------------

local RIPPLE_DB = "/tmp/jve/test_clipboard_ripple_delete.db"
setup_database(RIPPLE_DB)

insert_clip_via_command({
    clip_id = "ripple_clip_a",
    media_id = "ripple_media_a",
    track_id = "track_v1",
    start_value = 0,
    duration_value = 1000
})
insert_clip_via_command({
    clip_id = "ripple_clip_b",
    media_id = "ripple_media_b",
    track_id = "track_v1",
    start_value = 2000,
    duration_value = 1500
})

-- Record original clip_b position
local original_clip_b_start = get_clip_start_value("ripple_clip_b")

local ripple_cmd = Command.create("RippleDeleteSelection", "default_project")
ripple_cmd:set_parameter("clip_ids", {"ripple_clip_a"})
ripple_cmd:set_parameter("sequence_id", "default_sequence")
assert(command_manager.execute(ripple_cmd).success, "RippleDeleteSelection command failed")

-- Black-box: clip_a should be deleted from DB
local clips_after_ripple = database.load_clips("default_sequence")
local ripple_a_found = false
local ripple_b_after = nil
for _, c in ipairs(clips_after_ripple) do
    if c.id == "ripple_clip_a" then ripple_a_found = true end
    if c.id == "ripple_clip_b" then ripple_b_after = c end
end
assert(not ripple_a_found, "ripple_clip_a should be deleted")
assert(ripple_b_after, "ripple_clip_b should still exist")

-- Black-box: clip_b should have shifted left (ripple closes gap)
local ripple_b_start_after = ripple_b_after.timeline_start * 1000.0 / 30.0
assert(ripple_b_start_after < original_clip_b_start,
    string.format("clip_b should have shifted left after ripple (was %f, now %f)",
        original_clip_b_start, ripple_b_start_after))

-- Undo should restore both clips at original positions
assert(command_manager.undo().success, "Undo RippleDeleteSelection should succeed")

local clips_after_undo = database.load_clips("default_sequence")
local undo_a_found = false
local undo_b_start = nil
for _, c in ipairs(clips_after_undo) do
    if c.id == "ripple_clip_a" then undo_a_found = true end
    if c.id == "ripple_clip_b" then undo_b_start = c.timeline_start * 1000.0 / 30.0 end
end
assert(undo_a_found, "Undo should restore ripple_clip_a")
assert(math.abs(undo_b_start - original_clip_b_start) < 1,
    string.format("Undo should restore clip_b position (expected %f, got %f)",
        original_clip_b_start, undo_b_start))

print("✅ RippleDeleteSelection deletes clip, shifts downstream, undo restores both")
