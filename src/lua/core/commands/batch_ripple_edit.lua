local M = {}
local Clip = require('models.clip')
local database = require('core.database')
local frame_utils = require('core.frame_utils')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local edge_utils = require("ui.timeline.edge_utils")
local ui_constants = require("core.ui_constants")
local timeline_state
do
    local status, mod = pcall(require, 'ui.timeline.timeline_state')
    if status then timeline_state = mod end
end
local clip_mutator = require('core.clip_mutator') -- New dependency
local json = require("dkjson")

local function get_edge_track_id(edge_info, clip_lookup, original_states_map)
    if edge_info.track_id and edge_info.track_id ~= "" then
        return edge_info.track_id
    end
    if clip_lookup and clip_lookup[edge_info.clip_id] then
        return clip_lookup[edge_info.clip_id].track_id
    end
    local original = original_states_map and original_states_map[edge_info.clip_id]
    if original then
        return original.track_id
    end
    return nil
end

local function compute_edge_boundary_time(edge_info, original_states_map)
    if not edge_info or not original_states_map then
        return nil
    end
    local clip_state = original_states_map[edge_info.clip_id]
    if not clip_state then
        return nil
    end
    local raw_edge = edge_info.edge_type
    local normalized_edge = edge_info.normalized_edge or edge_utils.to_bracket(raw_edge)
    if raw_edge == "gap_before" then
        return clip_state.timeline_start
    elseif raw_edge == "gap_after" then
        return clip_state.timeline_start + clip_state.duration
    elseif normalized_edge == "in" then
        return clip_state.timeline_start
    elseif normalized_edge == "out" then
        return clip_state.timeline_start + clip_state.duration
    end
    return nil
end

local function build_edge_key(edge_info)
    if not edge_info then
        return "::"
    end
    local source_id = edge_info.original_clip_id or edge_info.clip_id
    return string.format("%s:%s", tostring(source_id or ""), tostring(edge_info.edge_type or ""))
end

local function hydrate_executed_mutations_if_missing(command)
    if not command or not command.get_parameter then
        error("BatchRippleEdit undo: invalid command handle")
    end
    local executed = command:get_parameter("executed_mutations")
    if type(executed) == "table" and next(executed) ~= nil then
        return executed
    end

    local originals = command:get_parameter("original_states")
    if type(originals) ~= "table" or next(originals) == nil then
        error("BatchRippleEdit undo: command missing executed_mutations and original_states")
    end

    local conn = database.get_connection()
    if not conn then
        error("BatchRippleEdit undo: no database connection available to hydrate mutations")
    end

    local sequence_id = command:get_parameter("sequence_id")
    local project_id = command.project_id or command:get_parameter("project_id") or "default_project"

    local function normalized_state(state)
        local copy = {}
        for k, v in pairs(state) do
            copy[k] = v
        end
        copy.project_id = copy.project_id or project_id
        copy.clip_kind = copy.clip_kind or "timeline"
        copy.owner_sequence_id = copy.owner_sequence_id or copy.track_sequence_id or sequence_id
        copy.track_sequence_id = copy.track_sequence_id or copy.owner_sequence_id
        return copy
    end

    local function clip_exists(clip_id)
        if not clip_id or clip_id == "" then
            return false
        end
        local stmt = conn:prepare("SELECT 1 FROM clips WHERE id = ? LIMIT 1")
        if not stmt then
            error("BatchRippleEdit undo: failed to inspect clip existence")
        end
        stmt:bind_value(1, clip_id)
        local exists = stmt:exec() and stmt:next()
        stmt:finalize()
        return exists
    end

    local rebuilt = {}
    for _, state in pairs(originals) do
        if type(state) == "table" and state.id then
            local prev = normalized_state(state)
            local tag = clip_exists(state.id) and "update" or "delete"
            table.insert(rebuilt, {
                type = tag,
                clip_id = state.id,
                previous = prev
            })
        end
    end

    if #rebuilt == 0 then
        error("BatchRippleEdit undo: unable to hydrate executed_mutations (no original states)")
    end

    command:set_parameter("executed_mutations", rebuilt)

    if command.sequence_number then
        local params = command.parameters or {}
        local encoded = json.encode(params)
        local stmt = conn:prepare("UPDATE commands SET command_args = ? WHERE sequence_number = ?")
        if stmt then
            stmt:bind_value(1, encoded)
            stmt:bind_value(2, command.sequence_number)
            if not stmt:exec() then
                print(string.format("WARNING: Failed to persist hydrated executed_mutations for sequence %s", tostring(command.sequence_number)))
            end
            stmt:finalize()
        end
    end

    return rebuilt
