--- Hydrate a full BatchRippleEdit mutation list from the compact
--- parameters persisted by finalize_execution, so the undoer can
--- revert without us writing thousands of mutation entries verbatim.
--
-- Responsibilities:
-- - Rebuild the executed_mutations list from original_states and
--   executed_mutation_order (the minimal persisted shape)
-- - Splice bulk_shift mutations around the per-clip entries in the
--   correct execution order (positive shifts pre-, negative post-)
-- - Handle bulk-shift-only commands: gap-only edits or pure downstream
--   shifts on unselected tracks produce no original_states but still
--   have bulk_shifts — those are fully undoable on their own
--
-- Non-goals:
-- - Executing the revert (that's command_helper.revert_mutations)
-- - Capturing new state — we only consume parameters the executor
--   already persisted
--
-- Invariants:
-- - Positive bulk_shifts execute BEFORE per-clip updates, negative
--   bulk_shifts execute AFTER — matches the forward order used by
--   finalize_execution so the reverse is consistent.
-- - Hydrated mutations are cached back onto the command via
--   set_parameter("executed_mutations", ...) so subsequent undos
--   skip the hydration step.
--
-- @file undo_hydrator.lua
local M = {}

-- ============================================================================
-- BatchRippleEdit undo hydrator helpers
-- ============================================================================

-- Stable identity key for a bulk_shift entry — three components: track,
-- start_frame, shift_frames. Used to dedupe bulk_shifts that may be
-- present both in `executed_mutations` and the standalone `bulk_shifts`
-- parameter.
local function bulk_shift_key(entry)
    return string.format("%s:%s:%s",
        tostring(entry.track_id or ""),
        tostring(entry.start_frame or ""),
        tostring(entry.shift_frames or ""))
end

-- Normalize a captured clip state for re-INSERT during undo. Asserts that
-- project_id and owner-sequence ids are recoverable; falls back to the
-- command-level fallbacks when the state row itself didn't carry them.
local function normalize_undo_clip_state(state, project_id, sequence_id)
    local copy = {}
    for k, v in pairs(state) do copy[k] = v end
    assert(copy.project_id or project_id,
        "BatchRippleEdit undo: clip state missing project_id")
    copy.project_id = copy.project_id or project_id
    -- V13: clip_kind is gone — track_type lives on the row when needed.
    assert(copy.owner_sequence_id or copy.track_sequence_id or sequence_id,
        string.format("BatchRippleEdit undo: clip %s missing owner_sequence_id",
            tostring(copy.id)))
    copy.owner_sequence_id = copy.owner_sequence_id or copy.track_sequence_id or sequence_id
    copy.track_sequence_id = copy.track_sequence_id or copy.owner_sequence_id
    return copy
end

local function clip_exists(clip_id)
    if not clip_id or clip_id == "" then return false end
    local Clip = require("models.clip")
    return Clip.load_optional(clip_id) ~= nil
end

-- Splice the command's `bulk_shifts` parameter back into the
-- executed_mutations list. Bulk_shifts go in two places:
--   * positive shifts run BEFORE per-clip undo entries (push downstream
--     forward so per-clip restores don't trigger the video-overlap
--     trigger), and
--   * negative shifts run AFTER (pull downstream back home after the
--     per-clip restores).
-- Bulk_shifts already in `target` are kept; new ones from the parameter
-- are appended (deduped by track/start/shift triple).
local function append_bulk_shifts_from_command(target, command)
    local bulk = command:get_parameter("bulk_shifts")
    if type(bulk) ~= "table" or #bulk == 0 then
        return target
    end

    local base, bulks, seen = {}, {}, {}
    for _, entry in ipairs(target) do
        if type(entry) == "table" and entry.type == "bulk_shift" then
            seen[bulk_shift_key(entry)] = true
            bulks[#bulks + 1] = entry
        else
            base[#base + 1] = entry
        end
    end

    for _, entry in ipairs(bulk) do
        if type(entry) == "table" and entry.type == "bulk_shift" then
            local k = bulk_shift_key(entry)
            if not seen[k] then
                seen[k] = true
                bulks[#bulks + 1] = entry
            end
        end
    end

    local pre, post = {}, {}
    for _, entry in ipairs(bulks) do
        assert(entry.shift_frames ~= nil,
            "BatchRippleEdit undo: bulk_shift entry missing shift_frames")
        local frames = tonumber(entry.shift_frames)
        if frames > 0 then
            pre[#pre + 1] = entry
        elseif frames < 0 then
            post[#post + 1] = entry
        end
    end

    local rebuilt = {}
    for _, entry in ipairs(pre)  do rebuilt[#rebuilt + 1] = entry end
    for _, entry in ipairs(base) do rebuilt[#rebuilt + 1] = entry end
    for _, entry in ipairs(post) do rebuilt[#rebuilt + 1] = entry end
    return rebuilt
end

-- Build the per-clip mutation list from `originals` + `executed_mutation_order`.
-- When the order is missing, fall back to one entry per original_state
-- (classify update vs delete by querying the live DB for the id).
local function build_clip_mutation_list(originals, ordered, project_id, sequence_id)
    local rebuilt = {}
    if type(ordered) == "table" and #ordered > 0 then
        for _, entry in ipairs(ordered) do
            if type(entry) == "table" and entry.clip_id and entry.type then
                if entry.type == "insert" then
                    rebuilt[#rebuilt + 1] = {type = "insert", clip_id = entry.clip_id}
                elseif entry.type == "update" or entry.type == "delete" then
                    local state = originals[entry.clip_id]
                    if type(state) ~= "table" then
                        error("BatchRippleEdit undo: missing original state for "
                            .. tostring(entry.clip_id))
                    end
                    rebuilt[#rebuilt + 1] = {
                        type     = entry.type,
                        clip_id  = entry.clip_id,
                        previous = normalize_undo_clip_state(state, project_id, sequence_id),
                    }
                end
            end
        end
    else
        for _, state in pairs(originals) do
            if type(state) == "table" and state.id then
                local prev = normalize_undo_clip_state(state, project_id, sequence_id)
                local tag = clip_exists(state.id) and "update" or "delete"
                rebuilt[#rebuilt + 1] = {
                    type     = tag,
                    clip_id  = state.id,
                    previous = prev,
                }
            end
        end
    end
    return rebuilt
end

function M.hydrate_executed_mutations_if_missing(command)
    if not command or not command.get_parameter then
        error("BatchRippleEdit undo: invalid command handle")
    end

    local executed = command:get_parameter("executed_mutations")
    if type(executed) == "table" and next(executed) ~= nil then
        return append_bulk_shifts_from_command(executed, command)
    end

    -- Bulk-shift-only commands: gap-only edits (or pure downstream shifts
    -- on unselected tracks) produce no per-clip mutations and no persisted
    -- original states — every persisted-state entry was a gap and got
    -- filtered out in finalize_execution. The bulk_shift entries are
    -- fully undoable on their own.
    local originals = command:get_parameter("original_states")
    local bulk = command:get_parameter("bulk_shifts")
    local has_bulk = type(bulk) == "table" and #bulk > 0
    if type(originals) ~= "table" or next(originals) == nil then
        if has_bulk then
            return append_bulk_shifts_from_command({}, command)
        end
        error("BatchRippleEdit undo: command missing executed_mutations and original_states")
    end

    local sequence_id = command:get_parameter("sequence_id")
    local project_id  = command.project_id or command:get_parameter("project_id")
    if not project_id or project_id == "" then
        error("BatchRippleEdit undo: missing project_id", 2)
    end

    local rebuilt = build_clip_mutation_list(originals,
        command:get_parameter("executed_mutation_order"),
        project_id, sequence_id)
    if #rebuilt == 0 then
        error("BatchRippleEdit undo: unable to hydrate executed_mutations (no original states)")
    end

    rebuilt = append_bulk_shifts_from_command(rebuilt, command)
    -- Hydrated mutations live on command.parameters. Caller
    -- (UndoBatchRippleEdit) is responsible for persisting via
    -- command:save(db) so subsequent undos don't re-hydrate.
    command:set_parameter("executed_mutations", rebuilt)
    return rebuilt
end

return M
