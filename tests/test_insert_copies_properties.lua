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
end

local function count_properties(db, clip_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM properties WHERE clip_id = ?")
    if not stmt then
        error("Failed to prepare property count statement")
    end
    stmt:bind_value(1, clip_id)
    local count = 0
    if stmt:exec() and stmt:next() then
        count = stmt:value(0) or 0
    end
    stmt:finalize()
    return count
end

local function fetch_property(db, clip_id, property_name)
    local stmt = db:prepare([[SELECT property_value FROM properties WHERE clip_id = ? AND property_name = ?]])
    if not stmt then
        error("Failed to prepare property fetch")
    end
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, property_name)
    local value = nil
    if stmt:exec() and stmt:next() then
        value = stmt:value(0)
    end
    stmt:finalize()
    return value
end

local function decode_json(raw)
    local ok, decoded = pcall(qt_json_decode, raw)
    if not ok then
        error("Failed to decode JSON: " .. tostring(decoded))
    end
    return decoded
end

print("=== Insert Command Property Propagation Tests ===")

local db_path = "/tmp/jve/test_insert_properties.db"
os.remove(db_path)

assert(database.init(db_path))
local db = database.get_connection()

db:exec(require('import_schema'))
db:exec("PRAGMA foreign_keys = ON;")
db:exec([[
    CREATE TABLE IF NOT EXISTS properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT,
        default_value TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Insert Test Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24, 1, 48000,
        1920, 1080,
        0, 240, 0,
        '[]', '[]', '[]',
        0, %d, %d
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

stub_timeline_state()
command_manager.init(db, 'timeline_seq', 'test_project')

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
    local Media = require("models.media")
    local media = Media.create({
        id = media_id,
        project_id = "test_project",
        name = "media.mov",
        file_path = "/tmp/jve/media.mov",
        duration = metadata.duration_ms,
        frame_rate = metadata.video and metadata.video.frame_rate or 0,
        width = metadata.video and metadata.video.width or 0,
        height = metadata.video and metadata.video.height or 0,
        audio_channels = metadata.audio and metadata.audio.channels or 0,
        codec = metadata.video and metadata.video.codec or metadata.audio.codec or "",
        created_at = now_ts,
        modified_at = now_ts
    })
    assert(media, "media import stub: failed to create media record")
    assert(media:save(conn), "media import stub: failed to insert media row")
    return media_id, metadata
end

local import_cmd = Command.create("ImportMedia", "test_project")
import_cmd:set_parameter("file_path", "/tmp/jve/media.mov")
import_cmd:set_parameter("project_id", "test_project")

local import_result = command_manager.execute(import_cmd)
assert(import_result.success, "ImportMedia command failed: " .. tostring(import_result.error_message))

local master_clip_id = import_cmd:get_parameter("master_clip_id")
assert(master_clip_id, "ImportMedia did not produce master_clip_id")

local set_property_cmd = Command.create("SetClipProperty", "test_project")
set_property_cmd:set_parameter("clip_id", master_clip_id)
set_property_cmd:set_parameter("property_name", "audio:sample_rate")
set_property_cmd:set_parameter("value", "48000")
set_property_cmd:set_parameter("property_type", "STRING")
set_property_cmd:set_parameter("default_value", "44100")

local property_result = command_manager.execute(set_property_cmd)
assert(property_result.success, "SetClipProperty failed: " .. tostring(property_result.error_message))

print("Test 1: Insert copies master clip properties to timeline clip")
local insert_cmd = Command.create("Insert", "test_project")
insert_cmd:set_parameter("media_id", import_cmd:get_parameter("media_id") or "media_001")
insert_cmd:set_parameter("track_id", "track_v1")
insert_cmd:set_parameter("sequence_id", "timeline_seq")
insert_cmd:set_parameter("project_id", "test_project")
insert_cmd:set_parameter("insert_time", 0)
insert_cmd:set_parameter("duration", 4000)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 4000)
insert_cmd:set_parameter("master_clip_id", master_clip_id)

local insert_result = command_manager.execute(insert_cmd)
assert(insert_result.success, "Insert command failed: " .. tostring(insert_result.error_message))

local new_clip_id = insert_cmd:get_parameter("clip_id")
assert(new_clip_id and new_clip_id ~= "", "Insert command did not record new clip_id")

local copied_value_raw = fetch_property(db, new_clip_id, "audio:sample_rate")
assert(copied_value_raw, "Timeline clip missing copied property")
local decoded_copied = decode_json(copied_value_raw)
assert(decoded_copied.value == "48000", "Copied property value mismatch: " .. tostring(decoded_copied.value))

print("Test 2: Undo removes copied properties")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo failed: " .. tostring(undo_result.error_message))
assert(count_properties(db, new_clip_id) == 0, "Properties should be removed after undo")

print("Test 3: Redo restores copied properties")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo failed: " .. tostring(redo_result.error_message))

local redo_clip_id = insert_cmd:get_parameter("clip_id")
assert(redo_clip_id == new_clip_id, "Redo produced unexpected clip_id")
local redo_value_raw = fetch_property(db, redo_clip_id, "audio:sample_rate")
assert(redo_value_raw, "Property missing after redo")
local decoded_redo = decode_json(redo_value_raw)
assert(decoded_redo.value == "48000", "Redo restored incorrect property value: " .. tostring(decoded_redo.value))

media_reader.import_media = original_import

print("✅ Insert property propagation tests passed")
