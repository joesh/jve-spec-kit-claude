#!/usr/bin/env luajit

-- Spec 022 Phase 1.3b — facade read accessors delegate to the displayed
-- tab's cache (not data.state directly). Proves the contract by mutating
-- displayed_tab.cache directly (bypassing data.state) and confirming the
-- facade reflects the tab cache, not the stale data.state.
--
-- Also pins get_sequence_id to the strip's active record tab (the edit
-- target), independent of which tab is displayed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

print("=== test_timeline_state_reads_from_displayed_tab.lua ===")

local DB = "/tmp/jve/test_timeline_state_reads_from_displayed_tab.db"
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
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('seqA', 'proj', 'A', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 2000, %d, %d),
           ('seqB', 'proj', 'B', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 2000, %d, %d)
]], now, now, now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name, muted)
    VALUES ('tA', 'seqA', 'VIDEO', 1, 'V1', 0),
           ('tB', 'seqB', 'VIDEO', 1, 'V1', 0)
]])

timeline_state.init("seqA", "proj")
local strip = timeline_state.get_tab_strip()
local tabA = strip:find_record_tab_by_sequence_id("seqA")

-- ── get_all_tracks reads from displayed tab ──────────────────────────────
local facade_tracks = timeline_state.get_all_tracks()
assert(facade_tracks and #facade_tracks > 0,
    "facade get_all_tracks returns the displayed tab's tracks (got empty)")
assert(facade_tracks == tabA.cache.tracks, string.format(
    "facade get_all_tracks must return THE SAME table reference as "
    .. "displayed_tab.cache.tracks (got %s vs %s)",
    tostring(facade_tracks), tostring(tabA.cache.tracks)))
print("✓ get_all_tracks returns displayed tab cache.tracks")

-- ── get_clips reads from displayed tab ───────────────────────────────────
-- Inject a synthetic clip into the displayed tab's cache directly (bypassing
-- data.state) and confirm the facade returns it. If facade still read from
-- data.state, this clip would be invisible.
local synthetic = {
    id = "synth-clip-1", track_id = "tA",
    sequence_start = 100, duration = 50,
    source_in = 0, source_out = 50,
}
table.insert(tabA.cache.clips, synthetic)
tabA:invalidate_indexes()

local facade_clips = timeline_state.get_clips()
local found = false
for _, c in ipairs(facade_clips) do
    if c.id == "synth-clip-1" then found = true; break end
end
assert(found, string.format(
    "facade get_clips must return displayed tab's cache.clips (synthetic "
    .. "clip injected into tab cache not visible; got %d clips)",
    #facade_clips))
print("✓ get_clips returns displayed tab cache.clips")

-- ── get_track_clip_index reads from displayed tab ────────────────────────
local idx = timeline_state.get_track_clip_index("tA")
assert(idx, "facade get_track_clip_index returns the tab's per-track index")
local found_synth_in_index = false
for _, c in ipairs(idx) do
    if c.id == "synth-clip-1" then found_synth_in_index = true; break end
end
assert(found_synth_in_index,
    "facade get_track_clip_index reflects tab cache mutations")
print("✓ get_track_clip_index reflects displayed tab cache")

-- ── get_sequence_id returns active record (not displayed) ────────────────
-- Open a source tab and switch displayed to it. Active record stays seqA;
-- displayed becomes the source master. get_sequence_id must still return
-- seqA (the edit target), NOT the displayed source master.
local ok = db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('master1', 'proj', 'M1', 'master', 24, 1, NULL, 1920, 1080,
        0, 0, 2000, %d, %d)
]], now, now))
assert(ok, "master1 INSERT failed: " .. tostring(db:last_error()))
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name, muted)
    VALUES ('tM', 'master1', 'VIDEO', 1, 'V1', 0)
]])

local source_tab = strip:open_source_tab("master1")
strip:switch_displayed(source_tab)

assert(timeline_state.get_sequence_id() == "seqA", string.format(
    "get_sequence_id must return ACTIVE record (seqA) even when displayed "
    .. "is the source master; got %s",
    tostring(timeline_state.get_sequence_id())))
print("✓ get_sequence_id returns active record, not displayed master")

-- After display swap, facade clip/track reads must follow the displayed
-- tab — they now point at the source master's cache.
local source_tracks = timeline_state.get_all_tracks()
assert(source_tracks == source_tab.cache.tracks,
    "facade get_all_tracks now returns source tab cache.tracks after display swap")
print("✓ get_all_tracks follows display swap to source tab")

print("✅ test_timeline_state_reads_from_displayed_tab.lua passed")
