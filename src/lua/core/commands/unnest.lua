--- Unnest command (Feature 013, T069).
---
--- Per FR-010 / contracts/commands.md §Unnest:
---   Args: { sequence_id, clip_id }. sequence_id is the clip's
---     owner_sequence_id (rule 2.29).
---   Pre: clip exists; clip.sequence_id.kind == 'sequence'.
---     Refused on masters (their tracks hold media_refs which can't
---     live in a non-master sequence).
---
--- Mutation:
---   1. For each clip C inside the unnested sequence: UPDATE
---      owner_sequence_id ← parent; track_id ← parent's matching
---      track (same track_type+track_index — refused if absent);
---      sequence_start_frame ← C.sequence_start_frame +
---      (clip.sequence_start_frame - clip.source_in_frame).
---   2. DELETE the unnested clip row.
---   3. If the unnested sequence has no remaining references in any
---      `clips` row, DELETE it (orphan cleanup).
---
--- First-landing scope: parent must have a track of matching
--- track_type + track_index for every track in the nested sequence.
--- Auto-creating missing parent tracks is a follow-up.
---
--- @file unnest.lua

local M = {}

local Clip      = require("models.clip")
local Sequence  = require("models.sequence")
local Track     = require("models.track")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "Unnest: '%s' is required (rule 2.29)", name))
    return v
end

-- (model-layer helpers used: Clip.list_in_sequence,
--  Clip.count_referencing_nested, Track.find_at)

