--- Shared scaffolding for Insert/Overwrite (Feature 013).
--
-- Both commands write 1 or 2 V9 clips rows referencing a nested sequence
-- onto an edit sequence's tracks, linked via clip_links when both mediums
-- land. They differ only in how they treat clips already on the target
-- tracks: Insert ripples forward; Overwrite removes/trims/splits.
--
-- This module owns the shared read-side resolution (policy / mediums /
-- durations / target tracks) and the shared write helpers (insert clip
-- row, create link group). Each command owns its own collision strategy.
--
-- SQL isolation: no direct DB access; all calls go through models.
--
-- @file core/commands/_place_shared.lua

local M = {}

local uuid      = require("uuid")
local Project   = require("models.project")
local Sequence  = require("models.sequence")
local Track     = require("models.track")
local Clip      = require("models.clip")
local clip_link = require("models.clip_link")
local Cycle     = require("models.cycle")

--- Resolve the effective fps-mismatch policy for a place operation.
--- Chain: explicit arg → owner sequence override (non-NULL) → project default.
function M.resolve_policy(explicit, owner_seq)
    if explicit ~= nil then
        assert(explicit == "resample" or explicit == "passthrough", string.format(
            "place_shared: fps_mismatch_policy arg must be 'resample' or "
            .. "'passthrough' (got %s)", tostring(explicit)))
        return explicit
    end
    if owner_seq.fps_mismatch_policy ~= nil
       and owner_seq.fps_mismatch_policy ~= "" then
        return owner_seq.fps_mismatch_policy
    end
    return Project.get_fps_mismatch_policy(owner_seq.project_id)
end

--- Round-nearest owner-timebase duration for a clip under `policy`. Caller
--- passes the nested's native-timebase duration AND the fps pair for each
--- side; output is in owner frames.
function M.compute_owner_duration(policy, nested_native_duration,
                                  owner_fps_num, owner_fps_den,
                                  nested_fps_num, nested_fps_den)
    if policy == "passthrough" then
        return nested_native_duration
    end
    assert(policy == "resample",
        "place_shared.compute_owner_duration: unknown policy " .. tostring(policy))
    local ratio = (owner_fps_num / owner_fps_den)
                / (nested_fps_num / nested_fps_den)
    return math.floor(nested_native_duration * ratio + 0.5)
end

--- Pick the owner track for a given medium. Caller-specified track wins; else
--- first track of that type on the owner. Asserts type + ownership.
function M.pick_target_track(owner_id, track_type, explicit_track_id)
    if explicit_track_id and explicit_track_id ~= "" then
        local t = Track.load(explicit_track_id)
        assert(t, string.format(
            "place_shared: target %s track %s not found",
            track_type, explicit_track_id))
        assert(t.sequence_id == owner_id, string.format(
            "place_shared: target track %s belongs to sequence %s, not %s",
            explicit_track_id, tostring(t.sequence_id), owner_id))
        assert(t.track_type == track_type, string.format(
            "place_shared: target track %s is %s, expected %s",
            explicit_track_id, tostring(t.track_type), track_type))
        return explicit_track_id
    end
    local tracks = Track.find_by_sequence(owner_id, track_type)
    assert(tracks and #tracks > 0, string.format(
        "place_shared: nested has %s but owner %s has no %s track",
        track_type, owner_id, track_type))
    return tracks[1].id
end

