-- Shared helper functions for command implementations.
-- Extracted to support splitting command_implementations.lua into modular files.

local M = {}

local json = require("dkjson")
local uuid = require("uuid")
local db = require("core.database")
local Clip = require("models.clip")
local timeline_state = require("ui.timeline.timeline_state")

local function get_conn()
    local conn = db.get_connection()
    if not conn then
        print("WARNING: command_helper: No database connection")
    end
    return conn
end

function M.trim_string(value)
    if type(value) ~= "string" then
        return ""
    end
    local stripped = value:match("^%s*(.-)%s*$")
    if stripped == nil then
        return ""
    end
    return stripped
end

function M.reload_timeline(sequence_id)
    local timeline_state_mod = require('ui.timeline.timeline_state')
    if not timeline_state_mod or not timeline_state_mod.reload_clips then
        return
    end
    local target_sequence = sequence_id
    if (not target_sequence or target_sequence == "") and timeline_state_mod.get_sequence_id then
        target_sequence = timeline_state_mod.get_sequence_id()
    end
    if target_sequence and target_sequence ~= "" then
        timeline_state_mod.reload_clips(target_sequence)
    end
end

function M.encode_property_json(raw)
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

function M.ensure_timeline_mutation_bucket(command, sequence_id)
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

function M.clip_update_payload(source, fallback_sequence_id)
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
        timeline_start = source.timeline_start,
        duration = source.duration,
        source_in = source.source_in,
        source_out = source.source_out,
        enabled = source.enabled ~= false
    }
end

function M.clip_insert_payload(source, fallback_sequence_id)
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
        
        timeline_start = source.timeline_start,
        duration = source.duration,
        source_in = source.source_in,
        source_out = source.source_out,
        
        enabled = source.enabled ~= false,
        offline = source.offline == true
    }
end

function M.add_update_mutation(command, sequence_id, update)
    if not update then
        return
    end
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
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

function M.add_insert_mutation(command, sequence_id, clip)
    if not clip then
        return
    end
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
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

function M.add_delete_mutation(command, sequence_id, clip_ids)
    if not clip_ids then
        return
    end
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
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

