local M = {}

local prepare = require("core.ripple.batch.prepare")

function M.run(ctx, db, ops)
    assert(ctx and type(ctx) == "table", "batch_pipeline.run: ctx is required")
    assert(type(ops) == "table", "batch_pipeline.run: ops table is required")

    prepare.resolve_sequence_rate(ctx, db)
    if not prepare.resolve_delta(ctx) then
        return false, "Invalid delta"
    end

    prepare.snapshot_edge_infos(ctx)

    ops.build_clip_cache(ctx)
    ops.prime_neighbor_bounds_cache(ctx)
    ops.materialize_gap_edges(ctx)
    ops.assign_edge_tracks(ctx)
    ops.determine_lead_edge(ctx)
    ops.analyze_selection(ctx)
    ops.compute_constraints(ctx, db)

    local ok_edges = ops.process_edge_trims(ctx, db)
    if not ok_edges then
        return false, "Failed to process edge trims"
    end

    local ok_shift, adjusted_frames = ops.compute_downstream_shifts(ctx, db)
    if not ok_shift then
        return ops.retry_with_adjusted_delta(ctx, adjusted_frames)
    end

    ops.build_planned_mutations(ctx)
    return ops.finalize_execution(ctx, db)
end

return M

