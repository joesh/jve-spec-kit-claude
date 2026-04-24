--- Insert command (Feature 013, rewrite per T040).
--
-- Places a master (or nested) sequence as a clip reference onto a
-- non-master ("edit") sequence's track. Does NOT flatten: the inserted
-- clips carry `nested_sequence_id`; playback resolves the chain via
-- Sequence:resolve_in_range (T030). No media_id on clip rows.
--
-- Contract: commands.md §Insert / CT-C1.
-- Data: data-model.md §clips. Invariants INV-2, INV-3, INV-4 enforced.
--
-- Per Insert-at-a-frame, writes 1 or 2 `clips` rows (V and/or A — NOT
-- per-channel; channel overrides live in media_refs_channel_state and
-- clip_channel_override, resolved at playback). If 2 clips are written,
-- they share a single `clip_links.link_group_id`.
--
-- fps_mismatch_policy is frozen on each clip at Insert time; effective
-- value = explicit arg ?? sequence.fps_mismatch_policy ?? project's
-- fps_mismatch_policy (data-model.md §Decisions: structural at Insert).
--
-- Ripple: clips on the target tracks at or past timeline_start_frame
-- shift forward by duration_frames. Other tracks are NOT touched (per
-- commands.md — differs from Overwrite, which occludes target tracks).
--
-- Exports `execute(args)` as a pure-logic entry point exercised by
-- T032's black-box DB test. `register(...)` wires the same logic into
-- command_manager for live-editor use.
--
-- SQL isolation (rule 2.x): this module does not call the database
-- directly; every DB read/write goes through the appropriate model
-- (Project / Sequence / Track / Clip / Clip_Link / Cycle).
--
-- @file insert.lua

local M = {}

local uuid       = require("uuid")
local Project    = require("models.project")
local Sequence   = require("models.sequence")
local Track      = require("models.track")
local Clip       = require("models.clip")
local Cycle      = require("models.cycle")
local clip_link  = require("models.clip_link")
local log        = require("core.logger").for_area("commands")

-- ---------------------------------------------------------------------------
-- Helpers (rule 2.5: orchestrator reads as an algorithm).
-- ---------------------------------------------------------------------------

-- Effective fps-mismatch policy for this Insert. Chain:
--   explicit arg > owner sequence override (non-NULL) > project default.
local function resolve_effective_policy(explicit, owner_seq, project_id)
    if explicit ~= nil then
        assert(explicit == "resample" or explicit == "passthrough", string.format(
            "Insert: fps_mismatch_policy arg must be 'resample' or 'passthrough' (got %s)",
            tostring(explicit)))
        return explicit
    end
    if owner_seq.fps_mismatch_policy ~= nil
       and owner_seq.fps_mismatch_policy ~= "" then
        return owner_seq.fps_mismatch_policy
    end
    return Project.get_fps_mismatch_policy(project_id)
end

-- Duration of the new clip in the owner sequence's timebase under the
-- chosen policy.
--   resample    = round(nested.duration * owner.fps / nested.fps)
--   passthrough = nested.duration  (treated as if already in owner fps)
-- Per data-model.md §Decisions and commands.md §Insert.
local function compute_owner_duration(policy, nested_duration_native,
                                      owner_fps_num, owner_fps_den,
                                      nested_fps_num, nested_fps_den)
    if policy == "passthrough" then
        return nested_duration_native
    end
    assert(policy == "resample",
        "compute_owner_duration: unknown policy " .. tostring(policy))
    -- resample: scale by the fps ratio, round-nearest. Accept sub-frame
    -- wall-clock drift per clip (research.md settled).
    local owner_fps  = owner_fps_num  / owner_fps_den
    local nested_fps = nested_fps_num / nested_fps_den
    local exact = nested_duration_native * owner_fps / nested_fps
    return math.floor(exact + 0.5)
end

-- Pick the owner track for a given medium. Caller-specified track wins; else
-- first track of that type on the owner. Asserts type + ownership (rule 1.14).
local function pick_target_track(owner_id, track_type, explicit_track_id)
    if explicit_track_id and explicit_track_id ~= "" then
        local t = Track.load(explicit_track_id)
        assert(t, string.format(
            "Insert: target %s track %s not found",
            track_type, explicit_track_id))
        assert(t.sequence_id == owner_id, string.format(
            "Insert: target track %s belongs to sequence %s, not %s",
            explicit_track_id, tostring(t.sequence_id), owner_id))
        assert(t.track_type == track_type, string.format(
            "Insert: target track %s is %s, expected %s",
            explicit_track_id, tostring(t.track_type), track_type))
        return explicit_track_id
    end
    local tracks = Track.find_by_sequence(owner_id, track_type)
    assert(tracks and #tracks > 0, string.format(
        "Insert: nested has %s but owner %s has no %s track",
        track_type, owner_id, track_type))
    return tracks[1].id
