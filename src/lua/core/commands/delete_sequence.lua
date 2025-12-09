local M = {}

local function set_error(set_last_error, message)
    if set_last_error then
        set_last_error(message)
    end
end

local function ensure_mutation_bucket(command, sequence_id)
    if not command or not sequence_id then
        return nil
    end
    local mutations = command:get_parameter("__timeline_mutations")
    if not mutations then
        mutations = {}
        command:set_parameter("__timeline_mutations", mutations)
    elseif mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
        local existing = mutations
        mutations = {[existing.sequence_id or sequence_id] = existing}
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

local function fetch_sequence_record(db, sequence_id)
    if not sequence_id or sequence_id == "" then
        return nil
    end

    local stmt = db:prepare([[
        SELECT id, project_id, name, kind,
               fps_numerator, fps_denominator, audio_rate, width, height,
               view_start_frame, view_duration_frames, playhead_frame,
               mark_in_frame, mark_out_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
               current_sequence_number, created_at, modified_at
        FROM sequences
        WHERE id = ?
    ]])
    if not stmt then
        return nil
    end

    stmt:bind_value(1, sequence_id)
    local sequence = nil
    if stmt:exec() and stmt:next() then
        sequence = {
            id = stmt:value(0),
            project_id = stmt:value(1),
            name = stmt:value(2),
            kind = stmt:value(3),
            fps_numerator = tonumber(stmt:value(4)) or 0,
            fps_denominator = tonumber(stmt:value(5)) or 1,
            frame_rate = (tonumber(stmt:value(4)) or 0) / (tonumber(stmt:value(5)) or 1),
            audio_sample_rate = tonumber(stmt:value(6)) or tonumber(stmt:value(6)) or 48000,
            audio_rate = tonumber(stmt:value(6)) or 48000,
            width = tonumber(stmt:value(7)) or 0,
            height = tonumber(stmt:value(8)) or 0,
            view_start_frame = tonumber(stmt:value(9)) or 0,
            view_duration_frames = tonumber(stmt:value(10)) or 240,
            playhead_value = tonumber(stmt:value(11)) or 0,
            mark_in_value = stmt:value(12) and tonumber(stmt:value(12)) or nil,
            mark_out_value = stmt:value(13) and tonumber(stmt:value(13)) or nil,
            selected_clip_ids = stmt:value(14),
            selected_edge_infos = stmt:value(15),
            selected_gap_infos = stmt:value(16),
            current_sequence_number = stmt:value(17) and tonumber(stmt:value(17)) or nil,
            created_at = stmt:value(18) and tonumber(stmt:value(18)) or os.time(),
            modified_at = stmt:value(19) and tonumber(stmt:value(19)) or os.time()
        }
    end
    stmt:finalize()
    return sequence
end

local function fetch_sequence_tracks(db, sequence_id)
    local tracks = {}
    local stmt = db:prepare([[
        SELECT id, sequence_id, name, track_type,
               track_index, enabled, locked, muted, soloed, volume, pan
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type DESC, track_index ASC
    ]])
    if not stmt then
        return tracks
    end
    stmt:bind_value(1, sequence_id)
    if stmt:exec() then
        while stmt:next() do
            table.insert(tracks, {
                id = stmt:value(0),
                sequence_id = stmt:value(1),
                name = stmt:value(2),
                track_type = stmt:value(3),
                track_index = tonumber(stmt:value(4)) or 0,
                enabled = stmt:value(5) == 1 or stmt:value(5) == true,
                locked = stmt:value(6) == 1 or stmt:value(6) == true,
                muted = stmt:value(7) == 1 or stmt:value(7) == true,
                soloed = stmt:value(8) == 1 or stmt:value(8) == true,
                volume = tonumber(stmt:value(9)) or 1.0,
                pan = tonumber(stmt:value(10)) or 0.0
            })
        end
    end
    stmt:finalize()
    return tracks
end

local function fetch_clip_properties(db, clip_id)
    local props = {}
    local stmt = db:prepare([[
        SELECT id, property_name, property_value, property_type, default_value
        FROM properties
        WHERE clip_id = ?
    ]])
    if not stmt then
        return props
    end
    stmt:bind_value(1, clip_id)
    if stmt:exec() then
        while stmt:next() do
            table.insert(props, {
                id = stmt:value(0),
                property_name = stmt:value(1),
                property_value = stmt:value(2),
                property_type = stmt:value(3),
                default_value = stmt:value(4),
            })
        end
    end
    stmt:finalize()
    return props
