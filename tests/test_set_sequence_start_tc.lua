-- T059 / CT-C15 (013): SetSequenceStartTC.
--
-- Per FR-017 / commands.md §SetSequenceStartTC:
--   Args: { sequence_id, medium ∈ {'video','audio'}, tc_value }.
--     sequence_id must exist (rule 2.29).
--   Mutation:
--     medium='video': sequences.video_start_tc_frame ← tc_value (frames).
--     medium='audio': sequences.audio_start_tc_samples ← tc_value (samples).
--   Undo: prior value (NULL or integer).
--   Signal: sequence_content_changed(sequence_id).
--
-- Refusals:
--   * sequence_id missing (rule 2.29).
--   * medium not in {'video','audio'}.
--   * tc_value not an integer (or non-numeric).
--   * sequence_id not found.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_set_sequence_start_tc.db"

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
            video_start_tc_frame, audio_start_tc_samples,
            created_at, modified_at)
        VALUES ('s', 'p1', 's', 'master', 24, 1, 48000, 1920, 1080,
                86400, 172800000, 0, 0);
    ]]))
    return db
end

local function load_tcs(db, seq_id)
    local stmt = db:prepare(
        "SELECT video_start_tc_frame, audio_start_tc_samples FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    local a = stmt:value(1)
    stmt:finalize()
    return v, a
end

local SetSequenceStartTC = require("core.commands.set_sequence_start_tc")

print("-- video: changes video_start_tc_frame; undo restores --")
do
    build_fixture()
    local db = database.get_connection()
    local prior_v, prior_a = load_tcs(db, "s")
    assert(prior_v == 86400 and prior_a == 172800000)

    local capture = SetSequenceStartTC.execute({
        sequence_id = "s",
        medium      = "video",
        tc_value    = 90000,
    })
    local v, a = load_tcs(db, "s")
    assert(v == 90000, "video TC updated")
    assert(a == 172800000, "audio TC untouched")

    SetSequenceStartTC.undo(capture)
    v, a = load_tcs(db, "s")
    assert(v == 86400 and a == 172800000, "undo restores video TC")
    print("  ok")
end

print("-- audio: changes audio_start_tc_samples; undo restores --")
do
    build_fixture()
    local db = database.get_connection()
    local capture = SetSequenceStartTC.execute({
        sequence_id = "s",
        medium      = "audio",
        tc_value    = 200000000,
    })
    local v, a = load_tcs(db, "s")
    assert(v == 86400 and a == 200000000)

    SetSequenceStartTC.undo(capture)
    v, a = load_tcs(db, "s")
    assert(v == 86400 and a == 172800000)
    print("  ok")
end

print("-- sequence_id missing: refused (rule 2.29) --")
do
    build_fixture()
    local ok = pcall(SetSequenceStartTC.execute, {
        medium   = "video",
        tc_value = 0,
    })
    assert(not ok)
    print("  ok")
end

print("-- unknown medium: refused --")
do
    build_fixture()
    local ok, err = pcall(SetSequenceStartTC.execute, {
        sequence_id = "s",
        medium      = "subtitle",
        tc_value    = 0,
    })
    assert(not ok)
    assert(tostring(err):find("medium"),
        "error names the constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- non-integer tc_value: refused --")
do
    build_fixture()
    local ok = pcall(SetSequenceStartTC.execute, {
        sequence_id = "s",
        medium      = "video",
        tc_value    = 12.5,
    })
    assert(not ok)
    print("  ok")
end

print("-- unknown sequence: refused --")
do
    build_fixture()
    local ok, err = pcall(SetSequenceStartTC.execute, {
        sequence_id = "nope",
        medium      = "video",
        tc_value    = 0,
    })
    assert(not ok)
    assert(tostring(err):find("not found")
        or tostring(err):find("nope"),
        "error names the missing sequence; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_set_sequence_start_tc.lua passed")
