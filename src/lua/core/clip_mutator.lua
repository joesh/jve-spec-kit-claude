local ClipMutator = {}
local Rational = require("core.rational")
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
	        created_at = row.created_at,
	        modified_at = row.modified_at,
	        start_value = row.start_value,
	        duration = row.duration,
	        source_in = row.source_in,
	        source_out = row.source_out,
	        fps_numerator = row.fps_numerator,
	        fps_denominator = row.fps_denominator,
	        enabled = row.enabled
	    }
	end

-- Helper to get frame count
local function get_frames(val)
    if type(val) == "table" and val.frames then return val.frames end
    return val
end

-- Helper to get rate from row (handles DB vs Timeline State format)
local function get_row_rate(row)
    if row.rate then
        return row.rate.fps_numerator, row.rate.fps_denominator
    end
    assert(row.fps_numerator and row.fps_denominator, "clip_mutator: missing fps metadata")
    return row.fps_numerator, row.fps_denominator
end

local function assert_rate(num, den, label)
    if not num or not den then
        error("clip_mutator: missing " .. tostring(label or "fps") .. " metadata", 3)
    end
    if num <= 0 or den <= 0 then
        error(string.format("clip_mutator: invalid %s metadata (%s/%s)", tostring(label or "fps"), tostring(num), tostring(den)), 3)
    end
end

local function ensure_rational(value, params, label)
    if getmetatable(value) == Rational.metatable then
        return value
    end

    if type(value) == "table" and value.frames ~= nil then
        if not value.fps_numerator or not value.fps_denominator then
            error("clip_mutator: missing fps metadata for " .. tostring(label or "value"), 3)
        end
        return Rational.new(value.frames, value.fps_numerator, value.fps_denominator)
    end

    if type(value) == "number" then
        local rate = params and params.sequence_frame_rate
        if not rate or not rate.fps_numerator or not rate.fps_denominator then
            error("clip_mutator: missing sequence_frame_rate for " .. tostring(label or "value") .. " hydration", 3)
        end
        return Rational.new(value, rate.fps_numerator, rate.fps_denominator)
    end

    error("clip_mutator: invalid " .. tostring(label or "value") .. " (type=" .. type(value) .. ")", 3)
end

-- Helper for mixed min/max
local function val_max(a, b)
    if getmetatable(a) == Rational.metatable or getmetatable(b) == Rational.metatable then
        return Rational.max(a, b)
    end
    return math.max(a, b)
end

local function val_min(a, b)
    -- Rational doesn't have min? It implements __lt.
    if getmetatable(a) == Rational.metatable or getmetatable(b) == Rational.metatable then
        return (a < b) and a or b
    end
    return math.min(a, b)
end