function M.resolve_sequence_id_for_edges(command, primary_edge, edge_list)
    local provided = command:get_parameter("sequence_id")

    local function lookup_sequence_id(edge)
        if not edge or not edge.clip_id or edge.clip_id == "" then
            return nil
        end

        local conn = get_conn()
        if not conn then return nil end
        
        local stmt = conn:prepare([[
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

function M.resolve_sequence_for_track(sequence_id_param, track_id)
    local resolved = sequence_id_param
    if resolved and resolved ~= "" then
        return resolved
    end
    if not track_id or track_id == "" then
        return resolved
    end
    
    local conn = get_conn()
    if not conn then return resolved end

    local stmt = conn:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
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

function M.restore_clip_state(state)
    if not state then return end
    if type(state.id) == "string" and state.id:find("^temp_gap_") then return nil end
    
    local conn = get_conn()
    if not conn then return nil end

    local clip = Clip.load_optional(state.id, conn)
    
    if not clip then
        -- Create new if missing
        clip = Clip.create(state.name or 'Restored Clip', state.media_id, {
            id = state.id,
            project_id = state.project_id,
            clip_kind = state.clip_kind,
            track_id = state.track_id,
            parent_clip_id = state.parent_clip_id,
            owner_sequence_id = state.owner_sequence_id,
            source_sequence_id = state.source_sequence_id,
            
            timeline_start = state.timeline_start,
            duration = state.duration,
            source_in = state.source_in,
            source_out = state.source_out,
            
            enabled = state.enabled ~= false,
            offline = state.offline,
        })
    else
        -- Update existing
        clip.track_id = state.track_id or clip.track_id
        clip.timeline_start = state.timeline_start
        clip.duration = state.duration
        clip.source_in = state.source_in
        clip.source_out = state.source_out
        clip.enabled = state.enabled ~= false
    end
    
    return clip
end

function M.capture_clip_state(clip)
    if not clip then return nil end
    return {
        id = clip.id,
        track_id = clip.track_id,
        media_id = clip.media_id,
        timeline_start = clip.timeline_start,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        enabled = clip.enabled
    }
end

function M.snapshot_properties_for_clip(clip_id)
    local props = {}
    if not clip_id or clip_id == "" then
        return props
    end

    local conn = get_conn()
    if not conn then return props end

    local query = conn:prepare("SELECT id, property_name, property_value, property_type, default_value FROM properties WHERE clip_id = ?")
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

function M.fetch_clip_properties_for_copy(clip_id)
    local props = {}
    if not clip_id or clip_id == "" then
        return props
    end

    local conn = get_conn()
    if not conn then return props end

    local query = conn:prepare("SELECT property_name, property_value, property_type, default_value FROM properties WHERE clip_id = ?")
    if not query then
        return props
    end
    query:bind_value(1, clip_id)

    if query:exec() then
        while query:next() do
            local property_name = query:value(0)
            local property_value = M.encode_property_json(query:value(1))
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

function M.ensure_copied_properties(command, source_clip_id)
    if not source_clip_id or source_clip_id == "" then
        return {}
    end
    return M.fetch_clip_properties_for_copy(source_clip_id)
end

function M.insert_properties_for_clip(clip_id, properties)
    if not properties or #properties == 0 then
        return true
    end

    local conn = get_conn()
    if not conn then return false end

    local stmt = conn:prepare([[
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
        stmt:bind_value(4, M.encode_property_json(prop.property_value))
        stmt:bind_value(5, prop.property_type or "STRING")
        stmt:bind_value(6, M.encode_property_json(prop.default_value))

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

function M.delete_properties_for_clip(clip_id)
    if not clip_id or clip_id == "" then
        return true
    end
    
    local conn = get_conn()
    if not conn then return false end

    local stmt = conn:prepare("DELETE FROM properties WHERE clip_id = ?")
    if not stmt then
        return false
    end
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    stmt:finalize()
    return ok
end

function M.delete_properties_by_list(properties)
    if not properties or #properties == 0 then
        return true
    end
    
    local conn = get_conn()
    if not conn then return false end

    local stmt = conn:prepare("DELETE FROM properties WHERE id = ?")
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

function M.delete_clips_by_id(command, sequence_id, clip_ids)
    if not clip_ids or #clip_ids == 0 then return end
    local conn = get_conn()
    for _, clip_id in ipairs(clip_ids) do
        local clip = Clip.load_optional(clip_id, conn)
        if clip then
            M.delete_properties_for_clip(clip_id)
            if clip:delete(conn) then
                M.add_delete_mutation(command, sequence_id, clip_id)
            end
        end
    end
end

-- Applies a list of mutations (from clip_mutator) to the database.
-- Caller must handle transaction.
function M.apply_mutations(db, mutations)
    if not db then
        return false, "No database connection provided for apply_mutations"
    end
    if not mutations or #mutations == 0 then
        return true
    end

    for _, mut in ipairs(mutations) do
        if mut.type == "update" then
            -- Validate required fields before attempting UPDATE
            if not mut.clip_id or mut.clip_id == "" then
                return false, "Mutation missing clip_id for UPDATE operation"
            end
            if not mut.timeline_start_frame then
                return false, string.format("Mutation for clip %s missing timeline_start_frame", mut.clip_id)
            end
            if not mut.duration_frames or mut.duration_frames <= 0 then
                return false, string.format("Mutation for clip %s has invalid duration: %s",
                                             mut.clip_id, tostring(mut.duration_frames))
            end

            local stmt = db:prepare([[
                UPDATE clips
                SET track_id = ?, timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?
                WHERE id = ?
            ]])
            if not stmt then
                return false, "Failed to prepare UPDATE statement for clip " .. tostring(mut.clip_id) .. ": " .. (db:last_error() or "unknown")
            end
            stmt:bind_value(1, mut.track_id)
            stmt:bind_value(2, mut.timeline_start_frame)
            stmt:bind_value(3, mut.duration_frames)
            stmt:bind_value(4, mut.source_in_frame)
            stmt:bind_value(5, mut.source_out_frame)
            stmt:bind_value(6, mut.enabled)
            stmt:bind_value(7, mut.clip_id)
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then
                return false, "Failed to execute UPDATE for clip " .. tostring(mut.clip_id) .. ": " .. (db:last_error() or "unknown")
            end
        elseif mut.type == "delete" then
            local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
            if not stmt then
                return false, "Failed to prepare DELETE statement for clip " .. tostring(mut.clip_id) .. ": " .. (db:last_error() or "unknown")
            end
            stmt:bind_value(1, mut.clip_id)
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then
                return false, "Failed to execute DELETE for clip " .. tostring(mut.clip_id) .. ": " .. (db:last_error() or "unknown")
            end
        elseif mut.type == "insert" then
            local stmt = db:prepare([[
                INSERT INTO clips (
                    id, project_id, clip_kind, name, track_id, media_id,
                    timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                    fps_numerator, fps_denominator, enabled,
                    created_at, modified_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])
            if not stmt then
                return false, "Failed to prepare INSERT statement for clip " .. tostring(mut.clip_id) .. ": " .. (db:last_error() or "unknown")
            end
            stmt:bind_value(1, mut.clip_id)
            stmt:bind_value(2, mut.project_id)
            stmt:bind_value(3, mut.clip_kind)
            stmt:bind_value(4, mut.name)
            stmt:bind_value(5, mut.track_id)
            stmt:bind_value(6, mut.media_id)
            stmt:bind_value(7, mut.timeline_start_frame)
            stmt:bind_value(8, mut.duration_frames)
            stmt:bind_value(9, mut.source_in_frame)
            stmt:bind_value(10, mut.source_out_frame)
            stmt:bind_value(11, mut.fps_numerator)
            stmt:bind_value(12, mut.fps_denominator)
            stmt:bind_value(13, mut.enabled)
            stmt:bind_value(14, mut.created_at or os.time())
            stmt:bind_value(15, mut.modified_at or os.time())
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then
                return false, "Failed to execute INSERT for clip " .. tostring(mut.clip_id) .. ": " .. (db:last_error() or "unknown")
            end
        else
            return false, "Unknown mutation type: " .. tostring(mut.type)
        end
    end

    return true
end

function M.revert_mutations(db, mutations, command, sequence_id)
    if not db then return false, "No database connection" end
    if not mutations or #mutations == 0 then return true end

    -- Revert in reverse order
    for i = #mutations, 1, -1 do
        local mut = mutations[i]
        if mut.type == "insert" then
            -- Undo Insert = Delete
            local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
            if not stmt then return false, "Failed to prepare undo insert" end
            stmt:bind_value(1, mut.clip_id)
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then return false, "Failed to execute undo insert" end
            
            if command then
                M.add_delete_mutation(command, sequence_id, mut.clip_id)
            end
            
        elseif mut.type == "delete" then
            -- Undo Delete = Insert (restore previous)
            local prev = mut.previous
            if not prev then return false, "Cannot undo delete: missing previous state" end
            
            local stmt = db:prepare([[
                INSERT INTO clips (
                    id, project_id, clip_kind, name, track_id, media_id,
                    timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                    fps_numerator, fps_denominator, enabled,
                    created_at, modified_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])
            if not stmt then return false, "Failed to prepare undo delete" end
            
            -- Helper to extract frame count
            local function val_frames(v)
                if type(v) == "table" and v.frames then return v.frames end
                return v or 0
            end

            stmt:bind_value(1, prev.id)
            stmt:bind_value(2, prev.project_id)
            stmt:bind_value(3, prev.clip_kind)
            stmt:bind_value(4, prev.name)
            stmt:bind_value(5, prev.track_id)
            stmt:bind_value(6, prev.media_id)
            stmt:bind_value(7, val_frames(prev.timeline_start or prev.start_value))
            stmt:bind_value(8, val_frames(prev.duration))
            stmt:bind_value(9, val_frames(prev.source_in))
            stmt:bind_value(10, val_frames(prev.source_out))
            stmt:bind_value(11, prev.fps_numerator or prev.rate and prev.rate.fps_numerator or 30)
            stmt:bind_value(12, prev.fps_denominator or prev.rate and prev.rate.fps_denominator or 1)
            stmt:bind_value(13, prev.enabled and 1 or 0)
            stmt:bind_value(14, prev.created_at or os.time())
            stmt:bind_value(15, prev.modified_at or os.time())
            
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then return false, "Failed to execute undo delete: " .. (db:last_error() or "") end
            
            if command then
                 M.add_insert_mutation(command, sequence_id, {id = prev.id})
            end

        elseif mut.type == "update" then
            -- Undo Update = Update to previous
            local prev = mut.previous
            if not prev then return false, "Cannot undo update: missing previous state" end

            local stmt = db:prepare([[
                UPDATE clips
                SET track_id = ?, timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?
                WHERE id = ?
            ]])
            if not stmt then return false, "Failed to prepare undo update" end

            local function val_frames(v)
                if type(v) == "table" and v.frames then return v.frames end
                return v or 0
            end

            stmt:bind_value(1, prev.track_id)
            stmt:bind_value(2, val_frames(prev.timeline_start or prev.start_value))
            stmt:bind_value(3, val_frames(prev.duration))
            stmt:bind_value(4, val_frames(prev.source_in))
            stmt:bind_value(5, val_frames(prev.source_out))
            stmt:bind_value(6, prev.enabled and 1 or 0)
            stmt:bind_value(7, prev.id)
            
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then return false, "Failed to execute undo update" end
            
            if command then
                M.add_update_mutation(command, sequence_id, {clip_id = prev.id})
            end
        end
    end
    return true
end

return M
