--- CollapseAudio command (Feature 013, T056j).
---
--- Per FR-024 + contracts/commands.md §CollapseAudio:
---   Args: { sequence_id, clip_ids }. sequence_id is the common owner;
---     clip_ids is a non-empty list of audio clips (rule 2.29).
---
---   Pre (refusals — rule 1.14):
---     * Selection non-empty.
---     * Every clip exists; owner_sequence_id == sequence_id.
---     * Every clip is on an AUDIO track.
---     * Every clip has non-NULL master_audio_track_id (already-composite
---       refuses — collapse is the inverse of expand).
---     * All share the same nested_sequence_id.
---     * All share the same source_in_frame AND source_out_frame
---       (divergent windows refuse — per-track slip is the genuine
---       expressiveness Expand buys; composite has nowhere to encode it).
---     * All share the same timeline_start_frame AND duration_frames.
---     * All share the same fps_mismatch_policy.
---     * All members of the same link_group_id.
---     * Each clip's master_audio_track_id is distinct.
---
---   Mutation:
---     1. Compute the unselected nested A tracks (= nested.A_tracks
---        minus the selection's master_audio_track_ids).
---     2. DELETE the selected clip rows (cascades clip_channel_override
---        + clip_links rows for each).
---     3. INSERT one composite clip on the topmost selected track
---        (lowest track_index among the selection) with
---        master_audio_track_id=NULL.
---     4. Project per-channel state onto the composite:
---        - Unselected nested track N → INSERT
---          clip_channel_override(composite_id, ch=track_index_of_N - 1,
---          enabled=0, gain_db=0). (1-channel-per-track first-landing.)
---        - Selected clip's per-channel overrides → copy to composite at
---          ch = the original clip's track_index - 1.
---        - Selected clip with non-unity volume → INSERT gain override
---          on composite for that clip's channel(s).
---     5. Re-link: append composite to the (existing) link_group.
---     6. sequence_content_changed(sequence_id).
---
--- First-landing scope: 1-channel-per-track masters (the dominant
--- Scenario-7 / multitrack assembly case). Multi-channel-per-track is
--- a follow-up.
---
--- @file collapse_audio.lua

local M = {}

local Clip       = require("models.clip")
local ClipLink   = require("models.clip_link")
local Override   = require("models.clip_channel_override")
local Track      = require("models.track")
local uuid       = require("uuid")
local log        = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "CollapseAudio: '%s' is required (rule 2.29)", name))
    return v
end

