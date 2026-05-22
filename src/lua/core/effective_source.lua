--- Effective source: who is currently "the source" for edit operations?
---
--- Precedence (NOT recency):
---
---   1. If the project browser is the active panel AND its selection
---      contains an insertable item (master_clip or timeline-as-sequence),
---      that item is the source.
---   2. Otherwise: whatever sequence is loaded in the source viewer
---      (may be nil = no source loaded).
---
--- "Active panel" comes from `selection_hub` — the currently focused panel,
--- not a sticky historical state. Clicking from the browser into the
--- timeline immediately reverts the precedence to rule 2; the browser
--- only "owns" the source while it's the focused panel.
---
--- A source can be a master clip OR a nested sequence. Both resolve to a
--- master sequence id via `master_seq_id_of`.
---
--- Emits `effective_source_changed(new_master_seq_id, prev_master_seq_id)`
--- whenever the computed `M.get()` value changes.
---
--- Consumers:
---   - `command_manager.execute_interactive` calls `pick_for_edit` to
---     inject `source_sequence_id` for Insert/Overwrite (and any future
---     command declaring source_sequence_id in its arg spec). The resolver
---     returns either a valid source id, or a `problem` table that the
---     command layer surfaces as a user-facing popup.
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

-- Internal state.
local _source_viewer_seq_id = nil
-- 019 FR-016d: when source_viewer is in live-bound mode, it carries
-- (in, out) overrides drawn from the loaded clip's source_in/out columns.
-- get() returns the triple in that case; staged mode leaves these nil.
-- All three fields are mutated through the three per-direction entry
-- points below — no other writers (see contracts/effective_source_pass_through.md).
local _source_viewer_in     = nil
local _source_viewer_out    = nil
local _browser_items        = {}    -- last persisted project_browser selection
local _active_panel_id      = nil
local _current              = nil

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

local function browser_is_active()
    return _active_panel_id == "project_browser"
end

-- First item in `_browser_items` that resolves to a master sequence id
-- via master_seq_id_of. Returns (item, seq_id) or (nil, nil).
local function first_insertable_browser_item()
    for _, it in ipairs(_browser_items) do
        local seq = M.master_seq_id_of(it)
        if seq ~= nil then return it, seq end
    end
    return nil, nil
end

-- Compute the "ambient" effective source: the precedence rule with no
-- destination-awareness (no cycle filtering). This is what M.get() returns
-- and what feeds `effective_source_changed` for non-edit consumers like
-- patch-seeding and src-btn rendering — they only need to know "what's the
-- source UI-wise", not "is it valid against destination X".
local function compute_current()
    if browser_is_active() then
        local _, seq = first_insertable_browser_item()
        if seq ~= nil then return seq end
        -- Non-empty browser selection but no insertable item, OR empty
        -- selection. Either way: rule 2 (fall through to source viewer).
        -- `pick_for_edit` distinguishes the two for popup purposes.
    end
    return _source_viewer_seq_id
end

local function recompute_and_emit()
    local next_value = compute_current()
    if next_value == _current then return end
    local prev = _current
    _current = next_value
    Signals.emit("effective_source_changed", _current, prev)
end

local function on_source_loaded_changed(new_master_seq_id, _prev_seq_id)
    assert(new_master_seq_id == nil
           or (type(new_master_seq_id) == "string" and new_master_seq_id ~= ""),
        string.format("effective_source.on_source_loaded_changed: "
            .. "new_master_seq_id must be string or nil; got %s (%s)",
            type(new_master_seq_id), tostring(new_master_seq_id)))
    _source_viewer_seq_id = new_master_seq_id
    recompute_and_emit()
end

local function on_selection_changed(_items, panel_id)
    -- Always pull the latest browser selection from the hub — `panel_id`
    -- here is the currently-active panel (any), not necessarily browser.
    -- The browser's persisted selection survives focus shifts.
    local items = selection_hub.get_selection("project_browser")
    assert(type(items) == "table", string.format(
        "effective_source.on_selection_changed: selection_hub.get_selection "
        .. "must return a table; got %s", type(items)))
    _browser_items = items
    _active_panel_id = panel_id
    recompute_and_emit()
end

-- Subscribe at module load. Lua's require cache makes this run once.
Signals.connect("source_loaded_changed", on_source_loaded_changed)
selection_hub.register_listener(on_selection_changed)

