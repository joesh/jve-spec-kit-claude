--- SendToResolve command — spec 023 T024 / FR-023.
---
--- Authors a DRT for the active sequence, hands it to the Resolve helper
--- to import + relink, and persists the returned identity mapping into
--- the resolve_bridge_link ledger so future SyncGradesFromResolve calls
--- (T031) can match Resolve items back to JVE clips.
---
--- Flow:
---   1. payload_builder.build → drt_writer-shaped payload.
---   2. drt_writer.author → a .drt on disk.
---   3. helper_supervisor.ensure_client → connected client.
---   4. client:request("import_timeline", {drt_path, media_paths,
---        change_token}) — change_token computed from active sequence;
---        media_paths derived from the export payload's media_refs (the
---        helper pre-imports each into Resolve's pool so the DRT's items
---        link byte-correctly — helper-protocol.md §import_timeline).
---   5. identity_ledger.upsert per mapping row.
---
--- Not undoable (FR-017 is for SYNC, not SEND). The Resolve side has its
--- own undo stack and we never mutate JVE model state here.
---
--- Asynchronous: every terminal path (success, every error code) routes
--- through `bridge_completion.notify("SendToResolve", args, result,
--- code, message)` which (a) emits the `send_to_resolve_completed` signal,
--- (b) logs the outcome, and (c) invokes `args.on_complete` if the
--- caller supplied one. Menu / shortcut callers omit `on_complete` and
--- observe completion via the signal (FR-023).

local M = {}

local payload_builder   = require("core.resolve_bridge.payload_builder")
local change_token      = require("core.resolve_bridge.change_token")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local bridge_command    = require("core.commands.bridge_command")
local drt_writer        = require("exporters.drt_writer")
local drt_round_trip    = require("exporters.drt_round_trip")
local Sequence          = require("models.sequence")
local log               = require("core.logger").for_area("commands")

local OP = bridge_command.declare(
    "SendToResolve", "send_to_resolve_completed")
local notify = OP.notify

-- Stable per-sequence path: re-sending the same sequence overwrites the
-- same file so the helper's idempotency check matches. Lives under
-- ~/.jve/ alongside the rest of JVE's per-user state.
local function out_path_for_export(sequence_id)
    local home = assert(os.getenv("HOME"),
        "SendToResolve: HOME env var required for export path")
    local dir = home .. "/.jve/resolve-exports"
    local ok, err = qt_fs_mkdir_p(dir)
    assert(ok, string.format(
        "SendToResolve: mkdir %s failed: %s", dir, tostring(err)))
    return string.format("%s/%s.drt", dir, sequence_id)
end

-- `_command` accepted for register_executor's executor signature; not
-- used here because SendToResolve is non-undoable (no captured state
-- to persist back onto the command).
function M.execute(args, db, _command)
    assert(type(args) == "table", "SendToResolve: args required")
    assert(db, "SendToResolve: db required (passed by register's "
        .. "executor closure; SQL isolation policy keeps "
        .. "the global DB lookup out of commands)")
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "SendToResolve: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SendToResolve: sequence_id required")
    local seq = Sequence.load(args.sequence_id)
    assert(seq, "SendToResolve: sequence not found: " .. args.sequence_id)
    assert(seq.mutation_generation,
        "SendToResolve: sequence missing mutation_generation — schema "
        .. "expected V13+ (FU-2)")

    local payload = payload_builder.build(db,
        args.project_id, args.sequence_id)
    local out_path = out_path_for_export(args.sequence_id)
    local authored = drt_writer.author_a005_compatible(out_path, payload)
    log.event("SendToResolve: authored %s", out_path)

    -- FR-004: round-trip the just-authored file through JVE's own
    -- importer BEFORE handing it to Resolve. Without this gate a
    -- writer regression (e.g. dropped DbId, malformed XML) ships
    -- silent corruption straight to the colorist.
    local rt_ok, rt_code, rt_message = drt_round_trip.validate(
        out_path, payload)
    if not rt_ok then
        log.error("SendToResolve: FR-004 round-trip validation failed "
            .. "for %s: %s", out_path, rt_message)
        notify(args, nil, rt_code, rt_message)
        return
    end

    supervisor.with_client(notify, args, function(client)
        local token = change_token.build(args.project_id, args.sequence_id,
            seq.mutation_generation)
        -- Distinct media file paths this DRT references. The helper
        -- pre-imports each into Resolve's pool before importing the
        -- timeline — Resolve links items byte-correctly only against
        -- pool clips; materializing from the DRT's embedded pool XML
        -- yields degenerate item source ranges (live-bisected
        -- 2026-06-10, helper-protocol.md §import_timeline).
        local media_paths, seen_paths = {}, {}
        for _, ref in ipairs(payload.media_refs) do
            assert(type(ref.file_path) == "string" and ref.file_path ~= "",
                "SendToResolve: media_ref missing file_path (file_uuid="
                .. tostring(ref.file_uuid) .. ")")
            if not seen_paths[ref.file_path] then
                seen_paths[ref.file_path] = true
                media_paths[#media_paths + 1] = ref.file_path
            end
        end
        client:request("import_timeline", {
            drt_path        = out_path,
            media_paths     = media_paths,
            clip_positions  = authored.emit_order,
            change_token    = token,
        }, function(response, code, message)
            if response == nil then
                notify(args, nil, code, message)
                return
            end
            -- Async-tail asserts (response shape, ledger upsert) crash by
            -- design — bridge_completion.lua's executor pcall only catches
            -- sync-phase asserts. The contract lives in bridge_completion's
            -- docstring; mirror it here so a reader of this file sees the
            -- rule without grep.
            local mapping = response.result.mapping
            local unrelinked = response.result.unrelinked
            local unkeyed_resolve_items = response.result.unkeyed_resolve_items
            assert(type(mapping) == "table",
                "SendToResolve: helper response missing result.mapping")
            assert(type(unrelinked) == "table",
                "SendToResolve: helper response missing result.unrelinked")
            assert(type(unkeyed_resolve_items) == "table",
                "SendToResolve: helper response missing "
                .. "result.unkeyed_resolve_items")
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
            log.event("SendToResolve: mapped %d clips, %d unrelinked, "
                .. "%d unkeyed Resolve items",
                #mapping, #unrelinked, #unkeyed_resolve_items)
            notify(args, response, nil, nil)
        end)
    end)
end

local SPEC = {
    undoable      = false,
    mutates_clips = false,
    args = {
        project_id  = { required = true },
        sequence_id = { required = true },
        on_complete = { required = false, kind = "function" },
    },
}

M.register = OP.make_register(M.execute, SPEC)

return M
