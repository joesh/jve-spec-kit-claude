-- T006 (018): invariant triggers INV-3 .. INV-7 enforce 018's data-model rules.
-- Initially fails because the triggers don't exist yet. Flips green after T005.
--
-- Triggers (data-model.md):
--   INV-3 — subframe presence by clip kind (video=NULL, audio=NOT NULL)
--   INV-4 — subframe bound (0 <= sub < ticks_per_frame)
--   INV-5 — sequences.fps_num/den single-writer (ConformSequence only)
--   INV-6 — projects.settings.master_clock_hz single-writer (SetProjectMasterClock only)
--   INV-7 — sequences.audio_sample_rate must be NULL on kind='master'

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_subframe_invariants.db"
os.remove(DB_PATH)
os.remove(DB_PATH .. "-wal")
os.remove(DB_PATH .. "-shm")

assert(database.init(DB_PATH), "DB init failed")
local db = database.get_connection()

-- ---------------------------------------------------------------------------
-- Seed minimal fixture: project with V11 settings, one master + one regular
-- sequence, one audio track on each.
-- ---------------------------------------------------------------------------
local function seed()
    -- project.settings must carry master_clock_hz for INV-4 + INV-6 to work.
    -- default_fps is also present per FR-026 / FR-027.
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', '%s', 0, 0);
    ]], '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}')))
    -- master: kind='master', audio_sample_rate MUST be NULL (INV-7).
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
    ]]))
    -- regular sequence: kind='sequence', audio_sample_rate required.
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('s', 'p1', 's', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
    ]]))
    -- tracks: a VIDEO and an AUDIO track on the regular sequence (clips live here).
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('s-v1', 's', 'V1', 'VIDEO', 1),
               ('s-a1', 's', 'A1', 'AUDIO', 1);
    ]]))
end
seed()

-- ---------------------------------------------------------------------------
-- Helper: attempt a SQL statement; return true if it errored, false if it
-- succeeded. lsqlite3's exec returns false on error.
-- ---------------------------------------------------------------------------
local function expect_abort(sql, expected_msg_fragment)
    local ok = db:exec(sql)
    -- lsqlite3 returns true on success and false on error from exec()
    if ok then
        error("expected ABORT but statement succeeded:\n  " .. sql, 2)
    end
    -- error_message() pulls the last error string from sqlite3.
    local err = db:last_error() or ""
    if expected_msg_fragment and not err:match(expected_msg_fragment) then
        error(string.format(
            "expected error to match %q, got %q\n  SQL: %s",
            expected_msg_fragment, err, sql), 2)
    end
end

-- ===========================================================================
-- INV-3: subframe presence by clip kind
-- ===========================================================================

-- VIDEO clip MUST have NULL subframes.
expect_abort([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('c-video-bad', 'p1', 's', 's-v1', 'm',
            0, 100, 0, 0, 0, 100, 'passthrough', 'v', 1, 1.0, 0, 0, 0);
]], "INV%-3")

-- AUDIO clip MUST have non-NULL subframes.
expect_abort([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('c-audio-bad', 'p1', 's', 's-a1', 'm',
            0, 100, NULL, NULL, 0, 100, 'passthrough', 'a', 1, 1.0, 0, 0, 0);
]], "INV%-3")

-- ===========================================================================
-- INV-4: subframe bound (0 <= sub < ticks_per_frame)
-- ticks_per_frame for source 'm' at 24/1 and master_clock_hz=192000:
--   = 192000 * 1 / 24 = 8000
-- ===========================================================================

-- subframe < 0 must be rejected.
expect_abort([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('c-sub-neg', 'p1', 's', 's-a1', 'm',
            0, 100, -1, 0, 0, 100, 'passthrough', 'a', 1, 1.0, 0, 0, 0);
]], "INV%-4")

-- subframe >= ticks_per_frame must be rejected.
expect_abort([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('c-sub-toobig', 'p1', 's', 's-a1', 'm',
            0, 100, 8000, 0, 0, 100, 'passthrough', 'a', 1, 1.0, 0, 0, 0);
]], "INV%-4")

