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
-- Size: ~55 LOC
-- Volatility: unknown
--
-- @file prepare.lua
local M = {}

local frame_utils = require("core.frame_utils")

function M.resolve_sequence_rate(ctx, db)
    assert(ctx and ctx.sequence_id and ctx.sequence_id ~= "", "BatchRippleEdit: missing sequence_id")
    assert(db, "BatchRippleEdit: missing db handle")

    local seq_stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    assert(seq_stmt, "BatchRippleEdit: failed to prepare sequence fps query")
    seq_stmt:bind_value(1, ctx.sequence_id)
    assert(seq_stmt:exec(), "BatchRippleEdit: failed to query sequence fps")
    assert(seq_stmt:next(), "BatchRippleEdit: missing sequence fps row for " .. tostring(ctx.sequence_id))
    local seq_fps_num = seq_stmt:value(0)
    local seq_fps_den = seq_stmt:value(1)
    seq_stmt:finalize()

    assert(type(seq_fps_num) == "number" and type(seq_fps_den) == "number", "BatchRippleEdit: invalid sequence fps values")
    ctx.seq_fps_num = seq_fps_num
    ctx.seq_fps_den = seq_fps_den
end

function M.resolve_delta(ctx)
    local seq_fps_num = ctx.seq_fps_num
    local seq_fps_den = ctx.seq_fps_den
    local delta_frames_input = ctx.delta_frames
    local delta_ms = ctx.delta_ms

    if delta_frames_input then
        assert(type(delta_frames_input) == "number", "BatchRippleEdit: delta_frames must be integer")
        ctx.delta_frames = delta_frames_input
    elseif delta_ms then
        assert(type(delta_ms) == "number", "BatchRippleEdit: delta_ms must be number")
        ctx.delta_frames = frame_utils.ms_to_frames(delta_ms, seq_fps_num, seq_fps_den)
    end

    return ctx.delta_frames ~= nil
end

function M.snapshot_edge_infos(ctx)
    local stored_edge_infos = {}
    assert(type(ctx.edge_infos) == "table", "BatchRippleEdit.snapshot_edge_infos: ctx.edge_infos must be a table")
    for _, edge in ipairs(ctx.edge_infos) do
        stored_edge_infos[#stored_edge_infos + 1] = {
            clip_id = edge.original_clip_id or edge.clip_id,
            original_clip_id = edge.original_clip_id,
            edge_type = edge.edge_type,
            track_id = edge.track_id,
            trim_type = edge.trim_type,
            type = edge.type,
        }
    end
    ctx.command:set_parameter("edge_infos", stored_edge_infos)
end

return M

