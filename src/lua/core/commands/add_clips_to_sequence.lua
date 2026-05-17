--- AddClipsToSequence command (Feature 013, rewrite per T042).
--
-- Batch placement of N clip groups onto an edit sequence in one undo
-- atom. Each group represents a logical placement unit (e.g. an A+V
-- master) — clips within a group are linked into a single clip_links
-- group after placement. Multiple groups can be arranged "serial" (back
-- to back) or "stacked" (all at the same start position, on different
-- tracks).
--
-- Insert/Overwrite (T040/T041) cover the single-master placement path;
-- this command exists for the multi-master batch path (e.g. dragging
-- several master clips onto the timeline at once with a single undo).
--
-- Per task T042: clip rows reference sequences only; no media_id /
-- clip_kind / master_clip_id / offline columns are read or written.
-- Each clip_desc carries a sequence_id that the new clip row
-- references; per-clip overrides ride on the clip row directly
-- (master_layer_track_id, fps_mismatch_policy).
--
-- Carving:
--   insert: ripple every track in the sequence forward by the batch's
--     total_duration starting at `position`.
--   overwrite: occlude the union of group ranges on each target track
--     via the shared place_shared.occlude_track helper.
--
-- Refuses (loud): malformed args, conflicting clip_desc fields,
-- per-clip owner-kind and source-window violations on insert, target_track_id absent or
-- in a different sequence.
--
-- Atomicity: SAVEPOINT wraps every DB write so a mid-batch failure
-- unwinds the entire operation.
--
-- Undo of the batch is deferred to the broader T046 sweep (it requires
-- replaying both ripple/occlusion captures and clip restorations across
-- N groups). The execute path is fully V13.
--
-- @file add_clips_to_sequence.lua

local M = {}

local Clip         = require("models.clip")
local Sequence     = require("models.sequence")
local Track        = require("models.track")
local clip_link    = require("models.clip_link")
local place_shared = require("core.commands._place_shared")
local database     = require("core.database")
local uuid         = require("uuid")
local log          = require("core.logger").for_area("commands")

local SAVEPOINT = "add_clips_to_sequence_atomic"

local SPEC = {
    -- Called from import flows (DRP, FCP7, ResolveDB) where the caller
    -- already knows which sequence is the target. No keyboard dispatch
    -- path; auto-injecting active_sequence_id would silently land clips
    -- in the wrong sequence when an import runs while a different
    -- timeline is open.
    caller_supplied_sequence_id = true,
    args = {
        sequence_id = { required = true },
        project_id  = { required = true },
        edit_type   = { required = true },  -- "insert" or "overwrite"
        arrangement = {},                    -- "serial" (default) or "stacked"
        position    = { required = true },   -- integer owner-frame
        groups      = { required = true },   -- list of { duration, clips = [...] }
        advance_playhead = { kind = "boolean" },
    },
    persisted = {
        created_clip_ids       = { kind = "table" },
        created_link_group_ids = { kind = "table" },
        rippled_capture        = { kind = "table" },
        occluded_capture       = { kind = "table" },
        prior_playhead         = { kind = "number" },
    },
}

-- Phase 1: compute the total batch duration on the timeline + a track-keyed
-- list of intervals. Each interval is {start, end_frame, clip_desc, group}.
-- Coordinates only; no DB access.
local function compute_space_needs(groups, arrangement, position)
    local total_duration = 0
    local track_map = {}

    if arrangement == "serial" then
        local cursor = position
        for _, group in ipairs(groups) do
            local group_frames = group.duration
            assert(type(group_frames) == "number" and group_frames > 0,
                "AddClipsToSequence: group.duration must be positive integer")
            local start_pos = cursor
            local end_pos   = cursor + group_frames
            for _, clip_desc in ipairs(group.clips) do
                local track_id = assert(clip_desc.target_track_id,
                    "AddClipsToSequence: clip_desc missing target_track_id")
                track_map[track_id] = track_map[track_id] or {}
                track_map[track_id][#track_map[track_id] + 1] = {
                    start_frame = start_pos,
                    end_frame   = end_pos,
                    clip_desc   = clip_desc,
                    group       = group,
                }
            end
            cursor = end_pos
            total_duration = cursor - position
        end
    else
        local max_frames = 0
        for _, group in ipairs(groups) do
            local group_frames = group.duration
            assert(type(group_frames) == "number" and group_frames > 0,
                "AddClipsToSequence: group.duration must be positive integer")
            if group_frames > max_frames then max_frames = group_frames end
            for _, clip_desc in ipairs(group.clips) do
                local track_id = assert(clip_desc.target_track_id,
                    "AddClipsToSequence: clip_desc missing target_track_id")
                track_map[track_id] = track_map[track_id] or {}
                track_map[track_id][#track_map[track_id] + 1] = {
                    start_frame = position,
                    end_frame   = position + group_frames,
                    clip_desc   = clip_desc,
                    group       = group,
                }
            end
        end
        total_duration = max_frames
    end

    return total_duration, track_map
