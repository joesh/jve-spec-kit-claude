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
-- Validate the place_placement input shape. Caller invariants only — the
-- field-level assertions on referenced sequences happen inside resolve_*
-- helpers below.
local function validate_plan_args(args)
    assert(type(args) == "table",
        "place_shared.plan_placement: args table required")
    assert(args.sequence_id and args.sequence_id ~= "",
        "place_shared: sequence_id required")
    assert(args.nested_sequence_id and args.nested_sequence_id ~= "",
        "place_shared: nested_sequence_id required")
    assert(type(args.timeline_start_frame) == "number"
        and args.timeline_start_frame >= 0,
        "place_shared: timeline_start_frame must be non-negative integer")
end

-- Load the owner+nested sequences, enforce INV-2 on the owner, project
-- consistency, and cycle absence. Returns owner, nested.
local function resolve_endpoints(args)
    local owner  = Sequence.find(args.sequence_id)
    assert(owner, string.format(
        "place_shared: owner %s not found", args.sequence_id))
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
    return owner, nested
end

-- Compute per-medium native durations from the nested sequence. Asserts
-- non-zero when the medium is present.
local function compute_native_durations(nested, mediums)
    local v_dur = mediums.VIDEO
        and Sequence.native_duration_for_medium(nested.id, "VIDEO") or 0
    local a_dur = mediums.AUDIO
        and Sequence.native_duration_for_medium(nested.id, "AUDIO") or 0
    if mediums.VIDEO then
        assert(v_dur > 0, "place_shared: VIDEO medium has zero duration")
    end
    if mediums.AUDIO then
        assert(a_dur > 0, "place_shared: AUDIO medium has zero duration")
    end
    return v_dur, a_dur
end

-- Honor nested-sequence marks (FCP/Premiere/Resolve UX). mark_in/mark_out
-- are in the nested's video timebase, absolute TC. When set, narrow the
-- video and audio source ranges to the marked sub-region. Returns four
-- values: video_native_dur, video_source_in, audio_native_dur, audio_source_in.
local function apply_nested_marks(nested, mediums, v_dur, a_dur)
    local mark_in, mark_out = nested.mark_in, nested.mark_out
    if mark_in == nil and mark_out == nil then
        return v_dur, 0, a_dur, 0
    end
    local tc_origin = nested.start_timecode_frame or 0
    local lo = mark_in  and (mark_in  - tc_origin) or 0
    local hi = mark_out and (mark_out - tc_origin) or v_dur
    local video_source_in, audio_source_in = 0, 0
    if mediums.VIDEO then
        assert(lo >= 0 and hi <= v_dur and hi > lo, string.format(
            "place_shared: nested %s marks [%s,%s) out of bounds for video duration %d",
            nested.id, tostring(lo), tostring(hi), v_dur))
        v_dur, video_source_in = hi - lo, lo
    end
    if mediums.AUDIO then
        local samples_per_frame =
            nested.audio_sample_rate * nested.fps_denominator / nested.fps_numerator
        local a_lo = math.floor(lo * samples_per_frame + 0.5)
        local a_hi = math.floor(hi * samples_per_frame + 0.5)
        assert(a_lo >= 0 and a_hi <= a_dur and a_hi > a_lo, string.format(
            "place_shared: nested %s mark-derived audio range [%d,%d) "
            .. "out of bounds for audio duration %d",
            nested.id, a_lo, a_hi, a_dur))
        a_dur, audio_source_in = a_hi - a_lo, a_lo
    end
    return v_dur, video_source_in, a_dur, audio_source_in
end

-- Project the placement onto owner-timebase frames. Video drives the
-- duration when present (rate-aware via policy); audio-only paths convert
-- samples through real-time seconds to owner frames.
local function compute_owner_duration_for_plan(policy, owner, nested, mediums,
                                               v_dur, a_dur)
    if mediums.VIDEO then
        return M.compute_owner_duration(
            policy, v_dur,
            owner.fps_numerator, owner.fps_denominator,
            nested.fps_numerator, nested.fps_denominator)
    end
    -- Audio-only: samples @ nested.audio_sample_rate → seconds → owner frames.
    local seconds = a_dur / nested.audio_sample_rate
    return math.floor(seconds * owner.fps_numerator / owner.fps_denominator + 0.5)
