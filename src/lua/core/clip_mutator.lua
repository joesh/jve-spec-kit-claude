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
-- Size: ~867 LOC
-- Volatility: unknown
--
-- @file clip_mutator.lua
local ClipMutator = {}
local uuid = require("uuid")
local logger = require("core.logger")
local krono_ok, krono = pcall(require, "core.krono")

    local function clone_state(row)
	    return {
	        id = row.id,
	        project_id = row.project_id,
	        clip_kind = row.clip_kind,
	        name = row.name,
	        track_id = row.track_id,
	        media_id = row.media_id,
            master_clip_id = row.master_clip_id,
            parent_clip_id = row.parent_clip_id,
            owner_sequence_id = row.owner_sequence_id,
	        created_at = row.created_at,
	        modified_at = row.modified_at,
	        start_value = row.start_value,
	        duration = row.duration,
	        source_in = row.source_in,
	        source_out = row.source_out,
	        fps_numerator = row.fps_numerator,
	        fps_denominator = row.fps_denominator,
	        enabled = row.enabled,
            offline = row.offline
	    }
	end

-- Assert value is integer frames
local function assert_int(val, label)
    assert(type(val) == "number", "clip_mutator: " .. (label or "value") .. " must be integer")
    return val
end

-- Extract frames from value (all coords are now integers; this validates and returns)
local function get_frames(val)
    if val == nil then return nil end
    assert(type(val) == "number", "clip_mutator.get_frames: expected integer, got " .. type(val))
    return val
end

-- Assert fps metadata exists (for validation only)
local function assert_fps(num, den, label)
    assert(num and num > 0, "clip_mutator: missing " .. (label or "fps") .. " numerator")
    assert(den and den > 0, "clip_mutator: missing " .. (label or "fps") .. " denominator")
end

-- Helper to get fps metadata from row (for passing through to new clips)
local function get_row_fps(row)
    local num = row.fps_numerator or (row.rate and row.rate.fps_numerator)
    local den = row.fps_denominator or (row.rate and row.rate.fps_denominator)
    assert_fps(num, den, "clip fps")
    return num, den
end

-- Assert value is integer frames (fail-fast, no backward compat)
local function ensure_integer(value, label)
    if type(value) ~= "number" then
        error("clip_mutator: " .. tostring(label or "value") .. " must be integer (got " .. type(value) .. ")", 3)
    end
    return value
end

local function require_source_out(row, context)
    assert(row, "clip_mutator: missing row (" .. tostring(context or "unknown") .. ")")
    local source_out = row.source_out
    assert(type(source_out) == "number", "clip_mutator: source_out must be integer (" .. tostring(context or "unknown") .. ")")
    return source_out
end

local function get_source_in(row)
    local source_in = row.source_in
    assert(type(source_in) == "number", "clip_mutator: source_in must be integer")
    return source_in
end

local function plan_update(row, original)
    return {
        type = "update",
        clip_id = row.id,
        track_id = row.track_id,
        timeline_start_frame = get_frames(row.timeline_start or row.start_value),
        duration_frames = get_frames(row.duration),
        source_in_frame = get_frames(row.source_in),
        source_out_frame = get_frames(row.source_out),
        enabled = row.enabled and 1 or 0,
        previous = original
    }
end

local function plan_delete(row)
    return {
        type = "delete",
        clip_id = row.id,
        previous = row
    }
end

local function plan_insert(row)
    -- Prefer explicit fps fields, but fall back to rate table used by Clip objects
    local fps_num = row.fps_numerator or (row.rate and row.rate.fps_numerator)
    local fps_den = row.fps_denominator or (row.rate and row.rate.fps_denominator)
    assert_fps(fps_num, fps_den, "clip fps")
    assert(row.timeline_start or row.start_value, "clip_mutator: insert mutation missing timeline_start")
    assert(row.duration, "clip_mutator: insert mutation missing duration")
    assert(row.source_in, "clip_mutator: insert mutation missing source_in")
    assert(row.source_out, "clip_mutator: insert mutation missing source_out")
    return {
        type = "insert",
        clip_id = row.id,
        project_id = row.project_id,
        clip_kind = assert(row.clip_kind, "clip_mutator.plan_insert: missing clip_kind for clip " .. tostring(row.id)),
        name = row.name or "",
        track_id = row.track_id,
        media_id = row.media_id,
        master_clip_id = row.master_clip_id,
        parent_clip_id = row.parent_clip_id,
        owner_sequence_id = row.owner_sequence_id,
        timeline_start_frame = get_frames(row.timeline_start or row.start_value),
        duration_frames = get_frames(row.duration),
        source_in_frame = get_frames(row.source_in),
        source_out_frame = get_frames(row.source_out),
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        enabled = row.enabled and 1 or 0,
        offline = row.offline and 1 or 0,
        created_at = assert(row.created_at, "clip_mutator: insert mutation missing created_at for clip " .. tostring(row.id)),
        modified_at = assert(row.modified_at, "clip_mutator: insert mutation missing modified_at for clip " .. tostring(row.id))
    }
