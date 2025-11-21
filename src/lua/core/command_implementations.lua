-- Command Implementations for Command Manager
-- Extracted for Rule 2.27 (Short Functions and Logical File Splitting)
--
-- Contains all 29 command executors and their undoers.
-- This file defines the actual command logic, while command_manager.lua
-- handles execution flow, undo/redo, and replay infrastructure.

local M = {}
M.exported_commands = {
    DeleteSequence = require("core.commands.delete_sequence"),
    DeleteMasterClip = require("core.commands.delete_master_clip"),
}

-- Register all command executors and undoers
-- Parameters:
--   command_executors: table to populate with executor functions
--   command_undoers: table to populate with undoer functions
--   db: database connection reference (captured by closures)
function M.register_commands(command_executors, command_undoers, command_redoers_or_db, db_or_setter, set_last_error_fn)
    local command_redoers
    local db
    if type(command_redoers_or_db) == "table" and (db_or_setter ~= nil or set_last_error_fn ~= nil) then
        command_redoers = command_redoers_or_db
        db = db_or_setter
    else
        command_redoers = {}
        db = command_redoers_or_db
        set_last_error_fn = db_or_setter
    end

    local frame_utils = require('core.frame_utils')
    local json = require("dkjson")
    local uuid = require("uuid")
    local database = require("core.database")
    local tag_service = require("core.tag_service")
    local ui_constants = require("core.ui_constants")
    local Sequence = require("models.sequence")
    local Clip = require("models.clip")
    local clip_mutator = require("core.clip_mutator")
    local set_last_error = set_last_error_fn or function(_) end
    command_redoers = command_redoers or {}
    local TIMELINE_CLIP_KIND = "timeline"

    local function trim_string(value)
        if type(value) ~= "string" then
            return ""
        end
        local stripped = value:match("^%s*(.-)%s*$")
        if stripped == nil then
            return ""
        end
        return stripped
    end

    local function reload_timeline(sequence_id)
        local ok, timeline_state = pcall(require, 'ui.timeline.timeline_state')
        if not ok or not timeline_state or not timeline_state.reload_clips then
            return
        end
        local target_sequence = sequence_id
        if (not target_sequence or target_sequence == "") and timeline_state.get_sequence_id then
            target_sequence = timeline_state.get_sequence_id()
        end
        if target_sequence and target_sequence ~= "" then
            timeline_state.reload_clips(target_sequence)
        end
    end

    local function encode_property_json(raw)
        if raw == nil or raw == "" then
            local encoded = json.encode({ value = nil })
            return encoded
        end
        if type(raw) == "string" then
            return raw
        end
        local encoded, err = json.encode({ value = raw })
        if not encoded then
            return json.encode({ value = nil })
        end
        return encoded
    end

    local function ensure_timeline_mutation_bucket(command, sequence_id)
        if not sequence_id then
            if command and command.type then
                print(string.format("WARNING: %s: Missing sequence_id for timeline mutation bucket", tostring(command.type)))
            end
            return nil
        end
        local mutations = command:get_parameter("__timeline_mutations")
        if not mutations then
            mutations = {}
            command:set_parameter("__timeline_mutations", mutations)
        elseif mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
            local existing_bucket = mutations
            mutations = {[existing_bucket.sequence_id or sequence_id] = existing_bucket}
            command:set_parameter("__timeline_mutations", mutations)
        end

        if not mutations[sequence_id] then
            mutations[sequence_id] = {
                sequence_id = sequence_id,
                inserts = {},
                updates = {},
                deletes = {}
            }
        end
        return mutations[sequence_id]
    end

    local function clip_update_payload(source, fallback_sequence_id)
        if not source or not source.id then
            return nil
        end
        local track_sequence_id = source.owner_sequence_id or source.track_sequence_id or fallback_sequence_id
        if not track_sequence_id then
            return nil
        end
        return {
            clip_id = source.id,
            track_id = source.track_id,
            track_sequence_id = track_sequence_id,
            start_value = source.start_value,
            duration = source.duration,
            source_in = source.source_in,
            source_out = source.source_out,
            enabled = source.enabled ~= false
        }
    end

    local function clip_insert_payload(source, fallback_sequence_id)
        if not source or not source.id then
            return nil
        end
        local track_sequence_id = source.owner_sequence_id or source.track_sequence_id or fallback_sequence_id
        if not track_sequence_id then
            return nil
        end
        local label = source.label or source.name
        if (not label or label == "") and source.id then
            label = "Clip " .. source.id:sub(1, 8)
        end
        return {
            id = source.id,
            clip_id = source.id,
            project_id = source.project_id,
            clip_kind = source.clip_kind,
            name = source.name,
            label = label,
            track_id = source.track_id,
            track_sequence_id = track_sequence_id,
            owner_sequence_id = source.owner_sequence_id or track_sequence_id,
            media_id = source.media_id,
            source_sequence_id = source.source_sequence_id,
            parent_clip_id = source.parent_clip_id,
            start_value = source.start_value,
            duration = source.duration,
            source_in = source.source_in,
            source_out = source.source_out,
            enabled = source.enabled ~= false,
            offline = source.offline == true
        }
    end

    local function add_update_mutation(command, sequence_id, update)
        if not update then
            return
        end
        local bucket = ensure_timeline_mutation_bucket(command, sequence_id)
        if not bucket then
            return
        end
        if update[1] then
            for _, entry in ipairs(update) do
                table.insert(bucket.updates, entry)
            end
        else
            table.insert(bucket.updates, update)
        end
        command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
    end

    local function iter_mutation_buckets(mutations)
        if not mutations then
            return {}
        end
        if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
            return {mutations}
        end
        local buckets = {}
        for _, bucket in pairs(mutations) do
            if type(bucket) == "table" and (bucket.sequence_id or bucket.inserts or bucket.updates or bucket.deletes) then
                table.insert(buckets, bucket)
            end
        end
        return buckets
    end

    local function flush_timeline_mutations(command, default_sequence_id)
        if not command then
            return
        end
        local mutations = command:get_parameter("__timeline_mutations")
        if not mutations then
            return
        end
        local timeline_state = require('ui.timeline.timeline_state')
        if not timeline_state or not timeline_state.apply_mutations then
            return
        end
        local buckets = iter_mutation_buckets(mutations)
        for _, bucket in ipairs(buckets) do
            local sequence_id = bucket.sequence_id
                or command:get_parameter("sequence_id")
                or default_sequence_id
                or (timeline_state.get_sequence_id and timeline_state.get_sequence_id())
            if sequence_id then
                bucket.sequence_id = sequence_id
            end
            local applied = timeline_state.apply_mutations(sequence_id, bucket)
            if not applied and timeline_state.reload_clips then
                timeline_state.reload_clips(sequence_id)
            end
        end
        command:clear_parameter("__timeline_mutations")
    end

    local function record_clip_enabled_mutation(command, clip)
        if not clip then
            return
        end
        local mutation_sequence = command:get_parameter("sequence_id") or clip.owner_sequence_id or clip.track_sequence_id
        local update_payload = clip_update_payload(clip, mutation_sequence)
        if update_payload then
            add_update_mutation(command, update_payload.track_sequence_id or mutation_sequence, update_payload)
        end
    end

    local function add_insert_mutation(command, sequence_id, clip)
        if not clip then
            return
        end
        local bucket = ensure_timeline_mutation_bucket(command, sequence_id)
        if not bucket then
            return
        end
        if clip[1] then
            for _, entry in ipairs(clip) do
                table.insert(bucket.inserts, entry)
            end
        else
            table.insert(bucket.inserts, clip)
        end
        command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
    end

    local function add_delete_mutation(command, sequence_id, clip_ids)
        if not clip_ids then
            return
        end
        local bucket = ensure_timeline_mutation_bucket(command, sequence_id)
        if not bucket then
            return
        end
        if type(clip_ids) == "table" then
            for _, clip_id in ipairs(clip_ids) do
                table.insert(bucket.deletes, clip_id)
            end
        else
            table.insert(bucket.deletes, clip_ids)
        end
        command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
    end

    local function merge_timeline_mutations(target_command, source_mutations)
        if not target_command or not source_mutations then
            return
        end

        local function merge_bucket(bucket)
            if not bucket or not bucket.sequence_id then
                return
            end
            if bucket.inserts and #bucket.inserts > 0 then
                add_insert_mutation(target_command, bucket.sequence_id, bucket.inserts)
            end
            if bucket.updates and #bucket.updates > 0 then
                add_update_mutation(target_command, bucket.sequence_id, bucket.updates)
            end
            if bucket.deletes and #bucket.deletes > 0 then
                add_delete_mutation(target_command, bucket.sequence_id, bucket.deletes)
            end
        end

        if source_mutations.sequence_id or source_mutations.inserts or source_mutations.updates or source_mutations.deletes then
            merge_bucket(source_mutations)
        else
            for _, bucket in pairs(source_mutations) do
                merge_bucket(bucket)
            end
        end
    end

    local function ensure_master_clip_for_media(command, media_id, opts)
        if not media_id or media_id == "" then
            return nil
        end
        opts = opts or {}
        local project_id_value = opts.project_id
            or command:get_parameter("project_id")
            or command.project_id
            or "default_project"

        local lookup = db:prepare([[
            SELECT id
            FROM clips
            WHERE clip_kind = 'master'
              AND media_id = ?
              AND (project_id = ? OR project_id IS NULL)
            LIMIT 1
        ]])
        if lookup then
            lookup:bind_value(1, media_id)
            lookup:bind_value(2, project_id_value)
            if lookup:exec() and lookup:next() then
                local existing_id = lookup:value(0)
                lookup:finalize()
                return existing_id
            end
            lookup:finalize()
        end

        local duration = math.max(opts.duration or 1000, 1)
        local source_in = opts.source_in or 0
        local source_out = opts.source_out or (source_in + duration)
        if source_out <= source_in then
            source_out = source_in + duration
        end

        local master_clip = Clip.create(opts.name or "Master Clip", media_id, {
            project_id = project_id_value,
            clip_kind = "master",
            start_value = 0,
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            enabled = true,
            offline = false
        })
        if not master_clip then
            return nil
        end
        if not master_clip:save(db, {skip_occlusion = true}) then
            return nil
        end
        return master_clip.id
    end

    local function record_occlusion_actions(command, sequence_id, actions)
        if not actions or #actions == 0 then
            return
        end
        for _, action in ipairs(actions) do
            if action.type == "delete" and action.clip and action.clip.id then
                add_delete_mutation(command, sequence_id, action.clip.id)
            elseif action.type == "trim" and action.after then
                local update = clip_update_payload(action.after, sequence_id)
                if update then
                    add_update_mutation(command, update.track_sequence_id or sequence_id, update)
                end
            elseif action.type == "insert" and action.clip then
                local insert_payload = clip_insert_payload(action.clip, sequence_id)
                if insert_payload then
                    add_insert_mutation(command, insert_payload.track_sequence_id or sequence_id, insert_payload)
                end
            end
        end
    end

    local function resolve_sequence_for_track(sequence_id_param, track_id)
        local resolved = sequence_id_param
        if resolved and resolved ~= "" then
            return resolved
        end
        if not track_id or track_id == "" then
            return resolved
        end
        local stmt = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
        if not stmt then
            return resolved
        end
        stmt:bind_value(1, track_id)
        if stmt:exec() and stmt:next() then
            resolved = stmt:value(0) or resolved
        end
        stmt:finalize()
        return resolved
    end

    local function fetch_clip_properties_for_copy(clip_id)
        local props = {}
        if not clip_id or clip_id == "" then
            return props
        end

        local query = db:prepare("SELECT property_name, property_value, property_type, default_value FROM properties WHERE clip_id = ?")
        if not query then
            return props
        end
        query:bind_value(1, clip_id)

        if query:exec() then
            while query:next() do
                local property_name = query:value(0)
                local property_value = encode_property_json(query:value(1))
                local property_type = query:value(2) or "STRING"
                local default_value = query:value(3)
                if default_value == nil or default_value == "" then
                    default_value = json.encode({ value = nil })
                end

                table.insert(props, {
                    id = uuid.generate(),
                    property_name = property_name,
                    property_value = property_value,
                    property_type = property_type,
                    default_value = default_value
                })
            end
        end
        query:finalize()
        return props
    end

    local function perform_item_rename(target_type, target_id, new_name, project_id)
        if not target_type or target_type == "" then
            return false, "RenameItem: Missing target_type"
        end
        if not target_id or target_id == "" then
            return false, "RenameItem: Missing target_id"
        end

        new_name = trim_string(new_name)
        if new_name == "" then
            return false, "RenameItem: New name cannot be empty"
        end

        project_id = project_id or "default_project"

        if target_type == "master_clip" then
            local clip = Clip.load_optional(target_id, db)
            if not clip then
                return false, "RenameItem: Master clip not found"
            end
            local previous_name = clip.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            clip.name = new_name
            if not clip:save(db, {skip_occlusion = true}) then
                return false, "RenameItem: Failed to save master clip"
            end
            local update_stmt = db:prepare([[
                UPDATE clips
                SET name = ?
                WHERE parent_clip_id = ? AND clip_kind = 'timeline'
            ]])
            if not update_stmt then
                return false, "RenameItem: Failed to prepare timeline rename"
            end
            update_stmt:bind_value(1, new_name)
            update_stmt:bind_value(2, clip.id)
            if not update_stmt:exec() then
                update_stmt:finalize()
                return false, "RenameItem: Failed to update timeline clips"
            end
            update_stmt:finalize()
            reload_timeline(clip.owner_sequence_id or clip.source_sequence_id)
            return true, previous_name
        elseif target_type == "sequence" then
            local sequence = Sequence.load(target_id, db)
            if not sequence then
                return false, "RenameItem: Sequence not found"
            end
            local previous_name = sequence.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            sequence.name = new_name
            if not sequence:save(db) then
                return false, "RenameItem: Failed to save sequence"
            end
            reload_timeline(sequence.id)
            return true, previous_name
        elseif target_type == "bin" then
            local ok, result = tag_service.rename_bin(project_id, target_id, new_name)
            if not ok then
                return false, result
            end
            return true, result.previous_name or new_name
        else
            return false, "RenameItem: Unsupported target type"
        end

        return true, new_name
    end

    command_executors["NewBin"] = function(command)
        command:set_parameter("__skip_sequence_replay", true)
        local project_id = command:get_parameter("project_id") or "default_project"
        local bin_name = trim_string(command:get_parameter("name"))
        if bin_name == "" then
            bin_name = "New Bin"
        end

        local bin_id = command:get_parameter("bin_id")
        if not bin_id or bin_id == "" then
            bin_id = uuid.generate()
            command:set_parameter("bin_id", bin_id)
        end

        local ok, result = tag_service.create_bin(project_id, {
            id = bin_id,
            name = bin_name,
            parent_id = command:get_parameter("parent_id")
        })
        if not ok then
            set_last_error("NewBin: " .. tostring(result))
            return false
        end

        command:set_parameter("bin_definition", result)
        return true
    end

    command_undoers["NewBin"] = function(command)
        local project_id = command:get_parameter("project_id") or "default_project"
        local bin_id = command:get_parameter("bin_id")
        if not bin_id or bin_id == "" then
            set_last_error("UndoNewBin: Missing bin_id parameter")
            return false
        end

        local ok, err = tag_service.remove_bin(project_id, bin_id)
        if not ok then
            set_last_error("UndoNewBin: " .. tostring(err))
            return false
        end

        return true
    end

    command_executors["DeleteBin"] = function(command)
        command:set_parameter("__skip_sequence_replay", true)
        local project_id = command:get_parameter("project_id") or "default_project"
        local bin_id = command:get_parameter("bin_id")
        if not bin_id or bin_id == "" then
            set_last_error("DeleteBin: Missing bin_id")
            return false
        end

        local ok, result = tag_service.remove_bin(project_id, bin_id)
        if not ok then
            set_last_error("DeleteBin: " .. tostring(result))
            return false
        end

        command:set_parameter("deleted_bin_definition", result.definition)
        command:set_parameter("child_parent_snapshot", result.child_snapshot)
        command:set_parameter("bin_insert_index", result.insert_index)
        return true
    end

    command_undoers["DeleteBin"] = function(command)
        local project_id = command:get_parameter("project_id") or "default_project"
        local target_bin = command:get_parameter("deleted_bin_definition")
        if not target_bin then
            set_last_error("UndoDeleteBin: Missing bin definition")
            return false
        end

        local child_snapshot = command:get_parameter("child_parent_snapshot") or {}
        local insert_index = command:get_parameter("bin_insert_index")

        local ok, err = tag_service.restore_bin(project_id, target_bin, insert_index, child_snapshot)
        if not ok then
            set_last_error("UndoDeleteBin: " .. tostring(err))
            return false
        end

        return true
    end

    local function snapshot_properties_for_clip(clip_id)
        local props = {}
        if not clip_id or clip_id == "" then
            return props
        end

        local query = db:prepare("SELECT id, property_name, property_value, property_type, default_value FROM properties WHERE clip_id = ?")
        if not query then
            return props
        end
        query:bind_value(1, clip_id)

        if query:exec() then
            while query:next() do
                table.insert(props, {
                    id = query:value(0),
                    property_name = query:value(1),
                    property_value = query:value(2),
                    property_type = query:value(3),
                    default_value = query:value(4)
                })
            end
        end
        query:finalize()
        return props
    end

    local function ensure_copied_properties(command, master_clip_id)
        if not master_clip_id or master_clip_id == "" then
            return {}
        end
        local stored = command:get_parameter("copied_properties")
        if type(stored) == "table" and #stored > 0 then
            return stored
        end
        local props = fetch_clip_properties_for_copy(master_clip_id)
        command:set_parameter("copied_properties", props)
        return props
    end

    local function insert_properties_for_clip(clip_id, properties)
        if not properties or #properties == 0 then
            return true
        end

        local stmt = db:prepare([[
            INSERT OR REPLACE INTO properties
            (id, clip_id, property_name, property_value, property_type, default_value)
            VALUES (?, ?, ?, ?, ?, ?)
        ]])

        if not stmt then
            print(string.format("WARNING: Failed to prepare property insert for clip %s", tostring(clip_id)))
            return false
        end

        for _, prop in ipairs(properties) do
            stmt:bind_value(1, prop.id or uuid.generate())
            stmt:bind_value(2, clip_id)
            stmt:bind_value(3, prop.property_name)
            stmt:bind_value(4, encode_property_json(prop.property_value))
            stmt:bind_value(5, prop.property_type or "STRING")
            stmt:bind_value(6, encode_property_json(prop.default_value))

            if not stmt:exec() then
                local err = "unknown"
                if stmt.last_error then
                    local ok, msg = pcall(stmt.last_error, stmt)
                    if ok and msg and msg ~= "" then
                        err = msg
                    end
                end
                print(string.format("WARNING: Failed to insert property %s for clip %s: %s",
                    tostring(prop.property_name), tostring(clip_id), tostring(err)))
                stmt:finalize()
                return false
            end
            stmt:reset()
            stmt:clear_bindings()
        end

        stmt:finalize()
        return true
    end

    local function delete_properties_for_clip(clip_id)
        if not clip_id or clip_id == "" then
            return true
        end
        local stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
        if not stmt then
            return false
        end
        stmt:bind_value(1, clip_id)
        local ok = stmt:exec()
        stmt:finalize()
        return ok
    end

    local function delete_properties_by_list(properties)
        if not properties or #properties == 0 then
            return true
        end
        local stmt = db:prepare("DELETE FROM properties WHERE id = ?")
        if not stmt then
            return false
        end
        for _, prop in ipairs(properties) do
            if prop.id then
                stmt:bind_value(1, prop.id)
                if not stmt:exec() then
                    stmt:finalize()
                    return false
                end
                stmt:reset()
                stmt:clear_bindings()
            end
        end
        stmt:finalize()
        return true
    end

    command_executors["DuplicateMasterClip"] = function(command)
        local snapshot = command:get_parameter("clip_snapshot")
        if type(snapshot) ~= "table" then
            set_last_error("DuplicateMasterClip: Missing clip_snapshot parameter")
            return false
        end

        local media_id = snapshot.media_id
        if not media_id or media_id == "" then
            set_last_error("DuplicateMasterClip: Snapshot missing media_id")
            return false
        end

        local project_id = command:get_parameter("project_id") or snapshot.project_id or "default_project"
        local target_bin_id = command:get_parameter("bin_id")
        if target_bin_id == "" then
            target_bin_id = nil
        end

        local new_clip_id = command:get_parameter("new_clip_id")
        if not new_clip_id or new_clip_id == "" then
            new_clip_id = uuid.generate()
            command:set_parameter("new_clip_id", new_clip_id)
        end

        local clip_name = command:get_parameter("name") or snapshot.name or "Master Clip Copy"
        local duration = snapshot.duration or ((snapshot.source_out or 0) - (snapshot.source_in or 0))
        if duration <= 0 then
            duration = 1
        end

        local clip_opts = {
            id = new_clip_id,
            project_id = project_id,
            clip_kind = "master",
            source_sequence_id = snapshot.source_sequence_id,
            start_value = snapshot.start_value or 0,
            duration = duration,
            source_in = snapshot.source_in or 0,
            source_out = snapshot.source_out or ((snapshot.source_in or 0) + duration),
            enabled = snapshot.enabled ~= false,
            offline = snapshot.offline == true,
        }

        local clip = Clip.create(clip_name, media_id, clip_opts)
        command:set_parameter("project_id", project_id)

        local ok, actions = clip:save(db, {skip_occlusion = true})
        if not ok then
            set_last_error("DuplicateMasterClip: Failed to save duplicated clip")
            return false
        end
        if actions and #actions > 0 then
            command:set_parameter("occlusion_actions", actions)
        end

        local copied_properties = command:get_parameter("copied_properties")
        if type(copied_properties) == "table" and #copied_properties > 0 then
            delete_properties_for_clip(new_clip_id)
            insert_properties_for_clip(new_clip_id, copied_properties)
        end

        if target_bin_id and not database.assign_master_clip_to_bin(project_id, new_clip_id, target_bin_id) then
            print(string.format("WARNING: DuplicateMasterClip: Failed to persist bin assignment for %s", new_clip_id))
        end

        print(string.format("✅ Duplicated master clip '%s' → %s", tostring(snapshot.name or media_id), new_clip_id))
        return true
    end

    command_undoers["DuplicateMasterClip"] = function(command)
        local clip_id = command:get_parameter("new_clip_id")
        if not clip_id or clip_id == "" then
            set_last_error("UndoDuplicateMasterClip: Missing new_clip_id")
            return false
        end

        local project_id = command:get_parameter("project_id") or "default_project"
        local clip = Clip.load_optional(clip_id, db)
        if clip then
            delete_properties_for_clip(clip_id)
            if not clip:delete(db) then
                set_last_error("UndoDuplicateMasterClip: Failed to delete duplicated clip")
                return false
            end
        end

        database.assign_master_clip_to_bin(project_id, clip_id, nil)

        return true
    end

    local function resolve_sequence_id_for_edges(command, primary_edge, edge_list)
        local provided = command:get_parameter("sequence_id")

        local function lookup_sequence_id(edge)
            if not edge or not edge.clip_id or edge.clip_id == "" then
                return nil
            end

            local stmt = db:prepare([[
                SELECT t.sequence_id
                FROM clips c
                JOIN tracks t ON c.track_id = t.id
                WHERE c.id = ?
            ]])

            if not stmt then
                return nil
            end

            stmt:bind_value(1, edge.clip_id)
            local sequence_id = nil
            if stmt:exec() and stmt:next() then
                sequence_id = stmt:value(0)
            end
            stmt:finalize()
            return sequence_id
        end

        local resolved = lookup_sequence_id(primary_edge)
        if not resolved and edge_list then
            for _, edge in ipairs(edge_list) do
                resolved = lookup_sequence_id(edge)
                if resolved then
                    break
                end
            end
        end

        if not resolved or resolved == "" then
            resolved = provided
        end

        if not resolved or resolved == "" then
            resolved = "default_sequence"
        end

        if resolved ~= provided then
            command:set_parameter("sequence_id", resolved)
        end

        return resolved
    end

