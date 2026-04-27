#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")
local json = require("dkjson")
local uuid = require("uuid")

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

--- Read clip name directly from DB
local function read_clip_name(db, clip_id)
    local stmt = db:prepare("SELECT name FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare name query")
    stmt:bind_value(1, clip_id)
    local name
    if stmt:exec() and stmt:next() then
        name = stmt:value(0)
    end
    stmt:finalize()
    return name
end

--- Read property value from properties table (JSON-decoded)
local function read_property(db, clip_id, property_name)
    local stmt = db:prepare("SELECT property_value FROM properties WHERE clip_id = ? AND property_name = ?")
    assert(stmt, "failed to prepare property query")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, property_name)
    local raw
    if stmt:exec() and stmt:next() then
        raw = stmt:value(0)
    end
    stmt:finalize()
    if not raw then return nil end
    local decoded = json.decode(raw)
    if type(decoded) == "table" and decoded.value ~= nil then
        return decoded.value
    end
    return decoded
end

--- Insert a property row
local function insert_property(db, clip_id, property_name, value)
    local encoded = json.encode({ value = value })
    local stmt = db:prepare("INSERT INTO properties (id, clip_id, property_name, property_value, property_type) VALUES (?, ?, ?, ?, 'string')")
    assert(stmt, "failed to prepare property insert")
    stmt:bind_value(1, uuid.generate())
    stmt:bind_value(2, clip_id)
    stmt:bind_value(3, property_name)
    stmt:bind_value(4, encoded)
    assert(stmt:exec(), "failed to insert property")
    stmt:finalize()
end

print("=== ReplaceClipProperty / ReplaceAllClipProperties Tests ===")

local pass_count = 0
local fail_count = 0

local function check(label, condition, msg)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. " -- " .. (msg or ""))
    end
end

-- Setup DB
local db_path = "/tmp/jve/test_replace_commands.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()


db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d)
]], now, now))

db:exec(string.format([[
    INSERT OR IGNORE INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'nested', 1000, 1, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d)
]], now, now))

db:exec([[
    INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)
]])

-- Insert clips with non-trivial names
local clip_ids = {"clip_a", "clip_b", "clip_c", "clip_d"}
local clip_names = {
    "Scene01_v1_final",
    "Scene02_v1_draft",
    "Scene03_v1_color",
    "Scene04_noMatch",
}
-- V13 placeholder master sequence + media_ref + media for clips below.
db:exec([[
INSERT OR IGNORE INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj1', 'placeholder', '_placeholder', 1000, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT OR IGNORE INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj1', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT OR IGNORE INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
]])

