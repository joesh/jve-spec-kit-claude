--- Clip state: in-memory clip collection for the active sequence.
--- Owns the clips list stored in timeline_state_data, plus per-track
--- clip-index caches for O(log n) lookup. apply_mutations consumes
--- the `__timeline_mutations` payload emitted by commands and patches
--- the in-memory cache in lock-step with the DB, avoiding a full
--- reload_clips on every edit. Gap clips are derived state —
--- recomputed by timeline_core_state, not stored in this module's
--- authoritative list.
---
--- @file clip_state.lua
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local db = require("core.database")
local log = require("core.logger").for_area("timeline")
local strip_holder = require("ui.timeline.state.strip_holder")

-- Spec 022 Phase 1.3f: public read getters delegate to the displayed tab's
-- cache + per-tab indexes. The displayed tab is the authoritative model
-- for "what clips does the timeline view show?" (rule 3.0 MVC). The local
-- `clip_lookup`/`track_clip_index`/`clip_track_positions` indexes below
-- still serve the legacy apply_mutations + snapshot/rollback paths (1.3f
-- step 3/4 migrate those). data.state.clips remains aliased to displayed
-- tab cache.clips by sync_displayed_tab_from_data_state until step 6
-- deletes the field entirely.
local function displayed_tab()
    local strip = strip_holder.get()
    if not strip then return nil end
    return strip:get_displayed()
end

-- Mutation transaction stack: snapshot in-memory clip state for undo group rollback.
-- Parallels the DB savepoint mechanism — begin/commit/rollback.
local mutation_snapshot_stack = {}

-- All coordinates are now integers. No Rational conversion needed.
-- This function validates and normalizes clip coords from various sources.
local function normalize_clip_integers(clip)
    if not clip then return false end

    -- Handle various field names from database/mutations
    local sequence_start = clip.sequence_start or clip.start_value
    local duration = clip.duration or clip.duration_value

    -- Assert integer types
    if type(sequence_start) ~= "number" then
        clip._invalid = true
        return false
    end
    if type(duration) ~= "number" or duration <= 0 then
        clip._invalid = true
        return false
    end

    -- Normalize field names
    clip.sequence_start = sequence_start
    clip.duration = duration

    -- source_in/source_out: alias _value variants from mutations
    if clip.source_in == nil and clip.source_in_value ~= nil then
        clip.source_in = clip.source_in_value
    end
    if clip.source_out == nil and clip.source_out_value ~= nil then
        clip.source_out = clip.source_out_value
    end

    -- source_in/source_out must be integers if present
    if clip.source_in ~= nil then
        assert(type(clip.source_in) == "number",
            "clip_state: source_in must be integer, got " .. type(clip.source_in))
    end
    if clip.source_out ~= nil then
        assert(type(clip.source_out) == "number",
            "clip_state: source_out must be integer, got " .. type(clip.source_out))
    end

    -- frame_rate is single-shape (table form only) per the rename, but it
    -- is NOT required by clip_state itself — this function only validates
    -- integer coords. Consumers that actually need fps (source-mark math,
    -- ripple delta conversion, undo) assert frame_rate at the point of
    -- use (clip_mutator.get_row_fps, command_helper.require_rate).

    clip._invalid = nil
    return true
end

-- Module-level mutation counter. Bumped by timeline_state.apply_mutations
-- after every change so consumers holding per-clip `_version` can detect
-- staleness via validate_clip_fresh. Snapshot/rollback also bump it.
local state_version = 0

-- Spec 022 Phase 1.3f: invalidate the DISPLAYED tab's indexes. The
-- legacy module-level clip_lookup / track_clip_index / clip_indexes_dirty
-- variables are gone — public getters delegate to the tab's own indexes
-- (1.3f step 2). Snapshot/rollback callers also invoke this to mark the
-- displayed tab's index stale after they swap data.state.clips back to
-- a restored snapshot.
function M.invalidate_indexes()
    local tab = displayed_tab()
    if tab then tab:invalidate_indexes() end
end

function M.get_all()
    local tab = displayed_tab()
    if not tab then return {} end
    return tab.cache.clips
