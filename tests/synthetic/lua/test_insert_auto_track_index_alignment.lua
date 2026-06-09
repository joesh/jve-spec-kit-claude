#!/usr/bin/env luajit

-- Regression: when patches route source audio to a record track index
-- HIGHER than any existing record track, Insert auto-pads the missing
-- intermediates. Those auto-pad tracks must land at the EXACT
-- track_index dictated by the patches — not at MAX(existing_index)+1.
--
-- Bug surfaced during 015 audit: insert.lua's auto_create_record_audio_tracks
-- looped `for i = rec_count+1, max_rec_idx` and called Track.create_audio
-- without `index = i`. Track.determine_next_index returns MAX(track_index)+1
-- when no index opt is passed, which misroutes whenever existing record
-- tracks are non-contiguous (e.g. user deleted A2 leaving A1+A3, or
-- importers placed at sparse indices).
--
-- Black-box assertion: after Insert with a patch routing source A1→rec A5,
-- the rec sequence must have an AUDIO track at track_index=5 (not 6, not
-- 4, not "next available").

require("test_env")
local database = require("core.database")

local DB = "/tmp/jve/test_insert_auto_track_index_alignment.db"

local function fresh_db()
    os.remove(DB)
    assert(database.init(DB), "schema.sql init failed")
    return database.get_connection()
end

print("=== test_insert_auto_track_index_alignment.lua ===")

local db = fresh_db()

-- Rec sequence has A1@idx=1 and A3@idx=3 (NON-CONTIGUOUS — A2 missing).
-- Source has a single A1. Patch routes source A1→rec A5 (skipping A2/A4).
-- After Insert, rec sequence must contain A tracks at indices {1,2,3,4,5}
-- with the new tracks at EXACTLY 2, 4, 5.
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p1', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m', 'p1', 'src',  'master',   24, 1, NULL, 1920, 1080, 0, 0),
           ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
           ('e-a1', 'e', 'A1', 'AUDIO', 1),
           ('e-a3', 'e', 'A3', 'AUDIO', 3);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels,
        created_at, modified_at)
    VALUES ('a',   'p1', 'a.wav', '/tmp/a.wav', 200000, 48000, 1, 1, 0, 0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-a','p1','m','m-a1','a', 0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO patches (id, sequence_id, track_type, source_shape,
        source_track_index, record_track_index, enabled, created_at)
    VALUES ('p-a1','e','AUDIO',1,1,5,1,0);
]]))
require("test_env").touch_media_fixtures()

-- Route through command_manager so the dispatched executor runs the pre-
-- placement auto_create_record_audio_tracks pass (the buggy site). Calling
-- Insert.execute() directly skips it.
local command_manager = require("core.command_manager")
command_manager.init("e", "p1")
local r = command_manager.execute("Insert", {
    sequence_id          = "e",
    source_sequence_id   = "m",
    sequence_start_frame = 0,
    -- project_id must be passed explicitly when the test runner doesn't
    -- guarantee a fresh command_manager state across tests.
    project_id           = "p1",
})
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))

-- Query the rec sequence's AUDIO tracks and assert {1,2,3,4,5} present,
-- exactly. No duplicates. Domain assertion: patch said rec_idx=5 → there
-- must be a track at index=5 and the inserted clip must live there.
local s = db:prepare(
    "SELECT track_index, id FROM tracks "
    .. "WHERE sequence_id='e' AND track_type='AUDIO' "
    .. "ORDER BY track_index ASC")
assert(s:exec())
local indices = {}
local id_at = {}
while s:next() do
    local idx = s:value(0)
    indices[#indices + 1] = idx
    id_at[idx] = s:value(1)
end
s:finalize()

local function fmt_list(t)
    local parts = {}
    for _, v in ipairs(t) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, ",")
end

assert(#indices == 5, string.format(
    "rec sequence must have exactly 5 AUDIO tracks after Insert "
    .. "(A1 existed + A3 existed + 3 auto-padded to reach patch rec_idx=5); "
    .. "got %d: [%s]", #indices, fmt_list(indices)))
for want = 1, 5 do
    assert(indices[want] == want, string.format(
        "rec AUDIO tracks must occupy contiguous indices 1..5; "
        .. "expected track_index=%d at position %d, got [%s]",
        want, want, fmt_list(indices)))
end

-- The inserted clip must land on the rec_idx=5 track, not on some
-- misaligned auto-created track.
local c = db:prepare(
    "SELECT track_id FROM clips WHERE owner_sequence_id='e'")
assert(c:exec() and c:next(),
    "Insert must have produced exactly one rec-owner audio clip")
local clip_track_id = c:value(0)
c:finalize()
assert(clip_track_id == id_at[5], string.format(
    "Insert clip must land on rec track at index=5 (patch target); "
    .. "got track_id=%s, expected id at index=5 was %s",
    tostring(clip_track_id), tostring(id_at[5])))

print("  patch A1→A5 routed to track_index=5 across non-contiguous prior state — OK")
print("\n✅ test_insert_auto_track_index_alignment.lua passed")
