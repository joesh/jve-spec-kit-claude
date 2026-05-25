-- Integration (019 T004): source_viewer.load_clip + live-bound mode.
--
-- Pinned behaviors (FR-002, FR-003, FR-004a, FR-004b, FR-024 v2,
-- FR-028, FR-029):
--   * load_clip enters live_bound_clip mode; selection_hub publishes
--     item_type="clip" carrying clip_id + project_id + owner_sequence_id.
--   * Monitor binds to the clip's SOURCE sequence (clip.sequence_id),
--     not the owner sequence and not the clip id.
--   * Default-park: master.playhead_position lands at clip.source_in
--     (canonical model write via core.playhead.set).
--   * opts.playhead_frame caller value wins over the default.
--   * Parking-clamp: out-of-range opts.playhead_frame clamps to
--     [clip.source_in, clip.source_out].
--   * sequence_content_changed on the owner triggers reload + title
--     recompute (FR-004b).
--   * Clip deletion (clip vanishes after a re-resolve) auto-unloads
--     and emits source_loaded_changed(nil, prev) (FR-004a).
--
-- Replaces the wholesale-mock test of the same name (which stubbed
-- models.clip + models.sequence + panel_manager + focus_manager +
-- transport + command_manager all at once). Real bindings throughout.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_source_viewer_load_clip.lua ===")

require("test_env")

local database        = require("core.database")
local selection_hub   = require("ui.selection_hub")
local Signals         = require("core.signals")
local Sequence        = require("models.sequence")
local Clip            = require("models.clip")
local qt_constants    = require("core.qt_constants")

-- ── DB: owner record + source master + one clip referencing the master.
-- Plus a placeholder media + media_ref so the master is "loadable" by
-- SequenceMonitor (audio_bus_rate requires the record's audio_sample_rate).
local DB = "/tmp/jve/test_source_viewer_load_clip_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj_X', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES
        ('owner_seq_1',  'proj_X', 'MainEdit',    'sequence', 24, 1, 48000,
         1920, 1080, 0, 0, 1000, 0, 0, 0),
        ('source_seq_A', 'proj_X', 'AlphaMaster', 'master',   24, 1, NULL,
         1920, 1080, 0, 0,  300, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('track_v1',  'owner_seq_1',  'V1', 'VIDEO', 1, 1),
        ('src_a_v1',  'source_seq_A', 'V1', 'VIDEO', 1, 1);
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, fps_mismatch_policy, name,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('clip_alpha', 'proj_X', 'owner_seq_1', 'source_seq_A',
              'track_v1', 50, 250, 100, 200, 'resample', 'Alpha',
              1, 1.0, 0, 0, 0);
]]))

-- Real source monitor + transport bootstrap (engine binds via the
-- transport_ready listener — see sequence_monitor.lua:247).
local source_mon = ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "proj_X",
}).source

selection_hub._reset_for_tests()
selection_hub.set_active_panel("source_monitor")

-- Force fresh load of source_viewer with our registered monitor.
package.loaded["ui.source_viewer"] = nil
local source_viewer = require("ui.source_viewer")

local function park_master_at(frame)
    local seq = Sequence.load("source_seq_A")
    seq.playhead_position = frame
    seq:save()
end

local function master_playhead()
    return Sequence.load("source_seq_A").playhead_position
end

-- ── Scenario 1: load_clip enters live-bound mode + publishes item ──────
print("-- (1) load_clip enters live-bound mode --")
park_master_at(0)
source_viewer.load_clip("clip_alpha", { skip_focus = true })

assert(source_viewer.get_mode() == "live_bound_clip", string.format(
    "after load_clip, mode must be 'live_bound_clip'; got %s",
    tostring(source_viewer.get_mode())))
assert(source_mon.sequence_id == "source_seq_A", string.format(
    "monitor must bind to clip.sequence_id (source_seq_A); got %s",
    tostring(source_mon.sequence_id)))