end

-- Resolve occlusions for a clip about to occupy [start_value, end_time).
-- Params:
--   track_id, start_value, duration
--   exclude_clip_id: clip id to ignore while checking overlaps (e.g., the clip being updated)
local function load_track_clips(db, track_id)
    local stmt = db:prepare([[
        SELECT c.id, c.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
               c.master_clip_id, c.parent_clip_id, c.owner_sequence_id,
               c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
               c.fps_numerator, c.fps_denominator,
               s.fps_numerator, s.fps_denominator,
               c.enabled, c.offline, c.created_at, c.modified_at
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences s ON t.sequence_id = s.id
        WHERE c.track_id = ?
        ORDER BY c.timeline_start_frame
    ]])
    if not stmt then
        return nil, "Failed to prepare track clip query"
    end
    stmt:bind_value(1, track_id)

    local results = {}
    if not stmt:exec() then
        local err = stmt:last_error()
        stmt:finalize()
        return nil, err
    end

    while stmt:next() do
        local clip_num = stmt:value(13)
        local clip_den = stmt:value(14)
        local seq_num = stmt:value(15)
        local seq_den = stmt:value(16)
        assert_fps(clip_num, clip_den, "clip fps")
        assert_fps(seq_num, seq_den, "sequence fps")
        table.insert(results, {
            id = stmt:value(0),
            project_id = stmt:value(1),
            clip_kind = stmt:value(2),
            name = stmt:value(3),
            track_id = stmt:value(4),
            media_id = stmt:value(5),
            master_clip_id = stmt:value(6),
            parent_clip_id = stmt:value(7),
            owner_sequence_id = stmt:value(8),
            created_at = stmt:value(19),
            modified_at = stmt:value(20),
            -- Integer frame coordinates
            timeline_start = stmt:value(9),
            start_value = stmt:value(9),  -- Legacy compat
            duration = stmt:value(10),
            source_in = stmt:value(11),
            source_out = stmt:value(12),
            -- Rate metadata for source coordinate conversions
            rate = { fps_numerator = clip_num, fps_denominator = clip_den },
            fps_numerator = clip_num,
            fps_denominator = clip_den,
            -- Sequence rate for reference
            seq_fps_numerator = seq_num,
            seq_fps_denominator = seq_den,
            enabled = stmt:value(17) == 1 or stmt:value(17) == true,
            offline = stmt:value(18) == 1 or stmt:value(18) == true
        })
    end
    stmt:finalize()
    return results
end

local function normalize_pending_lookup(pending_clips, exclude_id)
    local lookup = {}
    if type(pending_clips) ~= "table" then
        return lookup
    end

    local function ingest(clip_id, pending)
        if not clip_id or clip_id == exclude_id then
            return
        end
        if pending == false or pending.deleted then
            return
        end
        lookup[clip_id] = {
            start_value = pending.timeline_start or pending.start_value, -- Accept both
            duration = pending.duration,
            tolerance = pending.tolerance,
            _seen = false,
            _virtual = false
        }
    end

    for key, value in pairs(pending_clips) do
        if type(key) == "string" and type(value) == "table" then
            ingest(key, value)
        elseif type(value) == "table" and type(value.id) == "string" then
            ingest(value.id, value)
            if lookup[value.id] then
                lookup[value.id]._virtual = value.virtual == true
            end
        end
    end

    return lookup
end

local function iter_overlaps(clip_list, start_value, end_time)
    local index = 1
    local count = #clip_list

    return function()
        while index <= count do
            local item = clip_list[index]
            index = index + 1
            local clip_start = item.timeline_start or item.start_value
            assert(type(clip_start) == "number", "clip_mutator: overlap check missing clip_start")
            local clip_end = clip_start + (item.duration or 0)

            -- Integer comparison
            if clip_end > start_value and clip_start < end_time then
                return item
            end
            if clip_start >= end_time then
                break
            end
        end
        return nil
    end
