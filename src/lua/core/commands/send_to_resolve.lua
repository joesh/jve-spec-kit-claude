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
local drt_round_trip    = require("exporters.drt_round_trip")
local Sequence          = require("models.sequence")
local log               = require("core.logger").for_area("commands")

local function out_path_for_export(sequence_id)
    -- Stable per-sequence path: re-sending the same sequence overwrites
    -- the same file so the helper's idempotency check actually matches.
    return string.format("/tmp/jve-resolve-%s.drp", sequence_id)
end

-- Build the `clip_positions` payload the helper consumes to derive its
-- identity mapping (helper-protocol.md §import_timeline). The helper
-- has no JVE state (FR-021), so JVE supplies the (clip.id ↔ position)
-- map; the helper looks up live items by `(track_type, track_index,
-- record_start)`. Track index assignment must mirror `drt_writer`'s
-- partition (VideoTrackVec then AudioTrackVec preserving JVE order
-- within each type) so the index the helper observes on the imported
-- timeline matches.
local function build_clip_positions(payload)
    local positions = {}
    local video_idx, audio_idx = 0, 0
    for _, track in ipairs(payload.sequence.tracks) do
        local track_index
        if track.type == "video" then
            video_idx = video_idx + 1
            track_index = video_idx
        elseif track.type == "audio" then
            audio_idx = audio_idx + 1
            track_index = audio_idx
        else
            error(string.format(
                "SendToResolve: unknown track.type %q "
                .. "(payload_builder contract violation)",
                tostring(track.type)))
        end
        for _, clip in ipairs(track.clips) do
            positions[#positions + 1] = {
                clip_id      = clip.id,
                track_type   = track.type,
                track_index  = track_index,
                record_start = clip.sequence_start,
            }
        end
    end
    return positions
end

function M.execute(args, db)
    assert(type(args) == "table", "SendToResolve: args required")
    assert(db, "SendToResolve: db required (passed by register's "
        .. "executor closure; SQL isolation policy keeps "
        .. "the global DB lookup out of commands)")
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "SendToResolve: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SendToResolve: sequence_id required")
    assert(type(args.media_roots) == "table",
        "SendToResolve: media_roots required (array of search paths)")
    assert(type(args.on_complete) == "function",
        "SendToResolve: on_complete callback required (FR-007 — never "
        .. "silent enqueue)")

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

    -- FR-004: round-trip the just-authored file through JVE's own
    -- importer BEFORE handing it to Resolve. Without this gate a
    -- writer regression (e.g. dropped DbId, malformed XML) ships
    -- silent corruption straight to the colorist.
    local rt_ok, rt_code, rt_message = drt_round_trip.validate(
        out_path, payload)
    if not rt_ok then
        log.error("SendToResolve: FR-004 round-trip validation failed "
            .. "for %s: %s", out_path, rt_message)
        args.on_complete(nil, rt_code, rt_message)
        return
    end

    local client, supervisor_err = supervisor.ensure_client()
    if not client then
        args.on_complete(nil, "helper_unavailable", supervisor_err)
        return
    end

    local clip_positions = build_clip_positions(payload)
    local token = change_token.build(args.project_id, args.sequence_id,
        seq.mutation_generation)
    client:request("import_timeline", {
        drt_path        = out_path,
        media_roots     = args.media_roots,
        clip_positions  = clip_positions,
        change_token    = token,
    }, function(response, code, message)
        if response == nil then
            args.on_complete(nil, code, message)
            return
        end
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

function M.register(command_executors, _command_undoers, db, set_last_error)
    command_executors["SendToResolve"] = function(command)
        local args = command:get_all_parameters()
        local ok, err = pcall(M.execute, args, db)
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