end

function M.get_by_id(clip_id)
    if not clip_id then return nil end
    local tab = displayed_tab()
    if not tab then return nil end
    return tab:get_clip_by_id(clip_id)
end

function M.get_for_track(track_id)
    if not track_id then return {} end
    local tab = displayed_tab()
    if not tab then return {} end
    local list = tab:get_track_clip_index(track_id)
    if not list then return {} end
    -- Return copy to prevent modification of internal index
    local copy = {}
    for _, c in ipairs(list) do table.insert(copy, c) end
    return copy
end

-- Return the internal sorted clip list for a track (read-only reference).
function M.get_track_clip_index(track_id)
    if not track_id then return nil end
    local tab = displayed_tab()
    if not tab then return nil end
    return tab:get_track_clip_index(track_id)
end

-- Return all clips that span the given time (integer frame).
function M.get_at_time(time_value, candidate_clips)
    local clips
    if candidate_clips then
        clips = candidate_clips
    else
        local tab = displayed_tab()
        clips = tab and tab.cache.clips or nil
    end
    if not clips or #clips == 0 then
        return {}
    end

    assert(type(time_value) == "number", "clip_state.get_at_time: time_value must be integer")

    local matches = {}
    for _, clip in ipairs(clips) do
        local start_val = clip.sequence_start or clip.start_value
        local duration_val = clip.duration or clip.duration_value

        if type(start_val) ~= "number" or type(duration_val) ~= "number" or duration_val <= 0 then
            goto continue_clip
        end

        -- Skip gap clips — callers need media clips under playhead
        if clip.is_gap then
            goto continue_clip
        end

        -- Half-open [start, start+duration): clip owns its IN edge (first
        -- frame), the next clip / empty space owns the OUT boundary. NLE
        -- convention — also avoids two clips claiming the same boundary
        -- frame at edits.
        local clip_end = start_val + duration_val
        if time_value >= start_val and time_value < clip_end then
            table.insert(matches, clip)
        end
        ::continue_clip::
    end
    return matches
end

function M.locate_neighbor(clip, offset)
    if not clip or not clip.id then return nil end
    local tab = displayed_tab()
    if not tab then return nil end
    return tab:locate_neighbor(clip, offset)
end

--- Return the last frame occupied by any clip on any track.
--- Returns 0 for an empty timeline.
function M.get_content_end_frame()
    local tab = displayed_tab()
    local clips = tab and tab.cache.clips or nil
    if not clips or #clips == 0 then return 0 end

    local max_end = 0
    for _, clip in ipairs(clips) do
        local start_val = clip.sequence_start or clip.start_value
        local duration_val = clip.duration or clip.duration_value
        if type(start_val) == "number" and type(duration_val) == "number" then
            local clip_end = start_val + duration_val
            if clip_end > max_end then
                max_end = clip_end
            end
        end
    end
    return max_end
end

-- Spec 022 Phase 1.3f: hydrate a clip from SQL into a specific tab's cache.
-- Used by timeline_state.apply_mutations when an update references a clip
-- the tab cache hasn't seen yet (test fixtures pre-populating SQL; legacy
-- callsites that mutate without first hydrating). Preserves the same
-- assert-loud contract as hydrate_from_database.
function M.hydrate_into_tab(tab, clip_id, expected_sequence_id)
    assert(tab, "clip_state.hydrate_into_tab: tab required")
    assert(clip_id, "clip_state.hydrate_into_tab: clip_id required")
    local clip = db.load_clip_entry(clip_id)
    if not clip then
        error("clip_state.hydrate_into_tab: clip not found in database: " .. tostring(clip_id))
    end
    local target_sequence = expected_sequence_id or tab.sequence_id
    if target_sequence and clip.track_sequence_id and clip.track_sequence_id ~= target_sequence then
        error(string.format(
            "clip_state.hydrate_into_tab: clip %s belongs to sequence %s, not %s",
            tostring(clip_id), tostring(clip.track_sequence_id), tostring(target_sequence)))
    end
    normalize_clip_integers(clip)
    clip._version = state_version
    table.insert(tab.cache.clips, clip)
    tab:invalidate_indexes()
    return clip
