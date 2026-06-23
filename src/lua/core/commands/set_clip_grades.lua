--- SetClipGrades — synchronous undoable BATCH mutation of N clips'
--- color grades and identity-ledger grade fingerprints.
---
--- Granularity matters: a Resolve sync touches many hundreds of clips.
--- Dispatching one command per clip would pay full command_manager
--- overhead per clip (state_hash, command:save, notify_command_event,
--- grades_changed emit, on_model_changed) — measured ~250ms each,
--- multiplied out to minutes of serialised work on a real timeline.
--- One batch command captures ALL per-clip before-state in a single
--- synchronous execute(), records ONE undo entry, and emits
--- grades_changed ONCE.
---
--- Why it exists: SyncGradesFromResolve previously stashed captured-state
--- on the in-memory command from inside the async helper response. That
--- mutation never reached the persisted command record the undoer
--- rehydrates from, so Cmd-Z asserted. SyncGrades is now non-undoable;
--- its M.apply runs synchronously during the async response and
--- dispatches one SetClipGrades whose capture happens entirely inside
--- its synchronous execute — the standard command_manager capture
--- pattern.
---
--- Args (serialised in command_args JSON; rehydrated for undo):
---   sequence_id  string   (required) for the grades_changed signal
---   clips        array    (required) of per-clip operations:
---                         { clip_id, action, new_grade?,
---                           new_grade_fingerprint? }
---                         action ∈ {"set", "clear"}.
---                         "set" requires new_grade table.
---                         new_grade_fingerprint, when present,
---                         overwrites identity_ledger.grade_fingerprint
---                         (requires an existing identity-link entry).
---
--- Captured at execute() (read back at undo()):
---   _before        array   aligned with args.clips, each entry
---                          { clip_id, before_grade, before_link }
---
--- Single-underscore prefix (`_…`) is persistable; `__…` would be
--- ephemeral (see Command:get_persistable_parameters).

local M = {}

local ClipGrade       = require("models.clip_grade")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local Signals         = require("core.signals")

local VALID_ACTIONS = { set = true, clear = true }

local function clear_clip_grade(clip_id, db)
    local stmt = assert(db:prepare(
        "DELETE FROM clip_grade WHERE clip_id = ?"),
        "SetClipGrades: prepare DELETE failed")
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "SetClipGrades: DELETE failed for clip " .. clip_id)
end

local function apply_ledger_fingerprint(clip_id, new_fp, link, db)
    assert(link, "SetClipGrades: cannot update ledger grade_fingerprint "
        .. "for clip " .. clip_id .. " — no identity-link entry "
        .. "(auto-discovery seeds the link before dispatching "
        .. "SetClipGrades)")
    identity_ledger.upsert(clip_id, {
        resolve_item_id   = link.resolve_item_id,
        grade_fingerprint = new_fp,
        edit_fingerprint  = link.edit_fingerprint,
    }, db)
end

local function validate_op(op, i)
    assert(type(op) == "table", string.format(
        "SetClipGrades: clips[%d] must be a table", i))
    assert(type(op.clip_id) == "string" and op.clip_id ~= "", string.format(
        "SetClipGrades: clips[%d].clip_id required", i))
    assert(VALID_ACTIONS[op.action], string.format(
        "SetClipGrades: clips[%d].action must be \"set\" or \"clear\" "
        .. "(got %s)", i, tostring(op.action)))
    if op.action == "set" then
        assert(type(op.new_grade) == "table", string.format(
            "SetClipGrades: clips[%d].new_grade required when action=set",
            i))
    end
    if op.new_grade_fingerprint ~= nil then
        assert(type(op.new_grade_fingerprint) == "string"
            and op.new_grade_fingerprint ~= "", string.format(
            "SetClipGrades: clips[%d].new_grade_fingerprint must be a "
            .. "non-empty string", i))
    end
end

local function execute_set_clip_grades(command, db)
    local args = command:get_all_parameters()
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SetClipGrades: sequence_id required (for grades_changed signal)")
    assert(type(args.clips) == "table",
        "SetClipGrades: clips array required")

    local before = {}
    for i, op in ipairs(args.clips) do
        validate_op(op, i)
        local before_grade = ClipGrade.load(op.clip_id, db)
        local before_link  = identity_ledger.load(op.clip_id, db)
        before[i] = {
            clip_id      = op.clip_id,
            before_grade = before_grade,
            before_link  = before_link,
        }
    end
    command:set_parameter("_before", before)

    for i, op in ipairs(args.clips) do
        if op.action == "set" then
            ClipGrade.upsert(op.clip_id, op.new_grade, db)
        elseif before[i].before_grade ~= nil then
            clear_clip_grade(op.clip_id, db)
        end
        if op.new_grade_fingerprint ~= nil then
            apply_ledger_fingerprint(op.clip_id, op.new_grade_fingerprint,
                before[i].before_link, db)
        end
    end

    Signals.emit("grades_changed", args.sequence_id)
    return { success = true }
end

local function undo_set_clip_grades(command, db)
    local args = command:get_all_parameters()
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SetClipGrades undo: sequence_id required")
    assert(type(args._before) == "table",
        "SetClipGrades undo: _before snapshot required")
    assert(type(args.clips) == "table",
        "SetClipGrades undo: clips array required")

    for i, snap in ipairs(args._before) do
        if snap.before_grade ~= nil then
            ClipGrade.upsert(snap.clip_id, snap.before_grade, db)
        else
            clear_clip_grade(snap.clip_id, db)
        end
        -- Only revert ledger if execute() actually wrote a new
        -- fingerprint for this op. before_link is informational only
        -- when no fingerprint mutation happened.
        local op = args.clips[i]
        if op and op.new_grade_fingerprint ~= nil
                and snap.before_link ~= nil then
            identity_ledger.upsert(snap.clip_id, {
                resolve_item_id   = snap.before_link.resolve_item_id,
                grade_fingerprint = snap.before_link.grade_fingerprint,
                edit_fingerprint  = snap.before_link.edit_fingerprint,
            }, db)
        end
    end

    Signals.emit("grades_changed", args.sequence_id)
    return { success = true }
end

local SPEC = {
    undoable      = true,
    -- mutates_clips classifies how UI refresh is driven, NOT whether
    -- the command writes to any clip-adjacent table. False here because
    -- we touch clip_grade / resolve_bridge_link (never the clips table)
    -- and refresh via the grades_changed signal. The clip-cache reload
    -- safety net + __timeline_mutations expectation in command_manager
    -- are correctly skipped for us.
    mutates_clips = false,
    args = {
        sequence_id = { required = true,  kind = "string" },
        clips       = { required = true,  kind = "table"  },
    },
}

function M.register(command_executors, command_undoers, db, _set_last_error)
    command_executors["SetClipGrades"] = function(command)
        return execute_set_clip_grades(command, db)
    end
    command_undoers["SetClipGrades"] = function(command)
        return undo_set_clip_grades(command, db)
    end
    return {
        executor = command_executors["SetClipGrades"],
        undoer   = command_undoers["SetClipGrades"],
        spec     = SPEC,
    }
end

return M
