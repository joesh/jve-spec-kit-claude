-- Tests for SetViewport command — persists viewport bounds to DB

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local command_manager = require("core.command_manager")

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

print("\n=== SetViewport Command Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_set_viewport_cmd.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

local seq = Sequence.create("Timeline", "proj1",
    { fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    { kind = "nested",id = "seq1", audio_sample_rate = 48000})
assert(seq:save(), "setup: save sequence")

command_manager.init("seq1", "proj1")

local function execute_cmd(name, params)
    params = params or {}
    params.project_id = params.project_id or "proj1"
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

local function reload_seq()
    return Sequence.load("seq1")
end

-- 1. Set viewport bounds
local r = execute_cmd("SetViewport", {
    sequence_id = "seq1",
    viewport_start_time = 100,
    viewport_duration = 500,
})
check("SetViewport succeeds", r.success)

local s = reload_seq()
check("viewport_start_time=100", s.viewport_start_time == 100)
check("viewport_duration=500", s.viewport_duration == 500)

-- 2. Update with scroll offsets
r = execute_cmd("SetViewport", {
    sequence_id = "seq1",
    viewport_start_time = 200,
    viewport_duration = 1000,
    video_scroll_offset = 42,
    audio_scroll_offset = 17,
})
check("update succeeds", r.success)
s = reload_seq()
check("viewport_start_time=200", s.viewport_start_time == 200)
check("viewport_duration=1000", s.viewport_duration == 1000)
check("video_scroll_offset=42", s.video_scroll_offset == 42)
check("audio_scroll_offset=17", s.audio_scroll_offset == 17)

-- 3. Split ratio
r = execute_cmd("SetViewport", {
    sequence_id = "seq1",
    viewport_start_time = 0,
    viewport_duration = 240,
    video_audio_split_ratio = 0.65,
})
check("split ratio succeeds", r.success)
s = reload_seq()
check("viewport_start_time=0", s.viewport_start_time == 0)
-- video_audio_split_ratio may be stored as float
check("split_ratio near 0.65", s.video_audio_split_ratio and math.abs(s.video_audio_split_ratio - 0.65) < 0.001)

-- 4. Non-existent sequence fails
r = execute_cmd("SetViewport", {
    sequence_id = "nonexistent",
    viewport_start_time = 0,
    viewport_duration = 240,
})
check("nonexistent seq fails", not r.success)

-- 5. Large viewport values (100 hours at 24fps = 8,640,000 frames)
r = execute_cmd("SetViewport", {
    sequence_id = "seq1",
    viewport_start_time = 8640000,
    viewport_duration = 2160000,
})
check("large values succeed", r.success)
s = reload_seq()
check("large viewport_start=8640000", s.viewport_start_time == 8640000)
check("large viewport_duration=2160000", s.viewport_duration == 2160000)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_set_viewport_command.lua passed")
