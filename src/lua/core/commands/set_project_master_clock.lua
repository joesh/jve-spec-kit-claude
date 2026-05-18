--- SetProjectMasterClock command (018 T044 / FR-036b / FR-027 / FR-030b).
---
--- Changes projects.settings.master_clock_hz and atomically rescales every
--- audio clip's source_*_subframe so the wall-clock instant each clip
--- resolves to is preserved. Sequence fps values are NOT touched.
---
--- This is the ONLY legal path to mutate projects.settings.master_clock_hz.
--- Direct UPDATEs are blocked by trigger INV-6. The model-layer helper
--- Project.transition_master_clock_hz owns the transactional rewrite + INV-6
--- flag handling; this command is a thin validate-and-delegate wrapper.
---
--- @file set_project_master_clock.lua

local M = {}

local Project = require("models.project")
local subframe_math = require("core.subframe_math")
local log = require("core.logger").for_area("commands")

local function make_rescale_fn(old_mch, new_mch)
    return function(in_sub, out_sub)
        local rhaz = subframe_math.round_half_away_from_zero
        local new_in  = (in_sub  == nil) and nil or rhaz(in_sub  * new_mch / old_mch)
        local new_out = (out_sub == nil) and nil or rhaz(out_sub * new_mch / old_mch)
        return new_in, new_out
    end
end

function M.execute(args)
    assert(type(args) == "table", "SetProjectMasterClock.execute: args required")
    assert(args.project_id and args.project_id ~= "",
        "SetProjectMasterClock: project_id required (rule 2.29)")
    assert(type(args.master_clock_hz) == "number" and args.master_clock_hz > 0
        and math.floor(args.master_clock_hz) == args.master_clock_hz,
        string.format(
            "SetProjectMasterClock: master_clock_hz must be positive integer; got %s",
            tostring(args.master_clock_hz)))

    local old_mch = Project.get_master_clock_hz_for_id(args.project_id)
    local new_mch = args.master_clock_hz
    assert(old_mch ~= new_mch, string.format(
        "SetProjectMasterClock: new clock %d equals current; no-op rejected",
        new_mch))

    local captured = Project.collect_audio_clips(args.project_id)
    local post = Project.transition_master_clock_hz(
        args.project_id, new_mch, captured,
        make_rescale_fn(old_mch, new_mch))

    log.event("SetProjectMasterClock: %s %d -> %d (%d audio clips rescaled)",
        args.project_id, old_mch, new_mch, #captured)

    return {
        project_id = args.project_id,
        old_mch    = old_mch,
        new_mch    = new_mch,
        pre_subs   = captured,
        post_subs  = post,
    }
end

function M.undo(persisted)
    assert(type(persisted) == "table", "SetProjectMasterClock.undo: persisted required")
    assert(persisted.project_id and persisted.project_id ~= "",
        "SetProjectMasterClock.undo: project_id missing")
    assert(type(persisted.old_mch) == "number" and persisted.old_mch > 0,
        "SetProjectMasterClock.undo: old_mch missing/invalid")
    assert(type(persisted.pre_subs) == "table",
        "SetProjectMasterClock.undo: pre_subs missing")

    -- Replay the captured pre-subframes verbatim. transition_master_clock_hz
    -- iterates pre_subs in the same order it was captured; the rescale_fn
    -- yields each row's recorded subs straight back (ignoring its inputs).
    local idx = 0
    local function restore_fn(_in_unused, _out_unused)
        idx = idx + 1
        local c = persisted.pre_subs[idx]
        assert(c, "SetProjectMasterClock.undo: pre_subs exhausted mid-iter")
        return c.in_sub, c.out_sub
    end
    Project.transition_master_clock_hz(
        persisted.project_id, persisted.old_mch, persisted.pre_subs, restore_fn)
end

local SPEC = {
    args = {
        project_id      = { required = true },
        master_clock_hz = { required = true, kind = "number" },
    },
    persisted = {
        old_mch   = { kind = "number" },
        new_mch   = { kind = "number" },
        pre_subs  = { kind = "table" },
        post_subs = { kind = "table" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetProjectMasterClock"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetProjectMasterClock: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("old_mch",   cap.old_mch)
        command:set_parameter("new_mch",   cap.new_mch)
        command:set_parameter("pre_subs",  cap.pre_subs)
        command:set_parameter("post_subs", cap.post_subs)
        return true
    end

    command_undoers["SetProjectMasterClock"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            project_id = args.project_id,
            old_mch    = args.old_mch,
            pre_subs   = args.pre_subs,
        })
        return true
    end

    return {
        executor = command_executors["SetProjectMasterClock"],
        undoer   = command_undoers["SetProjectMasterClock"],
        spec     = SPEC,
    }
end

return M
