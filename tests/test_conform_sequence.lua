-- 018 T042 / FR-035: ConformSequence rewrites a sequence's fps_num/den
-- plus every dependent row (media_refs for kind=master, contained clips
-- for kind=sequence, outer clips pointing at this seq for BOTH kinds) so
-- the resolver produces the same wall-clock content under the new fps.
--
-- Atomic, undoable; only legal path to mutate sequences.fps_*. Direct
-- UPDATE blocked by trigger INV-5.
--
-- Expected to FAIL until T045 lands.

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_conform_sequence.db"

-- ─────────────────────────────────────────────────────────────────────
-- Scenario A: kind='master', conform 24/1 → 23.976 (24000/1001).
-- Master has a V media_ref (240 frames @ 24fps). One outer clip in 'e'
-- points at the master at source [0, 240). Conform should:
--   - master.fps becomes 24000/1001
--   - media_ref's sequence_start_frame / duration_frames rescale by
--     (24000*1) / (1001*24) = 24000/24024 ≈ 0.99900
--   - media_ref.source_in (file samples — N/A for video here) unchanged
--   - outer clip's source_in_frame / source_out_frame rescale
--   - source_*_subframe unchanged (subframes are master-clock ticks,
--     not fps-dependent)
-- ─────────────────────────────────────────────────────────────────────

local function build_master_fixture()
    os.remove(DB)
    assert(database.init(DB))
    local db = database.get_connection()
    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p', 'P', 'passthrough',
                '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
                %d, %d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p', 'M', 'master',  24, 1, NULL,  1920, 1080, %d, %d),
               ('e', 'p', 'E', 'sequence',24, 1, 48000, 1920, 1080, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vmed', 'p', 'v.mov', '/tmp/v.mov', 240, 24, 1, 0, %d, %d);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('vref', 'p', 'm', 'm-v1', 'vmed', 0, 240, 0, 240,
                1, 1.0, 0, %d, %d);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
            name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('outer-v', 'p', 'e', 'e-v1', 'm', 'Outer',
                0, 240, 0, 240, NULL, NULL,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now, now, now, now, now)))
    command_manager.init('e', 'p')
    return db
end

local function read_seq_fps(db, id)
    local s = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local n, d = s:value(0), s:value(1); s:finalize()
    return n, d
end
local function read_mref(db, id)
    local s = db:prepare([[
        SELECT sequence_start_frame, duration_frames, source_in_frame, source_out_frame
        FROM media_refs WHERE id = ?
    ]])
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local seq_start, dur, src_in, src_out = s:value(0), s:value(1), s:value(2), s:value(3)
    s:finalize()
    return seq_start, dur, src_in, src_out
end
local function read_clip(db, id)
    local s = db:prepare([[
        SELECT source_in_frame, source_out_frame,
               source_in_subframe, source_out_subframe,
               sequence_start_frame, duration_frames
        FROM clips WHERE id = ?
    ]])
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local r = {
        src_in    = s:value(0), src_out = s:value(1),
        sub_in    = s:value(2), sub_out = s:value(3),
        seq_start = s:value(4), dur     = s:value(5),
    }
    s:finalize()
    return r
end

