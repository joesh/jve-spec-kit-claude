-- SLOW_TEST
-- Offline-master regeneration (DRP Layer 2).
--
-- Domain behavior under test: "import everything in the DRP." When a clip's
-- media-pool master has been deleted (a dangling reference — Resolve permits
-- this), the timeline clip survives in the sequence XML carrying only its inline
-- <MediaFilePath>/<In>/<Duration> and an EMPTY <MediaRef>. JVE must still PLACE
-- that clip: regenerate a relinkable offline master from the surviving fields so
-- the edit is faithful and the user can reconnect the file later. Dropping the
-- clip silently loses part of the edit.
--
-- Ground truth (derived from the raw DRP, NOT from the parser — rule 2.34):
--   tests/fixtures/resolve/anamnesis joe edit.drp
--   SeqContainer/2992dfa0-06de-42de-a465-c55932af2813.xml = "composer scene 43
--   joe edit 2". Its 45 <Sm2TiAudioClip> blocks include three files that have NO
--   MediaPool master (verified absent from every MpFolder <Name>) and an empty
--   <MediaRef> on every placement:
--     composer-scene-sfx-v1.wav             x4   (all empty MediaRef)
--     composer-scene-sfx-v1_OttoSound_2.mp4 x4   (all empty MediaRef)
--     Phone slide sfx.m4a                   x1   (empty MediaRef)
--   => 9 offline audio placements that must land. Counts are LOWER bounds: a
--   synced clip on another track can borrow a file's audio without naming it.
--
-- A regenerated master must carry a positive media duration (a placed clip has a
-- playable extent); a zero-duration master would be filtered out and the clip
-- would vanish — the very bug this guards against.

require("test_env")
local database = require("core.database")

local FIXTURE = "/Users/joe/Local/jve-spec-kit-claude/tests/fixtures/resolve/anamnesis joe edit.drp"
local JVP = "/tmp/jve/test_drp_offline_master_regen.jvp"
os.remove(JVP); os.remove(JVP .. "-wal"); os.remove(JVP .. "-shm")

-- Resolve has no project-wide audio default; the convert flow derives one
-- (majority vote) when the caller passes none. Pass 48000 explicitly so the
-- test is hermetic and the regenerated offline masters get a concrete rate.
local ok, err = require("core.commands.open_project")
    ._convert_drp_to_jvp(FIXTURE, JVP, nil, { audio_sample_rate = 48000 })
assert(ok, "convert failed: " .. tostring(err))

local db = database.get_connection()

local s = db:prepare(
    "SELECT id FROM sequences WHERE kind='sequence' AND name='composer scene 43 joe edit 2' LIMIT 1")
assert(s:exec() and s:next(), "cs43 sequence not found")
local seq = s:value(0)
s:finalize()

-- Audio clips on cs43 whose bound media's file path ends in the given basename,
-- plus that media's duration. Black-box V13 join (clip -> track -> media_refs ->
-- media). DISTINCT on clip id: a clip binds one media.
local function clips_and_min_duration(basename)
    local q = db:prepare([[
        SELECT DISTINCT c.id, m.duration_frames
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
        JOIN media m ON m.id = mr.media_id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
          AND m.file_path LIKE ?
    ]])
    q:bind_value(1, seq)
    q:bind_value(2, "%" .. basename)
    assert(q:exec())
    local count, min_dur = 0, math.huge
    while q:next() do
        count = count + 1
        local d = q:value(1)
        if d < min_dur then min_dur = d end
    end
    q:finalize()
    return count, (count > 0 and min_dur or 0)
end

local expect = {
    { name = "composer-scene-sfx-v1.wav", min_clips = 4 },
    { name = "composer-scene-sfx-v1_OttoSound_2.mp4", min_clips = 4 },
    { name = "Phone slide sfx.m4a", min_clips = 1 },
}

local failures = {}
for _, e in ipairs(expect) do
    local n, min_dur = clips_and_min_duration(e.name)
    print(string.format("  %-40s clips=%d  min_media_duration=%s",
        e.name, n, tostring(min_dur)))
    if n < e.min_clips then
        failures[#failures + 1] = string.format(
            "%s: expected >= %d offline audio clips, got %d (clip dropped)",
            e.name, e.min_clips, n)
    elseif min_dur <= 0 then
        failures[#failures + 1] = string.format(
            "%s: regenerated master has non-positive duration %s (would be filtered)",
            e.name, tostring(min_dur))
    end
end

os.remove(JVP); os.remove(JVP .. "-wal"); os.remove(JVP .. "-shm")

if #failures > 0 then
    for _, f in ipairs(failures) do print("  FAIL: " .. f) end
    error("offline-master regeneration incomplete:\n  " .. table.concat(failures, "\n  "))
end

print("✅ test_drp_offline_master_regen.lua passed")
