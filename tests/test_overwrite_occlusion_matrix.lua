-- 013: Overwrite occlusion matrix (gap coverage).
--
-- CT-C2 (T033) exercises only the tail-overlap case (case b). This test
-- covers the remaining cases of the occlusion matrix and the multi-clip
-- interaction that wasn't exercised yet:
--
--   (a) new range fully covers an existing clip  → DELETE
--   (c) new range head-overlaps an existing clip → trim E's head
--       (sequence_start shifts forward, source_in advances,
--        source_out unchanged)
--   (d) new range straddles inside an existing   → split E into
--       (shorter left half + new right-half row at n_end)
--   (multi) a single Overwrite against three clips on one track, one
--       in each of cases (a)/(b)/(c), resolved in a single pass
--
-- Black-box: each scenario asserts observable DB state after the
-- Overwrite, without reading implementation internals. Expected values
-- are derived from domain semantics (passthrough is 1:1 owner↔source;
-- occlusion leaves no gap on the track from removed clips).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_overwrite_occlusion_matrix.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Build a fixture: 25fps V-only master 'm' (60 frames), a 200-frame
-- master 'm-pre' used for pre-existing clips on the edit timeline, and
-- a 24fps nested edit sequence. The caller seeds pre-existing clips
-- via direct SQL INSERT (one per scenario, parametrized positions).
local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, NULL, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, created_at, modified_at)
        VALUES ('m-pre', 'p1', 'pre', 'master', 24, 1, 48000, 1920, 1080, NULL, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-pre-v1', 'm-pre', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        UPDATE sequences SET default_video_layer_track_id = 'm-pre-v1' WHERE id = 'm-pre';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 60, 24, 1, 0, 0, 0);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v-pre', 'p1', 'pre.mov', '/tmp/pre.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 60, 0, 60, 1, 1.0, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v-pre', 'p1', 'm-pre', 'm-pre-v1', 'med-v-pre', 0, 1000, 0, 1000,
            1, 1.0, 0, 0, 0);
    ]]))
    return db
end

-- Seed one pre-existing V clip on the edit track. Timebase: edit is 24/1,
-- master 'm-pre' is 24/1 passthrough so source==owner frames. Source
-- range starts at `source_in` for `duration` frames.
local function seed_pre_clip(db, clip_id, sequence_start, duration, source_in)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', 'p1', 'e', 'e-v1', 'm-pre', '%s', %d, %d, %d, %d,
            'passthrough', 1, 1.0, 0, 0, 0)
    ]], clip_id, clip_id, sequence_start, duration, source_in,
       source_in + duration)))
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec(), "load_clip: exec failed")
    if not stmt:next() then stmt:finalize(); return nil end
    local r = {
        sequence_start = stmt:value(0),
        duration       = stmt:value(1),
        source_in      = stmt:value(2),
        source_out     = stmt:value(3),
    }
    stmt:finalize()
    return r
end

local function clips_on_track(db, track_id)
    local stmt = db:prepare([[
        SELECT id, sequence_start_frame, duration_frames
        FROM clips WHERE track_id = ? ORDER BY sequence_start_frame
    ]])
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "clips_on_track: exec failed")
    local list = {}
    while stmt:next() do
        list[#list + 1] = {
            id = stmt:value(0),
            sequence_start = stmt:value(1),
            duration = stmt:value(2),
        }
    end
    stmt:finalize()
    return list
end

local Overwrite = require("core.commands.overwrite")
assert(type(Overwrite.execute) == "function",
    "core.commands.overwrite must export .execute")

-- -------------------------------------------------------------------------
-- (a) Full-cover: Overwrite swallows an existing clip entirely.
-- -------------------------------------------------------------------------
print("-- (a) full-cover delete --")
do
    local db = build_fixture()
    -- Existing clip [40, 80). Overwrite at 30 with 60-frame master
    -- (passthrough policy chosen so new clip is 60 owner frames, range
    -- [30, 90) — fully contains [40, 80).
    seed_pre_clip(db, "pre", 40, 40, 0)
    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m",
        sequence_start_frame = 30,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",
    })
    assert(load_clip(db, "pre") == nil,
        "fully-covered clip must be deleted, not present")
    local list = clips_on_track(db, "e-v1")
    assert(#list == 1,
        string.format("track should hold 1 clip (the new one); got %d", #list))
    assert(list[1].sequence_start == 30 and list[1].duration == 60,
        string.format("new clip at [30,90); got [%d,%d)",
            list[1].sequence_start, list[1].sequence_start + list[1].duration))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- (c) Head-overlap: Overwrite's range starts at or before E's start and
--     ends inside E. E's head is trimmed away — sequence_start shifts to
--     n_end, source_in advances by the trimmed amount, source_out is
--     unchanged.
-- -------------------------------------------------------------------------
print("-- (c) head-overlap trim --")
do
    local db = build_fixture()
    -- Existing [100, 200) with source [50, 150). Overwrite at [80, 140)
    -- with 60-frame passthrough master.
    seed_pre_clip(db, "pre", 100, 100, 50)
    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m",
        sequence_start_frame = 80,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",
    })
    local pre = load_clip(db, "pre")
    assert(pre, "pre clip must still exist (head-trim, not delete)")
    -- New duration = 200 - 140 = 60; shifted to start at 140.
    assert(pre.sequence_start == 140, string.format(
        "pre clip sequence_start=%d expected 140 (n_end of overwrite)",
        pre.sequence_start))
    assert(pre.duration == 60, string.format(
        "pre clip duration=%d expected 60", pre.duration))
    -- source_in advances by the trim shift (140-100=40), passthrough 1:1
    -- so source_in = 50 + 40 = 90. source_out unchanged at 150.
    assert(pre.source_in == 90, string.format(
        "pre clip source_in=%d expected 90 (50 + 40 shift)", pre.source_in))
    assert(pre.source_out == 150, string.format(
        "pre clip source_out=%d expected 150 (unchanged by head-trim)",
        pre.source_out))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- (d) Straddle-split: Overwrite's range lies entirely inside E. E gets
