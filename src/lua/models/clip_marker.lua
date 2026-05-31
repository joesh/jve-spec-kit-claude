-- ClipMarker Model
-- A per-clip-instance marker: a frame offset from the clip's start, a span
-- `duration` (1 = point marker), a Resolve color name, a name, a note
-- (tooltip), and opaque `custom_data` (round-trip payload). Imported from
-- DaVinci Resolve DRP; drawn directly on the clip in the timeline.
local ClipMarker = {}
ClipMarker.__index = ClipMarker

local database = require("core.database")
local uuid = require("uuid")
local log = require("core.logger").for_area("database")

-- The 16 Resolve marker colors. Markers carry the color *name* (drawing maps
-- it to an RGB); an unknown color means the importer decoded garbage, so fail
-- fast rather than persist an unrenderable value.
local VALID_COLORS = {
    Blue = true, Cyan = true, Green = true, Yellow = true, Red = true,
    Pink = true, Purple = true, Fuchsia = true, Rose = true, Lavender = true,
    Sky = true, Mint = true, Lemon = true, Sand = true, Cocoa = true,
    Cream = true,
}

-- Create a new clip marker instance.
-- Every field is required (rule 2.13): the decoder always produces a complete
-- record (empty note / empty custom_data are passed as ""), so a missing field
-- here is a caller bug, not a value to substitute.
-- @param data table: { clip_id, frame, duration, color, name, note, custom_data, id? }
function ClipMarker.new(data)
    local function require_field(name)
        assert(data[name] ~= nil, "ClipMarker.new: missing required field: " .. name)
        return data[name]
    end

    local marker = setmetatable({}, ClipMarker)
    marker.id = data.id or uuid.generate()
    marker.clip_id = require_field("clip_id")
    marker.frame = require_field("frame")
    marker.duration = require_field("duration")
    marker.color = require_field("color")
    marker.name = require_field("name")
    marker.note = require_field("note")
    marker.custom_data = require_field("custom_data")

    assert(type(marker.frame) == "number" and marker.frame >= 0,
        "ClipMarker.new: frame must be a non-negative number")
    assert(type(marker.duration) == "number" and marker.duration >= 1,
        "ClipMarker.new: duration must be >= 1 (1 = point marker)")
    assert(VALID_COLORS[marker.color],
        "ClipMarker.new: unknown marker color: " .. tostring(marker.color))
    assert(type(marker.note) == "string",
        "ClipMarker.new: note must be a string (use '' for absent)")
    assert(type(marker.custom_data) == "string",
        "ClipMarker.new: custom_data must be a string (use '' for absent)")
    return marker
end

-- Persist this marker. Plain INSERT: a UUID collision is a bug we want to see,
-- not silently replace; re-import dedup goes through delete_for_clip first.
function ClipMarker:save()
    local conn = database.get_connection()
    assert(conn, "ClipMarker:save: no database connection")
    local stmt = conn:prepare([[
        INSERT INTO clip_markers
        (id, clip_id, frame, duration, color, name, note, custom_data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    assert(stmt, "ClipMarker:save: failed to prepare marker insert")

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.clip_id)
    stmt:bind_value(3, self.frame)
    stmt:bind_value(4, self.duration)
    stmt:bind_value(5, self.color)
    stmt:bind_value(6, self.name)
    stmt:bind_value(7, self.note)
    stmt:bind_value(8, self.custom_data)

    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "ClipMarker:save: failed to insert marker " .. tostring(self.id))
    return self
end

-- Drop every marker attached to a clip. Used by importers to make re-import
-- idempotent: the source defines the marker set for the clip, so clear before
-- re-inserting (fresh UUIDs per parse would otherwise accumulate duplicates).
-- @param clip_id string
function ClipMarker.delete_for_clip(clip_id)
    assert(clip_id and clip_id ~= "",
        "ClipMarker.delete_for_clip: clip_id required")
    local conn = database.get_connection()
    assert(conn, "ClipMarker.delete_for_clip: no database connection")
    local stmt = conn:prepare("DELETE FROM clip_markers WHERE clip_id = ?")
    assert(stmt, "ClipMarker.delete_for_clip: failed to prepare delete")
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "ClipMarker.delete_for_clip: delete failed for " .. clip_id)
end

-- Load all markers for a clip, ordered by frame.
-- @param clip_id string
-- @return table: array of ClipMarker (empty if none)
function ClipMarker.find_by_clip(clip_id)
    assert(clip_id and clip_id ~= "",
        "ClipMarker.find_by_clip: clip_id required")
    local conn = database.get_connection()
    assert(conn, "ClipMarker.find_by_clip: no database connection")
    local stmt = conn:prepare(
        "SELECT id, clip_id, frame, duration, color, name, note, custom_data "
        .. "FROM clip_markers WHERE clip_id = ? ORDER BY frame ASC")
    assert(stmt, "ClipMarker.find_by_clip: failed to prepare select")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "ClipMarker.find_by_clip: query failed for " .. clip_id)

    local markers = {}
    while stmt:next() do
        markers[#markers + 1] = setmetatable({
            id = stmt:value(0),
            clip_id = stmt:value(1),
            frame = stmt:value(2),
            duration = stmt:value(3),
            color = stmt:value(4),
            name = stmt:value(5),
            note = stmt:value(6),
            custom_data = stmt:value(7),
        }, ClipMarker)
    end
    stmt:finalize()
    log.detail("ClipMarker.find_by_clip %s → %d markers", clip_id, #markers)
    return markers
end

return ClipMarker
