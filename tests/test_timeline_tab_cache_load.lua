#!/usr/bin/env luajit

-- Spec 022 Phase 1.1 — per-tab cache + tab:load_from_database.
--
-- Each TimelineTab owns its own copy of the per-sequence model state
-- (tracks, clips with gaps, viewport, playhead, scroll, rate). The cache
-- is populated by tab:load_from_database() which reads the project DB
-- and the sequence row. Selection and drag state are NOT per-tab — both
-- remain global on timeline_state (selection is global by design, drag
-- because cross-timeline drags are supported).
--
-- Empty-plumbing phase: no reader in the codebase pulls from the per-tab
-- cache yet. This test pins the cache contract directly on the tab so
-- subsequent phases (1.3a re-pointing indexes, 1.3b accessor delegation,
-- 1.4 signal dispatch) build on a verified storage layer.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTab = require("ui.timeline.timeline_tab")

print("=== test_timeline_tab_cache_load.lua ===")

-- ── DB setup ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_timeline_tab_cache_load.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))

-- A regular (non-master) sequence with a known persisted state: viewport,
-- playhead, scroll offsets, split ratio all set to non-default values so
-- the cache load is observably distinct from the constructor defaults.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
        start_timecode_frame, created_at, modified_at)
    VALUES ('seqA', 'proj', 'A', 'sequence',
        24, 1, 48000,
        1920, 1080,
        7777, 100, 5000,
        13, 21, 0.625,
        86400, %d, %d)
]], now, now))

-- Two tracks: V1 and A1. Heights persisted to non-default values so the
-- cache load is observably distinct.
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name)
    VALUES ('trk_v1', 'seqA', 'VIDEO', 1, 'V1'),
           ('trk_a1', 'seqA', 'AUDIO', 1, 'A1')
]])

-- Two clips on V1 with a 200-frame gap between them at frames 500..700.
-- No media setup needed — load_clips LEFT JOINs media_refs so absent media
-- just leaves media_path nil; gap_lifecycle computes the interior gap from
-- sequence_start/duration alone. seqA references itself as `sequence_id`
-- (single-sequence fixture; no nesting) to satisfy the load_clips JOIN.
local fix_ok, fix_err = db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, name,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        fps_mismatch_policy, volume, playhead_frame, enabled,
        created_at, modified_at)
    VALUES ('clip_a', 'proj', 'seqA', 'seqA',
                'trk_v1', 'a',
                0, 500,
                0, 500,
                'resample', 1.0, 0, 1,
                %d, %d),
           ('clip_b', 'proj', 'seqA', 'seqA',
                'trk_v1', 'b',
                700, 300,
                500, 800,
                'resample', 1.0, 0, 1,
                %d, %d)
]], now, now, now, now))
assert(fix_ok, "fixture clips insert failed: " .. tostring(fix_err))

-- ── 1. cache exists at construction with empty defaults ───────────────────
local tab = TimelineTab.new("record", "seqA")
assert(tab.cache, "tab.cache table must exist at construction")
assert(type(tab.cache.tracks) == "table" and #tab.cache.tracks == 0,
    "cache.tracks starts empty")
assert(type(tab.cache.clips) == "table" and #tab.cache.clips == 0,
    "cache.clips starts empty")
assert(tab.cache.content_length == 0, "cache.content_length starts at 0")
assert(tab.cache.sequence_frame_rate == nil,
    "cache.sequence_frame_rate is nil until load_from_database")
assert(tab.cache.playhead_position == 0, "cache.playhead_position starts at 0")
assert(tab.cache.viewport_start_time == 0, "cache.viewport_start_time starts at 0")
assert(tab.cache.viewport_duration == 0, "cache.viewport_duration starts at 0")
assert(tab.cache.video_scroll_offset == 0, "cache.video_scroll_offset starts at 0")
assert(tab.cache.audio_scroll_offset == 0, "cache.audio_scroll_offset starts at 0")
assert(tab.cache.video_audio_split_ratio == 0.5,
    "cache.video_audio_split_ratio starts at 0.5")
assert(tab.cache.sequence_timecode_start_frame == 0,
    "cache.sequence_timecode_start_frame starts at 0")
