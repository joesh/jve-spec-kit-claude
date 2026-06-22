--- ExclusiveToggleTrackPreference command (spec 025 FR-005).
---
--- Option+click on any track-header toggle button. The clicked button
--- toggles (or cycles, for 3-state buttons) JUST LIKE a plain click, then
--- every other same-kind track (video tracks one population, audio
--- another) gets that button set to the CLICKED track's PRIOR state.
--- The siblings all land on the same value, exactly one step different
--- from where the clicked button just went.
---
--- Covers every header toggle: boolean (muted / soloed / locked /
--- waveform_display) and the 3-state sync_mode cycle.
---
--- Not undoable (consistent with the plain per-property commands, spec
--- 015 FR-040a). Writes route through whichever command/setter persists +
--- emits the change signal for the property — track_preference.set for
--- the boolean preferences, ToggleTrackWaveformDisplay for W,
--- SetSyncMode for Sync — so listeners restyle exactly as they would on
--- a plain click.
---
--- A locked clicked track is protected against M/S/W/Sync isolation
--- (FR-005 edge case): graceful no-op, nothing changes. The Lock gesture
--- itself is always allowed.

local M = {}

local Track             = require("models.track")
local track_preference  = require("core.track_preference")

-- Sync-mode cycle order. MUST match ui/timeline/timeline_panel.SYNC_CYCLE
-- — the plain-click cycle. The spec's "siblings get clicked's PRIOR
-- state" rule means siblings land one step earlier in this cycle (which
-- unifies cleanly with the boolean case where "prior" = NOT new).
local SYNC_CYCLE = { off = "ripple", ripple = "cut", cut = "off" }

-- Per-property metadata: the "kind" selects the storage path (which
-- command/setter the apply() helper routes through) and tracks whether
-- the value space is boolean or the sync_mode tri-state.
local PROPERTIES = {
    muted            = "boolean",
    soloed           = "boolean",
    locked           = "boolean",
    waveform_display = "waveform",   -- audio-only
    sync_mode        = "sync",
}

local SPEC = {
    undoable = false,
    keyboard = {
        category     = "Timeline ▸ Track Header",
        display_name = "Exclusive Toggle Track Header Button",
        description  = "Option+click on a track-header toggle (M / S / "
            .. "Lock / W / Sync): toggle or cycle THIS track normally, "
            .. "then set every other same-kind track's button to THIS "
            .. "track's prior state. Bind with property=muted|soloed|"
            .. "locked|waveform_display|sync_mode.",
    },
    args = {
        track_id    = { required = true },
        property    = { required = true },
        project_id  = { required = true },
        sequence_id = { required = true },
    },
}

-- ── Per-property primitives ─────────────────────────────────────────────

-- Read the clicked track's current value for `property`. Boolean
-- preferences arrive as Lua booleans from Track.load; sync_mode is the
-- raw string; waveform_display lives in transient track_state.
local function read_current(track, property)
    if property == "sync_mode" then
        return track.sync_mode
    elseif property == "waveform_display" then
        return require("ui.timeline.state.track_state").get_waveform_enabled(track.id)
    end
    return track[property] and true or false
end

-- Compute the clicked track's NEW value given its CURRENT value. Booleans
-- flip; sync_mode advances one rung around the SYNC_CYCLE.
local function compute_next(property, current)
    if property == "sync_mode" then
        local nxt = SYNC_CYCLE[current]
        assert(nxt, string.format(
            "ExclusiveToggleTrackPreference: unrecognised sync_mode '%s'",
            tostring(current)))
        return nxt
    end
    return not current
end

-- Apply `value` to `track`'s `property` via the same write path the
-- plain-click command would take, so the signal listeners that drive
-- header restyle / mix flush / waveform redraw fire identically.
local function apply(track, property, value, project_id)
    local kind = PROPERTIES[property]
    if kind == "boolean" then
        track_preference.set(track, property, value)
    elseif kind == "waveform" then
        require("core.commands.toggle_track_waveform_display").execute({
            track_id   = track.id,
            value      = value,
            project_id = project_id,
        })
    elseif kind == "sync" then
        require("core.commands.set_sync_mode").execute({
            track_id   = track.id,
            sync_mode  = value,
            project_id = project_id,
        })
    end
end

-- ── Command body ────────────────────────────────────────────────────────

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "ExclusiveToggleTrackPreference: track_id required")
    assert(PROPERTIES[args.property], string.format(
        "ExclusiveToggleTrackPreference: property must be muted/soloed/"
        .. "locked/waveform_display/sync_mode; got %s",
        tostring(args.property)))
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "ExclusiveToggleTrackPreference: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "ExclusiveToggleTrackPreference: sequence_id required (to find sibling tracks)")

    local clicked = Track.load(args.track_id)
    assert(clicked, string.format(
        "ExclusiveToggleTrackPreference: track %s not found",
        tostring(args.track_id)))

    -- A locked clicked track is protected from M/S/W/Sync isolation
    -- (FR-005 edge case). The Lock gesture itself is always allowed —
    -- Option+click Lock on a locked track walks the population back.
    if args.property ~= "locked" and clicked.locked then return true end

    -- W is audio-only; surface a wrong-kind clicked track loudly rather
    -- than silently producing a no-op on a video row.
    assert(args.property ~= "waveform_display" or clicked.track_type == "AUDIO",
        string.format("ExclusiveToggleTrackPreference: waveform_display "
            .. "applies only to AUDIO tracks; track %s is %s",
            tostring(args.track_id), tostring(clicked.track_type)))

    -- The gesture: clicked goes to NEW; every other same-kind track gets
    -- OLD (= NOT new for booleans, = one cycle step earlier for sync).
    local prev_state = read_current(clicked, args.property)
    local new_state  = compute_next(args.property, prev_state)

    local population = Track.find_by_sequence(args.sequence_id, clicked.track_type)
    assert(population and #population > 0, string.format(
        "ExclusiveToggleTrackPreference: no %s tracks in sequence %s",
        tostring(clicked.track_type), tostring(args.sequence_id)))

    for _, track in ipairs(population) do
        -- NB: explicit if/else, NOT `is_clicked and new_state or prev_state`
        -- — `new_state` is false for several boolean cases, which the and/or
        -- idiom mis-evaluates to prev_state.
        local value
        if track.id == args.track_id then value = new_state else value = prev_state end
        apply(track, args.property, value, args.project_id)
    end

    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["ExclusiveToggleTrackPreference"] = function(command)
        return M.execute(command:get_all_parameters())
    end

    return {
        executor = command_executors["ExclusiveToggleTrackPreference"],
        spec     = SPEC,
    }
end

return M
