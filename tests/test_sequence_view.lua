--- Test: SequenceView construction, sequence loading, playhead persistence,
--- marks via masterclip, listener notification, engine callback wiring.
--
-- Uses real DB for masterclip/sequence models. Qt and media infra mocked.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

-- Timer: captures callback for manual tick pumping
local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

local function pump_timers()
    local cbs = timer_callbacks
    timer_callbacks = {}
    for _, cb in ipairs(cbs) do cb() end
end

-- Track Qt operations for verification
local qt_log = {}

-- Mock qt_constants (comprehensive for widget creation + playback)
package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        ASSET_OPEN = function() return nil end,
        ASSET_INFO = function() return nil end,
        ASSET_CLOSE = function() end,
        READER_CREATE = function() return nil end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        SURFACE_SET_FRAME = function(surface, frame)
            qt_log[#qt_log + 1] = {
                type = "set_frame", surface = surface, frame = frame,
            }
        end,
        SURFACE_SET_ROTATION = function(surface, deg)
            qt_log[#qt_log + 1] = {
                type = "set_rotation", surface = surface, degrees = deg,
            }
        end,
    },
    WIDGET = {
        CREATE = function() return { _type = "widget" } end,
        CREATE_LABEL = function(text)
            return { _type = "label", _text = text }
        end,
        CREATE_GPU_VIDEO_SURFACE = function()
            return { _type = "gpu_surface" }
        end,
        CREATE_TIMELINE = function()
            return { _type = "timeline_widget" }
        end,
    },
    LAYOUT = {
        CREATE_VBOX = function() return { _type = "vbox" } end,
        SET_SPACING = function() end,
        SET_MARGINS = function() end,
        ADD_WIDGET = function() end,
        SET_ON_WIDGET = function() end,
        SET_STRETCH_FACTOR = function() end,
    },
    PROPERTIES = {
        SET_STYLE = function() end,
        SET_TEXT = function(label, text)
            if label then label._text = text end
        end,
    },
    GEOMETRY = {
        SET_SIZE_POLICY = function() end,
    },
    CONTROL = {
        SET_WIDGET_SIZE_POLICY = function() end,
    },
}

-- Mock global timeline API (for mark bar)
_G.timeline = {
    get_dimensions = function() return 400, 20 end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_triangle = function() end,
    add_text = function() end,
    update = function() end,
    set_lua_state = function() end,
    set_mouse_event_handler = function() end,
    set_resize_event_handler = function() end,
    set_desired_height = function() end,
}

-- Mock media_cache (with context tracking)
local created_contexts = {}
package.loaded["core.media.media_cache"] = {
    create_context = function(id)
        created_contexts[id] = true
    end,
    destroy_context = function(id)
        created_contexts[id] = nil
    end,
    activate = function() return { rotation = 0 } end,
    get_video_frame = function(frame, ctx) return "frame_" .. frame end,
    set_playhead = function() end,
    is_loaded = function() return true end,
    get_asset_info = function() return { rotation = 0 } end,
    stop_all_prefetch = function() end,
    ensure_audio_pooled = function()
        return { has_audio = true, audio_sample_rate = 48000 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
}

-- Mock logger
package.loaded["core.logger"] = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock Renderer (returns info from DB-loaded sequence)
local mock_renderer_info = {}
package.loaded["core.renderer"] = {
    get_sequence_info = function(seq_id)
        if mock_renderer_info[seq_id] then
            return mock_renderer_info[seq_id]
        end
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function(seq, frame, ctx_id)
        if frame >= 0 and frame < 100 then
            return "frame_handle_" .. frame, {
                clip_id = "clip1",
                media_path = "/test.mov",
                source_frame = frame,
                rotation = 0,
            }
        end
        return nil, nil
    end,
}

-- Mock Mixer
package.loaded["core.mixer"] = {
    resolve_audio_sources = function(seq, frame, fps_num, fps_den, mc)
        if frame >= 0 and frame < 100 then
            return {
                { path = "/test.mov", source_offset_us = 0, volume = 1.0,
                  duration_us = 4166666, clip_start_us = 0,
                  clip_end_us = 4166666, clip_id = "aclip1" },
            }, { aclip1 = true }
        end
        return {}, {}
    end,
}

-- Mock signals
package.loaded["core.signals"] = {
    connect = function() end,
    emit = function() end,
}

--------------------------------------------------------------------------------
-- Initialize real DB + models
--------------------------------------------------------------------------------

local database = require("core.database")
local import_schema = require("import_schema")

local DB_PATH = "/tmp/jve/test_sequence_view.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create project
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

-- Create media
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames,
                     fps_numerator, fps_denominator, width, height,
                     audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media1', 'proj', '/test/clip.mov', 'TestClip', 100, 24, 1,
           1920, 1080, 2, 'h264', strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Create masterclip sequence with stream clip
local test_env = require("test_env")
local mc_id = test_env.create_test_masterclip_sequence(
    "proj", "TestMaster", 24, 1, 100, "media1")

-- Register renderer info for masterclip
mock_renderer_info[mc_id] = {
    fps_num = 24, fps_den = 1,
    kind = "masterclip", name = "TestMaster",
    audio_sample_rate = 48000,
}

-- Create timeline sequence
assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('timeline1', 'proj', 'MyTimeline', 'timeline', 24, 1, 48000, 1920, 1080,
           0, 2000, 0, strftime('%s','now'), strftime('%s','now'))
]]))

