-- T054 (Pass 1) — sync_edits_from_resolve.classify_all bucketing
-- contract (spec 023, FR-024 / FR-025).
--
-- Black-box: feed the function a synthetic read_timeline response
-- (the shape helper-protocol.md defines) + a real DB with real clip
-- rows + real identity_ledger rows. Assert each clip lands in the
-- correct bucket. NO mocks — the classifier reads Clip.load_optional
-- and identity_ledger.load against the actual DB.
--
-- The bucketing semantics under test:
--   * Resolve diverged, JVE matches stored fingerprint  → to_apply
--   * Both diverged from stored fingerprint             → conflicts
--   * Resolve == stored, JVE diverged                   → skipped (jve_only)
--   * Neither diverged                                  → skipped (neither)
--   * No clip in DB                                     → unmatched (clip_missing)
--   * No ledger row                                     → unmatched (ledger_missing)
--   * Ledger row with empty edit_fingerprint            → bootstrap from current
--
-- Non-trivial values (FR-022): TC-style frame numbers, deltas large
-- enough to not coincide with default arg values.

require("test_env")

local database        = require("core.database")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local edit_diff       = require("core.resolve_bridge.edit_diff")
local sync_edits      = require("core.commands.sync_edits_from_resolve")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== sync_edits.classify_all Tests ===")

local db_path = "/tmp/jve/test_sync_edits_classify.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
                          created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',
        %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame,
        view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Four real clips at baseline state: source 1000..1200, record 5000..5200.
-- Each will be steered into a different bucket by the response we feed.
local function insert_clip(id, source_in, source_out, seq_start, dur, enabled)
    db:exec(string.format([[
        INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
            sequence_id, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame, source_in_subframe,
            source_out_subframe, enabled, created_at, modified_at,
            master_layer_track_id, master_audio_track_id,
            fps_mismatch_policy, volume, playhead_frame)
        VALUES ('%s', 'p', '%s', 't', 's', 's', %d, %d, %d, %d, NULL, NULL,
            %d, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]], id, id, seq_start, dur, source_in, source_out,
        enabled, now, now))
end

-- Each clip lives at its own record-range slot on the track (VIDEO_OVERLAP
-- trigger forbids stacking). Source TC is identical across clips —
-- only timeline position differs. Per-clip baseline fingerprint reflects
-- the current state at the slot.
insert_clip("c_apply",     1000, 1200, 5000, 200, 1)
insert_clip("c_conflict",  1000, 1200, 5300, 200, 1)
insert_clip("c_skip_n",    1000, 1200, 5600, 200, 1)
insert_clip("c_skip_jve",  1100, 1200, 5900, 100, 1) -- already trimmed locally
insert_clip("c_bootstrap", 1000, 1200, 6100, 200, 1)
insert_clip("c_no_ledger", 1000, 1200, 6400, 200, 1) -- clip exists, no ledger row

local function fp_at(source_in, source_out, record_start, record_dur)
    return edit_diff.fingerprint{
        source_in = source_in, source_out = source_out,
        record_start = record_start, record_dur = record_dur,
        enabled = true,
    }
end

local function seed_link(clip_id, edit_fp)
    identity_ledger.upsert(clip_id, {
        resolve_item_id  = "rs-" .. clip_id,
        edit_fingerprint = edit_fp,
    }, db)
end

-- For c_skip_jve, baseline fp reflects the PRE-local-trim state
-- (source_in=1000) — current is 1100, so JVE-side has diverged from
-- baseline. Resolve will be sent baseline values → jve_only.
seed_link("c_apply",     fp_at(1000, 1200, 5000, 200))
seed_link("c_conflict",  fp_at(1000, 1200, 5300, 200))
seed_link("c_skip_n",    fp_at(1000, 1200, 5600, 200))
seed_link("c_skip_jve",  fp_at(1000, 1200, 5900, 200))
seed_link("c_bootstrap", "")  -- empty edit_fingerprint → bootstrap path

