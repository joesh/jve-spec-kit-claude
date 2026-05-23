--- BladeAtPlayhead — keyboard adapter for the pure-model Blade command.
--
-- Blade (core.commands.blade) is intentionally pure-model: callers
-- supply sequence_id, blade_frame, and the list of armed track_ids
-- (T045a, 2026-04-24). The keyboard binding (Cmd+B) has no gesture
-- to carry blade_frame/track_ids the way a mouse-driven editor would,
-- so this thin adapter resolves them from ambient UI state and
-- dispatches Blade.
--
-- Resolution policy (Premiere Cmd+K parity):
--   blade_frame = active record playhead. command_manager auto-injects
--     `sequence_id` (active-record routing); the playhead is read from
--     the same sequence's persisted `playhead_position`. Using the
--     persisted value (not the transport engine directly) keeps the
--     resolution authoritative when the engine isn't bootstrapped
--     (headless tests, pre-bound state).
--   track_ids — selection-aware. Three cases:
--     1. Selection has at least one clip that is BOTH on an armed
--        (autoselect=1, locked=0) track AND strictly spans
--        blade_frame — "intersecting selection." track_ids =
--        the set of tracks owning those intersecting selected clips.
--        Only the selected/spanning subset gets cut.
--     2. Selection is empty OR contains no intersecting clips —
--        "non-intersecting selection." track_ids = every armed track.
--        Every spanning clip on every armed track gets cut.
--     3. No armed tracks at all → silent no-op.
--   The fallback in (2) is the user-friendly bit: a stale selection
--   from elsewhere on the timeline doesn't accidentally turn Cmd+B
--   into a no-op when the user clearly intended a razor at the
--   playhead. Matches Premiere Cmd+K behavior.
--
-- Track-arming filter on the intersection check: a selected clip on
-- a locked or autoselect-off track does NOT count as intersecting,
-- because Blade savepoint-rolls-back on any per-clip refusal — letting
-- a non-editable selected clip drive track_ids would surprise the user
-- with a whole-blade unwind. The intersection check is purely about
-- "what would actually be cut," not "what the user clicked."
--
-- This adapter is undoable=false: the nested Blade call owns the
-- single user-visible undo entry, so Cmd+Z reverts the cut cleanly.

local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true },
    },
}

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["BladeAtPlayhead"] = function(command)
        local args = command:get_all_parameters()
        local sequence_id = args.sequence_id
        assert(sequence_id and sequence_id ~= "",
            "BladeAtPlayhead: sequence_id required (auto-inject failed)")

        local Sequence = require("models.sequence")
        local seq = Sequence.load(sequence_id)
        assert(seq, string.format(
            "BladeAtPlayhead: sequence not found: %s", sequence_id))
        local blade_frame = seq.playhead_position
        assert(type(blade_frame) == "number", string.format(
            "BladeAtPlayhead: sequence %s has no playhead_position",
            sequence_id))

        local Track = require("models.track")
        local armed_set = {}
        local armed_list = {}
        for _, t in ipairs(Track.find_by_sequence(sequence_id)) do
            if t.autoselect and not t.locked then
                armed_set[t.id] = true
                armed_list[#armed_list + 1] = t.id
            end
        end

        if #armed_list == 0 then
            log.event("BladeAtPlayhead: no armed (autoselect=1, locked=0) "
                .. "tracks on sequence %s — no-op", sequence_id)
            return true
        end

        -- Selection-narrow check (Premiere Cmd+K parity, see
        -- specs/013-timeline-placements-as/contracts/commands.md
        -- "Cmd+B keyboard adapter"). Walk the current timeline
        -- selection; a selected clip counts as "intersecting" iff it
        -- sits on an armed track AND strictly spans blade_frame. If
        -- any such clip exists, narrow track_ids to that set;
        -- otherwise fall back to every armed track.
        local timeline_state = require("ui.timeline.timeline_state")
        local intersecting_set = {}
        local intersecting_list = {}
        for _, sc in ipairs(timeline_state.get_selected_clips()) do
            assert(type(sc.sequence_start) == "number"
                and type(sc.duration) == "number", string.format(
                "BladeAtPlayhead: selected clip %s missing geometry "
                .. "(sequence_start=%s, duration=%s) — timeline_state "
                .. "selection cache is malformed",
                tostring(sc.id), tostring(sc.sequence_start),
                tostring(sc.duration)))
            local strictly_inside = sc.sequence_start < blade_frame
                and blade_frame < sc.sequence_start + sc.duration
            if armed_set[sc.track_id]
                and strictly_inside
                and not intersecting_set[sc.track_id]
            then
                intersecting_set[sc.track_id] = true
                intersecting_list[#intersecting_list + 1] = sc.track_id
            end
        end

        local track_ids
        if #intersecting_list > 0 then
            track_ids = intersecting_list
            log.event("BladeAtPlayhead: selection-narrow → cutting %d "
                .. "track(s) (selection intersects playhead)",
                #intersecting_list)
        else
            track_ids = armed_list
        end

        -- command_manager.execute returns { success, error_message, result_data }.
        -- The executor's secondary return value (Blade's `{splits=...}`) is
        -- not propagated; the keyboard shortcut handler that invokes this
        -- adapter doesn't need it either. Surface success/failure only.
        --
        -- project_id is auto-injected at the outer-command boundary and
        -- propagated explicitly here so the nested call doesn't depend on
        -- the origin=="ui" side-channel default (would break script-origin
        -- and unit-test callers).
        local command_manager = require("core.command_manager")
        local result = command_manager.execute("Blade", {
            sequence_id = sequence_id,
            project_id  = args.project_id,
            blade_frame = blade_frame,
            track_ids   = track_ids,
        })
        assert(type(result) == "table" and type(result.success) == "boolean",
            string.format("BladeAtPlayhead: command_manager.execute(\"Blade\") "
                .. "returned malformed result (got %s) — contract violation",
                type(result)))
        if not result.success then
            local msg = result.error_message
            assert(type(msg) == "string" and msg ~= "",
                "BladeAtPlayhead: nested Blade reported success=false but "
                .. "error_message missing — Blade contract violation")
            return false, msg
        end
        return true
    end

    return {
        executor = command_executors["BladeAtPlayhead"],
        undoer   = nil,
        spec     = SPEC,
    }
end

return M