-- Add a track + clip to timeline (for _compute_content_end)
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index,
                      enabled, locked, muted, soloed, volume, pan)
    VALUES('tv1', 'timeline1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('tclip1', 'proj', 'timeline', 'Clip1', 'tv1', 'media1', 0, 50, 0, 50, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

mock_renderer_info["timeline1"] = {
    fps_num = 24, fps_den = 1,
    kind = "timeline", name = "MyTimeline",
    audio_sample_rate = 48000,
}

--------------------------------------------------------------------------------
-- Load SequenceView
--------------------------------------------------------------------------------
local SequenceView = require("ui.sequence_view")

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

print("=== test_sequence_view.lua ===")

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. " (expected assert, got success)")
    return err
end

-- ─── Test 1: Constructor validates config ───
print("\n--- constructor validation ---")
do
    expect_assert(function() SequenceView.new({}) end,
        "missing view_id")
    expect_assert(function() SequenceView.new({ view_id = "" }) end,
        "empty view_id")
    print("  ok")
end

-- ─── Test 2: Construction creates widgets and engine ───
print("\n--- construction ---")
do
    local view = SequenceView.new({ view_id = "test_view_1" })

    assert(view.view_id == "test_view_1", "view_id stored")
    assert(view.media_context_id == "test_view_1", "media_context_id matches view_id")
    assert(view.engine, "engine created")
    assert(view:get_widget(), "container widget created")
    assert(view:get_title_widget(), "title widget created")
    assert(view:get_video_surface(), "video surface created")
    assert(created_contexts["test_view_1"], "media_cache context created")
    assert(view.total_frames == 0, "no frames before load")
    assert(not view:has_clip(), "no clip before load")

    view:destroy()
    assert(not created_contexts["test_view_1"], "context destroyed")
    print("  ok")
end

-- ─── Test 3: Load masterclip sequence ───
print("\n--- load masterclip ---")
do
    local view = SequenceView.new({ view_id = "test_mc" })
    timer_callbacks = {}

    view:load_sequence(mc_id)

    assert(view.sequence_id == mc_id, "sequence_id set")
    assert(view:has_clip(), "has_clip after load")
    assert(view.total_frames == 100, "total_frames from masterclip")
    assert(view.fps_num == 24, "fps_num")
    assert(view.fps_den == 1, "fps_den")
    assert(view.sequence:is_masterclip(), "sequence is masterclip")

    -- Title should show "Source: TestMaster"
    local title = view:get_title_widget()
    assert(title._text:find("Source"), "title contains Source")
    assert(title._text:find("TestMaster"), "title contains name")

    view:destroy()
    print("  ok")
end

-- ─── Test 4: Load timeline sequence ───
print("\n--- load timeline ---")
do
    local view = SequenceView.new({ view_id = "test_tl" })
    timer_callbacks = {}

    view:load_sequence("timeline1")

    assert(view.sequence_id == "timeline1", "sequence_id set")
    assert(view:has_clip(), "has_clip after load")
    assert(view.total_frames == 50, "total_frames from timeline clips")
    assert(view.fps_num == 24, "fps_num")
    assert(not view.sequence:is_masterclip(), "NOT masterclip")

    -- Title should show "Timeline: MyTimeline"
    local title = view:get_title_widget()
    assert(title._text:find("Timeline"), "title contains Timeline")
    assert(title._text:find("MyTimeline"), "title contains name")

    view:destroy()
    print("  ok")
end

-- ─── Test 5: Playhead persistence for masterclip ───
print("\n--- playhead persistence ---")
do
    local view = SequenceView.new({ view_id = "test_persist" })
    timer_callbacks = {}

    view:load_sequence(mc_id)

    -- Set playhead (triggers debounced persist — immediate in test since no timer)
    view:set_playhead(42)
    assert(view.playhead == 42, "playhead updated")

    -- Persist fires immediately (no qt timer mock with callback)
    pump_timers()

    -- Verify persisted to DB
    local Sequence = require("models.sequence")
    local reloaded = Sequence.load(mc_id)
    assert(reloaded.playhead_position == 42,
        "playhead persisted to DB, got " .. tostring(reloaded.playhead_position))

    -- Reload view: should restore playhead
    local view2 = SequenceView.new({ view_id = "test_persist2" })
    view2:load_sequence(mc_id)
    assert(view2.playhead == 42,
        "playhead restored from DB, got " .. view2.playhead)

    view:destroy()
    view2:destroy()
    print("  ok")
