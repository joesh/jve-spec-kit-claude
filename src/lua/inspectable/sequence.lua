--- SequenceInspectable: Inspector-facing adapter for a single sequence.
--- Parallels ClipInspectable but queries the Sequence model. Writes flow
--- through SetSequenceMetadata. TIMECODE payloads are integer frames; rate
--- is read from the sequence, never duplicated into the payload.

local metadata_schemas = require("ui.metadata_schemas")
local base             = require("inspectable.sequence_row_base")

local SequenceInspectable = {}
SequenceInspectable.__index = SequenceInspectable

function SequenceInspectable.new(opts)
    assert(opts and opts.sequence_id, "SequenceInspectable.new requires sequence_id")
    assert(opts.project_id and opts.project_id ~= "",
        "SequenceInspectable.new requires project_id")

    local self = setmetatable({}, SequenceInspectable)
    self.sequence_id = opts.sequence_id
    self.project_id = opts.project_id
    -- Stub fallback: the browser's database.load_sequences() may pass a
    -- partial record (id + name + frame_rate + width + height); the
    -- inspector reads other fields lazily (lazy_fill_record below). When
    -- there's no live DB and no caller-supplied record, the stub keeps
    -- :get_display_name() viable for the empty-projects path. Production
    -- selection paths always reach Sequence.load successfully.
    self._record = opts.sequence or base.load_sequence(opts.sequence_id) or {
        id = opts.sequence_id,
        project_id = self.project_id
    }
    return self
end

function SequenceInspectable:get_schema_id()
    return "sequence"
end

function SequenceInspectable:refresh()
    local reloaded = base.load_sequence(self.sequence_id)
    if reloaded then self._record = reloaded end
end

-- Schema field keys are SQL column names (so SetSequenceMetadata's whitelist
-- doubles as the SQL safety boundary — see metadata_schemas.lua sequence
-- section). Sequence.load renames a few columns on the way into the model
-- object; this map translates on the read path. Unlisted keys map identity.
local COLUMN_TO_MODEL_FIELD = {
    playhead_frame       = "playhead_position",
    view_start_frame     = "viewport_start_time",
    view_duration_frames = "viewport_duration",
    mark_in_frame        = "mark_in",
    mark_out_frame       = "mark_out",
}

local SPECIALIZED_COMMANDS = {
    mark_in_frame  = "SetMarkIn",
    mark_out_frame = "SetMarkOut",
    playhead_frame = "SetPlayhead",
}

-- The browser's database.load_sequences() builds a minimal record (id, name,
-- frame_rate, width, height, audio_sample_rate). Other callers pass the full
-- model. Lazy-fill on first read of a missing field rather than trust any
-- particular caller's shape.
local function lazy_fill_record(self, mapped_key)
    if self._full_record_loaded then return end
    if self._record and self._record[mapped_key] ~= nil then return end
    local full = base.load_sequence(self.sequence_id)
    if not full then return end
    self._record = full
    self._full_record_loaded = true
end

function SequenceInspectable:get(field)
    if not self._record then return nil end
    if field == "frame_rate_display" then
        return base.format_frame_rate_display(self._record.frame_rate)
    end
    local mapped = COLUMN_TO_MODEL_FIELD[field] or field
    lazy_fill_record(self, mapped)
    return self._record[mapped]
end

function SequenceInspectable:set(field, value)
    assert(field and field ~= "", "SequenceInspectable:set: field required")
    assert(type(value) == "table",
        "SequenceInspectable:set: value must be a payload table")
    local payload_value = value.value
    local property_type = value.property_type
    assert(property_type and property_type ~= "",
        "SequenceInspectable:set: property_type required")

    if property_type == "TIMECODE" then
        base.validate_timecode("SequenceInspectable", field, payload_value)
    end

    local result = base.execute_sequence_field_set(
        self, field, payload_value, SPECIALIZED_COMMANDS, "SequenceInspectable")

    assert(type(result) == "table",
        "SequenceInspectable:set: execute returned non-table")
    if not result.success then
        return false, result.error_message or "failed to update sequence"
    end

    if self._record then
        local mapped = COLUMN_TO_MODEL_FIELD[field] or field
        self._record[mapped] = payload_value
    end

    return true
end

function SequenceInspectable:iter_fields()
    return metadata_schemas.iter_fields_for_schema(self:get_schema_id())
end

function SequenceInspectable:get_display_name()
    if self._record then
        return self._record.name or self.sequence_id
    end
    return self.sequence_id
end

function SequenceInspectable:supports_multi_edit()
    return false
end

function SequenceInspectable:get_watcher_keys()
    return { "sequence:" .. self.sequence_id }
end

return SequenceInspectable
