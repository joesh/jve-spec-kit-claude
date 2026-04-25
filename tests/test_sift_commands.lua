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

local function set_size(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ============================================================================
-- Setup: DB + project for settings persistence
-- ============================================================================
local database = require("core.database")
local db_path = "/tmp/jve/test_sift_commands.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj1', 'Test', 'resample', %d, %d)",
    now, now))

-- ============================================================================
-- Test data
-- ============================================================================
local clips = {
    {id = "c1", name = "INT_Scene1",  codec = "ProRes", fps = 24, duration = 150, enabled = true,  properties = {scene = "1"}},
    {id = "c2", name = "EXT_Scene2",  codec = "ProRes", fps = 24, duration = 200, enabled = true,  properties = {scene = "2"}},
    {id = "c3", name = "INT_Scene3",  codec = "DNxHD",  fps = 25, duration = 150, enabled = false, properties = {scene = "3"}},
    {id = "c4", name = "Interview_A", codec = "DNxHD",  fps = 25, duration = 3000, enabled = true,  properties = {scene = "4"}},
    {id = "c5", name = "BRoll_01",    codec = "H264",   fps = 30, duration = 75,  enabled = true,  properties = {scene = "5"}},
    {id = "c6", name = "SFX_Rain",    codec = "WAV",    fps = 48000, duration = 96000, enabled = true, properties = {}},
}

-- ============================================================================
-- Test the sift_commands module directly (not through command_manager)
-- These commands are thin wrappers around sift_state with persistence
-- ============================================================================
local sift_commands = require("core.sift_commands")
local sift_state = require("core.sift_state")

-- ============================================================================
-- Sift (fresh)
-- ============================================================================
print("--- sift fresh ---")
sift_state.clear()
sift_commands.sift(clips, {column = "codec", operator = "contains", value = "ProRes"}, "proj1")

check("sift: is_active", sift_state.is_active())
local result = sift_state.evaluate(clips)
local vis = {}
for _, id in ipairs(result.visible_ids) do vis[id] = true end
-- ProRes: c1, c2
check("sift: c1 visible", vis["c1"] == true)
check("sift: c2 visible", vis["c2"] == true)
check("sift: c3 hidden (DNxHD)", not vis["c3"])
check("sift: visible count = 2", set_size(vis) == 2)

-- ============================================================================
-- Expand Sift (OR)
-- ============================================================================
print("--- expand sift ---")
sift_commands.expand_sift(clips, {column = "codec", operator = "contains", value = "DNxHD"}, "proj1")

result = sift_state.evaluate(clips)
vis = {}
for _, id in ipairs(result.visible_ids) do vis[id] = true end
-- ProRes(2) + DNxHD(2) = 4
check("expand: c3 now visible", vis["c3"] == true)
check("expand: c4 now visible", vis["c4"] == true)
check("expand: c5 still hidden", not vis["c5"])
check("expand: visible count = 4", set_size(vis) == 4)

-- ============================================================================
-- Narrow Sift (AND)
-- ============================================================================
print("--- narrow sift ---")
sift_commands.narrow_sift(clips, {column = "fps", operator = "equals", value = "24"}, "proj1")

result = sift_state.evaluate(clips)
vis = {}
for _, id in ipairs(result.visible_ids) do vis[id] = true end
-- ProRes+DNxHD at 24fps: c1, c2 only
check("narrow: c1 visible (ProRes 24)", vis["c1"] == true)
check("narrow: c2 visible (ProRes 24)", vis["c2"] == true)
check("narrow: c3 hidden (DNxHD 25)", not vis["c3"])
check("narrow: c4 hidden (DNxHD 25)", not vis["c4"])
check("narrow: visible count = 2", set_size(vis) == 2)

-- ============================================================================
-- Clear Sift
-- ============================================================================
print("--- clear sift ---")
sift_commands.clear_sift("proj1")
check("clear: not active", not sift_state.is_active())

-- ============================================================================
-- Persistence: sift criteria saved to project settings
-- ============================================================================
print("--- persistence ---")
sift_commands.sift(clips, {column = "codec", operator = "contains", value = "ProRes"}, "proj1")
sift_commands.expand_sift(clips, {column = "codec", operator = "contains", value = "DNxHD"}, "proj1")

-- Read back from project settings
local settings_stmt = db:prepare("SELECT settings FROM projects WHERE id = ?")
settings_stmt:bind_value(1, "proj1")
assert(settings_stmt:exec() and settings_stmt:next(), "no project row")
local settings_json = settings_stmt:value(0)
settings_stmt:finalize()

local dkjson = require("dkjson")
local settings = dkjson.decode(settings_json)
check("settings has sift_state", settings.sift_state ~= nil)
check("settings sift_state is string", type(settings.sift_state) == "string")

-- Clear and restore from settings
sift_state.clear()
check("cleared", not sift_state.is_active())

sift_commands.restore_sift(clips, "proj1")
check("restored: is_active", sift_state.is_active())
result = sift_state.evaluate(clips)
vis = {}
for _, id in ipairs(result.visible_ids) do vis[id] = true end
check("restored: ProRes+DNxHD visible", set_size(vis) == 4)

-- Clear after restore
sift_commands.clear_sift("proj1")

-- Verify settings cleared
settings_stmt = db:prepare("SELECT settings FROM projects WHERE id = ?")
settings_stmt:bind_value(1, "proj1")
assert(settings_stmt:exec() and settings_stmt:next())
settings_json = settings_stmt:value(0)
settings_stmt:finalize()
settings = dkjson.decode(settings_json)
check("settings sift_state cleared", settings.sift_state == nil)

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_sift_commands.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_sift_commands.lua passed (%d assertions)", pass_count))
