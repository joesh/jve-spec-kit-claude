--- Paste — creates clips from clipboard data at the playhead with overwrite behavior.
--
-- Responsibilities:
-- - Read clipboard, resolve paste positions from playhead + offset
-- - Carve space (overwrite) on target tracks
-- - Create new clips directly from clipboard snapshot
-- - Copy properties from source masterclip stream clips
-- - Own mutations for proper undo/redo
--
-- Invariants:
-- - Clipboard must contain timeline_clips kind
-- - All coordinates are integer frames (or samples for audio)
-- - Each pasted clip gets a fresh UUID (stable across redo)
--
-- @file paste.lua
local M = {}

local clipboard = require("core.clipboard")
local clip_mutator = require("core.clip_mutator")
local clip_link = require("models.clip_link")
local command_helper = require("core.command_helper")
local uuid = require("uuid")
local log = require("core.logger").for_area("commands")

local SPEC = {
    args = {
        project_id = { required = true },
        sequence_id = {},
    },
    persisted = {
        executed_mutations = {},
        created_clip_ids = {},
        created_link_group_ids = {},
    },
}

--- Populate __timeline_mutations for UI cache updates from clip_mutator mutations.
local function populate_timeline_mutations(command, sequence_id, mutations)
    for _, mut in ipairs(mutations) do
        if mut.type == "insert" then
            command_helper.add_insert_mutation(command, sequence_id, {
                id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.sequence_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
                name = mut.name,
                sequence_id = mut.sequence_id,
                master_layer_track_id = mut.master_layer_track_id,
                master_audio_track_id = mut.master_audio_track_id,
                fps_mismatch_policy = mut.fps_mismatch_policy,
                owner_sequence_id = mut.owner_sequence_id,
                enabled = mut.enabled ~= false,
                track_type = mut.track_type,
            })
        elseif mut.type == "update" then
            command_helper.add_update_mutation(command, sequence_id, {
                clip_id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.sequence_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
            })
        elseif mut.type == "delete" then
            command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
        end
    end
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Paste"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "Paste: db is nil")

        -- Read clipboard
        local payload = clipboard.get()
        if not payload or payload.kind ~= "timeline_clips" then
            set_last_error("Paste: clipboard does not contain timeline clips")
            return false
        end
        -- Producers of kind="timeline_clips" payloads always populate clips
        -- (cut.lua, clipboard_actions). The kind check above narrows here.
        local clip_entries = payload.clips
        if #clip_entries == 0 then
            set_last_error("Paste: clipboard is empty")
            return false
        end

        -- Resolve sequence and project
        local timeline_state = require("ui.timeline.timeline_state")
        local sequence_id = args.sequence_id
            or (timeline_state.get_sequence_id and timeline_state.get_sequence_id())
        assert(sequence_id and sequence_id ~= "", "Paste: missing sequence_id")
        command:set_parameter("sequence_id", sequence_id)

        local project_id = command.project_id or args.project_id
            or (timeline_state.get_project_id and timeline_state.get_project_id())
        assert(project_id and project_id ~= "", "Paste: missing project_id")
        command:set_parameter("project_id", project_id)
        command.project_id = project_id

        -- Get playhead position (integer frames)
        local playhead_frames = timeline_state.get_playhead_position()
        assert(type(playhead_frames) == "number" and playhead_frames == math.floor(playhead_frames),
            "Paste: playhead must be integer frames, got " .. tostring(playhead_frames))

        -- Validate target tracks exist
        local database = require("core.database")
        local tracks = database.load_tracks(sequence_id)
        local track_lookup = {}
        for _, track in ipairs(tracks) do
            if track and track.id then
                track_lookup[track.id] = track
            end
        end

        -- Reuse clip IDs from previous execution (for redo stability)
        local redo_clip_ids = args.created_clip_ids
        local redo_idx = 1

        -- Phase 1: Resolve paste positions and build placement list
        local placements = {}  -- {track_id, paste_start, clip_data}
        for _, clip_data in ipairs(clip_entries) do
            assert(clip_data.track_id, "Paste: clipboard clip missing track_id")
            -- V13 Paste resolves through clip_data.sequence_id; the
            -- V8 media_id direct-link is no longer required at paste time.
            assert(track_lookup[clip_data.track_id],
                "Paste: target track " .. tostring(clip_data.track_id) .. " not found in sequence")
            assert(type(clip_data.duration) == "number", "Paste: duration must be integer")
            assert(type(clip_data.source_in) == "number", "Paste: source_in must be integer")
            assert(type(clip_data.source_out) == "number", "Paste: source_out must be integer")
            assert(clip_data.offset_frames ~= nil, "Paste: clip missing offset_frames")

            local paste_start = playhead_frames + clip_data.offset_frames
            log.event("  paste placement: track=%s offset=%d start=%d dur=%d name=%s",
                tostring(clip_data.track_id), clip_data.offset_frames,
                paste_start, clip_data.duration, tostring(clip_data.name))
            placements[#placements + 1] = {
                track_id = clip_data.track_id,
                paste_start = paste_start,
                clip_data = clip_data,
            }
        end

        -- Phase 2: Carve space (overwrite) — resolve occlusions per track.
        -- Use resolve_occlusions_multi to handle individual clip spans (not a bounding box).
        -- This preserves existing clips in gaps between pasted clips on the same track.
        local all_mutations = {}
        local spans_by_track = {}
        for _, p in ipairs(placements) do
            spans_by_track[p.track_id] = spans_by_track[p.track_id] or {}
            table.insert(spans_by_track[p.track_id], {
                start = p.paste_start,
                ["end"] = p.paste_start + p.clip_data.duration,
            })
        end
        for track_id, spans in pairs(spans_by_track) do
            local ok, err, mutations = clip_mutator.resolve_occlusions_multi(db, track_id, spans)
            if not ok then
                set_last_error("Paste: occlusion failed on track " .. tostring(track_id) .. ": " .. tostring(err))
                return false
            end
            -- resolve_occlusions_multi returns (ok, err, mutations) where
            -- mutations is always an array (possibly empty).
            for _, mut in ipairs(mutations) do
                table.insert(all_mutations, mut)
            end
        end

        -- Phase 3: Create clips
        local created_clips = {}
        for _, p in ipairs(placements) do
            local cd = p.clip_data

            -- Determine clip_id: prefer redo, then generate
            local clip_id
            if redo_clip_ids and redo_idx <= #redo_clip_ids then
                clip_id = redo_clip_ids[redo_idx]
                redo_idx = redo_idx + 1
            else
                clip_id = uuid.generate()
            end

            -- V13: Clip.create takes a single fields table; sequence_id
            -- is required. cd is a clipboard payload built by
            -- clipboard_actions on the V13 shape.
            assert(cd.sequence_id and cd.sequence_id ~= "",
                "Paste: clipboard entry missing sequence_id")
            local now = os.time()
            local clip_row = {
                id = clip_id,
                project_id = project_id,
                track_id = p.track_id,
                owner_sequence_id = sequence_id,
                sequence_id = cd.sequence_id,
                master_layer_track_id = cd.master_layer_track_id,
                master_audio_track_id = cd.master_audio_track_id,
                fps_mismatch_policy = cd.fps_mismatch_policy or "resample",
                name = cd.name or "Pasted Clip",
                sequence_start = p.paste_start,
                start_value = p.paste_start,
                duration = cd.duration,
                source_in = cd.source_in,
                source_out = cd.source_out,
                enabled = true,
                volume = cd.volume or 1.0,
                frame_rate = cd.frame_rate,
                created_at = now,
                modified_at = now,
            }

            table.insert(all_mutations, clip_mutator.plan_insert(clip_row))
            -- Determine role from track type
            local track = track_lookup[p.track_id]
            local role = (track.track_type == "VIDEO") and "video" or "audio"
            table.insert(created_clips, {
                clip_id = clip_id,
                sequence_id = cd.sequence_id,
                role = role,
                copied_properties = cd.copied_properties,
            })
        end

        -- Phase 4: Apply all mutations
        local ok_apply, apply_err = command_helper.apply_mutations(db, all_mutations)
        if not ok_apply then
            set_last_error("Paste: apply_mutations failed: " .. tostring(apply_err))
            return false
        end

        -- Phase 5: Restore copied properties from the clipboard payload.
        -- (V8 had a "find_source_stream_clip" fallback that read property
        -- rows attached to the master sequence's V/A stream clips. V13
        -- masters hold media_refs, not clips, so the fallback is gone —
        -- the clipboard payload carries the snapshot.)
        for _, created in ipairs(created_clips) do
            if created.copied_properties and #created.copied_properties > 0 then
                command_helper.delete_properties_for_clip(created.clip_id)
                command_helper.insert_properties_for_clip(created.clip_id, created.copied_properties)
            end
        end

        -- Phase 6: Link clips that came from the same nested sequence
        -- (e.g. V + A pair from one master).
        local clips_by_nested = {}
        for _, created in ipairs(created_clips) do
            local ns = created.sequence_id
            if not ns then goto next_link end
            clips_by_nested[ns] = clips_by_nested[ns] or {}
            table.insert(clips_by_nested[ns], {
                clip_id = created.clip_id,
                role = created.role,
                time_offset = 0,
            })
            ::next_link::
        end
        local link_group_ids = {}
        for _, group_clips in pairs(clips_by_nested) do
            if #group_clips >= 2 then
                local link_id, link_err = clip_link.create_link_group(group_clips, db)
                assert(link_id,
                    "Paste: failed to create link group: " .. tostring(link_err))
                table.insert(link_group_ids, link_id)
            end
        end

        -- Store for undo/redo
        populate_timeline_mutations(command, sequence_id, all_mutations)
        local clip_ids = {}
        for _, created in ipairs(created_clips) do
            table.insert(clip_ids, created.clip_id)
        end
        command:set_parameters({
            ["executed_mutations"] = all_mutations,
            ["created_clip_ids"] = clip_ids,
            ["created_link_group_ids"] = link_group_ids,
        })

        -- Update selection to pasted clips
        local new_selection = {}
        for _, cid in ipairs(clip_ids) do
            new_selection[#new_selection + 1] = { id = cid }
        end
        if timeline_state.set_selection then
            timeline_state.set_selection(new_selection)
        end

        log.event("Pasted %d clip(s) at frame %d", #clip_ids, playhead_frames)
        return true
    end

    command_undoers["Paste"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "UndoPaste: db is nil")

        -- Executor sets all three unconditionally before returning success.
        local link_group_ids     = args.created_link_group_ids
        local executed_mutations = args.executed_mutations

        if #executed_mutations == 0 and #link_group_ids == 0 then
            return true
        end

        -- Delete link groups first
        for _, link_id in ipairs(link_group_ids) do
            local query = db:prepare("DELETE FROM clip_links WHERE link_group_id = ?")
            if query then
                query:bind_value(1, link_id)
                query:exec()
                query:finalize()
            end
        end

        -- Revert mutations
        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, args.sequence_id)
        assert(ok, "UndoPaste: failed to revert mutations: " .. tostring(err))

        log.event("Undo Paste: reverted all changes")
        return true
    end

    command_executors["UndoPaste"] = command_undoers["Paste"]

    return {
        executor = command_executors["Paste"],
        undoer = command_undoers["Paste"],
        spec = SPEC,
    }
end

return M
