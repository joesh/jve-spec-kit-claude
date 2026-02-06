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
local database = require("core.database")

local M = {}

-- Get all clips in the same link group as the given clip
-- Returns: array of {clip_id, role, time_offset, enabled} or nil if not linked
function M.get_link_group(clip_id, db)
    -- First find the link group for this clip
    local query = db:prepare([[
        SELECT link_group_id FROM clip_links WHERE clip_id = ?
    ]])

    assert(query, string.format("clip_link.get_link_group: failed to prepare query for clip %s", tostring(clip_id)))

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

    assert(query, string.format("clip_link.get_link_group: failed to prepare group query for link_group %s", tostring(link_group_id)))

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

    assert(query, string.format("clip_link.is_linked: failed to prepare query for clip %s", tostring(clip_id)))

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
        insert_query:bind_value(4, clip_info.time_offset or 0) -- NSF-OK: 0 = no time offset between linked clips

        if not insert_query:exec() then
            insert_query:finalize()
            return nil, "Failed to insert clip into link group"
        end

        insert_query:reset()
    end

    insert_query:finalize()
    return link_group_id
end

-- Link two clips together (convenience method for clip_insertion)
-- Creates a new link group if left clip isn't linked, otherwise adds right to left's group
-- left/right: {id, role, time_offset} - id can be in 'id' or 'clip_id' field
function M.link_two_clips(left, right)
    local db = assert(database.get_connection(), "link_two_clips: missing db connection")
    local left_id = assert(left and (left.id or left.clip_id), "link_two_clips: missing left clip id")
    local right_id = assert(right and (right.id or right.clip_id), "link_two_clips: missing right clip id")

    local left_group = M.get_link_group_id(left_id, db)
    local right_group = M.get_link_group_id(right_id, db)
    assert(not right_group or right_group == left_group, "link_two_clips: clip already linked to another group")

    if not left_group then
        assert(left.role, "link_two_clips: left.role is required")
        assert(right.role, "link_two_clips: right.role is required")
        local link_group_id, error_msg = M.create_link_group({
            {
                clip_id = left_id,
                role = left.role,
                time_offset = left.time_offset or 0
            },
            {
                clip_id = right_id,
                role = right.role,
                time_offset = right.time_offset or 0
            }
        }, db)
        assert(link_group_id, error_msg or "link_two_clips: failed to create link group")
        return link_group_id
    end

    -- Add right clip to existing left group
    local insert_query = assert(db:prepare([[
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES (?, ?, ?, ?, 1)
    ]]), "link_two_clips: failed to prepare insert")
    insert_query:bind_value(1, left_group)
    insert_query:bind_value(2, right_id)
    assert(right.role, "link_two_clips: right.role is required")
    insert_query:bind_value(3, right.role)
    insert_query:bind_value(4, right.time_offset or 0)
    local ok = insert_query:exec()
    insert_query:finalize()
    assert(ok, "link_two_clips: failed to insert clip link")
    return left_group
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
    local delete_query = assert(db:prepare([[
        DELETE FROM clip_links WHERE clip_id = ?
    ]]), "clip_link.unlink_clip: failed to prepare DELETE for clip " .. tostring(clip_id))

    delete_query:bind_value(1, clip_id)
    assert(delete_query:exec(), "clip_link.unlink_clip: DELETE failed for clip " .. tostring(clip_id))
    delete_query:finalize()

    -- Check how many clips remain in the group
    local count_query = db:prepare([[
        SELECT COUNT(*) FROM clip_links WHERE link_group_id = ?
    ]])

    assert(count_query, "clip_link.unlink_clip: failed to prepare COUNT query for group " .. tostring(link_group_id))

    count_query:bind_value(1, link_group_id)

    local remaining_count = 0
    if count_query:exec() and count_query:next() then
        remaining_count = count_query:value(0)
    end
    count_query:finalize()

    -- If only 1 clip remains, delete the entire link group
    if remaining_count <= 1 then
        local cleanup_query = assert(db:prepare("DELETE FROM clip_links WHERE link_group_id = ?"),
            "clip_link.unlink_clip: failed to prepare cleanup DELETE")
        cleanup_query:bind_value(1, link_group_id)
        assert(cleanup_query:exec(), "clip_link.unlink_clip: cleanup DELETE failed for group " .. tostring(link_group_id))
        cleanup_query:finalize()
    end

    return true
end

-- Temporarily disable link for a clip (link remains but doesn't apply)
function M.disable_link(clip_id, db)
    local query = assert(db:prepare([[
        UPDATE clip_links SET enabled = 0 WHERE clip_id = ?
    ]]), "clip_link.disable_link: failed to prepare query for clip " .. tostring(clip_id))

    query:bind_value(1, clip_id)
    local result = query:exec()
    query:finalize()
    assert(result, "clip_link.disable_link: exec failed for clip " .. tostring(clip_id))

    return result
end

-- Re-enable a disabled link
function M.enable_link(clip_id, db)
    local query = assert(db:prepare([[
        UPDATE clip_links SET enabled = 1 WHERE clip_id = ?
    ]]), "clip_link.enable_link: failed to prepare query for clip " .. tostring(clip_id))

    query:bind_value(1, clip_id)
    local result = query:exec()
    query:finalize()
    assert(result, "clip_link.enable_link: exec failed for clip " .. tostring(clip_id))

    return result
end

-- Get the link group ID for a clip (or nil if not linked)
function M.get_link_group_id(clip_id, db)
    local query = db:prepare([[
        SELECT link_group_id FROM clip_links WHERE clip_id = ?
    ]])

    assert(query, string.format("clip_link.get_link_group_id: failed to prepare query for clip %s", tostring(clip_id)))

    query:bind_value(1, clip_id)

    local link_group_id = nil
    if query:exec() and query:next() then
        link_group_id = query:value(0)
    end
    query:finalize()

    return link_group_id
end

-- Calculate the anchor time for a link group (minimum timeline_start_frame across all clips)
-- This is used to maintain sync when trimming linked clips
function M.calculate_anchor_time(link_group_id, db)
    local query = db:prepare([[
        SELECT MIN(c.timeline_start_frame)
        FROM clips c
        JOIN clip_links cl ON c.id = cl.clip_id
        WHERE cl.link_group_id = ?
    ]])

    assert(query, string.format("clip_link.calculate_anchor_time: failed to prepare query for link_group %s", tostring(link_group_id)))

    query:bind_value(1, link_group_id)

    local anchor_time = nil
    if query:exec() and query:next() then
        anchor_time = query:value(0)
    end
    query:finalize()

    return anchor_time
end

return M
