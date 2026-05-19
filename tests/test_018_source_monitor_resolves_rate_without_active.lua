-- 018 FR-005 (NSF): audio_bus_rate.resolve_for_monitor must NOT require an
-- active record sequence to be set when loading a video-only master. It
-- finds an authoritative rate from the project's record sequence instead
-- of asserting. No active record at all (project has zero record sequences)
-- IS a hard error — the user has nothing to monitor against.
--
-- Covers all four resolution cases of audio_bus_rate.resolve_for_monitor.

require("test_env")
local database = require("core.database")
local Sequence = require("models.sequence")
local audio_bus_rate = require("core.audio_bus_rate")

local DB = "/tmp/jve/test_018_audio_bus_rate.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d),
           ('p_empty', 'PEmpty', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 24, 1, 44100, 1920, 1080, %d, %d),
           ('vmstr', 'p', 'VMaster', 'master', 24, 1, NULL, 1920, 1080, %d, %d),
           ('rec_b', 'p', 'RecB', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d),
           -- Empty project: a video-only master with NO record sequence anywhere.
           ('vmstr_orphan', 'p_empty', 'VOrphan', 'master', 24, 1, NULL, 1920, 1080, %d, %d);
]],
    now, now, now, now,
    now, now,
    now + 1, now + 1,   -- rec_b created AFTER rec so first-wins picks rec
    now, now,
    now + 2, now + 2)))

local rec      = Sequence.load("rec")
local vmstr    = Sequence.load("vmstr")
local orphan   = Sequence.load("vmstr_orphan")

-- Case 1: sequence carries its own rate.
print("-- Case 1: record sequence with own rate --")
do
    local r = audio_bus_rate.resolve_for_monitor(rec, nil, Sequence.load, Sequence.find_first_record_audio_rate)
    assert(r == 44100, "expected 44100; got " .. tostring(r))
    print("  ok")
end

-- Case 2: video-only master + active record set.
print("-- Case 2: master + active record --")
do
    local r = audio_bus_rate.resolve_for_monitor(vmstr, "rec_b", Sequence.load, Sequence.find_first_record_audio_rate)
    assert(r == 48000, "expected active record (48000); got " .. tostring(r))
    print("  ok")
end

-- Case 3: video-only master + NO active record → first project record sequence wins.
print("-- Case 3: master + no active → project record (FR-005 relax) --")
do
    local r = audio_bus_rate.resolve_for_monitor(vmstr, nil, Sequence.load, Sequence.find_first_record_audio_rate)
    assert(r == 44100, "expected first project record (44100); got " .. tostring(r))
    print("  ok")
end

-- Case 4: video-only master + no records in project → loud refusal.
print("-- Case 4: master, project has zero record sequences --")
do
    local ok, err = pcall(function()
        audio_bus_rate.resolve_for_monitor(orphan, nil, Sequence.load, Sequence.find_first_record_audio_rate)
    end)
    assert(not ok and tostring(err):find("no record sequence"),
        "expected refusal naming missing record sequence; got: " .. tostring(err))
    print("  ok")
end

-- Case 5 (invariant): active record that resolves to a master MUST loud-fail.
print("-- Case 5: active_id points at a master (FR-005 invariant) --")
do
    local ok, err = pcall(function()
        audio_bus_rate.resolve_for_monitor(vmstr, "vmstr", Sequence.load, Sequence.find_first_record_audio_rate)
    end)
    assert(not ok and tostring(err):find("master"),
        "expected refusal naming master/FR-005; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_018_source_monitor_resolves_rate_without_active.lua passed")
