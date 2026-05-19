-- 018 T041 / FR-036b: SetProjectMasterClock changes
-- projects.settings.master_clock_hz AND atomically rescales every audio
-- clip's source_*_subframe so wall-clock content is preserved. Sequence
-- fps values are unchanged. Direct UPDATEs to settings that change
-- master_clock_hz are blocked by INV-6.
--
-- Expected to FAIL until T044 lands.

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_set_project_master_clock.db"

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
        VALUES ('m', 'p', 'M', 'master',  24, 1, NULL,  1920, 1080, %d, %d),
               ('e', 'p', 'E', 'sequence',24, 1, 48000, 1920, 1080, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
            created_at, modified_at)
        VALUES ('med', 'p', 'a.mov', '/tmp/a.mov', 480, 24, 1, 1, 48000, %d, %d);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mref-a', 'p', 'm', 'm-a1', 'med', 0, 960000, 0, 960000,
                48000, 1, 1.0, 0, %d, %d);
        -- THREE audio clips: "near-edge" 7996 (safely scales to 1999),
        -- mid-range 3500, and STRICT-edge 7999 (the max legal subframe at
        -- old tpf=8000). Plus a video clip with NULL subframes.
        -- At master_clock_hz=192000, fps=24/1: tpf = 192000/24 = 8000.
        --
        -- Strict-edge case pins floor-this-step semantics: rhaz scaling
        -- of 7999 to 48k yields rhaz(1999.75)=2000=new_tpf which would
        -- violate INV-4 (sub < tpf). The command floors the result to
        -- new_tpf-1=1999 in this case, losing ≤½ master-clock tick on
        -- this one boundary per scale. Frames stay untouched. See
        -- spec contract for SetProjectMasterClock.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
            name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('a-edge', 'p', 'e', 'e-a1', 'm', 'AEdge',
                0, 10, 0, 10, 7996, 7996,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, %d, %d),
               ('a-mid',  'p', 'e', 'e-a1', 'm', 'AMid',
                20, 10, 20, 30, 3500, 6000,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, %d, %d),
               ('a-strict','p', 'e', 'e-a1', 'm', 'AStrict',
                40, 10, 40, 50, 7999, 7999,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, %d, %d),
               ('v-only', 'p', 'e', 'e-v1', 'm', 'VOnly',
                0, 10, 0, 10, NULL, NULL,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, %d, %d);
    ]], now, now, now, now, now, now, now, now, now, now, now, now, now, now, now, now, now, now)))
    command_manager.init('e', 'p')
    return db
end

local function read_mch(db)
    local s = db:prepare("SELECT json_extract(settings, '$.master_clock_hz') FROM projects WHERE id = 'p'")
    assert(s:exec() and s:next())
    local v = s:value(0)
    s:finalize()
    return v
end

local function read_clip_subs(db, id)
    local s = db:prepare(
        "SELECT source_in_subframe, source_out_subframe FROM clips WHERE id = ?")
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local i, o = s:value(0), s:value(1)
    s:finalize()
    return i, o
end

local function read_clip_frames(db, id)
    local s = db:prepare(
        "SELECT source_in_frame, source_out_frame FROM clips WHERE id = ?")
    s:bind_value(1, id)
    assert(s:exec() and s:next())
    local i, o = s:value(0), s:value(1)
    s:finalize()
    return i, o
end

