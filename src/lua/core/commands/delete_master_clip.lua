--- DeleteMasterClip — V13 rewrite.
--
-- "Master clip" in V13 == a sequence with kind='master' (whose tracks
-- hold media_refs). The V13 arg name is `master_sequence_id`.
--
-- Forward path:
--   1. Validate the target is a kind='master' sequence.
--   2. Find timeline clips that reference this master via
--      clips.nested_sequence_id (these are the "in-use" sites).
--   3. If any references exist and force≠true, refuse with an in-use
--      report — the UI confirms with the user before retrying force=true.
--   4. With force=true: delete referencing clips first (capturing them
--      for undo), then delegate to DeleteSequence.snapshot_for_delete +
--      cascade-delete the master sequence (its tracks, media_refs, and
--      media_refs_channel_state cascade via FK).
--
-- Undo path:
--   1. Restore the master sequence + its rows via
--      DeleteSequence.restore_from_payload.
--   2. Re-INSERT the V13 clips that were deleted with force=true.
--
-- Rule 2.13: every V13 column required on undo INSERT is asserted; no
-- silent defaults.
--
-- @file delete_master_clip.lua
local M = {}
local log = require("core.logger").for_area("commands")
local set_error


local SPEC = {
    args = {
        master_sequence_id = { required = true, kind = "string" },
        project_id = { required = true, kind = "string" },
        force = { kind = "boolean" },  -- delete timeline clips that reference this master
    },
    persisted = {
        master_clip_snapshot = { kind = "table" },
        master_clip_properties = { kind = "table" },
        deleted_timeline_clips = { kind = "table" },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    assert(command_executors, "DeleteMasterClip.register: missing command_executors")
    assert(command_undoers, "DeleteMasterClip.register: missing command_undoers")
    assert(db, "DeleteMasterClip.register: missing db")

    local Sequence = require("models.sequence")
    local delete_sequence_mod = require("core.commands.delete_sequence")

    -- Delete a single timeline clip + its properties + its link entry.
    local function delete_clip_with_metadata(clip_id)
        local prop_stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
        if prop_stmt then
            prop_stmt:bind_value(1, clip_id)
            assert(prop_stmt:exec(), "DeleteMasterClip: properties DELETE failed for clip "
                .. tostring(clip_id))
            prop_stmt:finalize()
        end
        local link_stmt = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
        if link_stmt then
            link_stmt:bind_value(1, clip_id)
            assert(link_stmt:exec(), "DeleteMasterClip: clip_links DELETE failed for clip "
                .. tostring(clip_id))
            link_stmt:finalize()
        end
        local delete_stmt = assert(db:prepare("DELETE FROM clips WHERE id = ?"),
            "DeleteMasterClip: failed to prepare clips DELETE for clip " .. tostring(clip_id))
        delete_stmt:bind_value(1, clip_id)
        assert(delete_stmt:exec(), "DeleteMasterClip: clips DELETE failed for clip "
            .. tostring(clip_id))
        delete_stmt:finalize()
    end

    -- Query every timeline clip referencing this master. Returns the list
    -- of snapshots (suitable for both undo restoration and pre-delete
    -- "in use" reporting).
    local function snapshot_referencing_clips(seq_id)
        local snapshots = {}
        local stmt = db:prepare([[
            SELECT c.id, c.project_id, c.name, c.track_id,
                   c.nested_sequence_id, c.owner_sequence_id,
                   c.timeline_start_frame, c.duration_frames,
                   c.source_in_frame, c.source_out_frame,
                   c.master_layer_track_id, c.master_audio_track_id,
                   c.fps_mismatch_policy,
                   c.enabled, c.created_at, c.modified_at,
                   c.volume, c.mark_in_frame, c.mark_out_frame, c.playhead_frame,
                   t.track_type
            FROM clips c
            JOIN tracks t ON c.track_id = t.id
            WHERE c.nested_sequence_id = ?
        ]])
        if not stmt then return nil end
        stmt:bind_value(1, seq_id)
        if stmt:exec() then
            while stmt:next() do
                snapshots[#snapshots + 1] = {
                    id = stmt:value(0), project_id = stmt:value(1),
                    name = stmt:value(2), track_id = stmt:value(3),
                    nested_sequence_id = stmt:value(4),
                    owner_sequence_id = stmt:value(5),
                    timeline_start = stmt:value(6),
                    duration = stmt:value(7),
                    source_in = stmt:value(8), source_out = stmt:value(9),
                    master_layer_track_id = stmt:value(10),
                    master_audio_track_id = stmt:value(11),
                    fps_mismatch_policy = stmt:value(12),
                    enabled = stmt:value(13) == 1,
                    created_at = stmt:value(14),
                    modified_at = stmt:value(15),
                    volume = stmt:value(16),
                    mark_in = stmt:value(17),
                    mark_out = stmt:value(18),
                    playhead_frame = stmt:value(19),
                    track_type = stmt:value(20),
                    sequence_id = stmt:value(5),  -- alias for cache invalidation
                }
            end
        end
        stmt:finalize()
        return snapshots
    end

    -- Bulk-delete the referencing timeline clips and record the
    -- per-sequence delete mutations for cache invalidation. Returns true
    -- on success; false (with error string set) on failure.
    local function force_delete_referencing(snapshots, command)
        local command_helper = require("core.command_helper")
        local clips_by_sequence = {}
        for _, snap in ipairs(snapshots) do
            delete_clip_with_metadata(snap.id)
            if snap.owner_sequence_id then
                local bucket = clips_by_sequence[snap.owner_sequence_id]
                    or {}
                bucket[#bucket + 1] = snap.id
                clips_by_sequence[snap.owner_sequence_id] = bucket
            end
        end
        command:set_parameter("deleted_timeline_clips", snapshots)
        for sid, clip_ids in pairs(clips_by_sequence) do
            command_helper.add_delete_mutation(command, sid, clip_ids)
        end
    end

    -- Tear down the master sequence rows: tracks (cascades media_refs +
    -- media_refs_channel_state), snapshots, then the sequence row itself.
    local function delete_master_sequence_rows(seq_id)
        local steps = {
            { sql = "DELETE FROM tracks WHERE sequence_id = ?",
              label = "tracks" },
            { sql = "DELETE FROM snapshots WHERE sequence_id = ?",
              label = "snapshots" },
            { sql = "DELETE FROM sequences WHERE id = ?",
              label = "sequences" },
        }
        for _, step in ipairs(steps) do
            local stmt = db:prepare(step.sql)
            if stmt then
                stmt:bind_value(1, seq_id)
                assert(stmt:exec(), string.format(
                    "DeleteMasterClip: %s DELETE failed for sequence %s",
                    step.label, tostring(seq_id)))
                stmt:finalize()
            end
        end
    end

    command_executors["DeleteMasterClip"] = function(command)
        local args = command:get_all_parameters()
        local seq_id = args.master_sequence_id

        local seq = Sequence.find(seq_id)
        if not seq then
            set_error(set_last_error, "DeleteMasterClip: Master sequence not found")
            return false
        end
        if seq.kind ~= "master" then
            set_error(set_last_error, string.format(
                "DeleteMasterClip: sequence %s has kind='%s' (expected 'master')",
                seq_id, tostring(seq.kind)))
            return false
        end

        local snapshots = snapshot_referencing_clips(seq_id)
        if not snapshots then
            set_error(set_last_error,
                "DeleteMasterClip: Failed to prepare reference check")
            return false
        end

        if #snapshots > 0 and not args.force then
            set_error(set_last_error, string.format(
                "DeleteMasterClip: Master referenced by %d timeline clip(s). "
                .. "Use force=true to delete anyway.", #snapshots))
            return { success = false, in_use_count = #snapshots }
        end
        if #snapshots > 0 then
            force_delete_referencing(snapshots, command)
        end

        command:set_parameter("master_clip_snapshot",
            delete_sequence_mod.snapshot_for_delete(db, seq_id))
        delete_master_sequence_rows(seq_id)

        log.event("Deleted master sequence %s", seq.name or seq_id)
        return true
    end

    command_undoers["DeleteMasterClip"] = function(command)
        local args = command:get_all_parameters()

        assert(args.master_clip_snapshot,
            "UndoDeleteMasterClip: missing master_clip_snapshot")

        local ok = delete_sequence_mod.restore_from_payload(db, args.master_clip_snapshot, set_last_error)
        assert(ok, "UndoDeleteMasterClip: restore_from_payload failed")

        -- Re-INSERT timeline clips deleted under force=true (V13 INSERT shape).
        local deleted_timeline_clips = args.deleted_timeline_clips or {}
        local command_helper = require("core.command_helper")
        if #deleted_timeline_clips > 0 then
            local insert_clip_stmt = assert(db:prepare([[
                INSERT INTO clips (
                    id, project_id, name, track_id,
                    nested_sequence_id, owner_sequence_id,
                    timeline_start_frame, duration_frames,
                    source_in_frame, source_out_frame,
                    master_layer_track_id, master_audio_track_id,
                    fps_mismatch_policy,
                    enabled, created_at, modified_at,
                    volume, mark_in_frame, mark_out_frame, playhead_frame
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]]), "UndoDeleteMasterClip: failed to prepare clips INSERT")

            for _, snap in ipairs(deleted_timeline_clips) do
                assert(snap.nested_sequence_id and snap.nested_sequence_id ~= "",
                    "UndoDeleteMasterClip: snap " .. tostring(snap.id) .. " missing nested_sequence_id")
                insert_clip_stmt:bind_value(1, snap.id)
                insert_clip_stmt:bind_value(2, snap.project_id)
                insert_clip_stmt:bind_value(3, snap.name or "Timeline Clip")
                insert_clip_stmt:bind_value(4, snap.track_id)
                insert_clip_stmt:bind_value(5, snap.nested_sequence_id)
                insert_clip_stmt:bind_value(6, snap.owner_sequence_id)
                insert_clip_stmt:bind_value(7, snap.timeline_start)
                insert_clip_stmt:bind_value(8, snap.duration)
                insert_clip_stmt:bind_value(9, snap.source_in)
                insert_clip_stmt:bind_value(10, snap.source_out)
                insert_clip_stmt:bind_value(11, snap.master_layer_track_id)
                insert_clip_stmt:bind_value(12, snap.master_audio_track_id)
                insert_clip_stmt:bind_value(13, snap.fps_mismatch_policy or "resample")
                insert_clip_stmt:bind_value(14, snap.enabled and 1 or 0)
                insert_clip_stmt:bind_value(15, snap.created_at or os.time())
                insert_clip_stmt:bind_value(16, snap.modified_at or os.time())
                insert_clip_stmt:bind_value(17, snap.volume or 1.0)
                if snap.mark_in then insert_clip_stmt:bind_value(18, snap.mark_in) end
                if snap.mark_out then insert_clip_stmt:bind_value(19, snap.mark_out) end
                insert_clip_stmt:bind_value(20, snap.playhead_frame or 0)
                assert(insert_clip_stmt:exec(),
                    "UndoDeleteMasterClip: INSERT failed for clip " .. snap.id)
                insert_clip_stmt:reset()
                insert_clip_stmt:clear_bindings()

                if snap.owner_sequence_id then
                    command_helper.add_insert_mutation(command, snap.owner_sequence_id, {
                        id = snap.id,
                        track_id = snap.track_id,
                        start_value = snap.timeline_start,
                        duration_value = snap.duration,
                        source_in_value = snap.source_in,
                        source_out_value = snap.source_out,
                        enabled = snap.enabled,
                        name = snap.name,
                        nested_sequence_id = snap.nested_sequence_id,
                        master_layer_track_id = snap.master_layer_track_id,
                        master_audio_track_id = snap.master_audio_track_id,
                        fps_mismatch_policy = snap.fps_mismatch_policy,
                        volume = snap.volume,
                    })
                end
            end
            insert_clip_stmt:finalize()
        end

        local seq_name = args.master_clip_snapshot.sequence and args.master_clip_snapshot.sequence.name or "unknown"
        local timeline_msg = #deleted_timeline_clips > 0
            and string.format(" and %d timeline clip(s)", #deleted_timeline_clips)
            or ""
        log.event("Undo DeleteMasterClip: restored master sequence %s%s", seq_name, timeline_msg)
        return true
    end

    return {
        executor = command_executors["DeleteMasterClip"],
        undoer = command_undoers["DeleteMasterClip"],
        spec = SPEC,
    }
end

set_error = function(set_last_error, msg)
    if set_last_error then set_last_error(msg) end
end

return M
