--- Unnest command (Feature 013, T069).
---
--- Per FR-010 / contracts/commands.md §Unnest:
---   Args: { sequence_id, clip_id }. sequence_id is the clip's
---     owner_sequence_id (rule 2.29).
---   Pre: clip exists; clip.nested_sequence_id.kind == 'nested'.
---     Refused on masters (their tracks hold media_refs which can't
---     live in a non-master sequence).
---
--- Mutation:
---   1. For each clip C inside the unnested sequence: UPDATE
---      owner_sequence_id ← parent; track_id ← parent's matching
---      track (same track_type+track_index — refused if absent);
---      timeline_start_frame ← C.timeline_start_frame +
---      (clip.timeline_start_frame - clip.source_in_frame).
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

function M.execute(args)
    assert(type(args) == "table", "Unnest.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")

    local clip = Clip.load_v13_row(clip_id)
    assert(clip, string.format("Unnest: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "Unnest: sequence_id mismatch — clip %s owner=%s args=%s (rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))

    local nested_id = clip.nested_sequence_id
    local nested = Sequence.find(nested_id)
    assert(nested, string.format(
        "Unnest: nested sequence %s not found", tostring(nested_id)))
    assert(nested.kind == "nested", string.format(
        "Unnest: clip %s references kind='%s' sequence %s; only nested "
        .. "sequences can be unnested. Masters hold media_refs and cannot "
        .. "be expanded inline (CT-C19).",
        clip_id, tostring(nested.kind), nested_id))

    -- Find inner clips inside the nested sequence.
    local inner = Clip.list_in_sequence(nested_id)

    -- Translation delta: outer position = inner_start + (clip.ts - clip.source_in).
    local delta = clip.timeline_start_frame - clip.source_in_frame

    -- Pre-resolve dst_track_id for every inner clip so we can refuse
    -- BEFORE any DB mutation if a parent track is missing.
    local dst_track_ids = {}
    for _, ic in ipairs(inner) do
        local src_track = Track.load(ic.track_id)
        assert(src_track, string.format(
            "Unnest: inner clip %s track %s not found",
            ic.id, tostring(ic.track_id)))
        local dst_track_id = Track.find_at(sequence_id,
            src_track.track_type, src_track.track_index)
        assert(dst_track_id, string.format(
            "Unnest: parent sequence %s has no %s track at index %d (matching "
            .. "the inner clip's source track). Auto-creating parent tracks "
            .. "is a follow-up; refusing rather than expanding silently.",
            sequence_id, src_track.track_type, src_track.track_index))
        dst_track_ids[ic.id] = dst_track_id
    end

    -- Capture the unnested clip's full state for undo (so it can be
    -- restored alongside the inner clips' priors). MUST happen BEFORE
    -- the delete below.
    local clip_capture = Clip.capture_v13_state(clip_id)

    -- DELETE the unnested clip FIRST. Otherwise the parent's track has
    -- both the old replacement clip AND the inner-clip moves overlap-
    -- check against it, tripping the video-overlap trigger.
    Clip.delete_by_ids({ clip_id })

    -- Now move each inner clip into the parent. Capture priors for undo.
    local moved = {}
    for _, ic in ipairs(inner) do
        moved[#moved + 1] = {
            clip_id              = ic.id,
            prior_owner_id       = nested_id,
            prior_track_id       = ic.track_id,
            prior_timeline_start = ic.timeline_start_frame,
        }
        Clip.update(ic.id, {
            track_id             = dst_track_ids[ic.id],
            timeline_start_frame = ic.timeline_start_frame + delta,
        })
        Clip.transfer_owner(ic.id, sequence_id)
    end

    -- Orphan cleanup: any other clips still referencing the nested?
    -- (Exclude the just-deleted clip_id, defensively.)
    local refs = Clip.count_referencing_nested(nested_id, clip_id)
    local orphan_deleted = false
    if refs == 0 then
        Sequence.delete_one(nested_id)
        orphan_deleted = true
        log.event("Unnest: orphan-deleted nested sequence %s", nested_id)
    end

    log.event("Unnest: parent=%s clip=%s expanded=%d orphan_deleted=%s",
        sequence_id, clip_id, #moved, tostring(orphan_deleted))

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)
    if orphan_deleted then
        Signals.emit("sequence_deleted", nested_id)
    else
        Signals.emit("sequence_content_changed", nested_id)
    end

    return {
        sequence_id    = sequence_id,
        clip_capture   = clip_capture,
        moved          = moved,
        nested_id      = nested_id,
        orphan_deleted = orphan_deleted,
    }
end

function M.undo(capture)
    error("Unnest.undo: not yet implemented — full restoration of the "
        .. "deleted clip + moved-clip priors + (if orphaned) the nested "
        .. "sequence is a follow-up. Forward execution is supported and "
        .. "tested under CT-C18/C19; undo lands with T067a/T067b.")
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
    },
    persisted = {
        moved          = {},
        nested_id      = "",
        orphan_deleted = false,
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
        command:set_parameter("moved",          cap.moved)
        command:set_parameter("nested_id",      cap.nested_id)
        command:set_parameter("orphan_deleted", cap.orphan_deleted)
        return true
    end

    command_undoers["Unnest"] = function(_command)
        error("Unnest undo: pending T067a/T067b implementation.")
    end

    return {
        executor = command_executors["Unnest"],
        undoer   = command_undoers["Unnest"],
        spec     = SPEC,
    }
end

return M
