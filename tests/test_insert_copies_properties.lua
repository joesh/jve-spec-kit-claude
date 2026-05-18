#!/usr/bin/env luajit
-- Black-box: after Insert places a master sequence onto a timeline, the new
-- clip is reachable through the standard Inspector interface, properties set
-- through that interface persist, and undo/redo restore them.
--
-- Original V8 test peeked under the hood at the `properties` table to verify
-- a copy was made at Insert time. V13 changed the semantic (FR-007: clips
-- track master live for non-overridden properties), so this rewrite drops
-- the copy-detection peek and instead verifies the user-observable contract:
-- if you set a property on a clip via the Inspector, you read the same value
-- back via the Inspector — including across undo / redo.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local Media = require("models.media")
local Clip = require("models.clip")
local inspectable_factory = require("inspectable")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== Insert + Inspector property round-trip ===")

local db_path = "/tmp/jve/test_insert_copies_properties.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Insert Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('timeline_seq', 'proj', 'Timeline', 'sequence',
        24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('tv1', 'timeline_seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now))

command_manager.init('timeline_seq', 'proj')

-- Create media + a master sequence wrapping it (V13 placement source).
local media = Media.create({
    id = "media1",
    project_id = "proj",
    file_path = "/tmp/jve/media1.mov",
    name = "media1.mov",
    duration_frames = 240,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
})
assert(media:save(db), "media save failed")
local master_id = test_env.create_test_masterclip_sequence(
    "proj", "Media1 Master", 24, 1, 240, "media1")

-- Drive Insert with the standard command interface.
local insert_cmd = Command.create("Insert", "proj")
insert_cmd:set_parameter("sequence_id", "timeline_seq")
insert_cmd:set_parameter("source_sequence_id", master_id)
insert_cmd:set_parameter("target_video_track_id", "tv1")
insert_cmd:set_parameter("sequence_start_frame", 0)
insert_cmd:set_parameter("clip_name", "Inserted Clip")
local insert_result = command_manager.execute(insert_cmd)
assert(insert_result.success,
    "Insert failed: " .. tostring(insert_result.error_message))

local created_clip_ids = insert_cmd:get_parameter("created_clip_ids")
assert(created_clip_ids and #created_clip_ids > 0,
    "Insert did not record created_clip_ids")

-- Locate the video clip among the created rows.
local function video_clip_id_among(ids)
    for _, cid in ipairs(ids) do
        local clip = Clip.load(cid)
        if clip then
            local stmt = db:prepare("SELECT track_type FROM tracks WHERE id = ?")
            stmt:bind_value(1, clip.track_id)
            assert(stmt:exec() and stmt:next(),
                "track lookup failed for " .. clip.track_id)
            local tt = stmt:value(0)
            stmt:finalize()
            if tt == "VIDEO" then return cid end
        end
    end
    error("no video clip among created_clip_ids")
end

local clip_id = video_clip_id_among(created_clip_ids)

-- ─────────────────────────────────────────────────────────────────────
-- Property round-trip via the Inspector — no peeking at the DB tables.
-- ─────────────────────────────────────────────────────────────────────
print("Test 1: Inspector set / get round-trips a custom property")
local clip_view = inspectable_factory.clip({
    clip_id = clip_id,
    project_id = "proj",
    sequence_id = "timeline_seq",
})

local ok_set, set_err = clip_view:set("audio:sample_rate", {
    value = "48000",
    property_type = "STRING",
    default_value = "44100",
})
assert(ok_set, "Inspector set failed: " .. tostring(set_err))

clip_view:refresh()
local read_back = clip_view:get("audio:sample_rate")
assert(read_back == "48000", string.format(
    "Inspector get returned %s; expected '48000'", tostring(read_back)))

print("Test 2: Undo restores the prior absence")
local undo_result = command_manager.undo()
assert(undo_result.success,
    "Undo failed: " .. tostring(undo_result.error_message))
clip_view:refresh()
local after_undo = clip_view:get("audio:sample_rate")
assert(after_undo == nil, string.format(
    "After undo, expected nil; got %s", tostring(after_undo)))

print("Test 3: Redo restores the property")
local redo_result = command_manager.redo()
assert(redo_result.success,
    "Redo failed: " .. tostring(redo_result.error_message))
clip_view:refresh()
local after_redo = clip_view:get("audio:sample_rate")
assert(after_redo == "48000", string.format(
    "After redo, expected '48000'; got %s", tostring(after_redo)))

print("Test 4: The clip's name reflects what Insert produced")
clip_view:refresh()
local name = clip_view:get("name") or clip_view:get_display_name()
assert(name and name ~= "", "Inspector returned empty clip name")

print("✅ test_insert_copies_properties.lua passed")
