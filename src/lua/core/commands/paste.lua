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
local Clip = require("models.clip")
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

--- Find source stream clip inside a masterclip sequence by role.
-- Shared pattern with AddClipsToSequence — finds video or audio stream clip.
local function find_source_stream_clip(db, masterclip_sequence_id, role)
    assert(masterclip_sequence_id and masterclip_sequence_id ~= "",
        "Paste.find_source_stream_clip: masterclip_sequence_id required")
    assert(role == "video" or role == "audio",
        "Paste.find_source_stream_clip: role must be 'video' or 'audio'")

    local track_type = (role == "video") and "VIDEO" or "AUDIO"
    local track_stmt = assert(db:prepare([[
        SELECT id FROM tracks WHERE sequence_id = ? AND track_type = ?
        ORDER BY track_index ASC LIMIT 1
    ]]), "Paste: failed to prepare track query")
    track_stmt:bind_value(1, masterclip_sequence_id)
    track_stmt:bind_value(2, track_type)
    assert(track_stmt:exec(), "Paste: track query failed")
    local track_id = track_stmt:next() and track_stmt:value(0) or nil
    track_stmt:finalize()
    if not track_id then return nil end

    local clip_stmt = assert(db:prepare([[
        SELECT id FROM clips WHERE owner_sequence_id = ? AND track_id = ? LIMIT 1
    ]]), "Paste: failed to prepare clip query")
    clip_stmt:bind_value(1, masterclip_sequence_id)
    clip_stmt:bind_value(2, track_id)
    assert(clip_stmt:exec(), "Paste: clip query failed")
    local clip_id = clip_stmt:next() and clip_stmt:value(0) or nil
    clip_stmt:finalize()
    return clip_id
end

--- Populate __timeline_mutations for UI cache updates from clip_mutator mutations.
local function populate_timeline_mutations(command, sequence_id, mutations)
    for _, mut in ipairs(mutations) do
        if mut.type == "insert" then
            command_helper.add_insert_mutation(command, sequence_id, {
                id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.timeline_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
                name = mut.name,
                media_id = mut.media_id,
                master_clip_id = mut.master_clip_id,
                owner_sequence_id = mut.owner_sequence_id,
                enabled = mut.enabled ~= false,
                clip_kind = mut.clip_kind,
                fps_numerator = mut.fps_numerator,
                fps_denominator = mut.fps_denominator,
            })
        elseif mut.type == "update" then
            command_helper.add_update_mutation(command, sequence_id, {
                clip_id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.timeline_start_frame,
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
        local clip_entries = payload.clips or {}
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
            assert(clip_data.media_id, "Paste: clipboard clip missing media_id")
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
            for _, mut in ipairs(mutations or {}) do
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

            local clip = Clip.create(cd.name or "Pasted Clip", cd.media_id, {
                id = clip_id,
                project_id = project_id,
                track_id = p.track_id,
                owner_sequence_id = sequence_id,
                master_clip_id = cd.master_clip_id,
                timeline_start = p.paste_start,
                duration = cd.duration,
                source_in = cd.source_in,
                source_out = cd.source_out,
                enabled = true,
                fps_numerator = cd.fps_numerator,
                fps_denominator = cd.fps_denominator,
            })

            table.insert(all_mutations, clip_mutator.plan_insert(clip))
            -- Determine role from track type
            local track = track_lookup[p.track_id]
            local role = (track.track_type == "VIDEO") and "video" or "audio"
            table.insert(created_clips, {
                clip_id = clip_id,
                master_clip_id = cd.master_clip_id,
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

        -- Phase 5: Copy properties from source masterclip stream clips
        for _, created in ipairs(created_clips) do
            -- Prefer properties snapshot from clipboard (preserves user edits)
            if created.copied_properties and #created.copied_properties > 0 then
                command_helper.delete_properties_for_clip(created.clip_id)
                command_helper.insert_properties_for_clip(created.clip_id, created.copied_properties)
            elseif created.master_clip_id then
                local source_clip_id = find_source_stream_clip(db, created.master_clip_id, created.role)
                if source_clip_id then
                    local copied_props = command_helper.ensure_copied_properties(command, source_clip_id)
                    if #copied_props > 0 then
                        command_helper.delete_properties_for_clip(created.clip_id)
                        command_helper.insert_properties_for_clip(created.clip_id, copied_props)
                    end
                end
            end
        end

        -- Phase 6: Link clips that came from the same masterclip
        local clips_by_master = {}
        for _, created in ipairs(created_clips) do
            local mc = created.master_clip_id
            if not mc then goto next_link end
            clips_by_master[mc] = clips_by_master[mc] or {}
            table.insert(clips_by_master[mc], {
                clip_id = created.clip_id,
                role = created.role,
                time_offset = 0,
            })
            ::next_link::
        end
        local link_group_ids = {}
        for _, group_clips in pairs(clips_by_master) do
            if #group_clips >= 2 then
                local link_id, link_err = clip_link.create_link_group(group_clips, db)
                if link_id then
                    table.insert(link_group_ids, link_id)
                else
                    log.warn("Paste: failed to create link group: %s", tostring(link_err))
                end
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

        local link_group_ids = args.created_link_group_ids or {}
        local executed_mutations = args.executed_mutations or {}

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
