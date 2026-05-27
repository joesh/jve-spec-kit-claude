#!/usr/bin/env luajit

-- Spec 022 Phase 1.3a-ii — tab:apply_mutations operates on the tab's own
-- cache. This is the storage half of the BRE silent-no-op / cross-tab-
-- edit bug fix. The dispatch half (timeline_state.apply_mutations routes
-- by sequence_id) is pinned by test_timeline_state_routes_to_target_tab.lua.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTab = require("ui.timeline.timeline_tab")

print("=== test_timeline_tab_apply_mutations.lua ===")

local DB = "/tmp/jve/test_timeline_tab_apply_mutations.db"
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
    VALUES ('seq', 'proj', 'A', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 2000, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name)
    VALUES ('v1', 'seq', 'VIDEO', 1, 'V1')
]])
db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, name,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        fps_mismatch_policy, volume, playhead_frame, enabled,
        created_at, modified_at)
    VALUES ('c1', 'proj', 'seq', 'seq', 'v1', 'one',
                100, 200, 0, 200, 'resample', 1.0, 0, 1, %d, %d),
           ('c2', 'proj', 'seq', 'seq', 'v1', 'two',
                500, 100, 0, 100, 'resample', 1.0, 0, 1, %d, %d),
           ('c3', 'proj', 'seq', 'seq', 'v1', 'three',
                800, 50,  0, 50,  'resample', 1.0, 0, 1, %d, %d)
]], now, now, now, now, now, now))

local tab = TimelineTab.new("record", "seq")
tab:load_from_database()

-- ── 1. updates: change fields on existing clip ────────────────────────────
local c1_before = tab:get_clip_by_id("c1")
assert(c1_before.duration == 200, "fixture: c1 starts at duration 200")

local changed = tab:apply_mutations({
    sequence_id = "seq",
    updates = {
        { clip_id = "c1", duration_value = 250 },
    },
})
assert(changed, "apply_mutations returns true when something changed")
local c1_after = tab:get_clip_by_id("c1")
assert(c1_after.duration == 250,
    string.format("c1.duration updated to 250 (got %s)", tostring(c1_after.duration)))
print("✓ updates apply to cache.clips + indexes refreshed")

-- ── 2. bulk_shifts: shift downstream clips ────────────────────────────────
-- c2 at 500, c3 at 800. Shift everything at or past frame 500 by +200:
-- c2 → 700, c3 → 1000. c1 (at 100) unaffected.
changed = tab:apply_mutations({
    sequence_id = "seq",
    bulk_shifts = {
        { track_id = "v1", start_frame = 500, shift_frames = 200 },
    },
})
assert(changed, "bulk_shift reports changed")
assert(tab:get_clip_by_id("c2").sequence_start == 700, "c2 shifted to 700")
assert(tab:get_clip_by_id("c3").sequence_start == 1000, "c3 shifted to 1000")
assert(tab:get_clip_by_id("c1").sequence_start == 100, "c1 unaffected (start < 500)")
print("✓ bulk_shifts apply to cache + assert when zero affected")

-- ── 3. bulk_shift with zero match must assert (NSF) ───────────────────────
local ok, err = pcall(function()
    tab:apply_mutations({
        sequence_id = "seq",
        bulk_shifts = {
            { track_id = "ghost_track", start_frame = 0, shift_frames = 50 },
        },
    })
end)
assert(not ok, "bulk_shift on empty track must assert (NSF — no silent drop)")
assert(tostring(err):find("zero clips", 1, true)
       or tostring(err):find("affected", 1, true),
    "assert message must name the zero-match condition; got: " .. tostring(err))
print("✓ bulk_shift on empty track asserts loudly")

-- ── 4. deletes remove clips from cache + lookup ───────────────────────────
changed = tab:apply_mutations({
    sequence_id = "seq",
    deletes = { "c2" },
})
assert(changed, "delete reports changed")
assert(tab:get_clip_by_id("c2") == nil, "c2 removed from lookup")
local v1_after_delete = tab:get_track_clip_index("v1")
local v1_media = {}
for _, c in ipairs(v1_after_delete) do
    if not c.is_gap then table.insert(v1_media, c) end
end
assert(#v1_media == 2, string.format("v1 has 2 media clips after delete (got %d)", #v1_media))
print("✓ deletes remove + reindex")

-- ── 5. inserts add new clip ───────────────────────────────────────────────
changed = tab:apply_mutations({
    sequence_id = "seq",
    inserts = {
        {
            id = "c_new", track_id = "v1", name = "inserted",
            sequence_start = 2000, duration = 100,
            source_in = 0, source_out = 100, enabled = true,
        },
    },
})
assert(changed, "insert reports changed")
local c_new = tab:get_clip_by_id("c_new")
assert(c_new and c_new.sequence_start == 2000,
    "inserted clip findable via lookup at sequence_start 2000")
print("✓ inserts add + reindex")

-- ── 6. no-op mutation returns false ───────────────────────────────────────
assert(tab:apply_mutations({sequence_id = "seq"}) == false,
    "empty mutation reports unchanged")
print("✓ empty mutation reports false")

print("✅ test_timeline_tab_apply_mutations.lua passed")
