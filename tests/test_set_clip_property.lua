#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 24}
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
    timeline_state.get_sequence_frame_rate = function() return 24.0 end
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

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Property Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
        timecode_start_frame, playhead_value, selected_clip_ids, selected_edge_infos,
        viewport_start_value, viewport_duration_frames_value, current_sequence_number)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24.0, 48000, 1920, 1080, 0, 0, '[]', '[]', 0, 240, NULL);

    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 'video_frames', 24.0, 1, 1);
]], now, now))

stub_timeline_state()
command_manager.init(db, "timeline_seq", "test_project")

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
            id, project_id, name, file_path, duration_value, timebase_type, timebase_rate,
            frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}')
    ]])
    assert(stmt, "media import stub: failed to prepare media insert")
    stmt:bind_value(1, media_id)
    stmt:bind_value(2, "test_project")
    stmt:bind_value(3, "media.mov")
    stmt:bind_value(4, "/tmp/jve/media.mov")
    stmt:bind_value(5, metadata.duration_ms)
    stmt:bind_value(6, metadata.has_video and "video_frames" or "audio_samples")
    stmt:bind_value(7, metadata.video and metadata.video.frame_rate or metadata.audio.sample_rate or 1000)
    stmt:bind_value(8, metadata.video and metadata.video.frame_rate or 0)
    stmt:bind_value(9, metadata.video and metadata.video.width or 0)
    stmt:bind_value(10, metadata.video and metadata.video.height or 0)
    stmt:bind_value(11, metadata.audio and metadata.audio.channels or 0)
    stmt:bind_value(12, metadata.video and metadata.video.codec or metadata.audio.codec or "")
    stmt:bind_value(13, now_ts)
    stmt:bind_value(14, now_ts)
    assert(stmt:exec(), "media import stub: failed to insert media row")
    stmt:finalize()
    return media_id, metadata
end

local import_cmd = Command.create("ImportMedia", "test_project")
import_cmd:set_parameter("file_path", "/tmp/jve/test_source.mov")
import_cmd:set_parameter("project_id", "test_project")

local import_result = command_manager.execute(import_cmd)
assert(import_result.success, "ImportMedia command failed: " .. tostring(import_result.error_message))

local master_clip_id = import_cmd:get_parameter("master_clip_id")
assert(master_clip_id and master_clip_id ~= "", "Expected master_clip_id from ImportMedia")

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

print("✅ All SetClipProperty tests passed")

media_reader.import_media = original_import