local function require_source_out(row, context)
    if not row or not row.source_out then
        error("clip_mutator: missing source_out (" .. tostring(context or "unknown") .. ")", 3)
    end
    return row.source_out
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
    assert_rate(fps_num, fps_den, "clip fps")
    assert(row.timeline_start or row.start_value, "clip_mutator: insert mutation missing timeline_start")
    assert(row.duration, "clip_mutator: insert mutation missing duration")
    assert(row.source_in, "clip_mutator: insert mutation missing source_in")
    assert(row.source_out, "clip_mutator: insert mutation missing source_out")
    return {
        type = "insert",
        clip_id = row.id,
        project_id = row.project_id,
        clip_kind = row.clip_kind or "timeline",
        name = row.name or "",
        track_id = row.track_id,
        media_id = row.media_id,
        timeline_start_frame = get_frames(row.timeline_start or row.start_value),
        duration_frames = get_frames(row.duration),
        source_in_frame = get_frames(row.source_in),
        source_out_frame = get_frames(row.source_out),
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        enabled = row.enabled and 1 or 0,
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
               c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
               c.fps_numerator, c.fps_denominator,
               s.fps_numerator, s.fps_denominator,
               c.enabled, c.created_at, c.modified_at
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
        local clip_num = stmt:value(10)
        local clip_den = stmt:value(11)
        local seq_num = stmt:value(12)
        local seq_den = stmt:value(13)
        assert_rate(clip_num, clip_den, "clip fps")
        assert_rate(seq_num, seq_den, "sequence fps")
        table.insert(results, {
		            id = stmt:value(0),
		            project_id = stmt:value(1),
		            clip_kind = stmt:value(2),
		            name = stmt:value(3),
		            track_id = stmt:value(4),
		            media_id = stmt:value(5),
		            created_at = stmt:value(15),
		            modified_at = stmt:value(16),
		            timeline_start = Rational.new(stmt:value(6), seq_num, seq_den),
		            start_value = Rational.new(stmt:value(6), seq_num, seq_den), -- Legacy compat
		            duration = Rational.new(stmt:value(7), seq_num, seq_den),
		            source_in = Rational.new(stmt:value(8), clip_num, clip_den),
		            source_out = Rational.new(stmt:value(9), clip_num, clip_den),
		            rate = { fps_numerator = clip_num, fps_denominator = clip_den },
		            fps_numerator = clip_num,
		            fps_denominator = clip_den,
		            enabled = stmt:value(14) == 1 or stmt:value(14) == true
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
	            if not clip_start or getmetatable(clip_start) ~= Rational.metatable then
	                error("clip_mutator: overlap check missing clip_start", 2)
	            end
	            local clip_end = clip_start + (item.duration or 0)
	            
	            -- Safe comparison (Rational < Rational)
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
    if not params then
        return true
    end

    local track_id = params.track_id
    local start_value = params.timeline_start or params.start_value -- Accept both
    local duration = params.duration
	    if not track_id or start_value == nil or duration == nil then
	        return true
	    end

	    start_value = ensure_rational(start_value, params, "start_value")
	    duration = ensure_rational(duration, params, "duration")

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
        if getmetatable(clip_start) ~= Rational.metatable then
            error("clip_mutator.resolve_occlusions: missing clip_start", 2)
        end

        local clip_duration = row.duration
        if getmetatable(clip_duration) ~= Rational.metatable then
            error("clip_mutator.resolve_occlusions: missing clip duration", 2)
        end

        local clip_end = clip_start + clip_duration
        local overlap_start = val_max(clip_start, start_value)
        local overlap_end = val_min(clip_end, end_time)

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
            local row_fps_num, row_fps_den = get_row_rate(row)
            local new_duration_seq = start_value - clip_start
            if new_duration_seq.frames < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            local new_duration_src = new_duration_seq:rescale_floor(row_fps_num, row_fps_den)
            row.duration = new_duration_seq
            row.source_out = row.source_in + new_duration_src

            table.insert(actions, plan_update(row, original))
            goto continue_loop
        end

        -- Overlap on head (trim left side): shift start to end_time, shorten duration from the front.
        if clip_start >= start_value and clip_end > end_time then
            local row_fps_num, row_fps_den = get_row_rate(row)
            local trim_amount_seq = end_time - clip_start
            local new_duration_seq = clip_end - end_time
            if new_duration_seq.frames < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            local trim_amount_src = trim_amount_seq:rescale_floor(row_fps_num, row_fps_den)
            row.timeline_start = end_time
            row.duration = new_duration_seq
            row.source_in = row.source_in + trim_amount_src
            row.source_out = require_source_out(original, "resolve_occlusions/head_trim")

            table.insert(actions, plan_update(row, original))
            goto continue_loop
        end

        -- Straddles new clip → split existing clip into left and right parts.
        if clip_start < start_value and clip_end > end_time then
            local row_fps_num, row_fps_den = get_row_rate(row)
            local left_duration_seq = start_value - clip_start
            local right_duration_seq = clip_end - end_time
            if left_duration_seq.frames < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            local left_duration_src = left_duration_seq:rescale_floor(row_fps_num, row_fps_den)
            row.duration = left_duration_seq
            row.source_out = row.source_in + left_duration_src
            table.insert(actions, plan_update(row, original))

            if right_duration_seq.frames > 0 then
                local right_shift_src = (end_time - clip_start):rescale_floor(row_fps_num, row_fps_den)
                local right_clip = {
                    id = uuid.generate(),
                    project_id = original.project_id,
                    clip_kind = original.clip_kind,
                    name = original.name,
                    track_id = original.track_id,
                    media_id = original.media_id,
                    timeline_start = end_time,
                    duration = right_duration_seq,
                    source_in = original.source_in + right_shift_src,
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
        pending_state._seen = true
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
    
    if not track_id or not insert_time or not shift_amount then
        return true -- Nothing to do
    end

    insert_time = ensure_rational(insert_time, params, "insert_time")
    shift_amount = ensure_rational(shift_amount, params, "shift_amount")
    
    local track_clips, err = load_track_clips(db, track_id)
    if not track_clips then return false, err end

    local actions = {}
    
    -- Iterate and shift/split
    -- Note: clips are ordered by start time
    for _, row in ipairs(track_clips) do
        local original = clone_state(row)
        local clip_start = row.timeline_start or row.start_value
        if getmetatable(clip_start) ~= Rational.metatable then
            error("clip_mutator.resolve_ripple: missing clip_start", 2)
        end
        local clip_end = clip_start + row.duration
        
        if clip_start >= insert_time then
            -- Fully after: Shift
            row.timeline_start = clip_start + shift_amount
            table.insert(actions, plan_update(row, original))
            
        elseif clip_start < insert_time and clip_end > insert_time then
            -- Straddles: Split
            -- Left Part: Ends at insert_time
            local row_fps_num, row_fps_den = get_row_rate(row)
            local split_point = insert_time
            local left_dur = split_point - clip_start
            local left_dur_source = left_dur:rescale_floor(row_fps_num, row_fps_den)
            
            row.duration = left_dur
            row.source_out = row.source_in + left_dur_source
            
            table.insert(actions, plan_update(row, original))
            
            -- Right Part: Starts at insert_time + shift_amount
            local right_start = split_point + shift_amount
            local right_dur = clip_end - split_point
            local right_src_in = row.source_in + left_dur_source
            
            local right_clip = {
                id = uuid.generate(),
                project_id = row.project_id,
                clip_kind = row.clip_kind,
                name = row.name .. " (2)",
                track_id = row.track_id,
                media_id = row.media_id,
                timeline_start = right_start,
                duration = right_dur,
                source_in = right_src_in,
                source_out = require_source_out(original, "resolve_ripple"), -- original end
                fps_numerator = row_fps_num,
                fps_denominator = row_fps_den,
                enabled = row.enabled,
                created_at = os.time(),
                modified_at = os.time()
            }
            table.insert(actions, plan_insert(right_clip))
        end
    end
    
    return true, nil, actions
end

return ClipMutator
