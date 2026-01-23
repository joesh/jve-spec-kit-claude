#!/usr/bin/env luajit

-- Ensure timeline viewport (start/duration) persists across restart.

package.path = "../src/lua/?.lua;../src/lua/?/init.lua;../tests/?.lua;" .. package.path

require('test_env')

local database = require('core.database')
local timeline_state = require('ui.timeline.timeline_state')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

local TEST_DB = "/tmp/jve/test_timeline_viewport_persistence.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()

-- Minimal schema + rows
db:exec(require('import_schema'))
db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                           view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 24, 1, 48000, 1920, 1080,
            0, 240, 0, strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- First init uses defaults from DB
assert(timeline_state.init('default_sequence'))
command_manager.init('default_sequence', 'default_project')

local start_before = timeline_state.get_viewport_start_time()
local dur_before = timeline_state.get_viewport_duration()
assert(start_before.frames == 0, "initial viewport start should be 0")
assert(dur_before.frames == 240, "initial viewport duration should be 240")

-- Change zoom window and persist
local new_start = Rational.new(120, 24, 1)
local new_dur = Rational.new(600, 24, 1)
timeline_state.set_viewport_duration(new_dur)
timeline_state.set_viewport_start_time(new_start)
timeline_state.persist_state_to_db(true)

-- Simulate restart by resetting state and re-initing
timeline_state.reset()
assert(timeline_state.init('default_sequence'))

local start_after = timeline_state.get_viewport_start_time()
local dur_after = timeline_state.get_viewport_duration()

assert(start_after.frames == new_start.frames and start_after.fps_numerator == 24 and start_after.fps_denominator == 1,
    string.format("restored viewport start mismatch (expected %d, got %s)", new_start.frames, tostring(start_after.frames)))
assert(dur_after.frames == new_dur.frames and dur_after.fps_numerator == 24 and dur_after.fps_denominator == 1,
    string.format("restored viewport duration mismatch (expected %d, got %s)", new_dur.frames, tostring(dur_after.frames)))

os.remove(TEST_DB)
print("✅ Timeline viewport start/duration persisted across restart")
