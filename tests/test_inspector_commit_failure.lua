#!/usr/bin/env luajit
-- Regression test: when inspectable:set fails (e.g. Clip.save raises
-- VIDEO_OVERLAP), the Inspector's commit_single_field path must:
--   1) revert the widget to the last-model value (so the user sees the
--      actual DB state, not their stale typed value),
--   2) surface the failure message via the on_error banner callback.
--
-- Reproducer: TSO 2026-04-20 18:08:25 — user edited clip.sequence_start in
-- single-edit mode; Clip.save rejected with VIDEO_OVERLAP; commit path
-- logged a warning but field kept the stale value and no banner showed.
--
-- This test is written BEFORE the fix exists — it should fail first, then
-- pass once commit_single_field handles the failure path correctly.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Stub command_manager BEFORE selection_binding is required, since it
-- captures command_manager at load.
local begin_end_calls = 0
package.loaded["core.command_manager"] = {
    begin_command_event = function() begin_end_calls = begin_end_calls + 1 end,
    end_command_event   = function() begin_end_calls = begin_end_calls + 1 end,
}
-- Stub qt_constants (command path doesn't touch widgets, but module-load does).
package.loaded["core.qt_constants"] = {
    DISPLAY    = { SET_VISIBLE = function() end },
    PROPERTIES = { SET_TEXT = function() end, SET_ENABLED = function() end },
    CONTROL    = { SET_ENABLED = function() end },
}
-- Stub inspectable factory (not used by commit_single_field directly but
-- required at module load).
package.loaded["inspectable"] = {
    clip     = function() return nil end,
    sequence = function() return nil end,
}

-- Make sure we get a fresh selection_binding after stubs are in place.
package.loaded["ui.inspector.selection_binding"] = nil
local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Inspector: commit-failure → revert + error banner ===\n")

-- Stub entry with set_value / blur_revert call tracking.
local function make_entry(last_model_value)
    local e = {
        field_key     = "sequence_start",
        field_type    = "TIMECODE",
        property_type = "TIMECODE",
        default_value = 0,
        dirty         = true,
        error         = false,
        pending_value = 2000,
        _last_model_value = last_model_value,
    }
    e.set_value_calls   = {}
    e.blur_revert_calls = 0
    function e:set_value(v)    table.insert(self.set_value_calls, v)  end
    function e:blur_revert()   self.blur_revert_calls = self.blur_revert_calls + 1 end
    function e:set_error(flag) self.error = flag end
    return e
end

-- Stub inspectable whose :set always fails.
local function failing_inspectable(err_message)
    return {
        sequence_id = "seq",
        get_schema_id = function() return "clip" end,
        set = function(_self, _field, _payload)
            return false, err_message or "VIDEO_OVERLAP: Clips cannot overlap on a video track"
        end,
    }
end

-- Stub inspectable whose :set succeeds.
local function succeeding_inspectable()
    return {
        sequence_id = "seq",
        get_schema_id = function() return "clip" end,
        set = function(_self, _field, _payload) return true end,
    }
end

--------------------------------------------------------------------------
-- Case 1: successful commit — entry:set_value(new value), no blur_revert,
-- on_error called with nil to clear any previous banner state.
--------------------------------------------------------------------------
do
    local entry = make_entry(1000)
    local on_error_calls = {}
    local ui_state = {
        mode = "single",
        active_inspectables = { succeeding_inspectable() },
        on_error = function(e, msg) table.insert(on_error_calls, { entry = e, msg = msg }) end,
    }
    sb.commit_single_field(ui_state, entry, 2000)
    check("success: set_value(new) called exactly once",
        #entry.set_value_calls == 1 and entry.set_value_calls[1] == 2000)
    check("success: blur_revert NOT called", entry.blur_revert_calls == 0)
    check("success: on_error called with nil (clear banner)",
        #on_error_calls == 1 and on_error_calls[1].msg == nil)
end

--------------------------------------------------------------------------
-- Case 2: failing commit — entry reverts to last model value, on_error
-- receives the failure message, NO set_value(new) call.
--------------------------------------------------------------------------
do
    local entry = make_entry(1000)
    local on_error_calls = {}
    local ui_state = {
        mode = "single",
        active_inspectables = { failing_inspectable("VIDEO_OVERLAP test") },
        on_error = function(e, msg) table.insert(on_error_calls, { entry = e, msg = msg }) end,
    }
    sb.commit_single_field(ui_state, entry, 9999)
    check("failure: set_value(9999) NOT called (field must not keep stale user value)",
        #entry.set_value_calls == 0)
    check("failure: blur_revert called exactly once",
        entry.blur_revert_calls == 1)
    check("failure: on_error called once",
        #on_error_calls == 1)
    check("failure: on_error message contains the underlying error",
        on_error_calls[1] and on_error_calls[1].msg
            and tostring(on_error_calls[1].msg):find("VIDEO_OVERLAP", 1, true) ~= nil)
    check("failure: entry associated with the error is the one that was committed",
        on_error_calls[1] and on_error_calls[1].entry == entry)
end

--------------------------------------------------------------------------
-- Case 3: mode is not 'single' — commit_single_field must no-op.
--------------------------------------------------------------------------
do
    local entry = make_entry(1000)
    local on_error_calls = {}
    local ui_state = {
        mode = "multi_edit",
        active_inspectables = { failing_inspectable() },
        on_error = function(e, msg) table.insert(on_error_calls, { entry = e, msg = msg }) end,
    }
    sb.commit_single_field(ui_state, entry, 2000)
    check("wrong mode: set_value NOT called",    #entry.set_value_calls == 0)
    check("wrong mode: blur_revert NOT called",  entry.blur_revert_calls == 0)
    check("wrong mode: on_error NOT called",     #on_error_calls == 0)
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_commit_failure.lua passed")
