-- 018 T040 / FR-036a: SetProjectDefaultFps changes projects.settings.default_fps
-- ONLY. No cascade to existing sequences/media_refs/clips. Undoable.
--
-- Expected to FAIL until T043 lands.

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_set_project_default_fps.db"

local function fresh()
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
        VALUES ('m',  'p', 'M',  'master',   24, 1, NULL,  1920, 1080, %d, %d),
               ('s1', 'p', 'S1', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d),
               ('s2', 'p', 'S2', 'sequence', 25, 1, 44100, 1920, 1080, %d, %d);
        -- A track + media + media_ref + clip on the master so the
        -- "no cascade" invariant has real rows to check (NSF Half 2).
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('s1-a1', 's1', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
            created_at, modified_at)
        VALUES ('med', 'p', 'a.wav', '/tmp/a.wav', 48000, 24, 1, 1, 48000, %d, %d);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mref', 'p', 'm', 'm-a1', 'med', 0, 48000, 0, 48000,
                48000, 1, 1.0, 0, %d, %d);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
            name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c1', 'p', 's1', 's1-a1', 'm', 'C1',
                7, 50, 10, 60, 1234, 5678,
                NULL, NULL, 'passthrough',
                1, 0.8, 3, %d, %d);
    ]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)))
    command_manager.init('s1', 'p')
    return db
end

local function read_default_fps(db)
    local s = db:prepare(
        "SELECT json_extract(settings, '$.default_fps.num'), "
        .. "json_extract(settings, '$.default_fps.den') FROM projects WHERE id = 'p'")
    assert(s:exec() and s:next())
    local n, d = s:value(0), s:value(1)
    s:finalize()
    return n, d
end

local function read_seq_fps(db, id)
    local s = db:prepare(
        "SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local n, d = s:value(0), s:value(1)
    s:finalize()
    return n, d
end

-- Half 2 helpers: capture full clip + media_ref state so we can compare
-- pre/post and prove "no cascade" by row-identity rather than vacuously.
local function snapshot_clip(db, id)
    local s = db:prepare([[
        SELECT sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               source_in_subframe, source_out_subframe,
               fps_mismatch_policy, enabled, volume, playhead_frame
        FROM clips WHERE id = ?
    ]])
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local t = {
        seq_start = s:value(0), dur = s:value(1),
        src_in    = s:value(2), src_out = s:value(3),
        sub_in    = s:value(4), sub_out = s:value(5),
        policy    = s:value(6), enabled = s:value(7),
        volume    = s:value(8), playhead = s:value(9),
    }
    s:finalize()
    return t
end
local function snapshot_mref(db, id)
    local s = db:prepare([[
        SELECT source_in_frame, source_out_frame,
               sequence_start_frame, duration_frames, audio_sample_rate
        FROM media_refs WHERE id = ?
    ]])
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local t = {
        src_in = s:value(0), src_out = s:value(1),
        seq_start = s:value(2), dur = s:value(3),
        rate = s:value(4),
    }
    s:finalize()
    return t
end
local function eq_snapshot(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then return false, k, v, b[k] end
    end
    return true
end

-- Case 1: happy path — change default_fps; existing sequences/media_refs/clips untouched.
print("-- happy path: default_fps changes, no cascade --")
do
    local db = fresh()
    local n0, d0 = read_default_fps(db)
    assert(n0 == 24 and d0 == 1, "test setup: default_fps should be 24/1")

    -- Half 2 baseline snapshots.
    local clip_pre  = snapshot_clip(db, "c1")
    local mref_pre  = snapshot_mref(db, "mref")

    local r = command_manager.execute("SetProjectDefaultFps", {
        project_id      = "p",
        fps_numerator   = 30,
        fps_denominator = 1,
    })
    assert(r and r.success, "SetProjectDefaultFps: " .. tostring(r and r.error_message))

    local n1, d1 = read_default_fps(db)
    assert(n1 == 30 and d1 == 1, string.format(
        "default_fps must be 30/1; got %s/%s", tostring(n1), tostring(d1)))

    -- Sequences unchanged.
    for _, row in ipairs({{"m",24,1}, {"s1",30,1}, {"s2",25,1}}) do
        local n, d = read_seq_fps(db, row[1])
        assert(n == row[2] and d == row[3], string.format(
            "sequence %s fps must be unchanged (%d/%d); got %s/%s",
            row[1], row[2], row[3], tostring(n), tostring(d)))
    end

    -- Half 2: clip + media_ref bit-identical pre/post.
    local clip_post = snapshot_clip(db, "c1")
    local ok_c, k_c, want_c, got_c = eq_snapshot(clip_pre, clip_post)
    assert(ok_c, string.format(
        "clip c1 column %s changed: was %s, now %s — SetProjectDefaultFps "
        .. "must not cascade",
        tostring(k_c), tostring(want_c), tostring(got_c)))
    local mref_post = snapshot_mref(db, "mref")
    local ok_m, k_m, want_m, got_m = eq_snapshot(mref_pre, mref_post)
    assert(ok_m, string.format(
        "media_ref mref column %s changed: was %s, now %s",
        tostring(k_m), tostring(want_m), tostring(got_m)))
    print("  ok")
end

-- Case 2: undo restores prior default_fps.
print("-- undo: prior default_fps restored --")
do
    local db = fresh()
    local r = command_manager.execute("SetProjectDefaultFps", {
        project_id      = "p",
        fps_numerator   = 60,
        fps_denominator = 1,
    })
    assert(r and r.success, "execute must succeed")
    assert(command_manager.undo(), "undo failed")
    local n, d = read_default_fps(db)
    assert(n == 24 and d == 1, string.format(
        "undo must restore 24/1; got %s/%s", tostring(n), tostring(d)))
    -- Redo re-applies.
    assert(command_manager.redo(), "redo failed")
    local rn, rd = read_default_fps(db)
    assert(rn == 60 and rd == 1, "redo must re-apply 60/1")
    print("  ok")
end

-- Case 3: no-op rejection (new equals current).
print("-- no-op rejected --")
do
    fresh()
    local refused
    local ok, _err = pcall(function()
        local r = command_manager.execute("SetProjectDefaultFps", {
            project_id      = "p",
            fps_numerator   = 24,
            fps_denominator = 1,
        })
        if r and r.success == false then refused = true; return end
        refused = false
    end)
    if not ok then refused = true end
    assert(refused, "SetProjectDefaultFps must refuse no-op (new == current)")
    print("  ok")
end

-- Case 4: invalid inputs each rejected (zero / negative / no-op direction).
print("-- invalid fps rejected --")
local function refused_for(args)
    fresh()
    local result
    local ok = pcall(function()
        result = command_manager.execute("SetProjectDefaultFps", args)
    end)
    if not ok then return true end
    return type(result) == "table" and result.success == false
end
do
    assert(refused_for({ project_id = "p", fps_numerator = 0,  fps_denominator = 1 }),
        "zero numerator must be refused")
    assert(refused_for({ project_id = "p", fps_numerator = 24, fps_denominator = 0 }),
        "zero denominator must be refused")
    assert(refused_for({ project_id = "p", fps_numerator = -30, fps_denominator = 1 }),
        "negative numerator must be refused")
    print("  ok")
end

print("✅ test_set_project_default_fps.lua passed")
