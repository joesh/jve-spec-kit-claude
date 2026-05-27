#!/usr/bin/env luajit

-- Spec 022 Phase 1.3a-ii — THE BUG FIX.
--
-- timeline_state.apply_mutations(target_seq, mutations, callback) now
-- routes writes through the target tab's per-tab cache (instead of
-- silently aiming them at data.state, which holds only the DISPLAYED
-- sequence's clips).
--
-- Before this fix: BRE bulk_shift targeting a record sequence while the
-- source tab is displayed crashed at the "affected zero clips" assert in
-- clip_state — because data.state held the source's clips, not the
-- record's, so the track lookup found nothing on the record's track.
--
-- After this fix: writes to a non-displayed target tab land in that
-- tab's cache and leave data.state (the displayed view) alone. The
-- displayed view doesn't change because nothing about the displayed
-- sequence changed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

print("=== test_timeline_state_routes_to_target_tab.lua ===")

local DB = "/tmp/jve/test_timeline_state_routes_to_target_tab.db"
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
    INSERT INTO tracks (id, sequence_id, track_type, track_index, name)
    VALUES ('vA1', 'seqA', 'VIDEO', 1, 'V1'),
           ('vB1', 'seqB', 'VIDEO', 1, 'V1')
]])
db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, name,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        fps_mismatch_policy, volume, playhead_frame, enabled,
        created_at, modified_at)
    VALUES ('a1', 'proj', 'seqA', 'seqA', 'vA1', 'A1', 0, 200, 0, 200, 'resample', 1.0, 0, 1, %d, %d),
           ('a2', 'proj', 'seqA', 'seqA', 'vA1', 'A2', 500, 100, 0, 100, 'resample', 1.0, 0, 1, %d, %d),
           ('b1', 'proj', 'seqB', 'seqB', 'vB1', 'B1', 0, 300, 0, 300, 'resample', 1.0, 0, 1, %d, %d),
           ('b2', 'proj', 'seqB', 'seqB', 'vB1', 'B2', 600, 200, 0, 200, 'resample', 1.0, 0, 1, %d, %d)
]], now, now, now, now, now, now, now, now))

-- Bring seqA up as active+displayed via the canonical path (M.init drives
-- core.init which loads data.state). Then open seqB as a second record
-- tab — it stays open but not displayed.
timeline_state.init("seqA", "proj")
local strip = timeline_state.get_tab_strip()
local tabA = strip:find_record_tab_by_sequence_id("seqA")
local tabB = strip:open_record_tab("seqB")
assert(tabA and strip:get_displayed() == tabA, "fixture: seqA is displayed")
assert(strip:get_active_record() == tabA, "fixture: seqA is active")

-- Capture the seqA tab's a2 sequence_start so we can prove it doesn't
-- move when we write to seqB.
local a2_before = tabA:get_clip_by_id("a2").sequence_start
assert(a2_before == 500, "fixture: a2 starts at 500")

-- ── BUG-FIX SCENARIO ──────────────────────────────────────────────────────
-- Apply a bulk_shift to seqB (NOT displayed). Before the fix this hit
-- the global clip_state which is built from seqA's clips — track vB1
-- isn't there, so the assert "affected zero clips" fires. After the
-- fix the write is routed to seqB's tab cache where vB1 DOES exist.
local applied_ok, applied_err = pcall(function()
    timeline_state.apply_mutations("seqB", {
        sequence_id = "seqB",
        bulk_shifts = {
            { track_id = "vB1", start_frame = 600, shift_frames = 100 },
        },
    })
end)
assert(applied_ok,
    "BUG-FIX: apply_mutations to non-displayed seqB must NOT crash "
    .. "(was: 'affected zero clips' assert from the wrong-cache lookup). "
    .. "Got: " .. tostring(applied_err))
print("✓ apply_mutations to non-displayed target does not crash")

-- seqB's tab cache reflects the bulk_shift.
local b2_after = tabB:get_clip_by_id("b2").sequence_start
assert(b2_after == 700, string.format(
    "seqB tab cache updated: b2 shifted from 600 to 700 (got %s)",
    tostring(b2_after)))
print("✓ target tab cache reflects the mutation")

-- seqA's tab cache UNTOUCHED — different sequence.
assert(tabA:get_clip_by_id("a2").sequence_start == 500,
    "seqA tab cache untouched by seqB-targeted mutation")
print("✓ non-target tab caches untouched")

-- ── DISPLAYED-TAB PATH (legacy mirror to data.state) ─────────────────────
-- Apply a bulk_shift to seqA (which IS displayed). This must update
-- both seqA's tab cache AND data.state.clips (the legacy read-side that
-- the renderer still uses until 1.3b lands).
timeline_state.apply_mutations("seqA", {
    sequence_id = "seqA",
    bulk_shifts = {
        { track_id = "vA1", start_frame = 500, shift_frames = 250 },
    },
})
assert(tabA:get_clip_by_id("a2").sequence_start == 750,
    "displayed seqA tab cache updated by mutation")
-- data.state should also reflect (legacy mirror).
local all_clips = timeline_state.get_tab_strip():displayed_clips()
local found_a2_in_state = false
for _, c in ipairs(all_clips) do
    if c.id == "a2" then
        assert(c.sequence_start == 750,
            string.format("data.state has a2 at 750 (got %s)", tostring(c.sequence_start)))
        found_a2_in_state = true
        break
    end
end
assert(found_a2_in_state, "data.state.clips still has a2 (displayed=seqA)")
print("✓ displayed-tab mutation mirrored to data.state (legacy reader compat)")

print("✅ test_timeline_state_routes_to_target_tab.lua passed")
