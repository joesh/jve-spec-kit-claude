#!/usr/bin/env luajit
--- 019 T002: OverwriteTrimEdge command contract.
---
--- New command (FR-014, FR-015, FR-015b) — peer of RippleTrimEdge. Same
--- SPEC.args shape (clip_id, edge, delta_frames, sequence_id, project_id).
--- Mutates ONE clip row only — never propagates the duration delta to
--- downstream clips. Downstream stays put; a gap appears when shrinking
--- and an overlap-attempt when growing (overlap policy is outside this
--- command's scope).
---
--- Pinned behaviors (NSF Half-1 + Half-2):
---   * Right-edge shrink/grow mutates source_out_frame + duration_frames
---     only; sequence_start_frame unchanged.
---   * Left-edge shrink/grow mutates source_in_frame + duration_frames AND
---     sequence_start_frame (the placement shifts to absorb the trim).
---   * Downstream clips on the same track do NOT move.
---   * Undo restores the four columns bit-for-bit.
---   * Every precondition violation asserts (FR-015): missing clip,
---     edge ∉ {"left","right"}, delta_frames == 0, range outside source
---     content extent.
---   * Output invariant per FR-015b: each scenario reads back via
---     Clip.load and asserts the four columns. Catches partial writes.
---
--- Black-box: asserts only on observable DB state via Clip.load after
--- command_manager.execute_interactive. No internal field inspection.

require("test_env")

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Sequence        = require("models.sequence")
local Clip            = require("models.clip")

local TEST_DB = "/tmp/jve/test_overwrite_trim_edge.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test Project', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq', 'proj', 'Sequence', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 10000, 0, '[]', '[]', '[]', 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
                        enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

command_manager.init("seq", "proj")

print("=== test_overwrite_trim_edge.lua ===")

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Creates a clip rooted in a fresh master sequence wrapping a 1000-frame
-- source. Source_in defaults to 100 (non-trivial — catches code that
-- assumes source_in=0).
local function create_clip(id, start_frame, duration, source_in_frame)
    source_in_frame = source_in_frame or 100
    local media_id = id .. "_media"
    require("test_env").create_test_media({
        id              = media_id,
        project_id      = "proj",
        name            = id .. ".mov",
        file_path       = "/tmp/jve/" .. id .. ".mov",
        duration_frames = 1000,
        fps_numerator   = 24,
        fps_denominator = 1,
        width           = 1920,
        height          = 1080,
    })
    local master_seq_id = Sequence.ensure_master(media_id, "proj")
    local now = os.time()
    local sub_in, sub_out = Clip.subframe_defaults_for(db, "v1")
    Clip.create({
        id                   = id,
        project_id           = "proj",
        owner_sequence_id    = "seq",
        track_id             = "v1",
        sequence_id          = master_seq_id,
        name                 = "Clip " .. id,
        sequence_start_frame = start_frame,
        duration_frames      = duration,
        source_in_frame      = source_in_frame,
        source_out_frame     = source_in_frame + duration,
        source_in_subframe   = sub_in,
        source_out_subframe  = sub_out,
        fps_mismatch_policy  = "resample",
        enabled              = true,
        volume               = 1.0,
        playhead_frame       = 0,
        created_at           = now,
        modified_at          = now,
    })
    timeline_state.reload_clips()
end

-- Read back the four post-mutation columns directly from the DB so output
-- invariants are validated against persisted state, not against the in-memory
-- model that may have been bypassed by a buggy save() (FR-015b).
local function read_clip_columns(clip_id)
    local stmt = db:prepare(
        "SELECT sequence_start_frame, duration_frames, source_in_frame, source_out_frame "
        .. "FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    assert(stmt:next(), "fixture: clip " .. clip_id .. " not found")
    local r = {
        sequence_start_frame = stmt:value(0),
        duration_frames      = stmt:value(1),
        source_in_frame      = stmt:value(2),
        source_out_frame     = stmt:value(3),
    }
    stmt:finalize()
    return r
end

local function reset()
    db:exec("DELETE FROM clips;")
    db:exec("DELETE FROM media;")
    db:exec("DELETE FROM sequences WHERE id != 'seq';")  -- preserve outer timeline; drop master wrappers
    timeline_state.reload_clips()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Right-edge shrink: source_out + duration decrease; start unchanged.
--    Downstream clip stays put.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Right-edge shrink ---")
do
    reset()
    create_clip("A", 100, 200, 50)   -- start=100, dur=200, src_in=50, src_out=250
    create_clip("B", 400, 100, 0)    -- downstream clip at 400; must not move

    local before_A = read_clip_columns("A")
    local before_B = read_clip_columns("B")
    assert(before_A.duration_frames == 200, "fixture: A starts with duration 200")
    assert(before_B.sequence_start_frame == 400, "fixture: B starts at 400")

    -- Shrink A's tail by 50 frames (delta < 0 on right edge).
    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "right",
        delta_frames = -50,
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, string.format("OverwriteTrimEdge must succeed; got %s",
        tostring(r and r.error_message)))

    local after_A = read_clip_columns("A")
    assert(after_A.sequence_start_frame == 100,
        string.format("right-edge trim must NOT move start; got %d (was 100)",
            after_A.sequence_start_frame))
    assert(after_A.duration_frames == 150,
        string.format("duration must decrease by 50 to 150; got %d",
            after_A.duration_frames))
    assert(after_A.source_in_frame == 50,
        string.format("source_in unchanged on right-edge; got %d (was 50)",
            after_A.source_in_frame))
    assert(after_A.source_out_frame == 200,
        string.format("source_out must decrease by 50 to 200; got %d",
            after_A.source_out_frame))

    -- Downstream stays put.
    local after_B = read_clip_columns("B")
    assert(after_B.sequence_start_frame == 400,
        string.format("downstream clip B must NOT move; got %d", after_B.sequence_start_frame))
    assert(after_B.duration_frames == 100, "downstream duration unchanged")
    print("  ✓ right-edge shrink: source_out/duration adjusted; start + downstream unchanged")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Left-edge shrink: source_in increases; start advances; downstream unmoved.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Left-edge shrink ---")
do
    reset()
    create_clip("A", 100, 200, 50)   -- start=100, dur=200, src_in=50
    create_clip("B", 400, 100, 0)

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "left",
        delta_frames = 30,           -- shrink left edge by 30 frames
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, "left-edge shrink must succeed")

    local after_A = read_clip_columns("A")
    assert(after_A.sequence_start_frame == 130,
        string.format("left-edge shrink moves start later by delta; got %d (expected 130)",
            after_A.sequence_start_frame))
    assert(after_A.source_in_frame == 80,
        string.format("source_in must advance by 30 to 80; got %d", after_A.source_in_frame))
    assert(after_A.source_out_frame == 250,
        string.format("source_out unchanged on left-edge; got %d (was 250)",
            after_A.source_out_frame))
    assert(after_A.duration_frames == 170,
        string.format("duration must decrease by 30 to 170; got %d", after_A.duration_frames))

    local after_B = read_clip_columns("B")
    assert(after_B.sequence_start_frame == 400,
        "downstream clip B must not move on left-edge trim either")
    print("  ✓ left-edge shrink: source_in/start move; source_out + downstream unchanged")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2b. Left-edge grow: source_in retreats earlier into source; start advances