--     shrunk to the left-of-new half, and a NEW clip row is created for
--     the right-of-new half with the matching source bounds.
-- -------------------------------------------------------------------------
print("-- (d) straddle split --")
do
    local db = build_fixture()
    -- Existing [50, 250) with source [100, 300). Overwrite at [120, 180)
    -- with 60-frame passthrough. Range [120, 180) is fully inside [50, 250).
    seed_pre_clip(db, "pre", 50, 200, 100)
    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m",
        sequence_start_frame = 120,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",
    })

    -- E becomes the left half [50, 120). duration 70. source_in 100
    -- unchanged, source_out shrinks by 130 (the removed right side) to 170.
    local pre = load_clip(db, "pre")
    assert(pre, "left half must still exist under original id")
    assert(pre.sequence_start == 50 and pre.duration == 70, string.format(
        "left half [timeline=%d, dur=%d] expected [50, 70]",
        pre.sequence_start, pre.duration))
    assert(pre.source_in == 100 and pre.source_out == 170, string.format(
        "left half source [%d,%d) expected [100,170)",
        pre.source_in, pre.source_out))

    -- Exactly three clips now on the track: left half, new, right half.
    local list = clips_on_track(db, "e-v1")
    assert(#list == 3, string.format(
        "straddle should leave 3 clips (left + new + right); got %d", #list))
    -- Identify right half: the clip at sequence_start >= 180 that's NOT
    -- the new clip (nested 'm').
    local function find_right_half()
        for _, c in ipairs(list) do
            if c.sequence_start == 180 then
                local q = db:prepare(
                    "SELECT sequence_id FROM clips WHERE id = ?")
                q:bind_value(1, c.id); q:exec(); q:next()
                local nested = q:value(0)
                q:finalize()
                if nested == "m-pre" then return c end
            end
        end
        return nil
    end
    local right = find_right_half()
    assert(right, "right half (nested=m-pre at tl=180) must exist")
    -- Right duration = 250 - 180 = 70.
    assert(right.duration == 70, string.format(
        "right half duration=%d expected 70", right.duration))
    local right_row = load_clip(db, right.id)
    -- Right source_in: original source_in 100 shifted by overlap-from-start
    -- (180 - 50 = 130) under passthrough 1:1, so source_in = 230.
    -- source_out carries through = original 300.
    assert(right_row.source_in == 230, string.format(
        "right half source_in=%d expected 230 (100 + 130 shift)",
        right_row.source_in))
    assert(right_row.source_out == 300, string.format(
        "right half source_out=%d expected 300 (unchanged from split)",
        right_row.source_out))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Multi-clip: one Overwrite against three pre-existing clips of
-- different overlap types on the same track, all resolved in one pass.
-- -------------------------------------------------------------------------
print("-- multi-clip occlusion --")
do
    local db = build_fixture()
    -- Pre clips:
    --   pre_a: [0, 40)  — tail-overlaps (new starts at 30)
    --   pre_b: [50, 80) — fully covered by new [30, 90)
    --   pre_c: [85, 150) — head-overlaps (new ends at 90)
    seed_pre_clip(db, "pre_a", 0,  40, 0)
    seed_pre_clip(db, "pre_b", 50, 30, 500)
    seed_pre_clip(db, "pre_c", 85, 65, 700)

    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m",
        sequence_start_frame = 30,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",  -- new = 60 frames at [30, 90)
    })

    -- pre_a trimmed to [0, 30): duration 30, source_out 30.
    local a = load_clip(db, "pre_a")
    assert(a and a.sequence_start == 0 and a.duration == 30
           and a.source_in == 0 and a.source_out == 30,
        string.format("pre_a expected [tl=0,d=30,s=(0,30)] got [tl=%s,d=%s,s=(%s,%s)]",
            tostring(a and a.sequence_start), tostring(a and a.duration),
            tostring(a and a.source_in),      tostring(a and a.source_out)))

    -- pre_b fully covered → deleted.
    assert(load_clip(db, "pre_b") == nil, "pre_b must be deleted")

    -- pre_c head-trimmed to [90, 150): duration 60, source_in shifts by 5.
    local c = load_clip(db, "pre_c")
    assert(c and c.sequence_start == 90 and c.duration == 60,
        string.format("pre_c expected [tl=90,d=60] got [tl=%s,d=%s]",
            tostring(c and c.sequence_start), tostring(c and c.duration)))
    assert(c.source_in == 705 and c.source_out == 765, string.format(
        "pre_c source expected [705,765) got [%d,%d)",
        c.source_in, c.source_out))

    -- Track now has 3 clips: pre_a, new, pre_c.
    local list = clips_on_track(db, "e-v1")
    assert(#list == 3, string.format("track expected 3 clips; got %d", #list))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Edge: zero-duration trim (exact boundary hit). Currently broken — this
-- test is EXPECTED TO FAIL until the implementation handles the case.
--
-- Pre clip [100, 160). Overwrite at [160, 220). n_start == e_end so the
-- overlap is empty — no occlusion required (new range touches but does
-- not cross into pre). The find_overlapping_on_track query uses strict
-- `>` on the right boundary via `sequence_start_frame + duration_frames
-- > window_start`, which for e_end == n_start yields `160 > 160` = false.
-- So no occlusion is invoked. Pre should survive unmodified; new clip
-- sits at [160, 220). No surprises.
-- -------------------------------------------------------------------------
print("-- edge: abutting (n_start == e_end, no actual overlap) --")
do
    local db = build_fixture()
    seed_pre_clip(db, "pre", 100, 60, 0)
    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m",
        sequence_start_frame = 160,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",
    })
    local pre = load_clip(db, "pre")
    assert(pre, "abutting pre clip must survive (no overlap)")
    assert(pre.sequence_start == 100 and pre.duration == 60 and
           pre.source_in == 0 and pre.source_out == 60,
        "abutting pre clip must be untouched")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Edge: tail-overlap that would leave duration == 0 (n_start == e_start).
