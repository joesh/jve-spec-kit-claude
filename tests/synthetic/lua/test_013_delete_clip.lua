-- DeleteClip V13 (no ripple).
--
-- Plain Delete (vs RippleDelete): removes the TARGETED clip without
-- shifting downstream. Delete acts on the selected clip ONLY — a linked
-- partner is NOT pulled in (revised 2026-05-28, supersedes the original
-- FR-003 "linked group is one delete unit").
--
-- Effect:
--   - the targeted clip is removed
--   - its clip_links and clip_channel_override rows cascade via FK
--   - other members of its link group survive, untouched
--   - clips on the same track at later times stay where they are
--   - undo restores the deleted clip (and its overrides + link membership)
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")

local DB_PATH = "/tmp/jve/test_013_delete_clip.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))
    return db
end

local function build_fixture()
    local db = fresh_db()
    
    local project_id = "p1"
    Project.create("p", {
        id = project_id,
        fps_mismatch_policy = "passthrough",
        settings = {
            master_clock_hz = 192000,
            default_fps = { num = 24, den = 1 }
        }
    }):save()

    Sequence.create("m", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = "m",
        kind = "master",
    }):save()

    local seq_id = "e"
    Sequence.create("edit", project_id, { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080, {
        id = seq_id,
        kind = "sequence",
        audio_sample_rate = 48000,
    }):save()

    Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
    Track.create_audio("A1", "m", { id = "m-a1", index = 1 }):save()
    -- Two master AUDIO tracks so undo override round-trip can target distinct UUIDs.
    Track.create_audio("A2", "m", { id = "m-a2", index = 2 }):save()
    Track.create_video("V1", seq_id, { id = "e-v1", index = 1 }):save()
    Track.create_audio("A1", seq_id, { id = "e-a1", index = 1 }):save()
    
    db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")

    local media_id = "med"
    Media.create({
        id = media_id,
        project_id = project_id,
        name = "a.mov",
        file_path = "/tmp/a.mov",
        duration_frames = 2000,
        fps_numerator = 24,
        fps_denominator = 1,
        audio_channels = 0,
        metadata = '{"start_tc_value":0,"start_tc_rate":24}'
    }):save()

    -- Ensure a media ref exists on the master track
    db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES
          ('mr-v', 'p1', 'm', 'm-v1', 'med', 0, 2000, 0, 2000, 48000, 1, 1.0, 0, 0, 0),
          ('mr-a', 'p1', 'm', 'm-a1', 'med', 0, 2000, 0, 2000, 48000, 1, 1.0, 0, 0, 0);
    ]])

    return db
end

local function seed_clip(clip_id, track_id, sequence_start, duration, source_in, source_out)
    local track = Track.load(track_id)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type(track.track_type)
    
    local cid = Clip.create({
        id = clip_id,
        project_id = "p1",
        owner_sequence_id = "e",
        track_id = track_id,
        sequence_id = "m",
        name = clip_id,
        sequence_start_frame = sequence_start,
        duration_frames = duration,
        source_in_frame = source_in,
        source_out_frame = source_out,
        source_in_subframe = sub_in,
        source_out_subframe = sub_out,
        fps_mismatch_policy = "passthrough",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(cid == clip_id, "seed_clip failed")
end

local function link_clips(db, group_id, members)
    for _, m in ipairs(members) do
        assert(db:exec(string.format([[
            INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
            VALUES ('%s', '%s', '%s', 0, 1)
        ]], group_id, m.id, m.role)))
    end
end

local function clip_exists(id)
    local c = Clip.load_optional(id)
    return c ~= nil
end

local function load_clip(id)
    local c = Clip.load_optional(id)
    assert(c, "load_clip: not found: " .. id)
    return {
        sequence_start = c.sequence_start,
        duration       = c.duration,
        track_id       = c.track_id,
    }
end

local DeleteClip = require("core.commands.delete_clip")
assert(type(DeleteClip.execute) == "function",
    "T046 partial not landed: core.commands.delete_clip must export .execute")

-- Drive the registered executor + undoer through a minimal command shim
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
local function register(module, name, db)
    local executors, undoers, last_err = {}, {}, nil
    module.register(executors, undoers, db, function(e) last_err = e end)
    return executors[name], undoers[name], function() return last_err end
end

-- -------------------------------------------------------------------------
-- Delete an unlinked clip: row gone, downstream untouched (no ripple).
-- -------------------------------------------------------------------------
print("-- DeleteClip unlinked: row gone, downstream stays put --")
do
    local db = build_fixture()
    seed_clip("v1", "e-v1",   0,  50,   0,  50)
    seed_clip("v2", "e-v1", 200,  50, 200, 250)

    local exec, _ = register(DeleteClip, "DeleteClip", db)
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))

    assert(not clip_exists("v1"), "v1 deleted")
    local v2 = load_clip("v2")
    assert(v2.sequence_start == 200 and v2.duration == 50,
        "v2 must NOT shift (Delete is non-ripple)")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Delete a linked clip: ONLY the targeted clip is removed. Its linked