--- Get the current effective source.
--- Returns one of:
---   (nil)                           — no source.
---   (seq_id)                        — staged-mode source viewer, OR browser-active.
---   (seq_id, in_frame, out_frame)   — live-bound clip in source viewer; in/out
---                                     are the loaded clip's source_in/out
---                                     and override any mark_in/out on the
---                                     source sequence itself for Insert/Overwrite
---                                     (spec 019 FR-016d).
--- Destination-agnostic — use `pick_for_edit` for edit-command dispatch.
function M.get()
    -- The override fields only carry meaning when the source viewer is the
    -- effective source (i.e., browser-active doesn't trump it). Browser
    -- precedence is already baked into _current; if browser won, _current
    -- holds the browser's seq_id, and we don't want stale source-viewer
    -- in/out leaking through. So gate the triple return on
    -- "_current matches the source-viewer seq id".
    if _source_viewer_in ~= nil and _current == _source_viewer_seq_id then
        return _current, _source_viewer_in, _source_viewer_out
    end
    return _current
end

--- 019 FR-016d display path: the source-side ruler (under the source
--- monitor) and the source tab (in the timeline tab strip) both need to
--- show the live-bound clip's in/out as visible marks when the source
--- viewer is in live_bound_clip mode. The marks live on the clip's
--- source_in/source_out columns (NOT the master source sequence's
--- mark_in/mark_out, which stay nil for the master).
---
--- This accessor returns the overrides for `sequence_id` if the source
--- viewer is currently live-bound to a clip whose source sequence
--- matches; otherwise returns nil, nil so callers fall back to the
--- sequence row's persisted marks (staged mode + non-source tabs).
---
--- Returns: (in_frame, out_frame) or (nil, nil).
function M.get_source_marks_for(sequence_id)
    if _source_viewer_seq_id == sequence_id
        and _source_viewer_in ~= nil
        and _source_viewer_out ~= nil then
        return _source_viewer_in, _source_viewer_out
    end
    return nil, nil
end

--- 019 FR-016d entry point: live-bound source viewer carries clip's
--- source_in/out as overrides. All three fields written atomically.
--- @param seq_id string  the clip's source sequence id
--- @param in_frame integer
--- @param out_frame integer  must be > in_frame
function M._set_source_viewer_clip(seq_id, in_frame, out_frame)
    assert(type(seq_id) == "string" and seq_id ~= "",
        "effective_source._set_source_viewer_clip: seq_id required (non-empty string)")
    assert(type(in_frame) == "number", string.format(
        "effective_source._set_source_viewer_clip: in_frame must be a number; got %s",
        type(in_frame)))
    assert(type(out_frame) == "number", string.format(
        "effective_source._set_source_viewer_clip: out_frame must be a number; got %s",
        type(out_frame)))
    assert(out_frame > in_frame, string.format(
        "effective_source._set_source_viewer_clip: out_frame (%d) must be > in_frame (%d)",
        out_frame, in_frame))
    _source_viewer_seq_id = seq_id
    _source_viewer_in     = in_frame
    _source_viewer_out    = out_frame
    recompute_and_emit()
end

--- 019 FR-016d entry point: staged source viewer carries just a seq id;
--- in/out overrides cleared in one pass.
function M._set_source_viewer_sequence(seq_id)
    assert(type(seq_id) == "string" and seq_id ~= "",
        "effective_source._set_source_viewer_sequence: seq_id required")
    _source_viewer_seq_id = seq_id
    _source_viewer_in     = nil
    _source_viewer_out    = nil
    recompute_and_emit()
end

--- 019 FR-016d entry point: clear all three fields atomically on unload.
function M._clear_source_viewer()
    _source_viewer_seq_id = nil
    _source_viewer_in     = nil
    _source_viewer_out    = nil
    recompute_and_emit()
end

--- Pick the source for an interactive edit command into a given
--- destination sequence. Returns `(seq_id, nil)` on success, or
--- `(nil, problem)` where `problem` is a structured table the UI layer
--- formats into a popup. Possible kinds:
---
---   * "not_insertable"   — browser is active, selection exists, but
---                          first item isn't a master_clip or timeline.
---                          problem.label = item.display_name
---   * "missing_item"     — no source available at all.
---                          problem.cmd = command name
---   * "cycle_self"       — chosen source == destination.
---                          problem.seq_name
---   * "cycle_transitive" — chosen source already contains destination.
---                          problem.dest_name, problem.src_name
---
--- The cycle checks duplicate the invariant guarded in
--- `_place_shared.pick_endpoints`; that assert remains as defense-in-depth.
--- Surfacing the failure here lets us show a user-friendly popup instead
--- of an internal Lua stacktrace warning.
function M.pick_for_edit(rec_id, cmd_name)
    assert(rec_id and rec_id ~= "",
        "effective_source.pick_for_edit: rec_id required")
    assert(cmd_name and cmd_name ~= "",
        "effective_source.pick_for_edit: cmd_name required")

    local seq
    if browser_is_active() and #_browser_items > 0 then
        local _, found = first_insertable_browser_item()
        if found ~= nil then
            seq = found
        else
            local first = _browser_items[1]
            local label = first.display_name
            assert(type(label) == "string" and label ~= "", string.format(
                "effective_source.pick_for_edit: first browser item missing "
                .. "display_name (item_type=%s) — normalize_* contract violated",
                tostring(first.item_type)))
            return nil, { kind = "not_insertable", label = label }
        end
    else
        seq = _source_viewer_seq_id
    end

    if seq == nil then
        return nil, { kind = "missing_item", cmd = cmd_name }
    end

    local Sequence = require("models.sequence")
    if seq == rec_id then
        return nil, {
            kind     = "cycle_self",
            seq_name = Sequence.get_name(rec_id),
        }
    end

    local Cycle = require("models.cycle")
    if Cycle.would_create_cycle(rec_id, seq) then
        return nil, {
            kind      = "cycle_transitive",
            dest_name = Sequence.get_name(rec_id),
            src_name  = Sequence.get_name(seq),
        }
    end

    return seq, nil
end

--- Test-only reset. Restores module state without re-subscribing.
function M._reset_for_tests()
    _source_viewer_seq_id = nil
    _source_viewer_in     = nil
    _source_viewer_out    = nil
    _browser_items        = {}
    _active_panel_id      = nil
    _current              = nil
end

return M
