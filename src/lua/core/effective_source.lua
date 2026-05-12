--- Effective source: who is currently "the source" for edit operations?
---
--- The effective source is a master sequence id, derived from two
--- independent input streams:
---
---   1. The source viewer's loaded master (via `source_loaded_changed`).
---   2. The project browser's current selection (via `selection_hub`).
---
--- Priority: if the project browser is the active panel AND its selection
--- contains a master_clip item, that wins. Otherwise the source viewer's
--- loaded master (which may be nil) is the answer.
---
--- Emits `effective_source_changed(new_master_seq_id, prev_master_seq_id)`
--- whenever the computed value changes (and only then — no spurious fires
--- on selection events that don't move the effective source).
---
--- Consumers:
---   - `command_manager.execute_interactive` injects `nested_sequence_id`
---     from `effective_source.get()` when params lacks it. This is how
---     Insert/Overwrite invoked from keymaps (e.g. F10) acquire their
---     source argument.
---   - `timeline_panel` listens for `effective_source_changed` to
---     re-render patch buttons and seed identity patches on the active
---     record sequence.
---
--- This module subscribes at require-time. Idempotent — multiple requires
--- return the same single subscription set.
---
--- @file core/effective_source.lua

local Signals       = require("core.signals")
local selection_hub = require("ui.selection_hub")

local M = {}

-- Internal state — only the derived `_current` is observable via M.get().
-- The two underlying inputs are kept so a change in either recomputes the
-- effective answer without re-asking source_viewer / selection_hub.
local _source_viewer_seq_id    = nil
local _browser_master_seq_id   = nil  -- nil unless browser is active AND has master_clip selected
local _current                 = nil

local function compute_effective()
    -- Browser-selected master takes priority when the browser is the active
    -- panel and has a master_clip selected. Otherwise the source viewer's
    -- loaded master (which may be nil). Written as explicit priority, not
    -- as a logical-or, so it's clear this is a choice rule, not a fallback
    -- for a missing required value (rule 2.13).
    if _browser_master_seq_id ~= nil then return _browser_master_seq_id end
    return _source_viewer_seq_id
end

local function recompute_and_emit()
    local next_value = compute_effective()
    if next_value == _current then return end
    local prev = _current
    _current = next_value
    Signals.emit("effective_source_changed", _current, prev)
end

local function on_source_loaded_changed(new_master_seq_id, _prev_seq_id)
    _source_viewer_seq_id = new_master_seq_id
    recompute_and_emit()
end

--- THE predicate: given a normalized browser-selection item, return the
--- master sequence id this item represents as an Insert/Overwrite
--- source — or `nil` if it isn't a source. Single source of truth for
--- "is this thing insertable" across the codebase.
---
--- Browser items arrive normalized by `browser_state.normalize_*`:
---   * item_type="master_clip" — top-level clip from imported media.
---     `master_sequence_id` names the underlying master sequence.
---   * item_type="timeline"    — a nested sequence. `id` names it.
---   * bins / other entries    — not insertable; returns nil.
function M.master_seq_id_of(item)
    if type(item) ~= "table" then return nil end
    if item.item_type == "master_clip"
       and type(item.master_sequence_id) == "string"
       and item.master_sequence_id ~= "" then
        return item.master_sequence_id
    end
    if item.item_type == "timeline"
       and type(item.id) == "string" and item.id ~= "" then
        return item.id
    end
    return nil
end

-- Pick the first source-shaped entry from a browser-selection items list.
-- Single-source-of-truth via M.master_seq_id_of.
--
-- selection_hub's contract is that items is always a table (possibly
-- empty). Assert that — silent-skip on non-table would hide a contract
-- breach in the selection plumbing.
local function pick_master_seq_id_from_items(items)
    assert(type(items) == "table",
        "effective_source: selection_hub listener got non-table items: " .. type(items))
    for _, it in ipairs(items) do
        local id = M.master_seq_id_of(it)
        if id ~= nil then return id end
    end
    return nil
end

local function on_selection_changed(items, panel_id)
    -- Browser-as-source applies only while the browser is the active panel.
    -- selection_hub.notify is called with (items_of_active_panel, active_panel_id);
    -- a panel switch fires this same callback with the new active panel's
    -- items. So this single listener handles both "selection changed in
    -- browser" and "panel switched to/from browser."
    if panel_id == "project_browser" then
        _browser_master_seq_id = pick_master_seq_id_from_items(items)
    else
        _browser_master_seq_id = nil
    end
    recompute_and_emit()
end

-- Subscribe at module load. Lua's require cache makes this run once.
Signals.connect("source_loaded_changed", on_source_loaded_changed)
selection_hub.register_listener(on_selection_changed)

--- Get the current effective master sequence id (or nil if no source).
function M.get()
    return _current
end

--- Test-only reset. Restores module state without re-subscribing.
function M._reset_for_tests()
    _source_viewer_seq_id  = nil
    _browser_master_seq_id = nil
    _current               = nil
end

return M
