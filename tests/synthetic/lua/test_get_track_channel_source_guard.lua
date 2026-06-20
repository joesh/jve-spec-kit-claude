#!/usr/bin/env luajit
-- get_track_channel_source backs a nameless track's label from its recorder
-- iXML channel name. Two contracts under test:
--   1. With no database connection it must fail LOUDLY (a missing connection is
--      a caller/lifecycle bug, not a "return nil" case) — rule 1.14 fail-fast.
--   2. A track that genuinely has no channel-backed media_ref returns nil — that
--      IS a legitimate optional (a plain sequence track, not a master channel
--      track), so it must NOT assert.

require("test_env")
package.loaded["ui.panel_manager"] = { get_active_sequence_monitor = function() return nil end }

local database = require("core.database")

print("=== test_get_track_channel_source_guard.lua ===")

-- ── 1. No connection → loud assert with actionable message. Runs before any
-- database.init, so db_connection is nil. ────────────────────────────────────
local ok, err = pcall(database.get_track_channel_source, "any_track")
assert(not ok, "get_track_channel_source must fail when there is no DB connection")
assert(tostring(err):find("no database connection", 1, true),
    "assert message must name the missing DB connection, got: " .. tostring(err))
print("  ✓ no DB connection → loud, actionable assert")

-- ── 2. Connected, but a plain track with no channel-backed media_ref → nil. ──
local DB = "/tmp/jve/test_get_track_channel_source_guard.db"
os.execute("mkdir -p /tmp/jve")
for _, s in ipairs({ "", "-wal", "-shm" }) do os.remove(DB .. s) end
assert(database.init(DB))

local Project  = require("models.project")
local Sequence = require("models.sequence")
local Track    = require("models.track")

assert(Project.create("G", { id = "p", fps_mismatch_policy = "resample",
    settings = { master_clock_hz = 192000, default_fps = { num = 24, den = 1 } } }):save())
assert(Sequence.create("Seq", "p", { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { id = "seq", kind = "sequence", audio_sample_rate = 48000,
      view_start_frame = 0, view_duration_frames = 10000, playhead_frame = 0 }):save())
local a1 = Track.create_audio("A1", "seq", { index = 1 })
assert(a1:save())

assert(database.get_track_channel_source(a1.id) == nil,
    "a plain audio track with no channel-backed media_ref must return nil, not assert")
print("  ✓ track with no channel source → nil (legitimate optional)")

print("✅ test_get_track_channel_source_guard.lua passed")
