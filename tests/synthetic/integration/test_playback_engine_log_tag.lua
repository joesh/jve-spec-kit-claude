-- Integration test: PlaybackEngine role-based log tag.
--
-- REPLACES:
--   tests/synthetic/lua/test_log_line_identifies_which_side_produced_it.lua
--
-- DOMAIN RULES PINNED:
--   LT-1  PlaybackEngine carries role field set at construction time ("source"
--         or "record"); both roles are valid.
--   LT-2  Before load_sequence: the log tag is the "<role>:unloaded" sentinel —
--         a line produced before any load still says which side made it.
--   LT-3  In a dual-engine session (source bound to a master, record bound to
--         a timeline sequence — FR-001 forbids any other pairing), the two
--         engines' log tags are distinct and each names its role, so the
--         operator can correlate [source:…] vs [record:…] lines. After a
--         load the tag also stops being the unloaded sentinel.
--   LT-4  FR-001 role/kind invariant is enforced loudly: a source engine
--         refuses to load a timeline sequence (and the error names both the
--         expected and actual kind).
--
-- DROPPED from the first conversion pass (self-review):
--   * "LOG_TAG_ID_PREFIX_LEN == 8" — pins an arbitrary constant; any prefix
--     length satisfies the domain rule (distinguishability), so the exact
--     value is implementation, not behavior.
--   * The original LT-4 computed expected tags with the test's own string
--     math and never read an engine — a self-verifying fake. Replaced by
--     LT-3, which reads the tags of two REAL engines bound to one sequence.
--
-- OPEN QUESTIONS:
--   None.
--
-- Runs via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_playback_engine_log_tag.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()  -- assert real C++ bindings are present

print("=== test_playback_engine_log_tag.lua ===")

require("test_env")

local PlaybackEngine = require("core.playback.playback_engine")

-- Minimal callbacks: PlaybackEngine.new requires them but they need not do
-- anything for log-tag tests (no sequence is loaded).
local function noop() end
local function new_engine(role)
    return PlaybackEngine.new(role, {
        on_show_frame       = noop,
        on_show_gap         = noop,
        on_set_rotation     = noop,
        on_set_par          = noop,
        on_position_changed = noop,
    })
end

-- ════════════════════════════════════════════════════════════════════════════
-- LT-1  role field set at construction
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (LT-1) role field set at construction --")
do
    local src = new_engine("source")
    local rec = new_engine("record")

    assert(src.role == "source", string.format(
        "source-role engine must carry role='source'; got '%s'",
        tostring(src.role)))
    assert(rec.role == "record", string.format(
        "record-role engine must carry role='record'; got '%s'",
        tostring(rec.role)))

    print("  PASS: both roles stored correctly on construction")
end

-- ════════════════════════════════════════════════════════════════════════════
-- LT-2  Before load_sequence: _log_tag is "<role>:unloaded" sentinel
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (LT-2) pre-load _log_tag is '<role>:unloaded' --")
do
    local src = new_engine("source")
    local rec = new_engine("record")

    assert(src._log_tag == "source:unloaded", string.format(
        "source engine pre-load _log_tag must be 'source:unloaded'; got '%s'",
        tostring(src._log_tag)))
    assert(rec._log_tag == "record:unloaded", string.format(
        "record engine pre-load _log_tag must be 'record:unloaded'; got '%s'",
        tostring(rec._log_tag)))

    print("  PASS: pre-load tag is '<role>:unloaded' for both roles")
end

-- ════════════════════════════════════════════════════════════════════════════
-- LT-3  Dual-engine session, BOTH roles on the SAME sequence → distinct tags
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (LT-3) dual-engine session → distinct, role-named tags --")
local transport = require("core.playback.transport")
do
    local database = require("core.database")
    local DB = "/tmp/jve/test_log_tag_integ.db"
    os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
    os.execute("mkdir -p /tmp/jve")
    assert(database.init(DB))
    local db = database.get_connection()
    db:exec(require("import_schema"))
    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('proj_lt', 'LogTag', 'resample',
                '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
        INSERT INTO media (id, project_id, file_path, name, duration_frames,
            fps_numerator, fps_denominator, width, height,
            audio_channels, audio_sample_rate, created_at, modified_at)
        VALUES ('media_lt', 'proj_lt', '/test/lt_clip.mov', 'LTClip', 300, 24, 1,
            1920, 1080, 2, 48000, %d, %d);
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
            audio_sample_rate, width, height, view_start_frame, view_duration_frames,
            playhead_frame, created_at, modified_at)
        VALUES ('tl_lt', 'proj_lt', 'Timeline', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 300, 0, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('tl_lt_v1', 'tl_lt', 'V1', 'VIDEO', 1, 1);
    ]], now, now, now, now, now, now)))
    local master_id = require("test_env").create_test_masterclip_sequence(
        "proj_lt", "LTClip", 24, 1, 300, "media_lt")

    transport.init("proj_lt")
    -- FR-001 pairing: source engines bind to masters, record to timelines.
    transport.bind_role_to_sequence("source", master_id)
    transport.bind_role_to_sequence("record", "tl_lt")

    local src = transport.engine_for_role("source")
    local rec = transport.engine_for_role("record")
    assert(src.loaded_sequence_id == master_id and rec.loaded_sequence_id == "tl_lt",
        "fixture: both engines must have loaded their role's sequence")

    local src_tag, rec_tag = src._log_tag, rec._log_tag
    assert(type(src_tag) == "string" and type(rec_tag) == "string",
        "both engines must carry a string log tag after load")
    assert(src_tag ~= rec_tag, string.format(
        "the two roles' tags must differ (operator log correlation); "
        .. "both are '%s'", src_tag))
    assert(src_tag:find("source", 1, true) and rec_tag:find("record", 1, true),
        string.format("each tag must name its role: source='%s' record='%s'",
            src_tag, rec_tag))
    assert(not src_tag:find("unloaded", 1, true)
        and not rec_tag:find("unloaded", 1, true), string.format(
        "after a load the unloaded sentinel must be gone: source='%s' record='%s'",
        src_tag, rec_tag))

    print(string.format("  PASS: '%s' ≠ '%s', both role-named", src_tag, rec_tag))
end

-- ════════════════════════════════════════════════════════════════════════════
-- LT-4  FR-001 role/kind invariant enforced loudly
-- ════════════════════════════════════════════════════════════════════════════
print("\n-- (LT-4) source engine refuses a timeline sequence (FR-001) --")
do
    local src = transport.engine_for_role("source")
    local ok, err = pcall(function() src:load("tl_lt") end)
    assert(not ok, "loading a timeline sequence into a source engine must error")
    assert(tostring(err):find("kind mismatch", 1, true), string.format(
        "the FR-001 error must name the kind mismatch; got: %s", tostring(err)))
    print("  PASS: kind mismatch asserts loudly")
end

print("\n✅ test_playback_engine_log_tag.lua passed")