end

-- Phase 2: carve space.
--   insert: ripple every track in the sequence by total_duration starting
--     at `position`. Insert ripples ALL tracks (not just target tracks)
--     so the batch's logical "wedge" leaves the timeline consistent.
--   overwrite: occlude the union of intervals on each target track via
--     the shared place_shared.occlude_track helper.
local function carve_space(edit_type, sequence_id, owner_seq,
                          position, total_duration, track_map)
    local rippled_capture = {}
    local occluded_capture = {}

    if edit_type == "insert" then
        local tracks = Track.find_by_sequence(sequence_id)
        assert(tracks, "AddClipsToSequence: Track.find_by_sequence returned nil")
        for _, t in ipairs(tracks) do
            local ids = Clip.ripple_track_forward(t.id, position, total_duration)
            if ids and #ids > 0 then
                rippled_capture[t.id] = {
                    shift      = total_duration,
                    from_frame = position,
                    clip_ids   = ids,
                }
            end
        end
    elseif edit_type == "overwrite" then
        for track_id, intervals in pairs(track_map) do
            local lo = intervals[1].start_frame
            local hi = intervals[1].end_frame
            for i = 2, #intervals do
                if intervals[i].start_frame < lo then lo = intervals[i].start_frame end
                if intervals[i].end_frame   > hi then hi = intervals[i].end_frame   end
            end
            if hi > lo then
                occluded_capture[track_id] =
                    place_shared.occlude_track(track_id, owner_seq, lo, hi)
            end
        end
    else
        error("AddClipsToSequence: edit_type must be 'insert' or 'overwrite'; got "
              .. tostring(edit_type))
    end

    return {
        rippled  = rippled_capture,
        occluded = occluded_capture,
    }
end

-- Phase 3: place the new clip rows. Each clip_desc must carry a V13
-- sequence_id, source_in/out, duration, fps_mismatch_policy.
-- Optional: master_layer_track_id, name, role.
local function place_clips(track_map, project_id, sequence_id)
    -- Flatten + deterministic order so failure messages are reproducible.
    local placements = {}
    for track_id, intervals in pairs(track_map) do
        for _, interval in ipairs(intervals) do
            placements[#placements + 1] = {
                track_id = track_id, interval = interval,
            }
        end
    end
    table.sort(placements, function(a, b)
        if a.track_id ~= b.track_id then return a.track_id < b.track_id end
        return a.interval.start_frame < b.interval.start_frame
    end)

    local created = {}
    for _, p in ipairs(placements) do
        local interval = p.interval
        local d = interval.clip_desc

        assert(d.sequence_id and d.sequence_id ~= "",
            "AddClipsToSequence: clip_desc.sequence_id required (rule 2.13 — V13 row shape)")
        assert(type(d.source_in) == "number"
           and type(d.source_out) == "number",
            "AddClipsToSequence: clip_desc.source_in / source_out must be integers")
        assert(d.fps_mismatch_policy and d.fps_mismatch_policy ~= "",
            "AddClipsToSequence: clip_desc.fps_mismatch_policy required (rule 2.13)")
        assert(type(d.duration) == "number" and d.duration > 0,
            "AddClipsToSequence: clip_desc.duration must be a positive integer")

        local clip_id = d.clip_id or uuid.generate()
        Clip._create_v13_row({
            id                    = clip_id,
            project_id            = project_id,
            owner_sequence_id     = sequence_id,
            track_id              = p.track_id,
            sequence_id    = d.sequence_id,
            name                  = d.name or "Timeline Clip",
            timeline_start_frame  = interval.start_frame,
            duration_frames       = d.duration,
            source_in_frame       = d.source_in,
            source_out_frame      = d.source_out,
            master_layer_track_id = d.master_layer_track_id,  -- nullable
            fps_mismatch_policy   = d.fps_mismatch_policy,
            enabled               = (d.enabled ~= false),
            volume                = d.volume or 1.0,
            mark_in_frame         = d.mark_in_frame,
            mark_out_frame        = d.mark_out_frame,
            playhead_frame        = d.playhead_frame or 0,
        })
        created[#created + 1] = {
            clip_id = clip_id,
            group   = interval.group,
            role    = d.role,  -- "video" / "audio" — used for link_group role
        }
    end
    return created
end

