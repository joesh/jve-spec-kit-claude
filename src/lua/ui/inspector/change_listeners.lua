-- Inspector change listeners.
--
-- Single-channel pull-on-notify (MVC rule 3.0). Only Signals.connect is
-- used — no timeline_state.add_listener subscription, no direct
-- imperative push paths. Rule 2.20 audit T054 greps for this.
--
-- Handlers:
--   project_changed(new_project_id)  — clear Inspector state (FR-017)
--   content_changed(sequence_id)     — pull current inspectables and refresh
--                                      non-dirty fields (FR-016, FR-016a)

local Signals = require("core.signals")
local qt_constants = require("core.qt_constants")
local selection_binding = require("ui.inspector.selection_binding")
local watchers = require("core.watchers")
local log = require("core.logger").for_area("ui")

local M = {}

local function on_entity_mutated(ui_state)
    return function(event_data)
        if not ui_state.active_schema_view then return end
        if #ui_state.active_inspectables == 0 then return end

        -- PERFORMANCE (FU-8 optimization): Ignore sequence playhead updates
        -- when we are only inspecting clips. Scrubbing persists the playhead
        -- to the DB every 200ms, but this doesn't change clip metadata.
        if event_data and event_data.kind == "playhead" then
            if ui_state.active_schema_id == "clip" then
                return
            end
        end

        log.detail("inspector: entity mutated, refreshing clean fields")

        -- Refresh the inspectables' DB cache.
        for _, insp in ipairs(ui_state.active_inspectables) do
            if insp.refresh then insp:refresh() end
        end

        -- Re-read non-dirty fields only. Dirty fields keep user's in-flight
        -- text (FR-016a).
        selection_binding._refresh_only_clean_fields(
            ui_state.active_schema_view,
            ui_state.active_inspectables,
            #ui_state.active_inspectables
        )
    end
end

local function on_project_changed(ui_state)
    return function(_new_project_id)
        M.update_watches(ui_state) -- Clear existing watches
        if ui_state.active_schema_view then
            ui_state.schema.deactivate(ui_state.active_schema_view)
        end
        ui_state.active_schema_view  = nil
        ui_state.active_schema_id    = nil
        ui_state.active_inspectables = {}
        ui_state.mode                = "empty"
        ui_state.prev_item_ids       = {}
        ui_state.prev_schemas_present = {}
        if ui_state.header_label then
            qt_constants.PROPERTIES.SET_TEXT(ui_state.header_label, "No editable selection")
        end
        if ui_state.apply_button then
            qt_constants.DISPLAY.SET_VISIBLE(ui_state.apply_button, false)
        end
        log.event("inspector: project_changed — state cleared")
    end
end

--- Update the set of entities the inspector is watching based on the current selection.
--  Called by selection_binding after every selection update.
function M.update_watches(ui_state)
    -- Clear previous watches
    if ui_state._watcher_tokens then
        for _, token in ipairs(ui_state._watcher_tokens) do
            watchers.unwatch(token)
        end
    end
    ui_state._watcher_tokens = {}

    if #ui_state.active_inspectables == 0 then
        return
    end

    -- Collect unique keys from all active inspectables
    local keys = {}
    for _, insp in ipairs(ui_state.active_inspectables) do
        if insp.get_watcher_keys then
            for _, key in ipairs(insp:get_watcher_keys()) do
                keys[key] = true
            end
        end
    end

    -- Register new watches
    local callback = on_entity_mutated(ui_state)
    for key, _ in pairs(keys) do
        local token = watchers.watch(key, callback)
        table.insert(ui_state._watcher_tokens, token)
    end
    
    log.detail("inspector: watching %d entity keys", #ui_state._watcher_tokens)
end

--- Install project-level handlers. Entity-level handlers are managed via update_watches.
function M.install(ui_state)
    assert(ui_state, "change_listeners.install: ui_state required")
    ui_state._watcher_tokens = {}
    local pc_id = Signals.connect("project_changed", on_project_changed(ui_state), 45)
    assert(pc_id, "change_listeners: failed to connect project_changed")

    return {
        project_changed_id = pc_id,
    }
end

function M.uninstall(disposers, ui_state)
    if ui_state then
        M.update_watches(ui_state) -- Passing empty selection state effectively unwatches everything
    end
    if not disposers then return end
    if disposers.project_changed_id then
        Signals.disconnect(disposers.project_changed_id)
    end
end

return M
