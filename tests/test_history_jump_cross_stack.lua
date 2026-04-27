#!/usr/bin/env luajit
-- Jumping to any visible past command must land the merged-view cursor
-- at that command, regardless of which stack (active-sequence or global)
-- the target lives on. With per-sequence + global stacks, walking or
-- terminating by a single stack's cursor is insufficient.

local test_env = require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Command         = require("command")
local Media           = require("models.media")
local history         = require("core.command_history")

--------------------------------------------------------------------------------
-- Test harness helpers
--------------------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_history_jump_cross_stack.db"

local function reset_db()
    os.remove(TEST_DB)
    os.remove(TEST_DB .. "-wal")
    os.remove(TEST_DB .. "-shm")
    database.init(TEST_DB)
    return database.get_connection()
end

local function seed_project(db, project_id, sequence_id, track_id)
    db:exec(require("import_schema"))
    local now = os.time()
    db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
          VALUES ('%s', 'P', 'resample', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            playhead_frame, view_start_frame, view_duration_frames,
            selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at)
          VALUES ('%s', '%s', 'S', 'nested', 25, 1, 48000, 1920, 1080,
                  0, 0, 240, '[]', '[]', '[]', 0, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
            enabled, locked, muted, soloed, volume, pan)
          VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    ]], project_id, now, now, sequence_id, project_id, now, now,
        track_id, sequence_id))
    return now
end

local function seed_media(db, project_id, media_id)
    local m = Media.create({
        id = media_id, project_id = project_id,
        file_path = "/tmp/jve/" .. media_id .. ".mov", name = media_id .. ".mov",
        duration_frames = 500,
        fps_numerator = 25, fps_denominator = 1,
        width = 1920, height = 1080,
    })
    assert(m:save(db), "media save")
    return test_env.create_test_masterclip_sequence(
        project_id, "MC-" .. media_id, 25, 1, 500, media_id)
end

local function new_bin(project_id, name)
    local c = Command.create("NewBin", project_id)
    c:set_parameter("bin_id", "bin_" .. name)
    c:set_parameter("name", name)
    local r = command_manager.execute(c)
    assert(r.success, "NewBin(" .. name .. ") failed: " .. tostring(r.error_message))
    return c.sequence_number
end

-- V13: Insert generates a uuid for the new clip. Return it so callers
-- can address the clip by its actual id. Set narrow marks on the
-- master so the inserted clip is small enough not to overlap the next.
local function insert_clip(project_id, sequence_id, track_id, master_id, clip_id, t)
    do
        local mc = require("models.sequence").load(master_id)
        if mc then
            mc.mark_in = 0
            mc.mark_out = 50
            mc:save()
        end
    end
    local c = Command.create("Insert", project_id)
    c:set_parameter("sequence_id", sequence_id)
    c:set_parameter("target_video_track_id", track_id)
    c:set_parameter("nested_sequence_id", master_id)
    c:set_parameter("clip_name", clip_id)
    c:set_parameter("timeline_start_frame", t)
    local r = command_manager.execute(c)
    assert(r.success, "Insert(" .. clip_id .. ") failed: " .. tostring(r.error_message))
    local cmd_obj = Command.deserialize(r.result_data)
    return cmd_obj.parameters.created_clip_ids
        and cmd_obj.parameters.created_clip_ids[1]
end