end

function ClipMutator.resolve_occlusions(db, params)
    if not params then return true end
    local track_id = params.track_id
    if not track_id then return true end
    local start_value = params.timeline_start or params.start_value
    assert(start_value ~= nil, "clip_mutator.resolve_occlusions: timeline_start/start_value is required")
    local duration = assert(params.duration, "clip_mutator.resolve_occlusions: duration is required")

    -- Ensure integer frame coordinates
    start_value = ensure_integer(start_value, "start_value")
    duration = ensure_integer(duration, "duration")

    local end_time = start_value + duration
    local exclude_id = params.exclude_clip_id

    local krono_enabled = krono_ok and krono and krono.is_enabled and krono.is_enabled()
    local krono_start = krono_enabled and krono.now and krono.now() or nil
    local track_clips, load_err = nil, nil
    local window_cache = params.pending_clips and params.pending_clips.__window_cache
    if window_cache and window_cache[track_id] then
        track_clips = window_cache[track_id]
    end
    if not track_clips then
        track_clips, load_err = load_track_clips(db, track_id)
        if not track_clips then
            return false, load_err
        end
    end

    local pending_lookup = normalize_pending_lookup(params.pending_clips, exclude_id)
    local overlaps = iter_overlaps(track_clips, start_value, end_time)

    local actions = {}

    local krono_prepare_done = krono_enabled and krono.now and krono.now() or nil
    while true do
        local row = overlaps()
        if not row then
            break
        end

        if row.id == exclude_id then
            goto continue_loop
        end

        local pending_state = pending_lookup[row.id]
        if pending_state then
            pending_state._seen = true
            goto continue_loop
        end

        local clip_start = row.timeline_start or row.start_value
        assert(type(clip_start) == "number", "clip_mutator.resolve_occlusions: missing clip_start")

        local clip_duration = row.duration
        assert(type(clip_duration) == "number", "clip_mutator.resolve_occlusions: missing clip duration")

        local clip_end = clip_start + clip_duration
        local overlap_start = math.max(clip_start, start_value)
        local overlap_end = math.min(clip_end, end_time)

        if overlap_end <= overlap_start then
            goto continue_loop
        end

        local original = clone_state(row)

        -- Fully covered → delete
        if overlap_start <= clip_start and overlap_end >= clip_end then
            table.insert(actions, plan_delete(original))
            goto continue_loop
        end

        -- Overlap on tail (trim right side): keep start, shorten duration to end at start_value.
        if clip_start < start_value and clip_end <= end_time then
            local new_duration = start_value - clip_start
            if new_duration < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            row.duration = new_duration
            row.source_out = get_source_in(row) + new_duration

            table.insert(actions, plan_update(row, original))
            goto continue_loop
        end

        -- Overlap on head (trim left side): shift start to end_time, shorten duration from the front.
        if clip_start >= start_value and clip_end > end_time then
            local trim_amount = end_time - clip_start
            local new_duration = clip_end - end_time
            if new_duration < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            row.timeline_start = end_time
            row.duration = new_duration
            row.source_in = get_source_in(row) + trim_amount
            row.source_out = require_source_out(original, "resolve_occlusions/head_trim")

            table.insert(actions, plan_update(row, original))
            goto continue_loop
        end

        -- Straddles new clip → split existing clip into left and right parts.
        if clip_start < start_value and clip_end > end_time then
            local row_fps_num, row_fps_den = get_row_fps(row)
            local left_duration = start_value - clip_start
            local right_duration = clip_end - end_time
            if left_duration < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            row.duration = left_duration
            row.source_out = get_source_in(row) + left_duration
            table.insert(actions, plan_update(row, original))

            if right_duration > 0 then
                local right_shift = end_time - clip_start
                local right_clip = {
                    id = uuid.generate(),
                    project_id = original.project_id,
                    clip_kind = original.clip_kind,
                    name = original.name,
                    track_id = original.track_id,
                    media_id = original.media_id,
                    timeline_start = end_time,
                    duration = right_duration,
                    source_in = get_source_in(original) + right_shift,
                    source_out = require_source_out(original, "resolve_occlusions/straddle_split"),
                    fps_numerator = row_fps_num,
                    fps_denominator = row_fps_den,
                    enabled = original.enabled,
                    created_at = os.time(),
                    modified_at = os.time()
                }
                table.insert(actions, plan_insert(right_clip))
            end
            goto continue_loop
        end

        ::continue_loop::
    end

    for clip_id, pending_state in pairs(pending_lookup) do
        if not pending_state._seen and not pending_state._virtual then
            logger.warn("clip_mutator", string.format(
                "resolve_occlusions: pending clip %s was not found on track %s",
                tostring(clip_id), tostring(track_id)))
        end
    end

    local krono_end = krono_enabled and krono.now and krono.now() or nil
    if krono_enabled and krono_start and krono_prepare_done and krono_end then
        local total = krono_end - krono_start
        logger.debug("clip_mutator", string.format("resolve[%s]: %.2fms (load=%.2fms body=%.2fms)",
            tostring(track_id or "unknown"), total,
            krono_prepare_done - krono_start, krono_end - krono_prepare_done))
    end

    return true, nil, actions
