local M = {}
local Clip = require('models.clip')
local database = require('core.database')
local frame_utils = require('core.frame_utils')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local edge_utils = require("ui.timeline.edge_utils")
local ui_constants = require("core.ui_constants")
local clip_mutator = require('core.clip_mutator') -- New dependency
local logger = require("core.logger")
local ripple_edge = require("core.ripple.edge_info")
local ripple_track = require("core.ripple.track_index")
local ripple_undo = require("core.ripple.undo_hydrator")
local batch_context = require("core.ripple.batch.context")
local batch_pipeline = require("core.ripple.batch.pipeline")

local get_edge_track_id = ripple_edge.get_edge_track_id
local compute_edge_boundary_time = ripple_edge.compute_edge_boundary_time
local build_edge_key = ripple_edge.build_edge_key
local bracket_for_normalized_edge = ripple_edge.bracket_for_normalized_edge
local build_neighbor_bounds_cache = ripple_track.build_neighbor_bounds_cache
local find_next_clip_on_track = ripple_track.find_next_clip_on_track
local find_prev_clip_on_track = ripple_track.find_prev_clip_on_track
local build_track_clip_map = ripple_track.build_track_clip_map
local hydrate_executed_mutations_if_missing = ripple_undo.hydrate_executed_mutations_if_missing

local function signum(value)
    if not value then
        return 0
    end
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

local function infer_implied_normalized_edge(lead_normalized, shift_sign, global_sign)
    if shift_sign == 0 then
        return lead_normalized
    end
    if not lead_normalized then
        return (shift_sign > 0) and "out" or "in"
    end
    if global_sign ~= 0 and shift_sign ~= global_sign then
        return (lead_normalized == "in") and "out" or "in"
    end
    return lead_normalized
end

local function lower_bound_start_frames(track_clips, boundary_frames)
    if type(track_clips) ~= "table" or #track_clips == 0 then
        return 1
    end
    local lo = 1
    local hi = #track_clips + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local clip = track_clips[mid]
        local start_frames = clip and clip.timeline_start and clip.timeline_start.frames
        if start_frames == nil then
            return 1
        end
        if start_frames < boundary_frames then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

local function pick_gap_anchor_clip_id(track_clips, boundary_frames, raw_edge_type)
    if type(track_clips) ~= "table" or #track_clips == 0 then
        return nil
    end
    local idx = lower_bound_start_frames(track_clips, boundary_frames or 0)
    local right = track_clips[idx]
    local left = (idx > 1) and track_clips[idx - 1] or nil
    if raw_edge_type == "gap_before" then
        return (right and right.id) or (left and left.id) or nil
    end
    return (left and left.id) or (right and right.id) or nil
end

-- Materialize a synthetic clip representing the requested gap edge so downstream
-- logic (trim/apply) can treat it like a normal clip. Returns nil when the edge
-- no longer corresponds to a real gap because the neighbors are missing.
local function create_temp_gap_clip(edge_info, clip_lookup, all_clips, seq_fps_num, seq_fps_den)
        if not edge_info or (edge_info.edge_type ~= "gap_after" and edge_info.edge_type ~= "gap_before") then
            return nil
        end

	        local function ensure_rational(value)
	            assert(value ~= nil, "create_temp_gap_clip: missing time value")
	            if getmetatable(value) == Rational.metatable then
	                return value:rescale(seq_fps_num, seq_fps_den)
	            end
	            if type(value) == "table" and value.frames then
	                return Rational.new(value.frames, seq_fps_num, seq_fps_den)
	            end
	            assert(type(value) == "number", "create_temp_gap_clip: expected number or Rational-like")
	            return Rational.new(value, seq_fps_num, seq_fps_den)
	        end

        local track_id = edge_info.track_id
        local reference_clip = clip_lookup[edge_info.clip_id]
        if reference_clip and not track_id then
            track_id = reference_clip.track_id
        end
    if not track_id then
        return nil
    end

    local gap_start
    local gap_end
    local left_clip
    local right_clip

    if edge_info.edge_type == "gap_after" then
        left_clip = reference_clip
        if not left_clip or not left_clip.timeline_start or not left_clip.duration then
            return nil
        end
        gap_start = left_clip.timeline_start + left_clip.duration
        right_clip = find_next_clip_on_track(all_clips, left_clip)
        if right_clip then
            gap_end = right_clip.timeline_start
        else
            gap_end = gap_start
        end
    else -- gap_before
        right_clip = reference_clip
        if not right_clip or not right_clip.timeline_start then
            return nil
        end
        gap_end = right_clip.timeline_start
        left_clip = find_prev_clip_on_track(all_clips, right_clip)
        if left_clip then
            gap_start = left_clip.timeline_start + left_clip.duration
        else
            gap_start = Rational.new(0, seq_fps_num, seq_fps_den)
        end
        end

        gap_start = ensure_rational(gap_start)
        gap_end = ensure_rational(gap_end)

	        local duration = gap_end - gap_start
	        assert(duration and duration.frames ~= nil, "create_temp_gap_clip: failed to compute gap duration")
	        if duration.frames < 0 then
	            duration = Rational.new(0, seq_fps_num, seq_fps_den)
	        end

	    assert(gap_start.frames ~= nil and gap_end.frames ~= nil, "create_temp_gap_clip: missing gap_start/gap_end frames")
	    local temp_id = string.format("temp_gap_%s_%s_%s", tostring(track_id), tostring(gap_start.frames), tostring(gap_end.frames))

    local gap_clip = {
        id = temp_id,
        track_id = track_id,
        timeline_start = gap_start,
        duration = duration,
        source_in = Rational.new(ui_constants.TIMELINE.GAP_SOURCE_MIN_FRAMES, seq_fps_num, seq_fps_den),
        source_out = Rational.new(ui_constants.TIMELINE.GAP_SOURCE_MAX_FRAMES, seq_fps_num, seq_fps_den),
        fps_numerator = seq_fps_num,
        fps_denominator = seq_fps_den,
        rate = { fps_numerator = seq_fps_num, fps_denominator = seq_fps_den },
        enabled = 1,
        created_at = 0,
        modified_at = 0,
        is_temp_gap = true,
        gap_left_id = left_clip and left_clip.id or nil,
        gap_right_id = right_clip and right_clip.id or nil
    }
    return gap_clip
end

local function compute_neighbor_bounds(all_clips, original_state, clip_id)
    if not original_state or not original_state.track_id then
        return nil, nil, nil, nil
    end
    local track_id = original_state.track_id
    local start_value = original_state.timeline_start
    local duration_value = original_state.duration
    if not start_value or not duration_value then
        return nil, nil, nil, nil
    end
    assert(type(start_value) == "table" and start_value.frames, "compute_neighbor_bounds: timeline_start must be Rational-like")
    assert(type(duration_value) == "table" and duration_value.frames, "compute_neighbor_bounds: duration must be Rational-like")

    local start_frames = start_value.frames
    local end_frames = start_frames + duration_value.frames

    local prev_end_frames = nil
    local next_start_frames = nil
    local prev_clip_id = nil
    local next_clip_id = nil

    assert(all_clips, "compute_neighbor_bounds: all_clips is nil")
    for _, other in ipairs(all_clips) do
        if other.id ~= clip_id and other.track_id == track_id then
            assert(other.timeline_start and other.timeline_start.frames, "compute_neighbor_bounds: other clip missing timeline_start.frames")
            assert(other.duration and other.duration.frames, "compute_neighbor_bounds: other clip missing duration.frames")
            local other_start_frames = other.timeline_start.frames
            local other_end_frames = other_start_frames + other.duration.frames

            if other_end_frames <= start_frames then
                if not prev_end_frames or other_end_frames > prev_end_frames then
                    prev_end_frames = other_end_frames
                    prev_clip_id = other.id
                end
            end
            if other_start_frames >= end_frames then
                if not next_start_frames or other_start_frames < next_start_frames then
                    next_start_frames = other_start_frames
                    next_clip_id = other.id
                end
            end
        end
    end

    return prev_end_frames, next_start_frames, prev_clip_id, next_clip_id
end

local function ensure_neighbor_bounds(ctx, clip_id)
    ctx.neighbor_bounds_cache = ctx.neighbor_bounds_cache or {}
    if ctx.neighbor_bounds_cache[clip_id] then
        return ctx.neighbor_bounds_cache[clip_id]
    end

    local original = ctx.original_states_map[clip_id] or ctx.base_clips[clip_id] or (ctx.clip_lookup and ctx.clip_lookup[clip_id])
    if not original then
        error(string.format("ensure_neighbor_bounds: missing original state for clip %s", tostring(clip_id)))
    end
    if not original.track_id then
        error(string.format("ensure_neighbor_bounds: clip %s missing track_id", tostring(clip_id)))
    end

    local prev_end_frames, next_start_frames, prev_id, next_id = compute_neighbor_bounds(ctx.all_clips, original, clip_id)
    ctx.neighbor_bounds_cache[clip_id] = {
        prev_end_frames = prev_end_frames,
        next_start_frames = next_start_frames,
        prev_id = prev_id,
        next_id = next_id
    }
    return ctx.neighbor_bounds_cache[clip_id]
end

local function should_negate_edge(ctx, edge_key)
    return ctx.edge_will_negate and ctx.edge_will_negate[edge_key]
end

local function resolve_gap_timeline_start_frames(ctx, clip, edge_info)
    local start_value = clip.timeline_start and clip.timeline_start.frames
    if edge_info.edge_type ~= "gap_before" then
        return start_value
    end
    if not clip.is_temp_gap then
        -- Non-materialized gap_before edges use the real clip's timeline_start.
        return start_value
    end
    local right_id = clip.gap_right_id or edge_info.original_clip_id or edge_info.clip_id
    assert(right_id, "resolve_gap_timeline_start_frames: gap_before requires right clip id")
    local right_original = ctx.original_states_map[right_id]
        or ctx.base_clips[right_id]
        or ctx.clip_lookup[right_id]
    if right_original and right_original.timeline_start and right_original.timeline_start.frames then
        return right_original.timeline_start.frames
    end
    return start_value
end

