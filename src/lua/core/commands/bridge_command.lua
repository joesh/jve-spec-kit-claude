--- bridge_command: per-command surface for spec 023's bridge commands.
---
--- Eliminates the boilerplate every bridge command would otherwise
--- duplicate (register_op call, notify-closure-over-op_name, and the
--- M.register body that wires register_executor + spec). Adding a 6th
--- bridge command should not be a 12-line copy of the prior 5.
---
--- Usage at command-module top:
---   local bridge_command = require("core.commands.bridge_command")
---   local OP = bridge_command.declare(
---       "SendToResolve", "send_to_resolve_completed")
---   local notify = OP.notify
---   ...
---   M.register = OP.make_register(M.execute, SPEC)
---
--- The module forwards to bridge_completion; it does not own the signal
--- wiring or counter — those still live in bridge_completion. This is
--- ergonomics, not policy.

local bridge_completion = require("core.commands.bridge_completion")

local M = {}

--- Declare a bridge command's op + completion signal in one shot.
--- @param op_name string command registry name (e.g. "SendToResolve")
--- @param signal_name string completion signal (e.g. "send_to_resolve_completed")
--- @return table {op_name, notify, make_register}
function M.declare(op_name, signal_name)
    bridge_completion.register_op(op_name, signal_name)
    local OP = { op_name = op_name }
    OP.notify = function(args, result, code, message)
        bridge_completion.notify(op_name, args, result, code, message)
    end
    OP.make_register = function(execute_fn, spec)
        assert(type(spec) == "table",
            "bridge_command.make_register: spec table required")
        return function(command_executors, _command_undoers, db, set_last_error)
            local executor = bridge_completion.register_executor(
                command_executors, op_name, execute_fn, db, set_last_error)
            return { executor = executor, spec = spec }
        end
    end
    return OP
end

return M
