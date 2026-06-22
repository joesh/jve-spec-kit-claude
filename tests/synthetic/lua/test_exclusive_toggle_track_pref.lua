-- FR-005: Option+click exclusive toggle — every track-header button (spec 025).
--
-- DOMAIN RULE: the clicked button toggles (or cycles) just like a plain click,
-- then every other same-kind track (video tracks one population, audio another)
-- gets that button set to the CLICKED button's PRIOR state. Siblings all land
-- on the same value, one step different from where the clicked button just
-- went. Unified across:
--   muted / soloed / locked / waveform_display  → boolean: new=!old, siblings=old
--   sync_mode (off/ripple/cut cycle)            → new=cycle(old), siblings=old
--
-- NOT undoable (consistent with the plain per-property commands).
-- Option+click M/S/W/Sync on a LOCKED clicked track → graceful no-op.
-- Option+click Lock on a locked track is allowed (cycles back).
--
-- Expected states come from FR-005 semantics, not from tracing code.
--
-- Run via:
--   cd tests && luajit test_harness.lua synthetic/lua/test_exclusive_toggle_track_pref.lua

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local command_manager = require("core.command_manager")
local Track           = require("models.track")
local ripple_layout   = require("synthetic.helpers.ripple_layout")
local track_state     = require("ui.timeline.state.track_state")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_exclusive_toggle_track_pref.lua ===")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_exclusive_toggle_track_pref.db",
    tracks = {
        order = {"v1", "v2", "v3", "a1", "a2", "a3"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        v2 = {id="trk_v2", name="V2", track_type="VIDEO", track_index=2, enabled=1},
        v3 = {id="trk_v3", name="V3", track_type="VIDEO", track_index=3, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
        a2 = {id="trk_a2", name="A2", track_type="AUDIO", track_index=2, enabled=1},
        a3 = {id="trk_a3", name="A3", track_type="AUDIO", track_index=3, enabled=1},
    },
    clips = { order = {} },
})
local PROJECT, SEQ = layout.project_id, layout.sequence_id

local function muted(id)  return Track.load(id).muted end
local function soloed(id) return Track.load(id).soloed end
local function locked(id) return Track.load(id).locked end
local function sync(id)   return Track.load(id).sync_mode end

local function call(args)
    local r = command_manager.execute("ExclusiveToggleTrackPreference", args)
    assert(r and r.success,
        "ExclusiveToggleTrackPreference failed: " .. tostring(r and r.error_message))
end

-- ── M on a population starting all un-muted: "mute only the clicked one" ──
-- A1.old=false → A1.new=true; siblings=A1.old=false.
do
    call{track_id="trk_a1", property="muted", project_id=PROJECT, sequence_id=SEQ}
    assert(muted("trk_a1") == true,  "A1 (clicked) → muted=true (toggle from false)")
    assert(muted("trk_a2") == false, "A2 → muted=false (= A1's prior state)")
    assert(muted("trk_a3") == false, "A3 → muted=false (= A1's prior state)")
    assert(muted("trk_v1") == false, "V1 mute unchanged by an audio exclusive toggle")
    print("  PASS: Opt+M on all-unmuted A1 → mute only A1 (siblings=A1's prior false)")
end

-- ── Re-click the same button: state-dependent inverse. A1 is now muted. ──
-- A1.old=true → A1.new=false; siblings=A1.old=true → "everyone except A1 muted".
do
    call{track_id="trk_a1", property="muted", project_id=PROJECT, sequence_id=SEQ}
    assert(muted("trk_a1") == false, "A1 (clicked) → un-muted (toggle from true)")
    assert(muted("trk_a2") == true,  "A2 → muted (= A1's prior state)")
    assert(muted("trk_a3") == true,  "A3 → muted (= A1's prior state)")
    print("  PASS: Opt+M on muted A1 → only A1 audible, others muted (siblings=A1's prior true)")
end

-- ── S on all un-soloed: "solo only this" ─────────────────────────────────
do
    call{track_id="trk_a2", property="soloed", project_id=PROJECT, sequence_id=SEQ}
    assert(soloed("trk_a2") == true,  "A2 (clicked) → soloed")
    assert(soloed("trk_a1") == false, "A1 → un-soloed (siblings=A2's prior false)")
    assert(soloed("trk_a3") == false, "A3 → un-soloed")
    print("  PASS: Opt+S on un-soloed A2 → solo only A2")
