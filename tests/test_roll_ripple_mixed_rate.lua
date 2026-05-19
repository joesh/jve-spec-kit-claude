#!/usr/bin/env luajit

-- Regression: roll/ripple with audio clips (48000 sample rate) on a 25fps
-- sequence must convert source deltas correctly. These tests use the DSL
-- with explicit non-default rates to catch unit mismatch bugs.

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")
local validator = require("tests.helpers.project_validator")
local timeline_state = require("ui.timeline.timeline_state")

local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local AUDIO_RATE = 48000
local SAMPLES_PER_FRAME = AUDIO_RATE / SEQ_FPS_NUM  -- 1920

-- =========================================================================
-- Helper: create a layout with one audio track at 48000 rate
-- =========================================================================

local function make_audio_layout(clips_cfg)
    return ripple_layout.create({
        db_path = "/tmp/jve/test_mixed_rate_" .. os.time() .. "_" .. math.random(99999) .. ".db",
        fps_numerator = SEQ_FPS_NUM,
        fps_denominator = SEQ_FPS_DEN,
        tracks = {
            order = {"a1"},
            a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 1, enabled = 1},
        },
        media = {
            order = {"main"},
            main = {
                id = "media_audio", name = "Audio", file_path = "synthetic://audio",
                duration_frames = AUDIO_RATE * 600,  -- 10 minutes in samples
                fps_numerator = AUDIO_RATE, fps_denominator = 1,
                width = 0, height = 0, audio_channels = 2, codec = "pcm", metadata = "{}",
            },
        },
        clips = clips_cfg,
    })
end

local function fix_source_out(layout, clip_id, source_in, duration_frames)
    -- Set source_out = source_in + duration_in_samples (speed 1.0)
    local source_out = source_in + duration_frames * SAMPLES_PER_FRAME
    local stmt = layout.db:prepare("UPDATE clips SET source_out_frame = ? WHERE id = ?")
    stmt:bind_value(1, source_out)
    stmt:bind_value(2, clip_id)
    assert(stmt:exec())
    stmt:finalize()
    -- Re-sync timeline_state: direct SQL bypassed the in-memory model.
    -- batch_ripple_edit now reads clips from timeline_state, so stale
    -- source_out values here would cause unit conversion math to fail.
    timeline_state.init(layout.sequence_id, layout.project_id)
    return source_out
end

local passed = 0
local failed = 0
local errors = {}

