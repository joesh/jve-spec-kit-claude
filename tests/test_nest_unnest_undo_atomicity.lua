-- T067b (013): Nest + Unnest undo atomicity.
--
-- Per FR-020 commentary in commands.md: per-override commands produce
-- one undo step EACH; structural multi-row commands (Insert/Overwrite/
-- Nest/Unnest) reverse the entire mutation set in one undo. This test
-- pins down the structural side: a single Nest.undo / Unnest.undo
-- restores the full pre-state.
--
-- Also covers T067a (orphan-delete observability) via the Unnest case:
-- when Unnest orphan-deletes the nested sequence, undo must resurrect
-- it (row + tracks) — observable via Sequence.find / track count.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_nest_unnest_undo_atomicity.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_three_clip_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c1', 'p1', 'e', 'e-v1', 'm', 'c1',
                100, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0),
               ('c2', 'p1', 'e', 'e-v1', 'm', 'c2',
                200, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0),
               ('c3', 'p1', 'e', 'e-v1', 'm', 'c3',
                300, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function snapshot_clips_in(db, seq_id)
    local stmt = db:prepare([[
        SELECT id, track_id, timeline_start_frame, duration_frames
        FROM clips WHERE owner_sequence_id = ?
        ORDER BY timeline_start_frame ASC, id ASC
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            timeline_start = stmt:value(2),
            duration = stmt:value(3),
        }
    end
    stmt:finalize()
    return rows
end

local function snapshots_equal(a, b)
    if #a ~= #b then return false, string.format("length %d vs %d", #a, #b) end
    for i = 1, #a do
        if a[i].id ~= b[i].id
           or a[i].track_id ~= b[i].track_id
           or a[i].timeline_start ~= b[i].timeline_start
           or a[i].duration ~= b[i].duration then
            return false, string.format("row %d differs", i)
        end
    end
    return true
end

local function sequence_exists(db, id)
    local stmt = db:prepare("SELECT 1 FROM sequences WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec())
    local found = stmt:next()
    stmt:finalize()
    return found
end

local Nest   = require("core.commands.nest")
local Unnest = require("core.commands.unnest")

print("-- Nest.undo restores parent + deletes new sequence atomically --")
do
    local db = build_three_clip_fixture()
    local pre = snapshot_clips_in(db, "e")
    assert(#pre == 3)

    local cap = Nest.execute({
        sequence_id        = "e",
        selected_clip_ids  = { "c1", "c2", "c3" },
    })
    -- Sanity: parent has the replacement; new sequence has 3.
    assert(#snapshot_clips_in(db, "e") == 1)
    assert(#snapshot_clips_in(db, cap.new_sequence_id) == 3)
    assert(sequence_exists(db, cap.new_sequence_id))

    Nest.undo(cap)

    local post = snapshot_clips_in(db, "e")
    local ok, err = snapshots_equal(pre, post)
    assert(ok, "Nest.undo must restore parent state exactly: " .. tostring(err))
    assert(not sequence_exists(db, cap.new_sequence_id),
        "Nest.undo must delete the sequence Nest.execute created")
    print("  ok")
end

print("-- Unnest.undo restores parent, resurrects nested sequence + clips --")
do
    local db = build_three_clip_fixture()
    -- Nest first to set up an unnested-able clip.
    local nest_cap = Nest.execute({
        sequence_id        = "e",
        selected_clip_ids  = { "c1", "c2", "c3" },
    })
    local pre_parent = snapshot_clips_in(db, "e")
    local pre_nested = snapshot_clips_in(db, nest_cap.new_sequence_id)
    assert(#pre_parent == 1 and #pre_nested == 3)

    local unnest_cap = Unnest.execute({
        sequence_id = "e",
        clip_id     = nest_cap.new_clip_id,
    })
    -- Sanity: parent now has 3 clips; nested orphan-deleted.
    assert(#snapshot_clips_in(db, "e") == 3)
    assert(unnest_cap.orphan_deleted == true)
    assert(not sequence_exists(db, nest_cap.new_sequence_id),
        "nested sequence orphan-deleted by Unnest")

    Unnest.undo(unnest_cap)

    -- Parent restored to its post-Nest state (one replacement clip).
    local post_parent = snapshot_clips_in(db, "e")
    local ok1, err1 = snapshots_equal(pre_parent, post_parent)
    assert(ok1, "Unnest.undo: parent state restored: " .. tostring(err1))

    -- Nested sequence resurrected.
    assert(sequence_exists(db, nest_cap.new_sequence_id),
        "Unnest.undo must resurrect the orphan-deleted nested sequence")
    local post_nested = snapshot_clips_in(db, nest_cap.new_sequence_id)
    local ok2, err2 = snapshots_equal(pre_nested, post_nested)
    assert(ok2, "Unnest.undo: nested clips restored: " .. tostring(err2))
    print("  ok")
end

print("-- Nest then Unnest then both undos: three-step round trip --")
do
    local db = build_three_clip_fixture()
    local pre = snapshot_clips_in(db, "e")

    local nest_cap = Nest.execute({
        sequence_id        = "e",
        selected_clip_ids  = { "c1", "c2", "c3" },
    })
    local unnest_cap = Unnest.execute({
        sequence_id = "e",
        clip_id     = nest_cap.new_clip_id,
    })
    -- Note: after Unnest, the Nest.execute's new sequence is gone (orphaned).
    -- The natural undo order is Unnest.undo, then... Nest.undo wants its
    -- new sequence + clips back where Unnest left them. But Unnest.undo
    -- will restore that state. Let's verify.
    Unnest.undo(unnest_cap)
    Nest.undo(nest_cap)

    local post = snapshot_clips_in(db, "e")
    local ok, err = snapshots_equal(pre, post)
    assert(ok, "Round-trip Nest+Unnest+undo+undo: " .. tostring(err))
    print("  ok")
end

print("✅ test_nest_unnest_undo_atomicity.lua passed")
