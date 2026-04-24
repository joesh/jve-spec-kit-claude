#!/usr/bin/env luajit
-- Contract test T005: TIMECODE branch at inspectable:set boundary (FR-012, Q3 resolution).
-- Black-box: asserts that integer-frame TIMECODE payloads persist, non-integer / negative
-- TIMECODE values assert with an actionable message (rule 1.14).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local inspectable_factory = require("inspectable")
local command_manager = require("core.command_manager")

-- Mock Qt timer: commands may schedule one.
_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== Inspector: inspectable :set TIMECODE branch contract ===\n")

-- Set up a minimal DB with a project, a sequence, a clip.
local db_path = "/tmp/jve/test_inspector_set_timecode.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj', 'Test', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator,
                           audio_rate, width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO tracks (id, sequence_id, name, kind, track_index, created_at, modified_at)
    VALUES ('trk', 'seq', 'V1', 'video', 0, %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO clips (id, project_id, sequence_id, track_id, name, clip_kind,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, created_at, modified_at)
    VALUES ('c1', 'proj', 'seq', 'trk', 'ClipOne', 'timeline',
            0, 240, 100, 340, 24, 1, 1, %d, %d);
]], now, now))

command_manager.init_project_only("proj")

local pass, fail = 0, 0
local function check(label, ok, msg) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label .. (msg and (": " .. msg) or "")) end end

local clip = inspectable_factory.clip({ clip_id = "c1", project_id = "proj", sequence_id = "seq" })

-- Valid TIMECODE payload persists.
local ok_set, err_set = clip:set("source_in_frame", {
    value = 144, property_type = "TIMECODE"
})
check("valid TIMECODE payload persists", ok_set == true,
    tostring(err_set))

-- Non-integer TIMECODE value asserts.
do
    local ok = pcall(function()
        clip:set("source_in_frame", { value = 3.14, property_type = "TIMECODE" })
    end)
    check("non-integer TIMECODE asserts", ok == false)
end

-- Negative TIMECODE value asserts.
do
    local ok, err = pcall(function()
        clip:set("source_in_frame", { value = -5, property_type = "TIMECODE" })
    end)
    check("negative TIMECODE asserts", ok == false)
    check("negative TIMECODE error mentions 'non-negative'",
        err and tostring(err):find("non%-negative", 1, false) ~= nil)
end

-- Non-number TIMECODE value asserts.
do
    local ok = pcall(function()
        clip:set("source_in_frame", { value = "100", property_type = "TIMECODE" })
    end)
    check("string TIMECODE value asserts", ok == false)
end

-- STRING / NUMBER / BOOLEAN still work (non-TIMECODE paths).
local ok_str = clip:set("name", { value = "Renamed", property_type = "STRING" })
check("STRING payload persists", ok_str == true)
local ok_bool = clip:set("enabled", { value = false, property_type = "BOOLEAN" })
check("BOOLEAN payload persists", ok_bool == true)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_set_timecode_contract.lua passed")