-- Resolve the unnested clip and its referenced nested sequence. Refuses
-- when the clip is missing, the sequence_id mismatches owner (rule 2.29),
-- or the referenced sequence is a master (CT-C19).
local function load_clip_and_nested(sequence_id, clip_id)
    local clip = Clip.load_row(clip_id)
    assert(clip, string.format("Unnest: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "Unnest: sequence_id mismatch — clip %s owner=%s args=%s (rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    local nested_id = clip.sequence_id
    local nested    = Sequence.find(nested_id)
    assert(nested, string.format(
        "Unnest: nested sequence %s not found", tostring(nested_id)))
    assert(nested.kind == "sequence", string.format(
        "Unnest: clip %s references kind='%s' sequence %s; only nested "
        .. "sequences can be unnested. Masters hold media_refs and cannot "
        .. "be expanded inline (CT-C19).",
        clip_id, tostring(nested.kind), nested_id))
    return clip, nested_id
end

-- For every inner clip resolve its destination track on the parent and
-- refuse BEFORE any mutation if a matching track is missing. Returns
-- a clip_id → dst_track_id map.
local function resolve_destination_tracks(parent_seq_id, inner)
    local dst_track_ids = {}
    for _, ic in ipairs(inner) do
        local src_track = Track.load(ic.track_id)
        assert(src_track, string.format(
            "Unnest: inner clip %s track %s not found",
            ic.id, tostring(ic.track_id)))
        local dst_track_id = Track.find_at(parent_seq_id,
            src_track.track_type, src_track.track_index)
        assert(dst_track_id, string.format(
            "Unnest: parent sequence %s has no %s track at index %d (matching "
            .. "the inner clip's source track). Auto-creating parent tracks "
            .. "is a follow-up; refusing rather than expanding silently.",
            parent_seq_id, src_track.track_type, src_track.track_index))
        dst_track_ids[ic.id] = dst_track_id
    end
    return dst_track_ids
end

-- Move each inner clip into the parent at delta-translated start. Returns
-- the priors needed for undo. Caller MUST have deleted the wrapper clip
-- first so the overlap trigger doesn't fire against it.
local function move_inner_clips_to_parent(inner, dst_track_ids,
                                          parent_seq_id, nested_id, delta)
    local moved = {}
    for _, ic in ipairs(inner) do
        moved[#moved + 1] = {
            clip_id              = ic.id,
            prior_owner_id       = nested_id,
            prior_track_id       = ic.track_id,
            prior_sequence_start = ic.sequence_start_frame,
        }
        Clip.update(ic.id, {
            track_id             = dst_track_ids[ic.id],
            sequence_start_frame = ic.sequence_start_frame + delta,
        })
        Clip.transfer_owner(ic.id, parent_seq_id)
    end
    return moved
end

-- If no other clips still reference `nested_id`, capture and delete it.
-- The capture lets undo resurrect the row + its tracks (no silent DB
-- record creation). Returns (orphan_deleted, nested_state_capture).
local function cleanup_orphan_nested(nested_id, just_deleted_clip_id)
    local refs = Clip.count_referencing_nested(nested_id, just_deleted_clip_id)
    if refs ~= 0 then
        return false, nil
    end
    local nested_state_capture = Sequence.capture_full_state(nested_id)
    Sequence.delete_one(nested_id)
    log.event("Unnest: orphan-deleted nested sequence %s", nested_id)
    return true, nested_state_capture
end

function M.execute(args)
    assert(type(args) == "table", "Unnest.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")

    local clip, nested_id = load_clip_and_nested(sequence_id, clip_id)
    local inner           = Clip.list_in_sequence(nested_id)
    local dst_track_ids   = resolve_destination_tracks(sequence_id, inner)
    -- outer_pos = inner_start + (clip.ts - clip.source_in)
    local delta           = clip.sequence_start_frame - clip.source_in_frame

    -- Capture wrapper state for undo BEFORE deleting it.
    local clip_capture = Clip.capture_state(clip_id)
    -- Delete wrapper FIRST so inner-clip moves don't overlap against it.
    Clip.delete_by_ids({ clip_id })

    local moved = move_inner_clips_to_parent(inner, dst_track_ids,
                                             sequence_id, nested_id, delta)
    local orphan_deleted, nested_state_capture =
        cleanup_orphan_nested(nested_id, clip_id)

    log.event("Unnest: parent=%s clip=%s expanded=%d orphan_deleted=%s",
        sequence_id, clip_id, #moved, tostring(orphan_deleted))

    local Signals = require("core.signals")
    if not orphan_deleted then
        Signals.emit("sequence_content_changed", nested_id)
    end
    -- The orphan-deleted branch's sequence_list_changed emit (and its
    -- undo companion) is queued from the executor wrapper below — it
    -- must be post-commit so tab strip / project browser see the same
    -- row state we see after the SQL settles.

    local parent = Sequence.load(sequence_id)
    assert(parent and parent.project_id and parent.project_id ~= "",
        "Unnest: parent sequence " .. tostring(sequence_id)
        .. " missing project_id — required for sequence_list_changed")

    return {
        sequence_id          = sequence_id,
        project_id           = parent.project_id,
        clip_capture         = clip_capture,
        moved                = moved,
        nested_id            = nested_id,
        orphan_deleted       = orphan_deleted,
        nested_state_capture = nested_state_capture,
    }
end

function M.undo(capture)
    assert(type(capture) == "table",
        "Unnest.undo: capture table required")
    -- (a) If orphan-deleted, resurrect the nested sequence first so the
    --     inner clips' restored owner_sequence_id resolves.
    if capture.orphan_deleted then
        assert(capture.nested_state_capture,
            "Unnest.undo: nested_state_capture missing on orphan-deleted unnest")
        Sequence.restore_full_state(capture.nested_state_capture)
    end

    -- (b) Move each inner clip back to the nested sequence at its prior
    --     track + sequence_start. Order: update track+start (trigger
    --     sees nested track empty post-resurrection), then transfer
    --     owner (trigger checks the new owner is kind='sequence').
    for _, m in ipairs(capture.moved) do
        Clip.update(m.clip_id, {
            track_id             = m.prior_track_id,
            sequence_start_frame = m.prior_sequence_start,
        })
        Clip.transfer_owner(m.clip_id, m.prior_owner_id)
    end

    -- (c) Restore the deleted unnested clip via its full V13 capture.
    Clip.restore_state(capture.clip_capture)

    -- Mirror the forward path: only emit sequence_content_changed for
    -- the non-orphan branch. The orphan-resurrected case fires
    -- sequence_list_changed from the executor wrapper (post-commit).
    if not capture.orphan_deleted then
        require("core.signals").emit("sequence_content_changed", capture.nested_id)
    end
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
    },
    persisted = {
        moved                = {},
        nested_id            = { kind = "string" },
        orphan_deleted       = { kind = "boolean" },
        clip_capture         = {},
        nested_state_capture = {},
        project_id           = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Unnest"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Unnest: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("moved",                cap.moved)
        command:set_parameter("nested_id",            cap.nested_id)
        command:set_parameter("orphan_deleted",       cap.orphan_deleted)
        command:set_parameter("clip_capture",         cap.clip_capture)
        command:set_parameter("nested_state_capture", cap.nested_state_capture)
        command:set_parameter("project_id",           cap.project_id)
        if cap.orphan_deleted then
            assert(cap.project_id and cap.project_id ~= "",
                "Unnest: capture missing project_id for sequence_list_changed emit")
            require("core.command_manager").queue_post_commit_emit(
                "sequence_list_changed", cap.project_id)
        end
        return true
    end

    command_undoers["Unnest"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id          = args.sequence_id,
            nested_id            = args.nested_id,
            orphan_deleted       = args.orphan_deleted and true or false,
            moved                = args.moved,
            clip_capture         = args.clip_capture,
            nested_state_capture = args.nested_state_capture,
        })
        if args.orphan_deleted then
            assert(args.project_id and args.project_id ~= "",
                "UndoUnnest: persisted project_id missing — required for "
                .. "sequence_list_changed emit after nested-sequence resurrect")
            require("core.command_manager").queue_post_commit_emit(
                "sequence_list_changed", args.project_id)
        end
        return true
    end

    return {
        executor = command_executors["Unnest"],
        undoer   = command_undoers["Unnest"],
        spec     = SPEC,
    }
end

return M
