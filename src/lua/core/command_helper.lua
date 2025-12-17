-- Shared helper functions for command implementations.
-- Extracted to support splitting command_implementations.lua into modular files.

local M = {}

local json = require("dkjson")
local uuid = require("uuid")
local db = require("core.database")
local Clip = require("models.clip")
local timeline_state = require("ui.timeline.timeline_state")
local logger = require("core.logger")

local function get_conn()
    local conn = db.get_connection()
    if not conn then
        logger.warn("command_helper", "No database connection")
    end
    return conn
end

local function lookup_track_sequence(track_id)
    local conn = get_conn()
    if not conn or not track_id then return nil end
    local stmt = conn:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
    if not stmt then return nil end
    stmt:bind_value(1, track_id)
    local seq = nil
    if stmt:exec() and stmt:next() then
        seq = stmt:value(0)
    end
    stmt:finalize()
    return seq
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
        local cmd_type = command and command.type or "unknown_command"
        error(string.format("%s: Missing sequence_id for timeline mutation bucket", tostring(cmd_type)), 2)
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
    local rate = source.rate
    if not rate and source.fps_numerator and source.fps_denominator then
        rate = { fps_numerator = source.fps_numerator, fps_denominator = source.fps_denominator }
    end
    return {
        clip_id = source.id,
        track_id = source.track_id,
        track_sequence_id = track_sequence_id,
        timeline_start = source.timeline_start,
        duration = source.duration,
        source_in = source.source_in,
        source_out = source.source_out,
        rate = rate,
        fps_numerator = rate and rate.fps_numerator or nil,
        fps_denominator = rate and rate.fps_denominator or nil,
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
    local rate = source.rate
    if not rate and source.fps_numerator and source.fps_denominator then
        rate = { fps_numerator = source.fps_numerator, fps_denominator = source.fps_denominator }
    end
    if (source.source_in ~= nil or source.source_out ~= nil) and (not rate or not rate.fps_numerator or not rate.fps_denominator) then
        error("command_helper.clip_insert_payload: clip missing rate metadata for source bounds (clip_id=" .. tostring(source.id) .. ")", 2)
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
        rate = rate,
        fps_numerator = rate and rate.fps_numerator or nil,
        fps_denominator = rate and rate.fps_denominator or nil,
        
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

    -- Validate update mutation payload to catch incomplete undo mutations
    local function validate_update(entry)
        assert(entry.clip_id, "add_update_mutation: missing clip_id")
        -- For UI cache updates, we need position data (not just clip_id)
        -- This catches bugs where undo sends {clip_id = "..."} without start_value/duration_value
        if not entry.start_value and not entry.duration_value and not entry.track_id then
            error(string.format(
                "add_update_mutation: incomplete payload for clip %s - missing start_value, duration_value, and track_id. " ..
                "Undo mutations must include full clip state for UI cache updates.",
                tostring(entry.clip_id)
            ), 2)
        end
    end

    if update[1] then
        for _, entry in ipairs(update) do
            validate_update(entry)
            table.insert(bucket.updates, entry)
        end
    else
        validate_update(update)
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

    -- Validate insert mutation payload to catch incomplete undo mutations
    local function validate_insert(entry)
        assert(entry.id, "add_insert_mutation: missing id")
        -- For UI cache inserts, we need position data (not just id)
        -- This catches bugs where undo delete sends {id = "..."} without start_value/duration_value
        if not entry.start_value and not entry.duration_value and not entry.track_id then
            error(string.format(
                "add_insert_mutation: incomplete payload for clip %s - missing start_value, duration_value, and track_id. " ..
                "Undo delete mutations must include full clip state for UI cache inserts.",
                tostring(entry.id)
            ), 2)
        end
    end

    if clip[1] then
        for _, entry in ipairs(clip) do
            validate_insert(entry)
            table.insert(bucket.inserts, entry)
        end
    else
        validate_insert(clip)
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
    local provided = sequence_id_param
    if not track_id or track_id == "" then
        return provided
    end

    local conn = get_conn()
    if not conn then
        return provided
    end

    local stmt = conn:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
    if not stmt then
        return provided
    end

    stmt:bind_value(1, track_id)
    local track_sequence_id = nil
    if stmt:exec() and stmt:next() then
        track_sequence_id = stmt:value(0)
    end
    stmt:finalize()

    if not track_sequence_id or track_sequence_id == "" then
        return provided
    end

    if provided and provided ~= "" and provided ~= track_sequence_id then
        logger.warn("command_helper", string.format(
            "resolve_sequence_for_track: sequence_id %s does not match track %s (sequence_id=%s); using track sequence",
            tostring(provided),
            tostring(track_id),
            tostring(track_sequence_id)
        ))
    end

    return track_sequence_id
end

function M.restore_clip_state(state)
    if not state then return end
    if type(state.id) == "string" and state.id:find("^temp_gap_") then return nil end
    
    local conn = get_conn()
    if not conn then return nil end

    -- Fill missing ownership if possible
    local seq_id = state.owner_sequence_id or state.track_sequence_id or lookup_track_sequence(state.track_id)
    state.owner_sequence_id = state.owner_sequence_id or seq_id
    state.track_sequence_id = state.track_sequence_id or seq_id
    state.project_id = state.project_id or "default_project"

    local clip = Clip.load_optional(state.id, conn)
    
    if not clip then
        -- Create new if missing
        clip = Clip.create(state.name or 'Restored Clip', state.media_id, {
            id = state.id,
            project_id = state.project_id,
            clip_kind = state.clip_kind,
            track_id = state.track_id,
            parent_clip_id = state.parent_clip_id,
            owner_sequence_id = state.owner_sequence_id or state.track_sequence_id,
            source_sequence_id = state.source_sequence_id,
            track_sequence_id = state.track_sequence_id or state.owner_sequence_id,
            
            timeline_start = state.timeline_start,
            duration = state.duration,
            source_in = state.source_in,
            source_out = state.source_out,
            
            enabled = state.enabled ~= false,
            offline = state.offline,
        })
        clip:restore_without_occlusion(conn)
    else
        -- Update existing
        clip.track_id = state.track_id or clip.track_id
        clip.timeline_start = state.timeline_start
        clip.duration = state.duration
        clip.source_in = state.source_in
        clip.source_out = state.source_out
        clip.enabled = state.enabled ~= false
        clip:restore_without_occlusion(conn)
    end
    
    return clip
end

function M.capture_clip_state(clip)
    if not clip then return nil end
    local rate = clip.rate
    if not rate or not rate.fps_numerator or not rate.fps_denominator then
        error(string.format("capture_clip_state: Clip %s missing rate metadata", tostring(clip.id)), 2)
    end
    local state = {
        id = clip.id,
        project_id = clip.project_id,
        clip_kind = clip.clip_kind,
        owner_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
        track_sequence_id = clip.track_sequence_id or clip.owner_sequence_id,
        parent_clip_id = clip.parent_clip_id,
        source_sequence_id = clip.source_sequence_id,
        track_id = clip.track_id,
        media_id = clip.media_id,
        timeline_start = clip.timeline_start,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        name = clip.name,
        enabled = clip.enabled,
        offline = clip.offline,
        -- Frame rate needed for Rational reconstruction after JSON round-trip
        fps_numerator = rate.fps_numerator,
        fps_denominator = rate.fps_denominator
    }
    -- Timestamps needed for restore operations (may be nil if not set)
    if clip.created_at then state.created_at = clip.created_at end
    if clip.modified_at then state.modified_at = clip.modified_at end
    return state
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
        logger.warn("command_helper", string.format("Failed to prepare property insert for clip %s", tostring(clip_id)))
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
            logger.warn("command_helper", string.format("Failed to insert property %s for clip %s: %s",
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

function M.add_bulk_shift_mutation(command, sequence_id, payload)
    if not command or not payload then
        return
    end
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
    if not bucket then
        return
    end
    bucket.bulk_shifts = bucket.bulk_shifts or {}
    table.insert(bucket.bulk_shifts, payload)
    command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
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

    local now = os.time()
    local update_stmt = nil
    local delete_stmt = nil
    local insert_stmt = nil
    local bulk_shift_by_id_stmt = nil
    local bulk_shift_select_desc_stmt = nil
    local bulk_shift_select_asc_stmt = nil
    local bulk_shift_anchor_stmt = nil

    local function finalize_stmt(stmt)
        if stmt and stmt.finalize then
            stmt:finalize()
        end
    end

    local function reset_stmt(stmt)
        if not stmt then return end
        if stmt.reset then stmt:reset() end
        if stmt.clear_bindings then stmt:clear_bindings() end
    end

    local function ensure_update_stmt()
        if update_stmt then
            return update_stmt
        end
        update_stmt = db:prepare([[
            UPDATE clips
            SET track_id = ?, timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?, modified_at = ?
            WHERE id = ?
        ]])
        if not update_stmt then
            return nil, "Failed to prepare UPDATE statement: " .. tostring(db:last_error() or "unknown")
        end
        return update_stmt
    end

    local function ensure_delete_stmt()
        if delete_stmt then
            return delete_stmt
        end
        delete_stmt = db:prepare("DELETE FROM clips WHERE id = ?")
        if not delete_stmt then
            return nil, "Failed to prepare DELETE statement: " .. tostring(db:last_error() or "unknown")
        end
        return delete_stmt
    end

    local function ensure_insert_stmt()
        if insert_stmt then
            return insert_stmt
        end
        insert_stmt = db:prepare([[
            INSERT INTO clips (
                id, project_id, clip_kind, name, track_id, media_id,
                source_sequence_id, parent_clip_id, owner_sequence_id,
                timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                fps_numerator, fps_denominator, enabled, offline,
                created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not insert_stmt then
            return nil, "Failed to prepare INSERT statement: " .. tostring(db:last_error() or "unknown")
        end
        return insert_stmt
    end

    local function ensure_bulk_shift_by_id_stmt()
        if bulk_shift_by_id_stmt then
            return bulk_shift_by_id_stmt
        end
        bulk_shift_by_id_stmt = db:prepare("UPDATE clips SET timeline_start_frame = timeline_start_frame + ?, modified_at = ? WHERE id = ?")
        if not bulk_shift_by_id_stmt then
            return nil, "Failed to prepare bulk shift per-clip UPDATE statement: " .. tostring(db:last_error() or "unknown")
        end
        return bulk_shift_by_id_stmt
    end

	    local function ensure_bulk_shift_select_stmt(order_desc)
	        if order_desc then
	            if bulk_shift_select_desc_stmt then
	                return bulk_shift_select_desc_stmt
	            end
	            bulk_shift_select_desc_stmt = db:prepare([[
	                SELECT id FROM clips
	                WHERE track_id = ? AND timeline_start_frame >= ?
	                ORDER BY timeline_start_frame DESC
	            ]])
	            if not bulk_shift_select_desc_stmt then
	                return nil, "Failed to prepare bulk shift SELECT statement: " .. tostring(db:last_error() or "unknown")
	            end
	            return bulk_shift_select_desc_stmt
	        end

	        if bulk_shift_select_asc_stmt then
	            return bulk_shift_select_asc_stmt
	        end
	        bulk_shift_select_asc_stmt = db:prepare([[
	            SELECT id FROM clips
	            WHERE track_id = ? AND timeline_start_frame >= ?
	            ORDER BY timeline_start_frame ASC
	        ]])
	        if not bulk_shift_select_asc_stmt then
	            return nil, "Failed to prepare bulk shift SELECT statement: " .. tostring(db:last_error() or "unknown")
	        end
	        return bulk_shift_select_asc_stmt
	    end

    local function ensure_bulk_shift_anchor_stmt()
        if bulk_shift_anchor_stmt then
            return bulk_shift_anchor_stmt
        end
        bulk_shift_anchor_stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
        if not bulk_shift_anchor_stmt then
            return nil, "Failed to prepare bulk shift anchor query: " .. tostring(db:last_error() or "unknown")
        end
        return bulk_shift_anchor_stmt
    end

    for _, mut in ipairs(mutations) do
        if mut.type == "update" then
            -- Validate required fields before attempting UPDATE
            if not mut.clip_id or mut.clip_id == "" then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, "Mutation missing clip_id for UPDATE operation"
            end
            if not mut.timeline_start_frame then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, string.format("Mutation for clip %s missing timeline_start_frame", mut.clip_id)
            end
            if not mut.duration_frames or mut.duration_frames <= 0 then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, string.format("Mutation for clip %s has invalid duration: %s",
                                             mut.clip_id, tostring(mut.duration_frames))
            end

            local stmt, stmt_err = ensure_update_stmt()
            if not stmt then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, stmt_err
            end
            stmt:bind_value(1, mut.track_id)
            stmt:bind_value(2, mut.timeline_start_frame)
            stmt:bind_value(3, mut.duration_frames)
            stmt:bind_value(4, mut.source_in_frame)
            stmt:bind_value(5, mut.source_out_frame)
            stmt:bind_value(6, mut.enabled)
            stmt:bind_value(7, now)
            stmt:bind_value(8, mut.clip_id)
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, "Failed to execute UPDATE for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "delete" then
            local stmt, stmt_err = ensure_delete_stmt()
            if not stmt then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, stmt_err
            end
            stmt:bind_value(1, mut.clip_id)
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, "Failed to execute DELETE for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "insert" then
            local stmt, stmt_err = ensure_insert_stmt()
            if not stmt then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, stmt_err
            end
            stmt:bind_value(1, mut.clip_id)
            stmt:bind_value(2, mut.project_id)
            stmt:bind_value(3, mut.clip_kind)
            stmt:bind_value(4, mut.name)
            stmt:bind_value(5, mut.track_id)
            stmt:bind_value(6, mut.media_id)
            stmt:bind_value(7, mut.source_sequence_id)
            stmt:bind_value(8, mut.parent_clip_id)
            stmt:bind_value(9, mut.owner_sequence_id)
            stmt:bind_value(10, mut.timeline_start_frame)
            stmt:bind_value(11, mut.duration_frames)
            stmt:bind_value(12, mut.source_in_frame)
            stmt:bind_value(13, mut.source_out_frame)
            stmt:bind_value(14, mut.fps_numerator)
            stmt:bind_value(15, mut.fps_denominator)
            stmt:bind_value(16, mut.enabled)
            stmt:bind_value(17, (mut.offline == 1 or mut.offline == true) and 1 or 0)
            if mut.created_at == nil or mut.modified_at == nil then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, "INSERT mutation missing created_at/modified_at for clip " .. tostring(mut.clip_id)
            end
            stmt:bind_value(18, mut.created_at)
            stmt:bind_value(19, mut.modified_at)
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_stmt(update_stmt)
                finalize_stmt(delete_stmt)
                finalize_stmt(insert_stmt)
                return false, "Failed to execute INSERT for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "bulk_shift" then
	            if not mut.track_id or mut.track_id == "" then
	                finalize_stmt(update_stmt)
	                finalize_stmt(delete_stmt)
	                finalize_stmt(insert_stmt)
	                finalize_stmt(bulk_shift_by_id_stmt)
	                finalize_stmt(bulk_shift_select_desc_stmt)
	                finalize_stmt(bulk_shift_select_asc_stmt)
	                finalize_stmt(bulk_shift_anchor_stmt)
	                return false, "bulk_shift mutation missing track_id"
	            end
	            if type(mut.shift_frames) ~= "number" then
	                finalize_stmt(update_stmt)
	                finalize_stmt(delete_stmt)
	                finalize_stmt(insert_stmt)
	                finalize_stmt(bulk_shift_by_id_stmt)
	                finalize_stmt(bulk_shift_select_desc_stmt)
	                finalize_stmt(bulk_shift_select_asc_stmt)
	                finalize_stmt(bulk_shift_anchor_stmt)
	                return false, "bulk_shift mutation missing numeric shift_frames"
	            end
                if not mut.anchor_start_frame and (not mut.first_clip_id or mut.first_clip_id == "") then
                    finalize_stmt(update_stmt)
                    finalize_stmt(delete_stmt)
                    finalize_stmt(insert_stmt)
                    finalize_stmt(bulk_shift_by_id_stmt)
                    finalize_stmt(bulk_shift_select_desc_stmt)
                    finalize_stmt(bulk_shift_select_asc_stmt)
                    finalize_stmt(bulk_shift_anchor_stmt)
                    return false, "bulk_shift mutation missing anchor_start_frame and first_clip_id"
                end

                local start_frames = mut.anchor_start_frame
                if type(start_frames) ~= "number" then
                    local anchor_stmt, anchor_err = ensure_bulk_shift_anchor_stmt()
                    if not anchor_stmt then
                        finalize_stmt(update_stmt)
                        finalize_stmt(delete_stmt)
                        finalize_stmt(insert_stmt)
                        finalize_stmt(bulk_shift_by_id_stmt)
                        finalize_stmt(bulk_shift_select_desc_stmt)
                        finalize_stmt(bulk_shift_select_asc_stmt)
                        finalize_stmt(bulk_shift_anchor_stmt)
                        return false, anchor_err
                    end
                    anchor_stmt:bind_value(1, mut.first_clip_id)
                    local ok_anchor = anchor_stmt:exec()
                    local err_anchor = db:last_error()
                    local has_row = ok_anchor and anchor_stmt:next()
                    start_frames = has_row and anchor_stmt:value(0) or nil
                    reset_stmt(anchor_stmt)
                    if not ok_anchor or start_frames == nil then
                        finalize_stmt(update_stmt)
                        finalize_stmt(delete_stmt)
                        finalize_stmt(insert_stmt)
                        finalize_stmt(bulk_shift_by_id_stmt)
                        finalize_stmt(bulk_shift_select_desc_stmt)
                        finalize_stmt(bulk_shift_select_asc_stmt)
                        finalize_stmt(bulk_shift_anchor_stmt)
                        return false, "bulk_shift: failed to resolve anchor clip start frame: " .. tostring(err_anchor or "unknown")
                    end
                end

	            local order_desc = mut.shift_frames > 0
	            local select_stmt, select_err = ensure_bulk_shift_select_stmt(order_desc)
	            if not select_stmt then
	                finalize_stmt(update_stmt)
	                finalize_stmt(delete_stmt)
	                finalize_stmt(insert_stmt)
	                finalize_stmt(bulk_shift_by_id_stmt)
	                finalize_stmt(bulk_shift_select_desc_stmt)
	                finalize_stmt(bulk_shift_select_asc_stmt)
	                finalize_stmt(bulk_shift_anchor_stmt)
	                return false, select_err
	            end
	            select_stmt:bind_value(1, mut.track_id)
	            select_stmt:bind_value(2, start_frames)
	            local ok_select = select_stmt:exec()
	            local select_db_err = db:last_error()

	            if not ok_select then
	                reset_stmt(select_stmt)
	                finalize_stmt(update_stmt)
	                finalize_stmt(delete_stmt)
	                finalize_stmt(insert_stmt)
	                finalize_stmt(bulk_shift_by_id_stmt)
	                finalize_stmt(bulk_shift_select_desc_stmt)
	                finalize_stmt(bulk_shift_select_asc_stmt)
	                finalize_stmt(bulk_shift_anchor_stmt)
	                return false, "bulk_shift: failed to enumerate clips for track " .. tostring(mut.track_id) .. ": " .. tostring(select_db_err or "unknown")
	            end

                mut.clip_ids = {}
                while select_stmt:next() do
                    local clip_id = select_stmt:value(0)
                    if clip_id then
                        table.insert(mut.clip_ids, clip_id)
                    end
                end
                reset_stmt(select_stmt)

                local update_shift_stmt, update_shift_err = ensure_bulk_shift_by_id_stmt()
                if not update_shift_stmt then
                    finalize_stmt(update_stmt)
                    finalize_stmt(delete_stmt)
                    finalize_stmt(insert_stmt)
                    finalize_stmt(bulk_shift_by_id_stmt)
                    finalize_stmt(bulk_shift_select_desc_stmt)
                    finalize_stmt(bulk_shift_select_asc_stmt)
                    finalize_stmt(bulk_shift_anchor_stmt)
                    return false, update_shift_err
                end
                for _, clip_id in ipairs(mut.clip_ids) do
                    update_shift_stmt:bind_value(1, mut.shift_frames)
                    update_shift_stmt:bind_value(2, now)
                    update_shift_stmt:bind_value(3, clip_id)
                    local ok_update = update_shift_stmt:exec()
                    local update_err = db:last_error()
                    reset_stmt(update_shift_stmt)
                    if not ok_update then
                        finalize_stmt(update_stmt)
                        finalize_stmt(delete_stmt)
                        finalize_stmt(insert_stmt)
                        finalize_stmt(bulk_shift_by_id_stmt)
                        finalize_stmt(bulk_shift_select_desc_stmt)
                        finalize_stmt(bulk_shift_select_asc_stmt)
                        finalize_stmt(bulk_shift_anchor_stmt)
                        return false, "Failed to execute bulk shift for clip " .. tostring(clip_id) .. ": " .. tostring(update_err or "unknown")
                    end
                end
	        else
	            finalize_stmt(update_stmt)
	            finalize_stmt(delete_stmt)
	            finalize_stmt(insert_stmt)
	            finalize_stmt(bulk_shift_by_id_stmt)
	            finalize_stmt(bulk_shift_select_desc_stmt)
	            finalize_stmt(bulk_shift_select_asc_stmt)
	            finalize_stmt(bulk_shift_anchor_stmt)
	            return false, "Unknown mutation type: " .. tostring(mut.type)
	        end
	    end

	    finalize_stmt(update_stmt)
	    finalize_stmt(delete_stmt)
	    finalize_stmt(insert_stmt)
	    finalize_stmt(bulk_shift_by_id_stmt)
	    finalize_stmt(bulk_shift_select_desc_stmt)
	    finalize_stmt(bulk_shift_select_asc_stmt)
	    finalize_stmt(bulk_shift_anchor_stmt)
	    return true
	end

function M.revert_mutations(db, mutations, command, sequence_id)
    if not db then return false, "No database connection" end
    if not mutations or #mutations == 0 then return true end

    local updates = {}
    local restore_deletes = {}
    local preserve_strict_order = command and command.type == "BatchRippleEdit"

    local function val_frames(v, label)
        if type(v) == "table" and v.frames then return v.frames end
        if type(v) == "number" then return v end
        error(string.format("undo %s: missing required %s frames", command and command.type or "update", label or "value"), 2)
    end

    local function require_rate(prev, context)
        local fps_num = prev and (prev.fps_numerator or (prev.rate and prev.rate.fps_numerator))
        local fps_den = prev and (prev.fps_denominator or (prev.rate and prev.rate.fps_denominator))
        if not fps_num or not fps_den then
            error(string.format("%s: missing fps for clip %s", context or "undo", tostring(prev and prev.id)), 2)
        end
        return fps_num, fps_den
    end

    local function apply_update(mut)
        local prev = mut.previous
        if not prev then return false, "Cannot undo update: missing previous state" end
        local now = os.time()

        local stmt = db:prepare([[
            UPDATE clips
            SET track_id = ?, timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?, modified_at = ?
            WHERE id = ?
        ]])
        if not stmt then return false, "Failed to prepare undo update: " .. tostring(db:last_error()) end

        stmt:bind_value(1, prev.track_id)
        stmt:bind_value(2, val_frames(prev.timeline_start or prev.start_value, "timeline_start"))
        stmt:bind_value(3, val_frames(prev.duration, "duration"))
        stmt:bind_value(4, val_frames(prev.source_in, "source_in"))
        stmt:bind_value(5, val_frames(prev.source_out, "source_out"))
        stmt:bind_value(6, prev.enabled and 1 or 0)
        stmt:bind_value(7, now)
        stmt:bind_value(8, prev.id)

        local ok = stmt:exec()
        local err = db:last_error()
        stmt:finalize()
        if not ok then
            return false, "Failed to execute undo update: " .. tostring(err)
        end

        if command then
            -- Include full clip state for UI cache update (not just clip_id)
            M.add_update_mutation(command, sequence_id, {
                clip_id = prev.id,
                track_id = prev.track_id,
                start_value = val_frames(prev.timeline_start or prev.start_value, "timeline_start"),
                duration_value = val_frames(prev.duration, "duration"),
                source_in_value = val_frames(prev.source_in, "source_in"),
                source_out_value = val_frames(prev.source_out, "source_out"),
                enabled = prev.enabled
            })
        end
        return true
    end

    local function restore_deleted_clip(mut)
        local prev = mut.previous
        if not prev then return false, "Cannot undo delete: missing previous state" end
        local fps_num, fps_den = require_rate(prev, "undo delete")
        if prev.created_at == nil or prev.modified_at == nil then
            return false, "undo delete: missing created_at/modified_at for clip " .. tostring(prev.id)
        end

        local stmt = db:prepare([[
            INSERT INTO clips (
                id, project_id, clip_kind, name, track_id, media_id,
                source_sequence_id, parent_clip_id, owner_sequence_id,
                timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                fps_numerator, fps_denominator, enabled, offline,
                created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not stmt then return false, "Failed to prepare undo delete: " .. tostring(db:last_error()) end

        stmt:bind_value(1, prev.id)
        stmt:bind_value(2, prev.project_id)
        stmt:bind_value(3, prev.clip_kind)
        stmt:bind_value(4, prev.name)
        stmt:bind_value(5, prev.track_id)
        stmt:bind_value(6, prev.media_id)
        stmt:bind_value(7, prev.source_sequence_id)
        stmt:bind_value(8, prev.parent_clip_id)
        stmt:bind_value(9, prev.owner_sequence_id or prev.track_sequence_id)
        stmt:bind_value(10, val_frames(prev.timeline_start or prev.start_value, "timeline_start"))
        stmt:bind_value(11, val_frames(prev.duration, "duration"))
        stmt:bind_value(12, val_frames(prev.source_in, "source_in"))
        stmt:bind_value(13, val_frames(prev.source_out, "source_out"))
        stmt:bind_value(14, fps_num)
        stmt:bind_value(15, fps_den)
        stmt:bind_value(16, prev.enabled and 1 or 0)
        stmt:bind_value(17, (prev.offline == 1 or prev.offline == true) and 1 or 0)
        stmt:bind_value(18, prev.created_at)
        stmt:bind_value(19, prev.modified_at)

        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            return false, "Failed to execute undo delete: " .. (db:last_error() or "")
        end

        if command then
            -- Include full clip payload for UI cache insert (not just id)
            M.add_insert_mutation(command, sequence_id, {
                id = prev.id,
                track_id = prev.track_id,
                start_value = val_frames(prev.timeline_start or prev.start_value, "timeline_start"),
                duration_value = val_frames(prev.duration, "duration"),
                source_in_value = val_frames(prev.source_in, "source_in"),
                source_out_value = val_frames(prev.source_out, "source_out"),
                enabled = prev.enabled,
                name = prev.name,
                media_id = prev.media_id
            })
        end
        return true
    end

    for i = #mutations, 1, -1 do
        local mut = mutations[i]
        if mut.type == "insert" then
            local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
            if not stmt then return false, "Failed to prepare undo insert: " .. tostring(db:last_error()) end
            stmt:bind_value(1, mut.clip_id)
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then return false, "Failed to execute undo insert: " .. tostring(db:last_error()) end

            if command then
                M.add_delete_mutation(command, sequence_id, mut.clip_id)
            end
        elseif mut.type == "delete" then
            if preserve_strict_order then
                local ok, err = restore_deleted_clip(mut)
                if not ok then return false, err end
            else
                table.insert(restore_deletes, mut)
            end
        elseif mut.type == "update" then
            if preserve_strict_order then
                local ok, err = apply_update(mut)
                if not ok then return false, err end
            else
                table.insert(updates, mut)
            end
	        elseif mut.type == "bulk_shift" then
	            local shift_frames = mut.shift_frames
	            if type(shift_frames) ~= "number" then
	                return false, "bulk_shift undo: missing numeric shift_frames"
	            end
            if type(mut.clip_ids) == "table" then
                local delta_frames = -shift_frames
                if delta_frames ~= 0 then
                    local select_stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
                    if not select_stmt then
                        return false, "bulk_shift undo: failed to prepare start query: " .. tostring(db:last_error())
                    end

                    local entries = {}
                    local seen = {}
                    for _, clip_id in ipairs(mut.clip_ids) do
                        if clip_id and not seen[clip_id] then
                            seen[clip_id] = true
                            select_stmt:bind_value(1, clip_id)
                            local ok_sel = select_stmt:exec()
                            local sel_err = db:last_error()
                            local has_row = ok_sel and select_stmt:next()
                            local start_frame = has_row and select_stmt:value(0) or nil
                            select_stmt:reset()
                            select_stmt:clear_bindings()
                            if not ok_sel or start_frame == nil then
                                select_stmt:finalize()
                                return false, "bulk_shift undo: failed to resolve start for clip " .. tostring(clip_id) .. ": " .. tostring(sel_err)
                            end
                            table.insert(entries, {id = clip_id, start_frame = start_frame})
                        end
                    end
	                    select_stmt:finalize()

	                    local order_desc = delta_frames > 0
	                    table.sort(entries, function(a, b)
	                        if a.start_frame == b.start_frame then
	                            if order_desc then
	                                return a.id > b.id
	                            end
	                            return a.id < b.id
	                        end
	                        if order_desc then
	                            return a.start_frame > b.start_frame
	                        end
	                        return a.start_frame < b.start_frame
	                    end)

                    local stmt = db:prepare("UPDATE clips SET timeline_start_frame = timeline_start_frame + ?, modified_at = ? WHERE id = ?")
                    if not stmt then return false, "bulk_shift undo: failed to prepare clip update: " .. tostring(db:last_error()) end
                    local now = os.time()
                    for _, entry in ipairs(entries) do
                        stmt:bind_value(1, delta_frames)
                        stmt:bind_value(2, now)
                        stmt:bind_value(3, entry.id)
                        local ok = stmt:exec()
                        local err = db:last_error()
                        stmt:reset()
                        stmt:clear_bindings()
                        if not ok then
                            stmt:finalize()
                            return false, "bulk_shift undo: failed to shift clip " .. tostring(entry.id) .. ": " .. tostring(err)
                        end
                    end
                    stmt:finalize()
                end
	            else
	                if not mut.track_id or mut.track_id == "" then
	                    return false, "bulk_shift undo: missing track_id"
	                end
	                if not mut.first_clip_id or mut.first_clip_id == "" then
	                    return false, "bulk_shift undo: missing first_clip_id"
	                end

                local anchor_stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
                if not anchor_stmt then return false, "bulk_shift undo: failed to prepare anchor query: " .. tostring(db:last_error()) end
                anchor_stmt:bind_value(1, mut.first_clip_id)
                local ok_anchor = anchor_stmt:exec() and anchor_stmt:next()
                local anchor_start = ok_anchor and anchor_stmt:value(0) or nil
                anchor_stmt:finalize()
                if anchor_start == nil then
                    return false, "bulk_shift undo: failed to resolve anchor start for clip " .. tostring(mut.first_clip_id)
                end

	                local order_desc = (-shift_frames) > 0
	                local select_sql = order_desc
	                    and "SELECT id FROM clips WHERE track_id = ? AND timeline_start_frame >= ? ORDER BY timeline_start_frame DESC"
	                    or "SELECT id FROM clips WHERE track_id = ? AND timeline_start_frame >= ? ORDER BY timeline_start_frame ASC"
	                local select_stmt = db:prepare(select_sql)
	                if not select_stmt then
	                    return false, "bulk_shift undo: failed to prepare clip enumeration: " .. tostring(db:last_error())
	                end
	                select_stmt:bind_value(1, mut.track_id)
	                select_stmt:bind_value(2, anchor_start)
	                local ok_select = select_stmt:exec()
	                local select_err = db:last_error()
	                if not ok_select then
	                    select_stmt:finalize()
	                    return false, "bulk_shift undo: failed to enumerate clips: " .. tostring(select_err)
	                end

	                local update_stmt = db:prepare("UPDATE clips SET timeline_start_frame = timeline_start_frame + ?, modified_at = ? WHERE id = ?")
	                if not update_stmt then
	                    select_stmt:finalize()
	                    return false, "bulk_shift undo: failed to prepare clip update: " .. tostring(db:last_error())
	                end
	                local now = os.time()
	                while select_stmt:next() do
	                    local clip_id = select_stmt:value(0)
	                    update_stmt:bind_value(1, -shift_frames)
	                    update_stmt:bind_value(2, now)
	                    update_stmt:bind_value(3, clip_id)
	                    local ok = update_stmt:exec()
	                    local err = db:last_error()
	                    update_stmt:reset()
	                    update_stmt:clear_bindings()
	                    if not ok then
	                        update_stmt:finalize()
	                        select_stmt:finalize()
	                        return false, "bulk_shift undo: failed to shift clip " .. tostring(clip_id) .. ": " .. tostring(err)
	                    end
	                end
	                update_stmt:finalize()
	                select_stmt:finalize()
	            end

            if command and sequence_id then
                local payload = {
                    track_id = mut.track_id,
                    first_clip_id = mut.first_clip_id,
                    anchor_start_frame = mut.anchor_start_frame,
                    shift_frames = -shift_frames,
                    start_frames = mut.start_frames,
                    clip_ids = mut.clip_ids,
                }
                M.add_bulk_shift_mutation(command, sequence_id, payload)
            end
        else
            return false, "Unknown mutation type: " .. tostring(mut.type)
        end
    end

    if #updates > 0 then
        if command and command.type == "Nudge" then
            local nudge = command.get_parameter and (command:get_parameter("nudge_amount_rat") or command:get_parameter("nudge_amount"))
            local sign = 0
            if type(nudge) == "table" and nudge.frames then
                sign = (nudge.frames > 0) and 1 or ((nudge.frames < 0) and -1 or 0)
            elseif type(nudge) == "number" then
                sign = (nudge > 0) and 1 or ((nudge < 0) and -1 or 0)
            end
            local function start_frames(mut)
                local prev = mut.previous
                if not prev then
                    error("undo update: mutation missing 'previous' state - incompatible command version", 2)
                end
                local ts = prev.timeline_start or prev.start_value
                if type(ts) == "table" and ts.frames then return ts.frames end
                if type(ts) == "number" then return ts end
                -- Likely an old mutation from before fps capture was added
                error(string.format(
                    "undo update: clip %s missing timeline_start frames - try deleting ~/Documents/JVE\\ Projects/Untitled\\ Project.jvp to reset command history",
                    tostring(prev.id or "unknown")
                ), 2)
            end
            table.sort(updates, function(a, b)
                local sa = start_frames(a)
                local sb = start_frames(b)
                if sign < 0 then
                    return sa > sb
                else
                    return sa < sb
                end
            end)
        end

        for _, mut in ipairs(updates) do
            local ok, err = apply_update(mut)
            if not ok then return false, err end
        end
    end

    for _, mut in ipairs(restore_deletes) do
        local ok, err = restore_deleted_clip(mut)
        if not ok then return false, err end
    end
    return true
end

return M