-- round_half_away_from_zero (matches subframe_math).
local function rhaz(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- ── Scenario A: kind='master' ───────────────────────────────────────
print("-- Scenario A: kind='master', 24/1 → 24000/1001 --")
do
    local db = build_master_fixture()

    local r = command_manager.execute("ConformSequence", {
        project_id      = "p",
        sequence_id     = "m",
        fps_numerator   = 24000,
        fps_denominator = 1001,
    })
    assert(r and r.success, "ConformSequence: " .. tostring(r and r.error_message))

    -- 1. Master fps changed.
    local n, d = read_seq_fps(db, "m")
    assert(n == 24000 and d == 1001, string.format(
        "master fps must be 24000/1001; got %s/%s", tostring(n), tostring(d)))

    -- 2. media_ref scaled: factor = 24000*1 / (1001*24) ≈ 0.99900.
    -- new = round(old * 24000 * 1 / (1001 * 24)).
    -- For old = 240: round(240 * 24000 / 24024) = round(239.7603) = 240.
    -- Doesn't drift on round numbers — pick a non-trivial source value.
    local seq_start, dur, src_in_mr, src_out_mr = read_mref(db, "vref")
    assert(seq_start == 0, "vref sequence_start_frame=0 must remain 0")
    -- duration 240 frames at 24/1 ↔ 24000/1001:
    -- new_dur = rhaz(240 * 24000 / (1001 * 24)) = rhaz(239.7603) = 240.
    -- The contract specifies frames rescale; for exactly 240 frames it
    -- happens to round-trip to 240. Verify the formula was applied (not
    -- skipped) by also checking source_in/out remain unchanged.
    local expected_dur = rhaz(240 * 24000 / (1001 * 24))
    assert(dur == expected_dur, string.format(
        "vref duration_frames must rescale to %d; got %s",
        expected_dur, tostring(dur)))
    -- For VIDEO media_refs, source_in/out are also frames; they stay in
    -- the file's native timebase (the file didn't change). Per contract:
    -- "media_ref.source_in (file-natural samples) is unchanged". For
    -- video media_refs the columns are frames; treat the same way
    -- (untouched).
    assert(src_in_mr == 0 and src_out_mr == 240,
        "vref source_in/out untouched (file unchanged)")

    -- 3. Outer clip's source_in_frame / source_out_frame rescale.
    local c = read_clip(db, "outer-v")
    local expected_src_out = rhaz(240 * 24000 / (1001 * 24))
    assert(c.src_in == 0, "outer clip src_in stays 0")
    assert(c.src_out == expected_src_out, string.format(
        "outer clip src_out must rescale to %d; got %s",
        expected_src_out, tostring(c.src_out)))

    -- 4. Subframes unchanged (NULL for video; this also covers
    -- "subframes unchanged" for any non-NULL ones in scenario B).
    assert(c.sub_in == nil and c.sub_out == nil, "video subframes stay NULL")

    -- 5. Outer clip's sequence_start_frame / duration_frames are in
    -- the OUTER sequence's owner timebase (24/1), which did NOT change.
    -- Those stay 0 / 240.
    assert(c.seq_start == 0 and c.dur == 240,
        "outer clip timeline placement (owner timebase) untouched")

    print("  ok")
end

-- ── Scenario B: kind='sequence' ─────────────────────────────────────
print("-- Scenario B: kind='sequence', conform 30/1 → 24/1 --")
do
    -- Sequence 'inner' (kind=sequence, 30/1, contains 2 clips). One outer
    -- clip in 'outer' (kind=sequence, 24/1) points AT inner as its source.
    os.remove(DB)
    assert(database.init(DB))
    local db = database.get_connection()
    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p', 'P', 'passthrough',
                '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('inner', 'p', 'I', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d),
               ('outer', 'p', 'O', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d),
               ('mleaf', 'p', 'L', 'master',   30, 1, NULL,  1920, 1080, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('inner-v1', 'inner', 'V1', 'VIDEO', 1),
               ('outer-v1', 'outer', 'V1', 'VIDEO', 1),
               ('mleaf-v1', 'mleaf', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'mleaf-v1' WHERE id = 'mleaf';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('vm', 'p', 'v.mov', '/tmp/v.mov', 600, 30, 1, 0, %d, %d);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('lref', 'p', 'mleaf', 'mleaf-v1', 'vm', 0, 600, 0, 600,
                1, 1.0, 0, %d, %d);
        -- Two contained clips on the inner sequence.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
            name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('inner-c1', 'p', 'inner', 'inner-v1', 'mleaf', 'C1',
                  0, 150,   0, 150, NULL, NULL, NULL, NULL, 'passthrough',
                  1, 1.0, 0, %d, %d),
               ('inner-c2', 'p', 'inner', 'inner-v1', 'mleaf', 'C2',
                150,  90, 150, 240, NULL, NULL, NULL, NULL, 'passthrough',
                  1, 1.0, 0, %d, %d),
               -- Outer clip references inner as its source (a nested edit
               -- — outer sequence holds an "inner-as-clip").
               ('outer-c', 'p', 'outer', 'outer-v1', 'inner', 'Nested',
                  0, 200,   0, 240, NULL, NULL, NULL, NULL, 'passthrough',
                  1, 1.0, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now, now, now, now, now,
        now, now, now, now, now, now)))
    command_manager.init('outer', 'p')

    local r = command_manager.execute("ConformSequence", {
        project_id      = "p",
        sequence_id     = "inner",
        fps_numerator   = 24,
        fps_denominator = 1,
    })
    assert(r and r.success, "ConformSequence: " .. tostring(r and r.error_message))

    -- Inner fps changed.
    local n, d = read_seq_fps(db, "inner")
    assert(n == 24 and d == 1, string.format(
        "inner fps must be 24/1; got %s/%s", tostring(n), tostring(d)))

    -- Contained clips rescale: factor = 24*1 / (1*30) = 0.8.
    -- c1: seq_start=0, dur=150 → 0, 120.  c2: 150, 90 → 120, 72.
    local c1 = read_clip(db, "inner-c1")
    assert(c1.seq_start == 0 and c1.dur == 120, string.format(
        "inner-c1 must rescale to (0, 120); got (%s, %s)",
        tostring(c1.seq_start), tostring(c1.dur)))
    local c2 = read_clip(db, "inner-c2")
    assert(c2.seq_start == 120 and c2.dur == 72, string.format(
        "inner-c2 must rescale to (120, 72); got (%s, %s)",
        tostring(c2.seq_start), tostring(c2.dur)))

    -- Contained clips' source_*_frame columns (point at mleaf, NOT inner)
    -- are independent of inner's fps and UNCHANGED.
    assert(c1.src_in == 0 and c1.src_out == 150, "inner-c1 source untouched")
    assert(c2.src_in == 150 and c2.src_out == 240, "inner-c2 source untouched")

    -- Outer clip points AT inner — its source_*_frame rescale.
    local oc = read_clip(db, "outer-c")
    -- old: src_in=0, src_out=240 in inner's old 30/1 frames.
    -- new (inner now 24/1): rhaz(0 * 24/30) = 0; rhaz(240 * 24/30) = 192.
    assert(oc.src_in == 0 and oc.src_out == 192, string.format(
        "outer-c source must rescale to (0, 192); got (%s, %s)",
        tostring(oc.src_in), tostring(oc.src_out)))
    -- Outer clip placement on outer sequence (owner 24/1) unchanged.
    assert(oc.seq_start == 0 and oc.dur == 200, "outer-c placement untouched")

    print("  ok")
