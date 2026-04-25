--- Master-level per-channel audio state (V13).
---
--- Sparse: a row exists only when the editor has explicitly touched
--- a channel's enabled/gain at the master level. Absent row = the
--- resolver's default-channel-state contract (enabled=true, gain=0).
---
--- Schema columns: owner_sequence_id, channel_index, enabled, default_gain_db.
--- PK (owner_sequence_id, channel_index). ON DELETE CASCADE on owner.
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

function M.find(owner_sequence_id, channel_index)
    assert(owner_sequence_id and owner_sequence_id ~= "",
        "media_refs_channel_state.find: owner_sequence_id required")
    assert(type(channel_index) == "number",
        "media_refs_channel_state.find: channel_index must be integer")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        SELECT enabled, default_gain_db FROM media_refs_channel_state
        WHERE owner_sequence_id = ? AND channel_index = ?
    ]])
    assert(stmt, "media_refs_channel_state.find: prepare failed")
    stmt:bind_value(1, owner_sequence_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "media_refs_channel_state.find: exec failed")
    local row
    if stmt:next() then
        row = {
            owner_sequence_id = owner_sequence_id,
            channel_index     = channel_index,
            enabled           = stmt:value(0) == 1,
            default_gain_db   = stmt:value(1),
        }
    end
    stmt:finalize()
    return row
end

function M.insert(fields)
    assert(type(fields) == "table",
        "media_refs_channel_state.insert: fields table required")
    assert(fields.owner_sequence_id and fields.owner_sequence_id ~= "",
        "media_refs_channel_state.insert: owner_sequence_id required")
    assert(type(fields.channel_index) == "number",
        "media_refs_channel_state.insert: channel_index required")
    assert(fields.enabled ~= nil,
        "media_refs_channel_state.insert: enabled required (rule 2.13)")
    assert(type(fields.default_gain_db) == "number",
        "media_refs_channel_state.insert: default_gain_db required (rule 2.13)")

    local conn = database.get_connection()
    local stmt = conn:prepare([[
        INSERT INTO media_refs_channel_state
            (owner_sequence_id, channel_index, enabled, default_gain_db)
        VALUES (?, ?, ?, ?)
    ]])
    assert(stmt, "media_refs_channel_state.insert: prepare failed")
    stmt:bind_value(1, fields.owner_sequence_id)
    stmt:bind_value(2, fields.channel_index)
    stmt:bind_value(3, bool_to_int(fields.enabled))
    stmt:bind_value(4, fields.default_gain_db)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    assert(ok, string.format(
        "media_refs_channel_state.insert: failed for seq=%s ch=%d: %s",
        fields.owner_sequence_id, fields.channel_index, tostring(err)))
end

function M.update(fields)
    assert(type(fields) == "table",
        "media_refs_channel_state.update: fields table required")
    assert(fields.owner_sequence_id and fields.owner_sequence_id ~= "",
        "media_refs_channel_state.update: owner_sequence_id required")
    assert(type(fields.channel_index) == "number",
        "media_refs_channel_state.update: channel_index required")
    assert(fields.enabled ~= nil,
        "media_refs_channel_state.update: enabled required")
    assert(type(fields.default_gain_db) == "number",
        "media_refs_channel_state.update: default_gain_db required")

    local conn = database.get_connection()
    local stmt = conn:prepare([[
        UPDATE media_refs_channel_state
        SET enabled = ?, default_gain_db = ?
        WHERE owner_sequence_id = ? AND channel_index = ?
    ]])
    assert(stmt, "media_refs_channel_state.update: prepare failed")
    stmt:bind_value(1, bool_to_int(fields.enabled))
    stmt:bind_value(2, fields.default_gain_db)
    stmt:bind_value(3, fields.owner_sequence_id)
    stmt:bind_value(4, fields.channel_index)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "media_refs_channel_state.update: exec failed")
end

function M.delete(owner_sequence_id, channel_index)
    assert(owner_sequence_id and owner_sequence_id ~= "",
        "media_refs_channel_state.delete: owner_sequence_id required")
    assert(type(channel_index) == "number",
        "media_refs_channel_state.delete: channel_index required")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        DELETE FROM media_refs_channel_state
        WHERE owner_sequence_id = ? AND channel_index = ?
    ]])
    assert(stmt, "media_refs_channel_state.delete: prepare failed")
    stmt:bind_value(1, owner_sequence_id)
    stmt:bind_value(2, channel_index)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "media_refs_channel_state.delete: exec failed")
end

return M
