--- JoinThroughEdit / JoinAllThroughEdits commands (spec 025 FR-001).
--
-- A *through-edit* is an editorially-invisible cut: two adjacent clips on
-- one track from the same master source track with contiguous source frames
-- (see core.through_edit). Joining one rejoins the pair into a single clip,
-- identical to what the uncut clip would have been for that range — the
-- inverse of SplitClip (split shrinks the left + creates a right; join
-- deletes the right + grows the left).
--
-- Join behavior (FR-001):
--   * The left clip's out-point + duration extend to cover the right clip's
--     full range; source_in is unchanged; source_out becomes the right
--     clip's source_out.
--   * The right clip's clip_markers are reassigned to the left clip BEFORE
--     the right clip is deleted (the schema's ON DELETE CASCADE would
--     otherwise discard them). `frame` is a clip-start offset, so it shifts
--     by the left clip's pre-join duration to hold its timeline position.
--   * The left clip's link-group membership is untouched (it keeps its own
--     clip_links row; the right clip's row cascades away with the delete).
--   * Both operations are undoable; undo restores the right clip exactly
--     (row + channel overrides + link + markers + grade).
--
-- JoinAllThroughEdits joins every through-edit pair in the active sequence
-- as ONE undo step. Three-way chains collapse fully (a freshly grown left
-- clip is re-tested against its new right neighbor). Pairs on LOCKED tracks
-- are skipped (their markers still render); the whole track is skipped.
--
-- SQL isolation: all DB access via models (Clip, ClipMarker, ClipGrade, Track).

local M = {}

local Clip       = require("models.clip")
local ClipMarker = require("models.clip_marker")
local ClipGrade  = require("models.clip_grade")
local Track      = require("models.track")
local through_edit = require("core.through_edit")
local database   = require("core.database")
local log        = require("core.logger").for_area("commands")

local SAVEPOINT = "join_through_edit_atomic"

-- ── helpers ──────────────────────────────────────────────────────────────

-- The through-edit `kind` ("video"/"audio") for a timeline track.
local function track_kind(track_id)
    local track = Track.load(track_id)
    assert(track, string.format("JoinThroughEdit: track %s not found", tostring(track_id)))
    if track.track_type == "VIDEO" then return "video" end
    if track.track_type == "AUDIO" then return "audio" end
    assert(false, string.format(
        "JoinThroughEdit: track %s has unknown type %s", track_id, tostring(track.track_type)))
end

-- Map a V13 row to the property-object shape core.through_edit consumes.
-- sequence_id is the source identity (the master sequence the clip was drawn
-- from); the master layer ids only disambiguate explicit angle/stream picks.
local function predicate_view(row)
    return {
        sequence_id           = row.sequence_id,
        master_layer_track_id = row.master_layer_track_id,
        master_audio_track_id = row.master_audio_track_id,
        sequence_start        = row.sequence_start_frame,
        duration              = row.duration_frames,
        source_in             = row.source_in_frame,
        source_out            = row.source_out_frame,
        source_in_subframe    = row.source_in_subframe,
        source_out_subframe   = row.source_out_subframe,
    }
end

