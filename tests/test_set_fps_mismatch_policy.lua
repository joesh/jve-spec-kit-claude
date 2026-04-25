-- T060 partial / CT-C16 (013): SetFpsMismatchPolicy — project + sequence scopes.
--
-- Per FR-015 / commands.md §SetFpsMismatchPolicy:
--   scope='project': Args { project_id, policy }, policy non-NULL. UPDATE
--     projects.fps_mismatch_policy. No effect on existing clips (clip
--     row's fps_mismatch_policy was frozen at Insert time).
--   scope='sequence': Args { sequence_id, policy ∈ {'resample',
--     'passthrough', NULL} }. NULL = inherit project default. UPDATE
--     sequences.fps_mismatch_policy. No effect on existing clips.
--   scope='clip' (DEFERRED — not implemented yet): structural mutation
--     that re-computes clips.duration_frames + ripples + flips linked
--     V+A pair together. T060 fully covers it once the structural
--     mutation pass lands; this file flags it.
--
-- Undo: prior value at the chosen scope.
-- Signals: project scope emits no signal; sequence scope emits
--   sequence_content_changed(sequence_id) so future Insert/Overwrite
--   operations on that sequence pick the new default.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_set_fps_mismatch_policy.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            fps_mismatch_policy, created_at, modified_at)
        VALUES ('s', 'p1', 's', 'nested', 24, 1, 48000, 1920, 1080, NULL, 0, 0);
    ]]))
    return db
end

local function load_project_policy(db, project_id)
    local stmt = db:prepare("SELECT fps_mismatch_policy FROM projects WHERE id = ?")
    stmt:bind_value(1, project_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

local function load_sequence_policy(db, sequence_id)
    local stmt = db:prepare("SELECT fps_mismatch_policy FROM sequences WHERE id = ?")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

local SetFpsMismatchPolicy = require("core.commands.set_fps_mismatch_policy")

print("-- project scope: resample → passthrough; undo restores --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_project_policy(db, "p1") == "resample")

    local capture = SetFpsMismatchPolicy.execute({
        scope      = "project",
        project_id = "p1",
        policy     = "passthrough",
    })
    assert(load_project_policy(db, "p1") == "passthrough", "policy flipped")

    SetFpsMismatchPolicy.undo(capture)
    assert(load_project_policy(db, "p1") == "resample", "undo restores")
    print("  ok")
end

print("-- sequence scope: NULL → 'passthrough' → 'resample' → NULL --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_sequence_policy(db, "s") == nil, "fixture starts NULL")

    local cap1 = SetFpsMismatchPolicy.execute({
        scope       = "sequence",
        sequence_id = "s",
        policy      = "passthrough",
    })
    assert(load_sequence_policy(db, "s") == "passthrough")

    local cap2 = SetFpsMismatchPolicy.execute({
        scope       = "sequence",
        sequence_id = "s",
        policy      = "resample",
    })
    assert(load_sequence_policy(db, "s") == "resample")

    SetFpsMismatchPolicy.undo(cap2)
    assert(load_sequence_policy(db, "s") == "passthrough", "undo step 2")

    SetFpsMismatchPolicy.undo(cap1)
    assert(load_sequence_policy(db, "s") == nil,
        "undo step 1 restores NULL inheritance")
    print("  ok")
end

print("-- sequence scope: passthrough → NULL clears the override --")
do
    build_fixture()
    local db = database.get_connection()
    assert(db:exec("UPDATE sequences SET fps_mismatch_policy = 'passthrough' WHERE id = 's'"))

    local capture = SetFpsMismatchPolicy.execute({
        scope       = "sequence",
        sequence_id = "s",
        policy      = nil,
    })
    assert(load_sequence_policy(db, "s") == nil, "policy cleared to NULL")

    SetFpsMismatchPolicy.undo(capture)
    assert(load_sequence_policy(db, "s") == "passthrough", "undo restores")
    print("  ok")
end

print("-- project scope refuses NULL policy --")
do
    build_fixture()
    local ok, err = pcall(SetFpsMismatchPolicy.execute, {
        scope      = "project",
        project_id = "p1",
        policy     = nil,
    })
    assert(not ok, "project NULL refused")
    assert(tostring(err):find("policy") or tostring(err):find("non%-NULL"),
        "error names the constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- unknown policy value: refused --")
do
    build_fixture()
    local ok = pcall(SetFpsMismatchPolicy.execute, {
        scope      = "project",
        project_id = "p1",
        policy     = "bad",
    })
    assert(not ok)
    print("  ok")
end

print("-- unknown scope: refused --")
do
    build_fixture()
    local ok = pcall(SetFpsMismatchPolicy.execute, {
        scope  = "weird",
        policy = "resample",
    })
    assert(not ok)
    print("  ok")
end

print("-- clip scope is deferred (refuses with TODO message) --")
do
    build_fixture()
    local ok, err = pcall(SetFpsMismatchPolicy.execute, {
        scope       = "clip",
        sequence_id = "s",
        clip_id     = "nope",
        policy      = "resample",
    })
    assert(not ok, "clip-scope deferred")
    assert(tostring(err):find("clip%-scope")
        or tostring(err):find("structural")
        or tostring(err):find("not yet"),
        "error must label the deferral; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_set_fps_mismatch_policy.lua passed")