-- Response shape — what helper read_timeline returns.
local response = { items = {
    -- Resolve trimmed right edge by -20; JVE unchanged from baseline → apply
    { jve_guid = "c_apply",    source_in = 1000, source_out = 1180,
      record_start = 5000, record_dur = 180, enabled = true },
    -- Resolve trimmed left by +10; JVE locally moved → both → conflict
    { jve_guid = "c_conflict", source_in = 1010, source_out = 1200,
      record_start = 5310, record_dur = 190, enabled = true },
    -- Neither side changed → skipped (neither)
    { jve_guid = "c_skip_n",   source_in = 1000, source_out = 1200,
      record_start = 5600, record_dur = 200, enabled = true },
    -- Resolve matches PRE-trim baseline; JVE diverged locally → jve_only
    { jve_guid = "c_skip_jve", source_in = 1000, source_out = 1200,
      record_start = 5900, record_dur = 200, enabled = true },
    -- Bootstrap: ledger has empty fp; live ≠ current → resolve_only
    { jve_guid = "c_bootstrap", source_in = 1000, source_out = 1150,
      record_start = 6100, record_dur = 150, enabled = true },
    -- Clip exists but no ledger row → unmatched(ledger_missing)
    { jve_guid = "c_no_ledger", source_in = 1000, source_out = 1200,
      record_start = 6400, record_dur = 200, enabled = true },
    -- No clip with this id → unmatched(clip_missing)
    { jve_guid = "c_ghost",    source_in = 1000, source_out = 1200,
      record_start = 5000, record_dur = 200, enabled = true },
} }

-- Make c_conflict's JVE-current state differ from baseline_fp so the
-- "both" semantics fire. (Direct UPDATE — black-box on classify_all,
-- not the SQL.)
-- c_conflict baseline fp was for record_start=5300; bump current to
-- 5350 so JVE-side diverged from baseline, and response sets it to
-- 5310 — both sides changed from baseline → "both" → conflict.
db:exec(
    "UPDATE clips SET sequence_start_frame = 5350 WHERE id = 'c_conflict';")

local result = sync_edits.classify_all(response, db)

local function find(list, clip_id)
    for _, e in ipairs(list) do
        if (e.clip_id or e.jve_guid) == clip_id then return e end
    end
    return nil
end

check("c_apply → to_apply",     find(result.to_apply,  "c_apply") ~= nil)
check("c_apply kind resolve_only",
    (find(result.to_apply, "c_apply") or {}).kind == "resolve_only")
check("c_conflict → conflicts", find(result.conflicts, "c_conflict") ~= nil)
check("c_conflict kind both",
    (find(result.conflicts, "c_conflict") or {}).kind == "both")
check("c_skip_n → skipped",     find(result.skipped,   "c_skip_n") ~= nil)
check("c_skip_n kind neither",
    (find(result.skipped, "c_skip_n") or {}).kind == "neither")
check("c_skip_jve → skipped",   find(result.skipped,   "c_skip_jve") ~= nil)
check("c_skip_jve kind jve_only",
    (find(result.skipped, "c_skip_jve") or {}).kind == "jve_only")
check("c_bootstrap → to_apply", find(result.to_apply,  "c_bootstrap") ~= nil)
check("c_bootstrap kind resolve_only",
    (find(result.to_apply, "c_bootstrap") or {}).kind == "resolve_only")
check("c_no_ledger → unmatched", find(result.unmatched, "c_no_ledger") ~= nil)
check("c_no_ledger reason ledger_missing",
    (find(result.unmatched, "c_no_ledger") or {}).reason == "ledger_missing")
check("c_ghost → unmatched",    find(result.unmatched, "c_ghost") ~= nil)
check("c_ghost reason clip_missing",
    (find(result.unmatched, "c_ghost") or {}).reason == "clip_missing")

check("to_apply count == 2",  #result.to_apply  == 2)
check("conflicts count == 1", #result.conflicts == 1)
check("skipped count == 2",   #result.skipped   == 2)
check("unmatched count == 2", #result.unmatched == 2)

-- Fail-fast asserts (rule 1.14): every error path raises, none silent.
local ok_no_db = pcall(sync_edits.classify_all, response, nil)
check("classify_all asserts on missing db", not ok_no_db)
local ok_no_items = pcall(sync_edits.classify_all, {}, db)
check("classify_all asserts on missing items", not ok_no_items)
local ok_bad_item = pcall(sync_edits.classify_all,
    { items = {{ jve_guid = "x" }} }, db)
check("classify_all asserts on incomplete item", not ok_bad_item)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_edits_classify_all.lua: failures present")
print("✅ test_sync_edits_classify_all.lua passed")