-- Build a timeline_state mutation entry from a V13 row (both `id` and
-- `clip_id` keys: inserts key by id, updates by clip_id). Mirrors
-- split_clip.mutation_entry.
local function mutation_entry(row)
    return {
        id                    = row.id,
        clip_id               = row.id,
        owner_sequence_id     = row.owner_sequence_id,
        track_sequence_id     = row.owner_sequence_id,
        track_id              = row.track_id,
        sequence_id           = row.sequence_id,
        sequence_start        = row.sequence_start_frame,
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

-- Perform one join (caller owns the savepoint). Returns the undo record.
-- left_row / right_row are V13 rows; they MUST already be a verified
-- through-edit pair (caller checks).
local function perform_join(left_row, right_row, kind)
    -- Marker offset shift: `frame` is relative to the clip start, and the
    -- merged clip keeps the LEFT clip's start, so right-clip markers shift
    -- by the gap between the two starts (== left's pre-join duration).
    local marker_shift = right_row.sequence_start_frame - left_row.sequence_start_frame

    -- Undo capture BEFORE any mutation.
    local right_state  = Clip.capture_v13_state(right_row.id)
    local right_marker_ids = {}
    for _, mk in ipairs(ClipMarker.find_by_clip(right_row.id)) do
        right_marker_ids[#right_marker_ids + 1] = mk.id
    end
    local right_had_grade = ClipGrade.load(right_row.id) ~= nil
    local left_prior = {
        sequence_start_frame = left_row.sequence_start_frame,
        duration_frames      = left_row.duration_frames,
        source_in_frame      = left_row.source_in_frame,
        source_out_frame     = left_row.source_out_frame,
    }

    -- Move markers while the right clip still exists, then delete it (frees
    -- the track range), then grow the left clip into the freed range. This
    -- order avoids a transient overlap (mirrors SplitClip's undo order).
    ClipMarker.reassign(right_marker_ids, left_row.id, marker_shift)
    Clip.delete_one(right_row.id)
    Clip.update_bounds(left_row.id,
        left_row.sequence_start_frame,
        left_row.duration_frames + right_row.duration_frames,
        left_row.source_in_frame,
        right_row.source_out_frame)

    log.event("JoinThroughEdit left=%s right=%s kind=%s markers=%d shift=%d",
        left_row.id, right_row.id, kind, #right_marker_ids, marker_shift)

    return {
        left_id          = left_row.id,
        right_id         = right_row.id,
        sequence_id      = left_row.owner_sequence_id,
        left_prior       = left_prior,
        right_state      = right_state,
        right_marker_ids = right_marker_ids,
        marker_shift     = marker_shift,
        right_had_grade  = right_had_grade,
    }
end

-- Reverse one join (caller owns the savepoint). Shrink the left clip back
-- (frees the range), recreate the right clip, move its markers back, and
-- restore its grade.
local function revert_join(rec)
    local p = rec.left_prior
    Clip.update_bounds(rec.left_id,
        p.sequence_start_frame, p.duration_frames,
        p.source_in_frame, p.source_out_frame)
    Clip.restore_v13_state(rec.right_state)
    ClipMarker.reassign(rec.right_marker_ids, rec.right_id, -rec.marker_shift)
    if rec.right_had_grade then
        -- The pair are through-edit halves with an identical grade; the left
        -- clip still carries it, so copy it back onto the restored right.
        ClipGrade.copy_to(rec.left_id, rec.right_id)
    end
end

-- Find the right neighbor of `left_row` on its track: the clip whose start
-- is flush with the left clip's end. Returns a V13 row or nil.
local function flush_right_neighbor(left_row)
    local left_end = left_row.sequence_start_frame + left_row.duration_frames
    for _, row in ipairs(Clip.list_in_sequence(left_row.owner_sequence_id)) do
        if row.track_id == left_row.track_id
            and row.sequence_start_frame == left_end
            and row.id ~= left_row.id then
            return Clip.load_v13_row(row.id)  -- full row incl. master_audio_track_id
        end
    end
    return nil
end

-- ── JoinThroughEdit (one pair) ─────────────────────────────────────────────

function M.execute_one(args)
    assert(type(args) == "table", "JoinThroughEdit.execute: args must be a table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "JoinThroughEdit: sequence_id required")
    assert(args.clip_id and args.clip_id ~= "",
        "JoinThroughEdit: clip_id required (the LEFT clip of the edit)")

    local left = Clip.load_v13_row(args.clip_id)
    assert(left, string.format("JoinThroughEdit: clip %s not found", args.clip_id))
    assert(left.owner_sequence_id == args.sequence_id, string.format(
        "JoinThroughEdit: clip %s owner=%s != sequence_id=%s",
        args.clip_id, left.owner_sequence_id, args.sequence_id))

    local right = flush_right_neighbor(left)
    assert(right, string.format(
        "JoinThroughEdit: clip %s has no flush right neighbor — not an edit point",
        args.clip_id))

    local kind = track_kind(left.track_id)
    assert(through_edit.is_through_edit(predicate_view(left), predicate_view(right), kind),
        string.format("JoinThroughEdit: clips %s/%s are not a through-edit", left.id, right.id))

    assert(database.savepoint(SAVEPOINT), "JoinThroughEdit: savepoint failed")
    local ok, rec_or_err = pcall(perform_join, left, right, kind)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(rec_or_err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT), "JoinThroughEdit: release savepoint failed")

    return { records = { rec_or_err }, sequence_id = args.sequence_id }
end

-- ── JoinAllThroughEdits (whole sequence, one undo step) ────────────────────

function M.execute_all(args)
    assert(type(args) == "table", "JoinAllThroughEdits.execute: args must be a table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "JoinAllThroughEdits: sequence_id required")

    local records = {}
    assert(database.savepoint(SAVEPOINT), "JoinAllThroughEdits: savepoint failed")
    local ok, err = pcall(function()
        for _, track in ipairs(Track.find_by_sequence(args.sequence_id)) do
            if not track.locked then
                local kind = track_kind(track.id)
                -- Re-scan after each join: a grown left clip may now be a
                -- through-edit with its new right neighbor (chain collapse).
                local progress = true
                while progress do
                    progress = false
                    local clips = {}
                    for _, row in ipairs(Clip.list_in_sequence(args.sequence_id)) do
                        if row.track_id == track.id then clips[#clips + 1] = row end
                    end
                    for i = 1, #clips - 1 do
                        local a = Clip.load_v13_row(clips[i].id)
                        local b = Clip.load_v13_row(clips[i + 1].id)
                        if a.sequence_start_frame + a.duration_frames == b.sequence_start_frame
                            and through_edit.is_through_edit(
                                predicate_view(a), predicate_view(b), kind) then
                            records[#records + 1] = perform_join(a, b, kind)
                            progress = true
                            break  -- clip list is now stale; re-scan
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT), "JoinAllThroughEdits: release savepoint failed")

    log.event("JoinAllThroughEdits sequence=%s joined=%d pairs", args.sequence_id, #records)
    return { records = records, sequence_id = args.sequence_id }
end

-- ── undo (shared) ─────────────────────────────────────────────────────────

-- Reverse a batch of join records in LIFO order under one savepoint.
local function undo_records(records)
    assert(database.savepoint(SAVEPOINT), "Undo Join: savepoint failed")
    local ok, err = pcall(function()
        for i = #records, 1, -1 do
            revert_join(records[i])
        end
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT), "Undo Join: release savepoint failed")
end

-- Build the __timeline_mutations payload for a set of records.
-- forward=true → joins applied (left grew, right deleted).
-- forward=false → joins reverted (left shrank, right re-inserted).
local function mutations_for(records, sequence_id, forward)
    local updates, inserts, deletes = {}, {}, {}
    for _, rec in ipairs(records) do
        updates[#updates + 1] = mutation_entry(Clip.load_v13_row(rec.left_id))
        if forward then
            deletes[#deletes + 1] = { clip_id = rec.right_id }
        else
            inserts[#inserts + 1] = mutation_entry(Clip.load_v13_row(rec.right_id))
        end
    end
    return {
        sequence_id = sequence_id,
        inserts     = inserts,
        updates     = updates,
        deletes     = deletes,
        bulk_shifts = {},
    }
end

-- ── registration ───────────────────────────────────────────────────────────

local SPEC_ONE = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },  -- the LEFT clip of the edit point
    },
    persisted = { records = {}, sequence_id = {} },
}

local SPEC_ALL = {
    args = { sequence_id = { required = true } },
    persisted = { records = {}, sequence_id = {} },
}

local function make_executor(exec_fn, name, command_executors, set_last_error)
    return function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(exec_fn, args)
        if not ok then
            set_last_error(name .. ": " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("records", result_or_err.records)
        command:set_parameter("sequence_id", result_or_err.sequence_id)
        command:set_parameter("__timeline_mutations",
            mutations_for(result_or_err.records, result_or_err.sequence_id, true))
        return { success = true, result_data = result_or_err }
    end
end

local function make_undoer(name)
    return function(command)
        local records = command:get_all_parameters().records
        local sequence_id = command:get_all_parameters().sequence_id
        assert(records, "Undo " .. name .. ": records missing")
        assert(sequence_id, "Undo " .. name .. ": sequence_id missing")
        undo_records(records)
        command:set_parameter("__timeline_mutations",
            mutations_for(records, sequence_id, false))
        return true
    end
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["JoinThroughEdit"] =
        make_executor(M.execute_one, "JoinThroughEdit", command_executors, set_last_error)
    command_undoers["JoinThroughEdit"] = make_undoer("JoinThroughEdit")

    command_executors["JoinAllThroughEdits"] =
        make_executor(M.execute_all, "JoinAllThroughEdits", command_executors, set_last_error)
    command_undoers["JoinAllThroughEdits"] = make_undoer("JoinAllThroughEdits")

    return {
        JoinThroughEdit = {
            executor = command_executors["JoinThroughEdit"],
            undoer   = command_undoers["JoinThroughEdit"],
            spec     = SPEC_ONE,
        },
        JoinAllThroughEdits = {
            executor = command_executors["JoinAllThroughEdits"],
            undoer   = command_undoers["JoinAllThroughEdits"],
            spec     = SPEC_ALL,
        },
    }
end

return M
