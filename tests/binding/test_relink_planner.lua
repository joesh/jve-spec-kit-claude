#!/usr/bin/env luajit

-- Relink planner regression tests.
--
-- The planner translates per-media relink results from media_relinker
-- into per-clip RelinkClips arguments. Two callers exist: show_relink_dialog
-- (production UI) and the test_e2e_retime_relink binding test. These
-- tests exercise the shared planner against scenarios the test-only
-- planner historically got wrong — specifically, path-collision with
-- existing DB rows that SQLite UNIQUE-constraints against.
--
-- Scenarios:
--   1. Normal entry collides with existing DB media at target path
--      → plan must reassign clips via priority_losers, NOT add the
--        colliding media to media_path_changes.
--   2. Split entry collides with existing DB media at target path
--      → plan must reassign split_clip_ids to the existing owner,
--        NOT register a clone media record at the target path.
--   3. Two media claim the same target — folder-priority tiebreak
--      → higher-priority media wins media_path_changes; loser's
--        clips get reassigned.
--   4. Failed entry with sibling row on disk
--      → salvage_via_dedupe reassigns clips to the sibling.

require('test_env')

local database = require("core.database")
local Media = require("models.media")
local relink_planner = require("core.relink_planner")

-- Lightweight assertion helpers.
local pass_count = 0
local function expect(label, cond, detail)
    if not cond then
        io.stderr:write(string.format("FAIL: %s\n  detail: %s\n", label, tostring(detail)))
        os.exit(1)
    end
    pass_count = pass_count + 1
end

local function expect_eq(label, actual, expected)
    expect(label, actual == expected,
        string.format("expected=%s got=%s", tostring(expected), tostring(actual)))
end

-- Fresh DB per scenario: each scenario sets its own initial state.
local function reset_db(path)
    os.remove(path)
    os.remove(path .. "-shm")
    os.remove(path .. "-wal")
    database.init(path)
    local db = database.get_connection()
    local schema_sql = require('import_schema')
    expect("schema creation", db:exec(schema_sql), "schema exec")
    return db
end

local function bootstrap_project(db, project_id, sequence_id)
    local ok = db:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('%s', 'Planner Test', strftime('%%s','now'), strftime('%%s','now'));
    ]], project_id))
    expect("project row", ok, "project insert")

    ok = db:exec(string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
        VALUES ('%s', '%s', 'Seq', 'timeline', 25, 1, 48000, 1920, 1080, strftime('%%s','now'), strftime('%%s','now'));
    ]], sequence_id, project_id))
    expect("sequence row", ok, "sequence insert")
end

local function make_media(project_id, id, file_path, name)
    local media = Media.create({
        id = id,
        project_id = project_id,
        file_path = file_path,
        name = name,
        duration_frames = 1000,
        fps_numerator = 25,
        fps_denominator = 1,
        audio_sample_rate = 48000,
        audio_channels = 2,
        width = 1920,
        height = 1080,
        metadata = "{}",
    })
    expect("media:save " .. id, media:save(), "save returned false")
    return media
end

local function make_track(db, project_id, sequence_id, track_id, track_type)
    local ok = db:exec(string.format([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('%s', '%s', 'T1', '%s', 1);
    ]], track_id, sequence_id, track_type))
    expect("track row", ok, "track insert")
end

-- The planner only reads clips via Clip.find_clips_for_media (raw SQL on
-- clips.media_id), so we insert rows directly and bypass Clip.create's
-- master_clip_id / TC-origin requirements. The test's purpose is planner
-- state shape, not clip-creation invariants.
-- Counter for non-overlapping placements per-track (DB enforces no overlap).
local _clip_placement = setmetatable({}, { __index = function() return 0 end })
local function make_clip(db, project_id, sequence_id, track_id, clip_id, media_id)
    local slot = _clip_placement[track_id]
    _clip_placement[track_id] = slot + 1
    local start = slot * 200
    local ok, err = db:exec(string.format([[
        INSERT INTO clips (id, project_id, clip_kind, owner_sequence_id, track_id, media_id,
                           name, timeline_start_frame, duration_frames,
                           source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, created_at, modified_at)
        VALUES ('%s', '%s', 'timeline', '%s', '%s', '%s',
                'c_%s', %d, 100, 0, 100, 25, 1,
                strftime('%%s','now'), strftime('%%s','now'));
    ]], clip_id, project_id, sequence_id, track_id, media_id, clip_id:sub(1, 6), start))
    expect("clip row " .. clip_id, ok, tostring(err))
    return { id = clip_id }
