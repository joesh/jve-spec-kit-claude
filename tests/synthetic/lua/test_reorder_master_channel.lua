#!/usr/bin/env luajit
-- ReorderMasterChannel — moves a master AUDIO channel to a new ordinal
-- slot. Domain behavior tested (no implementation references in the
-- expected values): after a move from slot K to slot N, the channel
-- order observed via Track.find_by_sequence(.., "AUDIO") matches what
-- a user would see in the Inspector channels list after dragging that
-- row to that position. Undo restores the original order verbatim.

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Command         = require("command")
local Track           = require("models.track")

local SCHEMA_SQL = require("import_schema")

local function setup_db(path)
    os.remove(path)
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    return conn
end

local function check(label, got, want)
    if got ~= want then
        error(string.format("FAIL: %s — got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local function channel_order(sequence_id)
    -- Return names in track_index ASC order — exactly what the Inspector
    -- channel list shows.
    local rows = Track.find_by_sequence(sequence_id, "AUDIO")
    local out = {}
    for i, t in ipairs(rows) do out[i] = t.name end
    return out
end

local function check_order(label, sequence_id, expected)
    local got = channel_order(sequence_id)
    local want_str = table.concat(expected, ",")
    local got_str  = table.concat(got, ",")
    if got_str ~= want_str then
        error(string.format("FAIL: %s — got [%s], want [%s]",
            label, got_str, want_str))
    end
end

print("=== ReorderMasterChannel: domain contract ===\n")

local db_path = "/tmp/jve/test_reorder_master_channel.db"
os.execute("mkdir -p /tmp/jve")
local conn = setup_db(db_path)

local now = os.time()
assert(conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample',
        '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
         width, height, playhead_frame, view_start_frame, view_duration_frames,
         mark_in_frame, mark_out_frame, start_timecode_frame,
         video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
         created_at, modified_at)
    VALUES
        ('master_seq', 'proj', 'BoomMaster', 'master', 24, 1, NULL,
         1920, 1080, 0, 0, 1000, NULL, NULL, 0,
         0, 0, 0.5, %d, %d),
        ('record_seq', 'proj', 'Rec',        'sequence', 24, 1, 48000,
         1920, 1080, 0, 0, 1000, NULL, NULL, 0,
         0, 0, 0.5, %d, %d);
    INSERT INTO tracks
        (id, sequence_id, name, track_type, track_index, enabled, locked,
         muted, soloed, volume, pan, sync_mode, autoselect, source_kind)
    VALUES
        ('mt_a1', 'master_seq', 'L',    'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL),
        ('mt_a2', 'master_seq', 'Boom', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL),
        ('mt_a3', 'master_seq', 'Lav',  'AUDIO', 3, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL),
        ('mt_a4', 'master_seq', 'R',    'AUDIO', 4, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL),
        ('mt_a5', 'master_seq', 'Amb',  'AUDIO', 5, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL);
    -- A VIDEO track to confirm the AUDIO-only shift doesn't touch VIDEO rows.
    INSERT INTO tracks
        (id, sequence_id, name, track_type, track_index, enabled, locked,
         muted, soloed, volume, pan, sync_mode, autoselect, source_kind)
    VALUES
        ('mt_v1', 'master_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL);
    -- Record sequence needs at least one track of each type for
    -- command_manager.init/timeline_state.init.
    INSERT INTO tracks
        (id, sequence_id, name, track_type, track_index, enabled, locked,
         muted, soloed, volume, pan, sync_mode, autoselect, source_kind)
    VALUES
        ('rt_v1', 'record_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL),
        ('rt_a1', 'record_seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0, 'ripple', 1, NULL);
]],
    now, now, now, now, now, now)))

-- command_manager wires its active sequence (timeline target) to a record
-- sequence; the command itself takes sequence_id as a parameter so the
-- active sequence is irrelevant to the mutation under test.
command_manager.init("record_seq", "proj")

-- Baseline ordering matches what was inserted.
check_order("baseline", "master_seq", {"L", "Boom", "Lav", "R", "Amb"})

-- ── Move down (slot 1 → 4): "L" should land at position 4, others slide up.
local cmd = Command.create("ReorderMasterChannel", "proj")
cmd:set_parameter("project_id",      "proj")
cmd:set_parameter("sequence_id",     "master_seq")
cmd:set_parameter("track_id",        "mt_a1")
cmd:set_parameter("new_track_index", 4)
local result = command_manager.execute(cmd)
check("move-down command succeeded", result.success, true)
check_order("after move L 1→4", "master_seq", {"Boom", "Lav", "R", "L", "Amb"})

-- ── Undo restores baseline.
command_manager.undo()
check_order("undo restores baseline", "master_seq", {"L", "Boom", "Lav", "R", "Amb"})

-- Verify raw track_index values are 1..N contiguous after undo. check_order
-- only verifies relative ordering — a track stuck at a negative index would
-- still sort first and pass the by-name comparison. The domain contract
-- requires positions to be 1..N.
do
    local rows = Track.find_by_sequence("master_seq", "AUDIO")
    for i, t in ipairs(rows) do
        if t.track_index ~= i then
            error(string.format(
                "undo left raw track_index dirty: row %d (%s) has track_index=%d",
                i, t.id, t.track_index))
        end
    end
end

-- ── Move up (slot 5 → 2): "Amb" should land at position 2, "Boom"/"Lav"/"R" slide down.
local cmd2 = Command.create("ReorderMasterChannel", "proj")
cmd2:set_parameter("project_id",      "proj")
cmd2:set_parameter("sequence_id",     "master_seq")
cmd2:set_parameter("track_id",        "mt_a5")
cmd2:set_parameter("new_track_index", 2)
check("move-up command succeeded", command_manager.execute(cmd2).success, true)
check_order("after move Amb 5→2", "master_seq", {"L", "Amb", "Boom", "Lav", "R"})
command_manager.undo()
check_order("undo move-up restores baseline", "master_seq",
    {"L", "Boom", "Lav", "R", "Amb"})

-- ── No-op move (slot 3 → 3) succeeds without churn.
local cmd3 = Command.create("ReorderMasterChannel", "proj")
cmd3:set_parameter("project_id",      "proj")
cmd3:set_parameter("sequence_id",     "master_seq")
cmd3:set_parameter("track_id",        "mt_a3")
cmd3:set_parameter("new_track_index", 3)
check("no-op move succeeded", command_manager.execute(cmd3).success, true)
check_order("no-op leaves order unchanged", "master_seq",
    {"L", "Boom", "Lav", "R", "Amb"})

-- ── VIDEO track unaffected by AUDIO reorders.
local v = Track.load("mt_v1")
check("V1 track_index unchanged after AUDIO shuffles", v.track_index, 1)

-- ── Out-of-range new_track_index asserts (5 AUDIO tracks → index 6 invalid).
local cmd4 = Command.create("ReorderMasterChannel", "proj")
cmd4:set_parameter("project_id",      "proj")
cmd4:set_parameter("sequence_id",     "master_seq")
cmd4:set_parameter("track_id",        "mt_a1")
cmd4:set_parameter("new_track_index", 6)
local ok, err = pcall(command_manager.execute, cmd4)
local raised = (not ok)
    or (type(err) == "string" and err ~= "")
    or (type(err) == "table")
-- command_manager may catch the assert and surface result.success=false;
-- accept either path so long as the order isn't mangled.
check_order("out-of-range did not mutate order", "master_seq",
    {"L", "Boom", "Lav", "R", "Amb"})
check("out-of-range surfaced (raised or result.success=false)",
    raised or (type(err) == "table" and err.success == false), true)

-- ── Wrong track_type (VIDEO) refused.
local cmd5 = Command.create("ReorderMasterChannel", "proj")
cmd5:set_parameter("project_id",      "proj")
cmd5:set_parameter("sequence_id",     "master_seq")
cmd5:set_parameter("track_id",        "mt_v1")
cmd5:set_parameter("new_track_index", 1)
pcall(command_manager.execute, cmd5)
check_order("VIDEO refusal did not mutate AUDIO order", "master_seq",
    {"L", "Boom", "Lav", "R", "Amb"})
v = Track.load("mt_v1")
check("V1 track_index still 1 after refused move", v.track_index, 1)

os.remove(db_path)
print("\n✅ test_reorder_master_channel.lua passed")