function M.register(command_executors, command_undoers, db, set_last_error)
    -- Helper: Load clip and capture original state if not already cached
    local function ensure_clip_loaded(ctx, clip_id, db)
        local clip = ctx.base_clips[clip_id]
        if not clip then
            local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
            local cached = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
            if cached then
                if is_temp_gap or (cached.rate and cached.rate.fps_numerator and cached.rate.fps_denominator) then
                    clip = cached
                end
            end
            if not clip and not is_temp_gap then
                clip = Clip.load_optional(clip_id, db)
            end
            if clip then
                ctx.base_clips[clip_id] = clip
            end
        end
        -- Skip capturing state for temp gap clips (synthetic, not persisted)
        local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
        if clip and not is_temp_gap and not ctx.original_states_map[clip_id] then
            ctx.original_states_map[clip_id] = command_helper.capture_clip_state(clip)
        end
        return clip
    end

    local function is_gap_edge(edge_type)
        return edge_type == "gap_after" or edge_type == "gap_before"
    end

    local function compute_gap_partner_key(edge_info, neighbors)
        if not neighbors then
            return nil
        end
        if edge_info.edge_type == "gap_after" and neighbors.next_id then
            return build_edge_key({clip_id = neighbors.next_id, edge_type = "gap_before"})
        elseif edge_info.edge_type == "gap_before" and neighbors.prev_id then
            return build_edge_key({clip_id = neighbors.prev_id, edge_type = "gap_after"})
        end
        return nil
    end

    local function register_gap_partner(ctx, edge_info, neighbors)
        if not neighbors then
            return
        end
        local partner_key = compute_gap_partner_key(edge_info, neighbors)
        if partner_key then
            local edge_key = build_edge_key(edge_info)
            ctx.gap_partner_edges[edge_key] = partner_key
        end
    end

    -- Helper: Calculate roll constraint (min/max delta) for an edge based on neighbor positions
    local function compute_roll_constraint(edge_info, clip, original, neighbors, edited_lookup)
        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local delta_min = nil
        local delta_max = nil
        local gap_frames = (clip.duration and clip.duration.frames) or 0

        assert(original and original.timeline_start and original.timeline_start.frames, "compute_roll_constraint: original missing timeline_start.frames")
        assert(original and original.duration and original.duration.frames, "compute_roll_constraint: original missing duration.frames")
        local original_start_frames = original.timeline_start.frames
        local original_end_frames = original_start_frames + original.duration.frames

        if normalized_edge == "in" then
            -- In-point: can't drag left past previous clip
            if edge_info.edge_type == "gap_after" then
                delta_min = -gap_frames
            elseif neighbors.prev_end_frames and not edited_lookup[neighbors.prev_id] then
                delta_min = neighbors.prev_end_frames - original_start_frames
            end
        elseif normalized_edge == "out" then
            -- Out-point: can't drag right past next clip
            if edge_info.edge_type == "gap_before" then
                delta_max = gap_frames
            elseif neighbors.next_start_frames and not edited_lookup[neighbors.next_id] then
                delta_max = neighbors.next_start_frames - original_end_frames
            end
        end

        return delta_min, delta_max
    end

    -- Helper: Calculate gap closure constraint
    local function compute_gap_close_constraint(edge_info, clip, will_negate)
        if edge_info.edge_type ~= "gap_before" and edge_info.edge_type ~= "gap_after" then
            return nil, nil
        end

        local duration = clip.duration and clip.duration.frames
        if not duration or duration <= 0 then
            return nil, nil
        end

        local normalized = edge_info.normalized_edge or edge_utils.to_bracket(edge_info.edge_type)
        local min_limit = -math.huge
        local max_limit = math.huge
        if normalized == "in" then
            max_limit = duration
        elseif normalized == "out" then
            min_limit = -duration
        end

        if will_negate then
            local flipped_min = -max_limit
            local flipped_max = -min_limit
            min_limit = flipped_min
            max_limit = flipped_max
        end

        return min_limit, max_limit
    end

    local function update_global_min(ctx, edge_key, value)
        if not value or value == -math.huge then
            return
        end
        ctx.global_min_edge_keys = ctx.global_min_edge_keys or {}
        if value > ctx.global_min_frames then
            ctx.global_min_frames = value
            ctx.global_min_edge_keys = {}
        end
        if edge_key and value == ctx.global_min_frames then
            ctx.global_min_edge_keys[edge_key] = true
        end
    end

    local function update_global_max(ctx, edge_key, value)
        if not value or value == math.huge then
            return
        end
        ctx.global_max_edge_keys = ctx.global_max_edge_keys or {}
        if value < ctx.global_max_frames then
            ctx.global_max_frames = value
            ctx.global_max_edge_keys = {}
        end
        if edge_key and value == ctx.global_max_frames then
            ctx.global_max_edge_keys[edge_key] = true
        end
    end

    local function apply_roll_constraints(ctx, edge_info, clip, neighbors)
        if edge_info.trim_type ~= "roll" then
            return
        end
        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}
        local delta_min, delta_max = compute_roll_constraint(edge_info, clip, ctx.original_states_map[edge_info.clip_id], neighbors, ctx.edited_clip_lookup)
        if delta_min then
            ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, delta_min)
            update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
        end
        if delta_max then
            ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, delta_max)
            update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
        end
    end

    local function apply_gap_limits(ctx, edge_info, clip, will_negate)
        if not is_gap_edge(edge_info.edge_type) then
            return
        end
        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}
        local gap_min, gap_max = compute_gap_close_constraint(edge_info, clip, will_negate)
        if gap_min then
            ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, gap_min)
            update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
        end
        if gap_max then
            ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, gap_max)
            update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
        end
    end

    local function clamp_gap_to_origin(ctx, edge_info, clip)
        if edge_info.edge_type ~= "gap_before" then
            return
        end
        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}
        local timeline_start_frames = resolve_gap_timeline_start_frames(ctx, clip, edge_info)
        if not timeline_start_frames then
            return
        end
        local start_limit = -timeline_start_frames
        ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, start_limit)
        update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
        if ctx.clamped_delta_rat and ctx.clamped_delta_rat.frames < start_limit then
            ctx.clamped_delta_rat = Rational.new(start_limit, ctx.seq_fps_num, ctx.seq_fps_den)
        end
    end

    local function apply_media_limits(ctx, edge_info, clip, will_negate)
        if is_gap_edge(edge_info.edge_type) then
            return
        end
        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local effective_delta_positive = (ctx.clamped_delta_rat.frames > 0 and not will_negate)
            or (ctx.clamped_delta_rat.frames < 0 and will_negate)
        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state then
            return
        end
        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}
        if normalized_edge == "in" then
            if not effective_delta_positive and clip_state.source_in then
                local extend_limit = -clip_state.source_in.frames
                ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, extend_limit)
                update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
            end
        elseif normalized_edge == "out" and effective_delta_positive and clip.media_id then
            local media = (ctx.preloaded_media and ctx.preloaded_media[clip.media_id]) or require("models.media").load(clip.media_id, db)
            if ctx.preloaded_media then
                ctx.preloaded_media[clip.media_id] = media
            end
            if media and media.duration and clip_state.source_in and clip_state.duration then
                local available_frames = media.duration.frames - clip_state.source_in.frames - clip_state.duration.frames
                if will_negate then
                    local global_constraint = -available_frames
                    ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, global_constraint)
                    update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
                else
                    ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, available_frames)
                    update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
                end
            end
        end
    end

    local function apply_min_duration_limits(ctx, edge_info, clip, will_negate)
        if is_gap_edge(edge_info.edge_type) then
            return
        end

        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        if normalized_edge ~= "in" and normalized_edge ~= "out" then
            return
        end

        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state or not clip_state.duration or not clip_state.duration.frames then
            return
        end

        local duration_frames = clip_state.duration.frames
        if duration_frames < 1 then
            return
        end

        local min_applied = -math.huge
        local max_applied = math.huge
        if normalized_edge == "in" then
            max_applied = duration_frames - 1
        else -- out
            min_applied = -(duration_frames - 1)
        end

        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}

        local global_min = min_applied
        local global_max = max_applied
        if will_negate then
            -- applied_delta = -clamped_delta => clamped_delta is constrained by the negated range
            global_min = (max_applied == math.huge) and -math.huge or -max_applied
            global_max = (min_applied == -math.huge) and math.huge or -min_applied
        end

        if global_min ~= -math.huge then
            ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, global_min)
            update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
        end
        if global_max ~= math.huge then
            ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, global_max)
            update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
        end
    end

    local function build_clip_cache(ctx)
        if type(ctx.preloaded_clip_snapshot) == "table" then
            assert(type(ctx.timeline_active_region) == "table",
                "build_clip_cache: __preloaded_clip_snapshot requires __timeline_active_region")
            local snapshot = ctx.preloaded_clip_snapshot
            assert(type(snapshot.clips) == "table", "build_clip_cache: __preloaded_clip_snapshot.clips is required")
            assert(type(snapshot.clip_lookup) == "table", "build_clip_cache: __preloaded_clip_snapshot.clip_lookup is required")
            assert(type(snapshot.track_clip_map) == "table", "build_clip_cache: __preloaded_clip_snapshot.track_clip_map is required")
            if ctx.dry_run then
                ctx.all_clips = snapshot.clips
                ctx.clip_lookup = snapshot.clip_lookup
                ctx.clip_track_lookup = snapshot.clip_track_lookup
                ctx.track_clip_map = snapshot.track_clip_map
                ctx.track_clip_positions = snapshot.track_clip_positions
                return
            end

            -- Execute mode: treat the snapshot as a *clip universe*, not as an
            -- authoritative source of clip positions. Snapshot clips can reflect
            -- transient preview shifts; load current persisted clips from the DB.
            ctx.all_clips = {}
            ctx.clip_lookup = {}
            ctx.clip_track_lookup = {}
            ctx.track_clip_map = {}

            local clip_ids = {}
            for clip_id, _ in pairs(snapshot.clip_lookup) do
                if clip_id then
                    table.insert(clip_ids, clip_id)
                end
            end
            for _, snap_clip in ipairs(snapshot.clips) do
                local clip_id = snap_clip and snap_clip.id
                if clip_id and snapshot.clip_lookup[clip_id] == nil then
                    table.insert(clip_ids, clip_id)
                end
            end

            for _, clip_id in ipairs(clip_ids) do
                local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
                local clip = is_temp_gap and snapshot.clip_lookup[clip_id] or Clip.load_optional(clip_id, db)
                if clip then
                    table.insert(ctx.all_clips, clip)
                    ctx.clip_lookup[clip_id] = clip
                    ctx.clip_track_lookup[clip_id] = clip.track_id
                    ctx.track_clip_map[clip.track_id] = ctx.track_clip_map[clip.track_id] or {}
                    table.insert(ctx.track_clip_map[clip.track_id], clip)
                end
            end

            for _, track_clips in pairs(ctx.track_clip_map) do
                table.sort(track_clips, function(a, b)
                    return a.timeline_start < b.timeline_start
                end)
            end
            return
        end

        -- UI-only optimization: prefer the in-memory timeline state for the
        -- active sequence to avoid reloading thousands of clips from SQLite.
        local use_timeline_state_cache = ctx.command:get_parameter("__use_timeline_state_cache") == true
        local timeline_state = use_timeline_state_cache and package.loaded["ui.timeline.timeline_state"] or nil
        if ctx.dry_run and timeline_state
            and timeline_state.get_sequence_id
            and timeline_state.get_sequence_id() == ctx.sequence_id
            and timeline_state.get_all_tracks
            and timeline_state.get_track_clip_index then
            ctx.clip_lookup = {}
            ctx.clip_track_lookup = {}
            ctx.track_clip_map = {}
            ctx.all_clips = {}
            for _, track in ipairs(timeline_state.get_all_tracks()) do
                local tid = track and track.id
                if tid then
                    local track_clips = timeline_state.get_track_clip_index(tid)
                    if track_clips and #track_clips > 0 then
                        ctx.track_clip_map[tid] = track_clips
                        for _, clip in ipairs(track_clips) do
                            if clip and clip.id then
                                table.insert(ctx.all_clips, clip)
                                ctx.clip_lookup[clip.id] = clip
                                ctx.clip_track_lookup[clip.id] = clip.track_id
                            end
                        end
                    end
                end
            end
            return
        end

        ctx.all_clips = database.load_clips(ctx.sequence_id)
        assert(ctx.all_clips, string.format("build_clip_cache: Failed to load clips for sequence %s", ctx.sequence_id))
        ctx.clip_lookup = {}
        for _, clip in ipairs(ctx.all_clips) do
            ctx.clip_lookup[clip.id] = clip
        end
        ctx.track_clip_map = build_track_clip_map(ctx.all_clips)
    end

    local function prime_neighbor_bounds_cache(ctx)
        assert(ctx.track_clip_map, "prime_neighbor_bounds_cache: track_clip_map is nil")
        ctx.neighbor_bounds_cache = build_neighbor_bounds_cache(ctx.track_clip_map)
    end

    local function register_temp_gap(ctx, gap_clip)
        if not gap_clip then
            return nil
        end
        ctx.temp_gap_clips = ctx.temp_gap_clips or {}
        if ctx.temp_gap_clips[gap_clip.id] then
            return gap_clip
        end
        ctx.temp_gap_clips[gap_clip.id] = gap_clip
        ctx.clip_lookup[gap_clip.id] = gap_clip
        ctx.base_clips[gap_clip.id] = gap_clip
        table.insert(ctx.materialized_gap_ids, gap_clip.id)
        return gap_clip
    end

    local function materialize_gap_edges(ctx)
        assert(ctx.edge_infos and #ctx.edge_infos > 0, "materialize_gap_edges: No edge_infos provided")
        for _, edge_info in ipairs(ctx.edge_infos) do
            if is_gap_edge(edge_info.edge_type) then
                local gap_clip = create_temp_gap_clip(edge_info, ctx.clip_lookup, ctx.all_clips, ctx.seq_fps_num, ctx.seq_fps_den)
                if not gap_clip then
                    error(string.format("Failed to materialize gap edge %s on clip %s", tostring(edge_info.edge_type), tostring(edge_info.clip_id)))
                end
                register_temp_gap(ctx, gap_clip)
                edge_info.original_clip_id = edge_info.clip_id
                edge_info.clip_id = gap_clip.id
                edge_info.track_id = gap_clip.track_id
                ctx.original_states_map[gap_clip.id] = command_helper.capture_clip_state(gap_clip)
            end
        end
    end

    local function assign_edge_tracks(ctx)
        assert(ctx.all_clips, "assign_edge_tracks: all_clips is nil")
        ctx.clip_track_lookup = ctx.clip_track_lookup or {}
        ctx.affected_tracks = {}
        ctx.selected_tracks = {}
        for _, clip in ipairs(ctx.all_clips) do
            if clip.id and ctx.clip_track_lookup[clip.id] == nil then
                ctx.clip_track_lookup[clip.id] = clip.track_id
            end
            if clip.track_id then
                ctx.affected_tracks[clip.track_id] = true
            end
        end
        assert(ctx.edge_infos, "assign_edge_tracks: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            if not edge_info.track_id then
                edge_info.track_id = ctx.clip_track_lookup[edge_info.clip_id]
            end
            if edge_info.track_id then
                ctx.selected_tracks[edge_info.track_id] = true
            end
            edge_info.normalized_edge = edge_utils.to_bracket(edge_info.edge_type)
        end
    end

    local function determine_lead_edge(ctx)
        assert(ctx.edge_infos, "determine_lead_edge: edge_infos is nil")
        local provided_lead_clip = ctx.provided_lead_edge and ctx.provided_lead_edge.clip_id or nil
        local provided_lead_norm = ctx.provided_lead_edge and edge_utils.to_bracket(ctx.provided_lead_edge.edge_type or ctx.provided_lead_edge.normalized_edge) or nil
        for _, edge_info in ipairs(ctx.edge_infos) do
            local matches_clip = provided_lead_clip
                and (edge_info.clip_id == provided_lead_clip or edge_info.original_clip_id == provided_lead_clip)
            local matches_edge = not provided_lead_norm or edge_info.normalized_edge == provided_lead_norm
            if matches_clip and matches_edge then
                ctx.lead_edge_entry = edge_info
                break
            end
        end
        if not ctx.lead_edge_entry then
            ctx.lead_edge_entry = ctx.edge_infos and ctx.edge_infos[1] or nil
        end
        if ctx.lead_edge_entry then
            ctx.command:set_parameter("lead_edge", {
                clip_id = ctx.lead_edge_entry.original_clip_id or ctx.lead_edge_entry.clip_id,
                original_clip_id = ctx.lead_edge_entry.original_clip_id,
                edge_type = ctx.lead_edge_entry.edge_type,
                track_id = ctx.lead_edge_entry.track_id,
                trim_type = ctx.lead_edge_entry.trim_type
            })
        end
    end

    local function load_clip_for_edit(ctx, clip_id, db)
        local clip = ctx.modified_clips[clip_id]
        if clip then
            return clip
        end

        local base = ctx.base_clips[clip_id]
        if not base then
            local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
            local cached = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
            if cached then
                if is_temp_gap or (cached.rate and cached.rate.fps_numerator and cached.rate.fps_denominator) then
                    base = cached
                end
            end
            if not base and not is_temp_gap then
                base = Clip.load_optional(clip_id, db)
            end
            if base then
                ctx.base_clips[clip_id] = base
            end
        end

        if not base then
            return nil
        end

        -- Skip capturing state for temp gap clips (synthetic, not persisted)
        local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
        if not is_temp_gap and not ctx.original_states_map[clip_id] then
            ctx.original_states_map[clip_id] = command_helper.capture_clip_state(base)
        end

        if ctx.dry_run then
            assert(base.rate and base.rate.fps_numerator and base.rate.fps_denominator,
                "load_clip_for_edit: base clip missing rate metadata")
            clip = {
                id = base.id,
                project_id = base.project_id,
                clip_kind = base.clip_kind,
                owner_sequence_id = base.owner_sequence_id or base.track_sequence_id,
                track_sequence_id = base.track_sequence_id or base.owner_sequence_id,
                parent_clip_id = base.parent_clip_id,
                source_sequence_id = base.source_sequence_id,
                track_id = base.track_id,
                media_id = base.media_id,
                timeline_start = base.timeline_start,
                duration = base.duration,
                source_in = base.source_in,
                source_out = base.source_out,
                name = base.name,
                enabled = base.enabled,
                rate = base.rate,
                fps_numerator = base.fps_numerator or base.rate.fps_numerator,
                fps_denominator = base.fps_denominator or base.rate.fps_denominator,
                created_at = base.created_at,
                modified_at = base.modified_at,
                is_temp_gap = base.is_temp_gap,
                gap_left_id = base.gap_left_id,
                gap_right_id = base.gap_right_id
            }
        else
            clip = base
        end

        ctx.modified_clips[clip_id] = clip
        return clip
    end

    local function fetch_clip(ctx, clip_id, db)
        local clip = ctx.base_clips[clip_id]
        if clip then
            return clip
        end
        local cached = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
        if cached then
            local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
            if is_temp_gap or (cached.rate and cached.rate.fps_numerator and cached.rate.fps_denominator) then
                return cached
            end
        end
        local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
        if is_temp_gap then
            return cached
        end
        return Clip.load_optional(clip_id, db)
    end

-- Apply the requested trim delta to clip/gap edges and return the ripple start.
-- Returns nil when the clip collapses (e.g., trim removes media entirely).
	local function apply_edge_ripple(clip, edge_type, delta_rat, trim_type, raw_edge_type)
	        if type(clip.duration) ~= "table" or not clip.duration.frames then
	            error("apply_edge_ripple: Clip missing Rational duration.")
	        end
	        assert(clip.duration.fps_numerator and clip.duration.fps_denominator, "apply_edge_ripple: Clip duration missing fps metadata")

	        local new_duration_timeline = clip.duration
	        local new_source_in = clip.source_in
	        local is_gap = is_gap_edge(raw_edge_type)

        if is_gap and trim_type == "roll" then
            new_duration_timeline = clip.duration
            if edge_type == "in" then
                clip.timeline_start = clip.timeline_start + delta_rat
            end
        elseif edge_type == "in" then
            new_duration_timeline = clip.duration - delta_rat
            new_source_in = clip.source_in + delta_rat
            if trim_type == "roll" then
                clip.timeline_start = clip.timeline_start + delta_rat
            end
        elseif edge_type == "out" then
            new_duration_timeline = clip.duration + delta_rat
        else
            error(string.format("apply_edge_ripple: Unsupported edge_type '%s'", edge_type))
        end

	        if is_gap then
	            if new_duration_timeline.frames and new_duration_timeline.frames < 0 then
	                new_duration_timeline = Rational.new(0, clip.duration.fps_numerator, clip.duration.fps_denominator)
	            end
	        else
	            if new_duration_timeline.frames < 1 then
	                clip.duration = Rational.new(0, clip.duration.fps_numerator, clip.duration.fps_denominator)
	                clip.source_in = new_source_in
	                clip.source_out = clip.source_in + clip.duration
	                return clip.timeline_start, true, true
	            end
	        end

	        clip.duration = new_duration_timeline
	        clip.source_in = new_source_in
	        clip.source_out = clip.source_in + clip.duration
	        return clip.timeline_start, true, false
	    end

    local function analyze_selection(ctx)
        ctx.selection_has_clip_edge = false
        ctx.edited_clip_lookup = {}
        ctx.lead_is_gap = ctx.lead_edge_entry and is_gap_edge(ctx.lead_edge_entry.edge_type)
        ctx.edge_will_negate = {}

        local lead_bracket = ctx.lead_edge_entry and bracket_for_normalized_edge(ctx.lead_edge_entry.normalized_edge or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type))

        assert(ctx.edge_infos, "setup_edge_context: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.clip_id then
                ctx.edited_clip_lookup[edge_info.clip_id] = true
                if edge_info.original_clip_id then
                    ctx.edited_clip_lookup[edge_info.original_clip_id] = true
                end
                if is_gap_edge(edge_info.edge_type) then
                    local gap_clip = ctx.base_clips and ctx.base_clips[edge_info.clip_id]
                    if gap_clip then
                        if gap_clip.gap_left_id then
                            ctx.edited_clip_lookup[gap_clip.gap_left_id] = true
                        end
                        if gap_clip.gap_right_id then
                            ctx.edited_clip_lookup[gap_clip.gap_right_id] = true
                        end
                    end
                end
                if not is_gap_edge(edge_info.edge_type) then
                    ctx.selection_has_clip_edge = true
                end
            end
            local normalized = edge_info.normalized_edge or edge_utils.to_bracket(edge_info.edge_type)
            local edge_bracket = bracket_for_normalized_edge(normalized)
            local key = build_edge_key(edge_info)
            ctx.edge_info_for_key[key] = edge_info
            if ctx.lead_edge_entry and edge_info ~= ctx.lead_edge_entry and edge_info.trim_type ~= "roll" then
                if lead_bracket and edge_bracket and edge_bracket ~= lead_bracket then
                    ctx.edge_will_negate[key] = true
                end
            end
        end

        ctx.clamped_delta_rat = ctx.delta_rat
    end

		    local function compute_earliest_ripple_hint(ctx)
		        assert(ctx.edge_infos, "compute_earliest_ripple_hint: edge_infos is nil")
		        assert(ctx.original_states_map, "compute_earliest_ripple_hint: original_states_map is nil")
		        ctx.earliest_ripple_hint = nil
		        for _, edge_info in ipairs(ctx.edge_infos) do
		            if edge_info.trim_type ~= "roll" then
		                local point = compute_edge_boundary_time(edge_info, ctx.original_states_map)
		                if point and (not ctx.earliest_ripple_hint or point < ctx.earliest_ripple_hint) then
		                    ctx.earliest_ripple_hint = point
		                end
		            end
		        end
		    end

	    local function clamp_downstream_overlaps(ctx)
	        local earliest = ctx.earliest_ripple_hint
	        if not earliest then
	            return
	        end
	
	        local function lead_edge_shift_factor()
	            if not ctx.lead_edge_entry then
	                return 1
	            end
	            local normalized = ctx.lead_edge_entry.normalized_edge
	                or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type)
	            if normalized == "in" then
	                return -1
	            end
	            return 1
	        end
	        local shift_factor = lead_edge_shift_factor()
	        assert(ctx.all_clips, "clamp_downstream_overlaps: all_clips is nil")
	        for _, clip in ipairs(ctx.all_clips) do
	            if clip.id
	                and not ctx.edited_clip_lookup[clip.id]
	                and clip.timeline_start then
                if ctx.selected_tracks[clip.track_id] and earliest and clip.timeline_start >= earliest then
                    goto continue_clip_scan
                end
                if earliest and clip.timeline_start < earliest then
                    goto continue_clip_scan
                end
                local neighbors = ctx.neighbor_bounds_cache and ctx.neighbor_bounds_cache[clip.id]
                assert(neighbors, "clamp_downstream_overlaps: missing neighbor cache for clip " .. tostring(clip.id))
                assert(clip.timeline_start and clip.timeline_start.frames, "clamp_downstream_overlaps: clip missing timeline_start.frames")
                assert(clip.duration and clip.duration.frames, "clamp_downstream_overlaps: clip missing duration.frames")
                local clip_start_frames = clip.timeline_start.frames
                local clip_end_frames = clip_start_frames + clip.duration.frames

                local function neighbor_in_shift_region(neighbor_id)
                    if not neighbor_id or not ctx.clip_lookup then
                        return false
                    end
                    local neighbor = ctx.clip_lookup[neighbor_id]
                    if not neighbor or not neighbor.timeline_start then
                        return false
                    end
                    return neighbor.timeline_start >= earliest
                end

	                if neighbors.prev_end_frames and neighbors.prev_id and not ctx.edited_clip_lookup[neighbors.prev_id] then
	                    if neighbor_in_shift_region(neighbors.prev_id) then
	                        goto continue_prev_gap
	                    end
	                    local prev_gap_frames = clip_start_frames - neighbors.prev_end_frames
	                    if prev_gap_frames >= 0 then
	                        local implied_key = build_edge_key({clip_id = clip.id, edge_type = "gap_before"})
	                        if shift_factor >= 0 then
	                            update_global_min(ctx, implied_key, -prev_gap_frames)
	                        else
	                            update_global_max(ctx, implied_key, prev_gap_frames)
	                        end
	                    end
	                end
                ::continue_prev_gap::

	                if neighbors.next_start_frames and neighbors.next_id and not ctx.edited_clip_lookup[neighbors.next_id] then
	                    if neighbor_in_shift_region(neighbors.next_id) then
	                        goto continue_next_gap
	                    end
	                    local next_gap_frames = neighbors.next_start_frames - clip_end_frames
	                    if next_gap_frames >= 0 then
	                        local implied_key = build_edge_key({clip_id = clip.id, edge_type = "gap_after"})
	                        if shift_factor >= 0 then
	                            update_global_max(ctx, implied_key, next_gap_frames)
	                        else
	                            update_global_min(ctx, implied_key, -next_gap_frames)
	                        end
	                    end
	                end
                ::continue_next_gap::
                ::continue_clip_scan::
            end
        end
    end

    local function clamp_delta(ctx)
        local delta_frames = ctx.clamped_delta_rat.frames
        if ctx.global_min_frames ~= -math.huge and ctx.global_max_frames ~= math.huge and ctx.global_min_frames > ctx.global_max_frames then
            delta_frames = 0
        else
            if ctx.global_min_frames ~= -math.huge and delta_frames < ctx.global_min_frames then
                delta_frames = ctx.global_min_frames
            end
            if ctx.global_max_frames ~= math.huge and delta_frames > ctx.global_max_frames then
                delta_frames = ctx.global_max_frames
            end
        end
        ctx.clamped_delta_rat = Rational.new(delta_frames, ctx.seq_fps_num, ctx.seq_fps_den)
        ctx.clamp_direction = 0
        if ctx.delta_rat and ctx.delta_rat.frames and ctx.clamped_delta_rat.frames then
            local diff = ctx.delta_rat.frames - ctx.clamped_delta_rat.frames
            if diff > 0 then
                ctx.clamp_direction = 1
            elseif diff < 0 then
                ctx.clamp_direction = -1
            end
        end
        ctx.command:set_parameter("clamped_delta_ms", ctx.clamped_delta_rat:to_milliseconds())
        return delta_frames
    end

    local function compute_constraints(ctx, db)
        ctx.global_min_frames = -math.huge
        ctx.global_max_frames = math.huge
        ctx.global_min_edge_keys = {}
        ctx.global_max_edge_keys = {}

        assert(ctx.edge_infos, "compute_constraints: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            local clip = ensure_clip_loaded(ctx, edge_info.clip_id, db)
            if clip then
                local neighbors = ensure_neighbor_bounds(ctx, edge_info.clip_id)
                local edge_key = build_edge_key(edge_info)
                ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}

                if is_gap_edge(edge_info.edge_type) then
                    register_gap_partner(ctx, edge_info, neighbors)
                end

                apply_roll_constraints(ctx, edge_info, clip, neighbors)
                local will_negate = should_negate_edge(ctx, edge_key)
                apply_gap_limits(ctx, edge_info, clip, will_negate)
                clamp_gap_to_origin(ctx, edge_info, clip)
                apply_media_limits(ctx, edge_info, clip, will_negate)
                apply_min_duration_limits(ctx, edge_info, clip, will_negate)
            end
        end

        compute_earliest_ripple_hint(ctx)
        clamp_downstream_overlaps(ctx)
        if ctx.command:get_parameter('__force_conflict_delta') then
            ctx.global_min_frames = 1
            ctx.global_max_frames = 0
            ctx.global_min_edge_keys = {}
            ctx.global_max_edge_keys = {}
        end
	        clamp_delta(ctx)
	        if ctx.clamp_direction ~= 0 then
	            local function promote_implied_edges(source_map)
	                if not source_map then
	                    return
	                end
	                for key in pairs(source_map) do
	                    if key and not (ctx.per_edge_constraints and ctx.per_edge_constraints[key]) then
	                        ctx.forced_clamped_edges[key] = true
	                    end
	                end
	            end
	            if ctx.clamp_direction == -1 then
                promote_implied_edges(ctx.global_min_edge_keys)
            elseif ctx.clamp_direction == 1 then
                promote_implied_edges(ctx.global_max_edge_keys)
            end
        end
    end

    local function add_preview_shift(ctx, clip_id, new_start, new_duration)
        if not ctx.dry_run or not clip_id or not new_start then
            return
        end
        ctx.preview_shifted_lookup = ctx.preview_shifted_lookup or {}
        if ctx.preview_shifted_lookup[clip_id] then
            return
        end
        ctx.preview_shifted_clips = ctx.preview_shifted_clips or {}
        table.insert(ctx.preview_shifted_clips, {
            clip_id = clip_id,
            new_start_value = new_start,
            new_duration = new_duration
        })
        ctx.preview_shifted_lookup[clip_id] = true
    end

	    local function reset_ripple_processing_state(ctx)
	        ctx.has_ripple_edge = false
	        ctx.ripple_anchor_edge_type = nil
	        ctx.ripple_anchor_is_gap = false
	        ctx.ripple_anchor_applied_delta = nil
	        ctx.ripple_anchor_track_id = nil
	        ctx.ripple_anchor_negated = false
	        ctx.track_shift_seeds = {}
	        ctx.track_shift_amounts = {}
	        ctx.track_ripple_start_frames = {}
	        ctx.earliest_ripple_time = nil
	        ctx.clips_marked_delete = {}
	        ctx.gap_applied_delta = {}
	        ctx.gap_right_moved = {}
	    end

    local function compute_applied_delta(ctx, edge_key)
        local applied_delta = ctx.clamped_delta_rat
        if should_negate_edge(ctx, edge_key) then
            applied_delta = -ctx.clamped_delta_rat
        end
        return applied_delta
    end

	    local function register_ripple_anchor(ctx, normalized_edge, is_gap_edge_type, applied_delta, track_id, edge_key)
	        ctx.has_ripple_edge = true
	        local is_negated = (edge_key and should_negate_edge(ctx, edge_key)) == true
	        if not ctx.ripple_anchor_edge_type then
	            ctx.ripple_anchor_edge_type = normalized_edge
	            ctx.ripple_anchor_is_gap = is_gap_edge_type
	            ctx.ripple_anchor_applied_delta = applied_delta
	            ctx.ripple_anchor_track_id = track_id
	            ctx.ripple_anchor_negated = is_negated
	            return
	        end
	        if ctx.ripple_anchor_is_gap and not is_gap_edge_type then
	            ctx.ripple_anchor_edge_type = normalized_edge
	            ctx.ripple_anchor_is_gap = false
	            ctx.ripple_anchor_applied_delta = applied_delta
	            ctx.ripple_anchor_track_id = track_id
	            ctx.ripple_anchor_negated = is_negated
	        end
	    end

    local function register_track_shift_seed(ctx, clip, normalized_edge, applied_delta, is_gap_edge_type)
        if not clip.track_id or ctx.track_shift_seeds[clip.track_id] then
            return
        end
        ctx.track_shift_seeds[clip.track_id] = {
            orientation = normalized_edge,
            applied_delta = applied_delta,
            is_gap = is_gap_edge_type
        }
    end

    local function record_preview_for_edge(ctx, clip, edge_info, normalized_edge)
        if not ctx.dry_run then
            return
        end
        ctx.preview_affected_clips = ctx.preview_affected_clips or {}
        table.insert(ctx.preview_affected_clips, {
            clip_id = clip.id,
            new_start_value = clip.timeline_start,
            new_duration = clip.duration,
            edge_type = normalized_edge,
            raw_edge_type = edge_info.edge_type,
            is_gap = is_gap_edge(edge_info.edge_type)
        })
    end

    local function compute_ripple_point(original, clip, normalized_edge)
        local source = original or clip
        if not source or not source.timeline_start then
            return clip.timeline_start
        end
        if normalized_edge == "out" then
            return source.timeline_start + source.duration
        end
        return source.timeline_start
    end

    local function update_earliest_ripple_time(ctx, point)
        if not point then
            return
        end
        if not ctx.earliest_ripple_time or point < ctx.earliest_ripple_time then
            ctx.earliest_ripple_time = point
        end
    end

    local function record_gap_delta(ctx, clip_id, applied_delta)
        ctx.gap_applied_delta[clip_id] = applied_delta
    end

    local function gap_right_has_independent_in_edge(ctx, clip_id)
        assert(ctx.edge_infos, "gap_right_has_independent_in_edge: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.clip_id == clip_id and edge_info.edge_type == "in" then
                return true
            end
        end
        return false
    end

    local function snapshot_clip_for_gap(ctx, clip)
        return {
            id = clip.id,
            track_id = clip.track_id,
            timeline_start = clip.timeline_start,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out,
            fps_numerator = clip.fps_numerator,
            fps_denominator = clip.fps_denominator,
            enabled = clip.enabled
        }
    end

    local function compute_gap_shift_value(ctx, gap_id, gap_clip, original_gap)
        local original_end = original_gap.timeline_start + original_gap.duration
        local new_end = gap_clip.timeline_start + gap_clip.duration
        local shift = new_end - original_end
        if shift.frames == 0 then
            shift = gap_clip.timeline_start - original_gap.timeline_start
        end
        if (not shift.frames or shift.frames == 0) and ctx.gap_applied_delta[gap_id] then
            shift = ctx.gap_applied_delta[gap_id]
        end
        return shift
    end

	    local function move_gap_right_clip(ctx, gap_id, gap_clip)
	        if not gap_clip or not gap_clip.is_temp_gap then
	            return
	        end
	        local right_id = gap_clip.gap_right_id
	        if not right_id or ctx.gap_right_moved[right_id] then
	            return
	        end
	        if gap_right_has_independent_in_edge(ctx, right_id) then
	            return
	        end
        local original_gap = ctx.original_states_map[gap_id]
        if not original_gap then
            return
        end
        local gap_shift = compute_gap_shift_value(ctx, gap_id, gap_clip, original_gap)
        if not gap_shift or not gap_shift.frames or gap_shift.frames == 0 then
            return
        end
        local right_clip = ctx.modified_clips[right_id] or ctx.clip_lookup[right_id]
        if not right_clip then
            return
        end
        if not ctx.modified_clips[right_id] then
            right_clip = snapshot_clip_for_gap(ctx, right_clip)
            ctx.modified_clips[right_id] = right_clip
            if not ctx.original_states_map[right_id] then
                ctx.original_states_map[right_id] = ctx.clip_lookup[right_id]
            end
        end
        right_clip.timeline_start = right_clip.timeline_start + gap_shift
        add_preview_shift(ctx, right_id, right_clip.timeline_start, right_clip.duration)
        ctx.gap_right_moved[right_id] = true
    end

    local function propagate_gap_offsets(ctx)
        for gap_id, gap_clip in pairs(ctx.modified_clips or {}) do
            if gap_clip and gap_clip.is_temp_gap then
                move_gap_right_clip(ctx, gap_id, gap_clip)
            end
        end
    end

	    local function compute_track_shift_amounts(ctx)
	        if ctx.has_ripple_edge then
	            assert(ctx.ripple_anchor_applied_delta and ctx.ripple_anchor_applied_delta.frames ~= nil,
	                "compute_track_shift_amounts: missing ripple_anchor_applied_delta")
	            local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
	            ctx.downstream_shift_rat = Rational.new(ctx.ripple_anchor_applied_delta.frames * shift_factor, ctx.seq_fps_num, ctx.seq_fps_den)

	            local drag_sign = (ctx.clamped_delta_rat.frames >= 0) and 1 or -1
	            for track_id, seed in pairs(ctx.track_shift_seeds) do
	                if track_id and seed.orientation and seed.applied_delta and seed.applied_delta.frames ~= nil then
	                    local orientation_sign = (seed.orientation == "in") and -1 or 1
	                    if seed.is_gap then
	                        ctx.track_shift_amounts[track_id] = Rational.new(seed.applied_delta.frames * orientation_sign, ctx.seq_fps_num, ctx.seq_fps_den)
	                    else
	                        local magnitude = math.abs(seed.applied_delta.frames)
	                        local direction_sign = drag_sign
	                        if seed.orientation == "out" then
	                            direction_sign = (seed.applied_delta.frames >= 0) and 1 or -1
	                        end
	                        local track_shift_frames = magnitude * direction_sign * orientation_sign
	                        ctx.track_shift_amounts[track_id] = Rational.new(track_shift_frames, ctx.seq_fps_num, ctx.seq_fps_den)
	                    end
	                end
	            end
	        else
	            ctx.downstream_shift_rat = Rational.new(0, ctx.seq_fps_num, ctx.seq_fps_den)
	        end
	    end

    local function ensure_earliest_ripple_time(ctx)
        if not ctx.earliest_ripple_time then
            ctx.earliest_ripple_time = Rational.new(0, ctx.seq_fps_num, ctx.seq_fps_den)
        end
    end

    local function process_edge_trims(ctx, db)
        reset_ripple_processing_state(ctx)

        assert(ctx.edge_infos, "process_edge_trims: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            local clip_id = edge_info.clip_id
            local clip = load_clip_for_edit(ctx, clip_id, db)
            if not clip then
                logger.warn("ripple", string.format("BatchRippleEdit: Clip %s not found. Skipping.", tostring(clip_id)))
                goto continue_edge_process
            end

            if ctx.clips_marked_delete[clip_id] then
                goto continue_edge_process
            end

            local original = ctx.original_states_map[clip_id]
            local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
            local key = build_edge_key(edge_info)
            local applied_delta = compute_applied_delta(ctx, key)

            local ripple_start, success, deleted_clip = apply_edge_ripple(clip, normalized_edge, applied_delta, edge_info.trim_type, edge_info.edge_type)
            if not success then
                logger.error("ripple", string.format("Ripple failed for clip %s (edge=%s trim=%s delta=%s)",
                    tostring(clip.id),
                    tostring(edge_info.edge_type),
                    tostring(edge_info.trim_type),
                    tostring(applied_delta)))
                return false
            end

            if is_gap_edge(edge_info.edge_type) then
                record_gap_delta(ctx, clip_id, applied_delta)
            end

	            if edge_info.trim_type ~= "roll" then
	                register_ripple_anchor(ctx, normalized_edge, is_gap_edge(edge_info.edge_type), applied_delta, clip.track_id, key)
	                register_track_shift_seed(ctx, clip, normalized_edge, applied_delta, is_gap_edge(edge_info.edge_type))
	            end

            record_preview_for_edge(ctx, clip, edge_info, normalized_edge)

            if deleted_clip then
                ctx.clips_marked_delete[clip_id] = true
            end

	            local ripple_point = compute_ripple_point(original, clip, normalized_edge)
	            if ripple_point and ripple_point.frames and clip.track_id then
	                local existing = ctx.track_ripple_start_frames[clip.track_id]
	                if not existing or ripple_point.frames < existing then
	                    ctx.track_ripple_start_frames[clip.track_id] = ripple_point.frames
	                end
	            end
	            update_earliest_ripple_time(ctx, ripple_point)

            ::continue_edge_process::
        end

        propagate_gap_offsets(ctx)
        compute_track_shift_amounts(ctx)
        ensure_earliest_ripple_time(ctx)
        return true
    end

    local function collect_downstream_clips(ctx)
        ctx.clips_to_shift = {}
        ctx.shift_lookup = {}
        ctx.edited_lookup_for_shifts = {}

        for id in pairs(ctx.modified_clips or {}) do
            ctx.edited_lookup_for_shifts[id] = true
        end
        for id in pairs(ctx.edited_clip_lookup or {}) do
            ctx.edited_lookup_for_shifts[id] = true
        end

        assert(ctx.all_clips, "collect_downstream_clips: all_clips is nil")
        for _, other_clip in ipairs(ctx.all_clips) do
            if other_clip.id
                and not ctx.edited_lookup_for_shifts[other_clip.id]
                and not (ctx.bulk_shift_anchor_lookup and ctx.bulk_shift_anchor_lookup[other_clip.id])
                and ctx.affected_tracks[other_clip.track_id]
                and other_clip.timeline_start
                and other_clip.timeline_start >= ctx.earliest_ripple_time then
                table.insert(ctx.clips_to_shift, other_clip)
            end
        end

        table.sort(ctx.clips_to_shift, function(a, b) return a.timeline_start < b.timeline_start end)

        for _, clip_info in ipairs(ctx.clips_to_shift) do
            ctx.shift_lookup[clip_info.id] = true
        end
    end

	    local function compute_shift_bounds(ctx)
	        assert(ctx.clips_to_shift, "compute_shift_bounds: clips_to_shift is nil")
	        local min_frames = -math.huge
	        local max_frames = math.huge

        local function accumulate_bounds_for_clip(shift_clip_data)
            local neighbors = ctx.neighbor_bounds_cache and ctx.neighbor_bounds_cache[shift_clip_data.id]
            assert(neighbors, "compute_shift_bounds: missing neighbor cache for clip " .. tostring(shift_clip_data.id))
            assert(shift_clip_data.timeline_start and shift_clip_data.timeline_start.frames, "compute_shift_bounds: clip missing timeline_start.frames")
            assert(shift_clip_data.duration and shift_clip_data.duration.frames, "compute_shift_bounds: clip missing duration.frames")

            local start_frames = shift_clip_data.timeline_start.frames
            local end_frames = start_frames + shift_clip_data.duration.frames

	            local function current_start_frames(clip_id)
	                local clip = ctx.modified_clips[clip_id] or ctx.clip_lookup[clip_id] or ctx.base_clips[clip_id]
	                if not clip or not clip.timeline_start or not clip.timeline_start.frames then
	                    return nil
	                end
	                return clip.timeline_start.frames
	            end

	            local function current_end_frames(clip_id)
	                local clip = ctx.modified_clips[clip_id] or ctx.clip_lookup[clip_id] or ctx.base_clips[clip_id]
	                if not clip or not clip.timeline_start or not clip.duration then
	                    return nil
	                end
	                local s = clip.timeline_start.frames
	                local d = clip.duration.frames
	                if s == nil or d == nil then
	                    return nil
	                end
	                return s + d
	            end

	            local prev_is_shifting = neighbors.prev_id and ctx.shift_lookup and ctx.shift_lookup[neighbors.prev_id]
	            if neighbors.prev_end_frames and not prev_is_shifting then
	                local prev_end = neighbors.prev_end_frames
	                if neighbors.prev_id and ctx.edited_lookup_for_shifts[neighbors.prev_id] then
	                    local updated_end = current_end_frames(neighbors.prev_id)
	                    if updated_end ~= nil then
	                        prev_end = updated_end
	                    end
	                end
	                local bound = prev_end - start_frames
	                if bound > min_frames then min_frames = bound end
	            end

	            local next_is_shifting = neighbors.next_id and ctx.shift_lookup and ctx.shift_lookup[neighbors.next_id]
	            if neighbors.next_start_frames and not next_is_shifting then
	                local next_start = neighbors.next_start_frames
	                if neighbors.next_id and ctx.edited_lookup_for_shifts[neighbors.next_id] then
	                    local updated_start = current_start_frames(neighbors.next_id)
	                    if updated_start ~= nil then
	                        next_start = updated_start
	                    end
	                end
	                local bound = next_start - end_frames
	                if bound < max_frames then max_frames = bound end
	            end
        end

        for _, shift_clip_data in ipairs(ctx.clips_to_shift) do
            accumulate_bounds_for_clip(shift_clip_data)
        end

        if ctx.bulk_shift_anchor_clips then
            for _, shift_clip_data in ipairs(ctx.bulk_shift_anchor_clips) do
                accumulate_bounds_for_clip(shift_clip_data)
            end
        end

        return min_frames, max_frames
    end

	    local function build_preview_shift_blocks(ctx)
	        local blocks = {}
	        local global_shift = (ctx.downstream_shift_rat and ctx.downstream_shift_rat.frames) or 0
	        local global_start_frames = ctx.earliest_ripple_time and ctx.earliest_ripple_time.frames
	        if global_start_frames == nil then
	            return blocks
	        end

	        if global_shift ~= 0 then
	            table.insert(blocks, {start_frames = global_start_frames, delta_frames = global_shift})
	        end
	        for track_id, shift_rat in pairs(ctx.track_shift_amounts or {}) do
	            assert(shift_rat and shift_rat.frames ~= nil, "build_preview_shift_blocks: track shift missing frames for track " .. tostring(track_id))
	            local frames = shift_rat.frames
	            local start_frames = ctx.track_ripple_start_frames and ctx.track_ripple_start_frames[track_id] or global_start_frames
	            if frames ~= 0 and (frames ~= global_shift or start_frames ~= global_start_frames) then
	                table.insert(blocks, {start_frames = start_frames, delta_frames = frames, track_id = track_id})
	            end
	        end
	        return blocks
	    end

    local function compute_downstream_shifts(ctx, db)
        -- Roll-only operations do not ripple-shift downstream clips. Avoid scanning the
        -- entire timeline to build a no-op shift list (can be thousands of clips).
        if not ctx.has_ripple_edge then
            ctx.clips_to_shift = {}
            ctx.shift_lookup = {}
            if ctx.dry_run and type(ctx.preloaded_clip_snapshot) == "table" then
                ctx.shift_blocks = {}
            end
            return true
        end

        -- If nothing is shifting (all shift vectors are zero), skip downstream enumeration.
        local downstream_shift = (ctx.downstream_shift_rat and ctx.downstream_shift_rat.frames) or 0
        local has_nonzero = downstream_shift ~= 0
        if not has_nonzero and ctx.track_shift_amounts then
            for _, shift_rat in pairs(ctx.track_shift_amounts) do
                if shift_rat and shift_rat.frames and shift_rat.frames ~= 0 then
                    has_nonzero = true
                    break
                end
            end
        end
	        if not has_nonzero then
	            ctx.clips_to_shift = {}
	            ctx.shift_lookup = {}
	            if ctx.dry_run and type(ctx.preloaded_clip_snapshot) == "table" then
	                ctx.shift_blocks = {}
	            end
	            return true
	        end

        ctx.bulk_shift_anchor_lookup = nil
        if type(ctx.preloaded_clip_snapshot) == "table" and type(ctx.preloaded_clip_snapshot.post_boundary_first_clip) == "table" then
            ctx.bulk_shift_anchor_lookup = {}
            for _, clip_id in pairs(ctx.preloaded_clip_snapshot.post_boundary_first_clip) do
                if clip_id then
                    ctx.bulk_shift_anchor_lookup[clip_id] = true
                end
            end
        end

	        collect_downstream_clips(ctx)

	        if type(ctx.preloaded_clip_snapshot) == "table" and type(ctx.preloaded_clip_snapshot.post_boundary_first_clip) == "table" then
	            ctx.bulk_shift_anchor_clips = {}
	            for _, clip_id in pairs(ctx.preloaded_clip_snapshot.post_boundary_first_clip) do
	                if clip_id then
	                    ctx.shift_lookup[clip_id] = true
                        local anchor = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
                        assert(anchor, "compute_downstream_shifts: missing bulk shift anchor clip " .. tostring(clip_id))
                        table.insert(ctx.bulk_shift_anchor_clips, anchor)
	                end
	            end
	        end

	        assert(ctx.clips_to_shift, "compute_downstream_shifts: clips_to_shift is nil")
	        local min_shift_frames, max_shift_frames = compute_shift_bounds(ctx)
	        local desired_shift_frames = ctx.downstream_shift_rat.frames
	        local adjusted_frames = desired_shift_frames

        if min_shift_frames ~= -math.huge and desired_shift_frames < min_shift_frames then
            adjusted_frames = min_shift_frames
        end
        if max_shift_frames ~= math.huge and desired_shift_frames > max_shift_frames then
            adjusted_frames = max_shift_frames
        end
        local forced_retry = ctx.command:get_parameter("__force_retry_delta")
        if forced_retry then
            adjusted_frames = forced_retry
        end

        if adjusted_frames ~= desired_shift_frames then
            return false, adjusted_frames
        end

        local snapshot_preview = ctx.dry_run and type(ctx.preloaded_clip_snapshot) == "table"
        for _, shift_clip_data in ipairs(ctx.clips_to_shift) do
            local shift_clip = nil

            if snapshot_preview then
                local base_clip = ctx.clip_lookup and ctx.clip_lookup[shift_clip_data.id] or shift_clip_data
                if base_clip then
                    if not ctx.original_states_map[base_clip.id] then
                        ctx.original_states_map[base_clip.id] = command_helper.capture_clip_state(base_clip)
                    end
                    shift_clip = snapshot_clip_for_gap(ctx, base_clip)
                end
            else
                shift_clip = load_clip_for_edit(ctx, shift_clip_data.id, db)
            end

            if not shift_clip then
                logger.warn("ripple", string.format("BatchRippleEdit: Downstream clip %s not found. Skipping shift.", tostring(shift_clip_data.id)))
                goto continue_shift
            end

            local track_shift = ctx.track_shift_amounts[shift_clip.track_id] or ctx.downstream_shift_rat
            shift_clip.timeline_start = shift_clip.timeline_start + track_shift
            ctx.modified_clips[shift_clip.id] = shift_clip

            ::continue_shift::
        end

	        if ctx.dry_run and type(ctx.preloaded_clip_snapshot) == "table" then
	            -- Preview mode: represent *far downstream* movement as shift blocks rather than
	            -- enumerating every downstream clip. We still shift clips inside the preloaded
	            -- snapshot so the active interaction region stays accurate.
	            ctx.shift_blocks = build_preview_shift_blocks(ctx)
	        elseif type(ctx.preloaded_clip_snapshot) == "table" and type(ctx.preloaded_clip_snapshot.post_boundary_first_clip) == "table" then
	            assert(type(ctx.timeline_active_region) == "table" and ctx.timeline_active_region.bulk_shift_start_frames,
	                "compute_downstream_shifts: missing timeline_active_region.bulk_shift_start_frames for bulk shift")
	            for track_id, clip_id in pairs(ctx.preloaded_clip_snapshot.post_boundary_first_clip) do
	                local track_shift = ctx.track_shift_amounts[track_id] or ctx.downstream_shift_rat
	                local frames = track_shift and track_shift.frames or 0
	                if clip_id and frames ~= 0 then
                        local anchor = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
                        assert(anchor and anchor.timeline_start and anchor.timeline_start.frames, "compute_downstream_shifts: bulk shift anchor clip missing timeline_start.frames " .. tostring(clip_id))
	                    table.insert(ctx.bulk_shift_mutations, {
	                        type = "bulk_shift",
	                        track_id = track_id,
	                        shift_frames = frames,
	                        first_clip_id = clip_id,
                            anchor_start_frame = anchor.timeline_start.frames,
	                        start_frames = ctx.timeline_active_region.bulk_shift_start_frames
	                    })
	                end
	            end
	        end

	        return true
	    end

	    local function retry_with_adjusted_delta(ctx, adjusted_frames)
	        local retry_count = ctx.command:get_parameter("__retry_delta_count") or 0
	        if retry_count > ui_constants.TIMELINE.MAX_RIPPLE_CONSTRAINT_RETRIES then
	            return false, "Failed to clamp ripple delta without overlap (retry limit)"
	        end

        ctx.command:set_parameter("__retry_delta_count", retry_count + 1)
        ctx.command:set_parameter("delta_ms", nil)

	        local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
	        local anchor_sign = ctx.ripple_anchor_negated and -1 or 1
	        local retry_delta_frames = adjusted_frames
	        if shift_factor ~= 0 and anchor_sign ~= 0 then
	            retry_delta_frames = adjusted_frames / (shift_factor * anchor_sign)
	        end

        ctx.command:set_parameter("delta_frames", retry_delta_frames)
        local adjusted_rat = Rational.new(adjusted_frames, ctx.seq_fps_num, ctx.seq_fps_den)
        ctx.command:set_parameter("clamped_delta_ms", adjusted_rat:to_milliseconds())

        return command_executors["BatchRippleEdit"](ctx.command)
    end

		    local function build_planned_mutations(ctx)
		        local shift_frames = ctx.downstream_shift_rat.frames or 0
		        local growth_frames = ctx.clamped_delta_rat.frames or 0

		        local temp_gap_mutations = {}
		        local clip_mutations = {}

		        local function sort_key_start_frames(mut)
		            if mut.type == "update" then
		                assert(type(mut.timeline_start_frame) == "number", "build_planned_mutations: update missing timeline_start_frame")
		                return mut.timeline_start_frame
		            end
		            if mut.type == "delete" then
		                local prev = mut.previous
		                assert(type(prev) == "table", "build_planned_mutations: delete missing previous state")
		                local start_value = prev.timeline_start or prev.start_value
		                if type(start_value) == "table" and start_value.frames ~= nil then
		                    return start_value.frames
		                end
		                assert(type(start_value) == "number", "build_planned_mutations: delete previous missing timeline_start frames")
		                return start_value
		            end
		            error("build_planned_mutations: unsupported mutation type for sorting: " .. tostring(mut.type))
		        end

		        for id, clip in pairs(ctx.modified_clips) do
		            local original = ctx.original_states_map[id]
		            local is_temp_gap_clip = type(id) == "string" and id:find("^temp_gap_")
		            if clip and is_temp_gap_clip then
		                if ctx.dry_run then
		                    assert(clip.timeline_start and clip.timeline_start.frames ~= nil, "build_planned_mutations: temp gap missing timeline_start.frames")
		                    assert(clip.duration and clip.duration.frames ~= nil, "build_planned_mutations: temp gap missing duration.frames")
		                    table.insert(temp_gap_mutations, {
		                        type = "temp_gap",
		                        clip_id = id,
		                        timeline_start_frame = clip.timeline_start.frames,
		                        duration_frames = clip.duration.frames
		                    })
		                end
		            else
		                if ctx.clips_marked_delete and ctx.clips_marked_delete[id] then
		                    table.insert(clip_mutations, clip_mutator.plan_delete(original))
		                else
		                    table.insert(clip_mutations, clip_mutator.plan_update(clip, original))
		                end
		            end
		        end

		        local pre_bulk_shifts = {}
		        local post_bulk_shifts = {}
		        if ctx.bulk_shift_mutations and #ctx.bulk_shift_mutations > 0 then
		            for _, mut in ipairs(ctx.bulk_shift_mutations) do
		                assert(type(mut) == "table" and mut.type == "bulk_shift", "build_planned_mutations: expected bulk_shift mutation")
		                local delta = mut.shift_frames
		                assert(type(delta) == "number", "build_planned_mutations: bulk_shift.shift_frames must be a number")
		                if delta > 0 then
		                    table.insert(pre_bulk_shifts, mut)
		                elseif delta < 0 then
		                    table.insert(post_bulk_shifts, mut)
		                end
		            end
		        end

		        table.sort(clip_mutations, function(a, b)
		            if a.type == "delete" and b.type ~= "delete" then return true end
		            if b.type == "delete" and a.type ~= "delete" then return false end

		            local t_a = sort_key_start_frames(a)
		            local t_b = sort_key_start_frames(b)

		            if shift_frames > 0 then
		                return t_a > t_b
		            elseif shift_frames < 0 then
		                return t_a < t_b
		            else
		                if growth_frames > 0 then
		                    return t_a > t_b
		                end
		                return t_a < t_b
		            end
		        end)

		        ctx.planned_mutations = {}
		        for _, mut in ipairs(pre_bulk_shifts) do
		            table.insert(ctx.planned_mutations, mut)
		        end
		        for _, mut in ipairs(clip_mutations) do
		            table.insert(ctx.planned_mutations, mut)
		        end
		        for _, mut in ipairs(post_bulk_shifts) do
		            table.insert(ctx.planned_mutations, mut)
		        end
		        for _, mut in ipairs(temp_gap_mutations) do
		            table.insert(ctx.planned_mutations, mut)
		        end

		        if ctx.dry_run then
		            ctx.preview_shifted_clips = ctx.preview_shifted_clips or {}
		            ctx.preview_shifted_lookup = ctx.preview_shifted_lookup or {}
		            assert(ctx.clips_to_shift, "build_planned_mutations: clips_to_shift is nil")
		            for _, shift_clip in ipairs(ctx.clips_to_shift) do
		                local track_shift = ctx.track_shift_amounts[shift_clip.track_id] or ctx.downstream_shift_rat
		                local new_start = shift_clip.timeline_start + track_shift
		                if new_start.frames < 0 then
		                    new_start = Rational.new(0, new_start.fps_numerator, new_start.fps_denominator)
		                end
		                if not ctx.preview_shifted_lookup[shift_clip.id] then
		                    add_preview_shift(ctx, shift_clip.id, new_start, shift_clip.duration)
		                else
		                    for _, entry in ipairs(ctx.preview_shifted_clips) do
		                        if entry.clip_id == shift_clip.id then
		                            entry.new_start_value = new_start
		                            entry.new_duration = shift_clip.duration
		                            break
		                        end
		                    end
		                end
		            end
		        end
		    end

    local function key_matches_clamp_sources(ctx, original_key, target_key)
        local relevant_map = nil
        if ctx.clamp_direction == -1 then
            relevant_map = ctx.global_min_edge_keys
        elseif ctx.clamp_direction == 1 then
            relevant_map = ctx.global_max_edge_keys
        end
        if not relevant_map or not next(relevant_map) then
            return true
        end
        if relevant_map[target_key] then
            return true
        end
        if original_key and relevant_map[original_key] then
            relevant_map[target_key] = true
            relevant_map[original_key] = nil
            return true
        end
        return false
    end

	    local function finalize_execution(ctx, db)
	        ctx.command:set_parameter("original_states", ctx.original_states_map)
	        if ctx.bulk_shift_mutations and #ctx.bulk_shift_mutations > 0 then
	            ctx.command:set_parameter("bulk_shifts", ctx.bulk_shift_mutations)
	        else
	            ctx.command:set_parameter("bulk_shifts", nil)
	        end
	        local order = {}
	        for _, mut in ipairs(ctx.planned_mutations or {}) do
	            if type(mut) == "table" and mut.type and mut.clip_id and mut.type ~= "temp_gap" then
	                table.insert(order, {type = mut.type, clip_id = mut.clip_id})
	            end
	        end
        ctx.command:set_parameter("executed_mutation_order", order)
        -- Avoid persisting the full mutation list (can be thousands of entries).
        -- Undo will hydrate from original_states + executed_mutation_order.
        ctx.command:set_parameter("executed_mutations", nil)

	        if ctx.dry_run then
	            local clamped_edges = {}
	            local final_delta = ctx.clamped_delta_rat.frames
	            for edge_key, limits in pairs(ctx.per_edge_constraints) do
	                local min_hit = (limits.min ~= -math.huge and final_delta == limits.min)
	                local max_hit = (limits.max ~= math.huge and final_delta == limits.max)
	                if min_hit or max_hit then
	                    local target_key = edge_key
	                    if key_matches_clamp_sources(ctx, edge_key, target_key) then
	                        clamped_edges[target_key] = true
	                    end
	                end
	            end
	            for key in pairs(ctx.forced_clamped_edges or {}) do
	                clamped_edges[key] = true
	            end
	
	            local function merge_edge_keys(edge_keys)
	                if not edge_keys then
	                    return
	                end
	                for key in pairs(edge_keys) do
	                    clamped_edges[key] = true
	                end
	            end
	            if ctx.global_min_frames ~= -math.huge and final_delta == ctx.global_min_frames then
	                merge_edge_keys(ctx.global_min_edge_keys)
	            end
	            if ctx.global_max_frames ~= math.huge and final_delta == ctx.global_max_frames then
	                merge_edge_keys(ctx.global_max_edge_keys)
	            end

                local function build_edge_preview_payload()
                    local edge_preview = {
                        requested_delta_frames = ctx.delta_rat and ctx.delta_rat.frames or 0,
                        clamped_delta_frames = ctx.clamped_delta_rat and ctx.clamped_delta_rat.frames or 0,
                        edges = {},
                        limiter_edge_keys = clamped_edges
                    }

                    local edges_by_key = {}
                    local function upsert(entry)
                        if not entry or not entry.edge_key then
                            return
                        end
                        local existing = edges_by_key[entry.edge_key]
                        if existing then
                            if entry.is_limiter then existing.is_limiter = true end
                            return
                        end
                        edges_by_key[entry.edge_key] = entry
                        table.insert(edge_preview.edges, entry)
                    end

                    local lead_normalized = nil
                    if ctx.lead_edge_entry then
                        lead_normalized = ctx.lead_edge_entry.normalized_edge
                            or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type)
                    end
                    local global_sign = signum(ctx.clamped_delta_rat and ctx.clamped_delta_rat.frames or 0)

                    -- Selected edges.
                    for _, edge_info in ipairs(ctx.edge_infos or {}) do
                        local raw_edge_type = edge_info.edge_type
                        local anchor_clip_id = edge_info.original_clip_id or edge_info.clip_id
                        if anchor_clip_id and raw_edge_type then
                            local edge_key = string.format("%s:%s", tostring(anchor_clip_id), tostring(raw_edge_type))
                            local source_key = build_edge_key(edge_info)
                            local applied = compute_applied_delta(ctx, source_key)
                            upsert({
                                edge_key = edge_key,
                                clip_id = anchor_clip_id,
                                track_id = edge_info.track_id,
                                raw_edge_type = raw_edge_type,
                                normalized_edge = edge_info.normalized_edge or edge_utils.to_bracket(raw_edge_type),
                                is_selected = true,
                                is_implied = false,
                                is_limiter = clamped_edges[edge_key] == true,
                                applied_delta_frames = applied and applied.frames or 0
                            })
                        end
                    end

                    -- Implied edges from track shifts (Rule 8.5).
                    local boundary_default = (ctx.earliest_ripple_time and ctx.earliest_ripple_time.frames) or 0
                    for track_id in pairs(ctx.affected_tracks or {}) do
                        if track_id and not (ctx.selected_tracks and ctx.selected_tracks[track_id]) then
                            local shift = (ctx.track_shift_amounts and ctx.track_shift_amounts[track_id]) or ctx.downstream_shift_rat
                            local shift_frames = shift and shift.frames or 0
                            if shift_frames ~= 0 then
                                local desired = infer_implied_normalized_edge(lead_normalized, signum(shift_frames), global_sign)
                                local raw_edge_type = (desired == "in") and "gap_after" or "gap_before"
                                local boundary_frames = (ctx.track_ripple_start_frames and ctx.track_ripple_start_frames[track_id]) or boundary_default
                                local track_clips = ctx.track_clip_map and ctx.track_clip_map[track_id] or {}
                                local anchor_clip_id = pick_gap_anchor_clip_id(track_clips, boundary_frames, raw_edge_type)
                                if anchor_clip_id then
                                    local edge_key = string.format("%s:%s", tostring(anchor_clip_id), tostring(raw_edge_type))
                                    upsert({
                                        edge_key = edge_key,
                                        clip_id = anchor_clip_id,
                                        track_id = track_id,
                                        raw_edge_type = raw_edge_type,
                                        normalized_edge = desired or edge_utils.to_bracket(raw_edge_type),
                                        is_selected = false,
                                        is_implied = true,
                                        is_limiter = clamped_edges[edge_key] == true,
                                        applied_delta_frames = shift_frames
                                    })
                                end
                            end
                        end
                    end

                    -- Ensure every limiter edge has a render entry.
                    for key in pairs(clamped_edges or {}) do
                        if not edges_by_key[key] and type(key) == "string" then
                            local clip_id, edge_type = key:match("^(.*):([^:]+)$")
                            if clip_id and edge_type and clip_id ~= "" then
                                local clip = (ctx.clip_lookup and ctx.clip_lookup[clip_id]) or nil
                                local track_id = (clip and clip.track_id) or (ctx.clip_track_lookup and ctx.clip_track_lookup[clip_id]) or nil
                                local shift = track_id and ctx.track_shift_amounts and ctx.track_shift_amounts[track_id] or nil
                                local shift_frames = shift and shift.frames or 0
                                upsert({
                                    edge_key = key,
                                    clip_id = clip_id,
                                    track_id = track_id,
                                    raw_edge_type = edge_type,
                                    normalized_edge = edge_utils.to_bracket(edge_type),
                                    is_selected = false,
                                    is_implied = true,
                                    is_limiter = true,
                                    applied_delta_frames = shift_frames
                                })
                            end
                        end
                    end

                    return edge_preview
                end
	
	            return true, {
	                planned_mutations = ctx.planned_mutations,
	                affected_clips = ctx.preview_affected_clips,
                shifted_clips = ctx.preview_shifted_clips,
                shift_blocks = ctx.shift_blocks,
                clamped_delta_ms = ctx.clamped_delta_rat:to_milliseconds(),
                materialized_gaps = ctx.materialized_gap_ids,
                clamped_edges = clamped_edges,
                edge_preview = build_edge_preview_payload()
            }
        end

        local ok_apply, apply_err = command_helper.apply_mutations(db, ctx.planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end

        -- Provide incremental UI mutations so CommandManager can update the
        -- timeline without reloading the full clip list.
        local seq_id = ctx.sequence_id
        assert(seq_id and seq_id ~= "", "BatchRippleEdit: missing sequence_id for timeline mutations")
	        for _, mut in ipairs(ctx.planned_mutations or {}) do
	            if mut.type == "update" then
	                command_helper.add_update_mutation(ctx.command, seq_id, {
	                    clip_id = mut.clip_id,
	                    track_id = mut.track_id,
	                    start_value = mut.timeline_start_frame,
	                    duration_value = mut.duration_frames,
	                    source_in_value = mut.source_in_frame,
	                    source_out_value = mut.source_out_frame,
	                    enabled = (mut.enabled == 1) or (mut.enabled == true)
	                })
	            elseif mut.type == "delete" then
	                command_helper.add_delete_mutation(ctx.command, seq_id, mut.clip_id)
	            elseif mut.type == "insert" then
	                local inserted = Clip.load_optional(mut.clip_id, db)
	                if inserted then
	                    local payload = command_helper.clip_insert_payload(inserted, seq_id)
	                    if payload then
	                        command_helper.add_insert_mutation(ctx.command, seq_id, payload)
	                    end
	                end
	            elseif mut.type == "bulk_shift" then
	                command_helper.add_bulk_shift_mutation(ctx.command, seq_id, {
	                    track_id = mut.track_id,
	                    first_clip_id = mut.first_clip_id,
                        anchor_start_frame = mut.anchor_start_frame,
	                    shift_frames = mut.shift_frames,
	                    start_frames = mut.start_frames,
                        clip_ids = mut.clip_ids,
	                })
	            end
	        end

	        logger.info("ripple", string.format("Batch ripple: processed %d edges, shifted %d downstream clips by %s",
	            #ctx.edge_infos, #(ctx.clips_to_shift or {}), tostring(ctx.downstream_shift_rat)))

	        return true
	    end

    command_executors["BatchRippleEdit"] = function(command)
        local ctx = batch_context.create(command)

        if not ctx.edge_infos or #ctx.edge_infos == 0 then
            logger.error("ripple", "BatchRippleEdit missing edge_infos")
            return false
        end

        if not ctx.delta_frames and not ctx.delta_ms then
            logger.error("ripple", "BatchRippleEdit missing delta")
            return false
        end

        if not ctx.dry_run then
            logger.info("ripple", "Executing BatchRippleEdit command")
        end

        return batch_pipeline.run(ctx, db, {
            build_clip_cache = build_clip_cache,
            prime_neighbor_bounds_cache = prime_neighbor_bounds_cache,
            materialize_gap_edges = materialize_gap_edges,
            assign_edge_tracks = assign_edge_tracks,
            determine_lead_edge = determine_lead_edge,
            analyze_selection = analyze_selection,
            compute_constraints = compute_constraints,
            process_edge_trims = process_edge_trims,
            compute_downstream_shifts = compute_downstream_shifts,
            retry_with_adjusted_delta = retry_with_adjusted_delta,
            build_planned_mutations = build_planned_mutations,
            finalize_execution = finalize_execution,
        })
    end

		    command_undoers["BatchRippleEdit"] = function(command)
		        logger.info("ripple", "Undoing BatchRippleEdit command")

		        local executed_mutations = hydrate_executed_mutations_if_missing(command)
		        local sequence_id = command:get_parameter("sequence_id")

		        local started, begin_err = db:begin_transaction()
		        if not started then
		            if string.find(tostring(begin_err), "cannot start a transaction within a transaction") then
		                started = nil
		            else
		                logger.error("ripple", "UndoBatchRippleEdit: Failed to begin transaction: " .. tostring(begin_err))
		                return false, begin_err
		            end
		        end

		        local ok, success, err = pcall(command_helper.revert_mutations, db, executed_mutations, command, sequence_id)
		        if not ok then
		            if started then db:rollback_transaction(started) end
		            logger.error("ripple", "UndoBatchRippleEdit: Failed to revert mutations: " .. tostring(success))
		            return false, success
		        end
		        if success ~= true then
		            if started then db:rollback_transaction(started) end
		            logger.error("ripple", "UndoBatchRippleEdit: Failed to revert mutations: " .. tostring(err))
		            return false, err
		        end
		        
		        if started then
		            local ok_commit, commit_err = db:commit_transaction(started)
		            if not ok_commit then
		                db:rollback_transaction(started)
		                return false, "Failed to commit undo transaction: " .. tostring(commit_err)
		            end
		        end

	        logger.info("ripple", "Undo Batch ripple: Reverted all changes")
	        return true
	    end

    command_executors["UndoBatchRippleEdit"] = command_undoers["BatchRippleEdit"]

    return {
        executor = command_executors["BatchRippleEdit"],
        undoer = command_undoers["BatchRippleEdit"]
    }
end

return M
