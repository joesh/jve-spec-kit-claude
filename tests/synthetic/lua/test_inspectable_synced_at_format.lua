#!/usr/bin/env luajit
-- ClipInspectable :get("synced_at") must return the raw unix epoch number
-- so the TIMESTAMP-typed field widget (M#21, pass 13) can format it.
-- Also pins the per-instance grade cache (M#1 partial): two consecutive
-- :get calls hit the DB once, not twice.

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")
local ClipInspectable = require("inspectable.clip")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("=== ClipInspectable synced_at + grade cache ===\n")

local db_path = "/tmp/jve/test_inspectable_synced_at.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = 1781006400  -- 2026-06-09 12:00:00 UTC
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume,
        playhead_frame)
    VALUES ('c1', 'p', 'c1', 't', 's', 's', 0, 96, 0, 96, NULL, NULL, 1, %d, %d,
        NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

ClipGrade.upsert("c1", {
    cdl = {
        slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
        offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
        power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
        saturation = 0.85,
    },
    lut_ref = nil,
    fidelity = "primary",
    reproduction = "full",
    source = "resolve_readback",
    stale = 0,
    synced_at = now,
}, db)

local ins = ClipInspectable.new({ clip_id = "c1", project_id = "p" })

-- synced_at must be a raw number (the TIMESTAMP widget formats it).
local synced = ins:get("synced_at")
check("synced_at is a number", type(synced) == "number")
check("synced_at equals the upserted epoch", synced == now)

-- Other ClipGrade fields still surface verbatim.
check("fidelity = 'primary'", ins:get("fidelity") == "primary")
check("source   = 'resolve_readback'", ins:get("source") == "resolve_readback")

-- Per-instance cache: drop the row, re-read; cached value must still come
-- back (proves the second :get did NOT re-hit the DB).
db:exec("DELETE FROM clip_grade WHERE clip_id = 'c1';")
check("cached synced_at survives DB delete", ins:get("synced_at") == now)
check("cached fidelity survives DB delete", ins:get("fidelity") == "primary")

-- refresh() clears the grade cache too.
ins:refresh()
check("after refresh(), synced_at is nil (row gone)", ins:get("synced_at") == nil)
check("after refresh(), fidelity is nil",             ins:get("fidelity")  == nil)

print(string.format("\n=== Pass: %d  Fail: %d ===", pass, fail))
if fail > 0 then os.exit(1) end
print("✅ test_inspectable_synced_at_format.lua passed")