-- Boundary: subframe = 7999 must succeed (one less than tpf).
local ok = db:exec([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        sequence_start_frame, duration_frames,
        fps_mismatch_policy, name, enabled, volume, playhead_frame,
        created_at, modified_at)
    VALUES ('c-sub-max', 'p1', 's', 's-a1', 'm',
            0, 100, 7999, 0, 0, 100, 'passthrough', 'a', 1, 1.0, 0, 0, 0);
]])
assert(ok, "INV-4: subframe=7999 (boundary) should succeed, got: " .. (db:last_error() or ""))
assert(db:exec("DELETE FROM clips WHERE id = 'c-sub-max'"))

-- ===========================================================================
-- INV-5: sequences.fps_num/den mutable only via ConformSequence
-- (i.e. when temp table _conform_sequence_in_progress exists)
-- ===========================================================================

-- Direct UPDATE without the temp-table flag must be rejected.
expect_abort([[
    UPDATE sequences SET fps_numerator = 30 WHERE id = 'm';
]], "INV%-5")

expect_abort([[
    UPDATE sequences SET fps_denominator = 1001 WHERE id = 'm';
]], "INV%-5")

-- With the temp-table flag set, the UPDATE is allowed.
assert(db:exec("INSERT INTO db_session_flags VALUES ('_conform_sequence_in_progress')"))
local ok2 = db:exec("UPDATE sequences SET fps_numerator = 30 WHERE id = 'm'")
assert(ok2, "INV-5: UPDATE under flag should succeed, got: " .. (db:last_error() or ""))
assert(db:exec("DELETE FROM db_session_flags WHERE name = '_conform_sequence_in_progress'"))
-- Restore fps_num for downstream tests.
assert(db:exec("INSERT INTO db_session_flags VALUES ('_conform_sequence_in_progress')"))
assert(db:exec("UPDATE sequences SET fps_numerator = 24 WHERE id = 'm'"))
assert(db:exec("DELETE FROM db_session_flags WHERE name = '_conform_sequence_in_progress'"))

-- ===========================================================================
-- INV-6: projects.settings.master_clock_hz mutable only via SetProjectMasterClock
-- ===========================================================================

-- Direct settings UPDATE that changes master_clock_hz must be rejected.
expect_abort([[
    UPDATE projects SET settings = '{"master_clock_hz":48000,"default_fps":{"num":24,"den":1}}'
        WHERE id = 'p1';
]], "INV%-6")

-- Settings UPDATE that does NOT change master_clock_hz is allowed.
local ok3 = db:exec([[
    UPDATE projects SET settings = '{"master_clock_hz":192000,"default_fps":{"num":30,"den":1}}'
        WHERE id = 'p1';
]])
assert(ok3, "INV-6: non-clock settings UPDATE should succeed, got: " .. (db:last_error() or ""))

-- With the flag set, master_clock change is allowed.
assert(db:exec("INSERT INTO db_session_flags VALUES ('_set_master_clock_in_progress')"))
local ok4 = db:exec([[
    UPDATE projects SET settings = '{"master_clock_hz":48000,"default_fps":{"num":30,"den":1}}'
        WHERE id = 'p1';
]])
assert(ok4, "INV-6: UPDATE under flag should succeed, got: " .. (db:last_error() or ""))
assert(db:exec("DELETE FROM db_session_flags WHERE name = '_set_master_clock_in_progress'"))

-- ===========================================================================
-- INV-7: sequences.audio_sample_rate must be NULL on kind='master'
-- ===========================================================================

-- INSERT of master with non-NULL audio_sample_rate must be rejected.
expect_abort([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m2', 'p1', 'm2', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
]], "INV%-7")

-- UPDATE of an existing master to set non-NULL audio_sample_rate must be rejected.
expect_abort([[
    UPDATE sequences SET audio_sample_rate = 48000 WHERE id = 'm';
]], "INV%-7")

print("✅ test_subframe_invariants.lua passed")
