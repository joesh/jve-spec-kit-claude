--- QueueResolveRender — queue a Resolve render of the graded timeline
--- and poll status to completion (spec 023, T040a, FR-018).
---
--- Scope (T040a — splits T040 like T029 split T029a/T029b):
---   • Calls `queue_render` via the helper, receives a `job_id`.
---   • Polls `render_status` every `poll_interval_ms` (default 2000)
---     until the helper reports a TERMINAL state (`completed` or
---     `failed`).
---   • Surfaces `{job_id, state, progress, output_paths?}` to the
---     caller via `on_complete`.
---
--- Auto-relink of the rendered output(s) (FR-019) is T040b — split off
--- because the per-clip→output-filename mapping needs live-Resolve
--- exploration of `GetRenderJobList`'s output-filename shape against a
--- range of preset configurations. T040a ships the orchestration; the
--- caller (UI or a follow-on RelinkAfterRender command) consumes
--- `output_paths` once T040b is wired. See
--- `todo_render_relink_clip_mapping`.
---
--- Not undoable (FR-017 is for grade/edit syncs, not for queueing a
--- render). The Resolve side has its own undo stack and we never mutate
--- JVE model state from this command.
---
--- Asynchronous: `M.execute` returns once the helper request is
--- enqueued; `on_complete` carries success / structured error.

local M = {}

local change_token   = require("core.resolve_bridge.change_token")
local supervisor     = require("core.resolve_bridge.helper_supervisor")
local Sequence       = require("models.sequence")
local log            = require("core.logger").for_area("commands")

local DEFAULT_POLL_INTERVAL_MS = 2000
local TERMINAL_STATES = { completed = true, failed = true }

local function validate_args(args)
    assert(type(args) == "table", "QueueResolveRender: args required")
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "QueueResolveRender: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "QueueResolveRender: sequence_id required")
    assert(type(args.preset_name) == "string" and args.preset_name ~= "",
        "QueueResolveRender: preset_name required (Resolve "
        .. "Deliver-page preset)")
    assert(type(args.target_dir) == "string" and args.target_dir ~= "",
        "QueueResolveRender: target_dir required (absolute path, "
        .. "same-machine topology)")
    if args.file_prefix ~= nil then
        assert(type(args.file_prefix) == "string"
            and args.file_prefix ~= "",
            "QueueResolveRender: file_prefix must be non-empty string "
            .. "when present")
    end
    if args.poll_interval_ms ~= nil then
        assert(type(args.poll_interval_ms) == "number"
            and args.poll_interval_ms >= 100
            and args.poll_interval_ms == math.floor(args.poll_interval_ms),
            "QueueResolveRender: poll_interval_ms must be integer ≥ 100")
    end
    assert(type(args.on_complete) == "function",
        "QueueResolveRender: on_complete callback required")
end

local function build_spec(args)
    local spec = {
        preset_name = args.preset_name,
        target_dir  = args.target_dir,
    }
    if args.file_prefix then spec.file_prefix = args.file_prefix end
    return spec
end

-- Schedule the next status poll. Recursive via `do_poll` so each
-- response either re-arms the timer (non-terminal state) or invokes
-- on_complete (terminal state / error). Cancellation belongs to the
-- supervisor / project_changed signal — caller-side concern.
local function start_polling(client, job_id, poll_interval_ms,
                              on_complete)
    local function do_poll()
        client:request("render_status", { job_id = job_id },
            function(response, code, message)
                if response == nil then
                    on_complete(nil, code, message)
                    return
                end
                local result = response.result
                assert(type(result) == "table",
                    "QueueResolveRender: render_status returned "
                    .. "non-table result")
                assert(type(result.state) == "string", string.format(
                    "QueueResolveRender: render_status result.state "
                    .. "must be string (job_id=%s)", job_id))
                if TERMINAL_STATES[result.state] then
                    log.event("QueueResolveRender: job %s reached "
                        .. "terminal state %s", job_id, result.state)
                    on_complete({
                        job_id       = job_id,
                        state        = result.state,
                        progress     = result.progress,
                        output_paths = result.output_paths,
                    }, nil, nil)
                    return
                end
                -- Non-terminal: re-arm.
                qt_create_single_shot_timer(poll_interval_ms, do_poll)  -- luacheck: ignore qt_create_single_shot_timer
            end)
    end
    qt_create_single_shot_timer(poll_interval_ms, do_poll)  -- luacheck: ignore qt_create_single_shot_timer
end

function M.execute(args)
    validate_args(args)

    local seq = Sequence.load(args.sequence_id)
    assert(seq, "QueueResolveRender: sequence not found: "
        .. args.sequence_id)
    assert(seq.mutation_generation, string.format(
        "QueueResolveRender: sequence %s missing mutation_generation "
        .. "— schema expected V12+ (FU-2)", args.sequence_id))

    local client, supervisor_err = supervisor.ensure_client()
    if not client then
        args.on_complete(nil, "helper_unavailable", supervisor_err)
        return
    end

    local spec = build_spec(args)
    local token = change_token.build(args.project_id, args.sequence_id,
        seq.mutation_generation)
    local poll_interval_ms = args.poll_interval_ms
        or DEFAULT_POLL_INTERVAL_MS

    log.event("QueueResolveRender: queueing render preset=%s "
        .. "target_dir=%s", spec.preset_name, spec.target_dir)

    client:request("queue_render", {
        spec         = spec,
        change_token = token,
    }, function(response, code, message)
        if response == nil then
            args.on_complete(nil, code, message)
            return
        end
        local job_id = response.result.job_id
        assert(type(job_id) == "string" and job_id ~= "",
            "QueueResolveRender: helper response missing "
            .. "result.job_id (non-empty string)")
        log.event("QueueResolveRender: queued job_id=%s; polling "
            .. "every %dms", job_id, poll_interval_ms)
        start_polling(client, job_id, poll_interval_ms, args.on_complete)
    end)
end

local SPEC = {
    undoable      = false,
    mutates_clips = false,
    args = {
        project_id       = { required = true },
        sequence_id      = { required = true },
        preset_name      = { required = true },
        target_dir       = { required = true },
        file_prefix      = { required = false, kind = "string" },
        poll_interval_ms = { required = false, kind = "number" },
        on_complete      = { required = true,  kind = "function" },
    },
}

function M.register(command_executors, _command_undoers, _db, set_last_error)
    command_executors["QueueResolveRender"] = function(command)
        local args = command:get_all_parameters()
        local ok, err = pcall(M.execute, args)
        if not ok then
            set_last_error("QueueResolveRender: " .. tostring(err))
            return false, tostring(err)
        end
        return true
    end
    return {
        executor = command_executors["QueueResolveRender"],
        spec     = SPEC,
    }
end

return M
