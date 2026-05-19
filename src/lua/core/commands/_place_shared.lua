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
local subframe_math = require("core.subframe_math")

--- Pick the effective fps-mismatch policy for a place operation.
--- Chain: explicit arg → owner sequence override (non-NULL) → project default.
function M.pick_policy(explicit, owner_seq)
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

--- Plan a placement: look up owner+nested, cycle check, policy, mediums,
--- per-medium native durations, owner-timebase duration, target tracks,
--- clip name. Returns a struct the caller consumes to execute.
---
---   args: { sequence_id, source_sequence_id, sequence_start_frame,
---           target_video_track_id?, target_audio_track_id?,
---           fps_mismatch_policy?, clip_name? }
---
---   result: { owner, nested, policy,
---             video_native_dur, audio_native_dur, owner_duration,
---             targets = { VIDEO?, AUDIO? }, base_name,
---             start_frame }
-- Validate the place_placement input shape. Caller invariants only — the
-- field-level assertions on referenced sequences happen inside the
-- pick_endpoints / compute_*_target helpers below.
local function validate_plan_args(args)
    assert(type(args) == "table",
        "place_shared.plan_placement: args table required")
    assert(args.sequence_id and args.sequence_id ~= "",
        "place_shared: sequence_id required")
    assert(args.source_sequence_id and args.source_sequence_id ~= "",
        "place_shared: source_sequence_id required")
    assert(type(args.sequence_start_frame) == "number"
        and args.sequence_start_frame >= 0,
        "place_shared: sequence_start_frame must be non-negative integer")
end

