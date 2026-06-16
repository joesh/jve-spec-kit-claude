--- Track-lock guard: refuse clip mutations targeting any locked track.
---
--- Single chokepoint consulted by Clip-model writes (Clip.create,
--- Clip.update, Clip.update_bounds, Clip.delete_*, Clip.shift_many_by,
--- Clip.ripple_track_forward) AND by command_helper.apply_mutations.
--- Centralizing here keeps the rule consistent regardless of which write
--- primitive a command uses.
---
--- Bypass: when command_manager.is_undo_redo_in_progress() is true the
--- guard is a no-op. A track locked AFTER an edit must still be revertable
--- — undo never originates an edit; it replays one that was allowed at
--- creation time.
---
--- @file track_lock_guard.lua

local M = {}

--- Returns true when the current operation is an undo or redo replay.
--- Lazy lookup avoids the circular require (command_manager loads commands
--- which load Clip which loads this guard).
local function in_undo_redo()
    local cm = package.loaded["core.command_manager"]
    if not cm or not cm.is_undo_redo_in_progress then return false end
    return cm.is_undo_redo_in_progress() == true
end

--- Query tracks.locked for the given ids and return locked rows.
--- @param db sqlite handle
--- @param track_ids array<string>
--- @return array<{id, name}> empty if none locked
local function locked_rows(db, track_ids)
    if #track_ids == 0 then return {} end
    local placeholders = require("core.database").in_placeholders(#track_ids)
    local stmt = db:prepare(string.format(
        "SELECT id, name FROM tracks WHERE id IN (%s) AND locked = 1",
        placeholders))
    assert(stmt, "track_lock_guard.locked_rows: prepare failed: "
        .. tostring(db:last_error()))
    for i, tid in ipairs(track_ids) do stmt:bind_value(i, tid) end
    assert(stmt:exec(), "track_lock_guard.locked_rows: exec failed: "
        .. tostring(db:last_error()))
    local out = {}
    while stmt:next() do
        out[#out + 1] = { id = stmt:value(0), name = stmt:value(1) }
    end
    stmt:finalize()
    return out
end

--- Format a locked-track list into the error message commands return to
--- the user / surface to logs.
local function fmt_locked_message(locked)
    local parts = {}
    for _, r in ipairs(locked) do
        parts[#parts + 1] = string.format("%s (%s)", r.name or "?", r.id)
    end
    return "track is locked: " .. table.concat(parts, ", ")
end

--- Non-throwing check used by command_helper.apply_mutations.
--- @return ok:boolean, err:string?
function M.check_writable(db, track_ids)
    if in_undo_redo() then return true end
    assert(db, "track_lock_guard.check_writable: db required")
    assert(type(track_ids) == "table",
        "track_lock_guard.check_writable: track_ids must be an array")
    local locked = locked_rows(db, track_ids)
    if #locked == 0 then return true end
    return false, fmt_locked_message(locked)
end

--- Throwing variant used by Clip-model writes that don't return (ok, err).
--- The thrown error propagates to command_manager.execute() which pcalls
--- and surfaces success=false, error_message=<the thrown string>.
function M.assert_writable(db, track_ids)
    local ok, err = M.check_writable(db, track_ids)
    if not ok then error(err, 2) end
end

--- Look up the track_ids for a set of clip ids and assert each is writable.
--- Used by Clip primitives that take clip_ids (delete_by_ids, shift_many_by).
function M.assert_clips_writable(db, clip_ids)
    if in_undo_redo() then return end
    if not clip_ids or #clip_ids == 0 then return end
    local placeholders = require("core.database").in_placeholders(#clip_ids)
    local stmt = db:prepare(string.format(
        "SELECT DISTINCT track_id FROM clips WHERE id IN (%s)", placeholders))
    assert(stmt, "track_lock_guard.assert_clips_writable: prepare failed: "
        .. tostring(db:last_error()))
    for i, cid in ipairs(clip_ids) do stmt:bind_value(i, cid) end
    assert(stmt:exec(), "track_lock_guard.assert_clips_writable: exec failed: "
        .. tostring(db:last_error()))
    local tracks = {}
    while stmt:next() do tracks[#tracks + 1] = stmt:value(0) end
    stmt:finalize()
    M.assert_writable(db, tracks)
end

--- Look up the track_id for a single clip and assert it is writable.
function M.assert_clip_writable(db, clip_id)
    if in_undo_redo() then return end
    assert(type(clip_id) == "string" and clip_id ~= "",
        "track_lock_guard.assert_clip_writable: clip_id required")
    local stmt = db:prepare("SELECT track_id FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(),
        "track_lock_guard.assert_clip_writable: exec failed: "
        .. tostring(db:last_error()))
    if not stmt:next() then stmt:finalize(); return end
    local tid = stmt:value(0)
    stmt:finalize()
    if not tid or tid == "" then return end
    M.assert_writable(db, { tid })
end

return M
