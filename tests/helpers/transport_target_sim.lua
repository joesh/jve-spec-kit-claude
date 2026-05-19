--- Test helper: simulate the UI state that drives transport.get_target().
---
--- The new contract is that the target is DERIVED from focus_manager +
--- timeline_state, so a test needs to put those modules into the state
--- that matches the role it wants to test. This helper installs stubs
--- for both surfaces.
---
--- IMPORTANT: install the stubs BEFORE requiring any module that captures
--- a reference to focus_manager or timeline_state. The transport module
--- requires lazily inside get_target() so the order is forgiving there,
--- but tests should call sim.target_*() at setup time.
---
--- Usage:
---     local sim = require("helpers.transport_target_sim")
---     sim.target_source()   -- transport.get_target() returns "source"
---     sim.target_record()   -- transport.get_target() returns "record"

local M = {}

--- Real timeline_state (loaded once if installed). When tests need both
--- the derived-target stub AND the real marks/playhead surface, this lets
--- the stub forward unknown keys to the real module.
local function get_real_timeline_state()
    -- Save the current package.loaded entry, clear it, force fresh load,
    -- then restore the stub if any.
    local prev = package.loaded["ui.timeline.timeline_state"]
    package.loaded["ui.timeline.timeline_state"] = nil
    local ok, real = pcall(require, "ui.timeline.timeline_state")
    package.loaded["ui.timeline.timeline_state"] = prev
    if ok then return real end
    return nil
end

local function stub(role)
    assert(role == "source" or role == "record", string.format(
        "transport_target_sim.stub: role must be 'source'|'record', got %s",
        tostring(role)))

    local panel_for_role = (role == "source") and "source_monitor" or "timeline"
    package.loaded["ui.focus_manager"] = {
        get_focused_panel = function() return panel_for_role end,
    }

    local real_ts = get_real_timeline_state()
    local stub_methods = {
        get_displayed_tab_kind = function() return role end,
    }
    package.loaded["ui.timeline.timeline_state"] = setmetatable(stub_methods, {
        __index = real_ts,
    })
end

function M.target_source() stub("source") end
function M.target_record() stub("record") end

return M
