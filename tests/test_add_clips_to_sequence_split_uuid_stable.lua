#!/usr/bin/env luajit
-- Regression test: AddClipsToSequence overwrite that triggers a straddle
-- split on the target track must preserve the split right-half's UUID
-- across execute → undo → redo.
--
-- Bug class: pass 19a–19c established the id_pool pattern for Insert/
-- Overwrite/ExtractRange. AddClipsToSequence still passes an EMPTY
-- `id_pool.new()` to `occlude_track`, so a redo mints a fresh uuid
-- instead of replaying the original.
--
-- Domain contract: undo+redo must restore the exact same set of clip
-- ids, because downstream commands (link groups, history, future edits
-- that reference the right-half by id) rely on id stability across
-- redo. A different right-half uuid post-redo is a model corruption.
--
-- Black-box check: capture the right-half uuid after execute, undo,
-- redo, then compare. No tracing of how the pool seeds itself —
-- domain says "same id."

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Media = require('models.media')
local command_manager = require('core.command_manager')

print("=== AddClipsToSequence Split-UUID-Stable Test ===\n")

local db_path = "/tmp/jve/test_add_clips_split_uuid.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'seq', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('seq', 'proj')

local media = Media.create({
    id = "media_a", project_id = "proj",
    file_path = "/tmp/jve/a.mov", name = "A",
    duration_frames = 200, fps_numerator = 24, fps_denominator = 1,
    width = 1920, height = 1080, audio_channels = 0,
})
media:save(db)

local test_env = require("test_env")
local master_a = test_env.create_test_masterclip_sequence("proj", "Master A", 24, 1, 200, "media_a")
local master_b = test_env.create_test_masterclip_sequence("proj", "Master B", 24, 1, 200, "media_a")

-- Query all clip IDs on the timeline track.
local function timeline_clip_ids()
    local ids = {}
    local stmt = db:prepare(
        "SELECT id FROM clips WHERE track_id = 'track_v1' ORDER BY sequence_start_frame")
    stmt:exec()
    while stmt:next() do ids[#ids+1] = stmt:value(0) end
    stmt:finalize()
    return ids
end

local function make_groups(master, dur, name)
    return {
        {
            sequence_id = master,
            duration    = dur,
            clips = {
                {
                    role = "video",
                    media_id = "media_a",
                    sequence_id = master,
                    project_id = "proj",
                    name = name,
                    source_in = 0,
                    source_out = dur,
                    duration = dur,
                    fps_numerator = 24,
                    fps_denominator = 1,
                    target_track_id = "track_v1",
                    fps_mismatch_policy = "resample",
                }
            }
        }
    }
end

local function exec_overwrite(groups, position)
    command_manager.begin_command_event("test")
    local r = command_manager.execute("AddClipsToSequence", {
        groups = groups,
        position = position,
        sequence_id = "seq",
        project_id = "proj",
        edit_type = "overwrite",
        arrangement = "serial",
    })
    command_manager.end_command_event()
    assert(r and r.success, "execute failed: " ..
        tostring(r and r.error_message or "nil result"))
end

-- Phase 0: place a wide clip [0, 200) on track_v1. This is the
-- "existing" clip that the next overwrite will straddle-split.
exec_overwrite(make_groups(master_b, 200, "Orig"), 0)
local pre = timeline_clip_ids()
assert(#pre == 1, "expected 1 clip after seed, got " .. #pre)
local orig_id = pre[1]
print(string.format("  seed clip id: %s", orig_id))

-- ---------- execute: straddle split at [50, 100) ----------
exec_overwrite(make_groups(master_a, 50, "New"), 50)
local after_exec = timeline_clip_ids()
-- Expect 3 clips: left half (clip_orig, [0,50)), new clip ([50,100)),
-- right half ([100,200)) with a fresh uuid.
assert(#after_exec == 3, string.format(
    "expected 3 clips after execute, got %d: [%s]",
    #after_exec, table.concat(after_exec, ",")))

local function find_split_right_half(ids)
    -- The split right-half: at sequence_start=100 with duration covering
    -- [100, 200) (the tail of the original wide clip).
    for _, cid in ipairs(ids) do
        local stmt = db:prepare(
            "SELECT sequence_start_frame, duration_frames FROM clips WHERE id = ?")
        stmt:bind_value(1, cid)
        stmt:exec()
        stmt:next()
        local start = stmt:value(0)
        local dur   = stmt:value(1)
        stmt:finalize()
        if start == 100 and dur == 100 then return cid end
    end
end

local right_half_id_first = find_split_right_half(after_exec)
assert(right_half_id_first,
    "couldn't locate split right-half (start=100) after execute")
print(string.format("  right-half uuid after execute: %s", right_half_id_first))

-- ---------- undo ----------
assert(command_manager.undo(), "undo failed")
local after_undo = timeline_clip_ids()
assert(#after_undo == 1 and after_undo[1] == orig_id, string.format(
    "expected only seed clip %s after undo, got: [%s]",
    orig_id, table.concat(after_undo, ",")))

-- ---------- redo ----------
assert(command_manager.redo(), "redo failed")
local after_redo = timeline_clip_ids()
assert(#after_redo == 3, string.format(
    "expected 3 clips after redo, got %d: [%s]",
    #after_redo, table.concat(after_redo, ",")))

local right_half_id_second = find_split_right_half(after_redo)
assert(right_half_id_second,
    "couldn't locate split right-half (start=100) after redo")
print(string.format("  right-half uuid after redo:    %s", right_half_id_second))

assert(right_half_id_first == right_half_id_second, string.format(
    "split right-half uuid changed across redo: first=%s second=%s",
    right_half_id_first, right_half_id_second))

print("\n✅ test_add_clips_to_sequence_split_uuid_stable.lua passed")