end

-- ─── Test 6: Playhead NOT persisted for timeline ───
print("\n--- no persist for timeline ---")
do
    local view = SequenceView.new({ view_id = "test_no_persist" })
    timer_callbacks = {}

    view:load_sequence("timeline1")
    view:set_playhead(25)
    pump_timers()

    -- Timeline playhead should NOT affect sequence record
    local Sequence = require("models.sequence")
    local reloaded = Sequence.load("timeline1")
    -- playhead_position should be 0 (default, not updated)
    assert(reloaded.playhead_position == 0 or reloaded.playhead_position == nil,
        "timeline playhead NOT persisted")

    view:destroy()
    print("  ok")
end

-- ─── Test 7: set_playhead clamping ───
print("\n--- playhead clamping ---")
do
    local view = SequenceView.new({ view_id = "test_clamp" })
    timer_callbacks = {}
    view:load_sequence(mc_id)

    view:set_playhead(-5)
    assert(view.playhead == 0, "clamped to 0")

    view:set_playhead(999)
    assert(view.playhead == 99, "clamped to total_frames-1")

    view:set_playhead(50.7)
    assert(view.playhead == 50, "floored")

    view:destroy()
    print("  ok")
end

-- ─── Test 8: Listener notification ───
print("\n--- listener notification ---")
do
    local view = SequenceView.new({ view_id = "test_listen" })
    timer_callbacks = {}
    view:load_sequence(mc_id)

    local notify_count = 0
    local listener = function() notify_count = notify_count + 1 end
    view:add_listener(listener)

    notify_count = 0
    view:set_playhead(10)
    assert(notify_count > 0, "listener notified on set_playhead")

    notify_count = 0
    view:set_playhead(10)  -- same value → no-op
    assert(notify_count == 0, "no notify on same playhead")

    -- Remove listener
    view:remove_listener(listener)
    notify_count = 0
    view:set_playhead(20)
    assert(notify_count == 0, "removed listener not notified")

    view:destroy()
    print("  ok")
end

-- ─── Test 9: Marks on masterclip ───
print("\n--- marks ---")
do
    local view = SequenceView.new({ view_id = "test_marks" })
    timer_callbacks = {}
    view:load_sequence(mc_id)

    -- Initially marks come from stream clip (source_in=0, source_out=100)
    local mi = view:get_mark_in()
    local mo = view:get_mark_out()
    assert(mi == 0, "mark_in from stream clip, got " .. tostring(mi))
    assert(mo == 100, "mark_out from stream clip, got " .. tostring(mo))

    -- Set marks
    view:set_mark_in(10)
    assert(view:get_mark_in() == 10, "mark_in updated")

    view:set_mark_out(80)
    assert(view:get_mark_out() == 80, "mark_out updated")

    -- Clear marks (resets to full duration)
    view:clear_marks()
    assert(view:get_mark_in() == 0, "mark_in cleared to 0")
    assert(view:get_mark_out() == 100, "mark_out cleared to source_out")

    view:destroy()
    print("  ok")
end

-- ─── Test 10: Marks nil for timeline ───
print("\n--- no marks for timeline ---")
do
    local view = SequenceView.new({ view_id = "test_tl_marks" })
    timer_callbacks = {}
    view:load_sequence("timeline1")

    assert(view:get_mark_in() == nil, "no mark_in for timeline")
    assert(view:get_mark_out() == nil, "no mark_out for timeline")

    expect_assert(function() view:set_mark_in(10) end,
        "set_mark_in on timeline")
    expect_assert(function() view:set_mark_out(80) end,
        "set_mark_out on timeline")
    expect_assert(function() view:clear_marks() end,
        "clear_marks on timeline")

    view:destroy()
    print("  ok")
end

-- ─── Test 11: seek_to_frame displays frame and updates playhead ───
print("\n--- seek_to_frame ---")
do
    local view = SequenceView.new({ view_id = "test_seek" })
    timer_callbacks = {}
    qt_log = {}

    view:load_sequence(mc_id)
    qt_log = {}

    view:seek_to_frame(42)
    assert(view.playhead == 42, "playhead updated after seek")

    -- Should have called SURFACE_SET_FRAME (via engine → _on_show_frame)
    local found_frame = false
    for _, entry in ipairs(qt_log) do
        if entry.type == "set_frame" and entry.frame then
            found_frame = true
            break
        end
    end
    assert(found_frame, "frame displayed via SURFACE_SET_FRAME")

    view:destroy()
    print("  ok")
