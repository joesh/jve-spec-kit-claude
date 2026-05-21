#!/usr/bin/env luajit
--- SetPlayhead command — integer form + TC-string positional alias.
---
--- SetPlayhead accepts a playhead in two equivalent forms:
---   • named:      { playhead_position = 120 }
---   • positional: { _positional = { "00:00:05:00" } }
--- The string form parses via core.frame_utils.parse_timecode against the
--- sequence's frame_rate; both resolve to the same integer TC-absolute frame.
--- The TC-string alias is purely a convenience layer — same model write,
--- same playhead_changed emission, same View-listener engine sync.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")

print("=== test_set_playhead.lua ===")

-- Harness identical in shape to test_mark_commands.lua.
local db_path = "/tmp/jve/test_set_playhead.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('project', 'Test', 'resample',
        '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

-- 24fps sequence — "00:00:05:00" = 120 frames; "00:00:10:00" = 240 frames.
local seq = Sequence.create("Test Timeline", "project",
    { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { kind = "sequence", id = "seq_1", audio_sample_rate = 48000 })
assert(seq:save(), "setup: failed to save sequence")

command_manager.init("seq_1", "project")

local function execute_cmd(params)
    params.project_id = params.project_id or "project"
    command_manager.begin_command_event("script")
    local result = command_manager.execute("SetPlayhead", params)
    command_manager.end_command_event()
    return result
end

-- Track playhead_changed signal payloads.
local emissions = {}
Signals.connect("playhead_changed", function(seq_id, frame)
    emissions[#emissions + 1] = { seq_id = seq_id, frame = frame }
end)

local pass_count, fail_count = 0, 0
local function check(label, ok, msg)
    if ok then
        pass_count = pass_count + 1
        print("  ✓ " .. label)
    else
        fail_count = fail_count + 1
        print("  ✗ " .. label .. (msg and ("  — " .. msg) or ""))
    end
end

-- ─── Regression: integer form still works (every existing caller) ────────

do
    emissions = {}
    local r = execute_cmd({ sequence_id = "seq_1", playhead_position = 42 })
    check("integer form succeeds", r.success, tostring(r.error_message))
    check("integer form persists frame", Sequence.load("seq_1").playhead_position == 42)
    check("integer form emits playhead_changed",
        #emissions == 1 and emissions[1].frame == 42)
end

-- ─── New: TC-string positional form ──────────────────────────────────────

do
    emissions = {}
    local r = execute_cmd({ sequence_id = "seq_1", _positional = { "00:00:05:00" } })
    check("TC-string '00:00:05:00' at 24fps succeeds", r.success, tostring(r.error_message))
    check("TC-string resolves to frame 120 (5s × 24fps)",
        Sequence.load("seq_1").playhead_position == 120)
    check("TC-string form emits playhead_changed at frame 120",
        #emissions == 1 and emissions[1].frame == 120)
end

do
    -- "01:00:00:00" at 24fps = 86400 frames (one TC hour). Pins the
    -- HH carry — earlier parsers truncated past the seconds field.
    local r = execute_cmd({ sequence_id = "seq_1", _positional = { "01:00:00:00" } })
    check("TC-string '01:00:00:00' at 24fps succeeds", r.success)
    check("TC-string resolves to 86400 (1h × 3600s × 24fps)",
        Sequence.load("seq_1").playhead_position == 86400)
end

do
    -- Negative TC consistent with frame_utils.parse_timecode signed support.
    local r = execute_cmd({ sequence_id = "seq_1", _positional = { "-00:00:05:00" } })
    check("TC-string '-00:00:05:00' resolves to -120",
        r.success and Sequence.load("seq_1").playhead_position == -120)
end

-- ─── Error paths — NSF: must fail loud, not silently substitute ──────────

do
    -- Both forms supplied → ambiguous; loud fail.
    local ok, err = pcall(execute_cmd, {
        sequence_id = "seq_1", playhead_position = 10, _positional = { "00:00:01:00" } })
    -- command_manager wraps the assert; check for the message either in the
    -- pcall error or in result.error_message.
    local message
    if not ok then
        message = tostring(err)
    else
        message = tostring((err and err.error_message) or "")
    end
    check("both forms supplied fails loud",
        message:find("exactly one of") ~= nil,
        "expected XOR error; got: " .. message)
end

do
    -- Neither form supplied → missing arg; loud fail.
    local ok, err = pcall(execute_cmd, { sequence_id = "seq_1" })
    local message
    if not ok then
        message = tostring(err)
    else
        message = tostring((err and err.error_message) or "")
    end
    check("neither form supplied fails loud",
        message:find("exactly one of") ~= nil,
        "expected XOR error; got: " .. message)
end

do
    -- Malformed TC → parse failure; loud fail.
    local ok, err = pcall(execute_cmd, {
        sequence_id = "seq_1", _positional = { "not-a-timecode" } })
    local message
    if not ok then
        message = tostring(err)
    else
        message = tostring((err and err.error_message) or "")
    end
    check("malformed TC string fails loud",
        message:find("parse TC") ~= nil or message:find("expected HH") ~= nil,
        "expected parse error; got: " .. message)
end

do
    -- Unknown sequence → loud fail (regression-pinning the existing assert).
    local ok, err = pcall(execute_cmd, {
        sequence_id = "no-such-seq", playhead_position = 1 })
    local message
    if not ok then
        message = tostring(err)
    else
        message = tostring((err and err.error_message) or "")
    end
    check("unknown sequence_id fails loud",
        message:find("sequence not found") ~= nil,
        "expected not-found error; got: " .. message)
end

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, "test_set_playhead.lua: some assertions failed")
print("✅ test_set_playhead.lua passed")