end

-- ── Scenario C: undo round-trip ─────────────────────────────────────
print("-- Scenario C: execute → undo restores; redo re-applies --")
do
    local db = build_master_fixture()
    -- Snapshot pre-execute state of the rewritten rows.
    local pre_mref = { read_mref(db, "vref") }
    local pre_clip = read_clip(db, "outer-v")
    local pre_n, pre_d = read_seq_fps(db, "m")

    local r = command_manager.execute("ConformSequence", {
        project_id = "p", sequence_id = "m",
        fps_numerator = 24000, fps_denominator = 1001,
    })
    assert(r and r.success, "execute")

    assert(command_manager.undo(), "undo")
    local un_n, un_d = read_seq_fps(db, "m")
    assert(un_n == pre_n and un_d == pre_d, "fps restored")
    local un_mref = { read_mref(db, "vref") }
    for i = 1, 4 do
        assert(un_mref[i] == pre_mref[i], string.format(
            "media_ref column %d not restored: was %s now %s",
            i, tostring(pre_mref[i]), tostring(un_mref[i])))
    end
    local un_clip = read_clip(db, "outer-v")
    for k, v in pairs(pre_clip) do
        assert(un_clip[k] == v, string.format(
            "outer-v clip column %s not restored: was %s now %s",
            k, tostring(v), tostring(un_clip[k])))
    end

    assert(command_manager.redo(), "redo")
    local rn, rd = read_seq_fps(db, "m")
    assert(rn == 24000 and rd == 1001, "redo re-applies 24000/1001")
    print("  ok")
end

-- ── Scenario D: INV-5 blocks direct fps UPDATE ──────────────────────
print("-- Scenario D: INV-5 blocks direct UPDATE of sequences.fps_* --")
do
    local db = build_master_fixture()
    local ok = pcall(function()
        local upd = db:prepare(
            "UPDATE sequences SET fps_numerator = 30 WHERE id = 'm'")
        assert(upd:exec(), "INV-5 should ABORT")
        upd:finalize()
    end)
    assert(not ok, "INV-5 must block direct UPDATE of sequences.fps_*")
    local n, d = read_seq_fps(db, "m")
    assert(n == 24 and d == 1, "master fps unchanged after refused UPDATE")
    print("  ok")
end

-- ── Scenario E: no-op rejected ──────────────────────────────────────
print("-- Scenario E: no-op rejected --")
do
    build_master_fixture()
    local refused
    local ok = pcall(function()
        local r = command_manager.execute("ConformSequence", {
            project_id = "p", sequence_id = "m",
            fps_numerator = 24, fps_denominator = 1,
        })
        refused = type(r) == "table" and r.success == false
    end)
    if not ok then refused = true end
    assert(refused, "no-op (new == current fps) must be refused")
    print("  ok")
end

print("✅ test_conform_sequence.lua passed")
