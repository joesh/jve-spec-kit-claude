-- Regression: every sequence created by the DRP import path must satisfy
-- `playhead_frame >= start_timecode_frame`. A playhead below the sequence's
-- TC origin trips the playback engine's start-frame assert at seek time,
-- and pre-content space is meaningless anyway. The Sequence.create
-- invariant (models/sequence.lua) enforces this at construction time —
-- this test pins the importer call paths as honoring it end-to-end.
--
-- Fixture: sample_project.drp (small, fast). The larger fixtures
-- (anamnesis-gold-timeline.drp, "2025-06-14 NO KINGS SEATTLE.drp") are
-- verified manually via the same probe pattern but not run in the auto-test
-- suite to keep runtime tight; slow-tier coverage can be added under
-- tests/slow/ if regressions appear with TC-bearing media.

require("test_env")

local Sequence = require("models.sequence")
local database = require("core.database")
local test_env = require("test_env")

print("\n=== DRP Playhead Invariant Test ===")

local fixture_path = test_env.resolve_repo_path(
    "tests/fixtures/resolve/sample_project.drp")
local jvp_path = "/tmp/jve/test_drp_playhead_invariant.jvp"
os.remove(jvp_path)
os.remove(jvp_path .. "-wal")
os.remove(jvp_path .. "-shm")

local ok, err = require("core.commands.open_project")._convert_drp_to_jvp(
    fixture_path, jvp_path, nil, { audio_sample_rate = 48000 })
assert(ok, "convert failed: " .. tostring(err))

local conn = assert(database.get_connection(), "no database connection")
local stmt = assert(conn:prepare("SELECT id FROM sequences"))
assert(stmt:exec())
local ids = {}
while stmt:next() do table.insert(ids, stmt:value(0)) end
stmt:finalize()
assert(#ids > 0, "import produced no sequences")

local masters, timelines = 0, 0
for _, id in ipairs(ids) do
    local s = Sequence.load(id)
    assert(s.playhead_position >= s.start_timecode_frame, string.format(
        "DRP import violates playhead invariant for sequence '%s' (kind=%s): "
        .. "playhead_position=%d < start_timecode_frame=%d — track down "
        .. "which Sequence.create call site emitted a sub-TC-origin playhead",
        s.name, s.kind, s.playhead_position, s.start_timecode_frame))
    if s.kind == "master" then masters = masters + 1
    else timelines = timelines + 1 end
end
print(string.format("  %d masters + %d timelines = %d sequences, all satisfy "
    .. "playhead_position >= start_timecode_frame",
    masters, timelines, #ids))

print("\n✅ test_drp_playhead_invariant.lua passed")
