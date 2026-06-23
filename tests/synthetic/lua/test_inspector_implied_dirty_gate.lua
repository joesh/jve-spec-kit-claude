-- Inspector implied-target dirty-edits gate.
--
-- When the timeline broadcasts a re-pick of the implied inspectable
-- (auto-driven by playhead motion, clip add/delete, track enable toggle),
-- the Inspector must NOT swap in the new clip if the user has unsaved
-- edits in the current view. The user keeps editing the clip they were
-- inspecting; the auto re-pick is dropped on the floor.
--
-- Real selection changes (explicit user click, including clearing the
-- selection back to true-empty) still flow through and discard pending
-- edits, matching the existing FR-013a behaviour.
--
-- Scope: gate-predicate only — items carry pre-built inspectables so
-- this never exercises the inspectable_factory path (covered separately
-- by the integration tests under tests/synthetic/integration/inspector).

require("test_env")

local sb = require("ui.inspector.selection_binding")

local function fake_inspectable(schema_id, name)
    return {
        get_schema_id      = function() return schema_id end,
        get_display_name   = function() return name end,
        supports_multi_edit = function() return true end,
        get                = function() return nil end,
    }
end

-- Minimal ui_state stub. Only the fields the binding touches in the
-- code paths exercised by these tests need to be present; the rest is
-- left nil so any unexpected access fails loudly.
local function make_ui_state(opts)
    opts = opts or {}
    local field_widgets = {}
    for key, dirty in pairs(opts.fields or {}) do
        field_widgets[key] = {
            dirty         = dirty,
            error         = false,
            pending_value = nil,
            clear_dirty   = function(self) self.dirty = false end,
            blur_revert   = function(self) self.dirty = false end,
            set_value     = function(self, v) self.value = v; self.dirty = false end,
            set_mixed     = function(self, m) self.mixed = m end,
        }
    end
    local schema_view = {
        field_widgets = field_widgets,
    }
    return {
        mode                  = opts.mode or "single",
        active_schema_id      = opts.active_schema_id or "clip",
        active_schema_view    = schema_view,
        active_inspectables   = opts.active_inspectables or { fake_inspectable("clip", "current") },
        prev_item_ids         = {},
        prev_schemas_present  = { clip = true },
        filter_query          = "",
        schema = {
            deactivate   = function() end,
            activate     = function() end,
            apply_filter = function() end,
        },
        schema_views = {
            clip = schema_view,
        },
    }
end

local function clip_item(id, name, opts)
    opts = opts or {}
    local item = {
        item_type   = "timeline_clip",
        clip_id     = id,
        clip        = { id = id },
        inspectable = fake_inspectable("clip", name),
        schema      = "clip",
        display_name = name,
        project_id  = "p",
        sequence_id = "s",
    }
    if opts.implied then item._implied = true end
    return item
end

local pass, fail = 0, 0
local function check(label, ok, msg)
    if ok then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label .. (msg and (": " .. msg) or "")) end
end

-- ─── Implied re-pick + dirty → ignored ─────────────────────────────────────
do
    local ui = make_ui_state{
        active_inspectables = { fake_inspectable("clip", "A") },
        fields = { name = true },  -- dirty
    }
    local before_mode = ui.mode
    local before_inspectable = ui.active_inspectables[1]
    sb.update_selection({ clip_item("B", "B", { implied = true }) }, "timeline", ui)
    check("dirty + implied: mode unchanged",
        ui.mode == before_mode)
    check("dirty + implied: active inspectable unchanged",
        ui.active_inspectables[1] == before_inspectable)
end

-- ─── Implied re-pick + clean → proceeds ────────────────────────────────────
do
    local ui = make_ui_state{
        active_inspectables = { fake_inspectable("clip", "A") },
        fields = { name = false },  -- clean
    }
    sb.update_selection({ clip_item("B", "B", { implied = true }) }, "timeline", ui)
    check("clean + implied: swapped to new inspectable",
        ui.active_inspectables[1] ~= nil
        and ui.active_inspectables[1].get_display_name() == "B")
    check("clean + implied: mode is single",
        ui.mode == "single")
end

-- ─── Explicit user selection always wins, dirty or not ─────────────────────
do
    local ui = make_ui_state{
        active_inspectables = { fake_inspectable("clip", "A") },
        fields = { name = true },  -- dirty
    }
    -- No _implied flag → user clicked B; pending edits get discarded
    -- (existing FR-013a behaviour).
    sb.update_selection({ clip_item("B", "B") }, "timeline", ui)
    check("dirty + explicit: swapped to new inspectable",
        ui.active_inspectables[1] ~= nil
        and ui.active_inspectables[1].get_display_name() == "B")
end

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_inspector_implied_dirty_gate.lua: failures")
print("✅ test_inspector_implied_dirty_gate.lua passed")
