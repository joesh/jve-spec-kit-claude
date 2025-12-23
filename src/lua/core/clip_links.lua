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
-- Size: ~190 LOC
-- Volatility: unknown
--
-- @file clip_links.lua
-- Original intent (unreviewed):
-- Clip Links: A/V sync relationships between clips
-- Manages linked clip groups for synchronized editing operations
local uuid = require("uuid")

local M = {}

-- Get all clips in the same link group as the given clip
-- Returns: array of {clip_id, role, time_offset, enabled} or nil if not linked
function M.get_link_group(clip_id, db)
    -- First find the link group for this clip
    local query = db:prepare([[
        SELECT link_group_id FROM clip_links WHERE clip_id = ?
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, clip_id)

    local link_group_id = nil
    if query:exec() and query:next() then
        link_group_id = query:value(0)
    end
    query:finalize()

    if not link_group_id then
        return nil  -- Clip is not linked
    end

    -- Now get all clips in this link group
    query = db:prepare([[
        SELECT clip_id, role, time_offset, enabled
        FROM clip_links
        WHERE link_group_id = ?
        ORDER BY role
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, link_group_id)

    local linked_clips = {}
    if query:exec() then
        while query:next() do
            table.insert(linked_clips, {
                clip_id = query:value(0),
                role = query:value(1),
                time_offset = query:value(2),
                enabled = query:value(3) == 1
            })
        end
    end
    query:finalize()

    return linked_clips
end

-- Check if a clip is part of a link group
function M.is_linked(clip_id, db)
    local query = db:prepare([[
        SELECT 1 FROM clip_links WHERE clip_id = ? LIMIT 1
    ]])

    if not query then
        return false
    end

    query:bind_value(1, clip_id)

    local result = false
    if query:exec() and query:next() then
        result = true
    end
    query:finalize()

    return result
end

-- Create a new link group between clips
-- clips: array of {clip_id, role, time_offset?}
-- Returns: link_group_id or nil on failure
function M.create_link_group(clips, db)
    if not clips or #clips < 2 then
        return nil, "At least 2 clips required for a link group"
    end

    -- Generate new link group ID
    local link_group_id = uuid.generate()

    -- Insert all clips into the link group
    local insert_query = db:prepare([[
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES (?, ?, ?, ?, 1)
    ]])

    if not insert_query then
        return nil, "Failed to prepare insert query"
    end

    for _, clip_info in ipairs(clips) do
        insert_query:bind_value(1, link_group_id)
        insert_query:bind_value(2, clip_info.clip_id)
        insert_query:bind_value(3, clip_info.role)
        insert_query:bind_value(4, clip_info.time_offset or 0)

        if not insert_query:exec() then
            insert_query:finalize()
            return nil, "Failed to insert clip into link group"
        end

        insert_query:reset()
    end

    insert_query:finalize()
    return link_group_id
end

-- Remove a clip from its link group
-- If this leaves only 1 clip in the group, delete the entire group
function M.unlink_clip(clip_id, db)
    -- Find the link group
    local query = db:prepare([[
        SELECT link_group_id FROM clip_links WHERE clip_id = ?
    ]])

    if not query then
        return false
    end

    query:bind_value(1, clip_id)

    local link_group_id = nil
    if query:exec() and query:next() then
        link_group_id = query:value(0)
    end
    query:finalize()

    if not link_group_id then
        return true  -- Already unlinked
    end

    -- Remove this clip from the link group
    local delete_query = db:prepare([[
        DELETE FROM clip_links WHERE clip_id = ?
    ]])

    if not delete_query then
        return false
    end

    delete_query:bind_value(1, clip_id)
    delete_query:exec()
    delete_query:finalize()

    -- Check how many clips remain in the group
    local count_query = db:prepare([[
        SELECT COUNT(*) FROM clip_links WHERE link_group_id = ?
    ]])

    if not count_query then
        return true  -- Clip was removed, ignore cleanup failure
    end

    count_query:bind_value(1, link_group_id)

    local remaining_count = 0
    if count_query:exec() and count_query:next() then
        remaining_count = count_query:value(0)
    end
    count_query:finalize()

    -- If only 1 clip remains, delete the entire link group
    if remaining_count <= 1 then
        local cleanup_query = db:prepare([[
            DELETE FROM clip_links WHERE link_group_id = ?
        ]])

        if cleanup_query then
            cleanup_query:bind_value(1, link_group_id)
            cleanup_query:exec()
            cleanup_query:finalize()
        end
    end

    return true
end

-- Temporarily disable link for a clip (link remains but doesn't apply)
function M.disable_link(clip_id, db)
    local query = db:prepare([[
        UPDATE clip_links SET enabled = 0 WHERE clip_id = ?
    ]])

    if not query then
        return false
    end

    query:bind_value(1, clip_id)
    local result = query:exec()
    query:finalize()

    return result
end

-- Re-enable a disabled link
function M.enable_link(clip_id, db)
    local query = db:prepare([[
        UPDATE clip_links SET enabled = 1 WHERE clip_id = ?
    ]])

    if not query then
        return false
    end

    query:bind_value(1, clip_id)
    local result = query:exec()
    query:finalize()

    return result
end

-- Get the link group ID for a clip (or nil if not linked)
function M.get_link_group_id(clip_id, db)
    local query = db:prepare([[
        SELECT link_group_id FROM clip_links WHERE clip_id = ?
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, clip_id)

    local link_group_id = nil
    if query:exec() and query:next() then
        link_group_id = query:value(0)
    end
    query:finalize()

    return link_group_id
end

-- Calculate the anchor time for a link group (minimum start_value across all clips)
-- This is used to maintain sync when trimming linked clips
function M.calculate_anchor_time(link_group_id, db)
    local query = db:prepare([[
        SELECT MIN(c.start_value)
        FROM clips c
        JOIN clip_links cl ON c.id = cl.clip_id
        WHERE cl.link_group_id = ?
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, link_group_id)

    local anchor_time = nil
    if query:exec() and query:next() then
        anchor_time = query:value(0)
    end
    query:finalize()

    return anchor_time
end

return M
