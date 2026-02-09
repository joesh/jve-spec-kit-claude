--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~350 LOC
-- Volatility: unknown
--
-- @file clip_state.lua
-- Original intent (unreviewed):
-- Timeline Clips State
-- Manages clip storage, indexing, lookup, and mutation application
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local db = require("core.database")

-- All coordinates are now integers. No Rational conversion needed.
-- This function validates and normalizes clip coords from various sources.
local function normalize_clip_integers(clip)
    if not clip then return false end

    -- Handle various field names from database/mutations
    local timeline_start = clip.timeline_start or clip.start_value
    local duration = clip.duration or clip.duration_value

    -- Assert integer types
    if type(timeline_start) ~= "number" then
        clip._invalid = true
        return false
    end
    if type(duration) ~= "number" or duration <= 0 then
        clip._invalid = true
        return false
    end

    -- Normalize field names
    clip.timeline_start = timeline_start
    clip.duration = duration

    -- source_in/source_out must also be integers if present
    if clip.source_in ~= nil then
        assert(type(clip.source_in) == "number",
            "clip_state: source_in must be integer, got " .. type(clip.source_in))
    end
    if clip.source_out ~= nil then
        assert(type(clip.source_out) == "number",
            "clip_state: source_out must be integer, got " .. type(clip.source_out))
    end

    clip._invalid = nil
    return true
end

-- Indices
local clip_lookup = {}
local track_clip_index = {}
local clip_track_positions = {}
local clip_indexes_dirty = true
local state_version = 0
local needs_normalization = true

local function rebuild_clip_indexes()
    clip_lookup = {}
    track_clip_index = {}
    clip_track_positions = {}

    local normalized = {}
    for _, clip in ipairs(data.state.clips) do
        if normalize_clip_integers(clip) and clip.id then
            table.insert(normalized, clip)
            clip_lookup[clip.id] = clip
            if clip.track_id then
                local list = track_clip_index[clip.track_id]
                if not list then
                    list = {}
                    track_clip_index[clip.track_id] = list
                end
                table.insert(list, clip)
            end
        end
    end
    data.state.clips = normalized

    for _, list in pairs(track_clip_index) do
        table.sort(list, function(a, b)
            assert(type(a.timeline_start) == "number",
                "clip_state: clip missing integer timeline_start in sort (id=" .. tostring(a.id) .. ")")
            assert(type(b.timeline_start) == "number",
                "clip_state: clip missing integer timeline_start in sort (id=" .. tostring(b.id) .. ")")
            local a_start = a.timeline_start
            local b_start = b.timeline_start
            if a_start == b_start then
                assert(a.id and b.id, "clip_state: clip missing id in sort")
                return a.id < b.id
            end
            return a_start < b_start
        end)
        for index, clip in ipairs(list) do
            if clip.id then
                clip_track_positions[clip.id] = {list = list, index = index}
            end
        end
    end

    clip_indexes_dirty = false
    needs_normalization = false
end

local function ensure_clip_indexes()
    if needs_normalization or clip_indexes_dirty then
        rebuild_clip_indexes()
    end
end

function M.invalidate_indexes()
    clip_indexes_dirty = true
end

function M.get_all()
    ensure_clip_indexes()
    return data.state.clips
end

function M.get_by_id(clip_id)
    if not clip_id then return nil end
    ensure_clip_indexes()
    return clip_lookup[clip_id]
end

function M.get_for_track(track_id)
    if not track_id then return {} end
    ensure_clip_indexes()
    local list = track_clip_index[track_id]
    if not list then return {} end
    -- Return copy to prevent modification of internal index
    local copy = {}
    for _, c in ipairs(list) do table.insert(copy, c) end
    return copy
end

-- Return the internal sorted clip list for a track (read-only reference).
function M.get_track_clip_index(track_id)
    if not track_id then return nil end
    ensure_clip_indexes()
    return track_clip_index[track_id]
end

-- Return all clips that span the given time (integer frame).
function M.get_at_time(time_value, candidate_clips)
    local clips = candidate_clips or data.state.clips
    if not clips or #clips == 0 then
        return {}
    end

    assert(type(time_value) == "number", "clip_state.get_at_time: time_value must be integer")

    local matches = {}
    for _, clip in ipairs(clips) do
        local start_val = clip.timeline_start or clip.start_value
        local duration_val = clip.duration or clip.duration_value

        if type(start_val) ~= "number" or type(duration_val) ~= "number" or duration_val <= 0 then
            goto continue_clip
        end

        local clip_end = start_val + duration_val
        if time_value > start_val and time_value < clip_end then
            table.insert(matches, clip)
        end
        ::continue_clip::
    end
    return matches
