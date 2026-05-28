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
---
--- Returns the currently loaded timeline_state if any (the one the test
--- already initialised), otherwise loads it fresh. Critically, this MUST
--- NOT fresh-load when a real module is already in package.loaded —
--- timeline_state's module-init creates a fresh TimelineTabStrip and
--- calls strip_holder.set(tab_strip), which would clobber the strip the
--- test bootstrapped via command_manager.init / timeline_state.init.
--- (Pre-H1 the strip clobber was harmless because the singleton mirror
--- still held the per-sequence values; post-H1 the cache lives on the
--- displaced tab, so a fresh strip means nil reads everywhere.)
local function get_real_timeline_state()
    local existing = package.loaded["ui.timeline.timeline_state"]
    if existing then return existing end
    local ok, real = pcall(require, "ui.timeline.timeline_state")
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
