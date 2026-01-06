--- Timeline editing operations
--
-- Provides editor-level API for timeline modifications.
-- Encapsulates all command-system ceremony (Command.create, set_parameter, execute).
--
-- @file timeline_ops.lua
local M = {}

local uuid_module            = require("uuid")
local command_module         = require("command")
local command_manager_module = require("core.command_manager")

--------------------------------------------------------------------------------
-- Add clip to timeline track (Insert or Overwrite mode)
--
-- Parameters:
--   mode: "Insert" or "Overwrite"
--   track_id: Target track ID
--   position: Timeline position (timecode)
--   sequence_id: Which sequence we're editing
--   clip_source: Table with master_clip_id, media_id, duration, source_in/out,
--                clip_name, advance_playhead, project_id
--   channel: Audio channel number (0, 1, 2...) or nil for video
--
-- Returns: clip_id of created timeline clip
--------------------------------------------------------------------------------
function M.add_clip_to_track(mode, track_id, position, sequence_id, clip_source, channel)
    assert(mode == "Insert" or mode == "Overwrite",
        "timeline_ops.add_clip_to_track: mode must be Insert or Overwrite, got: " .. tostring(mode))

    local clip_id = uuid_module.generate()
    local time_param = (mode == "Overwrite") and "overwrite_time" or "insert_time"

    -- Build and execute Insert/Overwrite command
    local cmd = command_module.create(mode, clip_source.project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", clip_source.master_clip_id)
    cmd:set_parameter("duration", clip_source.duration)
    cmd:set_parameter("source_in", clip_source.source_in)
    cmd:set_parameter("source_out", clip_source.source_out)
    cmd:set_parameter("project_id", clip_source.project_id)
    cmd:set_parameter("clip_id", clip_id)
    cmd:set_parameter(time_param, position)

    if clip_source.media_id then cmd:set_parameter("media_id", clip_source.media_id) end
    if clip_source.clip_name then cmd:set_parameter("clip_name", clip_source.clip_name) end
    if clip_source.advance_playhead then cmd:set_parameter("advance_playhead", true) end
    if channel ~= nil then cmd:set_parameter("channel", channel) end

    local result = command_manager_module.execute(cmd)
    if not (result and result.success) then
        error(string.format("timeline_ops.add_clip_to_track: %s failed: %s",
            mode, result and result.error_message or "unknown error"))
    end

    return clip_id
end

--------------------------------------------------------------------------------
-- Link multiple clips together (for A/V sync)
--
-- Parameters:
--   clip_infos: Array of {clip_id, role, time_offset} tables
--   project_id: Database project scope
--
-- Links clips so they move/trim/delete together (professional NLE behavior)
--------------------------------------------------------------------------------
function M.link_clips(clip_infos, project_id)
    if #clip_infos <= 1 then
        return -- Nothing to link
    end

    local cmd = command_module.create("LinkClips", project_id)
    cmd:set_parameter("clips", clip_infos)

    local result = command_manager_module.execute(cmd)
    if not (result and result.success) then
        error(string.format("timeline_ops.link_clips: failed: %s",
            result and result.error_message or "unknown error"))
    end
end

return M
