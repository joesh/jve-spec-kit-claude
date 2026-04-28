--- SetSequenceStartTC command (Feature 013, T063).
---
--- Per FR-017 / contracts/commands.md §SetSequenceStartTC:
---   Args: { sequence_id, medium ∈ {'video','audio'}, tc_value }.
---     sequence_id must reference an existing sequence (rule 2.29).
---     tc_value must be an integer (frames for video; samples for audio).
---   Mutation:
---     medium='video': sequences.video_start_tc_frame ← tc_value.
---     medium='audio': sequences.audio_start_tc_samples ← tc_value.
---   Undo: prior column value (may be NULL).
---   Signal: sequence_content_changed(sequence_id) — affects every
---     clip that references this sequence (their timeline-position
---     translation depends on the start TC).
---
--- @file set_sequence_start_tc.lua

local M = {}

local Sequence = require("models.sequence")
local log      = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "SetSequenceStartTC: '%s' is required (rule 2.29)", name))
    return v
end

local FIELD_FOR_MEDIUM = {
    video = "video_start_tc_frame",
    audio = "audio_start_tc_samples",
}

function M.execute(args)
    assert(type(args) == "table",
        "SetSequenceStartTC.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local medium = args.medium
    assert(medium == "video" or medium == "audio", string.format(
        "SetSequenceStartTC: medium must be 'video' or 'audio'; got %s",
        tostring(medium)))
    local tc_value = args.tc_value
    assert(type(tc_value) == "number"
        and tc_value == math.floor(tc_value), string.format(
        "SetSequenceStartTC: tc_value must be an integer; got %s",
        tostring(tc_value)))

    local seq = Sequence.find(sequence_id)
    assert(seq, string.format(
        "SetSequenceStartTC: sequence %s not found", sequence_id))

    local field = FIELD_FOR_MEDIUM[medium]
    local prior_value = seq[field]
    Sequence.update(sequence_id, { [field] = tc_value })

    log.event("SetSequenceStartTC: seq=%s medium=%s %s -> %s",
        sequence_id, medium, tostring(prior_value), tostring(tc_value))

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return {
        sequence_id  = sequence_id,
        medium       = medium,
        prior_value  = prior_value,
    }
end

function M.undo(capture)
    assert(type(capture) == "table",
        "SetSequenceStartTC.undo: capture table required")
    -- prior_value may be nil (column was NULL). Sequence.update skips nil
    -- entries via pairs(), so the dedicated setter is the only correct
    -- restore path.
    Sequence.set_start_tc(capture.sequence_id, capture.medium, capture.prior_value)

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        medium      = { required = true },
        tc_value    = { required = true },
    },
    persisted = {
        prior_value_present = { kind = "boolean" },
        prior_value         = { kind = "number" },
        medium              = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetSequenceStartTC"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetSequenceStartTC: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("medium", cap.medium)
        command:set_parameter("prior_value_present", cap.prior_value ~= nil)
        if cap.prior_value ~= nil then
            command:set_parameter("prior_value", cap.prior_value)
        end
        return true
    end

    command_undoers["SetSequenceStartTC"] = function(command)
        local args = command:get_all_parameters()
        local prior_value = nil
        if args.prior_value_present then
            assert(type(args.prior_value) == "number",
                "SetSequenceStartTC.undo: prior_value_present=true but prior_value missing/non-number")
            prior_value = args.prior_value
        end
        M.undo({
            sequence_id = args.sequence_id,
            medium      = args.medium,
            prior_value = prior_value,
        })
        return true
    end

    return {
        executor = command_executors["SetSequenceStartTC"],
        undoer   = command_undoers["SetSequenceStartTC"],
        spec     = SPEC,
    }
end

return M
