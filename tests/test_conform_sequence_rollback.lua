-- 018 / iter-3 audit follow-up: ConformSequence rollback path (Scenario F).
--
-- The transaction envelope inside Sequence.conform_fps inserts a session-
-- flag temp-table row to bypass INV-5, then runs three UPDATE loops, then
-- deletes the flag, all inside a savepoint pcall. If ANY of those updates
-- fails mid-transaction, the savepoint must roll back BOTH the fps change
-- AND the session-flag insert — otherwise a subsequent direct UPDATE could
-- silently bypass INV-5 against a future operator's expectations.
--
-- We exercise this by handing conform_fps a rescaler that errors after the
-- first UPDATE. The expected end state:
--   - the sequence's fps is unchanged (rollback)
--   - the db_session_flags row is NOT present (rollback)
--   - a fresh direct UPDATE attempt is still blocked by INV-5 (trigger
--     still enforces its rule)

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")

local DB = "/tmp/jve/test_conform_sequence_rollback.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough','{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
      VALUES ('m','p','M','master',24,1,NULL,1920,1080,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
      VALUES ('m-v1','m','V1','VIDEO',1);
    UPDATE sequences SET default_video_layer_track_id='m-v1' WHERE id='m';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at)
      VALUES ('med','p','m.mov','/tmp/m.mov',240,24,1,0,0,%d,%d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr-v','p','m','m-v1','med',0,240,0,240,1,1.0,0,%d,%d);
]], now, now, now, now, now, now, now, now)))

-- Pre-state: fps is 24/1, flag is absent.
local function read_fps()
    local s = assert(db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id='m'"))
    s:exec(); s:next()
    local n, d = s:value(0), s:value(1)
    s:finalize()
    return n, d
end
local function read_flag()
    local s = assert(db:prepare(
        "SELECT 1 FROM db_session_flags WHERE name='_conform_sequence_in_progress'"))
    s:exec()
    local has_row = s:next()
    s:finalize()
    return has_row == true
end

local n0, d0 = read_fps()
assert(n0 == 24 and d0 == 1, "pre: fps 24/1")
assert(not read_flag(), "pre: session flag absent")
print("  pre-state: fps=24/1, flag absent")

-- Hand-craft a captured table mimicking the V media_ref scaled by the
-- new rate. Capture inputs are unused by the failing-rescaler path; only
-- shape matters.
local captured = {
    mrefs = {
        { id = "mr-v", seq_start = 0, dur = 240 },
    },
    inner_clips = {},
    outer_clips = {},
}

-- Failing rescaler: succeeds on the first call (used for the fps UPDATE's
-- bookkeeping — see implementation), then errors. The exact call where it
-- fails depends on the implementation, but ANY error mid-conform_fps must
-- roll back the savepoint completely.
local calls = 0
local function failing_rescaler()
    calls = calls + 1
    if calls > 1 then
        error("test_conform_sequence_rollback: injected failure on call " .. calls)
    end
    return 0  -- arbitrary first return; let the implementation proceed once
end

-- Invoke. Sequence.conform_fps is expected to re-throw via pcall — wrap
-- locally so we observe the failure without aborting the test.
local ok, err = pcall(Sequence.conform_fps,
    "m", 24000, 1001, captured, failing_rescaler)
assert(not ok, "conform_fps must propagate the rescaler error, got success")
print("  injected failure: conform_fps re-threw — " .. tostring(err):sub(1, 60) .. "…")

-- Post-state: BOTH the fps and the flag must be back to pre-state.
local n1, d1 = read_fps()
assert(n1 == 24 and d1 == 1, string.format(
    "ROLLBACK FAILED: fps changed to %d/%d despite mid-transaction error",
    n1, d1))
print("  PASS: sequence fps rolled back to 24/1")

assert(not read_flag(), "ROLLBACK FAILED: db_session_flags row leaked past rollback")
print("  PASS: session flag rolled back (not leaked)")

-- INV-5 trigger still enforces its rule after the failed conform.
local ok2 = pcall(function()
    assert(db:exec(
        "UPDATE sequences SET fps_numerator=30, fps_denominator=1 WHERE id='m'"))
end)
assert(not ok2, "INV-5 must still block direct UPDATE after a failed conform")
local n2, _ = read_fps()
assert(n2 == 24, "fps must remain 24 after refused UPDATE")
print("  PASS: INV-5 still active after rollback (defense-in-depth intact)")

print("✅ test_conform_sequence_rollback.lua passed")
