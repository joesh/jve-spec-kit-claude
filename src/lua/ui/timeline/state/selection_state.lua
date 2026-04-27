--- Timeline Selection State
-- Manages selected clips, edges, and gaps
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")
local log = require("core.logger").for_area("timeline")

local on_selection_changed_callback = nil

local function normalize_edge_selection()
    local state = data.state
    if not state.selected_edges or #state.selected_edges == 0 then
        return false
    end

    local normalized = {}
    local seen = {}
    local changed = false

    clip_state.invalidate_indexes() -- Ensure fresh indexes before traversal? Actually ensure_clip_indexes calls it if needed.

    for _, edge in ipairs(state.selected_edges) do
        local clip = clip_state.get_by_id(edge.clip_id)

        if clip then
            local key = clip.id .. ":" .. edge.edge_type
            if not seen[key] then
                table.insert(normalized, {
                    clip_id = clip.id,
                    edge_type = edge.edge_type,
                    trim_type = edge.trim_type,
                    track_id = clip.track_id
                })
                seen[key] = true
            else
                changed = true
            end
        else
            -- Clip no longer exists (e.g. gap clip removed after recomputation)
            log.event("normalize_edge_selection: dropping stale edge clip=%s edge=%s (clip not found)",
                tostring(edge.clip_id):sub(1,12), tostring(edge.edge_type))
            changed = true
        end
    end

    if changed then
        state.selected_edges = normalized
    end

    return changed
end

function M.get_selected_clips()
    return data.state.selected_clips
end

function M.set_selection(clips, persist_callback)
    clips = clips or {}
    -- Idempotent: skip notification when the selection state is already
    -- equivalent (common case: undo of a metadata command restores the
    -- pre-snapshot empty selection). A no-op set_selection previously
    -- cascaded through selection_hub → inspector.update_selection →
    -- load_clip_data, dominating the undo latency for a user who is
    -- editing track properties or sequence metadata with no clip
    -- selected. We only cover the empty→empty case here — non-empty
    -- element-wise equality is a future optimization if it shows up.
    local prev_clips = data.state.selected_clips or {}
    local prev_edges = data.state.selected_edges or {}
    local prev_gaps = data.state.selected_gaps or {}
    if #clips == 0 and #prev_clips == 0 and #prev_edges == 0 and #prev_gaps == 0 then
        if persist_callback then persist_callback() end
        return
    end

    data.state.selected_clips = clips
    data.state.selected_edges = {}
    data.state.selected_gaps = {}

    data.notify_listeners()
    if persist_callback then persist_callback() end
    if on_selection_changed_callback then
        on_selection_changed_callback(data.state.selected_clips)
    end
end

function M.get_selected_edges()
    return data.state.selected_edges
end

--- Set edge selection with normalization and validation.
--- @param edges table Array of {clip_id, edge_type, trim_type} entries
--- @param opts table|nil Options: {normalize=true, notify=true, clear_clips=true, clear_gaps=true}
--- @param persist_callback function|nil Called after selection is set (for DB persistence)
---
--- Use this for user-initiated selections (clicks, drags) where the edge list may contain:
--- - Duplicate entries (same clip_id + edge_type)
--- - References to clips that no longer exist (deleted during the operation)
---
--- Normalization deduplicates entries and removes references to missing clips.
--- For undo/redo restoration of known-good selections, use restore_edge_selection instead.
function M.set_edge_selection(edges, opts, persist_callback)
    opts = opts or {
        normalize = true,
        notify = true,
        clear_clips = true,
        clear_gaps = true
    }
    for _, edge in ipairs(edges or {}) do
        log.event("set_edge_selection: clip=%s edge=%s trim=%s",
            tostring(edge.clip_id):sub(1,12), tostring(edge.edge_type),
            tostring(edge.trim_type))
    end
    data.state.selected_edges = edges or {}

    if opts.clear_clips ~= false then data.state.selected_clips = {} end
    if opts.clear_gaps ~= false then data.state.selected_gaps = {} end

    if opts.normalize ~= false then normalize_edge_selection() end
    if opts.notify ~= false then data.notify_listeners() end
    if persist_callback then persist_callback() end
