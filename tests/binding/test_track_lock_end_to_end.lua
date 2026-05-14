--- End-to-end smoke for track lock: real UI, real bindings, real commands.
---
--- Verifies:
---   1. ToggleTrackPreference(locked) flips the column and persists.
---   2. With the column flipped, the locked-track hash overlay's draw pass
---      runs without crashing (renderer iterates view.filtered_tracks and
---      issues add_line per locked row).
---   3. Insert into the locked track refuses with a "locked" error.
---   4. SetClipProperty on a clip ON the locked track refuses.
---   5. Undo of a pre-lock edit still works (bypass intact).
---
--- Runs via JVEEditor --test. Avoids stubbing — every binding is real.

local ui = require("integration.ui_test_env")

print("=== test_track_lock_end_to_end ===")

local _, info = ui.launch({
    project_name    = "Lock E2E",
    num_sequences   = 1,
    sequence_names  = { "Edit" },
    active_sequence = 1,
})

local database        = require("core.database")
local Track           = require("models.track")
local command_manager = require("core.command_manager")
local Media           = require("models.media")
local test_env        = require("test_env")

local project_id = info.project.id
local seq_id     = info.sequences[1].id

-- Seed a clip on V1 so SetClipProperty has something to target.
local v1 = Track.find_by_sequence(seq_id, "VIDEO")[1]
assert(v1, "test setup: rec V1 not present")

-- Master + media_ref backing the clip's content.
local media = Media.create({
    id = "lock-e2e-media", project_id = project_id,
    file_path = "/tmp/jve/lock_e2e.mov",
    name = "lock_e2e.mov", duration_frames = 240,
    fps_numerator = 24, fps_denominator = 1,
    width = 1920, height = 1080,
})
media:save(database.get_connection())
local mc_seq_id = test_env.create_test_masterclip_sequence(
    project_id, "Lock E2E MC", 24, 1, 240, "lock-e2e-media")

local db = database.get_connection()
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id,
        owner_sequence_id, sequence_id,
        timeline_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        fps_mismatch_policy, enabled, volume, mark_in_frame, mark_out_frame,
        playhead_frame, created_at, modified_at)
    VALUES ('e2e-clip', '%s', 'C', '%s', '%s', '%s',
        0, 120, 0, 120, 'resample', 1, 1.0, NULL, NULL, 0, 0, 0);
]], project_id, v1.id, seq_id, mc_seq_id)),
    "test setup: failed to seed clip")

ui.pump(50)

-- ── 1. Toggle lock ON via the real command ────────────────────────────────
print("-- toggle lock --")
local r_lock = command_manager.execute("ToggleTrackPreference", {
    track_id   = v1.id,
    property = "locked",
    project_id = project_id,
})
assert(r_lock and r_lock.success,
    "FAIL: ToggleTrackPreference failed: " .. tostring(r_lock and r_lock.error_message))
local t = Track.load(v1.id)
assert(t.locked == true, "FAIL: tracks.locked must be true after toggle")
print("  V1 locked — OK")

-- ── 2. Render runs without crash (hash overlay path active) ──────────────
-- Pump so renderer invalidates and redraws with the new lock state.
ui.pump(100)
-- No crash by here = pass. Renderer reads track.locked at draw time (MVC).
print("  render pumped without crash — OK")

-- ── 3. Insert into locked V1 refuses ──────────────────────────────────────
print("-- Insert refuses --")
-- A patch routing source V1 → rec V1 makes Insert target the locked V1.
-- Use INSERT OR REPLACE so a default patch seeded by the sequence
-- setup doesn't collide on the UNIQUE constraint.
assert(db:exec(string.format([[
    INSERT OR REPLACE INTO patches
        (id, sequence_id, track_type, source_shape,
         source_track_index, record_track_index, enabled, created_at)
    VALUES ('e2e-patch-v1', '%s', 'VIDEO', 1, 1, 1, 1, 0);
]], seq_id)), "test setup: failed to upsert patch")
local r_ins = command_manager.execute("Insert", {
    sequence_id          = seq_id,
    source_sequence_id   = mc_seq_id,
    timeline_start_frame = 130,
    project_id           = project_id,
})
assert(r_ins and r_ins.success == false,
    "FAIL: Insert into locked V1 must refuse; got "
    .. tostring(r_ins and r_ins.error_message))
assert(tostring(r_ins.error_message):match("[Ll]ocked"),
    "FAIL: error must mention 'locked'; got: "..tostring(r_ins.error_message))
print("  Insert refused — OK")

-- ── 4. SetClipProperty on locked-track clip refuses ───────────────────────
print("-- SetClipProperty refuses --")
local r_set = command_manager.execute("SetClipProperty", {
    clip_id        = "e2e-clip",
    property_name  = "enabled",
    property_type  = "boolean",
    value          = false,
    project_id     = project_id,
})
assert(r_set and r_set.success == false,
    "FAIL: SetClipProperty on locked-track clip must refuse")
assert(tostring(r_set.error_message):match("[Ll]ocked"),
    "FAIL: SetClipProperty error must mention locked")
print("  SetClipProperty refused — OK")

-- ── 5. Undo bypass: unlock, edit, lock again, undo must succeed ──────────
print("-- undo bypass --")
-- Unlock so we can land an edit.
local r_unlock = command_manager.execute("ToggleTrackPreference", {
    track_id = v1.id, property = "locked", project_id = project_id,
})
assert(r_unlock and r_unlock.success, "FAIL: unlock failed")
assert(Track.load(v1.id).locked == false, "FAIL: track should be unlocked")

local r_edit = command_manager.execute("SetClipProperty", {
    clip_id        = "e2e-clip",
    property_name  = "enabled",
    property_type  = "boolean",
    value          = false,
    project_id     = project_id,
})
assert(r_edit and r_edit.success, "FAIL: edit on unlocked track must succeed")

-- Re-lock then undo.
command_manager.execute("ToggleTrackPreference", {
    track_id = v1.id, property = "locked", project_id = project_id,
})
assert(Track.load(v1.id).locked == true, "FAIL: re-lock didn't stick")
local r_undo = command_manager.undo()
assert(r_undo and r_undo.success,
    "FAIL: undo blocked despite lock-bypass; got "
    .. tostring(r_undo and r_undo.error_message))
print("  Undo bypassed lock — OK")

print("\n✅ test_track_lock_end_to_end passed")
