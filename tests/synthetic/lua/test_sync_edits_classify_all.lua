-- T054a — sync_edits_from_resolve.classify_all bucketing contract
-- (spec 023 FR-024 / FR-025; data-model.md §SyncEditsFromResolve —
-- classification + dispatch contract).
--
-- Black-box: feed classify_all a synthetic read_timeline response built
-- to helper-protocol.md §read_timeline's exact shape, plus a real DB
-- with real clip + ledger rows. Assert each clip lands in the right
-- bucket with the right entry shape.
--
-- Non-trivial values (rule 2.34): TC-style frame numbers; deltas large
-- enough not to coincide with default args.

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
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES
        ('t',  's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1),
        ('t2', 's', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
]], now, now, now, now))

-- Insert a clip on the named track. Helper uses SQL column names
-- (sequence_start_frame / duration_frames / ...) which differ from the
-- Lua-visible Clip field names — see [[feedback_clip_lua_field_names]].
local function insert_clip(id, track_id, owner_seq, source_in, source_out,
                            seq_start, dur, enabled)
    db:exec(string.format([[
        INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
            sequence_id, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame, source_in_subframe,
            source_out_subframe, enabled, created_at, modified_at,
            master_layer_track_id, master_audio_track_id,
            fps_mismatch_policy, volume, playhead_frame)
        VALUES ('%s', 'p', '%s', '%s', '%s', '%s', %d, %d, %d, %d, NULL, NULL,
            %d, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]], id, id, track_id, owner_seq, owner_seq, seq_start, dur,
        source_in, source_out, enabled, now, now))
end

-- Baseline clips at distinct record slots (VIDEO_OVERLAP trigger
-- forbids stacking).
insert_clip("c_apply",              "t", "s", 1000, 1200, 5000, 200, 1)
insert_clip("c_conflict",           "t", "s", 1000, 1200, 5300, 200, 1)
insert_clip("c_skip_n",             "t", "s", 1000, 1200, 5600, 200, 1)
insert_clip("c_skip_jve",           "t", "s", 1100, 1200, 5900, 100, 1)
insert_clip("c_bootstrap",          "t", "s", 1000, 1200, 6100, 200, 1)
insert_clip("c_bootstrap_neither",  "t", "s", 1000, 1200, 6700, 200, 1)
insert_clip("c_no_ledger",          "t", "s", 1000, 1200, 6400, 200, 1)
insert_clip("c_track_move_ok",      "t", "s", 1000, 1200, 7000, 200, 1)
insert_clip("c_track_move_missing", "t", "s", 1000, 1200, 7300, 200, 1)
insert_clip("c_deleted",            "t", "s", 1000, 1200, 7600, 200, 1)

local function fp_at(source_in, source_out, record_start, record_dur)
    return edit_diff.fingerprint{
        source_in = source_in, source_out = source_out,
        record_start = record_start, record_dur = record_dur,
        enabled = true,
    }
end

local function seed_link(clip_id, edit_fp)
    local link = { resolve_item_id = "rs-" .. clip_id }
    if edit_fp then link.edit_fingerprint = edit_fp end
    identity_ledger.upsert(clip_id, link, db)
end

-- c_skip_jve baseline fp is the PRE-local-trim state (source_in=1000);
-- current is 1100 so JVE diverged from baseline. Response will carry
-- baseline values → kind=jve_only → skipped.
seed_link("c_apply",              fp_at(1000, 1200, 5000, 200))
seed_link("c_conflict",           fp_at(1000, 1200, 5300, 200))
seed_link("c_skip_n",             fp_at(1000, 1200, 5600, 200))
seed_link("c_skip_jve",           fp_at(1000, 1200, 5900, 200))
seed_link("c_bootstrap",          nil)
seed_link("c_bootstrap_neither",  nil)
seed_link("c_track_move_ok",      fp_at(1000, 1200, 7000, 200))
seed_link("c_track_move_missing", fp_at(1000, 1200, 7300, 200))
seed_link("c_deleted",            fp_at(1000, 1200, 7600, 200))

-- c_conflict: bump local sequence_start so JVE diverged from baseline
-- (current 5350 vs baseline 5300; response sets 5310 → both diverged
-- → kind=both → conflict).
db:exec(
    "UPDATE clips SET sequence_start_frame = 5350 WHERE id = 'c_conflict';")