--     EARLIER; duration grows. Downstream upstream-neighbor distinction
--     irrelevant here (no overlap-policy logic in OverwriteTrimEdge — that's
--     RippleTrimEdge's concern). The clip's head extends earlier into its
--     source media; the timeline start_frame moves earlier by |delta|.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Left-edge grow ---")
do
    reset()
    create_clip("A", 100, 200, 50)   -- start=100, dur=200, src_in=50, src_out=250

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "left",
        delta_frames = -25,          -- extend left edge 25 frames earlier
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, "left-edge grow must succeed")

    local after = read_clip_columns("A")
    assert(after.sequence_start_frame == 75,
        string.format("left-edge grow moves start earlier by |delta|; got %d (expected 75)",
            after.sequence_start_frame))
    assert(after.source_in_frame == 25,
        string.format("source_in must retreat by 25 to 25; got %d", after.source_in_frame))
    assert(after.source_out_frame == 250,
        string.format("source_out unchanged on left-edge; got %d (expected 250)",
            after.source_out_frame))
    assert(after.duration_frames == 225,
        string.format("duration must grow by 25 to 225; got %d", after.duration_frames))
    print("  ✓ left-edge grow: source_in retreats; start advances earlier; source_out unchanged")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Right-edge grow: source_out + duration increase; downstream stays put
