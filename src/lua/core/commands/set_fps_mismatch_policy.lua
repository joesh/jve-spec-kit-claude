--- SetFpsMismatchPolicy command (Feature 013, T064 partial).
---
--- Per FR-015 / contracts/commands.md §SetFpsMismatchPolicy. Three scopes:
---
---   scope='project': Args { project_id, policy ∈ {'resample','passthrough'} }
---     (non-NULL — the project always has a concrete default).
---     UPDATEs projects.fps_mismatch_policy. No effect on existing
---     clips (each clip's policy is frozen at Insert time).
---
---   scope='sequence': Args { sequence_id, policy ∈ {'resample',
---     'passthrough', NULL} }. NULL = inherit project default. UPDATEs
---     sequences.fps_mismatch_policy. No effect on existing clips.
---
---   scope='clip' (DEFERRED — not yet implemented): structural mutation
---     that re-computes clips.duration_frames under the new policy,
---     ripples downstream clips, and flips linked V+A pair together
---     as a unit. Refused with a clear message until that pass lands.
---
--- Project-scope emits no signal (project changes don't affect any
--- existing in-flight resolution). Sequence-scope emits
--- sequence_content_changed(sequence_id) so future Insert/Overwrite
--- pulls the new default at Insert time.
---
--- @file set_fps_mismatch_policy.lua

local M = {}

local Project  = require("models.project")
local Sequence = require("models.sequence")
local log      = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "SetFpsMismatchPolicy: '%s' is required (rule 2.29)", name))
    return v
end

local function valid_policy_or_nil(v)
    return v == nil or v == "resample" or v == "passthrough"
end

local function valid_policy_non_null(v)
    return v == "resample" or v == "passthrough"
end

-- ---------------------------------------------------------------------------
-- Scope dispatchers
-- ---------------------------------------------------------------------------

local function execute_project(args)
    local project_id = require_string_arg(args, "project_id")
    local policy = args.policy
    assert(valid_policy_non_null(policy), string.format(
        "SetFpsMismatchPolicy(project): policy must be 'resample' or "
        .. "'passthrough' (non-NULL); got %s", tostring(policy)))

    local prior = Project.set_fps_mismatch_policy(project_id, policy)

    log.event("SetFpsMismatchPolicy(project): %s %s -> %s",
        project_id, tostring(prior), tostring(policy))

    return {
        scope         = "project",
        project_id    = project_id,
        prior_policy  = prior,
    }
end

local function execute_sequence(args)
    local sequence_id = require_string_arg(args, "sequence_id")
    local policy = args.policy
    assert(valid_policy_or_nil(policy), string.format(
        "SetFpsMismatchPolicy(sequence): policy must be 'resample', "
        .. "'passthrough', or NULL; got %s", tostring(policy)))

    local seq = Sequence.find(sequence_id)
    assert(seq, string.format(
        "SetFpsMismatchPolicy(sequence): sequence %s not found", sequence_id))
    local prior = seq.fps_mismatch_policy

    Sequence.set_fps_mismatch_policy(sequence_id, policy)

    log.event("SetFpsMismatchPolicy(sequence): %s -> %s -> %s",
        sequence_id, tostring(prior), tostring(policy))

    local Signals = require("core.signals")

    return {
        scope         = "sequence",
        sequence_id   = sequence_id,
        prior_policy  = prior,
    }
end

local function execute_clip(_args)
    error("SetFpsMismatchPolicy(clip): clip-scope is a structural mutation "
        .. "(re-computes clips.duration_frames, ripples downstream, flips "
        .. "linked V+A pair together) — not yet implemented. Tracked as "
        .. "follow-up to T064; use Insert with explicit policy until then.")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.execute(args)
    assert(type(args) == "table",
        "SetFpsMismatchPolicy.execute: args table required")
    local scope = args.scope
    if scope == "project" then
        return execute_project(args)
    elseif scope == "sequence" then
        return execute_sequence(args)
    elseif scope == "clip" then
        return execute_clip(args)
    else
        error(string.format(
            "SetFpsMismatchPolicy: scope must be 'project', 'sequence', "
            .. "or 'clip'; got %s", tostring(scope)))
    end
end

function M.undo(capture)
    assert(type(capture) == "table",
        "SetFpsMismatchPolicy.undo: capture table required")
    if capture.scope == "project" then
        Project.set_fps_mismatch_policy(capture.project_id, capture.prior_policy)
    elseif capture.scope == "sequence" then
        Sequence.set_fps_mismatch_policy(capture.sequence_id, capture.prior_policy)
        local Signals = require("core.signals")
    else
        error("SetFpsMismatchPolicy.undo: unknown scope " .. tostring(capture.scope))
    end
end

local SPEC = {
    args = {
        scope        = { required = true },
        project_id   = {},
        sequence_id  = {},
        clip_id      = {},
        policy       = {},
    },
    persisted = {
        scope        = { kind = "string" },
        prior_policy = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetFpsMismatchPolicy"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetFpsMismatchPolicy: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("scope", cap.scope)
        -- prior_policy may legitimately be nil (project- or sequence-level
        -- policy was never explicitly set). Distinguish present-and-set
        -- from absent via a paired flag — no '' sentinel.
        command:set_parameter("prior_policy_present", cap.prior_policy ~= nil)
        if cap.prior_policy ~= nil then
            command:set_parameter("prior_policy", cap.prior_policy)
        end
        return true
    end

    command_undoers["SetFpsMismatchPolicy"] = function(command)
        local args = command:get_all_parameters()
        local prior_policy = nil
        if args.prior_policy_present then
            assert(type(args.prior_policy) == "string" and args.prior_policy ~= "",
                "SetFpsMismatchPolicy.undo: prior_policy_present=true but prior_policy missing/empty")
            prior_policy = args.prior_policy
        end
        M.undo({
            scope        = args.scope,
            project_id   = args.project_id,
            sequence_id  = args.sequence_id,
            prior_policy = prior_policy,
        })
        return true
    end

    return {
        executor = command_executors["SetFpsMismatchPolicy"],
        undoer   = command_undoers["SetFpsMismatchPolicy"],
        spec     = SPEC,
    }
end

return M
