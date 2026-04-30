#!/usr/bin/env luajit
-- Black-box test: pressing Delete/Backspace actually removes clips from the database.
-- Uses real command_manager, real timeline_state, real TOML keybindings, real SQLite.
-- Only Qt widget bindings are mocked.

require('test_env')

-- ── Minimal Qt stubs (only what's needed to break require chains) ──
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

-- ── Real modules ──
local db = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local Media = require("models.media")
local command_manager = require("core.command_manager")
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local timeline_state = require("ui.timeline.timeline_state")

-- ── Test database setup ──
local db_path = "/tmp/jve/test_keyboard_delete.jvp"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
db.init(db_path)

local project = Project.create("Test Delete", { fps_mismatch_policy = 'resample' })
project:save()

local media = Media.create({
    id = "test_media",
    project_id = project.id,
    file_path = "/tmp/jve/test_video.mov",
    name = "Test Video",
    duration_frames = 500,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
})
media:save(db.get_connection())

local mc_seq_id = require("test_env").create_test_masterclip_sequence(
    project.id, "MC", 24, 1, 500, "test_media")

local seq = Sequence.create("Seq", project.id,
    {  fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { kind = "nested", audio_sample_rate = 48000 })
seq:save()
local track = Track.create_video("V1", seq.id, { index = 1 })
track:save()

local function make_clip(name, start, dur)
    local clip_id = Clip.create({
        name = name,
        project_id = seq.project_id,
        track_id = track.id,
        owner_sequence_id = seq.id,
        nested_sequence_id = mc_seq_id,
        timeline_start_frame = start,
        duration_frames = dur,
        source_in_frame = 0,
        source_out_frame = dur,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
    return Clip.load(clip_id)
end

-- ── Init real command system + keyboard dispatch ──
-- After QShortcut migration, Delete/Backspace are dispatched by QShortcut,
-- not the Lua residual handler. Test through registry.handle_key_event()
-- (same dispatch function the QShortcut handlers use).
local registry = require("core.keyboard_shortcut_registry")

local function init_all()
    -- Reload modules to clear state from previous test
    package.loaded["core.command_manager"] = nil
    package.loaded["core.command_registry"] = nil
    package.loaded["core.command_history"] = nil
    package.loaded["core.command_state_manager"] = nil
    package.loaded["core.keyboard_shortcuts"] = nil
    package.loaded["core.keyboard_shortcut_registry"] = nil
    package.loaded["ui.timeline.timeline_state"] = nil
    package.loaded["ui.timeline.state.timeline_core_state"] = nil
    package.loaded["ui.timeline.state.timeline_state_data"] = nil
    package.loaded["ui.timeline.state.selection_state"] = nil

    command_manager = require("core.command_manager")
    keyboard_shortcuts = require("core.keyboard_shortcuts")
    registry = require("core.keyboard_shortcut_registry")
    timeline_state = require("ui.timeline.timeline_state")
    focus_manager = require("ui.focus_manager")

    command_manager.init(seq.id, project.id)

    local project_browser_stub = { add_selected_to_timeline = function() end }
    local timeline_panel_stub = { is_dragging = function() return false end }
    keyboard_shortcuts.init(command_manager,
        project_browser_stub, timeline_panel_stub)

    focus_manager.set_focused_panel("timeline")
    timeline_state.set_playhead_position(0)
end

-- Dispatch a key event through the registry (simulates QShortcut handler path)
local function dispatch_key(key, modifiers)
    command_manager.begin_command_event("ui")
    local handled = registry.handle_key_event(key, modifiers, "timeline")
    command_manager.end_command_event()
    return handled
end

-- ── Qt key codes (literal values from Qt::Key enum, NOT from our constants) ──
-- Using raw values ensures the test catches wrong-constant bugs like the F2 collision.
local QT_KEY_DELETE    = 16777223  -- Qt::Key_Delete    = 0x01000007
local QT_KEY_BACKSPACE = 16777219  -- Qt::Key_Backspace = 0x01000003
local QT_MOD_SHIFT     = 0x02000000

-- ── Test 1: Delete key removes selected clip from database ──
print("\nTest 1: Delete key removes selected clip from database")
do
    local clip_a = make_clip("A", 0, 24)
    local clip_b = make_clip("B", 24, 24)
    init_all()
    timeline_state.set_selection({ clip_b })

    dispatch_key(QT_KEY_DELETE, 0)

    -- Verify clip B removed from database (query by sequence, filter by track)
    local all_clips = db.load_clips(seq.id)
    local remaining = {}
    for _, c in ipairs(all_clips) do
        if c.track_id == track.id then remaining[#remaining + 1] = c end
    end
    assert(#remaining == 1,
        string.format("Expected 1 clip remaining, got %d", #remaining))
    assert(remaining[1].id == clip_a.id,
        "Clip A should survive, got: " .. remaining[1].name)
    print("  ✓ clip B deleted from database")

    -- Cleanup for next test
    clip_a:delete()
end

-- ── Test 2: Backspace also removes selected clip ──
print("\nTest 2: Backspace removes selected clip from database")
do
    local clip_c = make_clip("C", 0, 24)
    local clip_d = make_clip("D", 24, 24)
    init_all()
    timeline_state.set_selection({ clip_d })

    dispatch_key(QT_KEY_BACKSPACE, 0)

    local all_clips = db.load_clips(seq.id)
    local remaining = {}
    for _, c in ipairs(all_clips) do
        if c.track_id == track.id then remaining[#remaining + 1] = c end
    end
    assert(#remaining == 1,
        string.format("Expected 1 clip remaining, got %d", #remaining))
    assert(remaining[1].id == clip_c.id,
        "Clip C should survive, got: " .. remaining[1].name)
    print("  ✓ clip D deleted from database")

    clip_c:delete()
end

-- ── Test 3: Shift+Delete ripple-deletes (downstream clips shift left) ──
print("\nTest 3: Shift+Delete ripple-deletes and shifts downstream clips")
do
    local clip_e = make_clip("E", 0, 24)
    local clip_f = make_clip("F", 24, 24)
    local clip_g = make_clip("G", 48, 24)
    init_all()
    timeline_state.set_selection({ clip_f })

    dispatch_key(QT_KEY_DELETE, QT_MOD_SHIFT)

    local all_clips = db.load_clips(seq.id)
    local remaining = {}
    for _, c in ipairs(all_clips) do
        if c.track_id == track.id then remaining[#remaining + 1] = c end
    end
    assert(#remaining == 2,
        string.format("Expected 2 clips remaining, got %d", #remaining))

    -- Sort by timeline_start for predictable ordering
    table.sort(remaining, function(a, b) return a.timeline_start < b.timeline_start end)

    assert(remaining[1].id == clip_e.id, "Clip E should be first")
    assert(remaining[1].timeline_start == 0, "Clip E should stay at 0")
    assert(remaining[2].id == clip_g.id, "Clip G should be second")
    assert(remaining[2].timeline_start == 24,
        string.format("Clip G should shift from 48 to 24, got %d",
            remaining[2].timeline_start))
    print("  ✓ clip F ripple-deleted, clip G shifted to frame 24")

    clip_e:delete()
    clip_g:delete()
end

-- ── Test 4: Delete not handled by Lua residual handler ──
-- In the QShortcut architecture, text input protection is Qt-native:
-- QLineEdit accepts ShortcutOverride for Delete, preventing QShortcut from firing.
print("\nTest 4: Delete not handled by Lua residual handler")
do
    local clip_h = make_clip("H", 0, 24)
    init_all()
    timeline_state.set_selection({ clip_h })

    -- Lua handler should return false for Delete (not a residual key)
    local handled = keyboard_shortcuts.handle_key({
        key = QT_KEY_DELETE, modifiers = 0,
        text = "", focus_widget_is_text_input = false,
    })
    assert(not handled, "Delete must not be handled by Lua residual handler")

    -- Clip still exists (wasn't deleted via Lua handler)
    local all_clips = db.load_clips(seq.id)
    local remaining = {}
    for _, c in ipairs(all_clips) do
        if c.track_id == track.id then remaining[#remaining + 1] = c end
    end
    assert(#remaining == 1, "Clip should survive — Lua handler doesn't dispatch Delete")
    print("  ✓ Delete not handled by residual handler")

    clip_h:delete()
end

print("\n✅ test_keyboard_shortcuts_delete_clip.lua passed")
