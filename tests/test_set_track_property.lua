#!/usr/bin/env luajit
package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')
local database = require("core.database")
local command_manager = require("core.command_manager")
local Track = require("models.track")

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== SetTrackProperty Command Tests ===\n")

local db_path = "/tmp/jve/test_set_track_property.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert project + sequence + tracks
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d)
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq 1', 'timeline', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('vt1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)
]])

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('at1', 'seq1', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0)
]])

command_manager.init("seq1", "proj1")

--------------------------------------------------------------------------------
-- 1. Mute toggle via command + undo/redo
--------------------------------------------------------------------------------
print("\n--- 1. Mute toggle via SetTrackProperty ---")
do
    local track = Track.load("at1")
    assert(track, "audio track at1 must exist")
    assert(not track.muted, "track should start unmuted")

    local result = command_manager.execute("SetTrackProperty", {
        track_id = "at1",
        property = "muted",
        value = true,
        project_id = "proj1",
    })
    assert(result.success, "SetTrackProperty(muted=true) failed: " .. tostring(result.error_message))

    local fresh = Track.load("at1")
    assert(fresh.muted == true, "track should be muted after command")

    -- Undo
    command_manager.undo()
    fresh = Track.load("at1")
    assert(fresh.muted == false, "track should be unmuted after undo")

    -- Redo
    command_manager.redo()
    fresh = Track.load("at1")
    assert(fresh.muted == true, "track should be muted after redo")

    -- Undo again to clean up
    command_manager.undo()
    print("  PASS: mute toggle + undo/redo")
end

--------------------------------------------------------------------------------
-- 2. Solo toggle via command + undo
--------------------------------------------------------------------------------
print("\n--- 2. Solo toggle via SetTrackProperty ---")
do
    local track = Track.load("at1")
    assert(track, "audio track at1 must exist")
    assert(not track.soloed, "track should start unsoloed")

    local result = command_manager.execute("SetTrackProperty", {
        track_id = "at1",
        property = "soloed",
        value = true,
        project_id = "proj1",
    })
    assert(result.success, "SetTrackProperty(soloed=true) failed")

    local fresh = Track.load("at1")
    assert(fresh.soloed == true, "track should be soloed after command")

    command_manager.undo()
    fresh = Track.load("at1")
    assert(fresh.soloed == false, "track should be unsoloed after undo")
    print("  PASS: solo toggle + undo")
end

--------------------------------------------------------------------------------
-- 3. Volume set via command
--------------------------------------------------------------------------------
print("\n--- 3. Volume set via SetTrackProperty ---")
do
    local track = Track.load("at1")
    local original_vol = track.volume

    local result = command_manager.execute("SetTrackProperty", {
        track_id = "at1",
        property = "volume",
        value = 0.5,
        project_id = "proj1",
    })
    assert(result.success, "SetTrackProperty(volume=0.5) failed")

    local fresh = Track.load("at1")
    assert(math.abs(fresh.volume - 0.5) < 0.001, "volume should be 0.5")

    command_manager.undo()
    fresh = Track.load("at1")
    assert(math.abs(fresh.volume - original_vol) < 0.001, "volume should be restored after undo")
    print("  PASS: volume set + undo")
end

--------------------------------------------------------------------------------
-- 4. Invalid property asserts
--------------------------------------------------------------------------------
print("\n--- 4. Invalid property rejected ---")
do
    local result = command_manager.execute("SetTrackProperty", {
        track_id = "at1",
        property = "nonexistent",
        value = true,
        project_id = "proj1",
    })
    assert(not result.success, "should fail for invalid property")
    assert(tostring(result.error_message):find("invalid property"),
        "error should mention invalid property, got: " .. tostring(result.error_message))
    print("  PASS: invalid property rejected correctly")
end

--------------------------------------------------------------------------------
-- 5. Locked toggle via command
--------------------------------------------------------------------------------
print("\n--- 5. Locked toggle via SetTrackProperty ---")
do
    local track = Track.load("vt1")
    assert(not track.locked, "track should start unlocked")

    local result = command_manager.execute("SetTrackProperty", {
        track_id = "vt1",
        property = "locked",
        value = true,
        project_id = "proj1",
    })
    assert(result.success, "SetTrackProperty(locked=true) failed")

    local fresh = Track.load("vt1")
    assert(fresh.locked == true, "track should be locked after command")

    command_manager.undo()
    fresh = Track.load("vt1")
    assert(fresh.locked == false, "track should be unlocked after undo")
    print("  PASS: locked toggle + undo")
end

print("\n✅ test_set_track_property.lua passed")
