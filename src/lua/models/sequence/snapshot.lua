--- models/sequence/snapshot.lua — Sequence.capture_full_state and
--- Sequence.restore_full_state, used by Unnest.execute /
--- Unnest.undo to clone a sequence + its tracks before orphan-delete
--- and resurrect them on undo.
---
--- Extracted from models/sequence.lua (2.6: ~100-LOC cohesive pair).
--- Installed onto Sequence via M.install(Sequence). capture_full_state
--- calls Sequence.find which still lives in models/sequence.lua —
--- reached through the Sequence arg at install time.

local database = require("core.database")

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "models.sequence.snapshot: no database connection")
    return conn
end

local M = {}

function M.install(Sequence)

--- Capture a sequence's full row + its tracks, suitable for restore.
--- Used by Unnest.execute before orphan-deleting the nested sequence so
--- Unnest.undo can resurrect it. Returns nil if the sequence is missing.
---
--- @return table|nil { seq = {row...}, tracks = [{id,name,type,index},...] }
function Sequence.capture_full_state(id)
    assert(id and id ~= "", "Sequence.capture_full_state: id required")
    local seq = Sequence.find(id)
    if not seq then return nil end
    local Track = require("models.track")
    local tracks = {}
    for _, ttype in ipairs({ "VIDEO", "AUDIO" }) do
        local list = Track.find_by_sequence(id, ttype)
        for _, t in ipairs(list) do
            tracks[#tracks + 1] = {
                id          = t.id,
                name        = t.name,
                track_type  = ttype,
                track_index = t.track_index,
            }
        end
    end
    return { seq = seq, tracks = tracks }
end

--- Re-INSERT the sequence row + its tracks captured by
--- capture_full_state. Used by Unnest.undo when an orphan-deleted
--- nested sequence needs resurrection.
function Sequence.restore_full_state(state)
    assert(type(state) == "table" and type(state.seq) == "table",
        "Sequence.restore_full_state: state.seq table required")
    local s = state.seq
    local conn = resolve_db()
    local now = os.time()

    -- The captured default_video_layer_track_id references a track that
    -- WILL be re-INSERTed below. Defer FK checks for this transaction
    -- so the sequence INSERT lands before its tracks exist.
    conn:exec("PRAGMA defer_foreign_keys = ON;")
    conn:exec("BEGIN;")

    local function rollback(reason)
        conn:exec("ROLLBACK;")
        conn:exec("PRAGMA defer_foreign_keys = OFF;")
        error("Sequence.restore_full_state: " .. reason)
    end

    local stmt = conn:prepare([[
        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, video_start_tc_frame,
            audio_start_tc_samples, fps_mismatch_policy,
            playhead_frame, view_start_frame, view_duration_frames,
            video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
            mutation_generation, created_at, modified_at, start_timecode_frame
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                  0, 0, 240, 0, 0, 0.5, 0, ?, ?, 0)
    ]])
    if not stmt then rollback("prepare seq INSERT failed") end
    stmt:bind_value(1,  s.id)
    stmt:bind_value(2,  s.project_id)
    stmt:bind_value(3,  s.name)
    stmt:bind_value(4,  s.kind)
    stmt:bind_value(5,  s.fps_numerator)
    stmt:bind_value(6,  s.fps_denominator)
    stmt:bind_value(7,  s.audio_sample_rate)
    stmt:bind_value(8,  s.width)
    stmt:bind_value(9,  s.height)
    stmt:bind_value(10, s.default_video_layer_track_id)
    stmt:bind_value(11, s.video_start_tc_frame)
    stmt:bind_value(12, s.audio_start_tc_samples)
    stmt:bind_value(13, s.fps_mismatch_policy)
    stmt:bind_value(14, now)
    stmt:bind_value(15, now)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    if not ok then
        rollback(string.format("INSERT seq %s failed: %s", s.id, tostring(err)))
    end

    local Track = require("models.track")
    -- capture_full_state always populates state.tracks (possibly empty).
    for _, t in ipairs(state.tracks) do
        local newt
        if t.track_type == "VIDEO" then
            newt = Track.create_video(t.name, s.id,
                { id = t.id, index = t.track_index })
        else
            newt = Track.create_audio(t.name, s.id,
                { id = t.id, index = t.track_index })
        end
        if not newt:save() then
            rollback(string.format("save track %s failed", t.id))
        end
    end

    local commit_ok, commit_err = conn:exec("COMMIT;")
    conn:exec("PRAGMA defer_foreign_keys = OFF;")
    assert(commit_ok ~= false, string.format(
        "Sequence.restore_full_state: COMMIT failed: %s",
        tostring(commit_err)))
end

end -- M.install

return M