end

ClipMutator.plan_update = plan_update
ClipMutator.plan_delete = plan_delete
ClipMutator.plan_insert = plan_insert

function ClipMutator.resolve_ripple(db, params)
    if not params then return true end
    local track_id = params.track_id
    local insert_time = params.insert_time or params.timeline_start
    local shift_amount = params.shift_amount or params.duration
    if not track_id then return true end
    if not insert_time then return true end
    assert(shift_amount, "clip_mutator.resolve_ripple: shift_amount/duration is required")

    -- Ensure integer frame coordinates
    insert_time = ensure_integer(insert_time, "insert_time")
    shift_amount = ensure_integer(shift_amount, "shift_amount")
    
    local track_clips, err = load_track_clips(db, track_id)
    if not track_clips then return false, err end

    local actions = {}
    
    -- Iterate and shift/split
    -- Note: clips are ordered by start time
    for _, row in ipairs(track_clips) do
        local original = clone_state(row)
        local clip_start = row.timeline_start or row.start_value
        assert(type(clip_start) == "number", "clip_mutator.resolve_ripple: missing clip_start")
        local clip_end = clip_start + row.duration

        if clip_start >= insert_time then
            -- Fully after: Shift
            row.timeline_start = clip_start + shift_amount
            table.insert(actions, plan_update(row, original))
            
        elseif clip_start < insert_time and clip_end > insert_time then
            -- Straddles: Split
            -- Left Part: Ends at insert_time
            local row_fps_num, row_fps_den = get_row_fps(row)
            local left_dur = insert_time - clip_start

            row.duration = left_dur
            row.source_out = get_source_in(row) + left_dur

            table.insert(actions, plan_update(row, original))

            -- Right Part: Starts at insert_time + shift_amount
            local right_start = insert_time + shift_amount
            local right_dur = clip_end - insert_time
            local right_src_in = get_source_in(original) + left_dur

            local right_clip = {
                id = uuid.generate(),
                project_id = row.project_id,
                clip_kind = row.clip_kind,
                name = row.name .. " (2)",
                track_id = row.track_id,
                media_id = row.media_id,
                master_clip_id = original.master_clip_id,
                parent_clip_id = original.parent_clip_id,
                owner_sequence_id = original.owner_sequence_id,
                timeline_start = right_start,
                duration = right_dur,
                source_in = right_src_in,
                source_out = require_source_out(original, "resolve_ripple"),
                fps_numerator = row_fps_num,
                fps_denominator = row_fps_den,
                enabled = row.enabled,
                offline = original.offline,
                created_at = os.time(),
                modified_at = os.time()
            }
            table.insert(actions, plan_insert(right_clip))
        end
    end

    -- For positive shifts (inserting), reverse the update order so rightmost clips
    -- move first, preventing overlap errors when cascading updates
    if shift_amount > 0 then
        local updates = {}
        local non_updates = {}
        for _, action in ipairs(actions) do
            if action.type == "update" then
                table.insert(updates, 1, action)  -- prepend to reverse order
            else
                table.insert(non_updates, action)
            end
        end
        -- Put reversed updates first, then inserts
        actions = {}
        for _, u in ipairs(updates) do
            table.insert(actions, u)
        end
        for _, n in ipairs(non_updates) do
            table.insert(actions, n)
        end
    end

    return true, nil, actions
end

local function get_sequence_fps(db, sequence_id)
    local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    assert(stmt, "clip_mutator: failed to prepare sequence fps query")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next(), "clip_mutator: sequence not found: " .. tostring(sequence_id))
    local num, den = stmt:value(0), stmt:value(1)
    stmt:finalize()
    assert_fps(num, den, "sequence fps")
    return num, den
