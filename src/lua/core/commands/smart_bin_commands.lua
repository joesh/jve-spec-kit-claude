--- Smart Bin commands: CreateSmartBin, UpdateSmartBin, DeleteSmartBin
--
-- Undoable commands for smart bin CRUD.
-- Available to scripting via command_manager.execute("CreateSmartBin", {...})
--
-- @file smart_bin_commands.lua

local smart_bin = require("core.smart_bin")
local json = require("dkjson")

local M = {}

local SPEC_CREATE = {
    undoable = true,
    args = {
        project_id = { required = true },
        name = { required = true },
        criteria_json = { required = true },
        scope_bin_id = {},
    },
    persisted = {
        smart_bin_id = {},
    },
}

local SPEC_UPDATE = {
    undoable = true,
    args = {
        project_id = { required = true },
        smart_bin_id = { required = true },
        name = {},
        criteria_json = {},
        scope_bin_id = {},
    },
    persisted = {
        previous_name = {},
        previous_criteria_json = {},
        previous_scope_bin_id = {},
    },
}

local SPEC_DELETE = {
    undoable = true,
    args = {
        project_id = { required = true },
        smart_bin_id = { required = true },
    },
    persisted = {
        name = {},
        criteria_json = {},
        scope_bin_id = {},
        created_at = {},
    },
}

function M.register(command_executors, command_undoers, db, _)

    -- ========================================================================
    -- CreateSmartBin
    -- ========================================================================
    command_executors["CreateSmartBin"] = function(command)
        local args = command:get_all_parameters()

        -- If no name/criteria provided, open dialog (UI path)
        if not args.name or not args.criteria_json then
            local timeline_state = require("ui.timeline.timeline_state")
            local project_id = args.project_id
                or (timeline_state.get_project_id and timeline_state.get_project_id())
            assert(project_id, "CreateSmartBin: no project open")

            local tag_service = require("core.tag_service")
            local bins_list = tag_service.list(project_id)
            local bin_opts = {}
            for _, b in ipairs(bins_list) do
                bin_opts[#bin_opts + 1] = {id = b.id, name = b.name}
            end

            local smart_bin_dialog = require("ui.smart_bin_dialog")
            local result = smart_bin_dialog.show_create({
                project_id = project_id,
                bins = bin_opts,
            })

            if not result then
                return {success = true, cancelled = true}
            end

            args.project_id = project_id
            args.name = result.name
            args.criteria_json = result.criteria_json
            args.scope_bin_id = result.scope_bin_id
        end

        local sb = smart_bin.create(db, {
            project_id = args.project_id,
            name = args.name,
            criteria_json = args.criteria_json,
            scope_bin_id = args.scope_bin_id,
        })
        command:set_parameter("smart_bin_id", sb.id)

        -- Refresh browser to show new smart bin
        local project_browser = require("ui.project_browser")
        if project_browser.refresh then project_browser.refresh() end

        return {success = true, smart_bin_id = sb.id}
    end

    command_undoers["CreateSmartBin"] = function(command)
        local args = command:get_all_parameters()
        smart_bin.delete(db, args.smart_bin_id)
        return true
    end

    -- ========================================================================
    -- UpdateSmartBin
    -- ========================================================================
    command_executors["UpdateSmartBin"] = function(command)
        local args = command:get_all_parameters()
        -- Capture previous state
        local current = smart_bin.find_by_id(db, args.smart_bin_id)
        assert(current, "UpdateSmartBin: smart bin not found: " .. tostring(args.smart_bin_id))
        command:set_parameter("previous_name", current.name)
        command:set_parameter("previous_criteria_json", current.criteria_json)
        command:set_parameter("previous_scope_bin_id", current.scope_bin_id or json.null)

        -- Apply update
        local fields = {}
        if args.name then fields.name = args.name end
        if args.criteria_json then fields.criteria_json = args.criteria_json end
        if args.scope_bin_id then fields.scope_bin_id = args.scope_bin_id end
        smart_bin.update(db, args.smart_bin_id, fields)
        return {success = true}
    end

    command_undoers["UpdateSmartBin"] = function(command)
        local args = command:get_all_parameters()
        local fields = {
            name = args.previous_name,
            criteria_json = args.previous_criteria_json,
        }
        -- Restore scope_bin_id (json.null means "set to NULL / project-wide")
        if args.previous_scope_bin_id == json.null then
            fields.scope_bin_id = json.null  -- signals smart_bin.update to SET NULL
        elseif args.previous_scope_bin_id ~= nil then
            fields.scope_bin_id = args.previous_scope_bin_id
        end
        smart_bin.update(db, args.smart_bin_id, fields)
        return true
    end

    -- ========================================================================
    -- DeleteSmartBin
    -- ========================================================================
    command_executors["DeleteSmartBin"] = function(command)
        local args = command:get_all_parameters()
        -- Capture full record for undo
        local current = smart_bin.find_by_id(db, args.smart_bin_id)
        assert(current, "DeleteSmartBin: smart bin not found: " .. tostring(args.smart_bin_id))
        command:set_parameter("name", current.name)
        command:set_parameter("criteria_json", current.criteria_json)
        command:set_parameter("scope_bin_id", current.scope_bin_id or json.null)
        command:set_parameter("created_at", current.created_at)

        smart_bin.delete(db, args.smart_bin_id)
        return {success = true}
    end

    command_undoers["DeleteSmartBin"] = function(command)
        local args = command:get_all_parameters()
        -- Re-insert with original data
        local stmt = db:prepare([[
            INSERT INTO smart_bins (id, project_id, name, scope_bin_id, criteria_json, created_at, modified_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]])
        stmt:bind_value(1, args.smart_bin_id)
        stmt:bind_value(2, args.project_id)
        stmt:bind_value(3, args.name)
        local scope = args.scope_bin_id
        if scope == json.null then scope = nil end
        stmt:bind_value(4, scope)
        stmt:bind_value(5, args.criteria_json)
        stmt:bind_value(6, args.created_at)
        stmt:bind_value(7, os.time())
        assert(stmt:exec(), "DeleteSmartBin undo: INSERT failed")
        stmt:finalize()
        return true
    end

    -- Style B: multi-command registration
    return {
        ["CreateSmartBin"] = {
            executor = command_executors["CreateSmartBin"],
            undoer = command_undoers["CreateSmartBin"],
            spec = SPEC_CREATE,
        },
        ["UpdateSmartBin"] = {
            executor = command_executors["UpdateSmartBin"],
            undoer = command_undoers["UpdateSmartBin"],
            spec = SPEC_UPDATE,
        },
        ["DeleteSmartBin"] = {
            executor = command_executors["DeleteSmartBin"],
            undoer = command_undoers["DeleteSmartBin"],
            spec = SPEC_DELETE,
        },
    }
end

return M
