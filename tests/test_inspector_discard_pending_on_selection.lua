#!/usr/bin/env luajit
-- T011 (deferred from 012 tasks.md): FR-013a + FR-016a —
-- Selection change with pending un-Applied multi-edits discards those
-- pending values: dirty flag clears, pending_value clears, any error
-- state gets reverted to the last model value. A subsequent selection
-- update_apply_button call must then show Apply disabled.
--
-- Domain contract (derived from the spec, not from tracing code):
--   * Pending edits are per-mode — switching selection drops whatever
--     the user typed but didn't Apply.
--   * Fields with a parse error AND dirty state must blur-revert to the
--     model value (FR-015b) so the red border goes away.
--   * Clean fields (no dirty, no error) are left untouched.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

package.loaded["core.command_manager"] = {
    begin_command_event = function() end,
    end_command_event   = function() end,
}
-- SET_ENABLED capture is read by case 4. Case 4 reassigns a fresh table
-- before invoking the code under test, so nil-init here is intentional.
-- SET_VISIBLE is stubbed as a no-op — visibility isn't tested here.
local enabled_state
package.loaded["core.qt_constants"] = {
    DISPLAY    = { SET_VISIBLE = function() end },
    PROPERTIES = { SET_TEXT = function() end },
    CONTROL    = { SET_ENABLED = function(w, v) enabled_state[w] = v end },
}
package.loaded["inspectable"] = {
    clip     = function() return nil end,
    sequence = function() return nil end,
}

package.loaded["ui.inspector.selection_binding"] = nil
local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, ok)
    if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end
end

print("=== Inspector: discard_pending on selection change ===\n")

-- Entry stub: mirrors field_widget.Entry's dirty/error/pending/blur_revert
-- surface closely enough for the discard + apply-button checks.
local function make_entry(opts)
    local e = {
        field_key         = opts.field_key,
        dirty             = opts.dirty and true or false,
        error             = opts.err and true or false,
        pending_value     = opts.pending,
        _last_model_value = opts.model,
        clear_dirty_calls = 0,
        blur_revert_calls = 0,
    }
    function e:clear_dirty()
        self.clear_dirty_calls = self.clear_dirty_calls + 1
        self.dirty = false
        self.pending_value = nil
    end
    function e:blur_revert()
        self.blur_revert_calls = self.blur_revert_calls + 1
        self.error = false
    end
    return e
end

-- Case 1: Dirty valid field — clear_dirty fires, no blur_revert.
do
    local entry = make_entry { field_key = "name", dirty = true, pending = "typed" }
    sb._discard_pending({ field_widgets = { name = entry } })
    check("dirty-valid clears dirty", entry.clear_dirty_calls == 1)
    check("dirty-valid does not blur_revert (no error)", entry.blur_revert_calls == 0)
    check("dirty-valid pending_value cleared", entry.pending_value == nil)
end

-- Case 2: Dirty AND error — clear_dirty AND blur_revert fire.
do
    local entry = make_entry {
        field_key = "mark_in", dirty = true, err = true,
        pending = nil, model = 100,
    }
    sb._discard_pending({ field_widgets = { mark_in = entry } })
    check("dirty+error clears dirty", entry.clear_dirty_calls == 1)
    check("dirty+error blur_reverts (drops red border)", entry.blur_revert_calls == 1)
end

-- Case 3: Clean field — clear_dirty still fires (idempotent), blur_revert does not.
do
    local entry = make_entry { field_key = "enabled", dirty = false }
    sb._discard_pending({ field_widgets = { enabled = entry } })
    check("clean field clear_dirty still called", entry.clear_dirty_calls == 1)
    check("clean field no blur_revert", entry.blur_revert_calls == 0)
end

-- Case 4: After discard, Apply stays disabled (no dirty fields remain).
do
    local e1 = make_entry { field_key = "a", dirty = true, pending = "x" }
    local e2 = make_entry { field_key = "b", dirty = true, pending = "y" }
    local schema_view = { field_widgets = { a = e1, b = e2 } }
    sb._discard_pending(schema_view)

    local apply, reset = {_k="apply"}, {_k="reset"}
    enabled_state = {}
    sb._update_apply_button({
        mode = "multi_edit",
        bottom_bar   = {_k="bar"},
        apply_button = apply,
        reset_button = reset,
        active_schema_view = schema_view,
    })
    check("post-discard Apply disabled", enabled_state[apply] == false)
    check("post-discard Reset disabled", enabled_state[reset] == false)
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_discard_pending_on_selection.lua passed")
