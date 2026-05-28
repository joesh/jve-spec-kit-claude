--- Stateful UUID pool used by commands that must keep ids stable across
-- redo. On execute the pool is empty: every `:take()` generates a fresh
-- uuid AND remembers it on `:consumed`. The command persists `:consumed`
-- under a "created_*_ids" parameter. On redo the persisted list is fed
-- back as `preset`; the pool serves preset entries in order before
-- falling back to fresh uuids.
--
-- One pool per ENTITY KIND on a command (clips, link groups, auto-tracks,
-- split right-halves). Independent counts; one preset list per kind.
--
-- @file _id_pool.lua

local uuid = require("uuid")

local M = {}
local Pool = {}
Pool.__index = Pool

--- New pool seeded with optional `preset` list. nil/empty == fresh-only.
function M.new(preset)
    assert(preset == nil or type(preset) == "table",
        "_id_pool.new: preset must be table or nil")
    return setmetatable({
        preset   = preset or {},
        consumed = {},
        idx      = 0,
    }, Pool)
end

--- Single-id convenience: callers that persist exactly one string
-- (`created_link_group_id`) hand the string in directly. Empty-string ==
-- no preset (Insert sets "" when it had no audio+video group to create).
function M.from_one(preset_id)
    assert(preset_id == nil or type(preset_id) == "string",
        "_id_pool.from_one: preset_id must be string or nil")
    local arr = (preset_id and preset_id ~= "") and { preset_id } or {}
    return M.new(arr)
end

--- Pop the next id: preset first, fresh uuid after preset exhausts.
function Pool:take()
    self.idx = self.idx + 1
    local id = self.preset[self.idx] or uuid.generate()
    self.consumed[#self.consumed + 1] = id
    return id
end

--- The ordered list of ids served so far. Commands persist this on the
-- command record so a future redo replays with the same uuids.
function Pool:taken()
    return self.consumed
end

--- Single-id convenience: return the only id (or "" when nothing was
-- taken), shape matching the `created_link_group_id` persistence slot.
function Pool:taken_one()
    assert(#self.consumed <= 1, string.format(
        "_id_pool.taken_one: pool consumed %d ids (expected ≤1)",
        #self.consumed))
    return self.consumed[1] or ""
end

return M
