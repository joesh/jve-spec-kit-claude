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

local SCHEMA_SQL = [[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        name TEXT,
        file_path TEXT,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        clip_kind TEXT NOT NULL DEFAULT 'timeline',
        name TEXT DEFAULT '',
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT NOT NULL DEFAULT 'STRING',
        default_value TEXT
    );

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );
]]

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 24.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('video2', 'default_sequence', 'V2', 'VIDEO', 2, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('video3', 'default_sequence', 'V3', 'VIDEO', 3, 1);
]]

local db = nil

local function reload_clips_into_state(state)
    state.clips = {}
    state.clip_lookup = {}
    local stmt = db:prepare([[
        SELECT id, track_id, start_time, duration, source_in, source_out, media_id, parent_clip_id
        FROM clips
        ORDER BY start_time
    ]])
    assert(stmt:exec())
    while stmt:next() do
        local entry = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            start_time = stmt:value(2),
            duration = stmt:value(3),
            source_in = stmt:value(4),
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
    playhead_time = 0,
    selected_clips = {},
    clip_lookup = {},
    project_id = "default_project",
    sequence_id = "default_sequence"
}

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips or {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.get_clip_by_id(id) return timeline_state.clip_lookup[id] end
function timeline_state.get_sequence_id() return timeline_state.sequence_id end
function timeline_state.get_project_id() return timeline_state.project_id end
function timeline_state.get_playhead_time() return timeline_state.playhead_time end
function timeline_state.set_playhead_time(ms) timeline_state.playhead_time = ms end
function timeline_state.reload_clips() reload_clips_into_state(timeline_state) end
function timeline_state.get_clips()
    timeline_state.reload_clips()
    return timeline_state.clips
end
function timeline_state.persist_state_to_db() end
function timeline_state.capture_viewport()
    return {
        start_time = 0,
        duration = 10000
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

    timeline_state.playhead_time = 0
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

    timeline_state.playhead_time = 0
    timeline_state.selected_clips = {}
    timeline_state.clip_lookup = {}
    reload_clips_into_state(timeline_state)
end

local function create_media_record(media_id, duration)
    local Media = require('models.media')
    local media = Media.create({
        id = media_id,
        project_id = 'default_project',
        file_path = '/tmp/' .. media_id .. '.mov',
        file_name = media_id .. '.mov',
        duration = duration,
        frame_rate = 24
    })
    assert(media:save(db))
end

local function insert_clip_via_command(params)
    create_media_record(params.media_id, params.duration)
    local insert_cmd = Command.create("Insert", "default_project")
    insert_cmd:set_parameter("media_id", params.media_id)
    insert_cmd:set_parameter("track_id", params.track_id)
    insert_cmd:set_parameter("sequence_id", "default_sequence")
    insert_cmd:set_parameter("insert_time", params.start_time)
    insert_cmd:set_parameter("duration", params.duration)
    insert_cmd:set_parameter("source_in", 0)
    insert_cmd:set_parameter("source_out", params.duration)
    insert_cmd:set_parameter("clip_id", params.clip_id)
    insert_cmd:set_parameter("advance_playhead", false)
    local result = command_manager.execute(insert_cmd)
    assert(result.success, result.error_message or "Insert command failed")
end

local function get_clip_start_time(clip_id)
    local stmt = db:prepare("SELECT start_time FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local start_time = stmt:value(0)
    stmt:finalize()
    return start_time
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

local TEST_DB = "/tmp/test_clipboard_timeline_basic.db"
setup_database(TEST_DB)

insert_clip_via_command({
    clip_id = "clip_original",
    media_id = "media_original",
    track_id = "video1",
    start_time = 1000,
    duration = 800
})

timeline_state.reload_clips()
local base_clip = timeline_state.clip_lookup["clip_original"]
timeline_state.set_selection({base_clip})
focus_manager.set_focused_panel("timeline")

local ok, err = clipboard_actions.copy()
assert(ok, err or "copy failed")
local payload = clipboard.get()
assert(payload and payload.kind == "timeline_clips", "clipboard should contain timeline payload")

timeline_state.set_playhead_time(4000)
timeline_state.set_selection({})

local paste_ok, paste_err = clipboard_actions.paste()
assert(paste_ok, paste_err or "paste failed")

local verify_stmt = db:prepare([[
    SELECT COUNT(*) AS cnt, MIN(start_time)
    FROM clips
    WHERE clip_kind = 'timeline' AND id != 'clip_original'
]])
assert(verify_stmt:exec() and verify_stmt:next())
local pasted_count = verify_stmt:value(0)
local pasted_start = verify_stmt:value(1)
verify_stmt:finalize()

assert(pasted_count == 1, "expected exactly one pasted clip")
assert(pasted_start == 4000, string.format("pasted clip start_time should be 4000ms (got %s)", tostring(pasted_start)))

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

local REGRESSION_DB = "/tmp/test_clipboard_timeline_regression.db"
setup_database(REGRESSION_DB)

-- Build baseline timeline with multiple commands (mirrors real-world history)
insert_clip_via_command({clip_id = "clip_src", media_id = "media_src", track_id = "video1", start_time = 0, duration = 2000})
insert_clip_via_command({clip_id = "clip_mid", media_id = "media_mid", track_id = "video1", start_time = 4543560, duration = 1500})
insert_clip_via_command({clip_id = "clip_tail", media_id = "media_tail", track_id = "video1", start_time = 9087120, duration = 1500})

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

local baseline_other_start = get_clip_start_time("clip_tail")

timeline_state.reload_clips()
local src_clip = timeline_state.clip_lookup["clip_src"]
timeline_state.set_selection({src_clip})
focus_manager.set_focused_panel("timeline")

local copy_ok, copy_err = clipboard_actions.copy()
assert(copy_ok, copy_err or "copy failed")

timeline_state.set_playhead_time(16000000)
timeline_state.set_selection({})
local paste_result, paste_error = clipboard_actions.paste()
assert(paste_result, paste_error or "paste failed")

local undo_clipboard = command_manager.undo()
assert(undo_clipboard.success, "Undo after paste should succeed")

reopen_database(REGRESSION_DB)

local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo after paste failed")

local post_redo_other_start = get_clip_start_time("clip_tail")
assert(
    post_redo_other_start == baseline_other_start,
    string.format(
        "Undo/Redo after timeline paste should not move other tracks (expected %d, got %d)",
        baseline_other_start,
        post_redo_other_start
    )
)

print("✅ Redo after timeline clipboard paste preserves downstream clips on other tracks")