--- Plan a placement: resolve owner+nested, cycle check, policy, mediums,
--- per-medium native durations, owner-timebase duration, target tracks,
--- clip name. Returns a struct the caller consumes to execute.
---
---   args: { sequence_id, nested_sequence_id, timeline_start_frame,
---           target_video_track_id?, target_audio_track_id?,
---           fps_mismatch_policy?, clip_name? }
---
---   result: { owner, nested, policy,
---             video_native_dur, audio_native_dur, owner_duration,
---             targets = { VIDEO?, AUDIO? }, base_name,
---             start_frame }
function M.plan_placement(args)
    assert(type(args) == "table", "place_shared.plan_placement: args table required")
    assert(args.sequence_id and args.sequence_id ~= "",
        "place_shared: sequence_id required")
    assert(args.nested_sequence_id and args.nested_sequence_id ~= "",
        "place_shared: nested_sequence_id required")
    assert(type(args.timeline_start_frame) == "number" and args.timeline_start_frame >= 0,
        "place_shared: timeline_start_frame must be non-negative integer")

    local owner  = Sequence.find(args.sequence_id)
    assert(owner, string.format("place_shared: owner %s not found", args.sequence_id))
    local nested = Sequence.find(args.nested_sequence_id)
    assert(nested, string.format(
        "place_shared: nested %s not found", args.nested_sequence_id))
    assert(owner.kind == "nested", string.format(
        "place_shared: owner %s has kind='%s' (expected 'nested' — INV-2)",
        owner.id, owner.kind))
    assert(owner.project_id == nested.project_id, string.format(
        "place_shared: owner project %s != nested project %s",
        tostring(owner.project_id), tostring(nested.project_id)))

    if Cycle.would_create_cycle(owner.id, nested.id) then
        error(string.format(
            "place_shared: would create a cycle — sequence %s reachable from %s",
            nested.id, owner.id))
    end

    local policy = M.resolve_policy(args.fps_mismatch_policy, owner)

    local mediums = Sequence.contained_mediums(nested.id)
    assert(next(mediums) ~= nil, string.format(
        "place_shared: nested %s has no mediums", nested.id))

    local video_native_dur = mediums.VIDEO
        and Sequence.native_duration_for_medium(nested.id, "VIDEO") or 0
    local audio_native_dur = mediums.AUDIO
        and Sequence.native_duration_for_medium(nested.id, "AUDIO") or 0
    if mediums.VIDEO then
        assert(video_native_dur > 0, "place_shared: VIDEO medium has zero duration")
    end
    if mediums.AUDIO then
        assert(audio_native_dur > 0, "place_shared: AUDIO medium has zero duration")
    end

    local owner_duration
    if mediums.VIDEO then
        owner_duration = M.compute_owner_duration(
            policy, video_native_dur,
            owner.fps_numerator, owner.fps_denominator,
            nested.fps_numerator, nested.fps_denominator)
    else
        -- Audio-only: convert samples @ nested audio_rate to owner video frames.
        local seconds = audio_native_dur / nested.audio_rate
        owner_duration = math.floor(
            seconds * owner.fps_numerator / owner.fps_denominator + 0.5)
    end
    assert(owner_duration > 0,
        "place_shared: computed owner_duration <= 0")

    local targets = {}
    if mediums.VIDEO then
        targets.VIDEO = M.pick_target_track(
            owner.id, "VIDEO", args.target_video_track_id)
    end
    if mediums.AUDIO then
        targets.AUDIO = M.pick_target_track(
            owner.id, "AUDIO", args.target_audio_track_id)
    end

    local base_name = args.clip_name
    if not base_name or base_name == "" then
        base_name = Sequence.get_name(nested.id)
    end
    assert(base_name and base_name ~= "", "place_shared: could not derive clip name")

    return {
        owner            = owner,
        nested           = nested,
        policy           = policy,
        video_native_dur = video_native_dur,
        audio_native_dur = audio_native_dur,
        owner_duration   = owner_duration,
        targets          = targets,
        base_name        = base_name,
        start_frame      = args.timeline_start_frame,
    }
end

