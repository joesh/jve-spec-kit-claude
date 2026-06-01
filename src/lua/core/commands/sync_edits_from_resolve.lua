--- SyncEditsFromResolve — pull Resolve-side edit deltas back into JVE
--- (spec 023, T054, FR-024 / FR-025).
---
--- This file lands in two TDD passes:
---   Pass 1 (this commit): M.classify_all — pure data, no command
---       invocations. Bucket every clip in the read_timeline response
---       into {to_apply, conflicts, skipped, unmatched} using the same
---       fingerprint contract as `edit_diff.classify`.
---   Pass 2 (T054b, next commit): M.apply — translate every `to_apply`
---       entry into nested `command_manager.execute(...)` calls under a
---       single `begin_undo_group / end_undo_group` so the whole sync
---       lands as one undo. Reuses RippleTrimEdge / ToggleClipEnabled /
---       Nudge — no parallel mutation path (`feedback_no_lazy_shortcuts`,
---       ENGINEERING 1.9).
---
--- The two passes ship separately so the classifier is testable as pure
--- data (no helper, no nested commands) and the verb mapping can rest
--- on a careful read of RippleTrimEdge's record_start semantics first.

local M = {}

local Clip            = require("models.clip")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local edit_diff       = require("core.resolve_bridge.edit_diff")

local function assert_response_shape(response)
    assert(type(response) == "table" and type(response.items) == "table",
        "sync_edits.classify_all: response.items array required")
    for i, row in ipairs(response.items) do
        assert(type(row.jve_guid) == "string" and row.jve_guid ~= "",
            string.format(
                "sync_edits.classify_all: item[%d] missing jve_guid", i))
        for _, k in ipairs({
            "source_in", "source_out", "record_start", "record_dur",
        }) do
            assert(type(row[k]) == "number", string.format(
                "sync_edits.classify_all: item[%d] missing %s (number)",
                i, k))
        end
        assert(row.enabled ~= nil, string.format(
            "sync_edits.classify_all: item[%d] missing enabled", i))
    end
end

--- Pull the JVE-current edit state for a clip.
--- Field-name mapping: Lua model drops the SQL `_frame`/`_frames`
--- suffix — `sequence_start_frame` → `sequence_start`,
--- `duration_frames` → `duration`. read_timeline calls timeline-position
--- `record_start` / `record_dur`, so we adapt here.
local function load_current_state(clip_id)
    local clip = Clip.load_optional(clip_id)
    if not clip then return nil end
    return {
        source_in    = clip.source_in,
        source_out   = clip.source_out,
        record_start = clip.sequence_start,
        record_dur   = clip.duration,
        enabled      = clip.enabled,
    }
end

local function live_state_from_response_row(row)
    return {
        source_in    = row.source_in,
        source_out   = row.source_out,
        record_start = row.record_start,
        record_dur   = row.record_dur,
        enabled      = row.enabled,
    }
end

--- Pure-data classifier.
---
--- For each item in the read_timeline response, decide whether to
--- apply, conflict, skip, or report-unmatched. Buckets are:
---   to_apply  — `resolve_only` (Resolve diverged, JVE matched baseline)
---   conflicts — `both` (both sides diverged; user must choose)
---   skipped   — `neither` or `jve_only` (no Resolve-side work)
---   unmatched — no JVE clip OR no identity_ledger row for this jve_guid
---
--- When the ledger has no `edit_fingerprint` yet (first edit-sync after
--- SendToResolve / ConnectToResolveProject), the JVE current state is
--- used as the implicit baseline — i.e. live==current ⇒ neither,
--- live≠current ⇒ resolve_only. This is the only sensible bootstrap:
--- there is no prior common state to compare against, so JVE-local
--- divergence is undefined until the ledger has a fingerprint.
---
--- @param response table  {items = [{jve_guid, source_in, source_out,
---                                    record_start, record_dur, enabled},…]}
--- @param db       table  open SQLite connection (for ledger + clip read)
--- @return table { to_apply, conflicts, skipped, unmatched }
function M.classify_all(response, db)
    assert_response_shape(response)
    assert(db, "sync_edits.classify_all: db required")

    local result = {
        to_apply  = {},
        conflicts = {},
        skipped   = {},
        unmatched = {},
    }

    for _, row in ipairs(response.items) do
        local clip_id = row.jve_guid
        local current = load_current_state(clip_id)
        if current == nil then
            result.unmatched[#result.unmatched + 1] = {
                jve_guid = clip_id, reason = "clip_missing",
            }
        else
            local link = identity_ledger.load(clip_id, db)
            if link == nil then
                result.unmatched[#result.unmatched + 1] = {
                    jve_guid = clip_id, reason = "ledger_missing",
                }
            else
                local live = live_state_from_response_row(row)
                local stored_fp = link.edit_fingerprint
                if stored_fp == nil or stored_fp == "" then
                    stored_fp = edit_diff.fingerprint(current)
                end
                local classified = edit_diff.classify(
                    live, stored_fp, current)
                local entry = {
                    clip_id   = clip_id,
                    live      = live,
                    current   = current,
                    stored_fp = stored_fp,
                    kind      = classified.kind,
                }
                if classified.kind == "resolve_only" then
                    result.to_apply[#result.to_apply + 1] = entry
                elseif classified.kind == "both" then
                    result.conflicts[#result.conflicts + 1] = entry
                else
                    result.skipped[#result.skipped + 1] = entry
                end
            end
        end
    end

    return result
end

return M
