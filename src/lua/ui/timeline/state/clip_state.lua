-- Timeline Clips State
-- Manages clip storage, indexing, lookup, and mutation application

local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local db = require("core.database")
local Rational = require("core.rational")
local profile_scope = require("core.profile_scope")

-- Indices
local clip_lookup = {}
local track_clip_index = {}
local clip_track_positions = {}
local clip_indexes_dirty = true
local state_version = 0

local function rebuild_clip_indexes()
    clip_lookup = {}
    track_clip_index = {}
    clip_track_positions = {}

    for _, clip in ipairs(data.state.clips) do
        if clip.id then
            clip_lookup[clip.id] = clip
        end
        if clip.track_id then
            local list = track_clip_index[clip.track_id]
            if not list then
                list = {}
                track_clip_index[clip.track_id] = list
            end
            table.insert(list, clip)
        end
    end

    for _, list in pairs(track_clip_index) do
        table.sort(list, function(a, b)
            local a_start = a.timeline_start.frames or 0
            local b_start = b.timeline_start.frames or 0
            if a_start == b_start then
                return (a.id or "") < (b.id or "")
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
end

local function ensure_clip_indexes()
    if clip_indexes_dirty then
        rebuild_clip_indexes()
    end
end

function M.invalidate_indexes()
    clip_indexes_dirty = true
end

function M.get_all()
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

function M.locate_neighbor(clip, offset)
    if not clip or not clip.id then return nil end
    ensure_clip_indexes()
    local info = clip_track_positions[clip.id]
    if not info then return nil end
    local neighbor_index = info.index + offset
    if neighbor_index < 1 or neighbor_index > #info.list then return nil end
    return info.list[neighbor_index]
end

function M.hydrate_from_database(clip_id, expected_sequence_id)
    if not clip_id or not db or not db.load_clip_entry then return nil end
    local ok, clip = pcall(db.load_clip_entry, clip_id)
    if not ok or not clip then return nil end

    local target_sequence = expected_sequence_id or data.state.sequence_id
    if target_sequence and clip.track_sequence_id and clip.track_sequence_id ~= target_sequence then
        return nil
    end

    clip._version = state_version
    table.insert(data.state.clips, clip)
    M.invalidate_indexes()
    return clip
end

-- Mutation Application Logic
local last_mutation_failure = nil

function M.apply_mutations(mutations, persist_callback)
    if not mutations then return false end
    local changed = false
    local deleted_lookup = {}
    
    -- Handle Deletes
    if mutations.deletes then
        for _, clip_id in ipairs(mutations.deletes) do
            for i, clip in ipairs(data.state.clips) do
                if clip.id == clip_id then
                    table.remove(data.state.clips, i)
                    M.invalidate_indexes()
                    deleted_lookup[clip_id] = true
                    changed = true
                    break
                end
            end
        end
    end

    -- Handle Updates
    if mutations.updates and #mutations.updates > 0 then
        ensure_clip_indexes()
        local needs_resort = false
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
                    local fps = data.state.sequence_frame_rate
                    if update.start_value and update.start_value ~= clip.timeline_start.frames then
                        clip.timeline_start = Rational.new(update.start_value, fps.fps_numerator, fps.fps_denominator)
                        needs_resort = true; changed = true
                    end
                    if update.duration_value and update.duration_value ~= clip.duration.frames then
                        clip.duration = Rational.new(update.duration_value, fps.fps_numerator, fps.fps_denominator)
                        changed = true
                    end
                    if update.source_in_value and update.source_in_value ~= clip.source_in.frames then
                        clip.source_in = Rational.new(update.source_in_value, fps.fps_numerator, fps.fps_denominator)
                        changed = true
                    end
                    if update.source_out_value and update.source_out_value ~= clip.source_out.frames then
                        clip.source_out = Rational.new(update.source_out_value, fps.fps_numerator, fps.fps_denominator)
                        changed = true
                    end
                    if update.enabled ~= nil and update.enabled ~= clip.enabled then
                        clip.enabled = update.enabled and true or false
                        changed = true
                    end
                elseif not deleted_lookup[clip_id] then
                    -- Record failure
                    last_mutation_failure = {kind="missing_clip", clip_id=clip_id}
                    return false
                end
            end
        end
        if needs_resort then M.invalidate_indexes() end
    end

    -- Handle Inserts
    if mutations.inserts then
        for _, clip in ipairs(mutations.inserts) do
            table.insert(data.state.clips, clip)
            changed = true
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
