--- ExtendEdit command — extends selected edge(s) to meet the playhead.
--
-- Takes selected edges and computes delta to reach playhead, then delegates
-- to BatchRippleEdit. Honors trim_type (ripple vs roll).
--
-- This is a "nudge to playhead" for edges - the delta is computed automatically
-- based on edge position and playhead position.
--
-- Selection: if the caller does not pass `edge_infos`, the executor gathers
-- the active timeline's selected edges via timeline_state. This makes the
-- command directly bindable from TOML (`"E" = "ExtendEdit @timeline"`) — the
-- keyboard layer no longer assembles selection on its behalf.
--
-- @file extend_edit.lua
local M = {}

local SPEC = {
    args = {
        edge_infos = { kind = "table" },       -- array of {clip_id, edge_type, track_id, trim_type}; gathered from selection if absent
        playhead = { required = true, kind = "number" },  -- target frame (int) — auto-injected by execute_interactive
        project_id = { required = true },
        sequence_id = { required = true },
    },
    persisted = {},  -- Delegates to BatchRippleEdit for undo
}

local edge_decoration = require("ui.timeline.edge_decoration")

-- Pull selected edges off the active timeline_state and decorate them
-- with track_id via the shared edge_decoration helper. Thin wrapper so
-- the dispatch path stays one line.
local function gather_edge_infos_from_selection()
    local ts = require("ui.timeline.timeline_state")
    local selected_edges = ts.get_selected_edges()
    if not selected_edges or #selected_edges == 0 then return {} end
    return edge_decoration.decorate(selected_edges, ts.get_clips(), "ExtendEdit")
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["ExtendEdit"] = function(command)
        local args = command:get_all_parameters()
        local log = require("core.logger").for_area("commands")
        local command_manager = require("core.command_manager")
        local Clip = require("models.clip")

        local edge_infos = args.edge_infos
        if not edge_infos or #edge_infos == 0 then
            edge_infos = gather_edge_infos_from_selection()
        end
        if #edge_infos == 0 then
            -- No selection → nothing to extend. Matches the prior keyboard-
            -- layer behavior (silent no-op when nothing is selected).
            log.event("ExtendEdit: no edge selection, no-op")
            return true
        end

        local playhead = args.playhead
        assert(type(playhead) == "number", "ExtendEdit: playhead must be integer")

        log.event("ExtendEdit edges=%d playhead=%d", #edge_infos, playhead)

        -- Single-edge extend: lead edge drives the delta. Multi-edge with
        -- divergent deltas would require a BatchRippleEdit enhancement
        -- that isn't built yet; today's UX is "select one edge, press E."
        local lead_edge = edge_infos[1]
        local is_gap_clip = type(lead_edge.clip_id) == "string"
            and lead_edge.clip_id:find("^gap_") ~= nil
        local clip
        if is_gap_clip then
            -- Gap clips live in timeline_state only (in-memory, never
            -- persisted per the 005 gap-as-clip refactor). timeline_state
            -- is necessarily loaded — selected_edges came from it.
            clip = require("ui.timeline.timeline_state").get_clip_by_id(lead_edge.clip_id)
        else
            clip = Clip.load(lead_edge.clip_id)
        end
        assert(clip, string.format(
            "ExtendEdit: clip not found (id=%s, is_gap=%s)",
            tostring(lead_edge.clip_id), tostring(is_gap_clip)))

        -- Compute current edge position
        local edge_position
        if lead_edge.edge_type == "in" then
            edge_position = clip.sequence_start
        elseif lead_edge.edge_type == "out" then
            edge_position = clip.sequence_start + clip.duration
        else
            assert(false, string.format(
                "ExtendEdit: unknown edge_type: %s (must be 'in' or 'out')",
                tostring(lead_edge.edge_type)))
        end

        -- Delta = how much to move edge to reach playhead
        -- Positive delta moves edge right, negative moves left
        local delta_frames = playhead - edge_position

        if delta_frames == 0 then
            log.event("ExtendEdit: edge already at playhead, no-op")
            return true
        end

        log.event("ExtendEdit: edge at %d, playhead at %d, delta=%d",
            edge_position, playhead, delta_frames)

        -- Delegate to BatchRippleEdit. Its batch_context.create
        -- normalizes a 1-element edge_infos array uniformly with the
        -- multi-edge case, so single-edge extend uses the same dispatch
        -- path as multi-edge. The standalone RippleEdit command was
        -- deleted in T046.
        local result = command_manager.execute("BatchRippleEdit", {
            edge_infos = edge_infos,
            delta_frames = delta_frames,
            sequence_id = args.sequence_id,
            project_id = args.project_id,
        })

        assert(result and result.success, string.format(
            "ExtendEdit: nested BatchRippleEdit failed: %s "
            .. "(edges=%d delta=%d playhead=%d edge_position=%d)",
            tostring(result and result.error_message or "no result"),
            #edge_infos, delta_frames, playhead, edge_position))

        log.event("ExtendEdit: completed, delta=%d frames", delta_frames)
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
