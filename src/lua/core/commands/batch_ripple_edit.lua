--- BatchRippleEdit: apply roll/ripple trim deltas to one or more edges
--- in a single command, with undo + dry-run preview support.
--
-- Responsibilities:
-- - Load the clips touched by the edit from the in-memory
--   timeline_state bounded cache (no DB scan)
-- - Compute per-edge and global delta constraints (media bounds, min
--   duration, gap min, roll neighbor bounds)
-- - Apply the resulting clamped delta to edit-region clips
-- - Emit one bulk_shift mutation per affected track for the downstream
--   block, with a single max-shift check per track
-- - Produce dry-run preview payloads for the UI (affected clips,
--   shifted clips, shift-block outline, clamped edge keys)
-- - Persist undo parameters (original_states, bulk_shifts,
--   executed_mutation_order) for the undoer in undo_hydrator.lua
--
-- Non-goals:
-- - Recomputing gap clips (caller of the pipeline does that scoped
--   via timeline_state.apply_mutations → recompute_gap_clips)
-- - Direct SQL access (goes through command_helper.apply_mutations)
-- - Loading clips outside the bounded cache (no DB fallback)
--
-- Invariants:
-- - Every clip_id touched by the pipeline must be resolvable from
--   ctx.clip_lookup (populated by build_clip_cache from timeline_state)
--   or synthesized by inject_implicit_gap_edges. A stale clip_id
--   results in a graceful skip, not a crash — see
--   test_batch_ripple_invalid_params for the contract.
-- - Gap clips participate as first-class clips in neighbor bounds and
--   constraints; no `is_gap` special-casing in the
--   constraint/mutation pipeline.
-- - Downstream clips shift via one bulk_shift mutation per track, not
--   per-clip updates. The per-track max-shift check runs in O(1) per
--   affected track.
-- - Mutable clip copies are owned by ctx (via load_clip_for_edit);
--   base clips from timeline_state are never mutated in place so
--   retries see clean originals.
--
-- @file batch_ripple_edit.lua
local M = {}
local Clip = require('models.clip')
local frame_utils = require('core.frame_utils')
local command_helper = require("core.command_helper")
local edge_utils = require("core.edge_utils")
local ui_constants = require("core.ui_constants")
local clip_mutator = require('core.clip_mutator')
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
    -- Fetch a clip by id from the context's bounded cache. Callers may
    -- pass a stale clip_id (e.g., UI selection referencing a now-deleted
    -- clip); in that case we return nil and callers skip the edge. The
    -- cache is populated by build_clip_cache from timeline_state, which
    -- is authoritative — no DB fallback.
    local function fetch_base_clip(ctx, clip_id)
        local cached = ctx.base_clips[clip_id]
        if cached then
            return cached
        end
        local clip = ctx.clip_lookup[clip_id]
        if not clip then
            return nil
        end
        assert(clip.frame_rate and clip.frame_rate.fps_numerator and clip.frame_rate.fps_denominator,
            string.format("batch_ripple_edit: clip %s missing rate metadata", tostring(clip_id)))
        ctx.base_clips[clip_id] = clip
        return clip
    end

    -- Load a clip for read-only constraint computation and capture its
    -- original state (once) so undo can restore it later. Gap clips are
    -- included here for boundary math, but gap entries are filtered out
    -- of the persisted original_states in finalize_execution. Returns
    -- nil for stale clip_ids; callers guard with `if clip then`.
    local function ensure_clip_loaded(ctx, clip_id)
        local clip = fetch_base_clip(ctx, clip_id)
        if not clip then
            return nil
        end
        if not ctx.original_states_map[clip_id] then
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
        if value < ctx.global_max_frames then
            ctx.global_max_frames = value
            ctx.global_max_edge_keys = {}
        end
        if edge_key and value == ctx.global_max_frames then
            ctx.global_max_edge_keys[edge_key] = true
        end
    end

    -- Multitrack roll (a single roll edge on a track) uses per-edge
    -- constraints independently: each edge clamps its own delta without
    -- affecting the others. Same-track roll edit points (2+ roll edges
    -- on one track) and all ripple edges share the global clamped delta.
    --
    -- Relies on analyze_selection having populated ctx.roll_edit_point_tracks;
    -- every caller runs downstream of analyze_selection in the pipeline.
    local function is_multitrack_roll_edge(ctx, edge_info)
        return edge_info.trim_type == "roll"
            and not ctx.roll_edit_point_tracks[edge_info.track_id]
    end

    -- Record a constraint on one edge and, for non-multitrack-roll edges,
    -- promote the tightened bound to the global clamp as well. This is
    -- the pattern every constraint function needs: narrow the per-edge
    -- envelope, then propagate to global unless this edge is a free
    -- multitrack roll. Either `min_limit` or `max_limit` may be nil.
    local function apply_edge_constraint_limits(ctx, edge_info, edge_key, min_limit, max_limit)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key]
            or {min = -math.huge, max = math.huge}
        local bounds = ctx.per_edge_constraints[edge_key]
        local multitrack_roll = is_multitrack_roll_edge(ctx, edge_info)
        if min_limit ~= nil then
            if min_limit > bounds.min then
                bounds.min = min_limit
            end
            if not multitrack_roll then
                update_global_min(ctx, edge_key, bounds.min)
            end
        end
        if max_limit ~= nil then
            if max_limit < bounds.max then
                bounds.max = max_limit
            end
            if not multitrack_roll then
                update_global_max(ctx, edge_key, bounds.max)
            end
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
        local is_edit_point = ctx.roll_edit_point_tracks[edge_info.track_id]
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

    -- Resolve a media record for a clip, consulting the per-command
    -- preloaded cache first so we don't hit the DB twice for the same
    -- media during one command.
    local function fetch_media_for_clip(ctx, clip)
        if not (clip.resolved_media and clip.resolved_media.id) then return nil end
        local cached = ctx.preloaded_media[(clip.resolved_media and clip.resolved_media.id)]
        if cached then return cached end
        local media = require("models.media").load((clip.resolved_media and clip.resolved_media.id), db)
        ctx.preloaded_media[(clip.resolved_media and clip.resolved_media.id)] = media
        return media
    end

    -- True iff the actual applied delta for this edge will be positive —
    -- i.e., the clamped delta direction after the edge's negate flag is
    -- taken into account.
    local function effective_delta_positive(ctx, will_negate)
        local delta = ctx.clamped_delta_frames
        return (delta > 0 and not will_negate) or (delta < 0 and will_negate)
    end

    -- In-edge source limit: trimming the in-point leftward (extending
    -- the head of the clip) can't go below the file's first frame.
    -- Returns (min_limit, max_limit) for the edge.
    local function in_edge_media_limit(ctx, clip, clip_state, will_negate)
        if effective_delta_positive(ctx, will_negate) then
            return nil, nil
        end
        if not clip_state.source_in then return nil, nil end
        assert(type(clip_state.source_in) == "number",
            "apply_media_limits: clip_state.source_in must be integer")
        local media = fetch_media_for_clip(ctx, clip)
        local file_src_in = file_relative_source_in(media, clip_state.source_in)
        -- file_src_in is in SOURCE units; the per-edge constraint operates on
        -- delta_frames which is OWNER (sequence) units. Convert before
        -- using as a delta limit, so a clip on a 24fps timeline against a
        -- 30fps source clamps to the right number of owner frames.
        local clip_num = clip.frame_rate.fps_numerator
        local clip_den = clip.frame_rate.fps_denominator
        local owner_limit = file_src_in
        if clip_num and clip_den and ctx.seq_fps_num and ctx.seq_fps_den then
            owner_limit = math.floor(
                file_src_in * clip_den * ctx.seq_fps_num / (clip_num * ctx.seq_fps_den) + 0.5)
        end
        return -owner_limit, nil  -- can't extend further left than file start
    end

    -- Out-edge source limit: growing the out-point rightward (extending
    -- the tail) can't go past the end of the media. Returns signed
    -- (min, max) limits, which flip for will_negate edges.
    local function out_edge_media_limit(ctx, clip, clip_state, will_negate)
        if not effective_delta_positive(ctx, will_negate) then return nil, nil end
        local media = fetch_media_for_clip(ctx, clip)
        if not (media and media.duration and clip_state.source_in and clip_state.duration) then
            return nil, nil
        end
        assert(type(media.duration) == "number", "apply_media_limits: media.duration must be integer")
        assert(type(clip_state.source_in) == "number", "apply_media_limits: clip_state.source_in must be integer")
        assert(type(clip_state.duration) == "number", "apply_media_limits: clip_state.duration must be integer")
        local file_src_in = file_relative_source_in(media, clip_state.source_in)
        local available = media.duration - file_src_in - clip_state.duration
        -- available is in SOURCE units; convert to OWNER (sequence) units to
        -- match the per-edge constraint operating on delta_frames.
        local clip_num = clip.frame_rate.fps_numerator
        local clip_den = clip.frame_rate.fps_denominator
        if clip_num and clip_den and ctx.seq_fps_num and ctx.seq_fps_den then
            available = math.floor(
                available * clip_den * ctx.seq_fps_num / (clip_num * ctx.seq_fps_den) + 0.5)
        end
        if will_negate then
            return -available, nil  -- negated edge is constrained on the min side
        end
        return nil, available
    end

    -- Apply source media boundary constraints to an edge. Shrinking past
    -- the file's beginning (in-edge) or extending past the file's end
    -- (out-edge) are physically impossible — the media doesn't have
    -- those frames. Gap clips are skipped (they have no source media).
    local function apply_media_limits(ctx, edge_info, clip, will_negate)
        if clip.is_gap == true then return end
        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state then return end

        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local min_limit, max_limit
        if normalized_edge == "in" then
            min_limit, max_limit = in_edge_media_limit(ctx, clip, clip_state, will_negate)
        elseif normalized_edge == "out" then
            min_limit, max_limit = out_edge_media_limit(ctx, clip, clip_state, will_negate)
        else
            return
        end
        apply_edge_constraint_limits(ctx, edge_info, build_edge_key(edge_info), min_limit, max_limit)
    end

    -- The raw (pre-negation) delta limits produced by a "don't shrink
    -- below zero" clip: trimming the in-edge by at most +duration, or
    -- the out-edge by at most -duration. Returns (min, max) or nil.
    local function duration_floor_limits(normalized_edge, duration)
        if normalized_edge == "in" then
            return nil, duration
        end
        if normalized_edge == "out" then
            return -duration, nil
        end
        return nil, nil
    end

    -- Apply the will-negate flip to a (min, max) limit pair. When an
    -- edge's applied delta is the *negation* of the global clamped
    -- delta, the global clamped delta is constrained by the negated
    -- range. Either side may be nil going in or coming out.
    local function negate_limits(min_limit, max_limit)
        local new_min = max_limit ~= nil and -max_limit or nil
        local new_max = min_limit ~= nil and -min_limit or nil
        return new_min, new_max
    end

    -- Gap clips can shrink to zero-length but not below. Apply that
    -- floor as a per-edge + global clamp.
    local function apply_gap_min_duration(ctx, edge_info, clip, will_negate)
        if not clip.is_gap then return end
        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state or not clip_state.duration or clip_state.duration <= 0 then
            return
        end

        local normalized = edge_info.normalized_edge or edge_info.edge_type
        local min_limit, max_limit = duration_floor_limits(normalized, clip_state.duration)
        if will_negate then
            min_limit, max_limit = negate_limits(min_limit, max_limit)
        end
        apply_edge_constraint_limits(ctx, edge_info, build_edge_key(edge_info), min_limit, max_limit)
    end

    -- Media clips can trim to zero (which triggers delete) but not
    -- below. Apply that floor as a per-edge + global clamp. Gap clips
    -- are handled by apply_gap_min_duration.
    local function apply_min_duration_limits(ctx, edge_info, clip, will_negate)
        if clip.is_gap == true then return end
        local clip_state = ctx.original_states_map[edge_info.clip_id]
        if not clip_state or not clip_state.duration then return end
        assert(type(clip_state.duration) == "number",
            "apply_min_duration_limits: clip_state.duration must be integer")
        if clip_state.duration < 1 then return end

        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local min_limit, max_limit = duration_floor_limits(normalized_edge, clip_state.duration)
        if min_limit == nil and max_limit == nil then return end
        if will_negate then
            min_limit, max_limit = negate_limits(min_limit, max_limit)
        end
        apply_edge_constraint_limits(ctx, edge_info, build_edge_key(edge_info), min_limit, max_limit)
    end

    -- Populate the command context's clip caches from the in-memory
    -- timeline_state. timeline_state is the single authoritative source
    -- for the active sequence: it contains media clips loaded from SQLite
    -- plus pre-computed gap clips, both exposed via per-track indexes. No
    -- DB scan, no per-clip loads, no per-clip copies at this layer.
    -- (Mutable scratch copies are taken by load_clip_for_edit on demand.)
    local function build_clip_cache(ctx)
        local timeline_state = package.loaded["ui.timeline.timeline_state"]
        assert(timeline_state
            and timeline_state.get_sequence_id
            and timeline_state.get_sequence_id() == ctx.sequence_id
            and timeline_state.get_all_tracks
            and timeline_state.get_track_clip_index,
            string.format("build_clip_cache: timeline_state must be active for sequence %s",
                tostring(ctx.sequence_id)))

        ctx.all_clips = {}
        ctx.clip_lookup = {}
        ctx.clip_track_lookup = {}
        ctx.track_clip_map = {}

        for _, track in ipairs(timeline_state.get_all_tracks()) do
            assert(track.id and track.id ~= "",
                "build_clip_cache: timeline_state returned track with empty id")
            local track_clips = timeline_state.get_track_clip_index(track.id)
            if track_clips then
                ctx.track_clip_map[track.id] = track_clips
                for _, clip in ipairs(track_clips) do
                    assert(clip.id and clip.id ~= "", string.format(
                        "build_clip_cache: clip on track %s has empty id", track.id))
                    table.insert(ctx.all_clips, clip)
                    ctx.clip_lookup[clip.id] = clip
                    ctx.clip_track_lookup[clip.id] = clip.track_id
                end
            end
        end
    end

    local function prime_neighbor_bounds_cache(ctx)
        assert(ctx.track_clip_map, "prime_neighbor_bounds_cache: track_clip_map is nil")
        -- Gaps are clips. Include them in neighbor bounds so multi-edge rolls
        -- and ripples see gap duration as a real constraint (not an invisible
        -- transparent region).
        ctx.neighbor_bounds_cache = build_neighbor_bounds_cache(ctx.track_clip_map)
    end

    -- For each ripple edge, find the gap clip on OTHER tracks at the same
    -- timeline position and inject an edge on it. If clips are adjacent
    -- (no gap), create an implied zero-length gap. This allows single-track
    -- ripple to propagate across all tracks without explicit linked selection.
    -- Collect one boundary entry per non-roll edit edge. The boundary
    -- frame is where the ripple takes effect on OTHER tracks; is_in_edge
    -- remembers whether the source edge was "in" or "out" so we can pick
    -- the right downstream clip when synthesizing an implicit gap. Edges
    -- with stale clip_ids (nothing in the bounded cache) are skipped —
    -- the parameter-validation test contract allows graceful degradation
    -- for clip_ids that point at deleted clips.
    local function collect_ripple_boundaries(ctx)
        local entries = {}
        local selected_tracks = {}
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.trim_type ~= "roll" then
                local clip = ctx.clip_lookup[edge_info.clip_id]
                if clip and type(clip.timeline_start) == "number"
                   and type(clip.duration) == "number" then
                    selected_tracks[clip.track_id] = true
                    local normalized = edge_utils.to_bracket(edge_info.edge_type)
                    if normalized == "out" then
                        table.insert(entries, {
                            frame = clip.timeline_start + clip.duration,
                            is_in_edge = false,
                        })
                    else
                        table.insert(entries, {
                            frame = clip.timeline_start,
                            is_in_edge = true,
                        })
                    end
                end
            end
        end
        return entries, selected_tracks
    end

    -- Find an existing gap clip that covers `boundary_frame` on a track.
    -- Returns the gap (starting exactly at the boundary, or spanning it)
    -- or nil if the boundary falls on a hard cut between media clips.
    local function find_gap_at_boundary(track_clips, boundary_frame)
        for _, clip in ipairs(track_clips) do
            if clip.is_gap == true then
                local clip_end = clip.timeline_start + clip.duration
                if clip.timeline_start == boundary_frame or
                   (clip.timeline_start <= boundary_frame and clip_end > boundary_frame) then
                    return clip
                end
            end
        end
        return nil
    end

    -- When a boundary lands on adjacent media clips (no existing gap),
    -- pick the media clip whose start-of-frame will anchor a zero-length
    -- implied gap. For "in" source edges we prefer the strictly-after
    -- clip first, falling back to at-or-after, matching the original
    -- heuristic that propagated in-edge ripples onto the downstream clip.
    local function find_implied_gap_anchor_clip(track_clips, boundary_frame, is_in_edge)
        local function find_first_media(predicate)
            for _, clip in ipairs(track_clips) do
                if not clip.is_gap and predicate(clip) then
                    return clip
                end
            end
            return nil
        end
        if is_in_edge then
            return find_first_media(function(c) return c.timeline_start > boundary_frame end)
                or find_first_media(function(c) return c.timeline_start >= boundary_frame end)
        end
        return find_first_media(function(c) return c.timeline_start >= boundary_frame end)
    end

    -- Create a zero-length gap clip anchored at `anchor_frame` and
    -- register it in the bounded cache so the rest of the pipeline can
    -- treat it exactly like a pre-existing gap.
    local function synthesize_implied_gap(ctx, track_id, anchor_frame)
        local seq_fps = { fps_numerator = ctx.seq_fps_num, fps_denominator = ctx.seq_fps_den }
        local gap = gap_lifecycle.create_implied_gap(track_id, anchor_frame, seq_fps)
        if not gap then return nil end
        ctx.clip_lookup[gap.id] = gap
        ctx.base_clips[gap.id] = gap
        table.insert(ctx.all_clips, gap)
        return gap
    end

    -- Resolve or synthesize the gap clip that a boundary refers to on a
    -- given track. Returns nil if the track has no content at or beyond
    -- the boundary (nothing to ripple against).
    local function resolve_gap_at_boundary(ctx, track_id, track_clips, boundary_frame, is_in_edge)
        local existing = find_gap_at_boundary(track_clips, boundary_frame)
        if existing then return existing end
        local anchor_clip = find_implied_gap_anchor_clip(track_clips, boundary_frame, is_in_edge)
        if not anchor_clip then return nil end
        return synthesize_implied_gap(ctx, track_id, anchor_clip.timeline_start)
    end

    -- Append a gap.in edge into edge_infos, capturing its original state
    -- for undo. No-op if we've already injected an edge for this gap.
    local function inject_gap_edge(ctx, gap, track_id, injected_set)
        if injected_set[gap.id] then return end
        injected_set[gap.id] = true
        ctx.original_states_map[gap.id] = command_helper.capture_clip_state(gap)
        table.insert(ctx.edge_infos, {
            clip_id = gap.id,
            edge_type = "in",
            track_id = track_id,
            trim_type = "ripple",
            is_implicit_injection = true,
        })
    end

    -- For each selected ripple edge, propagate the edit onto every other
    -- track by injecting a gap edge at the same timeline position. If a
    -- gap exists at that position we use it; otherwise we synthesize a
    -- zero-length gap so the pipeline can handle straight cuts uniformly.
    local function inject_implicit_gap_edges(ctx)
        assert(ctx.edge_infos, "inject_implicit_gap_edges: edge_infos is nil")
        assert(ctx.all_clips, "inject_implicit_gap_edges: all_clips is nil")

        local boundaries, selected_tracks = collect_ripple_boundaries(ctx)
        local injected = {}
        for _, entry in ipairs(boundaries) do
            for track_id, track_clips in pairs(ctx.track_clip_map) do
                if not selected_tracks[track_id] then
                    local gap = resolve_gap_at_boundary(
                        ctx, track_id, track_clips, entry.frame, entry.is_in_edge)
                    if gap then
                        inject_gap_edge(ctx, gap, track_id, injected)
                    end
                end
            end
        end
    end

    -- Derive the set of tracks that have clips in the bounded cache —
    -- these are the "affected" tracks the ripple/roll can touch.
    local function collect_affected_tracks_from_cache(ctx)
        assert(ctx.all_clips, "assign_edge_tracks: all_clips is nil")
        ctx.affected_tracks = {}
        for _, clip in ipairs(ctx.all_clips) do
            assert(clip.track_id and clip.track_id ~= "",
                string.format("assign_edge_tracks: clip %s missing track_id", tostring(clip.id)))
            ctx.affected_tracks[clip.track_id] = true
        end
    end

    -- Fill in each edge_info's track_id from the cache if the caller
    -- didn't provide it, record which tracks have a selected edge, and
    -- normalize the edge_type bracket. Missing track_ids crash loudly.
    local function finalize_edge_info_tracks(ctx)
        assert(ctx.edge_infos, "assign_edge_tracks: edge_infos is nil")
        ctx.selected_tracks = {}
        for _, edge_info in ipairs(ctx.edge_infos) do
            if not edge_info.track_id then
                edge_info.track_id = ctx.clip_track_lookup[edge_info.clip_id]
            end
            assert(edge_info.track_id, string.format(
                "assign_edge_tracks: edge %s:%s missing track_id (clip_id=%s not in lookup?)",
                tostring(edge_info.clip_id), tostring(edge_info.edge_type), tostring(edge_info.clip_id)))
            ctx.selected_tracks[edge_info.track_id] = true
            edge_info.normalized_edge = edge_utils.to_bracket(edge_info.edge_type)
        end
    end

    local function assign_edge_tracks(ctx)
        collect_affected_tracks_from_cache(ctx)
        finalize_edge_info_tracks(ctx)
    end

    -- Find the edge in ctx.edge_infos that matches the caller's
    -- provided_lead_edge (if any). Returns nil if no match — caller
    -- falls back to the first edge.
    local function find_provided_lead_edge(ctx)
        local provided = ctx.provided_lead_edge
        if not provided then return nil end
        local want_clip = provided.clip_id
        local want_norm = edge_utils.to_bracket(provided.edge_type or provided.normalized_edge)
        for _, edge_info in ipairs(ctx.edge_infos) do
            local matches_clip = want_clip
                and (edge_info.clip_id == want_clip or edge_info.original_clip_id == want_clip)
            local matches_edge = not want_norm or edge_info.normalized_edge == want_norm
            if matches_clip and matches_edge then
                return edge_info
            end
        end
        return nil
    end

    -- Pick the "lead" edge for the command (the one the UI treats as
    -- the drag source) and persist a summary back onto the command.
    -- The lead edge drives the sign convention for other edges in the
    -- same command via the edge_will_negate map.
    local function determine_lead_edge(ctx)
        assert(ctx.edge_infos, "determine_lead_edge: edge_infos is nil")
        ctx.lead_edge_entry = find_provided_lead_edge(ctx) or ctx.edge_infos[1]
        if not ctx.lead_edge_entry then return end
        ctx.command:set_parameter("lead_edge", {
            clip_id = ctx.lead_edge_entry.original_clip_id or ctx.lead_edge_entry.clip_id,
            original_clip_id = ctx.lead_edge_entry.original_clip_id,
            edge_type = ctx.lead_edge_entry.edge_type,
            track_id = ctx.lead_edge_entry.track_id,
            trim_type = ctx.lead_edge_entry.trim_type,
        })
    end

    -- Load a clip for mutation. The base clip comes from timeline_state
    -- (the authoritative in-memory model) and must never be mutated
    -- directly — retries and multi-pass constraint math depend on
    -- reloading the original state from `base`. The command context owns
    -- the mutable scratch copy; final mutations persist via
    -- command_helper.apply_mutations. Returns nil for stale clip_ids.
    local function load_clip_for_edit(ctx, clip_id)
        local existing = ctx.modified_clips[clip_id]
        if existing then
            return existing
        end

        local base = fetch_base_clip(ctx, clip_id)
        if not base then
            return nil
        end

        if not ctx.original_states_map[clip_id] then
            ctx.original_states_map[clip_id] = command_helper.capture_clip_state(base)
        end

        local clip = {
            id = base.id,
            project_id = base.project_id,
            track_type = base.track_type,
            owner_sequence_id = base.owner_sequence_id,
            track_sequence_id = base.track_sequence_id,
            nested_sequence_id = base.nested_sequence_id,
            master_layer_track_id = base.master_layer_track_id,
            master_audio_track_id = base.master_audio_track_id,
            fps_mismatch_policy = base.fps_mismatch_policy,
            track_id = base.track_id,
            timeline_start = base.timeline_start,
            duration = base.duration,
            source_in = base.source_in,
            source_out = base.source_out,
            name = base.name,
            enabled = base.enabled,
            -- Carry is_gap so downstream gap-aware code (compute_seed_shift_contribution,
            -- register_ripple_anchor) sees the gap-orientation flip on synthesized
            -- gap edges. Without it, cross-track ripple propagation flipped sign.
            is_gap = base.is_gap,
            frame_rate = base.frame_rate,
            fps_numerator = base.frame_rate.fps_numerator,
            fps_denominator = base.frame_rate.fps_denominator,
            created_at = base.created_at,
            modified_at = base.modified_at,
        }
        ctx.modified_clips[clip_id] = clip
        return clip
    end

    -- Convert timeline-frame delta to source units for a clip.
    -- Delegates to frame_utils.timeline_to_source (the canonical conversion).
    local function timeline_delta_to_source(delta_frames_val, clip, seq_fps_num, seq_fps_den)
        local clip_num = clip.frame_rate.fps_numerator
        local clip_den = clip.frame_rate.fps_denominator
        assert(clip_num and clip_den, string.format(
            "apply_edge_ripple: clip %s missing fps", tostring(clip.id)))
        return frame_utils.timeline_to_source(delta_frames_val, clip_num, clip_den, seq_fps_num, seq_fps_den)
    end

