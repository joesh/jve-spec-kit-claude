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

--- Strict load + kind check. Enforces the lens-duality contract
--- symmetrically across both adapters: SequenceInspectable presents
--- kind='sequence' rows, MasterClipInspectable presents kind='master'.
--- A mismatch is a routing bug — fail loud at construction/refresh
--- rather than silently writing master fields through the record
--- schema (or vice versa).
function M.require_sequence_of_kind(sequence_id, expected_kind, caller)
    local record = M.require_sequence(sequence_id, caller)
    M.assert_kind(record, expected_kind, sequence_id, caller)
    return record
end

--- Asserts the kind of an already-in-hand sequence record. Used when
--- the adapter accepts opts.sequence (already-loaded row) and must
--- still enforce the lens-duality contract before adopting it. Single
--- source of truth for the kind-mismatch assert message — require_*_of_kind
--- delegates here.
function M.assert_kind(record, expected_kind, sequence_id, caller)
    assert(record.kind == expected_kind, string.format(
        "%s: sequence %s is kind='%s'; this adapter requires kind='%s' "
        .. "(use the other inspectable lens)",
        caller, sequence_id, tostring(record.kind), expected_kind))
end

--- Payload-key for each specialized command's primary value. The
--- generic SetSequenceMetadata path doesn't appear here because its
--- payload shape is fixed (field/value pair) and lives at the call
--- site in execute_sequence_field_set. Renaming a specialized
--- command's payload key changes one row in this table; both
--- adapters pick it up.
local SPECIALIZED_COMMAND_PAYLOAD_KEY = {
    SetMarkIn   = "frame",
    SetMarkOut  = "frame",
    SetPlayhead = "playhead_position",
}

--- Adapter :set methods all open with the same envelope-unpack:
--- value must be a payload table carrying `value` + `property_type`
--- (and optionally `default_value` for ClipInspectable). Lifted at
--- the third copy. Returns three values; callers that don't use
--- `default_value` just discard it.
function M.unpack_payload(caller, field, value)
    assert(field and field ~= "", string.format(
        "%s:set: field required", caller))
    assert(type(value) == "table", string.format(
        "%s:set(%s): expected payload table {value, property_type[, default_value]}, got %s",
        caller, field, type(value)))
    local property_type = value.property_type
    assert(property_type and property_type ~= "", string.format(
        "%s:set(%s): payload.property_type is required", caller, field))
    return value.value, property_type, value.default_value
end

--- Command-result envelope: success is non-optional, error_message
--- is mandatory when success=false. A command that violates the
--- contract should fail loud here rather than have the adapter
--- fabricate a generic error string.
function M.unwrap_command_result(caller, result)
    assert(type(result) == "table", string.format(
        "%s: command returned non-table result", caller))
    if result.success then return true end
    assert(result.error_message and result.error_message ~= "", string.format(
        "%s: command returned success=false without error_message (command-contract violation)",
        caller))
    return false, result.error_message
end

--- "%d fps" when integer; "%.3f fps" otherwise. nil for malformed input.
function M.format_frame_rate_display(frame_rate)
    if type(frame_rate) ~= "table" then return nil end
    local num, den = frame_rate.fps_numerator, frame_rate.fps_denominator
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
--- central SPECIALIZED_COMMAND_PAYLOAD_KEY table — each command owns its own
--- payload contract; the base never repeats it per-adapter.
function M.execute_sequence_field_set(self, field, payload_value, specialized_map)
    local command_name = specialized_map[field]
    if command_name then
        local payload_key = assert(SPECIALIZED_COMMAND_PAYLOAD_KEY[command_name], string.format(
            "execute_sequence_field_set: no payload key registered for %s "
            .. "(add to sequence_row_base.SPECIALIZED_COMMAND_PAYLOAD_KEY)", command_name))
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