end

-- ── Lock on a video population: clicked locks, siblings keep prior state ──
do
    call{track_id="trk_v2", property="locked", project_id=PROJECT, sequence_id=SEQ}
    assert(locked("trk_v2") == true,  "V2 (clicked) → locked")
    assert(locked("trk_v1") == false, "V1 → unlocked (siblings=V2's prior false)")
    assert(locked("trk_v3") == false, "V3 → unlocked")
    -- Audio population untouched by a video exclusive lock.
    assert(locked("trk_a1") == false, "A1 unchanged by a video exclusive lock")
    print("  PASS: Opt+Lock on unlocked V2 → lock only V2, audio untouched")
end

-- ── M/S/W/Sync on a LOCKED clicked track → graceful no-op ────────────────
do
    -- Plain lock A3.
    assert(command_manager.execute("ToggleTrackPreference",
        {track_id="trk_a3", property="locked", project_id=PROJECT}).success)
    local before_mute = {muted("trk_a1"), muted("trk_a2"), muted("trk_a3")}
    call{track_id="trk_a3", property="muted", project_id=PROJECT, sequence_id=SEQ}
    assert(muted("trk_a1") == before_mute[1] and muted("trk_a2") == before_mute[2]
        and muted("trk_a3") == before_mute[3],
        "Opt+M on a locked clicked track → NO mute state changes")
    print("  PASS: Opt+M on a locked clicked track is a no-op (no other tracks touched)")
end

-- ── Lock GESTURE on a locked clicked track IS allowed (walks back) ────────
do
    -- A3 is currently locked (from the previous scenario). Opt+Lock on A3:
    -- A3.old=true → A3.new=false; siblings=A3.old=true → A1/A2 become locked.
    call{track_id="trk_a3", property="locked", project_id=PROJECT, sequence_id=SEQ}
    assert(locked("trk_a3") == false, "A3 (clicked) → unlocked (toggle from true)")
    assert(locked("trk_a1") == true,  "A1 → locked (= A3's prior true)")
    assert(locked("trk_a2") == true,  "A2 → locked")
    print("  PASS: Opt+Lock on a locked track is allowed (cycles population back)")
    -- Cleanup: clear all audio locks so subsequent scenarios aren't blocked.
    for _, id in ipairs({"trk_a1", "trk_a2", "trk_a3"}) do
        assert(command_manager.execute("ToggleTrackPreference",
            {track_id=id, property="locked", value=false, project_id=PROJECT}).success)
    end
end

-- ── Waveform display (W): audio-only boolean toggle ──────────────────────
-- W defaults to enabled; first Opt+W on A1 flips A1 to hidden, siblings stay enabled.
do
    -- Establish baseline: all enabled.
    for _, id in ipairs({"trk_a1", "trk_a2", "trk_a3"}) do
        track_state.set_waveform_enabled(id, true)
    end
    call{track_id="trk_a1", property="waveform_display",
         project_id=PROJECT, sequence_id=SEQ}
    assert(track_state.get_waveform_enabled("trk_a1") == false,
        "A1 (clicked) → waveform hidden (toggle from shown)")
    assert(track_state.get_waveform_enabled("trk_a2") == true,
        "A2 → waveform shown (siblings=A1's prior true)")
    assert(track_state.get_waveform_enabled("trk_a3") == true, "A3 → waveform shown")
    print("  PASS: Opt+W on shown A1 → hide A1, others remain shown")
end