local function clip_exists(db, id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n > 0
end

local function merged_cursor(seq_id)
    return math.max(history.get_global_cursor() or 0,
                    history.get_sequence_cursor(seq_id) or 0)
end

--------------------------------------------------------------------------------
-- Scenario 1: NewBin (global) → Insert (sequence). Jump back to NewBin.
--------------------------------------------------------------------------------

local db = reset_db()
seed_project(db, "proj", "seq", "v1")
local mc_id = seed_media(db, "proj", "m1")
command_manager.init("seq", "proj")

local newbin_seq = new_bin("proj", "Alpha")
assert(history.get_global_cursor() == newbin_seq,
    "NewBin must advance the global cursor")

local clip_a_id = insert_clip("proj", "seq", "v1", mc_id, "clip_a", 0)
assert(history.get_sequence_cursor("seq") > newbin_seq,
    "Insert must advance the sequence cursor past NewBin")
assert(history.get_global_cursor() == newbin_seq,
    "Insert must NOT touch the global cursor")
assert(clip_exists(db, clip_a_id), "clip_a must exist after Insert")

local ok, err = command_manager:jump_to_sequence_number(newbin_seq)
assert(ok, "jump to global target failed: " .. tostring(err))
assert(merged_cursor("seq") == newbin_seq,
    "merged cursor must land at NewBin after jump")
assert(not clip_exists(db, clip_a_id),
    "clip_a must be removed by undoing Insert during jump")

--------------------------------------------------------------------------------
-- Scenario 2: seq cmd → global cmd → seq cmd. Jump back past the global.
-- The seq cursor's parent-chain walk must not undo past the target.
--------------------------------------------------------------------------------

local clip_a2_id = insert_clip("proj", "seq", "v1", mc_id, "clip_a", 0)  -- redo the first clip
local newbin2_seq = new_bin("proj", "Beta")                -- global after seq
local clip_b_id = insert_clip("proj", "seq", "v1", mc_id, "clip_b", 0)  -- seq after global

local ok2, err2 = command_manager:jump_to_sequence_number(newbin2_seq)
assert(ok2, "second jump failed: " .. tostring(err2))
assert(merged_cursor("seq") == newbin2_seq,
    "merged cursor must land at NewBin2 after second jump")
assert(history.get_global_cursor() == newbin2_seq,
    "global cursor must not be undone past NewBin2")
assert(not clip_exists(db, clip_b_id),
    "clip_b must be removed by undoing post-NewBin2 Insert")
assert(clip_exists(db, clip_a2_id),
    "clip_a must remain (it pre-dates NewBin2)")

--------------------------------------------------------------------------------
-- Scenario 3: jump to provenance (target = 0) when the sequence cursor
-- has walked its parent_sequence_number chain across a stack boundary
-- and now holds a global command's seq_number. Without a scope-filter
-- the merged-undo picker would re-undo that global cmd.
--------------------------------------------------------------------------------

db = reset_db()
local now2 = seed_project(db, "p2", "s2", "t2")
db:exec(string.format([[
    INSERT INTO commands(id, command_type, command_args, sequence_number,
                         parent_sequence_number, timestamp, sequence_id, project_id)
      VALUES('prov-1', 'ImportResolveProject', '{}', 0, -1, %d, NULL, 'p2');
]], now2))
local mc_id2 = seed_media(db, "p2", "m2")
command_manager.init("s2", "p2")

new_bin("p2", "g1")                                         -- global at seq=1
insert_clip("p2", "s2", "t2", mc_id2, "clip_x", 0)          -- seq after global
insert_clip("p2", "s2", "t2", mc_id2, "clip_y", 100)        -- seq after seq

local ok3, err3 = command_manager:jump_to_sequence_number(0)
assert(ok3, "jump to provenance failed: " .. tostring(err3))

-- User-visible "current" must be at provenance: nothing to undo on either
-- visible stack. The raw sequence cursor may still hold a parent-chain
-- placeholder pointing at a global command's seq_number — internal
-- artifact; what matters is that no undo target can be found.
assert(not command_manager.can_undo(),
    "after jump to provenance, can_undo() must be false")
assert(history.find_merged_undo_target("s2") == nil,
    "after jump to provenance, no merged undo target must remain")

--------------------------------------------------------------------------------
-- Error paths: invalid target, unknown target.
--------------------------------------------------------------------------------

local bad_ok, bad_err = command_manager:jump_to_sequence_number(-1)
assert(not bad_ok and bad_err == "Invalid target sequence number",
    "negative target must error; got ok=" .. tostring(bad_ok) ..
    " err=" .. tostring(bad_err))

bad_ok, bad_err = command_manager:jump_to_sequence_number("nope")
assert(not bad_ok and bad_err == "Invalid target sequence number",
    "non-number target must error; got ok=" .. tostring(bad_ok) ..
    " err=" .. tostring(bad_err))

bad_ok, bad_err = command_manager:jump_to_sequence_number(9999)
assert(not bad_ok and bad_err and bad_err:find("Unknown sequence number"),
    "target not in DB must error; got ok=" .. tostring(bad_ok) ..
    " err=" .. tostring(bad_err))

print("✅ test_history_jump_cross_stack.lua passed")
