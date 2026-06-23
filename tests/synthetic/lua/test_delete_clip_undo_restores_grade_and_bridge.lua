-- Regression (spec 023): DeleteClip + undo must restore clip_grade and
-- resolve_bridge_link rows. ON DELETE CASCADE drops them when the clip row
-- is deleted; undo's capture/restore was missing both satellites, so the
-- color grade and the Resolve identity binding silently vanished.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== DeleteClip Undo Restores Grade + Bridge Link ===")

local db_path = "/tmp/jve/test_delete_clip_grade_bridge.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
    VALUES ('_v13_placeholder_media', 'proj1', 'placeholder', '_placeholder', 5200, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('_v13_placeholder_master', 'proj1', 'placeholder_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('_v13_placeholder_mr', 'proj1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 5200, 0, 5200, 48000, 1, 1.0, 0, 0, 0);

    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, volume, mark_in_frame, mark_out_frame, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy) VALUES
        ('clip1', 'proj1', 'TestClip', 'v1', '_v13_placeholder_master', 'seq1', 100, 200, 5000, 5200, 1, 1.0, 30, 170, 85, %d, %d, NULL, NULL, 'resample');
]], now, now))

-- Write a primary CDL grade (all-or-none invariant) + a resolve identity link.
-- Non-trivial values so a partial restore (zeroed) wouldn't accidentally match.
local synced_at = now - 3600
db:exec(string.format([[
    INSERT INTO clip_grade
        (clip_id, slope_r, slope_g, slope_b, offset_r, offset_g, offset_b,
         power_r, power_g, power_b, saturation,
         lut_ref, fidelity, reproduction, source, stale, synced_at)
    VALUES
        ('clip1', 1.05, 0.97, 1.12, 0.03, -0.02, 0.01,
         1.08, 1.00, 0.93, 1.15,
         'luts/take03.cube', 'primary', 'full', 'resolve', 0, %d);
]], synced_at))

db:exec([[
    INSERT INTO resolve_bridge_link
        (jve_clip_uuid, resolve_item_id, grade_fingerprint, edit_fingerprint)
    VALUES
        ('clip1', 'resolve-item-XYZ', 'gfp-abc123', 'efp-def456');
]])

command_manager.init("seq1", "proj1")

local function execute_cmd(name, params)
    params = params or {}
    params.project_id = params.project_id or "proj1"
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

local function row_exists(table_name, key_col, key_val)
    local q = db:prepare(string.format("SELECT 1 FROM %s WHERE %s = ?", table_name, key_col))
    q:bind_value(1, key_val)
    local hit = q:exec() and q:next()
    q:finalize()
    return hit and true or false
end

local function fetch_grade(clip_id)
    local q = db:prepare([[
        SELECT slope_r, slope_g, slope_b, offset_r, offset_g, offset_b,
               power_r, power_g, power_b, saturation,
               lut_ref, fidelity, reproduction, source, stale, synced_at
        FROM clip_grade WHERE clip_id = ?
    ]])
    q:bind_value(1, clip_id)
    if not (q:exec() and q:next()) then q:finalize(); return nil end
    local g = {
        slope_r = q:value(0), slope_g = q:value(1), slope_b = q:value(2),
        offset_r = q:value(3), offset_g = q:value(4), offset_b = q:value(5),
        power_r = q:value(6), power_g = q:value(7), power_b = q:value(8),
        saturation = q:value(9),
        lut_ref = q:value(10), fidelity = q:value(11),
        reproduction = q:value(12), source = q:value(13),
        stale = q:value(14), synced_at = q:value(15),
    }
    q:finalize()
    return g
end

local function fetch_bridge(clip_id)
    local q = db:prepare([[
        SELECT resolve_item_id, grade_fingerprint, edit_fingerprint
        FROM resolve_bridge_link WHERE jve_clip_uuid = ?
    ]])
    q:bind_value(1, clip_id)
    if not (q:exec() and q:next()) then q:finalize(); return nil end
    local b = {
        resolve_item_id   = q:value(0),
        grade_fingerprint = q:value(1),
        edit_fingerprint  = q:value(2),
    }
    q:finalize()
    return b
end

print("\n--- Pre-delete ---")
check("clip exists",      row_exists("clips", "id", "clip1"))
check("grade exists",     row_exists("clip_grade", "clip_id", "clip1"))
check("bridge exists",    row_exists("resolve_bridge_link", "jve_clip_uuid", "clip1"))

print("\n--- Delete clip ---")
local r = execute_cmd("DeleteClip", {clip_id = "clip1", sequence_id = "seq1"})
check("delete succeeds", r and (r.success or r == true))
check("clip row gone",    not row_exists("clips", "id", "clip1"))
check("grade gone (CASCADE)",  not row_exists("clip_grade", "clip_id", "clip1"))
check("bridge gone (CASCADE)", not row_exists("resolve_bridge_link", "jve_clip_uuid", "clip1"))

print("\n--- Undo ---")
r = undo()
check("undo succeeds", r and (r.success or r == true))
check("clip restored",   row_exists("clips", "id", "clip1"))

local g = fetch_grade("clip1")
check("grade restored", g ~= nil)
if g then
    check("grade slope_r",     math.abs(g.slope_r - 1.05) < 1e-9)
    check("grade slope_g",     math.abs(g.slope_g - 0.97) < 1e-9)
    check("grade slope_b",     math.abs(g.slope_b - 1.12) < 1e-9)
    check("grade offset_r",    math.abs(g.offset_r - 0.03) < 1e-9)
    check("grade offset_g",    math.abs(g.offset_g - (-0.02)) < 1e-9)
    check("grade offset_b",    math.abs(g.offset_b - 0.01) < 1e-9)
    check("grade power_r",     math.abs(g.power_r - 1.08) < 1e-9)
    check("grade power_g",     math.abs(g.power_g - 1.00) < 1e-9)
    check("grade power_b",     math.abs(g.power_b - 0.93) < 1e-9)
    check("grade saturation",  math.abs(g.saturation - 1.15) < 1e-9)
    check("grade lut_ref",     g.lut_ref == "luts/take03.cube")
    check("grade fidelity",    g.fidelity == "primary")
    check("grade reproduction",g.reproduction == "full")
    check("grade source",      g.source == "resolve")
    check("grade stale",       g.stale == 0)
    check("grade synced_at",   g.synced_at == synced_at)
end

local b = fetch_bridge("clip1")
check("bridge restored", b ~= nil)
if b then
    check("bridge resolve_item_id",   b.resolve_item_id   == "resolve-item-XYZ")
    check("bridge grade_fingerprint", b.grade_fingerprint == "gfp-abc123")
    check("bridge edit_fingerprint",  b.edit_fingerprint  == "efp-def456")
end

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_delete_clip_undo_restores_grade_and_bridge.lua passed")
