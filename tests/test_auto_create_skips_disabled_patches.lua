#!/usr/bin/env luajit

-- 015 Phase 5: auto-create record audio tracks must NOT include disabled
-- patches in the max-rec-index computation. A disabled patch is the user
-- explicitly saying "drop this channel" — auto-creating a record track
-- for a channel that won't be inserted is wrong (orphan empty track).
--
-- Setup: source has A1, A2, A3. Record has A1 only. Patches:
--   A1 → 1, enabled=1
--   A2 → 5, enabled=0  (disabled — should NOT contribute)
--   A3 → 3, enabled=1
-- Expected after Insert: record has A1..A3 (max enabled rec_idx = 3).
-- Without the gate, the old code or a naive impl would create A1..A5
-- (because the user once routed A2→5).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_auto_create_skips_disabled_patches.lua ===")

local DB = "/tmp/jve/test_auto_create_skips_disabled.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('rec_seq', 'proj', 'Rec', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src_seq', 'proj', 'Src', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

db:exec("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('rec_v1', 'rec_seq', 'V1', 'VIDEO', 1, 1)")
db:exec("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('rec_a1', 'rec_seq', 'A1', 'AUDIO', 1, 1)")
db:exec("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
    .. "VALUES ('src_v1', 'src_seq', 'V1', 'VIDEO', 1, 1)")
for i = 1, 3 do
    db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) "
        .. "VALUES ('src_a%d', 'src_seq', 'A%d', 'AUDIO', %d, 1)", i, i, i))
end

-- Patches: A1→1 enabled, A2→5 DISABLED, A3→3 enabled.
db:exec("INSERT INTO patches (id, sequence_id, track_type, source_track_index, "
    .. "record_track_index, enabled, color, created_at) "
    .. "VALUES ('p_a1', 'rec_seq', 'AUDIO', 1, 1, 1, '#ff0000', 0)")
db:exec("INSERT INTO patches (id, sequence_id, track_type, source_track_index, "
    .. "record_track_index, enabled, color, created_at) "
    .. "VALUES ('p_a2', 'rec_seq', 'AUDIO', 2, 5, 0, '#00ff00', 0)")
db:exec("INSERT INTO patches (id, sequence_id, track_type, source_track_index, "
    .. "record_track_index, enabled, color, created_at) "
    .. "VALUES ('p_a3', 'rec_seq', 'AUDIO', 3, 3, 1, '#0000ff', 0)")

command_manager.init("rec_seq", "proj")

local function count_audio_tracks()
    local s = db:prepare(
        "SELECT COUNT(*) FROM tracks WHERE sequence_id='rec_seq' AND track_type='AUDIO'")
    assert(s); s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

assert(count_audio_tracks() == 1, "fixture: expected 1 audio track on rec_seq")

local r = command_manager.execute("Insert", {
    sequence_id          = "rec_seq",
    project_id           = "proj",
    nested_sequence_id   = "src_seq",
    timeline_start_frame = 0,
})
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))

-- Max enabled rec_idx = 3 (from A3→3). A2→5 is disabled and must NOT count.
-- A1→1 already exists. A2 and A3 created (identity rec_idx=2 for A2's source
-- index falls through since the patch overrides it but the patch is disabled
-- — A2 source channel is excluded entirely; A3 contributes rec_idx=3.
-- Result: A1, A2, A3 — 3 tracks total. NO A4 or A5.
local after = count_audio_tracks()
assert(after == 3, string.format(
    "FAIL: expected 3 audio tracks after Insert (A1+A2+A3, max enabled rec_idx=3); "
    .. "got %d. Disabled A2→5 patch must not auto-create A4/A5.", after))
print(string.format("  audio tracks after Insert: %d (A1..A3) — OK", after))

-- Verify A2 exists (identity routing via source A2 with no enabled patch
-- contribution... wait, A2 patch IS the disabled one; per spec the SOURCE
-- channel A2 is excluded entirely. But identity routing through A3 gives
-- rec_idx=3 which forces tracks 1..3 to exist. So A2 record track does
-- get created as filler to keep the index contiguous.
local s = db:prepare(
    "SELECT track_index FROM tracks WHERE sequence_id='rec_seq' AND track_type='AUDIO' "
    .. "ORDER BY track_index")
assert(s); s:exec()
local indices = {}
while s:next() do indices[#indices+1] = s:value(0) end
s:finalize()
assert(#indices == 3 and indices[1] == 1 and indices[2] == 2 and indices[3] == 3,
    string.format("FAIL: expected indices {1,2,3}, got {%s}",
        table.concat(indices, ",")))

print("\n✅ test_auto_create_skips_disabled_patches.lua passed")
