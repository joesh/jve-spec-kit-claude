--- Clip state facade: read accessors + snapshot/rollback wrappers that
--- delegate to the displayed (reads) or active record (snapshot) tab.
--- Per-tab cache.clips is authoritative; gap clips are derived state
--- recomputed by timeline_core_state.
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local db = require("core.database")
local log = require("core.logger").for_area("timeline")
local strip_holder = require("ui.timeline.state.strip_holder")

-- Public read getters delegate to the displayed tab's per-tab cache —
-- the authoritative model for "what clips does the timeline view show?"
-- (rule 3.0 MVC).
local function displayed_tab()
    local strip = strip_holder.get()
    if not strip then return nil end
    return strip:get_displayed()
end

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
    normalize_clip_integers(clip)
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

--- Whether any mutation snapshot is currently active on the active tab.
-- Used by command_manager.rollback_mutations to skip no-op rollbacks for
-- commands that declared skip_clip_snapshot — they never pushed a snapshot,
-- so there's nothing to pop.
function M.has_active_mutation_snapshot()
    local tab = active_record_tab()
    if not tab then return false end
    return tab:has_active_mutation_snapshot()
end

--- Snapshot current clip + selection state on the active record tab.
--- No-op when there is no active record tab (e.g. unit tests that
--- exercise command_manager without bootstrapping a timeline). Matches
--- the strip's "blank panel returns empty" convention — no tab means
--- nothing to snapshot, and commit/rollback in that state are also no-ops.
function M.begin_mutation_transaction()
    local tab = active_record_tab()
    if not tab then return end
    tab:begin_mutation_transaction()
end

--- Discard snapshot on successful undo group completion.
function M.commit_mutation_transaction()
    local tab = active_record_tab()
    if not tab then return end
    tab:commit_mutation_transaction()
end

--- Restore clip + selection state from snapshot on the active record tab.
function M.rollback_mutation_transaction()
    local tab = active_record_tab()
    if not tab then return end
    tab:rollback_mutation_transaction()
    state_version = state_version + 1
    local v = state_version
    for _, c in ipairs(tab.cache.clips) do c._version = v end
    data.notify_listeners()
    log.event("rollback_mutation_transaction: restored %d clips on tab %s",
        #tab.cache.clips, tostring(tab.sequence_id))
end

return M
