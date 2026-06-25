--- Shared write-path + load helpers for inspectables backed by a sequences
--- row. A master sequence (kind='master') and a record sequence (kind=
--- 'sequence') are the same SQLite row read through different lenses;
--- SequenceInspectable and MasterClipInspectable each present one lens
--- but write through the same commands. This module owns the work both
--- inspectables share so the two adapters diverge ONLY where their schema
--- lens differs.

local command_manager = require("core.command_manager")
local Sequence        = require("models.sequence")

local M = {}

--- Load a sequence row. Returns the model object, or nil when there is no
--- live DB connection / no row with that id. Raises on actual DB failures
--- (Sequence.load uses `error()` for query failures). The previous adapter
--- code wrapped this in pcall and discarded errors — that hid DB failures
--- behind misleading "not found" messages.
function M.load_sequence(sequence_id)
    return Sequence.load(sequence_id)
end

--- "%d fps" when integer; "%.3f fps" otherwise. nil for malformed input.
function M.format_frame_rate_display(fr)
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

--- TIMECODE payload must be a non-negative integer frame count. Same rule
--- both sides of the lens — extracted so a future schema-type change
--- (e.g. allow negative frames for pre-roll) lands in one place.
function M.validate_timecode(caller, field, payload_value)
    assert(type(payload_value) == "number"
        and payload_value == math.floor(payload_value)
        and payload_value >= 0,
        string.format("%s:set(%s): TIMECODE must be non-negative integer frames, got %s",
            caller, field, tostring(payload_value)))
end

--- Dispatch a field write: specialized command if `field` is in
--- `specialized_map` (key→command name), else the generic
--- SetSequenceMetadata. `playhead_frame` routes the payload through the
--- `playhead_position` param name; all other specialized fields use `frame`.
--- Returns the raw command result table.
function M.execute_sequence_field_set(self, field, payload_value, specialized_map, caller)
    if specialized_map[field] then
        local params = {
            sequence_id = self.sequence_id,
            project_id  = self.project_id,
        }
        if field == "playhead_frame" then
            params.playhead_position = payload_value
        else
            params.frame = payload_value
        end
        return command_manager.execute_interactive(specialized_map[field], params)
    end
    return command_manager.execute_interactive("SetSequenceMetadata", {
        sequence_id = self.sequence_id,
        field       = field,
        value       = payload_value,
        project_id  = self.project_id,
    })
end

return M
