-- clip_mutator.lua
-- Centralised helpers for enforcing clip occlusion policies on save.

local uuid = require("uuid")
local krono_ok, krono = pcall(require, "core.krono")

local ClipMutator = {}
local timeline_state_ok, timeline_state = pcall(require, 'ui.timeline.timeline_state')

local function clone_state(row)
    return {
        id = row.id,
        track_id = row.track_id,
        media_id = row.media_id,
        start_time = row.start_time,
        duration = row.duration,
        source_in = row.source_in,
        source_out = row.source_out,
        enabled = row.enabled
    }
end

local function default_source_out(row)
    local source_in = row.source_in or 0
    if row.source_out then
        return row.source_out
    end
    return source_in + row.duration
end

local function run_update(db, row)
    local stmt = db:prepare([[
        UPDATE clips
        SET start_time = ?, duration = ?, source_in = ?, source_out = ?, enabled = ?
        WHERE id = ?
    ]])
    if not stmt then
        return false, "Failed to prepare UPDATE for clip " .. tostring(row.id)
    end
    stmt:bind_value(1, row.start_time)
    stmt:bind_value(2, row.duration)
    stmt:bind_value(3, row.source_in)
    stmt:bind_value(4, row.source_out)
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
        INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then
        return false, "Failed to prepare INSERT for clip " .. tostring(row.id)
    end
    stmt:bind_value(1, row.id)
    stmt:bind_value(2, row.track_id)
    stmt:bind_value(3, row.media_id)
    stmt:bind_value(4, row.start_time)
    stmt:bind_value(5, row.duration)
    stmt:bind_value(6, row.source_in or 0)
    stmt:bind_value(7, row.source_out or (row.source_in or 0) + row.duration)
    stmt:bind_value(8, row.enabled and 1 or 0)
    local ok = stmt:exec()
    if not ok then
        return false, stmt:last_error()
    end
    return true
end

-- Resolve occlusions for a clip about to occupy [start_time, end_time).
-- Params:
--   track_id, start_time, duration
--   exclude_clip_id: clip id to ignore while checking overlaps (e.g., the clip being updated)
local function load_track_clips(db, track_id)
    local stmt = db:prepare([[
        SELECT id, track_id, media_id, start_time, duration, source_in, source_out, enabled
        FROM clips
        WHERE track_id = ?
        ORDER BY start_time
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
        table.insert(results, {
            id = stmt:value(0),
            track_id = stmt:value(1),
            media_id = stmt:value(2),
            start_time = stmt:value(3),
            duration = stmt:value(4),
            source_in = stmt:value(5),
            source_out = stmt:value(6),
            enabled = stmt:value(7) == 1 or stmt:value(7) == true
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
            start_time = pending.start_time,
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

local function iter_overlaps(clip_list, start_time, end_time)
    local index = 1
    local count = #clip_list

    return function()
        while index <= count do
            local item = clip_list[index]
            index = index + 1
            local clip_start = item.start_time or 0
            local clip_end = clip_start + (item.duration or 0)
            if clip_end > start_time and clip_start < end_time then
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
    local start_time = params.start_time
    local duration = params.duration
    if not track_id or start_time == nil or duration == nil then
        return true
    end

    local end_time = start_time + duration
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
    local overlaps = iter_overlaps(track_clips, start_time, end_time)

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

        local clip_start = row.start_time or 0
        local clip_end = clip_start + (row.duration or 0)
        local overlap_start = math.max(clip_start, start_time)
        local overlap_end = math.min(clip_end, end_time)

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
        if clip_start < start_time and clip_end <= end_time then
            local trim_amount = clip_end - start_time
            row.duration = row.duration - trim_amount
            if row.duration < 1 then
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
        if clip_start >= start_time and clip_end > end_time then
            local trim_amount = end_time - clip_start
            row.start_time = end_time
            row.duration = row.duration - trim_amount
            if row.duration < 1 then
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
        if clip_start < start_time and clip_end > end_time then
            local left_duration = start_time - clip_start
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
            if right_duration > 0 then
                local base_in = original.source_in or 0
                local original_out = default_source_out(original)
                local right_clip = {
                    id = uuid.generate(),
                    track_id = original.track_id,
                    media_id = original.media_id,
                    start_time = end_time,
                    duration = right_duration,
                    source_in = base_in + (end_time - clip_start),
                    source_out = original_out,
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
