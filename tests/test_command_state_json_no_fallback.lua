--- Test: command_state JSON encode errors propagate instead of falling back to "[]"
-- Regression: pcall swallowed encode errors, replacing selection data with empty array
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

-- Mock timeline_state
package.loaded["ui.timeline.timeline_state"] = {
    get_selected_clips = function()
        return { { id = "clip1" }, { id = "clip2" } }
    end,
    get_selected_edges = function() return {} end,
    get_selected_gaps = function() return {} end,
}

-- Mock logger
package.loaded["core.logger"] = {
    info = function() end, debug = function() end,
    warn = function() end, error = function() end,
    trace = function() end,
}

-- First test with working JSON encoder — should succeed
local command_state = require("core.command_state")
local clips_json, edges_json, gaps_json = command_state.capture_selection_snapshot()
check("valid clips JSON not empty", clips_json ~= "[]")
check("clips JSON contains clip1", clips_json:find("clip1") ~= nil)

-- Now break the JSON encoder to verify error propagation
-- command_state uses dkjson (json.encode), not qt_json_encode
local json = require("dkjson")
local original_encode = json.encode
json.encode = function(val)
    error("JSON encode explosion")
end

local ok, err = pcall(function()
    command_state.capture_selection_snapshot()
end)
check("broken encoder propagates error", not ok)
check("error mentions JSON", err and tostring(err):find("JSON") ~= nil)

-- Restore
json.encode = original_encode

if failed > 0 then
    print(string.format("❌ test_command_state_json_no_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_command_state_json_no_fallback.lua passed (%d assertions)", passed))
