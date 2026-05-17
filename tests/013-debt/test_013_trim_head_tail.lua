-- T034 (013): CT-C3 TrimHead + TrimTail contract test.
--
-- TrimHead advances the start of what a clip shows by N owner frames:
-- sequence_start moves forward by N, duration shrinks by N, source_in
-- advances by the policy-appropriate source delta, source_out unchanged.
-- TrimTail is the mirror: sequence_start unchanged, duration shrinks by
-- N, source_out retreats, source_in unchanged. Per commands.md §Trim
-- the arithmetic "shifts in/out by N frames" — under the clip's own
-- fps_mismatch_policy, so resample scales and passthrough is 1:1.
--
-- INV-4 (window in bounds) is checked post-write by Clip.update; a trim
-- that would leave an empty/inverted window is refused.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_trim_head_tail.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Project + master with 1000-frame V media_ref + edit sequence.
local function build_fixture(owner_fps_num, nested_fps_num)
    local db = fresh_db()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', %d, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', %d, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 1000, %d, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 1000, 0, 1000,
            1, 1.0, 0, 0, 0);
    ]], nested_fps_num, owner_fps_num, nested_fps_num)))
    return db
end

local function seed_clip(db, clip_id, policy,
                       sequence_start, duration, source_in, source_out)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', 'p1', 'e', 'e-v1', 'm', '%s', %d, %d, %d, %d,
            '%s', 1, 1.0, 0, 0, 0)
    ]], clip_id, clip_id, sequence_start, duration, source_in, source_out,
       policy)))
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "load_clip: not found: " .. id)
    local r = {
        sequence_start = stmt:value(0),
        duration       = stmt:value(1),
        source_in      = stmt:value(2),
        source_out     = stmt:value(3),
    }
    stmt:finalize()
    return r
end

local TrimHead = require("core.commands.trim_head")
local TrimTail = require("core.commands.trim_tail")
assert(type(TrimHead.execute) == "function",
    "T043 not yet landed: core.commands.trim_head must export .execute")
assert(type(TrimTail.execute) == "function",
    "T043 not yet landed: core.commands.trim_tail must export .execute")

-- CT-C3 baseline (matching fps, passthrough).
print("-- CT-C3: TrimHead by 10 --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", 100, 100, 0, 100)
    TrimHead.execute({
        sequence_id = "e", clip_id = "c", trim_amount_frames = 10,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 110 and c.duration == 90 and
           c.source_in == 10 and c.source_out == 100,
        string.format("expected [tl=110,d=90,s=(10,100)]; got [tl=%d,d=%d,s=(%d,%d)]",
            c.sequence_start, c.duration, c.source_in, c.source_out))
    print("  ok")
end

-- TrimTail mirror.
print("-- TrimTail by 10: shrink from the right --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", 100, 100, 0, 100)
    TrimTail.execute({
        sequence_id = "e", clip_id = "c", trim_amount_frames = 10,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 100 and c.duration == 90 and
           c.source_in == 0 and c.source_out == 90,
        string.format("expected [tl=100,d=90,s=(0,90)]; got [tl=%d,d=%d,s=(%d,%d)]",
            c.sequence_start, c.duration, c.source_in, c.source_out))
    print("  ok")
end

-- Non-trivial values.
print("-- TrimHead 25 on clip with offset source --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", 200, 100, 50, 150)
    TrimHead.execute({
        sequence_id = "e", clip_id = "c", trim_amount_frames = 25,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 225 and c.duration == 75 and
           c.source_in == 75 and c.source_out == 150,
        string.format("expected [tl=225,d=75,s=(75,150)]; got [tl=%d,d=%d,s=(%d,%d)]",
            c.sequence_start, c.duration, c.source_in, c.source_out))
    print("  ok")
end

-- Resample: 25fps nested inside 24fps owner. 24 owner frames → 25 nested.
print("-- TrimHead 24 under resample (25fps nested in 24fps owner) --")
do
    local db = build_fixture(24, 25)
    seed_clip(db, "c", "resample", 0, 96, 0, 100)
    TrimHead.execute({
        sequence_id = "e", clip_id = "c", trim_amount_frames = 24,
    })
    local c = load_clip(db, "c")
    assert(c.sequence_start == 24 and c.duration == 72, string.format(
        "expected [tl=24,d=72]; got [tl=%d,d=%d]",
        c.sequence_start, c.duration))
    assert(c.source_in == 25 and c.source_out == 100, string.format(
        "expected source [25,100); got [%d,%d)", c.source_in, c.source_out))
    print("  ok")
end

-- Error: trim amount >= duration. Loud refuse, DB unchanged.
print("-- TrimHead by full duration refuses --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", 100, 50, 0, 50)
    local before = load_clip(db, "c")
    local ok = pcall(TrimHead.execute, {
        sequence_id = "e", clip_id = "c", trim_amount_frames = 50,
    })
    assert(not ok, "trim by full duration should have errored")
    local after = load_clip(db, "c")
    assert(after.sequence_start == before.sequence_start
           and after.duration == before.duration
           and after.source_in == before.source_in
           and after.source_out == before.source_out,
        "DB state must be unchanged after a refused trim")
    print("  ok")
end

-- Error: non-positive amount refuses.
print("-- TrimTail by 0 or negative refuses --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", 100, 50, 0, 50)
    for _, amount in ipairs({ 0, -5 }) do
        local ok = pcall(TrimTail.execute, {
            sequence_id = "e", clip_id = "c", trim_amount_frames = amount,
        })
        assert(not ok, string.format(
            "trim amount %d must refuse (non-positive)", amount))
    end
    print("  ok")
end

-- Error: trim that would collapse source window.
print("-- TrimHead that collapses source window refuses --")
do
    local db = build_fixture(24, 24)
    seed_clip(db, "c", "passthrough", 100, 10, 90, 100)
    local ok = pcall(TrimHead.execute, {
        sequence_id = "e", clip_id = "c", trim_amount_frames = 10,
    })
    assert(not ok, "collapsing-window trim must refuse")
    local c = load_clip(db, "c")
    assert(c.sequence_start == 100 and c.duration == 10
           and c.source_in == 90 and c.source_out == 100,
        "DB unchanged after refused collapse-trim")
    print("  ok")
end

print("✅ test_013_trim_head_tail.lua passed")