end

-- ─── Test 12: on_position_changed during playback ───
print("\n--- position_changed during playback ---")
do
    local view = SequenceView.new({ view_id = "test_play" })
    timer_callbacks = {}
    view:load_sequence(mc_id)

    local notify_count = 0
    view:add_listener(function() notify_count = notify_count + 1 end)
    notify_count = 0

    -- Simulate engine calling on_position_changed (as during tick)
    view:_on_position_changed(15)
    assert(view.playhead == 15, "playhead updated from engine callback")
    assert(notify_count > 0, "listener notified on position change")

    view:destroy()
    print("  ok")
end

-- ─── Test 13: Unload clears state ───
print("\n--- unload ---")
do
    local view = SequenceView.new({ view_id = "test_unload" })
    timer_callbacks = {}
    view:load_sequence(mc_id)
    view:set_playhead(50)

    view:unload()
    assert(not view:has_clip(), "no clip after unload")
    assert(view.total_frames == 0, "total_frames reset")
    assert(view.playhead == 0, "playhead reset")
    assert(view.sequence_id == nil, "sequence_id nil")

    view:destroy()
    print("  ok")
end

-- ─── Test 14: Switching sequences saves previous playhead ───
print("\n--- switch saves playhead ---")
do
    local view = SequenceView.new({ view_id = "test_switch" })
    timer_callbacks = {}

    -- Load masterclip, set playhead
    view:load_sequence(mc_id)
    view:set_playhead(33)
    pump_timers()

    -- Switch to timeline (should save masterclip playhead first)
    view:load_sequence("timeline1")

    -- Verify masterclip playhead was saved
    local Sequence = require("models.sequence")
    local reloaded = Sequence.load(mc_id)
    assert(reloaded.playhead_position == 33,
        "previous masterclip playhead saved, got " .. tostring(reloaded.playhead_position))

    view:destroy()
    print("  ok")
end

-- ─── Test 15: Two views have independent state ───
print("\n--- independent views ---")
do
    local view1 = SequenceView.new({ view_id = "view_a" })
    local view2 = SequenceView.new({ view_id = "view_b" })
    timer_callbacks = {}

    assert(created_contexts["view_a"], "context a created")
    assert(created_contexts["view_b"], "context b created")

    view1:load_sequence(mc_id)
    view2:load_sequence("timeline1")

    assert(view1.sequence_id == mc_id, "view1 has masterclip")
    assert(view2.sequence_id == "timeline1", "view2 has timeline")
    assert(view1.total_frames == 100, "view1 frames from masterclip")
    assert(view2.total_frames == 50, "view2 frames from timeline")

    view1:set_playhead(25)
    assert(view1.playhead == 25, "view1 playhead updated")
    assert(view2.playhead == 0, "view2 playhead unaffected")

    view1:destroy()
    view2:destroy()
    print("  ok")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- NSF: Error Paths
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Test 16: load_sequence with missing ID asserts ───
print("\n--- error: load_sequence empty ---")
do
    local view = SequenceView.new({ view_id = "test_err" })
    expect_assert(function() view:load_sequence("") end,
        "load_sequence empty string")
    expect_assert(function() view:load_sequence(nil) end,
        "load_sequence nil")
    view:destroy()
    print("  ok")
end

-- ─── Test 17: seek_to_frame with no sequence is no-op ───
print("\n--- seek without sequence ---")
do
    local view = SequenceView.new({ view_id = "test_no_seq" })
    -- Should not error, just return
    view:seek_to_frame(10)
    assert(view.playhead == 0, "playhead unchanged without sequence")
    view:destroy()
    print("  ok")
end

-- ─── Test 18: set_playhead nil asserts ───
print("\n--- error: set_playhead nil ---")
do
    local view = SequenceView.new({ view_id = "test_nil_ph" })
    expect_assert(function() view:set_playhead(nil) end,
        "set_playhead nil")
    view:destroy()
    print("  ok")
end

-- ─── Test 19: set_mark_in without masterclip asserts ───
print("\n--- error: marks without masterclip ---")
do
    local view = SequenceView.new({ view_id = "test_mark_err" })
    -- No sequence loaded
    expect_assert(function() view:set_mark_in(10) end,
        "set_mark_in without masterclip")
    expect_assert(function() view:set_mark_out(10) end,
        "set_mark_out without masterclip")
    view:destroy()
    print("  ok")
end

print("\n✅ test_sequence_view.lua passed")
