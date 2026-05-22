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
---     * All share the same sequence_id.
---     * All share the same source_in_frame AND source_out_frame
---       (divergent windows refuse — per-track slip is the genuine
---       expressiveness Expand buys; composite has nowhere to encode it).
---     * All share the same sequence_start_frame AND duration_frames.
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

-- Load selected clips, validate each individually (existence, ownership,
-- audio track type, non-NULL master_audio_track_id), capture state for
-- undo. Returns selected[] (each {row, track_index}) and source_captures[].
local function load_selection(sequence_id, clip_ids)
    local selected, source_captures = {}, {}
    for _, cid in ipairs(clip_ids) do
        local row = Clip.load_v13_row(cid)
        assert(row, string.format("CollapseAudio: clip %s not found", cid))
        assert(row.owner_sequence_id == sequence_id, string.format(
            "CollapseAudio: clip %s owner=%s != args sequence_id %s (rule 2.29)",
            cid, tostring(row.owner_sequence_id), tostring(sequence_id)))
        local t = Track.load(row.track_id)
        assert(t, string.format(
            "CollapseAudio: clip %s track %s not found", cid, row.track_id))
        assert(t.track_type == "AUDIO", string.format(
            "CollapseAudio: clip %s is on a %s track; only audio clips can "
            .. "be collapsed.", cid, t.track_type))
        assert(row.master_audio_track_id ~= nil, string.format(
            "CollapseAudio: clip %s is already composite "
            .. "(master_audio_track_id IS NULL); nothing to collapse.", cid))
        selected[#selected + 1] = { row = row, track_index = t.track_index }
        source_captures[#source_captures + 1] = Clip.capture_v13_state(cid)
    end
    return selected, source_captures
end

-- Cross-clip selection invariants: distinct master_audio_track_ids, shared
-- nested/window/policy/link_group across the whole selection. Returns the
-- first row + the shared link_group_id (used for downstream link rewiring).
local function assert_consistent_selection(selected)
    local first    = selected[1].row
    local first_lg = ClipLink.get_link_group_id(first.id)
    assert(first_lg and first_lg ~= "", string.format(
        "CollapseAudio: first selected clip %s has no link_group — Collapse "
        .. "requires every selected clip to be in one link group.", first.id))
    local seen = { [first.master_audio_track_id] = true }
    for i = 2, #selected do
        local r = selected[i].row
        assert(not seen[r.master_audio_track_id], string.format(
            "CollapseAudio: selection has two clips with the same "
            .. "master_audio_track_id=%s; each selected clip must point at "
            .. "a distinct nested A track.", tostring(r.master_audio_track_id)))
        seen[r.master_audio_track_id] = true
        assert(r.sequence_id == first.sequence_id, string.format(
            "CollapseAudio: clip %s nested=%s differs from first selected "
            .. "clip nested=%s. All selected clips must reference the same "
            .. "master.", r.id, r.sequence_id, first.sequence_id))
        assert(r.source_in_frame == first.source_in_frame
           and r.source_out_frame == first.source_out_frame, string.format(
            "CollapseAudio: clip %s window [%d, %d) differs from first "
            .. "selected clip [%d, %d). Per-track slip cannot be encoded "
            .. "in composite — refused.",
            r.id, r.source_in_frame, r.source_out_frame,
            first.source_in_frame, first.source_out_frame))
        assert(r.sequence_start_frame == first.sequence_start_frame
           and r.duration_frames == first.duration_frames, string.format(
            "CollapseAudio: clip %s timeline window [%d..+%d) differs from "
            .. "first selected clip [%d..+%d).",
            r.id, r.sequence_start_frame, r.duration_frames,
            first.sequence_start_frame, first.duration_frames))
        assert(r.fps_mismatch_policy == first.fps_mismatch_policy, string.format(
            "CollapseAudio: clip %s fps_mismatch_policy=%s differs from first "
            .. "selected clip's %s.",
            r.id, r.fps_mismatch_policy, first.fps_mismatch_policy))
        local lg = ClipLink.get_link_group_id(r.id)
        assert(lg == first_lg, string.format(
            "CollapseAudio: clip %s is in link_group %s, expected %s. Every "
            .. "selected clip must be in the same link group.",
            r.id, tostring(lg), first_lg))
    end
    return first, first_lg
end

-- Topmost = lowest track_index across the selection (Premiere/Resolve
-- convention: V1 above V2 above V3 in audio means audio 1 sits up top).
local function pick_topmost_selected(selected)
    local topmost = selected[1]
    for i = 2, #selected do
        if selected[i].track_index < topmost.track_index then
            topmost = selected[i]
        end
    end
    return topmost
end

-- Nested A tracks NOT covered by the selection. Their channels project
-- onto the composite as enabled=0 disables (audibly silent for those
-- tracks, matching pre-collapse where those tracks played from now-
-- untouched per-track clips).
local function compute_unselected_master_tracks(nested_id, selected)
    local in_selection = {}
    for _, s in ipairs(selected) do
        in_selection[s.row.master_audio_track_id] = true
    end
    local out = {}
    for _, t in ipairs(Track.find_by_sequence(nested_id, "AUDIO")) do
        if not in_selection[t.id] then out[#out + 1] = t end
    end
    return out
end

-- Insert the new composite (master_audio_track_id=NULL) on the topmost
-- selected track at the same window as `first`. Per-clip volume folds
-- into per-channel gain below; the row itself carries volume=1.
local function insert_composite_clip(sequence_id, first, topmost)
    local composite_id = uuid.generate()
    -- 018 FR-014: collapse onto topmost track preserves subframe from source.
    Clip.create({
        id                    = composite_id,
        project_id            = first.project_id,
        owner_sequence_id     = sequence_id,
        track_id              = topmost.row.track_id,
        sequence_id    = first.sequence_id,
        name                  = first.name,
        sequence_start_frame  = first.sequence_start_frame,
        duration_frames       = first.duration_frames,
        source_in_frame       = first.source_in_frame,
        source_out_frame      = first.source_out_frame,
        source_in_subframe    = first.source_in_subframe,
        source_out_subframe   = first.source_out_subframe,
        master_layer_track_id = nil,
        master_audio_track_id = nil,
        fps_mismatch_policy   = first.fps_mismatch_policy,
        enabled               = first.enabled,
        volume                = 1.0,
        playhead_frame        = first.playhead_frame,
    })
    return composite_id
end

-- Compose (enabled, gain_db) for one selected source clip's channel,
-- folding source overrides + clip.volume + clip.enabled. 1-channel-per-
-- track first-landing assumption: source clip's ch=0 override (if any)
-- maps to composite at ch = master_audio_track.track_index - 1.
local function composite_state_for_source(source_clip, source_captures)
    local cap_overrides = {}
    for _, sc in ipairs(source_captures) do
        if sc.row.id == source_clip.id then
            -- capture_v13_state always populates overrides as an array.
            cap_overrides = sc.overrides
            break
        end
    end
    local enabled, gain_db = source_clip.enabled, 0.0
    for _, ov in ipairs(cap_overrides) do
        if ov.channel_index == 0 then
            if not ((ov.enabled == 1) or (ov.enabled == true)) then
                enabled = false
            end
            -- Schema: clip_channel_override.gain_db is REAL NOT NULL.
            gain_db = ov.gain_db
            break
        end
    end
    if source_clip.volume and source_clip.volume ~= 1.0 then
        if source_clip.volume > 0 then
            gain_db = gain_db + 20 * math.log(source_clip.volume) / math.log(10)
        else
            -- volume=0 → silence the channel (independent of gain).
            enabled = false
        end
    end
    return enabled, gain_db
end

-- Project per-channel state onto the composite: unselected tracks become
-- per-channel disables; selected clips' overrides + volume + enabled fold
-- into per-channel state at their respective composite channel index.
local function project_channel_state(composite_id, unselected_tracks, selected,
                                     source_captures)
    for _, t in ipairs(unselected_tracks) do
        Override.insert({
            clip_id       = composite_id,
            channel_index = t.track_index - 1,
            enabled       = false,
            gain_db       = 0.0,
        })
    end
    for _, s in ipairs(selected) do
        local mt = Track.load(s.row.master_audio_track_id)
        assert(mt, string.format(
            "CollapseAudio: master_audio_track %s for clip %s missing "
            .. "(internal error after refusal gate)",
            s.row.master_audio_track_id, s.row.id))
        local enabled, gain_db = composite_state_for_source(s.row, source_captures)
        if (not enabled) or gain_db ~= 0 then
            Override.insert({
                clip_id       = composite_id,
                channel_index = mt.track_index - 1,
                enabled       = enabled,
                gain_db       = gain_db,
            })
        end
    end
end

function M.execute(args)
    assert(type(args) == "table", "CollapseAudio.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_ids = args.clip_ids
    assert(type(clip_ids) == "table" and #clip_ids > 0,
        "CollapseAudio: clip_ids must be a non-empty array")

    local selected, source_captures = load_selection(sequence_id, clip_ids)
    local first, first_lg = assert_consistent_selection(selected)
    local topmost = pick_topmost_selected(selected)
    local unselected_tracks =
        compute_unselected_master_tracks(first.sequence_id, selected)

    -- DELETE the selected clip rows (cascades clip_links + overrides);
    -- INSERT composite; project channel state; re-link.
    local selected_ids = {}
    for _, s in ipairs(selected) do
        selected_ids[#selected_ids + 1] = s.row.id
    end
    Clip.delete_by_ids(selected_ids)

    local composite_id = insert_composite_clip(sequence_id, first, topmost)
    project_channel_state(composite_id, unselected_tracks, selected, source_captures)
    ClipLink.add_to_group(first_lg, composite_id, "audio", 0)

    log.event("CollapseAudio: %d clips → composite %s on track %s (unselected=%d)",
        #selected, composite_id, topmost.row.track_id, #unselected_tracks)

    return {
        sequence_id       = sequence_id,
        composite_clip_id = composite_id,
        link_group_id     = first_lg,
        source_captures   = source_captures,
    }
end

function M.undo(capture)
    assert(type(capture) == "table",
        "CollapseAudio.undo: capture table required")

    -- Order:
    --   1. DELETE the composite clip — cascades clip_links + projected
    --      clip_channel_override rows for the composite.
    --   2. Restore each captured selected clip via Clip.restore_v13_state
    --      — re-INSERTs row + overrides + link_links entry. The
    --      previously-existing link group survives (the V clip and any
    --      unselected siblings kept their entries through Collapse), so
    --      restored clips re-attach to the same group via their
    --      captured link entry.
    if capture.composite_clip_id and capture.composite_clip_id ~= "" then
        Clip.delete_by_ids({ capture.composite_clip_id })
    end

    for _, sc in ipairs(capture.source_captures) do
        Clip.restore_v13_state(sc)
    end

end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_ids    = { required = true },
    },
    persisted = {
        composite_clip_id = { kind = "string" },
        link_group_id     = { kind = "string" },
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
        command:set_parameter("source_captures",   cap.source_captures)
        return true
    end

    command_undoers["CollapseAudio"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id        = args.sequence_id,
            composite_clip_id  = args.composite_clip_id,
            source_captures    = args.source_captures,
        })
        return true
    end

    return {
        executor = command_executors["CollapseAudio"],
        undoer   = command_undoers["CollapseAudio"],
        spec     = SPEC,
    }
end

return M