-- ── Sync mode (3-state cycle): siblings get clicked's prior state ────────
-- Off → Ripple → Cut → Off. Starting from all-Off, Opt+Sync on V1 cycles V1
-- to Ripple; siblings get V1's prior Off (no-op).
do
    -- Ensure clean baseline. Track.lua defaults sync_mode='ripple'; reset all
    -- video tracks to 'off' to walk the cycle from a known starting point.
    -- V2 was locked above; force-unlock so the sync gesture isn't no-op'd.
    assert(command_manager.execute("ToggleTrackPreference",
        {track_id="trk_v2", property="locked", value=false, project_id=PROJECT}).success)
    for _, id in ipairs({"trk_v1", "trk_v2", "trk_v3"}) do
        assert(command_manager.execute("SetSyncMode",
            {track_id=id, sync_mode="off", project_id=PROJECT}).success)
    end

    call{track_id="trk_v1", property="sync_mode", project_id=PROJECT, sequence_id=SEQ}
    assert(sync("trk_v1") == "ripple", "V1 (clicked) → ripple (cycled from off)")
    assert(sync("trk_v2") == "off",    "V2 → off (siblings=V1's prior off)")
    assert(sync("trk_v3") == "off",    "V3 → off")
    print("  PASS: Opt+Sync on Off V1 → V1=ripple, siblings=Off (=V1's prior)")

    -- Now V1=ripple, V2/V3=off. Opt+Sync on V1 again: V1 cycles ripple→cut,
    -- siblings get V1's prior ripple.
    call{track_id="trk_v1", property="sync_mode", project_id=PROJECT, sequence_id=SEQ}
    assert(sync("trk_v1") == "cut",    "V1 → cut (cycled from ripple)")
    assert(sync("trk_v2") == "ripple", "V2 → ripple (= V1's prior ripple)")
    assert(sync("trk_v3") == "ripple", "V3 → ripple")
    print("  PASS: Opt+Sync on Ripple V1 → V1=cut, siblings=Ripple")

    -- V1=cut, V2/V3=ripple. Opt+Sync on V1 again: V1 cycles cut→off,
    -- siblings get V1's prior cut.
    call{track_id="trk_v1", property="sync_mode", project_id=PROJECT, sequence_id=SEQ}
    assert(sync("trk_v1") == "off", "V1 → off (cycled from cut)")
    assert(sync("trk_v2") == "cut", "V2 → cut (= V1's prior cut)")
    assert(sync("trk_v3") == "cut", "V3 → cut")
    print("  PASS: Opt+Sync on Cut V1 → V1=off, siblings=Cut")
end

-- ── Assert paths (executor invariants) ──────────────────────────────────
-- Run BEFORE single-track scenario: that scenario's ripple_layout:cleanup()
-- closes the shared singleton DB, breaking any subsequent Track.load on the
-- main layout's tracks.
do
    local M = require("core.commands.exclusive_toggle_track_preference")

    local ok1, err1 = pcall(M.execute,
        {track_id="trk_a1", property="volume", project_id=PROJECT, sequence_id=SEQ})
    assert(not ok1, "invalid property must assert")
    assert(tostring(err1):find("ExclusiveToggleTrackPreference")
        and tostring(err1):find("volume"),
        "error names the command and the bad property: " .. tostring(err1))

    local ok2 = pcall(M.execute,
        {property="muted", project_id=PROJECT, sequence_id=SEQ})
    assert(not ok2, "missing track_id must assert")

    local ok3 = pcall(M.execute,
        {track_id="trk_a1", property="muted", project_id=PROJECT})
    assert(not ok3, "missing sequence_id must assert (needed to find sibling tracks)")

    -- W on a video track must assert (audio-only).
    local ok4, err4 = pcall(M.execute,
        {track_id="trk_v1", property="waveform_display",
         project_id=PROJECT, sequence_id=SEQ})
    assert(not ok4, "waveform_display on a video track must assert")
    assert(tostring(err4):find("waveform_display") and tostring(err4):find("AUDIO"),
        "error names the property and the kind constraint: " .. tostring(err4))
    print("  PASS: invalid property / missing track_id / missing sequence_id / W-on-video all assert")
end

-- ── Single-track population: no siblings → behaves as plain toggle ───────
do
    local solo_layout = ripple_layout.create({
        db_path = "/tmp/jve/test_exclusive_toggle_single.db",
        tracks = {
            order = {"a1"},
            a1 = {id="solo_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
        },
        clips = { order = {} },
    })
    call{track_id="solo_a1", property="soloed",
         project_id=solo_layout.project_id, sequence_id=solo_layout.sequence_id}
    assert(Track.load("solo_a1").soloed == true,
        "lone track Opt+S → soloed (toggle from false; no siblings)")
    solo_layout:cleanup()
    print("  PASS: single-track population behaves as plain toggle")
end

layout:cleanup()
print("\n✅ test_exclusive_toggle_track_pref.lua passed")