end

-- Insert one V9 clip row via Clip.create's table form.
local function insert_clip_row(args)
    return Clip.create({
        id                    = args.id or uuid.generate(),
        project_id            = args.project_id,
        owner_sequence_id     = args.owner_sequence_id,
        track_id              = args.track_id,
        nested_sequence_id    = args.nested_sequence_id,
        name                  = args.name,
        timeline_start_frame  = args.timeline_start_frame,
        duration_frames       = args.duration_frames,
        source_in_frame       = args.source_in_frame,
        source_out_frame      = args.source_out_frame,
        master_layer_track_id = nil,  -- NULL = inherit nested seq's default layer
        fps_mismatch_policy   = args.fps_mismatch_policy,
        enabled               = true,
        volume                = 1.0,
        mark_in_frame         = nil,
        mark_out_frame        = nil,
        playhead_frame        = 0,
    })
end

-- ---------------------------------------------------------------------------
-- M.execute — pure-logic entry point (rule 2.5 orchestrator).
-- ---------------------------------------------------------------------------

-- Args:
--   sequence_id (required)            : owner edit sequence (kind='nested')
--   nested_sequence_id (required)     : the sequence being placed (any kind)
--   timeline_start_frame (required)   : integer, owner-timebase frame
--   target_video_track_id (optional)  : if absent, first V track on owner
--   target_audio_track_id (optional)  : if absent, first A track on owner
--   fps_mismatch_policy (optional)    : explicit override
--   clip_name (optional)              : label for the new clip rows
--
-- Returns:
--   {
--     created_clip_ids     = { v = <id>?, a = <id>?, list = {<id>, ...} },
--     link_group_id        = <id> | nil,
--     duration_frames      = <int>,
--     fps_mismatch_policy  = <resolved>,
--     rippled              = { [track_id] = { shift, from_frame, clip_ids = {...} } },
--   }
function M.execute(args)
    assert(type(args) == "table", "Insert.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "Insert.execute: sequence_id required")
    assert(args.nested_sequence_id and args.nested_sequence_id ~= "",
        "Insert.execute: nested_sequence_id required")
    assert(type(args.timeline_start_frame) == "number",
        "Insert.execute: timeline_start_frame must be integer")
    local start_frame = args.timeline_start_frame
    assert(start_frame >= 0, "Insert.execute: timeline_start_frame must be >= 0")

    -- Load owner + nested rows. INV-2 precondition: owner must be 'nested'.
    local owner  = Sequence.find(args.sequence_id)
    assert(owner, string.format(
        "Insert: owner sequence %s not found", args.sequence_id))
    local nested = Sequence.find(args.nested_sequence_id)
    assert(nested, string.format(
        "Insert: nested sequence %s not found", args.nested_sequence_id))
    assert(owner.kind == "nested", string.format(
        "Insert: owner sequence %s has kind='%s' (expected 'nested'; "
        .. "can only insert into non-master sequences — INV-2)",
        owner.id, owner.kind))
    assert(owner.project_id == nested.project_id, string.format(
        "Insert: owner project %s != nested project %s",
        tostring(owner.project_id), tostring(nested.project_id)))

    -- INV-3: cycle check at mutation time. Refuse if this edge would
    -- close a cycle (research.md §3; also guarded at resolve time).
    if Cycle.would_create_cycle(owner.id, nested.id) then
        error(string.format(
            "Insert: would create a cycle — sequence %s is already reachable "
            .. "from %s via clips.nested_sequence_id", nested.id, owner.id))
    end

    local policy = resolve_effective_policy(
        args.fps_mismatch_policy, owner, owner.project_id)

    -- Discover which mediums the nested sequence contributes.
    local mediums = Sequence.contained_mediums(nested.id)
    assert(next(mediums) ~= nil, string.format(
        "Insert: nested sequence %s has no mediums (no media_refs or clips)",
        nested.id))

    -- Per-medium native durations. VIDEO is in nested's video frames; AUDIO
    -- is in nested's audio samples (different units; carried separately).
    local video_native_dur = mediums.VIDEO
        and Sequence.native_duration_for_medium(nested.id, "VIDEO") or 0
    local audio_native_dur = mediums.AUDIO
        and Sequence.native_duration_for_medium(nested.id, "AUDIO") or 0
    if mediums.VIDEO then
        assert(video_native_dur > 0, string.format(
            "Insert: nested sequence %s has VIDEO tracks but zero video duration",
            nested.id))
    end
    if mediums.AUDIO then
        assert(audio_native_dur > 0, string.format(
            "Insert: nested sequence %s has AUDIO tracks but zero audio duration",
            nested.id))
    end

    -- Owner-timebase duration shared by V and A clips (linked-pair A/V sync
    -- requires identical owner-timeline spans). Derive from the video
    -- dimension when available (video frame count is the canonical link
    -- timebase); fall back to audio when the nested is audio-only.
    local owner_duration
    if mediums.VIDEO then
        owner_duration = compute_owner_duration(
            policy, video_native_dur,
            owner.fps_numerator, owner.fps_denominator,
            nested.fps_numerator, nested.fps_denominator)
    else
        -- Audio-only master. Convert audio samples @ nested audio_rate
        -- into owner video frames: seconds * owner_fps.
        local seconds = audio_native_dur / nested.audio_rate
        owner_duration = math.floor(
            seconds * owner.fps_numerator / owner.fps_denominator + 0.5)
    end
    assert(owner_duration > 0, "Insert: computed owner duration <= 0")

    local targets = {}
    if mediums.VIDEO then
        targets.VIDEO = pick_target_track(
            owner.id, "VIDEO", args.target_video_track_id)
    end
    if mediums.AUDIO then
        targets.AUDIO = pick_target_track(
            owner.id, "AUDIO", args.target_audio_track_id)
    end

    -- Ripple target tracks before the new INSERTs so we don't collide with
    -- an existing clip at start_frame.
    local rippled = {}
    for _, track_id in pairs(targets) do
        local ids = Clip.ripple_track_forward(track_id, start_frame, owner_duration)
        if #ids > 0 then
            rippled[track_id] = {
                shift = owner_duration,
                from_frame = start_frame,
                clip_ids = ids,
            }
        end
    end

    -- Clip name. Prefer caller-supplied; else the nested sequence's name
    -- (authoritative source, not a fallback default).
    local base_name = args.clip_name
    if not base_name or base_name == "" then
        base_name = Sequence.get_name(nested.id)
    end
    assert(base_name and base_name ~= "",
        "Insert: could not derive a non-empty clip name")

    -- Insert one clips row per medium. Both rows share the same source
    -- window [0, nested_duration_native] and the same owner-timebase
    -- window [start_frame, start_frame + owner_duration).
    local created_list = {}
    local v_clip_id, a_clip_id
    if targets.VIDEO then
        v_clip_id = insert_clip_row({
            project_id           = owner.project_id,
            owner_sequence_id    = owner.id,
            track_id             = targets.VIDEO,
            nested_sequence_id   = nested.id,
            name                 = base_name,
            timeline_start_frame = start_frame,
            duration_frames      = owner_duration,
            source_in_frame      = 0,
            source_out_frame     = video_native_dur,
            fps_mismatch_policy  = policy,
        })
        created_list[#created_list + 1] = v_clip_id
    end
    if targets.AUDIO then
        a_clip_id = insert_clip_row({
            project_id           = owner.project_id,
            owner_sequence_id    = owner.id,
            track_id             = targets.AUDIO,
            nested_sequence_id   = nested.id,
            name                 = base_name,
            timeline_start_frame = start_frame,
            duration_frames      = owner_duration,
            source_in_frame      = 0,
            source_out_frame     = audio_native_dur,
            fps_mismatch_policy  = policy,
        })
        created_list[#created_list + 1] = a_clip_id
    end

    -- Link group iff both mediums landed.
    local link_group_id
    if v_clip_id and a_clip_id then
        link_group_id = clip_link.create_link_group({
            { clip_id = v_clip_id, role = "video", time_offset = 0 },
            { clip_id = a_clip_id, role = "audio", time_offset = 0 },
        })
        assert(link_group_id and link_group_id ~= "",
            "Insert: clip_link.create_link_group returned empty id")
    end

    log.event("Insert: owner=%s nested=%s policy=%s duration=%d clips=%d",
        owner.id, nested.id, policy, owner_duration, #created_list)

    return {
        created_clip_ids    = created_list,
        video_clip_id       = v_clip_id,
        audio_clip_id       = a_clip_id,
        link_group_id       = link_group_id,
        duration_frames     = owner_duration,
        fps_mismatch_policy = policy,
        rippled             = rippled,
    }
end

-- ---------------------------------------------------------------------------
-- M.register — command_manager wiring.
-- ---------------------------------------------------------------------------
-- The registered executor delegates to M.execute and captures enough state
-- for the undoer to reverse (delete inserted clips, reverse ripple, drop
-- link_group). __timeline_mutations is populated so command_manager's
-- post-commit UI-cache update doesn't assert.

local SPEC = {
    args = {
        sequence_id           = { required = true },
        nested_sequence_id    = { required = true },
        timeline_start_frame  = { required = true },
        target_video_track_id = {},
        target_audio_track_id = {},
        fps_mismatch_policy   = {},
        clip_name             = {},
    },
    persisted = {
        created_clip_ids       = {},
        created_link_group_id  = "",
        rippled_capture        = {},
        duration_frames        = 0,
        fps_mismatch_policy    = "",
    },
}

local function build_insert_mutation_entry(clip_id)
    local row = Clip.load_v13_row(clip_id)
    assert(row, "Insert: could not re-read inserted clip " .. tostring(clip_id))
    return {
        id                    = row.id,
        owner_sequence_id     = row.owner_sequence_id,
        track_sequence_id     = row.owner_sequence_id,
        track_id              = row.track_id,
        nested_sequence_id    = row.nested_sequence_id,
        start_value           = row.timeline_start_frame,
        timeline_start        = row.timeline_start_frame,
        duration_value        = row.duration_frames,
        duration              = row.duration_frames,
        source_in             = row.source_in_frame,
        source_out            = row.source_out_frame,
        master_layer_track_id = row.master_layer_track_id,
        fps_mismatch_policy   = row.fps_mismatch_policy,
        name                  = row.name,
        enabled               = row.enabled,
        volume                = row.volume,
        playhead_frame        = row.playhead_frame,
    }
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Insert"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Insert: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        local result = result_or_err

        command:set_parameter("created_clip_ids",     result.created_clip_ids)
        command:set_parameter("created_link_group_id", result.link_group_id or "")
        command:set_parameter("rippled_capture",      result.rippled)
        command:set_parameter("duration_frames",      result.duration_frames)
        command:set_parameter("fps_mismatch_policy",  result.fps_mismatch_policy)

        local bucket = {
            sequence_id = args.sequence_id,
            inserts = {},
            updates = {},
            deletes = {},
            bulk_shifts = {},
        }
        for _, cid in ipairs(result.created_clip_ids) do
            bucket.inserts[#bucket.inserts + 1] = build_insert_mutation_entry(cid)
        end
        for track_id, rip in pairs(result.rippled) do
            bucket.bulk_shifts[#bucket.bulk_shifts + 1] = {
                track_id     = track_id,
                shift_frames = rip.shift,
                start_frame  = rip.from_frame,
            }
        end
        command:set_parameter("__timeline_mutations", bucket)

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        return true
    end

    command_undoers["Insert"] = function(command)
        local args = command:get_all_parameters()
        local created_ids   = args.created_clip_ids or {}
        local link_group_id = args.created_link_group_id
        local rippled       = args.rippled_capture or {}

        -- clip_links.clip_id has ON DELETE CASCADE, so deleting the clip
        -- rows implicitly removes the link_group rows; no explicit drop
        -- needed. link_group_id stays in undo state for redo to re-establish.
        local _unused_here = link_group_id  -- luacheck: ignore 211
        Clip.delete_by_ids(created_ids)

        -- Reverse ripple by the captured ids (not by re-querying — the new
        -- clip is gone, but the from_frame would sweep in others).
        for _, rip in pairs(rippled) do
            if rip.clip_ids and #rip.clip_ids > 0 then
                Clip.shift_many_by(rip.clip_ids, -rip.shift)
            end
        end

        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)

        return true
    end

    return {
        executor = command_executors["Insert"],
        undoer   = command_undoers["Insert"],
        spec     = SPEC,
    }
end

return M
