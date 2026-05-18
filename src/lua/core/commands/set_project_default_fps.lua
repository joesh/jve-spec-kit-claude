--- SetProjectDefaultFps command (018 T043 / FR-036a / FR-026 / FR-030a).
---
--- Sets projects.settings.default_fps. Settings-only — no cascade to
--- existing sequences/media_refs/clips. New sequences created after this
--- command pick up the new fps as their default. To rewrite an existing
--- sequence's fps, use ConformSequence (separate command).
---
--- @file set_project_default_fps.lua

local M = {}

local Project = require("models.project")
local log     = require("core.logger").for_area("commands")

function M.execute(args)
    assert(type(args) == "table", "SetProjectDefaultFps.execute: args table required")
    assert(args.project_id and args.project_id ~= "",
        "SetProjectDefaultFps: project_id required (rule 2.29)")
    assert(type(args.fps_numerator) == "number" and args.fps_numerator > 0
        and math.floor(args.fps_numerator) == args.fps_numerator,
        string.format("SetProjectDefaultFps: fps_numerator must be positive integer; got %s",
            tostring(args.fps_numerator)))
    assert(type(args.fps_denominator) == "number" and args.fps_denominator > 0
        and math.floor(args.fps_denominator) == args.fps_denominator,
        string.format("SetProjectDefaultFps: fps_denominator must be positive integer; got %s",
            tostring(args.fps_denominator)))

    local prior_num, prior_den = Project.set_default_fps(
        args.project_id, args.fps_numerator, args.fps_denominator)

    log.event("SetProjectDefaultFps: %s %d/%d -> %d/%d",
        args.project_id, prior_num, prior_den,
        args.fps_numerator, args.fps_denominator)

    return {
        project_id      = args.project_id,
        prior_num       = prior_num,
        prior_den       = prior_den,
        new_num         = args.fps_numerator,
        new_den         = args.fps_denominator,
    }
end

function M.undo(persisted)
    assert(type(persisted) == "table", "SetProjectDefaultFps.undo: persisted required")
    assert(persisted.project_id and persisted.project_id ~= "",
        "SetProjectDefaultFps.undo: project_id missing")
    assert(type(persisted.prior_num) == "number" and persisted.prior_num > 0,
        "SetProjectDefaultFps.undo: prior_num missing/invalid")
    assert(type(persisted.prior_den) == "number" and persisted.prior_den > 0,
        "SetProjectDefaultFps.undo: prior_den missing/invalid")
    Project.set_default_fps(persisted.project_id,
        persisted.prior_num, persisted.prior_den)
end

local SPEC = {
    args = {
        project_id      = { required = true },
        fps_numerator   = { required = true, kind = "number" },
        fps_denominator = { required = true, kind = "number" },
    },
    persisted = {
        prior_num = { kind = "number" },
        prior_den = { kind = "number" },
        new_num   = { kind = "number" },
        new_den   = { kind = "number" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetProjectDefaultFps"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetProjectDefaultFps: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("prior_num", cap.prior_num)
        command:set_parameter("prior_den", cap.prior_den)
        command:set_parameter("new_num",   cap.new_num)
        command:set_parameter("new_den",   cap.new_den)
        return true
    end

    command_undoers["SetProjectDefaultFps"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            project_id = args.project_id,
            prior_num  = args.prior_num,
            prior_den  = args.prior_den,
        })
        return true
    end

    return {
        executor = command_executors["SetProjectDefaultFps"],
        undoer   = command_undoers["SetProjectDefaultFps"],
        spec     = SPEC,
    }
end

return M
