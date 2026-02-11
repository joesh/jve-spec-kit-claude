--- Test: ripple_edit asserts sequence fps instead of falling back to 30fps
-- Regression: hardcoded seq_fps_num=30, seq_fps_den=1 used when DB query fails
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end


-- Build minimal stubs for ripple_edit registration
local clip_store = {}

package.loaded["core.command_helper"] = {
    add_delete_mutation = function() end,
    add_update_mutation = function() end,
    add_insert_mutation = function() end,
    clip_update_payload = function() return nil end,
    capture_clip_state = function() return {} end,
}

package.loaded["models.clip"] = {
    load = function(id) return clip_store[id] end,
    generate_id = function() return "new_clip_id" end,
}

-- Mock database that has no sequence row (simulates query failure)
local mock_query_no_rows = {
    bind_value = function() end,
    exec = function() return true end,
    next = function() return false end,  -- no rows!
    value = function() return nil end,
    finalize = function() end,
}

local mock_db = {
    prepare = function(_, sql)
        return mock_query_no_rows
    end,
}

-- Mock database module for load_clips
package.loaded["core.database"] = {
    get_connection = function() return mock_db end,
    init = function() return true end,
    load_clips = function() return {} end,
}

-- Mock command_helper.resolve_sequence_for_track
package.loaded["core.command_helper"] = {
    resolve_sequence_for_track = function() return "seq1" end,
    add_delete_mutation = function() end,
    add_update_mutation = function() end,
    add_insert_mutation = function() end,
    clip_update_payload = function() return nil end,
    capture_clip_state = function() return {} end,
}

local executors = {}
local undoers = {}
local ripple_edit = require("core.commands.ripple_edit")
ripple_edit.register(executors, undoers, mock_db, function() end)

local Command = require("command")
local cmd = Command.create("RippleEdit", "proj1")
cmd:set_parameters({
    project_id = "proj1",
    sequence_id = "seq1",
    delta_frames = 5,
    edge_info = {
        clip_id = "clip1",
        track_id = "track1",
        edge_type = "out",
    },
})

-- The executor should assert when it can't find the sequence fps
local ok, err = pcall(function()
    executors["RippleEdit"](cmd)
end)

check("ripple_edit asserts on missing sequence fps", not ok)
check("error mentions fps or sequence",
    err and (tostring(err):find("fps") ~= nil or tostring(err):find("sequence") ~= nil))

if failed > 0 then
    print(string.format("❌ test_ripple_edit_no_fps_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_ripple_edit_no_fps_fallback.lua passed (%d assertions)", passed))
