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
-- Size: ~1880 LOC
-- Volatility: unknown
--
-- @file batch_ripple_edit.lua
local M = {}
local Clip = require('models.clip')
local database = require('core.database')
local frame_utils = require('core.frame_utils')
local command_helper = require("core.command_helper")
local edge_utils = require("core.edge_utils")
local ui_constants = require("core.ui_constants")
local clip_mutator = require('core.clip_mutator') -- New dependency
local log = require("core.logger").for_area("commands")
local ripple_edge = require("core.ripple.edge_info")
local ripple_track = require("core.ripple.track_index")
local ripple_undo = require("core.ripple.undo_hydrator")
local gap_lifecycle = require("core.gap_lifecycle")
local batch_context = require("core.ripple.batch.context")
local batch_pipeline = require("core.ripple.batch.pipeline")

local compute_edge_boundary_time = ripple_edge.compute_edge_boundary_time
local build_edge_key = ripple_edge.build_edge_key
local bracket_for_normalized_edge = ripple_edge.bracket_for_normalized_edge
local build_neighbor_bounds_cache = ripple_track.build_neighbor_bounds_cache
local build_track_clip_map = ripple_track.build_track_clip_map
local hydrate_executed_mutations_if_missing = ripple_undo.hydrate_executed_mutations_if_missing
local signum
local infer_implied_normalized_edge
local lower_bound_start_frames
local pick_gap_anchor_clip_id
local compute_neighbor_bounds
local ensure_neighbor_bounds
local should_negate_edge


