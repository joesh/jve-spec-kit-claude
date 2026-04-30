--- NudgeSelection — selection-aware nudge dispatch.
--
-- Single binding target for the comma/period family of keys. Reads the
-- active timeline's selection and routes to:
--   * BatchRippleEdit  (when one or more edges are selected)
--   * Nudge            (when clips, but no edges, are selected)
-- A direction (-1/+1) and magnitude (positive frames) drive the delta.
--
-- Why this exists: TOML keymaps are flat (key → command), and there is no
-- way to express "if edges → A else → B" inside a binding. Putting the
-- routing inside a real command means:
--   * the keyboard layer stays a thin dispatcher
--   * the dialog (which reads the registry) sees one entry per binding
--   * users can rebind nudge keys, including magnitude, from TOML alone
--
-- @file nudge_selection.lua
local M = {}

local SPEC = {
    args = {
        direction  = { required = true, kind = "number" },  -- -1 or +1
        magnitude  = { required = true, kind = "number" },  -- positive frames
        project_id = { required = true },
        sequence_id = { required = true },
    },
    persisted = {},  -- Delegates to Nudge / BatchRippleEdit for undo state.
}

-- Build BatchRippleEdit-shaped edge_infos by joining selected_edges (which
-- carry edge_type and trim_type) against the active clips (which carry
-- track_id). The keyboard layer used to do this join inline; centralizing
-- it here keeps the dispatch in one place.
--
-- Asserts every selected edge resolves to a clip on the timeline. A
-- mismatch means selection state is out of sync with the timeline model
-- — a real bug upstream — and silently dropping the edge would let it
-- accumulate. Crash with the offending clip_id so the upstream cause
-- is identifiable.
local function build_edge_infos(selected_edges, all_clips)
    local clip_by_id = {}
    for _, c in ipairs(all_clips) do clip_by_id[c.id] = c end

    local edge_infos = {}
    for _, edge in ipairs(selected_edges) do
        local clip = clip_by_id[edge.clip_id]
        assert(clip, string.format(
            "NudgeSelection: selected edge references clip_id=%s, "
            .. "which is not on the active timeline (selection is stale)",
            tostring(edge.clip_id)))
        edge_infos[#edge_infos + 1] = {
            clip_id   = edge.clip_id,
            edge_type = edge.edge_type,
            track_id  = clip.track_id,
            trim_type = edge.trim_type,
        }
    end
    return edge_infos
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["NudgeSelection"] = function(command)
        local args = command:get_all_parameters()
        local log = require("core.logger").for_area("commands")
        local command_manager = require("core.command_manager")
        local timeline_state = require("ui.timeline.timeline_state")

        local direction = args.direction
        local magnitude = args.magnitude
        assert(direction == -1 or direction == 1,
            string.format("NudgeSelection: direction must be -1 or 1, got %s", tostring(direction)))
        assert(type(magnitude) == "number" and magnitude > 0,
            string.format("NudgeSelection: magnitude must be a positive number, got %s", tostring(magnitude)))

        local delta = direction * magnitude

        local selected_edges = timeline_state.get_selected_edges()
        local selected_clips = timeline_state.get_selected_clips()

        if selected_edges and #selected_edges > 0 then
            local edge_infos = build_edge_infos(selected_edges, timeline_state.get_clips())
            local result = command_manager.execute("BatchRippleEdit", {
                edge_infos   = edge_infos,
                delta_frames = delta,
                sequence_id  = args.sequence_id,
                project_id   = args.project_id,
            })
            if not result or not result.success then
                local msg = result and result.error_message or "BatchRippleEdit failed"
                return false, "NudgeSelection: " .. msg
            end
            return true
        end

        if selected_clips and #selected_clips > 0 then
            local clip_ids = {}
            for _, clip in ipairs(selected_clips) do
                clip_ids[#clip_ids + 1] = clip.id
            end
            local result = command_manager.execute("Nudge", {
                nudge_amount      = delta,
                selected_clip_ids = clip_ids,
                sequence_id       = args.sequence_id,
                project_id        = args.project_id,
            })
            if not result or not result.success then
                local msg = result and result.error_message or "Nudge failed"
                return false, "NudgeSelection: " .. msg
            end
            return true
        end

        -- Nothing selected — silent no-op (mirrors the prior keyboard-layer
        -- behavior when comma/period was pressed with an empty selection).
        log.event("NudgeSelection: empty selection, no-op")
        return true
    end

    -- Undo is handled by the nested Nudge / BatchRippleEdit commands.
    command_undoers["NudgeSelection"] = function(_command)
        return true
    end

    return {
        executor = command_executors["NudgeSelection"],
        undoer   = command_undoers["NudgeSelection"],
        spec     = SPEC,
    }
end

return M
