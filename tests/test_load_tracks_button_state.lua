#!/usr/bin/env luajit
package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')
local database = require("core.database")
local Track = require("models.track")

print("=== load_tracks Must Return Button State Fields ===\n")

local db_path = "/tmp/jve/test_load_tracks_button_state.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d)
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq 1', 'timeline', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

-- Insert tracks with muted/soloed/locked set to TRUE
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('at1', 'seq1', 'A1', 'AUDIO', 1, 1, 1, 1, 1, 1.0, 0.0)
]])

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('at2', 'seq1', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0)
]])

--------------------------------------------------------------------------------
-- 1. load_tracks must include muted, soloed, locked fields
--------------------------------------------------------------------------------
print("\n--- 1. load_tracks returns muted/soloed/locked ---")
local tracks = database.load_tracks("seq1")
assert(#tracks == 2, "expected 2 tracks, got " .. #tracks)

-- Find at1 (all true) and at2 (all false)
local at1, at2
for _, t in ipairs(tracks) do
    if t.id == "at1" then at1 = t end
    if t.id == "at2" then at2 = t end
end
assert(at1, "at1 not found in load_tracks result")
assert(at2, "at2 not found in load_tracks result")

-- at1: all button states should be true
assert(at1.muted == true,
    string.format("at1.muted should be true, got %s (%s)", tostring(at1.muted), type(at1.muted)))
assert(at1.soloed == true,
    string.format("at1.soloed should be true, got %s (%s)", tostring(at1.soloed), type(at1.soloed)))
assert(at1.locked == true,
    string.format("at1.locked should be true, got %s (%s)", tostring(at1.locked), type(at1.locked)))

-- at2: all button states should be false
assert(at2.muted == false,
    string.format("at2.muted should be false, got %s (%s)", tostring(at2.muted), type(at2.muted)))
assert(at2.soloed == false,
    string.format("at2.soloed should be false, got %s (%s)", tostring(at2.soloed), type(at2.soloed)))
assert(at2.locked == false,
    string.format("at2.locked should be false, got %s (%s)", tostring(at2.locked), type(at2.locked)))

print("  ✓ load_tracks returns muted/soloed/locked with correct boolean values")

--------------------------------------------------------------------------------
-- 2. Verify Track.load() agrees (sanity check)
--------------------------------------------------------------------------------
print("\n--- 2. Track.load agrees with load_tracks ---")
local full_at1 = Track.load("at1")
assert(full_at1.muted == at1.muted, "muted mismatch between load_tracks and Track.load")
assert(full_at1.soloed == at1.soloed, "soloed mismatch between load_tracks and Track.load")
assert(full_at1.locked == at1.locked, "locked mismatch between load_tracks and Track.load")
print("  ✓ Track.load and load_tracks agree")

print("\n✅ test_load_tracks_button_state.lua passed")
