-- T038 (013): Ripple-delete preserves link group on neighbors.
--
-- Acceptance Scenario 8 / FR-003: a single ripple-delete on a clip that
-- belongs to a link group treats the whole group as one unit — every
-- linked clip is removed, and each affected track's downstream clips
-- shift upstream by the duration deleted on THAT track. Link groups on
-- *neighboring* (not-deleted) clips remain intact.
--
-- This is a DOMAIN-LEVEL contract: the editor user expects that deleting
-- a V+A pair from the timeline leaves any other V+A pair downstream
-- still linked together.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_ripple_delete_link_group.db"

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
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 2000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES
          ('mr-v', 'p1', 'm', 'm-v1', 'med', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0),
          ('mr-a', 'p1', 'm', 'm-a1', 'med', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function seed_clip(db, clip_id, track_id, timeline_start, duration,
                        source_in, source_out)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', 'p1', 'e', '%s', 'm', '%s', %d, %d, %d, %d,
            'passthrough', 1, 1.0, 0, 0, 0)
    ]], clip_id, track_id, clip_id, timeline_start, duration,
       source_in, source_out)))
end

local function link_clips(db, group_id, members)
    for _, m in ipairs(members) do
        assert(db:exec(string.format([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES ('%s', '%s', '%s', 0, 1)
        ]], group_id, m.id, m.role)))
    end
end

local function clip_exists(db, clip_id)
    local stmt = db:prepare("SELECT 1 FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local exists = stmt:next() ~= nil
    if exists then exists = stmt:value(0) == 1 end
    stmt:finalize()
    return exists
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT timeline_start_frame, duration_frames
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "load_clip: not found: " .. id)
    local r = { timeline_start = stmt:value(0), duration = stmt:value(1) }
    stmt:finalize()
    return r
end

