#!/usr/bin/env luajit
-- SLOW_TEST
--
-- Combined integration test against the 41MB anamnesis DRP fixture.
-- Parses once (parse_drp_file) + converts once (to SQLite) for ALL assertions —
-- the single place the 41MB fixture is imported. Covers:
--   Phase 1 open timelines + cross-volume alt_paths
--   Phase 2 convert to SQLite
--   Phase 3 mute flags        Phase 4 BWF audio sync
--   Phase 5 media UUID dedup  Phase 6 media-pool bin structure
--   Phase 7 active timeline + open tabs
-- Phases 5–7 were folded here from test_drp_uuid_dedup_full, the anamnesis
-- case of test_drp_bin_structure, and Case 2 of test_drp_active_timeline_
-- restored — so the big fixture parses once, not four times.
--
-- Run with: RUN_SLOW_TESTS=1 make -j4

require("test_env")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local Sequence = require("models.sequence")
local test_env = require("test_env")
local json = require("dkjson")

local fixture_path = test_env.require_fixture(
    "tests/fixtures/resolve/anamnesis joe edit.drp")

-- BWF stub fixture — same bwf_time_reference as the real 1.2GB stereo mix
local bwf_fixture = test_env.require_fixture(
    "tests/fixtures/resolve/bwf_stereo_mix_stub.wav")