end

-- =========================================================================
-- Scenario 1: normal entry collides with existing DB media
-- =========================================================================
print("=== Scenario 1: normal-entry DB path collision ===")
do
    local DB = "/tmp/jve/test_relink_planner_s1.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p1", "s1", "t1"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local TARGET = "/fixtures/target.mov"
    make_media(pid, "media_A", "/old/a.mov", "shared.mov")
    make_media(pid, "media_B", TARGET,       "shared.mov")
    make_media(pid, "media_C", "/old/c.mov", "other.mov")

    local clip_a = make_clip(db, pid, sid, tid, "clip_A1", "media_A")
    make_clip(db, pid, sid, tid, "clip_B1", "media_B")
    make_clip(db, pid, sid, tid, "clip_C1", "media_C")

    local plan = relink_planner.build_plan(db, {
        { media_id = "media_A", new_path = TARGET, needs_split = false },
    }, {}, { "/fixtures" }, pid)

    expect_eq("A must not appear in media_path_changes (would collide)",
        plan.media_path_changes["media_A"], nil)
    expect("clip on A must reassign to B",
        plan.clip_relink_map[clip_a.id] ~= nil, "clip_A1 missing from clip_relink_map")
    expect_eq("clip reassignment target",
        plan.clip_relink_map[clip_a.id].new_media_id, "media_B")
    expect_eq("no clones registered",
        #plan.new_media_records, 0)
end

-- =========================================================================
-- Scenario 2: split entry collides with existing DB media
-- =========================================================================
print("=== Scenario 2: split-entry DB path collision ===")
do
    local DB = "/tmp/jve/test_relink_planner_s2.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p2", "s2", "t2"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local TARGET = "/fixtures/trimmed.mov"
    make_media(pid, "media_A", "/old/a.mov", "clip.mov")
    make_media(pid, "media_B", TARGET,       "clip.mov")

    local split_clip_1 = make_clip(db, pid, sid, tid, "clip_A1", "media_A")
    local split_clip_2 = make_clip(db, pid, sid, tid, "clip_A2", "media_A")

    local plan = relink_planner.build_plan(db, {
        {
            media_id = "media_A",
            new_path = TARGET,
            needs_split = true,
            split_clip_ids = { split_clip_1.id, split_clip_2.id },
        },
    }, {}, { "/fixtures" }, pid)

    expect_eq("no clone registered at colliding path",
        #plan.new_media_records, 0)
    expect_eq("split_clip_1 reassigned to existing owner",
        plan.clip_relink_map[split_clip_1.id] and plan.clip_relink_map[split_clip_1.id].new_media_id,
        "media_B")
    expect_eq("split_clip_2 reassigned to existing owner",
        plan.clip_relink_map[split_clip_2.id] and plan.clip_relink_map[split_clip_2.id].new_media_id,
        "media_B")
    expect_eq("A not in media_path_changes",
        plan.media_path_changes["media_A"], nil)
end

-- =========================================================================
-- Scenario 3: two media claim same target — folder-priority tiebreak
-- =========================================================================
print("=== Scenario 3: folder-priority tiebreak ===")
do
    local DB = "/tmp/jve/test_relink_planner_s3.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p3", "s3", "t3"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local TARGET = "/fixtures/winner.mov"
    -- A lives in HIGH priority folder, B lives in LOW priority folder.
    -- Both relinked entries claim TARGET.
    make_media(pid, "media_A", "/high/a.mov", "dup.mov")
    make_media(pid, "media_B", "/low/b.mov",  "dup.mov")

    local clip_a = make_clip(db, pid, sid, tid, "clip_A1", "media_A")
    local clip_b = make_clip(db, pid, sid, tid, "clip_B1", "media_B")

    local plan = relink_planner.build_plan(db, {
        { media_id = "media_A", new_path = TARGET, needs_split = false },
        { media_id = "media_B", new_path = TARGET, needs_split = false },
    }, {}, { "/high", "/low" }, pid)

    -- Domain: /high is priority index 1 (best), /low is 2. A wins.
    expect_eq("winner gets media_path_changes",
        plan.media_path_changes["media_A"], TARGET)
    expect_eq("loser not in media_path_changes",
        plan.media_path_changes["media_B"], nil)
    -- B's clips should reassign to the winner (A).
    expect_eq("loser's clips reassigned to winner",
        plan.clip_relink_map[clip_b.id] and plan.clip_relink_map[clip_b.id].new_media_id,
        "media_A")
    -- Winner's own clips don't need reassignment (they already point to A).
    expect_eq("winner's clips untouched",
        plan.clip_relink_map[clip_a.id], nil)
end

-- =========================================================================
-- Scenario 4: failed entry with sibling row on disk → salvage
-- =========================================================================
print("=== Scenario 4: dedupe salvage via on-disk sibling ===")
do
    local DB = "/tmp/jve/test_relink_planner_s4.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p4", "s4", "t4"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    -- Sibling lives at a real on-disk path (create a tiny file).
    local SIBLING = "/tmp/jve/sibling_dedupe.mov"
    os.remove(SIBLING)
    local f = io.open(SIBLING, "w"); f:write("x"); f:close()

    -- A failed (relinker couldn't find it), but B has the same name and
    -- an on-disk file → A's clips should salvage to B.
    make_media(pid, "media_A", "/missing/a.mov", "take01.mov")
    make_media(pid, "media_B", SIBLING,          "take01.mov")

    local clip_a = make_clip(db, pid, sid, tid, "clip_A1", "media_A")

    local plan = relink_planner.build_plan(db, {}, {
        { media_id = "media_A" },
    }, { "/fixtures" }, pid)

    expect_eq("salvaged count reported",
        plan.salvaged_count, 1)
    expect_eq("failed media's clip salvaged to sibling",
        plan.clip_relink_map[clip_a.id] and plan.clip_relink_map[clip_a.id].new_media_id,
        "media_B")

    os.remove(SIBLING)
end

-- =========================================================================
-- Scenario 5: priority-loser reassignment must NOT overwrite split assignments
-- =========================================================================
-- Edge case: when the same media_id appears as both a split source AND a
-- priority loser (two entries in relinked[]), reassign_priority_losers
-- loads ALL clips for that media and would — without a guard — overwrite
-- the split's clone assignment. Symmetric to salvage_via_dedupe's
-- `if not state.clip_relink_map[clip.id]` guard.
print("=== Scenario 5: priority-loser must not clobber split assignments ===")
do
    local DB = "/tmp/jve/test_relink_planner_s5.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p5", "s5", "t5"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local T1 = "/fixtures/trim.mov"   -- split clone target
    local T2 = "/fixtures/full.mov"   -- normal entry target

    -- Y has two clips: c1 (fits the trimmed file) and c2 (doesn't).
    -- Z has one clip c3; Z is in a higher-priority folder so it wins T2
    -- against Y, making Y a priority_loser.
    make_media(pid, "media_Y", "/low/y.mov",  "y.mov")
    make_media(pid, "media_Z", "/high/z.mov", "z.mov")

    local clip_c1 = make_clip(db, pid, sid, tid, "clip_c1", "media_Y")
    make_clip(db, pid, sid, tid, "clip_c2", "media_Y")
    make_clip(db, pid, sid, tid, "clip_c3", "media_Z")

    -- Entry order matters: Z must claim T2 BEFORE Y's normal entry arrives,
    -- so Y becomes a priority_loser (not vice-versa). This forces
    -- reassign_priority_losers to load ALL clips on Y, including c1.
    local plan = relink_planner.build_plan(db, {
        -- Z claims T2 first.
        { media_id = "media_Z", new_path = T2, needs_split = false },
        -- Split: c1 on Y fits the trimmed file T1 → clone assignment.
        { media_id = "media_Y", new_path = T1, needs_split = true,
          split_clip_ids = { clip_c1.id } },
        -- Y arrives at T2 after Z → becomes priority_loser to Z.
        { media_id = "media_Y", new_path = T2, needs_split = false },
    }, {}, { "/high", "/low" }, pid)

    -- c1's split-clone assignment MUST survive the priority-loser reassignment.
    expect("c1 stays assigned",
        plan.clip_relink_map[clip_c1.id] ~= nil, "c1 missing from clip_relink_map")
    local c1_target = plan.clip_relink_map[clip_c1.id].new_media_id
    expect("c1 points at a clone (not Z)",
        c1_target ~= "media_Z",
        "expected split clone, got " .. tostring(c1_target)
        .. " — priority-loser reassignment overwrote split assignment")
    -- Clone IDs are generated with "media_" prefix by the planner.
    expect("c1 target is a clone id",
        type(c1_target) == "string" and c1_target:sub(1, 6) == "media_",
        "unexpected c1 target: " .. tostring(c1_target))
end

-- =========================================================================
-- Scenario 6: folder-priority beats entry order
-- =========================================================================
-- Two media compete for the same target path. The higher-priority folder
-- MUST win regardless of which entry appears first in the relinked array.
-- Earlier versions of the planner short-circuited on any prior session
-- claim, making priority_losers assignment effectively first-writer-wins —
-- so this scenario would fail with B (low-priority, but first in array)
-- stealing the path from A.
print("=== Scenario 6: folder-priority beats entry order ===")
do
    local DB = "/tmp/jve/test_relink_planner_s6.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p6", "s6", "t6"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local TARGET = "/fixtures/winner.mov"
    -- A in HIGH-priority folder, B in LOW-priority folder.
    make_media(pid, "media_A", "/high/a.mov", "dup.mov")
    make_media(pid, "media_B", "/low/b.mov",  "dup.mov")

    local clip_a = make_clip(db, pid, sid, tid, "clip_A1", "media_A")
    local clip_b = make_clip(db, pid, sid, tid, "clip_B1", "media_B")

    -- Deliberately put B first in the array. A (higher priority folder)
    -- must still win the path.
    local plan = relink_planner.build_plan(db, {
        { media_id = "media_B", new_path = TARGET, needs_split = false },
        { media_id = "media_A", new_path = TARGET, needs_split = false },
    }, {}, { "/high", "/low" }, pid)

    expect_eq("higher-priority folder wins regardless of entry order",
        plan.media_path_changes["media_A"], TARGET)
    expect_eq("lower-priority media excluded from media_path_changes",
        plan.media_path_changes["media_B"], nil)
    -- B's clip reassigns to A (the winner).
    expect_eq("loser's clip reassigned to priority winner",
        plan.clip_relink_map[clip_b.id] and plan.clip_relink_map[clip_b.id].new_media_id,
        "media_A")
    expect_eq("winner's clip untouched",
        plan.clip_relink_map[clip_a.id], nil)
end

-- =========================================================================
-- Scenario 7: transitive displacement cascade
-- =========================================================================
-- Three media compete for the same target; displacements form a chain
-- A→B→C. All clips from all three must ultimately land on C, regardless
-- of which order reassign_priority_losers walks the chain.
-- Pre-fix: A's clips land on B (one hop), B→C chain not followed, so
-- A's clips end up orphaned on B (which isn't getting a path change).
print("=== Scenario 7: transitive displacement cascade (A→B→C) ===")
do
    local DB = "/tmp/jve/test_relink_planner_s7.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p7", "s7", "t7"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local TARGET = "/fixtures/shared.mov"
    -- A in pri-3 folder, B in pri-2, C in pri-1 (lowest index = highest).
    make_media(pid, "media_A", "/low/a.mov",  "shared.mov")
    make_media(pid, "media_B", "/mid/b.mov",  "shared.mov")
    make_media(pid, "media_C", "/high/c.mov", "shared.mov")

    local clip_a = make_clip(db, pid, sid, tid, "clip_A1", "media_A")
    local clip_b = make_clip(db, pid, sid, tid, "clip_B1", "media_B")
    local clip_c = make_clip(db, pid, sid, tid, "clip_C1", "media_C")

    local plan = relink_planner.build_plan(db, {
        { media_id = "media_A", new_path = TARGET, needs_split = false },
        { media_id = "media_B", new_path = TARGET, needs_split = false },
        { media_id = "media_C", new_path = TARGET, needs_split = false },
    }, {}, { "/high", "/mid", "/low" }, pid)

    expect_eq("C (terminal winner) gets media_path_changes",
        plan.media_path_changes["media_C"], TARGET)
    expect_eq("B not in media_path_changes",
        plan.media_path_changes["media_B"], nil)
    expect_eq("A not in media_path_changes",
        plan.media_path_changes["media_A"], nil)
    -- A's clip must transitively land on C, not stop at B.
    expect_eq("A's clip reassigned to terminal winner C",
        plan.clip_relink_map[clip_a.id] and plan.clip_relink_map[clip_a.id].new_media_id,
        "media_C")
    -- B's clip lands on C (direct).
    expect_eq("B's clip reassigned to C",
        plan.clip_relink_map[clip_b.id] and plan.clip_relink_map[clip_b.id].new_media_id,
        "media_C")
    -- C is the winner — own clips untouched.
    expect_eq("C's own clip untouched",
        plan.clip_relink_map[clip_c.id], nil)
end

-- =========================================================================
-- Scenario 8: split reassignment survives subsequent displacement
-- =========================================================================
-- A normal entry claims TARGET first. A split entry then arrives for
-- TARGET and reassigns its clip to A (the session owner). Finally a
-- higher-priority entry C displaces A. The split's clip must follow A's
-- chain to C — not orphan at A (whose file_path is no longer being
-- updated).
-- Pre-fix: split's clip stays pointing at A in clip_relink_map; A's path
-- change was revoked by the displacement, so the split's clip ends up on
-- a media whose file_path isn't being relinked.
print("=== Scenario 8: split clip follows chain after displacement ===")
do
    local DB = "/tmp/jve/test_relink_planner_s8.db"
    local db = reset_db(DB)
    local pid, sid, tid = "p8", "s8", "t8"
    bootstrap_project(db, pid, sid)
    make_track(db, pid, sid, tid, "VIDEO")

    local TARGET = "/fixtures/contested.mov"
    make_media(pid, "media_A", "/low/a.mov",   "contested.mov")
    make_media(pid, "media_Y", "/mid/y.mov",   "y.mov")
    make_media(pid, "media_C", "/high/c.mov",  "contested.mov")

    make_clip(db, pid, sid, tid, "clip_A1", "media_A")
    local split_clip = make_clip(db, pid, sid, tid, "clip_Y_split", "media_Y")
    make_clip(db, pid, sid, tid, "clip_C1", "media_C")

    -- Order: A first (claims TARGET), Y split (reassigns to A), C last (displaces A).
    local plan = relink_planner.build_plan(db, {
        { media_id = "media_A", new_path = TARGET, needs_split = false },
        { media_id = "media_Y", new_path = TARGET, needs_split = true,
          split_clip_ids = { split_clip.id } },
        { media_id = "media_C", new_path = TARGET, needs_split = false },
    }, {}, { "/high", "/mid", "/low" }, pid)

    expect_eq("C (highest priority) wins TARGET",
        plan.media_path_changes["media_C"], TARGET)
    -- No clone should have been registered — split was reassigned to existing
    -- owner A, not cloned.
    expect_eq("no clone registered",
        #plan.new_media_records, 0)
    -- The split's clip must follow the chain: was assigned to A, A lost to C,
    -- so the clip ends up on C.
    expect_eq("split clip follows chain to terminal winner",
        plan.clip_relink_map[split_clip.id] and plan.clip_relink_map[split_clip.id].new_media_id,
        "media_C")
end

-- =========================================================================
-- Scenario 9: build_plan arg validation + salvage bad-input assert
-- =========================================================================
-- Rule 2.32: assert-based failure paths must be tested via pcall with
-- actionable error messages.
print("=== Scenario 9: input validation asserts ===")
do
    local DB = "/tmp/jve/test_relink_planner_s9.db"
    local db = reset_db(DB)
    bootstrap_project(db, "p9", "s9")

    local function assert_pcall_fails(label, fn, expected_needle)
        local ok, err = pcall(fn)
        expect(label .. ": must fail", not ok, "unexpected success")
        expect(label .. ": message mentions " .. expected_needle,
            tostring(err):find(expected_needle, 1, true) ~= nil,
            "got: " .. tostring(err))
    end

    assert_pcall_fails("nil db",
        function() relink_planner.build_plan(nil, {}, {}, {}, "p9") end,
        "db required")
    assert_pcall_fails("non-table relinked",
        function() relink_planner.build_plan(db, "bad", {}, {}, "p9") end,
        "relinked must be array")
    assert_pcall_fails("non-table failed",
        function() relink_planner.build_plan(db, {}, "bad", {}, "p9") end,
        "failed must be array")
    assert_pcall_fails("non-table folder_priority",
        function() relink_planner.build_plan(db, {}, {}, "bad", "p9") end,
        "folder_priority must be array")
    assert_pcall_fails("missing project_id",
        function() relink_planner.build_plan(db, {}, {}, {}, nil) end,
        "project_id required")
    assert_pcall_fails("empty project_id",
        function() relink_planner.build_plan(db, {}, {}, {}, "") end,
        "project_id required")

    -- Failed entry without media_id must assert.
    assert_pcall_fails("failed entry without media_id",
        function()
            relink_planner.build_plan(db, {}, { { } }, {}, "p9")
        end,
        "failed entry missing media_id")
end

print(string.format("✅ test_relink_planner.lua passed (%d assertions)", pass_count))