end

function M.locate_neighbor(clip, offset)
    if not clip or not clip.id then return nil end
    ensure_clip_indexes()
    local info = clip_track_positions[clip.id]
    if not info then return nil end
    local neighbor_index = info.index + offset
    if neighbor_index < 1 or neighbor_index > #info.list then return nil end
    return info.list[neighbor_index]
end

--- Return the last frame occupied by any clip on any track.
--- Returns 0 for an empty timeline.
function M.get_content_end_frame()
    local clips = data.state.clips
    if not clips or #clips == 0 then return 0 end

    local max_end = 0
    for _, clip in ipairs(clips) do
        local start_val = clip.timeline_start or clip.start_value
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

function M.hydrate_from_database(clip_id, expected_sequence_id)
    assert(clip_id, "clip_state.hydrate_from_database: clip_id is required")
    assert(db and db.load_clip_entry, "clip_state.hydrate_from_database: database module missing load_clip_entry")
    local clip = db.load_clip_entry(clip_id)
    if not clip then
        error("clip_state.hydrate_from_database: clip not found in database: " .. tostring(clip_id))
    end

    local target_sequence = expected_sequence_id or data.state.sequence_id
    if target_sequence and clip.track_sequence_id and clip.track_sequence_id ~= target_sequence then
        error(string.format("clip_state.hydrate_from_database: clip %s belongs to sequence %s, not %s",
            tostring(clip_id), tostring(clip.track_sequence_id), tostring(target_sequence)))
    end

    normalize_clip_integers(clip)
    clip._version = state_version
    table.insert(data.state.clips, clip)
    needs_normalization = true
    return clip
end

