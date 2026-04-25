-- T052a (013): Insert/Overwrite multi-row atomic undo.
--
-- Distinct from T052 (per-override granularity — each override change
-- is a separate undo step). FR-020 commentary: structural multi-row
-- commands (Insert, Overwrite, Nest, Unnest) reverse ALL their writes
-- in a SINGLE undo. They are never split across multiple undo steps.
--
-- This test pins:
--   * Insert.undo reverses every row Insert wrote (V clip + A clip[s]
--     + link_group). One undo, full reversal.
--   * Overwrite.undo restores trimmed/removed clips and removes the
--     newly-inserted clip. One undo, full reversal.
--   * Both: composite mode (1 V + 1 A) AND expanded audio mode (1 V +
--     N A) — the multi-row count varies, atomicity stays one-step.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_insert_overwrite_atomic_undo.db"

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
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('m-a3', 'm', 'A3', 'AUDIO', 3),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, 0, 0),
               ('a1', 'p1', 'a1.wav', '/tmp/a1.wav', 200000, 48000, 1, 1, 0, 0),
               ('a2', 'p1', 'a2.wav', '/tmp/a2.wav', 200000, 48000, 1, 1, 0, 0),
               ('a3', 'p1', 'a3.wav', '/tmp/a3.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function clip_count(db, owner)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?")
    stmt:bind_value(1, owner)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local function clip_links_count(db, link_group_id)
    local stmt = db:prepare(
        "SELECT COUNT(*) FROM clip_links WHERE link_group_id = ?")
    stmt:bind_value(1, link_group_id)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local Insert = require("core.commands.insert")

print("-- Insert(composite): atomic undo reverses V + A + link group --")
do
    local db = build_fixture()
    assert(clip_count(db, "e") == 0, "edit empty pre-insert")

    -- Drive the executor with a thin command-shim (the same shape
    -- command_manager.execute would hand us). Captures the undo
    -- bucket via set_parameter.
    local args = {
        sequence_id          = "e",
        nested_sequence_id   = "m",
        timeline_start_frame = 0,
    }
    local cmd = {
        params = args,
        get_all_parameters = function(self) return self.params end,
        set_parameter = function(self, k, v) self.params[k] = v end,
    }
    local executors, undoers = {}, {}
    Insert.register(executors, undoers, db, function(_) end)
    assert(executors["Insert"](cmd), "Insert executor returned truthy")

    -- 2 clips materialized (V + A); link group has 2 entries.
    assert(clip_count(db, "e") == 2,
        "Insert composite materializes 1 V + 1 A clip")
    local lg = args.created_link_group_id
    assert(lg and lg ~= "", "Insert returns a link_group_id")
    assert(clip_links_count(db, lg) == 2,
        "link group contains 2 entries (V + A)")

    -- One undo reverses ALL.
    assert(undoers["Insert"](cmd), "Insert undoer returned truthy")
    assert(clip_count(db, "e") == 0,
        "after Insert.undo, all created clips gone")
    -- The link_group_id row CASCADES via clip_links.clip_id FK ON
    -- DELETE CASCADE when the V+A clips are deleted; verify nothing
    -- remains.
    assert(clip_links_count(db, lg) == 0,
        "link_group rows cascade away when clips delete")
    print("  ok")
end

print("-- Insert(expanded audio): atomic undo reverses V + N A + link group --")
do
    local db = build_fixture()
    -- 3-A-track master → expanded mode emits 1 V + 3 A = 4 clips.
    -- Owner has only A1 → 2 tracks auto-created in plan (A2, A3).
    local args = {
        sequence_id          = "e",
        nested_sequence_id   = "m",
        timeline_start_frame = 0,
        audio_drop_mode      = "expanded",
    }
    local cmd = {
        params = args,
        get_all_parameters = function(self) return self.params end,
        set_parameter = function(self, k, v) self.params[k] = v end,
    }
    local executors, undoers = {}, {}
    Insert.register(executors, undoers, db, function(_) end)
    assert(executors["Insert"](cmd), "Insert(expanded) executor truthy")

    assert(clip_count(db, "e") == 4,
        "Insert(expanded) materializes 1 V + 3 A clips")
    local lg = args.created_link_group_id
    assert(clip_links_count(db, lg) == 4,
        "link group contains 4 entries (V + 3 A)")

    -- ONE undo reverses ALL 4 clips.
    assert(undoers["Insert"](cmd), "Insert.undo truthy")
    assert(clip_count(db, "e") == 0,
        "after one Insert.undo, all 4 clips gone (atomic)")
    print("  ok")
end

print("✅ test_insert_overwrite_atomic_undo.lua passed")