-- Load the owner+nested sequences, enforce that owner is kind='sequence', project
-- consistency, and cycle absence. Returns owner, nested.
local function pick_endpoints(args)
    local owner  = Sequence.find(args.sequence_id)
    assert(owner, string.format(
        "place_shared: owner %s not found", args.sequence_id))
    local nested = Sequence.find(args.source_sequence_id)
    assert(nested, string.format(
        "place_shared: nested %s not found", args.source_sequence_id))
    assert(owner.kind == "sequence", string.format(
        "place_shared: owner %s has kind='%s' (expected 'sequence' — clips must be owned by a kind='sequence' sequence)",
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
-- are absolute TC frames in the nested's master.fps timebase. When set,
-- narrow the video and audio source ranges to the marked sub-region.
-- Returns four values: video_native_dur, video_source_in, audio_native_dur,
-- audio_source_in — all in the nested's master.fps timebase.
--
-- TIMECODE IS THE SOURCE OF TRUTH: clip.source_in_frame must match the
-- nested's media_refs' sequence_start_frame coordinate system (= TC space
-- with offset tc_origin). The resolver (Sequence.resolve_master_leaf)
-- converts to file-natural samples internally for AUDIO media_refs via
-- audio_sample_rate * fps_denominator / fps_numerator; we must NOT
-- pre-convert here.
--
-- For mixed V+A masters the timebase is the video framerate; both V and
-- A clip rows carry source_in in video frames (master.fps). For
-- audio-only masters master.fps == audio_sample_rate so master.fps frames
-- ARE samples — same field, consistent unit.
local function assert_marks_in_range(medium_label, nested_id, lo, hi, tc_origin, dur)
    local content_end = tc_origin + dur
    assert(lo >= tc_origin and hi <= content_end and hi > lo, string.format(
        "place_shared.apply_nested_marks: nested %s %s marks [%s,%s) "
        .. "out of bounds for TC range [%d,%d)",
        nested_id, medium_label, tostring(lo), tostring(hi),
        tc_origin, content_end))
end

local function apply_nested_marks(nested, mediums, v_dur, a_dur)
    local tc_origin = nested.start_timecode_frame
    assert(tc_origin, string.format(
        "place_shared: nested sequence %s missing start_timecode_frame", nested.id))

    local mark_in, mark_out = nested.mark_in, nested.mark_out
    if mark_in == nil and mark_out == nil then
        -- No marks: take the full media. source_in starts at the master's
        -- TC origin, not 0 — media_refs sit at [tc_origin, tc_origin+span).
        return v_dur, tc_origin, a_dur, tc_origin
    end

    -- Marks already in TC space (master.fps frames). Use directly.
    local lo = mark_in  or tc_origin
    local hi = mark_out or (tc_origin + (mediums.VIDEO and v_dur or a_dur))

    if mediums.VIDEO then
        assert_marks_in_range("video", nested.id, lo, hi, tc_origin, v_dur)
        v_dur = hi - lo
    end
    if mediums.AUDIO then
        assert_marks_in_range("audio", nested.id, lo, hi, tc_origin, a_dur)
        a_dur = hi - lo
    end

    return v_dur, lo, a_dur, lo
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
    -- Audio-only: samples @ master-effective rate → seconds → owner frames.
    -- 018: rate is now per-media_ref; pick via effective_audio_sample_rate helper.
    local seconds = a_dur / Sequence.effective_audio_sample_rate(nested)
    return math.floor(seconds * owner.fps_numerator / owner.fps_denominator + 0.5)
end

-- Route one source channel via the patch table at the current source's
-- shape (count of source tracks of this type; see spec §F2).
-- Returns rec_idx (number) or nil when the channel does not participate.
-- Patches are the sole routing mechanism — no implicit identity.
--   no patch row     → nil (source not routed; channel dropped)
--   patch.enabled=1  → patch.record_track_index
--   patch.enabled=0  → nil (channel dropped)
local function route_via_patch(owner_id, track_type, source_shape, src_idx)
    local Patch = require("models.patch")
    local p = Patch.find_by_source(owner_id, track_type, source_shape, src_idx)
    if not p then return nil end
    if p.enabled == 1 then  -- Patch.save normalizes; INTEGER 0/1 only.
        return p.record_track_index
    end
    return nil
end

-- Build the audio_targets list: one entry per A clip to create. Composite
-- emits 1 entry with NULL master_audio_track_id; expanded emits N entries,
-- one per nested A track that has an enabled patch routing it to a record
-- track. Auto-creates missing owner A tracks for the expanded path;
-- refuses on collision (rule 1.14, FR-023).
-- Ensure an owner track at the patch-dictated `rec_idx` exists, creating
-- it on demand with an explicit `index = rec_idx`. Used by both audio
-- (per-channel) and video (single-target) routing paths. The by-index
-- map is mutated in place so subsequent lookups in the same call hit
-- the cache.
local function ensure_owner_track_at_idx(owner_id, track_type, rec_idx,
                                         by_index, label_fmt)
    local existing = by_index[rec_idx]
    if existing then return existing end
    local creator = (track_type == "AUDIO") and Track.create_audio
                                              or Track.create_video
    local newt = creator(
        string.format(label_fmt, rec_idx), owner_id,
        { id = uuid.generate(), index = rec_idx })
    assert(newt:save(), string.format(
        "place_shared: failed to auto-create owner %s track at index %d "
        .. "on sequence %s", track_type, rec_idx, owner_id))
    by_index[rec_idx] = newt.id
    return newt.id
end

local function compute_audio_targets(owner, nested, drop_mode, args, a_dur,
                                     owner_duration)
    if drop_mode == "composite" then
        return { {
            track_id              = M.pick_target_track(
                owner.id, "AUDIO", args.target_audio_track_id),
            master_audio_track_id = nil,
            source_out            = a_dur,
        } }
    end

    local nested_a = Track.find_by_sequence(nested.id, "AUDIO")
    assert(#nested_a > 0, string.format(
        "place_shared: expanded audio_drop_mode requires nested %s to have "
        .. "at least one A track; got 0", nested.id))
    -- Source audio shape = count of nested audio tracks. Routing rows are
    -- keyed by this shape so a 2-ch boom and a 4-ch surround on the same
    -- owner sequence pick up independent maps (spec §F2 / §2b).
    local audio_shape = #nested_a
    local owner_a_by_index = {}
    for _, t in ipairs(Track.find_by_sequence(owner.id, "AUDIO")) do
        owner_a_by_index[t.track_index] = t.id
    end

    local targets = {}
    for _, nt in ipairs(nested_a) do
        local rec_idx = route_via_patch(owner.id, "AUDIO", audio_shape, nt.track_index)
        if rec_idx ~= nil then
            local owner_track_id = ensure_owner_track_at_idx(
                owner.id, "AUDIO", rec_idx, owner_a_by_index, "Audio %d")
            targets[#targets + 1] = {
                track_id              = owner_track_id,
                master_audio_track_id = nt.id,
                source_out            = a_dur,
            }
        end
    end

    -- Caller-side collision handling: Insert ripples the routed tracks
    -- forward before write_clips; Overwrite occludes (delete/trim/split).
    -- A pre-emptive refusal here would defeat both — and would break F10
    -- / F9 on any non-empty timeline. Auto-created tracks are empty by
    -- construction so they need no check either.
    return targets
end

-- Pick the owner VIDEO target via patches at the source's V-shape.
-- Mirror of compute_audio_targets' expanded path, but video is a single
-- clip per Insert so we return one track_id (or nil to drop video).
-- Explicit target_video_track_id wins (per pick_target_track contract).
local function compute_video_target(owner, nested, args)
    if args.target_video_track_id and args.target_video_track_id ~= "" then
        return M.pick_target_track(
            owner.id, "VIDEO", args.target_video_track_id)
    end
    local nested_v = Track.find_by_sequence(nested.id, "VIDEO")
    assert(#nested_v > 0, string.format(
        "place_shared: nested %s has VIDEO medium but no V tracks", nested.id))
    -- Multi-source-video would require expanded-style multi-V-clip writes
    -- (analogous to expanded audio). Out of scope until a test/spec needs it.
    assert(#nested_v == 1, string.format(
        "place_shared: multi-source-video routing not yet supported "
        .. "(nested %s has %d V tracks). Pass target_video_track_id to override.",
        nested.id, #nested_v))
    local video_shape = #nested_v
    local rec_idx = route_via_patch(
        owner.id, "VIDEO", video_shape, nested_v[1].track_index)
    if rec_idx == nil then return nil end  -- no patch or disabled → drop video
    local owner_v_by_index = {}
    for _, t in ipairs(Track.find_by_sequence(owner.id, "VIDEO")) do
        owner_v_by_index[t.track_index] = t.id
    end
    return ensure_owner_track_at_idx(
        owner.id, "VIDEO", rec_idx, owner_v_by_index, "V%d")
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
    local owner, nested = pick_endpoints(args)
    local policy        = M.pick_policy(args.fps_mismatch_policy, owner)

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
        -- Patch-routed video target. May be nil when the source V channel's
        -- patch is disabled or absent — in which case no V clip is written
        -- (audio-only edit). Per spec §F2 patches are sole routing.
        targets.VIDEO = compute_video_target(owner, nested, args)
    end

    -- Default = "expanded": patches drive per-channel audio routing (spec §F2).
    -- Callers that want the legacy mixdown behavior pass "composite" explicitly.
    local drop_mode = args.audio_drop_mode or "expanded"
    assert(drop_mode == "composite" or drop_mode == "expanded", string.format(
        "place_shared: audio_drop_mode must be 'composite' or 'expanded'; "
        .. "got %s", tostring(drop_mode)))
    -- Always a table — empty when no AUDIO medium. plan.audio_targets is a
    -- contract: callers (Insert, Overwrite) iterate it directly without nil
    -- guards (rule 2.13).
    local audio_targets = {}
    if mediums.AUDIO then
        audio_targets = compute_audio_targets(
            owner, nested, drop_mode, args, a_dur, owner_duration)
    end

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
        start_frame      = args.sequence_start_frame,
    }