-- Apply the requested trim delta to clip edges. Gap clips and media
-- clips share the same logic; the two differences:
-- - Gap clips have nil source_in/source_out (no source modification)
-- - Gap clips can reach duration 0; media clips at duration < 1 are deleted
--
-- Source coordinate rules:
-- - "in" edge:  source_in moves by source_delta, source_out STAYS
-- - "out" edge: source_out moves by source_delta, source_in STAYS
-- Preserves the clip's speed ratio for non-unity-speed clips.

    -- Compute the trimmed (duration, source_in, source_out) for an "in"
    -- edge. Does NOT mutate the clip — returns the new values. Caller
    -- decides whether the values are legal (non-negative duration).
    local function compute_in_edge_trim(clip, delta_frames, seq_fps_num, seq_fps_den)
        local new_duration = clip.duration - delta_frames
        local new_source_in = clip.source_in
        if new_source_in then
            local source_delta = timeline_delta_to_source(delta_frames, clip, seq_fps_num, seq_fps_den)
            new_source_in = clip.source_in + source_delta
        end
        return new_duration, new_source_in, clip.source_out
    end

    -- Compute the trimmed values for an "out" edge. Timeline start never
    -- changes for out edges.
    local function compute_out_edge_trim(clip, delta_frames, seq_fps_num, seq_fps_den)
        local new_duration = clip.duration + delta_frames
        local new_source_out = clip.source_out
        if new_source_out then
            local source_delta = timeline_delta_to_source(delta_frames, clip, seq_fps_num, seq_fps_den)
            new_source_out = clip.source_out + source_delta
        end
        return new_duration, clip.source_in, new_source_out
    end

    local function apply_edge_ripple(clip, edge_type, delta_frames, trim_type, seq_fps_num, seq_fps_den)
        assert(type(clip.duration) == "number", "apply_edge_ripple: clip.duration must be integer")
        assert(type(clip.timeline_start) == "number", "apply_edge_ripple: clip.timeline_start must be integer")
        assert(type(delta_frames) == "number", "apply_edge_ripple: delta_frames must be integer")

        local new_duration, new_source_in, new_source_out
        if edge_type == "in" then
            new_duration, new_source_in, new_source_out =
                compute_in_edge_trim(clip, delta_frames, seq_fps_num, seq_fps_den)
            if trim_type == "roll" then
                clip.timeline_start = clip.timeline_start + delta_frames
            end
        elseif edge_type == "out" then
            new_duration, new_source_in, new_source_out =
                compute_out_edge_trim(clip, delta_frames, seq_fps_num, seq_fps_den)
        else
            error(string.format("apply_edge_ripple: Unsupported edge_type '%s'", edge_type))
        end

        -- Gaps floor at 0 duration; media clips below 1 frame are deleted.
        local is_gap = clip.is_gap == true
        if is_gap then
            if new_duration < 0 then new_duration = 0 end
        elseif new_duration < 1 then
            clip.duration = 0
            clip.source_in = new_source_in
            clip.source_out = new_source_out
            return clip.timeline_start, true, true  -- success, deleted_clip=true
        end

        clip.duration = new_duration
        clip.source_in = new_source_in
        clip.source_out = new_source_out
        return clip.timeline_start, true, false
    end

    -- Return the bracket ("in" / "out") of the lead edge, or nil when
    -- no lead edge has been established yet.
    local function lead_edge_bracket(ctx)
        if not ctx.lead_edge_entry then return nil end
        local normalized = ctx.lead_edge_entry.normalized_edge
            or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type)
        return bracket_for_normalized_edge(normalized)
    end

    -- Populate edited_clip_lookup, edge_info_for_key, edge_will_negate,
    -- selection_has_clip_edge, and lead_is_gap from ctx.edge_infos.
    -- An edge "will negate" when it belongs to a multi-edge ripple with
    -- the opposite in/out bracket from the lead edge — its delta will
    -- be applied with flipped sign in compute_applied_delta.
    local function classify_selected_edges(ctx)
        ctx.selection_has_clip_edge = false
        ctx.edited_clip_lookup = {}
        ctx.edge_will_negate = {}

        local lead_clip = ctx.lead_edge_entry and ctx.clip_lookup[ctx.lead_edge_entry.clip_id]
        ctx.lead_is_gap = lead_clip and lead_clip.is_gap == true
        local lead_bracket = lead_edge_bracket(ctx)

        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.clip_id then
                local edge_clip = ctx.clip_lookup[edge_info.clip_id]
                ctx.edited_clip_lookup[edge_info.clip_id] = true
                if edge_clip and not edge_clip.is_gap then
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
    end

    -- Flag tracks that carry 2+ roll edges. These "roll edit points" use
    -- the globally-clamped delta (one shared value across all their roll
    -- edges); tracks with a single roll edge use per-edge constraints
    -- independently (the classic multitrack-roll semantic).
    local function detect_roll_edit_point_tracks(ctx)
        ctx.roll_edit_point_tracks = {}
        local roll_edges_by_track = {}
        for _, edge_info in ipairs(ctx.edge_infos) do
            if edge_info.trim_type == "roll" and edge_info.track_id then
                roll_edges_by_track[edge_info.track_id] =
                    (roll_edges_by_track[edge_info.track_id] or 0) + 1
            end
        end
        for track_id, count in pairs(roll_edges_by_track) do
            if count >= 2 then
                ctx.roll_edit_point_tracks[track_id] = true
            end
        end
    end

    local function analyze_selection(ctx)
        assert(ctx.edge_infos, "analyze_selection: edge_infos is nil")
        classify_selected_edges(ctx)
        ctx.clamped_delta_frames = ctx.delta_frames
        detect_roll_edit_point_tracks(ctx)
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

    -- Reset the per-command global delta bounds to the unconstrained
    -- state before compute_constraints walks the edges.
    local function reset_global_constraints(ctx)
        ctx.global_min_frames = -math.huge
        ctx.global_max_frames = math.huge
        ctx.global_min_edge_keys = {}
        ctx.global_max_edge_keys = {}
    end

    -- Apply every constraint type (roll neighbors, gap min duration,
    -- media bounds, clip min duration) to a single edge. Each
    -- sub-function tightens the per-edge and global bounds directly
    -- on ctx via apply_edge_constraint_limits.
    local function constrain_one_edge(ctx, edge_info)
        local clip = ensure_clip_loaded(ctx, edge_info.clip_id)
        if not clip then return end
        local neighbors = ensure_neighbor_bounds(ctx, edge_info.clip_id)
        local edge_key = build_edge_key(edge_info)
        ctx.per_edge_constraints[edge_key] = ctx.per_edge_constraints[edge_key]
            or {min = -math.huge, max = math.huge}

        apply_roll_constraints(ctx, edge_info, clip, neighbors)
        local will_negate = should_negate_edge(ctx, edge_key)
        apply_gap_min_duration(ctx, edge_info, clip, will_negate)
        apply_media_limits(ctx, edge_info, clip, will_negate)
        apply_min_duration_limits(ctx, edge_info, clip, will_negate)
    end

    -- Force the global bounds into a "no shift allowed" state. Used by
    -- the __force_conflict_delta debug path to simulate a fully
    -- clamped edit.
    local function apply_forced_conflict(ctx)
        ctx.global_min_frames = 1
        ctx.global_max_frames = 0
        ctx.global_min_edge_keys = {}
        ctx.global_max_edge_keys = {}
    end

    -- When the clamp moved the delta, any edge key that contributed
    -- to the winning min/max but has no explicit per-edge constraint
    -- entry is "implied" — promote it into forced_clamped_edges so
    -- the UI highlights it as the blocker.
    local function promote_implied_blocker_edges(ctx)
        if ctx.clamp_direction == 0 then return end
        local source_map
        if ctx.clamp_direction == -1 then
            source_map = ctx.global_min_edge_keys
        elseif ctx.clamp_direction == 1 then
            source_map = ctx.global_max_edge_keys
        end
        if not source_map then return end
        for key in pairs(source_map) do
            if key and not ctx.per_edge_constraints[key] then
                ctx.forced_clamped_edges[key] = true
            end
        end
    end

    local function compute_constraints(ctx)
        assert(ctx.edge_infos, "compute_constraints: edge_infos is nil")
        reset_global_constraints(ctx)

        for _, edge_info in ipairs(ctx.edge_infos) do
            constrain_one_edge(ctx, edge_info)
        end

        compute_earliest_ripple_hint(ctx)
        if ctx.command:get_parameter('__force_conflict_delta') then
            apply_forced_conflict(ctx)
        end
        clamp_delta(ctx)
        promote_implied_blocker_edges(ctx)
    end

    local function add_preview_shift(ctx, clip_id, new_start, new_duration)
        if not ctx.dry_run or not clip_id or not new_start then
            return
        end
        if ctx.preview_shifted_lookup[clip_id] then
            return
        end
        table.insert(ctx.preview_shifted_clips, {
            clip_id = clip_id,
            new_start_value = new_start,
            new_duration = new_duration,
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
        ctx.preview_shifted_lookup = {}
    end

    -- Multitrack roll delta: start from the raw user delta (not the
    -- globally clamped one) and clamp it against this edge's own
    -- per-edge constraint envelope. The edge is free to clamp
    -- independently of the other edges in the same command.
    local function compute_multitrack_roll_delta(ctx, edge_key)
        local delta = ctx.delta_frames
        if should_negate_edge(ctx, edge_key) then
            delta = -delta
        end
        local bounds = ctx.per_edge_constraints[edge_key]
        if not bounds then return delta end
        local before = delta
        if bounds.min ~= -math.huge and delta < bounds.min then
            delta = bounds.min
        end
        if bounds.max ~= math.huge and delta > bounds.max then
            delta = bounds.max
        end
        if before ~= delta then
            log.event("Multitrack roll edge %s: requested=%d, clamped to %d (min=%s, max=%s)",
                edge_key, before, delta,
                bounds.min == -math.huge and "-inf" or tostring(bounds.min),
                bounds.max == math.huge and "+inf" or tostring(bounds.max))
        end
        return delta
    end

    -- Globally clamped delta, possibly negated. Used by ripple edges
    -- and by same-track roll edit points (where all edges share one
    -- clamped value).
    local function global_clamped_delta(ctx, edge_key)
        if should_negate_edge(ctx, edge_key) then
            return -ctx.clamped_delta_frames
        end
        return ctx.clamped_delta_frames
    end

    local function compute_applied_delta(ctx, edge_key, edge_info)
        local multitrack_roll = edge_info and is_multitrack_roll_edge(ctx, edge_info)
        local applied
        if multitrack_roll then
            applied = compute_multitrack_roll_delta(ctx, edge_key)
        else
            applied = global_clamped_delta(ctx, edge_key)
        end
        log.event("compute_applied_delta: key=%s, is_multitrack_roll=%s, delta_frames=%s, clamped=%s, result=%s",
            edge_key, tostring(multitrack_roll), tostring(ctx.delta_frames),
            tostring(ctx.clamped_delta_frames), tostring(applied))
        return applied
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

    local function compute_seed_shift_contribution(seed, drag_sign)
        local orientation_sign = (seed.orientation == "in") and -1 or 1
        if seed.is_gap then
            return seed.applied_delta * orientation_sign
        end
        local magnitude = math.abs(seed.applied_delta)
        local direction_sign = drag_sign
        if seed.orientation == "out" then
            direction_sign = (seed.applied_delta >= 0) and 1 or -1
        end
        return magnitude * direction_sign * orientation_sign
    end

    local function register_track_shift_seed(ctx, clip, normalized_edge, applied_delta, is_gap_edge_type, ripple_point)
        if not clip.track_id then return end
        if not ctx.track_shift_seeds[clip.track_id] then
            ctx.track_shift_seeds[clip.track_id] = {}
        end
        -- When both edges of the same clip are selected (e.g. gap in+out),
        -- they form a single roll-like operation — not two independent ripple
        -- contributions. Only the first edge per clip registers a seed.
        for _, existing in ipairs(ctx.track_shift_seeds[clip.track_id]) do
            if existing.clip_id == clip.id then
                return
            end
        end
        table.insert(ctx.track_shift_seeds[clip.track_id], {
            clip_id = clip.id,
            orientation = normalized_edge,
            applied_delta = applied_delta,
            is_gap = is_gap_edge_type,
            ripple_point = ripple_point,
        })
    end

    local function record_preview_for_edge(ctx, clip, edge_info, normalized_edge)
        if not ctx.dry_run then
            return
        end
        table.insert(ctx.preview_affected_clips, {
            clip_id = clip.id,
            new_start_value = clip.timeline_start,
            new_duration = clip.duration,
            edge_type = normalized_edge,
            raw_edge_type = edge_info.edge_type,
            is_gap = clip.is_gap == true,
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

    -- Sum the shift contributions of every seed on a track to produce
    -- that track's total shift amount. Seeds with nil orientation or
    -- a non-numeric applied_delta contribute zero (defensive, matches
    -- pre-existing semantics).
    local function sum_track_seed_shifts(seeds, drag_sign)
        local total = 0
        for _, seed in ipairs(seeds) do
            if seed.orientation and type(seed.applied_delta) == "number" then
                total = total + compute_seed_shift_contribution(seed, drag_sign)
            end
        end
        return total
    end

    -- Resolve the fallback downstream_shift_frames for tracks that had
    -- no seeds of their own: prefer the anchor track's accumulated
    -- shift so non-seeded tracks stay in sync; otherwise derive from
    -- the ripple anchor's edge type + applied delta.
    local function fallback_downstream_shift(ctx)
        local anchor_track_id = ctx.ripple_anchor_track_id
        if anchor_track_id and ctx.track_shift_amounts[anchor_track_id] then
            return ctx.track_shift_amounts[anchor_track_id]
        end
        assert(type(ctx.ripple_anchor_applied_delta) == "number",
            "compute_track_shift_amounts: ripple_anchor_applied_delta must be integer")
        local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
        return ctx.ripple_anchor_applied_delta * shift_factor
    end

    local function compute_track_shift_amounts(ctx)
        if not ctx.has_ripple_edge then
            ctx.downstream_shift_frames = 0
            return
        end
        local drag_sign = (ctx.clamped_delta_frames >= 0) and 1 or -1
        for track_id, seeds in pairs(ctx.track_shift_seeds) do
            ctx.track_shift_amounts[track_id] = sum_track_seed_shifts(seeds, drag_sign)
        end
        ctx.downstream_shift_frames = fallback_downstream_shift(ctx)
    end

    --- When multiple ripple edges are on the same track, edited clips need partial
    --- shifts from edges that precede them. E.g., if A and B are abutted and both
    --- out-edges are ripple-trimmed, B needs to shift by A's ripple contribution
    --- (in addition to its own trim). Without this, a gap opens between A and B.
    -- Build a prefix sum of shift contributions for a list of seeds
    -- sorted by ripple_point. prefix_shift[i] is the total shift
    -- contributed by seeds 1..i — use prefix_shift[i-1] to shift
    -- seed[i]'s clip by the work of every earlier seed.
    local function build_prefix_shift_sums(seeds, drag_sign)
        local prefix_shift = { [0] = 0 }
        for i, seed in ipairs(seeds) do
            local contribution = 0
            if seed.orientation and type(seed.applied_delta) == "number" then
                contribution = compute_seed_shift_contribution(seed, drag_sign)
            end
            prefix_shift[i] = prefix_shift[i - 1] + contribution
        end
        return prefix_shift
    end

    -- When multiple ripple seeds exist on the same track, each seed's
    -- clip needs to be shifted by the CUMULATIVE contribution of every
    -- seed that precedes it in timeline order — not just its own. This
    -- closes the gap that would otherwise open between abutted clips
    -- when both of their out-edges are trimmed in a single command.
    local function apply_same_track_partial_shifts(ctx)
        local drag_sign = (ctx.clamped_delta_frames >= 0) and 1 or -1
        for _, seeds in pairs(ctx.track_shift_seeds) do
            if #seeds >= 2 then
                table.sort(seeds, function(a, b)
                    return (a.ripple_point or 0) < (b.ripple_point or 0)
                end)
                local prefix_shift = build_prefix_shift_sums(seeds, drag_sign)
                for i, seed in ipairs(seeds) do
                    local partial = prefix_shift[i - 1]
                    if partial ~= 0 and seed.clip_id then
                        local clip = ctx.modified_clips[seed.clip_id]
                        if clip and type(clip.timeline_start) == "number" then
                            clip.timeline_start = clip.timeline_start + partial
                        end
                    end
                end
            end
        end
    end

    local function ensure_earliest_ripple_time(ctx)
        if not ctx.earliest_ripple_time then
            ctx.earliest_ripple_time = 0
        end
    end

    -- When an implied zero-length gap gets a non-zero delta but ends up
    -- at duration 0 anyway, the gap couldn't absorb the shift. Record
    -- the edge as a blocker so the UI highlights it in red.
    local function record_blocked_gap_edge(ctx, key, clip, original, applied_delta)
        if not clip.is_gap then return end
        if applied_delta == 0 or clip.duration ~= 0 then return end
        local original_dur = original and original.duration or 0
        if original_dur == 0 or (original_dur + applied_delta < 0) then
            ctx.forced_clamped_edges[key] = true
        end
    end

    -- Narrow the per-track ripple start to the earliest point any edge
    -- on that track reached. This is what compute_downstream_shifts
    -- uses to position its bulk_shift anchor.
    local function update_track_ripple_start(ctx, track_id, ripple_point)
        if type(ripple_point) ~= "number" or not track_id then return end
        local existing = ctx.track_ripple_start_frames[track_id]
        if not existing or ripple_point < existing then
            ctx.track_ripple_start_frames[track_id] = ripple_point
        end
    end

    -- Apply a single edge's trim to its clip, update ripple bookkeeping,
    -- and return (ok, halt). `halt` signals that apply_edge_ripple
    -- reported hard failure — the caller should abort the whole command.
    local function apply_one_edge_trim(ctx, edge_info)
        local clip_id = edge_info.clip_id
        local clip = load_clip_for_edit(ctx, clip_id)
        if not clip then
            log.warn("BatchRippleEdit: Clip %s not found. Skipping.", tostring(clip_id))
            return true
        end
        if ctx.clips_marked_delete[clip_id] then
            return true
        end

        local original = ctx.original_states_map[clip_id]
        local normalized_edge = edge_info.normalized_edge or edge_info.edge_type
        local key = build_edge_key(edge_info)
        local applied_delta = compute_applied_delta(ctx, key, edge_info)

        local _, success, deleted_clip = apply_edge_ripple(
            clip, normalized_edge, applied_delta, edge_info.trim_type,
            ctx.seq_fps_num, ctx.seq_fps_den)
        if not success then
            log.error("Ripple failed for clip %s (edge=%s trim=%s delta=%s)",
                tostring(clip.id), tostring(edge_info.edge_type),
                tostring(edge_info.trim_type), tostring(applied_delta))
            return false
        end

        record_blocked_gap_edge(ctx, key, clip, original, applied_delta)
        local ripple_point = compute_ripple_point(original, clip, normalized_edge)

        if edge_info.trim_type ~= "roll" then
            register_ripple_anchor(ctx, normalized_edge, clip.is_gap == true,
                applied_delta, clip.track_id, key)
            register_track_shift_seed(ctx, clip, normalized_edge, applied_delta,
                clip.is_gap == true, ripple_point)
        end
        record_preview_for_edge(ctx, clip, edge_info, normalized_edge)
        if deleted_clip then
            ctx.clips_marked_delete[clip_id] = true
        end
        update_track_ripple_start(ctx, clip.track_id, ripple_point)
        update_earliest_ripple_time(ctx, ripple_point)
        return true
    end

    -- After apply_same_track_partial_shifts re-positions clips, the
    -- preview entries captured by record_preview_for_edge may hold stale
    -- timeline_start values. Refresh them from ctx.modified_clips.
    local function refresh_preview_start_values(ctx)
        if not (ctx.dry_run and ctx.preview_affected_clips) then return end
        for _, entry in ipairs(ctx.preview_affected_clips) do
            local clip = ctx.modified_clips[entry.clip_id]
            if clip and type(clip.timeline_start) == "number" then
                entry.new_start_value = clip.timeline_start
            end
        end
    end

    local function process_edge_trims(ctx)
        assert(ctx.edge_infos, "process_edge_trims: edge_infos is nil")
        reset_ripple_processing_state(ctx)

        for _, edge_info in ipairs(ctx.edge_infos) do
            if not apply_one_edge_trim(ctx, edge_info) then
                return false
            end
        end

        compute_track_shift_amounts(ctx)
        apply_same_track_partial_shifts(ctx)
        refresh_preview_start_values(ctx)
        ensure_earliest_ripple_time(ctx)
        return true
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
        for track_id, shift_frames in pairs(ctx.track_shift_amounts) do
            assert(type(shift_frames) == "number",
                "build_preview_shift_blocks: track shift must be integer for track " .. tostring(track_id))
            local start_frames = ctx.track_ripple_start_frames[track_id] or global_start_frames
            if shift_frames ~= 0 and (shift_frames ~= global_shift or start_frames ~= global_start_frames) then
                table.insert(blocks, {start_frames = start_frames, delta_frames = shift_frames, track_id = track_id})
            end
        end
        return blocks
    end

    -- Locate the first non-edited, non-gap clip at or after `boundary_frame`
    -- on a track, plus the last non-edited, non-gap clip ending at or before
    -- the boundary. Gap clips are transparent — they represent consumable
    -- empty space, not solid content that can collide with a shift.
    --
    -- @return table|nil first_downstream, number upstream_end, string|nil upstream_id
    local function find_track_boundary_neighbors(ctx, track_id, boundary_frame)
        local clips = ctx.track_clip_map[track_id]
        assert(clips, string.format(
            "find_track_boundary_neighbors: no track_clip_map entry for track %s",
            tostring(track_id)))
        local upstream_end = 0
        local upstream_id = nil
        local first_downstream = nil
        for _, clip in ipairs(clips) do
            if clip.is_gap == true or ctx.edited_clip_lookup[clip.id] then
                goto continue
            end
            if clip.timeline_start >= boundary_frame then
                if not first_downstream then
                    first_downstream = clip
                end
            else
                local clip_end = clip.timeline_start + clip.duration
                if clip_end > upstream_end then
                    upstream_end = clip_end
                    upstream_id = clip.id
                end
            end
            ::continue::
        end
        return first_downstream, upstream_end, upstream_id
    end

    -- Resolve the ripple boundary frame for a track. Tracks touched by a
    -- ripple edge have their own per-track boundary in track_ripple_start_frames;
    -- tracks that only participate via propagation use the global earliest
    -- ripple time.
    local function track_ripple_boundary(ctx, track_id)
        return ctx.track_ripple_start_frames[track_id] or ctx.earliest_ripple_time
    end

    -- The per-edge propagation delta — the amount every cross-track
    -- (non-seeded) track shifts in a ripple. This is the ripple
    -- anchor's applied delta adjusted for its edge orientation, NOT
    -- the sum of all seeds on the anchor track. For a single-edge
    -- ripple they're equal; for a multi-edge same-track ripple they
    -- differ (the sum is used for the anchor track's own downstream).
    local function cross_track_propagation_shift(ctx)
        assert(type(ctx.ripple_anchor_applied_delta) == "number",
            "cross_track_propagation_shift: ripple_anchor_applied_delta must be integer")
        local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
        return ctx.ripple_anchor_applied_delta * shift_factor
    end

    -- Resolve the shift amount for a track.
    --   Seeded track  → track_shift_amounts[track] (accumulated contributions)
    --   Non-seeded    → cross-track propagation delta (per-edge, not summed)
    local function track_shift_amount(ctx, track_id)
        if ctx.track_shift_amounts[track_id] then
            return ctx.track_shift_amounts[track_id]
        end
        return cross_track_propagation_shift(ctx)
    end

    -- Compute the most-negative shift the affected tracks can tolerate
    -- before a non-edited downstream clip collides with its non-edited
    -- upstream neighbor. Positive ripples have no upstream collision
    -- (everything moves right in lockstep). Tracks whose upstream is
    -- itself being edited are skipped — the upstream shifts along with
    -- the edit, not against it.
    --
    -- The check is per-track: each track contributes its own
    -- track_shift_amount to the comparison, not a single global delta.
    -- A track with plenty of room doesn't get clamped by another
    -- track's tighter constraint unless that track would actually
    -- over-shift under its own amount.
    --
    -- Blocker key reports the upstream clip's :out edge — that's the
    -- surface the downstream clip is running into, which matches the
    -- UI's "what's in the way" highlighting convention.
    local function compute_downstream_max_left_shift(ctx)
        local max_left = -math.huge
        local blocker_key = nil
        for track_id in pairs(ctx.affected_tracks) do
            local boundary = track_ripple_boundary(ctx, track_id)
            if boundary then
                local first_ds, upstream_end, upstream_id = find_track_boundary_neighbors(ctx, track_id, boundary)
                if first_ds and upstream_id and not ctx.edited_clip_lookup[upstream_id] then
                    local track_max_left = -(first_ds.timeline_start - upstream_end)
                    -- Only this track's own shift amount can be blocked
                    -- here; don't clamp tracks that fit inside their room.
                    local this_shift = track_shift_amount(ctx, track_id)
                    if this_shift < track_max_left and track_max_left > max_left then
                        max_left = track_max_left
                        blocker_key = upstream_id .. ":out"
                    end
                end
            end
        end
        return max_left, blocker_key
    end

    -- True iff at least one affected track would shift by a non-zero amount.
    -- A ripple with all-zero per-track shifts is a no-op downstream.
    local function has_nonzero_downstream_shift(ctx)
        if (ctx.downstream_shift_frames or 0) ~= 0 then
            return true
        end
        for _, shift_frames in pairs(ctx.track_shift_amounts) do
            if shift_frames ~= 0 then
                return true
            end
        end
        return false
    end

    -- Persist the forced-clamped-edge keys through a retry so the UI can
    -- continue to highlight the blocker edges in red after the delta is
    -- re-computed.
    local function persist_blocker_keys(ctx)
        if not ctx.forced_clamped_edges then return end
        local blocker_keys = {}
        for key in pairs(ctx.forced_clamped_edges) do
            table.insert(blocker_keys, key)
        end
        if #blocker_keys > 0 then
            ctx.command:set_parameter("__shift_blocker_keys", blocker_keys)
        end
    end

    -- Clamp the desired downstream shift to the tightest leftward room
    -- across affected tracks. If the clamp is active, mark the blocking
    -- edge for UI feedback and return `adjusted` != `desired` so the
    -- pipeline triggers a retry.
    local function clamp_downstream_shift(ctx)
        local max_left, blocker_key = compute_downstream_max_left_shift(ctx)
        local desired = ctx.downstream_shift_frames
        local adjusted = desired
        if max_left ~= -math.huge and desired < max_left then
            adjusted = max_left
            if blocker_key then
                ctx.forced_clamped_edges[blocker_key] = true
            end
        end
        if ctx.args.__force_retry_delta then
            adjusted = ctx.args.__force_retry_delta
        end
        return adjusted, desired
    end

    -- Emit one bulk_shift mutation per affected track. The SQL substrate
    -- (command_helper.apply_mutations + revert_mutations) owns the
    -- per-track UPDATE and the undo reverse-shift.
    --
    -- Canonical shape: { type, track_id, shift_frames, start_frame }.
    -- start_frame is the pre-shift position of the first clip that
    -- participates in the shift; every clip on the track with
    -- timeline_start_frame >= start_frame gets moved by shift_frames.
    local function emit_bulk_shift_mutations(ctx)
        for track_id in pairs(ctx.affected_tracks) do
            local boundary = track_ripple_boundary(ctx, track_id)
            local shift_frames = track_shift_amount(ctx, track_id)
            if boundary and shift_frames and shift_frames ~= 0 then
                local first_ds = find_track_boundary_neighbors(ctx, track_id, boundary)
                if first_ds then
                    table.insert(ctx.bulk_shift_mutations, {
                        type = "bulk_shift",
                        track_id = track_id,
                        shift_frames = shift_frames,
                        start_frame = first_ds.timeline_start,
                    })
                end
            end
        end
    end

    -- Dry-run only: emit one per-clip preview entry for every clip that
    -- the bulk_shift would move. The commit path doesn't need this (the
    -- SQL UPDATE does the work), but the UI preview and test assertions
    -- expect per-clip entries so they can render/verify each shifted
    -- clip individually.
    local function populate_preview_shifts(ctx)
        for track_id in pairs(ctx.affected_tracks) do
            local boundary = track_ripple_boundary(ctx, track_id)
            local shift_frames = track_shift_amount(ctx, track_id)
            if boundary and shift_frames and shift_frames ~= 0 then
                local first_ds = find_track_boundary_neighbors(ctx, track_id, boundary)
                if first_ds then
                    for _, clip in ipairs(ctx.track_clip_map[track_id]) do
                        local is_shifted = not clip.is_gap
                            and not ctx.edited_clip_lookup[clip.id]
                            and clip.timeline_start >= first_ds.timeline_start
                        if is_shifted then
                            add_preview_shift(ctx, clip.id,
                                clip.timeline_start + shift_frames, clip.duration)
                        end
                    end
                end
            end
        end
    end

    local function compute_downstream_shifts(ctx)
        if not ctx.has_ripple_edge then
            return true
        end
        if not has_nonzero_downstream_shift(ctx) then
            return true
        end

        local adjusted, desired = clamp_downstream_shift(ctx)
        if adjusted ~= desired then
            persist_blocker_keys(ctx)
            return false, adjusted
        end

        emit_bulk_shift_mutations(ctx)

        if ctx.dry_run then
            populate_preview_shifts(ctx)
            ctx.shift_blocks = build_preview_shift_blocks(ctx)
        end

        return true
    end

    -- Convert a desired TOTAL downstream shift back into the
    -- per-edge delta_frames that the executor takes as input. We use
    -- the ratio between the current pipeline shift and the current
    -- pipeline delta — this preserves multi-edge sign/scale behavior
    -- across the retry. Falls back to the single-anchor sign formula
    -- when no meaningful ratio is available.
    local function retry_delta_from_adjusted_shift(ctx, adjusted_frames)
        local current_shift = ctx.downstream_shift_frames
        local current_delta = ctx.clamped_delta_frames
        if current_shift ~= 0 and current_delta ~= 0 then
            local raw = adjusted_frames * current_delta / current_shift
            -- Round toward zero so the retry stays inside the constraint.
            return raw >= 0 and math.floor(raw) or math.ceil(raw)
        end
        local shift_factor = (ctx.ripple_anchor_edge_type == "in") and -1 or 1
        local anchor_sign = ctx.ripple_anchor_negated and -1 or 1
        return adjusted_frames / (shift_factor * anchor_sign)
    end

    -- Re-execute BatchRippleEdit with a new delta after the downstream
    -- max-shift check clamped it. Increments a retry counter to bound
    -- the recursion; once the limit is hit we fail the whole command
    -- rather than looping forever.
    local function retry_with_adjusted_delta(ctx, adjusted_frames)
        local retry_count = ctx.args.__retry_delta_count or 0
        if retry_count > ui_constants.TIMELINE.MAX_RIPPLE_CONSTRAINT_RETRIES then
            return false, "Failed to clamp ripple delta without overlap (retry limit)"
        end
        ctx.command:set_parameter("__retry_delta_count", retry_count + 1)
        ctx.command:set_parameter("delta_ms", nil)

        local retry_delta_frames = retry_delta_from_adjusted_shift(ctx, adjusted_frames)
        ctx.command:set_parameter("delta_frames", retry_delta_frames)
        local adjusted_ms = frame_utils.frames_to_ms(adjusted_frames, ctx.seq_fps_num, ctx.seq_fps_den)
        ctx.command:set_parameter("clamped_delta_ms", adjusted_ms)
        ctx.command:set_parameter("clamped_delta_frames", adjusted_frames)

        return command_executors["BatchRippleEdit"](ctx.command)
    end

    -- Return the starting frame of a mutation for ordering purposes.
    -- Updates carry it directly; deletes carry it on `previous`.
    local function mutation_sort_key(mut)
        if mut.type == "update" then
            assert(type(mut.timeline_start_frame) == "number",
                "build_planned_mutations: update missing timeline_start_frame")
            return mut.timeline_start_frame
        end
        if mut.type == "delete" then
            local prev = mut.previous
            assert(type(prev) == "table",
                "build_planned_mutations: delete missing previous state")
            local start_value = prev.timeline_start or prev.start_value
            assert(type(start_value) == "number",
                "build_planned_mutations: delete previous timeline_start must be integer")
            return start_value
        end
        error("build_planned_mutations: unsupported mutation type for sorting: " .. tostring(mut.type))
    end

    -- Partition ctx.modified_clips into three planned-mutation lists:
    -- gap previews (dry-run only), delete/update records for media
    -- clips, and the implicit "nothing" for clips that should stay put.
    local function partition_modified_clips(ctx)
        local gap_mutations = {}
        local clip_mutations = {}
        for id, clip in pairs(ctx.modified_clips) do
            local original = ctx.original_states_map[id]
            if clip and clip.is_gap == true then
                if ctx.dry_run then
                    assert(type(clip.timeline_start) == "number",
                        "build_planned_mutations: gap timeline_start must be integer")
                    assert(type(clip.duration) == "number",
                        "build_planned_mutations: gap duration must be integer")
                    table.insert(gap_mutations, {
                        type = "gap_preview",
                        clip_id = id,
                        timeline_start_frame = clip.timeline_start,
                        duration_frames = clip.duration,
                    })
                end
            elseif ctx.clips_marked_delete[id] then
                table.insert(clip_mutations, clip_mutator.plan_delete(original))
            else
                table.insert(clip_mutations, clip_mutator.plan_update(clip, original))
            end
        end
        return gap_mutations, clip_mutations
    end

    -- Split ctx.bulk_shift_mutations by direction. Positive shifts go
    -- BEFORE per-clip updates (move clips out of the way first);
    -- negative shifts go AFTER (make room first, then collapse).
    -- Zero shifts are dropped — they'd be no-ops.
    local function partition_bulk_shifts(ctx)
        local pre, post = {}, {}
        if not (ctx.bulk_shift_mutations and #ctx.bulk_shift_mutations > 0) then
            return pre, post
        end
        for _, mut in ipairs(ctx.bulk_shift_mutations) do
            assert(type(mut) == "table" and mut.type == "bulk_shift",
                "build_planned_mutations: expected bulk_shift mutation")
            assert(type(mut.shift_frames) == "number",
                "build_planned_mutations: bulk_shift.shift_frames must be a number")
            if mut.shift_frames > 0 then
                table.insert(pre, mut)
            elseif mut.shift_frames < 0 then
                table.insert(post, mut)
            end
        end
        return pre, post
    end

    -- Sort clip-level mutations by starting frame, with deletes first
    -- and ordering direction chosen to avoid transient overlaps:
    -- positive shift → right-to-left (descending), negative shift →
    -- left-to-right (ascending). Positive-growth roll edits tie-break
    -- as descending too.
    local function sort_clip_mutations(clip_mutations, shift_frames, growth_frames)
        table.sort(clip_mutations, function(a, b)
            if a.type == "delete" and b.type ~= "delete" then return true end
            if b.type == "delete" and a.type ~= "delete" then return false end
            local t_a = mutation_sort_key(a)
            local t_b = mutation_sort_key(b)
            if shift_frames > 0 then return t_a > t_b end
            if shift_frames < 0 then return t_a < t_b end
            if growth_frames > 0 then return t_a > t_b end
            return t_a < t_b
        end)
    end

    local function build_planned_mutations(ctx)
        local shift_frames = ctx.downstream_shift_frames or 0
        local growth_frames = ctx.clamped_delta_frames or 0

        local gap_mutations, clip_mutations = partition_modified_clips(ctx)
        local pre_bulk_shifts, post_bulk_shifts = partition_bulk_shifts(ctx)
        sort_clip_mutations(clip_mutations, shift_frames, growth_frames)

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
        for _, mut in ipairs(gap_mutations) do
            table.insert(ctx.planned_mutations, mut)
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

    -- Persist the undo-relevant parameters to the command: original
    -- states (media clips only — gaps are in-memory), bulk_shift list,
    -- and the executed mutation order so the undoer can hydrate a full
    -- mutation list without us writing thousands of entries verbatim.
    local function persist_undo_parameters(ctx)
        local persisted_states = {}
        for id, state in pairs(ctx.original_states_map) do
            -- V13: gaps are in-memory only — recomputed by timeline_state on
            -- undo. Excluded here so revert_mutations doesn't try to restore
            -- a gap row (which has no source_in/source_out).
            if not state.is_gap then
                persisted_states[id] = state
            end
        end
        ctx.command:set_parameter("original_states", persisted_states)

        if ctx.bulk_shift_mutations and #ctx.bulk_shift_mutations > 0 then
            ctx.command:set_parameter("bulk_shifts", ctx.bulk_shift_mutations)
        else
            ctx.command:set_parameter("bulk_shifts", nil)
        end

        local order = {}
        for _, mut in ipairs(ctx.planned_mutations) do
            if type(mut) == "table" and mut.type and mut.clip_id and mut.type ~= "gap_preview" then
                -- Skip gap-clip mutations: gaps are recomputed by
                -- timeline_state on undo, so the persisted order must not
                -- name gap ids (matches persist_undo_parameters' filter).
                local cap = ctx.original_states_map[mut.clip_id]
                if not (cap and cap.is_gap) then
                    table.insert(order, {type = mut.type, clip_id = mut.clip_id})
                end
            end
        end
        ctx.command:set_parameter("executed_mutation_order", order)
        ctx.command:set_parameter("executed_mutations", nil)
    end

    -- Walk ctx.planned_mutations and emit the incremental UI-sync
    -- payloads that CommandManager forwards to timeline_state so the
    -- view can update without a full reload.
    local function emit_timeline_mutations(ctx, seq_id)
        for _, mut in ipairs(ctx.planned_mutations) do
            if mut.type == "update" then
                command_helper.add_update_mutation(ctx.command, seq_id, {
                    clip_id = mut.clip_id,
                    track_id = mut.track_id,
                    start_value = mut.timeline_start_frame,
                    duration_value = mut.duration_frames,
                    source_in_value = mut.source_in_frame,
                    source_out_value = mut.source_out_frame,
                    enabled = (mut.enabled == 1) or (mut.enabled == true),
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
                    shift_frames = mut.shift_frames,
                    start_frame = mut.start_frame,
                })
            end
        end
    end

    -- Return the set of edge keys to render red in the dry-run preview.
    -- Includes edges that hit their per-edge limit, forced blockers, and
    -- the global min/max edge key sets — minus implicit gap injections
    -- whose hit was merely "fully consumed" rather than a genuine block.
    local function collect_clamped_edge_keys(ctx)
        local clamped_edges = {}
        local final_delta = ctx.clamped_delta_frames

        local implicit_edge_keys = {}
        if ctx.clamp_direction == 0 then
            for _, ei in ipairs(ctx.edge_infos) do
                if ei.is_implicit_injection then
                    implicit_edge_keys[build_edge_key(ei)] = true
                end
            end
        end

        for edge_key, limits in pairs(ctx.per_edge_constraints) do
            if not implicit_edge_keys[edge_key] then
                local min_hit = (limits.min ~= -math.huge and final_delta == limits.min)
                local max_hit = (limits.max ~= math.huge and final_delta == limits.max)
                if min_hit or max_hit then
                    if key_matches_clamp_sources(ctx, edge_key, edge_key) then
                        clamped_edges[edge_key] = true
                    end
                end
            end
        end

        for key in pairs(ctx.forced_clamped_edges) do
            if ctx.restored_blocker_keys[key] or not implicit_edge_keys[key] then
                clamped_edges[key] = true
            end
        end

        local function merge_edge_keys(source)
            if not source then return end
            for key in pairs(source) do
                clamped_edges[key] = true
            end
        end
        if ctx.global_min_frames ~= -math.huge and final_delta == ctx.global_min_frames then
            merge_edge_keys(ctx.global_min_edge_keys)
        end
        if ctx.global_max_frames ~= math.huge and final_delta == ctx.global_max_frames then
            merge_edge_keys(ctx.global_max_edge_keys)
        end
        return clamped_edges
    end

    -- Build an accumulator that dedups preview edge entries by key.
    -- If the same edge is added twice, later calls can only
    -- upgrade the `is_limiter` flag from false to true.
    local function make_edge_preview_accumulator()
        local edges = {}
        local by_key = {}
        local function upsert(entry)
            if not entry or not entry.edge_key then return end
            local existing = by_key[entry.edge_key]
            if existing then
                if entry.is_limiter then existing.is_limiter = true end
                return
            end
            by_key[entry.edge_key] = entry
            table.insert(edges, entry)
        end
        return edges, by_key, upsert
    end

    -- Emit a preview entry for every edge the caller selected,
    -- including the implicit gap edges inject_implicit_gap_edges
    -- added for multitrack propagation.
    local function preview_entries_for_selected_edges(ctx, upsert, clamped_edges)
        for _, edge_info in ipairs(ctx.edge_infos) do
            local raw_edge_type = edge_info.edge_type
            local anchor_clip_id = edge_info.original_clip_id or edge_info.clip_id
            if anchor_clip_id and raw_edge_type then
                local edge_key = string.format("%s:%s",
                    tostring(anchor_clip_id), tostring(raw_edge_type))
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
                    applied_delta_frames = applied or 0,
                })
            end
        end
    end

    -- Find a clip id to anchor a preview edge on an unselected track
    -- at the ripple boundary: prefer a gap clip that contains the
    -- boundary frame, otherwise fall back to the nearest media clip.
    local function anchor_clip_id_for_propagated_track(track_clips, boundary_frames, raw_edge_type)
        for _, c in ipairs(track_clips) do
            if c.is_gap
                and c.timeline_start <= boundary_frames
                and (c.timeline_start + c.duration) >= boundary_frames then
                return c.id
            end
        end
        return pick_gap_anchor_clip_id(track_clips, boundary_frames, raw_edge_type)
    end

    -- Emit a preview entry per unselected affected track (tracks that
    -- ripple via propagation rather than a direct edge selection). The
    -- entry anchors to the gap clip at the ripple boundary on that
    -- track so the UI can render the implied edge correctly.
    local function preview_entries_for_propagated_tracks(ctx, upsert, clamped_edges, lead_normalized, global_sign)
        local boundary_default = ctx.earliest_ripple_time or 0
        for track_id in pairs(ctx.affected_tracks) do
            if not ctx.selected_tracks[track_id] then
                local shift_frames = ctx.track_shift_amounts[track_id]
                    or ctx.downstream_shift_frames or 0
                if shift_frames ~= 0 then
                    local desired = infer_implied_normalized_edge(
                        lead_normalized, signum(shift_frames), global_sign)
                    local boundary_frames = ctx.track_ripple_start_frames[track_id] or boundary_default
                    local track_clips = ctx.track_clip_map[track_id] or {}
                    local raw_edge_type = desired or "in"
                    local anchor_clip_id = anchor_clip_id_for_propagated_track(
                        track_clips, boundary_frames, raw_edge_type)
                    if anchor_clip_id then
                        local edge_key = string.format("%s:%s",
                            tostring(anchor_clip_id), tostring(raw_edge_type))
                        upsert({
                            edge_key = edge_key,
                            clip_id = anchor_clip_id,
                            track_id = track_id,
                            raw_edge_type = raw_edge_type,
                            normalized_edge = desired or "in",
                            is_selected = false,
                            is_implied = true,
                            is_limiter = clamped_edges[edge_key] == true,
                            applied_delta_frames = shift_frames,
                        })
                    end
                end
            end
        end
    end

    -- Emit preview entries for any limiter edge key that didn't already
    -- get one via the selected/propagated loops. This catches blocker
    -- edges recorded via forced_clamped_edges on clips the pipeline
    -- didn't otherwise visit.
    local function preview_entries_for_leftover_limiters(ctx, upsert, clamped_edges, edges_by_key)
        for key in pairs(clamped_edges) do
            if not edges_by_key[key] and type(key) == "string" then
                local clip_id, edge_type = key:match("^(.*):([^:]+)$")
                if clip_id and edge_type and clip_id ~= "" then
                    local clip = ctx.clip_lookup[clip_id]
                    local track_id = (clip and clip.track_id) or ctx.clip_track_lookup[clip_id]
                    local shift_frames = (track_id and ctx.track_shift_amounts[track_id]) or 0
                    upsert({
                        edge_key = key,
                        clip_id = clip_id,
                        track_id = track_id,
                        raw_edge_type = edge_type,
                        normalized_edge = edge_utils.to_bracket(edge_type),
                        is_selected = false,
                        is_implied = true,
                        is_limiter = true,
                        applied_delta_frames = shift_frames,
                    })
                end
            end
        end
    end

    -- Build the full edge_preview payload the dry-run executor returns.
    -- This is the structure the UI renders to show which edges moved,
    -- which are implied, and which were clamped in red.
    local function build_edge_preview_payload(ctx, clamped_edges)
        local edges, by_key, upsert = make_edge_preview_accumulator()
        local lead_normalized = nil
        if ctx.lead_edge_entry then
            lead_normalized = ctx.lead_edge_entry.normalized_edge
                or edge_utils.to_bracket(ctx.lead_edge_entry.edge_type)
        end
        local global_sign = signum(ctx.clamped_delta_frames or 0)

        preview_entries_for_selected_edges(ctx, upsert, clamped_edges)
        preview_entries_for_propagated_tracks(ctx, upsert, clamped_edges, lead_normalized, global_sign)
        preview_entries_for_leftover_limiters(ctx, upsert, clamped_edges, by_key)

        return {
            requested_delta_frames = ctx.delta_frames or 0,
            clamped_delta_frames = ctx.clamped_delta_frames or 0,
            edges = edges,
            limiter_edge_keys = clamped_edges,
        }
    end

    local function finalize_execution(ctx)
        persist_undo_parameters(ctx)

        if ctx.dry_run then
            local clamped_edges = collect_clamped_edge_keys(ctx)
            local clamped_ms = frame_utils.frames_to_ms(
                ctx.clamped_delta_frames, ctx.seq_fps_num, ctx.seq_fps_den)
            return true, {
                planned_mutations = ctx.planned_mutations,
                affected_clips = ctx.preview_affected_clips,
                shifted_clips = ctx.preview_shifted_clips,
                shift_blocks = ctx.shift_blocks,
                clamped_delta_ms = clamped_ms,
                clamped_delta_frames = ctx.clamped_delta_frames,
                materialized_gaps = ctx.materialized_gap_ids,
                clamped_edges = clamped_edges,
                edge_preview = build_edge_preview_payload(ctx, clamped_edges),
            }
        end

        local ok_apply, apply_err = command_helper.apply_mutations(db, ctx.planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end

        assert(ctx.sequence_id and ctx.sequence_id ~= "",
            "BatchRippleEdit: missing sequence_id for timeline mutations")
        emit_timeline_mutations(ctx, ctx.sequence_id)

        log.event("Batch ripple: processed %d edges, downstream shift %d frames",
            #ctx.edge_infos, ctx.downstream_shift_frames or 0)

        return true
    end

    command_executors["BatchRippleEdit"] = function(command)
        local ctx = batch_context.create(command)

        -- Restore shift-bound blocker keys from a prior retry so the UI
        -- can highlight the blocking edges red even after delta re-clamp.
        -- These are genuine blockers — must not be filtered by implicit edge checks.
        ctx.restored_blocker_keys = {}
        local saved_blockers = command:get_parameter("__shift_blocker_keys")
        if type(saved_blockers) == "table" then
            for _, key in ipairs(saved_blockers) do
                ctx.forced_clamped_edges[key] = true
                ctx.restored_blocker_keys[key] = true
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
            for ei, edge in ipairs(ctx.edge_infos) do
                log.event("BatchRippleEdit edge[%d]: clip=%s edge=%s trim=%s track=%s",
                    ei, tostring(edge.clip_id):sub(1, 12),
                    tostring(edge.edge_type), tostring(edge.trim_type),
                    tostring(edge.track_id):sub(1, 12))
            end
            log.event("BatchRippleEdit delta=%s frames", tostring(ctx.delta_frames))
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

        -- Gap-only edits produce no DB mutations. Nothing to undo.
        local originals = command:get_parameter("original_states")
        local mutations = command:get_parameter("executed_mutations")
        local order = command:get_parameter("executed_mutation_order")
        local bulk = command:get_parameter("bulk_shifts")
        if (not mutations or next(mutations) == nil)
            and (not originals or next(originals) == nil)
            and (not order or #order == 0)
            and (not bulk or #bulk == 0) then
            return { success = true }
        end

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
    if raw_edge_type == "out" then
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
    if ctx.neighbor_bounds_cache[clip_id] then
        return ctx.neighbor_bounds_cache[clip_id]
    end

    local original = ctx.original_states_map[clip_id]
        or ctx.base_clips[clip_id]
        or ctx.clip_lookup[clip_id]
    assert(original, string.format(
        "ensure_neighbor_bounds: missing original state for clip %s", tostring(clip_id)))
    assert(original.track_id, string.format(
        "ensure_neighbor_bounds: clip %s missing track_id", tostring(clip_id)))

    local prev_end_frames, next_start_frames, prev_id, next_id =
        compute_neighbor_bounds(ctx.all_clips, original, clip_id)
    ctx.neighbor_bounds_cache[clip_id] = {
        prev_end_frames = prev_end_frames,
        next_start_frames = next_start_frames,
        prev_id = prev_id,
        next_id = next_id,
    }
    return ctx.neighbor_bounds_cache[clip_id]
end

should_negate_edge = function(ctx, edge_key)
    return ctx.edge_will_negate[edge_key]
end

return M
