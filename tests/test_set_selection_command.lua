-- Tests for SetSelection command — persists timeline selection to DB

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

print("\n=== SetSelection Command Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_set_selection_cmd.db"
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
    { kind = "sequence",id = "seq1", audio_sample_rate = 48000})
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

-- 1. Set clip selection
local r = execute_cmd("SetSelection", {
    sequence_id = "seq1",
    selected_clip_ids_json = '["clip_a","clip_b"]',
    selected_edge_infos_json = '[]',
})
check("SetSelection succeeds", r.success)

local s = reload_seq()
check("clip ids persisted", s.selected_clip_ids_json == '["clip_a","clip_b"]')
check("edge infos persisted", s.selected_edge_infos_json == '[]')

-- 2. Overwrite selection
r = execute_cmd("SetSelection", {
    sequence_id = "seq1",
    selected_clip_ids_json = '["clip_c"]',
    selected_edge_infos_json = '[{"clip_id":"clip_c","edge":"head"}]',
})
check("overwrite succeeds", r.success)
s = reload_seq()
check("overwritten clip ids", s.selected_clip_ids_json == '["clip_c"]')
check("overwritten edge infos", s.selected_edge_infos_json == '[{"clip_id":"clip_c","edge":"head"}]')

-- 3. Clear selection (empty arrays)
r = execute_cmd("SetSelection", {
    sequence_id = "seq1",
    selected_clip_ids_json = '[]',
    selected_edge_infos_json = '[]',
})
check("clear succeeds", r.success)
s = reload_seq()
check("cleared clip ids", s.selected_clip_ids_json == '[]')

-- 4. Non-existent sequence fails
r = execute_cmd("SetSelection", {
    sequence_id = "nonexistent",
    selected_clip_ids_json = '[]',
    selected_edge_infos_json = '[]',
})
check("nonexistent seq fails", not r.success)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_set_selection_command.lua passed")
