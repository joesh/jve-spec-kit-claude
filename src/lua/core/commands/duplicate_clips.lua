local M = {}

local Track = require("models.track")
local clip_link = require("models.clip_link")
local id_pool = require("core.commands._id_pool")
local command_helper = require("core.command_helper")
local clip_mutator = require("core.clip_mutator")
local log = require("core.logger").for_area("commands")


local SPEC = {
    args = {
        anchor_clip_id = { required = true },
        clip_ids = {},
        delta_frames = { kind = "number" },
        project_id = { required = true },
        sequence_id = { required = true },
        target_track_id = { required = true },
    },
    persisted = {
        executed_mutations = {},
        new_clip_ids = {},
        -- Redo-stable ids for tracks the duplicate had to create and the
        -- link groups it formed; also the undo manifest (what to delete).
        auto_track_ids = {},
        created_link_group_ids = {},
    },

}

-- Auto-create the destination tracks the mapping needs but the sequence
-- lacks (e.g. a linked audio clip duplicated above the highest audio track).
-- Mirrors insert.lua's auto_create_record_audio_tracks: pinned per-type
-- index, redo-stable id from the pool, removed on undo. No fallback to the
-- source track — the clip lands where the shared mapping says it must.
local function auto_create_missing_tracks(missing, sequence_id, track_pool)
    for _, desc in ipairs(missing) do
        local t
        if desc.track_type == "AUDIO" then
            t = Track.create_audio(string.format("A%d", desc.track_index), sequence_id,
                { id = track_pool:take(), index = desc.track_index })
        elseif desc.track_type == "VIDEO" then
            t = Track.create_video(string.format("V%d", desc.track_index), sequence_id,
                { id = track_pool:take(), index = desc.track_index })
        else
            error("DuplicateClips: cannot auto-create track of type " .. tostring(desc.track_type))
        end
        assert(t:save(), string.format("DuplicateClips: failed to save auto-created %s track index %d",
            desc.track_type, desc.track_index))
        log.event("DuplicateClips: auto-created %s track index %d id=%s",
            desc.track_type, desc.track_index, t.id)
    end
end

