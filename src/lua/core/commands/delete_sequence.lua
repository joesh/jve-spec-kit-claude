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
-- Size: ~551 LOC
-- Volatility: unknown
--
-- @file delete_sequence.lua
local M = {}
local set_error
local ensure_mutation_bucket
local fetch_sequence_record
local fetch_sequence_tracks
local fetch_clip_properties
local fetch_sequence_clips
local fetch_sequence_snapshot
local count_sequence_references
local insert_properties_for_clip
local restore_sequence_from_payload


local SPEC = {
    args = {
        delete_sequence_snapshot = {},
        project_id = { required = true },
        sequence_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    assert(command_executors, "DeleteSequence.register: missing command_executors")
    assert(command_undoers, "DeleteSequence.register: missing command_undoers")

    command_executors["DeleteSequence"] = function(command)
        local args = command:get_all_parameters()
        local sequence_id = args.sequence_id
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
                    assert(delete_links:exec(), "DeleteSequence: clip_links DELETE failed for clip " .. tostring(clip_id))
                    delete_links:reset()
                end
                delete_links:finalize()
            end

            local delete_properties = db:prepare("DELETE FROM properties WHERE clip_id = ?")
            if delete_properties then
                for _, clip_id in ipairs(clip_ids) do
                    delete_properties:bind_value(1, clip_id)
                    assert(delete_properties:exec(), "DeleteSequence: properties DELETE failed for clip " .. tostring(clip_id))
                    delete_properties:reset()
                end
                delete_properties:finalize()
            end

            local delete_clips = assert(db:prepare("DELETE FROM clips WHERE owner_sequence_id = ?"),
                "DeleteSequence: failed to prepare clips DELETE for sequence " .. tostring(sequence_id))
            delete_clips:bind_value(1, sequence_id)
            assert(delete_clips:exec(), "DeleteSequence: clips DELETE failed for sequence " .. tostring(sequence_id))
            delete_clips:finalize()
        end

        local delete_tracks = assert(db:prepare("DELETE FROM tracks WHERE sequence_id = ?"),
            "DeleteSequence: failed to prepare tracks DELETE for sequence " .. tostring(sequence_id))
        delete_tracks:bind_value(1, sequence_id)
        assert(delete_tracks:exec(), "DeleteSequence: tracks DELETE failed for sequence " .. tostring(sequence_id))
        delete_tracks:finalize()

        local delete_snapshots = db:prepare("DELETE FROM snapshots WHERE sequence_id = ?")
        if delete_snapshots then
            delete_snapshots:bind_value(1, sequence_id)
            assert(delete_snapshots:exec(), "DeleteSequence: snapshots DELETE failed for sequence " .. tostring(sequence_id))
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

        command:set_parameters({
            ["__skip_timeline_reload"] = true,
            ["__allow_empty_mutations"] = true,
        })
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
        local args = command:get_all_parameters()

        return restore_sequence_from_payload(db, set_last_error, args.delete_sequence_snapshot)
    end

    command_executors["UndoDeleteSequence"] = command_undoers["DeleteSequence"]

    return {
        executor = command_executors["DeleteSequence"],
        undoer = command_undoers["DeleteSequence"],
        spec = SPEC,
    }
end

function M.restore_from_payload(db, payload, set_last_error)
    return restore_sequence_from_payload(db, set_last_error, payload)
end


set_error = function(set_last_error, message)
    if set_last_error then
        set_last_error(message)
    end
end

ensure_mutation_bucket = function(command, sequence_id)
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

fetch_sequence_record = function(db, sequence_id)
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
            fps_numerator = assert(tonumber(stmt:value(4)), "DeleteSequence.fetch_sequence_record: missing fps_numerator for sequence " .. tostring(sequence_id)),
            fps_denominator = assert(tonumber(stmt:value(5)), "DeleteSequence.fetch_sequence_record: missing fps_denominator for sequence " .. tostring(sequence_id)),
            frame_rate = assert(tonumber(stmt:value(4)), "unreachable") / assert(tonumber(stmt:value(5)), "unreachable"),
            audio_sample_rate = assert(tonumber(stmt:value(6)), "DeleteSequence.fetch_sequence_record: missing audio_rate for sequence " .. tostring(sequence_id)),
            audio_rate = assert(tonumber(stmt:value(6)), "DeleteSequence.fetch_sequence_record: missing audio_rate for sequence " .. tostring(sequence_id)),
            width = assert(tonumber(stmt:value(7)), "DeleteSequence.fetch_sequence_record: missing width for sequence " .. tostring(sequence_id)),
            height = assert(tonumber(stmt:value(8)), "DeleteSequence.fetch_sequence_record: missing height for sequence " .. tostring(sequence_id)),
            view_start_frame = assert(tonumber(stmt:value(9)), "DeleteSequence.fetch_sequence_record: NULL view_start_frame for sequence " .. tostring(sequence_id)),
            view_duration_frames = assert(tonumber(stmt:value(10)), "DeleteSequence.fetch_sequence_record: NULL view_duration_frames for sequence " .. tostring(sequence_id)),
            playhead_value = assert(tonumber(stmt:value(11)), "DeleteSequence.fetch_sequence_record: NULL playhead_frame for sequence " .. tostring(sequence_id)),
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

fetch_sequence_tracks = function(db, sequence_id)
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
                volume = tonumber(stmt:value(9)) or 1.0, -- NSF-OK: unity gain default
                pan = tonumber(stmt:value(10)) or 0.0 -- NSF-OK: center pan default
            })
        end
    end
    stmt:finalize()
    return tracks
