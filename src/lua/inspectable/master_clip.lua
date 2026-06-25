--- MasterClipInspectable: the master-clip lens onto a `sequences.kind='master'`
--- row. A master sequence and a master clip are the SAME database row
--- (`database.build_master_clip_entry` "master IS-a"); this adapter presents
--- it through the Resolve-style master-clip schema (file metadata + source
--- range + channels in Phase 2) instead of the sequence-of-tracks schema.
---
--- Reads aggregate:
---   * sequence row     — name, marks, playhead, frame rate
---   * primary media_ref — media_id, source_in, source_out
---   * media row        — offline state
---
--- Writes (Phase 1):
---   * name            → SetSequenceMetadata
---   * mark_in / mark_out → SetMarkIn / SetMarkOut
---   * playhead_frame  → SetPlayhead
---   * source_in / source_out → assert (read-only Phase 1; write command
---       deferred per spec 012 amendment)
---   * media_id / offline / rate_display — schema-declared read_only.
---
--- @file master_clip.lua
local metadata_schemas = require("ui.metadata_schemas")
local Sequence         = require("models.sequence")
local Track            = require("models.track")
local base             = require("inspectable.sequence_row_base")

local MasterClipInspectable = {}
MasterClipInspectable.__index = MasterClipInspectable

local MASTER_KIND = "master"

function MasterClipInspectable.new(opts)
    assert(opts and opts.sequence_id and opts.sequence_id ~= "",
        "MasterClipInspectable.new requires sequence_id")
    assert(opts.project_id and opts.project_id ~= "",
        "MasterClipInspectable.new requires project_id")

    local self = setmetatable({}, MasterClipInspectable)
    self.sequence_id = opts.sequence_id
    self.project_id  = opts.project_id
    if opts.sequence then
        base.assert_kind(opts.sequence, MASTER_KIND,
            self.sequence_id, "MasterClipInspectable.new")
        self._record = opts.sequence
    else
        self._record = base.require_sequence_of_kind(
            self.sequence_id, MASTER_KIND, "MasterClipInspectable.new")
    end
    self._primary_ref = Sequence.get_primary_media_ref(opts.sequence_id)
    return self
end

function MasterClipInspectable:get_schema_id()
    return "master_clip"
end

function MasterClipInspectable:refresh()
    self._record = base.require_sequence_of_kind(
        self.sequence_id, MASTER_KIND, "MasterClipInspectable:refresh")
    self._lazy_fill_succeeded = false
    self._primary_ref = Sequence.get_primary_media_ref(self.sequence_id)
end

-- Field-key → sequence-record key. The shared FIELDS table in
-- metadata_schemas uses clip-style keys (mark_in, mark_out, playhead_frame);
-- Sequence.load already exposes mark_in / mark_out under the same names, so
-- only playhead_frame needs a model-side rename to playhead_position.
local SEQUENCE_FIELD_MAP = {
    mark_in        = "mark_in",
    mark_out       = "mark_out",
    playhead_frame = "playhead_position",
}

-- Schema field key → command name. Each command's payload-key lives
-- in sequence_row_base.SPECIALIZED_COMMAND_PAYLOAD_KEY (single source of
-- truth).
local SPECIALIZED_COMMANDS = {
    mark_in        = "SetMarkIn",
    mark_out       = "SetMarkOut",
    playhead_frame = "SetPlayhead",
}

-- Browser path (database.build_master_clip_entry) supplies the flat
-- master-clip projection: id, kind, name, frame_rate, source_in/out, media
-- — but NOT mark_in / mark_out / playhead_position. Lazy-load on first
-- read of an absent record-side field so the inspector shows real values
-- on first render. Symmetric with sequence.lua's lazy_fill_record (same
-- "deliberately-nil vs partial-record" caveat tracked in
-- todo_inspectable_lazy_fill_disconnect_silent_nil.md).
local function lazy_fill_record(self, mapped_key)
    if self._lazy_fill_succeeded then return end
    if self._record[mapped_key] ~= nil then return end
    local full = base.load_sequence(self.sequence_id)
    if not full then return end
    base.assert_kind(full, MASTER_KIND,
        self.sequence_id, "MasterClipInspectable.lazy_fill_record")
    self._record = full
    self._lazy_fill_succeeded = true
end

function MasterClipInspectable:get(field)
    assert(field and field ~= "", "MasterClipInspectable:get: field required")
    if field == "name" then
        return self._record.name
    elseif field == "rate_display" then
        return base.format_frame_rate_display(self._record.frame_rate)
    elseif SEQUENCE_FIELD_MAP[field] then
        local mapped = SEQUENCE_FIELD_MAP[field]
        lazy_fill_record(self, mapped)
        return self._record[mapped]
    end
    if field == "media_id" then
        return self._primary_ref and self._primary_ref.media_id
    elseif field == "source_in" then
        return self._primary_ref and self._primary_ref.source_in_frame
    elseif field == "source_out" then
        return self._primary_ref and self._primary_ref.source_out_frame
    elseif field == "offline" then
        -- offline iff no media row OR media row carries a non-empty offline_note.
        if not self._primary_ref then return true end
        local note = self._primary_ref.media_offline
        return type(note) == "string" and note ~= ""
    end
    return nil
end

function MasterClipInspectable:set(field, value)
    local payload_value, property_type =
        base.unpack_payload("MasterClipInspectable", field, value)

    -- Source In/Out are read-only in Phase 1; fail loud rather than silently
    -- discarding. Lands when general In/Out editing UX lands.
    assert(field ~= "source_in" and field ~= "source_out", string.format(
        "MasterClipInspectable:set: %s is read-only (Phase 1; "
        .. "edit on a timeline-clip instance instead)", field))

    if property_type == "TIMECODE" then
        base.validate_timecode("MasterClipInspectable", field, payload_value)
    end

    local result = base.execute_sequence_field_set(
        self, field, payload_value, SPECIALIZED_COMMANDS)

    local ok, err = base.unwrap_command_result("MasterClipInspectable:set", result)
    if not ok then return false, err end

    if SEQUENCE_FIELD_MAP[field] then
        self._record[SEQUENCE_FIELD_MAP[field]] = payload_value
    elseif field == "name" then
        self._record.name = payload_value
    end

    return true
end

function MasterClipInspectable:iter_fields()
    return metadata_schemas.iter_fields_for_schema(self:get_schema_id())
end

--- Phase 2 read-only Channels section. Master AUDIO tracks present as
--- one row per channel, ordered by tracks.track_index ASC (the channel
--- slot is the track slot — same as how the resolver lays the master out;
--- per Joe 2026-06-24). channel_index is 1-based for display. Iterator
--- form so the renderer can `for ch in mc:iter_channels() do ... end`
--- without a temporary array.
function MasterClipInspectable:iter_channels()
    local audio_tracks = Track.find_by_sequence(self.sequence_id, "AUDIO")
    local i = 0
    return function()
        i = i + 1
        local t = audio_tracks[i]
        if not t then return nil end
        return { channel_index = t.track_index, name = t.name }
    end
end

function MasterClipInspectable:get_display_name()
    assert(self._record.name and self._record.name ~= "", string.format(
        "MasterClipInspectable:get_display_name: master %s has empty name "
        .. "(sequences.name is NOT NULL by schema)", self.sequence_id))
    return self._record.name
end

function MasterClipInspectable:supports_multi_edit()
    return false
end

function MasterClipInspectable:get_watcher_keys()
    return { "master_clip:" .. self.sequence_id }
end

return MasterClipInspectable
