#!/usr/bin/env luajit

-- Spec 022 Phase 1.5 — measure tab-switch latency between two record tabs
-- each holding ~3000 clips.
--
-- The plan calls for sub-millisecond switches: "Tab switch becomes a pointer
-- swap on the strip, NOT a cache rebuild. ... If it still rebuilds, you missed
-- a hook." This measurement isolates two flavors of switch:
--
--   1. Raw `strip:switch_active_record(tab)` — the pure pointer-swap step.
--      Per the per-tab cache architecture, this is the metric that defines
--      "Phase 1 delivered its perf claim."
--
--   2. `timeline_state.switch_to_record_tab(seq_id)` — the full user-facing
--      operation. Today this still routes through `core.activate_displayed`
--      → `load_displayed_sequence`, which re-reads tracks + clips from SQLite
--      every switch. The deferred 1.3f cleanup migrates writes off
--      `data.state.clips/tracks`, after which `activate_displayed` can be
--      reduced to a strip-pointer move (no DB hit). Until then this number
--      will dominate.
--
-- This test PRINTS but does NOT assert thresholds. Numbers are the
-- deliverable.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

print("=== test_timeline_tab_switch_perf.lua ===")

local DB = "/tmp/jve/test_timeline_tab_switch_perf.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample',
        '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))

-- Two record sequences with identical shape.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
        start_timecode_frame, created_at, modified_at)
    VALUES
        ('seqA', 'proj', 'A', 'sequence', 24, 1, 48000, 1920, 1080,
                0, 0, 30000, 0, 0, 0.5, 0, %d, %d),
        ('seqB', 'proj', 'B', 'sequence', 24, 1, 48000, 1920, 1080,
                0, 0, 30000, 0, 0, 0.5, 0, %d, %d)
]], now, now, now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name)
    VALUES
        ('tA_v1', 'seqA', 'VIDEO', 1, 'V1'),
        ('tB_v1', 'seqB', 'VIDEO', 1, 'V1')
]])

local CLIPS_PER_SEQ = 3000

local function insert_many_clips(seq_id, track_id, count)
    db:exec("BEGIN TRANSACTION")
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
            track_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, volume, playhead_frame, enabled,
            created_at, modified_at)
        VALUES (?, 'proj', ?, ?, ?, ?,
                ?, 8, 0, 8, 'resample', 1.0, 0, 1, ?, ?)
    ]])
    for i = 1, count do
        local id = string.format("%s_clip_%05d", seq_id, i)
        stmt:reset()
        stmt:bind_value(1, id)
        stmt:bind_value(2, seq_id)
        stmt:bind_value(3, seq_id)
        stmt:bind_value(4, track_id)
        stmt:bind_value(5, string.format("clip %d", i))
        stmt:bind_value(6, (i - 1) * 10)  -- 8-frame clips with 2-frame gaps
        stmt:bind_value(7, now)
        stmt:bind_value(8, now)
        stmt:exec()
    end
    stmt:finalize()
    db:exec("COMMIT")
end

print(string.format("Inserting %d clips per sequence...", CLIPS_PER_SEQ))
insert_many_clips("seqA", "tA_v1", CLIPS_PER_SEQ)
insert_many_clips("seqB", "tB_v1", CLIPS_PER_SEQ)
print(string.format("  done (%d total)", CLIPS_PER_SEQ * 2))

-- ── Bootstrap: open both tabs via the strip so their caches are pre-hydrated.
-- timeline_state.init handles seqA wiring; open seqB explicitly afterward.
timeline_state.init("seqA", "proj")
local strip = timeline_state.get_tab_strip()
local tab_a = strip:find_record_tab_by_sequence_id("seqA")
local tab_b = strip:open_record_tab("seqB")
assert(tab_a and tab_b, "both tabs should be open")
assert(#tab_a.cache.clips >= CLIPS_PER_SEQ,
    string.format("tab_a cache should hold ~%d clips (got %d)",
        CLIPS_PER_SEQ, #tab_a.cache.clips))
assert(#tab_b.cache.clips >= CLIPS_PER_SEQ,
    string.format("tab_b cache should hold ~%d clips (got %d)",
        CLIPS_PER_SEQ, #tab_b.cache.clips))

print(string.format("  tab_a.cache.clips = %d", #tab_a.cache.clips))
print(string.format("  tab_b.cache.clips = %d", #tab_b.cache.clips))

-- Warm-up: one round-trip through both paths so any first-call effects don't
-- dominate sample #1.
strip:switch_active_record(tab_b)
strip:switch_active_record(tab_a)
timeline_state.switch_to_record_tab("seqB")
timeline_state.switch_to_record_tab("seqA")

-- ── Bench 1: raw strip pointer swap ───────────────────────────────────────
local N_STRIP = 10000
local t0 = os.clock()
for i = 1, N_STRIP do
    if i % 2 == 1 then strip:switch_active_record(tab_b)
    else strip:switch_active_record(tab_a) end
end
local elapsed_strip = os.clock() - t0
local per_strip_us = (elapsed_strip / N_STRIP) * 1e6

-- Restore to seqA before the next bench.
if strip:get_active_record() ~= tab_a then
    strip:switch_active_record(tab_a)
end

-- ── Bench 2: full timeline_state.switch_to_record_tab path ────────────────
-- Includes load_displayed_sequence (DB reload of tracks + clips + gap recompute)
-- and the displayed_tab_changed signal fan-out.
local N_FULL = 200
t0 = os.clock()
for i = 1, N_FULL do
    if i % 2 == 1 then timeline_state.switch_to_record_tab("seqB")
    else timeline_state.switch_to_record_tab("seqA") end
end
local elapsed_full = os.clock() - t0
local per_full_us = (elapsed_full / N_FULL) * 1e6

print("")
print("=== Results ===")
print(string.format("  Strip pointer swap (strip:switch_active_record):"))
print(string.format("    %d switches in %.3fs", N_STRIP, elapsed_strip))
print(string.format("    %.2f µs/switch", per_strip_us))
print(string.format("    sub-millisecond? %s",
    per_strip_us < 1000 and "YES" or "NO"))
print("")
print(string.format("  Full path (timeline_state.switch_to_record_tab):"))
print(string.format("    %d switches in %.3fs", N_FULL, elapsed_full))
print(string.format("    %.2f µs/switch  (%.2f ms)",
    per_full_us, per_full_us / 1000))
print(string.format("    sub-millisecond? %s",
    per_full_us < 1000 and "YES" or "NO"))

print("")
print("(no assertion — Phase 1.5 deliverable is the numbers themselves)")

database.shutdown()
os.remove(DB)

print("\n✅ test_timeline_tab_switch_perf.lua passed")