end

local function fetch_sequence_clips(db, sequence_id)
    local clips = {}
    local properties = {}
    local clip_links = {}

    local clip_stmt = db:prepare([[
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               source_sequence_id, parent_clip_id, owner_sequence_id,
               timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
               fps_numerator, fps_denominator, enabled,
               offline, created_at, modified_at
        FROM clips
        WHERE track_id IN (
            SELECT id FROM tracks WHERE sequence_id = ?
        )
        ORDER BY track_id, timeline_start_frame
    ]])
    if not clip_stmt then
        return clips, properties, clip_links
    end
    clip_stmt:bind_value(1, sequence_id)

    if clip_stmt:exec() then
        while clip_stmt:next() do
            local clip_id = clip_stmt:value(0)
            local clip_entry = {
                id = clip_id,
                project_id = clip_stmt:value(1),
                clip_kind = clip_stmt:value(2),
                name = clip_stmt:value(3),
                track_id = clip_stmt:value(4),
                media_id = clip_stmt:value(5),
                source_sequence_id = clip_stmt:value(6),
                parent_clip_id = clip_stmt:value(7),
                owner_sequence_id = clip_stmt:value(8),
                start_value = tonumber(clip_stmt:value(9)) or 0,
                duration_value = tonumber(clip_stmt:value(10)) or 0,
                source_in_value = tonumber(clip_stmt:value(11)) or 0,
                source_out_value = tonumber(clip_stmt:value(12)) or 0,
                fps_numerator = tonumber(clip_stmt:value(13)) or 0,
                fps_denominator = tonumber(clip_stmt:value(14)) or 1,
                enabled = clip_stmt:value(15) == 1 or clip_stmt:value(15) == true,
                offline = clip_stmt:value(16) == 1 or clip_stmt:value(16) == true,
                created_at = clip_stmt:value(17) and tonumber(clip_stmt:value(17)) or nil,
                modified_at = clip_stmt:value(18) and tonumber(clip_stmt:value(18)) or nil
            }
            table.insert(clips, clip_entry)
        end
    end

    clip_stmt:finalize()

    return clips, properties, clip_links
end

local function fetch_sequence_snapshot(db, sequence_id)
    local stmt = db:prepare([[
        SELECT id, sequence_id, sequence_number, clips_state, created_at
        FROM snapshots
        WHERE sequence_id = ?
        ORDER BY created_at DESC
        LIMIT 1
    ]])

    if not stmt then
        return nil
    end

    stmt:bind_value(1, sequence_id)
    local snapshot = nil
    if stmt:exec() and stmt:next() then
        snapshot = {
            id = stmt:value(0),
            sequence_id = stmt:value(1),
            sequence_number = tonumber(stmt:value(2)) or 0,
            clips_state = stmt:value(3),
            created_at = tonumber(stmt:value(4)) or os.time()
        }
    end
    stmt:finalize()
    return snapshot
end

local function count_sequence_references(db, sequence_id)
    local stmt = db:prepare([[
        SELECT COUNT(*) FROM clips
        WHERE source_sequence_id = ?
          AND (owner_sequence_id IS NULL OR owner_sequence_id <> ?)
    ]])
    if not stmt then
        return 0
    end
    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, sequence_id)
    local count = 0
    if stmt:exec() and stmt:next() then
        count = tonumber(stmt:value(0)) or 0
    end
    stmt:finalize()
    return count
end