local response = { items = {
    -- Resolve trimmed right by -20; JVE at baseline → to_apply.
    { resolve_item_id = "rs-c_apply",    track_id = "t",
      source_in = 1000, source_out = 1180,
      record_start = 5000, record_duration = 180, enabled = true },
    -- Resolve trimmed left by +10; JVE locally moved → both → conflict.
    { resolve_item_id = "rs-c_conflict", track_id = "t",
      source_in = 1010, source_out = 1200,
      record_start = 5310, record_duration = 190, enabled = true },
    -- Neither side changed → skipped(neither_changed).
    { resolve_item_id = "rs-c_skip_n",   track_id = "t",
      source_in = 1000, source_out = 1200,
      record_start = 5600, record_duration = 200, enabled = true },
    -- Resolve == baseline; JVE locally diverged → skipped(only_jve_changed).
    { resolve_item_id = "rs-c_skip_jve", track_id = "t",
      source_in = 1000, source_out = 1200,
      record_start = 5900, record_duration = 200, enabled = true },
    -- Bootstrap: ledger fp empty + live ≠ current → to_apply(bootstrapped).
    { resolve_item_id = "rs-c_bootstrap", track_id = "t",
      source_in = 1000, source_out = 1150,
      record_start = 6100, record_duration = 150, enabled = true },
    -- Bootstrap: ledger fp empty + live == current → skipped(neither_changed,
    -- bootstrapped=true).
    { resolve_item_id = "rs-c_bootstrap_neither", track_id = "t",
      source_in = 1000, source_out = 1200,
      record_start = 6700, record_duration = 200, enabled = true },
    -- No ledger row → unmatched(ledger_missing).
    { resolve_item_id = "rs-c_no_ledger", track_id = "t",
      source_in = 1000, source_out = 1200,
      record_start = 6400, record_duration = 200, enabled = true },
    -- Track changed to existing JVE track t2 →
    -- to_apply(requires_track_move=true, target_track_id="t2").
    { resolve_item_id = "rs-c_track_move_ok", track_id = "t2",
      source_in = 1000, source_out = 1200,
      record_start = 7000, record_duration = 200, enabled = true },
    -- Track changed to non-existent JVE track →
    -- conflicts(missing_target_track_in_jve).
    { resolve_item_id = "rs-c_track_move_missing", track_id = "t-ghost",
      source_in = 1000, source_out = 1200,
      record_start = 7300, record_duration = 200, enabled = true },
    -- c_deleted: NOT in response; ledger walk → conflicts(deleted_in_resolve).
} }

local result = sync_edits.classify_all(response, "s", db)

local function find(list, key)
    for _, e in ipairs(list) do
        if (e.clip_id or e.resolve_item_id) == key then return e end
    end
    return nil
end

-- ============ to_apply ============
local e_apply = find(result.to_apply, "c_apply")
check("c_apply → to_apply",                e_apply ~= nil)
check("c_apply kind=resolve_only",         e_apply and e_apply.kind == "resolve_only")
check("c_apply has live + current",        e_apply and e_apply.live ~= nil
                                            and e_apply.current ~= nil)
check("c_apply track_type carried",        e_apply and e_apply.track_type == "VIDEO")
check("c_apply not bootstrapped",          e_apply and e_apply.bootstrapped == nil)

local e_bs = find(result.to_apply, "c_bootstrap")
check("c_bootstrap → to_apply",            e_bs ~= nil)
check("c_bootstrap kind=resolve_only",     e_bs and e_bs.kind == "resolve_only")
check("c_bootstrap bootstrapped=true",     e_bs and e_bs.bootstrapped == true)

local e_tm = find(result.to_apply, "c_track_move_ok")
check("c_track_move_ok → to_apply",        e_tm ~= nil)
check("c_track_move_ok kind=resolve_only", e_tm and e_tm.kind == "resolve_only")
check("c_track_move_ok requires_track_move", e_tm and e_tm.requires_track_move == true)
check("c_track_move_ok target_track_id=t2", e_tm and e_tm.target_track_id == "t2")

-- ============ conflicts ============
local e_conf = find(result.conflicts, "c_conflict")
check("c_conflict → conflicts",            e_conf ~= nil)
check("c_conflict kind=both",              e_conf and e_conf.kind == "both")
check("c_conflict reason=diverged_both_sides",
    e_conf and e_conf.reason == "diverged_both_sides")

local e_tmm = find(result.conflicts, "c_track_move_missing")
check("c_track_move_missing → conflicts",  e_tmm ~= nil)
check("c_track_move_missing reason=missing_target_track_in_jve",
    e_tmm and e_tmm.reason == "missing_target_track_in_jve")
check("c_track_move_missing live_track_id=t-ghost",
    e_tmm and e_tmm.live_track_id == "t-ghost")

