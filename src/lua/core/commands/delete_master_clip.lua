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
-- Size: ~213 LOC
-- Volatility: unknown
--
-- @file delete_master_clip.lua
local M = {}
local set_error


local SPEC = {
    args = {
        master_clip_id = { required = true },
        project_id = { required = true },
        force = { kind = "boolean" },  -- If true, also delete timeline clips that reference this master
    },
    persisted = {
        -- Computed during execution for undo
        master_clip_snapshot = {},
        master_clip_properties = {},
        deleted_timeline_clips = {},  -- Snapshots of timeline clips deleted when force=true
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    assert(command_executors, "DeleteMasterClip.register: missing command_executors")
    assert(command_undoers, "DeleteMasterClip.register: missing command_undoers")
    assert(db, "DeleteMasterClip.register: missing db")

    local Clip = require("models.clip")
    local delete_sequence_mod = require("core.commands.delete_sequence")

    local function delete_clip_with_metadata(clip_id)
        local prop_stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
        if prop_stmt then
            prop_stmt:bind_value(1, clip_id)
            assert(prop_stmt:exec(), "DeleteMasterClip: properties DELETE failed for clip " .. tostring(clip_id))
            prop_stmt:finalize()
        end

        local link_stmt = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
        if link_stmt then
            link_stmt:bind_value(1, clip_id)
            assert(link_stmt:exec(), "DeleteMasterClip: clip_links DELETE failed for clip " .. tostring(clip_id))
            link_stmt:finalize()
        end

        local clip_obj = Clip.load_optional(clip_id)
        if clip_obj then
            return clip_obj:delete()
        else
            local delete_stmt = assert(db:prepare("DELETE FROM clips WHERE id = ?"),
                "DeleteMasterClip: failed to prepare clips DELETE for clip " .. tostring(clip_id))
            delete_stmt:bind_value(1, clip_id)
            assert(delete_stmt:exec(), "DeleteMasterClip: clips DELETE failed for clip " .. tostring(clip_id))
            delete_stmt:finalize()
        end
        return true
    end

    command_executors["DeleteMasterClip"] = function(command)
        local args = command:get_all_parameters()


        local clip = Clip.load_optional(args.master_clip_id)
        if not clip then
            set_error(set_last_error, "DeleteMasterClip: Master clip not found")
            return false
        end

        if clip.clip_kind ~= "master" then
            set_error(set_last_error, "DeleteMasterClip: Clip is not a master clip")
            return false
        end

        -- Check for timeline clips referencing this master
        local timeline_clip_snapshots = {}
        if clip.master_clip_id and clip.master_clip_id ~= "" then
            local ref_query = db:prepare([[
                SELECT c.id, c.track_id, c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
                       c.enabled, c.offline, c.fps_numerator, c.fps_denominator, c.name, c.owner_sequence_id, t.sequence_id,
                       c.volume, c.created_at, c.modified_at
                FROM clips c
                JOIN tracks t ON c.track_id = t.id
                WHERE c.master_clip_id = ?
                  AND c.clip_kind = 'timeline'
                  AND (c.owner_sequence_id IS NULL OR c.owner_sequence_id <> ?)
            ]])
            if not ref_query then
                set_error(set_last_error, "DeleteMasterClip: Failed to prepare reference check")
                return false
            end
            ref_query:bind_value(1, clip.master_clip_id)
            ref_query:bind_value(2, clip.master_clip_id)
            if ref_query:exec() then
                while ref_query:next() do
                    table.insert(timeline_clip_snapshots, {
                        id = ref_query:value(0),
                        track_id = ref_query:value(1),
                        timeline_start = ref_query:value(2),
                        duration = ref_query:value(3),
                        source_in = ref_query:value(4),
                        source_out = ref_query:value(5),
                        enabled = ref_query:value(6) == 1,
                        offline = ref_query:value(7) == 1,
                        fps_numerator = ref_query:value(8),
                        fps_denominator = ref_query:value(9),
                        name = ref_query:value(10),
                        owner_sequence_id = ref_query:value(11),
                        sequence_id = ref_query:value(12),  -- For cache invalidation
                        volume = ref_query:value(13),
                        created_at = ref_query:value(14),
                        modified_at = ref_query:value(15),
                        master_clip_id = clip.master_clip_id,
                        project_id = clip.project_id,
                        media_id = clip.media_id,
                        clip_kind = "timeline",
                    })
                end
            end
            ref_query:finalize()

            if #timeline_clip_snapshots > 0 then
                if not args.force then
                    -- Return special error that UI can detect
                    set_error(set_last_error, string.format(
                        "DeleteMasterClip: Clip referenced by %d timeline clip(s). Use force=true to delete anyway.",
                        #timeline_clip_snapshots))
                    return { success = false, in_use_count = #timeline_clip_snapshots }
                end

                -- force=true: Delete timeline clips first
                local command_helper = require("core.command_helper")
                local clips_by_sequence = {}
                for _, snap in ipairs(timeline_clip_snapshots) do
                    if not delete_clip_with_metadata(snap.id) then
                        set_error(set_last_error, "DeleteMasterClip: Failed to delete timeline clip " .. snap.id)
                        return false
                    end
                    if snap.sequence_id then
                        if not clips_by_sequence[snap.sequence_id] then
                            clips_by_sequence[snap.sequence_id] = {}
                        end
                        table.insert(clips_by_sequence[snap.sequence_id], snap.id)
                    end
                end
                command:set_parameter("deleted_timeline_clips", timeline_clip_snapshots)

                -- Produce delete mutations for affected sequences
                for seq_id, clip_ids in pairs(clips_by_sequence) do
                    command_helper.add_delete_mutation(command, seq_id, clip_ids)
                end
            end
        end

        -- Snapshot the full masterclip sequence BEFORE deleting anything.
        -- This captures the sequence record, tracks, clips, properties, and links
        -- so undo can restore everything.
        local seq_id = clip.master_clip_id or args.master_clip_id
        local seq_snapshot = delete_sequence_mod.snapshot_for_delete(db, seq_id)
        command:set_parameter("master_clip_snapshot", seq_snapshot)

        -- Remove stream clips that belong to the master clip's source sequence
        local child_stmt = db:prepare("SELECT id FROM clips WHERE owner_sequence_id = ?")
        local child_clip_ids = {}
        if child_stmt then
            child_stmt:bind_value(1, clip.master_clip_id or args.master_clip_id)
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
        local master_clip_id = clip.master_clip_id
        if master_clip_id and master_clip_id ~= "" then
            local delete_tracks = db:prepare("DELETE FROM tracks WHERE sequence_id = ?")
            if delete_tracks then
                delete_tracks:bind_value(1, master_clip_id)
                assert(delete_tracks:exec(), "DeleteMasterClip: tracks DELETE failed for sequence " .. tostring(master_clip_id))
                delete_tracks:finalize()
            end

            local delete_snapshots = db:prepare("DELETE FROM snapshots WHERE sequence_id = ?")
            if delete_snapshots then
                delete_snapshots:bind_value(1, master_clip_id)
                assert(delete_snapshots:exec(), "DeleteMasterClip: snapshots DELETE failed for sequence " .. tostring(master_clip_id))
                delete_snapshots:finalize()
            end

            local delete_sequence_stmt = assert(db:prepare("DELETE FROM sequences WHERE id = ?"),
                "DeleteMasterClip: failed to prepare sequences DELETE for sequence " .. tostring(master_clip_id))
            delete_sequence_stmt:bind_value(1, master_clip_id)
            assert(delete_sequence_stmt:exec(), "DeleteMasterClip: sequences DELETE failed for sequence " .. tostring(master_clip_id))
            delete_sequence_stmt:finalize()
        end

        print(string.format("✅ Deleted master clip %s", clip.name or args.master_clip_id))
        return true
    end

    command_undoers["DeleteMasterClip"] = function(command)
        local args = command:get_all_parameters()

        assert(args.master_clip_snapshot,
            "UndoDeleteMasterClip: missing master_clip_snapshot")

        -- Restore the full masterclip sequence (sequence + tracks + clips + properties)
        local ok = delete_sequence_mod.restore_from_payload(db, args.master_clip_snapshot, set_last_error)
        assert(ok, "UndoDeleteMasterClip: restore_from_payload failed")

        -- Restore timeline clips that were deleted with force=true
        local deleted_timeline_clips = args.deleted_timeline_clips or {}
        local command_helper = require("core.command_helper")
        for _, snap in ipairs(deleted_timeline_clips) do
            local timeline_clip = Clip.create(snap.name or "Timeline Clip", snap.media_id, {
                id = snap.id,
                project_id = snap.project_id,
                clip_kind = snap.clip_kind,
                track_id = snap.track_id,
                master_clip_id = snap.master_clip_id,
                owner_sequence_id = snap.owner_sequence_id,
                timeline_start = snap.timeline_start,
                duration = snap.duration,
                source_in = snap.source_in,
                source_out = snap.source_out,
                enabled = snap.enabled ~= false,
                offline = snap.offline,
                fps_numerator = snap.fps_numerator,
                fps_denominator = snap.fps_denominator,
                volume = snap.volume,
            })
            assert(timeline_clip:save(),
                "UndoDeleteMasterClip: Failed to restore timeline clip " .. snap.id)

            local mut_seq = snap.sequence_id or snap.owner_sequence_id
            if mut_seq then
                command_helper.add_insert_mutation(command, mut_seq, {
                    id = snap.id,
                    track_id = snap.track_id,
                    start_value = snap.timeline_start,
                    duration_value = snap.duration,
                    source_in_value = snap.source_in,
                    source_out_value = snap.source_out,
                    enabled = snap.enabled ~= false,
                    name = snap.name,
                    media_id = snap.media_id,
                    volume = snap.volume,
                })
            end
        end

        local seq_name = args.master_clip_snapshot.sequence and args.master_clip_snapshot.sequence.name or "unknown"
        local timeline_msg = #deleted_timeline_clips > 0
            and string.format(" and %d timeline clip(s)", #deleted_timeline_clips)
            or ""
        print(string.format("UNDO: Restored master clip %s%s", seq_name, timeline_msg))
        return true
    end

    return {
        executor = command_executors["DeleteMasterClip"],
        undoer = command_undoers["DeleteMasterClip"],
        spec = SPEC,
    }
end


set_error = function(set_last_error, message)
    if set_last_error then
        set_last_error(message)
    end
end

return M