-- Mutation Application Logic
function M.apply_mutations(mutations, persist_callback)
    if not mutations then return false end
    local changed = false
    local deleted_lookup = {}
    local needs_resort = false

    local function apply_bulk_shifts()
        if not mutations.bulk_shifts then
            return
        end
        ensure_clip_indexes()

        for _, shift in ipairs(mutations.bulk_shifts) do
            if type(shift) ~= "table" then
                error("clip_state.apply_mutations: bulk_shift entry must be a table", 2)
            end
            assert(shift.track_id and shift.track_id ~= "", "clip_state.apply_mutations: bulk_shift missing track_id")
            assert(type(shift.shift_frames) == "number", "clip_state.apply_mutations: bulk_shift missing numeric shift_frames")

            local delta_frames = shift.shift_frames
            if delta_frames ~= 0 then
                if type(shift.clip_ids) == "table" then
                    for _, clip_id in ipairs(shift.clip_ids) do
                        local clip = clip_lookup[clip_id] or M.hydrate_from_database(clip_id)
                        if not clip then
                            error("clip_state.apply_mutations: bulk_shift clip missing from state: " .. tostring(clip_id), 2)
                        end
                        if clip.track_id ~= shift.track_id then
                            error("clip_state.apply_mutations: bulk_shift clip track mismatch: " .. tostring(clip_id), 2)
                        end
                        assert(type(clip.timeline_start) == "number",
                            "clip_state.apply_mutations: bulk_shift clip missing integer timeline_start: " .. tostring(clip_id))
                        clip.timeline_start = clip.timeline_start + delta_frames
                        changed = true
                    end
                else
                    if not shift.first_clip_id or shift.first_clip_id == "" then
                        error("clip_state.apply_mutations: bulk_shift missing first_clip_id and clip_ids", 2)
                    end
                    local anchor_start = shift.anchor_start_frame
                    if type(anchor_start) ~= "number" then
                        local anchor = clip_lookup[shift.first_clip_id] or M.hydrate_from_database(shift.first_clip_id)
                        if anchor and anchor.track_id ~= shift.track_id then
                            error("clip_state.apply_mutations: bulk_shift anchor track mismatch", 2)
                        end
                        assert(anchor and type(anchor.timeline_start) == "number",
                            "clip_state.apply_mutations: bulk_shift anchor clip missing integer timeline_start")
                        anchor_start = anchor.timeline_start
                    end

                    local list = track_clip_index[shift.track_id] or {}
                    for _, clip in ipairs(list) do
                        if type(clip.timeline_start) == "number" and clip.timeline_start >= anchor_start then
                            clip.timeline_start = clip.timeline_start + delta_frames
                            changed = true
                        end
                    end
                end
            end
        end
    end
    
    apply_bulk_shifts()

    -- Handle Deletes
    if mutations.deletes then
        for _, clip_id in ipairs(mutations.deletes) do
            for i, clip in ipairs(data.state.clips) do
                if clip.id == clip_id then
                    table.remove(data.state.clips, i)
                    needs_normalization = true
                    deleted_lookup[clip_id] = true
                    changed = true
                    break
                end
            end
            -- Also remove from selection to keep selection consistent with clip list
            if data.state.selected_clips then
                for i = #data.state.selected_clips, 1, -1 do
                    local sel = data.state.selected_clips[i]
                    if sel and sel.id == clip_id then
                        table.remove(data.state.selected_clips, i)
                    end
                end
            end
            if data.state.selected_edges then
                for i = #data.state.selected_edges, 1, -1 do
                    local edge = data.state.selected_edges[i]
                    if edge and edge.clip_id == clip_id then
                        table.remove(data.state.selected_edges, i)
                    end
                end
            end
        end
    end

    -- Handle Updates
    if mutations.updates and #mutations.updates > 0 then
        ensure_clip_indexes()
        for _, update in ipairs(mutations.updates) do
            local clip_id = update.clip_id or update.id
            if clip_id then
                local clip = clip_lookup[clip_id]
                if not clip then
                    clip = M.hydrate_from_database(clip_id, update.track_sequence_id)
                    if clip then needs_resort = true; changed = true end
                end

                if clip then
                    if update.track_id and update.track_id ~= clip.track_id then
                        clip.track_id = update.track_id
                        needs_resort = true; changed = true
                    end
                    -- Apply fps info from update (metadata, not used for coord conversion)
                    if update.fps_numerator and update.fps_denominator then
                        clip.fps_numerator = update.fps_numerator
                        clip.fps_denominator = update.fps_denominator
                    end
                    -- All values are now integers - direct assignment
                    if update.start_value and update.start_value ~= clip.timeline_start then
                        assert(type(update.start_value) == "number",
                            "clip_state.apply_mutations: start_value must be integer")
                        clip.timeline_start = update.start_value
                        needs_resort = true; changed = true
                    end
                    if update.duration_value and update.duration_value ~= clip.duration then
                        assert(type(update.duration_value) == "number",
                            "clip_state.apply_mutations: duration_value must be integer")
                        clip.duration = update.duration_value
                        changed = true
                    end
                    if update.source_in_value and update.source_in_value ~= clip.source_in then
                        assert(type(update.source_in_value) == "number",
                            "clip_state.apply_mutations: source_in_value must be integer")
                        clip.source_in = update.source_in_value
                        changed = true
                    end
                    if update.source_out_value and update.source_out_value ~= clip.source_out then
                        assert(type(update.source_out_value) == "number",
                            "clip_state.apply_mutations: source_out_value must be integer")
                        clip.source_out = update.source_out_value
                        changed = true
                    end
                    if update.enabled ~= nil and update.enabled ~= clip.enabled then
                        clip.enabled = update.enabled and true or false
                        changed = true
                    end
                elseif not deleted_lookup[clip_id] then
                    -- Record failure
                    -- missing clip; ignore (caller may hydrate later)
                    return false
                end
            end
        end
        if needs_resort then M.invalidate_indexes() end
    end

    -- Handle Inserts
    if mutations.inserts then
        for _, clip in ipairs(mutations.inserts) do
            if normalize_clip_integers(clip) then
                table.insert(data.state.clips, clip)
                changed = true
            end
        end
        M.invalidate_indexes()
    end

    if changed then
        state_version = state_version + 1
        for _, clip in ipairs(data.state.clips) do clip._version = state_version end
        if persist_callback then persist_callback() end
        data.notify_listeners()
    end
    return changed
end

function M.get_version() return state_version end
function M.inc_version() state_version = state_version + 1 end

return M
