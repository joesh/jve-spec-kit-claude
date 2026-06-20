#!/usr/bin/env luajit
-- Spec 023 §5.5 / FR-015 (T043): the Inspector's Grade Fidelity display
-- must be honest about what JVE can show. A clip whose Resolve grade
-- exceeds primary-CDL fidelity (`partial`, `unrepresentable`) renders
-- ungraded in JVE, so the badge must SAY the full grade requires a
-- Resolve render — a bare enum word doesn't tell the user why the
-- viewer doesn't match Resolve. `primary` (faithfully displayed) and
-- `none` (genuinely ungraded) carry no notice.

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")
local ClipInspectable = require("inspectable.clip")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("=== ClipInspectable fidelity affordance (spec 023 §5.5) ===\n")

local db_path = "/tmp/jve/test_inspectable_fidelity_affordance.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = 1781006400
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
]], now, now, now, now))

local CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}

-- Distinct record ranges — clips must not stack on a video track
-- (schema trg_prevent_video_overlap_insert).
local CLIPS = {
    -- reproduction: what JVE can DISPLAY (FR-015 badge axis).
    { id = "c_primary", start = 0, fidelity = "primary",
      reproduction = "full", grade = { cdl = CDL, lut_ref = nil } },
    -- non-primary with a non-identity bake → APPROXIMATE.
    { id = "c_partial", start = 96, fidelity = "partial",
      reproduction = "approximate",
      grade = { cdl = nil, lut_ref = "/luts/k2383.cube" } },
    -- spatial grade (identity bake / no carrier) → NOT SHOWN.
    { id = "c_unrep", start = 192, fidelity = "unrepresentable",
      reproduction = "not_shown", grade = { cdl = nil, lut_ref = nil } },
}

for _, spec in ipairs(CLIPS) do
    local insert_sql = string.format([[
        INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
            sequence_id, sequence_start_frame, duration_frames, source_in_frame,
            source_out_frame, source_in_subframe, source_out_subframe, enabled,
            created_at, modified_at, master_layer_track_id, master_audio_track_id,
            fps_mismatch_policy, volume, playhead_frame)
        VALUES ('%s', 'p', '%s', 't', 's', 's', %d, 96, 0, 96, NULL, NULL, 1,
            %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]], spec.id, spec.id, spec.start, now, now)
    assert(db:exec(insert_sql), "clip INSERT failed for " .. spec.id)
    ClipGrade.upsert(spec.id, {
        cdl = spec.grade.cdl,
        lut_ref = spec.grade.lut_ref,
        fidelity = spec.fidelity,
        reproduction = spec.reproduction,
        source = "resolve_readback",
        stale = 0,
        synced_at = now,
    }, db)
end

local NOTICE = "requires Resolve render"

local function fidelity_display(clip_id)
    return ClipInspectable.new({
        clip_id = clip_id, project_id = "p",
    }):get("fidelity")
end
local function reproduction_field(clip_id)
    return ClipInspectable.new({
        clip_id = clip_id, project_id = "p",
    }):get("reproduction")
end

-- primary: faithfully displayed in JVE — no notice.
local d = fidelity_display("c_primary")
check("primary names its fidelity", tostring(d):find("primary", 1, true) ~= nil)
check("primary carries NO render notice",
    tostring(d):find(NOTICE, 1, true) == nil)
check("primary reproduction is 'full'", reproduction_field("c_primary") == "full")

-- partial with a real bake → APPROXIMATE: JVE shows part of the grade. The
-- look is mostly right and this state covers nearly every clip, so the
-- fidelity field carries NO notice (Joe 2026-06-19) — only the raw
-- reproduction field still exposes the value, for Find.
d = fidelity_display("c_partial")
check("partial names its fidelity", tostring(d):find("partial", 1, true) ~= nil)
check("partial carries NO render notice",
    tostring(d):find(NOTICE, 1, true) == nil)
check("partial reproduction is still 'approximate'",
    reproduction_field("c_partial") == "approximate")

-- unrepresentable spatial grade → NOT SHOWN: JVE renders passthrough, the
-- badge must say the grade is not shown (distinct from a missing grade).
d = fidelity_display("c_unrep")
check("unrepresentable names its fidelity",
    tostring(d):find("unrepresentable", 1, true) ~= nil)
check("unrepresentable says 'not shown'",
    tostring(d):find("not shown", 1, true) ~= nil)
check("unrepresentable carries the render notice",
    tostring(d):find(NOTICE, 1, true) ~= nil)
check("unrepresentable reproduction is 'not_shown'",
    reproduction_field("c_unrep") == "not_shown")

-- ungraded clip (no ClipGrade row): nil — the field stays blank.
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames, source_in_frame,
        source_out_frame, source_in_subframe, source_out_subframe, enabled,
        created_at, modified_at, master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy, volume, playhead_frame)
    VALUES ('c_bare', 'p', 'c_bare', 't', 's', 's', 288, 96, 0, 96, NULL, NULL, 1,
        %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))
check("ungraded clip shows no fidelity", fidelity_display("c_bare") == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
    print("FAILURES DETECTED")
    os.exit(1)
end
print("✅ test_inspectable_fidelity_affordance.lua passed")
