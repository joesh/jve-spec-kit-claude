--- ExtendEdit command — extends selected edge(s) to meet the playhead.
--
-- Takes selected edges and computes delta to reach playhead, then delegates
-- to RippleEdit/BatchRippleEdit. Honors trim_type (ripple vs roll).
--
-- This is a "nudge to playhead" for edges - the delta is computed automatically
-- based on edge position and playhead position.
--
-- @file extend_edit.lua
local M = {}
local database = require("core.database")

local SPEC = {
    args = {
        edge_infos = { required = true },      -- array of {clip_id, edge_type, track_id, trim_type}
        playhead_frame = { required = true },  -- target frame (int)
        project_id = { required = true },
        sequence_id = { required = true },
    },
    persisted = {},  -- Delegates to RippleEdit/BatchRippleEdit for undo
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["ExtendEdit"] = function(command)
        local args = command:get_all_parameters()
        local logger = require("core.logger")
        local command_manager = require("core.command_manager")
        local Clip = require("models.clip")

        local edge_infos = args.edge_infos
        assert(type(edge_infos) == "table" and #edge_infos > 0,
            "ExtendEdit: edge_infos must be non-empty array")

        local playhead = args.playhead_frame
        assert(type(playhead) == "number", "ExtendEdit: playhead_frame must be integer")

        logger.info("extend_edit", string.format("ExtendEdit edges=%d playhead=%d", #edge_infos, playhead))

        -- Compute delta for each edge to reach playhead
        -- For simplicity, use lead edge (first edge) to compute single delta
        -- (multi-edge extend with different deltas would need BatchRippleEdit enhancement)
        local lead_edge = edge_infos[1]
        local clip = Clip.load(lead_edge.clip_id)
        if not clip then
            set_last_error(string.format("ExtendEdit: clip not found: %s", lead_edge.clip_id))
            return false
        end

        -- Compute current edge position
        local edge_position
        if lead_edge.edge_type == "in" or lead_edge.edge_type == "gap_before" then
            edge_position = clip.timeline_start
        elseif lead_edge.edge_type == "out" or lead_edge.edge_type == "gap_after" then
            edge_position = clip.timeline_start + clip.duration
        else
            set_last_error(string.format("ExtendEdit: unknown edge_type: %s", tostring(lead_edge.edge_type)))
            return false
        end

        -- Delta = how much to move edge to reach playhead
        -- Positive delta moves edge right, negative moves left
        local delta_frames = playhead - edge_position

        if delta_frames == 0 then
            logger.info("extend_edit", "ExtendEdit: edge already at playhead, no-op")
            return true
        end

        logger.info("extend_edit", string.format("ExtendEdit: edge at %d, playhead at %d, delta=%d",
            edge_position, playhead, delta_frames))

        -- Delegate to RippleEdit/BatchRippleEdit
        local result
        if #edge_infos > 1 then
            result = command_manager.execute("BatchRippleEdit", {
                edge_infos = edge_infos,
                delta_frames = delta_frames,
                sequence_id = args.sequence_id,
                project_id = args.project_id,
            })
        else
            result = command_manager.execute("RippleEdit", {
                edge_info = edge_infos[1],
                delta_frames = delta_frames,
                sequence_id = args.sequence_id,
                project_id = args.project_id,
            })
        end

        if not result or not result.success then
            local msg = result and result.error_message or "RippleEdit/BatchRippleEdit failed"
            set_last_error("ExtendEdit: " .. msg)
            return false
        end

        logger.info("extend_edit", string.format("ExtendEdit: completed, delta=%d frames", delta_frames))
        return true
    end

    -- Undo is handled by the nested RippleEdit/BatchRippleEdit command
    command_undoers["ExtendEdit"] = function(command)
        -- Nested commands handle their own undo via command_manager
        return true
    end

    return {
        executor = command_executors["ExtendEdit"],
        undoer = command_undoers["ExtendEdit"],
        spec = SPEC,
    }
end

return M