for i, cid in ipairs(clip_ids) do
    local rc, err = db:exec(string.format([[
INSERT INTO clips (id, project_id, owner_sequence_id, track_id, nested_sequence_id, name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('%s', 'proj1', 'seq1', 'track1', '_v13_placeholder_master', '%s', %d, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]], cid, clip_names[i], (i - 1) * 100, now, now))
    assert(rc, "clip insert failed for " .. cid .. ": " .. tostring(err))
end

stub_timeline_state()
command_manager.init("seq1", "proj1")

---------------------------------------------------------------------------
-- Test 1: ReplaceClipProperty on clip name
---------------------------------------------------------------------------
print("Test 1: ReplaceClipProperty replaces substring in clip name")
local cmd1 = Command.create("ReplaceClipProperty", "proj1")
cmd1:set_parameter("clip_id", "clip_a")
cmd1:set_parameter("column", "name")
cmd1:set_parameter("find_value", "v1")
cmd1:set_parameter("replace_value", "v2")

local result1 = command_manager.execute(cmd1)
check("T1 execute success", result1.success, tostring(result1.error_message))
local name_after = read_clip_name(db, "clip_a")
check("T1 name replaced", name_after == "Scene01_v2_final",
    "expected 'Scene01_v2_final', got '" .. tostring(name_after) .. "'")

---------------------------------------------------------------------------
-- Test 2: Undo restores original name
---------------------------------------------------------------------------
print("Test 2: Undo restores original name")
local undo1 = command_manager.undo()
check("T2 undo success", undo1.success, tostring(undo1.error_message))
local name_undone = read_clip_name(db, "clip_a")
check("T2 name restored", name_undone == "Scene01_v1_final",
    "expected 'Scene01_v1_final', got '" .. tostring(name_undone) .. "'")

---------------------------------------------------------------------------
-- Test 3: Redo re-applies replacement
---------------------------------------------------------------------------
print("Test 3: Redo re-applies replacement")
local redo1 = command_manager.redo()
check("T3 redo success", redo1.success, tostring(redo1.error_message))
local name_redone = read_clip_name(db, "clip_a")
check("T3 name re-replaced", name_redone == "Scene01_v2_final",
    "expected 'Scene01_v2_final', got '" .. tostring(name_redone) .. "'")

-- Undo to reset clip_a back to original for batch test
command_manager.undo()

---------------------------------------------------------------------------
-- Test 4: ReplaceAllClipProperties batch replace on 3 clips
---------------------------------------------------------------------------
print("Test 4: ReplaceAllClipProperties batch replace v1 -> v2")
local cmd4 = Command.create("ReplaceAllClipProperties", "proj1")
cmd4:set_parameter("clip_ids", {"clip_a", "clip_b", "clip_c"})
cmd4:set_parameter("column", "name")
cmd4:set_parameter("find_value", "v1")
cmd4:set_parameter("replace_value", "v2")

local result4 = command_manager.execute(cmd4)
check("T4 execute success", result4.success, tostring(result4.error_message))
check("T4 clip_a replaced", read_clip_name(db, "clip_a") == "Scene01_v2_final",
    "got: " .. tostring(read_clip_name(db, "clip_a")))
check("T4 clip_b replaced", read_clip_name(db, "clip_b") == "Scene02_v2_draft",
    "got: " .. tostring(read_clip_name(db, "clip_b")))
check("T4 clip_c replaced", read_clip_name(db, "clip_c") == "Scene03_v2_color",
    "got: " .. tostring(read_clip_name(db, "clip_c")))

---------------------------------------------------------------------------
-- Test 5: Undo ReplaceAll restores all 3 names
---------------------------------------------------------------------------
print("Test 5: Undo ReplaceAll restores all 3 names")
local undo4 = command_manager.undo()
check("T5 undo success", undo4.success, tostring(undo4.error_message))
check("T5 clip_a restored", read_clip_name(db, "clip_a") == "Scene01_v1_final",
    "got: " .. tostring(read_clip_name(db, "clip_a")))
check("T5 clip_b restored", read_clip_name(db, "clip_b") == "Scene02_v1_draft",
    "got: " .. tostring(read_clip_name(db, "clip_b")))
check("T5 clip_c restored", read_clip_name(db, "clip_c") == "Scene03_v1_color",
    "got: " .. tostring(read_clip_name(db, "clip_c")))

---------------------------------------------------------------------------
-- Test 6: Replace when find_value not found (clip unchanged, command succeeds)
---------------------------------------------------------------------------
print("Test 6: Replace when find_value not found")
local cmd6 = Command.create("ReplaceClipProperty", "proj1")
cmd6:set_parameter("clip_id", "clip_d")
cmd6:set_parameter("column", "name")
cmd6:set_parameter("find_value", "NONEXISTENT_PATTERN")
cmd6:set_parameter("replace_value", "anything")

local result6 = command_manager.execute(cmd6)
check("T6 execute success", result6.success, tostring(result6.error_message))
local name_unchanged = read_clip_name(db, "clip_d")
check("T6 name unchanged", name_unchanged == "Scene04_noMatch",
    "expected 'Scene04_noMatch', got '" .. tostring(name_unchanged) .. "'")

---------------------------------------------------------------------------
-- Test 7: Replace on a custom property (via properties table)
---------------------------------------------------------------------------
print("Test 7: Replace on custom property in properties table")
insert_property(db, "clip_a", "reel_name", "REEL_v1_A001")

local cmd7 = Command.create("ReplaceClipProperty", "proj1")
cmd7:set_parameter("clip_id", "clip_a")
cmd7:set_parameter("column", "reel_name")
cmd7:set_parameter("find_value", "v1")
cmd7:set_parameter("replace_value", "v3")

local result7 = command_manager.execute(cmd7)
check("T7 execute success", result7.success, tostring(result7.error_message))
local prop_after = read_property(db, "clip_a", "reel_name")
check("T7 property replaced", prop_after == "REEL_v3_A001",
    "expected 'REEL_v3_A001', got '" .. tostring(prop_after) .. "'")

-- Undo property replace
local undo7 = command_manager.undo()
check("T7 undo success", undo7.success, tostring(undo7.error_message))
local prop_undone = read_property(db, "clip_a", "reel_name")
check("T7 property restored", prop_undone == "REEL_v1_A001",
    "expected 'REEL_v1_A001', got '" .. tostring(prop_undone) .. "'")

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    error(fail_count .. " test(s) failed")
end
print("✅ test_replace_commands.lua passed")