local function restore_clip_state(state)
        if not state then
            return
        end
    if type(state.id) == "string" and state.id:find("^temp_gap_") then
        return nil
    end
        local Clip = require('models.clip')
        local clip = Clip.load_optional(state.id, db)
    if not clip then
        clip = Clip.create(state.name or 'Restored Clip', state.media_id, {
            id = state.id,
            project_id = state.project_id,
            clip_kind = state.clip_kind,
            track_id = state.track_id,
            parent_clip_id = state.parent_clip_id,
            owner_sequence_id = state.owner_sequence_id,
            source_sequence_id = state.source_sequence_id,
            start_value = state.start_value,
            duration = state.duration,
            source_in = state.source_in,
            source_out = state.source_out,
            enabled = state.enabled ~= false,
            offline = state.offline,
        })
    else
        clip.project_id = state.project_id or clip.project_id
        clip.clip_kind = state.clip_kind or clip.clip_kind
        clip.track_id = state.track_id or clip.track_id
        clip.parent_clip_id = state.parent_clip_id
        clip.owner_sequence_id = state.owner_sequence_id or clip.owner_sequence_id
        clip.source_sequence_id = state.source_sequence_id or clip.source_sequence_id
        clip.start_value = state.start_value
        clip.duration = state.duration
        clip.duration_value = state.duration
        clip.source_in = state.source_in
        clip.source_in_value = state.source_in
        clip.source_out = state.source_out
        clip.source_out_value = state.source_out
        clip.enabled = state.enabled ~= false
        clip.offline = state.offline or false
    end
    clip.media_id = state.media_id
    clip:restore_without_occlusion(db)
    return clip
end

local function apply_clip_state_list(command, states, default_sequence_id)
    if not states or #states == 0 then
        return
    end
    for _, state in ipairs(states) do
        local restored = restore_clip_state(state)
        if restored then
            local payload = clip_update_payload(restored, default_sequence_id or restored.owner_sequence_id or restored.track_sequence_id)
            if payload then
                add_update_mutation(command, payload.track_sequence_id or default_sequence_id, payload)
            end
        end
    end
end

local function delete_clips_by_id(command, sequence_id, clip_ids)
    if not clip_ids or #clip_ids == 0 then
        return
    end
    local Clip = require('models.clip')
    for _, clip_id in ipairs(clip_ids) do
        local clip = Clip.load_optional(clip_id, db)
        if clip then
            delete_properties_for_clip(clip_id)
            if clip:delete(db) then
                add_delete_mutation(command, sequence_id, clip_id)
            end
        end
    end
end

local function load_sequence_track_ids(sequence_id)
    if not sequence_id or sequence_id == "" then
        return {}
    end
    local ids = {}
    local query = db:prepare("SELECT id FROM tracks WHERE sequence_id = ?")
    if not query then
        return ids
    end
    query:bind_value(1, sequence_id)
    if query:exec() then
        while query:next() do
            table.insert(ids, query:value(0))
        end
    end
    query:finalize()
    return ids
end

    local function revert_occlusion_actions(actions, command, sequence_id)
        if not actions or #actions == 0 then
            return
        end
        for i = #actions, 1, -1 do
            local action = actions[i]
            if action.type == 'trim' then
                local restored = restore_clip_state(action.before)
                if restored and command then
                    local payload = clip_update_payload(restored, sequence_id or restored.owner_sequence_id or restored.track_sequence_id)
                    if payload then
                        add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
                    end
                end
            elseif action.type == 'delete' then
                local restored = restore_clip_state(action.clip or action.before)
                if restored and command then
                    local payload = clip_insert_payload(restored, sequence_id or restored.owner_sequence_id or restored.track_sequence_id)
                    if payload then
                        add_insert_mutation(command, payload.track_sequence_id or sequence_id, payload)
                    end
                end
            elseif action.type == 'insert' then
                local state = action.clip
                if state then
                    local clip = Clip.load_optional(state.id, db)
                    if clip and clip:delete(db) and command then
                        add_delete_mutation(command, sequence_id or state.owner_sequence_id or state.track_sequence_id, state.id)
                    end
                end
            end
        end
    end


local function capture_clip_state(clip)
    if not clip then
        return nil
    end
    return {
        id = clip.id,
        track_id = clip.track_id,
        media_id = clip.media_id,
        start_value = clip.start_value,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        enabled = clip.enabled
    }
end