local function insert_properties_for_clip(db, clip_id, props)
    if not props or #props == 0 then
        return true
    end
    local stmt = db:prepare([[
        INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value)
        VALUES (?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then
        return false
    end
    for _, prop in ipairs(props) do
        stmt:bind_value(1, prop.id)
        stmt:bind_value(2, clip_id)
        stmt:bind_value(3, prop.property_name)
        stmt:bind_value(4, prop.property_value)
        stmt:bind_value(5, prop.property_type)
        stmt:bind_value(6, prop.default_value)
        if not stmt:exec() then
            stmt:finalize()
            return false
        end
        stmt:reset()
    end
    stmt:finalize()
    return true
end

local function restore_sequence_from_payload(db, set_last_error, payload)
    if not payload or type(payload) ~= "table" then
        set_error(set_last_error, "UndoDeleteSequence: Missing snapshot payload")
        return false
    end

    local sequence_row = payload.sequence
    if not sequence_row or not sequence_row.id then
        set_error(set_last_error, "UndoDeleteSequence: Missing sequence record")
        return false
    end

    local insert_sequence_stmt = db:prepare([[
        INSERT INTO sequences (
            id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
            view_start_frame, view_duration_frames, playhead_frame,
            mark_in_frame, mark_out_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not insert_sequence_stmt then
        set_error(set_last_error, "UndoDeleteSequence: Failed to prepare sequence insert")
        return false
    end

    insert_sequence_stmt:bind_value(1, sequence_row.id)
    insert_sequence_stmt:bind_value(2, sequence_row.project_id)
    insert_sequence_stmt:bind_value(3, sequence_row.name)
    insert_sequence_stmt:bind_value(4, sequence_row.kind or "timeline")
    insert_sequence_stmt:bind_value(5, sequence_row.fps_numerator or 24)
    insert_sequence_stmt:bind_value(6, sequence_row.fps_denominator or 1)
    insert_sequence_stmt:bind_value(7, sequence_row.audio_rate or sequence_row.audio_sample_rate or 48000)
    insert_sequence_stmt:bind_value(8, sequence_row.width or 1920)
    insert_sequence_stmt:bind_value(9, sequence_row.height or 1080)
    insert_sequence_stmt:bind_value(10, sequence_row.view_start_frame or 0)
    insert_sequence_stmt:bind_value(11, sequence_row.view_duration_frames or 240)
    insert_sequence_stmt:bind_value(12, sequence_row.playhead_value or 0)
    insert_sequence_stmt:bind_value(13, sequence_row.mark_in_value)
    insert_sequence_stmt:bind_value(14, sequence_row.mark_out_value)
    insert_sequence_stmt:bind_value(15, sequence_row.selected_clip_ids or '[]')
    insert_sequence_stmt:bind_value(16, sequence_row.selected_edge_infos or '[]')
    insert_sequence_stmt:bind_value(17, sequence_row.selected_gap_infos or '[]')
    insert_sequence_stmt:bind_value(18, sequence_row.current_sequence_number)
    insert_sequence_stmt:bind_value(19, sequence_row.created_at or os.time())
    insert_sequence_stmt:bind_value(20, sequence_row.modified_at or os.time())

    if not insert_sequence_stmt:exec() then
        insert_sequence_stmt:finalize()
        set_error(set_last_error, "UndoDeleteSequence: Failed to restore sequence row")
        return false
    end
    insert_sequence_stmt:finalize()

    local tracks = payload.tracks or {}
    if #tracks > 0 then
        local insert_track_stmt = db:prepare([[
            INSERT INTO tracks (
                id, sequence_id, name, track_type, track_index,
                enabled, locked, muted, soloed, volume, pan
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not insert_track_stmt then
            set_error(set_last_error, "UndoDeleteSequence: Failed to prepare track insert")
            return false
        end
        for _, track in ipairs(tracks) do
            insert_track_stmt:bind_value(1, track.id)
            insert_track_stmt:bind_value(2, track.sequence_id or sequence_row.id)
            insert_track_stmt:bind_value(3, track.name or "")
            insert_track_stmt:bind_value(4, track.track_type or "VIDEO")
            insert_track_stmt:bind_value(5, track.track_index or 0)
            insert_track_stmt:bind_value(6, track.enabled and 1 or 0)
            insert_track_stmt:bind_value(7, track.locked and 1 or 0)
            insert_track_stmt:bind_value(8, track.muted and 1 or 0)
            insert_track_stmt:bind_value(9, track.soloed and 1 or 0)
            insert_track_stmt:bind_value(10, track.volume or 1.0)
            insert_track_stmt:bind_value(11, track.pan or 0.0)
            if not insert_track_stmt:exec() then
                insert_track_stmt:finalize()
                set_error(set_last_error, "UndoDeleteSequence: Failed to restore track")
                return false
            end
            insert_track_stmt:reset()
            insert_track_stmt:clear_bindings()
        end
        insert_track_stmt:finalize()
    end

    local clips = payload.clips or {}
    if #clips > 0 then
        local insert_clip_stmt = db:prepare([[
            INSERT INTO clips (
                id, project_id, clip_kind, name, track_id, media_id,
                source_sequence_id, parent_clip_id, owner_sequence_id,
                timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                fps_numerator, fps_denominator, enabled,
                offline, created_at, modified_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not insert_clip_stmt then
            set_error(set_last_error, "UndoDeleteSequence: Failed to prepare clip insert")
            return false
        end

        for _, clip in ipairs(clips) do
            insert_clip_stmt:bind_value(1, clip.id)
            insert_clip_stmt:bind_value(2, clip.project_id)
            insert_clip_stmt:bind_value(3, clip.clip_kind or "timeline")
            insert_clip_stmt:bind_value(4, clip.name or "")
            insert_clip_stmt:bind_value(5, clip.track_id)
            insert_clip_stmt:bind_value(6, clip.media_id)
            insert_clip_stmt:bind_value(7, clip.source_sequence_id)
            insert_clip_stmt:bind_value(8, clip.parent_clip_id)
            insert_clip_stmt:bind_value(9, clip.owner_sequence_id or sequence_row.id)
            insert_clip_stmt:bind_value(10, clip.start_value or 0)
            insert_clip_stmt:bind_value(11, clip.duration_value or clip.duration or 0)
            insert_clip_stmt:bind_value(12, clip.source_in_value or clip.source_in or 0)
            insert_clip_stmt:bind_value(13, clip.source_out_value or clip.source_out or 0)
            insert_clip_stmt:bind_value(14, clip.fps_numerator or sequence_row.fps_numerator or 24)
            insert_clip_stmt:bind_value(15, clip.fps_denominator or sequence_row.fps_denominator or 1)
            insert_clip_stmt:bind_value(16, clip.enabled and 1 or 0)
            insert_clip_stmt:bind_value(17, clip.offline and 1 or 0)
            insert_clip_stmt:bind_value(18, clip.created_at or os.time())
            insert_clip_stmt:bind_value(19, clip.modified_at or os.time())
            if not insert_clip_stmt:exec() then
                insert_clip_stmt:finalize()
                set_error(set_last_error, "UndoDeleteSequence: Failed to restore clip")
                return false
            end
            insert_clip_stmt:reset()
            insert_clip_stmt:clear_bindings()

            local props = payload.properties and payload.properties[clip.id]
            if props and not insert_properties_for_clip(db, clip.id, props) then
                insert_clip_stmt:finalize()
                set_error(set_last_error, "UndoDeleteSequence: Failed to restore clip properties")
                return false
            end
        end
        insert_clip_stmt:finalize()
    end

    local clip_links = payload.clip_links or {}
    if #clip_links > 0 then
        local insert_link_stmt = db:prepare([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, timebase_type, timebase_rate, enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]])
        if insert_link_stmt then
            for _, link in ipairs(clip_links) do
                insert_link_stmt:bind_value(1, link.link_group_id)
                insert_link_stmt:bind_value(2, link.clip_id)
                insert_link_stmt:bind_value(3, link.role)
                insert_link_stmt:bind_value(4, link.time_offset or 0)
                insert_link_stmt:bind_value(5, link.timebase_type or "video_frames")
                insert_link_stmt:bind_value(6, link.timebase_rate or 24)
                insert_link_stmt:bind_value(7, link.enabled and 1 or 0)
                insert_link_stmt:exec()
                insert_link_stmt:reset()
                insert_link_stmt:clear_bindings()
            end
            insert_link_stmt:finalize()
        end
    end

    if payload.snapshot then
        local snapshot = payload.snapshot
        local insert_snapshot_stmt = db:prepare([[
            INSERT OR REPLACE INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at)
            VALUES (?, ?, ?, ?, ?)
        ]])
        if insert_snapshot_stmt then
            insert_snapshot_stmt:bind_value(1, snapshot.id)
            insert_snapshot_stmt:bind_value(2, snapshot.sequence_id or sequence_row.id)
            insert_snapshot_stmt:bind_value(3, snapshot.sequence_number or 0)
            insert_snapshot_stmt:bind_value(4, snapshot.clips_state)
            insert_snapshot_stmt:bind_value(5, snapshot.created_at or os.time())
            insert_snapshot_stmt:exec()
            insert_snapshot_stmt:finalize()
        end
    end

    print(string.format("✅ Undo DeleteSequence: Restored sequence %s", tostring(sequence_row.id)))
    return true
end

function M.register(command_executors, command_undoers, db, set_last_error)
    if not command_executors or not command_undoers then
        return nil
    end

    command_executors["DeleteSequence"] = function(command)
        local sequence_id = command:get_parameter("sequence_id")
        if not sequence_id or sequence_id == "" then
            set_error(set_last_error, "DeleteSequence: Missing sequence_id")
            return false
        end
        if sequence_id == "default_sequence" then
            set_error(set_last_error, "DeleteSequence: Cannot delete default sequence")
            return false
        end

        local sequence_row = fetch_sequence_record(db, sequence_id)
        if not sequence_row then
            set_error(set_last_error, "DeleteSequence: Sequence not found")
            return false
        end

        if sequence_row.kind and sequence_row.kind ~= "timeline" then
            set_error(set_last_error, "DeleteSequence: Only timeline sequences can be deleted")
            return false
        end

        if count_sequence_references(db, sequence_id) > 0 then
            set_error(set_last_error, "DeleteSequence: Sequence is referenced by other clips")
            return false
        end

        local tracks = fetch_sequence_tracks(db, sequence_id)
        local clips, clip_properties, clip_links = fetch_sequence_clips(db, sequence_id)
        local snapshot = fetch_sequence_snapshot(db, sequence_id)

        local payload = {
            sequence = sequence_row,
            tracks = tracks,
            clips = clips,
            properties = clip_properties,
            clip_links = clip_links,
            snapshot = snapshot
        }
        command:set_parameter("delete_sequence_snapshot", payload)

        if #clips > 0 then
            local clip_ids = {}
            for _, clip in ipairs(clips) do
                table.insert(clip_ids, clip.id)
            end
            local delete_links = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
            if delete_links then
                for _, clip_id in ipairs(clip_ids) do
                    delete_links:bind_value(1, clip_id)
                    delete_links:exec()
                    delete_links:reset()
                end
                delete_links:finalize()
            end

            local delete_properties = db:prepare("DELETE FROM properties WHERE clip_id = ?")
            if delete_properties then
                for _, clip_id in ipairs(clip_ids) do
                    delete_properties:bind_value(1, clip_id)
                    delete_properties:exec()
                    delete_properties:reset()
                end
                delete_properties:finalize()
            end

            local delete_clips = db:prepare("DELETE FROM clips WHERE owner_sequence_id = ?")
            if delete_clips then
                delete_clips:bind_value(1, sequence_id)
                delete_clips:exec()
                delete_clips:finalize()
            end
        end

        local delete_tracks = db:prepare("DELETE FROM tracks WHERE sequence_id = ?")
        if delete_tracks then
            delete_tracks:bind_value(1, sequence_id)
            delete_tracks:exec()
            delete_tracks:finalize()
        end

        local delete_snapshots = db:prepare("DELETE FROM snapshots WHERE sequence_id = ?")
        if delete_snapshots then
            delete_snapshots:bind_value(1, sequence_id)
            delete_snapshots:exec()
            delete_snapshots:finalize()
        end

        local delete_sequence_stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
        if not delete_sequence_stmt then
            set_error(set_last_error, "DeleteSequence: Failed to prepare delete statement")
            return false
        end
        delete_sequence_stmt:bind_value(1, sequence_id)
        local ok = delete_sequence_stmt:exec()
        delete_sequence_stmt:finalize()
        if not ok then
            set_error(set_last_error, "DeleteSequence: Failed to delete sequence")
            return false
        end

        command:set_parameter("__skip_timeline_reload", true)
        command:set_parameter("__allow_empty_mutations", true)
        local bucket = ensure_mutation_bucket(command, sequence_id)
        if bucket then
            bucket.sequence_meta = bucket.sequence_meta or {}
            table.insert(bucket.sequence_meta, {
                action = "deleted",
                sequence_id = sequence_id,
                project_id = sequence_row.project_id,
                name = sequence_row.name
            })
        end
        print(string.format("✅ Deleted sequence %s (%d track(s), %d clip(s))",
            sequence_row.name or sequence_id, #tracks, #clips))
        return true
    end

    command_undoers["DeleteSequence"] = function(command)
        local payload = command:get_parameter("delete_sequence_snapshot")
        return restore_sequence_from_payload(db, set_last_error, payload)
    end

    command_executors["UndoDeleteSequence"] = command_undoers["DeleteSequence"]

    return {
        executor = command_executors["DeleteSequence"],
        undoer = command_undoers["DeleteSequence"],
    }
end

function M.restore_from_payload(db, payload, set_last_error)
    return restore_sequence_from_payload(db, set_last_error, payload)
end

return M