end

local function bracket_for_normalized_edge(edge_type)
    if edge_type == "in" then
        return "["
    elseif edge_type == "out" then
        return "]"
    end
    return nil
end

local function find_next_clip_on_track(all_clips, clip)
    if not clip or not clip.track_id then return nil end
    assert(all_clips, "find_next_clip_on_track: all_clips is nil")
    local clip_end = clip.timeline_start + clip.duration
    local best = nil
    for _, other in ipairs(all_clips) do
        if other.id ~= clip.id and other.track_id == clip.track_id then
            local other_start = other.timeline_start
            if other_start >= clip_end then
                if not best or other_start < best.timeline_start then
                    best = other
                end
            end
        end
    end
    return best
end

local function find_prev_clip_on_track(all_clips, clip)
    if not clip or not clip.track_id then return nil end
    assert(all_clips, "find_prev_clip_on_track: all_clips is nil")
    local start_value = clip.timeline_start
    local best = nil
    for _, other in ipairs(all_clips) do
        if other.id ~= clip.id and other.track_id == clip.track_id then
            local other_end = other.timeline_start + other.duration
            if other_end <= start_value then
                if not best or other_end > (best.timeline_start + best.duration) then
                    best = other
                end
            end
        end
    end
    return best
end

local function build_track_clip_map(all_clips)
    assert(all_clips, "build_track_clip_map: all_clips is nil")
    local map = {}
    for _, clip in ipairs(all_clips) do
        local track_id = clip.track_id
        if track_id then
            map[track_id] = map[track_id] or {}
            table.insert(map[track_id], clip)
        end
    end
    for _, list in pairs(map) do
        table.sort(list, function(a, b)
            if a.timeline_start == b.timeline_start then
                return (a.id or "") < (b.id or "")
            end
            return a.timeline_start < b.timeline_start
        end)
    end
    return map
end

-- Materialize a synthetic clip representing the requested gap edge so downstream
-- logic (trim/apply) can treat it like a normal clip. Returns nil when the edge
-- no longer corresponds to a real gap because the neighbors are missing.
local function create_temp_gap_clip(edge_info, clip_lookup, all_clips, track_clip_map, seq_fps_num, seq_fps_den)
        if not edge_info or (edge_info.edge_type ~= "gap_after" and edge_info.edge_type ~= "gap_before") then
            return nil
        end

        local function ensure_rational(value)
            if getmetatable(value) == Rational.metatable then
                return value:rescale(seq_fps_num, seq_fps_den)
            end
            if type(value) == "table" and value.frames then
                return Rational.new(value.frames, value.fps_numerator or seq_fps_num, value.fps_denominator or seq_fps_den)
            end
            return Rational.new(value or 0, seq_fps_num, seq_fps_den)
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
        if not duration or not duration.frames then
            duration = Rational.new(0, seq_fps_num, seq_fps_den)
        end
        if duration.frames < 0 then
            duration = Rational.new(0, seq_fps_num, seq_fps_den)
    end

    local temp_id = string.format("temp_gap_%s_%s_%s", tostring(track_id), tostring(gap_start.frames or 0), tostring(gap_end.frames or 0))

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
    local clip_end = start_value + duration_value
    local prev_end = nil
    local next_start = nil
    local prev_clip_id = nil
    local next_clip_id = nil
    assert(all_clips, "compute_neighbor_bounds: all_clips is nil")
    for _, other in ipairs(all_clips) do
        if other.id ~= clip_id and other.track_id == track_id then
            local other_start = other.timeline_start
            local other_end = other.timeline_start + other.duration
            if other_end <= start_value then
                if not prev_end or other_end > prev_end then
                    prev_end = other_end
                    prev_clip_id = other.id
                end
            end
            if other_start >= clip_end then
                if not next_start or other_start < next_start then
                    next_start = other_start
                    next_clip_id = other.id
                end
            end
        end
    end
    return prev_end, next_start, prev_clip_id, next_clip_id
