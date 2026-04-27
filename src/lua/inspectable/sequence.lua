--- SequenceInspectable: Inspector-facing adapter for a single sequence.
--- Parallels ClipInspectable but queries the Sequence model (already the
--- canonical in-memory representation of a sequence row). Writes flow
--- through SetSequenceMetadata. TIMECODE payloads are integer-frames;
--- rate is read from the sequence, never duplicated into the payload.
---
--- @file sequence.lua
local command_manager = require("core.command_manager")
local metadata_schemas = require("ui.metadata_schemas")

local SequenceInspectable = {}
SequenceInspectable.__index = SequenceInspectable

-- Use Sequence.load (the canonical model loader) rather than
-- database.load_sequence_record — the latter returns a LEGACY shape with
-- _value suffixes (`playhead_value`, `mark_in_value`, …) that doesn't
-- match the field names Sequence.load uses everywhere else. Three
-- different naming conventions for the same columns across the codebase
-- is the root "four layers of schema drift" Joe flagged; this keeps the
-- Inspector on the Sequence.load convention.
-- pcall-swallow is test-friendly: lazy_fill_record and refresh() both
-- call this; production always has a connected DB, but unit tests
-- construct inspectables from in-memory fixtures without one. A bare
-- Sequence.load() would crash those tests before the field lookup
-- even ran.
local function load_sequence(sequence_id)
    local Sequence = require("models.sequence")
    local ok, record = pcall(Sequence.load, sequence_id)
    if ok and record then return record end
    return nil
end

function SequenceInspectable.new(opts)
    if not opts or not opts.sequence_id then
        error("SequenceInspectable.new requires sequence_id")
    end

    local self = setmetatable({}, SequenceInspectable)
    self.sequence_id = opts.sequence_id
    if not opts.project_id or opts.project_id == "" then
        error("SequenceInspectable.new requires project_id")
    end
    self.project_id = opts.project_id
    self._record = opts.sequence or load_sequence(opts.sequence_id) or {
        id = opts.sequence_id,
        project_id = self.project_id
    }
    return self
end

function SequenceInspectable:get_schema_id()
    return "sequence"
end

function SequenceInspectable:refresh()
    self._record = load_sequence(self.sequence_id) or self._record
end

-- Bridge: DB column name → field name on the Sequence model object.
-- Sequence.load() historically renamed some columns when loading into the
-- Lua object (e.g., `playhead_frame` → `playhead_position`). The Inspector
-- speaks DB column names (so SetSequenceMetadata can use them as SQL); this
-- map translates on the read path. Unlisted columns map identity.
local COLUMN_TO_MODEL_FIELD = {
    playhead_frame       = "playhead_position",
    view_start_frame     = "viewport_start_time",
    view_duration_frames = "viewport_duration",
    mark_in_frame        = "mark_in",
    mark_out_frame       = "mark_out",
    audio_sample_rate           = "audio_sample_rate",
}

local function format_frame_rate_display(fr)
    if type(fr) ~= "table" then return nil end
    local num = fr.fps_numerator
    local den = fr.fps_denominator
    if type(num) ~= "number" or type(den) ~= "number" or den == 0 then
        return nil
    end
    local fps = num / den
    -- Integer rates render without decimals; fractional rates round to 3.
    if num % den == 0 then
        return string.format("%d fps", math.floor(fps + 0.5))
    end
    return string.format("%.3f fps", fps)
end

-- Keys present on an opts.sequence passed in from SOME callers but missing
-- from others. The browser's database.load_sequences() builds a minimal
-- record (id/name/frame_rate/width/height/audio_sample_rate only) and NEVER
-- supplies mark_in / mark_out / playhead_position / start_timecode_frame /
-- viewport_*. Rather than trust any specific caller's opts.sequence shape,
-- we lazily upgrade to a Sequence.load() result on first read of a missing
-- field. Result is cached back onto _record so the load runs once per
-- inspectable.
local function lazy_fill_record(self, mapped_key)
    if self._full_record_loaded then return end
    if self._record and self._record[mapped_key] ~= nil then return end
    local full = load_sequence(self.sequence_id)
    if not full then return end
    self._record = full
    self._full_record_loaded = true
end

function SequenceInspectable:get(field)
    if not self._record then return nil end
    -- Synthetic fields computed from model state (have no direct column).
    if field == "frame_rate_display" then
        return format_frame_rate_display(self._record.frame_rate)
    end
    local mapped = COLUMN_TO_MODEL_FIELD[field] or field
    lazy_fill_record(self, mapped)
    return self._record[mapped]
end

function SequenceInspectable:set(field, value)
    assert(field and field ~= "", "SequenceInspectable:set: field is required")

    -- Payload-style input (matches ClipInspectable:set). Raw value style is
    -- no longer accepted — callers must supply {value, property_type, default_value?}.
    assert(type(value) == "table",
        string.format("SequenceInspectable:set(%s): value must be a payload table {value, property_type, ...}",
            field))
    local payload_value = value.value
    local property_type = value.property_type
    assert(property_type and property_type ~= "",
        string.format("SequenceInspectable:set(%s): property_type is required", field))

    if property_type == "TIMECODE" then
        assert(type(payload_value) == "number",
            string.format("SequenceInspectable:set(%s): TIMECODE value must be a number, got %s",
                field, type(payload_value)))
        assert(payload_value == math.floor(payload_value),
            string.format("SequenceInspectable:set(%s): TIMECODE value must be integer frames, got %s",
                field, tostring(payload_value)))
        assert(payload_value >= 0,
            string.format("SequenceInspectable:set(%s): TIMECODE value must be non-negative, got %d",
                field, payload_value))
    end

    local result = command_manager.execute_interactive("SetSequenceMetadata", {
        ["sequence_id"] = self.sequence_id,
        ["field"]       = field,
        ["value"]       = payload_value,
        project_id      = self.project_id,
    })
    assert(type(result) == "table",
        string.format("SequenceInspectable:set(%s): execute() returned %s, expected table",
            tostring(field), type(result)))
    if not result.success then
        return false, result.error_message or "failed to update sequence"
    end

    if self._record then
        self._record[field] = payload_value
    end

    -- Dispatch signal-emitting commands so all views update. Field names here
    -- are the DB column names that flow through the Inspector → whitelist path.
    if field == "mark_in_frame" then
        command_manager.execute_interactive("SetMarkIn",
            {sequence_id = self.sequence_id, frame = payload_value, project_id = self.project_id})
    elseif field == "mark_out_frame" then
        command_manager.execute_interactive("SetMarkOut",
            {sequence_id = self.sequence_id, frame = payload_value, project_id = self.project_id})
    elseif field == "playhead_frame" then
        assert(payload_value ~= nil,
            "SequenceInspectable:set(playhead_frame): value cannot be nil")
        command_manager.execute_interactive("SetPlayhead",
            {sequence_id = self.sequence_id, playhead_position = payload_value, project_id = self.project_id})
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
    -- Multi-editing sequences is not supported today.
    return false
end

return SequenceInspectable
