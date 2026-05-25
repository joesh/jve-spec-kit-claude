-- Integration (019 T008): source_viewer publishes selection_hub items
-- under "source_monitor" so the Inspector renders the right schema.
--
-- Domain rules:
--   * Staged-sequence load (load_master_clip) → publish carries the
--     sequence_id + project_id + item_type="timeline" (sequence schema).
--   * Unload clears the published selection.
--   * Subsequent load replaces (no accumulation).
--   * Live-bound load (load_clip, FR-028) → publish carries clip_id +
--     project_id + OWNER sequence_id (not the source sequence) +
--     item_type="clip" (clip schema).
--
-- Replaces the stub-heavy test of the same name. Real bindings only.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_source_viewer_publishes_selection.lua ===")

require("test_env")

local database        = require("core.database")
local selection_hub   = require("ui.selection_hub")

-- ── DB ────────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_source_viewer_publishes_selection_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj_under_test', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    -- Record sequence (provides audio_sample_rate for audio_bus_rate).
    -- All other sequences below are masters (kind='master', NULL audio rate).
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES
        ('rec',              'proj_under_test', 'Rec',     'sequence', 24, 1, 48000,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('loaded_seq_id',    'proj_under_test', 'Loaded',  'master',   24, 1, NULL,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('first_seq',        'proj_under_test', 'First',   'master',   24, 1, NULL,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('second_seq',       'proj_under_test', 'Second',  'master',   24, 1, NULL,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('src_seq_for_clip', 'proj_under_test', 'SrcMaster','master',  24, 1, NULL,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('owner_seq_live',   'proj_under_test', 'OwnerTL', 'sequence', 24, 1, 48000,
         1920, 1080, 0, 0, 1000, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('rv1', 'rec',              'V1', 'VIDEO', 1, 1),
        ('lv1', 'loaded_seq_id',    'V1', 'VIDEO', 1, 1),
        ('fv1', 'first_seq',        'V1', 'VIDEO', 1, 1),
        ('sv1', 'second_seq',       'V1', 'VIDEO', 1, 1),
        ('cv1', 'src_seq_for_clip', 'V1', 'VIDEO', 1, 1),
        ('ov1', 'owner_seq_live',   'V1', 'VIDEO', 1, 1);
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, fps_mismatch_policy, name,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('clip_live', 'proj_under_test', 'owner_seq_live',
              'src_seq_for_clip', 'ov1', 30, 180, 100, 150,
              'resample', 'LiveClip', 1, 1.0, 0, 0, 0);
]]))

-- Real source monitor + transport bootstrap.
local source_mon = ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "proj_under_test",
}).source

selection_hub._reset_for_tests()
-- Inspector subscribes to the active panel; mirror that here so the
-- listener actually fires when source_viewer publishes.
selection_hub.set_active_panel("source_monitor")

-- Capture the items selection_hub broadcasts under "source_monitor".
local last_items, last_panel
selection_hub.register_listener(function(items, panel_id)
    if panel_id == "source_monitor" then
        last_items = items
        last_panel = panel_id
    end
end)

-- Force fresh load of source_viewer with our registered monitor.
package.loaded["ui.source_viewer"] = nil
local source_viewer = require("ui.source_viewer")

-- ── (1) load_master_clip → staged-sequence publish ────────────────────
print("-- (1) load_master_clip publishes timeline-typed selection --")
last_items, last_panel = nil, nil
source_viewer.load_master_clip("loaded_seq_id", { skip_focus = true })

assert(last_panel == "source_monitor", string.format(
    "publish panel_id must be 'source_monitor'; got %s",
    tostring(last_panel)))
assert(type(last_items) == "table" and #last_items == 1, string.format(
    "publish must carry exactly one item; got %s",
    last_items and tostring(#last_items) or "nil"))
do
    local it = last_items[1]
    assert(it.sequence_id == "loaded_seq_id"
       and it.project_id  == "proj_under_test"
       and it.item_type   == "timeline", string.format(
        "staged publish: (item_type, sequence_id, project_id) must be "
        .. "('timeline', 'loaded_seq_id', 'proj_under_test'); got (%s, %s, %s)",
        tostring(it.item_type), tostring(it.sequence_id), tostring(it.project_id)))
end
print("  PASS staged-mode publish carries timeline-typed item")

-- ── (2) unload clears the published selection ─────────────────────────
print("-- (2) unload clears selection --")
source_viewer.unload()
local current = selection_hub.get_selection("source_monitor")
assert(type(current) == "table" and #current == 0, string.format(
    "after unload, source_monitor selection must be empty; got %d items",
    type(current) == "table" and #current or -1))
print("  PASS unload clears selection")

-- ── (3) subsequent load replaces (no accumulation) ────────────────────
print("-- (3) subsequent load replaces --")
source_viewer.load_master_clip("first_seq", { skip_focus = true })
local first = selection_hub.get_selection("source_monitor")
assert(#first == 1 and first[1].sequence_id == "first_seq",
    "fixture: first load must publish first_seq")

source_viewer.load_master_clip("second_seq", { skip_focus = true })
local second = selection_hub.get_selection("source_monitor")
assert(#second == 1 and second[1].sequence_id == "second_seq", string.format(
    "second load must replace prior selection with new sequence_id; "
    .. "got count=%d sequence_id=%s",
    #second, tostring(second[1] and second[1].sequence_id)))
print("  PASS load replaces (no accumulation)")

-- ── (4) live-bound load → item_type='clip' (FR-028) ───────────────────
print("-- (4) live-bound load publishes clip-typed selection --")
source_viewer.load_clip("clip_live", { skip_focus = true })

local published = selection_hub.get_selection("source_monitor")
assert(#published == 1, string.format(
    "live-bound publish must carry exactly one item; got %d", #published))
do
    local it = published[1]
    assert(it.item_type   == "clip"
       and it.clip_id     == "clip_live"
       and it.project_id  == "proj_under_test"
       and it.sequence_id == "owner_seq_live", string.format(
        "live-bound publish: (item_type, clip_id, project_id, sequence_id) "
        .. "must be ('clip', 'clip_live', 'proj_under_test', 'owner_seq_live') "
        .. "— sequence_id must be the OWNER sequence, not the clip's source; "
        .. "got (%s, %s, %s, %s)",
        tostring(it.item_type), tostring(it.clip_id),
        tostring(it.project_id), tostring(it.sequence_id)))
end
print("  PASS live-bound publish carries clip-typed item with owner sequence_id")

print("\nPASS test_source_viewer_publishes_selection.lua")