end

-- luacheck: ignore 211 (fetch_clip_properties defined but unused - kept for future use)
fetch_clip_properties = function(db_conn, clip_id)
    local props = {}
    local stmt = db_conn:prepare([[
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

fetch_sequence_clips = function(db, sequence_id)
    local clips = {}
    local properties = {}
    local clip_links = {}

    local clip_stmt = db:prepare([[
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               master_clip_id, parent_clip_id, owner_sequence_id,
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
                master_clip_id = clip_stmt:value(6),
                parent_clip_id = clip_stmt:value(7),
                owner_sequence_id = clip_stmt:value(8),
                start_value = assert(tonumber(clip_stmt:value(9)), "DeleteSequence.fetch_sequence_clips: missing start_value for clip " .. tostring(clip_id)),
                duration_value = assert(tonumber(clip_stmt:value(10)), "DeleteSequence.fetch_sequence_clips: missing duration_value for clip " .. tostring(clip_id)),
                source_in_value = assert(tonumber(clip_stmt:value(11)), "DeleteSequence.fetch_sequence_clips: missing source_in_value for clip " .. tostring(clip_id)),
                source_out_value = assert(tonumber(clip_stmt:value(12)), "DeleteSequence.fetch_sequence_clips: missing source_out_value for clip " .. tostring(clip_id)),
                fps_numerator = assert(tonumber(clip_stmt:value(13)), "DeleteSequence.fetch_sequence_clips: missing fps_numerator for clip " .. tostring(clip_id)),
                fps_denominator = assert(tonumber(clip_stmt:value(14)), "DeleteSequence.fetch_sequence_clips: missing fps_denominator for clip " .. tostring(clip_id)),
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

fetch_sequence_snapshot = function(db, sequence_id)
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

count_sequence_references = function(db, sequence_id)
    local stmt = db:prepare([[
        SELECT COUNT(*) FROM clips
        WHERE master_clip_id = ?
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

insert_properties_for_clip = function(db, clip_id, props)
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

restore_sequence_from_payload = function(db, set_last_error, payload)
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
    if not sequence_row.fps_numerator then
        set_error(set_last_error, "UndoDeleteSequence: Missing sequence fps_numerator")
        insert_sequence_stmt:finalize()
        return false
    end
    if not sequence_row.fps_denominator then
        set_error(set_last_error, "UndoDeleteSequence: Missing sequence fps_denominator")
        insert_sequence_stmt:finalize()
        return false
    end
    insert_sequence_stmt:bind_value(5, sequence_row.fps_numerator)
    insert_sequence_stmt:bind_value(6, sequence_row.fps_denominator)
    local audio_rate = sequence_row.audio_rate or sequence_row.audio_sample_rate
    assert(audio_rate, "UndoDeleteSequence: missing audio_rate for sequence " .. tostring(sequence_row.id))
    assert(sequence_row.width, "UndoDeleteSequence: missing width for sequence " .. tostring(sequence_row.id))
    assert(sequence_row.height, "UndoDeleteSequence: missing height for sequence " .. tostring(sequence_row.id))
    insert_sequence_stmt:bind_value(7, audio_rate)
    insert_sequence_stmt:bind_value(8, sequence_row.width)
    insert_sequence_stmt:bind_value(9, sequence_row.height)
    insert_sequence_stmt:bind_value(10, sequence_row.view_start_frame)
    insert_sequence_stmt:bind_value(11, sequence_row.view_duration_frames)
    insert_sequence_stmt:bind_value(12, sequence_row.playhead_value)
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
            insert_track_stmt:bind_value(2, assert(track.sequence_id or sequence_row.id, "UndoDeleteSequence: track missing sequence_id"))
            insert_track_stmt:bind_value(3, assert(track.name, "UndoDeleteSequence: track missing name"))
            insert_track_stmt:bind_value(4, assert(track.track_type, "UndoDeleteSequence: track missing track_type"))
            insert_track_stmt:bind_value(5, assert(track.track_index, "UndoDeleteSequence: track missing track_index"))
            insert_track_stmt:bind_value(6, track.enabled and 1 or 0)
            insert_track_stmt:bind_value(7, track.locked and 1 or 0)
            insert_track_stmt:bind_value(8, track.muted and 1 or 0)
            insert_track_stmt:bind_value(9, track.soloed and 1 or 0)
            insert_track_stmt:bind_value(10, track.volume or 1.0) -- NSF-OK: unity gain default
            insert_track_stmt:bind_value(11, track.pan or 0.0) -- NSF-OK: center pan default
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
                master_clip_id, parent_clip_id, owner_sequence_id,
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
            insert_clip_stmt:bind_value(7, clip.master_clip_id)
            insert_clip_stmt:bind_value(8, clip.parent_clip_id)
            insert_clip_stmt:bind_value(9, clip.owner_sequence_id or sequence_row.id)
            insert_clip_stmt:bind_value(10, clip.start_value or 0)
            insert_clip_stmt:bind_value(11, clip.duration_value or clip.duration or 0)
            insert_clip_stmt:bind_value(12, clip.source_in_value or clip.source_in or 0)
            insert_clip_stmt:bind_value(13, clip.source_out_value or clip.source_out or 0)
            local clip_fps_num = clip.fps_numerator or sequence_row.fps_numerator
            local clip_fps_den = clip.fps_denominator or sequence_row.fps_denominator
            if not clip_fps_num or not clip_fps_den then
                insert_clip_stmt:finalize()
                set_error(set_last_error, "UndoDeleteSequence: Missing clip fps")
                return false
            end
            insert_clip_stmt:bind_value(14, clip_fps_num)
            insert_clip_stmt:bind_value(15, clip_fps_den)
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
        local insert_link_stmt = assert(db:prepare([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, timebase_type, timebase_rate, enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]]), "UndoDeleteSequence: failed to prepare clip_links INSERT")
        for _, link in ipairs(clip_links) do
            insert_link_stmt:bind_value(1, link.link_group_id)
            insert_link_stmt:bind_value(2, link.clip_id)
            insert_link_stmt:bind_value(3, link.role)
            insert_link_stmt:bind_value(4, link.time_offset or 0)
            insert_link_stmt:bind_value(5, link.timebase_type or "video_frames")
            assert(link.timebase_rate, "UndoDeleteSequence: missing link timebase_rate for clip " .. tostring(link.clip_id))
            insert_link_stmt:bind_value(6, link.timebase_rate)
            insert_link_stmt:bind_value(7, link.enabled and 1 or 0)
            assert(insert_link_stmt:exec(), "UndoDeleteSequence: clip_links INSERT failed for clip " .. tostring(link.clip_id))
            insert_link_stmt:reset()
            insert_link_stmt:clear_bindings()
        end
        insert_link_stmt:finalize()
    end

    if payload.snapshot then
        local snapshot = payload.snapshot
        local insert_snapshot_stmt = assert(db:prepare([[
            INSERT OR REPLACE INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at)
            VALUES (?, ?, ?, ?, ?)
        ]]), "UndoDeleteSequence: failed to prepare snapshots INSERT")
        insert_snapshot_stmt:bind_value(1, snapshot.id)
        insert_snapshot_stmt:bind_value(2, snapshot.sequence_id or sequence_row.id)
        insert_snapshot_stmt:bind_value(3, snapshot.sequence_number or 0)
        insert_snapshot_stmt:bind_value(4, snapshot.clips_state)
        insert_snapshot_stmt:bind_value(5, snapshot.created_at or os.time())
        assert(insert_snapshot_stmt:exec(), "UndoDeleteSequence: snapshots INSERT failed")
        insert_snapshot_stmt:finalize()
    end

    print(string.format("✅ Undo DeleteSequence: Restored sequence %s", tostring(sequence_row.id)))
    return true
end

return M