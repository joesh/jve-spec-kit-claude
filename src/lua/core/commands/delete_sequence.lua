local log = require("core.logger").for_area("commands")

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
    mutates_clips = false,  -- mutates sequences table, not clips
    args = {
        delete_sequence_snapshot = {},
        project_id = { required = true },
        sequence_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    assert(command_executors, "DeleteSequence.register: missing command_executors")
    assert(command_undoers, "DeleteSequence.register: missing command_undoers")

    -- Validate the target sequence is a deletable nested edit timeline.
    -- Returns the sequence row on success; false on refusal (with
    -- set_last_error already invoked).
    local function validate_target(sequence_id)
        local row = fetch_sequence_record(db, sequence_id)
        if not row then
            set_error(set_last_error, "DeleteSequence: Sequence not found")
            return false
        end
        if row.kind ~= "sequence" then
            set_error(set_last_error,
                "DeleteSequence: Only nested (edit timeline) sequences can be deleted")
            return false
        end
        if count_sequence_references(db, sequence_id) > 0 then
            set_error(set_last_error,
                "DeleteSequence: Sequence is referenced by other clips")
            return false
        end
        return row
    end

    -- Run a parameterized DELETE for each clip id, asserting on failure.
    local function delete_per_clip(sql, label, clip_ids, sequence_id)
        local stmt = db:prepare(sql)
        if not stmt then return end
        for _, clip_id in ipairs(clip_ids) do
            stmt:bind_value(1, clip_id)
            assert(stmt:exec(), string.format(
                "DeleteSequence: %s DELETE failed for clip %s in sequence %s",
                label, tostring(clip_id), tostring(sequence_id)))
            stmt:reset()
        end
        stmt:finalize()
    end

    -- Bulk-delete every clip on this sequence + its links + properties.
    local function delete_clips_in_sequence(clips, sequence_id)
        if #clips == 0 then return end
        local clip_ids = {}
        for _, clip in ipairs(clips) do clip_ids[#clip_ids + 1] = clip.id end
        delete_per_clip("DELETE FROM clip_links WHERE clip_id = ?",
            "clip_links", clip_ids, sequence_id)
        delete_per_clip("DELETE FROM properties WHERE clip_id = ?",
            "properties", clip_ids, sequence_id)
        local delete_clips = assert(db:prepare(
            "DELETE FROM clips WHERE owner_sequence_id = ?"),
            "DeleteSequence: failed to prepare clips DELETE for sequence "
                .. tostring(sequence_id))
        delete_clips:bind_value(1, sequence_id)
        assert(delete_clips:exec(),
            "DeleteSequence: clips DELETE failed for sequence "
                .. tostring(sequence_id))
        delete_clips:finalize()
    end

    -- Tear down the sequence's tracks, snapshots, then the sequence row.
    local function delete_sequence_rows(sequence_id)
        local delete_tracks = assert(db:prepare(
            "DELETE FROM tracks WHERE sequence_id = ?"),
            "DeleteSequence: failed to prepare tracks DELETE for sequence "
                .. tostring(sequence_id))
        delete_tracks:bind_value(1, sequence_id)
        assert(delete_tracks:exec(),
            "DeleteSequence: tracks DELETE failed for sequence "
                .. tostring(sequence_id))
        delete_tracks:finalize()

        local delete_snapshots = db:prepare(
            "DELETE FROM snapshots WHERE sequence_id = ?")
        if delete_snapshots then
            delete_snapshots:bind_value(1, sequence_id)
            assert(delete_snapshots:exec(),
                "DeleteSequence: snapshots DELETE failed for sequence "
                    .. tostring(sequence_id))
            delete_snapshots:finalize()
        end

        local delete_seq = db:prepare("DELETE FROM sequences WHERE id = ?")
        if not delete_seq then
            return false
        end
        delete_seq:bind_value(1, sequence_id)
        local ok = delete_seq:exec()
        delete_seq:finalize()
        return ok
    end

    -- Build the undo payload + record the metadata mutation entry.
    local function record_undo_state(command, sequence_id, sequence_row,
                                     tracks, clips, clip_properties, clip_links,
                                     snapshot)
        command:set_parameter("delete_sequence_snapshot", {
            sequence    = sequence_row,
            tracks      = tracks,
            clips       = clips,
            properties  = clip_properties,
            clip_links  = clip_links,
            snapshot    = snapshot,
        })
        command:set_parameters({
            __skip_timeline_reload = true,
            __allow_empty_mutations = true,
        })
        local bucket = ensure_mutation_bucket(command, sequence_id)
        if bucket then
            bucket.sequence_meta = bucket.sequence_meta or {}
            table.insert(bucket.sequence_meta, {
                action = "deleted",
                sequence_id = sequence_id,
                project_id = sequence_row.project_id,
                name = sequence_row.name,
            })
        end
    end

    command_executors["DeleteSequence"] = function(command)
        local args = command:get_all_parameters()
        local sequence_id = args.sequence_id

        local sequence_row = validate_target(sequence_id)
        if not sequence_row then return false end

        local tracks = fetch_sequence_tracks(db, sequence_id)
        local clips, clip_properties, clip_links =
            fetch_sequence_clips(db, sequence_id)
        local snapshot = fetch_sequence_snapshot(db, sequence_id)

        record_undo_state(command, sequence_id, sequence_row, tracks, clips,
            clip_properties, clip_links, snapshot)

        delete_clips_in_sequence(clips, sequence_id)
        if not delete_sequence_rows(sequence_id) then
            set_error(set_last_error,
                "DeleteSequence: Failed to delete sequence")
            return false
        end

        log.event("Deleted sequence %s (%d track(s), %d clip(s))",
            sequence_row.name or sequence_id, #tracks, #clips)
        require("core.command_manager").queue_post_commit_emit(
            "sequence_list_changed", sequence_row.project_id)
        return true
    end

    command_undoers["DeleteSequence"] = function(command)
        local args = command:get_all_parameters()

        local snapshot = args.delete_sequence_snapshot
        assert(type(snapshot) == "table" and type(snapshot.sequence) == "table"
            and type(snapshot.sequence.project_id) == "string"
            and snapshot.sequence.project_id ~= "",
            "UndoDeleteSequence: delete_sequence_snapshot.sequence.project_id missing — "
            .. "execute path must have captured it; sequence_list_changed needs the project id")
        local ok = restore_sequence_from_payload(db, set_last_error, snapshot)
        if ok then
            require("core.command_manager").queue_post_commit_emit(
                "sequence_list_changed", snapshot.sequence.project_id)
        end
        return ok
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

--- Build a snapshot payload for a sequence (before deleting it).
-- Returns the same format that restore_from_payload expects.
function M.snapshot_for_delete(db_conn, sequence_id)
    local sequence_row = fetch_sequence_record(db_conn, sequence_id)
    assert(sequence_row, "snapshot_for_delete: sequence not found: " .. tostring(sequence_id))
    local tracks = fetch_sequence_tracks(db_conn, sequence_id)
    local clips, clip_properties, clip_links = fetch_sequence_clips(db_conn, sequence_id)
    local snapshot = fetch_sequence_snapshot(db_conn, sequence_id)
    return {
        sequence = sequence_row,
        tracks = tracks,
        clips = clips,
        properties = clip_properties,
        clip_links = clip_links,
        snapshot = snapshot,
    }
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
               fps_numerator, fps_denominator, audio_sample_rate, width, height,
               view_start_frame, view_duration_frames, playhead_frame,
               mark_in_frame, mark_out_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
               current_sequence_number, created_at, modified_at,
               start_timecode_frame, video_scroll_offset, audio_scroll_offset, video_audio_split_ratio
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
            -- audio_sample_rate is NULL on video-only masters (schema permits it
            -- there); preserve nil so undo restores the row faithfully.
            audio_sample_rate = stmt:value(6) and tonumber(stmt:value(6)) or nil,
            -- width/height are NULL on audio-only masters (schema permits it
            -- there); preserve nil so undo restores the row faithfully.
            width = stmt:value(7) and tonumber(stmt:value(7)) or nil,
            height = stmt:value(8) and tonumber(stmt:value(8)) or nil,
            view_start_frame = assert(tonumber(stmt:value(9)), "DeleteSequence.fetch_sequence_record: NULL view_start_frame for sequence " .. tostring(sequence_id)),
            view_duration_frames = assert(tonumber(stmt:value(10)), "DeleteSequence.fetch_sequence_record: NULL view_duration_frames for sequence " .. tostring(sequence_id)),
            playhead_value = assert(tonumber(stmt:value(11)), "DeleteSequence.fetch_sequence_record: NULL playhead_frame for sequence " .. tostring(sequence_id)),
            mark_in_value = stmt:value(12) and tonumber(stmt:value(12)) or nil,
            mark_out_value = stmt:value(13) and tonumber(stmt:value(13)) or nil,
            selected_clip_ids = stmt:value(14),
            selected_edge_infos = stmt:value(15),
            selected_gap_infos = stmt:value(16),
            -- current_sequence_number permits NULL (DEFAULT 0) per schema.
            current_sequence_number = stmt:value(17) and tonumber(stmt:value(17)) or nil,
            -- created_at / modified_at and the view-state columns below are
            -- all schema NOT NULL — assert presence rather than fabricate.
            created_at = assert(tonumber(stmt:value(18)),
                "fetch_sequence_record: NULL created_at for sequence " .. tostring(sequence_id)),
            modified_at = assert(tonumber(stmt:value(19)),
                "fetch_sequence_record: NULL modified_at for sequence " .. tostring(sequence_id)),
            start_timecode_frame = assert(tonumber(stmt:value(20)),
                "fetch_sequence_record: NULL start_timecode_frame for sequence " .. tostring(sequence_id)),
            video_scroll_offset = assert(tonumber(stmt:value(21)),
                "fetch_sequence_record: NULL video_scroll_offset for sequence " .. tostring(sequence_id)),
            audio_scroll_offset = assert(tonumber(stmt:value(22)),
                "fetch_sequence_record: NULL audio_scroll_offset for sequence " .. tostring(sequence_id)),
            video_audio_split_ratio = assert(tonumber(stmt:value(23)),
                "fetch_sequence_record: NULL video_audio_split_ratio for sequence " .. tostring(sequence_id)),
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
                -- tracks.track_index/volume/pan are all NOT NULL per schema;
                -- a missing value is a corruption bug, not a default to invent.
                track_index = assert(tonumber(stmt:value(4)),
                    "fetch_sequence_tracks: NULL track_index in sequence " .. tostring(sequence_id)),
                enabled = stmt:value(5) == 1 or stmt:value(5) == true,
                locked = stmt:value(6) == 1 or stmt:value(6) == true,
                muted = stmt:value(7) == 1 or stmt:value(7) == true,
                soloed = stmt:value(8) == 1 or stmt:value(8) == true,
                volume = assert(tonumber(stmt:value(9)),
                    "fetch_sequence_tracks: NULL volume in sequence " .. tostring(sequence_id)),
                pan = assert(tonumber(stmt:value(10)),
                    "fetch_sequence_tracks: NULL pan in sequence " .. tostring(sequence_id)),
            })
        end
    end
    stmt:finalize()
    return tracks
end

-- Used by fetch_sequence_clips to snapshot per-clip property rows for undo.
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

    -- V13 columns: clips no longer carry clip_kind / media_id /
    -- fps_numerator / fps_denominator / offline (those moved to the
    -- nested sequence + media_refs + media chain). master_clip_id
    -- renamed to sequence_id; new columns master_layer_track_id /
    -- master_audio_track_id / fps_mismatch_policy.
    local clip_stmt = db:prepare([[
        SELECT c.id, c.project_id, c.name, c.track_id,
               c.sequence_id, c.owner_sequence_id,
               c.sequence_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.created_at, c.modified_at,
               c.volume, c.mark_in_frame, c.mark_out_frame, c.playhead_frame,
               t.track_type
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE c.track_id IN (
            SELECT id FROM tracks WHERE sequence_id = ?
        )
        ORDER BY c.track_id, c.sequence_start_frame
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
                name = clip_stmt:value(2),
                track_id = clip_stmt:value(3),
                sequence_id = clip_stmt:value(4),
                owner_sequence_id = clip_stmt:value(5),
                start_value = assert(tonumber(clip_stmt:value(6)), "DeleteSequence.fetch_sequence_clips: missing start_value for clip " .. tostring(clip_id)),
                duration_value = assert(tonumber(clip_stmt:value(7)), "DeleteSequence.fetch_sequence_clips: missing duration_value for clip " .. tostring(clip_id)),
                source_in_value = assert(tonumber(clip_stmt:value(8)), "DeleteSequence.fetch_sequence_clips: missing source_in_value for clip " .. tostring(clip_id)),
                source_out_value = assert(tonumber(clip_stmt:value(9)), "DeleteSequence.fetch_sequence_clips: missing source_out_value for clip " .. tostring(clip_id)),
                master_layer_track_id = clip_stmt:value(10),
                master_audio_track_id = clip_stmt:value(11),
                fps_mismatch_policy = clip_stmt:value(12),
                enabled = clip_stmt:value(13) == 1 or clip_stmt:value(13) == true,
                -- clips.created_at/modified_at/volume/playhead_frame are all
                -- NOT NULL per schema; mark_in/mark_out are NULL-allowed.
                created_at = assert(tonumber(clip_stmt:value(14)),
                    "fetch_sequence_clips: NULL created_at for clip " .. tostring(clip_id)),
                modified_at = assert(tonumber(clip_stmt:value(15)),
                    "fetch_sequence_clips: NULL modified_at for clip " .. tostring(clip_id)),
                volume = assert(tonumber(clip_stmt:value(16)),
                    "fetch_sequence_clips: NULL volume for clip " .. tostring(clip_id)),
                mark_in_value = clip_stmt:value(17) and tonumber(clip_stmt:value(17)) or nil,
                mark_out_value = clip_stmt:value(18) and tonumber(clip_stmt:value(18)) or nil,
                playhead_value = assert(tonumber(clip_stmt:value(19)),
                    "fetch_sequence_clips: NULL playhead_frame for clip " .. tostring(clip_id)),
                track_type = clip_stmt:value(20),
            }

            -- Fetch properties for this clip
            local clip_props = fetch_clip_properties(db, clip_id)
            if clip_props and #clip_props > 0 then
                properties[clip_id] = clip_props
            end

            table.insert(clips, clip_entry)
        end
    end

    clip_stmt:finalize()

    -- Fetch clip links for all clips in this sequence
    local links_stmt = db:prepare([[
        SELECT cl.link_group_id, cl.clip_id, cl.role, cl.time_offset, cl.enabled
        FROM clip_links cl
        WHERE cl.clip_id IN (
            SELECT c.id FROM clips c
            JOIN tracks t ON c.track_id = t.id
            WHERE t.sequence_id = ?
        )
    ]])
    if links_stmt then
        links_stmt:bind_value(1, sequence_id)
        if links_stmt:exec() then
            while links_stmt:next() do
                table.insert(clip_links, {
                    link_group_id = links_stmt:value(0),
                    clip_id = links_stmt:value(1),
                    role = links_stmt:value(2),
                    -- clip_links.time_offset is NOT NULL DEFAULT 0; presence is required.
                    time_offset = assert(tonumber(links_stmt:value(3)),
                        "fetch_sequence_clips/links: NULL time_offset"),
                    enabled = links_stmt:value(4) == 1 or links_stmt:value(4) == true
                })
            end
        end
        links_stmt:finalize()
    end

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
            -- snapshots.sequence_number / created_at are both schema NOT NULL.
            sequence_number = assert(tonumber(stmt:value(2)),
                "fetch_sequence_snapshot: NULL sequence_number"),
            clips_state = stmt:value(3),
            created_at = assert(tonumber(stmt:value(4)),
                "fetch_sequence_snapshot: NULL created_at"),
        }
    end
    stmt:finalize()
    return snapshot
end

count_sequence_references = function(db, sequence_id)
    -- V13: clips reference other sequences via sequence_id.
    local stmt = db:prepare([[
        SELECT COUNT(*) FROM clips
        WHERE sequence_id = ?
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

-- ============================================================================
-- restore_sequence_from_payload — phase helpers
-- ============================================================================

-- Bind one column that may be NULL on the row.
local function bind_nullable(stmt, idx, val)
    if val ~= nil then
        stmt:bind_value(idx, val)
    elseif stmt.bind_null then
        stmt:bind_null(idx)
    else
        stmt:bind_value(idx, nil)
    end
end

-- Re-INSERT the sequence row. audio_sample_rate / width / height are
-- NULLABLE only on masters; non-master sequences must carry positive
-- values per schema. Returns (true, nil) | (false, reason).
local function restore_sequence_row(db, sequence_row)
    local stmt = db:prepare([[
        INSERT INTO sequences (
            id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
            view_start_frame, view_duration_frames, playhead_frame,
            mark_in_frame, mark_out_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at,
            start_timecode_frame, video_scroll_offset, audio_scroll_offset, video_audio_split_ratio
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then
        return false, "UndoDeleteSequence: Failed to prepare sequence insert"
    end
    if not sequence_row.fps_numerator then
        stmt:finalize(); return false, "UndoDeleteSequence: Missing sequence fps_numerator"
    end
    if not sequence_row.fps_denominator then
        stmt:finalize(); return false, "UndoDeleteSequence: Missing sequence fps_denominator"
    end
    if sequence_row.kind ~= "master" then
        assert(sequence_row.audio_sample_rate, string.format(
            "UndoDeleteSequence: missing audio_sample_rate for non-master sequence %s",
            tostring(sequence_row.id)))
        assert(sequence_row.width, string.format(
            "UndoDeleteSequence: missing width for non-master sequence %s",
            tostring(sequence_row.id)))
        assert(sequence_row.height, string.format(
            "UndoDeleteSequence: missing height for non-master sequence %s",
            tostring(sequence_row.id)))
    end

    stmt:bind_value(1, sequence_row.id)
    stmt:bind_value(2, sequence_row.project_id)
    stmt:bind_value(3, sequence_row.name)
    assert(sequence_row.kind == "master" or sequence_row.kind == "sequence",
        string.format(
            "UndoDeleteSequence: snapshot kind must be 'master' or 'sequence' "
            .. "(schema CHECK); got %q for sequence %s",
            tostring(sequence_row.kind), tostring(sequence_row.id)))
    stmt:bind_value(4, sequence_row.kind)
    stmt:bind_value(5, sequence_row.fps_numerator)
    stmt:bind_value(6, sequence_row.fps_denominator)
    bind_nullable(stmt, 7, sequence_row.audio_sample_rate)
    bind_nullable(stmt, 8, sequence_row.width)
    bind_nullable(stmt, 9, sequence_row.height)
    stmt:bind_value(10, sequence_row.view_start_frame)
    stmt:bind_value(11, sequence_row.view_duration_frames)
    stmt:bind_value(12, sequence_row.playhead_value)
    stmt:bind_value(13, sequence_row.mark_in_value)
    stmt:bind_value(14, sequence_row.mark_out_value)
    -- selected_*_infos are TEXT NOT NULL with no schema default; if the
    -- snapshot is missing them it's a corrupt capture, not a default to
    -- fabricate. Same for the timestamp + view-state columns below.
    stmt:bind_value(15, assert(sequence_row.selected_clip_ids,
        "UndoDeleteSequence: snapshot missing selected_clip_ids"))
    stmt:bind_value(16, assert(sequence_row.selected_edge_infos,
        "UndoDeleteSequence: snapshot missing selected_edge_infos"))
    stmt:bind_value(17, assert(sequence_row.selected_gap_infos,
        "UndoDeleteSequence: snapshot missing selected_gap_infos"))
    stmt:bind_value(18, sequence_row.current_sequence_number)
    stmt:bind_value(19, assert(sequence_row.created_at,
        "UndoDeleteSequence: snapshot missing created_at"))
    stmt:bind_value(20, assert(sequence_row.modified_at,
        "UndoDeleteSequence: snapshot missing modified_at"))
    stmt:bind_value(21, assert(sequence_row.start_timecode_frame,
        "UndoDeleteSequence: snapshot missing start_timecode_frame"))
    stmt:bind_value(22, assert(sequence_row.video_scroll_offset,
        "UndoDeleteSequence: snapshot missing video_scroll_offset"))
    stmt:bind_value(23, assert(sequence_row.audio_scroll_offset,
        "UndoDeleteSequence: snapshot missing audio_scroll_offset"))
    stmt:bind_value(24, assert(sequence_row.video_audio_split_ratio,
        "UndoDeleteSequence: snapshot missing video_audio_split_ratio"))

    if not stmt:exec() then
        stmt:finalize(); return false, "UndoDeleteSequence: Failed to restore sequence row"
    end
    stmt:finalize()
    return true
end

-- Re-INSERT every captured track row.
local function restore_tracks(db, tracks, fallback_sequence_id)
    if #tracks == 0 then return true end
    local stmt = db:prepare([[
        INSERT INTO tracks (
            id, sequence_id, name, track_type, track_index,
            enabled, locked, muted, soloed, volume, pan
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return false, "UndoDeleteSequence: Failed to prepare track insert" end
    for _, track in ipairs(tracks) do
        stmt:bind_value(1, track.id)
        stmt:bind_value(2, assert(track.sequence_id or fallback_sequence_id,
            "UndoDeleteSequence: track missing sequence_id"))
        stmt:bind_value(3, assert(track.name, "UndoDeleteSequence: track missing name"))
        stmt:bind_value(4, assert(track.track_type, "UndoDeleteSequence: track missing track_type"))
        stmt:bind_value(5, assert(track.track_index, "UndoDeleteSequence: track missing track_index"))
        stmt:bind_value(6, track.enabled and 1 or 0)
        stmt:bind_value(7, track.locked and 1 or 0)
        stmt:bind_value(8, track.muted and 1 or 0)
        stmt:bind_value(9, track.soloed and 1 or 0)
        stmt:bind_value(10, assert(track.volume,
            "UndoDeleteSequence: track snapshot missing volume"))
        stmt:bind_value(11, assert(track.pan,
            "UndoDeleteSequence: track snapshot missing pan"))
        if not stmt:exec() then
            stmt:finalize(); return false, "UndoDeleteSequence: Failed to restore track"
        end
        stmt:reset()
        stmt:clear_bindings()
    end
    stmt:finalize()
    return true
end

-- Re-INSERT every captured clip and its associated property rows. Asserts
-- the schema-required NOT NULL fields are present (fetch_sequence_clips
-- already asserted them; this is the bind-time mirror of that contract).
local function restore_clips(db, clips, owner_sequence_id, payload_properties)
    if #clips == 0 then return true end
    local stmt = db:prepare([[
        INSERT INTO clips (
            id, project_id, name, track_id,
            sequence_id, owner_sequence_id,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id,
            fps_mismatch_policy,
            enabled, created_at, modified_at,
            volume, mark_in_frame, mark_out_frame, playhead_frame
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return false, "UndoDeleteSequence: Failed to prepare clip insert" end

    for _, clip in ipairs(clips) do
        if not clip.sequence_id or clip.sequence_id == "" then
            stmt:finalize()
            return false, "UndoDeleteSequence: clip " .. tostring(clip.id) .. " missing sequence_id"
        end
        assert(clip.name and clip.fps_mismatch_policy
            and clip.created_at and clip.modified_at
            and type(clip.volume) == "number"
            and type(clip.playhead_value) == "number"
            and clip.owner_sequence_id == owner_sequence_id, string.format(
            "UndoDeleteSequence: snapshot for clip %s missing required fields",
            tostring(clip.id)))
        stmt:bind_value(1, clip.id)
        stmt:bind_value(2, clip.project_id)
        stmt:bind_value(3, clip.name)
        stmt:bind_value(4, clip.track_id)
        stmt:bind_value(5, clip.sequence_id)
        stmt:bind_value(6, clip.owner_sequence_id)
        stmt:bind_value(7, clip.start_value)
        stmt:bind_value(8, clip.duration_value)
        stmt:bind_value(9, clip.source_in_value)
        stmt:bind_value(10, clip.source_out_value)
        stmt:bind_value(11, clip.master_layer_track_id)
        stmt:bind_value(12, clip.master_audio_track_id)
        stmt:bind_value(13, clip.fps_mismatch_policy)
        stmt:bind_value(14, clip.enabled and 1 or 0)
        stmt:bind_value(15, clip.created_at)
        stmt:bind_value(16, clip.modified_at)
        stmt:bind_value(17, clip.volume)
        if clip.mark_in_value  then stmt:bind_value(18, clip.mark_in_value)  end
        if clip.mark_out_value then stmt:bind_value(19, clip.mark_out_value) end
        stmt:bind_value(20, clip.playhead_value)
        if not stmt:exec() then
            stmt:finalize(); return false, "UndoDeleteSequence: Failed to restore clip"
        end
        stmt:reset()
        stmt:clear_bindings()

        local props = payload_properties and payload_properties[clip.id]
        if props and not insert_properties_for_clip(db, clip.id, props) then
            stmt:finalize(); return false, "UndoDeleteSequence: Failed to restore clip properties"
        end
    end
    stmt:finalize()
    return true
end

-- Re-INSERT every captured clip_links row.
local function restore_clip_links(db, clip_links)
    if #clip_links == 0 then return end
    local stmt = assert(db:prepare([[
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES (?, ?, ?, ?, ?)
    ]]), "UndoDeleteSequence: failed to prepare clip_links INSERT")
    for _, link in ipairs(clip_links) do
        stmt:bind_value(1, link.link_group_id)
        stmt:bind_value(2, link.clip_id)
        stmt:bind_value(3, link.role)
        stmt:bind_value(4, assert(link.time_offset,
            "UndoDeleteSequence: clip_links snapshot missing time_offset"))
        stmt:bind_value(5, link.enabled and 1 or 0)
        assert(stmt:exec(),
            "UndoDeleteSequence: clip_links INSERT failed for clip " .. tostring(link.clip_id))
        stmt:reset()
        stmt:clear_bindings()
    end
    stmt:finalize()
end

-- Re-INSERT the captured undo snapshot row, if any.
local function restore_snapshot(db, snapshot, fallback_sequence_id)
    if not snapshot then return end
    local stmt = assert(db:prepare([[
        INSERT OR REPLACE INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at)
        VALUES (?, ?, ?, ?, ?)
    ]]), "UndoDeleteSequence: failed to prepare snapshots INSERT")
    stmt:bind_value(1, snapshot.id)
    stmt:bind_value(2, assert(snapshot.sequence_id or fallback_sequence_id,
        "UndoDeleteSequence: snapshot missing sequence_id and no fallback"))
    stmt:bind_value(3, assert(snapshot.sequence_number,
        "UndoDeleteSequence: snapshot missing sequence_number"))
    stmt:bind_value(4, snapshot.clips_state)
    stmt:bind_value(5, assert(snapshot.created_at,
        "UndoDeleteSequence: snapshot missing created_at"))
    assert(stmt:exec(), "UndoDeleteSequence: snapshots INSERT failed")
    stmt:finalize()
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

    local ok, err = restore_sequence_row(db, sequence_row)
    if not ok then set_error(set_last_error, err); return false end

    -- snapshot_for_delete always populates tracks/clips/clip_links arrays;
    -- a payload without them is a corrupt capture, not "nothing to do".
    assert(type(payload.tracks)     == "table",
        "UndoDeleteSequence: payload.tracks missing (corrupt snapshot)")
    assert(type(payload.clips)      == "table",
        "UndoDeleteSequence: payload.clips missing (corrupt snapshot)")
    assert(type(payload.clip_links) == "table",
        "UndoDeleteSequence: payload.clip_links missing (corrupt snapshot)")

    ok, err = restore_tracks(db, payload.tracks, sequence_row.id)
    if not ok then set_error(set_last_error, err); return false end

    ok, err = restore_clips(db, payload.clips, sequence_row.id, payload.properties)
    if not ok then set_error(set_last_error, err); return false end

    restore_clip_links(db, payload.clip_links)
    restore_snapshot(db, payload.snapshot, sequence_row.id)

    log.event("Undo DeleteSequence: restored sequence %s", tostring(sequence_row.id))
    return true
end

return M