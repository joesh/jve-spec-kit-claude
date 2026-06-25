--- Shared write-path + load helpers for inspectables backed by a sequences
--- row. A master sequence (kind='master') and a record sequence (kind=
--- 'sequence') are the same SQLite row read through different lenses;
--- SequenceInspectable and MasterClipInspectable each present one lens
--- but write through the same commands. This module owns the work both
--- inspectables share so the two adapters diverge ONLY where their schema
--- lens differs.

local command_manager = require("core.command_manager")
local database        = require("core.database")
local Sequence        = require("models.sequence")

local M = {}

--- Soft load. Returns the model object, nil for missing-row OR
--- missing-DB, raises on real DB failures. Used by lazy_fill_record
--- paths that legitimately tolerate absence.
function M.load_sequence(sequence_id)
    return Sequence.load(sequence_id)
end

--- Strict load. Asserts with distinct messages for "no DB connection"
--- vs "row not found" so the inspector adapter's fail-fast message
--- doesn't lie about which contract was violated. Used by adapter
--- constructors and refresh().
function M.require_sequence(sequence_id, caller)
    assert(database.has_connection(), string.format(
        "%s: no active database connection — cannot load sequence %s",
        caller, sequence_id))
    local record = Sequence.load(sequence_id)
    assert(record, string.format(
        "%s: sequence %s not found in active project",
        caller, sequence_id))
    return record
end

--- Single source of truth for each command's payload-key contract.
--- Adapter SPECIALIZED_COMMANDS tables map a schema field → command
--- name; the base looks the param name up here. Renaming a command's
--- payload key changes one row in this table; both adapters pick it up.
local COMMAND_PAYLOAD_KEY = {
    SetMarkIn   = "frame",
    SetMarkOut  = "frame",
    SetPlayhead = "playhead_position",
}

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
--- `specialized_map` (schema field → command name), else the generic
--- SetSequenceMetadata. The command's payload-key comes from the
--- central COMMAND_PAYLOAD_KEY table — each command owns its own
--- payload contract; the base never repeats it per-adapter.
function M.execute_sequence_field_set(self, field, payload_value, specialized_map)
    local command_name = specialized_map[field]
    if command_name then
        local payload_key = assert(COMMAND_PAYLOAD_KEY[command_name], string.format(
            "execute_sequence_field_set: no payload key registered for %s "
            .. "(add to sequence_row_base.COMMAND_PAYLOAD_KEY)", command_name))
        return command_manager.execute_interactive(command_name, {
            sequence_id   = self.sequence_id,
            project_id    = self.project_id,
            [payload_key] = payload_value,
        })
    end
    return command_manager.execute_interactive("SetSequenceMetadata", {
        sequence_id = self.sequence_id,
        field       = field,
        value       = payload_value,
        project_id  = self.project_id,
    })
end

return M
