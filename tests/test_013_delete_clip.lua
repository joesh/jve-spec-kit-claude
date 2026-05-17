-- T046 partial (013): DeleteClip V13 + link-group-aware (no ripple).
--
-- Plain Delete (vs RippleDelete): removes clips without shifting
-- downstream. Per FR-003 a linked group is treated as one unit, so
-- deleting any member removes ALL members of the group.
--
-- Effect:
--   - every member of the delete unit is removed
--   - clip_links and clip_channel_override rows cascade via FK
--   - clips on the same track at later times stay where they are
--   - undo restores every deleted clip (and its overrides)
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_delete_clip.db"

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
        VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0),
               ('e', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
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
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES
          ('mr-v', 'p1', 'm', 'm-v1', 'med', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0),
          ('mr-a', 'p1', 'm', 'm-a1', 'med', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function seed_clip(db, id, track_id, ts, dur, src_in, src_out)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', 'p1', 'e', '%s', 'm', '%s', %d, %d, %d, %d,
            'passthrough', 1, 1.0, 0, 0, 0)
    ]], id, track_id, id, ts, dur, src_in, src_out)))
end

local function link_clips(db, group_id, members)
    for _, m in ipairs(members) do
        assert(db:exec(string.format([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES ('%s', '%s', '%s', 0, 1)
        ]], group_id, m.id, m.role)))
    end
end

local function clip_exists(db, id)
    local stmt = db:prepare("SELECT 1 FROM clips WHERE id = ?")
    stmt:bind_value(1, id); assert(stmt:exec())
    local exists = stmt:next() ~= nil
    if exists then exists = stmt:value(0) == 1 end
    stmt:finalize()
    return exists
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT sequence_start_frame, duration_frames, track_id
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. id)
    local r = {
        sequence_start = stmt:value(0),
        duration       = stmt:value(1),
        track_id       = stmt:value(2),
    }
    stmt:finalize()
    return r
end

local DeleteClip = require("core.commands.delete_clip")
assert(type(DeleteClip.execute) == "function",
    "T046 partial not landed: core.commands.delete_clip must export .execute")

-- -------------------------------------------------------------------------
-- Delete an unlinked clip: row gone, downstream untouched (no ripple).
-- -------------------------------------------------------------------------
print("-- DeleteClip unlinked: row gone, downstream stays put --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1",   0,  50,   0,  50)
    seed_clip(db, "v2", "e-v1", 200,  50, 200, 250)

    DeleteClip.execute({ sequence_id = "e", clip_id = "v1" })

    assert(not clip_exists(db, "v1"), "v1 deleted")
    local v2 = load_clip(db, "v2")
    assert(v2.sequence_start == 200 and v2.duration == 50,
        "v2 must NOT shift (Delete is non-ripple)")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Delete a linked clip: every member of the group is removed, downstream
-- stays put on each track. FR-003 — link group is one unit.
-- -------------------------------------------------------------------------
print("-- DeleteClip linked V+A: both removed, downstream untouched --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1",   0, 100,   0, 100)
    seed_clip(db, "a1", "e-a1",   0, 100,   0, 100)
    seed_clip(db, "v2", "e-v1", 100, 100, 100, 200)
    seed_clip(db, "a2", "e-a1", 100, 100, 100, 200)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })
    link_clips(db, "G2", { { id = "v2", role = "video" }, { id = "a2", role = "audio" } })

    DeleteClip.execute({ sequence_id = "e", clip_id = "v1" })

    assert(not clip_exists(db, "v1"), "v1 deleted")
    assert(not clip_exists(db, "a1"), "a1 deleted (linked partner)")

    -- Downstream pair must NOT shift (non-ripple).
    local v2 = load_clip(db, "v2")
    local a2 = load_clip(db, "a2")
    assert(v2.sequence_start == 100, "v2 must not move")
    assert(a2.sequence_start == 100, "a2 must not move")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Delete missing clip: loud refusal, DB unchanged.
-- -------------------------------------------------------------------------
print("-- DeleteClip on missing id refuses --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1", 0, 100, 0, 100)
    local ok = pcall(DeleteClip.execute, {
        sequence_id = "e", clip_id = "missing",
    })
    assert(not ok, "missing clip must refuse")
    assert(clip_exists(db, "v1"), "v1 untouched after refused delete")
    print("  ok")
end

-- Drive the registered executor + undoer through a minimal command shim
-- (matches the pattern used in test_013_signal_sequence_content_changed).
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
-- Undo of an unlinked-clip delete restores the row, its overrides, and
-- (since none existed) leaves clip_links untouched.
-- -------------------------------------------------------------------------
print("-- Undo DeleteClip unlinked: row + overrides restored --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1", 100, 50, 0, 50)
    -- Two channel overrides that must survive the round trip.
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('v1', 0, 1, -3.0), ('v1', 1, 0, 0.0);
    ]]))

    local exec, undo = register(DeleteClip, "DeleteClip")
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))
    assert(not clip_exists(db, "v1"), "v1 deleted after execute")

    assert(undo(cmd))
    assert(clip_exists(db, "v1"), "v1 restored after undo")
    local v1 = load_clip(db, "v1")
    assert(v1.sequence_start == 100 and v1.duration == 50,
        "v1 timeline restored")

    local stmt = db:prepare(
        "SELECT channel_index, enabled, gain_db FROM clip_channel_override WHERE clip_id = ? ORDER BY channel_index")
    stmt:bind_value(1, "v1")
    assert(stmt:exec())
    local ovs = {}
    while stmt:next() do
        ovs[#ovs+1] = { ch = stmt:value(0), en = stmt:value(1), g = stmt:value(2) }
    end
    stmt:finalize()
    assert(#ovs == 2, string.format("expected 2 overrides; got %d", #ovs))
    assert(ovs[1].ch == 0 and ovs[1].en == 1 and ovs[1].g == -3.0)
    assert(ovs[2].ch == 1 and ovs[2].en == 0 and ovs[2].g == 0.0)
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Undo of a linked-pair delete restores BOTH clips and the original
-- clip_links rows so they remain in their original group.
-- -------------------------------------------------------------------------
print("-- Undo DeleteClip linked V+A: pair restored, link group intact --")
do
    local db = build_fixture()
    seed_clip(db, "v1", "e-v1", 0, 100, 0, 100)
    seed_clip(db, "a1", "e-a1", 0, 100, 0, 100)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })

    local exec, undo = register(DeleteClip, "DeleteClip")
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))
    assert(not clip_exists(db, "v1") and not clip_exists(db, "a1"),
        "both members deleted after execute")

    assert(undo(cmd))
    assert(clip_exists(db, "v1") and clip_exists(db, "a1"),
        "both members restored after undo")

    local function group_id_for(id)
        local stmt = db:prepare("SELECT link_group_id FROM clip_links WHERE clip_id = ?")
        stmt:bind_value(1, id); assert(stmt:exec())
        local g; if stmt:next() then g = stmt:value(0) end
        stmt:finalize()
        return g
    end
    assert(group_id_for("v1") == "G1", "v1 link membership restored to G1")
    assert(group_id_for("a1") == "G1", "a1 link membership restored to G1")
    print("  ok")
end

print("✅ test_013_delete_clip.lua passed")