local function normalize_segments(segments)
    if not segments or #segments == 0 then
        return {}
    end

    table.sort(segments, function(a, b)
        if a.start_value == b.start_value then
            return (a.duration or 0) < (b.duration or 0)
        end
        return (a.start_value or 0) < (b.start_value or 0)
    end)

    local merged = {}
    for _, seg in ipairs(segments) do
        local start_value = seg.start_value or 0
        local duration = math.max(0, seg.duration or 0)
        local end_time = start_value + duration
        if end_time > start_value then
            local last = merged[#merged]
            if last and start_value <= last.end_time then
                if end_time > last.end_time then
                    last.end_time = end_time
                    last.duration = last.end_time - last.start_value
                end
            else
                table.insert(merged, {
                    start_value = start_value,
                    end_time = end_time,
                    duration = duration
                })
            end
        end
    end

    return merged
end

-- Command type implementations
command_executors["CreateProject"] = function(command)
    print("Executing CreateProject command")

    local name = command:get_parameter("name")
    if not name or name == "" then
        print("WARNING: CreateProject: Missing required 'name' parameter")
        return false
    end

    local Project = require('models.project')
    local project = Project.create(name)

    command:set_parameter("project_id", project.id)

    if project:save(db) then
        print(string.format("Created project: %s with ID: %s", name, project.id))
        return true
    else
        print(string.format("Failed to save project: %s", name))
        return false
    end
end

command_executors["LoadProject"] = function(command)
    print("Executing LoadProject command")

    local project_id = command:get_parameter("project_id")
    if not project_id or project_id == "" then
        print("WARNING: LoadProject: Missing required 'project_id' parameter")
        return false
    end

    local Project = require('models.project')
    local project = Project.load(project_id, db)
    if not project or project.id == "" then
        print(string.format("Failed to load project: %s", project_id))
        return false
    end

    print(string.format("Loaded project: %s", project.name))
    return true
end

command_executors["CreateSequence"] = function(command)
    print("Executing CreateSequence command")

    local name = command:get_parameter("name")
    local project_id = command:get_parameter("project_id")
    local frame_rate = command:get_parameter("frame_rate")
    local width = command:get_parameter("width")
    local height = command:get_parameter("height")

    if not name or name == "" or not project_id or project_id == "" or not frame_rate or frame_rate <= 0 then
        print("WARNING: CreateSequence: Missing required parameters")
        return false
    end

    local Sequence = require('models.sequence')
    local Track = require('models.track')

    local MIN_TRACK_HEIGHT = 24
    local DEFAULT_TRACK_HEIGHT = (ui_constants and ui_constants.TIMELINE and ui_constants.TIMELINE.TRACK_HEIGHT) or 50
    local TRACK_TEMPLATE_KEY = "track_height_template"

    local function normalize_height(value)
        if type(value) ~= "number" then
            return DEFAULT_TRACK_HEIGHT
        end
        local clamped = math.floor(value)
        if clamped < MIN_TRACK_HEIGHT then
            clamped = MIN_TRACK_HEIGHT
        end
        return clamped
    end

    local function seed_default_tracks(sequence_id, project_id)
        local template = nil
        if database.get_project_setting then
            template = database.get_project_setting(project_id, TRACK_TEMPLATE_KEY)
        end
        local template_video = type(template) == "table" and template.video or {}
        local template_audio = type(template) == "table" and template.audio or {}

        local definitions = {
            {builder = Track.create_video, label = "V1", index = 1, kind = "video"},
            {builder = Track.create_video, label = "V2", index = 2, kind = "video"},
            {builder = Track.create_video, label = "V3", index = 3, kind = "video"},
            {builder = Track.create_audio, label = "A1", index = 1, kind = "audio"},
            {builder = Track.create_audio, label = "A2", index = 2, kind = "audio"},
            {builder = Track.create_audio, label = "A3", index = 3, kind = "audio"},
        }

        local height_map = {}

        for _, def in ipairs(definitions) do
            local track = def.builder(def.label, sequence_id, {
                index = def.index,
                db = db
            })
            if not track or not track:save(db) then
                return false, string.format("CreateSequence: Failed to create track %s", def.label)
            end

            local template_source = def.kind == "video" and template_video or template_audio
            local desired_height = template_source and template_source[def.index] or nil
            height_map[track.id] = normalize_height(desired_height)
        end

        if database.set_sequence_track_heights then
            database.set_sequence_track_heights(sequence_id, height_map)
        end

        return true
    end

    local sequence = Sequence.create(name, project_id, frame_rate, width, height)

    command:set_parameter("sequence_id", sequence.id)

    if not sequence:save(db) then
        print(string.format("Failed to save sequence: %s", name))
        return false
    end

    local seeded, seed_err = seed_default_tracks(sequence.id, project_id)
    if not seeded then
        print(string.format("ERROR: %s", seed_err or "CreateSequence: Failed to seed default tracks"))
        return false
    end

    print(string.format("Created sequence: %s with ID: %s", name, sequence.id))
    local metadata_bucket = ensure_timeline_mutation_bucket(command, sequence.id)
    if metadata_bucket then
        metadata_bucket.sequence_meta = metadata_bucket.sequence_meta or {}
        table.insert(metadata_bucket.sequence_meta, {
            action = "created",
            sequence_id = sequence.id,
            project_id = project_id,
            name = name
        })
    end
    command:set_parameter("__allow_empty_mutations", true)
    return true
end

-- BatchCommand: Execute multiple commands as a single undo unit
-- Wraps N commands into one transaction for atomic undo/redo
command_executors["BatchCommand"] = function(command)
    print("Executing BatchCommand")

    local commands_json = command:get_parameter("commands_json")
    if not commands_json or commands_json == "" then
        print("ERROR: BatchCommand: No commands provided")
        return false
    end

    -- Parse JSON array of command specs
    local json = require("dkjson")
    local command_specs, parse_err = json.decode(commands_json)
    if not command_specs then
        print(string.format("ERROR: BatchCommand: Failed to parse commands JSON: %s", parse_err or "unknown"))
        return false
    end

    local batch_project_id = command:get_parameter("project_id") or command.project_id
    if not batch_project_id or batch_project_id == "" then
        print("ERROR: BatchCommand: Missing project_id on parent command")
        return false
    end

    -- Execute each command in sequence
    -- Outer execute() provides transaction safety - no nested transactions needed
    local Command = require("command")
    local executed_commands = {}

    local function deep_copy(value, seen)
        if type(value) ~= "table" then
            return value
        end
        seen = seen or {}
        if seen[value] then
            return seen[value]
        end
        local result = {}
        seen[value] = result
        for k, v in pairs(value) do
            result[k] = deep_copy(v, seen)
        end
        return result
    end

    for i, spec in ipairs(command_specs) do
        local child_project_id = spec.project_id
        if not child_project_id or child_project_id == "" then
            child_project_id = batch_project_id
            spec.project_id = child_project_id
        end

        local cmd = Command.create(spec.command_type, child_project_id)

        -- Set parameters from spec
        if spec.parameters then
            for key, value in pairs(spec.parameters) do
                cmd:set_parameter(key, value)
            end
        end

        if not cmd:get_parameter("project_id") or cmd:get_parameter("project_id") == "" then
            cmd:set_parameter("project_id", child_project_id)
        end
        cmd.project_id = child_project_id

        -- Execute command (don't add to command log - batch is the log entry)
        local executor = command_executors[spec.command_type]
        if not executor then
            print(string.format("ERROR: BatchCommand: Unknown command type '%s'", spec.command_type))
            return false
        end

        local success = executor(cmd)
        if not success then
            print(string.format("ERROR: BatchCommand: Command %d (%s) failed", i, spec.command_type))
            return false
        end

        table.insert(executed_commands, cmd)

        -- Capture mutated parameters to ensure deterministic replay/undo.
        local mutated = cmd:get_all_parameters()
        if mutated and next(mutated) ~= nil then
            spec.parameters = deep_copy(mutated)
        end
        spec.project_id = cmd.project_id
        merge_timeline_mutations(command, cmd:get_parameter("__timeline_mutations"))
    end

    -- Store executed commands for undo
    command:set_parameter("executed_commands_json", json.encode(command_specs))

    print(string.format("BatchCommand: Executed %d commands successfully", #executed_commands))
    return true
end

command_undoers["BatchCommand"] = function(command)
    print("Undoing BatchCommand")

    local commands_json = command:get_parameter("executed_commands_json")
    if not commands_json then
        print("ERROR: BatchCommand undo: No executed commands found")
        return false
    end

    -- Parse and undo in reverse order
    local json = require("dkjson")
    local command_specs = json.decode(commands_json)

    local Command = require("command")
    local batch_project_id = command:get_parameter("project_id") or command.project_id
    if not batch_project_id or batch_project_id == "" then
        print("ERROR: BatchCommand undo: Missing project_id on parent command")
        return false
    end

    for i = #command_specs, 1, -1 do
        local spec = command_specs[i]
        local child_project_id = spec.project_id
        if not child_project_id or child_project_id == "" then
            child_project_id = batch_project_id
            spec.project_id = child_project_id
        end

        local cmd = Command.create(spec.command_type, child_project_id)

        -- Restore parameters
        if spec.parameters then
            for key, value in pairs(spec.parameters) do
                cmd:set_parameter(key, value)
            end
        end

        if not cmd:get_parameter("project_id") or cmd:get_parameter("project_id") == "" then
            cmd:set_parameter("project_id", child_project_id)
        end
        cmd.project_id = child_project_id

        -- Execute undo
        local undoer = command_undoers[spec.command_type]
        if undoer then
            local success = undoer(cmd)
            if not success then
                print(string.format("WARNING: BatchCommand undo: Failed to undo command %d (%s)", i, spec.command_type))
            end
        end
        merge_timeline_mutations(command, cmd:get_parameter("__timeline_mutations"))
    end

    print(string.format("BatchCommand: Undid %d commands", #command_specs))
    return true
end

command_executors["DeleteClip"] = function(command)
    print("Executing DeleteClip command")

    local clip_id = command:get_parameter("clip_id")
    if not clip_id or clip_id == "" then
        print("WARNING: DeleteClip: Missing required parameter 'clip_id'")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.load_optional(clip_id, db)
    if not clip then
        local previous_state = command:get_parameter("deleted_clip_state")
        if previous_state then
            restore_clip_state(previous_state)
            clip = Clip.load_optional(clip_id, db)
        end
    end
    if not clip then
        print(string.format("INFO: DeleteClip: Clip %s already absent during replay; skipping delete", clip_id))
        return true
    end

    local clip_state = {
        id = clip.id,
        track_id = clip.track_id,
        media_id = clip.media_id,
        start_value = clip.start_value,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        enabled = clip.enabled
    }
    command:set_parameter("deleted_clip_state", clip_state)
    command:set_parameter("deleted_clip_properties", snapshot_properties_for_clip(clip_id))

    delete_properties_for_clip(clip_id)

    if not clip:delete(db) then
        print(string.format("WARNING: DeleteClip: Failed to delete clip %s", clip_id))
        return false
    end

    local sequence_id = command:get_parameter("sequence_id")
        or clip.owner_sequence_id
        or clip.track_sequence_id
        or (clip.track and clip.track.sequence_id)
    if sequence_id then
        add_delete_mutation(command, sequence_id, clip.id)
    end

    print(string.format("✅ Deleted clip %s from timeline", clip_id))
    return true
end

command_undoers["DeleteClip"] = function(command)
    local clip_state = command:get_parameter("deleted_clip_state")
    if not clip_state then
        print("WARNING: DeleteClip undo: Missing clip state")
        return false
    end

    restore_clip_state(clip_state)
    local properties = command:get_parameter("deleted_clip_properties") or {}
    if #properties > 0 then
        insert_properties_for_clip(clip_state.id, properties)
    end
    print(string.format("✅ Undo DeleteClip: Restored clip %s", clip_state.id))
    return true
end

command_executors["ImportMedia"] = function(command)
    print("Executing ImportMedia command")

    local file_path = command:get_parameter("file_path")
    local project_id = command:get_parameter("project_id")
    local existing_media_id = command:get_parameter("media_id")

    if not file_path or file_path == "" or not project_id or project_id == "" then
        print("WARNING: ImportMedia: Missing required parameters")
        return false
    end

    -- Use MediaReader to probe file and extract metadata
    local MediaReader = require("media.media_reader")
    local media_id, metadata, err = MediaReader.import_media(file_path, db, project_id, existing_media_id)

    if not media_id then
        print(string.format("ERROR: ImportMedia: Failed to import %s: %s", file_path, err or "unknown error"))
        return false
    end

    -- Store media_id for undo/redo
    command:set_parameter("media_id", media_id)
    if metadata then
        command:set_parameter("media_metadata", metadata)
    end

    local Sequence = require("models.sequence")
    local Track = require("models.track")
    local Clip = require("models.clip")

    local function extract_filename(path)
        if not path then
            return "Imported Media"
        end
        local name = path:match("([^/\\]+)$")
        if not name or name == "" then
            return path
        end
        return name
    end

    local duration_ms = 1000
    if metadata and metadata.duration_ms and metadata.duration_ms > 0 then
        duration_ms = math.floor(metadata.duration_ms + 0.5)
    end
    if duration_ms <= 0 then
        duration_ms = 1000
    end

    local base_name = extract_filename(file_path)
    local master_sequence_id = command:get_parameter("master_sequence_id")
    local sequence = Sequence.create(base_name .. " (Source)", project_id,
        metadata and metadata.video and metadata.video.frame_rate or 30.0,
        metadata and metadata.video and metadata.video.width or 1920,
        metadata and metadata.video and metadata.video.height or 1080,
        {
            id = master_sequence_id,
            kind = "master",
            timecode_start_frame = 0
        })
    if not sequence then
        print("ERROR: ImportMedia: Failed to create master sequence object")
        return false
    end
    if not sequence:save(db) then
        print("ERROR: ImportMedia: Failed to save master sequence")
        return false
    end
    command:set_parameter("master_sequence_id", sequence.id)

    -- Create or reuse internal tracks
    local master_video_track_id = command:get_parameter("master_video_track_id")
    local video_track = nil
    if metadata and metadata.has_video then
        video_track = Track.create_video("Video 1", sequence.id, {
            id = master_video_track_id,
            index = 1,
            db = db
        })
        if not video_track or not video_track:save(db) then
            print("ERROR: ImportMedia: Failed to create master video track")
            return false
        end
        command:set_parameter("master_video_track_id", video_track.id)
    else
        command:set_parameter("master_video_track_id", nil)
    end

    local stored_audio_track_ids = command:get_parameter("master_audio_track_ids")
    if type(stored_audio_track_ids) ~= "table" then
        stored_audio_track_ids = {}
    end
    local audio_track_ids = {}
    if metadata and metadata.has_audio then
        local channels = metadata.audio and metadata.audio.channels or 1
        if channels < 1 then
            channels = 1
        end
        for channel = 1, channels do
            local track = Track.create_audio(string.format("Audio %d", channel), sequence.id, {
                id = stored_audio_track_ids[channel],
                index = channel,
                db = db
            })
            if not track or not track:save(db) then
                print("ERROR: ImportMedia: Failed to create master audio track")
                return false
            end
            audio_track_ids[channel] = track.id
        end
    end
    command:set_parameter("master_audio_track_ids", audio_track_ids)

    -- Create master clip entry referencing this sequence
    local master_clip_id = command:get_parameter("master_clip_id")
    local master_clip = Clip.create(base_name, media_id, {
        id = master_clip_id,
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = sequence.id,
        start_value = 0,
        duration = duration_ms,
        source_in = 0,
        source_out = duration_ms,
        enabled = true,
        offline = false
    })
    local ok_master, occlusion_actions = master_clip:save(db, {skip_occlusion = true})
    if not ok_master then
        print("ERROR: ImportMedia: Failed to persist master clip")
        return false
    end
    command:set_parameter("master_clip_id", master_clip.id)
    if occlusion_actions and #occlusion_actions > 0 then
        print("WARNING: ImportMedia: Unexpected occlusion actions when saving master clip")
    end

    -- Populate internal source clips for tracks
    if video_track then
        local video_clip_id = command:get_parameter("master_video_clip_id")
        local video_clip = Clip.create(master_clip.name .. " (Video)", media_id, {
            id = video_clip_id,
            project_id = project_id,
            track_id = video_track.id,
            parent_clip_id = master_clip.id,
            owner_sequence_id = sequence.id,
            start_value = 0,
            duration = duration_ms,
            source_in = 0,
            source_out = duration_ms,
            enabled = true,
            offline = false
        })
        if not video_clip:save(db, {skip_occlusion = true}) then
            print("ERROR: ImportMedia: Failed to create master video clip")
            return false
        end
        command:set_parameter("master_video_clip_id", video_clip.id)
    else
        command:set_parameter("master_video_clip_id", nil)
    end

    local stored_audio_clip_ids = command:get_parameter("master_audio_clip_ids")
    if type(stored_audio_clip_ids) ~= "table" then
        stored_audio_clip_ids = {}
    end
    local audio_clip_ids = {}
    for index, track_id in ipairs(audio_track_ids) do
        local audio_clip = Clip.create(string.format("%s (Audio %d)", master_clip.name, index), media_id, {
            id = stored_audio_clip_ids[index],
            project_id = project_id,
            track_id = track_id,
            parent_clip_id = master_clip.id,
            owner_sequence_id = sequence.id,
            start_value = 0,
            duration = duration_ms,
            source_in = 0,
            source_out = duration_ms,
            enabled = true,
            offline = false
        })
        if not audio_clip:save(db, {skip_occlusion = true}) then
            print("ERROR: ImportMedia: Failed to create master audio clip")
            return false
        end
        audio_clip_ids[index] = audio_clip.id
    end
    command:set_parameter("master_audio_clip_ids", audio_clip_ids)

    print(string.format("Imported media: %s with ID: %s", file_path, media_id))
    return true
end

command_undoers["ImportMedia"] = function(command)
    print("Undoing ImportMedia command")

    local media_id = command:get_parameter("media_id")

    if not media_id or media_id == "" then
        print("WARNING: ImportMedia undo: No media_id found in command parameters")
        return false
    end

    -- Delete master clip (cascade removes nested clips)
    local master_clip_id = command:get_parameter("master_clip_id")
    if master_clip_id and master_clip_id ~= "" then
        local clip_stmt = db:prepare("DELETE FROM clips WHERE id = ?")
        if clip_stmt then
            clip_stmt:bind_value(1, master_clip_id)
            clip_stmt:exec()
            clip_stmt:finalize()
        end
    end

    -- Delete master sequence (cascade removes tracks)
    local master_sequence_id = command:get_parameter("master_sequence_id")
    if master_sequence_id and master_sequence_id ~= "" then
        local seq_stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
        if seq_stmt then
            seq_stmt:bind_value(1, master_sequence_id)
            seq_stmt:exec()
            seq_stmt:finalize()
        end
    end

    -- Delete media from database
    local stmt = db:prepare("DELETE FROM media WHERE id = ?")
    if not stmt then
        print("ERROR: ImportMedia undo: Failed to prepare DELETE statement")
        return false
    end

    stmt:bind_value(1, media_id)
    local success = stmt:exec()

    if success then
        print(string.format("Deleted imported media: %s", media_id))
        return true
    else
        print(string.format("ERROR: ImportMedia undo: Failed to delete media: %s", media_id))
        return false
    end
end

    -- MatchFrame: Focus the master clip for the currently selected timeline clip
    command_executors["MatchFrame"] = function(command)
        local timeline_state = require('ui.timeline.timeline_state')
        local project_browser = require('ui.project_browser')

        local selected = timeline_state.get_selected_clips and timeline_state.get_selected_clips() or {}
        if not selected or #selected == 0 then
            set_last_error("MatchFrame: No clips selected")
            return false
        end

        local function extract_parent_id(entry)
            if type(entry) ~= "table" then
                return nil
            end
            if entry.parent_clip_id and entry.parent_clip_id ~= "" then
                return entry.parent_clip_id
            end
            if entry.parent_id and entry.parent_id ~= "" then
                return entry.parent_id
            end
            return nil
        end

        local target_master_id = nil
        for _, clip in ipairs(selected) do
            target_master_id = extract_parent_id(clip)
            if target_master_id then
                break
            end
        end

        if not target_master_id then
            set_last_error("MatchFrame: Selected clip is not linked to a master clip")
            return false
        end

        local ok, err = pcall(project_browser.focus_master_clip, target_master_id, {
            skip_focus = command:get_parameter("skip_focus") == true,
            skip_activate = command:get_parameter("skip_activate") == true
        })
        if not ok then
            set_last_error("MatchFrame: " .. tostring(err))
            return false
        end

        if err == false then
            set_last_error("MatchFrame: Failed to focus master clip")
            return false
        end

        return true
    end

command_executors["SetClipProperty"] = function(command)
    print("Executing SetClipProperty command")

    local clip_id = command:get_parameter("clip_id")
    local property_name = command:get_parameter("property_name")
    local new_value = command:get_parameter("value")
    local property_type = command:get_parameter("property_type")
    local default_value_param = command:get_parameter("default_value")

    if not clip_id or clip_id == "" or not property_name or property_name == "" then
        local message = "SetClipProperty: Missing required parameters"
        set_last_error(message)
        print("WARNING: " .. message)
        return false
    end

    if not property_type or property_type == "" then
        local message = "SetClipProperty: Missing property_type parameter"
        set_last_error(message)
        print("WARNING: " .. message)
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.load_optional(clip_id, db)
    if not clip or clip.id == "" then
        local executed_with_clip = command:get_parameter("executed_with_clip")
        if executed_with_clip then
            print(string.format("INFO: SetClipProperty: Clip %s missing during replay; property update skipped", clip_id))
            return true
        end

        if command:get_parameter("previous_value") ~= nil then
            print(string.format("INFO: SetClipProperty: Clip %s missing but previous_value present; assuming clip deleted and skipping", clip_id))
            return true
        end

        print(string.format("WARNING: SetClipProperty: Clip not found during replay: %s; skipping property update", clip_id))
        return true
    end

    local select_stmt = db:prepare("SELECT id, property_value, property_type, default_value FROM properties WHERE clip_id = ? AND property_name = ?")
    if not select_stmt then
        local message = "SetClipProperty: Failed to prepare property lookup query"
        set_last_error(message)
        print("WARNING: " .. message)
        return false
    end
    select_stmt:bind_value(1, clip_id)
    select_stmt:bind_value(2, property_name)

    local property_id = nil
    local previous_value = nil
    local previous_type = nil
    local previous_default = nil
    local existing_property = false

    local function decode_property(raw)
        if not raw or raw == "" then
            return nil
        end
        local decoded, _, err = json.decode(raw)
        if err or decoded == nil then
            return raw
        end
        if type(decoded) == "table" and decoded.value ~= nil then
            return decoded.value
        end
        return decoded
    end

    if select_stmt:exec() and select_stmt:next() then
        existing_property = true
        property_id = select_stmt:value(0)
        previous_value = decode_property(select_stmt:value(1))
        previous_type = select_stmt:value(2)
        previous_default = select_stmt:value(3)
    else
        property_id = uuid.generate()
    end
    select_stmt:finalize()

    local encoded_value, encode_err = json.encode({ value = new_value })
    if not encoded_value then
        local message = "SetClipProperty: Failed to encode property value: " .. tostring(encode_err)
        set_last_error(message)
        print("WARNING: " .. message)
        return false
    end

    local default_json = nil
    do
        local encoded_default, default_err = json.encode({ value = default_value_param })
        if not encoded_default then
            local message = "SetClipProperty: Failed to encode default value: " .. tostring(default_err)
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        default_json = encoded_default
    end

    command:set_parameter("previous_value", previous_value)
    command:set_parameter("previous_type", previous_type)
    command:set_parameter("previous_default", previous_default)
    command:set_parameter("property_id", property_id)
    command:set_parameter("created_new", not existing_property)
    command:set_parameter("executed_with_clip", true)

    if existing_property then
        local update_sql
        if default_json ~= nil then
            update_sql = "UPDATE properties SET property_value = ?, property_type = ?, default_value = ? WHERE id = ?"
        else
            update_sql = "UPDATE properties SET property_value = ?, property_type = ? WHERE id = ?"
        end
        local update_stmt = db:prepare(update_sql)
        if not update_stmt then
            local message = "SetClipProperty: Failed to prepare property update"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        update_stmt:bind_value(1, encoded_value)
        update_stmt:bind_value(2, property_type)
        if default_json ~= nil then
            update_stmt:bind_value(3, default_json)
            update_stmt:bind_value(4, property_id)
        else
            update_stmt:bind_value(3, property_id)
        end
        if not update_stmt:exec() then
            local err = "unknown"
            if update_stmt.last_error then
                local ok, msg = pcall(update_stmt.last_error, update_stmt)
                if ok and msg and msg ~= "" then
                    err = msg
                end
            end
            local message = "SetClipProperty: Failed to update property row: " .. tostring(err)
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        update_stmt:finalize()
    else
        local insert_stmt = db:prepare("INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value) VALUES (?, ?, ?, ?, ?, ?)")
        if not insert_stmt then
            local message = "SetClipProperty: Failed to prepare property insert"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        insert_stmt:bind_value(1, property_id)
        insert_stmt:bind_value(2, clip_id)
        insert_stmt:bind_value(3, property_name)
        insert_stmt:bind_value(4, encoded_value)
        insert_stmt:bind_value(5, property_type)
        insert_stmt:bind_value(6, default_json or json.encode({ value = nil }))
        if not insert_stmt:exec() then
            local err = "unknown"
            if insert_stmt.last_error then
                local ok, msg = pcall(insert_stmt.last_error, insert_stmt)
                if ok and msg and msg ~= "" then
                    err = msg
                end
            end
            local message = "SetClipProperty: Failed to insert property row: " .. tostring(err)
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        insert_stmt:finalize()
    end

    clip:set_property(property_name, new_value)

    if clip:save(db) then
        print(string.format("Set clip property %s to %s for clip %s", property_name, tostring(new_value), clip_id))
        return true
    else
        local message = "Failed to save clip property change"
        set_last_error(message)
        print("WARNING: " .. message)
        return false
    end
end

command_undoers["SetClipProperty"] = function(command)
    print("Undoing SetClipProperty command")

    local clip_id = command:get_parameter("clip_id")
    local property_name = command:get_parameter("property_name")
    local property_id = command:get_parameter("property_id")
    local previous_value = command:get_parameter("previous_value")
    local previous_type = command:get_parameter("previous_type")
    local previous_default = command:get_parameter("previous_default")
    local created_new = command:get_parameter("created_new") and true or false

    if not property_id or property_id == "" then
        local message = "Undo SetClipProperty: Missing property_id parameter"
        set_last_error(message)
        print("WARNING: " .. message)
        return false
    end

    if created_new then
        local delete_stmt = db:prepare("DELETE FROM properties WHERE id = ?")
        if not delete_stmt then
            local message = "Undo SetClipProperty: Failed to prepare delete statement"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        delete_stmt:bind_value(1, property_id)
        if not delete_stmt:exec() then
            local message = "Undo SetClipProperty: Failed to delete newly created property row"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        delete_stmt:finalize()
    else
        if not previous_type or previous_type == "" then
            local message = "Undo SetClipProperty: Missing previous_type for existing property restore"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        local encoded_prev, encode_err = json.encode({ value = previous_value })
        if not encoded_prev then
            local message = "Undo SetClipProperty: Failed to encode previous property value: " .. tostring(encode_err)
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        local update_sql
        if previous_default ~= nil then
            update_sql = "UPDATE properties SET property_value = ?, property_type = ?, default_value = ? WHERE id = ?"
        else
            update_sql = "UPDATE properties SET property_value = ?, property_type = ? WHERE id = ?"
        end
        local update_stmt = db:prepare(update_sql)
        if not update_stmt then
            local message = "Undo SetClipProperty: Failed to prepare update statement"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        update_stmt:bind_value(1, encoded_prev)
        update_stmt:bind_value(2, previous_type)
        if previous_default ~= nil then
            update_stmt:bind_value(3, previous_default)
            update_stmt:bind_value(4, property_id)
        else
            update_stmt:bind_value(3, property_id)
        end
        if not update_stmt:exec() then
            local message = "Undo SetClipProperty: Failed to restore property row"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        update_stmt:finalize()
    end

    local Clip = require('models.clip')
    local clip = Clip.load_optional(clip_id, db)
    if clip then
        clip:set_property(property_name, previous_value)
        clip:save(db)
    end

    return true
end

local sequence_metadata_columns = {
    name = {type = "string"},
    frame_rate = {type = "number"},
    width = {type = "number"},
    height = {type = "number"},
    timecode_start_frame = {type = "number"},
    playhead_value = {type = "number"},
    viewport_start_value = {type = "number"},
    viewport_duration_frames_value = {type = "number"},
    mark_in_value = {type = "nullable_number"},
    mark_out_value = {type = "nullable_number"}
}

local function normalize_sequence_value(field, value)
    local config = sequence_metadata_columns[field]
    if not config then
        return value
    end

    if config.type == "string" then
        return value ~= nil and tostring(value) or ""
    elseif config.type == "number" then
        return tonumber(value) or 0
    elseif config.type == "nullable_number" then
        if value == nil or value == "" then
            return nil
        end
        return tonumber(value)
    end
    return value
end

command_executors["SetSequenceMetadata"] = function(command)
    local sequence_id = command:get_parameter("sequence_id")
    local field = command:get_parameter("field")
    local new_value = command:get_parameter("value")

    if not sequence_id or sequence_id == "" or not field or field == "" then
        set_last_error("SetSequenceMetadata: Missing required parameters")
        return false
    end

    local column = sequence_metadata_columns[field]
    if not column then
        set_last_error("SetSequenceMetadata: Field not allowed: " .. tostring(field))
        return false
    end

    local select_stmt = db:prepare("SELECT " .. field .. " FROM sequences WHERE id = ?")
    if not select_stmt then
        set_last_error("SetSequenceMetadata: Failed to prepare select statement")
        return false
    end
    select_stmt:bind_value(1, sequence_id)
    local previous_value = nil
    if select_stmt:exec() and select_stmt:next() then
        previous_value = select_stmt:value(0)
    end
    select_stmt:finalize()

    local normalized_value = normalize_sequence_value(field, new_value)
    command:set_parameter("previous_value", previous_value)
    command:set_parameter("normalized_value", normalized_value)

    local update_stmt = db:prepare("UPDATE sequences SET " .. field .. " = ? WHERE id = ?")
    if not update_stmt then
        set_last_error("SetSequenceMetadata: Failed to prepare update statement")
        return false
    end

    if normalized_value == nil then
        if update_stmt.bind_null then
            update_stmt:bind_null(1)
        else
            update_stmt:bind_value(1, nil)
        end
    else
        update_stmt:bind_value(1, normalized_value)
    end
    update_stmt:bind_value(2, sequence_id)

    local ok = update_stmt:exec()
    update_stmt:finalize()

    if not ok then
        set_last_error("SetSequenceMetadata: Update failed")
        return false
    end

    print(string.format("Set sequence %s field %s to %s", sequence_id, field, tostring(normalized_value)))
    return true
end

command_undoers["SetSequenceMetadata"] = function(command)
    local sequence_id = command:get_parameter("sequence_id")
    local field = command:get_parameter("field")
    local previous_value = command:get_parameter("previous_value")

    if not sequence_id or sequence_id == "" or not field or field == "" then
        set_last_error("UndoSetSequenceMetadata: Missing parameters")
        return false
    end

    local column = sequence_metadata_columns[field]
    if not column then
        set_last_error("UndoSetSequenceMetadata: Field not allowed: " .. tostring(field))
        return false
    end

    local normalized = normalize_sequence_value(field, previous_value)
    local stmt = db:prepare("UPDATE sequences SET " .. field .. " = ? WHERE id = ?")
    if not stmt then
        set_last_error("UndoSetSequenceMetadata: Failed to prepare update statement")
        return false
    end

    if normalized == nil then
        if stmt.bind_null then
            stmt:bind_null(1)
        else
            stmt:bind_value(1, nil)
        end
    else
        stmt:bind_value(1, normalized)
    end
    stmt:bind_value(2, sequence_id)

    local ok = stmt:exec()
    stmt:finalize()

    if not ok then
        set_last_error("UndoSetSequenceMetadata: Update failed")
        return false
    end

    print(string.format("Undo sequence %s field %s to %s", sequence_id, field, tostring(normalized)))
    return true
end

command_executors["SetProperty"] = function(command)
    print("Executing SetProperty command")

    local entity_id = command:get_parameter("entity_id")
    local entity_type = command:get_parameter("entity_type")
    local property_name = command:get_parameter("property_name")
    local new_value = command:get_parameter("value")

    if not entity_id or entity_id == "" or not entity_type or entity_type == "" or not property_name or property_name == "" then
        print("WARNING: SetProperty: Missing required parameters")
        return false
    end

    local Property = require('models.property')
    local property = Property.create(property_name, entity_id)

    -- Store previous value for undo
    local previous_value = property.value
    command:set_parameter("previous_value", previous_value)

    -- Set new value
    property:set_value(new_value)

    if property:save(db) then
        print(string.format("Set property %s to %s for %s %s", property_name, tostring(new_value), entity_type, entity_id))
        return true
    else
        print("WARNING: Failed to save property change")
        return false
    end
end

command_executors["ModifyProperty"] = function(command)
    print("Executing ModifyProperty command")

    local entity_id = command:get_parameter("entity_id")
    local entity_type = command:get_parameter("entity_type")
    local property_name = command:get_parameter("property_name")
    local new_value = command:get_parameter("value")

    if not entity_id or entity_id == "" or not entity_type or entity_type == "" or not property_name or property_name == "" then
        print("WARNING: ModifyProperty: Missing required parameters")
        return false
    end

    local Property = require('models.property')
    local property = Property.load(entity_id, db)
    if not property or property.id == "" then
        print("WARNING: ModifyProperty: Property not found")
        return false
    end

    -- Store previous value for undo
    local previous_value = property.value
    command:set_parameter("previous_value", previous_value)

    -- Set new value
    property:set_value(new_value)

    if property:save(db) then
        print(string.format("Modified property %s to %s for %s %s", property_name, tostring(new_value), entity_type, entity_id))
        return true
    else
        print("WARNING: Failed to save property modification")
        return false
    end
end

command_executors["CreateClip"] = function(command)
    print("Executing CreateClip command")

    local track_id = command:get_parameter("track_id")
    local media_id = command:get_parameter("media_id")
    local start_value = command:get_parameter("start_value") or 0
    local duration = command:get_parameter("duration")
    local source_in = command:get_parameter("source_in") or 0
    local source_out = command:get_parameter("source_out")
    local master_clip_id = command:get_parameter("master_clip_id")
    local project_id_param = command:get_parameter("project_id")

    local Clip = require('models.clip')
    local master_clip = nil
    local copied_properties = {}
    if master_clip_id and master_clip_id ~= "" then
        master_clip = Clip.load_optional(master_clip_id, db)
        if not master_clip then
            print(string.format("WARNING: CreateClip: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
            master_clip_id = nil
        end
    end

    if master_clip and (not media_id or media_id == "") then
        media_id = master_clip.media_id
    end

    if not track_id or track_id == "" or not media_id or media_id == "" then
        print("WARNING: CreateClip: Missing required parameters")
        return false
    end

    if master_clip then
        if not duration or duration <= 0 then
            duration = master_clip.duration or ((master_clip.source_out or 0) - (master_clip.source_in or 0))
        end
        if not source_out or source_out <= source_in then
            source_in = master_clip.source_in or source_in
            source_out = master_clip.source_out or (master_clip.duration or 0)
        end
    end

    if not duration or duration <= 0 or not source_out or source_out <= source_in then
        print("WARNING: CreateClip: Missing or invalid duration/source range")
        return false
    end

    local clip = Clip.create("Timeline Clip", media_id, {
        project_id = project_id_param or (master_clip and master_clip.project_id),
        track_id = track_id,
        owner_sequence_id = command:get_parameter("sequence_id"),
        parent_clip_id = master_clip_id,
        source_sequence_id = master_clip and master_clip.source_sequence_id,
        start_value = start_value,
        duration = duration,
        source_in = source_in,
        source_out = source_out,
        enabled = true,
        offline = master_clip and master_clip.offline,
    })

    command:set_parameter("clip_id", clip.id)
    if master_clip_id and master_clip_id ~= "" then
        command:set_parameter("master_clip_id", master_clip_id)
    end
    if project_id_param then
        command:set_parameter("project_id", project_id_param)
    elseif master_clip and master_clip.project_id then
        command:set_parameter("project_id", master_clip.project_id)
    end

    if clip:save(db) then
        print(string.format("Created clip with ID: %s on track %s at %dms", clip.id, track_id, start_value))
        return true
    else
        print("WARNING: Failed to save clip")
        return false
    end
end

command_executors["AddTrack"] = function(command)
    print("Executing AddTrack command")

    local sequence_id = command:get_parameter("sequence_id")
    local track_type = command:get_parameter("track_type")

    if not sequence_id or sequence_id == "" or not track_type or track_type == "" then
        print("WARNING: AddTrack: Missing required parameters")
        return false
    end

    local Track = require('models.track')
    local track
    if track_type == "video" then
        track = Track.create_video("Video Track", sequence_id)
    elseif track_type == "audio" then
        track = Track.create_audio("Audio Track", sequence_id)
    else
        print(string.format("WARNING: AddTrack: Unknown track type: %s", track_type))
        return false
    end

    command:set_parameter("track_id", track.id)

    if track:save(db) then
        print(string.format("Added track with ID: %s", track.id))
        return true
    else
        print("WARNING: Failed to save track")
        return false
    end
end

command_executors["AddClip"] = function(command)
    print("Executing AddClip command")
    return command_executors["CreateClip"](command)
end

-- Insert clip from media browser to timeline at playhead
command_executors["InsertClipToTimeline"] = function(command)
    print("Executing InsertClipToTimeline command")

    local media_id = command:get_parameter("media_id")
    local track_id = command:get_parameter("track_id")
    local start_value = command:get_parameter("start_value") or 0
    local media_duration = command:get_parameter("media_duration") or 3000

    if not media_id or media_id == "" then
        print("WARNING: InsertClipToTimeline: Missing media_id")
        return false
    end

    if not track_id or track_id == "" then
        print("WARNING: InsertClipToTimeline: Missing track_id")
        return false
    end

    local Clip = require('models.clip')
    local master_clip_id = command:get_parameter("master_clip_id")
    local project_id_param = command:get_parameter("project_id")
    local master_clip = nil

    if master_clip_id and master_clip_id ~= "" then
        master_clip = Clip.load_optional(master_clip_id, db)
        if not master_clip then
            print(string.format("WARNING: InsertClipToTimeline: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
            master_clip_id = nil
        end
    end

    if master_clip and (not media_id or media_id == "") then
        media_id = master_clip.media_id
    end

    if not media_id or media_id == "" then
        print("WARNING: InsertClipToTimeline: Missing media_id after resolving master clip")
        return false
    end

    local duration = media_duration
    local source_in = 0
    local source_out = media_duration
    if master_clip then
        duration = master_clip.duration or ((master_clip.source_out or 0) - (master_clip.source_in or 0)) or media_duration
        source_in = master_clip.source_in or 0
        source_out = master_clip.source_out or (source_in + duration)
        if duration <= 0 then
            duration = media_duration
        end
        copied_properties = ensure_copied_properties(command, master_clip_id)
    end

    local clip = Clip.create("Clip", media_id, {
        project_id = project_id_param or (master_clip and master_clip.project_id),
        track_id = track_id,
        owner_sequence_id = command:get_parameter("sequence_id"),
        parent_clip_id = master_clip_id,
        source_sequence_id = master_clip and master_clip.source_sequence_id,
        start_value = start_value,
        duration = duration,
        source_in = source_in,
        source_out = source_out,
        enabled = true,
        offline = master_clip and master_clip.offline,
    })

    command:set_parameter("clip_id", clip.id)
    if master_clip_id and master_clip_id ~= "" then
        command:set_parameter("master_clip_id", master_clip_id)
    end
    if project_id_param then
        command:set_parameter("project_id", project_id_param)
    elseif master_clip and master_clip.project_id then
        command:set_parameter("project_id", master_clip.project_id)
    end

    if clip:save(db) then
        if #copied_properties > 0 then
            delete_properties_for_clip(clip.id)
            if not insert_properties_for_clip(clip.id, copied_properties) then
                print(string.format("WARNING: InsertClipToTimeline: Failed to copy properties from master clip %s", tostring(master_clip_id)))
            end
        end
        print(string.format("✅ Inserted clip %s to track %s at time %d", clip.id, track_id, start_value))
        return true
    else
        print("WARNING: Failed to save clip to timeline")
        return false
    end
end

-- Undo for InsertClipToTimeline: remove the clip
command_executors["UndoInsertClipToTimeline"] = function(command)
    print("Executing UndoInsertClipToTimeline command")

    local clip_id = command:get_parameter("clip_id")

    if not clip_id or clip_id == "" then
        print("WARNING: UndoInsertClipToTimeline: Missing clip_id")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)

    if not clip then
        print(string.format("WARNING: UndoInsertClipToTimeline: Clip not found: %s", clip_id))
        return false
    end

    delete_properties_for_clip(clip_id)
    if clip:delete(db) then
        print(string.format("✅ Removed clip %s from timeline", clip_id))
        return true
    else
        print("WARNING: Failed to delete clip from timeline")
        return false
    end
end

command_executors["SetupProject"] = function(command)
    print("Executing SetupProject command")

    local project_id = command:get_parameter("project_id")
    local settings = command:get_parameter("settings")

    if not project_id or project_id == "" then
        print("WARNING: SetupProject: Missing required parameters")
        return false
    end

    local Project = require('models.project')
    local project = Project.load(project_id, db)
    if not project or project.id == "" then
        print(string.format("WARNING: SetupProject: Project not found: %s", project_id))
        return false
    end

    -- Store previous settings for undo
    local previous_settings = project.settings
    command:set_parameter("previous_settings", previous_settings)

    -- Apply new settings
    local settings_json = require('json').encode(settings)
    project:set_settings(settings_json)

    if project:save(db) then
        print(string.format("Applied settings to project: %s", project_id))
        return true
    else
        print("WARNING: Failed to save project settings")
        return false
    end
end

command_executors["SplitClip"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing SplitClip command")
    end

    local clip_id = command:get_parameter("clip_id")
    local split_value = command:get_parameter("split_value") or command:get_parameter("split_time")

    if not dry_run then
        print(string.format("  clip_id: %s", tostring(clip_id)))
        print(string.format("  split_value: %s", tostring(split_value)))
        print(string.format("  db: %s", tostring(db)))
    end

    if not clip_id or clip_id == "" or not split_value or split_value <= 0 then
        print("WARNING: SplitClip: Missing required parameters")
        return false
    end

    -- Load the original clip
    local Clip = require('models.clip')
    local original_clip = Clip.load(clip_id, db)
    if not original_clip or original_clip.id == "" then
        print(string.format("WARNING: SplitClip: Clip not found: %s", clip_id))
        return false
    end

    -- Validate split_time is within clip bounds
    if split_value <= original_clip.start_value or split_value >= (original_clip.start_value + original_clip.duration) then
        print(string.format("WARNING: SplitClip: split_value %d is outside clip bounds [%d, %d]",
            split_value, original_clip.start_value, original_clip.start_value + original_clip.duration))
        return false
    end

    local mutation_sequence = original_clip.owner_sequence_id or original_clip.track_sequence_id
    if (not mutation_sequence or mutation_sequence == "") and original_clip.track_id then
        mutation_sequence = resolve_sequence_for_track(command:get_parameter("sequence_id"), original_clip.track_id)
    end
    if mutation_sequence and (not command:get_parameter("sequence_id") or command:get_parameter("sequence_id") == "") then
        command:set_parameter("sequence_id", mutation_sequence)
    end

    -- Store original state for undo
    command:set_parameter("track_id", original_clip.track_id)
    command:set_parameter("original_start_value", original_clip.start_value)
    command:set_parameter("original_duration", original_clip.duration)
    command:set_parameter("original_source_in", original_clip.source_in)
    command:set_parameter("original_source_out", original_clip.source_out)

    -- Calculate new durations and source points
    local first_duration = split_value - original_clip.start_value
    local second_duration = original_clip.duration - first_duration

    -- Calculate source points for the split
    local source_split_point = original_clip.source_in + first_duration

    -- Create second clip (right side of split)
    -- IMPORTANT: Reuse second_clip_id if this is a replay (deterministic replay for event sourcing)
    local existing_second_clip_id = command:get_parameter("second_clip_id")
    local second_clip = Clip.create(original_clip.name .. " (2)", original_clip.media_id, {
        project_id = original_clip.project_id,
        track_id = original_clip.track_id,
        owner_sequence_id = original_clip.owner_sequence_id,
        parent_clip_id = original_clip.parent_clip_id,
        source_sequence_id = original_clip.source_sequence_id,
        start_value = split_value,
        duration = second_duration,
        source_in = source_split_point,
        source_out = original_clip.source_out,
        enabled = original_clip.enabled,
        offline = original_clip.offline,
        clip_kind = original_clip.clip_kind,
    })
    if existing_second_clip_id then
        second_clip.id = existing_second_clip_id  -- Reuse ID from original execution
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        return true, {
            first_clip = {
                clip_id = original_clip.id,
                new_duration = first_duration,
                new_source_out = source_split_point
            },
            second_clip = {
                clip_id = second_clip.id,
                track_id = second_clip.track_id,
                start_value = second_clip.start_value,
                duration = second_clip.duration,
                source_in = second_clip.source_in,
                source_out = second_clip.source_out
            }
        }
    end

    -- Update original clip (left side of split)
    original_clip.duration = first_duration
    original_clip.duration_value = first_duration
    original_clip.source_out = source_split_point
    original_clip.source_out_value = source_split_point

    -- EXECUTE: Save both clips
    if not original_clip:save(db) then
        print("WARNING: SplitClip: Failed to save modified original clip")
        return false
    end

    local first_update = clip_update_payload(original_clip, mutation_sequence)
    if first_update then
        add_update_mutation(command, first_update.track_sequence_id or mutation_sequence, first_update)
    end

    if not second_clip:save(db) then
        print("WARNING: SplitClip: Failed to save new clip")
        return false
    end

    local second_insert = clip_insert_payload(second_clip, mutation_sequence)
    if second_insert then
        add_insert_mutation(command, second_insert.track_sequence_id or mutation_sequence, second_insert)
    end

    -- Store second clip ID for undo / replay
    command:set_parameter("second_clip_id", second_clip.id)

    print(string.format("Split clip %s at time %d into clips %s and %s",
        clip_id, split_value, original_clip.id, second_clip.id))
    return true
end

-- Undo SplitClip command
local function perform_split_clip_undo(command)
    print("Executing UndoSplitClip command")

    local clip_id = command:get_parameter("clip_id")
    local track_id = command:get_parameter("track_id")
    local split_value = command:get_parameter("split_value") or command:get_parameter("split_time")
    local original_start_value = command:get_parameter("original_start_value")
    local original_duration = command:get_parameter("original_duration")
    local original_source_in = command:get_parameter("original_source_in")
    local original_source_out = command:get_parameter("original_source_out")
    local mutation_sequence = command:get_parameter("sequence_id")

    if not clip_id or clip_id == "" or not track_id or not split_value then
        print("WARNING: UndoSplitClip: Missing required parameters")
        return false
    end

    -- Load the original clip (left side of split)
    local Clip = require('models.clip')
    local original_clip = Clip.load(clip_id, db)

    if not original_clip then
        print(string.format("WARNING: UndoSplitClip: Original clip not found: %s", clip_id))
        return false
    end

    mutation_sequence = mutation_sequence
        or original_clip.owner_sequence_id
        or original_clip.track_sequence_id
        or resolve_sequence_for_track(nil, track_id)

    -- Find the second clip (right side) by position: on same track, starts at split_value
    -- Use direct SQL query since Clip model doesn't have a "find by position" method
    local query = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ? AND start_value = ? AND id != ?
        LIMIT 1
    ]])

    if not query then
        print("WARNING: UndoSplitClip: Failed to prepare second clip query")
        return false
    end

    query:bind_value(1, track_id)
    query:bind_value(2, split_value)
    query:bind_value(3, clip_id)  -- Exclude the original clip itself

    local second_clip = nil
    local second_clip_id = nil
    if query:exec() and query:next() then
        second_clip_id = query:value(0)
        second_clip = Clip.load(second_clip_id, db)
    end

    if not second_clip then
        print(string.format("WARNING: UndoSplitClip: Second clip not found at track=%s, time=%d",
            track_id, split_value))
        return false
    end

    -- Restore ALL original clip properties
    original_clip.start_value = original_start_value
    original_clip.duration = original_duration
    original_clip.source_in = original_source_in
    original_clip.source_out = original_source_out

    -- Save original clip
    if not original_clip:save(db) then
        print("WARNING: UndoSplitClip: Failed to save original clip")
        return false
    end

    local restore_update = clip_update_payload(original_clip, mutation_sequence)
    if restore_update then
        add_update_mutation(command, restore_update.track_sequence_id or mutation_sequence, restore_update)
    end

    -- Delete second clip
    if not second_clip:delete(db) then
        print("WARNING: UndoSplitClip: Failed to delete second clip")
        return false
    end

    add_delete_mutation(command, mutation_sequence, second_clip_id)

    flush_timeline_mutations(command, mutation_sequence or original_clip.owner_sequence_id or original_clip.track_sequence_id)

    print(string.format("Undid split: restored clip %s and deleted clip %s",
        clip_id, second_clip_id))
    return true
end

command_executors["UndoSplitClip"] = perform_split_clip_undo


-- INSERT: Add clip at playhead, rippling all subsequent clips forward
command_executors["Insert"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Insert command")
    end

    local Clip = require('models.clip')

    local media_id = command:get_parameter("media_id")
    local track_id = command:get_parameter("track_id")
    local insert_time = command:get_parameter("insert_time")
    local duration = command:get_parameter("duration_value") or command:get_parameter("duration")
    local source_in = command:get_parameter("source_in_value")
        or command:get_parameter("source_in") or 0
    local source_out = command:get_parameter("source_out_value") or command:get_parameter("source_out")
    local master_clip_id = command:get_parameter("master_clip_id")
    local project_id_param = command:get_parameter("project_id")

    local master_clip = nil
    if master_clip_id and master_clip_id ~= "" then
        master_clip = Clip.load_optional(master_clip_id, db)
        if not master_clip then
            print(string.format("WARNING: Insert: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
            master_clip_id = nil
        end
    end

    local copied_properties = {}
    if master_clip then
        if (not media_id or media_id == "") and master_clip.media_id then
            media_id = master_clip.media_id
        end
        if not duration or duration <= 0 then
            local master_duration = master_clip.duration or ((master_clip.source_out or 0) - (master_clip.source_in or 0))
            duration = master_duration
        end
        if not source_out or source_out <= source_in then
            local master_source_in = master_clip.source_in or source_in
            local master_source_out = master_clip.source_out or (master_clip.duration or 0)
            source_in = master_source_in
            source_out = master_source_out
        end
        copied_properties = ensure_copied_properties(command, master_clip_id)
    end

    if not media_id or media_id == "" or not track_id or track_id == "" then
        print("WARNING: Insert: Missing media_id or track_id")
        return false
    end

    if not insert_time or not duration or duration <= 0 or not source_out then
        print("WARNING: Insert: Missing or invalid insert_time, duration, or source_out")
        return false
    end

    -- Frame alignment now automatic in Clip:save() for video tracks
    -- Audio tracks preserve sample-accurate precision

    -- Step 1: Ripple all clips on this track that start at or after insert_time
    local db_module = require('core.database')
    local sequence_id = resolve_sequence_for_track(command:get_parameter("sequence_id"), track_id) or "default_sequence"
    if sequence_id and sequence_id ~= "" then
        command:set_parameter("sequence_id", sequence_id)
    end

    -- Load all clips on this track
    local query = db:prepare([[
        SELECT id, start_value, duration_value FROM clips
        WHERE track_id = ?
        ORDER BY start_value ASC
    ]])

    if not query then
        print("WARNING: Insert: Failed to prepare query")
        return false
    end

    query:bind_value(1, track_id)

    local clips_to_ripple = {}
    local pending_moves = {}
    local pending_tolerance = frame_utils.frame_duration_ms()
    if query:exec() then
        while query:next() do
            local clip_id = query:value(0)
            local start_value = query:value(1)
            local clip_duration = query:value(2)
            -- Ripple clips that start at or after insert_time to prevent overlap
            if start_value >= insert_time then
                local new_start = start_value + duration
                table.insert(clips_to_ripple, {
                    id = clip_id,
                    old_start = start_value,
                    new_start = new_start,
                    duration = clip_duration
                })
                pending_moves[clip_id] = {
                    start_value = new_start,
                    duration = clip_duration,
                    tolerance = pending_tolerance
                }
            end
        end
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        local preview_rippled_clips = {}
        for _, clip_info in ipairs(clips_to_ripple) do
            table.insert(preview_rippled_clips, {
                clip_id = clip_info.id,
                new_start_value = clip_info.new_start
            })
        end

        local existing_clip_id = command:get_parameter("clip_id")
        local Clip = require('models.clip')
        local new_clip_id = existing_clip_id or Clip.generate_id()

        return true, {
            new_clip = {
                clip_id = new_clip_id,
                track_id = track_id,
                start_value = insert_time,
                duration = duration,
                source_in = source_in,
                source_out = source_out
            },
            rippled_clips = preview_rippled_clips
        }
    end

    -- EXECUTE: Ripple clips forward
    for _, clip_info in ipairs(clips_to_ripple) do
        local clip = Clip.load_optional(clip_info.id, db)
        if not clip then
            print(string.format("WARNING: Insert: Skipping missing clip %s during ripple", clip_info.id))
            pending_moves[clip_info.id] = nil
            goto continue_ripple
        end

        clip.start_value = clip_info.new_start

        local save_opts = nil
        if next(pending_moves) ~= nil then
            save_opts = {pending_clips = pending_moves}
        end

        local saved, occlusion_actions = clip:save(db, save_opts)
        if not saved then
            print(string.format("WARNING: Insert: Failed to ripple clip %s", clip_info.id))
            return false
        end
        pending_moves[clip.id] = nil
        if occlusion_actions and #occlusion_actions > 0 then
            record_occlusion_actions(command, clip.owner_sequence_id or sequence_id, occlusion_actions)
        end

        local update_payload = clip_update_payload(clip, sequence_id)
        if update_payload then
            add_update_mutation(command, update_payload.track_sequence_id, update_payload)
        end

        ::continue_ripple::
    end

    -- Store ripple info for undo
    command:set_parameter("rippled_clips", clips_to_ripple)

    -- Step 2: Create the new clip at insert_time
    -- Reuse clip_id if this is a replay (to preserve selection references)
    local existing_clip_id = command:get_parameter("clip_id")
    local clip_name = (master_clip and master_clip.name) or "Inserted Clip"
    if (not master_clip_id or master_clip_id == "") then
        master_clip_id = ensure_master_clip_for_media(command, media_id, {
            name = clip_name,
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            project_id = project_id_param
        }) or master_clip_id
        if master_clip_id and master_clip_id ~= "" then
            command:set_parameter("master_clip_id", master_clip_id)
        end
    end
    local clip_opts = {
        id = existing_clip_id,
        project_id = project_id_param or (master_clip and master_clip.project_id),
        track_id = track_id,
        owner_sequence_id = sequence_id,
        parent_clip_id = master_clip_id,
        source_sequence_id = master_clip and master_clip.source_sequence_id,
        start_value = insert_time,
        duration = duration,
        source_in = source_in,
        source_out = source_out,
        enabled = true,
        offline = master_clip and master_clip.offline,
    }
    local clip = Clip.create(clip_name, media_id, clip_opts)

    command:set_parameter("clip_id", clip.id)
    if master_clip_id and master_clip_id ~= "" then
        command:set_parameter("master_clip_id", master_clip_id)
    end
    if project_id_param then
        command:set_parameter("project_id", project_id_param)
    elseif master_clip and master_clip.project_id then
        command:set_parameter("project_id", master_clip.project_id)
    end

    local saved, clip_occlusion_actions = clip:save(db)
    if saved then
        if clip_occlusion_actions and #clip_occlusion_actions > 0 then
            record_occlusion_actions(command, clip.owner_sequence_id or sequence_id, clip_occlusion_actions)
        end
        if #copied_properties > 0 then
            delete_properties_for_clip(clip.id)
            if not insert_properties_for_clip(clip.id, copied_properties) then
                print(string.format("WARNING: Insert: Failed to copy properties from master clip %s", tostring(master_clip_id)))
            end
        end
        -- Advance playhead to end of inserted clip (if requested)
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead then
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_playhead_value(insert_time + duration)
        end

        local insert_payload = clip_insert_payload(clip, sequence_id)
        if insert_payload then
            add_insert_mutation(command, insert_payload.track_sequence_id, insert_payload)
        end

        print(string.format("✅ Inserted clip at %dms, rippled %d clips forward by %dms",
            insert_time, #clips_to_ripple, duration))
        return true
    else
        print("WARNING: Insert: Failed to save clip")
        return false
    end
end

-- OVERWRITE: Add clip at playhead, trimming/replacing existing clips
command_executors["Overwrite"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Overwrite command")
    end

    local media_id = command:get_parameter("media_id")
    local track_id = command:get_parameter("track_id")
    local overwrite_time = command:get_parameter("overwrite_time")
    local duration = command:get_parameter("duration_value") or command:get_parameter("duration")
    local source_in = command:get_parameter("source_in_value") or command:get_parameter("source_in") or 0
    local source_out = command:get_parameter("source_out_value") or command:get_parameter("source_out")
    local master_clip_id = command:get_parameter("master_clip_id")
    local project_id_param = command:get_parameter("project_id")
    local sequence_id = resolve_sequence_for_track(command:get_parameter("sequence_id"), track_id)
    if sequence_id and sequence_id ~= "" then
        command:set_parameter("sequence_id", sequence_id)
    end

    local Clip = require('models.clip')
    local master_clip = nil
    local copied_properties = {}
    if master_clip_id and master_clip_id ~= "" then
        master_clip = Clip.load_optional(master_clip_id, db)
        if not master_clip then
            print(string.format("WARNING: Overwrite: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
            master_clip_id = nil
        end
    end

    if master_clip and (not media_id or media_id == "") then
        media_id = master_clip.media_id
    end

    if not media_id or media_id == "" or not track_id or track_id == "" then
        print("WARNING: Overwrite: Missing media_id or track_id")
        return false
    end

    if master_clip then
        if not duration or duration <= 0 then
            duration = master_clip.duration or ((master_clip.source_out or 0) - (master_clip.source_in or 0))
        end
        if not source_out or source_out <= source_in then
            source_in = master_clip.source_in or source_in
            source_out = master_clip.source_out or (source_in + duration)
        end
        copied_properties = ensure_copied_properties(command, master_clip_id)
    end

    if (not master_clip_id or master_clip_id == "") then
        local fallback_master = ensure_master_clip_for_media(command, media_id, {
            name = command:get_parameter("clip_name"),
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            project_id = project_id_param
        })
        if fallback_master then
            master_clip_id = fallback_master
            command:set_parameter("master_clip_id", master_clip_id)
        end
    end

    if not overwrite_time or not duration or duration <= 0 or not source_out or source_out <= source_in then
        print("WARNING: Overwrite: Missing or invalid overwrite_time, duration, or source range")
        return false
    end

    local overwrite_end = overwrite_time + duration

    -- Inspect overlaps to capture metadata and reuse IDs when overwriting whole clips
    local overlap_query = db:prepare([[
        SELECT id, start_value, duration_value
        FROM clips
        WHERE track_id = ?
        ORDER BY start_value ASC
    ]])

    if not overlap_query then
        print("WARNING: Overwrite: Failed to prepare overlap query")
        return false
    end

    overlap_query:bind_value(1, track_id)

    local overlapping = {}
    local reuse_clip_id = nil

    if overlap_query:exec() then
        while overlap_query:next() do
            local clip_id = overlap_query:value(0)
            local clip_start = overlap_query:value(1)
            local clip_duration = overlap_query:value(2)
            local clip_end = clip_start + clip_duration

            if clip_start < overwrite_end and clip_end > overwrite_time then
                table.insert(overlapping, {
                    id = clip_id,
                    start_value = clip_start,
                    duration = clip_duration,
                    end_time = clip_end
                })

                if clip_start >= overwrite_time and clip_end <= overwrite_end and not reuse_clip_id then
                    reuse_clip_id = clip_id
                end
            end
        end
    end

    if dry_run then
        return true, {affected_clips = overlapping}
    end

    if reuse_clip_id then
        command:set_parameter("overwrite_reused_clip_id", reuse_clip_id)
        if not command:get_parameter("overwrite_reused_clip_state") then
            local existing_clip = Clip.load_optional(reuse_clip_id, db)
            if existing_clip then
                command:set_parameter("overwrite_reused_clip_state", capture_clip_state(existing_clip))
            end
        end
    else
        command:clear_parameter("overwrite_reused_clip_id")
        command:clear_parameter("overwrite_reused_clip_state")
    end

    local existing_clip_id = command:get_parameter("clip_id")
    local clip_opts = {
        id = existing_clip_id or reuse_clip_id,
        project_id = project_id_param or (master_clip and master_clip.project_id),
        track_id = track_id,
        owner_sequence_id = sequence_id or command:get_parameter("sequence_id"),
        parent_clip_id = master_clip_id,
        source_sequence_id = master_clip and master_clip.source_sequence_id,
        start_value = overwrite_time,
        duration = duration,
        source_in = source_in,
        source_out = source_out,
        enabled = true,
        offline = master_clip and master_clip.offline,
    }
    local clip_name = command:get_parameter("clip_name") or (master_clip and master_clip.name) or "Overwrite Clip"
    local clip = Clip.create(clip_name, media_id, clip_opts)

    command:set_parameter("clip_id", clip.id)
    if master_clip_id and master_clip_id ~= "" then
        command:set_parameter("master_clip_id", master_clip_id)
    end
    if project_id_param then
        command:set_parameter("project_id", project_id_param)
    elseif master_clip and master_clip.project_id then
        command:set_parameter("project_id", master_clip.project_id)
    end

    local saved, actions = clip:save(db)
    if saved then
        if actions and #actions > 0 then
            record_occlusion_actions(command, clip.owner_sequence_id or sequence_id, actions)
            command:set_parameter("occlusion_actions", actions)
        end
        if #copied_properties > 0 then
            delete_properties_for_clip(clip.id)
            if not insert_properties_for_clip(clip.id, copied_properties) then
                print(string.format("WARNING: Overwrite: Failed to copy properties from master clip %s", tostring(master_clip_id)))
            end
        end
        -- Advance playhead to end of overwritten clip (if requested)
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead then
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_playhead_value(overwrite_time + duration)
        end

        local mutation_sequence = clip.owner_sequence_id or sequence_id
        local inserted = (reuse_clip_id == nil)
        if inserted then
            local insert_payload = clip_insert_payload(clip, mutation_sequence)
            if insert_payload then
                add_insert_mutation(command, insert_payload.track_sequence_id, insert_payload)
            end
        else
            local update_payload = clip_update_payload(clip, mutation_sequence)
            if update_payload then
                add_update_mutation(command, update_payload.track_sequence_id, update_payload)
            end
        end

        command:set_parameter("__skip_sequence_replay_on_undo", true)

        print(string.format("✅ Overwrote at %dms", overwrite_time))
        return true
    else
        print("WARNING: Overwrite: Failed to save clip")
        return false
    end
end

command_undoers["Overwrite"] = function(command)
    print("Undoing Overwrite command")
    local sequence_id = command:get_parameter("sequence_id")
    local occlusion_actions = command:get_parameter("occlusion_actions") or {}
    local reused_clip_id = command:get_parameter("overwrite_reused_clip_id")
    local clip_id = command:get_parameter("clip_id")

    if reused_clip_id and reused_clip_id ~= "" then
        local snapshot = command:get_parameter("overwrite_reused_clip_state")
        if snapshot then
            local restored = restore_clip_state(snapshot)
            if restored then
                local payload = clip_update_payload(restored, sequence_id or restored.owner_sequence_id or restored.track_sequence_id)
                if payload then
                    add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
                end
            else
                print(string.format("WARNING: Undo Overwrite: Failed to restore reused clip %s", tostring(reused_clip_id)))
            end
        else
            print(string.format("WARNING: Undo Overwrite: Missing snapshot for reused clip %s", tostring(reused_clip_id)))
        end
    elseif clip_id and clip_id ~= "" then
        delete_clips_by_id(command, sequence_id, {clip_id})
    end

    revert_occlusion_actions(occlusion_actions, command, sequence_id)
    flush_timeline_mutations(command, sequence_id)

    print("✅ Undo Overwrite: Restored overlapped clips and selection state")
    return true
end

-- MOVE CLIP TO TRACK: Move a clip from one track to another (same timeline position)
command_executors["MoveClipToTrack"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing MoveClipToTrack command")
    end

    local clip_id = command:get_parameter("clip_id")
    local target_track_id = command:get_parameter("target_track_id")

    if not clip_id or clip_id == "" then
        print("WARNING: MoveClipToTrack: Missing clip_id")
        return false
    end

    if not target_track_id or target_track_id == "" then
        print("WARNING: MoveClipToTrack: Missing target_track_id")
        return false
    end

    -- Load the clip
    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)

    if not clip then
        print(string.format("WARNING: MoveClipToTrack: Clip %s not found", clip_id))
        return false
    end

    local mutation_sequence = clip.owner_sequence_id or clip.track_sequence_id
    if (not mutation_sequence or mutation_sequence == "") and clip.track_id then
        local seq_lookup = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
        if seq_lookup then
            seq_lookup:bind_value(1, clip.track_id)
            if seq_lookup:exec() and seq_lookup:next() then
                mutation_sequence = seq_lookup:value(0)
            end
            seq_lookup:finalize()
        end
    end
    if not mutation_sequence or mutation_sequence == "" then
        local target_lookup = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
        if target_lookup then
            target_lookup:bind_value(1, target_track_id)
            if target_lookup:exec() and target_lookup:next() then
                mutation_sequence = target_lookup:value(0)
            end
            target_lookup:finalize()
        end
    end
    if not mutation_sequence or mutation_sequence == "" then
        print("WARNING: MoveClipToTrack: Unable to resolve sequence for clip " .. tostring(clip_id))
        return false
    end
    clip.owner_sequence_id = clip.owner_sequence_id or mutation_sequence

    -- Save original track for undo (store as parameter)
    command:set_parameter("original_track_id", clip.track_id)

    -- DRY RUN: Return preview data without executing
    if dry_run then
        return true, {
            clip_id = clip_id,
            original_track_id = clip.track_id,
            new_track_id = target_track_id
        }
    end

    -- EXECUTE: Update clip's track
    clip.track_id = target_track_id

    local save_opts = nil
    local skip_occlusion = command:get_parameter("skip_occlusion") == true
    local pending_new_start = command:get_parameter("pending_new_start_value")
    if skip_occlusion or pending_new_start then
        save_opts = save_opts or {}
        if skip_occlusion then
            save_opts.skip_occlusion = true
        end
        if pending_new_start then
            local pending_duration = command:get_parameter("pending_duration") or clip.duration
            save_opts.pending_clips = save_opts.pending_clips or {}
            save_opts.pending_clips[clip.id] = {
                start_value = pending_new_start,
                duration = pending_duration,
                tolerance = math.max(pending_duration or 0, frame_utils.frame_duration_ms())
            }
        end
    end

    if not clip:save(db, save_opts) then
        print(string.format("WARNING: MoveClipToTrack: Failed to save clip %s", clip_id))
        return false
    end

    local update = {
        clip_id = clip.id,
        track_id = clip.track_id,
        track_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
        start_value = clip.start_value,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out
    }

    local update_sequence = clip.owner_sequence_id or clip.track_sequence_id or mutation_sequence
    update.track_sequence_id = update_sequence
    add_update_mutation(command, update_sequence, update)

    print(string.format("✅ Moved clip %s to track %s", clip_id, target_track_id))
    return true
end

command_executors["RippleDelete"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing RippleDelete command")
    end

    local track_id = command:get_parameter("track_id")
    local gap_start = command:get_parameter("gap_start")
    local gap_duration = command:get_parameter("gap_duration")
    local sequence_id = command:get_parameter("sequence_id")

    if not track_id or gap_start == nil or not gap_duration or gap_duration <= 0 then
        print("WARNING: RippleDelete: Missing or invalid parameters")
        return false
    end

    if not sequence_id or sequence_id == "" then
        local seq_query = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
        if seq_query then
            seq_query:bind_value(1, track_id)
            if seq_query:exec() and seq_query:next() then
                sequence_id = seq_query:value(0)
            end
            seq_query:finalize()
        end
    end

    if not sequence_id or sequence_id == "" then
        print("WARNING: RippleDelete: Unable to determine sequence for track " .. tostring(track_id))
        return false
    end

    local gap_end = gap_start + gap_duration

    local function ensure_global_gap_is_clear()
        local gap_query = db:prepare([[
            SELECT id, track_id, start_value, start_value + duration_value AS end_time
            FROM clips
            WHERE owner_sequence_id = ?
              AND NOT (start_value >= ? OR (start_value + duration_value) <= ?)
        ]])
        if not gap_query then
            print("ERROR: RippleDelete: Failed to prepare gap validation query")
            return false
        end
        gap_query:bind_value(1, sequence_id)
        gap_query:bind_value(2, gap_end)
        gap_query:bind_value(3, gap_start)

        local blocking_clips = {}
        if gap_query:exec() then
            while gap_query:next() do
                table.insert(blocking_clips, {
                    clip_id = gap_query:value(0),
                    track_id = gap_query:value(1),
                    start_value = gap_query:value(2),
                    end_time = gap_query:value(3)
                })
            end
        end
        gap_query:finalize()

        if #blocking_clips > 0 then
            local messages = {}
            for index, info in ipairs(blocking_clips) do
                messages[index] = string.format(
                    "clip %s on track %s (%d–%dms)",
                    tostring(info.clip_id),
                    tostring(info.track_id),
                    tonumber(info.start_value) or 0,
                    tonumber(info.end_time) or 0
                )
            end
            print("WARNING: RippleDelete blocked because the gap is not clear across all tracks: " .. table.concat(messages, "; "))
            return false
        end

        return true
    end

    if not ensure_global_gap_is_clear() then
        return false
    end

    local moved_clips = {}
    local query = db:prepare([[
        SELECT id, start_value, track_id
        FROM clips
        WHERE owner_sequence_id = ? AND start_value >= ?
        ORDER BY start_value ASC
    ]])
    if not query then
        print("ERROR: RippleDelete: Failed to prepare clip query")
        return false
    end
    query:bind_value(1, sequence_id)
    query:bind_value(2, gap_end)

    local clip_ids = {}
    if query:exec() then
        while query:next() do
            table.insert(clip_ids, {
                id = query:value(0),
                start_value = query:value(1),
                track_id = query:value(2)
            })
        end
    end
    query:finalize()

    if dry_run then
        return true, {
            track_id = track_id,
            gap_start = gap_start,
            gap_duration = gap_duration,
            clip_count = #clip_ids
        }
    end

    local Clip = require('models.clip')
    for _, info in ipairs(clip_ids) do
        local clip = Clip.load(info.id, db)
        if not clip then
            print(string.format("WARNING: RippleDelete: Clip %s not found", tostring(info.id)))
            return false
        end

        local original_start = clip.start_value
            clip.start_value = math.max(0, clip.start_value - gap_duration)

        local saved = clip:save(db, {skip_occlusion = true})
        if not saved then
            print(string.format("ERROR: RippleDelete: Failed to save clip %s", tostring(info.id)))
            return false
        end
        local update_payload = clip_update_payload(clip, sequence_id)
        if update_payload then
            add_update_mutation(command, update_payload.track_sequence_id, update_payload)
        end

        table.insert(moved_clips, {
            clip_id = info.id,
            original_start = original_start,
            track_id = info.track_id,
        })
    end

    command:set_parameter("ripple_track_id", track_id)
    command:set_parameter("ripple_gap_start", gap_start)
    command:set_parameter("ripple_sequence_id", sequence_id)
    command:set_parameter("ripple_gap_duration", gap_duration)
    command:set_parameter("ripple_moved_clips", moved_clips)

    print(string.format("✅ Ripple deleted gap on track %s (moved %d clip(s) across sequence %s)", tostring(track_id), #moved_clips, tostring(sequence_id)))
    return true
end

command_undoers["RippleDelete"] = function(command)
    local moved_clips = command:get_parameter("ripple_moved_clips")
    if not moved_clips or #moved_clips == 0 then
        return true
    end

    local Clip = require('models.clip')
    for _, info in ipairs(moved_clips) do
        local clip = Clip.load(info.clip_id, db)
        if clip then
            clip.start_value = info.original_start
            local saved = clip:save(db, {skip_occlusion = true})
            if not saved then
                print(string.format("WARNING: RippleDelete undo: Failed to restore clip %s", tostring(info.clip_id)))
            end
        end
    end

    print("✅ Undo RippleDelete: Restored clip positions")
    return true
end

local function collect_edit_points()
    local timeline_state = require('ui.timeline.timeline_state')
    local clips = timeline_state.get_clips() or {}
    local point_map = {[0] = true}

    local function add_point(value)
        if type(value) == "number" then
            point_map[value] = true
        end
    end

    for _, clip in ipairs(clips) do
        local start_value = clip.start_value or clip.start or clip.startTime
        local duration = clip.duration_value or clip.duration or clip.length or clip.duration_ms

        add_point(start_value)
        if type(start_value) == "number" and type(duration) == "number" then
            add_point(start_value + duration)
        end
    end

    local points = {}
    for value in pairs(point_map) do
        table.insert(points, value)
    end
    table.sort(points)
    return points
end

command_executors["DeselectAll"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing DeselectAll command")
    end

    if dry_run then
        return true
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local current_clips = timeline_state.get_selected_clips() or {}
    local current_edges = timeline_state.get_selected_edges() or {}

    if #current_clips == 0 and #current_edges == 0 then
        print("DeselectAll: nothing currently selected")
    end

    timeline_state.set_selection({})
    timeline_state.clear_edge_selection()

    print("✅ Deselected all clips and edges")
    return true
end

command_executors["SelectAll"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing SelectAll command")
    end

    local focus_manager_ok, focus_manager = pcall(require, "ui.focus_manager")
    local focused_panel = nil
    if focus_manager_ok and focus_manager and focus_manager.get_focused_panel then
        focused_panel = focus_manager.get_focused_panel()
    end

    if focused_panel == "project_browser" then
        if dry_run then
            return true
        end
        local ok, result = pcall(function()
            local project_browser = require("ui.project_browser")
            if project_browser and project_browser.select_all_items then
                return project_browser.select_all_items()
            end
            return false, "Project browser select_all not available"
        end)
        if ok and result then
            print("✅ Selected all items in Project Browser")
            return true
        end
        print(string.format("SelectAll (Project Browser) failed: %s", result or "unknown error"))
        return false
    end

    local timeline_state = require('ui.timeline.timeline_state')
    if dry_run then
        return true, {total_clips = #(timeline_state.get_clips() or {})}
    end

    local all_clips = timeline_state.get_clips() or {}
    if #all_clips == 0 then
        timeline_state.set_selection({})
        timeline_state.clear_edge_selection()
        print("SelectAll: no clips available to select")
        return true
    end

    timeline_state.set_selection(all_clips)
    timeline_state.clear_edge_selection()
    print(string.format("✅ Selected all %d clip(s)", #all_clips))
    return true
end

command_executors["RenameItem"] = function(command)
    local target_type = command:get_parameter("target_type")
    local target_id = command:get_parameter("target_id")
    local project_id = command:get_parameter("project_id") or command.project_id or "default_project"
    local new_name = trim_string(command:get_parameter("new_name"))

    if not target_type or target_type == "" then
        set_last_error("RenameItem: Missing target_type")
        return false
    end
    if not target_id or target_id == "" then
        set_last_error("RenameItem: Missing target_id")
        return false
    end
    if new_name == "" then
        set_last_error("RenameItem: New name cannot be empty")
        return false
    end

    local success, previous_or_err = perform_item_rename(target_type, target_id, new_name, project_id)
    if not success then
        set_last_error(previous_or_err or "RenameItem failed")
        return false
    end

    command:set_parameter("target_type", target_type)
    command:set_parameter("target_id", target_id)
    command:set_parameter("project_id", project_id)
    command:set_parameter("previous_name", previous_or_err or "")
    command:set_parameter("final_name", new_name)
    return true
end

command_undoers["RenameItem"] = function(command)
    local previous_name = command:get_parameter("previous_name")
    if not previous_name or previous_name == "" then
        return true
    end
    local target_type = command:get_parameter("target_type")
    local target_id = command:get_parameter("target_id")
    local project_id = command:get_parameter("project_id") or command.project_id or "default_project"

    local success, err = perform_item_rename(target_type, target_id, previous_name, project_id)
    if not success then
        set_last_error(err or "UndoRenameItem failed")
        return false
    end
    return true
end

command_executors["ToggleClipEnabled"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing ToggleClipEnabled command")
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local active_sequence_id = command:get_parameter("sequence_id")
    if (not active_sequence_id or active_sequence_id == "") and timeline_state and timeline_state.get_sequence_id then
        active_sequence_id = timeline_state.get_sequence_id()
        if active_sequence_id and active_sequence_id ~= "" then
            command:set_parameter("sequence_id", active_sequence_id)
        end
    end

    local toggles = command:get_parameter("clip_toggles")
    if not toggles or #toggles == 0 then
        local clip_ids = command:get_parameter("clip_ids")

        if not clip_ids or #clip_ids == 0 then
            local selected_clips = timeline_state.get_selected_clips() or {}
            clip_ids = {}
            for _, clip in ipairs(selected_clips) do
                if clip and clip.id then
                    table.insert(clip_ids, clip.id)
                end
            end
        end

        if not clip_ids or #clip_ids == 0 then
            print("ToggleClipEnabled: No clips selected")
            return false
        end

        local Clip = require('models.clip')
        toggles = {}
        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load_optional(clip_id, db)
            if clip then
                local enabled_before = clip.enabled ~= false
                table.insert(toggles, {
                    clip_id = clip_id,
                    enabled_before = enabled_before,
                    enabled_after = not enabled_before,
                })
            else
                print(string.format("WARNING: ToggleClipEnabled: Clip %s not found", tostring(clip_id)))
            end
        end

        if #toggles == 0 then
            print("ToggleClipEnabled: No valid clips to toggle")
            return false
        end

        command:set_parameter("clip_toggles", toggles)
    end

    if dry_run then
        return true, {clip_toggles = toggles}
    end

    command:set_parameter("__skip_sequence_replay", true)

    local Clip = require('models.clip')
    local toggled = 0
    for _, toggle in ipairs(toggles) do
        local clip = Clip.load_optional(toggle.clip_id, db)
        if clip then
            clip.enabled = toggle.enabled_after and true or false
            if clip:save(db, {skip_occlusion = true}) then
                record_clip_enabled_mutation(command, clip)
                toggled = toggled + 1
            else
                print(string.format("ERROR: ToggleClipEnabled: Failed to save clip %s", tostring(toggle.clip_id)))
                return false
            end
        else
            print(string.format("WARNING: ToggleClipEnabled: Clip %s missing during execution", tostring(toggle.clip_id)))
        end
    end

    print(string.format("✅ Toggled enabled state for %d clip(s)", toggled))
    return toggled > 0
end

command_undoers["ToggleClipEnabled"] = function(command)
    local toggles = command:get_parameter("clip_toggles")
    if not toggles or #toggles == 0 then
        return true
    end

    local Clip = require('models.clip')
    local restored = 0
    for _, toggle in ipairs(toggles) do
        local clip = Clip.load_optional(toggle.clip_id, db)
        if clip then
            clip.enabled = toggle.enabled_before and true or false
            if clip:save(db, {skip_occlusion = true}) then
                record_clip_enabled_mutation(command, clip)
                restored = restored + 1
            else
                print(string.format("WARNING: ToggleClipEnabled undo: Failed to restore clip %s", tostring(toggle.clip_id)))
            end
        end
    end

    flush_timeline_mutations(command, command:get_parameter("sequence_id"))

    print(string.format("✅ Undo ToggleClipEnabled: Restored %d clip(s)", restored))
    return true
end

if command_redoers then
    command_redoers["ToggleClipEnabled"] = function(command)
        local toggles = command:get_parameter("clip_toggles")
        if not toggles or #toggles == 0 then
            return true
        end

        local Clip = require('models.clip')
        local reapplied = 0
        for _, toggle in ipairs(toggles) do
            local clip = Clip.load_optional(toggle.clip_id, db)
            if clip then
                clip.enabled = toggle.enabled_after and true or false
                if clip:save(db, {skip_occlusion = true}) then
                    record_clip_enabled_mutation(command, clip)
                    reapplied = reapplied + 1
                else
                    print(string.format("WARNING: ToggleClipEnabled redo: Failed to reapply clip %s", tostring(toggle.clip_id)))
                end
            end
        end

        flush_timeline_mutations(command, command:get_parameter("sequence_id"))

        print(string.format("✅ Redo ToggleClipEnabled: Reapplied %d clip(s)", reapplied))
        return true
    end
end

command_executors["RippleDeleteSelection"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing RippleDeleteSelection command")
    end

    local clip_ids = command:get_parameter("clip_ids")
    local timeline_state = require('ui.timeline.timeline_state')

    if (not clip_ids or #clip_ids == 0) and timeline_state and timeline_state.get_selected_clips then
        local selected = timeline_state.get_selected_clips() or {}
        clip_ids = {}
        for _, clip in ipairs(selected) do
            if type(clip) == "table" then
                if clip.id then
                    table.insert(clip_ids, clip.id)
                elseif clip.clip_id then
                    table.insert(clip_ids, clip.clip_id)
                end
            elseif type(clip) == "string" then
                table.insert(clip_ids, clip)
            end
        end
    end

    if not clip_ids or #clip_ids == 0 then
        print("RippleDeleteSelection: No clips selected")
        return false
    end

    local Clip = require('models.clip')
    local clips = {}
    local clip_ids_for_delete = {}
    local window_start = nil
    local window_end = nil

    for _, clip_id in ipairs(clip_ids) do
        local clip = Clip.load_optional(clip_id, db)
        if clip then
            clips[#clips + 1] = clip
            local clip_start = clip.start_value or 0
            local clip_end = clip_start + (clip.duration or 0)
            window_start = window_start and math.min(window_start, clip_start) or clip_start
            window_end = window_end and math.max(window_end, clip_end) or clip_end
            table.insert(clip_ids_for_delete, clip.id)
        else
            print(string.format("WARNING: RippleDeleteSelection: Clip %s not found", tostring(clip_id)))
        end
    end

    if #clips == 0 then
        print("RippleDeleteSelection: No valid clips to delete")
        return false
    end

    window_start = window_start or 0
    window_end = window_end or window_start
    local shift_amount = window_end - window_start
    if shift_amount < 0 then
        shift_amount = 0
    end

    local sequence_id = command:get_parameter("sequence_id")
    if (not sequence_id or sequence_id == "") and #clips > 0 then
        local track_query = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
        if track_query then
            track_query:bind_value(1, clips[1].track_id)
            if track_query:exec() and track_query:next() then
                sequence_id = track_query:value(0)
            end
            track_query:finalize()
        end
    end

    if not sequence_id or sequence_id == "" then
        print("RippleDeleteSelection: Unable to determine sequence_id")
        return false
    end

    if dry_run then
        return true, {
            clip_count = #clips,
            shift_amount = shift_amount,
            window_start = window_start,
            window_end = window_end,
        }
    end

    local deleted_states = {}
    local selected_by_track = {}
    local global_segments_raw = {}
    local total_removed_duration = 0

    for _, clip in ipairs(clips) do
        table.insert(deleted_states, capture_clip_state(clip))
        total_removed_duration = total_removed_duration + (clip.duration or 0)
        selected_by_track[clip.track_id] = selected_by_track[clip.track_id] or {}
        table.insert(selected_by_track[clip.track_id], {
            start_value = clip.start_value or 0,
            duration = clip.duration or 0
        })
        table.insert(global_segments_raw, {
            start_value = clip.start_value or 0,
            duration = clip.duration or 0
        })
    end

    for _, clip in ipairs(clips) do
        if not clip:delete(db) then
            print(string.format("ERROR: RippleDeleteSelection: Failed to delete clip %s", tostring(clip.id)))
            return false
        end
    end
    if #clip_ids_for_delete > 0 then
        add_delete_mutation(command, sequence_id, clip_ids_for_delete)
    end

    local normalized_segments_by_track = {}
    for track_id, segments in pairs(selected_by_track) do
        normalized_segments_by_track[track_id] = normalize_segments(segments)
    end
    local global_segments = normalize_segments(global_segments_raw)
    local track_ids = load_sequence_track_ids(sequence_id)
    if (#track_ids == 0) then
        for track_id in pairs(selected_by_track) do
            table.insert(track_ids, track_id)
        end
    end

    local shifted_clips = {}
    local deleted_lookup = {}
    for _, deleted_id in ipairs(clip_ids_for_delete) do
        deleted_lookup[deleted_id] = true
    end

    local active_sequence_id = nil
    if timeline_state and timeline_state.get_sequence_id then
        local ok, seq = pcall(timeline_state.get_sequence_id)
        if ok then
            active_sequence_id = seq
        end
    end
    local timeline_track_cache_allowed = timeline_state
        and timeline_state.get_clips_for_track
        and active_sequence_id
        and active_sequence_id == sequence_id

    for _, track_id in ipairs(track_ids) do
        local segments = normalized_segments_by_track[track_id]
        if (not segments or #segments == 0) and global_segments and #global_segments > 0 then
            segments = global_segments
        end

        if segments and #segments > 0 then
            local seg_index = 1
            local cumulative_removed = 0

            local function process_shift_candidate(shifted_id, original_start)
                while seg_index <= #segments and (segments[seg_index].end_time or (segments[seg_index].start_value + (segments[seg_index].duration or 0))) <= original_start do
                    cumulative_removed = cumulative_removed + (segments[seg_index].duration or 0)
                    seg_index = seg_index + 1
                end

                if cumulative_removed > 0 then
                    local shift_clip = Clip.load_optional(shifted_id, db)
                    if shift_clip then
                        local new_start = math.max(0, original_start - cumulative_removed)
                        shift_clip.start_value = new_start
                        if shift_clip:save(db, {skip_occlusion = true}) then
                            table.insert(shifted_clips, {
                                clip_id = shifted_id,
                                original_start = original_start,
                                new_start = new_start,
                            })
                            local update_payload = clip_update_payload(shift_clip, sequence_id)
                            if update_payload then
                                add_update_mutation(command, update_payload.track_sequence_id or sequence_id, update_payload)
                            end
                        else
                            return false, string.format("ERROR: RippleDeleteSelection: Failed to save shifted clip %s", tostring(shifted_id))
                        end
                    end
                end
                return true
            end

            local processed = false
            if timeline_track_cache_allowed then
                local ok, track_clips = pcall(timeline_state.get_clips_for_track, track_id)
                if ok and track_clips and #track_clips > 0 then
                    processed = true
                    for _, entry in ipairs(track_clips) do
                        if not deleted_lookup[entry.id] then
                            local status, err = process_shift_candidate(entry.id, entry.start_value or 0)
                            if status == false then
                                print(err)
                                return false
                            end
                        end
                    end
                end
            end

            if not processed then
                local shift_query = db:prepare([[SELECT id, start_value FROM clips WHERE track_id = ? ORDER BY start_value ASC]])
                if not shift_query then
                    print("ERROR: RippleDeleteSelection: Failed to prepare per-track shift query")
                    return false
                end
                shift_query:bind_value(1, track_id)

                if shift_query:exec() then
                    while shift_query:next() do
                        local shifted_id = shift_query:value(0)
                        local original_start = shift_query:value(1) or 0
                        local status, err = process_shift_candidate(shifted_id, original_start)
                        if status == false then
                            shift_query:finalize()
                            print(err)
                            return false
                        end
                    end
                else
                    shift_query:finalize()
                    print("ERROR: RippleDeleteSelection: Failed to execute per-track shift query")
                    return false
                end

                shift_query:finalize()
            end
        end
    end

    command:set_parameter("ripple_selection_deleted_clips", deleted_states)
    command:set_parameter("ripple_selection_shifted", shifted_clips)
    command:set_parameter("ripple_selection_shift_amount", total_removed_duration)
    command:set_parameter("ripple_selection_total_removed", total_removed_duration)
    command:set_parameter("ripple_selection_window_start", window_start)
    command:set_parameter("ripple_selection_window_end", window_end)
    command:set_parameter("ripple_selection_sequence_id", sequence_id)

    if timeline_state then
        if timeline_state.set_selection then
            timeline_state.set_selection({})
        end
        if timeline_state.clear_edge_selection then
            timeline_state.clear_edge_selection()
        end
        if timeline_state.clear_gap_selection then
            timeline_state.clear_gap_selection()
        end
        if timeline_state.persist_state_to_db then
            timeline_state.persist_state_to_db()
        end
    end

    print(string.format("✅ Ripple delete selection: removed %d clip(s), shifted %d clip(s) by %dms",
        #clips, #shifted_clips, shift_amount))
    return true
end

command_undoers["RippleDeleteSelection"] = function(command)
    local deleted_states = command:get_parameter("ripple_selection_deleted_clips") or {}
    local shifted_clips = command:get_parameter("ripple_selection_shifted") or {}
    local shift_amount = command:get_parameter("ripple_selection_shift_amount") or command:get_parameter("ripple_selection_total_removed") or 0
    local sequence_id = command:get_parameter("ripple_selection_sequence_id")

    local Clip = require('models.clip')

    for _, info in ipairs(shifted_clips) do
        local clip = Clip.load_optional(info.clip_id, db)
        if clip and info.original_start then
            clip.start_value = info.original_start
            if not clip:save(db, {skip_occlusion = true}) then
                print(string.format("WARNING: RippleDeleteSelection undo: Failed to restore shifted clip %s", tostring(info.clip_id)))
            else
                local update_payload = clip_update_payload(clip, sequence_id)
                if update_payload then
                    add_update_mutation(command, update_payload.track_sequence_id or sequence_id, update_payload)
                end
            end
        end
    end

    for _, state in ipairs(deleted_states) do
        local restored = restore_clip_state(state)
        if restored then
            local insert_payload = clip_insert_payload(restored, sequence_id or restored.owner_sequence_id)
            if insert_payload then
                add_insert_mutation(command, insert_payload.track_sequence_id or sequence_id, insert_payload)
            end
        end
    end

    flush_timeline_mutations(command, sequence_id)

    print(string.format("✅ Undo RippleDeleteSelection: restored %d clip(s)", #deleted_states))
    return true
end

command_executors["GoToStart"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing GoToStart command")
    end

    if dry_run then
        return true
    end

    local timeline_state = require('ui.timeline.timeline_state')
    timeline_state.set_playhead_value(0)
    print("✅ Moved playhead to start")
    return true
end

command_executors["GoToEnd"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing GoToEnd command")
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local clips = timeline_state.get_clips() or {}
    local max_end = 0
    for _, clip in ipairs(clips) do
        local start_value = clip.start_value
        local duration = clip.duration
        if start_value and duration then
            local clip_end = start_value + duration
            if clip_end > max_end then
                max_end = clip_end
            end
        end
    end

    if dry_run then
        return true, { timeline_end = max_end }
    end

    timeline_state.set_playhead_value(max_end)
    print(string.format("✅ Moved playhead to timeline end (%dms)", max_end))
    return true
end

command_executors["Cut"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Cut command")
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local Clip = require('models.clip')

    local selected = timeline_state.get_selected_clips() or {}
    local unique = {}
    local clip_ids = {}

    local function add_clip_id(id)
        if id and id ~= "" and not unique[id] then
            unique[id] = true
            table.insert(clip_ids, id)
        end
    end

    for _, clip in ipairs(selected) do
        if type(clip) == "table" then
            add_clip_id(clip.id or clip.clip_id)
        elseif type(clip) == "string" then
            add_clip_id(clip)
        end
    end

    if #clip_ids == 0 then
        if not dry_run then
            print("Cut: nothing selected")
        end
        return true
    end

    if dry_run then
        return true, { clip_count = #clip_ids }
    end

    local sequence_id = command:get_parameter("sequence_id")
    if (not sequence_id or sequence_id == "") and timeline_state and timeline_state.get_sequence_id then
        sequence_id = timeline_state.get_sequence_id()
    end
    if sequence_id and sequence_id ~= "" then
        command:set_parameter("sequence_id", sequence_id)
    end

    local deleted_count = 0
    for _, clip_id in ipairs(clip_ids) do
        local clip = Clip.load_optional(clip_id, db)
        if clip then
            sequence_id = sequence_id or clip.owner_sequence_id or clip.track_sequence_id
            if clip:delete(db) then
                deleted_count = deleted_count + 1
            else
                print(string.format("WARNING: Cut: failed to delete clip %s", clip_id))
            end
        else
            print(string.format("WARNING: Cut: clip %s not found", clip_id))
        end
    end

    command:set_parameter("cut_clip_ids", clip_ids)
    if not sequence_id or sequence_id == "" then
        sequence_id = (timeline_state and timeline_state.get_sequence_id and timeline_state.get_sequence_id()) or "default_sequence"
    end
    add_delete_mutation(command, sequence_id, clip_ids)

    timeline_state.set_selection({})
    if timeline_state.clear_edge_selection then
        timeline_state.clear_edge_selection()
    end

    print(string.format("✅ Cut removed %d clip(s)", deleted_count))
    return true
end

command_executors["GoToPrevEdit"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing GoToPrevEdit command")
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local points = collect_edit_points()
    local playhead = timeline_state.get_playhead_value() or 0

    local target = 0
    for _, point in ipairs(points) do
        if point < playhead then
            target = point
        else
            break
        end
    end

    if dry_run then
        return true, { target = target }
    end

    timeline_state.set_playhead_value(target)
    print(string.format("✅ Moved playhead to previous edit (%dms)", target))
    return true
end

command_executors["GoToNextEdit"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing GoToNextEdit command")
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local points = collect_edit_points()
    local playhead = timeline_state.get_playhead_value() or 0

    local target = playhead
    for _, point in ipairs(points) do
        if point > playhead then
            target = point
            break
        end
    end

    if dry_run then
        return true, { target = target }
    end

    timeline_state.set_playhead_value(target)
    print(string.format("✅ Moved playhead to next edit (%dms)", target))
    return true
end

-- Undo for MoveClipToTrack: move clip back to original track
command_executors["UndoMoveClipToTrack"] = function(command)
    print("Executing UndoMoveClipToTrack command")

    local clip_id = command:get_parameter("clip_id")
    local original_track_id = command:get_parameter("original_track_id")

    if not clip_id or clip_id == "" then
        print("WARNING: UndoMoveClipToTrack: Missing clip_id")
        return false
    end

    if not original_track_id or original_track_id == "" then
        print("WARNING: UndoMoveClipToTrack: Missing original_track_id parameter")
        return false
    end

    -- Load the clip
    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)

    if not clip then
        print(string.format("WARNING: UndoMoveClipToTrack: Clip %s not found", clip_id))
        return false
    end

    -- Restore original track
    clip.track_id = original_track_id

    if not clip:save(db) then
        print(string.format("WARNING: UndoMoveClipToTrack: Failed to save clip %s", clip_id))
        return false
    end

    local update = {
        clip_id = clip.id,
        track_id = clip.track_id,
        track_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
        start_value = clip.start_value,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out
    }

    add_update_mutation(command, clip.owner_sequence_id or clip.track_sequence_id, update)

    print(string.format("✅ Restored clip %s to original track %s", clip_id, original_track_id))
    return true
end

-- NUDGE: Move clips or trim edges by a time offset (frame-accurate)
-- Inspects selection to determine whether to nudge clips (move) or edges (trim)
command_executors["Nudge"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Nudge command")
    end

    local nudge_amount_ms = command:get_parameter("nudge_amount_ms")  -- Can be negative
    local selected_clip_ids = command:get_parameter("selected_clip_ids")
    local selected_edges = command:get_parameter("selected_edges")  -- Array of {clip_id, edge_type}
    local clip_module = require('models.clip')

    -- Determine what we're nudging
    local nudge_type = "none"
    local updates_by_clip = {}
    local mutated_clip_ids = {}
    local timeline_state = require('ui.timeline.timeline_state')
    local active_sequence_id = command:get_parameter("sequence_id")
    if (not active_sequence_id or active_sequence_id == "") and timeline_state and timeline_state.get_sequence_id then
        active_sequence_id = timeline_state.get_sequence_id()
        if active_sequence_id and active_sequence_id ~= "" then
            command:set_parameter("sequence_id", active_sequence_id)
        end
    end

    local function register_update(clip)
        if not clip or not clip.id then
            return
        end
        mutated_clip_ids[clip.id] = true
        updates_by_clip[clip.id] = {
            clip_id = clip.id,
            track_id = clip.track_id,
            track_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
            start_value = clip.start_value,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }
    end

    local function apply_updates_if_needed(default_sequence_id)
        if next(updates_by_clip) == nil then
            return false
        end

        local updates = {}
        local sequence_id = default_sequence_id
        for _, update in pairs(updates_by_clip) do
            table.insert(updates, update)
            sequence_id = sequence_id or update.track_sequence_id
        end

        add_update_mutation(command, sequence_id, updates)
        return true
    end

    local function capture_updates_via_reload(default_sequence_id)
        if next(mutated_clip_ids) == nil then
            return false
        end
        local fallback_updates = {}
        local sequence_id = default_sequence_id
        local mutated_count = 0
        for clip_id in pairs(mutated_clip_ids) do
            mutated_count = mutated_count + 1
            local clip = clip_module.load_optional(clip_id, db)
            if clip then
                local update_payload = clip_update_payload(clip, sequence_id)
                if update_payload then
                    sequence_id = sequence_id or update_payload.track_sequence_id
                    table.insert(fallback_updates, update_payload)
                end
            end
        end
        if mutated_count == 0 then
            return false
        end
        if #fallback_updates == 0 then
            return false
        end
        sequence_id = sequence_id or fallback_updates[1].track_sequence_id
        if not sequence_id then
            return false
        end
        add_update_mutation(command, sequence_id, fallback_updates)
        return true
    end

    local function capture_updates_from_selection(default_sequence_id)
        local collected_ids = {}
        if type(selected_clip_ids) == "table" then
            for _, clip_id in ipairs(selected_clip_ids) do
                if clip_id then
                    collected_ids[clip_id] = true
                end
            end
        end
        if type(selected_edges) == "table" then
            for _, edge_info in ipairs(selected_edges) do
                if edge_info and edge_info.clip_id then
                    collected_ids[edge_info.clip_id] = true
                end
            end
        end
        if next(collected_ids) == nil then
            return false
        end
        local updates = {}
        local sequence_id = default_sequence_id
        for clip_id in pairs(collected_ids) do
            local clip = clip_module.load_optional(clip_id, db)
            if clip then
                local update_payload = clip_update_payload(clip, sequence_id)
                if update_payload then
                    sequence_id = sequence_id or update_payload.track_sequence_id
                    table.insert(updates, update_payload)
                end
            end
        end
        if #updates == 0 then
            return false
        end
        sequence_id = sequence_id or updates[1].track_sequence_id
        if not sequence_id then
            return false
        end
        add_update_mutation(command, sequence_id, updates)
        return true
    end

    if selected_edges and #selected_edges > 0 then
        nudge_type = "edges"
        local preview_clips = {}

        -- Nudge edges (trim clips)
        for _, edge_info in ipairs(selected_edges) do
            local Clip = require('models.clip')
            local clip = Clip.load(edge_info.clip_id, db)

            if not clip then
                print(string.format("WARNING: Nudge: Clip %s not found", edge_info.clip_id:sub(1,8)))
                goto continue
            end

            if edge_info.edge_type == "in" or edge_info.edge_type == "gap_before" then
                -- Trim in-point: adjust start_value and duration
                clip.start_value = math.max(0, clip.start_value + nudge_amount_ms)
                clip.duration = math.max(1, clip.duration - nudge_amount_ms)
                clip.source_in = clip.source_in + nudge_amount_ms
            elseif edge_info.edge_type == "out" or edge_info.edge_type == "gap_after" then
                -- Trim out-point: adjust duration only
                clip.duration = math.max(1, clip.duration + nudge_amount_ms)
                clip.source_out = clip.source_in + clip.duration
            end

            -- DRY RUN: Collect preview data
            if dry_run then
                table.insert(preview_clips, {
                    clip_id = clip.id,
                    new_start_value = clip.start_value,
                    new_duration = clip.duration,
                    edge_type = edge_info.edge_type
                })
            else
                mutated_clip_ids[clip.id] = true
                -- EXECUTE: Save changes
                if not clip:save(db) then
                    print(string.format("ERROR: Nudge: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
                    return false
                end
                register_update(clip)
            end

            ::continue::
        end

        -- DRY RUN: Return preview data without executing
        if dry_run then
            return true, {
                nudge_type = "edges",
                affected_clips = preview_clips
            }
        end

        print(string.format("✅ Nudged %d edge(s) by %dms", #selected_edges, nudge_amount_ms))
    elseif selected_clip_ids and #selected_clip_ids > 0 then
        nudge_type = "clips"
        local clip_links = require('core.clip_links')
        local clips_to_move = {}
        local processed_groups = {}

        for _, clip_id in ipairs(selected_clip_ids) do
            clips_to_move[clip_id] = true
            local link_group = clip_links.get_link_group(clip_id, db)
            if link_group then
                local link_group_id = clip_links.get_link_group_id(clip_id, db)
                if link_group_id and not processed_groups[link_group_id] then
                    processed_groups[link_group_id] = true
                    for _, link_info in ipairs(link_group) do
                        if link_info.enabled then
                            clips_to_move[link_info.clip_id] = true
                        end
                    end
                end
            end
        end

        local move_targets = {}
        local neighbor_clip_ids = {}
        local track_groups = {}
        local any_change = false
        local preview_clips = {}

        for clip_id, _ in pairs(clips_to_move) do
            local clip = clip_module.load(clip_id, db)
            if not clip then
                print(string.format("WARNING: Nudge: Clip %s not found", clip_id:sub(1,8)))
                clips_to_move[clip_id] = nil
                goto continue_collect_block
            end

            if clip.clip_kind and clip.clip_kind ~= TIMELINE_CLIP_KIND then
                clips_to_move[clip_id] = nil
                goto continue_collect_block
            end

            local new_start = math.max(0, clip.start_value + nudge_amount_ms)
            if new_start ~= clip.start_value then
                any_change = true
            end
            clip.__new_start = new_start
            mutated_clip_ids[clip.id] = true
            neighbor_clip_ids[#neighbor_clip_ids + 1] = clip.id
            table.insert(move_targets, clip)
            table.insert(preview_clips, {
                clip_id = clip.id,
                new_start_value = new_start,
                new_duration = clip.duration
            })

            local track_id = clip.track_id or clip.track_sequence_id
            if not track_id then
                print(string.format("WARNING: Nudge: Clip %s missing track_id", clip.id or "unknown"))
                goto continue_collect_block
            end
            local group = track_groups[track_id]
            if not group then
                group = {
                    clips = {},
                    pending = {},
                    before_min = nil,
                    before_max = nil,
                    after_min = nil,
                    after_max = nil,
                    sequence_id = clip.owner_sequence_id or clip.track_sequence_id or active_sequence_id
                }
                track_groups[track_id] = group
            end

            local clip_end = clip.start_value + clip.duration
            group.before_min = group.before_min and math.min(group.before_min, clip.start_value) or clip.start_value
            group.before_max = group.before_max and math.max(group.before_max, clip_end) or clip_end

            local new_end = new_start + clip.duration
            group.after_min = group.after_min and math.min(group.after_min, new_start) or new_start
            group.after_max = group.after_max and math.max(group.after_max, new_end) or new_end

            group.pending[clip.id] = {
                start_value = new_start,
                duration = clip.duration
            }

            table.insert(group.clips, clip)

            ::continue_collect_block::
        end

        if dry_run then
            return true, {
                nudge_type = "clips",
                affected_clips = preview_clips
            }
        end

        if any_change then
            local neighbor_windows = nil
            if timeline_state and timeline_state.describe_track_neighbors and #neighbor_clip_ids > 0 then
                neighbor_windows = timeline_state.describe_track_neighbors(active_sequence_id, neighbor_clip_ids)
            end
            for track_id, group in pairs(track_groups) do
                if group.after_max and group.after_min then
                    local block_duration = math.max(group.after_max - group.after_min, group.before_max - group.before_min)
                    if neighbor_windows and neighbor_windows[track_id] and neighbor_windows[track_id].window then
                        group.pending.__window_cache = { [track_id] = neighbor_windows[track_id].window }
                    else
                        group.pending.__window_cache = nil
                    end
                    local ok, err, actions = clip_mutator.resolve_occlusions(db, {
                        track_id = track_id,
                        start_value = group.after_min,
                        duration = block_duration,
                        pending_clips = group.pending
                    })
                    if not ok then
                        print(string.format("ERROR: Nudge: Failed to resolve occlusions on track %s: %s", tostring(track_id), tostring(err)))
                        return false
                    end
                    record_occlusion_actions(command, group.sequence_id, actions)
                end
            end

            for _, clip in ipairs(move_targets) do
                clip.start_value = clip.__new_start or clip.start_value
                if not clip:save(db, {skip_occlusion = true}) then
                    print(string.format("ERROR: Nudge: Failed to save clip %s", clip.id:sub(1,8)))
                    return false
                end
                register_update(clip)
            end
        end

        local total_moved = 0
        for _ in pairs(clips_to_move) do
            total_moved = total_moved + 1
        end

        local linked_count = total_moved - #selected_clip_ids
        if linked_count > 0 then
            print(string.format("✅ Nudged %d clip(s) + %d linked clip(s) by %dms",
                #selected_clip_ids, linked_count, nudge_amount_ms))
        else
            print(string.format("✅ Nudged %d clip(s) by %dms", #selected_clip_ids, nudge_amount_ms))
        end
    else
        print("WARNING: Nudge: Nothing selected")
        return false
    end

    -- Store what we nudged for undo
    command:set_parameter("nudge_type", nudge_type)

    local captured_mutations = apply_updates_if_needed(active_sequence_id)
    if not captured_mutations then
        local recovered = capture_updates_via_reload(active_sequence_id)
        if not recovered then
            recovered = capture_updates_from_selection(active_sequence_id)
        end
        if not recovered then
            print(string.format(
                "WARNING: Nudge: Failed to capture timeline mutations for timeline cache (sequence=%s)",
                tostring(active_sequence_id or "nil")))
        end
    end

    return true
end

-- Undo for Nudge: reverse the nudge by applying negative offset
command_executors["UndoNudge"] = function(command)
    print("Executing UndoNudge command")

    -- Just re-run nudge with inverted amount
    local nudge_amount_ms = command:get_parameter("nudge_amount_ms")
    command:set_parameter("nudge_amount_ms", -nudge_amount_ms)

    local result = command_executors["Nudge"](command)

    -- Restore original amount for redo
    command:set_parameter("nudge_amount_ms", -nudge_amount_ms)

    return result
end

-- Helper: Apply ripple edit to a single edge
-- Returns: ripple_time, success
local function apply_edge_ripple(clip, edge_type, delta_ms)
    -- GAP CLIPS ARE MATERIALIZED BEFORE CALLING THIS FUNCTION
    -- So edge_type is always "in" or "out", never "gap_after" or "gap_before"
    --
    -- CRITICAL: RIPPLE TRIM NEVER MOVES THE CLIP'S POSITION!
    -- Only duration and source_in/out change. Position stays FIXED.
    -- See docs/ripple-trim-semantics.md for detailed examples.

    if not clip.duration and clip.duration_value then
        clip.duration = clip.duration_value
    end
    if not clip.source_in and clip.source_in_value then
        clip.source_in = clip.source_in_value
    end
    if not clip.source_out and clip.source_out_value then
        clip.source_out = clip.source_out_value
    end
    if not clip.duration then
        error("apply_edge_ripple: clip missing duration")
    end

    local ripple_time
    local is_gap_clip = clip.is_gap == true
    local min_duration = 0
    local deletion_threshold = 1
    -- Gap clips have no media_id - they represent empty timeline space
    -- Skip media boundary checks for gaps (allow source_in/out to be anything)
    local has_source_media = (clip.media_id ~= nil)

    if edge_type == "in" then
        -- Ripple in-point trim
        -- Example: drag [ right +500ms
        -- BEFORE: start=3618, dur=3000, src_in=0
        -- AFTER:  start=3618, dur=2500, src_in=500  <-- position UNCHANGED!

        ripple_time = clip.start_value  -- Downstream clips shift from here

        local new_duration = clip.duration - delta_ms  -- 3000 - 500 = 2500
        if new_duration < 0 then
            return nil, false
        end

        -- DO NOT modify clip.start_value! Position stays fixed.
        clip.duration = new_duration  -- 3000 → 2500
        clip.duration_value = new_duration

        if has_source_media then
            -- Advance source to reveal less of the beginning
            local new_source_in = clip.source_in + delta_ms  -- 0 + 500 = 500

            if new_source_in < 0 then
                print(string.format("  BLOCKED: new_source_in=%d < 0 (can't rewind past start of media)", new_source_in))
                return nil, false  -- Hit media boundary
            end

            -- Check if new_source_in would exceed source_out
            if clip.source_out and new_source_in >= clip.source_out then
                print(string.format("  BLOCKED: new_source_in=%d >= source_out=%d (media window would invert)",
                    new_source_in, clip.source_out))
                return nil, false
            end

            clip.source_in = new_source_in  -- 0 → 500
            clip.source_in_value = new_source_in
        end

    elseif edge_type == "out" then
        -- Ripple out-point trim
        -- Example: drag ] right +500ms
        -- BEFORE: start=3618, dur=2500, src_out=2500
        -- AFTER:  start=3618, dur=3000, src_out=3000  <-- position UNCHANGED!

        ripple_time = clip.start_value + clip.duration  -- Downstream clips shift from here

        local new_duration = clip.duration + delta_ms  -- 2500 + 500 = 3000
        if new_duration < 0 then
            return nil, false
        end

        if has_source_media then
            -- CRITICAL: Check media boundary before applying
            -- Can't extend source_out beyond media duration
            local new_source_out = clip.source_in + new_duration

            -- Load media to check duration boundary
            local Media = require('models.media')
            local media = nil
            if clip.media_id then
                media = Media.load(clip.media_id, db)
            end

            if media and media.duration and media.duration > 0 then
                local max_source_out = media.duration
                local available_tail = max_source_out - (clip.source_in + clip.duration)
                if available_tail < 0 then available_tail = 0 end
                if delta_ms > available_tail then
                    if available_tail == 0 then
                        print(string.format("  BLOCKED: already at media end (%dms)", max_source_out))
                        delta_ms = 0
                    else
                        print(string.format("  CLAMPED: requested delta=%dms, available tail=%dms", delta_ms, available_tail))
                        delta_ms = available_tail
                    end
                    new_duration = clip.duration + delta_ms
                    new_source_out = clip.source_in + new_duration
                end
            end

            -- Check if new duration would be too small
            if new_duration < min_duration then
                print(string.format("  BLOCKED: new_duration=%d < %d (minimum duration)", new_duration, min_duration))
                return nil, false
            end

            clip.duration = math.max(min_duration, new_duration)
            clip.duration_value = clip.duration
            clip.source_out = new_source_out
            clip.source_out_value = new_source_out
        else
            -- No source media (generated clip) - no boundary check needed
            if new_duration < min_duration then
                return nil, false
            end
            clip.duration = math.max(min_duration, new_duration)
            clip.duration_value = clip.duration
        end
    end

    local deleted_clip = not is_gap_clip and clip.duration <= deletion_threshold
    if deleted_clip then
        clip.duration = 0
        clip.duration_value = 0
    end

    return ripple_time, true, deleted_clip
end

local function append_actions(target, actions)
    if not actions or target == nil then
        return
    end
    for _, action in ipairs(actions) do
        target[#target + 1] = action
    end
end

-- Shared gap ripple constraint:
-- Prevents shifting downstream clips left into stationary clips on ANY track before the ripple point.
-- Uses gap length as an additional closure limit.
local function calculate_gap_ripple_delta_range(clip, edge_type, all_clips, sequence_id)
    if not clip or not edge_type then
        return nil, nil
    end

    all_clips = all_clips or {}

    local ripple_time
    if edge_type == "in" then
        ripple_time = clip.start_value
    else
        ripple_time = clip.start_value + clip.duration
    end

    local stationary_clips = {}
    for _, c in ipairs(all_clips) do
        if c.start_value and c.duration and c.start_value < ripple_time then
            stationary_clips[#stationary_clips + 1] = c
        end
    end

    local max_shift = math.huge
    local min_shift = -math.huge

    for _, shifting_clip in ipairs(all_clips) do
        if shifting_clip.start_value and shifting_clip.duration and shifting_clip.start_value >= ripple_time then
            for _, stationary in ipairs(stationary_clips) do
                if shifting_clip.track_id == stationary.track_id then
                    local gap_between = shifting_clip.start_value - (stationary.start_value + stationary.duration)
                    if gap_between >= 0 then
                        if -gap_between > min_shift then
                            min_shift = -gap_between
                        end
                    else
                        if 0 > min_shift then
                            min_shift = 0
                        end
                    end
                end
            end
        end
    end

    -- Leave at least 0ms; if duration exists, limit closure to gap length
    local duration = tonumber(clip.duration) or 0
    if duration <= 0 then
        -- Derive span from nearest neighbor when duration wasn't recorded
        local left_end = 0
        local right_start = ripple_time
        for _, c in ipairs(all_clips) do
            if c.track_id == clip.track_id then
                local c_end = (c.start_value or 0) + (c.duration or 0)
                if c_end <= ripple_time and c_end > left_end then
                    left_end = c_end
                end
                if c.start_value and c.start_value >= ripple_time and c.start_value < right_start then
                    right_start = c.start_value
                end
            end
        end
        local inferred = right_start - left_end
        if inferred > 0 then
            duration = inferred
        end
    end
    local gap_limit = -(math.max(duration, 0) - 0)  -- allow closing the gap but not crossing left neighbor
    if gap_limit > min_shift then
        min_shift = gap_limit
    end

    -- Respect timeline start for gap_after trims
    if edge_type == "in" then
        local start_value = tonumber(clip.start_value) or 0
        local timeline_limit = -start_value
        if timeline_limit > min_shift then
            min_shift = timeline_limit
        end
    end

    local min_delta, max_delta
    if edge_type == "in" then
        min_delta = -max_shift
        max_delta = -min_shift
    else
        min_delta = min_shift
        max_delta = max_shift
    end

    local span = math.max(duration, 0)
    if edge_type == "out" and span > 0 then
        -- Do not allow closing past the actual gap length. Ensure min_shift honors at least the gap_floor.
        min_shift = math.min(min_shift, -span)
        min_delta = min_shift
    elseif edge_type == "in" and span > 0 then
        -- Symmetric guard for gap_after trims.
        max_delta = math.max(max_delta or span, span)
    end

    if min_delta == 0 and edge_type == "out" then
        print(string.format("DEBUG GAP CONSTRAINT anomaly: clip=%s start=%s dur=%s ripple_time=%s min_shift=%s max_shift=%s span=%s",
            tostring(clip.id), tostring(clip.start_value), tostring(clip.duration), tostring(ripple_time), tostring(min_shift), tostring(max_shift), tostring(duration)))
        for _, c in ipairs(all_clips or {}) do
            if c.track_id == clip.track_id then
                local c_end = (c.start_value or 0) + (c.duration or 0)
                print(string.format("  track clip %s [%s-%s]", tostring(c.id), tostring(c.start_value), tostring(c_end)))
            end
        end
    end

    if max_delta == 0 and edge_type == "in" then
        print(string.format("DEBUG GAP CONSTRAINT anomaly (in): clip=%s start=%s dur=%s ripple_time=%s min_shift=%s max_shift=%s span=%s",
            tostring(clip.id), tostring(clip.start_value), tostring(clip.duration), tostring(ripple_time), tostring(min_shift), tostring(max_shift), tostring(duration)))
        for _, c in ipairs(all_clips or {}) do
            if c.track_id == clip.track_id then
                local c_end = (c.start_value or 0) + (c.duration or 0)
                print(string.format("  track clip %s [%s-%s]", tostring(c.id), tostring(c.start_value), tostring(c_end)))
            end
        end
    end

    return min_delta, max_delta
end

local function compute_gap_bounds(reference_clip, edge_type, all_clips, neighbor_entry)
    local gap_start
    local gap_end

    if neighbor_entry then
        if edge_type == "gap_after" then
            gap_start = (reference_clip.start_value or 0) + (reference_clip.duration or 0)
            if neighbor_entry.right_neighbor then
                gap_end = neighbor_entry.right_neighbor.start_value or gap_start
            else
                gap_end = math.huge
            end
        else
            gap_end = reference_clip.start_value or 0
            if neighbor_entry.left_neighbor then
                local prev = neighbor_entry.left_neighbor
                gap_start = (prev.start_value or 0) + (prev.duration or 0)
            else
                gap_start = 0
            end
        end
        return gap_start, gap_end - gap_start
    end

    all_clips = all_clips or {}

    if edge_type == "gap_after" then
        gap_start = reference_clip.start_value + reference_clip.duration
        gap_end = math.huge
        for _, clip in ipairs(all_clips) do
            if clip.track_id == reference_clip.track_id and clip.start_value >= gap_start then
                gap_end = math.min(gap_end, clip.start_value)
            end
        end
    else
        gap_end = reference_clip.start_value
        gap_start = 0
        for _, clip in ipairs(all_clips) do
            if clip.track_id == reference_clip.track_id and clip.start_value + clip.duration <= gap_end then
                gap_start = math.max(gap_start, clip.start_value + clip.duration)
            end
        end
    end
    return gap_start, gap_end - gap_start
end

local function collect_downstream_clips(all_clips, excluded_ids, ripple_time)
    local clips = {}
    local floor_time = ripple_time - 1
    for _, other in ipairs(all_clips) do
        if other.start_value >= floor_time then
            if not excluded_ids or not excluded_ids[other.id] then
                clips[#clips + 1] = other
            end
        end
    end
    return clips
end

local function shift_clips(command, sequence_id, clips_to_shift, shift_amount, Clip, occlusion_actions, pending_moves, label, post_state_bucket)
    local context = label or "RippleEdit"
    for _, downstream_clip in ipairs(clips_to_shift) do
        local shift_clip = Clip.load(downstream_clip.id, db)
        if not shift_clip then
            print(string.format("WARNING: %s: Failed to load downstream clip %s", context, downstream_clip.id:sub(1,8)))
            goto continue_shift
        end

        shift_clip.start_value = shift_clip.start_value + shift_amount

        local save_opts = nil
        if pending_moves and next(pending_moves) ~= nil then
            save_opts = {pending_clips = pending_moves}
        end

        local ok, actions = shift_clip:save(db, save_opts)
        if not ok then
            return false, downstream_clip.id
        end
        append_actions(occlusion_actions, actions)

        local update_payload = clip_update_payload(shift_clip, sequence_id)
        if update_payload then
            add_update_mutation(command, update_payload.track_sequence_id, update_payload)
        end

        if pending_moves then
            pending_moves[shift_clip.id] = nil
        end

        if post_state_bucket then
            post_state_bucket[#post_state_bucket + 1] = capture_clip_state(shift_clip)
        end

        ::continue_shift::
    end

    return true
end

-- RippleEdit: Trim an edge and shift all downstream clips to close/open the gap
-- This is the standard NLE ripple edit - affects the timeline duration
-- Supports dry_run mode for preview without executing
command_executors["RippleEdit"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing RippleEdit command")
    end

    local raw_edge_info = command:get_parameter("edge_info")  -- {clip_id, edge_type, track_id}
    local edge_info = nil
    if raw_edge_info then
        edge_info = {
            clip_id = raw_edge_info.clip_id,
            edge_type = raw_edge_info.edge_type,
            track_id = raw_edge_info.track_id,
            trim_type = raw_edge_info.trim_type,
            type = raw_edge_info.type
        }
        if type(edge_info.clip_id) == "string" and edge_info.clip_id:find("^temp_gap_") then
            edge_info.clip_id = edge_info.clip_id:gsub("^temp_gap_", "")
        end
        command:set_parameter("edge_info", edge_info)
    end
    local delta_ms = command:get_parameter("delta_ms")    -- Positive = extend, negative = trim

    if not edge_info or not delta_ms then
        print("ERROR: RippleEdit missing parameters")
        return {success = false, error_message = "RippleEdit missing parameters"}
    end

    local Clip = require('models.clip')
    local database = require('core.database')
    local timeline_state = require('ui.timeline.timeline_state')
    local sequence_id = resolve_sequence_id_for_edges(command, edge_info)
    local frame_rate = frame_utils.default_frame_rate
    local seq_stmt = db:prepare("SELECT frame_rate FROM sequences WHERE id = ?")
    if seq_stmt then
        seq_stmt:bind_value(1, sequence_id)
        if seq_stmt:exec() and seq_stmt:next() then
            frame_rate = tonumber(seq_stmt:value(0)) or frame_rate
        end
        seq_stmt:finalize()
    end
    local pending_tolerance = frame_utils.frame_duration_ms(frame_rate)

    local function timeline_has_edge_clip()
        if not timeline_state or not timeline_state.get_clip_by_id then
            return false
        end
        if edge_info and edge_info.clip_id then
            local ok, clip_entry = pcall(timeline_state.get_clip_by_id, edge_info.clip_id)
            if not ok or not clip_entry then
                return false
            end
        end
        return true
    end

    local active_state_sequence = nil
    if timeline_state and timeline_state.get_sequence_id then
        local ok, maybe_sequence = pcall(timeline_state.get_sequence_id)
        if ok then
            active_state_sequence = maybe_sequence
        end
    end
    local timeline_state_ready = timeline_state
        and timeline_state.describe_track_neighbors
        and timeline_state.get_clips
        and timeline_state.get_clip_by_id
        and active_state_sequence
        and active_state_sequence == sequence_id
        and timeline_has_edge_clip()

    local function neighbor_entry_for_clip(clip)
        if not timeline_state_ready or not clip or not clip.id or not clip.track_id then
            return nil
        end
        local neighbors = timeline_state.describe_track_neighbors(sequence_id, {clip.id})
        if not neighbors then
            return nil
        end
        local track_entry = neighbors[clip.track_id]
        if not track_entry then
            return nil
        end
        if track_entry.per_clip and track_entry.per_clip[clip.id] then
            return track_entry.per_clip[clip.id]
        end
        return {
            left_neighbor = track_entry.left_neighbor,
            right_neighbor = track_entry.right_neighbor
        }
    end

    local all_clips = nil
    if timeline_state_ready then
        all_clips = timeline_state.get_clips()
    end
    if not all_clips then
        all_clips = database.load_clips(sequence_id)
    end

    local occlusion_actions = {}
    local post_states = {}
    local deleted_clip_ids = {}

    -- MATERIALIZE GAP CLIPS: Convert gap edges to temporary gap clip objects
    local gap_reference_clip = nil
    local clip, edge_type, is_gap_clip
    local original_start_value
    local original_duration
    if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
        local reference_clip = Clip.load_optional(edge_info.clip_id, db)
        local reference_missing = false
        if not reference_clip then
            local stored_start = command:get_parameter("gap_start_value")
            local stored_duration = command:get_parameter("gap_duration")
            if stored_start and stored_duration and edge_info.track_id and edge_info.track_id ~= "" then
                reference_clip = {
                    id = edge_info.clip_id or "",
                    track_id = edge_info.track_id,
                    start_value = stored_start,
                    duration = stored_duration
                }
                reference_missing = true
            else
                print("ERROR: RippleEdit: Reference clip not found and no stored gap bounds")
                return {success = false, error_message = "Reference clip not found"}
            end
        end
        gap_reference_clip = reference_clip

        -- Use stored gap boundaries if available (for deterministic replay)
        -- Otherwise calculate dynamically from adjacent clips
        local gap_start = command:get_parameter("gap_start_value")
        local gap_duration = command:get_parameter("gap_duration")
        local neighbor_metadata = neighbor_entry_for_clip(reference_clip)
        if not gap_start or not gap_duration then
            if not reference_missing then
                gap_start, gap_duration = compute_gap_bounds(reference_clip, edge_info.edge_type, all_clips, neighbor_metadata)
                if not dry_run then
                    command:set_parameter("gap_start_value", gap_start)
                    command:set_parameter("gap_duration", gap_duration)
                end
            else
                print("ERROR: RippleEdit: Missing gap bounds for replay")
                return {success = false, error_message = "Missing gap bounds"}
            end
        end
        -- If there is no actual gap, treat this as a normal clip edge (avoid materializing zero-length gaps)
        if gap_duration <= 0 then
            clip = reference_clip
            edge_type = "out"  -- gap_before translates to clip out edge
            is_gap_clip = false
            original_start_value = clip.start_value
            original_duration = clip.duration
        else
            original_start_value = gap_start
            original_duration = gap_duration

            -- Create temporary gap clip object (not saved to database)
            clip = {
                id = "temp_gap_" .. edge_info.clip_id,
                track_id = reference_clip.track_id,
                start_value = gap_start,
                duration = gap_duration,
                source_in = 0,
                source_out = gap_duration,
                is_gap = true
            }
            edge_type = edge_info.edge_type == "gap_after" and "in" or "out"  -- gap_after→in, gap_before→out
            is_gap_clip = true
        end
    else
        clip = Clip.load(edge_info.clip_id, db)
        if not clip then
            print("ERROR: RippleEdit: Clip not found")
            return {success = false, error_message = "Clip not found"}
        end
        edge_type = edge_info.edge_type
        is_gap_clip = false
        original_start_value = clip.start_value
        original_duration = clip.duration
    end

    -- CONSTRAINT CHECK: Clamp delta to valid range
    -- Frame alignment now automatic in Clip:save() for video tracks
    local constraints = require('core.timeline_constraints')

    -- For deterministic replay: use stored clamped_delta if available, otherwise calculate
    local clamped_delta = command:get_parameter("clamped_delta_ms")
    if not clamped_delta then
        -- For gap edits: use special ripple constraint logic
        -- For regular edits: use normal trim constraints
        if is_gap_clip then
        local min_delta, max_delta = calculate_gap_ripple_delta_range(clip, edge_type, all_clips, sequence_id)
        if not min_delta or not max_delta then
            print("ERROR: RippleEdit: Failed to calculate gap constraints")
            return {success = false, error_message = "Gap constraint calculation failed"}
        end
        clamped_delta = math.max(min_delta, math.min(max_delta, delta_ms))
    else
        -- Regular clip trim: use normal constraint logic (no frame snapping)
        -- Adjacent checks are skipped here; overlap prevention is handled below via gap checks.
        clamped_delta = constraints.clamp_trim_delta(clip, edge_type, delta_ms, all_clips, nil, nil, true)
    end

        -- Allow full deletion when dragging past the clip duration.
        if edge_type == "out" and clamped_delta < -original_duration then
            clamped_delta = -original_duration
        elseif edge_type == "in" and clamped_delta > original_duration then
            clamped_delta = original_duration
        end

        if clamped_delta ~= delta_ms and not dry_run then
            print(string.format("⚠️  Trim adjusted: %dms → %dms (collision)", delta_ms, clamped_delta))
        end

        -- Store clamped delta for deterministic replay
        command:set_parameter("clamped_delta_ms", clamped_delta)
    end

    delta_ms = clamped_delta

    if delta_ms == 0 then
        if dry_run then
            return true, {
                affected_clip = {
                    clip_id = clip.id,
                    new_start_value = clip.start_value,
                    new_duration = clip.duration
                },
                shifted_clips = {}
            }
        end
        print("RippleEdit: Delta clamped to 0ms – no timeline changes, skipping reload")
        command:set_parameter("__skip_timeline_reload", true)
        command:set_parameter("__skip_sequence_replay", true)
        command:set_parameter("__suppress_if_unchanged", true)
        return true
    end

    -- Save original state for undo (not needed for dry-run or gap clips)
    local original_clip_state = nil
    if not dry_run and not is_gap_clip then
        original_clip_state = capture_clip_state(clip)
    end

    -- Calculate ripple point and new clip dimensions (no mutation yet)
    local ripple_time, success, deleted_clip = apply_edge_ripple(clip, edge_type, delta_ms)
    if not success then
        return {success = false, error_message = "Ripple operation would violate clip or media constraints"}
    end

    -- Calculate actual shift amount for downstream clips based on the updated duration
    local original_end = original_start_value + original_duration

    local new_end = clip.start_value + clip.duration
    local shift_amount = new_end - original_end

    if not dry_run then
        print(string.format("RippleEdit: original_edge=%s, normalized_edge=%s, delta_ms=%d, shift_amount=%d, ripple_time=%d",
            edge_info.edge_type, edge_type, delta_ms, shift_amount, ripple_time))
    end

    if deleted_clip and not is_gap_clip then
        table.insert(deleted_clip_ids, clip.id)
    end

    -- Find all clips on ALL tracks that start after the ripple point
    -- Ripple affects the entire timeline to maintain sync across all tracks
    local excluded_ids = {[clip.id] = true}
    local clips_to_shift = collect_downstream_clips(all_clips, excluded_ids, ripple_time)

    local function build_pending_moves(shift_delta)
        if shift_delta == 0 or #clips_to_shift == 0 then
            return nil
        end
        local map = {}
        for _, downstream_clip in ipairs(clips_to_shift) do
            map[downstream_clip.id] = {
                start_value = downstream_clip.start_value + shift_delta,
                duration = downstream_clip.duration,
                tolerance = pending_tolerance
            }
        end
        return map
    end

    local pending_moves = build_pending_moves(shift_amount)

    if not dry_run then
        for _, other_clip in ipairs(clips_to_shift) do
            print(string.format("  Will shift clip %s from %d to %d", other_clip.id:sub(1,8), other_clip.start_value, other_clip.start_value + shift_amount))
        end
        print(string.format("RippleEdit: Found %d clips to shift", #clips_to_shift))
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        return true, {
            affected_clip = {
                clip_id = clip.id,
                new_start_value = clip.start_value,
                new_duration = clip.duration
            },
            shifted_clips = (function()
                local shifts = {}
                for _, downstream_clip in ipairs(clips_to_shift) do
                    table.insert(shifts, {
                        clip_id = downstream_clip.id,
                        new_start_value = downstream_clip.start_value + shift_amount
                    })
                end
                return shifts
            end)()
        }
    end

    -- EXECUTE: Actually save changes (skip for gap clips - they're not persisted)
        if not is_gap_clip then
            if deleted_clip then
                if not clip:delete(db) then
                    print(string.format("ERROR: RippleEdit: Failed to delete clip %s", edge_info.clip_id:sub(1,8)))
                    return {success = false, error_message = "Failed to delete clip"}
                end
                add_delete_mutation(command, sequence_id, clip.id)
            else
                local save_opts = nil
                if pending_moves and next(pending_moves) ~= nil then
                    save_opts = {pending_clips = pending_moves}
                end

                local ok, actions = clip:save(db, save_opts)
                if not ok then
                    print(string.format("ERROR: RippleEdit: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
                    return {success = false, error_message = "Failed to save clip"}
                end
                append_actions(occlusion_actions, actions)
                local update_payload = clip_update_payload(clip, sequence_id)
                if update_payload then
                    add_update_mutation(command, update_payload.track_sequence_id, update_payload)
                end

                post_states[#post_states + 1] = capture_clip_state(clip)

                if pending_moves then
                    local snapped_new_end = clip.start_value + clip.duration
                    shift_amount = snapped_new_end - original_end
                    pending_moves = build_pending_moves(shift_amount)
            end
        end
    end

    -- Shift all downstream clips
    local shift_ok, failing_clip_id = shift_clips(command, sequence_id, clips_to_shift, shift_amount, Clip, occlusion_actions, pending_moves, "RippleEdit", post_states)
    if not shift_ok then
        print(string.format("ERROR: RippleEdit: Failed to save downstream clip %s", failing_clip_id:sub(1,8)))
        return {success = false, error_message = "Failed to save downstream clip"}
    end

    -- Store state for undo
    command:set_parameter("original_clip_state", original_clip_state)
    command:set_parameter("shifted_clip_ids", (function()
        local ids = {}
        for _, c in ipairs(clips_to_shift) do table.insert(ids, c.id) end
        return ids
    end)())
    command:set_parameter("ripple_shift_amount", shift_amount)

    if #occlusion_actions > 0 then
        record_occlusion_actions(command, sequence_id, occlusion_actions)
        command:set_parameter("occlusion_actions", occlusion_actions)
    end
    if #deleted_clip_ids > 0 then
        command:set_parameter("deleted_clip_ids", deleted_clip_ids)
    end

    -- For gap clips, store the calculated boundaries for deterministic replay
    if is_gap_clip then
        command:set_parameter("gap_start_value", original_start_value)
        command:set_parameter("gap_duration", original_duration)
    end

    print(string.format("✅ Ripple edit: trimmed %s edge by %dms, shifted %d downstream clips",
        edge_info.edge_type, delta_ms, #clips_to_shift))

    command:set_parameter("ripple_post_states", post_states)
    command:set_parameter("__skip_sequence_replay_on_undo", true)
    command:set_parameter("__skip_sequence_replay_on_redo", true)
    command:set_parameter("__skip_sequence_replay_on_redo", true)

    return true
end

-- BatchRippleEdit: Trim multiple edges simultaneously with single timeline shift
-- Prevents cascading shifts when multiple edges are selected
command_executors["BatchRippleEdit"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing BatchRippleEdit command")
    end

    local edge_infos_raw = command:get_parameter("edge_infos")  -- Array of {clip_id, edge_type, track_id}
    local edge_infos = {}
    if edge_infos_raw then
        for _, edge in ipairs(edge_infos_raw) do
            local cleaned_id = edge.clip_id
            if type(cleaned_id) == "string" and cleaned_id:find("^temp_gap_") then
                cleaned_id = cleaned_id:gsub("^temp_gap_", "")
            end
            edge_infos[#edge_infos + 1] = {
                clip_id = cleaned_id,
                edge_type = edge.edge_type,
                track_id = edge.track_id,
                trim_type = edge.trim_type,
                type = edge.type
            }
        end
    end
    local delta_ms = command:get_parameter("delta_ms")
    local primary_edge = edge_infos and edge_infos[1] or nil
    local sequence_id = resolve_sequence_id_for_edges(command, primary_edge, edge_infos)

    if not edge_infos or not delta_ms or #edge_infos == 0 then
        print("ERROR: BatchRippleEdit missing parameters")
        return false
    end

    -- Persist sanitized edge infos so replay never sees materialized temp_gap ids
    command:set_parameter("edge_infos", edge_infos)

    local Clip = require('models.clip')
    local database = require('core.database')
    local timeline_state = require('ui.timeline.timeline_state')
    local original_states = {}
    local post_states = {}
    local earliest_ripple_time = math.huge  -- Track leftmost ripple point (determines which clips shift)
    local downstream_shift_amount = nil  -- Timeline length change (NOT summed across tracks)
    local preview_affected_clips = {}
    local occlusion_actions = {}
    local deleted_clip_ids = {}

    local function timeline_has_all_edge_clips()
        if not timeline_state or not timeline_state.get_clip_by_id then
            return false
        end
        for _, edge in ipairs(edge_infos) do
            if edge and edge.clip_id then
                local ok, clip_entry = pcall(timeline_state.get_clip_by_id, edge.clip_id)
                if not ok or not clip_entry then
                    return false
                end
            end
        end
        return true
    end

    local active_sequence_id = nil
    if timeline_state and timeline_state.get_sequence_id then
        local ok, seq = pcall(timeline_state.get_sequence_id)
        if ok then
            active_sequence_id = seq
        end
    end
    local timeline_state_ready = timeline_state
        and timeline_state.describe_track_neighbors
        and timeline_state.get_clips
        and timeline_state.get_clip_by_id
        and active_sequence_id
        and active_sequence_id == sequence_id
        and timeline_has_all_edge_clips()

    local neighbor_snapshot = nil
    if timeline_state_ready then
        local neighbor_ids = {}
        for _, edge in ipairs(edge_infos) do
            if edge and edge.clip_id then
                neighbor_ids[#neighbor_ids + 1] = edge.clip_id
            end
        end
        if #neighbor_ids > 0 then
            neighbor_snapshot = timeline_state.describe_track_neighbors(sequence_id, neighbor_ids)
        end
    end

    local function per_clip_neighbors(clip)
        if not neighbor_snapshot or not clip or not clip.track_id then
            return nil
        end
        local track_entry = neighbor_snapshot[clip.track_id]
        if not track_entry then
            return nil
        end
        if track_entry.per_clip and track_entry.per_clip[clip.id] then
            return track_entry.per_clip[clip.id]
        end
        return {
            left_neighbor = track_entry.left_neighbor,
            right_neighbor = track_entry.right_neighbor
        }
    end

    -- Load all clips once for gap materialization
    local all_clips = nil
    if timeline_state_ready then
        local ok, clips = pcall(timeline_state.get_clips)
        if ok and type(clips) == "table" then
            all_clips = clips
        end
    end
    if not all_clips then
        all_clips = database.load_clips(sequence_id)
    end

    -- Phase 0: Calculate constraints for ALL edges BEFORE any modifications
    -- Find the most restrictive constraint to ensure all edges can move together
    local global_min_delta = -math.huge
    local global_max_delta = math.huge

    -- Determine reference bracket type from first effective edge
    local reference_bracket = nil
    for _, edge_info in ipairs(edge_infos) do
        -- Materialize clip (gap or real)
        local clip, actual_edge_type, is_gap_clip

        if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
            local reference_clip = Clip.load(edge_info.clip_id, db)
            if not reference_clip then
                print(string.format("WARNING: Gap reference clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end

            local neighbor_entry = per_clip_neighbors(reference_clip)
            local gap_start, gap_duration = compute_gap_bounds(reference_clip, edge_info.edge_type, all_clips, neighbor_entry)

            clip = {
                id = "temp_gap_" .. edge_info.clip_id,
                track_id = reference_clip.track_id,
                start_value = gap_start,
                duration = gap_duration,
                source_in = 0,
                source_out = gap_duration,
                is_gap = true
            }
            actual_edge_type = edge_info.edge_type == "gap_after" and "in" or "out"
            is_gap_clip = true
        else
            clip = Clip.load(edge_info.clip_id, db)
            if not clip then
                print(string.format("WARNING: Clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end
            actual_edge_type = edge_info.edge_type
            is_gap_clip = false
        end

        -- ASYMMETRIC FIX: Negate delta for opposite BRACKET types (non-roll only)
        -- Bracket mapping: in/gap_after → [, out/gap_before → ]
        -- Roll trims intentionally keep edges in lockstep so they ignore bracket polarity.
        local edge_bracket = (actual_edge_type == "in") and "[" or "]"
        if not reference_bracket and edge_info == edge_infos[1] then
            reference_bracket = edge_bracket
        end

        local resolved_trim_type = edge_info.trim_type or edge_info.edge_type or edge_info.type
        local is_roll_edge = resolved_trim_type == "roll"

        local edge_delta = is_roll_edge and delta_ms or ((edge_bracket == reference_bracket) and delta_ms or -delta_ms)

        -- Calculate constraints using timeline_constraints module
        -- For ripple edits, skip adjacent clip checks since they move downstream
        local constraints_module = require('core.timeline_constraints')
        local min_delta, max_delta
        if is_gap_clip then
            min_delta, max_delta = calculate_gap_ripple_delta_range(clip, actual_edge_type, all_clips, sequence_id)
            if not min_delta or not max_delta then
                print("WARNING: Failed to calculate gap constraints for clip " .. tostring(clip.id))
                return false
            end
        else
            local constraint_result = constraints_module.calculate_trim_range(
                clip,
                actual_edge_type,
                all_clips,
                false,  -- check_all_tracks: ripple shift handles downstream movement
                true    -- skip_adjacent_check: overlap guard handled separately
            )
            min_delta = constraint_result.min_delta
            max_delta = constraint_result.max_delta
        end

        if not dry_run then
            print(string.format("  Edge %s (%s) %s: edge_delta=%d, constraint=[%d, %d]",
                clip.id:sub(1,8),
                is_gap_clip and "gap" or "clip",
                actual_edge_type,
                edge_delta,
                min_delta,
                max_delta == math.huge and 999999999 or max_delta))
        end

        -- Map edge_delta constraints into delta_ms space
        local invert_delta = (not is_roll_edge) and (edge_bracket ~= reference_bracket)
        local delta_range_min, delta_range_max
        if invert_delta then
            delta_range_min = -max_delta
            delta_range_max = -min_delta
        else
            delta_range_min = min_delta
            delta_range_max = max_delta
        end

        -- Normalise ordering in case of infinities or flipped bounds
        if delta_range_min > delta_range_max then
            delta_range_min, delta_range_max = delta_range_max, delta_range_min
        end

        if delta_range_min > global_min_delta then
            global_min_delta = delta_range_min
        end
        if delta_range_max < global_max_delta then
            global_max_delta = delta_range_max
        end
    end

    if global_min_delta > global_max_delta then
        if not dry_run then
            print(string.format("WARNING: BatchRippleEdit: No valid delta range after intersecting constraints (min=%s max=%s)",
                tostring(global_min_delta), tostring(global_max_delta)))
        end
        return false
    end

    -- Clamp delta_ms to the most restrictive constraint
    local original_delta = delta_ms
    if delta_ms < global_min_delta then
        delta_ms = global_min_delta
    end
    if delta_ms > global_max_delta then
        delta_ms = global_max_delta
    end

    if delta_ms ~= original_delta then
        if not dry_run then
            print(string.format("Clamped delta: %d → %d", original_delta, delta_ms))
        end
        -- Store clamped delta for deterministic replay
        command:set_parameter("clamped_delta_ms", delta_ms)
    end

    if delta_ms == 0 then
        if not dry_run then
            print("WARNING: All edges blocked - no movement possible (no-op)")
            command:set_parameter("clamped_delta_ms", 0)
            command:set_parameter("ripple_post_states", {})
            command:set_parameter("__skip_sequence_replay_on_undo", true)
            command:set_parameter("__skip_sequence_replay_on_redo", true)
        end
        return true, {affected_clips = {}, shifted_clips = {}}
    end

    -- Phase 1: Trim all edges with the clamped delta
    -- All edges now guaranteed to succeed - preserves relative timing
    local edited_clip_ids = {}  -- Track clip IDs that were edited (real or temporary gap clips)
    for _, edge_info in ipairs(edge_infos) do
        -- MATERIALIZE GAP CLIPS: Create virtual clip objects for gaps
        -- This removes all special cases - gaps behave exactly like clips
        local clip, actual_edge_type, is_gap_clip

        if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
            -- Find the real clip that defines this gap
            local reference_clip = Clip.load(edge_info.clip_id, db)
            if not reference_clip then
                print(string.format("WARNING: BatchRippleEdit: Gap reference clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end

            local gap_start, gap_duration = compute_gap_bounds(reference_clip, edge_info.edge_type, all_clips)

            -- Create temporary gap clip object (not saved to database)
            clip = {
                id = "temp_gap_" .. edge_info.clip_id,
                track_id = reference_clip.track_id,
                start_value = gap_start,
                duration = gap_duration,
                source_in = 0,
                source_out = gap_duration,
                is_gap = true
            }
            actual_edge_type = edge_info.edge_type == "gap_after" and "in" or "out"
            is_gap_clip = true
        else
            clip = Clip.load(edge_info.clip_id, db)
            if not clip then
                print(string.format("WARNING: BatchRippleEdit: Clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end
            actual_edge_type = edge_info.edge_type
            is_gap_clip = false
        end

        -- Save original state (before trim)
        local original_duration = clip.duration
        original_states[edge_info.clip_id] = capture_clip_state(clip)

        if not dry_run and is_gap_clip then
            print(string.format("  Gap materialized: duration=%s (infinite=%s)",
                tostring(clip.duration),
                tostring(clip.duration == math.huge)))
        end

        -- Track this clip as edited (use materialized clip.id, not edge_info.clip_id)
        -- For real clips: clip.id == edge_info.clip_id
        -- For gaps: clip.id == "temp_gap_..." (won't match any DB clip, so won't exclude reference clip)
        table.insert(edited_clip_ids, clip.id)

        local resolved_trim_type = edge_info.trim_type or edge_info.edge_type or edge_info.type
        local is_roll_trim = resolved_trim_type == "roll"

        -- Apply edge ripple using shared helper
        -- Phase 0 already ensured this will succeed by clamping delta_ms
        -- ASYMMETRIC FIX: Negate delta for opposite BRACKET types (not in/out types!)
        -- Bracket mapping: in/gap_after → [, out/gap_before → ]
        local edge_bracket = (actual_edge_type == "in") and "[" or "]"
        local edge_delta
        edge_delta = is_roll_trim and delta_ms or ((edge_bracket == reference_bracket) and delta_ms or -delta_ms)
        local ripple_time, success, deleted_clip = apply_edge_ripple(clip, actual_edge_type, edge_delta)
        if not success then
            -- This should never happen after Phase 0 constraint calculation
            print(string.format("ERROR: Ripple failed for clip %s despite constraint pre-calculation!", clip.id:sub(1,8)))
            print(string.format("       This indicates a bug in constraint calculation - please report"))
            return false
        end

        if deleted_clip and not is_gap_clip then
            table.insert(deleted_clip_ids, clip.id)
        end

        -- DRY RUN: Collect preview data
        if dry_run then
            local preview_start = clip.start_value
            local preview_duration = clip.duration
            if resolved_trim_type == "roll" and actual_edge_type == "in" then
                preview_start = preview_start + edge_delta
            end
            table.insert(preview_affected_clips, {
                clip_id = clip.id,
                new_start_value = preview_start,
                new_duration = preview_duration,
                edge_type = actual_edge_type  -- Use translated edge type, not gap_before/gap_after
            })
        else
            -- EXECUTE: Save changes (skip gap clips - they're not persisted)
            if not is_gap_clip then
                if deleted_clip then
                    if not clip:delete(db) then
                        print(string.format("ERROR: BatchRippleEdit: Failed to delete clip %s", clip.id:sub(1,8)))
                        return false
                    end
                    add_delete_mutation(command, sequence_id, clip.id)
                else
                    if resolved_trim_type == "roll" and actual_edge_type == "in" then
                        clip.start_value = clip.start_value + delta_ms
                    end
                    local ok, actions = clip:save(db, {skip_occlusion = true})
                    if not ok then
                        print(string.format("ERROR: BatchRippleEdit: Failed to save clip %s", clip.id:sub(1,8)))
                        return false
                    end
                    append_actions(occlusion_actions, actions)
                    local update_payload = clip_update_payload(clip, sequence_id)
                    if update_payload then
                        add_update_mutation(command, update_payload.track_sequence_id, update_payload)
                    end

                    post_states[#post_states + 1] = capture_clip_state(clip)
                end

            end
        end

        -- Calculate downstream shift from timeline length change
        -- Tracks are PARALLEL, so use first edge's duration change (not summed)
        if ripple_time then
            local duration_change = clip.duration - original_duration

            -- Skip infinite gaps (extend to end of timeline) - they produce NaN
            -- math.huge - math.huge = nan, which corrupts downstream clip positions
            local is_infinite_gap = (original_duration == math.huge or clip.duration == math.huge)

            if not dry_run then
                print(string.format("  Duration change: %s - %s = %s (infinite=%s)",
                    tostring(clip.duration), tostring(original_duration),
                    tostring(duration_change), tostring(is_infinite_gap)))
            end

            if not is_roll_trim then
                if downstream_shift_amount == nil and not is_infinite_gap then
                    downstream_shift_amount = duration_change
                    if not dry_run then
                        print(string.format("  Set downstream_shift_amount = %s", tostring(downstream_shift_amount)))
                    end
                elseif not dry_run and is_infinite_gap then
                    print(string.format("  Skipped infinite gap - not setting downstream_shift_amount"))
                end

                -- Track leftmost ripple point (determines which clips shift)
                if ripple_time < earliest_ripple_time then
                    earliest_ripple_time = ripple_time
                end
            elseif not dry_run then
                print("  Roll trim detected - skipping downstream ripple contribution")
            end
        end
    end

    -- If all edges were infinite gaps, default to zero shift
    -- This prevents nil downstream_shift_amount from corrupting clip positions
    if downstream_shift_amount == nil then
        downstream_shift_amount = 0
    end

    -- Phase 2: Single timeline shift at earliest ripple point
    -- edited_clip_ids contains materialized clip IDs (real clips + temp gap clips)
    -- Temp gap IDs won't match any DB clips, so reference clips naturally aren't excluded
    local phase2_clips = nil
    if timeline_state_ready and all_clips then
        phase2_clips = all_clips
    end
    if not phase2_clips then
        phase2_clips = database.load_clips(sequence_id)
    end
    local edited_lookup = {}
    for _, id in ipairs(edited_clip_ids) do
        edited_lookup[id] = true
    end

    local clips_to_shift = {}

    if not dry_run then
        local display_time = (earliest_ripple_time ~= math.huge) and string.format("%dms", earliest_ripple_time) or "nil"
        print(string.format("DOWNSTREAM SHIFT: earliest_ripple_time=%s, edited_clip_ids=%s",
            display_time, table.concat(edited_clip_ids, ",")))
    end

    for _, other_clip in ipairs(phase2_clips) do
        local is_edited = edited_lookup[other_clip.id] == true
        local is_after_ripple = (earliest_ripple_time ~= math.huge) and (other_clip.start_value >= earliest_ripple_time - 1)

        if not is_edited and is_after_ripple then
            table.insert(clips_to_shift, other_clip)
            if not dry_run then
                print(string.format("  Will shift: %s at %dms on %s", other_clip.id:sub(1,8), other_clip.start_value, other_clip.track_id))
            end
        elseif not dry_run then
            print(string.format("  Skip: %s at %dms (edited=%s, >= ripple_time=%s)",
                other_clip.id:sub(1,8), other_clip.start_value, tostring(is_edited), tostring(is_after_ripple)))
        end
    end

    -- Clamp negative shifts so we never push a clip before t=0
    if downstream_shift_amount < 0 then
        local min_start = math.huge
        for _, clip in ipairs(clips_to_shift) do
            if clip.start_value < min_start then
                min_start = clip.start_value
            end
        end
        if min_start ~= math.huge then
            local max_negative_shift = -min_start
            if downstream_shift_amount < max_negative_shift then
                if not dry_run then
                    print(string.format("  Clamped negative downstream shift: %d → %d (prevent negative start)",
                        downstream_shift_amount, max_negative_shift))
                end
                downstream_shift_amount = max_negative_shift
            end
        end
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        local preview_shifted_clips = {}
        for _, downstream_clip in ipairs(clips_to_shift) do
            table.insert(preview_shifted_clips, {
                clip_id = downstream_clip.id,
                new_start_value = downstream_clip.start_value + (downstream_shift_amount or 0)
            })
        end
        return true, {
            affected_clips = preview_affected_clips,
            shifted_clips = preview_shifted_clips
        }
    end

    -- EXECUTE: Shift all downstream clips once
        if not dry_run and #clips_to_shift > 0 then
            print(string.format("DEBUG: downstream_shift_amount=%s", tostring(downstream_shift_amount)))
        end

        for _, downstream_clip in ipairs(clips_to_shift) do
            local shift_clip = Clip.load(downstream_clip.id, db)
            if not shift_clip then
                print(string.format("WARNING: BatchRippleEdit: Failed to load downstream clip %s", downstream_clip.id:sub(1,8)))
                goto continue_batch_shift
            end

            if not dry_run then
                print(string.format("  Before: clip %s start_value=%s", shift_clip.id:sub(1,8), tostring(shift_clip.start_value)))
            end

            shift_clip.start_value = shift_clip.start_value + (downstream_shift_amount or 0)

            if not dry_run then
                print(string.format("  After:  clip %s start_value=%s", shift_clip.id:sub(1,8), tostring(shift_clip.start_value)))
            end

            local ok, actions = shift_clip:save(db, {skip_occlusion = true})
            if not ok then
                print(string.format("ERROR: BatchRippleEdit: Failed to save downstream clip %s", downstream_clip.id:sub(1,8)))
                return false
            end
            append_actions(occlusion_actions, actions)
            local update_payload = clip_update_payload(shift_clip, sequence_id)
            if update_payload then
                add_update_mutation(command, update_payload.track_sequence_id, update_payload)
            end

            post_states[#post_states + 1] = capture_clip_state(shift_clip)

        ::continue_batch_shift::
    end

    -- Store for undo
    command:set_parameter("original_states", original_states)
    command:set_parameter("shifted_clip_ids", (function()
        local ids = {}
        for _, c in ipairs(clips_to_shift) do table.insert(ids, c.id) end
        return ids
    end)())
    command:set_parameter("shift_amount", downstream_shift_amount or 0)  -- Store shift for undo
    if #occlusion_actions > 0 then
        record_occlusion_actions(command, sequence_id, occlusion_actions)
        command:set_parameter("occlusion_actions", occlusion_actions)
    end
    if #deleted_clip_ids > 0 then
        command:set_parameter("deleted_clip_ids", deleted_clip_ids)
    end

    print(string.format("✅ Batch ripple: trimmed %d edges, shifted %d downstream clips by %dms",
        #edge_infos, #clips_to_shift, downstream_shift_amount or 0))

    command:set_parameter("batch_ripple_post_states", post_states)
    command:set_parameter("__skip_sequence_replay_on_undo", true)
    command:set_parameter("__skip_sequence_replay_on_redo", true)

    return true
end

-- Undo for BatchRippleEdit
command_undoers["BatchRippleEdit"] = function(command)
    print("Undoing BatchRippleEdit command")

    local original_states = command:get_parameter("original_states")
    local shift_amount = command:get_parameter("shift_amount")  -- BUG FIX: Use stored shift, not delta_ms
    local shifted_clip_ids = command:get_parameter("shifted_clip_ids")
    local occlusion_actions = command:get_parameter("occlusion_actions") or {}
    local sequence_id = command:get_parameter("sequence_id")

    local Clip = require('models.clip')

    local function record_clip_update(clip)
        if not clip then
            return
        end
        local payload = clip_update_payload(clip, sequence_id or clip.owner_sequence_id or clip.track_sequence_id)
        if payload then
            add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
        end
    end

    -- Restore all edited clips (including any that were deleted)
    for clip_id, state in pairs(original_states) do
        if state then
            state.id = state.id or clip_id
            local restored_clip = restore_clip_state(state)
            record_clip_update(restored_clip)
        end
    end

    -- Shift all affected clips back
    for _, clip_id in ipairs(shifted_clip_ids) do
        local shift_clip = Clip.load(clip_id, db)
        if not shift_clip then
            print(string.format("WARNING: UndoBatchRippleEdit: Shifted clip %s not found", clip_id:sub(1,8)))
            goto continue_unshift
        end

        local restored_start = (shift_clip.start_value or 0) - shift_amount
        if restored_start < 0 then
            restored_start = 0
        end
        shift_clip.start_value = restored_start  -- BUG FIX: Use stored shift

        if not shift_clip:restore_without_occlusion(db) then
            print(string.format("ERROR: UndoBatchRippleEdit: Failed to save shifted clip %s", clip_id:sub(1,8)))
            return false
        end
        record_clip_update(shift_clip)

        ::continue_unshift::
    end

    revert_occlusion_actions(occlusion_actions, command, sequence_id)
    flush_timeline_mutations(command, sequence_id)

    print(string.format("✅ Undone batch ripple: restored %d clips, shifted %d clips back",
        table.getn(original_states), #shifted_clip_ids))
    return true
end

-- Undo for RippleEdit: restore original clip state and shift downstream clips back
command_undoers["RippleEdit"] = function(command)
    print("Undoing RippleEdit command")

    local edge_info = command:get_parameter("edge_info")
    local applied_delta = command:get_parameter("clamped_delta_ms")
    if applied_delta == nil then
        applied_delta = command:get_parameter("delta_ms")
    end
    local delta_ms = tonumber(applied_delta) or 0
    local stored_shift = command:get_parameter("ripple_shift_amount")
    local shift_amount = tonumber(stored_shift) or delta_ms
    local original_clip_state = command:get_parameter("original_clip_state")
    local shifted_clip_ids = command:get_parameter("shifted_clip_ids") or {}
    local occlusion_actions = command:get_parameter("occlusion_actions") or {}
    local sequence_id = command:get_parameter("sequence_id") or (edge_info and edge_info.sequence_id)

    -- Restore original clip
    local Clip = require('models.clip')
    local function record_clip_update(clip)
        if not clip then
            return
        end
        local payload = clip_update_payload(clip, sequence_id or clip.owner_sequence_id or clip.track_sequence_id)
        if payload then
            add_update_mutation(command, payload.track_sequence_id or sequence_id, payload)
        end
    end

    if original_clip_state then
        original_clip_state.id = original_clip_state.id or edge_info.clip_id
        local restored_clip = restore_clip_state(original_clip_state)
        record_clip_update(restored_clip)
    end

    -- Shift all affected clips back
    for _, clip_id in ipairs(shifted_clip_ids) do
        local shift_clip = Clip.load(clip_id, db)
        if shift_clip then
            local restored_start = (shift_clip.start_value or 0) - shift_amount
            if restored_start < 0 then
                restored_start = 0
            end
            shift_clip.start_value = restored_start
            shift_clip:restore_without_occlusion(db)
            record_clip_update(shift_clip)
        end
    end

    revert_occlusion_actions(occlusion_actions, command, sequence_id)
    flush_timeline_mutations(command, sequence_id)

    print(string.format("✅ Undone ripple edit: restored clip and shifted %d clips back", #shifted_clip_ids))
    return true
end

if command_redoers then
    command_redoers["BatchRippleEdit"] = function(command)
        local sequence_id = command:get_parameter("sequence_id")
        delete_clips_by_id(command, sequence_id, command:get_parameter("deleted_clip_ids"))
        apply_clip_state_list(command, command:get_parameter("batch_ripple_post_states"), sequence_id)
        flush_timeline_mutations(command, sequence_id)
        return true
    end
    command_redoers["RippleEdit"] = function(command)
        local sequence_id = command:get_parameter("sequence_id")
        delete_clips_by_id(command, sequence_id, command:get_parameter("deleted_clip_ids"))
        apply_clip_state_list(command, command:get_parameter("ripple_post_states"), sequence_id)
        flush_timeline_mutations(command, sequence_id)
        return true
    end
end

end

return M
