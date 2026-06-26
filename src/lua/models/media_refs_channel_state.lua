--- Master-level per-channel audio state.
---
--- Sparse: a row exists only when the editor has explicitly touched
--- a channel's enabled/gain at the master level. Absent row = the
--- resolver's default-channel-state contract (enabled=true, gain=0).
---
--- Schema columns: master_track_id, enabled, default_gain_db.
--- PK (master_track_id). ON DELETE CASCADE on tracks(id) — the owning
--- master sequence is implied by tracks.sequence_id.
---
--- Identity is the master AUDIO track (tracks.id), not a slot integer:
--- reordering the master's tracks reorders the channels without
--- cascading remaps, and deleting a track CASCADES the state row out.
---
--- Rule 2.13: both `enabled` and `default_gain_db` must be supplied
--- on every insert/update. The SetMasterChannelState command is the
--- canonical writer.
---
--- @file media_refs_channel_state.lua

local M = {}
local database = require("core.database")

local function bool_to_int(v)
    if v == true or v == 1 then return 1 end
    if v == false or v == 0 then return 0 end
    error("media_refs_channel_state: enabled must be true/false or 1/0")
end

function M.find(master_track_id)
    assert(type(master_track_id) == "string" and master_track_id ~= "",
        "media_refs_channel_state.find: master_track_id required")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        SELECT enabled, default_gain_db FROM media_refs_channel_state
        WHERE master_track_id = ?
    ]])
    assert(stmt, "media_refs_channel_state.find: prepare failed")
    stmt:bind_value(1, master_track_id)
    assert(stmt:exec(), "media_refs_channel_state.find: exec failed")
    local row
    if stmt:next() then
        row = {
            master_track_id = master_track_id,
            enabled         = stmt:value(0) == 1,
            default_gain_db = stmt:value(1),
        }
    end
    stmt:finalize()
    return row
end

function M.insert(fields)
    assert(type(fields) == "table",
        "media_refs_channel_state.insert: fields table required")
    assert(type(fields.master_track_id) == "string" and fields.master_track_id ~= "",
        "media_refs_channel_state.insert: master_track_id required")
    assert(fields.enabled ~= nil,
        "media_refs_channel_state.insert: enabled required (rule 2.13)")
    assert(type(fields.default_gain_db) == "number",
        "media_refs_channel_state.insert: default_gain_db required (rule 2.13)")

    local conn = database.get_connection()
    local stmt = conn:prepare([[
        INSERT INTO media_refs_channel_state
            (master_track_id, enabled, default_gain_db)
        VALUES (?, ?, ?)
    ]])
    assert(stmt, "media_refs_channel_state.insert: prepare failed")
    stmt:bind_value(1, fields.master_track_id)
    stmt:bind_value(2, bool_to_int(fields.enabled))
    stmt:bind_value(3, fields.default_gain_db)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    assert(ok, string.format(
        "media_refs_channel_state.insert: failed for master_track=%s: %s",
        fields.master_track_id, tostring(err)))
end

function M.update(fields)
    assert(type(fields) == "table",
        "media_refs_channel_state.update: fields table required")
    assert(type(fields.master_track_id) == "string" and fields.master_track_id ~= "",
        "media_refs_channel_state.update: master_track_id required")
    assert(fields.enabled ~= nil,
        "media_refs_channel_state.update: enabled required")
    assert(type(fields.default_gain_db) == "number",
        "media_refs_channel_state.update: default_gain_db required")

    local conn = database.get_connection()
    local stmt = conn:prepare([[
        UPDATE media_refs_channel_state
        SET enabled = ?, default_gain_db = ?
        WHERE master_track_id = ?
    ]])
    assert(stmt, "media_refs_channel_state.update: prepare failed")
    stmt:bind_value(1, bool_to_int(fields.enabled))
    stmt:bind_value(2, fields.default_gain_db)
    stmt:bind_value(3, fields.master_track_id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "media_refs_channel_state.update: exec failed")
end

function M.delete(master_track_id)
    assert(type(master_track_id) == "string" and master_track_id ~= "",
        "media_refs_channel_state.delete: master_track_id required")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        DELETE FROM media_refs_channel_state
        WHERE master_track_id = ?
    ]])
    assert(stmt, "media_refs_channel_state.delete: prepare failed")
    stmt:bind_value(1, master_track_id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "media_refs_channel_state.delete: exec failed")
end

return M
