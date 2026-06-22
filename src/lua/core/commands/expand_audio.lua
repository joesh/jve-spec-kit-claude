--- ExpandAudio command (Feature 013, T056i).
---
--- Per FR-023 + contracts/commands.md §ExpandAudio:
---   Args: { sequence_id, clip_id }. sequence_id is the clip's
---     owner_sequence_id (rule 2.29).
---
---   Pre (refusals — rule 1.14, no partial DB state):
---     * clip exists.
---     * clip.owner_sequence_id == sequence_id.
---     * clip is on an AUDIO track (only audio clips can be expanded).
---     * clip.master_audio_track_id IS NULL (already-expanded refuses).
---     * Nested sequence has >= 2 audio tracks ("nothing to expand").
---     * No collision: every owner A target track empty across the
---       source clip's [sequence_start, sequence_start + duration).
---
---   Mutation:
---     1. For each A track of the nested sequence (sorted by index):
---        ensure the owner has a matching A track at that index
---        (auto-create if missing — non-destructive); INSERT a per-
---        track A clip with master_audio_track_id = nested track id,
---        mirroring the source's window/policy.
---     2. Source clip's link_group: append every expanded A clip; if
---        no link_group existed, create one containing only the
---        expanded clips.
---     3. Project per-channel overrides: for each
---        clip_channel_override(source.id, ch=N), copy the override
---        onto the Nth expanded clip's channel 0 (first-landing scope:
---        1-channel-per-track masters). Multi-channel-per-track masters
---        are a follow-up.
---     4. DELETE the source clip + its overrides + its link_group entry.
---
---   Undo: full restoration via Clip.restore_state on the source +
---   reverse of the above.
---
--- @file expand_audio.lua

local M = {}

local Clip       = require("models.clip")
local ClipLink   = require("models.clip_link")
local Override   = require("models.clip_channel_override")
local Sequence   = require("models.sequence")
local Track      = require("models.track")
local uuid       = require("uuid")
local log        = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "ExpandAudio: '%s' is required (rule 2.29)", name))
    return v
end