-- SPEC.args: caller inputs. SPEC.persisted: executor-written undo/results payload. __keys: ephemeral scratch.
local SPEC = {
    args = {
        project_id = { required = true, kind = "string", empty_as_nil = true },
        sequence_id = { kind = "string", empty_as_nil = true },

        -- Provided by tests/UI. Normalized into ctx.edge_infos by batch_context.
        -- Accept multiple caller flavors; batch_context is the choke point that normalizes.
        -- (Most callers should pass edge_infos.)
        edge_infos = { kind = "table" },
        edge_info = { kind = "table" },
        __edge_infos = { kind = "table" },
        __selected_edge_infos = { kind = "table" },
        __selected_edge_infos_pre = { kind = "table" },
        lead_edge = { kind = "table" },

        delta_frames = { kind = "number" },
        delta_ms = { kind = "number" },
        dry_run = { kind = "boolean" },

        -- Internal/computed parameters (set by executor)
        __retry_delta_count = { kind = "number" },
        __preloaded_clip_snapshot = { kind = "table" },
        __timeline_active_region = { kind = "table" },
        __use_timeline_state_cache = { kind = "boolean" },
        __force_conflict_delta = { kind = "boolean" },
        __force_retry_delta = { kind = "number" },
    },
    persisted = {
        bulk_shifts = { kind = "table" },
        clamped_delta_ms = { kind = "number" },
        clamped_delta_frames = { kind = "number" },
        original_states = { kind = "table" },
        executed_mutation_order = { kind = "table" },
        executed_mutations = { kind = "table" },
    },

    requires_any = {
        { "delta_frames", "delta_ms" },
        { "edge_infos", "edge_info", "__edge_infos", "__selected_edge_infos", "__selected_edge_infos_pre" },
    },
}
function M.register(command_executors, command_undoers, db, set_last_error)
    -- Helper: Load clip and capture original state if not already cached
    local function ensure_clip_loaded(ctx, clip_id)
        local clip = ctx.base_clips[clip_id]
        if not clip then
            local is_gap = type(clip_id) == "string" and clip_id:find("^gap_")
            local cached = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
            if cached then
                if is_gap or (cached.rate and cached.rate.fps_numerator and cached.rate.fps_denominator) then
                    clip = cached
                end
            end
            if not clip and not is_gap then
                clip = Clip.load_optional(clip_id)
            end
            if clip then
                ctx.base_clips[clip_id] = clip
            end
        end
        -- Capture original state for constraint computation (gaps included
        -- for boundary time calculation, but not persisted to command undo data)
        if clip and not ctx.original_states_map[clip_id] then
            ctx.original_states_map[clip_id] = command_helper.capture_clip_state(clip)
        end
        return clip
    end

    -- Helper: Calculate roll constraint (min/max delta) for an edge based on neighbor positions
    local function compute_roll_constraint(edge_info, clip, original, neighbors, edited_lookup)
        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local delta_min = nil
        local delta_max = nil
        assert(type(clip.duration) == "number", "compute_roll_constraint: clip.duration must be integer")

        assert(original and type(original.timeline_start) == "number", "compute_roll_constraint: original.timeline_start must be integer")
        assert(original and type(original.duration) == "number", "compute_roll_constraint: original.duration must be integer")
        local original_start_frames = original.timeline_start
        local original_end_frames = original_start_frames + original.duration

        if normalized_edge == "in" then
            -- In-point: can't drag left past previous clip
            if neighbors.prev_end_frames and not edited_lookup[neighbors.prev_id] then
                delta_min = neighbors.prev_end_frames - original_start_frames
            end
        elseif normalized_edge == "out" then
            -- Out-point: can't drag right past next clip
            if neighbors.next_start_frames and not edited_lookup[neighbors.next_id] then
                delta_max = neighbors.next_start_frames - original_end_frames
            end
        end

        return delta_min, delta_max
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
        -- Roll edit points (multiple roll edges on same track) use global constraint.
        -- Multitrack roll (single roll edge per track) uses per-edge constraint only.
        local is_edit_point = ctx.roll_edit_point_tracks and ctx.roll_edit_point_tracks[edge_info.track_id]
        if delta_min then
            ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, delta_min)
            if is_edit_point then
                update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
            end
        end
        if delta_max then
            ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, delta_max)
            if is_edit_point then
                update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
            end
        end
    end

    -- Convert absolute-TC source_in to file-relative offset by subtracting
    -- the media's TC origin. source_in is stored as media_tc_origin + file_offset
    -- (commit 4bec175). Media constraint math needs the file_offset, not absolute TC.
    local function file_relative_source_in(media, source_in_abs)
        if not media or not source_in_abs then
            return source_in_abs
        end
        local tc_origin = media:get_start_tc()
        if not tc_origin then
            return source_in_abs
        end
        local file_offset = source_in_abs - tc_origin
        -- Sanity: file_offset should be non-negative. If negative, TC metadata is
        -- wrong or source_in predates the media start — clamp to 0.
        if file_offset < 0 then
            log.warn("apply_media_limits: file_offset=%d is negative (source_in=%d tc_origin=%d media=%s)",
                file_offset, source_in_abs, tc_origin, tostring(media.id))
            file_offset = 0
        end
        return file_offset
    end

    local function apply_media_limits(ctx, edge_info, clip, will_negate)
        -- Gap clips have no media — no source limits to apply
        if clip.clip_kind == "gap" then
            return
        end
        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local effective_delta_positive = (ctx.clamped_delta_frames > 0 and not will_negate)
            or (ctx.clamped_delta_frames < 0 and will_negate)
        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state then
            return
        end
        local edge_key = build_edge_key(edge_info)
        -- Multitrack roll uses per-edge constraints; edit points and ripple use global.
        local is_multitrack_roll = edge_info.trim_type == "roll"
            and not (ctx.roll_edit_point_tracks and ctx.roll_edit_point_tracks[edge_info.track_id])
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}
        if normalized_edge == "in" then
            if not effective_delta_positive and clip_state.source_in then
                assert(type(clip_state.source_in) == "number", "apply_media_limits: clip_state.source_in must be integer")
                -- source_in is absolute TC; convert to file-relative for limit calc
                local media = (ctx.preloaded_media and ctx.preloaded_media[clip.media_id]) or (clip.media_id and require("models.media").load(clip.media_id, db))
                if ctx.preloaded_media and clip.media_id then
                    ctx.preloaded_media[clip.media_id] = media
                end
                local file_src_in = file_relative_source_in(media, clip_state.source_in)
                local extend_limit = -file_src_in
                ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, extend_limit)
                if not is_multitrack_roll then
                    update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
                end
            end
        elseif normalized_edge == "out" and effective_delta_positive and clip.media_id then
            local media = (ctx.preloaded_media and ctx.preloaded_media[clip.media_id]) or require("models.media").load(clip.media_id, db)
            if ctx.preloaded_media then
                ctx.preloaded_media[clip.media_id] = media
            end
            if media and media.duration and clip_state.source_in and clip_state.duration then
                assert(type(media.duration) == "number", "apply_media_limits: media.duration must be integer")
                assert(type(clip_state.source_in) == "number", "apply_media_limits: clip_state.source_in must be integer")
                assert(type(clip_state.duration) == "number", "apply_media_limits: clip_state.duration must be integer")
                -- source_in is absolute TC; convert to file-relative for limit calc
                local file_src_in = file_relative_source_in(media, clip_state.source_in)
                local available_frames = media.duration - file_src_in - clip_state.duration
                if will_negate then
                    local global_constraint = -available_frames
                    ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, global_constraint)
                    if not is_multitrack_roll then
                        update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
                    end
                else
                    ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, available_frames)
                    if not is_multitrack_roll then
                        update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
                    end
                end
            end
        end
    end

    -- Gap clips can close to 0 but not go negative.
    local function apply_gap_min_duration(ctx, edge_info, clip, will_negate)
        if clip.clip_kind ~= "gap" then return end

        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state or not clip_state.duration then return end
        local duration = clip_state.duration
        if duration <= 0 then return end

        local normalized = edge_info.normalized_edge or edge_info.edge_type
        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}

        local min_limit, max_limit
        if normalized == "in" then
            max_limit = duration  -- can't shrink gap below 0
        elseif normalized == "out" then
            min_limit = -duration  -- can't shrink gap below 0
        end

        if will_negate then
            if min_limit and max_limit then
                min_limit, max_limit = -max_limit, -min_limit
            elseif min_limit then
                max_limit = -min_limit
                min_limit = nil
            elseif max_limit then
                min_limit = -max_limit
                max_limit = nil
            end
        end

        if min_limit then
            ctx.per_edge_constraints[edge_key].min = math.max(ctx.per_edge_constraints[edge_key].min, min_limit)
            update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
        end
        if max_limit then
            ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, max_limit)
            update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
        end
    end

    local function apply_min_duration_limits(ctx, edge_info, clip, will_negate)
        if clip.clip_kind == "gap" then
            return  -- handled by apply_gap_min_duration
        end

        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        if normalized_edge ~= "in" and normalized_edge ~= "out" then
            return
        end

        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state or not clip_state.duration then
            return
        end
        assert(type(clip_state.duration) == "number", "apply_min_duration_limits: clip_state.duration must be integer")

        local duration_frames = clip_state.duration
        if duration_frames < 1 then
            return
        end

        local min_applied = -math.huge
        local max_applied = math.huge
        if normalized_edge == "in" then
            max_applied = duration_frames  -- Allow trim to zero (deletes clip)
        else -- out
            min_applied = -duration_frames  -- Allow trim to zero (deletes clip)
        end

        local edge_key = build_edge_key(edge_info)
        -- Multitrack roll uses per-edge constraints; edit points and ripple use global.
        local is_multitrack_roll = edge_info.trim_type == "roll"
            and not (ctx.roll_edit_point_tracks and ctx.roll_edit_point_tracks[edge_info.track_id])
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
            if not is_multitrack_roll then
                update_global_min(ctx, edge_key, ctx.per_edge_constraints[edge_key].min)
            end
        end
        if global_max ~= math.huge then
            ctx.per_edge_constraints[edge_key].max = math.min(ctx.per_edge_constraints[edge_key].max, global_max)
            if not is_multitrack_roll then
                update_global_max(ctx, edge_key, ctx.per_edge_constraints[edge_key].max)
            end
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
                -- Shallow-copy clip_lookup so register_temp_gap doesn't
                -- pollute the shared snapshot across preview/commit cycles.
                local lookup_copy = {}
                for k, v in pairs(snapshot.clip_lookup) do lookup_copy[k] = v end
                ctx.clip_lookup = lookup_copy
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
                local clip = is_temp_gap and snapshot.clip_lookup[clip_id] or Clip.load_optional(clip_id)
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
                    assert(type(a.timeline_start) == "number", "build_clip_cache: clip a.timeline_start must be integer")
                    assert(type(b.timeline_start) == "number", "build_clip_cache: clip b.timeline_start must be integer")
                    return a.timeline_start < b.timeline_start
                end)
            end
            return
        end

        -- UI-only optimization: prefer the in-memory timeline state for the
        -- active sequence to avoid reloading thousands of clips from SQLite.
        local use_timeline_state_cache = ctx.args.__use_timeline_state_cache == true
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

        -- Compute and inject gap clips (in-memory only, not persisted)
        local seq_fps = { fps_numerator = ctx.seq_fps_num, fps_denominator = ctx.seq_fps_den }
        local track_media = build_track_clip_map(ctx.all_clips)
        for track_id, sorted_clips in pairs(track_media) do
            local gaps = gap_lifecycle.compute_gaps_for_track(track_id, sorted_clips, seq_fps)
            for _, gap in ipairs(gaps) do
                table.insert(ctx.all_clips, gap)
            end
        end

        ctx.clip_lookup = {}
        for _, clip in ipairs(ctx.all_clips) do
            ctx.clip_lookup[clip.id] = clip
        end
        ctx.track_clip_map = build_track_clip_map(ctx.all_clips)
    end

    local function prime_neighbor_bounds_cache(ctx)
        assert(ctx.track_clip_map, "prime_neighbor_bounds_cache: track_clip_map is nil")
        -- Build neighbor bounds from MEDIA clips only. Gap clips are transparent
        -- for overlap/constraint computation — they represent empty space, not
        -- physical content that blocks movement.
        local media_only_map = {}
        for track_id, clips in pairs(ctx.track_clip_map) do
            local media_clips = {}
            for _, clip in ipairs(clips) do
                if clip.clip_kind ~= "gap" then
                    table.insert(media_clips, clip)
                end
            end
            if #media_clips > 0 then
                media_only_map[track_id] = media_clips
            end
        end
        ctx.neighbor_bounds_cache = build_neighbor_bounds_cache(media_only_map)
    end

    -- For each ripple edge, find the gap clip on OTHER tracks at the same
    -- timeline position and inject an edge on it. If clips are adjacent
    -- (no gap), create an implied zero-length gap. This allows single-track
    -- ripple to propagate across all tracks without explicit linked selection.
    local function inject_implicit_gap_edges(ctx)
        assert(ctx.edge_infos, "inject_implicit_gap_edges: edge_infos is nil")
        assert(ctx.all_clips, "inject_implicit_gap_edges: all_clips is nil")

        -- Collect the edit boundary from each selected ripple edge
        local boundary_entries = {}
        local selected_track_ids = {}
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.trim_type ~= "roll" then
                local clip = ctx.clip_lookup[edge_info.clip_id]
                if clip and type(clip.timeline_start) == "number" and type(clip.duration) == "number" then
                    selected_track_ids[clip.track_id] = true
                    local normalized = edge_utils.to_bracket(edge_info.edge_type)
                    local boundary
                    local is_in_edge
                    if normalized == "out" then
                        boundary = clip.timeline_start + clip.duration
                        is_in_edge = false
                    else
                        boundary = clip.timeline_start
                        is_in_edge = true
                    end
                    table.insert(boundary_entries, { frame = boundary, is_in_edge = is_in_edge })
                end
            end
        end

        -- For each boundary on each unselected track, find the gap clip at
        -- that boundary. If no gap exists (adjacent clips), create an implied
        -- zero-length gap clip. Then inject an edge on the gap's "in" edge.
        local injected_gaps = {}
        local seq_fps = { fps_numerator = ctx.seq_fps_num, fps_denominator = ctx.seq_fps_den }
        for _, entry in ipairs(boundary_entries) do
            local boundary_frame = entry.frame
            for track_id, track_clips in pairs(ctx.track_clip_map) do
                if not selected_track_ids[track_id] then
                    -- Find the gap clip at the boundary position
                    local gap_at_boundary = nil
                    for _, clip in ipairs(track_clips) do
                        if clip.clip_kind == "gap" and clip.timeline_start == boundary_frame then
                            gap_at_boundary = clip
                            break
                        end
                        -- Gap that contains the boundary (boundary is inside a gap)
                        if clip.clip_kind == "gap" and clip.timeline_start <= boundary_frame
                            and (clip.timeline_start + clip.duration) > boundary_frame then
                            gap_at_boundary = clip
                            break
                        end
                    end

                    -- If no gap at boundary, look for a media clip at the boundary
                    -- and create an implied zero-length gap
                    if not gap_at_boundary then
                        local downstream_clip = nil
                        if entry.is_in_edge then
                            for _, clip in ipairs(track_clips) do
                                if clip.clip_kind ~= "gap" and clip.timeline_start > boundary_frame then
                                    downstream_clip = clip
                                    break
                                end
                            end
                            if not downstream_clip then
                                for _, clip in ipairs(track_clips) do
                                    if clip.clip_kind ~= "gap" and clip.timeline_start >= boundary_frame then
                                        downstream_clip = clip
                                        break
                                    end
                                end
                            end
                        else
                            for _, clip in ipairs(track_clips) do
                                if clip.clip_kind ~= "gap" and clip.timeline_start >= boundary_frame then
                                    downstream_clip = clip
                                    break
                                end
                            end
                        end

                        if downstream_clip then
                            -- Create implied zero-length gap at the downstream clip's position.
                            -- This is where the gap logically exists — between the previous
                            -- clip's end and this clip's start.
                            gap_at_boundary = gap_lifecycle.create_implied_gap(track_id, downstream_clip.timeline_start, seq_fps)
                            if gap_at_boundary then
                                -- Register in context so pipeline can find it
                                ctx.clip_lookup[gap_at_boundary.id] = gap_at_boundary
                                ctx.base_clips[gap_at_boundary.id] = gap_at_boundary
                                table.insert(ctx.all_clips, gap_at_boundary)
                            end
                        end
                    end

                    if gap_at_boundary and not injected_gaps[gap_at_boundary.id] then
                        injected_gaps[gap_at_boundary.id] = true
                        ctx.original_states_map[gap_at_boundary.id] = command_helper.capture_clip_state(gap_at_boundary)
                        table.insert(ctx.edge_infos, {
                            clip_id = gap_at_boundary.id,
                            edge_type = "in",
                            track_id = track_id,
                            trim_type = "ripple",
                            is_implicit_injection = true,
                        })
                    end
                end
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
            assert(edge_info.track_id,
                string.format("assign_edge_tracks: edge %s:%s missing track_id (clip_id=%s not in lookup?)",
                    tostring(edge_info.clip_id), tostring(edge_info.edge_type), tostring(edge_info.clip_id)))
            ctx.selected_tracks[edge_info.track_id] = true
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

    local function load_clip_for_edit(ctx, clip_id)
        local clip = ctx.modified_clips[clip_id]
        if clip then
            return clip
        end

        local base = ctx.base_clips[clip_id]
        if not base then
            local is_gap = type(clip_id) == "string" and clip_id:find("^gap_")
            local cached = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
            if cached then
                if is_gap or (cached.rate and cached.rate.fps_numerator and cached.rate.fps_denominator) then
                    base = cached
                end
            end
            if not base and not is_gap then
                base = Clip.load_optional(clip_id)
            end
            if base then
                ctx.base_clips[clip_id] = base
            end
        end

        if not base then
            return nil
        end

        if not ctx.original_states_map[clip_id] then
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
                master_clip_id = base.master_clip_id,
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
            }
        else
            clip = base
        end

        ctx.modified_clips[clip_id] = clip
        return clip
    end