local e_del = find(result.conflicts, "c_deleted")
check("c_deleted → conflicts (ledger walk)", e_del ~= nil)
check("c_deleted reason=deleted_in_resolve",
    e_del and e_del.reason == "deleted_in_resolve")
check("c_deleted carries resolve_item_id",
    e_del and e_del.resolve_item_id == "rs-c_deleted")

-- ============ skipped ============
local e_skn = find(result.skipped, "c_skip_n")
check("c_skip_n → skipped",                e_skn ~= nil)
check("c_skip_n reason=neither_changed",   e_skn and e_skn.reason == "neither_changed")
check("c_skip_n has no kind field",        e_skn and e_skn.kind == nil)

local e_skj = find(result.skipped, "c_skip_jve")
check("c_skip_jve → skipped",              e_skj ~= nil)
check("c_skip_jve reason=only_jve_changed",
    e_skj and e_skj.reason == "only_jve_changed")

local e_bn = find(result.skipped, "c_bootstrap_neither")
check("c_bootstrap_neither → skipped",     e_bn ~= nil)
check("c_bootstrap_neither bootstrapped=true",
    e_bn and e_bn.bootstrapped == true)
check("c_bootstrap_neither reason=neither_changed",
    e_bn and e_bn.reason == "neither_changed")

-- ============ unmatched ============
local e_nl = find(result.unmatched, "rs-c_no_ledger")
check("c_no_ledger → unmatched",           e_nl ~= nil)
check("c_no_ledger reason=ledger_missing", e_nl and e_nl.reason == "ledger_missing")

