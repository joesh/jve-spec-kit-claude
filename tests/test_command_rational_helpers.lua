--- Test: command_rational_helpers.lua - all three functions
-- Coverage: require_sequence_rate, require_media_rate, require_master_clip_rate
-- Tests both happy paths and error paths (nil params, missing metadata)
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local helpers = require("core.command_rational_helpers")
local database = require("core.database")

-- Setup: create test database
local db_path = "/tmp/jve/test_cmd_rational_helpers.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
os.execute("mkdir -p /tmp/jve")

database.init(db_path)
local db = database.get_connection()

-- Insert test data
local project_id = "test_project_1"
local seq_id = "test_seq_1"
local media_id = "test_media_1"
local now = os.time()

local ok, err = db:exec(string.format(
    [[INSERT INTO projects (id, name, created_at, modified_at) VALUES (%q, 'Test', %d, %d)]],
    project_id, now, now
))
assert(ok, "Failed to insert project: " .. tostring(err))

ok, err = db:exec(string.format(
    [[INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
      VALUES (%q, %q, 'Test Seq', 24000, 1001, 48000, 1920, 1080, %d, %d)]],
    seq_id, project_id, now, now
))
assert(ok, "Failed to insert sequence: " .. tostring(err))

ok, err = db:exec(string.format(
    [[INSERT INTO media (id, project_id, name, file_path, fps_numerator, fps_denominator, duration_frames, width, height, created_at, modified_at)
      VALUES (%q, %q, 'test_video', '/test/video.mp4', 30000, 1001, 1000, 1920, 1080, %d, %d)]],
    media_id, project_id, now, now
))
assert(ok, "Failed to insert media: " .. tostring(err))

-- ============================================================================
-- require_sequence_rate tests
-- ============================================================================

print("Test: require_sequence_rate with valid params")
local fps_num, fps_den = helpers.require_sequence_rate(db, seq_id)
check("sequence fps_num is 24000", fps_num == 24000)
check("sequence fps_den is 1001", fps_den == 1001)
print("  ✓ require_sequence_rate returns correct fps")

print("Test: require_sequence_rate with nil db asserts")
ok, err = pcall(function()
    helpers.require_sequence_rate(nil, seq_id)
end)
check("nil db asserts", not ok)
check("error mentions db", err and tostring(err):find("db") ~= nil)
print("  ✓ require_sequence_rate validates db")

print("Test: require_sequence_rate with nil sequence_id asserts")
ok, err = pcall(function()
    helpers.require_sequence_rate(db, nil)
end)
check("nil sequence_id asserts", not ok)
check("error mentions sequence_id", err and tostring(err):find("sequence_id") ~= nil)
print("  ✓ require_sequence_rate validates sequence_id")

print("Test: require_sequence_rate with empty sequence_id asserts")
ok, err = pcall(function()
    helpers.require_sequence_rate(db, "")
end)
check("empty sequence_id asserts", not ok)
check("error mentions sequence_id (empty)", err and tostring(err):find("sequence_id") ~= nil)
print("  ✓ require_sequence_rate rejects empty sequence_id")

print("Test: require_sequence_rate with nonexistent sequence asserts")
ok, err = pcall(function()
    helpers.require_sequence_rate(db, "nonexistent_seq")
end)
check("nonexistent sequence asserts", not ok)
check("error mentions missing fps metadata", err and tostring(err):find("missing fps") ~= nil)
print("  ✓ require_sequence_rate asserts on missing fps")

-- ============================================================================
-- require_media_rate tests
-- ============================================================================

print("Test: require_media_rate with valid params")
fps_num, fps_den = helpers.require_media_rate(db, media_id)
check("media fps_num is 30000", fps_num == 30000)
check("media fps_den is 1001", fps_den == 1001)
print("  ✓ require_media_rate returns correct fps")

print("Test: require_media_rate with nil db asserts")
ok, err = pcall(function()
    helpers.require_media_rate(nil, media_id)
end)
check("nil db asserts (media)", not ok)
check("error mentions db (media)", err and tostring(err):find("db") ~= nil)
print("  ✓ require_media_rate validates db")

print("Test: require_media_rate with nil media_id asserts")
ok, err = pcall(function()
    helpers.require_media_rate(db, nil)
end)
check("nil media_id asserts", not ok)
check("error mentions media_id", err and tostring(err):find("media_id") ~= nil)
print("  ✓ require_media_rate validates media_id")

print("Test: require_media_rate with empty media_id asserts")
ok, err = pcall(function()
    helpers.require_media_rate(db, "")
end)
check("empty media_id asserts", not ok)
check("error mentions media_id (empty)", err and tostring(err):find("media_id") ~= nil)
print("  ✓ require_media_rate rejects empty media_id")

print("Test: require_media_rate with nonexistent media asserts")
ok, err = pcall(function()
    helpers.require_media_rate(db, "nonexistent_media")
end)
check("nonexistent media asserts", not ok)
check("error mentions missing fps metadata (media)", err and tostring(err):find("missing fps") ~= nil)
print("  ✓ require_media_rate asserts on missing fps")

-- ============================================================================
-- require_master_clip_rate tests
-- ============================================================================

print("Test: require_master_clip_rate with valid master clip")
local master_clip = {
    id = "mc_1",
    rate = { fps_numerator = 25, fps_denominator = 1 }
}
fps_num, fps_den = helpers.require_master_clip_rate(master_clip)
check("master_clip fps_num is 25", fps_num == 25)
check("master_clip fps_den is 1", fps_den == 1)
print("  ✓ require_master_clip_rate returns correct fps")

print("Test: require_master_clip_rate with nil master_clip asserts")
ok, err = pcall(function()
    helpers.require_master_clip_rate(nil)
end)
check("nil master_clip asserts", not ok)
check("error mentions master clip", err and tostring(err):find("master clip") ~= nil)
print("  ✓ require_master_clip_rate validates master_clip")

print("Test: require_master_clip_rate with missing rate field asserts")
ok, err = pcall(function()
    helpers.require_master_clip_rate({ id = "mc_2" })
end)
check("missing rate field asserts", not ok)
check("error mentions rate field", err and tostring(err):find("rate") ~= nil)
print("  ✓ require_master_clip_rate validates rate field")

print("Test: require_master_clip_rate with nil rate asserts")
ok, err = pcall(function()
    helpers.require_master_clip_rate({ id = "mc_3", rate = nil })
end)
check("nil rate asserts", not ok)
check("error mentions rate (nil)", err and tostring(err):find("rate") ~= nil)
print("  ✓ require_master_clip_rate rejects nil rate")

print("Test: require_master_clip_rate with missing fps_numerator asserts")
ok, err = pcall(function()
    helpers.require_master_clip_rate({ rate = { fps_denominator = 1 } })
end)
check("missing fps_numerator asserts", not ok)
check("error mentions fps metadata", err and tostring(err):find("fps") ~= nil)
print("  ✓ require_master_clip_rate validates fps_numerator")

print("Test: require_master_clip_rate with missing fps_denominator asserts")
ok, err = pcall(function()
    helpers.require_master_clip_rate({ rate = { fps_numerator = 24 } })
end)
check("missing fps_denominator asserts", not ok)
check("error mentions fps (denom)", err and tostring(err):find("fps") ~= nil)
print("  ✓ require_master_clip_rate validates fps_denominator")

-- Cleanup (connection closes on GC; just remove test DB)
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")

if failed > 0 then
    print(string.format("❌ test_command_rational_helpers.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_command_rational_helpers.lua passed (%d assertions)", passed))