end

-- Spec 022 Phase 1.3f: M.apply_mutations DELETED. timeline_state.apply_mutations
-- now orchestrates the full edit cycle (hydration + selection cleanup +
-- per-tab mutation via TimelineTab:apply_mutations + gap recompute +
-- version stamping + signal). The mutation engine lives on the tab.

function M.get_version() return state_version end
function M.inc_version() state_version = state_version + 1 end

--- Whether any mutation snapshot is currently active on the stack.
-- Used by command_manager.rollback_mutations to skip no-op rollbacks for
-- commands that declared skip_clip_snapshot — they never pushed a snapshot,
-- so there's nothing to pop.
function M.has_active_mutation_snapshot()
    return #mutation_snapshot_stack > 0
end

--- Snapshot current clip + selection state. Called by begin_undo_group.
function M.begin_mutation_transaction()
    -- Shallow-clone each clip table (mutations modify fields in-place)
    local clips_copy = {}
    for i, clip in ipairs(data.state.clips) do
        local copy = {}
        for k, v in pairs(clip) do copy[k] = v end
        clips_copy[i] = copy
    end

    -- Store selection as IDs (clip objects will be different after restore)
    local selected_clip_ids = {}
    for _, clip in ipairs(data.state.selected_clips or {}) do
        table.insert(selected_clip_ids, clip.id)
    end

    -- Shallow-clone edge and gap selection (small tables, own data)
    local edges_copy = {}
    for i, edge in ipairs(data.state.selected_edges or {}) do
        edges_copy[i] = {
            clip_id = edge.clip_id,
            edge_type = edge.edge_type,
            trim_type = edge.trim_type,
            track_id = edge.track_id,
        }
    end

    local gaps_copy = {}
    for i, gap in ipairs(data.state.selected_gaps or {}) do
        local g = {}
        for k, v in pairs(gap) do g[k] = v end
        gaps_copy[i] = g
    end

    table.insert(mutation_snapshot_stack, {
        clips = clips_copy,
        selected_clip_ids = selected_clip_ids,
        selected_edges = edges_copy,
        selected_gaps = gaps_copy,
    })
end

--- Discard snapshot on successful undo group completion.
function M.commit_mutation_transaction()
    assert(#mutation_snapshot_stack > 0,
        "clip_state.commit_mutation_transaction: no matching begin (stack empty)")
    table.remove(mutation_snapshot_stack)
end

--- Restore clip + selection state from snapshot. Called by rollback_transaction.
function M.rollback_mutation_transaction()
    assert(#mutation_snapshot_stack > 0,
        "clip_state.rollback_mutation_transaction: no matching begin (stack empty)")

    local snapshot = table.remove(mutation_snapshot_stack)

    data.set_clips(snapshot.clips)

    -- Rebuild selected_clips from IDs against restored clip objects
    local id_lookup = {}
    for _, clip in ipairs(snapshot.clips) do
        id_lookup[clip.id] = clip
    end
    local restored_selection = {}
    for _, id in ipairs(snapshot.selected_clip_ids) do
        if id_lookup[id] then
            table.insert(restored_selection, id_lookup[id])
        end
    end
    data.state.selected_clips = restored_selection
    data.state.selected_edges = snapshot.selected_edges
    data.state.selected_gaps = snapshot.selected_gaps

    M.invalidate_indexes()
    state_version = state_version + 1
    for _, clip in ipairs(data.state.clips) do clip._version = state_version end
    -- Spec 022 Phase 1.3b: facade reads come from displayed_tab.cache;
    -- rollback rewrites data.state.clips out-of-band so the displayed
    -- tab must be re-pointed at the restored array. Lazy require avoids
    -- a circular dep with timeline_core_state (which requires clip_state).
    local core_state = require("ui.timeline.state.timeline_core_state")
    core_state.sync_displayed_tab_from_data_state()
    data.notify_listeners()
    log.event("rollback_mutation_transaction: restored %d clips", #snapshot.clips)
end

return M
