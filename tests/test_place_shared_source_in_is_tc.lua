-- Regression (TSO 2026-05-17 F10-no-frames):
--
-- Domain behavior:
--   Inserting/overwriting a clip that references a nested master sequence
--   whose video starts at a non-zero TC origin (e.g. cinema camera grab,
--   BWF, DPX, EXR) must write the new clip's source_in_frame in **absolute
--   TC space** — i.e. matching the nested's media_refs coordinate system
--   per TIMECODE IS THE SOURCE OF TRUTH (specs/013/data-model.md §source_*).
--
--   Otherwise the resolver's range overlap check (`r_hi > master_lo and
--   r_lo < master_hi` in resolve_master_leaf) finds nothing in the nested,
--   _provide_clips returns 0 entries, and the timeline monitor shows gap
--   even though the clip is on disk.
--
-- Cases:
--   T1: Insert with no marks set on the nested master (tc_origin > 0)
--       → clip.source_in_frame must equal tc_origin (not 0).
--   T2: Insert with marks set (mark_in / mark_out in absolute TC frames)
--       → clip.source_in_frame must equal mark_in (not mark_in - tc_origin).
--   T3: AUDIO clip source_in_frame must equal the SAME absolute TC value
--       as VIDEO (master.fps frames). Pre-fix code converted to samples,
--       which is the resolver's job — not the writer's.
--
-- Black-box: drives Insert.execute against a freshly-built fixture and
-- reads the resulting rows' source_in_frame.

require("test_env")

local database = require("core.database")
local Insert   = require("core.commands.insert")

local DB_PATH = "/tmp/jve/test_place_shared_source_in_is_tc.db"

local TC_ORIGIN     = 1424483        -- absolute video frame; matches the
                                     -- F10 repro from the TSO investigation.
local MEDIA_DUR     = 2317           -- master.fps frames span
local EDIT_FPS_NUM  = 25
local EDIT_FPS_DEN  = 1

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return assert(database.get_connection(), "no db connection")
end

local function exec(db, sql)
    assert(db:exec(sql), "DB exec failed:\n" .. sql)
end

-- Project + 25fps master with V+A media_refs at timeline_start = tc_origin,
-- plus a 25fps edit sequence.  Returns the ids of interest.
local function build_fixture()
    local db = fresh_db()
    exec(db, [[INSERT INTO projects (id, name, fps_mismatch_policy,
                  created_at, modified_at)
               VALUES ('p1', 'p', 'resample', 0, 0)]])

    exec(db, string.format([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, start_timecode_frame,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master',
            25, 1, 48000, 1920, 1080, %d, 0, 0)]], TC_ORIGIN))

    exec(db, string.format([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence',
            %d, %d, 48000, 1920, 1080, 0, 0)]], EDIT_FPS_NUM, EDIT_FPS_DEN))

    exec(db, [[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
            VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
            VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
            VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
            VALUES ('e-a1', 'e', 'A1', 'AUDIO', 1);
    ]])

    exec(db, "UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")

    exec(db, [[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 2317, 25, 1, 0, 0, 0)
    ]])
    exec(db, [[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('med-a', 'p1', 'a.wav', '/tmp/a.wav', 4448640, 48000, 1, 2, 0, 0)
    ]])

    -- media_refs sit at timeline_start = tc_origin per master timebase
    -- (TIMECODE IS TRUTH). Both V and A use the master's video timebase.
    exec(db, string.format([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', %d, %d, %d, %d,
            1, 1.0, 0, 0, 0)]],
        TC_ORIGIN, TC_ORIGIN + MEDIA_DUR, TC_ORIGIN, MEDIA_DUR))
    exec(db, string.format([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'med-a', 0, 4448640, %d, %d,
            1, 1.0, 0, 0, 0)]],
        TC_ORIGIN, MEDIA_DUR))

    return { project_id = "p1", master_id = "m", edit_id = "e",
             edit_v1 = "e-v1", edit_a1 = "e-a1" }
end

local function load_clip_row(db, clip_id)
    local stmt = db:prepare([[
        SELECT track_id, source_in_frame, source_out_frame,
               timeline_start_frame, duration_frames
        FROM clips WHERE id = ?]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(),
        "load_clip_row: clip " .. clip_id .. " not found")
    local row = {
        track_id          = stmt:value(0),
        source_in_frame   = stmt:value(1),
        source_out_frame  = stmt:value(2),
        timeline_start    = stmt:value(3),
        duration_frames   = stmt:value(4),
    }
    stmt:finalize()
    return row
end

local function v_clip(db, ids, created_ids)
    for _, cid in ipairs(created_ids) do
        local row = load_clip_row(db, cid)
        if row.track_id == ids.edit_v1 then return row end
    end
    error("no V clip found among created ids")
end

local function a_clip(db, ids, created_ids)
    for _, cid in ipairs(created_ids) do
        local row = load_clip_row(db, cid)
        if row.track_id == ids.edit_a1 then return row end
    end
    error("no A clip found among created ids")
end

print("=== test_place_shared_source_in_is_tc.lua ===")

-- ── T1: no marks → source_in == tc_origin (not 0) ───────────────────────
print("-- T1: no marks → V/A source_in == tc_origin")
do
    local ids = build_fixture()
    local result = Insert.execute({
        sequence_id          = ids.edit_id,
        source_sequence_id   = ids.master_id,
        timeline_start_frame = 1000,
    })
    local db = database.get_connection()
    local v = v_clip(db, ids, result.created_clip_ids)
    local a = a_clip(db, ids, result.created_clip_ids)

    assert(v.source_in_frame == TC_ORIGIN, string.format(
        "T1: V clip source_in_frame must equal tc_origin %d, got %d",
        TC_ORIGIN, v.source_in_frame))
    assert(v.source_out_frame == TC_ORIGIN + MEDIA_DUR, string.format(
        "T1: V clip source_out_frame must equal tc_origin+span %d, got %d",
        TC_ORIGIN + MEDIA_DUR, v.source_out_frame))

    assert(a.source_in_frame == TC_ORIGIN, string.format(
        "T1: A clip source_in_frame must equal tc_origin %d (same absolute "
        .. "TC as V — master.fps timebase, NOT samples), got %d",
        TC_ORIGIN, a.source_in_frame))
    assert(a.source_out_frame == TC_ORIGIN + MEDIA_DUR, string.format(
        "T1: A clip source_out_frame must equal tc_origin+span %d, got %d",
        TC_ORIGIN + MEDIA_DUR, a.source_out_frame))
end

-- ── T2: marks set → source_in == mark_in (absolute TC, not file-relative) ─
print("-- T2: marks set → V/A source_in == mark_in")
do
    local ids = build_fixture()
    local mark_in  = TC_ORIGIN + 176     -- matches the TSO repro offset
    local mark_out = TC_ORIGIN + 697     -- 521-frame span

    local db = database.get_connection()
    exec(db, string.format(
        "UPDATE sequences SET mark_in_frame=%d, mark_out_frame=%d WHERE id='m'",
        mark_in, mark_out))

    local result = Insert.execute({
        sequence_id          = ids.edit_id,
        source_sequence_id   = ids.master_id,
        timeline_start_frame = 2000,
    })
    local v = v_clip(db, ids, result.created_clip_ids)
    local a = a_clip(db, ids, result.created_clip_ids)

    assert(v.source_in_frame == mark_in, string.format(
        "T2: V source_in_frame must equal mark_in %d (absolute TC), got %d "
        .. "(pre-fix bug returned %d = mark_in - tc_origin)",
        mark_in, v.source_in_frame, mark_in - TC_ORIGIN))
    assert(v.source_out_frame == mark_out, string.format(
        "T2: V source_out_frame must equal mark_out %d, got %d",
        mark_out, v.source_out_frame))

    -- AUDIO source_in MUST be the same absolute TC value as VIDEO —
    -- master.fps timebase (= video frames for mixed media). The resolver
    -- (Sequence.resolve_master_leaf) converts to file-native samples
    -- internally using audio_sample_rate * fps_den / fps_num.
    assert(a.source_in_frame == mark_in, string.format(
        "T3: A source_in_frame must equal mark_in %d (master.fps frames, "
        .. "NOT samples), got %d. Pre-fix bug pre-converted to "
        .. "%d samples; that's the resolver's job, not the writer's.",
        mark_in, a.source_in_frame,
        math.floor((mark_in - TC_ORIGIN)
            * 48000 * EDIT_FPS_DEN / EDIT_FPS_NUM + 0.5)))
    assert(a.source_out_frame == mark_out, string.format(
        "T3: A source_out_frame must equal mark_out %d, got %d",
        mark_out, a.source_out_frame))
end

print("\n✅ test_place_shared_source_in_is_tc.lua passed")
