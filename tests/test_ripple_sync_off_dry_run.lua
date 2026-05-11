#!/usr/bin/env luajit

-- 015 — sync_mode='off' must be respected in the dry-run preview.
--
-- Bug (pre-fix): the dry-run payload's GLOBAL shift_block has no track_id,
-- and the renderer falls back to it for every visible track — including
-- sync_mode='off' tracks. The rubberband rectangle then sweeps off-track
-- clips visually even though the commit path correctly leaves them in place.
--
-- Contract: off tracks must be discoverable from the dry-run payload so
-- the renderer can exclude them. Either an explicit `off_tracks` set or
-- a per-track shift_block entry with delta=0 (anything that prevents the
-- GLOBAL block from being applied to the off track).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Command         = require("command")
local ripple_layout   = require("tests.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_ripple_sync_off_dry_run.lua ===")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_ripple_sync_off_dry_run.db",
    fps_numerator = 1000, fps_denominator = 1,
    tracks = {
        order = {"v1", "a1", "a2"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        a1 = {id="trk_a1", name="A1", track_type="AUDIO", track_index=1, enabled=1},
        a2 = {id="trk_a2", name="A2", track_type="AUDIO", track_index=2, enabled=1},
    },
    media = { main = { audio_channels=2 } },
    clips = {
        order = {"c_v1f", "c_v1b", "c_a1f", "c_a1b", "c_a2f", "c_a2b"},
        c_v1f = {id="c_v1f", name="V1f", track_key="v1", media_key="main",
                 timeline_start=0,   duration=100, source_in=500, fps_numerator=1000, fps_denominator=1},
        c_v1b = {id="c_v1b", name="V1b", track_key="v1", media_key="main",
                 timeline_start=100, duration=100, source_in=600, fps_numerator=1000, fps_denominator=1},
        c_a1f = {id="c_a1f", name="A1f", track_key="a1", media_key="main",
                 timeline_start=0,   duration=60,  source_in=500, fps_numerator=1000, fps_denominator=1},
        c_a1b = {id="c_a1b", name="A1b", track_key="a1", media_key="main",
                 timeline_start=100, duration=100, source_in=600, fps_numerator=1000, fps_denominator=1},
        c_a2f = {id="c_a2f", name="A2f", track_key="a2", media_key="main",
                 timeline_start=0,   duration=60,  source_in=500, fps_numerator=1000, fps_denominator=1},
        c_a2b = {id="c_a2b", name="A2b", track_key="a2", media_key="main",
                 timeline_start=100, duration=100, source_in=600, fps_numerator=1000, fps_denominator=1},
    },
})

local db = database.get_connection()
assert(db:exec("UPDATE tracks SET sync_mode='off' WHERE id='trk_a1'"))
assert(db:exec("UPDATE tracks SET sync_mode='ripple' WHERE id IN ('trk_v1','trk_a2')"))

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = "c_v1f", edge_type = "out", trim_type = "ripple", track_id = "trk_v1"},
})
cmd:set_parameter("delta_frames", -30)
cmd:set_parameter("dry_run", true)

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "no BatchRippleEdit executor")
local ok, payload = executor(cmd)
assert(ok, "dry-run failed: " .. tostring(payload))
assert(type(payload) == "table", "payload must be table")

-- Shifted clips list must exclude off-track clips entirely.
for _, e in ipairs(payload.shifted_clips or {}) do
    assert(e.clip_id ~= "c_a1b" and e.clip_id ~= "c_a1f",
        string.format("FAIL: off-track clip %s appeared in shifted_clips preview", tostring(e.clip_id)))
end

-- shift_blocks must not sweep off tracks. The renderer applies a GLOBAL
-- block (no track_id) to every visible track unless told otherwise.
-- Surface the off tracks on the payload so the renderer can exclude them.
local has_global = false
for _, b in ipairs(payload.shift_blocks or {}) do
    if not b.track_id then has_global = true; break end
end

if has_global then
    assert(type(payload.off_tracks) == "table",
        "FAIL: dry-run payload has a GLOBAL shift_block but no off_tracks set — renderer will sweep off tracks")
    assert(payload.off_tracks["trk_a1"] == true,
        "FAIL: off_tracks does not include trk_a1 — renderer will sweep it under the GLOBAL shift_block")
end

layout:cleanup()
print("✅ test_ripple_sync_off_dry_run.lua passed")