end

-- Build the audio_targets list: one entry per A clip to create. Composite
-- emits 1 entry with NULL master_audio_track_id; expanded emits N entries,
-- one per nested A track. Auto-creates missing owner A tracks for the
-- expanded path; refuses on collision (rule 1.14, FR-023).
local function resolve_audio_targets(owner, nested, drop_mode, args, a_dur,
                                     owner_duration)
    if drop_mode == "composite" then
        return { {
            track_id              = M.pick_target_track(
                owner.id, "AUDIO", args.target_audio_track_id),
            master_audio_track_id = nil,
            source_out            = a_dur,
        } }
    end

    local nested_a = Track.find_by_sequence(nested.id, "AUDIO") or {}
    assert(#nested_a > 0, string.format(
        "place_shared: expanded audio_drop_mode requires nested %s to have "
        .. "at least one A track; got 0", nested.id))
    local owner_a_by_index = {}
    for _, t in ipairs(Track.find_by_sequence(owner.id, "AUDIO") or {}) do
        owner_a_by_index[t.track_index] = t.id
    end

    local targets = {}
    for _, nt in ipairs(nested_a) do
        local owner_track_id = owner_a_by_index[nt.track_index]
        if not owner_track_id then
            local newt = Track.create_audio(
                string.format("Audio %d", nt.track_index), owner.id,
                { id = uuid.generate(), index = nt.track_index })
            assert(newt:save(), string.format(
                "place_shared: failed to auto-create owner A track at index %d "
                .. "on sequence %s", nt.track_index, owner.id))
            owner_track_id = newt.id
            owner_a_by_index[nt.track_index] = owner_track_id
        end
        targets[#targets + 1] = {
            track_id              = owner_track_id,
            master_audio_track_id = nt.id,
            source_out            = a_dur,
        }
    end

    -- Collision check across the owner-frame placement window.
    local hi = args.timeline_start_frame + owner_duration
    for _, tgt in ipairs(targets) do
        local overlapping = Clip.find_overlapping_on_track(
            tgt.track_id, args.timeline_start_frame, hi)
        if #overlapping > 0 then
            error(string.format(
                "place_shared: expanded-audio collision on owner track %s — "
                .. "existing clip %s overlaps [%d, %d). Auto-creating tracks "
                .. "is non-destructive but overwriting an existing clip is. "
                .. "Clear the track or pick another start frame.",
                tgt.track_id, overlapping[1].id,
                args.timeline_start_frame, hi))
        end
    end
    return targets
end

local function derive_base_name(nested, args)
    local name = args.clip_name
    if not name or name == "" then
        name = Sequence.get_name(nested.id)
    end
    assert(name and name ~= "", "place_shared: could not derive clip name")
    return name
end

function M.plan_placement(args)
    validate_plan_args(args)
    local owner, nested = resolve_endpoints(args)
    local policy        = M.resolve_policy(args.fps_mismatch_policy, owner)

    local mediums = Sequence.contained_mediums(nested.id)
    assert(next(mediums) ~= nil, string.format(
        "place_shared: nested %s has no mediums", nested.id))

    local v_dur, a_dur = compute_native_durations(nested, mediums)
    local v_src_in, a_src_in
    v_dur, v_src_in, a_dur, a_src_in =
        apply_nested_marks(nested, mediums, v_dur, a_dur)

    local owner_duration = compute_owner_duration_for_plan(
        policy, owner, nested, mediums, v_dur, a_dur)
    assert(owner_duration > 0, "place_shared: computed owner_duration <= 0")

    local targets = {}
    if mediums.VIDEO then
        targets.VIDEO = M.pick_target_track(
            owner.id, "VIDEO", args.target_video_track_id)
    end

    local drop_mode = args.audio_drop_mode or "composite"
    assert(drop_mode == "composite" or drop_mode == "expanded", string.format(
        "place_shared: audio_drop_mode must be 'composite' or 'expanded'; "
        .. "got %s", tostring(drop_mode)))
    local audio_targets = mediums.AUDIO
        and resolve_audio_targets(owner, nested, drop_mode, args, a_dur, owner_duration)
        or {}

    return {
        owner            = owner,
        nested           = nested,
        policy           = policy,
        video_native_dur = v_dur,
        audio_native_dur = a_dur,
        video_source_in  = v_src_in,
        audio_source_in  = a_src_in,
        owner_duration   = owner_duration,
        targets          = targets,
        audio_targets    = audio_targets,
        audio_drop_mode  = drop_mode,
        base_name        = derive_base_name(nested, args),
        start_frame      = args.timeline_start_frame,
    }
