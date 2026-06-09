--- Test: UnlinkClip undo re-inserts clip_links row with correct column name
-- Regression: link_clips.lua:185 had literal "args.original_role" as SQL column
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

-- Minimal DB mock that records prepared SQL and bound values
local prepared_sqls = {}
local last_binds = {}
local exec_result = true

local mock_query = {
    bind_value = function(_, idx, val)
        last_binds[idx] = val
    end,
    exec = function()
        return exec_result
    end,
    next = function()
        return true
    end,
    value = function(_, idx)
        if idx == 0 then return "existing_link_group_123" end
        return nil
    end,
    finalize = function() end,
}

local mock_db = {
    prepare = function(_, sql)
        table.insert(prepared_sqls, sql)
        last_binds = {}
        return mock_query
    end,
}

-- Stub uuid
package.loaded["uuid"] = { generate = function() return "new-uuid-456" end }

-- Stub clip_link model
package.loaded["models.clip_link"] = {
    get_link_group = function(clip_id, db)
        return {
            { clip_id = "clip_A", role = "video", time_offset = 0, enabled = true },
            { clip_id = "clip_B", role = "audio", time_offset = 5, enabled = true },
        }
    end,
    unlink_clip = function(clip_id, db)
        return true
    end,
    create_link_group = function(clips, db)
        return "grp1", nil
    end,
}

-- Load the command module
local link_clips = require("core.commands.link_clips")

local executors = {}
local undoers = {}
link_clips.register(executors, undoers, mock_db)

-- Build a command that simulates having executed UnlinkClip on clip_A
local Command = require("command")
local cmd = Command.create("UnlinkClip", "proj1")
cmd:set_parameters({
    clip_id = "clip_A",
    project_id = "proj1",
    link_group_id = "grp1",
    original_link_group = {
        { clip_id = "clip_A", role = "video", time_offset = 0, enabled = true },
        { clip_id = "clip_B", role = "audio", time_offset = 5, enabled = true },
    },
    original_role = "video",
    original_time_offset = 0,
})

-- Execute the undo — this is where the broken SQL column causes a prepare failure
prepared_sqls = {}
local result = undoers["UnlinkClip"](cmd)

check("undo returns true", result == true)

-- Verify the INSERT SQL uses "role" not "args.original_role"
local found_insert = false
for _, sql in ipairs(prepared_sqls) do
    if sql:find("INSERT INTO clip_links") then
        found_insert = true
        check("INSERT uses 'role' column", sql:find("%f[%w]role%f[%W]") ~= nil)
        check("INSERT does NOT use 'args.original_role'", sql:find("args%.original_role") == nil)
    end
end
check("found INSERT statement", found_insert)

-- Verify correct values were bound
check("bound link_group_id", last_binds[1] == "existing_link_group_123")
check("bound clip_id", last_binds[2] == "clip_A")
check("bound role value", last_binds[3] == "video")
check("bound time_offset", last_binds[4] == 0)

if failed > 0 then
    print(string.format("❌ test_unlink_clip_undo_relinks.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_unlink_clip_undo_relinks.lua passed (%d assertions)", passed))
