--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~79 LOC
-- Volatility: unknown
--
-- @file sequence.lua
local database = require("core.database")
require("command")  -- luacheck: ignore 211 (reserved for future use)
local command_manager = require("core.command_manager")
local metadata_schemas = require("ui.metadata_schemas")
local timeline_state = require("ui.timeline.timeline_state")

local SequenceInspectable = {}
SequenceInspectable.__index = SequenceInspectable

local function load_sequence(sequence_id)
    local ok, record = pcall(database.load_sequence_record, sequence_id)
    if ok and record then
        return record
    end
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

function SequenceInspectable:get(field)
    return self._record and self._record[field]
end

function SequenceInspectable:set(field, value)
    local result = command_manager.execute("SetSequenceMetadata", {
        ["sequence_id"] = self.sequence_id,
                ["field"] = field,
                ["value"] = value,
        project_id = self.project_id,
    })
    if not result.success then
        return false, result.error_message or "failed to update sequence"
    end

    if self._record then
        self._record[field] = value
    end

    -- Dispatch signal-emitting commands so all views update
    if field == "mark_in_time" then
        command_manager.execute("SetMarkIn", {sequence_id = self.sequence_id, frame = value, project_id = self.project_id})
    elseif field == "mark_out_time" then
        command_manager.execute("SetMarkOut", {sequence_id = self.sequence_id, frame = value, project_id = self.project_id})
    elseif field == "playhead_value" then
        command_manager.execute("SetPlayhead", {sequence_id = self.sequence_id, playhead_position = value or 0, project_id = self.project_id})
    elseif field == "viewport_start_value" or field == "viewport_duration" then
        -- Viewport commands don't have signals yet — use direct setter for now
        if timeline_state and timeline_state.get_sequence_id and timeline_state.get_sequence_id() == self.sequence_id then
            if field == "viewport_start_value" then
                timeline_state.set_viewport_start_time(value or 0)
            else
                timeline_state.set_viewport_duration(value or 0)
            end
        end
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
