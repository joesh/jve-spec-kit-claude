--- Nest command (Feature 013, T068).
---
--- Per FR-010 / contracts/commands.md §Nest:
---   Args: { sequence_id, selected_clip_ids }
---     sequence_id MUST reference a kind='nested' sequence (rule 2.29).
---     all selected_clip_ids belong to that sequence.
---
--- First-landing scope: all selected clips must be on the same track.
--- Multi-track nesting (with one parent clip per medium and a link group)
--- is a follow-up — refused with a clear message.
---
--- Mutation:
---   1. Create new sequence S (kind='nested'; timebase + dimensions
---      copied from the parent).
---   2. Create one track on S matching the source track's type/index.
---   3. Move each selected clip into S: owner_sequence_id ← S;
---      track_id ← S's new track; timeline_start_frame translated by
---      -min_selected_start (so S's content starts at frame 0).
---   4. INSERT one new clip on the parent at min_selected_start with
---      nested_sequence_id = S; duration = (max_end - min_start);
---      source_in = 0; source_out = duration.
---
--- Undo capture: new_sequence_id, new_clip_id, moved clips' priors,
--- new track id (so undo can DELETE it cleanly).
---
--- Signal: sequence_content_changed(parent), sequence_content_changed(S).
---
--- @file nest.lua

local M = {}

local Clip      = require("models.clip")
local Sequence  = require("models.sequence")
local Track     = require("models.track")
local uuid      = require("uuid")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "Nest: '%s' is required (rule 2.29)", name))
    return v
end

-- Direct UPDATE on a clips row's owner+track+start, used to migrate a
-- selected clip into the newly-created nested sequence. Goes via the
-- model-layer SQL so it stays out of command code.
local function migrate_clip_to_S(clip_id, new_owner, new_track, new_start)
    -- clips must be owned by a kind='nested' sequence — new_owner has kind='nested'. The
    -- video-overlap trigger fires on UPDATE; new_track is empty (we just
    -- created the track) so no collision is possible.
    Clip.update(clip_id, {
        track_id             = new_track,
        timeline_start_frame = new_start,
    })
    -- Sequence transfer requires a separate model entry point. Add via
    -- direct UPDATE on the row (bypassing Clip.update which doesn't
    -- accept owner_sequence_id as a structural-protected column).
    Clip.transfer_owner(clip_id, new_owner)
end

-- Resolve the parent sequence and refuse if it isn't a non-master ('nested').
-- Masters hold media_refs, not clips, so Nest doesn't apply to them.
local function load_parent_sequence(sequence_id)
    local parent = Sequence.find(sequence_id)
    assert(parent, string.format(
        "Nest: parent sequence %s not found", sequence_id))
    assert(parent.kind == "nested", string.format(
        "Nest: parent sequence %s has kind='%s'; Nest is valid only on "
        .. "non-master (kind='nested') sequences (masters hold media_refs, "
        .. "not clips).", sequence_id, tostring(parent.kind)))
    return parent
end

