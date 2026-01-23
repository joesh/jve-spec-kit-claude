#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 1000}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.get_selected_clips = function() return {} end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_position = function(_) end
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.reload_clips = function() end
    timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 1000, fps_denominator = 1} end
    timeline_state.get_sequence_audio_sample_rate = function() return 48000 end
end

local function query_property(db, clip_id, property_name)
    local stmt = db:prepare([[
        SELECT property_value, property_type, default_value
        FROM properties
        WHERE clip_id = ? AND property_name = ?
    ]])
    if not stmt then
        error("Failed to prepare property query")
    end
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, property_name)

    local row = nil
    if stmt:exec() and stmt:next() then
        row = {
            property_value = stmt:value(0),
            property_type = stmt:value(1),
            default_value = stmt:value(2)
        }
    end
    stmt:finalize()
    return row
end

local function JSON_decode(raw)
    local ok, value = pcall(qt_json_decode, raw)
    if not ok then
        error("Failed to decode JSON: " .. tostring(value))
    end
    return value
end

print("=== SetClipProperty Command Tests ===")

local db_path = "/tmp/jve/test_set_clip_property.db"
os.remove(db_path)

assert(database.init(db_path))
local db = database.get_connection()

db:exec(require('import_schema'))
db:exec([[
    CREATE TABLE IF NOT EXISTS properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT,
        default_value TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Property Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        1000, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

stub_timeline_state()
command_manager.init("timeline_seq", "test_project")

local media_reader = require("media.media_reader")
local original_import = media_reader.import_media

media_reader.import_media = function(_, _, _, existing_media_id)
    local media_id = existing_media_id or "media_001"
    local metadata = {
        duration_ms = 4000,
        has_video = true,
        video = {width = 1920, height = 1080, frame_rate = 24.0, codec = "prores"},
        has_audio = true,
        audio = {channels = 2, sample_rate = 48000, codec = "aac"},
    }
    local conn = database.get_connection()
    assert(conn, "media import stub: database not initialized")
    local now_ts = os.time()
    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO media (
            id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
            width, height, audio_channels, codec, metadata, created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}', ?, ?)
    ]])
    assert(stmt, "media import stub: failed to prepare media insert")
    stmt:bind_value(1, media_id)
    stmt:bind_value(2, "test_project")
    stmt:bind_value(3, "media.mov")
    stmt:bind_value(4, "/tmp/jve/media.mov")
    stmt:bind_value(5, metadata.duration_ms)
    stmt:bind_value(6, 1000)
    stmt:bind_value(7, 1)
    stmt:bind_value(8, metadata.video and metadata.video.width or 0)
    stmt:bind_value(9, metadata.video and metadata.video.height or 0)
    stmt:bind_value(10, metadata.audio and metadata.audio.channels or 0)
    stmt:bind_value(11, metadata.video and metadata.video.codec or metadata.audio.codec or "")
    stmt:bind_value(12, now_ts)
    stmt:bind_value(13, now_ts)
    assert(stmt:exec(), "media import stub: failed to insert media row")
    stmt:finalize()
    return media_id, metadata
end

local import_cmd = Command.create("ImportMedia", "test_project")
import_cmd:set_parameter("file_path", "/tmp/jve/test_source.mov")
import_cmd:set_parameter("project_id", "test_project")

local import_result = command_manager.execute(import_cmd)
assert(import_result.success, "ImportMedia command failed: " .. tostring(import_result.error_message))

