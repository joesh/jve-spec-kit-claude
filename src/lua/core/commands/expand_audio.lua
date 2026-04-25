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
---       source clip's [timeline_start, timeline_start + duration).
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
---   Undo: full restoration via Clip.restore_v13_state on the source +
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

function M.execute(args)
    assert(type(args) == "table", "ExpandAudio.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")

    local clip = Clip.load_v13_row(clip_id)
    assert(clip, string.format(
        "ExpandAudio: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "ExpandAudio: sequence_id mismatch — clip %s owner=%s args=%s "
        .. "(rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))

    -- Track-type check: clip must be on an AUDIO track.
    local source_track = Track.load(clip.track_id)
    assert(source_track, string.format(
        "ExpandAudio: clip %s track %s not found",
        clip_id, tostring(clip.track_id)))
    assert(source_track.track_type == "AUDIO", string.format(
        "ExpandAudio: clip %s is on a %s track; ExpandAudio applies only "
        .. "to audio clips.", clip_id, source_track.track_type))

    -- Already-expanded refuses.
    assert(clip.master_audio_track_id == nil, string.format(
        "ExpandAudio: clip %s is already expanded "
        .. "(master_audio_track_id=%s); nothing to do.",
        clip_id, tostring(clip.master_audio_track_id)))

    -- Nested must have >= 2 audio tracks.
    local nested_a = Track.find_by_sequence(clip.nested_sequence_id, "AUDIO") or {}
    assert(#nested_a >= 2, string.format(
        "ExpandAudio: nested sequence %s has %d audio track(s); "
        .. "ExpandAudio requires >= 2 (nothing to expand).",
        clip.nested_sequence_id, #nested_a))

    local owner = Sequence.find(sequence_id)
    assert(owner, string.format(
        "ExpandAudio: owner sequence %s not found", sequence_id))

    -- Plan the per-track destinations: for each nested A track, the
    -- matching-index owner A track (auto-create if missing). We resolve
    -- destinations BEFORE any DB mutation so refusals stay clean.
    local owner_a = Track.find_by_sequence(sequence_id, "AUDIO") or {}
    local owner_a_by_index = {}
    for _, t in ipairs(owner_a) do
        owner_a_by_index[t.track_index] = t.id
    end
    local plan = {}   -- list of { nested_track_id, owner_track_id, owner_track_was_created }
    for _, nt in ipairs(nested_a) do
        local existing = owner_a_by_index[nt.track_index]
        plan[#plan + 1] = {
            nested_track_id          = nt.id,
            owner_track_id           = existing,   -- nil if auto-create needed
            owner_track_was_created  = false,
            track_index              = nt.track_index,
            track_name               = string.format("Audio %d", nt.track_index),
        }
    end

    -- Collision check on existing owner A tracks. Auto-create targets
    -- can't collide because the track doesn't exist yet.
    local outer_lo = clip.timeline_start_frame
    local outer_hi = outer_lo + clip.duration_frames
    for _, p in ipairs(plan) do
        if p.owner_track_id and p.owner_track_id ~= clip.track_id then
            local overlapping = Clip.find_overlapping_on_track(
                p.owner_track_id, outer_lo, outer_hi)
            for _, o in ipairs(overlapping) do
                if o.id ~= clip_id then
                    error(string.format(
                        "ExpandAudio: collision on owner track %s — "
                        .. "existing clip %s overlaps [%d, %d). Clear the "
                        .. "track or pick another start frame.",
                        p.owner_track_id, o.id, outer_lo, outer_hi))
                end
            end
        end
    end

    -- All refusal cases passed. Capture undo state.
    local source_capture = Clip.capture_v13_state(clip_id)

    -- Auto-create owner A tracks where missing. (Past the refusal gate
    -- so a partial create-then-fail is impossible.)
    local created_track_ids = {}
    for _, p in ipairs(plan) do
        if not p.owner_track_id then
            local newt = Track.create_audio(p.track_name, sequence_id,
                { id = uuid.generate(), index = p.track_index })
            assert(newt:save(), string.format(
                "ExpandAudio: failed to save auto-created A track at index %d",
                p.track_index))
            p.owner_track_id          = newt.id
            p.owner_track_was_created = true
            created_track_ids[#created_track_ids + 1] = newt.id
        end
    end

    -- Source's link group (may be nil).
    local source_lg = ClipLink.get_link_group_id(clip_id)

    -- DELETE source FIRST so its track is empty for the expanded clip
    -- on that same track (the source's track is one of the A tracks
    -- the expanded set will reuse — collision-free pre-condition relies
    -- on source being gone).
    Clip.delete_by_ids({ clip_id })

    -- INSERT one expanded clip per nested A track.
    local expanded_ids = {}
    local expanded_by_index = {}    -- track_index -> clip_id
    for _, p in ipairs(plan) do
        local new_id = uuid.generate()
        Clip.create({
            id                    = new_id,
            project_id            = clip.project_id,
            owner_sequence_id     = sequence_id,
            track_id              = p.owner_track_id,
            nested_sequence_id    = clip.nested_sequence_id,
            name                  = clip.name,
            timeline_start_frame  = outer_lo,
            duration_frames       = clip.duration_frames,
            source_in_frame       = clip.source_in_frame,
            source_out_frame      = clip.source_out_frame,
            master_layer_track_id = nil,
            master_audio_track_id = p.nested_track_id,
            fps_mismatch_policy   = clip.fps_mismatch_policy,
            enabled               = clip.enabled,
            volume                = clip.volume,
            playhead_frame        = clip.playhead_frame,
        })
        expanded_ids[#expanded_ids + 1] = new_id
        expanded_by_index[p.track_index] = new_id
    end

    -- Re-link: append every expanded clip into the source's link_group,
    -- or create a new one with just the expanded clips (no V to share
    -- with — first-landing semantics).
    local final_lg = source_lg
    if final_lg then
        for _, eid in ipairs(expanded_ids) do
            ClipLink.add_to_group(final_lg, eid, "audio", 0)
        end
    elseif #expanded_ids >= 2 then
        local entries = {}
        for _, eid in ipairs(expanded_ids) do
            entries[#entries + 1] = {
                clip_id = eid, role = "audio", time_offset = 0,
            }
        end
        final_lg = ClipLink.create_link_group(entries)
    end

    -- Project per-channel overrides from source onto expanded clips.
    -- Source channel index N maps to the (N+1)th nested A track in the
    -- resolver's enumeration order (sort by track_index ASC). For
    -- 1-channel-per-track masters (first-landing scope) this means
    -- override(source, ch=N) → override(expanded[track_index=N+1], ch=0).
    local source_overrides = {}
    -- Use the captured state (since the source row is gone). The
    -- capture's `overrides` is an array of { channel_index, enabled, gain_db }.
    if source_capture and source_capture.overrides then
        source_overrides = source_capture.overrides
    end
    for _, ov in ipairs(source_overrides) do
        local target_track_index = ov.channel_index + 1   -- 1-based track index
        local target_clip_id = expanded_by_index[target_track_index]
        if target_clip_id then
            Override.insert({
                clip_id       = target_clip_id,
                channel_index = 0,
                enabled       = ov.enabled,
                gain_db       = ov.gain_db,
            })
        end
        -- If no expanded clip at that track_index (channel_index out of
        -- bounds for the master's track count), the override is dropped.
        -- Captured in undo via source_capture.
    end

    log.event("ExpandAudio: clip=%s -> %d expanded clips on tracks [%s]",
        clip_id, #expanded_ids,
        table.concat((function() local s = {}
            for _, p in ipairs(plan) do s[#s+1] = tostring(p.track_index) end
            return s
        end)(), ","))

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return {
        sequence_id          = sequence_id,
        source_capture       = source_capture,
        source_link_group_id = source_lg,
        expanded_clip_ids    = expanded_ids,
        created_track_ids    = created_track_ids,
        final_link_group_id  = final_lg,
    }
end

function M.undo(_capture)
    error("ExpandAudio.undo: not yet implemented (T056c follow-up). "
        .. "Forward path lands first; full restoration requires "
        .. "Clip.restore_v13_state of the source + reverse of expanded "
        .. "clip / link / track creates.")
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
        source_link_group_id = "",
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
        return true
    end

    command_undoers["ExpandAudio"] = function(_command)
        error("ExpandAudio undo: pending T056c implementation.")
    end

    return {
        executor = command_executors["ExpandAudio"],
        undoer   = command_undoers["ExpandAudio"],
        spec     = SPEC,
    }
end

return M
