-- FR-005: Option+click exclusive M/S toggle (spec 025).
--
-- DOMAIN RULE: exclusive-toggling a track preference sets the clicked
-- track to the toggled state and EVERY OTHER track of the same kind
-- (video tracks one population, audio another) to the OPPOSITE state —
-- "mute everything except this", "solo only this". Independent per kind:
-- exclusive-mute on an audio track leaves video mute states untouched.
--
-- It is NOT undoable (consistent with the plain ToggleTrackPreference).
-- Option+click on a LOCKED track is a no-op (graceful refusal), not a crash.
--
-- Expected states come from the FR-005 semantics, not from tracing code.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local command_manager = require("core.command_manager")
local Track           = require("models.track")
local ripple_layout   = require("synthetic.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_exclusive_toggle_track_pref.lua ===")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_exclusive_toggle_track_pref.db",
    tracks = {
        order = {"v1", "v2", "a1", "a2", "a3"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        v2 = {id="trk_v2", name="V2", track_type="VIDEO", track_index=2, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
        a2 = {id="trk_a2", name="A2", track_type="AUDIO", track_index=2, enabled=1},
        a3 = {id="trk_a3", name="A3", track_type="AUDIO", track_index=3, enabled=1},
    },
    clips = { order = {} },
})
local PROJECT, SEQ = layout.project_id, layout.sequence_id

local function muted(id) return Track.load(id).muted end
local function soloed(id) return Track.load(id).soloed end

-- Tracks default to muted=false. Establish a NON-TRIVIAL mixed initial
-- state via the real toggle command: A2 muted, V1 muted.
assert(command_manager.execute("ToggleTrackPreference",
    {track_id="trk_a2", property="muted", project_id=PROJECT}).success)
assert(command_manager.execute("ToggleTrackPreference",
    {track_id="trk_v1", property="muted", project_id=PROJECT}).success)
assert(muted("trk_a2") == true and muted("trk_a1") == false and muted("trk_a3") == false,
    "fixture: A1=false A2=true A3=false")
assert(muted("trk_v1") == true, "fixture: V1 muted=true")

-- ── Exclusive mute on A1 (currently false) ───────────────────────────────
-- new_state = not false = true. A1→true, every OTHER audio track→false.
do
    local r = command_manager.execute("ExclusiveToggleTrackPreference",
        {track_id="trk_a1", property="muted", project_id=PROJECT, sequence_id=SEQ})
    assert(r and r.success, "ExclusiveToggleTrackPreference failed: "
        .. tostring(r and r.error_message))
    assert(muted("trk_a1") == true,  "A1 (clicked) → muted=true")
    assert(muted("trk_a2") == false, "A2 → muted=false (opposite)")
    assert(muted("trk_a3") == false, "A3 → muted=false (opposite)")
    -- Video population untouched.
    assert(muted("trk_v1") == true,  "V1 mute unchanged by an audio exclusive toggle")
    assert(muted("trk_v2") == false, "V2 mute unchanged")
    print("  PASS: exclusive mute A1 → A1 on, A2/A3 off, video untouched")
end

-- ── Exclusive solo on A2 (currently false) ───────────────────────────────
do
    local r = command_manager.execute("ExclusiveToggleTrackPreference",
        {track_id="trk_a2", property="soloed", project_id=PROJECT, sequence_id=SEQ})
    assert(r and r.success, "exclusive solo failed")
    assert(soloed("trk_a2") == true,  "A2 (clicked) → soloed=true")
    assert(soloed("trk_a1") == false, "A1 → soloed=false")
    assert(soloed("trk_a3") == false, "A3 → soloed=false")
    print("  PASS: exclusive solo A2 → A2 on, others off")
end

-- ── Locked clicked track → graceful no-op (NOT a crash) ──────────────────
do
    -- Lock A3 and capture the full audio mute vector.
    assert(command_manager.execute("ToggleTrackPreference",
        {track_id="trk_a3", property="locked", project_id=PROJECT}).success)
    local before = {muted("trk_a1"), muted("trk_a2"), muted("trk_a3")}

    local r = command_manager.execute("ExclusiveToggleTrackPreference",
        {track_id="trk_a3", property="muted", project_id=PROJECT, sequence_id=SEQ})
    assert(r and r.success, "exclusive on a locked track must not error (graceful no-op)")
    assert(muted("trk_a1") == before[1] and muted("trk_a2") == before[2]
        and muted("trk_a3") == before[3],
        "locked clicked track → NO track's mute state changes")
    print("  PASS: locked clicked track is a no-op, no other tracks touched")
end

-- ── Single-track population behaves as a plain toggle ────────────────────
do
    local solo_layout = ripple_layout.create({
        db_path = "/tmp/jve/test_exclusive_toggle_single.db",
        tracks = {
            order = {"a1"},
            a1 = {id="solo_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
        },
        clips = { order = {} },
    })
    local r = command_manager.execute("ExclusiveToggleTrackPreference",
        {track_id="solo_a1", property="muted",
         project_id=solo_layout.project_id, sequence_id=solo_layout.sequence_id})
    assert(r and r.success, "single-track exclusive failed")
    assert(Track.load("solo_a1").muted == true,
        "lone track toggles (no others to set opposite)")
    solo_layout:cleanup()
    print("  PASS: single-track exclusive toggles like a plain toggle")
end

-- ── Assert paths (executor invariants) ───────────────────────────────────
do
    local M = require("core.commands.exclusive_toggle_track_preference")

    local ok1, err1 = pcall(M.execute,
        {track_id="trk_a1", property="volume", project_id=PROJECT, sequence_id=SEQ})
    assert(not ok1, "invalid property must assert")
    assert(tostring(err1):find("ExclusiveToggleTrackPreference") and tostring(err1):find("volume"),
        "error names the command and the bad property: " .. tostring(err1))

    local ok2 = pcall(M.execute,
        {property="muted", project_id=PROJECT, sequence_id=SEQ})
    assert(not ok2, "missing track_id must assert")

    local ok3 = pcall(M.execute,
        {track_id="trk_a1", property="muted", project_id=PROJECT})
    assert(not ok3, "missing sequence_id must assert (needed to find sibling tracks)")
    print("  PASS: invalid property / missing track_id / missing sequence_id assert")
end

layout:cleanup()
print("\n✅ test_exclusive_toggle_track_pref.lua passed")
