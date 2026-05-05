#!/usr/bin/env luajit
-- Regression: DRP projects where no media carries a decodeable audio rate
-- (video-only projects, or projects whose BtAudioInfo blobs all failed)
-- must still import with a valid project audio sample rate rather than
-- crashing the importer with a "audio_sample_rate required" assert.
--
-- Domain behavior: Resolve always has a project-level audio rate (Project
-- Settings → Fairlight → Timeline Sample Rate). Its DRP format encodes that
-- rate in a binary FieldsBlob we cannot yet decode; until that decoder lands,
-- 48 kHz is the documented Resolve default and must be used as the fallback.
-- Projects actually running at 96/192 kHz will have decodeable audio media,
-- so the majority-vote path handles them; the 48 kHz fallback only fires for
-- true video-only projects or decoding failures.

require("test_env")

local drp = require("importers.drp_importer")

print("=== test_drp_no_audio_project_rate.lua ===")

-- ─────────────────────────────────────────────────────────────────────────
-- Case 1: No timelines at all → must return 48000, not nil.
-- ─────────────────────────────────────────────────────────────────────────
local rate_empty = drp.pick_majority_audio_sample_rate({ timelines = {} })
assert(rate_empty == 48000, string.format(
    "empty timelines: expected 48000 fallback, got %s", tostring(rate_empty)))
print("  ✓ empty timelines: fallback to 48000")

-- ─────────────────────────────────────────────────────────────────────────
-- Case 2: Timeline with only video-only media (no audio_sample_rate set)
-- → must return 48000, not nil.
-- ─────────────────────────────────────────────────────────────────────────
local parse_video_only = {
    timelines = {
        {
            media_files = {
                clip_a = { duration = 240, frame_rate = 24 },   -- no audio_sample_rate
                clip_b = { duration = 600, frame_rate = 25 },
            }
        }
    }
}
local rate_vo = drp.pick_majority_audio_sample_rate(parse_video_only)
assert(rate_vo == 48000, string.format(
    "video-only media: expected 48000 fallback, got %s", tostring(rate_vo)))
print("  ✓ video-only project: fallback to 48000")

-- ─────────────────────────────────────────────────────────────────────────
-- Case 3: Mix of decodeable audio and video-only → majority vote wins
-- (no fallback; the decodeable rate is authoritative).
-- ─────────────────────────────────────────────────────────────────────────
local parse_mixed = {
    timelines = {
        {
            media_files = {
                av1 = { audio_sample_rate = 48000 },
                av2 = { audio_sample_rate = 48000 },
                vo1 = {},   -- video-only, no audio_sample_rate
                av3 = { audio_sample_rate = 48000 },
            }
        }
    }
}
local rate_mixed = drp.pick_majority_audio_sample_rate(parse_mixed)
assert(rate_mixed == 48000, string.format(
    "mixed: expected 48000 from vote, got %s", tostring(rate_mixed)))
print("  ✓ mixed audio/video project: vote picks correct rate")

-- ─────────────────────────────────────────────────────────────────────────
-- Case 4: 96 kHz project (Studio) — majority vote must win over fallback.
-- ─────────────────────────────────────────────────────────────────────────
local parse_96k = {
    timelines = {
        {
            media_files = {
                hi1 = { audio_sample_rate = 96000 },
                hi2 = { audio_sample_rate = 96000 },
                hi3 = { audio_sample_rate = 96000 },
            }
        }
    }
}
local rate_96k = drp.pick_majority_audio_sample_rate(parse_96k)
assert(rate_96k == 96000, string.format(
    "96k project: expected 96000 from vote, got %s", tostring(rate_96k)))
print("  ✓ 96 kHz Studio project: vote picks 96000, not fallback")

print("\n✅ test_drp_no_audio_project_rate.lua passed")
