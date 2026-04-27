-- T037 (013): CT-C8 Duplicate copies per-clip overrides.
--
-- Duplicate creates a new clips row with the same shape, shifted by
-- delta_frames on the same or a different track. Per commands.md §Duplicate:
--   - master_layer_track_id, fps_mismatch_policy, source_in/out, duration,
--     enabled, volume, etc. are copied verbatim
--   - all clip_channel_override rows are cloned to the new clip_id
--   - timeline_start_frame = original.timeline_start_frame + delta_frames
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_duplicate_copies_overrides.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-v2', 'm', 'V2', 'VIDEO', 2),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-v2', 'e', 'V2', 'VIDEO', 2);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function seed_clip(db, clip_id, master_layer)
    local master_val = master_layer and ("'" .. master_layer .. "'") or "NULL"
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('%s', 'p1', 'e', 'e-v1', 'm', '%s',
            100, 50, 200, 250,
            %s, 'resample',
            1, 0.75, 0, 0, 0)
    ]], clip_id, clip_id, master_val)))
end

local function seed_override(db, clip_id, channel, enabled, gain_db)
    assert(db:exec(string.format([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('%s', %d, %d, %f)
    ]], clip_id, channel, enabled and 1 or 0, gain_db)))
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               master_layer_track_id, fps_mismatch_policy,
               enabled, volume, track_id, owner_sequence_id, nested_sequence_id
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. id)
    local r = {
        timeline_start = stmt:value(0),
        duration       = stmt:value(1),
        source_in      = stmt:value(2),
        source_out     = stmt:value(3),
        master_layer   = stmt:value(4),
        policy         = stmt:value(5),
        enabled        = stmt:value(6) == 1,
        volume         = stmt:value(7),
        track_id       = stmt:value(8),
        owner_seq_id   = stmt:value(9),
        nested_seq_id  = stmt:value(10),
    }
    stmt:finalize()
    return r
end

local function load_overrides(db, clip_id)
    local stmt = db:prepare([[
        SELECT channel_index, enabled, gain_db
        FROM clip_channel_override WHERE clip_id = ?
        ORDER BY channel_index ASC
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            channel_index = stmt:value(0),
            enabled       = stmt:value(1) == 1,
            gain_db       = stmt:value(2),
        }
    end
    stmt:finalize()
    return rows
end

local Duplicate = require("core.commands.duplicate")
assert(type(Duplicate.execute) == "function",
    "T047 not landed: core.commands.duplicate must export .execute")

-- -------------------------------------------------------------------------
-- CT-C8: duplicate of a clip with 3 overrides yields a new clip with 3
-- matching override rows AND copies master_layer_track_id + policy.
-- Original sits at [100,150) on e-v1. Duplicate to e-v2 with delta=200.
-- -------------------------------------------------------------------------
print("-- CT-C8 Duplicate copies master_layer_track_id + policy + overrides --")
do
    local db = build_fixture()
    seed_clip(db, "c", "m-v2")
    seed_override(db, "c", 0, true,  -3.0)
    seed_override(db, "c", 1, false,  0.0)
    seed_override(db, "c", 2, true,  -6.0)

    local result = Duplicate.execute({
        sequence_id     = "e",
        clip_id         = "c",
        target_track_id = "e-v2",
        delta_frames    = 200,
    })
    assert(type(result) == "table" and result.new_clip_id,
        "Duplicate must return new_clip_id")
    local new_id = result.new_clip_id
    assert(new_id ~= "c", "duplicate must produce a fresh id")

    local orig = load_clip(db, "c")
    local new  = load_clip(db, new_id)

    -- Original untouched.
    assert(orig.timeline_start == 100 and orig.duration == 50
           and orig.source_in == 200 and orig.source_out == 250,
        "original clip must not be modified by Duplicate")
    assert(orig.master_layer == "m-v2" and orig.policy == "resample",
        "original structural fields must not be modified")

    -- New clip: shifted by +200 on the target track.
    assert(new.timeline_start == 300 and new.duration == 50,
        string.format("expected duplicate at [300,350); got [%d,%d)",
            new.timeline_start, new.timeline_start + new.duration))
    assert(new.track_id == "e-v2", "duplicate must land on target_track_id")
    assert(new.owner_seq_id == "e" and new.nested_seq_id == "m",
        "duplicate must preserve owner+nested sequences")

    -- Source window copied verbatim.
    assert(new.source_in == 200 and new.source_out == 250,
        "source window must be copied verbatim")

    -- Structural overrides preserved.
    assert(new.master_layer == "m-v2", "master_layer_track_id must copy")
    assert(new.policy == "resample",   "fps_mismatch_policy must copy")
    assert(new.enabled == true and math.abs(new.volume - 0.75) < 1e-9,
        "enabled/volume must copy")

    -- Channel override rows.
    local orig_ovs = load_overrides(db, "c")
    local new_ovs  = load_overrides(db, new_id)
    assert(#orig_ovs == 3 and #new_ovs == 3, string.format(
        "both clips must have 3 overrides; orig=%d new=%d",
        #orig_ovs, #new_ovs))
    for i = 1, 3 do
        assert(orig_ovs[i].channel_index == new_ovs[i].channel_index
               and orig_ovs[i].enabled == new_ovs[i].enabled
               and orig_ovs[i].gain_db == new_ovs[i].gain_db,
            string.format("override[%d] mismatch between original and duplicate", i))
    end
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Duplicate at delta=0 onto the SAME track must refuse: it would create
-- two clips with the same [timeline_start, duration), tripping the video
-- overlap trigger. Refusal is loud; DB unchanged.
-- -------------------------------------------------------------------------
print("-- Duplicate at delta=0 on same track refuses --")
do
    local db = build_fixture()
    seed_clip(db, "c", nil)
    local ok = pcall(Duplicate.execute, {
        sequence_id     = "e",
        clip_id         = "c",
        target_track_id = "e-v1",
        delta_frames    = 0,
    })
    assert(not ok, "delta=0 onto same track must refuse (overlap)")
    -- DB unchanged: still exactly one clip on e.
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'e'")
    stmt:exec(); stmt:next()
    local n = stmt:value(0); stmt:finalize()
    assert(n == 1, string.format("expected 1 clip after refused dup; got %d", n))
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Duplicate with no overrides: still copies structural fields, zero
-- override rows on either side.
-- -------------------------------------------------------------------------
print("-- Duplicate of clip with no overrides --")
do
    local db = build_fixture()
    seed_clip(db, "c", nil)
    local result = Duplicate.execute({
        sequence_id     = "e",
        clip_id         = "c",
        target_track_id = "e-v1",
        delta_frames    = 100,
    })
    local new_ovs = load_overrides(db, result.new_clip_id)
    assert(#new_ovs == 0, "no overrides on either side")
    local new = load_clip(db, result.new_clip_id)
    assert(new.timeline_start == 200 and new.duration == 50,
        "duplicate at +100 lands at [200,250)")
    print("  ok")
end

print("✅ test_013_duplicate_copies_overrides.lua passed")
