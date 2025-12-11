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
    local clip_end = clip.timeline_start + clip.duration
    local best = nil
    for _, other in ipairs(all_clips or {}) do
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
    local start_value = clip.timeline_start
    local best = nil
    for _, other in ipairs(all_clips or {}) do
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
    local map = {}
    for _, clip in ipairs(all_clips or {}) do
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

local function create_temp_gap_clip(edge_info, clip_lookup, all_clips, track_clip_map, seq_fps_num, seq_fps_den)
    if not edge_info or (edge_info.edge_type ~= "gap_after" and edge_info.edge_type ~= "gap_before") then
        return nil
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
        source_in = Rational.new(-1000000000000000, seq_fps_num, seq_fps_den),
        source_out = Rational.new(1000000000000000, seq_fps_num, seq_fps_den),
        fps_numerator = seq_fps_num,
        fps_denominator = seq_fps_den,
        enabled = 1,
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
    for _, other in ipairs(all_clips or {}) do
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

function M.register(command_executors, command_undoers, db, set_last_error)
    -- Conditional logging based on environment variable (off by default to reduce noise)
    local log_level = os.getenv("JVE_LOG_LEVEL") or "INFO"
    local function log_debug(msg)
        if log_level == "DEBUG" then
            print("[DEBUG] " .. msg)
        end
    end

    -- Helper: Load clip and capture original state if not already cached
    local function ensure_clip_loaded(clip_id, preloaded, original_states, get_cached_clip)
        local clip = preloaded[clip_id]
        if not clip then
            clip = get_cached_clip(clip_id)
            preloaded[clip_id] = clip
        end
        if clip and not original_states[clip_id] then
            original_states[clip_id] = command_helper.capture_clip_state(clip)
        end
        return clip
    end

    local function is_gap_edge(edge_type)
        return edge_type == "gap_after" or edge_type == "gap_before"
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
    local function compute_gap_close_constraint(edge_info, clip, original, neighbors, edited_lookup)
        if edge_info.edge_type ~= "gap_before" and edge_info.edge_type ~= "gap_after" then
            return nil
        end

        local close_limit = nil
        if edge_info.edge_type == "gap_before" then
            -- gap_before moving left closes the gap
            close_limit = (clip.duration and clip.duration.frames) or 0
            if close_limit then
                return -close_limit  -- Negative because moving left
            end
        elseif edge_info.edge_type == "gap_after" then
            -- gap_after moving left closes the gap
            close_limit = (clip.duration and clip.duration.frames) or 0
            if close_limit then
                return -close_limit  -- Negative because moving left
            end
        end
        return nil
    end

    local function apply_edge_ripple(clip, edge_type, delta_rat, trim_type, raw_edge_type)
        -- Strict V5: Expect Rational
        if type(clip.duration) ~= "table" or not clip.duration.frames then
            error("apply_edge_ripple: Clip missing Rational duration.")
        end

        local new_duration_timeline = clip.duration
        local new_source_in = clip.source_in

        log_debug(string.format("apply_edge_ripple: clip.duration=%s (type %s), delta_rat=%s (type %s), clip.source_in=%s (type %s)",
            tostring(clip.duration), type(clip.duration),
            tostring(delta_rat), type(delta_rat),
            tostring(clip.source_in), type(clip.source_in)))

        if edge_type == "in" then
            -- Ripple in: shorten/extend from the leading edge. Start stays anchored for ripple;
            -- rolls move the edit point because both sides are selected.
            new_duration_timeline = clip.duration - delta_rat
            new_source_in = clip.source_in + delta_rat
            if trim_type == "roll" then
                clip.timeline_start = clip.timeline_start + delta_rat
            end
        elseif edge_type == "out" then
            -- Ripple out: change duration
            new_duration_timeline = clip.duration + delta_rat
        else
            error(string.format("apply_edge_ripple: Unsupported edge_type '%s'", edge_type))
        end

        local is_gap = is_gap_edge(raw_edge_type)

        if is_gap then
            if new_duration_timeline.frames and new_duration_timeline.frames < 0 then
                local fps_num = (clip.duration and clip.duration.fps_numerator) or (clip.source_in and clip.source_in.fps_numerator) or 30
                local fps_den = (clip.duration and clip.duration.fps_denominator) or (clip.source_in and clip.source_in.fps_denominator) or 1
                new_duration_timeline = Rational.new(0, fps_num, fps_den)
            end
        else
            if new_duration_timeline.frames < 1 then
                return nil, false, true -- Too short/deleted
            end
        end
        
        clip.duration = new_duration_timeline
        clip.source_in = new_source_in
        clip.source_out = clip.source_in + clip.duration -- Re-calculate source_out
        
        return clip.timeline_start, true, false
    end

    command_executors["BatchRippleEdit"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing BatchRippleEdit command")
        end

        local edge_infos_raw = command:get_parameter("edge_infos")
        local provided_lead_edge = command:get_parameter("lead_edge")
        local edge_infos = {}
        local lead_edge_entry = nil
        if edge_infos_raw then
            for _, edge in ipairs(edge_infos_raw) do
                local source_original_id = edge.original_clip_id or edge.clip_id
                local cleaned_id = edge.clip_id
                if type(cleaned_id) == "string" and cleaned_id:find("^temp_gap_") then
                    cleaned_id = cleaned_id:gsub("^temp_gap_", "")
                end
                edge_infos[#edge_infos + 1] = {
                    clip_id = cleaned_id,
                    original_clip_id = source_original_id,
                    edge_type = edge.edge_type,
                    track_id = edge.track_id,
                    trim_type = edge.trim_type,
                    type = edge.type
                }
            end
        end
        
        local delta_frames = command:get_parameter("delta_frames")
        local delta_ms = command:get_parameter("delta_ms")
        
        local primary_edge = provided_lead_edge or (edge_infos and edge_infos[1] or nil)
        local sequence_id = command_helper.resolve_sequence_id_for_edges(command, primary_edge, edge_infos)

        if not edge_infos or #edge_infos == 0 or (not delta_frames and not delta_ms) then
            print("ERROR: BatchRippleEdit missing parameters")
            return false
        end

        -- Resolve Sequence Rate
        local seq_fps_num = ui_constants.TIMELINE.DEFAULT_FPS_NUMERATOR
        local seq_fps_den = ui_constants.TIMELINE.DEFAULT_FPS_DENOMINATOR
        local seq_stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        if seq_stmt then
            seq_stmt:bind_value(1, sequence_id)
            if seq_stmt:exec() and seq_stmt:next() then
                seq_fps_num = seq_stmt:value(0)
                seq_fps_den = seq_stmt:value(1)
            end
            seq_stmt:finalize()
        end
        
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
        if not delta_rat or not delta_rat.frames then
            return false
        end

        local stored_edge_infos = {}
        for _, edge in ipairs(edge_infos or {}) do
            stored_edge_infos[#stored_edge_infos + 1] = {
                clip_id = edge.original_clip_id or edge.clip_id,
                original_clip_id = edge.original_clip_id,
                edge_type = edge.edge_type,
                track_id = edge.track_id,
                trim_type = edge.trim_type,
                type = edge.type
            }
        end
        command:set_parameter("edge_infos", stored_edge_infos)

        local original_states_map = {} -- Stores original clip states before modification
        local planned_mutations = {} -- Collect all mutations here
        local preview_affected_clips = {}
        local preview_shifted_clips = {}
        local neighbor_bounds_cache = {}
        local preloaded_clips = {}
        local modified_clips = {} -- Map id -> clip object (modified)
        local global_min_frames = -math.huge
        local global_max_frames = math.huge
        local per_edge_constraints = {} -- Track individual edge constraints for limit coloring
        local forced_clamped_edges = {}
        
        local function get_cached_clip(clip_id)
            return preloaded_clips[clip_id] or Clip.load_optional(clip_id, db)
        end
        
        -- Load all clips on sequence for downstream calculation
        local all_clips = database.load_clips(sequence_id)
        local clip_lookup = {}
        for _, c in ipairs(all_clips or {}) do
            clip_lookup[c.id] = c
        end

        local track_clip_map = build_track_clip_map(all_clips)
        local temp_gap_clips = {}
        local materialized_gap_ids = {}

        local function register_temp_gap(gap_clip)
            if not gap_clip or temp_gap_clips[gap_clip.id] then
                return gap_clip
            end
            temp_gap_clips[gap_clip.id] = gap_clip
            clip_lookup[gap_clip.id] = gap_clip
            preloaded_clips[gap_clip.id] = gap_clip
            table.insert(materialized_gap_ids, gap_clip.id)
            return gap_clip
        end

        for _, edge_info in ipairs(edge_infos or {}) do
            if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
                local gap_clip = create_temp_gap_clip(edge_info, clip_lookup, all_clips, track_clip_map, seq_fps_num, seq_fps_den)
                if not gap_clip then
                    error(string.format("Failed to materialize gap edge %s on clip %s", tostring(edge_info.edge_type), tostring(edge_info.clip_id)))
                end
                register_temp_gap(gap_clip)
                edge_info.clip_id = gap_clip.id
                edge_info.track_id = gap_clip.track_id
            end
        end
        local clip_track_lookup = {}
        local affected_tracks = {}
        for _, clip in ipairs(all_clips or {}) do
            clip_track_lookup[clip.id] = clip.track_id
            if clip.track_id then
                affected_tracks[clip.track_id] = true
            end
        end
        for _, edge_info in ipairs(edge_infos or {}) do
            if not edge_info.track_id then
                edge_info.track_id = clip_track_lookup[edge_info.clip_id]
            end
            edge_info.normalized_edge = edge_utils.to_bracket(edge_info.edge_type)
        end

        local provided_lead_clip = provided_lead_edge and provided_lead_edge.clip_id or nil
        local provided_lead_norm = provided_lead_edge and edge_utils.to_bracket(provided_lead_edge.edge_type or provided_lead_edge.normalized_edge) or nil
        for _, edge_info in ipairs(edge_infos or {}) do
            local matches_clip = provided_lead_clip
                and (edge_info.clip_id == provided_lead_clip or edge_info.original_clip_id == provided_lead_clip)
            local matches_edge = not provided_lead_norm or edge_info.normalized_edge == provided_lead_norm
            if matches_clip and matches_edge then
                lead_edge_entry = edge_info
                break
            end
        end
        if not lead_edge_entry then
            lead_edge_entry = edge_infos[1]
        end
        if lead_edge_entry then
            command:set_parameter("lead_edge", {
                clip_id = lead_edge_entry.original_clip_id or lead_edge_entry.clip_id,
                original_clip_id = lead_edge_entry.original_clip_id,
                edge_type = lead_edge_entry.edge_type,
                track_id = lead_edge_entry.track_id,
                trim_type = lead_edge_entry.trim_type
            })
        end

        local clamped_delta_rat = delta_rat
        local selection_has_clip_edge = false
        local edited_clip_lookup = {}
        for _, edge_info in ipairs(edge_infos or {}) do
            if edge_info.clip_id then
                edited_clip_lookup[edge_info.clip_id] = true
                if not is_gap_edge(edge_info.edge_type) then
                    selection_has_clip_edge = true
                end
                if is_gap_edge(edge_info.edge_type) then
                    local gap_clip = preloaded_clips[edge_info.clip_id]
                    if gap_clip then
                        if gap_clip.gap_left_id then
                            edited_clip_lookup[gap_clip.gap_left_id] = true
                        end
                        if gap_clip.gap_right_id then
                            edited_clip_lookup[gap_clip.gap_right_id] = true
                        end
                    end
                end
            end
        end

        -- Gap clamp only when gap edge is leading OR delta would close the gap
        local lead_is_gap = lead_edge_entry and (lead_edge_entry.edge_type == "gap_before" or lead_edge_entry.edge_type == "gap_after")

        local function apply_gap_clamp(target_type, is_positive)
            local min_gap_frames = nil
            local limiting_edges = {}
            for _, edge_info in ipairs(edge_infos) do
                if edge_info.edge_type == target_type then
                    local clip = get_cached_clip(edge_info.clip_id)
                    if clip and clip.duration and clip.duration.frames then
                        local gap_frames = clip.duration.frames
                        if not min_gap_frames or gap_frames < min_gap_frames then
                            min_gap_frames = gap_frames
                            limiting_edges = {build_edge_key(edge_info)}
                        elseif gap_frames == min_gap_frames then
                            limiting_edges[#limiting_edges + 1] = build_edge_key(edge_info)
                        end
                    end
                end
            end
            if min_gap_frames then
                local target = Rational.new(is_positive and min_gap_frames or -min_gap_frames, seq_fps_num, seq_fps_den)
                if (is_positive and clamped_delta_rat > target) or (not is_positive and clamped_delta_rat < target) then
                    clamped_delta_rat = target
                    for _, key in ipairs(limiting_edges) do
                        forced_clamped_edges[key] = true
                    end
                end
            end
        end

        -- Pre-load all edge clips and capture original states BEFORE constraint calculation
        for _, edge_info in ipairs(edge_infos) do
            local clip = get_cached_clip(edge_info.clip_id)
            if clip and not original_states_map[edge_info.clip_id] then
                original_states_map[edge_info.clip_id] = command_helper.capture_clip_state(clip)
                preloaded_clips[edge_info.clip_id] = clip
            end
        end

        -- Pre-calculate lead edge info and opposing bracket negation BEFORE constraint calculation
        local lead_edge_for_constraints = lead_edge_entry or edge_infos[1]
        local lead_boundary_time = nil
        local lead_track_id = nil
        local lead_bracket = nil
        if lead_edge_for_constraints then
            lead_boundary_time = compute_edge_boundary_time(lead_edge_for_constraints, original_states_map)
            lead_track_id = get_edge_track_id(lead_edge_for_constraints, clip_lookup, original_states_map)
            local lead_norm = lead_edge_for_constraints.normalized_edge or edge_utils.to_bracket(lead_edge_for_constraints.edge_type)
            lead_bracket = bracket_for_normalized_edge(lead_norm)
        end

        -- Pre-calculate which edges will get negated delta (for correct constraint calculation)
        local edge_will_negate = {}
        local edge_shares_lead_point = {}
        for _, edge_info in ipairs(edge_infos) do
            local normalized_edge = edge_info.normalized_edge or edge_utils.to_bracket(edge_info.edge_type)
            local edge_bracket = bracket_for_normalized_edge(normalized_edge)
            local key = build_edge_key(edge_info)
            if edge_info ~= lead_edge_for_constraints and edge_info.trim_type ~= "roll" and lead_bracket and edge_bracket then
                local should_negate = false
                local current_track_id = get_edge_track_id(edge_info, clip_track_lookup, original_states_map)
                local share_edit_point = false
                if lead_boundary_time and lead_track_id and current_track_id and current_track_id == lead_track_id then
                    local boundary = compute_edge_boundary_time(edge_info, original_states_map)
                    if boundary and boundary == lead_boundary_time then
                        share_edit_point = true
                    end
                end
                edge_shares_lead_point[key] = share_edit_point
                if share_edit_point and edge_bracket ~= lead_bracket then
                    should_negate = true
                elseif lead_edge_for_constraints
                    and is_gap_edge(lead_edge_for_constraints.edge_type)
                    and edge_bracket ~= lead_bracket
                    and delta_rat.frames < 0 then
                    should_negate = true
                end
                if should_negate then
                    edge_will_negate[key] = true
                end
            end
        end

        local has_partner_clip = false
        if lead_is_gap then
            for _, edge_info in ipairs(edge_infos) do
                if not is_gap_edge(edge_info.edge_type) then
                    local key = build_edge_key(edge_info)
                    if edge_shares_lead_point[key] then
                        has_partner_clip = true
                        break
                    end
                end
            end
        end

        if delta_rat < Rational.new(0, seq_fps_num, seq_fps_den) then
            apply_gap_clamp("gap_before", false)
        elseif delta_rat > Rational.new(0, seq_fps_num, seq_fps_den) and lead_is_gap and not has_partner_clip then
            apply_gap_clamp("gap_after", true)
        end

        -- Prepopulate original states and neighbor bounds to constrain delta frames
        for _, edge_info in ipairs(edge_infos) do
            local clip_id = edge_info.clip_id
            local clip = ensure_clip_loaded(clip_id, preloaded_clips, original_states_map, get_cached_clip)

            if clip then
                -- Cache neighbor bounds for constraint calculations
                if not neighbor_bounds_cache[clip_id] then
                    local prev_bound, next_bound, prev_id, next_id = compute_neighbor_bounds(all_clips, original_states_map[clip_id], clip_id)
                    neighbor_bounds_cache[clip_id] = {prev = prev_bound, next = next_bound, prev_id = prev_id, next_id = next_id}
                end

                local original = original_states_map[clip_id]
                local neighbors = neighbor_bounds_cache[clip_id]
                local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
                local edge_key = build_edge_key(edge_info)

                -- Initialize per-edge constraint tracking
                per_edge_constraints[edge_key] = {min = -math.huge, max = math.huge}

                -- Roll constraint calculation
                if edge_info.trim_type == "roll" then
                    local delta_min, delta_max = compute_roll_constraint(edge_info, clip, original, neighbors, edited_clip_lookup)
                    if delta_min then
                        log_debug(string.format("BatchRippleEdit: edge %s delta_min=%s", tostring(normalized_edge), tostring(delta_min)))
                        per_edge_constraints[edge_key].min = math.max(per_edge_constraints[edge_key].min, delta_min)
                        if delta_min > global_min_frames then
                            global_min_frames = delta_min
                        end
                    end
                    if delta_max then
                        log_debug(string.format("BatchRippleEdit: edge %s delta_max=%s", tostring(normalized_edge), tostring(delta_max)))
                        per_edge_constraints[edge_key].max = math.min(per_edge_constraints[edge_key].max, delta_max)
                        if delta_max < global_max_frames then
                            global_max_frames = delta_max
                        end
                    end
                end

                -- Gap closure constraint calculation
                local close_limit = compute_gap_close_constraint(edge_info, clip, original, neighbors, edited_clip_lookup)
                if close_limit then
                    log_debug(string.format("BatchRippleEdit: edge %s delta_min_close=%s", tostring(normalized_edge), tostring(close_limit)))
                    per_edge_constraints[edge_key].min = math.max(per_edge_constraints[edge_key].min, close_limit)
                    if close_limit > global_min_frames then
                        global_min_frames = close_limit
                    end
                end

                -- Media boundary constraints (skip for gap edges)
                if is_gap_edge(edge_info.edge_type) then
                    goto skip_media_constraints
                end

                -- Determine actual direction this edge will move (accounting for negation)
                local will_negate = edge_will_negate[edge_key]
                local effective_delta_positive = (delta_rat.frames > 0 and not will_negate) or (delta_rat.frames < 0 and will_negate)

                if normalized_edge == "in" then
                    if not effective_delta_positive and original.source_in then
                        -- Moving left (extending in-point): can't go below source_in = 0
                        local extend_limit = -original.source_in.frames
                        per_edge_constraints[edge_key].min = math.max(per_edge_constraints[edge_key].min, extend_limit)
                        if extend_limit > global_min_frames then
                            global_min_frames = extend_limit
                        end
                    end
                elseif normalized_edge == "out" then
                    if effective_delta_positive and clip.media_id then
                        -- Moving right (extending out-point): can't exceed media duration
                        local media = preloaded_clips[clip.media_id] or require("models.media").load(clip.media_id, db)
                        if media and media.duration and original.source_in and original.duration then
                            local available_frames = media.duration.frames - original.source_in.frames - original.duration.frames

                            -- If edge will be negated, flip constraint direction
                            if will_negate then
                                -- Edge gets negated: global min = -(available_frames)
                                local global_constraint = -available_frames
                                per_edge_constraints[edge_key].min = math.max(per_edge_constraints[edge_key].min, global_constraint)
                                if global_constraint > global_min_frames then
                                    global_min_frames = global_constraint
                                end
                            else
                                -- No negation: straightforward max constraint
                                per_edge_constraints[edge_key].max = math.min(per_edge_constraints[edge_key].max, available_frames)
                                if available_frames < global_max_frames then
                                    global_max_frames = available_frames
                                end
                            end
                        end
                    end
                end

                ::skip_media_constraints::
            end
        end

        -- (lead_boundary_time, lead_track_id, lead_bracket, edge_will_negate already calculated above)

        -- Determine earliest ripple point from original states
        local earliest_ripple_hint = nil
        for _, edge_info in ipairs(edge_infos) do
            if edge_info.trim_type ~= "roll" then
                local original = original_states_map[edge_info.clip_id]
                if original then
                    local point = original.timeline_start
                    local edge_kind = edge_info.normalized_edge or edge_info.edge_type
                    if edge_kind == "out" then
                        point = original.timeline_start + original.duration
                    end
                    if not earliest_ripple_hint or point < earliest_ripple_hint then
                        earliest_ripple_hint = point
                    end
                end
            end
        end

        -- Clamp delta further so downstream shift cannot overlap other tracks
        if earliest_ripple_hint then
            for _, clip in ipairs(all_clips or {}) do
                if clip.id and not edited_clip_lookup[clip.id]
                    and affected_tracks[clip.track_id]
                    and clip.timeline_start and clip.timeline_start >= earliest_ripple_hint then
                    local original = command_helper.capture_clip_state(clip)
                    local prev_bound, next_bound, prev_id, next_id = compute_neighbor_bounds(all_clips, original, clip.id)
                    if prev_bound and not edited_clip_lookup[prev_id] then
                        local delta_min = (prev_bound - clip.timeline_start).frames
                        if delta_min > global_min_frames then
                            global_min_frames = delta_min
                        end
                    end
                    if next_bound and not edited_clip_lookup[next_id] then
                        local delta_max = (next_bound - (clip.timeline_start + clip.duration)).frames
                        if delta_max < global_max_frames then
                            global_max_frames = delta_max
                        end
                    end
                end
            end
        end

        local delta_frames = clamped_delta_rat.frames
        if global_min_frames ~= -math.huge and global_max_frames ~= math.huge and global_min_frames > global_max_frames then
            delta_frames = 0
        else
            if global_min_frames ~= -math.huge and delta_frames < global_min_frames then
                delta_frames = global_min_frames
            end
            if global_max_frames ~= math.huge and delta_frames > global_max_frames then
                delta_frames = global_max_frames
            end
        end
        clamped_delta_rat = Rational.new(delta_frames, seq_fps_num, seq_fps_den)
        log_debug(string.format("BatchRippleEdit: clamped delta frames=%d", delta_frames or -1))
        command:set_parameter("clamped_delta_ms", clamped_delta_rat:to_milliseconds())
        local earliest_ripple_time = nil -- Rational
        
        -- Tracking for net ripple amount (downstream shift)
        local has_ripple_edge = false
        local downstream_shift_rat = Rational.new(0, seq_fps_num, seq_fps_den)
        local ripple_anchor_edge_type = nil
        local ripple_anchor_is_gap = false
        local lead_bracket = nil
        local track_ripple_orientation = {}
        local track_shift_amounts = {}
        if lead_edge_entry and lead_edge_entry.trim_type ~= "roll" then
            ripple_anchor_edge_type = lead_edge_entry.normalized_edge
            ripple_anchor_is_gap = is_gap_edge(lead_edge_entry.edge_type)
            lead_bracket = bracket_for_normalized_edge(ripple_anchor_edge_type)
        end
        
        local clips_marked_delete = {} -- Set of ids

        -- Step 1: Process Edges (Trim/Extend)
        for _, edge_info in ipairs(edge_infos) do
            local clip_id = edge_info.clip_id
            
            -- Get or load clip
            local clip = modified_clips[clip_id]
            if not clip then
                clip = preloaded_clips[clip_id]
            end
            if not clip then
                clip = get_cached_clip(clip_id)
                if not clip then
                    print(string.format("WARNING: BatchRippleEdit: Clip %s not found. Skipping.", clip_id:sub(1,8)))
                    goto continue_edge
                end
                -- First time seeing this clip, capture original
                if not original_states_map[clip_id] then
                    original_states_map[clip_id] = command_helper.capture_clip_state(clip)
                end
            end

            if not modified_clips[clip_id] then
                modified_clips[clip_id] = clip
            end
            
            if clips_marked_delete[clip_id] then
                goto continue_edge
            end

            local original = original_states_map[clip_id]
            local original_end = original.timeline_start + original.duration

            local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
            local current_track_id = get_edge_track_id(edge_info, clip_track_lookup, original_states_map)
            local key = build_edge_key(edge_info)
            local applied_delta = clamped_delta_rat
            if edge_will_negate[key] then
                applied_delta = -clamped_delta_rat
            end

            local shares_lead_point = edge_shares_lead_point[key]
            if edge_info.trim_type ~= "roll" and current_track_id and not track_ripple_orientation[current_track_id] and shares_lead_point then
                track_ripple_orientation[current_track_id] = normalized_edge
            end

            local ripple_start, success, deleted_clip = apply_edge_ripple(clip, normalized_edge, applied_delta, edge_info.trim_type, edge_info.edge_type)
            if not success then
                print(string.format("ERROR: Ripple failed for clip %s", clip.id:sub(1,8)))
                return false
            end

            if edge_info.trim_type ~= "roll" then
                has_ripple_edge = true
                if not ripple_anchor_edge_type then
                    ripple_anchor_edge_type = normalized_edge
                    ripple_anchor_is_gap = is_gap_edge(edge_info.edge_type)
                elseif ripple_anchor_is_gap and not is_gap_edge(edge_info.edge_type) then
                    ripple_anchor_edge_type = normalized_edge
                    ripple_anchor_is_gap = false
                end
            end

            if dry_run then
                local preview_clip_id = clip.id
                local is_gap = is_gap_edge(edge_info.edge_type)
                table.insert(preview_affected_clips, {
                    clip_id = preview_clip_id,
                    new_start_value = clip.timeline_start,
                    new_duration = clip.duration,
                    edge_type = normalized_edge,
                    raw_edge_type = edge_info.edge_type,  -- Tag for renderer filtering
                    is_gap = is_gap  -- Explicit gap flag
                })
            end

            if deleted_clip then
                clips_marked_delete[clip_id] = true
            end
            
            -- Determine earliest ripple time (start of the edited range)
            local ripple_point = clip.timeline_start
            if normalized_edge == "out" then
                -- For Out trim, ripple point is original end
                ripple_point = original.timeline_start + original.duration 
            end
            if normalized_edge == "in" then
                ripple_point = original.timeline_start
            end

            if not earliest_ripple_time or ripple_point < earliest_ripple_time then
                earliest_ripple_time = ripple_point
            end
            
            ::continue_edge::
        end

        -- Coordinate space conversion: Shift vs Delta
        -- When user drags an edge, the delta describes how much the edge moves.
        -- But downstream clips need to shift to accommodate the trim.
        -- - Out-point trim: shift = +delta (extending out-point pushes clips right)
        -- - In-point trim: shift = -delta (extending in-point pulls clips left)
        local shift_factor = (ripple_anchor_edge_type == "in") and -1 or 1

        if has_ripple_edge then
            downstream_shift_rat = Rational.new(clamped_delta_rat.frames * shift_factor, seq_fps_num, seq_fps_den)
            for track_id, orientation in pairs(track_ripple_orientation) do
                if track_id and orientation then
                    local factor = (orientation == "in") and -1 or 1
                    track_shift_amounts[track_id] = Rational.new(clamped_delta_rat.frames * factor, seq_fps_num, seq_fps_den)
                end
            end
        else
            downstream_shift_rat = Rational.new(0, seq_fps_num, seq_fps_den)
        end

        if not earliest_ripple_time then
            earliest_ripple_time = Rational.new(0, seq_fps_num, seq_fps_den)
        end
        
        -- Step 2: Identify Downstream Clips and Plan Shifts
        local edited_lookup = {}
        for id, _ in pairs(modified_clips) do edited_lookup[id] = true end

        local clips_to_shift = {}
        
        for _, other_clip in ipairs(all_clips) do
            if not edited_lookup[other_clip.id]
                and other_clip.timeline_start
                and other_clip.timeline_start >= earliest_ripple_time then
                table.insert(clips_to_shift, other_clip)
            end
        end

        -- Sort clips to shift by timeline_start to maintain order
        table.sort(clips_to_shift, function(a, b) return a.timeline_start < b.timeline_start end)

        local shift_lookup = {}
        for _, clip_info in ipairs(clips_to_shift) do
            if clip_info.id then
                shift_lookup[clip_info.id] = true
            end
        end

        for _, shift_clip_data in ipairs(clips_to_shift) do
            local shift_clip = modified_clips[shift_clip_data.id]
            if not shift_clip then
                shift_clip = get_cached_clip(shift_clip_data.id)
            end
            if not shift_clip then
                print(string.format("WARNING: BatchRippleEdit: Downstream clip %s not found. Skipping shift.", shift_clip_data.id:sub(1,8)))
                goto continue_shift_plan
            end
            
            if not original_states_map[shift_clip.id] then
                original_states_map[shift_clip.id] = command_helper.capture_clip_state(shift_clip)
            end
            
            local track_shift = track_shift_amounts[shift_clip.track_id] or downstream_shift_rat
            shift_clip.timeline_start = shift_clip.timeline_start + track_shift
            modified_clips[shift_clip.id] = shift_clip

            ::continue_shift_plan::
        end

        local function compute_shift_bounds()
            local min_frames = -math.huge
            local max_frames = math.huge
            for _, shift_clip_data in ipairs(clips_to_shift) do
                local original = {
                    timeline_start = shift_clip_data.timeline_start,
                    duration = shift_clip_data.duration,
                    track_id = shift_clip_data.track_id
                }
                local prev_bound, next_bound, prev_id, next_id = compute_neighbor_bounds(all_clips, original, shift_clip_data.id)

                if prev_bound and edited_lookup[prev_id] then
                    local neighbour = modified_clips[prev_id]
                    if neighbour then
                        prev_bound = neighbour.timeline_start + neighbour.duration
                    else
                        prev_bound = nil
                    end
                elseif prev_bound and shift_lookup[prev_id] then
                    prev_bound = nil
                end

                if next_bound and edited_lookup[next_id] then
                    local neighbour = modified_clips[next_id]
                    if neighbour then
                        next_bound = neighbour.timeline_start
                    else
                        next_bound = nil
                    end
                elseif next_bound and shift_lookup[next_id] then
                    next_bound = nil
                end

                if prev_bound then
                    local bound = (prev_bound - original.timeline_start).frames
                    if bound > min_frames then min_frames = bound end
                end
                if next_bound then
                    local bound = (next_bound - (original.timeline_start + original.duration)).frames
                    if bound < max_frames then max_frames = bound end
                end
            end
            return min_frames, max_frames
        end

        local min_shift_frames, max_shift_frames = compute_shift_bounds()
        local desired_shift_frames = downstream_shift_rat.frames
        local adjusted_frames = desired_shift_frames
        if min_shift_frames ~= -math.huge and desired_shift_frames < min_shift_frames then
            adjusted_frames = min_shift_frames
        end
        if max_shift_frames ~= math.huge and desired_shift_frames > max_shift_frames then
            adjusted_frames = max_shift_frames
        end
        if adjusted_frames ~= desired_shift_frames then
            local retry_count = command:get_parameter("__retry_delta_count") or 0
            if retry_count > ui_constants.TIMELINE.MAX_RIPPLE_CONSTRAINT_RETRIES then
                return false, "Failed to clamp ripple delta without overlap (retry limit)"
            end
            command:set_parameter("__retry_delta_count", retry_count + 1)
            local retry_delta_frames = adjusted_frames
            if shift_factor ~= 0 then
                retry_delta_frames = adjusted_frames / shift_factor
            end
            command:set_parameter("delta_frames", retry_delta_frames)
            command:set_parameter("delta_ms", nil)
            local adjusted_rat = Rational.new(adjusted_frames, seq_fps_num, seq_fps_den)
            command:set_parameter("clamped_delta_ms", adjusted_rat:to_milliseconds())
            return command_executors["BatchRippleEdit"](command)
        end

        -- Generate Planned Mutations
        for id, clip in pairs(modified_clips) do
            local original = original_states_map[id]
            local is_temp_gap_clip = type(id) == "string" and id:find("^temp_gap_")
            if clip and is_temp_gap_clip then
                if dry_run then
                    table.insert(planned_mutations, {
                        type = "temp_gap",
                        clip_id = id,
                        timeline_start_frame = (clip.timeline_start and clip.timeline_start.frames) or 0,
                        duration_frames = (clip.duration and clip.duration.frames) or 0
                    })
                end
            else
                if clips_marked_delete[id] then
                    table.insert(planned_mutations, clip_mutator.plan_delete(original))
                else
                    table.insert(planned_mutations, clip_mutator.plan_update(clip, original))
                end
            end
        end

        -- Sort mutations to prevent transient overlaps during updates
        local shift_frames = downstream_shift_rat.frames or 0
        local growth_frames = clamped_delta_rat.frames or 0

        table.sort(planned_mutations, function(a, b)
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

        if dry_run then
            preview_shifted_clips = {}
            for _, shift_clip in ipairs(clips_to_shift or {}) do
                local track_shift = track_shift_amounts[shift_clip.track_id] or downstream_shift_rat
                local new_start = shift_clip.timeline_start + track_shift
                table.insert(preview_shifted_clips, {
                    clip_id = shift_clip.id,
                    new_start_value = new_start,
                    new_duration = shift_clip.duration
                })
            end
        end

        command:set_parameter("original_states", original_states_map)
        command:set_parameter("executed_mutations", planned_mutations)

        if dry_run then
            -- Determine which edges actually hit their constraints
            local clamped_edges = {}
            local final_delta = clamped_delta_rat.frames
            for edge_key, limits in pairs(per_edge_constraints) do
                -- Edge is clamped if the final delta matches its min or max constraint
                if (limits.min ~= -math.huge and final_delta == limits.min) or
                   (limits.max ~= math.huge and final_delta == limits.max) then
                    clamped_edges[edge_key] = true
                end
            end
            for key in pairs(forced_clamped_edges) do
                clamped_edges[key] = true
            end

            return true, {
                planned_mutations = planned_mutations,
                affected_clips = preview_affected_clips,
                shifted_clips = preview_shifted_clips,
                clamped_delta_ms = clamped_delta_rat:to_milliseconds(),
                materialized_gaps = materialized_gap_ids,
                clamped_edges = clamped_edges
            }
        end

        -- Step 3: Execute all Planned Mutations (Transaction handled by CommandManager)
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end
        
        print(string.format("✅ Batch ripple: processed %d edges, shifted %d downstream clips by %s",
            #edge_infos, #clips_to_shift, tostring(downstream_shift_rat)))

        return true
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
