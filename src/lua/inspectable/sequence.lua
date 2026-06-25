--- SequenceInspectable: Inspector-facing adapter for a single sequence.
--- Parallels ClipInspectable but queries the Sequence model. Writes flow
--- through SetSequenceMetadata. TIMECODE payloads are integer frames; rate
--- is read from the sequence, never duplicated into the payload.

local metadata_schemas = require("ui.metadata_schemas")
local base             = require("inspectable.sequence_row_base")

local SequenceInspectable = {}
SequenceInspectable.__index = SequenceInspectable

local SEQUENCE_KIND = "sequence"

function SequenceInspectable.new(opts)
    assert(opts and opts.sequence_id, "SequenceInspectable.new requires sequence_id")
    assert(opts.project_id and opts.project_id ~= "",
        "SequenceInspectable.new requires project_id")

    local self = setmetatable({}, SequenceInspectable)
    self.sequence_id = opts.sequence_id
    self.project_id = opts.project_id
    -- Browser's database.load_sequences() may pass a partial record (id +
    -- name + frame_rate + width + height); lazy_fill_record below pulls
    -- the rest on first miss. Selection paths that don't pre-load pass
    -- only sequence_id + project_id and rely on require_sequence_of_kind
    -- here — which distinguishes "no DB" from "row not found" AND
    -- enforces the lens-duality contract (kind='sequence').
    if opts.sequence then
        base.assert_kind(opts.sequence, SEQUENCE_KIND,
            self.sequence_id, "SequenceInspectable.new")
        self._record = opts.sequence
    else
        self._record = base.require_sequence_of_kind(
            self.sequence_id, SEQUENCE_KIND, "SequenceInspectable.new")
    end
    return self
end

function SequenceInspectable:get_schema_id()
    return "sequence"
end

function SequenceInspectable:refresh()
    self._record = base.require_sequence_of_kind(
        self.sequence_id, SEQUENCE_KIND, "SequenceInspectable:refresh")
    self._lazy_fill_succeeded = false
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

-- Schema field key → command name. Each command's payload-key lives
-- in sequence_row_base.SPECIALIZED_COMMAND_PAYLOAD_KEY (single source of
-- truth); adapters only own the field→command mapping.
local SPECIALIZED_COMMANDS = {
    mark_in_frame  = "SetMarkIn",
    mark_out_frame = "SetMarkOut",
    playhead_frame = "SetPlayhead",
}

-- The browser's database.load_sequences() builds a minimal record (id, name,
-- frame_rate, width, height, audio_sample_rate). Other callers pass the full
-- model. Lazy-fill on first read of a missing field rather than trust any
-- particular caller's shape. Cannot distinguish "field absent" from
-- "field=nil" in Lua, so a deliberately-unset mark trips this path too —
-- silent no-op when load_sequence returns nil is the conservative behavior
-- (mid-session DB disconnect risk tracked separately).
local function lazy_fill_record(self, mapped_key)
    if self._lazy_fill_succeeded then return end
    if self._record[mapped_key] ~= nil then return end
    local full = base.load_sequence(self.sequence_id)
    if not full then return end
    base.assert_kind(full, SEQUENCE_KIND,
        self.sequence_id, "SequenceInspectable.lazy_fill_record")
    self._record = full
    self._lazy_fill_succeeded = true
end

function SequenceInspectable:get(field)
    if field == "frame_rate_display" then
        return base.format_frame_rate_display(self._record.frame_rate)
    end
    local mapped = COLUMN_TO_MODEL_FIELD[field] or field
    lazy_fill_record(self, mapped)
    return self._record[mapped]
end

function SequenceInspectable:set(field, value)
    local payload_value, property_type =
        base.unpack_payload("SequenceInspectable", field, value)

    if property_type == "TIMECODE" then
        base.validate_timecode("SequenceInspectable", field, payload_value)
    end

    local result = base.execute_sequence_field_set(
        self, field, payload_value, SPECIALIZED_COMMANDS)

    local ok, err = base.unwrap_command_result("SequenceInspectable:set", result)
    if not ok then return false, err end

    local mapped = COLUMN_TO_MODEL_FIELD[field] or field
    self._record[mapped] = payload_value
    return true
end

function SequenceInspectable:iter_fields()
    return metadata_schemas.iter_fields_for_schema(self:get_schema_id())
end

function SequenceInspectable:get_display_name()
    assert(self._record.name and self._record.name ~= "", string.format(
        "SequenceInspectable:get_display_name: sequence %s has empty name "
        .. "(sequences.name is NOT NULL by schema)", self.sequence_id))
    return self._record.name
end

function SequenceInspectable:supports_multi_edit()
    return false
end

function SequenceInspectable:get_watcher_keys()
    return { "sequence:" .. self.sequence_id }
end

return SequenceInspectable