function M.execute(args)
    assert(type(args) == "table", "CollapseAudio.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_ids = args.clip_ids
    assert(type(clip_ids) == "table" and #clip_ids > 0,
        "CollapseAudio: clip_ids must be a non-empty array")

    -- Load all selected clips. Capture each one for undo.
    local selected = {}
    local source_captures = {}
    for _, cid in ipairs(clip_ids) do
        local row = Clip.load_v13_row(cid)
        assert(row, string.format(
            "CollapseAudio: clip %s not found", cid))
        assert(row.owner_sequence_id == sequence_id, string.format(
            "CollapseAudio: clip %s owner=%s != args sequence_id %s "
            .. "(rule 2.29)",
            cid, tostring(row.owner_sequence_id), tostring(sequence_id)))
        local t = Track.load(row.track_id)
        assert(t, string.format(
            "CollapseAudio: clip %s track %s not found", cid, row.track_id))
        assert(t.track_type == "AUDIO", string.format(
            "CollapseAudio: clip %s is on a %s track; only audio clips "
            .. "can be collapsed.", cid, t.track_type))
        assert(row.master_audio_track_id ~= nil, string.format(
            "CollapseAudio: clip %s is already composite "
            .. "(master_audio_track_id IS NULL); nothing to collapse.", cid))
        selected[#selected + 1] = {
            row         = row,
            track_index = t.track_index,
        }
        source_captures[#source_captures + 1] = Clip.capture_v13_state(cid)
    end

    -- Distinct master_audio_track_id check.
    do
        local seen = {}
        for _, s in ipairs(selected) do
            local k = s.row.master_audio_track_id
            assert(not seen[k], string.format(
                "CollapseAudio: selection has two clips with the same "
                .. "master_audio_track_id=%s; each selected clip must point "
                .. "at a distinct nested A track.", tostring(k)))
            seen[k] = true
        end
    end

    -- Same nested + window + policy + link_group.
    local first = selected[1].row
    local first_lg = ClipLink.get_link_group_id(first.id)
    assert(first_lg and first_lg ~= "", string.format(
        "CollapseAudio: first selected clip %s has no link_group — "
        .. "Collapse requires every selected clip to be in one link group.",
        first.id))
    for i = 2, #selected do
        local r = selected[i].row
        assert(r.nested_sequence_id == first.nested_sequence_id, string.format(
            "CollapseAudio: clip %s nested=%s differs from first selected "
            .. "clip nested=%s. All selected clips must reference the same "
            .. "master.",
            r.id, r.nested_sequence_id, first.nested_sequence_id))
        assert(r.source_in_frame == first.source_in_frame
           and r.source_out_frame == first.source_out_frame, string.format(
            "CollapseAudio: clip %s window [%d, %d) differs from first "
            .. "selected clip [%d, %d). Per-track slip cannot be encoded "
            .. "in composite — refused.",
            r.id, r.source_in_frame, r.source_out_frame,
            first.source_in_frame, first.source_out_frame))
        assert(r.timeline_start_frame == first.timeline_start_frame
           and r.duration_frames == first.duration_frames, string.format(
            "CollapseAudio: clip %s timeline window [%d..+%d) differs from "
            .. "first selected clip [%d..+%d).",
            r.id, r.timeline_start_frame, r.duration_frames,
            first.timeline_start_frame, first.duration_frames))
        assert(r.fps_mismatch_policy == first.fps_mismatch_policy,
            string.format(
            "CollapseAudio: clip %s fps_mismatch_policy=%s differs from "
            .. "first selected clip's %s.",
            r.id, r.fps_mismatch_policy, first.fps_mismatch_policy))
        local lg = ClipLink.get_link_group_id(r.id)
        assert(lg == first_lg, string.format(
            "CollapseAudio: clip %s is in link_group %s, expected %s. "
            .. "Every selected clip must be in the same link group.",
            r.id, tostring(lg), first_lg))
    end

    -- Compute topmost selected track (lowest track_index).
    local topmost = selected[1]
    for i = 2, #selected do
        if selected[i].track_index < topmost.track_index then
            topmost = selected[i]
        end
    end

    -- Compute selected master_audio_track_id set (for unselected-tracks
    -- diff downstream).
    local selected_master_track_ids = {}
    for _, s in ipairs(selected) do
        selected_master_track_ids[s.row.master_audio_track_id] = true
    end

    -- Enumerate nested A tracks; identify unselected.
    local nested_a = Track.find_by_sequence(first.nested_sequence_id, "AUDIO") or {}
    local unselected_master_tracks = {}
    for _, t in ipairs(nested_a) do
        if not selected_master_track_ids[t.id] then
            unselected_master_tracks[#unselected_master_tracks + 1] = t
        end
    end

    -- DELETE the selected clip rows (cascades clip_links + overrides).
    local selected_ids = {}
    for _, s in ipairs(selected) do selected_ids[#selected_ids + 1] = s.row.id end
    Clip.delete_by_ids(selected_ids)

    -- INSERT the composite clip on the topmost selected track.
    local composite_id = uuid.generate()
    Clip.create({
        id                    = composite_id,
        project_id            = first.project_id,
        owner_sequence_id     = sequence_id,
        track_id              = topmost.row.track_id,
        nested_sequence_id    = first.nested_sequence_id,
        name                  = first.name,
        timeline_start_frame  = first.timeline_start_frame,
        duration_frames       = first.duration_frames,
        source_in_frame       = first.source_in_frame,
        source_out_frame      = first.source_out_frame,
        master_layer_track_id = nil,
        master_audio_track_id = nil,   -- composite
        fps_mismatch_policy   = first.fps_mismatch_policy,
        enabled               = first.enabled,
        volume                = 1.0,    -- per-clip volume goes to per-channel gain below
        playhead_frame        = first.playhead_frame or 0,
    })

    -- Project per-channel state onto the composite.
    -- 1-channel-per-track scope: composite channel index = source track_index - 1.
    -- (a) Unselected tracks → enabled=0 disables on their channels.
    for _, t in ipairs(unselected_master_tracks) do
        Override.insert({
            clip_id       = composite_id,
            channel_index = t.track_index - 1,
            enabled       = false,
            gain_db       = 0.0,
        })
    end
    -- (b) Per selected clip:
    --     * Each existing per-channel override (the clip's ch=0 row, since
    --       1-channel-per-track) maps to composite ch = (clip's
    --       master_audio_track's track_index - 1).
    --     * Non-unity clip.volume becomes per-channel gain on composite.
    --     * enabled=false on the source clip projects to enabled=false on
    --       composite for that channel.
    for _, s in ipairs(selected) do
        local r = s.row
        local mt = Track.load(r.master_audio_track_id)
        assert(mt, string.format(
            "CollapseAudio: master_audio_track %s for clip %s missing "
            .. "(internal error after refusal gate)",
            r.master_audio_track_id, r.id))
        local composite_ch = mt.track_index - 1

        -- Source overrides for this clip, captured before delete.
        local cap_overrides = {}
        for _, sc in ipairs(source_captures) do
            if sc.row.id == r.id then
                cap_overrides = sc.overrides or {}
                break
            end
        end

        -- Pull the ch=0 source override (if any), or default
        -- (enabled=true, gain=0). Compose with clip volume + clip enabled.
        local src_enabled = r.enabled
        local src_gain_db = 0.0
        for _, ov in ipairs(cap_overrides) do
            if ov.channel_index == 0 then
                if not ((ov.enabled == 1) or (ov.enabled == true)) then
                    src_enabled = false
                end
                src_gain_db = ov.gain_db or 0.0
                break
            end
        end

        -- Volume → dB. clip.volume is a linear multiplier; convert.
        if r.volume and r.volume ~= 1.0 then
            local v = r.volume
            if v > 0 then
                local dB = 20 * math.log(v) / math.log(10)
                src_gain_db = src_gain_db + dB
            else
                -- volume=0 → silence the channel (independent of gain).
                src_enabled = false
            end
        end

        -- Only insert a composite override if it differs from default
        -- (true, 0). Otherwise leave the row absent (composite tracks
        -- the inherited state — same audible effect).
        if (not src_enabled) or src_gain_db ~= 0 then
            Override.insert({
                clip_id       = composite_id,
                channel_index = composite_ch,
                enabled       = src_enabled,
                gain_db       = src_gain_db,
            })
        end
    end

    -- Re-link: append composite to the (still-existing) link group.
    -- The selected clips' link entries cascaded away when DELETE FROM
    -- clips ran. Composite gets a fresh row in `lg`.
    ClipLink.add_to_group(first_lg, composite_id, "audio", 0)

    log.event("CollapseAudio: %d clips → composite %s on track %s "
        .. "(unselected=%d)",
        #selected, composite_id, topmost.row.track_id,
        #unselected_master_tracks)

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return {
        sequence_id        = sequence_id,
        composite_clip_id  = composite_id,
        link_group_id      = first_lg,
        source_captures    = source_captures,
    }
end

function M.undo(_capture)
    error("CollapseAudio.undo: not yet implemented (T056g/T056e cover the "
        .. "roundtrip cases that exercise undo; lands as a follow-up).")
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_ids    = { required = true },
    },
    persisted = {
        composite_clip_id = "",
        link_group_id     = "",
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["CollapseAudio"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("CollapseAudio: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("composite_clip_id", cap.composite_clip_id)
        command:set_parameter("link_group_id",     cap.link_group_id)
        return true
    end

    command_undoers["CollapseAudio"] = function(_command)
        error("CollapseAudio undo: pending follow-up.")
    end

    return {
        executor = command_executors["CollapseAudio"],
        undoer   = command_undoers["CollapseAudio"],
        spec     = SPEC,
    }
end

return M
