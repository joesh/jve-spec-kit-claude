#!/usr/bin/env luajit

-- Spec 022 Phase 1.3a-i — per-tab clip indexes (empty plumbing).
--
-- Each TimelineTab.cache now carries its own clip indexes parallel to the
-- module-level indexes in `clip_state.lua`: clip_lookup (id → clip),
-- track_clip_index (track_id → sorted clip list), clip_track_positions
-- (id → {list, index}). Indexes are lazily rebuilt from cache.clips
-- after load_from_database or any mutation that marks them dirty.
--
-- Phase 1.3a-ii will route apply_mutations through these per-tab indexes
-- so writes to a non-displayed active tab no longer hit the wrong cache
-- (the BRE silent-no-op / cross-tab-edit bug). This phase is empty
-- plumbing: the indexes exist and rebuild correctly, but nothing in the
-- write path uses them yet.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTab = require("ui.timeline.timeline_tab")

print("=== test_timeline_tab_indexes.lua ===")

local DB = "/tmp/jve/test_timeline_tab_indexes.db"
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
        0, 0, 2000, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name)
    VALUES ('v1', 'seqA', 'VIDEO', 1, 'V1'),
           ('v2', 'seqA', 'VIDEO', 2, 'V2')
]])
-- Three clips on V1 placed OUT OF ORDER in INSERT to verify sort by
-- sequence_start; one clip on V2 to verify per-track partitioning.
db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, name,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        fps_mismatch_policy, volume, playhead_frame, enabled,
        created_at, modified_at)
    VALUES ('c_mid',   'proj', 'seqA', 'seqA', 'v1', 'mid',
                500, 100, 0, 100, 'resample', 1.0, 0, 1, %d, %d),
           ('c_first', 'proj', 'seqA', 'seqA', 'v1', 'first',
                0, 200, 0, 200, 'resample', 1.0, 0, 1, %d, %d),
           ('c_last',  'proj', 'seqA', 'seqA', 'v1', 'last',
                1000, 50, 0, 50, 'resample', 1.0, 0, 1, %d, %d),
           ('c_v2',    'proj', 'seqA', 'seqA', 'v2', 'on V2',
                300, 100, 0, 100, 'resample', 1.0, 0, 1, %d, %d)
]], now, now, now, now, now, now, now, now))

local tab = TimelineTab.new("record", "seqA")
tab:load_from_database()

-- ── 1. cache index fields exist + start unbuilt-but-rebuildable ───────────
-- The presence of clip_lookup as a table (vs nil) is the marker that the
-- cache schema includes indexes; the dirty flag drives lazy rebuild.
assert(type(tab.cache.clip_lookup) == "table", "cache.clip_lookup exists")
assert(type(tab.cache.track_clip_index) == "table", "cache.track_clip_index exists")
assert(type(tab.cache.clip_track_positions) == "table",
    "cache.clip_track_positions exists")
print("✓ cache index tables exist")

-- ── 2. id lookup returns the right clip ───────────────────────────────────
local c_first = tab:get_clip_by_id("c_first")
assert(c_first and c_first.id == "c_first",
    string.format("get_clip_by_id returns c_first (got %s)",
        tostring(c_first and c_first.id)))
local c_v2 = tab:get_clip_by_id("c_v2")
assert(c_v2 and c_v2.track_id == "v2", "get_clip_by_id finds clip on v2")

-- Unknown id returns nil, not error (mirrors clip_state.get_by_id).
assert(tab:get_clip_by_id("ghost") == nil, "unknown id returns nil")
assert(tab:get_clip_by_id(nil) == nil, "nil id returns nil")
print("✓ get_clip_by_id")

-- ── 3. per-track sorted index ─────────────────────────────────────────────
local v1_list = tab:get_track_clip_index("v1")
assert(type(v1_list) == "table",
    "get_track_clip_index returns a list for v1")
-- V1 has 3 media clips + however many derived gaps load_from_database produced.
-- Sort by sequence_start: ties broken by id. The media clips alone should
-- appear in order: c_first (0), c_mid (500), c_last (1000), with any gap
-- clips interleaved by their starts.
local media_only = {}
for _, c in ipairs(v1_list) do
    if not c.is_gap then table.insert(media_only, c) end
end
assert(#media_only == 3, string.format("v1 has 3 media clips (got %d)", #media_only))
assert(media_only[1].id == "c_first", "v1 sorted: c_first first")
assert(media_only[2].id == "c_mid",   "v1 sorted: c_mid middle")
assert(media_only[3].id == "c_last",  "v1 sorted: c_last last")

-- V2 has one media clip.
local v2_list = tab:get_track_clip_index("v2")
assert(type(v2_list) == "table", "get_track_clip_index returns a list for v2")
local v2_media = {}
for _, c in ipairs(v2_list) do
    if not c.is_gap then table.insert(v2_media, c) end
end
assert(#v2_media == 1 and v2_media[1].id == "c_v2", "v2 has one media clip c_v2")

-- M3 contract: unknown track_id and nil/empty input must fail loudly with
-- context; known-empty tracks return `{}`, not nil. The old behaviour
-- (silent nil) conflated "track has no clips" with "track doesn't exist."
local ok_unknown, err_unknown = pcall(tab.get_track_clip_index, tab, "nope")
assert(not ok_unknown, "unknown track_id must assert")
assert(tostring(err_unknown):find("unknown track_id"),
    "unknown-track error must name the violation, got: " .. tostring(err_unknown))
local ok_nil = pcall(tab.get_track_clip_index, tab, nil)
assert(not ok_nil, "nil track_id must assert")
local ok_empty = pcall(tab.get_track_clip_index, tab, "")
assert(not ok_empty, "empty-string track_id must assert")
print("✓ get_track_clip_index sorts by sequence_start (M3 contract: assert on unknown/nil)")

-- ── 4. neighbor lookup uses the per-track position cache ─────────────────
local next_after_first = tab:locate_neighbor(c_first, 1)
assert(next_after_first ~= nil,
    "locate_neighbor returns SOMETHING immediately after c_first")
-- The next entry on v1's sorted list could be a gap or c_mid depending on
-- whether load_from_database computed a leading gap. Just verify the
-- ordering invariant: the neighbor's sequence_start >= c_first's.
assert(next_after_first.sequence_start >= c_first.sequence_start,
    "next neighbor's sequence_start >= c_first.sequence_start")

-- Walking off the end returns nil.
local c_last = tab:get_clip_by_id("c_last")
assert(tab:locate_neighbor(c_last, 1) == nil,
    "walking past last clip returns nil")
assert(tab:locate_neighbor(c_first, -1) == nil
       or tab:locate_neighbor(c_first, -1).sequence_start <= c_first.sequence_start,
    "walking before first returns nil or a leading gap")
print("✓ locate_neighbor")

-- ── 5. reloading re-builds indexes ───────────────────────────────────────-
-- Delete a clip from DB and re-load. Indexes must reflect the new shape.
db:exec("DELETE FROM clips WHERE id='c_mid'")
tab:load_from_database()
assert(tab:get_clip_by_id("c_mid") == nil,
    "after reload, c_mid no longer indexed")
local v1_after = tab:get_track_clip_index("v1")
local media_after = {}
for _, c in ipairs(v1_after) do
    if not c.is_gap then table.insert(media_after, c) end
end
assert(#media_after == 2, "after reload, v1 has 2 media clips")
print("✓ load_from_database rebuilds indexes")

print("✅ test_timeline_tab_indexes.lua passed")