--- Insert the new clip rows dictated by `plan`. Returns the ids.
function M.write_clips(plan)
    local created_list = {}
    local v_clip_id, a_clip_id

    local function insert_one(track_id, source_out)
        return Clip.create({
            id                    = uuid.generate(),
            project_id            = plan.owner.project_id,
            owner_sequence_id     = plan.owner.id,
            track_id              = track_id,
            nested_sequence_id    = plan.nested.id,
            name                  = plan.base_name,
            timeline_start_frame  = plan.start_frame,
            duration_frames       = plan.owner_duration,
            source_in_frame       = 0,
            source_out_frame      = source_out,
            master_layer_track_id = nil,
            fps_mismatch_policy   = plan.policy,
            enabled               = true,
            volume                = 1.0,
            mark_in_frame         = nil,
            mark_out_frame        = nil,
            playhead_frame        = 0,
        })
    end

    if plan.targets.VIDEO then
        v_clip_id = insert_one(plan.targets.VIDEO, plan.video_native_dur)
        created_list[#created_list + 1] = v_clip_id
    end
    if plan.targets.AUDIO then
        a_clip_id = insert_one(plan.targets.AUDIO, plan.audio_native_dur)
        created_list[#created_list + 1] = a_clip_id
    end

    local link_group_id
    if v_clip_id and a_clip_id then
        link_group_id = clip_link.create_link_group({
            { clip_id = v_clip_id, role = "video", time_offset = 0 },
            { clip_id = a_clip_id, role = "audio", time_offset = 0 },
        })
        assert(link_group_id and link_group_id ~= "",
            "place_shared: clip_link.create_link_group returned empty id")
    end

    return {
        created_clip_ids = created_list,
        video_clip_id    = v_clip_id,
        audio_clip_id    = a_clip_id,
        link_group_id    = link_group_id,
    }
end

--- Occlude one track for a clip range [n_start, n_end). Used by Overwrite
--- and AddClipsToSequence's overwrite mode. For each clip on `track_id`
--- that overlaps the range:
---   (a) fully covered          → DELETE
---   (b) tail-overlap on E      → trim E to end at n_start
---   (c) head-overlap on E      → trim E to start at n_end
---   (d) E straddles the range  → shrink E to the left half, INSERT a
---                                new right-half clip
--- Source-frame deltas use each clip's own fps_mismatch_policy via
--- Clip.owner_delta_to_source.
---
--- Returns { deleted = [rows], trimmed = [{id, prior}], split_new_ids = [ids] }
--- so the caller can capture undo state.
function M.occlude_track(track_id, owner_seq, n_start, n_end)
    assert(track_id and track_id ~= "",
        "place_shared.occlude_track: track_id required")
    assert(type(n_start) == "number" and type(n_end) == "number"
       and n_end > n_start,
        "place_shared.occlude_track: range must be a non-empty owner-frame pair")

    local overlapping = Clip.find_overlapping_on_track(track_id, n_start, n_end)
    local deleted_rows  = {}
    local trimmed       = {}
    local split_new_ids = {}

    for _, e in ipairs(overlapping) do
        local e_start = e.timeline_start_frame
        local e_end   = e_start + e.duration_frames

        local nested = Sequence.find(e.nested_sequence_id)
        assert(nested, string.format(
            "place_shared.occlude_track: nested %s of clip %s not found",
            tostring(e.nested_sequence_id), tostring(e.id)))

        if n_start <= e_start and n_end >= e_end then
            deleted_rows[#deleted_rows + 1] = e
            Clip.delete_by_ids({ e.id })

        elseif n_start > e_start and n_end >= e_end then
            local new_duration = n_start - e_start
            local trim_delta   = e.duration_frames - new_duration
            local source_delta = Clip.owner_delta_to_source(
                e.fps_mismatch_policy, trim_delta,
                owner_seq.fps_numerator, owner_seq.fps_denominator,
                nested.fps_numerator,    nested.fps_denominator)
            trimmed[#trimmed + 1] = {
                id = e.id,
                prior = {
                    timeline_start_frame = e.timeline_start_frame,
                    duration_frames      = e.duration_frames,
                    source_in_frame      = e.source_in_frame,
                    source_out_frame     = e.source_out_frame,
                },
            }
            Clip.update_bounds(e.id,
                e.timeline_start_frame, new_duration,
                e.source_in_frame, e.source_out_frame - source_delta)

        elseif n_start <= e_start and n_end < e_end then
            local shift        = n_end - e_start
            local new_duration = e.duration_frames - shift
            local source_delta = Clip.owner_delta_to_source(
                e.fps_mismatch_policy, shift,
                owner_seq.fps_numerator, owner_seq.fps_denominator,
                nested.fps_numerator,    nested.fps_denominator)
            trimmed[#trimmed + 1] = {
                id = e.id,
                prior = {
                    timeline_start_frame = e.timeline_start_frame,
                    duration_frames      = e.duration_frames,
                    source_in_frame      = e.source_in_frame,
                    source_out_frame     = e.source_out_frame,
                },
            }
            Clip.update_bounds(e.id,
                n_end, new_duration,
                e.source_in_frame + source_delta, e.source_out_frame)

        elseif n_start > e_start and n_end < e_end then
            local left_duration   = n_start - e_start
            local right_duration  = e_end - n_end
            local left_trim_delta = e.duration_frames - left_duration
            local left_source_delta = Clip.owner_delta_to_source(
                e.fps_mismatch_policy, left_trim_delta,
                owner_seq.fps_numerator, owner_seq.fps_denominator,
                nested.fps_numerator,    nested.fps_denominator)
            local right_owner_shift  = n_end - e_start
            local right_source_delta = Clip.owner_delta_to_source(
                e.fps_mismatch_policy, right_owner_shift,
                owner_seq.fps_numerator, owner_seq.fps_denominator,
                nested.fps_numerator,    nested.fps_denominator)
            trimmed[#trimmed + 1] = {
                id = e.id,
                prior = {
                    timeline_start_frame = e.timeline_start_frame,
                    duration_frames      = e.duration_frames,
                    source_in_frame      = e.source_in_frame,
                    source_out_frame     = e.source_out_frame,
                },
            }
            Clip.update_bounds(e.id,
                e.timeline_start_frame, left_duration,
                e.source_in_frame, e.source_out_frame - left_source_delta)
            local right_id = Clip.create({
                id                    = uuid.generate(),
                project_id            = e.project_id,
                owner_sequence_id     = e.owner_sequence_id,
                track_id              = e.track_id,
                nested_sequence_id    = e.nested_sequence_id,
                name                  = e.name,
                timeline_start_frame  = n_end,
                duration_frames       = right_duration,
                source_in_frame       = e.source_in_frame + right_source_delta,
                source_out_frame      = e.source_out_frame,
                master_layer_track_id = e.master_layer_track_id,
                fps_mismatch_policy   = e.fps_mismatch_policy,
                enabled               = e.enabled,
                volume                = e.volume,
                mark_in_frame         = e.mark_in_frame,
                mark_out_frame        = e.mark_out_frame,
                playhead_frame        = e.playhead_frame,
            })
            split_new_ids[#split_new_ids + 1] = right_id

        else
            error(string.format(
                "place_shared.occlude_track: unreachable case — clip=%s "
                .. "E=[%d,%d) N=[%d,%d)",
                e.id, e_start, e_end, n_start, n_end))
        end
    end

    return {
        deleted       = deleted_rows,
        trimmed       = trimmed,
        split_new_ids = split_new_ids,
    }
end

return M
