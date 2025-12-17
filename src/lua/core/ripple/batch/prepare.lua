local M = {}

local Rational = require("core.rational")

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
    local delta_frames = ctx.delta_frames
    local delta_ms = ctx.delta_ms
    local delta_rat

    if delta_frames then
        delta_rat = Rational.new(delta_frames, seq_fps_num, seq_fps_den)
    elseif delta_ms then
        if type(delta_ms) == "number" then
            error("BatchRippleEdit: delta_ms must be Rational, not number")
        end
        if getmetatable(delta_ms) == Rational.metatable then
            delta_rat = delta_ms:rescale(seq_fps_num, seq_fps_den)
        elseif type(delta_ms) == "table" and delta_ms.frames then
            delta_rat = Rational.new(delta_ms.frames, delta_ms.fps_numerator or seq_fps_num, delta_ms.fps_denominator or seq_fps_den)
        else
            error("BatchRippleEdit: delta_ms must be Rational-like")
        end
    end

    ctx.delta_rat = delta_rat
    return delta_rat ~= nil and delta_rat.frames ~= nil
end

function M.snapshot_edge_infos(ctx)
    local stored_edge_infos = {}
    for _, edge in ipairs(ctx.edge_infos or {}) do
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