-- Re-form link groups among the duplicates: clips copied from one source
-- link group become a new group of their own, carrying the source roles
-- (mirrors paste.lua). A clip whose source was unlinked stays unlinked.
-- Returns the array of created link_group_ids (for persistence + undo).
local function create_duplicate_link_groups(db, new_clips, link_group_pool)
    local buckets = {}  -- [source_group_id] = { {clip_id, role, time_offset}, ... }
    for _, nc in ipairs(new_clips) do
        local source_group_id = clip_link.get_link_group_id(nc.source_clip_id, db)
        if source_group_id then
            local members = clip_link.get_link_group(nc.source_clip_id, db)
            assert(members, "DuplicateClips: source clip in a group but group load failed")
            local source_role
            for _, m in ipairs(members) do
                if m.clip_id == nc.source_clip_id then source_role = m.role end
            end
            assert(source_role, "DuplicateClips: linked source clip missing its own role")
            buckets[source_group_id] = buckets[source_group_id] or {}
            table.insert(buckets[source_group_id],
                { clip_id = nc.new_id, role = source_role, time_offset = 0 })
        end
    end

    local created = {}
    for _, group_clips in pairs(buckets) do
        if #group_clips >= 2 then
            local link_id, link_err = clip_link.create_link_group(group_clips, db, link_group_pool:take())
            assert(link_id, "DuplicateClips: create_link_group failed: " .. tostring(link_err))
            created[#created + 1] = link_id
        end
    end
    return created
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateClips"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "DuplicateClips: db is nil")
        assert(command and command.get_parameter, "DuplicateClips: invalid command handle")

        local sequence_id = args.sequence_id
        if not sequence_id or sequence_id == "" then
            return false, "DuplicateClips: missing sequence_id"
        end

        local clip_ids = args.clip_ids
        if type(clip_ids) ~= "table" or #clip_ids == 0 then
            return false, "DuplicateClips: missing clip_ids"
        end

        local target_track_id = args.target_track_id
        if not target_track_id or target_track_id == "" then
            return false, "DuplicateClips: missing target_track_id"
        end

        -- Delta must be integer frames
        local delta_frames = args.delta_frames or 0
        assert(type(delta_frames) == "number", "DuplicateClips: delta_frames must be integer")

        local anchor_clip_id = args.anchor_clip_id or clip_ids[1]
        if not anchor_clip_id or anchor_clip_id == "" then
            return false, "DuplicateClips: missing anchor_clip_id"
        end

        local plan_params = {
            sequence_id = sequence_id,
            clip_ids = clip_ids,
            delta_frames = delta_frames,
            target_track_id = target_track_id,
            anchor_clip_id = anchor_clip_id,
        }

        -- Phase 1: create destination tracks the mapping needs but the
        -- sequence lacks, BEFORE planning (the planner only accepts real
        -- track ids). Pool seeded from persisted ids keeps them stable on redo.
        local track_pool = id_pool.new(args.auto_track_ids)
        local missing = clip_mutator.compute_missing_target_tracks(db, plan_params)
        auto_create_missing_tracks(missing, sequence_id, track_pool)

        -- Phase 2: plan the duplicate (all destination tracks now exist).
        local ok_plan, plan_err, plan = clip_mutator.plan_duplicate_block(db, plan_params)
        if not ok_plan then
            return false, plan_err
        end

        local planned_mutations = plan.planned_mutations
        if #planned_mutations == 0 then
            -- No work after all — drop any tracks we speculatively created.
            local created_track_ids = track_pool:taken()
            for i = #created_track_ids, 1, -1 do
                Track.delete(created_track_ids[i])
            end
            return true
        end

        -- Phase 3: apply clip mutations.
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "DuplicateClips: apply_mutations failed: " .. tostring(apply_err)
        end

        -- Phase 4: re-form link groups among the duplicates.
        local link_group_pool = id_pool.new(args.created_link_group_ids)
        local created_groups = create_duplicate_link_groups(db, plan.new_clips, link_group_pool)

        command:set_parameters({
            ["executed_mutations"]     = planned_mutations,
            ["new_clip_ids"]           = plan.new_clip_ids,
            ["auto_track_ids"]         = track_pool:taken(),
            ["created_link_group_ids"] = created_groups,
        })

        command_helper.report_planner_mutations(command, sequence_id, planned_mutations)
        return true
    end

    command_undoers["DuplicateClips"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "UndoDuplicateClips: db is nil")
        assert(command and command.get_parameter, "UndoDuplicateClips: invalid command handle")

        local executed = args.executed_mutations
        local created_groups = args.created_link_group_ids
        local auto_ids = args.auto_track_ids

        -- A trivial execute (no mutations planned) persisted none of these.
        if executed == nil and created_groups == nil and auto_ids == nil then
            return true
        end

        -- The executor sets all three together on the do-work path; a missing
        -- one here is a persistence bug that would leak orphan tracks or link
        -- groups. Fail fast (1.14) rather than silently skip.
        assert(type(executed) == "table",
            "UndoDuplicateClips: executed_mutations not persisted on command")
        assert(type(created_groups) == "table",
            "UndoDuplicateClips: created_link_group_ids not persisted on command")
        assert(type(auto_ids) == "table",
            "UndoDuplicateClips: auto_track_ids not persisted on command")

        -- Delete the duplicate link groups first (clip_links also cascade
        -- when the clips are reverted, but explicit delete matches paste.lua
        -- and keeps the in-memory path clean).
        for _, gid in ipairs(created_groups) do
            clip_link.delete_link_group(gid, db)
        end

        -- Revert clip inserts/occlusion edits (removes the duplicate clips).
        if #executed > 0 then
            local ok, err = command_helper.revert_mutations(db, executed, command, args.sequence_id)
            if not ok then
                return false, "UndoDuplicateClips: revert_mutations failed: " .. tostring(err)
            end
        end

        -- Delete auto-created tracks (now empty) in reverse creation order.
        for i = #auto_ids, 1, -1 do
            Track.delete(auto_ids[i])
        end

        return true
    end

    command_executors["UndoDuplicateClips"] = command_undoers["DuplicateClips"]

    return {
        executor = command_executors["DuplicateClips"],
        undoer = command_undoers["DuplicateClips"],
        spec = SPEC,
    }
end

return M