end

--- Insert the new clip rows dictated by `plan`. Returns the ids.
---
--- Audio: one clip per `plan.audio_targets[i]`. Composite mode produces
--- 1 entry with master_audio_track_id=NULL; expanded mode produces N
--- entries with distinct selectors and pre-validated/auto-created
--- target tracks (see plan_placement).
---
--- Link group: created with V + every A clip when both mediums land.
function M.write_clips(plan)
    local created_list = {}
    local v_clip_id
    local a_clip_ids = {}

    local function insert_clip(fields)
        return Clip.create(fields)
    end

    -- Optional preset_ids let callers (e.g. command redo replaying a
    -- persisted execute) pin the new clip ids so undo/redo round-trip
    -- without churning uuids. preset_ids[1] is consumed for the video
    -- clip (when there is one) and the remaining entries feed the audio
    -- clip loop in order. Falls back to uuid.generate per slot.
    local preset_ids = plan.preset_ids or {}
    local preset_idx = 1
    local function next_preset()
        local pid = preset_ids[preset_idx]
        preset_idx = preset_idx + 1
        return pid or uuid.generate()
    end

    if plan.targets.VIDEO then
        local v_in  = plan.video_source_in or 0
        v_clip_id = insert_clip({
            id                    = next_preset(),
            project_id            = plan.owner.project_id,
            owner_sequence_id     = plan.owner.id,
            track_id              = plan.targets.VIDEO,
            nested_sequence_id    = plan.nested.id,
            name                  = plan.base_name,
            timeline_start_frame  = plan.start_frame,
            duration_frames       = plan.owner_duration,
            source_in_frame       = v_in,
            source_out_frame      = v_in + plan.video_native_dur,
            master_layer_track_id = nil,
            master_audio_track_id = nil,
            fps_mismatch_policy   = plan.policy,
            enabled               = true,
            volume                = 1.0,
            playhead_frame        = 0,
        })
        created_list[#created_list + 1] = v_clip_id
    end

    local a_in = plan.audio_source_in or 0
    for _, tgt in ipairs(plan.audio_targets or {}) do
        local id = insert_clip({
            id                    = next_preset(),
            project_id            = plan.owner.project_id,
            owner_sequence_id     = plan.owner.id,
            track_id              = tgt.track_id,
            nested_sequence_id    = plan.nested.id,
            name                  = plan.base_name,
            timeline_start_frame  = plan.start_frame,
            duration_frames       = plan.owner_duration,
            source_in_frame       = a_in,
            source_out_frame      = a_in + tgt.source_out,
            master_layer_track_id = nil,
            master_audio_track_id = tgt.master_audio_track_id,
            fps_mismatch_policy   = plan.policy,
            enabled               = true,
            volume                = 1.0,
            playhead_frame        = 0,
        })
        a_clip_ids[#a_clip_ids + 1] = id
        created_list[#created_list + 1] = id
    end

    -- Link group: V + every A clip when both mediums land.
    local link_group_id
    if v_clip_id and #a_clip_ids > 0 then
        local entries = {
            { clip_id = v_clip_id, role = "video", time_offset = 0 },
        }
        for _, aid in ipairs(a_clip_ids) do
            entries[#entries + 1] = {
                clip_id = aid, role = "audio", time_offset = 0,
            }
        end
        link_group_id = clip_link.create_link_group(entries)
        assert(link_group_id and link_group_id ~= "",
            "place_shared: clip_link.create_link_group returned empty id")
    end

    return {
        created_clip_ids = created_list,
        video_clip_id    = v_clip_id,
        audio_clip_id    = a_clip_ids[1],   -- first/only A in composite
        audio_clip_ids   = a_clip_ids,      -- all A clips (1 in composite, N in expanded)
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
-- Capture an existing clip's bounds for undo restoration.
local function snapshot_bounds(e)
    return {
        id = e.id,
        prior = {
            timeline_start_frame = e.timeline_start_frame,
            duration_frames      = e.duration_frames,
            source_in_frame      = e.source_in_frame,
            source_out_frame     = e.source_out_frame,
        },
    }
end

-- Convert an owner-frame delta to the equivalent source-frame delta under
-- this clip's fps_mismatch_policy. Wrapper for the long Clip.owner_delta…
-- name inside this branchy function.
local function owner_to_source_delta(e, owner_seq, nested, owner_delta)
    return Clip.owner_delta_to_source(
        e.fps_mismatch_policy, owner_delta,
        owner_seq.fps_numerator, owner_seq.fps_denominator,
        nested.fps_numerator,    nested.fps_denominator)
end

-- One of four overlap cases. Each helper mutates the clip via Clip.* and
-- returns the per-call deltas (a deleted row, a trimmed snapshot, a new
-- right-half id, or any combination). Returning tables instead of nil
-- keeps the dispatcher's accumulator code uniform.

local function occlude_full_cover(e)
    Clip.delete_by_ids({ e.id })
    return { deleted = e }
end

local function occlude_trim_tail(e, owner_seq, nested, n_start)
    local new_duration = n_start - e.timeline_start_frame
    local source_delta = owner_to_source_delta(
        e, owner_seq, nested, e.duration_frames - new_duration)
    local snap = snapshot_bounds(e)
    Clip.update_bounds(e.id,
        e.timeline_start_frame, new_duration,
        e.source_in_frame, e.source_out_frame - source_delta)
    return { trimmed = snap }
end

local function occlude_trim_head(e, owner_seq, nested, n_end)
    local shift        = n_end - e.timeline_start_frame
    local new_duration = e.duration_frames - shift
    local source_delta = owner_to_source_delta(e, owner_seq, nested, shift)
    local snap = snapshot_bounds(e)
    Clip.update_bounds(e.id,
        n_end, new_duration,
        e.source_in_frame + source_delta, e.source_out_frame)
    return { trimmed = snap }
end

local function occlude_split_middle(e, owner_seq, nested, n_start, n_end)
    local e_end           = e.timeline_start_frame + e.duration_frames
    local left_duration   = n_start - e.timeline_start_frame
    local right_duration  = e_end - n_end
    local left_source_delta = owner_to_source_delta(
        e, owner_seq, nested, e.duration_frames - left_duration)
    local right_source_delta = owner_to_source_delta(
        e, owner_seq, nested, n_end - e.timeline_start_frame)
    local snap = snapshot_bounds(e)
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
    return { trimmed = snap, split_new_id = right_id }
end

local function classify_overlap(e_start, e_end, n_start, n_end)
    if n_start <= e_start and n_end >= e_end then return "full_cover" end
    if n_start >  e_start and n_end >= e_end then return "trim_tail" end
    if n_start <= e_start and n_end <  e_end then return "trim_head" end
    if n_start >  e_start and n_end <  e_end then return "split"     end
    return nil  -- unreachable for an actually-overlapping clip
end

function M.occlude_track(track_id, owner_seq, n_start, n_end)
    assert(track_id and track_id ~= "",
        "place_shared.occlude_track: track_id required")
    assert(type(n_start) == "number" and type(n_end) == "number"
       and n_end > n_start,
        "place_shared.occlude_track: range must be a non-empty owner-frame pair")

    local deleted_rows, trimmed, split_new_ids = {}, {}, {}
    for _, e in ipairs(Clip.find_overlapping_on_track(track_id, n_start, n_end)) do
        local nested = Sequence.find(e.nested_sequence_id)
        assert(nested, string.format(
            "place_shared.occlude_track: nested %s of clip %s not found",
            tostring(e.nested_sequence_id), tostring(e.id)))
        local e_end = e.timeline_start_frame + e.duration_frames
        local kind  = classify_overlap(e.timeline_start_frame, e_end, n_start, n_end)
        local out
        if kind == "full_cover" then
            out = occlude_full_cover(e)
        elseif kind == "trim_tail" then
            out = occlude_trim_tail(e, owner_seq, nested, n_start)
        elseif kind == "trim_head" then
            out = occlude_trim_head(e, owner_seq, nested, n_end)
        elseif kind == "split" then
            out = occlude_split_middle(e, owner_seq, nested, n_start, n_end)
        else
            error(string.format(
                "place_shared.occlude_track: unreachable case — clip=%s "
                .. "E=[%d,%d) N=[%d,%d)", e.id, e.timeline_start_frame, e_end,
                n_start, n_end))
        end
        if out.deleted      then deleted_rows[#deleted_rows + 1]   = out.deleted   end
        if out.trimmed      then trimmed[#trimmed + 1]             = out.trimmed   end
        if out.split_new_id then split_new_ids[#split_new_ids + 1] = out.split_new_id end
    end

    return {
        deleted       = deleted_rows,
        trimmed       = trimmed,
        split_new_ids = split_new_ids,
    }
end

--- Split any clip on `track_id` that strictly straddles `position`
--- (timeline_start < position < timeline_start + duration) into a left
--- half ending at position and a right half starting at position. The
--- caller's subsequent ripple_track_forward(track_id, position, shift)
--- picks up the new right-half (its timeline_start_frame == position) and
--- shifts it forward by `shift` along with everything downstream.
---
--- Net effect for an Insert at mid-clip: A becomes [orig_start, position),
--- the inserted clip occupies [position, position+inserted_dur), and
--- A_right occupies [position+inserted_dur, position+inserted_dur+(orig_end-position)).
--- This is the V8 / Resolve / Premiere / FCP UX for Insert.
---
--- INV: at most one clip on a track can strictly straddle a single point
--- (clips on a track may not overlap), so the loop runs at most once.
---
--- Returns { trimmed = [{id, prior}], split_new_ids = [ids] } — same
--- shape subset as occlude_track. Call sites can route this through the
--- same undo path: delete split_new_ids, restore trimmed bounds.
function M.split_track_at_insertion(track_id, owner_seq, position)
    assert(track_id and track_id ~= "",
        "place_shared.split_track_at_insertion: track_id required")
    assert(type(position) == "number",
        "place_shared.split_track_at_insertion: position must be integer frame")
    assert(owner_seq and owner_seq.fps_numerator and owner_seq.fps_denominator,
        "place_shared.split_track_at_insertion: owner_seq with fps required")

    local trimmed       = {}
    local split_new_ids = {}

    -- A strict-straddler has start < position AND start + duration > position.
    -- find_overlapping_on_track requires hi > lo, so use [position, position+1).
    local candidates = Clip.find_overlapping_on_track(track_id, position, position + 1)
    for _, e in ipairs(candidates) do
        local e_start = e.timeline_start_frame
        local e_end   = e_start + e.duration_frames
        if e_start < position and e_end > position then
            local nested = Sequence.find(e.nested_sequence_id)
            assert(nested, string.format(
                "place_shared.split_track_at_insertion: nested %s of clip %s not found",
                tostring(e.nested_sequence_id), tostring(e.id)))

            local left_duration  = position - e_start
            local right_duration = e_end - position
            local source_offset  = Clip.owner_delta_to_source(
                e.fps_mismatch_policy, left_duration,
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

            -- Atomic order matters for the video-overlap trigger: shrink
            -- the left half first (frees [position, e_end)), then create
            -- the right half into that freed range. Mirrors split_clip.lua.
            Clip.update_bounds(e.id,
                e.timeline_start_frame, left_duration,
                e.source_in_frame, e.source_in_frame + source_offset)

            local right_id = uuid.generate()
            Clip._create_v13_row({
                id                    = right_id,
                project_id            = e.project_id,
                owner_sequence_id     = e.owner_sequence_id,
                track_id              = e.track_id,
                nested_sequence_id    = e.nested_sequence_id,
                name                  = e.name,
                timeline_start_frame  = position,
                duration_frames       = right_duration,
                source_in_frame       = e.source_in_frame + source_offset,
                source_out_frame      = e.source_out_frame,
                master_layer_track_id = e.master_layer_track_id,
                fps_mismatch_policy   = e.fps_mismatch_policy,
                enabled               = e.enabled,
                volume                = e.volume,
                mark_in_frame         = e.mark_in_frame,
                mark_out_frame        = e.mark_out_frame,
                playhead_frame        = e.playhead_frame,
            })
            Clip.copy_channel_overrides(e.id, right_id)
            split_new_ids[#split_new_ids + 1] = right_id
        end
    end

    return {
        trimmed       = trimmed,
        split_new_ids = split_new_ids,
    }
end

return M
