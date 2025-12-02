local ClipMutator = {}
local timeline_state_ok, timeline_state = pcall(require, 'ui.timeline.timeline_state')
local Rational = require("core.rational")
local uuid = require("uuid")

    local function clone_state(row)
    return {
        id = row.id,
        project_id = row.project_id,
        track_id = row.track_id,
        media_id = row.media_id,
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
    return row.fps_numerator or 30, row.fps_denominator or 1
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

local function default_source_out(row)
    local source_in = row.source_in or 0
    if getmetatable(source_in) ~= Rational.metatable then
        -- Should ideally be Rational
    end
    
    if row.source_out then
        return row.source_out
    end
    return source_in + row.duration
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
    local fps_num = row.fps_numerator or (row.rate and row.rate.fps_numerator) or 30
    local fps_den = row.fps_denominator or (row.rate and row.rate.fps_denominator) or 1
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
        source_in_frame = get_frames(row.source_in or 0),
        source_out_frame = get_frames(row.source_out or (row.source_in or 0) + row.duration),
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        enabled = row.enabled and 1 or 0,
        created_at = row.created_at or os.time(),
        modified_at = row.modified_at or os.time()
    }
end

-- Resolve occlusions for a clip about to occupy [start_value, end_time).
-- Params:
--   track_id, start_value, duration
--   exclude_clip_id: clip id to ignore while checking overlaps (e.g., the clip being updated)
local function load_track_clips(db, track_id)
    local stmt = db:prepare([[
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
               fps_numerator, fps_denominator, enabled
        FROM clips
        WHERE track_id = ?
        ORDER BY timeline_start_frame
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
        local num = stmt:value(10)
        local den = stmt:value(11)
        table.insert(results, {
            id = stmt:value(0),
            project_id = stmt:value(1),
            clip_kind = stmt:value(2),
            name = stmt:value(3),
            track_id = stmt:value(4),
            media_id = stmt:value(5),
            timeline_start = Rational.new(stmt:value(6), num, den),
            start_value = Rational.new(stmt:value(6), num, den), -- Legacy compat
            duration = Rational.new(stmt:value(7), num, den),
            source_in = Rational.new(stmt:value(8), num, den),
            source_out = Rational.new(stmt:value(9), num, den),
            fps_numerator = num,
            fps_denominator = den,
            enabled = stmt:value(12) == 1 or stmt:value(12) == true
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
            if not clip_start then
                 clip_start = Rational.new(0, item.fps_numerator or 30, item.fps_denominator or 1)
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

    -- Hydrate inputs to ensure safe Rational comparisons
    start_value = Rational.hydrate(start_value, 30, 1)
    duration = Rational.hydrate(duration, 30, 1)
    
    if not start_value or not duration then
        return true -- Should not happen if inputs weren't nil
    end

    local end_time = start_value + duration
    local exclude_id = params.exclude_clip_id

    local krono_enabled = krono_ok and krono and krono.is_enabled and krono.is_enabled()
    local krono_start = krono_enabled and krono.now and krono.now() or nil
    local track_clips, load_err = nil, nil
    local window_cache = params.pending_clips and params.pending_clips.__window_cache
    if not window_cache and timeline_state_ok and timeline_state and timeline_state.get_clips_for_track then
        local cached = timeline_state.get_clips_for_track(track_id)
        if cached and #cached > 0 then
            window_cache = {[track_id] = cached}
        end
    end
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

        local clip_start = Rational.hydrate(row.timeline_start or row.start_value, get_row_rate(row))
        if not clip_start then
             clip_start = Rational.new(0, get_row_rate(row))
        end
        
        row.duration = Rational.hydrate(row.duration, get_row_rate(row))
        
        local clip_end = clip_start + (row.duration or Rational.new(0, 30, 1))
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

        -- Overlap on tail (trim right side)
        -- Result must end BEFORE or AT start_value
        if clip_start < start_value and clip_end <= end_time then
            local row_fps_num, row_fps_den = get_row_rate(row)
            local target_end = start_value:rescale_floor(row_fps_num, row_fps_den)
            local new_duration = target_end - clip_start
            
            row.duration = new_duration
            
            local dur_frames = get_frames(row.duration)
            if dur_frames < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            if row.source_out then
                row.source_out = (row.source_in or 0) + new_duration
            else
                local base_in = row.source_in or 0
                row.source_out = base_in + row.duration
            end

            table.insert(actions, plan_update(row, original))
            goto continue_loop
        end

        -- Overlap on head (trim left side)
        -- Result must start AFTER or AT end_time
        if clip_start >= start_value and clip_end > end_time then
            local row_fps_num, row_fps_den = get_row_rate(row)
            local target_start = end_time:rescale_ceil(row_fps_num, row_fps_den)
            
            local original_end = clip_start + row.duration
            local new_duration = original_end - target_start
            
            local trim_amount = target_start - clip_start

            row.timeline_start = target_start
            row.duration = new_duration
            
            local dur_frames = get_frames(row.duration)
            if dur_frames < 1 then
                table.insert(actions, plan_delete(original))
                goto continue_loop
            end

            if row.source_in then
                row.source_in = row.source_in + trim_amount
            else
                row.source_in = trim_amount
            end
            
            row.source_out = row.source_in + row.duration

            table.insert(actions, plan_update(row, original))
            goto continue_loop
        end

        -- Straddles new clip → split existing clip
        if clip_start < start_value and clip_end > end_time then
            local row_fps_num, row_fps_den = get_row_rate(row)
            local target_left_end = start_value:rescale_floor(row_fps_num, row_fps_den)
            local left_duration = target_left_end - clip_start
            
            local target_right_start = end_time:rescale_ceil(row_fps_num, row_fps_den)
            local right_duration = clip_end - target_right_start

            -- Update left portion
            row.duration = left_duration
            row.source_out = (row.source_in or 0) + left_duration

            table.insert(actions, plan_update(row, original))

            -- Create right portion
            local right_dur_frames = get_frames(right_duration)
            if right_dur_frames > 0 then
                local base_in = original.source_in or 0
                local shift_amount = target_right_start - clip_start
                local original_out = default_source_out(original)
                local right_clip = {
                    id = uuid.generate(),
                    project_id = original.project_id,
                    clip_kind = original.clip_kind,
                    name = original.name,
                    track_id = original.track_id,
                    media_id = original.media_id,
                    timeline_start = target_right_start,
                    duration = right_duration,
                    source_in = base_in + shift_amount,
                    source_out = original_out,
                    fps_numerator = row_fps_num,
                    fps_denominator = row_fps_den,
                    enabled = original.enabled
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
        print(string.format("clip_mutator.resolve[%s]: %.2fms (load=%.2fms body=%.2fms)",
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

    insert_time = Rational.hydrate(insert_time, 30, 1)
    shift_amount = Rational.hydrate(shift_amount, 30, 1)
    
    local track_clips, err = load_track_clips(db, track_id)
    if not track_clips then return false, err end

    local actions = {}
    
    -- Iterate and shift/split
    -- Note: clips are ordered by start time
    for _, row in ipairs(track_clips) do
        local original = clone_state(row)
        local clip_start = Rational.hydrate(row.timeline_start or row.start_value, get_row_rate(row))
        local clip_end = clip_start + row.duration
        
        if clip_start >= insert_time then
            -- Fully after: Shift
            row.timeline_start = clip_start + shift_amount
            table.insert(actions, plan_update(row, original))
            
        elseif clip_start < insert_time and clip_end > insert_time then
            -- Straddles: Split
            -- Left Part: Ends at insert_time
            local row_fps_num, row_fps_den = get_row_rate(row)
            local split_point = insert_time:rescale_floor(row_fps_num, row_fps_den)
            local left_dur = split_point - clip_start
            
            row.duration = left_dur
            row.source_out = (row.source_in or 0) + left_dur
            
            table.insert(actions, plan_update(row, original))
            
            -- Right Part: Starts at insert_time + shift_amount
            local right_start = split_point + shift_amount
            local right_dur = clip_end - split_point
            local right_src_in = (row.source_in or 0) + left_dur
            
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
                source_out = default_source_out(original), -- original end
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
