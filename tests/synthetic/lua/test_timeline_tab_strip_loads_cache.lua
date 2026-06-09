#!/usr/bin/env luajit

-- Spec 022 Phase 1.2 — strip open hooks hydrate the per-tab cache.
--
-- After TimelineTabStrip:open_record_tab / open_source_tab the returned
-- tab's .cache fields are populated from the project DB. The reload path
-- (open_source_tab when source already open) re-hydrates the cache for
-- the new sequence_id.
--
-- Still empty plumbing: nothing reads from .cache yet. This test pins
-- the lifecycle contract — cache is loaded at tab-open and at source-
-- tab-reload — so later phases (1.3a re-pointing indexes) can rely on
-- "an open tab always has a populated cache."

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")

print("=== test_timeline_tab_strip_loads_cache.lua ===")

local DB = "/tmp/jve/test_timeline_tab_strip_loads_cache.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
        created_at, modified_at)
    VALUES ('recA', 'proj', 'A', 'sequence',
                24, 1, 48000,
                1920, 1080,
                1234, 50, 800,
                17, 23, 0.4,
                %d, %d),
           ('recB', 'proj', 'B', 'sequence',
                30, 1, 48000,
                1920, 1080,
                4321, 0, 600,
                0, 0, 0.5,
                %d, %d),
           ('srcM', 'proj', 'M', 'master',
                24, 1, NULL,
                1920, 1080,
                0, 0, 300,
                0, 0, 0.5,
                %d, %d)
]], now, now, now, now, now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name)
    VALUES ('trkA_v1', 'recA', 'VIDEO', 1, 'V1'),
           ('trkB_v1', 'recB', 'VIDEO', 1, 'V1')
]])

-- ── open_record_tab hydrates the cache ────────────────────────────────────
local strip = TimelineTabStrip.new()
local tabA = strip:open_record_tab("recA")
assert(tabA.cache.playhead_position == 1234,
    string.format("recA cache.playhead from DB (got %s)",
        tostring(tabA.cache.playhead_position)))
assert(tabA.cache.viewport_start_time == 50, "recA cache.viewport from DB")
assert(tabA.cache.viewport_duration == 800, "recA cache.viewport_duration from DB")
assert(tabA.cache.video_scroll_offset == 17, "recA cache.video_scroll from DB")
assert(math.abs(tabA.cache.video_audio_split_ratio - 0.4) < 1e-9,
    "recA cache.split_ratio from DB")
assert(#tabA.cache.tracks == 1 and tabA.cache.tracks[1].id == "trkA_v1",
    "recA cache.tracks loaded")
assert(tabA.cache.sequence_frame_rate.fps_numerator == 24,
    "recA cache.frame_rate loaded")
print("✓ open_record_tab hydrates cache from DB")

-- Idempotent open returns the SAME tab object — cache must not be wiped
-- by a re-open (the user clicking an already-open tab is not a reload).
local tabA_again = strip:open_record_tab("recA")
assert(tabA_again == tabA, "open_record_tab idempotent")
assert(tabA_again.cache.playhead_position == 1234,
    "idempotent open preserves cache")
print("✓ open_record_tab idempotent without re-loading cache")

-- Open a second record tab: it gets its own independent cache.
local tabB = strip:open_record_tab("recB")
assert(tabB ~= tabA, "distinct record tabs are distinct objects")
assert(tabB.cache.playhead_position == 4321,
    string.format("recB cache distinct from recA (got %s)",
        tostring(tabB.cache.playhead_position)))
assert(tabB.cache.sequence_frame_rate.fps_numerator == 30,
    "recB cache.frame_rate is its own")
print("✓ each record tab has independent cache")

-- ── open_source_tab hydrates the cache ────────────────────────────────────
local src = strip:open_source_tab("srcM")
assert(src.cache.sequence_frame_rate ~= nil,
    "source tab cache populated by open_source_tab")
assert(type(src.cache.tracks) == "table", "source tab cache.tracks present")
print("✓ open_source_tab hydrates cache from DB")

-- ── open_source_tab(other_seq) re-hydrates the singleton ──────────────────
-- A second open_source_tab with a different sequence_id reloads the same
-- tab object (singleton). The cache must update to the new sequence.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
        created_at, modified_at)
    VALUES ('srcM2', 'proj', 'M2', 'master',
                30, 1, NULL,
                1920, 1080,
                9999, 0, 100,
                0, 0, 0.5,
                %d, %d)
]], now, now))
local src_after = strip:open_source_tab("srcM2")
assert(src_after == src, "source tab singleton survives reload")
assert(src_after.sequence_id == "srcM2", "sequence_id updated on reload")
assert(src_after.cache.sequence_frame_rate.fps_numerator == 30,
    "source tab cache.frame_rate re-loaded from new sequence row")
assert(src_after.cache.playhead_position == 9999,
    "source tab cache.playhead re-loaded from new sequence row")
print("✓ open_source_tab reload re-hydrates cache")

print("✅ test_timeline_tab_strip_loads_cache.lua passed")
