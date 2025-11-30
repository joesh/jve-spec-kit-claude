-- clip_mutator.lua
-- Centralised helpers for enforcing clip occlusion policies on save.

local uuid = require("uuid")
local krono_ok, krono = pcall(require, "core.krono")

local ClipMutator = {}
local timeline_state_ok, timeline_state = pcall(require, 'ui.timeline.timeline_state')
local Rational = require("core.rational")

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

local function run_update(db, row)
    local stmt = db:prepare([[
        UPDATE clips
        SET timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?
        WHERE id = ?
    ]])
    if not stmt then
        return false, "Failed to prepare UPDATE for clip " .. tostring(row.id)
    end
    stmt:bind_value(1, get_frames(row.start_value))
    stmt:bind_value(2, get_frames(row.duration))
    stmt:bind_value(3, get_frames(row.source_in))
    stmt:bind_value(4, get_frames(row.source_out))
    stmt:bind_value(5, row.enabled and 1 or 0)
    stmt:bind_value(6, row.id)
    local ok = stmt:exec()
    if not ok then
        return false, stmt:last_error()
    end
    return true
end

local function run_delete(db, clip_id)
    local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
    if not stmt then
        return false, "Failed to prepare DELETE for clip " .. tostring(clip_id)
    end
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    if not ok then
        return false, stmt:last_error()
    end
    return true
end

local function run_insert(db, row)
    local stmt = db:prepare([[
        INSERT INTO clips (
            id, project_id, clip_kind, name, track_id, media_id,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then
        return false, "Failed to prepare INSERT for clip " .. tostring(row.id)
    end
    stmt:bind_value(1, row.id)
    stmt:bind_value(2, row.project_id)
    stmt:bind_value(3, row.clip_kind or "timeline")
    stmt:bind_value(4, row.name or "")
    stmt:bind_value(5, row.track_id)
    stmt:bind_value(6, row.media_id)
    stmt:bind_value(7, get_frames(row.start_value))
    stmt:bind_value(8, get_frames(row.duration))
    stmt:bind_value(9, get_frames(row.source_in or 0))
    stmt:bind_value(10, get_frames(row.source_out or (row.source_in or 0) + row.duration))
    stmt:bind_value(11, row.fps_numerator or 30)
    stmt:bind_value(12, row.fps_denominator or 1)
    stmt:bind_value(13, row.enabled and 1 or 0)
    local ok = stmt:exec()
    if not ok then
        return false, stmt:last_error()
    end
    return true
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
            start_value = Rational.new(stmt:value(6), num, den),
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
            local clip_start = item.start_value or 0
            local clip_end = clip_start + (item.duration or 0)
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
    if not db or not params then
        return true
    end

    local track_id = params.track_id
    local start_value = params.timeline_start or params.start_value -- Accept both
    local duration = params.duration
    if not track_id or start_value == nil or duration == nil then
        return true
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

        local clip_start = row.start_value or 0
        local clip_end = clip_start + (row.duration or 0)
        local overlap_start = val_max(clip_start, start_value)
        local overlap_end = val_min(clip_end, end_time)

        if overlap_end <= overlap_start then
            goto continue_loop
        end

        local original = clone_state(row)

        -- Fully covered → delete
        if overlap_start <= clip_start and overlap_end >= clip_end then
            table.insert(actions, {
                type = "delete",
                clip = original
            })
            local ok, err = run_delete(db, row.id)
            if not ok then
                return false, err
            end
            goto continue_loop
        end

        -- Overlap on tail (trim right side)
        if clip_start < start_value and clip_end <= end_time then
            local trim_amount = clip_end - start_value
            row.duration = row.duration - trim_amount
            
            local dur_frames = get_frames(row.duration)
            if dur_frames < 1 then
                table.insert(actions, {
                    type = "delete",
                    clip = original
                })
                local ok, err = run_delete(db, row.id)
                if not ok then
                    return false, err
                end
                goto continue_loop
            end

            if row.source_out then
                row.source_out = row.source_out - trim_amount
            else
                local base_in = row.source_in or 0
                row.source_out = base_in + row.duration
            end

            local ok, err = run_update(db, row)
            if not ok then
                return false, err
            end
            table.insert(actions, {
                type = "trim",
                before = original,
                after = clone_state(row)
            })
            goto continue_loop
        end

        -- Overlap on head (trim left side)
        if clip_start >= start_value and clip_end > end_time then
            local trim_amount = end_time - clip_start
            row.start_value = end_time
            row.duration = row.duration - trim_amount
            
            local dur_frames = get_frames(row.duration)
            if dur_frames < 1 then
                table.insert(actions, {
                    type = "delete",
                    clip = original
                })
                local ok, err = run_delete(db, row.id)
                if not ok then
                    return false, err
                end
                goto continue_loop
            end

            if row.source_in then
                row.source_in = row.source_in + trim_amount
            else
                row.source_in = 0
            end
            if row.source_out then
                row.source_out = row.source_in + row.duration
            else
                row.source_out = row.source_in + row.duration
            end

            local ok, err = run_update(db, row)
            if not ok then
                return false, err
            end
            table.insert(actions, {
                type = "trim",
                before = original,
                after = clone_state(row)
            })
            goto continue_loop
        end

        -- Straddles new clip → split existing clip
        if clip_start < start_value and clip_end > end_time then
            local left_duration = start_value - clip_start
            local right_duration = clip_end - end_time

            -- Update left portion
            row.duration = left_duration
            if row.source_out then
                row.source_out = original.source_out - right_duration
            else
                local base_in = row.source_in or 0
                row.source_out = base_in + left_duration
            end

            local ok, err = run_update(db, row)
            if not ok then
                return false, err
            end
            table.insert(actions, {
                type = "trim",
                before = original,
                after = clone_state(row)
            })

            -- Create right portion
            local right_dur_frames = get_frames(right_duration)
            if right_dur_frames > 0 then
                local base_in = original.source_in or 0
                local original_out = default_source_out(original)
                local right_clip = {
                    id = uuid.generate(),
                    project_id = original.project_id,
                    clip_kind = original.clip_kind,
                    name = original.name,
                    track_id = original.track_id,
                    media_id = original.media_id,
                    start_value = end_time,
                    duration = right_duration,
                    source_in = base_in + (end_time - clip_start),
                    source_out = original_out,
                    fps_numerator = original.fps_numerator,
                    fps_denominator = original.fps_denominator,
                    enabled = original.enabled
                }
                local ok_insert, err_insert = run_insert(db, right_clip)
                if not ok_insert then
                    return false, err_insert
                end
                table.insert(actions, {
                    type = "insert",
                    clip = clone_state(right_clip)
                })
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

return ClipMutator