--    (overlap policy not this command's concern).
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Right-edge grow ---")
do
    reset()
    create_clip("A", 100, 200, 50)   -- src_out = 250; content extent = 1000

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "right",
        delta_frames = 40,           -- grow tail by 40 frames
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, "right-edge grow must succeed")

    local after = read_clip_columns("A")
    assert(after.duration_frames == 240,
        string.format("duration must grow to 240; got %d", after.duration_frames))
    assert(after.source_out_frame == 290,
        string.format("source_out must grow to 290; got %d", after.source_out_frame))
    print("  ✓ right-edge grow: source_out/duration increase")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Undo round-trip: pre-execute read-back equals post-undo read-back
--    bit-for-bit (FR-015b).
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Undo round-trip ---")
do
    reset()
    create_clip("A", 100, 200, 50)
    local before = read_clip_columns("A")

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "right",
        delta_frames = -50,
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success)

    local mid = read_clip_columns("A")
    assert(mid.duration_frames ~= before.duration_frames, "fixture: state actually mutated")

    command_manager.undo()

    local after = read_clip_columns("A")
    for k, _ in pairs(before) do
        assert(after[k] == before[k], string.format(
            "undo must restore %s bit-for-bit; before=%s after=%s",
            k, tostring(before[k]), tostring(after[k])))
    end
    print("  ✓ undo restores all four columns bit-for-bit")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Precondition asserts (FR-015) — invalid input must surface, never silent.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Precondition asserts ---")
do
    reset()
    create_clip("A", 100, 200, 50)

    -- delta_frames == 0 is the no-op case; spec says assert (no silent skip).
    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id = "A", edge = "right", delta_frames = 0,
        sequence_id = "seq", project_id = "proj",
    })
    assert(not (r and r.success),
        "OverwriteTrimEdge with delta_frames=0 must NOT succeed silently")

    -- edge ∉ {"left","right"}
    r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id = "A", edge = "bogus", delta_frames = -10,
        sequence_id = "seq", project_id = "proj",
    })
    assert(not (r and r.success),
        "OverwriteTrimEdge with edge='bogus' must NOT succeed")

    -- Missing clip_id
    r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id = "nonexistent", edge = "right", delta_frames = -10,
        sequence_id = "seq", project_id = "proj",
    })
    assert(not (r and r.success),
        "OverwriteTrimEdge against missing clip must NOT succeed silently")

    -- Trim past content extent: clip A's source covers [50, 250); the
    -- source media is 1000 frames; trying to grow the right edge by 800
    -- pushes source_out to 1050, past the media's 1000-frame extent.
    r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id = "A", edge = "right", delta_frames = 800,
        sequence_id = "seq", project_id = "proj",
    })
    assert(not (r and r.success),
        "OverwriteTrimEdge growing past content extent must NOT succeed")

    -- After all failed attempts, clip A's columns must be unchanged.
    local final = read_clip_columns("A")
    assert(final.sequence_start_frame == 100 and final.duration_frames == 200
        and final.source_in_frame == 50 and final.source_out_frame == 250,
        "after failed preconditions, clip state must be unchanged (no partial mutation)")
    print("  ✓ all four preconditions reject without partial mutation")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Left-edge grow ABSORBS upstream neighbor (FR-014 update, 2026-05-20).