end

local function ensure_neighbor_bounds(ctx, clip_id)
    ctx.neighbor_bounds_cache = ctx.neighbor_bounds_cache or {}
    if not ctx.neighbor_bounds_cache[clip_id] then
        local original = ctx.original_states_map[clip_id]
        local prev_bound, next_bound, prev_id, next_id = compute_neighbor_bounds(ctx.all_clips, original, clip_id)
        ctx.neighbor_bounds_cache[clip_id] = {
            prev = prev_bound,
            next = next_bound,
            prev_id = prev_id,
            next_id = next_id
        }
    end
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
    if start_value and start_value ~= 0 then
        return start_value
    end
    local right_id = clip.gap_right_id or edge_info.original_clip_id
    if not right_id then
        return start_value
    end
    local right_original = ctx.original_states_map[right_id]
        or ctx.preloaded_clips[right_id]
        or ctx.clip_lookup[right_id]
    if right_original and right_original.timeline_start and right_original.timeline_start.frames then
        return right_original.timeline_start.frames
    end
    return start_value
end

function M.register(command_executors, command_undoers, db, set_last_error)
    -- Conditional logging based on environment variable (off by default to reduce noise)
    local log_level = os.getenv("JVE_LOG_LEVEL") or "INFO"
    local function log_debug(msg)
        if log_level == "DEBUG" then
            print("[DEBUG] " .. msg)
        end
    end

    -- Helper: Load clip and capture original state if not already cached
    local function ensure_clip_loaded(ctx, clip_id, db)
        local clip = ctx.preloaded_clips[clip_id]
        if not clip then
            clip = Clip.load_optional(clip_id, db)
            ctx.preloaded_clips[clip_id] = clip
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

        if normalized_edge == "in" then
            -- In-point: can't drag left past previous clip
            if edge_info.edge_type == "gap_after" then
                delta_min = -gap_frames
            elseif neighbors.prev and not edited_lookup[neighbors.prev_id] then
                delta_min = (neighbors.prev - original.timeline_start).frames
            end
        elseif normalized_edge == "out" then
            -- Out-point: can't drag right past next clip
            if edge_info.edge_type == "gap_before" then
                delta_max = gap_frames
            elseif neighbors.next and not edited_lookup[neighbors.next_id] then
                delta_max = (neighbors.next - (original.timeline_start + original.duration)).frames
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
            local media = ctx.preloaded_clips[clip.media_id] or require("models.media").load(clip.media_id, db)
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

    local function build_clip_cache(ctx)
        ctx.all_clips = database.load_clips(ctx.sequence_id)
        assert(ctx.all_clips, string.format("build_clip_cache: Failed to load clips for sequence %s", ctx.sequence_id))
        ctx.clip_lookup = {}
        for _, clip in ipairs(ctx.all_clips) do
            ctx.clip_lookup[clip.id] = clip
        end
        ctx.track_clip_map = build_track_clip_map(ctx.all_clips)
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
        ctx.preloaded_clips[gap_clip.id] = gap_clip
        table.insert(ctx.materialized_gap_ids, gap_clip.id)
        return gap_clip
    end

    local function materialize_gap_edges(ctx)
        assert(ctx.edge_infos and #ctx.edge_infos > 0, "materialize_gap_edges: No edge_infos provided")
        for _, edge_info in ipairs(ctx.edge_infos) do
            if is_gap_edge(edge_info.edge_type) then
                local gap_clip = create_temp_gap_clip(edge_info, ctx.clip_lookup, ctx.all_clips, ctx.track_clip_map, ctx.seq_fps_num, ctx.seq_fps_den)
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
        ctx.clip_track_lookup = {}
        ctx.affected_tracks = {}
        ctx.selected_tracks = {}
        for _, clip in ipairs(ctx.all_clips) do
            ctx.clip_track_lookup[clip.id] = clip.track_id
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
        clip = ctx.preloaded_clips[clip_id]
        if not clip then
            clip = Clip.load_optional(clip_id, db)
            if clip then
                ctx.preloaded_clips[clip_id] = clip
            end
        end
        -- Skip capturing state for temp gap clips (synthetic, not persisted)
        local is_temp_gap = type(clip_id) == "string" and clip_id:find("^temp_gap_")
        if clip and not is_temp_gap and not ctx.original_states_map[clip_id] then
            ctx.original_states_map[clip_id] = command_helper.capture_clip_state(clip)
        end
        if clip then
            ctx.modified_clips[clip_id] = clip
        end
        return clip
    end

    local function fetch_clip(ctx, clip_id, db)
        return ctx.preloaded_clips[clip_id] or Clip.load_optional(clip_id, db)
    end

-- Apply the requested trim delta to clip/gap edges and return the ripple start.
-- Returns nil when the clip collapses (e.g., trim removes media entirely).
local function apply_edge_ripple(clip, edge_type, delta_rat, trim_type, raw_edge_type)
        if type(clip.duration) ~= "table" or not clip.duration.frames then
            error("apply_edge_ripple: Clip missing Rational duration.")
        end

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
                local fps_num = (clip.duration and clip.duration.fps_numerator) or (clip.source_in and clip.source_in.fps_numerator) or 30
                local fps_den = (clip.duration and clip.duration.fps_denominator) or (clip.source_in and clip.source_in.fps_denominator) or 1
                new_duration_timeline = Rational.new(0, fps_num, fps_den)
            end
        else
            if new_duration_timeline.frames < 1 then
                return nil, false, true
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
                    local gap_clip = ctx.preloaded_clips and ctx.preloaded_clips[edge_info.clip_id]
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
        ctx.earliest_ripple_hint = nil
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.trim_type ~= "roll" then
                local original = ctx.original_states_map[edge_info.clip_id]
                if original then
                    local point = original.timeline_start
                    local edge_kind = edge_info.normalized_edge or edge_info.edge_type
                    if edge_kind == "out" then
                        point = original.timeline_start + original.duration
                    end
                    if not ctx.earliest_ripple_hint or point < ctx.earliest_ripple_hint then
                        ctx.earliest_ripple_hint = point
                    end
                end
            end
        end
    end

    local function clamp_downstream_overlaps(ctx)
        local earliest = ctx.earliest_ripple_hint
        if not earliest then
            return
        end

        local ripple_sign = 1
        if ctx.lead_edge_entry then
            local normalized = ctx.lead_edge_entry.normalized_edge or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type)
            if normalized == "in" then
                ripple_sign = -1
            end
        end
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
                local original = command_helper.capture_clip_state(clip)
                local prev_bound, next_bound, prev_id, next_id = compute_neighbor_bounds(ctx.all_clips, original, clip.id)
                if prev_bound and not ctx.edited_clip_lookup[prev_id] then
                    local prev_gap = (clip.timeline_start - prev_bound).frames
                    if prev_gap and prev_gap > 0 then
                        local implied_key = build_edge_key({clip_id = clip.id, edge_type = "gap_before"})
                        if ripple_sign >= 0 then
                            update_global_min(ctx, implied_key, -prev_gap)
                        else
                            update_global_max(ctx, implied_key, prev_gap)
                        end
                    end
                end
                if next_bound and not ctx.edited_clip_lookup[next_id] then
                    local next_gap = (next_bound - (clip.timeline_start + clip.duration)).frames
                    if next_gap and next_gap > 0 then
                        local implied_key = build_edge_key({clip_id = clip.id, edge_type = "gap_after"})
                        if ripple_sign >= 0 then
                            update_global_max(ctx, implied_key, next_gap)
                        else
                            update_global_min(ctx, implied_key, -next_gap)
                        end
                    end
                end
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
                    if key and not ctx.edge_info_for_key[key] then
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
        ctx.track_shift_seeds = {}
        ctx.track_shift_amounts = {}
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

    local function register_ripple_anchor(ctx, normalized_edge, is_gap_edge_type)
        ctx.has_ripple_edge = true
        if not ctx.ripple_anchor_edge_type then
            ctx.ripple_anchor_edge_type = normalized_edge
            ctx.ripple_anchor_is_gap = is_gap_edge_type
            return
        end
        if ctx.ripple_anchor_is_gap and not is_gap_edge_type then
            ctx.ripple_anchor_edge_type = normalized_edge
            ctx.ripple_anchor_is_gap = false
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
        if not right_id or not ctx.edited_clip_lookup[right_id] or ctx.gap_right_moved[right_id] then
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
        local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
        if ctx.has_ripple_edge then
            ctx.downstream_shift_rat = Rational.new(ctx.clamped_delta_rat.frames * shift_factor, ctx.seq_fps_num, ctx.seq_fps_den)
            local drag_sign = (ctx.clamped_delta_rat.frames >= 0) and 1 or -1
            for track_id, seed in pairs(ctx.track_shift_seeds) do
                if track_id and seed.orientation and seed.applied_delta and seed.applied_delta.frames then
                    local orientation_sign = (seed.orientation == "in") and -1 or 1
                    if seed.is_gap then
                        ctx.track_shift_amounts[track_id] = Rational.new(seed.applied_delta.frames * orientation_sign, ctx.seq_fps_num, ctx.seq_fps_den)
                    else
                        local magnitude = math.abs(seed.applied_delta.frames)
                        local track_shift_frames = magnitude * drag_sign * orientation_sign
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
                print(string.format("WARNING: BatchRippleEdit: Clip %s not found. Skipping.", tostring(clip_id):sub(1, 8)))
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
                print(string.format("ERROR: Ripple failed for clip %s", tostring(clip.id):sub(1, 8)))
                return false
            end

            if is_gap_edge(edge_info.edge_type) then
                record_gap_delta(ctx, clip_id, applied_delta)
            end

            if edge_info.trim_type ~= "roll" then
                register_ripple_anchor(ctx, normalized_edge, is_gap_edge(edge_info.edge_type))
                register_track_shift_seed(ctx, clip, normalized_edge, applied_delta, is_gap_edge(edge_info.edge_type))
            end

            record_preview_for_edge(ctx, clip, edge_info, normalized_edge)

            if deleted_clip then
                ctx.clips_marked_delete[clip_id] = true
            end

            local ripple_point = compute_ripple_point(original, clip, normalized_edge)
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

        for _, shift_clip_data in ipairs(ctx.clips_to_shift) do
            local original = {
                timeline_start = shift_clip_data.timeline_start,
                duration = shift_clip_data.duration,
                track_id = shift_clip_data.track_id
            }
            local prev_bound, next_bound, prev_id, next_id = compute_neighbor_bounds(ctx.all_clips, original, shift_clip_data.id)

            if prev_bound and prev_id and ctx.edited_lookup_for_shifts[prev_id] then
                prev_bound = nil
            end
            if prev_bound then
                local bound = (prev_bound - original.timeline_start).frames
                if bound > min_frames then min_frames = bound end
            end

            if next_bound and next_id and ctx.edited_lookup_for_shifts[next_id] then
                next_bound = nil
            end
            if next_bound then
                local bound = (next_bound - (original.timeline_start + original.duration)).frames
                if bound < max_frames then max_frames = bound end
            end
        end

        return min_frames, max_frames
    end

    local function compute_downstream_shifts(ctx, db)
        collect_downstream_clips(ctx)

        assert(ctx.clips_to_shift, "compute_downstream_shifts: clips_to_shift is nil")
        for _, shift_clip_data in ipairs(ctx.clips_to_shift) do
            local shift_clip = load_clip_for_edit(ctx, shift_clip_data.id, db)
            if not shift_clip then
                print(string.format("WARNING: BatchRippleEdit: Downstream clip %s not found. Skipping shift.", tostring(shift_clip_data.id):sub(1, 8)))
                goto continue_shift
            end

            local track_shift = ctx.track_shift_amounts[shift_clip.track_id] or ctx.downstream_shift_rat
            shift_clip.timeline_start = shift_clip.timeline_start + track_shift
            ctx.modified_clips[shift_clip.id] = shift_clip

            ::continue_shift::
        end

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
        local retry_delta_frames = adjusted_frames
        if shift_factor ~= 0 then
            retry_delta_frames = adjusted_frames / shift_factor
        end

        ctx.command:set_parameter("delta_frames", retry_delta_frames)
        local adjusted_rat = Rational.new(adjusted_frames, ctx.seq_fps_num, ctx.seq_fps_den)
        ctx.command:set_parameter("clamped_delta_ms", adjusted_rat:to_milliseconds())

        return command_executors["BatchRippleEdit"](ctx.command)
    end

    local function build_planned_mutations(ctx)
        ctx.planned_mutations = {}
        local shift_frames = ctx.downstream_shift_rat.frames or 0
        local growth_frames = ctx.clamped_delta_rat.frames or 0

        for id, clip in pairs(ctx.modified_clips) do
            local original = ctx.original_states_map[id]
            local is_temp_gap_clip = type(id) == "string" and id:find("^temp_gap_")
            if clip and is_temp_gap_clip then
                if ctx.dry_run then
                    table.insert(ctx.planned_mutations, {
                        type = "temp_gap",
                        clip_id = id,
                        timeline_start_frame = (clip.timeline_start and clip.timeline_start.frames) or 0,
                        duration_frames = (clip.duration and clip.duration.frames) or 0
                    })
                end
            else
                if ctx.clips_marked_delete and ctx.clips_marked_delete[id] then
                    table.insert(ctx.planned_mutations, clip_mutator.plan_delete(original))
                else
                    table.insert(ctx.planned_mutations, clip_mutator.plan_update(clip, original))
                end
            end
        end

        table.sort(ctx.planned_mutations, function(a, b)
            if a.type == "delete" and b.type ~= "delete" then return true end
            if b.type == "delete" and a.type ~= "delete" then return false end

            local t_a = a.timeline_start_frame or 0
            local t_b = b.timeline_start_frame or 0

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
                    -- If an entry already exists (e.g., from temp gap propagation), update to the downstream value if it differs.
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
        ctx.command:set_parameter("executed_mutations", ctx.planned_mutations)

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

            return true, {
                planned_mutations = ctx.planned_mutations,
                affected_clips = ctx.preview_affected_clips,
                shifted_clips = ctx.preview_shifted_clips,
                clamped_delta_ms = ctx.clamped_delta_rat:to_milliseconds(),
                materialized_gaps = ctx.materialized_gap_ids,
                clamped_edges = clamped_edges
            }
        end

        local ok_apply, apply_err = command_helper.apply_mutations(db, ctx.planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end

        print(string.format("✅ Batch ripple: processed %d edges, shifted %d downstream clips by %s",
            #ctx.edge_infos, #(ctx.clips_to_shift or {}), tostring(ctx.downstream_shift_rat)))

        return true
    end

    local function create_execution_context(command)
        local ctx = {
            command = command,
            dry_run = command:get_parameter("dry_run"),
            edge_infos_raw = command:get_parameter("edge_infos"),
            provided_lead_edge = command:get_parameter("lead_edge"),
            delta_frames = command:get_parameter("delta_frames"),
            delta_ms = command:get_parameter("delta_ms"),
            edge_infos = {},
            original_states_map = {},
            planned_mutations = {},
            preview_affected_clips = {},
            preview_shifted_clips = {},
            neighbor_bounds_cache = {},
            preloaded_clips = {},
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
            edited_lookup_for_shifts = {}
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
                    type = edge.type
                }
            end
        end

        ctx.primary_edge = ctx.provided_lead_edge or (ctx.edge_infos and ctx.edge_infos[1] or nil)
        ctx.sequence_id = command_helper.resolve_sequence_id_for_edges(command, ctx.primary_edge, ctx.edge_infos)
        ctx.project_id = command.project_id or command:get_parameter("project_id") or "default_project"
        return ctx
    end

    local function resolve_sequence_rate(ctx, db)
        local seq_fps_num = ui_constants.TIMELINE.DEFAULT_FPS_NUMERATOR
        local seq_fps_den = ui_constants.TIMELINE.DEFAULT_FPS_DENOMINATOR
        local seq_stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        if seq_stmt then
            seq_stmt:bind_value(1, ctx.sequence_id)
            if seq_stmt:exec() and seq_stmt:next() then
                seq_fps_num = seq_stmt:value(0)
                seq_fps_den = seq_stmt:value(1)
            end
            seq_stmt:finalize()
        end
        ctx.seq_fps_num = seq_fps_num
        ctx.seq_fps_den = seq_fps_den
    end

    local function resolve_delta(ctx)
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

    local function snapshot_edge_infos(ctx)
        local stored_edge_infos = {}
        for _, edge in ipairs(ctx.edge_infos or {}) do
            stored_edge_infos[#stored_edge_infos + 1] = {
                clip_id = edge.original_clip_id or edge.clip_id,
                original_clip_id = edge.original_clip_id,
                edge_type = edge.edge_type,
                track_id = edge.track_id,
                trim_type = edge.trim_type,
                type = edge.type
            }
        end
        ctx.command:set_parameter("edge_infos", stored_edge_infos)
    end


    command_executors["BatchRippleEdit"] = function(command)
        local ctx = create_execution_context(command)

        if not ctx.edge_infos or #ctx.edge_infos == 0 then
            print("ERROR: BatchRippleEdit missing edge_infos")
            return false
        end

        if not ctx.delta_frames and not ctx.delta_ms then
            print("ERROR: BatchRippleEdit missing delta")
            return false
        end

        if not ctx.dry_run then
            print("Executing BatchRippleEdit command")
        end

        resolve_sequence_rate(ctx, db)
        if not resolve_delta(ctx) then
            return false, "Invalid delta"
        end

        snapshot_edge_infos(ctx)
        build_clip_cache(ctx)
        materialize_gap_edges(ctx)
        assign_edge_tracks(ctx)
        determine_lead_edge(ctx)
        analyze_selection(ctx)
        compute_constraints(ctx, db)

        local ok_edges = process_edge_trims(ctx, db)
        if not ok_edges then
            return false, "Failed to process edge trims"
        end

        local ok_shift, adjusted_frames = compute_downstream_shifts(ctx, db)
        if not ok_shift then
            return retry_with_adjusted_delta(ctx, adjusted_frames)
        end

        build_planned_mutations(ctx)
        return finalize_execution(ctx, db)
    end

    command_undoers["BatchRippleEdit"] = function(command)
        print("Undoing BatchRippleEdit command")

        local executed_mutations = hydrate_executed_mutations_if_missing(command)
        local sequence_id = command:get_parameter("sequence_id")

        local started, begin_err = db:begin_transaction()
        if not started then
            print("ERROR: UndoBatchRippleEdit: Failed to begin transaction: " .. tostring(begin_err))
            return false
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
        if not ok then
            db:rollback_transaction(started)
            print("ERROR: UndoBatchRippleEdit: Failed to revert mutations: " .. tostring(err))
            return false
        end
        
        local ok_commit, commit_err = db:commit_transaction(started)
        if not ok_commit then
            db:rollback_transaction(started)
            return false, "Failed to commit undo transaction: " .. tostring(commit_err)
        end

        print("✅ Undo Batch ripple: Reverted all changes")
        return true
    end

    command_executors["UndoBatchRippleEdit"] = command_undoers["BatchRippleEdit"]

    return {
        executor = command_executors["BatchRippleEdit"],
        undoer = command_undoers["BatchRippleEdit"]
    }
end

return M
