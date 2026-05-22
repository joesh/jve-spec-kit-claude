#!/usr/bin/env luajit
--- 019 T004: source_viewer.load_clip + live-bound mode contract.
---
--- Pinned behaviors (FR-002, FR-003, FR-004a, FR-004b, FR-013, FR-016b,
--- FR-016f, FR-028, FR-029):
---   * load_clip enters live-bound mode; mode flag, live_clip_id, and
---     selection_hub publish all transition atomically.
---   * Selection_hub publishes item_type="clip" with clip_id + project_id +
---     owner sequence_id (FR-028).
---   * Mark-setter dispatch routes to OverwriteTrimEdge or RippleTrimEdge
---     based on `core.edit_mode.get_trim_mode()` (FR-013), with the right
---     edge ("left" for IN, "right" for OUT) and delta_frames.
---   * Key-repeat suppression: `is_auto_repeat=true` events drop without
---     dispatch (FR-016b).
---   * Mutation re-resolve: `sequence_content_changed` signal for the
---     owner sequence triggers reload + title + republish (FR-004b).
---   * Auto-unload-on-delete: when the loaded clip vanishes (not present
---     after a sequence_content_changed re-resolve), source_viewer unloads
---     and emits `source_loaded_changed(nil, prev_clip_id)` (FR-004a).
---
--- Black-box: asserts only on observable outputs — selection_hub items,
--- captured command dispatches, emitted signals, public-API return values.
--- No inspection of internal source_viewer fields beyond what M.get_mode()
--- exposes (a documented accessor, part of the public contract).

require("test_env")

print("=== test_source_viewer_load_clip.lua ===")

local selection_hub = require("ui.selection_hub")
local Signals       = require("core.signals")

selection_hub._reset_for_tests()

-- ── Stubs ────────────────────────────────────────────────────────────────────

-- panel_manager / focus_manager / transport — minimal pass-through stubs.
local fake_monitor = {
    sequence_id  = nil,
    sequence     = nil,
    seek_calls   = {},  -- ordered list of frames passed to seek_to_frame
}
function fake_monitor:get_loaded_master_seq_id() return self.sequence_id end
function fake_monitor:load_sequence(seq_id)
    self.sequence_id = seq_id
    self.sequence = { id = seq_id, project_id = "proj_X", name = "SrcSeq " .. seq_id }
end
function fake_monitor:seek_to_frame(frame)
    table.insert(self.seek_calls, frame)
end
function fake_monitor:unload()
    self.sequence_id = nil
    self.sequence = nil
end
function fake_monitor:_set_title(title)
    self.title = title
end

package.loaded["ui.panel_manager"] = {
    get_sequence_monitor = function(view_id)
        if view_id == "source_monitor" then return fake_monitor end
        return nil
    end,
}

package.loaded["ui.focus_manager"] = {
    focus_panel = function(_) end,
}

package.loaded["core.playback.transport"] = {
    bind_role_to_sequence = function(_role, _seq_id) end,
}

-- Intercept-and-discard stub. The I/O dispatch contract that scenarios
-- 2/3/4 used to exercise via command_manager moved into the
-- SetMarkAndTrimIfClip command and is pinned by
-- tests/test_set_mark_and_trim_if_clip_routes_to_trim.lua. This stub
-- stays so that if source_viewer's code ever calls into command_manager
-- the test doesn't crash — if such a call appears unexpectedly, replace
-- with an asserting stub then.
package.loaded["core.command_manager"] = {
    execute_interactive = function() return { success = true } end,
}

-- models.clip / models.sequence stubs returning known rows for `load_clip`.
local clip_rows = {
    clip_alpha = {
        id                   = "clip_alpha",
        name                 = "Alpha",
        project_id           = "proj_X",
        owner_sequence_id    = "owner_seq_1",
        sequence_id          = "source_seq_A",   -- the clip's SOURCE sequence
        track_id             = "track_v1",
        -- Model-field names (no _frame suffix) — matches what
        -- real models/clip.lua build_clip_from_load_row returns.
        source_in            = 50,
        source_out           = 250,
        duration             = 200,
        sequence_start       = 100,
    },
}

