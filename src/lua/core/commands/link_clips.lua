-- LinkClips and UnlinkClip commands
local M = {}

function M.register(executors, undoers, db)
    
    executors["LinkClips"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing LinkClips command")
        end

        local clips_to_link = command:get_parameter("clips")

        if not clips_to_link or #clips_to_link < 2 then
            print("ERROR: LinkClips requires at least 2 clips")
            return false
        end

        if dry_run then
            return true  -- Preview is valid
        end

        local clip_links = require('core.clip_links')
        local link_group_id, error_msg = clip_links.create_link_group(clips_to_link, db)

        if not link_group_id then
            print(string.format("ERROR: LinkClips failed: %s", error_msg or "unknown error"))
            return false
        end

        -- Store link group ID for undo
        command:set_parameter("link_group_id", link_group_id)

        print(string.format("✅ Linked %d clips (group %s)", #clips_to_link, link_group_id:sub(1,8)))
        return true
    end

    undoers["LinkClips"] = function(command)
        local link_group_id = command:get_parameter("link_group_id")

        if not link_group_id then
            return false
        end

        -- Delete the entire link group
        local query = db:prepare([[
            DELETE FROM clip_links WHERE link_group_id = ?
        ]])

        if not query then
            return false
        end

        query:bind_value(1, link_group_id)
        local result = query:exec()
        query:finalize()

        return result
    end

    executors["UnlinkClip"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing UnlinkClip command")
        end

        local clip_id = command:get_parameter("clip_id")

        if not clip_id then
            print("ERROR: UnlinkClip missing clip_id")
            return false
        end

        if dry_run then
            return true
        end

        local clip_links = require('core.clip_links')

        -- Save original link info for undo
        local link_group = clip_links.get_link_group(clip_id, db)
        if link_group then
            command:set_parameter("original_link_group", link_group)

            -- Find this clip's info in the group
            for _, link_info in ipairs(link_group) do
                if link_info.clip_id == clip_id then
                    command:set_parameter("original_role", link_info.role)
                    command:set_parameter("original_time_offset", link_info.time_offset)
                    break
                end
            end
        end

        local success = clip_links.unlink_clip(clip_id, db)

        if success then
            print(string.format("✅ Unlinked clip %s", clip_id:sub(1,8)))
        else
            print(string.format("ERROR: Failed to unlink clip %s", clip_id:sub(1,8)))
        end

        return success
    end

    undoers["UnlinkClip"] = function(command)
        local clip_id = command:get_parameter("clip_id")
        local original_link_group = command:get_parameter("original_link_group")

        if not clip_id or not original_link_group or #original_link_group == 0 then
            return true  -- Clip was not linked, nothing to restore
        end

        -- Restore the link
        local link_group_id = nil
        for _, link_info in ipairs(original_link_group) do
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
        local role = command:get_parameter("original_role")
        local time_offset = command:get_parameter("original_time_offset") or 0

        local insert_query = db:prepare([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES (?, ?, ?, ?, 1)
        ]])

        if not insert_query then
            return false
        end

        insert_query:bind_value(1, link_group_id)
        insert_query:bind_value(2, clip_id)
        insert_query:bind_value(3, role)
        insert_query:bind_value(4, time_offset)

        local result = insert_query:exec()
        insert_query:finalize()

        return result
    end

    executors["UnlinkClips"] = executors["UnlinkClip"]
    undoers["UnlinkClips"] = undoers["UnlinkClip"]

    return {executor = executors["LinkClips"], undoer = undoers["LinkClips"]}
end

return M