-- ============ counts ============
check("to_apply count == 3",   #result.to_apply  == 3)
check("conflicts count == 3",  #result.conflicts == 3)
check("skipped count == 3",    #result.skipped   == 3)
check("unmatched count == 1",  #result.unmatched == 1)

-- ============ failure-path asserts (rule 1.14, 2.32) ============

-- (a) Missing db.
local ok_no_db = pcall(sync_edits.classify_all, response, "s", nil)
check("classify_all asserts on missing db",          not ok_no_db)

-- (b) Missing sequence_id.
local ok_no_seq = pcall(sync_edits.classify_all, response, nil, db)
check("classify_all asserts on missing sequence_id", not ok_no_seq)

-- (c) Missing items (response.items absent).
local ok_no_items = pcall(sync_edits.classify_all, {}, "s", db)
check("classify_all asserts on missing items",       not ok_no_items)

-- (d) Item shape: missing source_in.
local ok_bad_item = pcall(sync_edits.classify_all,
    { items = {{ resolve_item_id = "x", track_id = "t" }} }, "s", db)
check("classify_all asserts on incomplete item",     not ok_bad_item)

-- (e) Item shape: missing track_id.
local ok_no_track = pcall(sync_edits.classify_all,
    { items = {{ resolve_item_id = "x", source_in = 0, source_out = 1,
                 record_start = 0, record_duration = 1, enabled = true }} },
    "s", db)
check("classify_all asserts on missing track_id",    not ok_no_track)

-- (f) Duplicate resolve_item_id.
local dup_item = { resolve_item_id = "dup", track_id = "t",
    source_in = 0, source_out = 1, record_start = 0, record_duration = 1,
    enabled = true }
local ok_dup = pcall(sync_edits.classify_all,
    { items = { dup_item, dup_item } }, "s", db)
check("classify_all asserts on duplicate resolve_item_id", not ok_dup)

-- ============ empty response: legitimate no-op (no assert) ============
-- Use a fresh sequence with no clips/ledger rows so the ledger walk
-- finds nothing — otherwise s's ledger rows would surface as
-- deleted_in_resolve.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame,
        view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s_empty', 'p', 'Empty', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now))
local empty_result = sync_edits.classify_all({ items = {} }, "s_empty", db)
check("empty response: to_apply == 0",  #empty_result.to_apply  == 0)
check("empty response: conflicts == 0", #empty_result.conflicts == 0)
check("empty response: skipped == 0",   #empty_result.skipped   == 0)
check("empty response: unmatched == 0", #empty_result.unmatched == 0)

-- ============ V1 video-only: AUDIO clip asserts ============
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES ('a', 's_empty', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
]])
-- Inline insert (audio clips require non-NULL source_*_subframe per
-- schema trigger trg_clips_subframe_kind_insert).
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy, volume, playhead_frame)
    VALUES ('c_audio', 'p', 'c_audio', 'a', 's_empty', 's_empty',
        5000, 200, 1000, 1200, 0, 0,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))
seed_link("c_audio", fp_at(1000, 1200, 5000, 200))
local audio_response = { items = {
    { resolve_item_id = "rs-c_audio", track_id = "a",
      source_in = 1000, source_out = 1200,
      record_start = 5000, record_duration = 200, enabled = true },
} }
local ok_audio, err_audio = pcall(sync_edits.classify_all,
    audio_response, "s_empty", db)
check("V1 audio clip asserts", not ok_audio)
check("V1 audio assert message names VIDEO or AUDIO",
    err_audio and (err_audio:find("VIDEO") or err_audio:find("AUDIO")))

-- ============ translate_wire_response (T052) ============
-- Wire shape from helper read_timeline: (track_type, track_index)
-- positional identity. Translator looks up each pair via
-- Track.find_at to produce classifier shape (track_id).

local function wire_item(rid, ttype, tidx)
    return { resolve_item_id = rid,
             kind             = "media",
             track_type       = ttype,
             track_index      = tidx,
             source_in        = 1000,
             source_out       = 1200,
             record_start     = 5000,
             record_duration  = 200,
             enabled          = true }
end

local function wire_item_non_media(rid, ttype, tidx)
    return { resolve_item_id = rid,
             kind             = "non_media",
             track_type       = ttype,
             track_index      = tidx,
             record_start     = 5000,
             record_duration  = 200,
             enabled          = true }
end

-- Happy: sequence 's' has V1='t' at index 1 and V2='t2' at index 2.
do
    local wire = { items = {
        wire_item("rs-1", "video", 1),
        wire_item("rs-2", "video", 2),
    } }
    local translated = sync_edits.translate_wire_response(wire, "s")
    check("translate: item count preserved",
        #translated.items == 2)
    check("translate: video track 1 → JVE track 't'",
        translated.items[1].track_id == "t")
    check("translate: video track 2 → JVE track 't2'",
        translated.items[2].track_id == "t2")
end

-- Resolve track has no JVE counterpart → sentinel string flows through
-- the classifier's missing_target_track_in_jve conflict path.
do
    local wire = { items = {
        wire_item("rs-ghost-v", "video", 99),
        wire_item("rs-ghost-a", "audio", 1),  -- sequence has no audio
    } }
    local translated = sync_edits.translate_wire_response(wire, "s")
    check("translate: missing video track yields sentinel string",
        translated.items[1].track_id == "resolve-missing-track:video:99")
    check("translate: missing audio track yields sentinel string",
        translated.items[2].track_id == "resolve-missing-track:audio:1")
end

-- Non-track fields preserved verbatim through translation.
do
    local wire = { items = {{
        resolve_item_id = "rs-preserve", kind = "media",
        track_type = "video", track_index = 1,
        source_in = 12345, source_out = 67890,
        record_start = 11111, record_duration = 22222,
        enabled = false,
    }} }
    local out = sync_edits.translate_wire_response(wire, "s").items[1]
    check("translate: resolve_item_id preserved",
        out.resolve_item_id == "rs-preserve")
    check("translate: source_in preserved",      out.source_in == 12345)
    check("translate: source_out preserved",     out.source_out == 67890)
    check("translate: record_start preserved",   out.record_start == 11111)
    check("translate: record_duration preserved",
        out.record_duration == 22222)
    check("translate: enabled preserved",        out.enabled == false)
end

-- Non-media items filtered before reaching the classifier (it requires
-- source_in/source_out — non_media items don't carry them).
do
    local wire = { items = {
        wire_item("rs-real", "video", 1),
        wire_item_non_media("rs-gen", "video", 1),
        wire_item_non_media("rs-trans", "video", 2),
    } }
    local translated = sync_edits.translate_wire_response(wire, "s")
    check("translate: non_media items filtered out",
        #translated.items == 1)
    check("translate: media item survives",
        translated.items[1].resolve_item_id == "rs-real")
end

-- Wire validation: malformed wire items are dropped with log.warn, never
-- crash JVE (rule 1.14 — external Resolve wire data). Internal call
-- contract violations (empty sequence_id) still assert.
do
    -- missing kind → warn + skip (validate_item_kind returns false for nil)
    local ok_mk, r_mk = pcall(sync_edits.translate_wire_response,
        { items = {{ resolve_item_id="x", track_type="video",
            track_index=1, source_in=0, source_out=1,
            record_start=0, record_duration=1, enabled=true }} }, "s")
    check("translate: missing kind does not crash (wire data → dropped)",
        ok_mk == true)
    check("translate: missing-kind item is dropped from output",
        ok_mk and #r_mk.items == 0)

    -- kind outside closed set → warn + skip
    local ok_kv, r_kv = pcall(sync_edits.translate_wire_response,
        { items = {{ resolve_item_id="x", kind="generator",
            track_type="video", track_index=1, source_in=0,
            source_out=1, record_start=0, record_duration=1,
            enabled=true }} }, "s")
    check("translate: unknown kind does not crash (wire data → dropped)",
        ok_kv == true)
    check("translate: unknown-kind item is dropped from output",
        ok_kv and #r_kv.items == 0)

    -- track_type outside closed set → warn + skip
    local ok_tt, r_tt = pcall(sync_edits.translate_wire_response,
        { items = {{ resolve_item_id="x", kind="media",
            track_type="movie", track_index=1, source_in=0,
            source_out=1, record_start=0, record_duration=1,
            enabled=true }} }, "s")
    check("translate: bad track_type does not crash (wire data → dropped)",
        ok_tt == true)
    check("translate: bad-track_type item is dropped from output",
        ok_tt and #r_tt.items == 0)

    -- track_index=0 (1-based contract violation) → warn + skip
    local ok_iz, r_iz = pcall(sync_edits.translate_wire_response,
        { items = {{ resolve_item_id="x", kind="media",
            track_type="video", track_index=0, source_in=0,
            source_out=1, record_start=0, record_duration=1,
            enabled=true }} }, "s")
    check("translate: track_index=0 does not crash (wire data → dropped)",
        ok_iz == true)
    check("translate: track_index=0 item is dropped from output",
        ok_iz and #r_iz.items == 0)

    -- non-integer track_index → warn + skip
    local ok_if, r_if = pcall(sync_edits.translate_wire_response,
        { items = {{ resolve_item_id="x", kind="media",
            track_type="video", track_index=1.5, source_in=0,
            source_out=1, record_start=0, record_duration=1,
            enabled=true }} }, "s")
    check("translate: non-integer track_index does not crash (wire data → dropped)",
        ok_if == true)
    check("translate: non-integer-track_index item is dropped from output",
        ok_if and #r_if.items == 0)

    -- empty sequence_id is an internal call-contract violation → still asserts
    local bad_seq = pcall(sync_edits.translate_wire_response,
        { items = {} }, "")
    check("translate: asserts on empty sequence_id",  not bad_seq)

    -- audio_items_skipped absent (older helper) → warn + continue, no crash
    local ok_no_audio, r_no_audio = pcall(sync_edits.translate_wire_response,
        { items = { wire_item("rs-na", "video", 1) } }, "s")
    check("translate: absent audio_items_skipped does not crash",
        ok_no_audio == true)
    check("translate: items still flow when audio_items_skipped absent",
        ok_no_audio and #r_no_audio.items == 1)

    -- audio_items_skipped as non-number → warn + continue, no crash
    local ok_bad_audio, r_bad_audio = pcall(sync_edits.translate_wire_response,
        { items = { wire_item("rs-ba", "video", 1) },
          audio_items_skipped = "five" }, "s")
    check("translate: non-number audio_items_skipped does not crash",
        ok_bad_audio == true)
    check("translate: items still flow when audio_items_skipped is non-number",
        ok_bad_audio and #r_bad_audio.items == 1)
end

-- End-to-end: wire response with missing-track sentinel flows through
-- M.apply's translate→classify_all path, producing the documented
-- missing_target_track_in_jve conflict (clip c_track_move_missing
-- already has a ledger row for 'rs-c_track_move_missing').
--
-- Note: M.apply is invoked inside test_sync_edits_apply.lua; here we
-- verify only the wire→classifier handoff via classify_all on the
-- translated payload.
do
    local wire = { items = {
        wire_item("rs-c_track_move_missing", "video", 99),
    } }
    local translated = sync_edits.translate_wire_response(wire, "s")
    local trans_result = sync_edits.classify_all(translated, "s", db)
    -- ledger walk surfaces every other 's' ledger row as deleted;
    -- the wire item with the missing-track sentinel should land as a
    -- missing_target_track_in_jve conflict (not deleted).
    local found_missing = false
    for _, c in ipairs(trans_result.conflicts) do
        if c.clip_id == "c_track_move_missing"
            and c.reason == "missing_target_track_in_jve" then
            found_missing = true
            check("translate→classify: live_track_id carries sentinel",
                c.live_track_id == "resolve-missing-track:video:99")
        end
    end
    check("translate→classify: missing-track item → missing_target_track_in_jve",
        found_missing)
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_edits_classify_all.lua: failures present")
print("✅ test_sync_edits_classify_all.lua passed")