-- partner survives (and keeps its own link-group row); downstream stays
-- put on each track (non-ripple).
-- -------------------------------------------------------------------------
print("-- DeleteClip linked V: only V removed, linked A survives --")
do
    local db = build_fixture()
    seed_clip("v1", "e-v1",   0, 100,   0, 100)
    seed_clip("a1", "e-a1",   0, 100,   0, 100)
    seed_clip("v2", "e-v1", 100, 100, 100, 200)
    seed_clip("a2", "e-a1", 100, 100, 100, 200)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })
    link_clips(db, "G2", { { id = "v2", role = "video" }, { id = "a2", role = "audio" } })

    local exec, _ = register(DeleteClip, "DeleteClip", db)
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))

    assert(not clip_exists("v1"), "v1 deleted")
    assert(clip_exists("a1"), "a1 (linked partner) must SURVIVE")

    -- a1 keeps its own link-group membership row (v1's row cascaded away).
    local stmt = db:prepare("SELECT link_group_id FROM clip_links WHERE clip_id = 'a1'")
    assert(stmt:exec() and stmt:next() and stmt:value(0) == "G1",
        "a1 must keep its G1 link row")
    stmt:finalize()
    local g1 = db:prepare("SELECT COUNT(*) FROM clip_links WHERE link_group_id = 'G1'")
    assert(g1:exec() and g1:next() and g1:value(0) == 1,
        "G1 must contain only a1 after v1's row cascades")
    g1:finalize()

    -- Downstream pair must NOT shift (non-ripple).
    local v2 = load_clip("v2")
    local a2 = load_clip("a2")
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
    seed_clip("v1", "e-v1", 0, 100, 0, 100)
    
    local exec, _ = register(DeleteClip, "DeleteClip", db)
    local cmd = make_cmd({ sequence_id = "e", clip_id = "missing" })
    local ok = exec(cmd)
    assert(not ok, "missing clip must refuse")
    assert(clip_exists("v1"), "v1 untouched after refused delete")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Undo of an unlinked-clip delete restores the row, its overrides, and
-- (since none existed) leaves clip_links untouched.
-- -------------------------------------------------------------------------
print("-- Undo DeleteClip unlinked: row + overrides restored --")
do
    local db = build_fixture()
    seed_clip("v1", "e-v1", 100, 50, 0, 50)
    -- Two channel overrides keyed by master AUDIO track UUID (Phase 4a).
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db)
        VALUES ('v1', 'm-a1', 1, -3.0), ('v1', 'm-a2', 0, 0.0);
    ]]))

    local exec, undo = register(DeleteClip, "DeleteClip", db)
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))
    assert(not clip_exists("v1"), "v1 deleted after execute")

    assert(undo(cmd))
    assert(clip_exists("v1"), "v1 restored after undo")
    local v1 = load_clip("v1")
    assert(v1.sequence_start == 100 and v1.duration == 50,
        "v1 timeline restored")

    -- Read back overrides ordered by master_track_id (m-a1 < m-a2 lexicographically).
    local stmt = db:prepare(
        "SELECT master_track_id, enabled, gain_db FROM clip_channel_override WHERE clip_id = ? ORDER BY master_track_id")
    stmt:bind_value(1, "v1")
    assert(stmt:exec())
    local ovs = {}
    while stmt:next() do
        ovs[#ovs+1] = { mt = stmt:value(0), en = stmt:value(1), g = stmt:value(2) }
    end
    stmt:finalize()
    assert(#ovs == 2, string.format("expected 2 overrides; got %d", #ovs))
    assert(ovs[1].mt == "m-a1" and ovs[1].en == 1 and math.abs(ovs[1].g - (-3.0)) < 1e-9,
        "undo restores m-a1 override: enabled=1, gain=-3")
    assert(ovs[2].mt == "m-a2" and ovs[2].en == 0 and math.abs(ovs[2].g - 0.0) < 1e-9,
        "undo restores m-a2 override: enabled=0, gain=0")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Undo of a linked-clip delete restores ONLY the deleted clip (its partner
-- was never deleted) and reattaches its link-group row. The surviving
-- partner is untouched throughout.
-- -------------------------------------------------------------------------
print("-- Undo DeleteClip linked V: deleted V restored to group, A untouched --")
do
    local db = build_fixture()
    seed_clip("v1", "e-v1", 0, 100, 0, 100)
    seed_clip("a1", "e-a1", 0, 100, 0, 100)
    link_clips(db, "G1", { { id = "v1", role = "video" }, { id = "a1", role = "audio" } })

    local exec, undo = register(DeleteClip, "DeleteClip", db)
    local cmd = make_cmd({ sequence_id = "e", clip_id = "v1" })
    assert(exec(cmd))
    assert(not clip_exists("v1"), "v1 deleted after execute")
    assert(clip_exists("a1"), "a1 (partner) survives the delete")

    assert(undo(cmd))
    assert(clip_exists("v1") and clip_exists("a1"),
        "v1 restored after undo; a1 still present")

    local function group_id_for(id)
        local stmt = db:prepare("SELECT link_group_id FROM clip_links WHERE clip_id = ?")
        stmt:bind_value(1, id); assert(stmt:exec())
        local g; if stmt:next() then g = stmt:value(0) end
        stmt:finalize()
        return g
    end
    assert(group_id_for("v1") == "G1", "v1 link membership restored to G1")
    assert(group_id_for("a1") == "G1", "a1 link membership untouched (still G1)")
    print("  ok")
end

print("✅ test_013_delete_clip.lua passed")
