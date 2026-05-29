--- Clip state facade: read accessors + snapshot/rollback wrappers that
--- delegate to the displayed (reads) or active record (snapshot) tab.
--- Per-tab cache.clips is authoritative; gap clips are derived state
--- recomputed by timeline_core_state.
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local db = require("core.database")
local log = require("core.logger").for_area("timeline")
local strip_holder = require("ui.timeline.state.strip_holder")
local clip_geometry = require("ui.timeline.clip_geometry")

-- Public read getters delegate to the displayed tab's per-tab cache —
-- the authoritative model for "what clips does the timeline view show?"
-- (rule 3.0 MVC). Returns nil for all blank-display states: no strip yet,
-- strip with zero tabs, OR strip with tabs but no displayed pointer
-- (legitimate transient state during clear_displayed / close_displayed_tab).
local function displayed_tab()
    local strip = strip_holder.get()
    if not strip then return nil end
    return strip:get_displayed()
end

-- Module-level mutation counter. Bumped by timeline_state.apply_mutations
-- after every change so consumers holding per-clip `_version` can detect
-- staleness via validate_clip_fresh. Snapshot/rollback also bump it.
local state_version = 0

-- Invalidate the displayed tab's clip indexes — next index getter rebuilds.
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
        -- Skip gap clips — callers need media clips under playhead
        if not clip.is_gap then
            assert(type(clip.sequence_start) == "number",
                "clip_state.get_at_time: clip missing sequence_start (clip_id=" .. tostring(clip.id) .. ")")
            assert(type(clip.duration) == "number" and clip.duration > 0,
                "clip_state.get_at_time: clip missing positive duration (clip_id=" .. tostring(clip.id) .. ")")
            -- Half-open [start, start+duration): clip owns its IN edge (first
            -- frame), the next clip / empty space owns the OUT boundary. NLE
            -- convention — also avoids two clips claiming the same boundary
            -- frame at edits.
            local clip_end = clip.sequence_start + clip.duration
            if time_value >= clip.sequence_start and time_value < clip_end then
                table.insert(matches, clip)
            end
        end
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
        assert(type(clip.sequence_start) == "number",
            "clip_state.get_content_end_frame: clip missing sequence_start (clip_id=" .. tostring(clip.id) .. ")")
        assert(type(clip.duration) == "number",
            "clip_state.get_content_end_frame: clip missing duration (clip_id=" .. tostring(clip.id) .. ")")
        local clip_end = clip.sequence_start + clip.duration
        if clip_end > max_end then
            max_end = clip_end
        end
    end
    return max_end
end

-- Hydrate a clip from SQL into the given tab's cache. Asserts on
-- missing clip or sequence-id mismatch (no silent skip).
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
    clip_geometry.normalize_clip_integers(clip)
    clip._version = state_version
    table.insert(tab.cache.clips, clip)
    tab:invalidate_indexes()
    return clip
end

function M.get_version() return state_version end
function M.inc_version() state_version = state_version + 1 end

-- Snapshot/rollback always target the active record tab (the edit target),
-- which can differ from the displayed tab when a source is shown. Returns
-- nil for blank-project / pre-init states.
local function active_record_tab()
    local strip = strip_holder.get()
    if not strip then return nil end
    return strip:get_active_record()
end

-- Mutation transaction stack — global, cross-tab. Each frame binds the tab
-- the active edit-target pointed to at begin time (or nil) so commit/rollback
-- target THAT tab even if the active record changes within the group — e.g. a
-- blank-timeline drop creates the edit-target sequence mid-group, so the tab is
-- nil at begin but non-nil by commit. Re-resolving the tab at commit would
-- otherwise commit a snapshot on a tab that never saw a begin. The frame also
-- carries the global selection snapshot (the cross-tab concern the per-tab
-- module deliberately stays out of).
local mutation_transaction_stack = {}

--- Whether a mutation transaction frame is currently open.
-- Used by command_manager.rollback_mutations to skip no-op rollbacks for
-- commands that declared skip_clip_snapshot — they never pushed a frame,
-- so there's nothing to pop.
function M.has_active_mutation_snapshot()
    return #mutation_transaction_stack > 0
end

local function snapshot_global_selection()
    local clip_ids = {}
    for _, clip in ipairs(data.state.selected_clips or {}) do
        table.insert(clip_ids, clip.id)
    end
    local edges = {}
    for i, edge in ipairs(data.state.selected_edges or {}) do
        edges[i] = {
            clip_id = edge.clip_id, edge_type = edge.edge_type,
            trim_type = edge.trim_type, track_id = edge.track_id,
        }
    end
    local gaps = {}
    for i, gap in ipairs(data.state.selected_gaps or {}) do
        local g = {}
        for k, v in pairs(gap) do g[k] = v end
        gaps[i] = g
    end
    return { clip_ids = clip_ids, edges = edges, gaps = gaps }
end

local function restore_global_selection(snap, restored_clips)
    local id_lookup = {}
    for _, clip in ipairs(restored_clips) do id_lookup[clip.id] = clip end
    local restored = {}
    for _, id in ipairs(snap.clip_ids) do
        if id_lookup[id] then table.insert(restored, id_lookup[id]) end
    end
    data.state.selected_clips = restored
    data.state.selected_edges = snap.edges
    data.state.selected_gaps = snap.gaps
end

--- Snapshot current clip cache + global selection at the active record tab.
--- Always pushes a frame so begin/commit/rollback stay balanced even when
--- there is no active record tab at begin time — the frame records that tab
--- (possibly nil) so commit/rollback target it, not whatever the active
--- record happens to be later. nil-tab frames are the unit-test case (no
--- timeline bootstrap) and the blank-timeline-drop case (edit-target created
--- mid-group): both skip the per-tab snapshot in lockstep.
function M.begin_mutation_transaction()
    local tab = active_record_tab()
    if tab then tab:begin_mutation_transaction() end
    table.insert(mutation_transaction_stack,
        { tab = tab, selection = snapshot_global_selection() })
end

--- Discard snapshot on successful undo group completion.
function M.commit_mutation_transaction()
    assert(#mutation_transaction_stack > 0,
        "clip_state.commit_mutation_transaction: transaction stack empty (paired begin missing)")
    local frame = table.remove(mutation_transaction_stack)
    if frame.tab then frame.tab:commit_mutation_transaction() end
end

--- Restore clip cache + global selection from the snapshot.
function M.rollback_mutation_transaction()
    assert(#mutation_transaction_stack > 0,
        "clip_state.rollback_mutation_transaction: transaction stack empty (paired begin missing)")
    local frame = table.remove(mutation_transaction_stack)
    local tab = frame.tab
    if not tab then return end
    local restored_clips = tab:rollback_mutation_transaction()
    restore_global_selection(frame.selection, restored_clips)
    state_version = state_version + 1
    local v = state_version
    for _, c in ipairs(tab.cache.clips) do c._version = v end
    data.notify_listeners()
    log.event("rollback_mutation_transaction: restored %d clips on tab %s",
        #tab.cache.clips, tostring(tab.sequence_id))
end

return M
