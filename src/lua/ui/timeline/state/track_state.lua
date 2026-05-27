--- Timeline Tracks State
-- Manages track list, layout, and properties.
--
-- Spec 022 Phase 1.3f: reads pull live from the displayed tab's cache via
-- the strip. Module-level state shrinks to "is layout dirty" — the track
-- list itself lives on the tab (rule 3.0 MVC: views pull from model).
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local strip_holder = require("ui.timeline.state.strip_holder")

local track_layout_dirty = false

-- Live read of the displayed tab's track list. Empty when no tab is
-- displayed (project-blank or post-clear). NEVER nil — callers iterate
-- without nil-guards.
local function displayed_tracks()
    local strip = strip_holder.get()
    if not strip then return {} end
    local displayed = strip:get_displayed()
    if not displayed then return {} end
    return displayed.cache.tracks
end

function M.get_all()
    return displayed_tracks()
end

function M.get_video_tracks()
    local result = {}
    for _, track in ipairs(displayed_tracks()) do
        if track.track_type == "VIDEO" then table.insert(result, track) end
    end
    return result
end

function M.get_audio_tracks()
    local result = {}
    for _, track in ipairs(displayed_tracks()) do
        if track.track_type == "AUDIO" then table.insert(result, track) end
    end
    return result
end

-- Find a track row by id; raise with `caller` in the message when absent.
-- Centralises the assert-on-unknown-track contract (rule 2.5).
local function require_track(track_id, caller)
    assert(type(track_id) == "string" and track_id ~= "",
        caller .. ": track_id required")
    for _, track in ipairs(displayed_tracks()) do
        if track.id == track_id then return track end
    end
    error(string.format(
        "%s: track %s not in state — caller is referencing a track that "
        .. "does not exist on the displayed sequence", caller, track_id))
end

function M.get_height(track_id)
    local track = require_track(track_id, "track_state.get_height")
    -- track.height nil = "exists but never resized" → DEFAULT is the
    -- correct semantic; UNKNOWN track already raised in require_track.
    return track.height or data.dimensions.default_track_height
end

function M.set_height(track_id, height, persist_callback)
    local track = require_track(track_id, "track_state.set_height")
    assert(type(height) == "number", string.format(
        "track_state.set_height: height must be number (track=%s), got %s",
        track_id, type(height)))
    if track.height == height then return end
    track.height = height
    track_layout_dirty = true
    data.notify_listeners()
    if persist_callback then persist_callback(true) end -- force persist layout
end

function M.is_layout_dirty() return track_layout_dirty end
function M.clear_layout_dirty() track_layout_dirty = false end

function M.get_primary_id(track_type)
    local type_upper = track_type:upper()
    for _, track in ipairs(displayed_tracks()) do
        if track.track_type == type_upper then return track.id end
    end
    return nil
end

function M.get_by_id(track_id)
    if not track_id then return nil end
    for _, track in ipairs(displayed_tracks()) do
        if track.id == track_id then
            return track
        end
    end
    return nil
end

--- Get whether waveform display is enabled for a track.
--- Audio tracks default to true; video tracks always return false.
function M.get_waveform_enabled(track_id)
    local track = M.get_by_id(track_id)
    if not track then return false end
    if track.track_type ~= "AUDIO" then return false end
    if track.waveform_enabled == nil then return true end
    return track.waveform_enabled
end

--- Set waveform display enabled state for a track. Notifies listeners.
function M.set_waveform_enabled(track_id, enabled)
    local track = M.get_by_id(track_id)
    assert(track, "track_state.set_waveform_enabled: track not found: " .. tostring(track_id))
    assert(track.track_type == "AUDIO",
        "track_state.set_waveform_enabled: only audio tracks have waveform toggle")
    track.waveform_enabled = enabled
    data.notify_listeners()
end

return M
