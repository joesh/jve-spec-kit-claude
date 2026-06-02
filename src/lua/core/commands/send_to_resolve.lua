--- SendToResolve command — spec 023 T024 / FR-023.
---
--- Authors a DRT for the active sequence, hands it to the Resolve helper
--- to import + relink, and persists the returned identity mapping into
--- the resolve_bridge_link ledger so future SyncGradesFromResolve calls
--- (T031) can match Resolve items back to JVE clips.
---
--- Flow:
---   1. payload_builder.build → drt_writer-shaped payload.
---   2. drt_writer.author → a .drp/.drt on disk.
---   3. helper_supervisor.ensure_client → connected client.
---   4. client:request("import_timeline", {drt_path, media_roots,
---        change_token}) — change_token computed from active sequence.
---   5. identity_ledger.upsert per mapping row.
---
--- Not undoable (FR-017 is for SYNC, not SEND). The Resolve side has its
--- own undo stack and we never mutate JVE model state here.
---
--- Asynchronous: returns nil success on enqueue; the on_complete callback
--- is what surfaces success/failure to the UI layer.

local M = {}

local payload_builder   = require("core.resolve_bridge.payload_builder")
local change_token      = require("core.resolve_bridge.change_token")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local drt_writer        = require("exporters.drt_writer")
local Sequence          = require("models.sequence")
local database          = require("core.database")
local log               = require("core.logger").for_area("commands")

local function out_path_for_export(sequence_id)
    -- Stable per-sequence path: re-sending the same sequence overwrites
    -- the same file so the helper's idempotency check actually matches.
    return string.format("/tmp/jve-resolve-%s.drp", sequence_id)
end

function M.execute(args)
    assert(type(args) == "table", "SendToResolve: args required")
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "SendToResolve: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SendToResolve: sequence_id required")
    assert(type(args.media_roots) == "table",
        "SendToResolve: media_roots required (array of search paths)")
    assert(type(args.on_complete) == "function",
        "SendToResolve: on_complete callback required (FR-007 — never "
        .. "silent enqueue)")

    local db = database.get_connection()
    assert(db, "SendToResolve: no database connection")

    local seq = Sequence.load(args.sequence_id)
    assert(seq, "SendToResolve: sequence not found: " .. args.sequence_id)
    assert(seq.mutation_generation,
        "SendToResolve: sequence missing mutation_generation — schema "
        .. "expected V12+ (FU-2)")

    local payload = payload_builder.build(db,
        args.project_id, args.sequence_id)
    local out_path = out_path_for_export(args.sequence_id)
    drt_writer.author(out_path, payload)
    log.event("SendToResolve: authored %s", out_path)

    local client, supervisor_err = supervisor.ensure_client()
    if not client then
        args.on_complete(nil, "helper_unavailable", supervisor_err)
        return
    end

    local token = change_token.build(args.project_id, args.sequence_id,
        seq.mutation_generation)
    client:request("import_timeline", {
        drt_path     = out_path,
        media_roots  = args.media_roots,
        change_token = token,
    }, function(response, code, message)
        if response == nil then
            args.on_complete(nil, code, message)
            return
        end
        local mapping = response.result.mapping
        local unrelinked = response.result.unrelinked
        assert(type(mapping) == "table",
            "SendToResolve: helper response missing result.mapping")
        assert(type(unrelinked) == "table",
            "SendToResolve: helper response missing result.unrelinked")
        for _, row in ipairs(mapping) do
            assert(type(row.jve_guid) == "string" and row.jve_guid ~= "",
                "SendToResolve: mapping row missing jve_guid")
            assert(type(row.resolve_item_id) == "string"
                and row.resolve_item_id ~= "",
                "SendToResolve: mapping row missing resolve_item_id")
            identity_ledger.upsert(row.jve_guid, {
                resolve_item_id = row.resolve_item_id,
            }, db)
        end
        log.event("SendToResolve: mapped %d clips, %d unrelinked",
            #mapping, #unrelinked)
        args.on_complete(response, nil, nil)
    end)
end

local SPEC = {
    undoable      = false,
    mutates_clips = false,
    args = {
        project_id  = { required = true },
        sequence_id = { required = true },
        media_roots = { required = true, kind = "table" },
        on_complete = { required = true, kind = "function" },
    },
}

function M.register(command_executors, _command_undoers, _db, set_last_error)
    command_executors["SendToResolve"] = function(command)
        local args = command:get_all_parameters()
        local ok, err = pcall(M.execute, args)
        if not ok then
            set_last_error("SendToResolve: " .. tostring(err))
            return false, tostring(err)
        end
        return true
    end
    return {
        executor = command_executors["SendToResolve"],
        spec     = SPEC,
    }
end

return M