--    "Overwrite trim" means extension into occupied space eats the neighbor —
--    the same primitive (clip_mutator.resolve_occlusions) Insert / Overwrite /
--    Paste use to carve space. Regression for the VIDEO_OVERLAP trigger that
--    used to fire when growing into a neighbor (TSO 2026-05-20).
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Left-edge grow absorbs upstream neighbor ---")
do
    reset()
    -- Two-clip layout on v1:
    --   B at [0, 80)        — upstream neighbor (the one to be absorbed)
    --   A at [100, 300)     — focus clip (src_in=50)
    -- Grow A's left edge by 30 frames earlier → A spans [70, 300). The
    -- last 10 frames of B [70, 80) sit under A's new head → B should be
    -- trimmed at the tail down to [0, 70).
    create_clip("B",   0,  80,  500)
    create_clip("A", 100, 200,   50)

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "left",
        delta_frames = -30,
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, string.format(
        "left-edge grow into occupied space must succeed; got %s",
        tostring(r and r.error_message)))

    local a_after = read_clip_columns("A")
    assert(a_after.sequence_start_frame == 70, string.format(
        "A.sequence_start must move to 70 (100 + delta -30); got %d",
        a_after.sequence_start_frame))
    assert(a_after.duration_frames == 230, string.format(
        "A.duration must grow to 230; got %d", a_after.duration_frames))
    assert(a_after.source_in_frame == 20, string.format(
        "A.source_in must retreat to 20 (50 + -30); got %d", a_after.source_in_frame))

    -- B was partially absorbed: tail trimmed to 70 (A's new start).
    local b_after = read_clip_columns("B")
    assert(b_after.sequence_start_frame == 0, string.format(
        "B.sequence_start unchanged when only its tail is eaten; got %d",
        b_after.sequence_start_frame))
    assert(b_after.duration_frames == 70, string.format(
        "B.duration trimmed to 70 (start unchanged; new end at A.new_start=70); got %d",
        b_after.duration_frames))
    print("  ✓ neighbor absorbed (tail trimmed) by left-edge grow")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Right-edge grow ABSORBS downstream neighbor — symmetric to scenario 6.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Right-edge grow absorbs downstream neighbor ---")
do
    reset()
    -- A at [100, 300), B at [320, 400). Grow A's right edge by +40 → A
    -- spans [100, 340). B's head [320, 340) is eaten; B should be
    -- trimmed at the head down to [340, 400) (duration 60).
    create_clip("A", 100, 200, 50)
    create_clip("B", 320,  80, 200)

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "right",
        delta_frames = 40,
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, "right-edge grow into occupied space must succeed")

    local a_after = read_clip_columns("A")
    assert(a_after.sequence_start_frame == 100,
        "A.sequence_start unchanged for right-edge trim")
    assert(a_after.duration_frames == 240, string.format(
        "A.duration must grow to 240; got %d", a_after.duration_frames))

    local b_after = read_clip_columns("B")
    assert(b_after.sequence_start_frame == 340, string.format(
        "B.sequence_start must move to 340 (A's new end); got %d",
        b_after.sequence_start_frame))
    assert(b_after.duration_frames == 60, string.format(
        "B.duration trimmed to 60 (head eaten); got %d", b_after.duration_frames))
    print("  ✓ neighbor absorbed (head trimmed) by right-edge grow")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Grow that FULLY COVERS a neighbor deletes it.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Grow that fully covers a neighbor deletes it ---")
do
    reset()
    -- A at [0, 100), N at [120, 180), C at [300, 400). Grow A's right
    -- edge by +200 → A spans [0, 300). N is fully covered → deleted.
    -- C is untouched.
    create_clip("A",   0, 100, 50)
    create_clip("N", 120,  60, 200)
    create_clip("C", 300, 100, 300)

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "right",
        delta_frames = 200,
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success, "fully-covering grow must succeed")

    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = 'N'")
    assert(stmt:exec()); assert(stmt:next())
    local n_count = stmt:value(0); stmt:finalize()
    assert(n_count == 0, string.format(
        "fully-covered neighbor N must be deleted; got %d row(s) remaining",
        n_count))

    local c_after = read_clip_columns("C")
    assert(c_after.sequence_start_frame == 300 and c_after.duration_frames == 100,
        "C (not in the path) must be untouched")
    print("  ✓ fully-covered neighbor deleted; uninvolved clip untouched")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Undo restores absorbed neighbor bit-for-bit.
-- ─────────────────────────────────────────────────────────────────────────────
print("\n--- Undo restores absorbed neighbor ---")
do
    reset()
    create_clip("B",   0,  80, 500)
    create_clip("A", 100, 200,  50)
    local b_before = read_clip_columns("B")
    local a_before = read_clip_columns("A")

    local r = command_manager.execute_interactive("OverwriteTrimEdge", {
        clip_id      = "A",
        edge         = "left",
        delta_frames = -30,
        sequence_id  = "seq",
        project_id   = "proj",
    })
    assert(r and r.success)

    command_manager.undo()

    local b_after = read_clip_columns("B")
    local a_after = read_clip_columns("A")
    for k, _ in pairs(b_before) do
        assert(b_after[k] == b_before[k], string.format(
            "undo must restore B.%s bit-for-bit; before=%s after=%s",
            k, tostring(b_before[k]), tostring(b_after[k])))
    end
    for k, _ in pairs(a_before) do
        assert(a_after[k] == a_before[k], string.format(
            "undo must restore A.%s bit-for-bit; before=%s after=%s",
            k, tostring(a_before[k]), tostring(a_after[k])))
    end
    print("  ✓ undo restores focus clip + absorbed neighbor bit-for-bit")
end

print("\n✅ test_overwrite_trim_edge.lua passed")

print("\n✅ test_overwrite_trim_edge.lua passed")
