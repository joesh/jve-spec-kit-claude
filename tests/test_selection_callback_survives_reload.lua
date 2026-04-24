#!/usr/bin/env luajit
-- Regression: reload_clips must not muzzle the selection-changed callback.
--
-- TSO 2026-04-21 14:43:46 → 14:44:22: user Nudges a selected clip; the
-- command triggers content_changed → reload_clips; from that moment on,
-- every subsequent timeline click produces zero inspector.update_selection
-- events. Inspector is frozen showing the timeline/sequence it fell back
-- to when the clip briefly "deselected".
--
-- Root cause: timeline_core_state.reload_clips() at line 579 calls
--   selection_state.set_on_selection_changed(nil)
-- whenever it refreshes an active clip selection. The author's intent
-- (per the "Trigger callback?" comment) was to re-broadcast; the effect
-- is to delete the callback, silencing every future selection change.
--
-- Domain behavior (not implementation):
--   After any content-changing command fires while a clip is selected,
--   clicking a different clip still updates the broadcast selection.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local selection_state = require("ui.timeline.state.selection_state")

print("=== reload_clips must keep selection callback alive ===")

local db_path = "/tmp/jve/test_selection_callback_survives_reload.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('p1', 'Callback Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'p1', 'Seq1', 'timeline', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Two clips to select between.
for i, cid in ipairs({"c1", "c2"}) do
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, clip_kind, owner_sequence_id,
            track_id, media_id, name,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, created_at, modified_at)
        VALUES (?, 'p1', 'timeline', 'seq1', 't1', NULL, ?,
            ?, 120, 0, 120, 24000, 1001, 1, ?, ?)
    ]])
    stmt:bind_value(1, cid); stmt:bind_value(2, cid .. "-name")
    stmt:bind_value(3, (i - 1) * 120); stmt:bind_value(4, now); stmt:bind_value(5, now)
    assert(stmt:exec(), "clip insert failed for " .. cid)
    stmt:finalize()
end

timeline_state.init("seq1", "p1")

-- Register the callback that drives the selection_hub broadcast.
local broadcast_log = {}
selection_state.set_on_selection_changed(function(selected_clips)
    local ids = {}
    for _, c in ipairs(selected_clips) do table.insert(ids, c.id) end
    table.insert(broadcast_log, table.concat(ids, ","))
end)

-- Baseline: selecting a clip broadcasts its id.
local clips = timeline_state.get_clips()
local c1 = nil
local c2 = nil
for _, c in ipairs(clips) do
    if c.id == "c1" then c1 = c
    elseif c.id == "c2" then c2 = c end
end
assert(c1 and c2, "setup: expected c1 and c2 in cached clips")

selection_state.set_selection({c1})
assert(broadcast_log[#broadcast_log] == "c1", string.format(
    "baseline: expected broadcast 'c1', got %s", tostring(broadcast_log[#broadcast_log])))

-- Now reload clips (simulates content_changed after any command).
timeline_state.reload_clips("seq1")

-- After reload, selecting a different clip MUST still broadcast.
-- Before the fix: reload_clips nil'd the callback, so this would be silent.
local count_before = #broadcast_log
selection_state.set_selection({c2})
local count_after = #broadcast_log
assert(count_after > count_before, string.format(
    "after reload_clips: clicking a different clip produced zero broadcasts " ..
    "(log count unchanged at %d). reload_clips muzzled the callback.",
    count_before))
assert(broadcast_log[#broadcast_log] == "c2", string.format(
    "after reload_clips: expected broadcast 'c2', got %s",
    tostring(broadcast_log[#broadcast_log])))

-- Extra: deselecting (to empty) also broadcasts.
count_before = #broadcast_log
selection_state.set_selection({})
assert(#broadcast_log > count_before, "deselect broadcast missing after reload_clips")
assert(broadcast_log[#broadcast_log] == "", string.format(
    "after deselect: expected empty broadcast, got %q",
    broadcast_log[#broadcast_log]))

print("✅ test_selection_callback_survives_reload.lua passed")
