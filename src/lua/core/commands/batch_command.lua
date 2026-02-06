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
-- Size: ~163 LOC
-- Volatility: unknown
--
-- @file batch_command.lua
local M = {}
local json = require("dkjson")
local Command = require("command")
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        commands_json = {},
        project_id = { required = true },
        sequence_id = {},
    },
    persisted = {
        executed_commands_json = {},
    },
    requires_any = {
        { "commands_json", "executed_commands_json" },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    
    local function deep_copy(value, seen)
        if type(value) ~= "table" then
            return value
        end
        seen = seen or {}
        if seen[value] then
            return seen[value]
        end
        local result = {}
        seen[value] = result
        for k, v in pairs(value) do
            result[k] = deep_copy(v, seen)
        end
        return result
    end

    local function merge_timeline_mutations(target_command, source_mutations)
        if not target_command or not source_mutations then
            return
        end

        local function merge_bucket(bucket)
            if not bucket or not bucket.sequence_id then
                return
            end
            if bucket.inserts and #bucket.inserts > 0 then
                command_helper.add_insert_mutation(target_command, bucket.sequence_id, bucket.inserts)
            end
            if bucket.updates and #bucket.updates > 0 then
                command_helper.add_update_mutation(target_command, bucket.sequence_id, bucket.updates)
            end
            if bucket.deletes and #bucket.deletes > 0 then
                command_helper.add_delete_mutation(target_command, bucket.sequence_id, bucket.deletes)
            end
        end

        if source_mutations.sequence_id or source_mutations.inserts or source_mutations.updates or source_mutations.deletes then
            merge_bucket(source_mutations)
        else
            for _, bucket in pairs(source_mutations) do
                merge_bucket(bucket)
            end
        end
    end

    command_executors["BatchCommand"] = function(command)
        local args = command:get_all_parameters()
        print("Executing BatchCommand")

        local commands_json = args.executed_commands_json or args.commands_json
        if not commands_json or commands_json == "" then
            set_last_error("BatchCommand: No commands provided")
            return false
        end

        local command_specs, parse_err = json.decode(commands_json)
        if not command_specs then
            print(string.format("ERROR: BatchCommand: Failed to parse commands JSON: %s", parse_err or "unknown"))
            return false
        end



        local executed_commands = {}

        for i, spec in ipairs(command_specs) do
            local child_project_id = spec.project_id
            if not child_project_id or child_project_id == "" then
                child_project_id = args.project_id
                spec.project_id = child_project_id
            end

            if args.sequence_id and (not spec.parameters or not spec.parameters.sequence_id) then
                spec.parameters = spec.parameters or {}
                spec.parameters.sequence_id = args.sequence_id
            end

            local cmd = Command.create(spec.command_type, child_project_id)

            -- Set parameters from spec
            if spec.parameters then
                for key, value in pairs(spec.parameters) do
                    cmd:set_parameter(key, value)
                end
            end

            if not cmd:get_parameter("project_id") or cmd:get_parameter("project_id") == "" then
                cmd:set_parameter("project_id", child_project_id)
            end
            cmd.project_id = child_project_id

            local executor = command_executors[spec.command_type]
            if not executor then
                -- Auto-load if missing (copied logic from command_manager)
                local filename = spec.command_type:gsub("%u", function(c) return "_" .. c:lower() end):sub(2)
                local module_path = "core.commands." .. filename
                local status, mod = pcall(require, module_path)
                if status and type(mod) == "table" and mod.register then
                    mod.register(command_executors, command_undoers, db, set_last_error)
                    executor = command_executors[spec.command_type]
                end
            end

            if not executor then
                print(string.format("ERROR: BatchCommand: Unknown command type '%s'", spec.command_type))
                return false
            end

            local success = executor(cmd)
            if not success then
                print(string.format("ERROR: BatchCommand: Command %d (%s) failed", i, spec.command_type))
                return false
            end

            table.insert(executed_commands, cmd)

            -- Capture mutated parameters to ensure deterministic replay/undo.
            local mutated = cmd:get_all_parameters()
            if mutated and next(mutated) ~= nil then
                spec.parameters = deep_copy(mutated)
            end
            spec.project_id = cmd.project_id
            merge_timeline_mutations(command, cmd:get_parameter("__timeline_mutations"))
        end

        command:set_parameter("executed_commands_json", json.encode(command_specs))

        -- Generate descriptive label based on child commands
        local command_labels = require("core.command_labels")
        local function generate_label()
            if #command_specs == 0 then
                return nil
            end
            -- Single child: use its label
            if #command_specs == 1 then
                return command_labels.label_for_type(command_specs[1].command_type)
            end
            -- Multiple children of same type: "Delete Clip (3)"
            local type_counts = {}
            for _, spec in ipairs(command_specs) do
                local t = spec.command_type or "Unknown"
                type_counts[t] = (type_counts[t] or 0) + 1
            end
            local unique_type, unique_count = nil, 0
            for t, count in pairs(type_counts) do
                if unique_type == nil then
                    unique_type, unique_count = t, count
                else
                    unique_type = nil
                    break
                end
            end
            if unique_type then
                return command_labels.label_for_type(unique_type) .. " (" .. unique_count .. ")"
            end
            -- Mixed types
            return "Batch (" .. #command_specs .. ")"
        end
        command:set_parameter("display_label", generate_label())

        print(string.format("BatchCommand: Executed %d commands successfully", #executed_commands))
        return true
    end

    command_undoers["BatchCommand"] = function(command)
        local args = command:get_all_parameters()
        print("Undoing BatchCommand")


        if not args.executed_commands_json then
            set_last_error("BatchCommand undo: No executed commands found")
            return false
        end

        local command_specs = json.decode(args.executed_commands_json)


        for i = #command_specs, 1, -1 do
            local spec = command_specs[i]
            local child_project_id = spec.project_id
            if not child_project_id or child_project_id == "" then
                child_project_id = args.project_id
                spec.project_id = child_project_id
            end

            local cmd = Command.create(spec.command_type, child_project_id)

            -- Restore parameters
            if spec.parameters then
                for key, value in pairs(spec.parameters) do
                    cmd:set_parameter(key, value)
                end
            end

            if not cmd:get_parameter("project_id") or cmd:get_parameter("project_id") == "" then
                cmd:set_parameter("project_id", child_project_id)
            end
            cmd.project_id = child_project_id

            local undoer = command_undoers[spec.command_type]
            assert(undoer, string.format("BatchCommand undo: no undoer registered for command %d (%s)", i, spec.command_type))
            local success = undoer(cmd)
            assert(success, string.format("BatchCommand undo: child undo failed for command %d (%s)", i, spec.command_type))
            merge_timeline_mutations(command, cmd:get_parameter("__timeline_mutations"))
        end

        print(string.format("BatchCommand: Undid %d commands", #command_specs))
        return true
    end

    return {
        executor = command_executors["BatchCommand"],
        undoer = command_undoers["BatchCommand"],
        spec = SPEC,
    }
end

return M