-- Sequence stubs must expose start_timecode_frame + playhead_position +
-- :save() because source_viewer.load_clip routes the post-load seek
-- through core.playhead.set (canonical model write — see FR-024 v2
-- 2026-05-22). core.playhead.set asserts start_timecode_frame, writes
-- playhead_position, calls :save(), then emits playhead_changed.
local sequence_rows = {
    source_seq_A = {
        id                    = "source_seq_A",
        project_id            = "proj_X",
        name                  = "AlphaMaster",
        kind                  = "master",
        fps_numerator         = 24,
        fps_denominator       = 1,
        start_timecode_frame  = 0,
        playhead_position     = 0,
    },
    owner_seq_1 = {
        id                    = "owner_seq_1",
        project_id            = "proj_X",
        name                  = "MainEdit",
        kind                  = "sequence",
        start_timecode_frame  = 0,
        playhead_position     = 0,
    },
}
for _, row in pairs(sequence_rows) do
    row.save = function(_self) return true end
end

package.loaded["models.clip"] = {
    load = function(clip_id) return clip_rows[clip_id] end,
}
package.loaded["models.sequence"] = {
    load = function(seq_id) return sequence_rows[seq_id] end,
}

-- Force a fresh load of source_viewer with the stubs in place.
package.loaded["ui.source_viewer"] = nil
local source_viewer = require("ui.source_viewer")

-- ── Scenario 1: load_clip enters live-bound mode ─────────────────────────────
do
    selection_hub._reset_for_tests()
    selection_hub.set_active_panel("source_monitor")

    source_viewer.load_clip("clip_alpha", { skip_focus = true })

    assert(type(source_viewer.get_mode) == "function",
        "source_viewer must expose get_mode() to report which mode it's in")
    assert(source_viewer.get_mode() == "live_bound_clip", string.format(
        "after load_clip, mode must be 'live_bound_clip'; got %q",
        tostring(source_viewer.get_mode())))

    -- Playback binding: monitor was loaded with the clip's SOURCE sequence,
    -- not the clip id, not the owner sequence.
    assert(fake_monitor.sequence_id == "source_seq_A", string.format(
        "load_clip must bind monitor to clip.sequence_id (source_seq_A); "
        .. "got %q", tostring(fake_monitor.sequence_id)))

    -- Selection_hub published the clip-typed item.
    local items = selection_hub.get_selection("source_monitor")
    assert(#items == 1, string.format(
        "load_clip must publish exactly one selection item; got %d", #items))
    local it = items[1]
    assert(it.item_type == "clip", string.format(
        "live-bound publish item_type must be 'clip'; got %q",
        tostring(it.item_type)))
    assert(it.clip_id == "clip_alpha", "publish must carry clip_id")
    assert(it.project_id == "proj_X", "publish must carry project_id")
    assert(it.sequence_id == "owner_seq_1", string.format(
        "publish.sequence_id must be the OWNER sequence (where the clip lives), "
        .. "not the source sequence; got %q", tostring(it.sequence_id)))

    -- FR-024 v2 (2026-05-22): load_clip with no caller-supplied
    -- playhead_frame defaults to clip.source_in. The seek is written
    -- through core.playhead.set — the canonical model write — so the
    -- master sequence's playhead_position row (which the src tab
    -- ruler reads) ends up at clip.source_in. transport's
    -- playhead_changed listener then seeks the source engine; in
    -- production both stay in sync. This test stubs transport, so we
    -- assert on the model write directly (the canonical observable).
    assert(sequence_rows.source_seq_A.playhead_position == 50, string.format(
        "load_clip (no opts.playhead_frame) must write "
        .. "master.playhead_position = clip.source_in (=50); got %s",
        tostring(sequence_rows.source_seq_A.playhead_position)))

    print("  ✓ load_clip enters live-bound mode + publishes item_type='clip'")
    print("  ✓ load_clip default-parks master.playhead_position at clip.source_in (FR-024 v2)")
