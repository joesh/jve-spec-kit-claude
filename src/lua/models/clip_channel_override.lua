--- Per-clip per-channel audio override (V13).
---
--- Sparse: a row exists ONLY when the editor has explicitly touched
--- a channel's enabled/gain on that clip. Absent row = inherit the
--- nested sequence's state (which in turn may come from
--- media_refs_channel_state at the leaf master).
---
--- Schema columns: clip_id, channel_index, enabled (INTEGER), gain_db.
--- PK (clip_id, channel_index). ON DELETE CASCADE on clip_id.
---
--- Per rule 2.13 (no fallbacks): both `enabled` and `gain_db` must be
--- supplied explicitly to insert. The ToggleClipChannel command
--- materializes inherited values via Sequence.get_master_channel_state
--- before insert.
---
--- @file clip_channel_override.lua

local M = {}
local database = require("core.database")

local function bool_to_int(v)
    if v == true or v == 1 then return 1 end
    if v == false or v == 0 then return 0 end
    error("clip_channel_override: enabled must be true/false or 1/0; got "
        .. tostring(v))
end

--- Find one row by (clip_id, channel_index). Returns table or nil.
--- List all override rows for a clip, sorted by channel_index. Used
--- by ExpandAudio (project source overrides onto expanded clips) and
--- CollapseAudio (gather expanded-clip overrides into composite form).
function M.find_all(clip_id)
    assert(clip_id and clip_id ~= "",
        "clip_channel_override.find_all: clip_id required")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        SELECT clip_id, channel_index, enabled, gain_db
        FROM clip_channel_override WHERE clip_id = ?
        ORDER BY channel_index ASC
    ]])
    assert(stmt, "clip_channel_override.find_all: prepare failed")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "clip_channel_override.find_all: exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            clip_id       = stmt:value(0),
            channel_index = stmt:value(1),
            enabled       = stmt:value(2) == 1,
            gain_db       = stmt:value(3),
        }
    end
    stmt:finalize()
    return rows
end

function M.find(clip_id, channel_index)
    assert(clip_id and clip_id ~= "", "clip_channel_override.find: clip_id required")
    assert(type(channel_index) == "number",
        "clip_channel_override.find: channel_index must be integer")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        SELECT clip_id, channel_index, enabled, gain_db
        FROM clip_channel_override
        WHERE clip_id = ? AND channel_index = ?
    ]])
    assert(stmt, "clip_channel_override.find: prepare failed")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "clip_channel_override.find: exec failed")
    local row
    if stmt:next() then
        row = {
            clip_id       = stmt:value(0),
            channel_index = stmt:value(1),
            enabled       = stmt:value(2) == 1,
            gain_db       = stmt:value(3),
        }
    end
    stmt:finalize()
    return row
end

--- INSERT a row. Errors if (clip_id, channel_index) already exists
--- (PK collision). Caller knows whether to insert or update.
---
--- @param fields { clip_id, channel_index, enabled (bool), gain_db }
function M.insert(fields)
    assert(type(fields) == "table",
        "clip_channel_override.insert: fields table required")
    assert(fields.clip_id and fields.clip_id ~= "",
        "clip_channel_override.insert: clip_id required")
    assert(type(fields.channel_index) == "number",
        "clip_channel_override.insert: channel_index required")
    assert(fields.enabled ~= nil,
        "clip_channel_override.insert: enabled required (rule 2.13)")
    assert(type(fields.gain_db) == "number",
        "clip_channel_override.insert: gain_db required (rule 2.13)")

    local conn = database.get_connection()
    local stmt = conn:prepare([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES (?, ?, ?, ?)
    ]])
    assert(stmt, "clip_channel_override.insert: prepare failed")
    stmt:bind_value(1, fields.clip_id)
    stmt:bind_value(2, fields.channel_index)
    stmt:bind_value(3, bool_to_int(fields.enabled))
    stmt:bind_value(4, fields.gain_db)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    assert(ok, string.format(
        "clip_channel_override.insert: failed for clip=%s channel=%d: %s",
        fields.clip_id, fields.channel_index, tostring(err)))
end

--- Update existing (clip_id, channel_index) row. Errors if no row.
---
--- @param fields { clip_id, channel_index, enabled (bool), gain_db }
function M.update(fields)
    assert(type(fields) == "table",
        "clip_channel_override.update: fields table required")
    assert(fields.clip_id and fields.clip_id ~= "",
        "clip_channel_override.update: clip_id required")
    assert(type(fields.channel_index) == "number",
        "clip_channel_override.update: channel_index required")
    assert(fields.enabled ~= nil,
        "clip_channel_override.update: enabled required")
    assert(type(fields.gain_db) == "number",
        "clip_channel_override.update: gain_db required")

    local conn = database.get_connection()
    local stmt = conn:prepare([[
        UPDATE clip_channel_override
        SET enabled = ?, gain_db = ?
        WHERE clip_id = ? AND channel_index = ?
    ]])
    assert(stmt, "clip_channel_override.update: prepare failed")
    stmt:bind_value(1, bool_to_int(fields.enabled))
    stmt:bind_value(2, fields.gain_db)
    stmt:bind_value(3, fields.clip_id)
    stmt:bind_value(4, fields.channel_index)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format(
        "clip_channel_override.update: failed for clip=%s channel=%d",
        fields.clip_id, fields.channel_index))
end

--- DELETE one row. Idempotent (no error if absent).
function M.delete(clip_id, channel_index)
    assert(clip_id and clip_id ~= "",
        "clip_channel_override.delete: clip_id required")
    assert(type(channel_index) == "number",
        "clip_channel_override.delete: channel_index required")
    local conn = database.get_connection()
    local stmt = conn:prepare([[
        DELETE FROM clip_channel_override
        WHERE clip_id = ? AND channel_index = ?
    ]])
    assert(stmt, "clip_channel_override.delete: prepare failed")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format(
        "clip_channel_override.delete: exec failed for clip=%s channel=%d",
        clip_id, channel_index))
end

return M