-- Apply the requested trim delta to clip edges and return the ripple start.
-- Gap clips and media clips use the same logic. The only difference:
-- - Gap clips have nil source_in/source_out (no source modification)
-- - Gap clips can reach duration 0; media clips have minimum duration 1
	local function apply_edge_ripple(clip, edge_type, delta_frames, trim_type)
	        assert(type(clip.duration) == "number", "apply_edge_ripple: clip.duration must be integer")
	        assert(type(clip.timeline_start) == "number", "apply_edge_ripple: clip.timeline_start must be integer")
	        assert(type(delta_frames) == "number", "apply_edge_ripple: delta_frames must be integer")

	        local new_duration_timeline = clip.duration
	        local new_source_in = clip.source_in  -- nil for gap clips
	        local is_gap = clip.clip_kind == "gap"

        if edge_type == "in" then
            new_duration_timeline = clip.duration - delta_frames
            if new_source_in then
                new_source_in = clip.source_in + delta_frames
            end
            if trim_type == "roll" then
                clip.timeline_start = clip.timeline_start + delta_frames
            end
        elseif edge_type == "out" then
            new_duration_timeline = clip.duration + delta_frames
        else
            error(string.format("apply_edge_ripple: Unsupported edge_type '%s'", edge_type))
        end

	        if is_gap then
	            if new_duration_timeline < 0 then
	                new_duration_timeline = 0
	            end
	        else
	            if new_duration_timeline < 1 then
	                clip.duration = 0
	                clip.source_in = new_source_in
	                if new_source_in then
	                    clip.source_out = new_source_in + clip.duration
	                end
	                return clip.timeline_start, true, true
	            end
	        end

	        clip.duration = new_duration_timeline
	        clip.source_in = new_source_in
	        if new_source_in then
	            clip.source_out = new_source_in + clip.duration
	        end
	        return clip.timeline_start, true, false
	    end

    local function analyze_selection(ctx)
        ctx.selection_has_clip_edge = false
        ctx.edited_clip_lookup = {}
        local lead_clip = ctx.lead_edge_entry and ctx.clip_lookup and ctx.clip_lookup[ctx.lead_edge_entry.clip_id]
        ctx.lead_is_gap = lead_clip and lead_clip.clip_kind == "gap"
        ctx.edge_will_negate = {}

        local lead_bracket = ctx.lead_edge_entry and bracket_for_normalized_edge(ctx.lead_edge_entry.normalized_edge or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type))

        assert(ctx.edge_infos, "setup_edge_context: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.clip_id then
                local edge_clip = ctx.clip_lookup and ctx.clip_lookup[edge_info.clip_id]
                local clip_is_gap = edge_clip and edge_clip.clip_kind == "gap"
                ctx.edited_clip_lookup[edge_info.clip_id] = true
                if not clip_is_gap then
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

        ctx.clamped_delta_frames = ctx.delta_frames

        -- Pre-compute which tracks have roll edit points (multiple CLIP roll edges on same track).
        -- Gap edges (gap_before/gap_after) don't count - they're part of the same edit as the clip edge.
        -- Roll edges on these tracks use global constraints; multitrack roll uses per-edge.
        -- Tracks with a roll edit point use global constraints (not per-edge).
        -- A roll edit point is:
        --   - clip-clip: 2+ clip roll edges on same track (out + in)
        --   - clip-gap:  1 clip roll edge + 1 gap roll edge on same track
        -- Without this, clip-gap rolls get treated as multitrack_roll
        -- (per-edge constraints) which produces wrong behavior.
        -- With gap-as-clip, roll edit points are simply 2+ roll edges on the same track.
        -- A clip-gap roll has exactly 2 edges: clip:out + gap:in (both are standard edges).
        ctx.roll_edit_point_tracks = {}
        local roll_edges_by_track = {}
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.trim_type == "roll" and edge_info.track_id then
                roll_edges_by_track[edge_info.track_id] = (roll_edges_by_track[edge_info.track_id] or 0) + 1
            end
        end
        for track_id, count in pairs(roll_edges_by_track) do
            if count >= 2 then
                ctx.roll_edit_point_tracks[track_id] = true
            end
        end
    end

		    local function compute_earliest_ripple_hint(ctx)
		        assert(ctx.edge_infos, "compute_earliest_ripple_hint: edge_infos is nil")
		        assert(ctx.original_states_map, "compute_earliest_ripple_hint: original_states_map is nil")
		        ctx.earliest_ripple_hint = nil
		        for _, edge_info in ipairs(ctx.edge_infos) do
		            if edge_info.trim_type ~= "roll" and edge_info.clip_id and ctx.original_states_map[edge_info.clip_id] then
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
	            if clip.clip_kind ~= "gap"  -- Gap clips are transparent for overlap detection
	                and clip.id
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
                assert(type(clip.timeline_start) == "number", "clamp_downstream_overlaps: clip.timeline_start must be integer")
                assert(type(clip.duration) == "number", "clamp_downstream_overlaps: clip.duration must be integer")
                local clip_start_frames = clip.timeline_start
                local clip_end_frames = clip_start_frames + clip.duration

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
	                        local implied_key = build_edge_key({clip_id = clip.id, edge_type = "in"})
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
	                        local implied_key = build_edge_key({clip_id = clip.id, edge_type = "out"})
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
        local delta_frames = ctx.clamped_delta_frames
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
        ctx.clamped_delta_frames = delta_frames
        if delta_frames ~= ctx.delta_frames then
            print(string.format("DEBUG_CLAMP2: delta clamped from %s to %s (global_min=%s, global_max=%s)",
                tostring(ctx.delta_frames), tostring(delta_frames),
                tostring(ctx.global_min_frames), tostring(ctx.global_max_frames)))
        end
        ctx.clamp_direction = 0
        if ctx.delta_frames and ctx.clamped_delta_frames then
            local diff = ctx.delta_frames - ctx.clamped_delta_frames
            if diff > 0 then
                ctx.clamp_direction = 1
            elseif diff < 0 then
                ctx.clamp_direction = -1
            end
        end
        local clamped_delta_ms = frame_utils.frames_to_ms(delta_frames, ctx.seq_fps_num, ctx.seq_fps_den)
        ctx.command:set_parameter("clamped_delta_ms", clamped_delta_ms)
        ctx.command:set_parameter("clamped_delta_frames", ctx.clamped_delta_frames)
        return delta_frames
    end

    local function compute_constraints(ctx)
        ctx.global_min_frames = -math.huge
        ctx.global_max_frames = math.huge
        ctx.global_min_edge_keys = {}
        ctx.global_max_edge_keys = {}

        assert(ctx.edge_infos, "compute_constraints: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            local clip = ensure_clip_loaded(ctx, edge_info.clip_id)
            if clip then
                local neighbors = ensure_neighbor_bounds(ctx, edge_info.clip_id)
                local edge_key = build_edge_key(edge_info)
                ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key] or {min = -math.huge, max = math.huge}

                apply_roll_constraints(ctx, edge_info, clip, neighbors)
                local will_negate = should_negate_edge(ctx, edge_key)
                apply_gap_min_duration(ctx, edge_info, clip, will_negate)
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
	    end

    local function compute_applied_delta(ctx, edge_key, edge_info)
        local applied_delta
        -- Multitrack roll (single roll edge per track) uses per-edge constraints independently.
        -- Roll edit points (multiple roll edges on same track) and ripple use global clamped delta.
        local is_multitrack_roll = edge_info and edge_info.trim_type == "roll"
            and not (ctx.roll_edit_point_tracks and ctx.roll_edit_point_tracks[edge_info.track_id])
        if is_multitrack_roll then
            -- Multitrack roll: use original delta + per-edge constraints
            applied_delta = ctx.delta_frames
            if should_negate_edge(ctx, edge_key) then
                applied_delta = -ctx.delta_frames
            end
            local constraints = ctx.per_edge_constraints[edge_key]
            if constraints then
                local before_clamp = applied_delta
                if constraints.min ~= -math.huge and applied_delta < constraints.min then
                    applied_delta = constraints.min
                end
                if constraints.max ~= math.huge and applied_delta > constraints.max then
                    applied_delta = constraints.max
                end
                if before_clamp ~= applied_delta then
                    log.event("Multitrack roll edge %s: requested=%d, clamped to %d (min=%s, max=%s)",
                        edge_key, before_clamp, applied_delta,
                        constraints.min == -math.huge and "-inf" or tostring(constraints.min),
                        constraints.max == math.huge and "+inf" or tostring(constraints.max))
                end
            end
        else
            -- Ripple edges or same-track roll edit points use global clamped delta
            applied_delta = ctx.clamped_delta_frames
            if should_negate_edge(ctx, edge_key) then
                applied_delta = -ctx.clamped_delta_frames
            end
        end
        log.event("compute_applied_delta: key=%s, is_multitrack_roll=%s, delta_frames=%s, clamped=%s, result=%s",
            edge_key, tostring(is_multitrack_roll), tostring(ctx.delta_frames), tostring(ctx.clamped_delta_frames), tostring(applied_delta))
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
            is_gap = clip.clip_kind == "gap"
        })
    end

    local function compute_ripple_point(original, clip, _normalized_edge)
        local source = original or clip
        if not source or not source.timeline_start then
            return clip.timeline_start + clip.duration
        end
        return source.timeline_start + source.duration
    end

    local function update_earliest_ripple_time(ctx, point)
        if not point then
            return
        end
        if not ctx.earliest_ripple_time or point < ctx.earliest_ripple_time then
            ctx.earliest_ripple_time = point
        end
    end

	    local function compute_track_shift_amounts(ctx)
	        if ctx.has_ripple_edge then
	            assert(type(ctx.ripple_anchor_applied_delta) == "number",
	                "compute_track_shift_amounts: ripple_anchor_applied_delta must be integer")
	            local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
	            ctx.downstream_shift_frames = ctx.ripple_anchor_applied_delta * shift_factor

	            local drag_sign = (ctx.clamped_delta_frames >= 0) and 1 or -1
	            for track_id, seed in pairs(ctx.track_shift_seeds) do
	                if track_id and seed.orientation and type(seed.applied_delta) == "number" then
	                    local orientation_sign = (seed.orientation == "in") and -1 or 1
	                    if seed.is_gap then
	                        ctx.track_shift_amounts[track_id] = seed.applied_delta * orientation_sign
	                    else
	                        local magnitude = math.abs(seed.applied_delta)
	                        local direction_sign = drag_sign
	                        if seed.orientation == "out" then
	                            direction_sign = (seed.applied_delta >= 0) and 1 or -1
	                        end
	                        local track_shift_frames = magnitude * direction_sign * orientation_sign
	                        ctx.track_shift_amounts[track_id] = track_shift_frames
	                    end
	                end
	            end
	        else
	            ctx.downstream_shift_frames = 0
	        end
	    end

    local function ensure_earliest_ripple_time(ctx)
        if not ctx.earliest_ripple_time then
            ctx.earliest_ripple_time = 0
        end
    end

    local function process_edge_trims(ctx)
        reset_ripple_processing_state(ctx)

        assert(ctx.edge_infos, "process_edge_trims: edge_infos is nil")
        for _, edge_info in ipairs(ctx.edge_infos) do
            local clip_id = edge_info.clip_id
            local clip = load_clip_for_edit(ctx, clip_id)
            if not clip then
                log.warn("BatchRippleEdit: Clip %s not found. Skipping.", tostring(clip_id))
                goto continue_edge_process
            end

            if ctx.clips_marked_delete[clip_id] then
                goto continue_edge_process
            end

            local original = ctx.original_states_map[clip_id]
            local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
            local key = build_edge_key(edge_info)
            local applied_delta = compute_applied_delta(ctx, key, edge_info)

            local _, success, deleted_clip = apply_edge_ripple(clip, normalized_edge, applied_delta, edge_info.trim_type)
            if not success then
                log.error("Ripple failed for clip %s (edge=%s trim=%s delta=%s)",
                    tostring(clip.id),
                    tostring(edge_info.edge_type),
                    tostring(edge_info.trim_type),
                    tostring(applied_delta))
                return false
            end

            local clip_is_gap = clip.clip_kind == "gap"

            if clip_is_gap then
                -- Implied zero-length gaps clamped to 0 are blockers: the gap
                -- couldn't absorb the shift. Record so the UI shows red.
                if applied_delta ~= 0 and clip.duration == 0 then
                    local original_dur = original and original.duration or 0
                    if original_dur == 0 or (original_dur + applied_delta < 0) then
                        ctx.forced_clamped_edges[key] = true
                    end
                end
            end

	            if edge_info.trim_type ~= "roll" then
	                register_ripple_anchor(ctx, normalized_edge, clip_is_gap, applied_delta, clip.track_id, key)
	                register_track_shift_seed(ctx, clip, normalized_edge, applied_delta, clip_is_gap)
	            end

            record_preview_for_edge(ctx, clip, edge_info, normalized_edge)

            if deleted_clip then
                ctx.clips_marked_delete[clip_id] = true
            end

	            local ripple_point = compute_ripple_point(original, clip, normalized_edge)
	            if ripple_point and type(ripple_point) == "number" and clip.track_id then
	                local existing = ctx.track_ripple_start_frames[clip.track_id]
	                if not existing or ripple_point < existing then
	                    ctx.track_ripple_start_frames[clip.track_id] = ripple_point
	                end
	            end
	            update_earliest_ripple_time(ctx, ripple_point)

            ::continue_edge_process::
        end

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
            if other_clip.clip_kind ~= "gap"  -- Gap clips recomputed, not shifted
                and other_clip.id
                and not ctx.edited_lookup_for_shifts[other_clip.id]
                and not (ctx.bulk_shift_anchor_lookup and ctx.bulk_shift_anchor_lookup[other_clip.id])
                and ctx.affected_tracks[other_clip.track_id]
                and other_clip.timeline_start then
                -- Use per-track ripple point; fall back to global earliest
                local track_threshold = (ctx.track_ripple_start_frames and ctx.track_ripple_start_frames[other_clip.track_id])
                    or ctx.earliest_ripple_time
                if other_clip.timeline_start >= track_threshold then
                    table.insert(ctx.clips_to_shift, other_clip)
                end
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
	        local min_blocker_key = nil  -- edge key of clip whose out-edge blocks leftward shift
	        local max_blocker_key = nil  -- edge key of clip whose in-edge blocks rightward shift

        local function accumulate_bounds_for_clip(shift_clip_data)
            local neighbors = ctx.neighbor_bounds_cache and ctx.neighbor_bounds_cache[shift_clip_data.id]
            assert(neighbors, "compute_shift_bounds: missing neighbor cache for clip " .. tostring(shift_clip_data.id))
            assert(type(shift_clip_data.timeline_start) == "number", "compute_shift_bounds: clip.timeline_start must be integer")
            assert(type(shift_clip_data.duration) == "number", "compute_shift_bounds: clip.duration must be integer")

            local start_frames = shift_clip_data.timeline_start
            local end_frames = start_frames + shift_clip_data.duration

	            local function current_start_frames(clip_id)
	                local clip = ctx.modified_clips[clip_id] or ctx.clip_lookup[clip_id] or ctx.base_clips[clip_id]
	                if not clip or type(clip.timeline_start) ~= "number" then
	                    return nil
	                end
	                return clip.timeline_start
	            end

	            local function current_end_frames(clip_id)
	                local clip = ctx.modified_clips[clip_id] or ctx.clip_lookup[clip_id] or ctx.base_clips[clip_id]
	                if not clip or type(clip.timeline_start) ~= "number" or type(clip.duration) ~= "number" then
	                    return nil
	                end
	                return clip.timeline_start + clip.duration
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
	                if bound > min_frames then
	                    min_frames = bound
	                    if neighbors.prev_id then
	                        min_blocker_key = tostring(neighbors.prev_id) .. ":out"
	                    end
	                end
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
	                if bound < max_frames then
	                    max_frames = bound
	                    if neighbors.next_id then
	                        max_blocker_key = tostring(neighbors.next_id) .. ":in"
	                    end
	                end
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

        return min_frames, max_frames, min_blocker_key, max_blocker_key
    end

	    local function build_preview_shift_blocks(ctx)
	        local blocks = {}
	        local global_shift = ctx.downstream_shift_frames or 0
	        local global_start_frames = ctx.earliest_ripple_time
	        if global_start_frames == nil then
	            return blocks
	        end

	        if global_shift ~= 0 then
	            table.insert(blocks, {start_frames = global_start_frames, delta_frames = global_shift})
	        end
	        for track_id, shift_frames in pairs(ctx.track_shift_amounts or {}) do
	            assert(type(shift_frames) == "number", "build_preview_shift_blocks: track shift must be integer for track " .. tostring(track_id))
	            local start_frames = ctx.track_ripple_start_frames and ctx.track_ripple_start_frames[track_id] or global_start_frames
	            if shift_frames ~= 0 and (shift_frames ~= global_shift or start_frames ~= global_start_frames) then
	                table.insert(blocks, {start_frames = start_frames, delta_frames = shift_frames, track_id = track_id})
	            end
	        end
	        return blocks
	    end

    local function compute_downstream_shifts(ctx)
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
        local downstream_shift = ctx.downstream_shift_frames or 0
        local has_nonzero = downstream_shift ~= 0
        if not has_nonzero and ctx.track_shift_amounts then
            for _, shift_frames in pairs(ctx.track_shift_amounts) do
                if shift_frames and shift_frames ~= 0 then
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
	        local min_shift_frames, max_shift_frames, min_blocker_key, max_blocker_key = compute_shift_bounds(ctx)
	        local desired_shift_frames = ctx.downstream_shift_frames
	        local adjusted_frames = desired_shift_frames

        if min_shift_frames ~= -math.huge and desired_shift_frames < min_shift_frames then
            adjusted_frames = min_shift_frames
            -- Record the blocking edge for red display in UI
            if min_blocker_key then
                ctx.forced_clamped_edges = ctx.forced_clamped_edges or {}
                ctx.forced_clamped_edges[min_blocker_key] = true
            end
        end
        if max_shift_frames ~= math.huge and desired_shift_frames > max_shift_frames then
            adjusted_frames = max_shift_frames
            if max_blocker_key then
                ctx.forced_clamped_edges = ctx.forced_clamped_edges or {}
                ctx.forced_clamped_edges[max_blocker_key] = true
            end
        end
        local forced_retry = ctx.args.__force_retry_delta
        if forced_retry then
            adjusted_frames = forced_retry
        end

        if adjusted_frames ~= desired_shift_frames then
            -- Persist blocker edge keys through retry so UI can show them red
            if ctx.forced_clamped_edges then
                local blocker_keys = {}
                for key in pairs(ctx.forced_clamped_edges) do
                    table.insert(blocker_keys, key)
                end
                if #blocker_keys > 0 then
                    ctx.command:set_parameter("__shift_blocker_keys", blocker_keys)
                end
            end
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
                    shift_clip = {
                        id = base_clip.id,
                        track_id = base_clip.track_id,
                        timeline_start = base_clip.timeline_start,
                        duration = base_clip.duration,
                        source_in = base_clip.source_in,
                        source_out = base_clip.source_out,
                        clip_kind = base_clip.clip_kind,
                        fps_numerator = base_clip.fps_numerator,
                        fps_denominator = base_clip.fps_denominator,
                        enabled = base_clip.enabled
                    }
                end
            else
                shift_clip = load_clip_for_edit(ctx, shift_clip_data.id)
            end

            if not shift_clip then
                log.warn("BatchRippleEdit: Downstream clip %s not found. Skipping shift.", tostring(shift_clip_data.id))
                goto continue_shift
            end

            local track_shift = ctx.track_shift_amounts[shift_clip.track_id] or ctx.downstream_shift_frames
            assert(type(shift_clip.timeline_start) == "number", "compute_downstream_shifts: shift_clip.timeline_start must be integer")
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
	                local track_shift = ctx.track_shift_amounts[track_id] or ctx.downstream_shift_frames
	                local frames = track_shift or 0
	                if clip_id and frames ~= 0 then
                        local anchor = ctx.clip_lookup and ctx.clip_lookup[clip_id] or nil
                        assert(anchor and type(anchor.timeline_start) == "number", "compute_downstream_shifts: bulk shift anchor clip.timeline_start must be integer " .. tostring(clip_id))
	                    table.insert(ctx.bulk_shift_mutations, {
	                        type = "bulk_shift",
	                        track_id = track_id,
	                        shift_frames = frames,
	                        first_clip_id = clip_id,
                            anchor_start_frame = anchor.timeline_start,
	                        start_frames = ctx.timeline_active_region.bulk_shift_start_frames
	                    })
	                end
	            end
	        end

	        return true
	    end

	    local function retry_with_adjusted_delta(ctx, adjusted_frames)
	        local retry_count = ctx.args.__retry_delta_count or 0
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
        local adjusted_ms = frame_utils.frames_to_ms(adjusted_frames, ctx.seq_fps_num, ctx.seq_fps_den)
        ctx.command:set_parameter("clamped_delta_ms", adjusted_ms)
        ctx.command:set_parameter("clamped_delta_frames", adjusted_frames)

        return command_executors["BatchRippleEdit"](ctx.command)
    end

		    local function build_planned_mutations(ctx)
		        local shift_frames = ctx.downstream_shift_frames or 0
		        local growth_frames = ctx.clamped_delta_frames or 0

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
		                assert(type(start_value) == "number", "build_planned_mutations: delete previous timeline_start must be integer")
		                return start_value
		            end
		            error("build_planned_mutations: unsupported mutation type for sorting: " .. tostring(mut.type))
		        end

		        for id, clip in pairs(ctx.modified_clips) do
		            local original = ctx.original_states_map[id]
		            local is_gap_clip = clip and clip.clip_kind == "gap"
		            if is_gap_clip then
		                -- Gap clips are in-memory only — no DB mutation.
		                -- Include in preview data so UI can render gap changes.
		                if ctx.dry_run then
		                    assert(type(clip.timeline_start) == "number", "build_planned_mutations: gap timeline_start must be integer")
		                    assert(type(clip.duration) == "number", "build_planned_mutations: gap duration must be integer")
		                    table.insert(temp_gap_mutations, {
		                        type = "temp_gap",
		                        clip_id = id,
		                        timeline_start_frame = clip.timeline_start,
		                        duration_frames = clip.duration
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
		                local track_shift = ctx.track_shift_amounts[shift_clip.track_id] or ctx.downstream_shift_frames
		                assert(type(shift_clip.timeline_start) == "number", "build_planned_mutations: shift_clip.timeline_start must be integer")
		                local new_start = shift_clip.timeline_start + track_shift
		                if new_start < 0 then
		                    new_start = 0
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

	    local function finalize_execution(ctx)
	        -- original_states includes gap clips (for constraint computation during
	        -- the edit). The undo hydrator uses executed_mutation_order to decide
	        -- which clips to revert — gap clips aren't in mutation_order, so they
	        -- won't be reverted from DB. But original_states must be non-empty for
	        -- the hydrator to work.
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
	            local final_delta = ctx.clamped_delta_frames
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
                        requested_delta_frames = ctx.delta_frames or 0,
                        clamped_delta_frames = ctx.clamped_delta_frames or 0,
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
                    local global_sign = signum(ctx.clamped_delta_frames or 0)

                    -- Selected edges (and implicit gap edges injected on unselected tracks).
                    for _, edge_info in ipairs(ctx.edge_infos or {}) do
                        local raw_edge_type = edge_info.edge_type
                        local anchor_clip_id = edge_info.original_clip_id or edge_info.clip_id
                        if anchor_clip_id and raw_edge_type then
                            local edge_key = string.format("%s:%s", tostring(anchor_clip_id), tostring(raw_edge_type))
                            local source_key = build_edge_key(edge_info)
                            local applied = compute_applied_delta(ctx, source_key, edge_info)
                            local is_implicit = edge_info.is_implicit_injection == true
                            upsert({
                                edge_key = edge_key,
                                clip_id = anchor_clip_id,
                                track_id = edge_info.track_id,
                                raw_edge_type = raw_edge_type,
                                normalized_edge = edge_info.normalized_edge or edge_utils.to_bracket(raw_edge_type),
                                is_selected = not is_implicit,
                                is_implied = is_implicit,
                                is_limiter = clamped_edges[edge_key] == true,
                                applied_delta_frames = applied or 0
                            })
                        end
                    end

                    -- Implied edges from track shifts (Rule 8.5).
                    -- With gap-as-clip, find the gap clip at the ripple boundary on each
                    -- unselected track. Use the gap clip's edge for the implied display.
                    local boundary_default = ctx.earliest_ripple_time or 0
                    for track_id in pairs(ctx.affected_tracks or {}) do
                        if track_id and not (ctx.selected_tracks and ctx.selected_tracks[track_id]) then
                            local shift_frames = (ctx.track_shift_amounts and ctx.track_shift_amounts[track_id]) or ctx.downstream_shift_frames or 0
                            if shift_frames ~= 0 then
                                local desired = infer_implied_normalized_edge(lead_normalized, signum(shift_frames), global_sign)
                                local boundary_frames = (ctx.track_ripple_start_frames and ctx.track_ripple_start_frames[track_id]) or boundary_default
                                local track_clips = ctx.track_clip_map and ctx.track_clip_map[track_id] or {}
                                -- Find gap clip at boundary, or fall back to nearest media clip
                                local anchor_clip_id = nil
                                local raw_edge_type = desired or "in"
                                for _, c in ipairs(track_clips) do
                                    if c.clip_kind == "gap" and c.timeline_start <= boundary_frames
                                        and (c.timeline_start + c.duration) >= boundary_frames then
                                        anchor_clip_id = c.id
                                        break
                                    end
                                end
                                if not anchor_clip_id then
                                    anchor_clip_id = pick_gap_anchor_clip_id(track_clips, boundary_frames, raw_edge_type)
                                end
                                if anchor_clip_id then
                                    local edge_key = string.format("%s:%s", tostring(anchor_clip_id), tostring(raw_edge_type))
                                    upsert({
                                        edge_key = edge_key,
                                        clip_id = anchor_clip_id,
                                        track_id = track_id,
                                        raw_edge_type = raw_edge_type,
                                        normalized_edge = desired or "in",
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
                                local shift_frames = (track_id and ctx.track_shift_amounts and ctx.track_shift_amounts[track_id]) or 0
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
	
	            local clamped_ms = frame_utils.frames_to_ms(ctx.clamped_delta_frames, ctx.seq_fps_num, ctx.seq_fps_den)
	            return true, {
	                planned_mutations = ctx.planned_mutations,
	                affected_clips = ctx.preview_affected_clips,
                shifted_clips = ctx.preview_shifted_clips,
                shift_blocks = ctx.shift_blocks,
                clamped_delta_ms = clamped_ms,
                clamped_delta_frames = ctx.clamped_delta_frames,
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
	                local inserted = Clip.load_optional(mut.clip_id)
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

	        -- DEBUG: dump planned mutations for diagnosis
	        for _di, _dm in ipairs(ctx.planned_mutations or {}) do
	            if _dm.type == "update" then
	                print(string.format("DEBUG_BRE: mut[%d] UPDATE clip=%s start=%s dur=%s", _di, tostring(_dm.clip_id):sub(1,8), tostring(_dm.timeline_start_frame), tostring(_dm.duration_frames)))
	            elseif _dm.type == "bulk_shift" then
	                print(string.format("DEBUG_BRE: mut[%d] BULK_SHIFT track=%s shift=%s anchor=%s clip_ids=%s", _di, tostring(_dm.track_id):sub(1,8), tostring(_dm.shift_frames), tostring(_dm.first_clip_id and _dm.first_clip_id:sub(1,8)), tostring(_dm.clip_ids and #_dm.clip_ids or "nil")))
	            elseif _dm.type == "delete" then
	                print(string.format("DEBUG_BRE: mut[%d] DELETE clip=%s", _di, tostring(_dm.clip_id):sub(1,8)))
	            end
	        end
	        print(string.format("DEBUG_BRE: downstream_shift=%s clips_to_shift=%d", tostring(ctx.downstream_shift_frames), #(ctx.clips_to_shift or {})))

	        log.event("Batch ripple: processed %d edges, shifted %d downstream clips by %d frames",
	            #ctx.edge_infos, #(ctx.clips_to_shift or {}), ctx.downstream_shift_frames or 0)

	        return true
	    end

    command_executors["BatchRippleEdit"] = function(command)
        local ctx = batch_context.create(command)

        -- Restore shift-bound blocker keys from a prior retry so the UI
        -- can highlight the blocking edges red even after delta re-clamp.
        local saved_blockers = command:get_parameter("__shift_blocker_keys")
        if type(saved_blockers) == "table" then
            for _, key in ipairs(saved_blockers) do
                ctx.forced_clamped_edges[key] = true
            end
        end

        if not ctx.edge_infos or #ctx.edge_infos == 0 then
            log.error("BatchRippleEdit missing edge_infos")
            return { success = false, error_message = "BatchRippleEdit missing edge_infos" }
        end

        if not ctx.delta_frames and not ctx.delta_ms then
            log.error("BatchRippleEdit missing delta")
            return { success = false, error_message = "BatchRippleEdit missing delta" }
        end

        if not ctx.dry_run then
            log.event("Executing BatchRippleEdit command")
        end

        return batch_pipeline.run(ctx, db, {
            build_clip_cache = build_clip_cache,
            prime_neighbor_bounds_cache = prime_neighbor_bounds_cache,
            inject_implicit_gap_edges = inject_implicit_gap_edges,
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
		        local args = command:get_all_parameters()
		        log.event("Undoing BatchRippleEdit command")

		        local executed_mutations = hydrate_executed_mutations_if_missing(command)

		        -- Persist hydrated mutations to avoid re-hydration on subsequent undos
		        if command.sequence_number and executed_mutations then
		            local save_ok, save_err = pcall(function() return command:save(db) end)
		            if not save_ok then
		                log.warn("Failed to persist hydrated mutations: %s", tostring(save_err))
		            end
		        end

		        -- No transaction here — command_manager provides one
		        local ok, success, err = pcall(command_helper.revert_mutations, db, executed_mutations, command, args.sequence_id)
		        if not ok then
		            log.error("UndoBatchRippleEdit: Failed to revert mutations: %s", tostring(success))
		            return { success = false, error_message = "Failed to revert mutations: " .. tostring(success) }
		        end
		        if success ~= true then
		            log.error("UndoBatchRippleEdit: Failed to revert mutations: %s", tostring(err))
		            return { success = false, error_message = "Failed to revert mutations: " .. tostring(err) }
		        end
	        return { success = true }
	    end

    command_executors["UndoBatchRippleEdit"] = command_undoers["BatchRippleEdit"]

    return {
        executor = command_executors["BatchRippleEdit"],
        undoer = command_undoers["BatchRippleEdit"],
        spec = SPEC,
    }
end


signum = function(value)
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

infer_implied_normalized_edge = function(lead_normalized, shift_sign, global_sign)
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

lower_bound_start_frames = function(track_clips, boundary_frames)
    if type(track_clips) ~= "table" or #track_clips == 0 then
        return 1
    end
    local lo = 1
    local hi = #track_clips + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local clip = track_clips[mid]
        if not clip or type(clip.timeline_start) ~= "number" then
            return 1
        end
        local start_frames = clip.timeline_start
        if start_frames < boundary_frames then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

pick_gap_anchor_clip_id = function(track_clips, boundary_frames, raw_edge_type)
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

compute_neighbor_bounds = function(all_clips, original_state, clip_id)
    if not original_state or not original_state.track_id then
        return nil, nil, nil, nil
    end
    local track_id = original_state.track_id
    local start_value = original_state.timeline_start
    local duration_value = original_state.duration
    if not start_value or not duration_value then
        return nil, nil, nil, nil
    end
    assert(type(start_value) == "number", "compute_neighbor_bounds: timeline_start must be integer")
    assert(type(duration_value) == "number", "compute_neighbor_bounds: duration must be integer")

    local start_frames = start_value
    local end_frames = start_frames + duration_value

    local prev_end_frames = nil
    local next_start_frames = nil
    local prev_clip_id = nil
    local next_clip_id = nil

    assert(all_clips, "compute_neighbor_bounds: all_clips is nil")
    for _, other in ipairs(all_clips) do
        if other.id ~= clip_id and other.track_id == track_id then
            assert(type(other.timeline_start) == "number", "compute_neighbor_bounds: other.timeline_start must be integer")
            assert(type(other.duration) == "number", "compute_neighbor_bounds: other.duration must be integer")
            local other_start_frames = other.timeline_start
            local other_end_frames = other_start_frames + other.duration

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

ensure_neighbor_bounds = function(ctx, clip_id)
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

should_negate_edge = function(ctx, edge_key)
    return ctx.edge_will_negate and ctx.edge_will_negate[edge_key]
end

return M