end

--- Collect every owner-side track that will receive a clip from this plan
--- — VIDEO (when present) plus each entry's track_id in plan.audio_targets,
--- de-duplicated (multiple source channels may stack onto one rec row per
--- spec §F2 FR-010a). Order: VIDEO first, then audio targets in plan order.
---
--- Insert.execute iterates this list for split+ripple; Overwrite.execute
--- iterates it for occlude. Centralizing the walk here means a future
--- plan-extending medium (subtitles, etc.) only touches plan_placement +
--- this helper, not every command.
function M.iter_target_track_ids(plan)
    assert(type(plan.audio_targets) == "table",
        "place_shared.iter_target_track_ids: plan.audio_targets missing")
    local ids = {}
    if plan.targets.VIDEO then
        ids[#ids + 1] = plan.targets.VIDEO
    end
    local seen = {}
    for _, tgt in ipairs(plan.audio_targets) do
        if not seen[tgt.track_id] then
            seen[tgt.track_id] = true
            ids[#ids + 1] = tgt.track_id
        end
    end
    return ids
end

-- Optional preset_ids let callers (e.g. command redo replaying a
-- persisted execute) pin the new clip ids so undo/redo round-trip
-- without churning uuids. preset_ids[1] is consumed for the video clip
-- (when there is one) and the remaining entries feed the audio clip
-- loop in order; new uuids fill the unfilled slots.
local function make_id_supplier(plan)
    local preset_ids = plan.preset_ids or {}
    local idx = 0
    return function()
        idx = idx + 1
        return preset_ids[idx] or uuid.generate()
    end
end

local function insert_video_clip(plan, next_id)
    local v_in = plan.video_source_in
    assert(v_in, "place_shared.write_clips: video target without video_source_in")
    return Clip.create({
        id                    = next_id(),
        project_id            = plan.owner.project_id,
        owner_sequence_id     = plan.owner.id,
        track_id              = plan.targets.VIDEO,
        sequence_id    = plan.nested.id,
        name                  = plan.base_name,
        sequence_start_frame  = plan.start_frame,
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
end

-- 018 FR-008 / FR-025: convert plan-internal (samples, sample_count) into
-- canonical (master.fps frame, ticks subframe) at the clip write boundary.
-- plan.audio_source_in is in SAMPLES at the nested master's effective audio
-- rate; tgt.source_out is the sample count. Resolver expects master.fps
-- frames + sample residual carried in source_*_subframe.
local function convert_audio_samples_to_frame_subframe(plan, samples)
    local rate = Sequence.effective_audio_sample_rate(plan.nested)
    assert(rate and rate > 0, string.format(
        "place_shared.insert_audio_clips: nested %s has no effective audio "
        .. "rate (FR-008 conversion needs it)", tostring(plan.nested.id)))
    local proj = assert(Project.load(plan.owner.project_id), string.format(
        "place_shared.insert_audio_clips: project %s not found",
        tostring(plan.owner.project_id)))
    local mch = proj:get_master_clock_hz()
    local tpf = subframe_math.ticks_per_frame(mch,
        plan.nested.fps_numerator, plan.nested.fps_denominator)
    local ticks = subframe_math.samples_to_ticks(samples, rate, mch)
    -- Lua multi-return truncation gotcha: `return f(...), x` keeps only the
    -- first return of f. Capture explicitly.
    local frame, sub = subframe_math.unpack(ticks, tpf)
    return frame, sub
end

local function insert_audio_clips(plan, next_id)
    local audio_targets = plan.audio_targets
    if not audio_targets or #audio_targets == 0 then return {} end
    local a_in_samples = plan.audio_source_in
    assert(a_in_samples, "place_shared.write_clips: audio targets without audio_source_in")

    -- Convert the source_in offset once (same for every audio target).
    local in_frame, in_sub = convert_audio_samples_to_frame_subframe(plan, a_in_samples)

    local ids = {}
    for _, tgt in ipairs(audio_targets) do
        -- tgt.source_out is the source range in SAMPLES from the plan;
        -- absolute file-sample boundary is a_in_samples + tgt.source_out.
        local out_frame, out_sub = convert_audio_samples_to_frame_subframe(
            plan, a_in_samples + tgt.source_out)
        ids[#ids + 1] = Clip.create({
            id                    = next_id(),
            project_id            = plan.owner.project_id,
            owner_sequence_id     = plan.owner.id,
            track_id              = tgt.track_id,
            sequence_id           = plan.nested.id,
            name                  = plan.base_name,
            sequence_start_frame  = plan.start_frame,
            duration_frames       = plan.owner_duration,
            source_in_frame       = in_frame,
            source_out_frame      = out_frame,
            source_in_subframe    = in_sub,
            source_out_subframe   = out_sub,
            master_layer_track_id = nil,
            master_audio_track_id = tgt.master_audio_track_id,
            fps_mismatch_policy   = plan.policy,
            enabled               = true,
            volume                = 1.0,
            playhead_frame        = 0,
        })
    end
    return ids
end

-- Group V + every A together. Caller guarantees both mediums landed.
local function link_video_with_audio(v_clip_id, a_clip_ids)
    local entries = {
        { clip_id = v_clip_id, role = "video", time_offset = 0 },
    }
    for _, aid in ipairs(a_clip_ids) do
        entries[#entries + 1] = {
            clip_id = aid, role = "audio", time_offset = 0,
        }
    end
    local link_group_id = clip_link.create_link_group(entries)
    assert(link_group_id and link_group_id ~= "",
        "place_shared: clip_link.create_link_group returned empty id")
    return link_group_id
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
    local next_id  = make_id_supplier(plan)
    local v_clip_id
    if plan.targets.VIDEO then
        v_clip_id = insert_video_clip(plan, next_id)
    end
    local a_clip_ids = insert_audio_clips(plan, next_id)

    local created_list = {}
    if v_clip_id then created_list[#created_list + 1] = v_clip_id end
    for _, aid in ipairs(a_clip_ids) do
        created_list[#created_list + 1] = aid
    end

    local link_group_id
    if v_clip_id and #a_clip_ids > 0 then
        link_group_id = link_video_with_audio(v_clip_id, a_clip_ids)
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
            sequence_start_frame = e.sequence_start_frame,
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
    local new_duration = n_start - e.sequence_start_frame
    local source_delta = owner_to_source_delta(
        e, owner_seq, nested, e.duration_frames - new_duration)
    local snap = snapshot_bounds(e)
    Clip.update_bounds(e.id,
        e.sequence_start_frame, new_duration,
        e.source_in_frame, e.source_out_frame - source_delta)
    return { trimmed = snap }
end

local function occlude_trim_head(e, owner_seq, nested, n_end)
    local shift        = n_end - e.sequence_start_frame
    local new_duration = e.duration_frames - shift
    local source_delta = owner_to_source_delta(e, owner_seq, nested, shift)
    local snap = snapshot_bounds(e)
    Clip.update_bounds(e.id,
        n_end, new_duration,
        e.source_in_frame + source_delta, e.source_out_frame)
    return { trimmed = snap }
end

local function occlude_split_middle(e, owner_seq, nested, n_start, n_end)
    local e_end           = e.sequence_start_frame + e.duration_frames
    local left_duration   = n_start - e.sequence_start_frame
    local right_duration  = e_end - n_end
    local left_source_delta = owner_to_source_delta(
        e, owner_seq, nested, e.duration_frames - left_duration)
    local right_source_delta = owner_to_source_delta(
        e, owner_seq, nested, n_end - e.sequence_start_frame)
    local snap = snapshot_bounds(e)
    Clip.update_bounds(e.id,
        e.sequence_start_frame, left_duration,
        e.source_in_frame, e.source_out_frame - left_source_delta)
    -- 018 FR-014: split must preserve any pre-existing subframe through the
    -- right half. Inherit verbatim from e (which already carries them as
    -- loaded by database.load_clips).
    local right_id = Clip.create({
        id                    = uuid.generate(),
        project_id            = e.project_id,
        owner_sequence_id     = e.owner_sequence_id,
        track_id              = e.track_id,
        sequence_id    = e.sequence_id,
        name                  = e.name,
        sequence_start_frame  = n_end,
        duration_frames       = right_duration,
        source_in_frame       = e.source_in_frame + right_source_delta,
        source_out_frame      = e.source_out_frame,
        source_in_subframe    = e.source_in_subframe,
        source_out_subframe   = e.source_out_subframe,
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
        local nested = Sequence.find(e.sequence_id)
        assert(nested, string.format(
            "place_shared.occlude_track: nested %s of clip %s not found",
            tostring(e.sequence_id), tostring(e.id)))
        local e_end = e.sequence_start_frame + e.duration_frames
        local kind  = classify_overlap(e.sequence_start_frame, e_end, n_start, n_end)
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
                .. "E=[%d,%d) N=[%d,%d)", e.id, e.sequence_start_frame, e_end,
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
--- (sequence_start < position < sequence_start + duration) into a left
--- half ending at position and a right half starting at position. The
--- caller's subsequent ripple_track_forward(track_id, position, shift)
--- picks up the new right-half (its sequence_start_frame == position) and
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
        local e_start = e.sequence_start_frame
        local e_end   = e_start + e.duration_frames
        if e_start < position and e_end > position then
            local nested = Sequence.find(e.sequence_id)
            assert(nested, string.format(
                "place_shared.split_track_at_insertion: nested %s of clip %s not found",
                tostring(e.sequence_id), tostring(e.id)))

            local left_duration  = position - e_start
            local right_duration = e_end - position
            local source_offset  = Clip.owner_delta_to_source(
                e.fps_mismatch_policy, left_duration,
                owner_seq.fps_numerator, owner_seq.fps_denominator,
                nested.fps_numerator,    nested.fps_denominator)

            trimmed[#trimmed + 1] = {
                id = e.id,
                prior = {
                    sequence_start_frame = e.sequence_start_frame,
                    duration_frames      = e.duration_frames,
                    source_in_frame      = e.source_in_frame,
                    source_out_frame     = e.source_out_frame,
                },
            }

            -- Atomic order matters for the video-overlap trigger: shrink
            -- the left half first (frees [position, e_end)), then create
            -- the right half into that freed range. Mirrors split_clip.lua.
            Clip.update_bounds(e.id,
                e.sequence_start_frame, left_duration,
                e.source_in_frame, e.source_in_frame + source_offset)

            local right_id = uuid.generate()
            Clip._create_v13_row({
                id                    = right_id,
                project_id            = e.project_id,
                owner_sequence_id     = e.owner_sequence_id,
                track_id              = e.track_id,
                sequence_id    = e.sequence_id,
                name                  = e.name,
                sequence_start_frame  = position,
                duration_frames       = right_duration,
                source_in_frame       = e.source_in_frame + source_offset,
                source_out_frame      = e.source_out_frame,
                -- 018 FR-014: split preserves any pre-existing subframe.
                source_in_subframe    = e.source_in_subframe,
                source_out_subframe   = e.source_out_subframe,
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
