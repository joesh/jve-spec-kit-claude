--- command_dispatch: helpers that wrap command_manager dispatch with
--- strict result inspection. Plain `command_manager.execute_interactive`
--- returns a result table that callers often discard, so a failed
--- command stays silent (NSF half-2 violation: pipeline output not
--- checked). The wrappers here re-raise on failure with the command
--- name, callsite tag, and the underlying error_message.
---
--- Usage:
---     command_dispatch.execute_or_fail("ToggleTrackPreference",
---         { track_id = id, property = "muted", project_id = pid },
---         "mute btn click")
---
--- @file command_dispatch.lua
local M = {}

-- command_manager.execute_interactive returns either `true`, `{success=true,
-- ...}`, `{success=false, error_message=...}`, or nil. Normalise to a
-- boolean + caller-friendly message.
local function result_ok(r)
    if r == true then return true end
    if type(r) == "table" and r.success == true then return true end
    return false
end

local function fail_message(r)
    if type(r) == "table" then return tostring(r.error_message) end
    return "no result returned"
end

--- Dispatch via command_manager.execute_interactive; raise on failure.
function M.execute_or_fail(command_name, params, context_tag)
    assert(type(command_name) == "string" and command_name ~= "",
        "command_dispatch.execute_or_fail: command_name required")
    assert(type(context_tag) == "string" and context_tag ~= "",
        "command_dispatch.execute_or_fail: context_tag required (helps the "
        .. "user identify which callsite failed)")
    local r = require("core.command_manager").execute_interactive(command_name, params)
    if result_ok(r) then return r end
    error(string.format("command_dispatch.execute_or_fail: command %s failed at %s — %s",
        command_name, context_tag, fail_message(r)))
end

return M
