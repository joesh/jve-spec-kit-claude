--- Test: ensure_project_context asserts when project_id cannot be derived
-- Regression: silently left self.project_id = nil after failed DB lookups
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end


-- Mock database that returns no results for project lookups
local empty_query = {
    bind_value = function() end,
    exec = function() return true end,
    next = function() return false end,  -- no rows
    value = function() return nil end,
    finalize = function() end,
}

local mock_db = {
    prepare = function(_, sql)
        -- For the EXISTS check in save, return 0
        if sql:find("SELECT COUNT") then
            return {
                bind_value = function() end,
                exec = function() return true end,
                next = function() return true end,
                value = function() return 0 end,
                finalize = function() end,
            }
        end
        return empty_query
    end,
}

-- Mock database module
package.loaded["core.database"] = {
    get_connection = function() return mock_db end,
    init = function() return true end,
}

-- Mock krono
package.loaded["core.krono"] = nil

local Clip = require("models.clip")

-- Create a clip with NO project_id and NO track_id — project_id cannot be derived
local clip = Clip.create("orphan_clip", "media1", {
    id = "clip_orphan",
    clip_kind = "master",
    track_id = nil,
    project_id = nil,
    timeline_start = 0,
    duration = 100,
    source_in = 0,
    source_out = 100,
    fps_numerator = 24,
    fps_denominator = 1,
})

-- save should assert because project_id cannot be derived
local ok, err = pcall(function()
    clip:save()
end)

check("save asserts on nil project_id", not ok)
check("error mentions ensure_project_context or project_id",
    err and (tostring(err):find("project_id") ~= nil or tostring(err):find("ensure_project_context") ~= nil))

if failed > 0 then
    print(string.format("❌ test_clip_ensure_project_context_asserts.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_clip_ensure_project_context_asserts.lua passed (%d assertions)", passed))