print("✓ cache exists at construction with empty defaults")

-- ── 2. load_from_database populates cache from DB ─────────────────────────
tab:load_from_database()

-- Sequence-row fields propagate verbatim.
assert(tab.cache.playhead_position == 7777,
    string.format("playhead from seq row (got %s)", tostring(tab.cache.playhead_position)))
assert(tab.cache.viewport_start_time == 100,
    string.format("viewport_start_time from seq row (got %s)",
        tostring(tab.cache.viewport_start_time)))
assert(tab.cache.viewport_duration == 5000,
    string.format("viewport_duration from seq row (got %s)",
        tostring(tab.cache.viewport_duration)))
assert(tab.cache.video_scroll_offset == 13, "video_scroll_offset from seq row")
assert(tab.cache.audio_scroll_offset == 21, "audio_scroll_offset from seq row")
assert(math.abs(tab.cache.video_audio_split_ratio - 0.625) < 1e-9,
    "video_audio_split_ratio from seq row")
assert(tab.cache.sequence_timecode_start_frame == 86400,
    "start_timecode_frame from seq row")
assert(type(tab.cache.sequence_frame_rate) == "table"
    and tab.cache.sequence_frame_rate.fps_numerator == 24
    and tab.cache.sequence_frame_rate.fps_denominator == 1,
    "sequence_frame_rate from seq row")

-- Tracks loaded from DB.
assert(#tab.cache.tracks == 2,
    string.format("tracks loaded (got %d)", #tab.cache.tracks))
local track_by_id = {}
for _, t in ipairs(tab.cache.tracks) do track_by_id[t.id] = t end
assert(track_by_id.trk_v1 and track_by_id.trk_v1.track_type == "VIDEO",
    "V1 loaded with correct type")
assert(track_by_id.trk_a1 and track_by_id.trk_a1.track_type == "AUDIO",
    "A1 loaded with correct type")

-- Media clips + computed gap clips both present.
local media_count, gap_count = 0, 0
for _, c in ipairs(tab.cache.clips) do
    if c.is_gap then gap_count = gap_count + 1
    else media_count = media_count + 1 end
end
assert(media_count == 2, string.format("2 media clips (got %d)", media_count))
-- V1 has an interior gap at 500..700 between clip_a and clip_b. A1 has no
-- media so no gap is computed (gap_lifecycle only emits gaps between media).
assert(gap_count >= 1, string.format(
    "at least one derived gap clip computed (got %d)", gap_count))

-- Locate the interior gap on V1.
local found_v1_gap = false
for _, c in ipairs(tab.cache.clips) do
    if c.is_gap and c.track_id == "trk_v1"
       and c.sequence_start == 500 and c.duration == 200 then
        found_v1_gap = true; break
    end
end
assert(found_v1_gap,
    "V1 interior gap at frames 500..700 must appear in cache.clips")

-- content_length: clip_b ends at 700 + 300 = 1000.
assert(tab.cache.content_length == 1000,
    string.format("content_length = 1000 (got %s)",
        tostring(tab.cache.content_length)))
print("✓ load_from_database populates cache from DB (incl. derived gaps)")

-- ── 3. load_from_database is idempotent — second call yields same shape ──
local first_clip_count = #tab.cache.clips
local first_track_count = #tab.cache.tracks
tab:load_from_database()
assert(#tab.cache.clips == first_clip_count,
    "second load yields same clip count")
assert(#tab.cache.tracks == first_track_count,
    "second load yields same track count")
assert(tab.cache.playhead_position == 7777, "second load preserves playhead")
print("✓ load_from_database is idempotent")

-- ── 4. load asserts on a sequence with NULL invariants (Sequence.load
--      asserts on the schema level; we re-verify the tab surfaces the
--      error rather than silently caching half-state) ─────────────────────
db:exec("DELETE FROM sequences WHERE id='seqA'")
local ok, err = pcall(function() tab:load_from_database() end)
assert(not ok, "load_from_database must fail when sequence is gone")
assert(tostring(err):find("seqA", 1, true),
    "error must name the offending sequence id; got: " .. tostring(err))
print("✓ load_from_database asserts on missing sequence")

print("✅ test_timeline_tab_cache_load.lua passed")