-- Phase 4: link clips within each group (clip_link.create_link_group
-- requires ≥2 members; single-clip groups are left unlinked).
local function link_groups(created)
    local clips_by_group = {}
    for _, c in ipairs(created) do
        clips_by_group[c.group] = clips_by_group[c.group] or {}
        clips_by_group[c.group][#clips_by_group[c.group] + 1] = {
            clip_id     = c.clip_id,
            role        = c.role or "video",
            time_offset = 0,
        }
    end
    local link_group_ids = {}
    for _, members in pairs(clips_by_group) do
        if #members >= 2 then
            local id, err = clip_link.create_link_group(members)
            assert(id, string.format(
                "AddClipsToSequence: link group creation failed: %s",
                tostring(err)))
            link_group_ids[#link_group_ids + 1] = id
        end
    end
    return link_group_ids
end

function M.execute(args)
    assert(type(args) == "table", "AddClipsToSequence.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "AddClipsToSequence: sequence_id required (rule 2.29)")
    assert(args.project_id and args.project_id ~= "",
        "AddClipsToSequence: project_id required")
    assert(type(args.position) == "number" and args.position >= 0,
        "AddClipsToSequence: position must be a non-negative integer frame")
    assert(type(args.groups) == "table" and #args.groups > 0,
        "AddClipsToSequence: groups must be a non-empty array")

    local edit_type   = args.edit_type
    assert(edit_type == "insert" or edit_type == "overwrite", string.format(
        "AddClipsToSequence: edit_type must be 'insert' or 'overwrite'; got %s",
        tostring(edit_type)))
    local arrangement = args.arrangement or "serial"
    assert(arrangement == "serial" or arrangement == "stacked", string.format(
        "AddClipsToSequence: arrangement must be 'serial' or 'stacked'; got %s",
        tostring(arrangement)))

    local owner_seq = Sequence.find(args.sequence_id)
    assert(owner_seq, string.format(
        "AddClipsToSequence: sequence %s not found", args.sequence_id))
    assert(owner_seq.kind == "sequence", string.format(
        "AddClipsToSequence: sequence %s has kind='%s' (expected 'sequence') — clips must be owned by a kind='sequence' sequence",
        args.sequence_id, tostring(owner_seq.kind)))

    local total_duration, track_map =
        compute_space_needs(args.groups, arrangement, args.position)

    assert(database.savepoint(SAVEPOINT), "AddClipsToSequence: savepoint failed")
    local result = {}
    local ok, err = pcall(function()
        local carve = carve_space(edit_type, args.sequence_id, owner_seq,
            args.position, total_duration, track_map)
        local created = place_clips(track_map, args.project_id, args.sequence_id)
        local link_group_ids = link_groups(created)

        result.created          = created
        result.carve            = carve
        result.link_group_ids   = link_group_ids
        result.total_duration   = total_duration
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT),
        "AddClipsToSequence: release savepoint failed")

    log.event("AddClipsToSequence: %d group(s), %d clip(s), %d link group(s) at frame %d (%s, %s)",
        #args.groups, #result.created, #result.link_group_ids,
        args.position, edit_type, arrangement)

    return {
        sequence_id      = args.sequence_id,
        position         = args.position,
        total_duration   = total_duration,
        created_clip_ids = (function()
            local t = {}
            for _, c in ipairs(result.created) do t[#t+1] = c.clip_id end
            return t
        end)(),
        link_group_ids   = result.link_group_ids,
        carve            = result.carve,  -- {rippled, occluded}
    }
end

-- Build the __timeline_mutations bucket the executor hands off to
-- command_manager. Inserts come from re-loading the just-created clips
-- (Clip.load joins frame_rate from the nested sequence row, which
-- clip_state asserts non-nil). Bulk_shifts come from the insert-mode
-- carve's rippled clips.
local function build_executor_mutation_bucket(sequence_id, result)
    local bucket = {
        sequence_id = sequence_id,
        inserts     = {},
        updates     = {},
        deletes     = {},
        bulk_shifts = {},
    }
    for _, cid in ipairs(result.created_clip_ids) do
        local clip = Clip.load(cid)
        if clip then
            bucket.inserts[#bucket.inserts + 1] = {
                id                    = clip.id,
                owner_sequence_id     = clip.owner_sequence_id,
                track_sequence_id     = clip.owner_sequence_id,
                track_id              = clip.track_id,
                sequence_id    = clip.sequence_id,
                start_value           = clip.timeline_start,
                timeline_start        = clip.timeline_start,
                duration_value        = clip.duration,
                duration              = clip.duration,
                source_in             = clip.source_in,
                source_out            = clip.source_out,
                master_layer_track_id = clip.master_layer_track_id,
                fps_mismatch_policy   = clip.fps_mismatch_policy,
                frame_rate            = clip.frame_rate,
                name                  = clip.name,
                enabled               = clip.enabled,
                volume                = clip.volume,
                playhead_frame        = clip.playhead_frame,
            }
        end
    end
    for track_id, rip in pairs(result.carve.rippled) do
        bucket.bulk_shifts[#bucket.bulk_shifts + 1] = {
            track_id     = track_id,
            shift_frames = rip.shift,
            start_frame  = rip.from_frame,
        }
    end
    return bucket
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["AddClipsToSequence"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("AddClipsToSequence: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        -- carve always carries both fields (see carve_space); no fallback.
        command:set_parameter("created_clip_ids",       result_or_err.created_clip_ids)
        command:set_parameter("created_link_group_ids", result_or_err.link_group_ids)
        command:set_parameter("rippled_capture",        result_or_err.carve.rippled)
        command:set_parameter("occluded_capture",       result_or_err.carve.occluded)
        command:set_parameter("__timeline_mutations",
            build_executor_mutation_bucket(args.sequence_id, result_or_err))

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        -- advance_playhead: same contract as Insert/Overwrite. Advance by
        -- total_duration from position; persist; emit playhead_changed.
        if args.advance_playhead then
            local owner = assert(Sequence.load(args.sequence_id),
                "AddClipsToSequence: sequence " .. tostring(args.sequence_id) .. " not found post-execute")
            command:set_parameter("prior_playhead", owner.playhead_position)
            local new_playhead = result_or_err.position + result_or_err.total_duration
            owner:set_playhead(new_playhead)
            assert(owner:save(), "AddClipsToSequence: sequence save failed after advance_playhead")
            Signals.emit("playhead_changed", args.sequence_id, new_playhead)
        end

        return true, {
            created_clip_ids = result_or_err.created_clip_ids,
            link_group_ids   = result_or_err.link_group_ids,
        }
    end

    command_undoers["AddClipsToSequence"] = function(command)
        local args = command:get_all_parameters()
        -- Executor set these unconditionally; carve sub-captures always
        -- carry split_new_ids/trimmed/deleted arrays (see occlude_track).
        local created_ids = args.created_clip_ids
        local rippled     = args.rippled_capture
        local occluded    = args.occluded_capture

        -- 1. Delete the newly-created clips (clip_links FK cascades).
        Clip.delete_by_ids(created_ids)

        -- 2. Reverse the insert-mode ripple. Use shift_many_by on the
        --    captured clip_ids so re-created/restored clips below aren't
        --    swept in. delta = -shift.
        for _, rip in pairs(rippled) do
            if rip.clip_ids and #rip.clip_ids > 0 and rip.shift then
                Clip.shift_many_by(rip.clip_ids, -rip.shift)
            end
        end

        -- 3. Restore overwrite-mode occlusion captures: drop split-rights,
        --    un-trim, re-create fully-deleted clips. Mirrors Overwrite.undo.
        for _, cap in pairs(occluded) do
            Clip.delete_by_ids(cap.split_new_ids)
        end
        for _, cap in pairs(occluded) do
            for _, tr in ipairs(cap.trimmed) do
                Clip.update_bounds(tr.id,
                    tr.prior.timeline_start_frame,
                    tr.prior.duration_frames,
                    tr.prior.source_in_frame,
                    tr.prior.source_out_frame)
            end
        end
        for _, cap in pairs(occluded) do
            for _, d in ipairs(cap.deleted) do
                Clip.create({
                    id                    = d.id,
                    project_id            = d.project_id,
                    owner_sequence_id     = d.owner_sequence_id,
                    track_id              = d.track_id,
                    sequence_id    = d.sequence_id,
                    name                  = d.name,
                    timeline_start_frame  = d.timeline_start_frame,
                    duration_frames       = d.duration_frames,
                    source_in_frame       = d.source_in_frame,
                    source_out_frame      = d.source_out_frame,
                    master_layer_track_id = d.master_layer_track_id,
                    fps_mismatch_policy   = d.fps_mismatch_policy,
                    enabled               = d.enabled,
                    volume                = d.volume,
                    mark_in_frame         = d.mark_in_frame,
                    mark_out_frame        = d.mark_out_frame,
                    playhead_frame        = d.playhead_frame,
                })
            end
        end

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        -- Restore playhead if execute had advanced it.
        if args.prior_playhead ~= nil and args.sequence_id then
            local owner = Sequence.load(args.sequence_id)
            if owner then
                owner:set_playhead(args.prior_playhead)
                owner:save()
                Signals.emit("playhead_changed", args.sequence_id, args.prior_playhead)
            end
        end

        return true
    end

    return {
        executor = command_executors["AddClipsToSequence"],
        undoer   = command_undoers["AddClipsToSequence"],
        spec     = SPEC,
    }
end

return M