end

-- ── Scenario 1b: opts.playhead_frame wins over default ───────────────────────
-- FR-024 v2: when the caller (e.g. OpenClipInSourceMonitor for Shift+F)
-- passes opts.playhead_frame, that value is written to the master row,
-- not clip.source_in. The rec-tab-sync behavior is built on top of
-- this; here we pin the helper's contract independently.
do
    sequence_rows.source_seq_A.playhead_position = 0  -- reset
    -- Re-add clip_alpha (scenario 3 below will delete it; this scenario
    -- runs before scenario 3 so it should still be present, but be
    -- explicit for clarity).
    source_viewer._reset_for_tests()
    source_viewer.load_clip("clip_alpha", { skip_focus = true, playhead_frame = 137 })

    assert(sequence_rows.source_seq_A.playhead_position == 137, string.format(
        "load_clip with opts.playhead_frame=137 must write master.playhead_position=137; "
        .. "got %s", tostring(sequence_rows.source_seq_A.playhead_position)))
    print("  ✓ load_clip honors opts.playhead_frame (caller-supplied wins over default)")
end

-- I/O dispatch contract (formerly scenarios 2/3) lives in
-- tests/test_set_mark_and_trim_if_clip_routes_to_trim.lua — the dispatch
-- moved out of source_viewer into the SetMarkAndTrimIfClip command.
-- Auto-repeat suppression (formerly scenario 4) lives in
-- keyboard_shortcuts.lua, which drops auto-repeat events before any
-- command runs.

-- ── Scenario 2: mutation re-resolve via sequence_content_changed (FR-004b) ───
do
    -- Mutate the clip's name in the model and emit the signal. Source viewer
    -- must reload + recompute its title via monitor:_set_title.
    clip_rows.clip_alpha.name = "AlphaRenamed"
    fake_monitor.title = nil

    Signals.emit("sequence_content_changed", "owner_seq_1")

    assert(fake_monitor.title and fake_monitor.title:find("AlphaRenamed"),
        string.format(
        "after sequence_content_changed on the owner sequence, source_viewer "
        .. "must reload and recompute the title to include the new clip name; "
        .. "got title=%s", tostring(fake_monitor.title)))
    print("  ✓ sequence_content_changed triggers reload + title recompute")
end

-- ── Scenario 3: auto-unload on clip deletion (FR-004a) ───────────────────────
do
    local captured_unload = {}
    Signals.connect("source_loaded_changed", function(new_id, prev_id)
        table.insert(captured_unload, { new = new_id, prev = prev_id })
    end)

    -- Simulate the clip being deleted: remove it from the model, then emit
    -- the signal. Source viewer's re-resolve handler should detect the
    -- vanished clip and unload.
    clip_rows.clip_alpha = nil
    captured_unload = {}

    Signals.emit("sequence_content_changed", "owner_seq_1")

    assert(source_viewer.get_mode() ~= "live_bound_clip", string.format(
        "after the loaded clip is deleted, source_viewer must no longer be "
        .. "in live_bound_clip mode; got %q",
        tostring(source_viewer.get_mode())))

    -- The unload must have emitted source_loaded_changed with (nil, prev).
    local saw_unload = false
    for _, e in ipairs(captured_unload) do
        if e.new == nil and (e.prev == "clip_alpha" or e.prev == "source_seq_A") then
            saw_unload = true
            break
        end
    end
    assert(saw_unload,
        "auto-unload on clip-delete must emit source_loaded_changed(nil, prev)")
    print("  ✓ deleted clip triggers auto-unload + source_loaded_changed")
end

print("\n✅ test_source_viewer_load_clip.lua passed")