local items = selection_hub.get_selection("source_monitor")
assert(#items == 1, string.format(
    "load_clip must publish exactly one selection item; got %d", #items))
local it = items[1]
assert(it.item_type == "clip"
   and it.clip_id == "clip_alpha"
   and it.project_id == "proj_X"
   and it.sequence_id == "owner_seq_1", string.format(
    "publish must carry (item_type='clip', clip_id, project_id, owner sequence_id); "
    .. "got (%s, %s, %s, %s)",
    tostring(it.item_type), tostring(it.clip_id),
    tostring(it.project_id), tostring(it.sequence_id)))

-- FR-024 v2: default-park master.playhead at clip.source_in (= 50).
assert(master_playhead() == 50, string.format(
    "default-park: master.playhead_position must == clip.source_in (50); got %s",
    tostring(master_playhead())))
print("  PASS live-bound mode + selection-hub publish + default-park at source_in")

-- ── Scenario 1b: opts.playhead_frame caller wins over default ─────────
print("-- (1b) opts.playhead_frame wins --")
park_master_at(0)
source_viewer._reset_for_tests()
source_viewer.load_clip("clip_alpha",
    { skip_focus = true, playhead_frame = 137 })
assert(master_playhead() == 137, string.format(
    "in-range opts.playhead_frame must be written verbatim; got %s",
    tostring(master_playhead())))
print("  PASS opts.playhead_frame=137 honored")

-- ── Scenario 1c: parking-clamp out-of-range to clip's source range ────
print("-- (1c) parking-clamp out-of-range --")
park_master_at(0)
source_viewer._reset_for_tests()
source_viewer.load_clip("clip_alpha",
    { skip_focus = true, playhead_frame = 9999 })
assert(master_playhead() == 250, string.format(
    "above source_out must clamp down to 250; got %s",
    tostring(master_playhead())))

park_master_at(0)
source_viewer._reset_for_tests()
source_viewer.load_clip("clip_alpha",
    { skip_focus = true, playhead_frame = -50 })
assert(master_playhead() == 50, string.format(
    "below source_in must clamp up to 50; got %s",
    tostring(master_playhead())))
print("  PASS parking-clamp [50, 250]")

-- ── Scenario 2: sequence_content_changed → reload + title recompute ───
-- Real SequenceMonitor:_set_title writes to a Qt label widget; query
-- it back via PROPERTIES.GET_TEXT rather than the headless test's
-- old self.title fabrication.
print("-- (2) sequence_content_changed reloads + retitles --")
source_viewer._reset_for_tests()
source_viewer.load_clip("clip_alpha", { skip_focus = true })

local function monitor_title()
    return qt_constants.PROPERTIES.GET_TEXT(source_mon:get_title_widget())
end

-- Rename the clip in the DB and fire the signal.
local renamed = Clip.load("clip_alpha")
renamed.name = "AlphaRenamed"
assert(renamed:save(), "rename: clip save must succeed")

local title_before = monitor_title()
Signals.emit("sequence_content_changed", "owner_seq_1")

local title_after = monitor_title()
assert(title_after and title_after:find("AlphaRenamed"), string.format(
    "after sequence_content_changed on the owner sequence, source_viewer "
    .. "must reload and retitle to include the new clip name; "
    .. "title before=%s after=%s",
    tostring(title_before), tostring(title_after)))
print("  PASS sequence_content_changed → reload + retitle")

-- ── Scenario 3: clip deletion → auto-unload + source_loaded_changed ───
print("-- (3) deleted clip auto-unloads --")
local unload_log = {}
local unload_token = Signals.connect("source_loaded_changed",
    function(new_id, prev_id)
        unload_log[#unload_log + 1] = { new = new_id, prev = prev_id }
    end)

-- Delete the clip row, then emit the re-resolve signal.
assert(db:exec("DELETE FROM clips WHERE id = 'clip_alpha';"))
Signals.emit("sequence_content_changed", "owner_seq_1")

assert(source_viewer.get_mode() ~= "live_bound_clip", string.format(
    "after the loaded clip is deleted, source_viewer must leave "
    .. "live_bound_clip mode; got %s", tostring(source_viewer.get_mode())))

local saw_unload = false
for _, e in ipairs(unload_log) do
    if e.new == nil
       and (e.prev == "clip_alpha" or e.prev == "source_seq_A") then
        saw_unload = true
        break
    end
end
assert(saw_unload,
    "deletion must emit source_loaded_changed(nil, prev)")
Signals.disconnect(unload_token)
print("  PASS deleted clip → auto-unload + signal")

print("\nPASS test_source_viewer_load_clip.lua")
