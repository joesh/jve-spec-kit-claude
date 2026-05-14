--- Effective source: who is currently "the source" for edit operations?
---
--- The effective source is a master sequence id, derived from two
--- independent input streams:
---
---   1. The source viewer's loaded master (via `source_loaded_changed`).
---   2. The project browser's current selection (via `selection_hub`).
---
--- Priority — recency rule among the two source inputs:
---
---   "Most-recently-activated among {source_viewer, browser} wins,
---    provided it has a valid value. If the most-recent winner has no
---    value, fall back to whichever of the two does."
---
--- Activating means becoming the focused panel (selection_hub's active
--- panel). Activating any OTHER panel (e.g. timeline) does NOT change
--- the recency — clicking a src-btn on the timeline shifts focus there
--- but the previously-selected source survives.
---
--- "Valid value" = source viewer has a clip loaded, or browser has a
--- master_clip/timeline item selected.
---
--- Emits `effective_source_changed(new_master_seq_id, prev_master_seq_id)`
--- whenever the computed value changes (and only then — no spurious fires
--- on selection events that don't move the effective source).
---
--- Consumers:
---   - `command_manager.execute_interactive` injects `sequence_id`
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
local SOURCE_INPUT_PANELS = { source_monitor = true, project_browser = true }

local _source_viewer_seq_id    = nil
local _browser_master_seq_id   = nil  -- current browser-selected master (nil if none)
local _last_active_source_input = nil  -- "source_monitor" | "project_browser" | nil
local _current                 = nil

local function compute_effective()
    -- Recency rule: between the two source inputs, whichever was activated
    -- most recently wins — provided it has a value. If the recency winner
    -- has no value, the other input is the answer (this is the recency
    -- rule's tiebreaker, not a fallback for a missing required value).
    local sv  = _source_viewer_seq_id
    local br  = _browser_master_seq_id
    if _last_active_source_input == "source_monitor" and sv ~= nil then return sv end
    if _last_active_source_input == "project_browser" and br ~= nil then return br end
    -- Recency winner has no value (or neither has been activated yet) —
    -- pick whichever has a value; nil if neither does.
    if sv ~= nil then return sv end
    return br
end

local function recompute_and_emit()
    local next_value = compute_effective()
    if next_value == _current then return end
    local prev = _current
    _current = next_value
    Signals.emit("effective_source_changed", _current, prev)
end

local function on_source_loaded_changed(new_master_seq_id, _prev_seq_id)
    -- nil = source viewer cleared; non-nil must be a non-empty string id.
    assert(new_master_seq_id == nil
           or (type(new_master_seq_id) == "string" and new_master_seq_id ~= ""),
        string.format("effective_source.on_source_loaded_changed: "
            .. "new_master_seq_id must be string or nil; got %s (%s)",
            type(new_master_seq_id), tostring(new_master_seq_id)))
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

local function on_selection_changed(_items, panel_id)
    -- Always recompute browser-selected source from the hub's persisted
    -- selection — independent of which panel is currently active. The
    -- browser's selection survives focus shifts (e.g. clicking a src-btn
    -- on the timeline).
    _browser_master_seq_id = pick_master_seq_id_from_items(
        selection_hub.get_selection("project_browser"))
    -- Track recency among the two source inputs. Activating any other
    -- panel (timeline, etc.) does NOT change recency.
    if SOURCE_INPUT_PANELS[panel_id] then
        _last_active_source_input = panel_id
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
    _source_viewer_seq_id    = nil
    _browser_master_seq_id   = nil
    _last_active_source_input = nil
    _current                 = nil
end

return M