end

--- Restore edge selection without normalization (for undo/redo).
--- @param edges table Array of {clip_id, edge_type, trim_type} entries
--- @param opts table|nil Options passed to set_edge_selection (normalize forced to false)
--- @param persist_callback function|nil Called after selection is set
---
--- Use this for undo/redo restoration where:
--- - The edges were previously validated and persisted
--- - The clips are known to exist (just restored by the undo operation)
--- - Normalization would be redundant and waste cycles on clip lookups
---
--- For user-initiated selections, use set_edge_selection instead.
function M.restore_edge_selection(edges, opts, persist_callback)
    opts = opts or {}
    opts.normalize = false
    return M.set_edge_selection(edges, opts, persist_callback)
end

function M.toggle_edge_selection(clip_id, edge_type, trim_type, persist_callback)
    local state = data.state
    for i, edge in ipairs(state.selected_edges) do
        if edge.clip_id == clip_id and edge.edge_type == edge_type then
            table.remove(state.selected_edges, i)
            normalize_edge_selection()
            state.selected_gaps = {}
            data.notify_listeners()
            if persist_callback then persist_callback() end
            return false
        end
    end

    if #state.selected_edges == 0 then
        state.selected_clips = {}
        state.selected_gaps = {}
    end

    table.insert(state.selected_edges, {
        clip_id = clip_id,
        edge_type = edge_type,
        trim_type = trim_type
    })

    normalize_edge_selection()
    state.selected_gaps = {}
    data.notify_listeners()
    if persist_callback then persist_callback() end
    return true
end

function M.get_selected_gaps()
    return data.state.selected_gaps or {}
end

local function gaps_equal(a, b)
    if not a or not b or a.track_id ~= b.track_id then return false end
    -- All gap coords are now integers
    if (a.start_value or 0) ~= (b.start_value or 0) then return false end
    if (a.duration or a.duration_value or 0) ~= (b.duration or b.duration_value or 0) then return false end
    return true
end

function M.set_gap_selection(gaps)
    gaps = gaps or {}
    -- Idempotent: see M.set_selection for rationale. Restoring an empty
    -- gap selection during undo must not fire the notify/listener chain
    -- when the state is already empty.
    local prev_clips = data.state.selected_clips or {}
    local prev_edges = data.state.selected_edges or {}
    local prev_gaps = data.state.selected_gaps or {}
    if #gaps == 0 and #prev_gaps == 0 and #prev_clips == 0 and #prev_edges == 0 then
        return
    end

    data.state.selected_gaps = gaps
    data.state.selected_clips = {}
    data.state.selected_edges = {}
    data.notify_listeners()
end

function M.toggle_gap_selection(gap)
    if not gap then return false end
    local current = data.state.selected_gaps or {}
    if #current == 1 and gaps_equal(current[1], gap) then
        data.state.selected_gaps = {}
        data.notify_listeners()
        return false
    else
        data.state.selected_gaps = {gap}
        data.state.selected_clips = {}
        data.state.selected_edges = {}
        data.notify_listeners()
        return true
    end
end

function M.clear_edge_selection(persist_callback)
    if #data.state.selected_edges > 0 then
        data.state.selected_edges = {}
        normalize_edge_selection()
        data.state.selected_gaps = {}
        data.notify_listeners()
        if persist_callback then persist_callback() end
    end
end

function M.set_on_selection_changed(callback)
    on_selection_changed_callback = callback
    if callback and #data.state.selected_clips > 0 then
        callback(data.state.selected_clips)
    end
end

function M.normalize_edge_selection()
    return normalize_edge_selection()
end

return M