-- Load each selected clip and enforce the first-landing scope: all clips
-- belong to the parent sequence and sit on a single shared track. Returns
-- the row list and the shared track_id.
local function load_selected_clips(sequence_id, selected_ids)
    local clip_rows = {}
    local first_track_id
    for _, cid in ipairs(selected_ids) do
        local row = Clip.load_v13_row(cid)
        assert(row, string.format("Nest: clip %s not found", cid))
        assert(row.owner_sequence_id == sequence_id, string.format(
            "Nest: clip %s belongs to sequence %s, not the args sequence_id %s",
            cid, row.owner_sequence_id, sequence_id))
        if first_track_id == nil then
            first_track_id = row.track_id
        else
            assert(row.track_id == first_track_id, string.format(
                "Nest: first-landing scope requires all selected clips to "
                .. "be on the same track. Got %s on %s and %s on %s. "
                .. "(Multi-track nesting is a follow-up feature.)",
                cid, tostring(row.track_id),
                selected_ids[1], tostring(first_track_id)))
        end
        clip_rows[#clip_rows + 1] = row
    end
    return clip_rows, first_track_id
end

-- [min_start, max_end) covering every selected clip's timeline window.
local function compute_selection_span(clip_rows)
    local min_start, max_end
    for _, r in ipairs(clip_rows) do
        local s = r.timeline_start_frame
        local e = s + r.duration_frames
        if min_start == nil or s < min_start then min_start = s end
        if max_end == nil or e > max_end then max_end = e end
    end
    local span = max_end - min_start
    assert(span > 0, "Nest: selection span must be > 0")
    return min_start, span
end

-- Create the new nested sequence S inheriting timebase + dimensions from
-- the parent so passthrough scaling holds at the parent boundary.
local function create_nested_sequence(parent, new_seq_id)
    local s = Sequence.create("Nested", parent.project_id,
        { fps_numerator = parent.fps_numerator,
          fps_denominator = parent.fps_denominator },
        parent.width, parent.height,
        { id          = new_seq_id,
          kind        = "nested",
          audio_sample_rate  = parent.audio_sample_rate,
        })
    assert(s:save(), "Nest: failed to save new nested sequence")
    return s
end

-- Create a single track on S mirroring the source track's type and index.
-- For VIDEO, set the sequence's default video layer (required when video tracks exist).
local function create_mirrored_track(source_track, new_seq_id, new_track_id)
    if source_track.track_type == "VIDEO" then
        local t = Track.create_video(source_track.name, new_seq_id,
            { id = new_track_id, index = source_track.track_index })
        assert(t:save(), "Nest: failed to save new V track on S")
        Sequence.update(new_seq_id, { default_video_layer_track_id = new_track_id })
    else
        local t = Track.create_audio(source_track.name, new_seq_id,
            { id = new_track_id, index = source_track.track_index })
        assert(t:save(), "Nest: failed to save new A track on S")
    end
end

-- Move every selected clip into S, translated so S starts at frame 0.
-- Returns the priors needed to undo the move.
local function migrate_selection_into_S(clip_rows, new_seq_id, new_track_id, min_start)
    local moved = {}
    for _, r in ipairs(clip_rows) do
        moved[#moved + 1] = {
            clip_id              = r.id,
            prior_owner_id       = r.owner_sequence_id,
            prior_track_id       = r.track_id,
            prior_timeline_start = r.timeline_start_frame,
        }
        migrate_clip_to_S(r.id, new_seq_id, new_track_id,
            r.timeline_start_frame - min_start)
    end
    return moved
end

-- INSERT one replacement clip on the parent that wraps S over the same
-- timeline window the selection used to occupy.
local function insert_replacement_clip(parent, sequence_id, track_id,
                                       new_clip_id, new_seq_id,
                                       min_start, span)
    Clip.create({
        id                    = new_clip_id,
        project_id            = parent.project_id,
        owner_sequence_id     = sequence_id,
        track_id              = track_id,
        nested_sequence_id    = new_seq_id,
        name                  = "Nested",
        timeline_start_frame  = min_start,
        duration_frames       = span,
        source_in_frame       = 0,
        source_out_frame      = span,
        master_layer_track_id = nil,
        fps_mismatch_policy   = "passthrough",  -- same timebase as parent
        enabled               = true,
        volume                = 1.0,
        playhead_frame        = 0,
    })
end

function M.execute(args)
    assert(type(args) == "table", "Nest.execute: args table required")
    local sequence_id  = require_string_arg(args, "sequence_id")
    local selected_ids = args.selected_clip_ids
    assert(type(selected_ids) == "table" and #selected_ids > 0,
        "Nest: selected_clip_ids must be a non-empty array")

    local parent                  = load_parent_sequence(sequence_id)
    local clip_rows, src_track_id = load_selected_clips(sequence_id, selected_ids)
    local source_track            = Track.load(src_track_id)
    assert(source_track, string.format(
        "Nest: source track %s not found", src_track_id))
    local min_start, span         = compute_selection_span(clip_rows)

    local new_seq_id   = args.new_sequence_id or uuid.generate()
    local new_track_id = args.new_track_id    or uuid.generate()
    local new_clip_id  = args.new_clip_id     or uuid.generate()

    create_nested_sequence(parent, new_seq_id)
    create_mirrored_track(source_track, new_seq_id, new_track_id)
    local moved = migrate_selection_into_S(clip_rows, new_seq_id, new_track_id, min_start)
    insert_replacement_clip(parent, sequence_id, src_track_id,
                            new_clip_id, new_seq_id, min_start, span)

    log.event("Nest: parent=%s S=%s moved=%d span=%d at=%d",
        sequence_id, new_seq_id, #moved, span, min_start)

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)
    Signals.emit("sequence_content_changed", new_seq_id)

    return {
        sequence_id      = sequence_id,
        new_sequence_id  = new_seq_id,
        new_track_id     = new_track_id,
        new_clip_id      = new_clip_id,
        moved            = moved,
    }
end

function M.undo(capture)
    assert(type(capture) == "table", "Nest.undo: capture table required")
    -- Reverse order:
    -- (a) Delete the parent's replacement clip.
    Clip.delete_by_ids({ capture.new_clip_id })
    -- (b) Restore each moved clip's prior owner/track/start.
    for _, m in ipairs(capture.moved) do
        Clip.update(m.clip_id, {
            track_id             = m.prior_track_id,
            timeline_start_frame = m.prior_timeline_start,
        })
        Clip.transfer_owner(m.clip_id, m.prior_owner_id)
    end
    -- (c) Delete the new track + new sequence (cascades clean since the
    -- moved clips are gone).
    Track.delete(capture.new_track_id)
    Sequence.delete_one(capture.new_sequence_id)

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

local SPEC = {
    args = {
        sequence_id        = { required = true },
        selected_clip_ids  = { required = true },
    },
    persisted = {
        new_sequence_id = { kind = "string" },
        new_track_id    = { kind = "string" },
        new_clip_id     = { kind = "string" },
        moved           = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Nest"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Nest: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("new_sequence_id", cap.new_sequence_id)
        command:set_parameter("new_track_id",    cap.new_track_id)
        command:set_parameter("new_clip_id",     cap.new_clip_id)
        command:set_parameter("moved",           cap.moved)
        return true
    end

    command_undoers["Nest"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id      = args.sequence_id,
            new_sequence_id  = args.new_sequence_id,
            new_track_id     = args.new_track_id,
            new_clip_id      = args.new_clip_id,
            moved            = args.moved,
        })
        return true
    end

    return {
        executor = command_executors["Nest"],
        undoer   = command_undoers["Nest"],
        spec     = SPEC,
    }
end

return M
