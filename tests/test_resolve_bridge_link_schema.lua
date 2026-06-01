-- Schema invariant — `resolve_bridge_link.jve_clip_uuid` FK CASCADE on
-- DELETE. The SyncEditsFromResolve classifier asserts that no ledger
-- row can outlive its clip (see classify_row's FK CASCADE invariant
-- assert). This test pins that schema property: weakening or removing
-- the CASCADE here would let orphan ledger rows survive, which would
-- in turn turn the classifier's assert into a real crash on stale state.
--
-- Spec: 023-resolve-color-bridge data-model.md §resolve_bridge_link
-- lifecycle, FR-013a.

require("test_env")

local database        = require("core.database")
local identity_ledger = require("core.resolve_bridge.identity_ledger")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== resolve_bridge_link FK CASCADE Tests ===")

local db_path = "/tmp/jve/test_resolve_bridge_link_schema.db"
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
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy, volume, playhead_frame)
    VALUES ('c1', 'p', 'c1', 't', 's', 's', 5000, 200, 1000, 1200,
        NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

identity_ledger.upsert("c1",
    { resolve_item_id = "rs-c1", edit_fingerprint = "anything" }, db)

-- Pre-cascade: the row exists.
local function count_ledger_rows(clip_id)
    local stmt = assert(db:prepare(
        "SELECT COUNT(*) FROM resolve_bridge_link WHERE jve_clip_uuid = ?"))
    stmt:bind_value(1, clip_id)
    stmt:exec(); stmt:next()
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

check("pre-delete: ledger row present", count_ledger_rows("c1") == 1)

-- Delete the clip; CASCADE must drop the ledger row.
db:exec("DELETE FROM clips WHERE id = 'c1';")

check("post-delete: ledger row removed by CASCADE",
    count_ledger_rows("c1") == 0)

-- And lookup_clip_id agrees (defensive — same SELECT path classify_all uses).
check("lookup_clip_id returns nil after cascade",
    identity_ledger.lookup_clip_id("rs-c1", db) == nil)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_resolve_bridge_link_schema.lua: failures present")
print("✅ test_resolve_bridge_link_schema.lua passed")
