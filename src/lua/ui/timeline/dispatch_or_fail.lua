--- dispatch_or_fail: thin wrapper around command_manager.execute_interactive
--- that surfaces a loud failure when the dispatch reports success=false (or
--- returns nil). The wire_* track-header helpers used to fire-and-forget,
--- so a failed command left the button visually frozen with no user-visible
--- signal that the click was rejected (NSF half-2 violation: pipeline
--- output not checked).
---
--- Usage:
---     dispatch_or_fail.execute_or_fail("ToggleTrackPreference",
---         { track_id = id, property = "muted", project_id = pid },
---         "mute btn click")
---
--- Errors carry: command name, caller-supplied context tag, and the
--- underlying error_message from the failed result.
---
--- @file dispatch_or_fail.lua
local M = {}

function M.execute_or_fail(command_name, params, context_tag)
    assert(type(command_name) == "string" and command_name ~= "",
        "execute_or_fail: command_name required")
    assert(type(context_tag) == "string" and context_tag ~= "",
        "execute_or_fail: context_tag required (helps the user identify "
        .. "which callsite failed)")
    local r = require("core.command_manager").execute_interactive(command_name, params)
    if r == true then return r end
    if type(r) == "table" and r.success == true then return r end
    error(string.format(
        "execute_or_fail: command %s failed at %s — %s",
        command_name, context_tag,
        type(r) == "table" and tostring(r.error_message) or "no result returned"))
end

return M