-- Validate the source clip: exists on this sequence, is on an audio track,
-- not already expanded, and the nested sequence has ≥2 audio tracks.
-- Returns the loaded clip row.
local function validate_source_clip(sequence_id, clip_id)
    local clip = Clip.load_row(clip_id)
    assert(clip, string.format("ExpandAudio: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "ExpandAudio: sequence_id mismatch — clip %s owner=%s args=%s "
        .. "(rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    local source_track = Track.load(clip.track_id)
    assert(source_track, string.format(
        "ExpandAudio: clip %s track %s not found", clip_id, tostring(clip.track_id)))
    assert(source_track.track_type == "AUDIO", string.format(
        "ExpandAudio: clip %s is on a %s track; ExpandAudio applies only "
        .. "to audio clips.", clip_id, source_track.track_type))
    assert(clip.master_audio_track_id == nil, string.format(
        "ExpandAudio: clip %s is already expanded (master_audio_track_id=%s); "
        .. "nothing to do.", clip_id, tostring(clip.master_audio_track_id)))
    return clip
end

-- Build the per-track placement plan (one entry per nested A track) and
-- check for collisions on the OWNER side. Auto-create cases (no
-- owner_track_id yet) cannot collide. Returns plan[] (entries get
-- owner_track_id filled in here when one already exists).
local function build_placement_plan(clip, clip_id, sequence_id)
    local nested_a = Track.find_by_sequence(clip.sequence_id, "AUDIO")
    assert(#nested_a >= 2, string.format(
        "ExpandAudio: nested sequence %s has %d audio track(s); ExpandAudio "
        .. "requires >= 2 (nothing to expand).",
        clip.sequence_id, #nested_a))
    local owner_a_by_index = {}
    for _, t in ipairs(Track.find_by_sequence(sequence_id, "AUDIO")) do
        owner_a_by_index[t.track_index] = t.id
    end
    local plan = {}
    for _, nt in ipairs(nested_a) do
        plan[#plan + 1] = {
            nested_track_id = nt.id,
            owner_track_id  = owner_a_by_index[nt.track_index],
            track_index     = nt.track_index,
            track_name      = string.format("Audio %d", nt.track_index),
        }
    end

    local outer_lo = clip.sequence_start_frame
    local outer_hi = outer_lo + clip.duration_frames
    for _, p in ipairs(plan) do
        if p.owner_track_id and p.owner_track_id ~= clip.track_id then
            for _, o in ipairs(Clip.find_overlapping_on_track(
                    p.owner_track_id, outer_lo, outer_hi)) do
                if o.id ~= clip_id then
                    error(string.format(
                        "ExpandAudio: collision on owner track %s — existing "
                        .. "clip %s overlaps [%d, %d). Clear the track or "
                        .. "pick another start frame.",
                        p.owner_track_id, o.id, outer_lo, outer_hi))
                end
            end
        end
    end
    return plan
end

-- Past the refusal gate, materialize any plan entries that need their
-- owner A track auto-created. Returns the list of newly-created track ids
-- so the undoer can drop them.
local function auto_create_missing_tracks(plan, sequence_id)
    local created = {}
    for _, p in ipairs(plan) do
        if not p.owner_track_id then
            local newt = Track.create_audio(p.track_name, sequence_id,
                { id = uuid.generate(), index = p.track_index })
            assert(newt:save(), string.format(
                "ExpandAudio: failed to save auto-created A track at index %d",
                p.track_index))
            p.owner_track_id = newt.id
            created[#created + 1] = newt.id
        end
    end
    return created
end

-- Insert one expanded clip per plan entry, each with a distinct
-- master_audio_track_id selector. Returns expanded_ids[] (in plan order)
-- and expanded_by_index[track_index → clip_id].
local function insert_expanded_clips(plan, clip, sequence_id)
    local expanded_ids, by_index = {}, {}
    local outer_lo = clip.sequence_start_frame
    for _, p in ipairs(plan) do
        local new_id = uuid.generate()
        -- 018 FR-014: ExpandAudio creates AUDIO clips; preserve any
        -- subframe from the source clip (frame-aligned input = 0,0).
        Clip.create({
            id                    = new_id,
            project_id            = clip.project_id,
            owner_sequence_id     = sequence_id,
            track_id              = p.owner_track_id,
            sequence_id    = clip.sequence_id,
            name                  = clip.name,
            sequence_start_frame  = outer_lo,
            duration_frames       = clip.duration_frames,
            source_in_frame       = clip.source_in_frame,
            source_out_frame      = clip.source_out_frame,
            source_in_subframe    = clip.source_in_subframe,
            source_out_subframe   = clip.source_out_subframe,
            master_layer_track_id = nil,
            master_audio_track_id = p.nested_track_id,
            fps_mismatch_policy   = clip.fps_mismatch_policy,
            enabled               = clip.enabled,
            volume                = clip.volume,
            playhead_frame        = clip.playhead_frame,
        })
        expanded_ids[#expanded_ids + 1] = new_id
        by_index[p.track_index]         = new_id
    end
    return expanded_ids, by_index
end

-- Append expanded clips to the source's link group, or build a fresh
-- group when source had none and the expansion produced ≥2 clips.
local function relink_expanded_clips(source_lg, expanded_ids)
    if source_lg then
        for _, eid in ipairs(expanded_ids) do
            ClipLink.add_to_group(source_lg, eid, "audio", 0)
        end
        return source_lg
    end
    if #expanded_ids < 2 then return nil end
    local entries = {}
    for _, eid in ipairs(expanded_ids) do
        entries[#entries + 1] = { clip_id = eid, role = "audio", time_offset = 0 }
    end
    return ClipLink.create_link_group(entries)
end

-- Project the source clip's per-channel overrides onto the matching
-- expanded clip. 1-channel-per-track first-landing: source ch=N maps to
-- the expanded clip whose master_audio_track is at track_index N+1, at
-- ch=0 there. Out-of-bounds source channels are dropped (captured in
-- undo via source_capture).
local function project_source_overrides(source_capture, expanded_by_index)
    -- capture_state always populates overrides as an array.
    assert(type(source_capture) == "table" and type(source_capture.overrides) == "table",
        "ExpandAudio: source_capture/overrides missing")
    for _, ov in ipairs(source_capture.overrides) do
        local target_clip_id = expanded_by_index[ov.channel_index + 1]
        if target_clip_id then
            Override.insert({
                clip_id       = target_clip_id,
                channel_index = 0,
                enabled       = ov.enabled,
                gain_db       = ov.gain_db,
            })
        end
    end
end

-- Compact "track 1, track 2, …" string for the event log.
local function track_index_list(plan)
    local out = {}
    for _, p in ipairs(plan) do out[#out + 1] = tostring(p.track_index) end
    return table.concat(out, ",")
end

function M.execute(args)
    assert(type(args) == "table", "ExpandAudio.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")

    local clip = validate_source_clip(sequence_id, clip_id)
    local owner = Sequence.find(sequence_id)
    assert(owner, string.format(
        "ExpandAudio: owner sequence %s not found", sequence_id))

    local plan = build_placement_plan(clip, clip_id, sequence_id)

    -- Past the refusal gate: capture undo, materialize tracks, mutate.
    local source_capture   = Clip.capture_state(clip_id)
    local created_track_ids = auto_create_missing_tracks(plan, sequence_id)
    local source_lg        = ClipLink.get_link_group_id(clip_id)

    -- DELETE source first so its track is free for the matching expanded
    -- clip — the same track is one of the destinations.
    Clip.delete_by_ids({ clip_id })

    local expanded_ids, expanded_by_index = insert_expanded_clips(plan, clip, sequence_id)
    local final_lg = relink_expanded_clips(source_lg, expanded_ids)
    project_source_overrides(source_capture, expanded_by_index)

    log.event("ExpandAudio: clip=%s -> %d expanded clips on tracks [%s]",
        clip_id, #expanded_ids, track_index_list(plan))

    return {
        sequence_id          = sequence_id,
        source_capture       = source_capture,
        source_link_group_id = source_lg,
        expanded_clip_ids    = expanded_ids,
        created_track_ids    = created_track_ids,
        final_link_group_id  = final_lg,
    }
end

function M.undo(capture)
    assert(type(capture) == "table",
        "ExpandAudio.undo: capture table required")

    -- Order:
    --   1. DELETE every expanded clip. The clip_links rows for them
    --      cascade away (so the source's link_group is back to whatever
    --      entries existed pre-expand, e.g. the V clip).
    --   2. DELETE auto-created owner A tracks. The tracks are empty by
    --      now (their only clips were the expanded ones, just deleted).
    --   3. Restore the source via Clip.restore_state — re-INSERTs
    --      the row + overrides + the source's link_group entry.
    -- Execute always populates these arrays (possibly empty).
    Clip.delete_by_ids(capture.expanded_clip_ids)

    for _, tid in ipairs(capture.created_track_ids) do
        Track.delete(tid)
    end

    Clip.restore_state(capture.source_capture)

end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
    },
    persisted = {
        expanded_clip_ids   = {},
        created_track_ids   = {},
        source_capture      = {},
        source_link_group_id = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["ExpandAudio"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("ExpandAudio: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("expanded_clip_ids", cap.expanded_clip_ids)
        command:set_parameter("created_track_ids", cap.created_track_ids)
        command:set_parameter("source_capture",    cap.source_capture)
        return true
    end

    command_undoers["ExpandAudio"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id        = args.sequence_id,
            expanded_clip_ids  = args.expanded_clip_ids,
            created_track_ids  = args.created_track_ids,
            source_capture     = args.source_capture,
        })
        return true
    end

    return {
        executor = command_executors["ExpandAudio"],
        undoer   = command_undoers["ExpandAudio"],
        spec     = SPEC,
    }
end

return M