end

local function load_sequence_tracks(db, sequence_id)
    local stmt = db:prepare([[
        SELECT id, track_index, track_type
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type ASC, track_index ASC
    ]])
    assert(stmt, "clip_mutator.plan_duplicate_block: failed to prepare tracks query")

    stmt:bind_value(1, sequence_id)
    local ok = stmt:exec()
    assert(ok, "clip_mutator.plan_duplicate_block: failed to execute tracks query")

    local tracks = {}
    while stmt:next() do
        table.insert(tracks, {
            id = stmt:value(0),
            track_index = stmt:value(1),
            track_type = stmt:value(2),
        })
    end
    stmt:finalize()
    return tracks
end

local function build_track_maps(tracks)
    local by_id = {}
    local by_type_index = {}
    for _, track in ipairs(tracks or {}) do
        if track and track.id and track.track_type and track.track_index then
            by_id[track.id] = track
            by_type_index[track.track_type] = by_type_index[track.track_type] or {}
            by_type_index[track.track_type][track.track_index] = track
        end
    end
    return by_id, by_type_index
end

local function merge_intervals(intervals)
    if type(intervals) ~= "table" or #intervals == 0 then
        return {}
    end

    table.sort(intervals, function(a, b)
        return a.start < b.start
    end)

    local merged = {}
    local current = {start = intervals[1].start, ["end"] = intervals[1]["end"]}
    for i = 2, #intervals do
        local next_it = intervals[i]
        if next_it.start <= current["end"] then
            if next_it["end"] > current["end"] then
                current["end"] = next_it["end"]
            end
        else
            table.insert(merged, current)
            current = {start = next_it.start, ["end"] = next_it["end"]}
        end
    end
    table.insert(merged, current)
    return merged
end

local function validate_no_overlaps_per_track(track_intervals)
    for track_id, intervals in pairs(track_intervals or {}) do
        table.sort(intervals, function(a, b)
            return a.start < b.start
        end)
        local prev = nil
        for _, interval in ipairs(intervals) do
            if prev and interval.start < prev["end"] then
                return false, string.format(
                    "clip_mutator.plan_duplicate_block: pasted clips overlap on track %s (%s < %s)",
                    tostring(track_id),
                    tostring(interval.start),
                    tostring(prev["end"])
                )
            end
            prev = interval
        end
    end
    return true
end