print("\n=== test_drp_anamnesis_full.lua (SLOW) ===")

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 1: parse_drp_file (no DB) — open timelines assertions
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 1: parse_drp_file — open timelines ---")
do
    local result = drp_converter.parse_drp_file(fixture_path)
    assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

    -- SequenceTabsData should yield exactly 3 tabs, not 125 from TimelineHandleVec
    local open_ids = result.project.open_timeline_ids
    assert(open_ids and #open_ids <= 10,
        string.format("Expected ≤10 open timelines (from tabs), got %d — "
            .. "likely using TimelineHandleVec instead of SequenceTabsData",
            open_ids and #open_ids or 0))
    assert(#open_ids == 3,
        string.format("Expected 3 open timelines from SequenceTabsData, got %d",
            #open_ids))
    print(string.format("  PASS: %d open timelines (not 125)", #open_ids))

    assert(result.project.active_timeline_id,
        "Expected active_timeline_id to be set")
    print(string.format("  PASS: active timeline = %s", result.project.active_timeline_id))

    -- Cross-volume dedup (verified at the DB level in Phase 5) is only
    -- meaningful if the project actually pools the same file under multiple
    -- volume paths: assert the parser recorded alt_paths so Phase 5 is not
    -- vacuous (folded from the retired test_drp_uuid_dedup_full Step 1).
    local with_alt_paths = 0
    for _, item in pairs(result.media_items) do
        if item.alt_paths and next(item.alt_paths) then
            with_alt_paths = with_alt_paths + 1
        end
    end
    assert(with_alt_paths > 0,
        "expected some media with alt_paths (cross-volume dedup) — none found")
    print(string.format("  PASS: %d media carry alt_paths (cross-volume)", with_alt_paths))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 2: convert to SQLite (single parse + full DB write)
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 2: convert to SQLite ---")
local JVP_PATH = "/tmp/jve/test_drp_anamnesis_full.jvp"
os.remove(JVP_PATH); os.remove(JVP_PATH .. "-wal"); os.remove(JVP_PATH .. "-shm")

local ok, err = require("core.commands.open_project")._convert_drp_to_jvp(fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
assert(ok, "DRP convert failed: " .. tostring(err))
local db = database.get_connection()
print("  PASS: convert succeeded")

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 3: Mute flag assertions
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 3: mute flags ---")

-- 3a: Disabled clips exist
local stmt = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE enabled = 0"))
assert(stmt:exec() and stmt:next())
local disabled_count = stmt:value(0)
stmt:finalize()
assert(disabled_count > 0, "expected disabled clips, got 0 — mute flag not imported")
print(string.format("  3a: %d disabled timeline clips", disabled_count))

-- 3b: Enabled clips also present (not ALL disabled)
local stmt2 = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE enabled = 1"))
assert(stmt2:exec() and stmt2:next())
local enabled_count = stmt2:value(0)
stmt2:finalize()
assert(enabled_count > disabled_count,
    string.format("expected more enabled (%d) than disabled (%d)",
        enabled_count, disabled_count))
print(string.format("  3b: %d enabled, %d disabled (%.0f%%)",
    enabled_count, disabled_count,
    disabled_count * 100 / (enabled_count + disabled_count)))

-- 3c: get_audio_in_range excludes disabled clips
local seq_stmt = assert(db:prepare([[
    SELECT DISTINCT s.id, s.name
    FROM sequences s
    JOIN tracks t ON t.sequence_id = s.id
    JOIN clips c ON c.track_id = t.id
    WHERE s.kind = 'sequence' AND t.track_type = 'AUDIO'
      AND c.enabled = 0
    LIMIT 1
]]))
assert(seq_stmt:exec())
if seq_stmt:next() then
    local seq_id = seq_stmt:value(0)
    local seq_name = seq_stmt:value(1)
    seq_stmt:finalize()

    local seq = Sequence.load(seq_id)
    assert(seq, "failed to load sequence " .. seq_id)

    local dis_stmt = assert(db:prepare([[
        SELECT c.id, c.sequence_start_frame,
               c.sequence_start_frame + c.duration_frames as clip_end
        FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
          AND c.enabled = 0
        ORDER BY c.sequence_start_frame LIMIT 1
    ]]))
    dis_stmt:bind_value(1, seq_id)
    assert(dis_stmt:exec() and dis_stmt:next())
    local disabled_clip_id = dis_stmt:value(0)
    local disabled_start = dis_stmt:value(1)
    local disabled_end = dis_stmt:value(2)
    dis_stmt:finalize()

    -- V13 resolver entries are flat (no entry.clip nesting) and the resolver
    -- already drops disabled clips upstream — so the located disabled clip
    -- must not appear among the entries overlapping its own range.
    local audio_entries = seq:get_audio_in_range(disabled_start, disabled_end)
    for _, entry in ipairs(audio_entries) do
        assert(entry.clip_id ~= disabled_clip_id,
            string.format("get_audio_in_range returned disabled clip id=%s at tl=%d",
                tostring(entry.clip_id), entry.sequence_start))
    end
    print(string.format("  3c: disabled audio clip at [%d..%d] excluded from %s",
        disabled_start, disabled_end, seq_name))
else
    seq_stmt:finalize()
    print("  3c SKIP: no sequence with disabled audio clips found")
end

-- 3d: get_video_in_range excludes disabled clips
local vseq_stmt = assert(db:prepare([[
    SELECT DISTINCT s.id, s.name
    FROM sequences s
    JOIN tracks t ON t.sequence_id = s.id
    JOIN clips c ON c.track_id = t.id
    WHERE s.kind = 'sequence' AND t.track_type = 'VIDEO'
      AND c.enabled = 0
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
        SELECT c.id, c.sequence_start_frame,
               c.sequence_start_frame + c.duration_frames
        FROM clips c JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'VIDEO'
          AND c.enabled = 0
        ORDER BY c.sequence_start_frame LIMIT 1
    ]]))
    vdis_stmt:bind_value(1, seq_id)
    assert(vdis_stmt:exec() and vdis_stmt:next())
    local vdisabled_clip_id = vdis_stmt:value(0)
    local vd_start = vdis_stmt:value(1)
    local vd_end = vdis_stmt:value(2)
    vdis_stmt:finalize()

    -- Flat V13 entries; resolver drops disabled clips (see 3c).
    local video_entries = seq:get_video_in_range(vd_start, vd_end)
    for _, entry in ipairs(video_entries) do
        assert(entry.clip_id ~= vdisabled_clip_id,
            string.format("get_video_in_range returned disabled clip id=%s",
                tostring(entry.clip_id)))
    end
    print(string.format("  3d: disabled video clip at [%d..%d] excluded from %s",
        vd_start, vd_end, seq_name))
else
    vseq_stmt:finalize()
    print("  3d SKIP: no sequence with disabled video clips found")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 4: BWF audio sync assertions
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 4: BWF audio sync ---")

-- Probe the BWF stub fixture for metadata
assert(type(qt_constants) == "table", "qt_constants not available — run via --test")
local EMP = qt_constants.EMP
local probe = EMP.MEDIA_FILE_PROBE(bwf_fixture)
assert(probe and probe.bwf_time_reference >= 0, "BWF stub missing bwf_time_reference")
local bwf_samples = probe.bwf_time_reference
local sample_rate = probe.audio_sample_rate
print(string.format("  BWF stub: first_sample_tc=%d samples = %.4fs",
    bwf_samples, bwf_samples / sample_rate))

assert(probe.first_sample_tc == bwf_samples,
    string.format("first_sample_tc=%d should == bwf_time_reference=%d",
        probe.first_sample_tc, bwf_samples))

-- 4a: Non-BWF clip — source_in includes media_tc_origin from MediaStartTime
print("\n  4a: Non-BWF clip source_in = media_tc_origin + in_offset")

local tl_stmt = db:prepare("SELECT id FROM sequences WHERE name LIKE '%2026-03-28%' LIMIT 1")
assert(tl_stmt:exec() and tl_stmt:next())
local timeline_id = tl_stmt:value(0)
tl_stmt:finalize()

local a3_stmt = db:prepare([[
    -- V13: a clip reaches its leaf media through its nested master
    -- sequence's media_refs (clips no longer carry media_id). The C053 name
    -- filter selects the clip's own master, not any borrowed sync audio;
    -- GROUP BY c.id collapses the master's V + per-channel audio refs (all
    -- the same media_id) to one row per clip.
    -- V13: a clip's source rate is its nested source sequence's fps
    -- (clips no longer carry fps_numerator — the source timebase lives on
    -- c.sequence_id, per the subframe trigger).
    SELECT c.source_in_frame, src.fps_numerator, m.metadata
    FROM clips c JOIN tracks t ON c.track_id=t.id
    JOIN sequences src ON src.id = c.sequence_id
    JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
    JOIN media m ON m.id = mr.media_id
    WHERE t.sequence_id=? AND t.name='A3' AND c.sequence_start_frame=96607
      AND m.name LIKE '%C053%'
    GROUP BY c.id
]])
a3_stmt:bind_value(1, timeline_id)
assert(a3_stmt:exec() and a3_stmt:next(), "A3 clip at 96607 not found")
local a3_source_in = a3_stmt:value(0)
local a3_rate = a3_stmt:value(1)
local a3_meta = json.decode(a3_stmt:value(2)) or {}
a3_stmt:finalize()

local in_offset = math.floor(916 * (a3_rate / 25) + 0.5)
local mst = a3_meta.start_tc_value and a3_meta.start_tc_rate and a3_meta.start_tc_rate > 0
    and math.floor(a3_meta.start_tc_value / a3_meta.start_tc_rate * a3_rate + 0.5) or 0
local expected_a3 = mst + in_offset
print(string.format("    A3: source_in=%d, expected=%d (mst=%d + in_offset=%d)",
    a3_source_in, expected_a3, mst, in_offset))
assert(math.abs(a3_source_in - expected_a3) <= 1, string.format(
    "A3 source_in should be %d (mst=%d + in_offset=%d), got %d",
    expected_a3, mst, in_offset, a3_source_in))

-- 4b: Stereo Mix — source_in is absolute TC, TMB subtracts first_sample_tc
print("\n  4b: Stereo Mix absolute TC source_in")

local mix_stmt = db:prepare([[
    -- V13 clip→media via the nested master's media_refs (see 4a). GROUP BY
    -- c.id collapses the master's multiple refs to one row per clip.
    SELECT c.sequence_start_frame, c.source_in_frame
    FROM clips c JOIN tracks t ON c.track_id=t.id
    JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
    JOIN media m ON m.id = mr.media_id
    WHERE t.sequence_id=? AND t.name='A1'
      AND m.name LIKE '%Stereo Mix - Online%'
    GROUP BY c.id
    ORDER BY c.sequence_start_frame
]])
mix_stmt:bind_value(1, timeline_id)
assert(mix_stmt:exec())

local max_drift_frames = 2
local all_ok = true
local clip_idx = 0
while mix_stmt:next() do
    clip_idx = clip_idx + 1
    local tl_start = mix_stmt:value(0)
    local source_in = mix_stmt:value(1)

    local file_pos_samples = source_in - bwf_samples
    local file_seek_s = file_pos_samples / sample_rate
    local audio_tc_s = source_in / sample_rate
    local timeline_tc_s = tl_start / 25
    local drift_frames = math.abs((timeline_tc_s - audio_tc_s) * 25)

    local status = drift_frames <= max_drift_frames and "OK" or "FAIL"
    if status == "FAIL" then all_ok = false end
    print(string.format("    %s clip %d: tl=%d src_in=%d file_seek=%.3fs drift=%.1f frames",
        status, clip_idx, tl_start, source_in, file_seek_s, drift_frames))
end
mix_stmt:finalize()

assert(all_ok, "Stereo Mix TC sync drift exceeds tolerance")

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 5: media UUID dedup (folded from the retired test_drp_uuid_dedup_full)
-- The same physical file pooled under several volume paths must collapse to
-- ONE media entry, keyed by its file_uuid (MediaRef DbId).
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 5: media UUID dedup ---")

local dup_stmt = assert(db:prepare([[
    SELECT COUNT(*) FROM (
        SELECT file_uuid FROM media WHERE file_uuid IS NOT NULL
        GROUP BY file_uuid HAVING COUNT(*) > 1
    )
]]))
assert(dup_stmt:exec() and dup_stmt:next())
local dup_uuids = dup_stmt:value(0)
dup_stmt:finalize()
assert(dup_uuids == 0, string.format(
    "%d file_uuid value(s) map to >1 media entry — cross-volume dedup failed",
    dup_uuids))
print("  PASS: every file_uuid maps to exactly one media entry")

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 6: media-pool bin structure (folded from the retired anamnesis case
-- of test_drp_bin_structure). Every master clip lands in a bin; the project's
-- orphaned (pool-less) media land in "Unorganized"; pool sub-folders are NOT
-- promoted to root bins.
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 6: media-pool bin structure ---")

local function scalar(sql)
    local s = assert(db:prepare(sql)); assert(s:exec() and s:next())
    local v = s:value(0); s:finalize(); return v
end

local master_total = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'master'")
local master_binned = scalar([[
    SELECT COUNT(DISTINCT entity_id) FROM tag_assignments
    WHERE entity_type = 'master_clip'
]])
assert(master_binned == master_total, string.format(
    "expected all %d master clips in a bin, got %d", master_total, master_binned))
print(string.format("  PASS: %d/%d master clips in bins", master_binned, master_total))

local unorganized = scalar([[
    SELECT COUNT(*) FROM tag_assignments ta
    JOIN tags t ON ta.tag_id = t.id
    JOIN tag_namespaces ns ON t.namespace_id = ns.id
    WHERE ns.display_name = 'Bins' AND t.name = 'Unorganized'
        AND ta.entity_type = 'master_clip'
]])
assert(unorganized > 0, "expected orphaned media in the Unorganized bin")
print(string.format("  PASS: Unorganized bin holds %d orphaned clips", unorganized))

local root_bins_stmt = assert(db:prepare([[
    SELECT t.name FROM tags t
    JOIN tag_namespaces ns ON t.namespace_id = ns.id
    WHERE ns.display_name = 'Bins' AND t.parent_id IS NULL
    ORDER BY t.name
]]))
assert(root_bins_stmt:exec())
local root_bins = {}
while root_bins_stmt:next() do root_bins[#root_bins + 1] = root_bins_stmt:value(0) end
root_bins_stmt:finalize()
for _, name in ipairs(root_bins) do
    assert(name ~= "A020" and name ~= "A026-2" and name ~= "A027" and name ~= "A029",
        "pool sub-folder '" .. name .. "' must not be promoted to a root bin")
end
print(string.format("  PASS: no pool sub-folders at root (%d root bins)", #root_bins))

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 7: active-timeline + open-tabs restore (folded from the anamnesis case
-- of test_drp_active_timeline_restored). The project must record which timeline
-- to open and which tabs to restore, and the active one must be among the tabs.
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Phase 7: active timeline + open tabs ---")
do
    local pid = database.get_current_project_id()
    assert(pid and pid ~= "", "no current project_id after convert")
    local sequences = database.load_sequences(pid)
    local seq_ids = {}
    for _, s in ipairs(sequences) do seq_ids[s.id] = s end

    local active_id = database.get_project_setting(pid, "last_open_sequence_id")
    local open_ids  = database.get_project_setting(pid, "open_sequence_ids")
    assert(active_id and active_id ~= "" and seq_ids[active_id],
        "last_open_sequence_id missing or not a real sequence")
    assert(type(open_ids) == "table" and #open_ids > 0,
        "open_sequence_ids missing or empty — no tabs would restore")
    local active_in_open = false
    for _, id in ipairs(open_ids) do
        assert(seq_ids[id], "open_sequence_ids contains a non-real sequence id")
        if id == active_id then active_in_open = true end
    end
    assert(active_in_open, "active sequence is not among the open tabs")
    print(string.format("  PASS: active=%q, %d open tabs",
        seq_ids[active_id].name, #open_ids))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Phase 8: timeline audio clips are not dropped when Resolve severs the
--          <MediaRef> UUID link (empty MediaRef, inline MediaFilePath only)
-- ═══════════════════════════════════════════════════════════════════════════
-- Domain: when a clip's media-pool master is reorganized/relinked, Resolve
-- clears the clip's <MediaRef> and keeps only the inline <MediaFilePath>. The
-- file still lives in the pool, so every such audio clip must still land on its
-- timeline. Before the filename-keyed sample-rate recovery, the importer keyed
-- audio's native rate ONLY by <MediaRef> UUID, so empty-MediaRef clips were
-- misclassified as nested sequences and silently dropped — 44 of 45 audio clips
-- on "composer scene 43 joe edit 2" vanished, collapsing its audio tracks.
--
-- Expectations are derived from the DRP's own SeqContainer XML (rule 2.34), NOT
-- the parser under test: in SeqContainer/2992dfa0-06de-42de-a465-c55932af2813
-- .xml ("composer scene 43 joe edit 2"), 244-T004.WAV and 215-T001.WAV each
-- appear as the MediaFilePath of 9 Sm2TiAudioClip elements, all with an empty
-- <MediaRef>, and each has a pool master carrying a real TracksBA sample rate.
-- So all 9 direct placements of each must import (before the fix: zero did).
-- This is a LOWER bound, not equality: a synced clip can additionally borrow a
-- file's audio without naming it in its own MediaFilePath, so the imported count
-- may exceed the direct-placement count — it must never fall below it.
print("\n--- Phase 8: empty-MediaRef audio clips not dropped ---")

local cs43_stmt = db:prepare(
    "SELECT id FROM sequences WHERE kind='sequence' "
    .. "AND name='composer scene 43 joe edit 2' LIMIT 1")
assert(cs43_stmt:exec() and cs43_stmt:next(),
    "composer scene 43 joe edit 2 sequence not found in converted DB")
local cs43_id = cs43_stmt:value(0)
cs43_stmt:finalize()

-- V13: a clip reaches its media through its nested master sequence's media_refs
-- (clips no longer carry media_id) — same join as Phase 4a/4b. COUNT(DISTINCT
-- c.id) collapses the master's per-channel audio refs to one row per clip.
local function count_audio_clips_for(seq_id, name_like)
    local cq = assert(db:prepare([[
        SELECT COUNT(DISTINCT c.id)
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
        JOIN media m ON m.id = mr.media_id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
          AND m.name LIKE ?
    ]]))
    cq:bind_value(1, seq_id)
    cq:bind_value(2, name_like)
    assert(cq:exec() and cq:next())
    local n = cq:value(0)
    cq:finalize()
    return n
end

for _, expect in ipairs({
    { name = "244-T004.WAV", like = "%244-T004%", min = 9 },
    { name = "215-T001.WAV", like = "%215-T001%", min = 9 },
}) do
    local got = count_audio_clips_for(cs43_id, expect.like)
    assert(got >= expect.min, string.format(
        "expected >= %d audio clips for %s on composer scene 43, got %d "
        .. "(empty-MediaRef clips dropped — severed-link restore regressed)",
        expect.min, expect.name, got))
    print(string.format("  PASS: %d audio clips for %s (>= %d direct placements)",
        got, expect.name, expect.min))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Cleanup
-- ═══════════════════════════════════════════════════════════════════════════
os.remove(JVP_PATH); os.remove(JVP_PATH .. "-wal"); os.remove(JVP_PATH .. "-shm")

print("\n✅ test_drp_anamnesis_full.lua passed")
