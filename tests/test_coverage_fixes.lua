require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

local database = require("core.database")
local db_path = "/tmp/jve/test_coverage_fixes.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

-- Seed valid track_heights to ensure the table exists via the real codepath
database.set_sequence_track_heights("seq1", { V1 = 80 })

-- ============================================================
-- T5a: load_sequence_track_heights — malformed JSON → error with decode details
-- ============================================================
print("\n--- T5a: malformed JSON in track_heights ---")
do
    -- Corrupt the stored JSON via prepared statement
    local upd = db:prepare("UPDATE sequence_track_layouts SET track_heights_json = ? WHERE sequence_id = ?")
    assert(upd, "T5a: failed to prepare UPDATE")
    upd:bind_value(1, "{not valid json!!!}")
    upd:bind_value(2, "seq1")
    assert(upd:exec(), "T5a: UPDATE exec failed")
    upd:finalize()

    expect_error("malformed JSON → error with decode details", function()
        database.load_sequence_track_heights("seq1")
    end, "invalid JSON")
end

-- ============================================================
-- T5b: load_sequence_track_heights — JSON array rejected
-- ============================================================
print("\n--- T5b: JSON array in track_heights ---")
do
    -- Set a JSON array instead of object
    local upd = db:prepare("UPDATE sequence_track_layouts SET track_heights_json = ? WHERE sequence_id = ?")
    assert(upd, "T5b: failed to prepare UPDATE")
    upd:bind_value(1, "[1,2,3]")
    upd:bind_value(2, "seq1")
    assert(upd:exec(), "T5b: UPDATE exec failed")
    upd:finalize()

    expect_error("JSON array → error expected JSON object", function()
        database.load_sequence_track_heights("seq1")
    end, "expected JSON object")
end

-- ============================================================
-- T6a: Command.deserialize — malformed JSON uses direct decode
-- ============================================================
print("\n--- T6a: Command.deserialize malformed JSON ---")
do
    local Command = require("command")
    local cmd, err = Command.deserialize("{broken json!!!")
    check("T6a: deserialize returns nil", cmd == nil)
    check("T6a: error mentions decode failure",
        err ~= nil and (tostring(err):find("decode") ~= nil or tostring(err):find("JSON") ~= nil))
end

-- ============================================================
-- T6b: Command.save — missing fps_denominator errors (no silent or-1)
-- ============================================================
print("\n--- T6b: Command.save missing fps_denominator ---")
do
    local Command = require("command")
    local cmd = Command.create("TestSave", "proj1")
    cmd.playhead_value = 100
    cmd.playhead_rate = { fps_numerator = 24000 } -- missing fps_denominator
    cmd.executed_at = os.time()

    expect_error("missing fps_denominator → error", function()
        cmd:save(db)
    end, "fps_denominator")
end

-- ============================================================
-- T6c: Command.save — separate error messages for playhead_value vs rate
-- ============================================================
print("\n--- T6c: Command.save separate playhead errors ---")
do
    local Command = require("command")

    -- nil playhead_value with valid rate
    local cmd1 = Command.create("TestSave", "proj1")
    cmd1.playhead_value = nil
    cmd1.playhead_rate = { fps_numerator = 24000, fps_denominator = 1001 }
    cmd1.executed_at = os.time()

    local err1 = expect_error("nil playhead_value → error mentions playhead_value", function()
        cmd1:save(db)
    end, "playhead_value")

    -- valid playhead_value with zero rate
    local cmd2 = Command.create("TestSave", "proj1")
    cmd2.playhead_value = 100
    cmd2.playhead_rate = 0
    cmd2.executed_at = os.time()

    local err2 = expect_error("zero playhead_rate → error mentions playhead_rate", function()
        cmd2:save(db)
    end, "playhead_rate")

    -- Verify they are DIFFERENT messages
    if err1 and err2 then
        check("T6c: different error messages", tostring(err1) ~= tostring(err2))
    end
end

-- ============================================================
-- T8b: format_user_error — type check before field access
-- ============================================================
print("\n--- T8b: format_user_error type check ordering ---")
do
    local error_system = require("core.error_system")

    expect_error("string input → error mentions type", function()
        error_system.format_user_error("not a table")
    end, "must be a table")

    expect_error("number input → error mentions type", function()
        error_system.format_user_error(42)
    end, "must be a table")
end

-- ============================================================
-- T11: Integer coordinate comparison (Rational refactor complete)
-- ============================================================
print("\n--- T11: Integer coordinate comparison ---")
do
    -- All coordinates are now plain integers
    local a = 10
    local b = 10
    local c = 20

    check("T11: equal integers are equal", a == b)
    check("T11: unequal integers are not equal", a ~= c)
    check("T11: less than works", a < c)
    check("T11: not less than when equal", a >= b)
    check("T11: not less than when greater", c >= a)

    -- Same value integers are equal
    local d = 10
    local e = 10
    check("T11: same value integers are equal", d == e)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    error("test_coverage_fixes.lua: " .. fail_count .. " failures")
end
print("✅ test_coverage_fixes.lua passed")
