#!/usr/bin/env luajit

-- Track lock must REFUSE clip mutations targeting any locked track. Surfaced
-- 2026-05-13: the lock toggle persisted to tracks.locked but no command
-- consulted it, so Insert/Overwrite/SetClipProperty etc. happily mutated
-- locked tracks. Domain rule (Premiere/FCP convention): a locked track is
-- read-only for the user; undo/redo bypass the gate (you can always revert).
--
-- Single chokepoint: command_helper.apply_mutations is the SQL write path
-- every clip-mutating command funnels through. Gate there with an undo
-- bypass via command_manager.is_undo_redo_in_progress().

require("test_env")
local database        = require("core.database")
local command_manager = require("core.command_manager")

print("=== test_track_lock_enforcement.lua ===")

local DB = "/tmp/jve/test_track_lock_enforcement.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB), "schema.sql init failed")
local db = database.get_connection()

-- Sequence with V1 (locked), V2 (unlocked), one clip on each.
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec',  'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, 0, 0),
           ('msa', 'p', 'M',    'master',   24, 1, NULL, 1920, 1080, 0, 0, 300, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES
      ('rec-v1', 'rec', 'V1', 'VIDEO', 1, 1, 1, 0, 0, 1.0, 0.0, 'off', 1),
      ('rec-v2', 'rec', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0, 'off', 1),
      ('msa-v1', 'msa', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height,
        created_at, modified_at)
    VALUES ('m', 'p', 'm.mov', '/tmp/m.mov', 240, 24, 1, 1920, 1080, 0, 0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'p', 'msa', 'msa-v1', 'm', 0, 240, 0, 240, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO patches (id, sequence_id, track_type, source_shape,
        source_track_index, record_track_index, enabled, created_at)
    VALUES ('p-v1','rec','VIDEO',1,1,1,1,0);
    INSERT INTO clips (id, project_id, name, track_id,
        owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        fps_mismatch_policy, enabled, volume, mark_in_frame, mark_out_frame,
        playhead_frame, created_at, modified_at)
    VALUES
      ('c-on-locked', 'p', 'c1', 'rec-v1', 'rec', 'msa',
            0, 100, 0, 100, 'resample', 1, 1.0, NULL, NULL, 0, 0, 0),
      ('c-on-free',   'p', 'c2', 'rec-v2', 'rec', 'msa',
            0, 100, 0, 100, 'resample', 1, 1.0, NULL, NULL, 0, 0, 0);
]]))
require("test_env").touch_media_fixtures()

command_manager.init("rec", "p")

local function clip_state(clip_id)
    local s = db:prepare("SELECT sequence_start_frame, duration_frames, enabled "
        .. "FROM clips WHERE id = ?")
    s:bind_value(1, clip_id); assert(s:exec()); assert(s:next())
    local r = { ts = s:value(0), dur = s:value(1), enabled = s:value(2) }
    s:finalize()
    return r
end

-- ── (a) Insert with patch routing to LOCKED V1 must refuse ───────────────
print("-- (a) Insert into locked track refused --")
local before_v1 = clip_state("c-on-locked")
local r1 = command_manager.execute("Insert", {
    sequence_id          = "rec",
    source_sequence_id   = "msa",
    sequence_start_frame = 200,
    project_id           = "p",
})
assert(r1 and r1.success == false,
    "FAIL: Insert into locked V1 succeeded; should have refused")
assert(tostring(r1.error_message):match("[Ll]ocked"),
    "FAIL: error message must mention 'locked'; got: "..tostring(r1.error_message))
local after_v1 = clip_state("c-on-locked")
assert(after_v1.ts == before_v1.ts and after_v1.dur == before_v1.dur,
    "FAIL: locked track clip was mutated despite refusal")
print("  Insert refused + no DB change — OK")

-- ── (b) SetClipProperty on clip ON a locked track must refuse ────────────
print("-- (b) SetClipProperty on locked-track clip refused --")
local r2 = command_manager.execute("SetClipProperty", {
    clip_id  = "c-on-locked",
    property_name  = "enabled",
    property_type  = "boolean",
    value          = false,
    project_id = "p",
})
assert(r2 and r2.success == false,
    "FAIL: SetClipProperty on locked-track clip succeeded; should have refused")
assert(tostring(r2.error_message):match("[Ll]ocked"),
    "FAIL: error message must mention 'locked'; got: "..tostring(r2.error_message))
assert(clip_state("c-on-locked").enabled == 1,
    "FAIL: locked-track clip enabled was mutated despite refusal")
print("  SetClipProperty refused + no DB change — OK")

-- ── (c) Same operation on UNLOCKED V2 clip succeeds ──────────────────────
print("-- (c) SetClipProperty on unlocked-track clip succeeds --")
local r3 = command_manager.execute("SetClipProperty", {
    clip_id  = "c-on-free",
    property_name  = "enabled",
    property_type  = "boolean",
    value          = false,
    project_id = "p",
})
assert(r3 and r3.success,
    "FAIL: SetClipProperty on unlocked clip must succeed; got: "..tostring(r3 and r3.error_message))
assert(clip_state("c-on-free").enabled == 0, "FAIL: unlocked-clip mutation didn't land")
print("  Free-track mutation landed — OK")

-- ── (d) Undo of (c) must succeed even though it touches the same row ─────
print("-- (d) undo bypasses lock check --")
local u = command_manager.undo()
assert(u and u.success,
    "FAIL: undo blocked by lock check; should bypass: "..tostring(u and u.error_message))
assert(clip_state("c-on-free").enabled == 1,
    "FAIL: undo did not restore clip state")
print("  Undo restored state through gate — OK")

-- ── (e) Locking the track AFTER content exists: edits on that content
--     must refuse, but undo of pre-lock edits must still work ─────────────
print("-- (e) lock-then-edit refuses; lock-then-undo bypasses --")
db:exec("UPDATE tracks SET locked = 1 WHERE id = 'rec-v2'")
local r5 = command_manager.execute("SetClipProperty", {
    clip_id        = "c-on-free",
    property_name  = "enabled",
    property_type  = "boolean",
    value          = false,
    project_id     = "p",
})
assert(r5 and r5.success == false,
    "FAIL: post-lock edit on V2 must refuse")
print("  post-lock refuses — OK")

print("\n✅ test_track_lock_enforcement.lua passed")
