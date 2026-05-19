-- RippleTrimEdge: trim a single clip edge with ripple propagation.
--
-- Thin wrapper around BatchRippleEdit for the common single-edge case.
-- Maps (clip_id, edge, delta_frames) → edge_infos and delegates.
-- Undo is handled entirely by the nested BatchRippleEdit undo entry.

local M = {}

local SPEC = {
    args = {
        clip_id      = { required = true,  kind = "string" },
        edge         = { required = true,  kind = "string" },  -- "left" or "right"
        delta_frames = { required = true,  kind = "number" },
        sequence_id  = { required = true,  kind = "string" },
        project_id   = { required = true,  kind = "string" },
    },
    persisted = {},  -- delegates undo state to nested BatchRippleEdit
}

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["RippleTrimEdge"] = function(command)
        local args             = command:get_all_parameters()
        local log              = require("core.logger").for_area("commands")
        local command_manager  = require("core.command_manager")
        local Clip             = require("models.clip")

        assert(args.edge == "left" or args.edge == "right",
            string.format("RippleTrimEdge: edge must be 'left' or 'right', got '%s'",
                tostring(args.edge)))
        assert(args.delta_frames ~= 0,
            "RippleTrimEdge: delta_frames must be non-zero")

        local clip = Clip.load(args.clip_id)
        assert(clip, "RippleTrimEdge: clip not found: " .. tostring(args.clip_id))

        local edge_type = (args.edge == "right") and "out" or "in"

        local result = command_manager.execute("BatchRippleEdit", {
            sequence_id  = args.sequence_id,
            project_id   = args.project_id,
            delta_frames = args.delta_frames,
            edge_infos   = {
                {
                    clip_id   = args.clip_id,
                    edge_type = edge_type,
                    trim_type = "ripple",
                    track_id  = clip.track_id,
                }
            },
        })

        if not result or not result.success then
            return {
                success       = false,
                error_message = "RippleTrimEdge: " ..
                    tostring(result and result.error_message or "BatchRippleEdit failed"),
            }
        end

        log.event("RippleTrimEdge: clip=%s edge=%s delta=%d",
            args.clip_id, args.edge, args.delta_frames)
        return { success = true }
    end

    -- Undo is driven by BatchRippleEdit's undo entry; no separate undoer needed.
    command_undoers["RippleTrimEdge"] = function(_command)
        return true
    end

    return {
        executor = command_executors["RippleTrimEdge"],
        undoer   = command_undoers["RippleTrimEdge"],
        spec     = SPEC,
    }
end

return M
