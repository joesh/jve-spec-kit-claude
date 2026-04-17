#!/usr/bin/env luajit

-- Regression: opening a project that has no saved tab state must leave the
-- editor in the no-active-sequence state. The old behavior silently fell back
-- to Sequence.find_most_recent() / sequences[1]; that fallback is removed
-- per feature 010 FR-004 (principle VIII: no backward compatibility).
--
-- Domain behavior under test:
--   * A project that exists with sequences but has no last_open_sequence_id
--     setting and no (or empty) open_sequence_ids setting must resolve to
--     "no active sequence" — the caller (layout) then opens blank.
--   * A project whose last_open_sequence_id names a valid sequence must
--     still resolve to that sequence (regression guard for the normal path).
--   * A project whose last_open_sequence_id names a deleted sequence must
--     resolve to "no active sequence" (spec: don't resurrect a stale ref).
--
-- Tested via a small model-layer helper `Sequence.resolve_initial_for_project`
-- which replaces the inline find_most_recent / sequences[1] fallback in
-- layout.lua. The helper is pure-Lua (model + DB only, no Qt), so the test
-- runs without --test mode.

require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')

local DB_PATH = "/tmp/jve/test_project_open_no_tab_info.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "db init failed")
local conn = database.get_connection()
conn:exec(require('import_schema'))

local PROJ = "prj-open-test"
local SEQ_OLDEST = "seq-oldest"
local SEQ_NEWEST = "seq-newest"

-- Two sequences, both valid. Newest is what old code's find_most_recent()
-- would have returned silently.
assert(conn:exec(string.format([[
INSERT INTO projects (id, name, created_at, modified_at)
VALUES ('%s', 'Open Test', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame,
    created_at, modified_at)
VALUES
('%s', '%s', 'Oldest', 'timeline', 24, 1, 48000, 1920, 1080, 0, 240, 0,
    strftime('%%s','now') - 100, strftime('%%s','now') - 100),
('%s', '%s', 'Newest', 'timeline', 24, 1, 48000, 1920, 1080, 0, 240, 0,
    strftime('%%s','now'), strftime('%%s','now'));
]], PROJ, SEQ_OLDEST, PROJ, SEQ_NEWEST, PROJ)), "seed insert failed")

print("=== open w/o tab info → blank state contract ===")

local resolve = assert(Sequence.resolve_initial_for_project,
    "Sequence model must expose resolve_initial_for_project(project_id) — "
    .. "this replaces layout.lua's inline find_most_recent fallback")

-- 1. No tab settings at all → nil (blank state)
do
    local seq = resolve(PROJ)
    assert(seq == nil,
        "no tab settings → must return nil (blank state); got "
        .. tostring(seq and seq.id))
    print("  OK: no last_open_sequence_id → resolve returns nil (no fallback)")
end

-- 2. Empty string last_open_sequence_id → nil
do
    database.set_project_setting(PROJ, "last_open_sequence_id", "")
    local seq = resolve(PROJ)
    assert(seq == nil,
        "empty-string last_open_sequence_id must be treated as absent; got "
        .. tostring(seq and seq.id))
    print("  OK: empty last_open_sequence_id → resolve returns nil")
end

-- 3. Valid last_open_sequence_id → returns that sequence (regression guard)
do
    database.set_project_setting(PROJ, "last_open_sequence_id", SEQ_OLDEST)
    local seq = resolve(PROJ)
    assert(seq and seq.id == SEQ_OLDEST,
        "valid last_open_sequence_id must still resolve normally; got "
        .. tostring(seq and seq.id))
    print("  OK: valid last_open_sequence_id → resolves to that sequence")
end

-- 4. Stale last_open_sequence_id (sequence was deleted) → nil
do
    database.set_project_setting(PROJ, "last_open_sequence_id", "seq-does-not-exist")
    local seq = resolve(PROJ)
    assert(seq == nil,
        "stale last_open_sequence_id must resolve to nil (don't resurrect); got "
        .. tostring(seq and seq.id))
    print("  OK: stale last_open_sequence_id → resolve returns nil")
end

print("✅ test_project_open_no_tab_info_stays_blank.lua passed")
