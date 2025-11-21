local M = {}

local function set_error(set_last_error, message)
    if set_last_error then
        set_last_error(message)
    end
end

function M.register(command_executors, command_undoers, db, set_last_error)
    if not command_executors or not command_undoers or not db then
        return nil
    end

    local Clip = require("models.clip")

    local function delete_clip_with_metadata(clip_id)
        local prop_stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
        if prop_stmt then
            prop_stmt:bind_value(1, clip_id)
            prop_stmt:exec()
            prop_stmt:finalize()
        end

        local link_stmt = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
        if link_stmt then
            link_stmt:bind_value(1, clip_id)
            link_stmt:exec()
            link_stmt:finalize()
        end

        local clip_obj = Clip.load_optional(clip_id, db)
        if clip_obj then
            return clip_obj:delete(db)
        else
            local delete_stmt = db:prepare("DELETE FROM clips WHERE id = ?")
            if delete_stmt then
                delete_stmt:bind_value(1, clip_id)
                local ok = delete_stmt:exec()
                delete_stmt:finalize()
                return ok
            end
        end
        return true
    end

    command_executors["DeleteMasterClip"] = function(command)
        local master_clip_id = command:get_parameter("master_clip_id")
        if not master_clip_id or master_clip_id == "" then
            set_error(set_last_error, "DeleteMasterClip: Missing master_clip_id")
            return false
        end

        local clip = Clip.load_optional(master_clip_id, db)
        if not clip then
            set_error(set_last_error, "DeleteMasterClip: Master clip not found")
            return false
        end

        if clip.clip_kind ~= "master" then
            set_error(set_last_error, "DeleteMasterClip: Clip is not a master clip")
            return false
        end

        if clip.source_sequence_id and clip.source_sequence_id ~= "" then
            local ref_query = db:prepare([[
                SELECT COUNT(*) FROM clips
                WHERE parent_clip_id = ?
                  AND clip_kind = 'timeline'
                  AND (owner_sequence_id IS NULL OR owner_sequence_id <> ?)
            ]])
            if not ref_query then
                set_error(set_last_error, "DeleteMasterClip: Failed to prepare reference check")
                return false
            end
            ref_query:bind_value(1, master_clip_id)
            ref_query:bind_value(2, clip.source_sequence_id)
            local in_use = 0
            if ref_query:exec() and ref_query:next() then
                in_use = ref_query:value(0) or 0
            end
            ref_query:finalize()

            if in_use > 0 then
                set_error(set_last_error, "DeleteMasterClip: Clip still referenced in timeline")
                return false
            end
        end

        -- Remove timeline clips that belong to the master clip's source sequence
        local child_stmt = db:prepare("SELECT id FROM clips WHERE parent_clip_id = ?")
        local child_clip_ids = {}
        if child_stmt then
            child_stmt:bind_value(1, master_clip_id)
            if child_stmt:exec() then
                while child_stmt:next() do
                    table.insert(child_clip_ids, child_stmt:value(0))
                end
            end
            child_stmt:finalize()
        end

        for _, child_id in ipairs(child_clip_ids) do
            if not delete_clip_with_metadata(child_id) then
                set_error(set_last_error, "DeleteMasterClip: Failed to remove child clip")
                return false
            end
        end

        -- Remove tracks and snapshots for the master clip's source sequence
        local source_sequence_id = clip.source_sequence_id
        if source_sequence_id and source_sequence_id ~= "" then
            local delete_tracks = db:prepare("DELETE FROM tracks WHERE sequence_id = ?")
            if delete_tracks then
                delete_tracks:bind_value(1, source_sequence_id)
                delete_tracks:exec()
                delete_tracks:finalize()
            end

            local delete_snapshots = db:prepare("DELETE FROM snapshots WHERE sequence_id = ?")
            if delete_snapshots then
                delete_snapshots:bind_value(1, source_sequence_id)
                delete_snapshots:exec()
                delete_snapshots:finalize()
            end

            local delete_sequence_stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
            if delete_sequence_stmt then
                delete_sequence_stmt:bind_value(1, source_sequence_id)
                delete_sequence_stmt:exec()
                delete_sequence_stmt:finalize()
            end
        end

        local snapshot = {
            id = clip.id,
            project_id = clip.project_id,
            clip_kind = clip.clip_kind,
            name = clip.name,
            track_id = clip.track_id,
            media_id = clip.media_id,
            source_sequence_id = clip.source_sequence_id,
            parent_clip_id = clip.parent_clip_id,
            owner_sequence_id = clip.owner_sequence_id,
            start_value = clip.start_value,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out,
            enabled = clip.enabled,
            offline = clip.offline,
        }
        command:set_parameter("master_clip_snapshot", snapshot)

        local properties = {}
        local prop_query = db:prepare("SELECT id, property_name, property_value, property_type, default_value FROM properties WHERE clip_id = ?")
        if prop_query then
            prop_query:bind_value(1, master_clip_id)
            if prop_query:exec() then
                while prop_query:next() do
                    table.insert(properties, {
                        id = prop_query:value(0),
                        property_name = prop_query:value(1),
                        property_value = prop_query:value(2),
                        property_type = prop_query:value(3),
                        default_value = prop_query:value(4),
                    })
                end
            end
            prop_query:finalize()
        end
        command:set_parameter("master_clip_properties", properties)

        -- Remove metadata for the master clip itself
        if not delete_clip_with_metadata(master_clip_id) then
            set_error(set_last_error, "DeleteMasterClip: Failed to delete clip")
            return false
        end

        print(string.format("✅ Deleted master clip %s", clip.name or master_clip_id))
        return true
    end

    command_undoers["DeleteMasterClip"] = function(command)
        local snapshot = command:get_parameter("master_clip_snapshot")
        if not snapshot then
            set_error(set_last_error, "UndoDeleteMasterClip: Missing snapshot")
            return false
        end

        local restored = Clip.create(snapshot.name or "Master Clip", snapshot.media_id, {
            id = snapshot.id,
            project_id = snapshot.project_id,
            clip_kind = snapshot.clip_kind,
            track_id = snapshot.track_id,
            parent_clip_id = snapshot.parent_clip_id,
            owner_sequence_id = snapshot.owner_sequence_id,
            source_sequence_id = snapshot.source_sequence_id,
            start_value = snapshot.start_value,
            duration = snapshot.duration,
            source_in = snapshot.source_in,
            source_out = snapshot.source_out,
            enabled = snapshot.enabled ~= false,
            offline = snapshot.offline,
        })

        if not restored:save(db) then
            set_error(set_last_error, "UndoDeleteMasterClip: Failed to restore master clip")
            return false
        end

        local properties = command:get_parameter("master_clip_properties") or {}
        if #properties > 0 then
            local insert_prop = db:prepare("INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value) VALUES (?, ?, ?, ?, ?, ?)")
            if not insert_prop then
                set_error(set_last_error, "UndoDeleteMasterClip: Failed to prepare property restore")
                return false
            end
            for _, prop in ipairs(properties) do
                insert_prop:bind_value(1, prop.id)
                insert_prop:bind_value(2, snapshot.id)
                insert_prop:bind_value(3, prop.property_name)
                insert_prop:bind_value(4, prop.property_value)
                insert_prop:bind_value(5, prop.property_type)
                insert_prop:bind_value(6, prop.default_value)
                if not insert_prop:exec() then
                    insert_prop:finalize()
                    set_error(set_last_error, "UndoDeleteMasterClip: Failed to restore property")
                    return false
                end
            end
            insert_prop:finalize()
        end

        print(string.format("UNDO: Restored master clip %s", snapshot.name or snapshot.id))
        return true
    end

    return {
        executor = command_executors["DeleteMasterClip"],
        undoer = command_undoers["DeleteMasterClip"],
    }
end

return M
