#!/usr/bin/env luajit
-- Regression Test: Insert Split & Ripple
-- Verifies Insert command splits overlapping clips and ripples downstream clips.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Testing Insert Split & Ripple ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_insert_split.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Insert Project/Sequence (24fps)
local now = os.time()
db:exec(string.format([[ 
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test', %d, %d);
]], now, now))
db:exec(string.format([[ 
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[ 
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/media_1.mov",
    name = "Media 1",
    duration_frames = 1000,
    fps_numerator = 24,
    fps_denominator = 1
})
media:save(db)

-- Create Clip A (0-100 frames)
local clip_a = Clip.create("Clip A", "media_1", {
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = Rational.new(0, 24, 1),
    duration = Rational.new(100, 24, 1),
    source_in = Rational.new(0, 24, 1),
    source_out = Rational.new(100, 24, 1),
    enabled = true,
    fps_numerator = 24,
    fps_denominator = 1
})
assert(clip_a:save(db), "Failed to save Clip A")

-- Create Clip C (200-300 frames) - Downstream clip to test ripple
local clip_c = Clip.create("Clip C", "media_1", {
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = Rational.new(200, 24, 1),
    duration = Rational.new(100, 24, 1),
    source_in = Rational.new(200, 24, 1),
    source_out = Rational.new(300, 24, 1),
    enabled = true,
    fps_numerator = 24,
    fps_denominator = 1
})
assert(clip_c:save(db), "Failed to save Clip C")

print("Created Clip A (0-100) and Clip C (200-300)")

-- Execute Insert at 50 (Duration 20)
-- Should split A into A_Left (0-50) and A_Right (70-120).
-- Should shift C to 220-320.
-- Insert B at 50-70.

local cmd = Command.create("Insert", "project")
cmd:set_parameter("media_id", "media_1")
cmd:set_parameter("track_id", "track_v1")
cmd:set_parameter("sequence_id", "sequence")
cmd:set_parameter("insert_time", Rational.new(50, 24, 1))
cmd:set_parameter("duration", Rational.new(20, 24, 1))
cmd:set_parameter("source_in", Rational.new(0, 24, 1))
cmd:set_parameter("source_out", Rational.new(20, 24, 1))
cmd:set_parameter("clip_name", "Clip B")

-- Register Insert Command
local registry = require('core.command_registry')
local insert_cmd = require('core.commands.insert')
-- Pass dummy tables, then register with manager
local ret = insert_cmd.register({}, {}, db, command_manager.set_last_error)
command_manager.register_executor("Insert", ret.executor, ret.undoer)
command_manager.register_executor("UndoInsert", ret.executor, ret.undoer)

print("Executing Insert (At 50, Dur 20)...")
local result = command_manager.execute(cmd)

if not result.success then
    print("❌ Insert failed: " .. tostring(result.error_message))
    os.exit(1)
end

print("✅ Insert succeeded")
-- print("Result Data: " .. tostring(result.result_data))

-- Parse result to get output parameters (reference to cmd might not update if copied)
local executed_cmd = _G.qt_json_decode(result.result_data)
-- local b_id = executed_cmd.parameters and executed_cmd.parameters.clip_id
local stmt = db:prepare("SELECT id FROM clips WHERE timeline_start_frame = 50 AND track_id = 'track_v1' AND duration_frames = 20")
stmt:exec()
stmt:next()
local b_id = stmt:value(0)
stmt:finalize()

local executed_mutations = executed_cmd and executed_cmd.parameters and executed_cmd.parameters.executed_mutations

-- Verify DB State
local function get_clip(id)
    return Clip.load(id, db)
end

local a_after = get_clip(clip_a.id)
local c_after = get_clip(clip_c.id)
-- local b_id = cmd:get_parameter("clip_id") -- Use parsed ID
print("DEBUG: b_id from result is: " .. tostring(b_id))
local b_after = get_clip(b_id)

-- Find split part (A_Right)
-- New architecture stores all changes in `executed_mutations`
-- local executed_mutations = cmd:get_parameter("executed_mutations") -- Use parsed mutations
local a_right_id = nil

print("Searching for split clip... B_ID=" .. tostring(b_id))
if executed_mutations then
    print("Mutations count: " .. #executed_mutations)
    for i, mut in ipairs(executed_mutations) do
        -- print(string.format("Mut %d: type=%s id=%s", i, mut.type, tostring(mut.clip_id)))
        if mut.type == "insert" and mut.clip_id ~= b_id then
            a_right_id = mut.clip_id
            print("Found split clip ID: " .. tostring(a_right_id))
        end
    end
end

local a_right_after = nil
if a_right_id and a_right_id ~= "" then
    a_right_after = get_clip(a_right_id)
else
    print("❌ Failed to find split info for Clip A. Executed mutations: " .. #executed_mutations)
    os.exit(1)
end

print("\nVerifying state:")

-- Clip A (Left)
if a_after.duration.frames == 50 then
    print("✅ Clip A (Left) duration is 50 (Correct)")
else
    print(string.format("❌ Clip A (Left) duration mismatch: expected 50, got %d", a_after.duration.frames))
    os.exit(1)
end

-- Clip B (Inserted)
if b_after.timeline_start.frames == 50 then
    print("✅ Clip B start is 50 (Correct)")
else
    print(string.format("❌ Clip B start mismatch: expected 50, got %d", b_after.timeline_start.frames))
    os.exit(1)
end
if b_after.duration.frames == 20 then
    print("✅ Clip B duration is 20 (Correct)")
else
    print(string.format("❌ Clip B duration mismatch: expected 20, got %d", b_after.duration.frames))
    os.exit(1)
end

-- Clip A (Right)
-- Should start at 50 + 20 = 70.
if a_right_after.timeline_start.frames == 70 then
    print("✅ Clip A (Right) start is 70 (Correct)")
else
    print(string.format("❌ Clip A (Right) start mismatch: expected 70, got %d", a_right_after.timeline_start.frames))
    os.exit(1)
end
-- Duration should be 100 - 50 = 50.
if a_right_after.duration.frames == 50 then
    print("✅ Clip A (Right) duration is 50 (Correct)")
else
    print(string.format("❌ Clip A (Right) duration mismatch: expected 50, got %d", a_right_after.duration.frames))
    os.exit(1)
end

-- Clip C (Rippled)
-- Should start at 200 + 20 = 220.
if c_after.timeline_start.frames == 220 then
    print("✅ Clip C start is 220 (Correct)")
else
    print(string.format("❌ Clip C start mismatch: expected 220, got %d", c_after.timeline_start.frames))
    os.exit(1)
end

print("\nAll checks passed.")
os.exit(0)
