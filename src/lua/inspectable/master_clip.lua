--- MasterClipInspectable: the master-clip lens onto a `sequences.kind='master'`
--- row. A master sequence and a master clip are the SAME database row
--- (database.lua:1649 "master IS-a"); this adapter presents it through
--- the Resolve-style master-clip schema (file metadata + source range +
--- channels in Phase 2) instead of the sequence-of-tracks schema.
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
local command_manager = require("core.command_manager")
local metadata_schemas = require("ui.metadata_schemas")
local Sequence = require("models.sequence")

local MasterClipInspectable = {}
MasterClipInspectable.__index = MasterClipInspectable

local function load_sequence(sequence_id)
    local ok, record = pcall(Sequence.load, sequence_id)
    if ok and record then return record end
    return nil
end

function MasterClipInspectable.new(opts)
    assert(opts and opts.sequence_id and opts.sequence_id ~= "",
        "MasterClipInspectable.new requires sequence_id")
    assert(opts.project_id and opts.project_id ~= "",
        "MasterClipInspectable.new requires project_id")

    local self = setmetatable({}, MasterClipInspectable)
    self.sequence_id = opts.sequence_id
    self.project_id  = opts.project_id
    self._record     = opts.sequence or load_sequence(opts.sequence_id)
    assert(self._record, string.format(
        "MasterClipInspectable.new: sequence %s not found", opts.sequence_id))
    assert(self._record.kind == "master", string.format(
        "MasterClipInspectable.new: sequence %s is kind='%s'; "
        .. "MasterClipInspectable requires kind='master' (use SequenceInspectable for record sequences)",
        opts.sequence_id, tostring(self._record.kind)))
    self._primary_ref = Sequence.get_primary_media_ref(opts.sequence_id)
    return self
end

function MasterClipInspectable:get_schema_id()
    return "master_clip"
end

function MasterClipInspectable:refresh()
    local reloaded = load_sequence(self.sequence_id)
    assert(reloaded, string.format(
        "MasterClipInspectable:refresh: sequence %s vanished from the DB",
        self.sequence_id))
    self._record      = reloaded
    self._primary_ref = Sequence.get_primary_media_ref(self.sequence_id)
end

local function format_frame_rate_display(fr)
    if type(fr) ~= "table" then return nil end
    local num, den = fr.fps_numerator, fr.fps_denominator
    if type(num) ~= "number" or type(den) ~= "number" or den == 0 then
        return nil
    end
    if num % den == 0 then
        return string.format("%d fps", math.floor(num / den + 0.5))
    end
    return string.format("%.3f fps", num / den)
end

-- Field-key → sequence-record key. The shared FIELDS table in
-- metadata_schemas uses clip-style keys (mark_in, mark_out, playhead_frame);
-- Sequence.load already exposes mark_in / mark_out under the same names
-- (sequence.lua:258-259), so only playhead_frame needs a model-side rename
-- to playhead_position.
local SEQUENCE_FIELD_MAP = {
    mark_in        = "mark_in",
    mark_out       = "mark_out",
    playhead_frame = "playhead_position",
}

function MasterClipInspectable:get(field)
    assert(field and field ~= "", "MasterClipInspectable:get: field required")
    if field == "name" then
        return self._record.name
    elseif field == "rate_display" then
        return format_frame_rate_display(self._record.frame_rate)
    elseif SEQUENCE_FIELD_MAP[field] then
        return self._record[SEQUENCE_FIELD_MAP[field]]
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
    assert(field and field ~= "", "MasterClipInspectable:set: field required")
    assert(type(value) == "table",
        "MasterClipInspectable:set: value must be a payload table")
    local payload_value = value.value
    local property_type = value.property_type
    assert(property_type and property_type ~= "",
        "MasterClipInspectable:set: property_type required")

    -- Source In/Out are read-only in Phase 1; fail loud rather than silently
    -- discarding. Lands when general In/Out editing UX lands.
    assert(field ~= "source_in" and field ~= "source_out", string.format(
        "MasterClipInspectable:set: %s is read-only (Phase 1; "
        .. "edit on a timeline-clip instance instead)", field))

    if property_type == "TIMECODE" then
        assert(type(payload_value) == "number"
            and payload_value == math.floor(payload_value)
            and payload_value >= 0,
            string.format("MasterClipInspectable:set(%s): TIMECODE must be "
                .. "non-negative integer frames, got %s",
                field, tostring(payload_value)))
    end

    local specialized = {
        mark_in        = "SetMarkIn",
        mark_out       = "SetMarkOut",
        playhead_frame = "SetPlayhead",
    }

    local result
    if specialized[field] then
        local params = {
            sequence_id = self.sequence_id,
            project_id  = self.project_id,
        }
        if field == "playhead_frame" then
            params.playhead_position = payload_value
        else
            params.frame = payload_value
        end
        result = command_manager.execute_interactive(specialized[field], params)
    else
        result = command_manager.execute_interactive("SetSequenceMetadata", {
            sequence_id = self.sequence_id,
            field       = field,
            value       = payload_value,
            project_id  = self.project_id,
        })
    end

    assert(type(result) == "table",
        "MasterClipInspectable:set: execute returned non-table")
    if not result.success then
        return false, result.error_message or "failed to update master clip"
    end

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

function MasterClipInspectable:get_display_name()
    return self._record.name or self.sequence_id
end

function MasterClipInspectable:supports_multi_edit()
    return false
end

function MasterClipInspectable:get_watcher_keys()
    return { "master_clip:" .. self.sequence_id }
end

return MasterClipInspectable
