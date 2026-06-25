#!/usr/bin/env luajit
-- Regression test: Inspector reads values correctly for every field key in
-- its schema, including the synthetic display fields (rate_display,
-- frame_rate_display) and BOOLEAN fields whose false value was being
-- coerced to nil by the old `clip_table[field] or nil` pattern.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local ClipInspectable = require("inspectable.clip")
local SequenceInspectable = require("inspectable.sequence")
local schemas = require("ui.metadata_schemas")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1; print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want))) end
end

print("=== Inspector display reads (clip + sequence) ===\n")

-- ---------------------------------------------------------------
-- Clip: BOOLEAN `false` must come through as `false`, not nil.
-- Synthetic `rate_display` must format from the frame_rate table.
-- ---------------------------------------------------------------
local fake_clip = {
    id              = "c1",
    name            = "TestClip",
    media_id        = "m1",
    enabled         = true,
    offline         = false,               -- crucial: false, not nil
    sequence_start  = 1000,
    duration        = 240,
    source_in       = 5000,
    source_out      = 5240,
    mark_in         = nil,                 -- legitimately unset
    mark_out        = 9999,
    playhead_frame  = 100,
    volume          = 0.75,
    frame_rate            = { fps_numerator = 24, fps_denominator = 1 },
}

local clip_ins = ClipInspectable.new({ clip_id = "c1", project_id = "p1", clip = fake_clip })

check("clip.name",           clip_ins:get("name"),           "TestClip")
check("clip.enabled=true",   clip_ins:get("enabled"),        true)
-- The key assertion for this regression.
check("clip.offline=false (not nil)", clip_ins:get("offline"), false)
check("clip.sequence_start", clip_ins:get("sequence_start"), 1000)
check("clip.duration",       clip_ins:get("duration"),       240)
check("clip.source_in",      clip_ins:get("source_in"),      5000)
check("clip.source_out",     clip_ins:get("source_out"),     5240)
-- mark_in is legitimately nil (no mark set).
check("clip.mark_in=nil",    clip_ins:get("mark_in"),        nil)
check("clip.mark_out",       clip_ins:get("mark_out"),       9999)
check("clip.playhead_frame", clip_ins:get("playhead_frame"), 100)
check("clip.volume",         clip_ins:get("volume"),         0.75)
check("clip.rate_display (synthetic, 24 fps)",
    clip_ins:get("rate_display"), "24 fps")

-- Schema declares rate_display exists; the Inspector will ask for it.
check("schema has clip.rate_display",
    schemas.get_field("clip", "rate_display") ~= nil, true)

-- ---------------------------------------------------------------
-- Sequence: audio_sample_rate reads from model.audio_sample_rate,
-- frame_rate_display is computed from model.frame_rate.
-- ---------------------------------------------------------------
local fake_seq = {
    id                    = "s1",
    project_id            = "p1",
    kind                  = "sequence",
    name                  = "TestSeq",
    frame_rate            = { fps_numerator = 30000, fps_denominator = 1001 },
    audio_sample_rate     = 48000,
    width                 = 1920,
    height                = 1080,
    playhead_position     = 42,
    viewport_start_time   = 0,
    viewport_duration     = 1000,
    start_timecode_frame  = 3600,
    mark_in               = nil,
    mark_out              = 2400,
}

local seq_ins = SequenceInspectable.new({
    sequence_id = "s1", project_id = "p1", sequence = fake_seq
})

check("sequence.name",                 seq_ins:get("name"),                 "TestSeq")
check("sequence.width",                seq_ins:get("width"),                1920)
check("sequence.height",               seq_ins:get("height"),               1080)
-- Key mapping: Inspector asks `audio_sample_rate` (DB column); model stores it as
-- `audio_sample_rate`. COLUMN_TO_MODEL_FIELD translates.
check("sequence.audio_sample_rate (→ audio_sample_rate)",
    seq_ins:get("audio_sample_rate"), 48000)
-- Synthetic display from rate table.
check("sequence.frame_rate_display (30000/1001 → 29.970 fps)",
    seq_ins:get("frame_rate_display"), "29.970 fps")
check("sequence.start_timecode_frame", seq_ins:get("start_timecode_frame"), 3600)
-- Key mapping: Inspector asks `playhead_frame`; model stores as `playhead_position`.
check("sequence.playhead_frame (→ playhead_position)",
    seq_ins:get("playhead_frame"), 42)
check("sequence.mark_in_frame (→ mark_in, unset = nil)",
    seq_ins:get("mark_in_frame"), nil)
check("sequence.mark_out_frame (→ mark_out)",
    seq_ins:get("mark_out_frame"), 2400)

-- Integer frame rate renders without decimals.
local fake_seq_24 = {
    id = "s2", project_id = "p1", kind = "sequence", name = "S2",
    frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    audio_sample_rate = 48000, width = 1920, height = 1080,
    playhead_position = 0, viewport_start_time = 0, viewport_duration = 0,
    start_timecode_frame = 0,
}
local seq_24 = SequenceInspectable.new({
    sequence_id = "s2", project_id = "p1", sequence = fake_seq_24
})
check("sequence.frame_rate_display (24/1 → 24 fps)",
    seq_24:get("frame_rate_display"), "24 fps")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspectable_display_values.lua passed")