local function group_id_for(db, clip_id)
    local stmt = db:prepare(
        "SELECT link_group_id FROM clip_links WHERE clip_id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local id
    if stmt:next() then id = stmt:value(0) end
    stmt:finalize()
    return id
end

local function members_of(db, group_id)
    local stmt = db:prepare(
        "SELECT clip_id FROM clip_links WHERE link_group_id = ? ORDER BY clip_id")
    stmt:bind_value(1, group_id)
    assert(stmt:exec())
    local r = {}
    while stmt:next() do r[#r+1] = stmt:value(0) end
    stmt:finalize()
    return r
end

local RippleDelete = require("core.commands.ripple_delete")
assert(type(RippleDelete.execute) == "function",
    "T046 partial not landed: core.commands.ripple_delete must export .execute")

-- -------------------------------------------------------------------------
-- Two linked V+A pairs back-to-back. Ripple-delete the first V (linked to
-- A1 in group G1). Both V1 + A1 disappear; V2 shifts to [0,100) on V1
-- track; A2 shifts to [0,100) on A1 track; G2 still links V2+A2.
-- -------------------------------------------------------------------------
print("-- Ripple-delete linked V+A unit; downstream pair stays linked --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1",   0, 100,   0, 100)
    seed_clip(db, "a1", "e-a1",   0, 100,   0, 100)
    seed_clip(db, "v2", "e-v1", 100, 100, 100, 200)
    seed_clip(db, "a2", "e-a1", 100, 100, 100, 200)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })
    link_clips(db, "G2", { { id = "v2", role = "video" }, { id = "a2", role = "audio" } })

    RippleDelete.execute({
        sequence_id = "e",
        clip_id     = "v1",
    })

    -- Pair 1 fully removed (linked unit).
    assert(not clip_exists(db, "v1"), "v1 must be deleted")
    assert(not clip_exists(db, "a1"), "a1 must be deleted (linked partner)")

    -- Pair 2 ripples upstream by 100 on each affected track.
    local v2 = load_clip(db, "v2")
    local a2 = load_clip(db, "a2")
    assert(v2.timeline_start == 0 and v2.duration == 100,
        string.format("v2 expected at [0,100); got [%d,%d)",
            v2.timeline_start, v2.timeline_start + v2.duration))
    assert(a2.timeline_start == 0 and a2.duration == 100,
        string.format("a2 expected at [0,100); got [%d,%d)",
            a2.timeline_start, a2.timeline_start + a2.duration))

    -- G2 link group still intact: both v2 and a2 share G2.
    assert(group_id_for(db, "v2") == "G2", "v2 lost G2 group")
    assert(group_id_for(db, "a2") == "G2", "a2 lost G2 group")
    local g2 = members_of(db, "G2")
    table.sort(g2)
    assert(#g2 == 2 and g2[1] == "a2" and g2[2] == "v2",
        "G2 must still hold exactly v2+a2")

    -- G1 rows cascaded by FK ON DELETE.
    assert(#members_of(db, "G1") == 0, "G1 must be empty after cascade")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Ripple-delete an unlinked clip: only that clip is removed; downstream
-- on the same track shifts; unrelated tracks untouched.
-- -------------------------------------------------------------------------
print("-- Ripple-delete unlinked clip: single-track ripple --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1",   0,  50,   0,  50)
    seed_clip(db, "v2", "e-v1",  50,  50,  50, 100)
    seed_clip(db, "a1", "e-a1",   0, 100,   0, 100)  -- unrelated, no link

    RippleDelete.execute({ sequence_id = "e", clip_id = "v1" })

    assert(not clip_exists(db, "v1"), "v1 deleted")
    assert(clip_exists(db, "v2"), "v2 retained")
    assert(clip_exists(db, "a1"), "a1 (unrelated track) retained")
    local v2 = load_clip(db, "v2")
    assert(v2.timeline_start == 0, "v2 ripples to start")
    local a1 = load_clip(db, "a1")
    assert(a1.timeline_start == 0 and a1.duration == 100,
        "a1 on unrelated track must not move")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Ripple-delete on a non-existent clip raises loud-fail; DB unchanged.
-- -------------------------------------------------------------------------
print("-- Ripple-delete missing clip refuses --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1", 0, 100, 0, 100)
    local ok = pcall(RippleDelete.execute, {
        sequence_id = "e", clip_id = "nope",
    })
    assert(not ok, "ripple-delete of missing clip must refuse")
    assert(clip_exists(db, "v1"), "v1 untouched after refused delete")
    print("  ok")
end

-- Drive the registered executor + undoer through a minimal command shim.
local function make_cmd(params)
    return {
        params = params,
        get_all_parameters = function(self) return self.params end,
        get_parameter      = function(self, k) return self.params[k] end,
        set_parameter      = function(self, k, v) self.params[k] = v end,
        set_parameters     = function(self, t)
            for k, v in pairs(t) do self.params[k] = v end
        end,
    }
end
local function register(module, name)
    local executors, undoers, last_err = {}, {}, nil
    module.register(executors, undoers, nil, function(e) last_err = e end)
    return executors[name], undoers[name], function() return last_err end
end

-- -------------------------------------------------------------------------
-- Undo of a linked-pair ripple-delete: both clips restored at original
-- positions, downstream pair shifts back to where it was, link groups
-- reattached.
-- -------------------------------------------------------------------------
print("-- Undo RippleDelete linked V+A: clips + ripple restored --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1",   0, 100,   0, 100)
    seed_clip(db, "a1", "e-a1",   0, 100,   0, 100)
    seed_clip(db, "v2", "e-v1", 100, 100, 100, 200)
    seed_clip(db, "a2", "e-a1", 100, 100, 100, 200)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })
    link_clips(db, "G2", { { id = "v2", role = "video" }, { id = "a2", role = "audio" } })

    local exec, undo = register(RippleDelete, "RippleDelete")
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))
    -- Sanity: pair 1 gone, pair 2 rippled to start.
    assert(not clip_exists(db, "v1") and not clip_exists(db, "a1"))
    local v2 = load_clip(db, "v2")
    assert(v2.timeline_start == 0)

    -- Undo.
    assert(undo(cmd))
    assert(clip_exists(db, "v1") and clip_exists(db, "a1"),
        "deleted pair restored")
    local v1_after = load_clip(db, "v1")
    local a1_after = load_clip(db, "a1")
    assert(v1_after.timeline_start == 0 and v1_after.duration == 100,
        "v1 restored at original position")
    assert(a1_after.timeline_start == 0 and a1_after.duration == 100,
        "a1 restored at original position")
    local v2_after = load_clip(db, "v2")
    local a2_after = load_clip(db, "a2")
    assert(v2_after.timeline_start == 100 and v2_after.duration == 100,
        "v2 un-rippled back to original position")
    assert(a2_after.timeline_start == 100 and a2_after.duration == 100,
        "a2 un-rippled back to original position")
    assert(group_id_for(db, "v1") == "G1" and group_id_for(db, "a1") == "G1",
        "G1 link rows restored")
    assert(group_id_for(db, "v2") == "G2" and group_id_for(db, "a2") == "G2",
        "G2 link rows untouched")
    print("  ok")
end

print("✅ test_013_ripple_delete_link_group.lua passed")
