#!/usr/bin/env luajit
-- SLOW_TEST — superseded by test_drp_anamnesis_full.lua
-- Black-box test: DRP import respects clip mute flags.
-- Uses anamnesis DRP which has ~129 muted clips (Flags bit 1 = muted).
--
-- Verifies:
-- 1. Muted clips have enabled=0 in DB
-- 2. Enabled clips have enabled=1
-- 3. get_audio_in_range() excludes disabled clips
-- 4. get_video_in_range() excludes disabled clips

require("test_env")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local Sequence = require("models.sequence")
local test_env = require("test_env")

local fixture = test_env.require_fixture(
    "tests/fixtures/resolve/anamnesis joe edit.drp")

print("\n=== DRP Import Mute Flag Test (anamnesis) ===")

local JVP = "/tmp/jve/test_drp_mute.jvp"
os.remove(JVP); os.remove(JVP .. "-wal"); os.remove(JVP .. "-shm")

local ok, err = drp_converter.convert(fixture, JVP, nil, {audio_sample_rate = 48000})
assert(ok, "convert failed: " .. tostring(err))

local db = database.get_connection()

-- ═══════════════════════════════════════════════════════════════
-- 1. Disabled clips exist in DB
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1: Disabled clips in DB ---")

local stmt = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE enabled = 0 AND clip_kind = 'timeline'"))
assert(stmt:exec() and stmt:next())
local disabled_count = stmt:value(0)
stmt:finalize()

assert(disabled_count > 0, "expected disabled clips, got 0 — mute flag not imported")
print(string.format("  %d disabled timeline clips", disabled_count))

-- ═══════════════════════════════════════════════════════════════
-- 2. Enabled clips also exist (sanity — not ALL clips disabled)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2: Enabled clips also present ---")

local stmt2 = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE enabled = 1 AND clip_kind = 'timeline'"))
assert(stmt2:exec() and stmt2:next())
local enabled_count = stmt2:value(0)
stmt2:finalize()

assert(enabled_count > disabled_count,
    string.format("expected more enabled (%d) than disabled (%d)",
        enabled_count, disabled_count))
print(string.format("  %d enabled, %d disabled (ratio %.0f%%)",
    enabled_count, disabled_count,
    disabled_count * 100 / (enabled_count + disabled_count)))

-- ═══════════════════════════════════════════════════════════════
-- 3. get_audio_in_range excludes disabled clips
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3: get_audio_in_range excludes disabled ---")

-- Find a sequence with both enabled and disabled audio clips
local seq_stmt = assert(db:prepare([[
    SELECT DISTINCT s.id, s.name
    FROM sequences s
    JOIN tracks t ON t.sequence_id = s.id
    JOIN clips c ON c.track_id = t.id
    WHERE s.kind = 'timeline' AND t.track_type = 'AUDIO'
      AND c.clip_kind = 'timeline' AND c.enabled = 0
    LIMIT 1
]]))
assert(seq_stmt:exec())
if seq_stmt:next() then
    local seq_id = seq_stmt:value(0)
    local seq_name = seq_stmt:value(1)
    seq_stmt:finalize()

    local seq = Sequence.load(seq_id)
    assert(seq, "failed to load sequence " .. seq_id)

    -- Count disabled audio clips on this sequence
    local dis_stmt = assert(db:prepare([[
        SELECT c.timeline_start_frame, c.timeline_start_frame + c.duration_frames as clip_end
        FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
          AND c.clip_kind = 'timeline' AND c.enabled = 0
        ORDER BY c.timeline_start_frame LIMIT 1
    ]]))
    dis_stmt:bind_value(1, seq_id)
    assert(dis_stmt:exec() and dis_stmt:next())
    local disabled_start = dis_stmt:value(0)
    local disabled_end = dis_stmt:value(1)
    dis_stmt:finalize()

    -- Query audio in the disabled clip's range
    local audio_entries = seq:get_audio_in_range(disabled_start, disabled_end)

    -- None of the returned entries should be the disabled clip
    for _, entry in ipairs(audio_entries) do
        assert(entry.clip.enabled ~= 0 and entry.clip.enabled ~= false,
            string.format("get_audio_in_range returned disabled clip id=%s at tl=%d",
                entry.clip.id, entry.clip.timeline_start))
    end
    print(string.format("  PASS: disabled audio clip at [%d..%d] excluded from %s",
        disabled_start, disabled_end, seq_name))
else
    seq_stmt:finalize()
    print("  SKIP: no sequence with disabled audio clips found")
end

-- ═══════════════════════════════════════════════════════════════
-- 4. get_video_in_range excludes disabled clips
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4: get_video_in_range excludes disabled ---")

local vseq_stmt = assert(db:prepare([[
    SELECT DISTINCT s.id, s.name
    FROM sequences s
    JOIN tracks t ON t.sequence_id = s.id
    JOIN clips c ON c.track_id = t.id
    WHERE s.kind = 'timeline' AND t.track_type = 'VIDEO'
      AND c.clip_kind = 'timeline' AND c.enabled = 0
    LIMIT 1
]]))
assert(vseq_stmt:exec())
if vseq_stmt:next() then
    local seq_id = vseq_stmt:value(0)
    local seq_name = vseq_stmt:value(1)
    vseq_stmt:finalize()

    local seq = Sequence.load(seq_id)
    assert(seq, "failed to load sequence")

    local vdis_stmt = assert(db:prepare([[
        SELECT c.timeline_start_frame, c.timeline_start_frame + c.duration_frames
        FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'VIDEO'
          AND c.clip_kind = 'timeline' AND c.enabled = 0
        ORDER BY c.timeline_start_frame LIMIT 1
    ]]))
    vdis_stmt:bind_value(1, seq_id)
    assert(vdis_stmt:exec() and vdis_stmt:next())
    local vd_start = vdis_stmt:value(0)
    local vd_end = vdis_stmt:value(1)
    vdis_stmt:finalize()

    local video_entries = seq:get_video_in_range(vd_start, vd_end)
    for _, entry in ipairs(video_entries) do
        assert(entry.clip.enabled ~= 0 and entry.clip.enabled ~= false,
            string.format("get_video_in_range returned disabled clip id=%s",
                entry.clip.id))
    end
    print(string.format("  PASS: disabled video clip at [%d..%d] excluded from %s",
        vd_start, vd_end, seq_name))
else
    vseq_stmt:finalize()
    print("  SKIP: no sequence with disabled video clips found")
end

-- Cleanup
os.remove(JVP); os.remove(JVP .. "-wal"); os.remove(JVP .. "-shm")
print("\n✅ test_drp_import_mute.lua passed")