-- ImportMedia stores arrays of IDs (supports multiple files)
local master_clip_ids = import_cmd:get_parameter("master_clip_ids")
assert(master_clip_ids and #master_clip_ids > 0, "Expected master_clip_ids array from ImportMedia")
local master_clip_id = master_clip_ids[1]
assert(master_clip_id and master_clip_id ~= "", "Expected valid master_clip_id")

local property_name = "audio:sample_rate"

print("Test 1: Setting new clip property creates property row")
local set_cmd = Command.create("SetClipProperty", "test_project")
set_cmd:set_parameter("clip_id", master_clip_id)
set_cmd:set_parameter("property_name", property_name)
set_cmd:set_parameter("value", "48000")
set_cmd:set_parameter("property_type", "STRING")
set_cmd:set_parameter("default_value", "44100")

local set_result = command_manager.execute(set_cmd)
assert(set_result.success, "SetClipProperty command failed: " .. tostring(set_result.error_message))

local property_row = query_property(db, master_clip_id, property_name)
assert(property_row, "Property row not created")

local decoded_value = JSON_decode(property_row.property_value)
assert(decoded_value.value == "48000", "Expected property value 48000, got " .. tostring(decoded_value.value))
assert(property_row.property_type == "STRING", "Expected property type STRING, got " .. tostring(property_row.property_type))

print("Test 2: Undo removes newly created property")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo failed: " .. tostring(undo_result.error_message))
local row_after_undo = query_property(db, master_clip_id, property_name)
assert(row_after_undo == nil, "Property row should be removed after undo")

print("Test 3: Redo recreates property with original value")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo failed: " .. tostring(redo_result.error_message))
local row_after_redo = query_property(db, master_clip_id, property_name)
assert(row_after_redo, "Property row missing after redo")
local decoded_after_redo = JSON_decode(row_after_redo.property_value)
assert(decoded_after_redo.value == "48000", "Redo restored incorrect property value: " .. tostring(decoded_after_redo.value))

print("Test 4: Updating existing property stores previous value for undo")
local update_cmd = Command.create("SetClipProperty", "test_project")
update_cmd:set_parameter("clip_id", master_clip_id)
update_cmd:set_parameter("property_name", property_name)
update_cmd:set_parameter("value", "96000")
update_cmd:set_parameter("property_type", "STRING")

local update_result = command_manager.execute(update_cmd)
assert(update_result.success, "Update SetClipProperty failed: " .. tostring(update_result.error_message))

local row_after_update = query_property(db, master_clip_id, property_name)
local decoded_after_update = JSON_decode(row_after_update.property_value)
assert(decoded_after_update.value == "96000", "Expected 96000, got " .. tostring(decoded_after_update.value))

print("Test 5: Undo update restores previous value")
local undo_update_result = command_manager.undo()
assert(undo_update_result.success, "Undo update failed: " .. tostring(undo_update_result.error_message))

local row_after_undo_update = query_property(db, master_clip_id, property_name)
local decoded_after_undo_update = JSON_decode(row_after_undo_update.property_value)
assert(decoded_after_undo_update.value == "48000", "Undo should restore 48000, got " .. tostring(decoded_after_undo_update.value))

print("Test 6: Multiple undo/redo cycles maintain integrity")
-- Redo the update we undid
local redo_update = command_manager.redo()
assert(redo_update.success, "Redo update failed")
local row_check = query_property(db, master_clip_id, property_name)
local decoded_check = JSON_decode(row_check.property_value)
assert(decoded_check.value == "96000", "After redo, expected 96000")

-- Cycle through a few more times
for i = 1, 2 do
    local u = command_manager.undo()
    assert(u.success, "Undo cycle " .. i .. " failed")
    local r = command_manager.redo()
    assert(r.success, "Redo cycle " .. i .. " failed")
end

local final_row = query_property(db, master_clip_id, property_name)
local final_decoded = JSON_decode(final_row.property_value)
assert(final_decoded.value == "96000", "Final value should be 96000 after cycles")

print("Test 7: Setting property on nonexistent clip (expect warning, command skips gracefully)")
local ghost_cmd = Command.create("SetClipProperty", "test_project")
ghost_cmd:set_parameter("clip_id", "nonexistent_clip_id")
ghost_cmd:set_parameter("property_name", "test_property")
ghost_cmd:set_parameter("value", "test_value")
ghost_cmd:set_parameter("property_type", "STRING")

-- Note: SetClipProperty returns true even for missing clips (logs warning and skips)
local ghost_result = command_manager.execute(ghost_cmd)
assert(ghost_result.success, "SetClipProperty on missing clip should succeed (skip gracefully)")

print("✅ All SetClipProperty tests passed")

media_reader.import_media = original_import