-- Pre clip [100, 160), Overwrite at [100, 180). overlap check
-- (sequence_start_frame < 180 && tl + dur > 100) = true; but the trim
-- would make new_duration = 100 - 100 = 0. That's actually a
-- full-cover case (n_start <= e_start and n_end >= e_end), so case (a)
-- fires and E is deleted. Verifies the branch ordering holds up at
-- the edge.
-- -------------------------------------------------------------------------
print("-- edge: overlap with n_start == e_start routes to full-cover --")
do
    local db = build_fixture()
    seed_pre_clip(db, "pre", 100, 60, 0)
    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m",
        sequence_start_frame = 100,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",  -- new = 60, [100, 160)
    })
    -- New exactly covers pre — full cover delete.
    assert(load_clip(db, "pre") == nil,
        "pre must be deleted when Overwrite exactly aligns boundary-to-boundary")
    local list = clips_on_track(db, "e-v1")
    assert(#list == 1, "track should have just the new clip")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Edge: head-overlap that would leave duration == 0 (n_end == e_end).
-- Pre clip [100, 160), Overwrite at [40, 160). overlap true. This should
-- ALSO route to full-cover (a) since n_start < e_start and n_end >= e_end.
-- -------------------------------------------------------------------------
print("-- edge: overlap with n_end == e_end routes to full-cover --")
do
    local db = build_fixture()
    seed_pre_clip(db, "pre", 100, 60, 0)
    -- We need a 120-frame nested to make [40, 160). Reuse m-pre briefly:
    -- but contract allows any nested. Construct a scenario with a
    -- passthrough 120-frame master — simplest is just to place m at 40
    -- with explicit passthrough math. m's native = 60, passthrough = 60,
    -- insufficient. Skip: construct via m-pre which is 1000-frame. We'll
    -- need a small purpose-built nested for this. Use a variant fixture.
    db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, created_at, modified_at)
        VALUES ('m120', 'p1', 'm120', 'master', 24, 1, 48000, 1920, 1080,
            NULL, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m120-v1', 'm120', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm120-v1' WHERE id = 'm120';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med120', 'p1', 'm120.mov', '/tmp/m120.mov', 120, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr120', 'p1', 'm120', 'm120-v1', 'med120', 0, 120, 0, 120,
            1, 1.0, 0, 0, 0);
    ]])
    Overwrite.execute({
        sequence_id = "e", source_sequence_id = "m120",
        sequence_start_frame = 40,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",  -- new = 120, [40, 160)
    })
    assert(load_clip(db, "pre") == nil,
        "pre must be deleted — new range [40,160) fully contains [100,160)")
    print("  ok")
end

print("✅ test_overwrite_occlusion_matrix.lua passed")
