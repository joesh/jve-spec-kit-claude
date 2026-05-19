#!/usr/bin/env luajit
--- SetTimelineDecodeMode — rebindable command that sets the decoder's
--- mode (scrub / park / play). Currently invoked from the ruler drag
--- start/end transitions; routing through command_manager makes the
--- side-effect explicit and lets a future gesture editor rebind which
--- pointer event drives the transition.

require("test_env")

print("=== test_set_timeline_decode_mode_command.lua ===")

local set_mode_log = {}
package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function(mode)
            table.insert(set_mode_log, mode)
        end,
    },
}

local command_manager = require("core.command_manager")

for _, mode in ipairs({ "scrub", "park", "play" }) do
    set_mode_log = {}
    assert(command_manager.execute("SetTimelineDecodeMode", { mode = mode }),
        string.format("SetTimelineDecodeMode(%s) must succeed", mode))
    assert(#set_mode_log == 1 and set_mode_log[1] == mode, string.format(
        "SetTimelineDecodeMode(%s) must call EMP.SET_DECODE_MODE with %q; "
        .. "got %d calls, last = %s",
        mode, mode, #set_mode_log, tostring(set_mode_log[#set_mode_log])))
    print(string.format("  ✓ %s mode dispatched to EMP", mode))
end

-- Unknown mode is rejected (no silent fallback to a default).
-- command_manager wraps executor errors; observe the side-effect
-- absence — EMP must NOT be called with a bogus mode.
set_mode_log = {}
pcall(command_manager.execute, "SetTimelineDecodeMode", { mode = "bogus" })
assert(#set_mode_log == 0, "unknown mode must NOT reach EMP (no silent fallback)")
print("  ✓ unknown mode rejected")

print("\n✅ test_set_timeline_decode_mode_command.lua passed")
