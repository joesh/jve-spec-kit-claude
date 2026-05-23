--- LinkClips and UnlinkClip commands
local M = {}
local log = require("core.logger").for_area("commands")


-- Two distinct SPECs (LINK_SPEC, UNLINK_SPEC) because the executors take
-- different args. They were collapsed into one shared SPEC originally,
-- which made UnlinkClips' SPEC validate-require `clips` and `link_group_id`
-- (LinkClips-only fields it never reads) — caller had to pass dummies
-- to satisfy validation. Split lets each command demand only what it
-- actually uses.
local LINK_SPEC = {
    args = {
        clips         = { required = true },
        link_group_id = { required = true },
        project_id    = { required = true },
        dry_run       = { kind = "boolean" },
    },
}

local UNLINK_SPEC = {
    args = {
        clip_id    = { required = true },
        project_id = { required = true },
        dry_run    = { kind = "boolean" },
    },
    persisted = {
        original_link_group = {},
        original_role = {},
        original_time_offset = { kind = "number", default = 0 },
    },
}

function M.register(executors, undoers, db)
    
    local function executor(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            log.event("Executing LinkClips")
        end

        if not args.clips or #args.clips < 2 then
            log.error("LinkClips requires at least 2 clips")
            return false
        end

        if args.dry_run then
            return true  -- Preview is valid
        end

        local clip_links = require('models.clip_link')
        local link_group_id, error_msg = clip_links.create_link_group(args.clips, db)

        if not link_group_id then
            log.error("LinkClips failed: %s", tostring(error_msg or "unknown error"))
            return false
        end

        command:set_parameter("link_group_id", link_group_id)
        log.event("Linked %d clips (group %s)", #args.clips, link_group_id:sub(1, 8))
        return true
    end

    local function undoer(command)
        local args = command:get_all_parameters()
        local link_group_id = args.link_group_id

        assert(link_group_id, "UnlinkClip.undo: missing link_group_id in undo args")

        -- Delete the entire link group
        local query = assert(db:prepare([[
            DELETE FROM clip_links WHERE link_group_id = ?
        ]]), "UnlinkClip.undo: failed to prepare DELETE query")

        query:bind_value(1, link_group_id)
        local result = query:exec()
        query:finalize()

        return result
    end

    executors["UnlinkClip"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            log.event("Executing UnlinkClip")
        end

        if not args.clip_id then
            log.error("UnlinkClip missing args.clip_id")
            return false
        end

        if args.dry_run then
            return true
        end

        local clip_links = require('models.clip_link')

        -- Save original link info for undo
        local link_group = clip_links.get_link_group(args.clip_id, db)
        if link_group then
            command:set_parameter("original_link_group", link_group)

            -- Find this clip's info in the group. clip_links.get_link_group
            -- returns rows with `clip_id` directly (not nested under .args).
            for _, link_info in ipairs(link_group) do
                if link_info.clip_id == args.clip_id then
                    command:set_parameters({
                        ["original_role"] = link_info.role,
                        ["original_time_offset"] = link_info.time_offset,
                    })
                    break
                end
            end
        end

        local success = clip_links.unlink_clip(args.clip_id, db)

        if success then
            log.event("Unlinked clip %s", args.clip_id:sub(1, 8))
        else
            log.error("Failed to unlink clip %s", args.clip_id:sub(1, 8))
        end

        return success
    end

    undoers["UnlinkClip"] = function(command)
        local args = command:get_all_parameters()
        local clip_id = args.clip_id


        if not clip_id or not args.original_link_group or #args.original_link_group == 0 then
            return true  -- Clip was not linked, nothing to restore
        end

        -- Restore the link
        local link_group_id = nil
        for _, link_info in ipairs(args.original_link_group) do
            if link_info.clip_id ~= clip_id then
                -- Find the existing link group ID from another clip
                local query = db:prepare([[
                    SELECT link_group_id FROM clip_links WHERE clip_id = ? LIMIT 1
                ]])
                if query then
                    query:bind_value(1, link_info.clip_id)
                    if query:exec() and query:next() then
                        link_group_id = query:value(0)
                    end
                    query:finalize()
                    if link_group_id then
                        break
                    end
                end
            end
        end

        if not link_group_id then
            -- The entire link group was deleted, recreate it
            local uuid = require('uuid')
            link_group_id = uuid.generate()
        end

        -- Re-insert this clip into the link group

        local time_offset = args.original_time_offset

        local insert_query = db:prepare([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES (?, ?, ?, ?, 1)
        ]])

        if not insert_query then
            return false
        end

        insert_query:bind_value(1, link_group_id)
        insert_query:bind_value(2, clip_id)
        insert_query:bind_value(3, args.original_role)
        insert_query:bind_value(4, time_offset)

        local result = insert_query:exec()
        insert_query:finalize()

        return result
    end

    executors["UnlinkClips"] = executors["UnlinkClip"]
    undoers["UnlinkClips"] = undoers["UnlinkClip"]

    -- Multi-style registration: each name gets its OWN spec entry. The
    -- prior single-style return registered `executor` (LinkClips) under
    -- whatever name triggered the load, overwriting the direct
    -- `executors["UnlinkClips"] = ...` assignment above with the LinkClips
    -- function. Dispatches to UnlinkClips then ran the LINK executor
    -- and failed the "≥2 clips" check.
    return {
        LinkClips   = { executor = executor,                   undoer = undoer,                   spec = LINK_SPEC },
        UnlinkClip  = { executor = executors["UnlinkClip"],    undoer = undoers["UnlinkClip"],    spec = UNLINK_SPEC },
        UnlinkClips = { executor = executors["UnlinkClips"],   undoer = undoers["UnlinkClips"],   spec = UNLINK_SPEC },
    }
end

return M
