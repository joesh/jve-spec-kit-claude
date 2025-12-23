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
-- Size: ~65 LOC
-- Volatility: unknown
--
-- @file context.lua
local M = {}

local command_helper = require("core.command_helper")

function M.create(command)
    assert(command and command.get_parameter, "BatchRippleEdit: missing command handle")

    local ctx = {
        command = command,
        dry_run = command:get_parameter("dry_run"),
        edge_infos_raw = command:get_parameter("edge_infos"),
        provided_lead_edge = command:get_parameter("lead_edge"),
        delta_frames = command:get_parameter("delta_frames"),
        delta_ms = command:get_parameter("delta_ms"),
        preloaded_clip_snapshot = command:get_parameter("__preloaded_clip_snapshot"),
        timeline_active_region = command:get_parameter("__timeline_active_region"),
        edge_infos = {},
        original_states_map = {},
        planned_mutations = {},
        preview_affected_clips = {},
        preview_shifted_clips = {},
        shift_blocks = {},
        neighbor_bounds_cache = {},
        base_clips = {},
        preloaded_media = {},
        modified_clips = {},
        per_edge_constraints = {},
        forced_clamped_edges = {},
        gap_partner_edges = {},
        edge_info_for_key = {},
        materialized_gap_ids = {},
        global_min_frames = -math.huge,
        global_max_frames = math.huge,
        global_min_edge_keys = {},
        global_max_edge_keys = {},
        clamp_direction = 0,
        clips_marked_delete = {},
        track_shift_amounts = {},
        track_shift_seeds = {},
        clips_to_shift = {},
        shift_lookup = {},
        edited_lookup_for_shifts = {},
        bulk_shift_mutations = {},
    }

    if ctx.edge_infos_raw then
        for _, edge in ipairs(ctx.edge_infos_raw) do
            local source_original_id = edge.original_clip_id or edge.clip_id
            local cleaned_id = edge.clip_id
            if type(cleaned_id) == "string" and cleaned_id:find("^temp_gap_") then
                cleaned_id = cleaned_id:gsub("^temp_gap_", "")
            end
            ctx.edge_infos[#ctx.edge_infos + 1] = {
                clip_id = cleaned_id,
                original_clip_id = source_original_id,
                edge_type = edge.edge_type,
                track_id = edge.track_id,
                trim_type = edge.trim_type,
                type = edge.type,
            }
        end
    end

    ctx.primary_edge = ctx.provided_lead_edge or (ctx.edge_infos and ctx.edge_infos[1] or nil)
    ctx.sequence_id = command_helper.resolve_sequence_id_for_edges(command, ctx.primary_edge, ctx.edge_infos)
    ctx.project_id = command.project_id or command:get_parameter("project_id")
    assert(ctx.project_id and ctx.project_id ~= "", "BatchRippleEdit: missing project_id")

    return ctx
end

return M