-- Case 1: scale 192000 → 48000 (1/4); audio subframes scale; video untouched.
print("-- happy: scale 192k → 48k, audio subs scale 1/4, video untouched --")
do
    local db = fresh()
    assert(read_mch(db) == 192000, "test setup mch")
    local edge_in_pre, edge_out_pre     = read_clip_subs(db, "a-edge")   -- 7996, 7996
    local mid_in_pre,  mid_out_pre      = read_clip_subs(db, "a-mid")    --  3500, 6000
    local strict_in_pre, strict_out_pre = read_clip_subs(db, "a-strict") -- 7999, 7999
    assert(edge_in_pre == 7996 and edge_out_pre == 7996, "test setup near-edge subs")
    assert(mid_in_pre == 3500 and mid_out_pre == 6000, "test setup mid subs")
    assert(strict_in_pre == 7999 and strict_out_pre == 7999, "test setup strict-edge subs")

    local r = command_manager.execute("SetProjectMasterClock", {
        project_id      = "p",
        master_clock_hz = 48000,
    })
    assert(r and r.success, "SetProjectMasterClock: " .. tostring(r and r.error_message))

    assert(read_mch(db) == 48000, "master_clock_hz must be 48000")

    -- 1/4 scale: rhaz(7996*48000/192000) = rhaz(1999.0) = 1999.
    local edge_in_post, edge_out_post = read_clip_subs(db, "a-edge")
    assert(edge_in_post == 1999 and edge_out_post == 1999, string.format(
        "near-edge subs must rescale to 1999; got in=%s out=%s",
        tostring(edge_in_post), tostring(edge_out_post)))

    -- rhaz(3500*48000/192000) = rhaz(875) = 875.
    -- rhaz(6000*48000/192000) = rhaz(1500) = 1500.
    local mid_in_post, mid_out_post = read_clip_subs(db, "a-mid")
    assert(mid_in_post == 875 and mid_out_post == 1500, string.format(
        "mid subs must rescale to (875, 1500); got (%s, %s)",
        tostring(mid_in_post), tostring(mid_out_post)))

    -- Strict-edge floor: rhaz(7999*48000/192000) = rhaz(1999.75) = 2000
    -- which would equal new_tpf (8000/4=2000). INV-4 demands sub < tpf,
    -- so the command floors the result to new_tpf-1=1999. Precision loss
    -- is ≤½ master-clock tick (~2.6μs at 192kHz); frames stay untouched.
    local strict_in_post, strict_out_post = read_clip_subs(db, "a-strict")
    assert(strict_in_post == 1999 and strict_out_post == 1999, string.format(
        "strict-edge subs must floor to new_tpf-1=1999; got (%s, %s)",
        tostring(strict_in_post), tostring(strict_out_post)))

    -- Video clip's NULL subframes stay NULL; frames untouched.
    local v_in_sub, v_out_sub = read_clip_subs(db, "v-only")
    assert(v_in_sub == nil and v_out_sub == nil, "video subs must remain NULL")
    local v_in_f, v_out_f = read_clip_frames(db, "v-only")
    assert(v_in_f == 0 and v_out_f == 10, "video frames untouched")

    -- Audio frame columns untouched on the audio clips too.
    local ef_in, ef_out = read_clip_frames(db, "a-edge")
    assert(ef_in == 0  and ef_out == 10, "audio edge frames untouched")
    local mf_in, mf_out = read_clip_frames(db, "a-mid")
    assert(mf_in == 20 and mf_out == 30, "audio mid frames untouched")

    -- Sequence fps untouched.
    local s = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = 'e'")
    assert(s:exec() and s:next())
    local n, d = s:value(0), s:value(1); s:finalize()
    assert(n == 24 and d == 1, "edit fps untouched")

    print("  ok")
end

-- Case 2: undo restores subs + clock exactly.
print("-- undo restores subs + clock exactly --")
do
    local db = fresh()
    local r = command_manager.execute("SetProjectMasterClock", {
        project_id = "p", master_clock_hz = 96000,
    })
    assert(r and r.success, "execute")
    assert(command_manager.undo(), "undo")
    assert(read_mch(db) == 192000, "mch restored")
    local ei, eo = read_clip_subs(db, "a-edge")
    assert(ei == 7996 and eo == 7996, "near-edge subs restored exactly")
    local mi, mo = read_clip_subs(db, "a-mid")
    assert(mi == 3500 and mo == 6000, "mid subs restored exactly")

    assert(command_manager.redo(), "redo")
    assert(read_mch(db) == 96000, "redo re-applies 96k")
    print("  ok")
end

-- Case 3: no-op rejected.
print("-- no-op rejected --")
do
    fresh()
    local refused
    local ok = pcall(function()
        local r = command_manager.execute("SetProjectMasterClock", {
            project_id = "p", master_clock_hz = 192000,
        })
        refused = type(r) == "table" and r.success == false
    end)
    if not ok then refused = true end
    assert(refused, "no-op (new == current) must be refused")
    print("  ok")
end

-- Case 4: INV-6 blocks direct settings UPDATE that changes mch.
print("-- INV-6 blocks direct mch UPDATE --")
do
    local db = fresh()
    local ok = pcall(function()
        local upd = db:prepare(
            "UPDATE projects SET settings = '{\"master_clock_hz\":48000,\"default_fps\":{\"num\":24,\"den\":1}}' WHERE id = 'p'")
        assert(upd:exec(), "direct UPDATE should refuse via trigger ABORT")
        upd:finalize()
    end)
    assert(not ok, "INV-6 trigger must abort direct UPDATE that changes master_clock_hz")
    -- And mch is untouched.
    assert(read_mch(db) == 192000, "mch unchanged after refused direct UPDATE")
    print("  ok")
end

print("✅ test_set_project_master_clock.lua passed")
