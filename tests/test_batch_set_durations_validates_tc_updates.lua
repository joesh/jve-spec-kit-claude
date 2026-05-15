#!/usr/bin/env luajit
--- NSF input-validation contract for Media.batch_set_durations tc_updates
---
--- Half 1 of NSF: validate caller preconditions at the function boundary.
--- `tc_updates` carries the probed TC origin that the function uses to
--- rebase media_refs.timeline_start_frame / source_in_frame / source_out
--- _frame. A bad value here lands directly in the DB columns — SQL has
--- no CHECK constraint on negative origin, and the next resolver call
--- silently produces wrong coverage. (Live precedent for the symptom:
--- TSO 2026-05-15 12:20:21 — stale TC origin → phantom gaps. Same
--- damage class if tc_updates were ever malformed.)
---
--- Contract:
---   tc_updates entries must be tables. Their start_tc_value /
---   start_tc_audio_samples (when present) must be non-negative
---   integers. Anything else asserts at the function boundary, not
---   ten minutes later when a clip plays black mid-render.

require("test_env")

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_batch_set_durations_validates_tc_updates.lua ===")

local database = require("core.database")
local uuid = require("uuid")
local json = require("dkjson")
local Media = require("models.media")
local Sequence = require("models.sequence")

local TEST_DB = "/tmp/jve/test_batch_set_durations_validates_tc_updates.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-nsf"
local media_id = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'P', 'resample', %d, %d, '{}');
]], project_id, now, now))

local media = Media.create({
    id = media_id, project_id = project_id,
    file_path = "/x/file.mov", name = "file.mov",
    duration_frames = 100,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
    audio_channels = 2, audio_sample_rate = 48000,
    metadata = json.encode({
        start_tc_value = 1000, start_tc_rate = 25,
        start_tc_audio_samples = 1920000, start_tc_audio_rate = 48000,
    }),
})
media:save(db)
Sequence.ensure_master(media_id, project_id)

local function expect_assert(label, fn)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert, but call succeeded")
    print(string.format("  ✓ %s: %s", label, tostring(err):match("[^\n]+")))
end

local good_dur = { [media_id] = { duration_frames = 50, audio_duration_samples = 96000 } }

print("\n--- tc_updates entry must be a table ---")
expect_assert("non-table tc_updates entry", function()
    Media.batch_set_durations(good_dur, { [media_id] = "bogus" })
end)

print("\n--- tc_updates.start_tc_value: type + sign + integer ---")
expect_assert("string start_tc_value", function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = "100", start_tc_audio_samples = 192000 },
    })
end)
expect_assert("negative start_tc_value", function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = -1, start_tc_audio_samples = 192000 },
    })
end)
expect_assert("fractional start_tc_value", function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = 1.5, start_tc_audio_samples = 192000 },
    })
end)

print("\n--- tc_updates.start_tc_audio_samples: type + sign + integer ---")
expect_assert("negative start_tc_audio_samples", function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = 100, start_tc_audio_samples = -1 },
    })
end)
expect_assert("fractional start_tc_audio_samples", function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = 100, start_tc_audio_samples = 0.5 },
    })
end)
expect_assert("string start_tc_audio_samples", function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = 100, start_tc_audio_samples = "x" },
    })
end)

print("\n--- happy path: well-formed tc_updates accepted ---")
local ok, err = pcall(function()
    Media.batch_set_durations(good_dur, {
        [media_id] = { start_tc_value = 100, start_tc_audio_samples = 192000 },
    })
end)
assert(ok, "well-formed tc_updates must succeed: " .. tostring(err))
print("  ✓ accepts {start_tc_value=100, start_tc_audio_samples=192000}")

print("\n✅ test_batch_set_durations_validates_tc_updates.lua passed")