local function merge_integer_ranges(ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return {}
    end

    table.sort(ranges, function(a, b)
        return a.start < b.start
    end)

    local merged = {}
    local current = {start = ranges[1].start, ["end"] = ranges[1]["end"]}
    for i = 2, #ranges do
        local next_r = ranges[i]
        if next_r.start <= current["end"] + 1 then
            if next_r["end"] > current["end"] then
                current["end"] = next_r["end"]
            end
        else
            table.insert(merged, current)
            current = {start = next_r.start, ["end"] = next_r["end"]}
        end
    end
    table.insert(merged, current)
    return merged
end

local function clamp_delta_to_avoid_source_overlaps(requested_delta_frames, directional_sign, copy_specs_by_track, source_intervals_by_track)
    assert(type(requested_delta_frames) == "number", "clip_mutator.plan_duplicate_block: requested_delta_frames must be number")
    assert(directional_sign == 1 or directional_sign == -1, "clip_mutator.plan_duplicate_block: directional_sign must be ±1")

    local forbidden = {}

    for target_track_id, specs in pairs(copy_specs_by_track or {}) do
        local originals = source_intervals_by_track[target_track_id]
        if type(originals) ~= "table" or #originals == 0 then
            goto continue_track
        end

        for _, spec in ipairs(specs) do
            local s_start = spec.source_start_frames
            local s_end = spec.source_end_frames
            assert(type(s_start) == "number" and type(s_end) == "number" and s_end >= s_start,
                "clip_mutator.plan_duplicate_block: invalid copy spec interval")

            for _, original in ipairs(originals) do
                local o_start = original.start_frames
                local o_end = original.end_frames
                assert(type(o_start) == "number" and type(o_end) == "number" and o_end >= o_start,
                    "clip_mutator.plan_duplicate_block: invalid source interval")

                local delta_before = o_start - s_end
                local delta_after = o_end - s_start

                local range_start = delta_before + 1
                local range_end = delta_after - 1
                if range_start <= range_end then
                    table.insert(forbidden, {start = range_start, ["end"] = range_end})
                end
            end
        end

        ::continue_track::
    end

    if #forbidden == 0 then
        return requested_delta_frames
    end

    local merged = merge_integer_ranges(forbidden)

    if directional_sign > 0 then
        local d = requested_delta_frames
        for _, r in ipairs(merged) do
            if d < r.start then
                break
            end
            if d >= r.start and d <= r["end"] then
                d = r["end"] + 1
            end
        end
        return d
    end

    local d = requested_delta_frames
    for i = #merged, 1, -1 do
        local r = merged[i]
        if d > r["end"] then
            break
        end
        if d >= r.start and d <= r["end"] then
            d = r.start - 1
        end
    end
    return d
end

local function load_clip_for_duplicate_plan(db, clip_id, sequence_id, seq_fps_num, seq_fps_den)
    local stmt = db:prepare([[
        SELECT c.id, c.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
               c.master_clip_id, c.parent_clip_id, c.owner_sequence_id,
               c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
               c.fps_numerator, c.fps_denominator,
               c.enabled, c.offline, c.created_at, c.modified_at,
               s.id, s.fps_numerator, s.fps_denominator
        FROM clips c
        LEFT JOIN tracks t ON c.track_id = t.id
        LEFT JOIN sequences s ON t.sequence_id = s.id
        WHERE c.id = ?
    ]])
    assert(stmt, "clip_mutator.plan_duplicate_block: failed to prepare clip query")
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    assert(ok, "clip_mutator.plan_duplicate_block: failed to execute clip query")
    if not stmt:next() then
        stmt:finalize()
        return nil
    end

    local owning_sequence_id = stmt:value(19)
    assert(owning_sequence_id, "clip_mutator.plan_duplicate_block: clip missing owning sequence via track_id (clip_id=" .. tostring(clip_id) .. ")")
    assert(owning_sequence_id == sequence_id,
        string.format("clip_mutator.plan_duplicate_block: clip %s belongs to sequence %s, not %s",
            tostring(clip_id), tostring(owning_sequence_id), tostring(sequence_id)))

    local owning_fps_num = stmt:value(20)
    local owning_fps_den = stmt:value(21)
    assert(owning_fps_num == seq_fps_num and owning_fps_den == seq_fps_den,
        string.format("clip_mutator.plan_duplicate_block: clip %s owning sequence rate mismatch (%s/%s vs %s/%s)",
            tostring(clip_id), tostring(owning_fps_num), tostring(owning_fps_den), tostring(seq_fps_num), tostring(seq_fps_den)))

    local clip_fps_num = stmt:value(13)
    local clip_fps_den = stmt:value(14)
    assert_fps(clip_fps_num, clip_fps_den, "clip fps")

    local clip = {
        id = stmt:value(0),
        project_id = stmt:value(1),
        clip_kind = stmt:value(2),
        name = stmt:value(3),
        track_id = stmt:value(4),
        media_id = stmt:value(5),
        master_clip_id = stmt:value(6),
        parent_clip_id = stmt:value(7),
        owner_sequence_id = stmt:value(8),
        -- Integer frame coordinates
        timeline_start = stmt:value(9),
        duration = stmt:value(10),
        source_in = stmt:value(11),
        source_out = stmt:value(12),
        -- Fps metadata (for storage/passthrough only)
        fps_numerator = clip_fps_num,
        fps_denominator = clip_fps_den,
        rate = {fps_numerator = clip_fps_num, fps_denominator = clip_fps_den},
        enabled = stmt:value(15) == 1 or stmt:value(15) == true,
        offline = stmt:value(16) == 1 or stmt:value(16) == true,
        created_at = stmt:value(17),
        modified_at = stmt:value(18),
    }
    stmt:finalize()
    return clip
end

function ClipMutator.plan_duplicate_block(db, params)
    assert(db, "clip_mutator.plan_duplicate_block: db is nil")
    assert(type(params) == "table", "clip_mutator.plan_duplicate_block: params table required")

    local sequence_id = params.sequence_id
    local clip_ids = params.clip_ids
    local target_track_id = params.target_track_id
    local anchor_clip_id = params.anchor_clip_id

    assert(sequence_id and sequence_id ~= "", "clip_mutator.plan_duplicate_block: missing sequence_id")
    assert(type(clip_ids) == "table" and #clip_ids > 0, "clip_mutator.plan_duplicate_block: missing clip_ids")
    assert(target_track_id and target_track_id ~= "", "clip_mutator.plan_duplicate_block: missing target_track_id")

    local seq_fps_num, seq_fps_den = get_sequence_fps(db, sequence_id)

    -- Delta must be integer frames
    local delta_frames = params.delta_frames or 0
    assert(type(delta_frames) == "number", "clip_mutator.plan_duplicate_block: delta_frames must be integer")

    local tracks = load_sequence_tracks(db, sequence_id)
    local tracks_by_id, tracks_by_type_index = build_track_maps(tracks)

    anchor_clip_id = anchor_clip_id or clip_ids[1]
    assert(anchor_clip_id and anchor_clip_id ~= "", "clip_mutator.plan_duplicate_block: missing anchor_clip_id")

    local anchor_clip = load_clip_for_duplicate_plan(db, anchor_clip_id, sequence_id, seq_fps_num, seq_fps_den)
    assert(anchor_clip, "clip_mutator.plan_duplicate_block: anchor clip not found: " .. tostring(anchor_clip_id))

    local anchor_track = anchor_clip.track_id and tracks_by_id[anchor_clip.track_id] or nil
    assert(anchor_track, "clip_mutator.plan_duplicate_block: anchor clip track not found in sequence: " .. tostring(anchor_clip.track_id))

    local target_track = tracks_by_id[target_track_id]
    assert(target_track, "clip_mutator.plan_duplicate_block: target track not found in sequence: " .. tostring(target_track_id))

    assert(target_track.track_type == anchor_track.track_type,
        string.format("clip_mutator.plan_duplicate_block: target track type mismatch (anchor=%s target=%s)",
            tostring(anchor_track.track_type), tostring(target_track.track_type)))

    local delta_track_index = target_track.track_index - anchor_track.track_index
    assert(type(delta_track_index) == "number", "clip_mutator.plan_duplicate_block: invalid delta_track_index")

    if delta_track_index == 0 and delta_frames == 0 then
        return true, nil, {planned_mutations = {}, new_clip_ids = {}}
    end

    local source_clips = {}
    local source_intervals_by_track = {}
    local copy_specs_by_track = {}

    local min_source_start_frames = nil
    for _, clip_id in ipairs(clip_ids) do
        local clip = load_clip_for_duplicate_plan(db, clip_id, sequence_id, seq_fps_num, seq_fps_den)
        if not clip then
            return false, "clip_mutator.plan_duplicate_block: source clip not found: " .. tostring(clip_id)
        end
        if clip.clip_kind ~= "timeline" then
            return false, "clip_mutator.plan_duplicate_block: can only duplicate timeline clips (clip_kind=" .. tostring(clip.clip_kind) .. ")"
        end

        table.insert(source_clips, clip)

        local start_frames = assert(type(clip.timeline_start) == "number", "clip_mutator.plan_duplicate_block: source clip timeline_start must be integer") and clip.timeline_start
        local dur_frames = assert(type(clip.duration) == "number", "clip_mutator.plan_duplicate_block: source clip duration must be integer") and clip.duration
        local end_frames = start_frames + dur_frames

        source_intervals_by_track[clip.track_id] = source_intervals_by_track[clip.track_id] or {}
        table.insert(source_intervals_by_track[clip.track_id], {start_frames = start_frames, end_frames = end_frames, clip_id = clip.id})

        if min_source_start_frames == nil or start_frames < min_source_start_frames then
            min_source_start_frames = start_frames
        end
    end

    local lower_bound = 0
    if min_source_start_frames ~= nil then
        lower_bound = -min_source_start_frames
    end

    local requested_delta_frames = delta_frames
    if requested_delta_frames < lower_bound then
        requested_delta_frames = lower_bound
    end

    for _, clip in ipairs(source_clips) do
        local source_track = clip.track_id and tracks_by_id[clip.track_id] or nil
        assert(source_track, "clip_mutator.plan_duplicate_block: source clip track not found in sequence: " .. tostring(clip.track_id))
        if source_track.track_type ~= anchor_track.track_type then
            goto continue_spec
        end

        local target_track_index = source_track.track_index + delta_track_index
        local mapped_track = tracks_by_type_index[source_track.track_type]
            and tracks_by_type_index[source_track.track_type][target_track_index]
            or nil
        if not mapped_track then
            goto continue_spec
        end

        local start_frames = clip.timeline_start
        local end_frames = start_frames + clip.duration
        copy_specs_by_track[mapped_track.id] = copy_specs_by_track[mapped_track.id] or {}
        table.insert(copy_specs_by_track[mapped_track.id], {
            clip_id = clip.id,
            source_start_frames = start_frames,
            source_end_frames = end_frames,
        })

        ::continue_spec::
    end

    local directional_sign = 1
    if delta_frames < 0 then
        directional_sign = -1
    end

    local clamped_delta_frames = clamp_delta_to_avoid_source_overlaps(
        requested_delta_frames,
        directional_sign,
        copy_specs_by_track,
        source_intervals_by_track
    )
    if clamped_delta_frames < lower_bound then
        return true, nil, {planned_mutations = {}, new_clip_ids = {}}
    end

    local effective_delta = clamped_delta_frames

    local insert_mutations = {}
    local planned_intervals_by_track = {}
    local merged_overwrite_spans_by_track = {}
    local new_clip_ids = {}

    for _, clip in ipairs(source_clips) do
        local source_track = clip.track_id and tracks_by_id[clip.track_id] or nil
        assert(source_track, "clip_mutator.plan_duplicate_block: source clip track not found in sequence: " .. tostring(clip.track_id))
        if source_track.track_type ~= anchor_track.track_type then
            goto continue_clip
        end

        local target_track_index = source_track.track_index + delta_track_index
        local mapped_track = tracks_by_type_index[source_track.track_type]
            and tracks_by_type_index[source_track.track_type][target_track_index]
            or nil
        if not mapped_track then
            goto continue_clip
        end

        local new_start = clip.timeline_start + effective_delta
        if new_start < 0 then
            return false, "clip_mutator.plan_duplicate_block: computed negative timeline_start after clamping"
        end

        if new_start == clip.timeline_start and mapped_track.id == clip.track_id then
            goto continue_clip
        end

        local new_id = uuid.generate()
        local now = os.time()
        local new_clip = {
            id = new_id,
            project_id = clip.project_id,
            clip_kind = "timeline",
            name = clip.name,
            track_id = mapped_track.id,
            media_id = clip.media_id,
            owner_sequence_id = sequence_id,
            parent_clip_id = clip.parent_clip_id,
            master_clip_id = clip.master_clip_id,
            timeline_start = new_start,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out,
            fps_numerator = clip.fps_numerator,
            fps_denominator = clip.fps_denominator,
            enabled = clip.enabled,
            offline = clip.offline,
            created_at = now,
            modified_at = now,
        }

        table.insert(new_clip_ids, new_id)

        planned_intervals_by_track[mapped_track.id] = planned_intervals_by_track[mapped_track.id] or {}
        table.insert(planned_intervals_by_track[mapped_track.id], {
            start = new_start,
            ["end"] = new_start + clip.duration,
        })

        table.insert(insert_mutations, plan_insert(new_clip))

        ::continue_clip::
    end

    if #insert_mutations == 0 then
        return true, nil, {planned_mutations = {}, new_clip_ids = {}}
    end

    local ok_overlaps, overlap_err = validate_no_overlaps_per_track(planned_intervals_by_track)
    if not ok_overlaps then
        return false, overlap_err
    end

    for track_id, intervals in pairs(planned_intervals_by_track) do
        merged_overwrite_spans_by_track[track_id] = merge_intervals(intervals)
    end

    local occlusion_mutations = {}
    for track_id, spans in pairs(merged_overwrite_spans_by_track) do
        for _, span in ipairs(spans) do
            local span_duration = span["end"] - span.start
            assert(type(span_duration) == "number" and span_duration >= 0, "clip_mutator.plan_duplicate_block: invalid span duration")
            if span_duration > 0 then
                local ok_occ, occ_err, occ_actions = ClipMutator.resolve_occlusions(db, {
                    track_id = track_id,
                    timeline_start = span.start,
                    duration = span_duration,
                    exclude_clip_id = nil,
                })
                if not ok_occ then
                    return false, "clip_mutator.plan_duplicate_block: resolve_occlusions failed: " .. tostring(occ_err)
                end
                for _, mut in ipairs(occ_actions or {}) do
                    table.insert(occlusion_mutations, mut)
                end
            end
        end
    end

    local combined = {}
    for _, mut in ipairs(occlusion_mutations) do
        table.insert(combined, mut)
    end
    for _, mut in ipairs(insert_mutations) do
        table.insert(combined, mut)
    end

    return true, nil, {planned_mutations = combined, new_clip_ids = new_clip_ids}
end

return ClipMutator
