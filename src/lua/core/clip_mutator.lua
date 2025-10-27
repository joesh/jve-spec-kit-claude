-- clip_mutator.lua
-- Centralised helpers for enforcing clip occlusion policies on save.

local uuid = require("uuid")

local ClipMutator = {}

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

    local pending_clips = {}
    if params.pending_clips and type(params.pending_clips) == "table" then
        for key, value in pairs(params.pending_clips) do
            if type(key) == "string" and type(value) == "table" then
                pending_clips[key] = value
            elseif type(value) == "table" and type(value.id) == "string" then
                pending_clips[value.id] = value
            end
        end
    end

    local select_stmt = db:prepare([[
        SELECT id, track_id, media_id, start_time, duration, source_in, source_out, enabled
        FROM clips
        WHERE track_id = ?
          AND start_time < ?
          AND (start_time + duration) > ?
          AND (? IS NULL OR id != ?)
        ORDER BY start_time
    ]])

    if not select_stmt then
        return false, "Failed to prepare overlap query"
    end

    select_stmt:bind_value(1, track_id)
    select_stmt:bind_value(2, end_time)
    select_stmt:bind_value(3, start_time)
    select_stmt:bind_value(4, exclude_id)
    select_stmt:bind_value(5, exclude_id)

    if not select_stmt:exec() then
        return false, select_stmt:last_error()
    end

    local actions = {}

    while select_stmt:next() do
        local row = {
            id = select_stmt:value(0),
            track_id = select_stmt:value(1),
            media_id = select_stmt:value(2),
            start_time = select_stmt:value(3),
            duration = select_stmt:value(4),
            source_in = select_stmt:value(5),
            source_out = select_stmt:value(6),
            enabled = select_stmt:value(7) == 1 or select_stmt:value(7) == true
        }

        local pending_state = pending_clips[row.id]
        if pending_state ~= nil then
            if pending_state == false or pending_state.deleted then
                goto continue
            end

            local pending_start = pending_state.start_time
            if pending_start == nil then
                pending_start = row.start_time
            end
            local pending_duration = pending_state.duration or row.duration
            local pending_end = pending_start + pending_duration

            local pending_overlap_start = math.max(pending_start, start_time)
            local pending_overlap_end = math.min(pending_end, end_time)
            if pending_overlap_end > pending_overlap_start then
                local overlap_amount = pending_overlap_end - pending_overlap_start
                local tolerance = pending_state.tolerance or 0
                if overlap_amount > tolerance then
                    select_stmt:finalize()
                    return false, string.format(
                        "Pending clip %s would overlap target range (%d-%d vs %d-%d)",
                        row.id, pending_start, pending_end, start_time, end_time
                    )
                end
            end

            goto continue
        end

        local clip_start = row.start_time
        local clip_end = row.start_time + row.duration
        local overlap_start = math.max(clip_start, start_time)
        local overlap_end = math.min(clip_end, end_time)

        if overlap_end <= overlap_start then
            goto continue
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
            goto continue
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
                goto continue
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
            goto continue
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
                goto continue
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
            goto continue
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
            goto continue
        end

        ::continue::
    end

    return true, nil, actions
end

return ClipMutator
