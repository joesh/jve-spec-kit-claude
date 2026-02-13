--- Mark Commands — undoable mark in/out on any sequence
--
-- Commands:
-- - SetMarkIn (undoable): set mark_in at frame (inclusive)
-- - SetMarkOut (undoable): set mark_out at frame (inclusive — stored as frame+1, exclusive)
-- - ClearMarkIn (undoable): clear mark_in only
-- - ClearMarkOut (undoable): clear mark_out only
-- - ClearMarks (undoable): clear both marks
-- - GetMarkIn (query): return mark_in value (inclusive)
-- - GetMarkOut (query): return mark_out value (exclusive)
-- - GoToMarkIn (non-undoable): set playhead to mark_in
-- - GoToMarkOut (non-undoable): set playhead to mark_out - 1 (last included frame)
--
-- Out-point convention (industry standard):
-- mark_in is INCLUSIVE (first frame in range).
-- mark_out is EXCLUSIVE (first frame NOT in range).
-- SetMarkOut accepts the inclusive frame (what user sees) and stores frame+1.
-- Duration = mark_out - mark_in.
--
-- All take sequence_id (required). Set commands take frame (required).
-- Undoable commands store old value on command for undo.
-- Emit "marks_changed" signal after execute and undo.
--
-- @file set_marks.lua
local M = {}
local Signals = require("core.signals")

local function load_sequence(sequence_id)
    local Sequence = require("models.sequence")
    local seq = Sequence.load(sequence_id)
    assert(seq, string.format("set_marks: sequence %s not found", tostring(sequence_id)))
    return seq
end

local function emit_marks_changed(sequence_id)
    Signals.emit("marks_changed", sequence_id)
end

-- Specs
local SET_MARK_IN_SPEC = {
    undoable = true,
    args = {
        sequence_id = { required = true, kind = "string" },
        frame = { required = true, kind = "number" },
    },
}

local SET_MARK_OUT_SPEC = {
    undoable = true,
    args = {
        sequence_id = { required = true, kind = "string" },
        frame = { required = true, kind = "number" },
    },
}

local CLEAR_MARK_IN_SPEC = {
    undoable = true,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

local CLEAR_MARK_OUT_SPEC = {
    undoable = true,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

local CLEAR_MARKS_SPEC = {
    undoable = true,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

local GET_MARK_IN_SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

local GET_MARK_OUT_SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

local GO_TO_MARK_IN_SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

local GO_TO_MARK_OUT_SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true, kind = "string" },
    },
}