local function run(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  " .. name .. " — passed")
    else
        failed = failed + 1
        table.insert(errors, err)
        print("  " .. name .. " — FAILED: " .. tostring(err))
    end
end

-- =========================================================================
-- Test 1: Roll on audio clips — source_in changes by samples, not frames
-- =========================================================================

run("roll audio: source_in changes in samples", function()
    local layout = make_audio_layout({
        order = {"left", "right", "downstream"},
        left = {
            id = "clip_left", name = "Left", track_key = "a1", media_key = "main",
            sequence_start = 0, duration = 100,
            source_in = 96000,  -- 2 seconds in samples
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
        right = {
            id = "clip_right", name = "Right", track_key = "a1", media_key = "main",
            sequence_start = 100, duration = 100,
            source_in = 288000,  -- 6 seconds
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
        downstream = {
            id = "clip_ds", name = "Downstream", track_key = "a1", media_key = "main",
            sequence_start = 200, duration = 50,
            source_in = 480000,  -- 10 seconds
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
    })
    fix_source_out(layout, "clip_left", 96000, 100)
    fix_source_out(layout, "clip_right", 288000, 100)
    fix_source_out(layout, "clip_ds", 480000, 50)

    local right_before = Clip.load("clip_right")

    -- Roll left:out + right:in by 10 frames
    local delta = 10
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = "clip_left", edge_type = "out", track_id = "track_a1", trim_type = "roll"},
        {clip_id = "clip_right", edge_type = "in", track_id = "track_a1", trim_type = "roll"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Roll failed: " .. tostring(result.error_message))

    validator.assert_valid(layout.db, nil, layout.sequence_id, "after audio roll")

    local right_after = Clip.load("clip_right")

    -- source_in should change by 10 * 1920 = 19200 samples
    local expected_delta = delta * SAMPLES_PER_FRAME
    local actual_delta = right_after.source_in - right_before.source_in
    assert(actual_delta == expected_delta,
        string.format("source_in delta: got %d, expected %d", actual_delta, expected_delta))

    -- source_out should NOT change (in-edge trim)
    assert(right_after.source_out == right_before.source_out,
        string.format("source_out should not change: before=%d after=%d",
            right_before.source_out, right_after.source_out))

    -- Downstream should NOT shift (roll)
    local ds = Clip.load("clip_ds")
    assert(ds.sequence_start == 200, "Downstream shifted — roll acted as ripple!")

    command_manager.undo()
    layout:cleanup()
end)

-- =========================================================================
-- Test 2: Ripple on audio — source_in changes in samples, downstream shifts
-- =========================================================================

run("ripple audio: source_in in samples, downstream shifts", function()
    local layout = make_audio_layout({
        order = {"clip_a", "clip_b"},
        clip_a = {
            id = "clip_a", name = "A", track_key = "a1", media_key = "main",
            sequence_start = 0, duration = 100,
            source_in = 48000,
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
        clip_b = {
            id = "clip_b", name = "B", track_key = "a1", media_key = "main",
            sequence_start = 100, duration = 100,
            source_in = 240000,
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
    })
    fix_source_out(layout, "clip_a", 48000, 100)
    fix_source_out(layout, "clip_b", 240000, 100)

    -- Ripple A out by +20 frames — A extends, B shifts right
    local delta = 20
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = "clip_a", edge_type = "out", track_id = "track_a1", trim_type = "ripple"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Ripple failed")

    validator.assert_valid(layout.db, nil, layout.sequence_id, "after audio ripple")

    local a = Clip.load("clip_a")
    assert(a.duration == 120, "A duration should be 120")

    -- A's source_out should extend by delta in SAMPLES (20 * 1920 = 38400)
    assert(a.source_out == 48000 + 120 * SAMPLES_PER_FRAME,
        string.format("A source_out: got %d, expected %d",
            a.source_out, 48000 + 120 * SAMPLES_PER_FRAME))

    -- B should shift right by 20 frames
    local b = Clip.load("clip_b")
    assert(b.sequence_start == 120, "B should shift to 120")

    command_manager.undo()
    layout:cleanup()
end)

-- =========================================================================
-- Test 3: Roll vs ripple comparison on audio — must differ
-- =========================================================================

run("audio: roll vs ripple produce different downstream results", function()
    local function make_layout()
        local l = make_audio_layout({
            order = {"x", "y", "z"},
            x = {
                id = "clip_x", name = "X", track_key = "a1", media_key = "main",
                sequence_start = 0, duration = 100,
                source_in = 96000,
                fps_numerator = AUDIO_RATE, fps_denominator = 1,
            },
            y = {
                id = "clip_y", name = "Y", track_key = "a1", media_key = "main",
                sequence_start = 100, duration = 200,
                source_in = 288000,
                fps_numerator = AUDIO_RATE, fps_denominator = 1,
            },
            z = {
                id = "clip_z", name = "Z", track_key = "a1", media_key = "main",
                sequence_start = 300, duration = 100,
                source_in = 672000,
                fps_numerator = AUDIO_RATE, fps_denominator = 1,
            },
        })
        fix_source_out(l, "clip_x", 96000, 100)
        fix_source_out(l, "clip_y", 288000, 200)
        fix_source_out(l, "clip_z", 672000, 100)
        return l
    end

    -- Roll
    local l1 = make_layout()
    local roll_cmd = Command.create("BatchRippleEdit", l1.project_id)
    roll_cmd:set_parameter("sequence_id", l1.sequence_id)
    roll_cmd:set_parameter("edge_infos", {
        {clip_id = "clip_x", edge_type = "out", track_id = "track_a1", trim_type = "roll"},
        {clip_id = "clip_y", edge_type = "in", track_id = "track_a1", trim_type = "roll"},
    })
    roll_cmd:set_parameter("delta_frames", 15)
    command_manager.execute(roll_cmd)
    local z_after_roll = Clip.load("clip_z").sequence_start
    command_manager.undo()
    l1:cleanup()

    -- Ripple
    local l2 = make_layout()
    local rip_cmd = Command.create("BatchRippleEdit", l2.project_id)
    rip_cmd:set_parameter("sequence_id", l2.sequence_id)
    rip_cmd:set_parameter("edge_infos", {
        {clip_id = "clip_x", edge_type = "out", track_id = "track_a1", trim_type = "ripple"},
    })
    rip_cmd:set_parameter("delta_frames", 15)
    command_manager.execute(rip_cmd)
    local z_after_ripple = Clip.load("clip_z").sequence_start
    command_manager.undo()
    l2:cleanup()

    assert(z_after_roll == 300, "Roll should not shift Z: got " .. z_after_roll)
    assert(z_after_ripple == 315, "Ripple should shift Z to 315: got " .. z_after_ripple)
    assert(z_after_roll ~= z_after_ripple, "Roll and ripple produced same result!")
end)

-- =========================================================================
-- Results
-- =========================================================================

if failed > 0 then
    print("\nFailed:")
    for _, e in ipairs(errors) do print("  " .. tostring(e)) end
end

assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_roll_ripple_mixed_rate.lua passed")
