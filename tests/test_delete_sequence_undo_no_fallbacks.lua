--- Test: delete_sequence fetch/restore preserves exact values, no invented defaults
-- Regression: fetch_sequence_record used "or 0", "or 48000", "or 1920" etc.
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local database = require("core.database")
local db_path = "/tmp/jve/test_delete_sequence_undo_no_fallbacks.db"
os.remove(db_path)
os.remove(db_path .. "-shm")
os.remove(db_path .. "-wal")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Insert project
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

-- Insert sequence with NON-DEFAULT values (not 1920x1080, not 48000, not 24fps)
-- These unusual values would be lost if fallbacks were used
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        created_at, modified_at
    ) VALUES (
        'seq_custom', 'proj1', 'Custom Seq', 'timeline',
        25, 1, 44100,
        3840, 2160,
        50, 500, 120,
        '[]', '[]', '[]',
        %d, %d
    );
]], now, now))

-- Stub timeline_state
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function()
    return { start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 1000 }
end
timeline_state.restore_viewport = function() end
timeline_state.get_sequence_audio_sample_rate = function() return 44100 end

-- Load the delete_sequence command and test fetch_sequence_record
local delete_sequence = require("core.commands.delete_sequence")

-- Register with executors/undoers tables
local executors = {}
local undoers = {}
delete_sequence.register(executors, undoers, db, function() end)

-- Verify the sequence was fetched with exact values (not fallbacks)
-- We'll test by doing a full delete → undo → verify cycle
local Command = require("command")

-- Execute delete
local cmd = Command.create("DeleteSequence", "proj1")
cmd:set_parameters({
    project_id = "proj1",
    sequence_id = "seq_custom",
})

local exec_result = executors["DeleteSequence"](cmd)
check("delete executes", exec_result == true)

-- Verify sequence is deleted
local verify_stmt = db:prepare("SELECT COUNT(*) FROM sequences WHERE id = ?")
verify_stmt:bind_value(1, "seq_custom")
verify_stmt:exec()
verify_stmt:next()
check("sequence deleted from DB", verify_stmt:value(0) == 0)
verify_stmt:finalize()

-- Undo the delete
local undo_result = undoers["DeleteSequence"](cmd)
check("undo executes", undo_result == true)

-- Verify sequence restored with EXACT original values
local check_stmt = db:prepare([[
    SELECT fps_numerator, fps_denominator, audio_rate, width, height,
           view_start_frame, view_duration_frames, playhead_frame
    FROM sequences WHERE id = ?
]])
check_stmt:bind_value(1, "seq_custom")
assert(check_stmt:exec() and check_stmt:next(), "restored sequence not found")

check("fps_numerator = 25 (not 0 or 30)", tonumber(check_stmt:value(0)) == 25)
check("fps_denominator = 1", tonumber(check_stmt:value(1)) == 1)
check("audio_rate = 44100 (not 48000)", tonumber(check_stmt:value(2)) == 44100)
check("width = 3840 (not 1920)", tonumber(check_stmt:value(3)) == 3840)
check("height = 2160 (not 1080)", tonumber(check_stmt:value(4)) == 2160)
check("view_start_frame = 50", tonumber(check_stmt:value(5)) == 50)
check("view_duration_frames = 500 (not 240)", tonumber(check_stmt:value(6)) == 500)
check("playhead_frame = 120", tonumber(check_stmt:value(7)) == 120)
check_stmt:finalize()

-- Test 2: fetch_sequence_record should NOT silently invent values
-- Insert a broken sequence row with NULL in NOT NULL columns via raw SQL bypass
-- (In real use this can't happen due to schema constraints, but the code must not
-- silently invent values if it somehow does)
-- We test by verifying the fetch path captures actual DB values, not fallbacks.
-- The key assertion: fps_numerator=25 was stored, not the fallback 0 from "or 0"
-- Already verified above. The code fix removes the fallback patterns.

-- Test 3: restore_sequence_from_payload asserts on nil required fields
-- Simulate a corrupted payload missing width
local cmd2 = Command.create("DeleteSequence", "proj1")
cmd2:set_parameters({
    project_id = "proj1",
    sequence_id = "seq_corrupt",
    delete_sequence_snapshot = {
        sequence = {
            id = "seq_corrupt",
            project_id = "proj1",
            name = "Corrupt",
            kind = "timeline",
            fps_numerator = 24,
            fps_denominator = 1,
            audio_sample_rate = 48000,
            audio_rate = 48000,
            width = nil,   -- missing!
            height = 1080,
            view_start_frame = 0,
            view_duration_frames = 240,
            playhead_value = 0,
            selected_clip_ids = "[]",
            selected_edge_infos = "[]",
            selected_gap_infos = "[]",
            created_at = now,
            modified_at = now,
        },
        tracks = {},
        clips = {},
    },
})

local ok3, err3 = pcall(function()
    undoers["DeleteSequence"](cmd2)
end)

check("undo with nil width asserts", not ok3)
check("error mentions width", err3 and tostring(err3):find("width") ~= nil)

if failed > 0 then
    print(string.format("❌ test_delete_sequence_undo_no_fallbacks.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_delete_sequence_undo_no_fallbacks.lua passed (%d assertions)", passed))