function M.register(executors, undoers)
    ---------------------------------------------------------------------------
    -- SetMarkIn
    ---------------------------------------------------------------------------
    executors["SetMarkIn"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "SetMarkIn: sequence_id is required")
        assert(type(args.frame) == "number",
            "SetMarkIn: frame is required and must be a number")

        local seq = load_sequence(args.sequence_id)
        local old_value = seq.mark_in
        command:set_parameter("_old_mark_in", old_value)

        seq.mark_in = args.frame
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    undoers["SetMarkIn"] = function(command)
        local args = command:get_all_parameters()
        local seq = load_sequence(args.sequence_id)
        seq.mark_in = args._old_mark_in
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- SetMarkOut
    ---------------------------------------------------------------------------
    executors["SetMarkOut"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "SetMarkOut: sequence_id is required")
        assert(type(args.frame) == "number",
            "SetMarkOut: frame is required and must be a number")

        local seq = load_sequence(args.sequence_id)
        local old_value = seq.mark_out
        command:set_parameter("_old_mark_out", old_value)

        -- Store exclusive boundary: frame is the last included frame,
        -- stored value is first excluded frame (industry standard)
        seq.mark_out = args.frame + 1
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    undoers["SetMarkOut"] = function(command)
        local args = command:get_all_parameters()
        local seq = load_sequence(args.sequence_id)
        seq.mark_out = args._old_mark_out
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- ClearMarkIn
    ---------------------------------------------------------------------------
    executors["ClearMarkIn"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "ClearMarkIn: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        command:set_parameter("_old_mark_in", seq.mark_in)

        seq.mark_in = nil
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    undoers["ClearMarkIn"] = function(command)
        local args = command:get_all_parameters()
        local seq = load_sequence(args.sequence_id)
        seq.mark_in = args._old_mark_in
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- ClearMarkOut
    ---------------------------------------------------------------------------
    executors["ClearMarkOut"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "ClearMarkOut: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        command:set_parameter("_old_mark_out", seq.mark_out)

        seq.mark_out = nil
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    undoers["ClearMarkOut"] = function(command)
        local args = command:get_all_parameters()
        local seq = load_sequence(args.sequence_id)
        seq.mark_out = args._old_mark_out
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- ClearMarks (both)
    ---------------------------------------------------------------------------
    executors["ClearMarks"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "ClearMarks: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        command:set_parameter("_old_mark_in", seq.mark_in)
        command:set_parameter("_old_mark_out", seq.mark_out)

        seq.mark_in = nil
        seq.mark_out = nil
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    undoers["ClearMarks"] = function(command)
        local args = command:get_all_parameters()
        local seq = load_sequence(args.sequence_id)
        seq.mark_in = args._old_mark_in
        seq.mark_out = args._old_mark_out
        seq:save()
        emit_marks_changed(args.sequence_id)
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- GetMarkIn (query, non-undoable)
    ---------------------------------------------------------------------------
    executors["GetMarkIn"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "GetMarkIn: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        return { success = true, result_data = { mark_in = seq.mark_in } }
    end

    ---------------------------------------------------------------------------
    -- GetMarkOut (query, non-undoable)
    ---------------------------------------------------------------------------
    executors["GetMarkOut"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "GetMarkOut: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        return { success = true, result_data = { mark_out = seq.mark_out } }
    end

    ---------------------------------------------------------------------------
    -- GoToMarkIn (non-undoable): set playhead to mark_in
    ---------------------------------------------------------------------------
    executors["GoToMarkIn"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "GoToMarkIn: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        if seq.mark_in then
            seq.playhead_position = seq.mark_in
            seq:save()
            Signals.emit("playhead_changed", args.sequence_id, seq.mark_in)
        end
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- GoToMarkOut (non-undoable): set playhead to last included frame
    ---------------------------------------------------------------------------
    executors["GoToMarkOut"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "GoToMarkOut: sequence_id is required")

        local seq = load_sequence(args.sequence_id)
        if seq.mark_out then
            -- mark_out is exclusive; last included frame = mark_out - 1
            local target = seq.mark_out - 1
            seq.playhead_position = target
            seq:save()
            Signals.emit("playhead_changed", args.sequence_id, target)
        end
        return { success = true }
    end

    ---------------------------------------------------------------------------
    -- Return registrations (multi-command style B)
    ---------------------------------------------------------------------------
    return {
        ["SetMarkIn"] = { executor = executors["SetMarkIn"], undoer = undoers["SetMarkIn"], spec = SET_MARK_IN_SPEC },
        ["SetMarkOut"] = { executor = executors["SetMarkOut"], undoer = undoers["SetMarkOut"], spec = SET_MARK_OUT_SPEC },
        ["ClearMarkIn"] = { executor = executors["ClearMarkIn"], undoer = undoers["ClearMarkIn"], spec = CLEAR_MARK_IN_SPEC },
        ["ClearMarkOut"] = { executor = executors["ClearMarkOut"], undoer = undoers["ClearMarkOut"], spec = CLEAR_MARK_OUT_SPEC },
        ["ClearMarks"] = { executor = executors["ClearMarks"], undoer = undoers["ClearMarks"], spec = CLEAR_MARKS_SPEC },
        ["GetMarkIn"] = { executor = executors["GetMarkIn"], spec = GET_MARK_IN_SPEC },
        ["GetMarkOut"] = { executor = executors["GetMarkOut"], spec = GET_MARK_OUT_SPEC },
        ["GoToMarkIn"] = { executor = executors["GoToMarkIn"], spec = GO_TO_MARK_IN_SPEC },
        ["GoToMarkOut"] = { executor = executors["GoToMarkOut"], spec = GO_TO_MARK_OUT_SPEC },
    }
end

return M
