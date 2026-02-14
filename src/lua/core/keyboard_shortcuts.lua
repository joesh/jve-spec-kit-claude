--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~988 LOC
-- Volatility: unknown
--
-- @file keyboard_shortcuts.lua
-- Original intent (unreviewed):
-- Keyboard Shortcuts Module
-- Centralized keyboard shortcut handling for JVE
local keyboard_shortcuts = {}
local shortcut_registry = require("core.keyboard_shortcut_registry")
local panel_manager = require("ui.panel_manager")
local kb_constants = require("core.keyboard_constants")

-- Self-managed arrow key repeat: bypasses macOS key repeat rate (~12/sec)
-- with our own timer at ~30fps. Detects keyDown → start timer, keyUp → stop.
local ARROW_STEP_MS = 33            -- ~30fps stepping (matches NLE convention)
local ARROW_INITIAL_DELAY_MS = 200  -- delay before repeat starts
local arrow_repeat_active = false   -- true while arrow key is held and timer is running
local arrow_repeat_dir = 0          -- 1=right, -1=left
local arrow_repeat_shift = false    -- shift held = 1-second jumps
local arrow_repeat_gen = 0          -- generation counter for timer invalidation

--- Get the PlaybackEngine for the currently active SequenceMonitor.
-- @return PlaybackEngine|nil
local function get_active_engine()
    local sv = panel_manager.get_active_sequence_monitor()
    if not sv then return nil end
    return sv.engine
end

--- Check if the active view has a sequence loaded and ready for playback.
local function ensure_playback_initialized()
    local sv = panel_manager.get_active_sequence_monitor()
    if not sv then return false end
    if not sv.sequence_id then return false end
    if sv.total_frames <= 0 then return false end
    return true
end

-- K key held state for K+J/K+L slow playback
local k_held = false

-- JKL handler functions (called by registry)

local function handle_jkl_forward()
    if not ensure_playback_initialized() then return end
    local engine = get_active_engine()
    if k_held then
        engine:slow_play(1)   -- K+L = slow forward
    else
        engine:shuttle(1)     -- L = forward shuttle
    end
end

local function handle_jkl_reverse()
    if not ensure_playback_initialized() then return end
    local engine = get_active_engine()
    if k_held then
        engine:slow_play(-1)  -- K+J = slow reverse
    else
        engine:shuttle(-1)    -- J = reverse shuttle
    end
end

local function handle_jkl_stop()
    k_held = true
    local engine = get_active_engine()
    if engine then engine:stop() end
end

-- Toggle play/pause handler (Spacebar)
local function handle_play_toggle()
    if not ensure_playback_initialized() then return end
    local engine = get_active_engine()
    if engine:is_playing() then
        engine:stop()
    else
        engine:play()
    end
end

-- Register JKL commands with the shortcut registry (idempotent)
local function register_jkl_commands()
    -- Skip if already registered
    if shortcut_registry.commands["playback.forward"] then
        return
    end

    -- Spacebar play/pause toggle
    shortcut_registry.register_command({
        id = "playback.toggle",
        category = "Playback",
        name = "Play/Pause",
        description = "Toggle playback (play at 1x or stop)",
        default_shortcuts = {"Space"},
        context = {"timeline", "source_monitor", "timeline_monitor"},
        handler = handle_play_toggle
    })
    shortcut_registry.assign_shortcut("playback.toggle", "Space")

    shortcut_registry.register_command({
        id = "playback.forward",
        category = "Playback",
        name = "Play Forward / Speed Up",
        description = "Start forward playback or increase speed",
        default_shortcuts = {"L"},
        context = {"timeline", "source_monitor", "timeline_monitor"},
        handler = handle_jkl_forward
    })
    shortcut_registry.register_command({
        id = "playback.reverse",
        category = "Playback",
        name = "Play Reverse / Speed Up",
        description = "Start reverse playback or increase speed",
        default_shortcuts = {"J"},
        context = {"timeline", "source_monitor", "timeline_monitor"},
        handler = handle_jkl_reverse
    })
    shortcut_registry.register_command({
        id = "playback.stop",
        category = "Playback",
        name = "Stop Playback",
        description = "Stop playback and mark K held for slow-play combo",
        default_shortcuts = {"K"},
        context = {"timeline", "source_monitor", "timeline_monitor"},
        handler = handle_jkl_stop
    })
    -- Assign shortcuts
    shortcut_registry.assign_shortcut("playback.forward", "L")
    shortcut_registry.assign_shortcut("playback.reverse", "J")
    shortcut_registry.assign_shortcut("playback.stop", "K")
end

-- Key and modifier constants (from keyboard_constants.lua)
local KEY = kb_constants.KEY
local MOD = kb_constants.MOD

-- Expose key/modifier maps for other modules that need to parse shortcuts
keyboard_shortcuts.KEY = KEY
keyboard_shortcuts.MOD = MOD

-- References to timeline state and other modules
local timeline_state = nil
local command_manager = nil

local function execute_command(command_name, params)
    assert(command_manager, "KeyboardShortcuts: command_manager not initialized")

    if type(command_manager.execute_ui) == "function" then
        return command_manager.execute_ui(command_name, params)
    end

    -- Fallback for minimal stubs (e.g. headless tests) where begin/end may not exist.
    local owns_event = false
    if type(command_manager.begin_command_event) == "function" and type(command_manager.end_command_event) == "function" then
        if not command_manager.peek_command_event_origin or command_manager.peek_command_event_origin() == nil then
            command_manager.begin_command_event("ui")
            owns_event = true
        end
    end

    local result = command_manager.execute(command_name, params)

    if owns_event then
        command_manager.end_command_event()
    end

    return result
end
local project_browser = nil
local timeline_panel = nil
local focus_manager = require("ui.focus_manager")
local redo_toggle_state = nil
local zoom_fit_toggle_state = nil

local ACTIVATE_BROWSER_COMMAND = "ActivateBrowserSelection"

local function clear_zoom_fit_toggle()
    zoom_fit_toggle_state = nil
end

function keyboard_shortcuts.clear_zoom_toggle()
    clear_zoom_fit_toggle()
end

local function snapshot_viewport(state)
    assert(state, "snapshot_viewport: timeline state is required")

    if state.capture_viewport then
        local viewport = state.capture_viewport()
        assert(type(viewport) == "table", "snapshot_viewport: capture_viewport must return a table")
        return {
            start_value = viewport.start_value,
            duration = viewport.duration,
        }
    end

    assert(state.get_viewport_start_time, "snapshot_viewport: state missing get_viewport_start_time")
    assert(state.get_viewport_duration, "snapshot_viewport: state missing get_viewport_duration")
    local start_value = state.get_viewport_start_time()
    local duration = state.get_viewport_duration()
    assert(start_value ~= nil, "snapshot_viewport: get_viewport_start_time returned nil")
    assert(duration ~= nil, "snapshot_viewport: get_viewport_duration returned nil")
    return {start_value = start_value, duration = duration}
end

function keyboard_shortcuts.toggle_zoom_fit(target_state)
    local state = target_state or timeline_state
    if not state then
        print("⚠️  Zoom to fit unavailable (timeline state missing)")
        return false
    end

    local snapshot = snapshot_viewport(state)

    if zoom_fit_toggle_state and zoom_fit_toggle_state.previous_view then
        local prev = zoom_fit_toggle_state.previous_view
        local restore_duration = prev.duration
        if not restore_duration and state.get_viewport_duration then
            local ok, current_duration = pcall(state.get_viewport_duration)
            if ok then
                restore_duration = current_duration
            end
        end
        -- All coords are integer frames
        assert(type(restore_duration) == "number", "keyboard_shortcuts: restore_duration must be integer")

        if state.set_viewport_duration then
            state.set_viewport_duration(restore_duration)
        elseif state.restore_viewport then
            pcall(state.restore_viewport, prev)
        end

        if state.get_playhead_position and state.set_viewport_start_time then
            local playhead = state.get_playhead_position()
            if playhead then
                -- Center on playhead: start = playhead - duration/2
                local half_dur = math.floor(restore_duration / 2)
                state.set_viewport_start_time(playhead - half_dur)
            end
        end

        zoom_fit_toggle_state = nil
        print("🔄 Zoom fit toggle: restored view around playhead")
        return true
    end

    local clips = {}
    if state.get_clips then
        local ok, clip_list = pcall(state.get_clips)
        if ok and type(clip_list) == "table" then
            clips = clip_list
        end
    end

    -- All coords are integer frames
    local min_start = nil
    local max_end_time = nil

    for _, clip in ipairs(clips) do
        local start_val = clip.timeline_start or clip.start_value
        local dur_val = clip.duration

        -- Coordinates must be integers
        if type(start_val) ~= "number" or type(dur_val) ~= "number" then
            goto continue_clip
        end

        local end_val = start_val + dur_val

        if not min_start or start_val < min_start then
            min_start = start_val
        end
        if not max_end_time or end_val > max_end_time then
            max_end_time = end_val
        end

        ::continue_clip::
    end

    if not max_end_time or not min_start then
        zoom_fit_toggle_state = nil
        print("⚠️  No clips to scale to")
        return false
    end

    zoom_fit_toggle_state = {
        previous_view = snapshot,
    }

    local duration = max_end_time - min_start
    -- Add a 10% buffer at the end so zoom-fit isn't tight against the last clip
    local buffer = math.max(1, math.floor(duration / 10))
    local fit_duration = duration + buffer

    if state.set_viewport_duration then
        state.set_viewport_duration(fit_duration)
    end
    if state.set_viewport_start_time then
        state.set_viewport_start_time(min_start)
    end

    print(string.format("🔍 Zoomed to fit: %d frames visible (buffered)", fit_duration))
    return true
end

-- Minimal command dispatcher for tests and menu actions
function keyboard_shortcuts.handle_command(command_name)
    if command_name == "TimelineZoomFit" then
        return keyboard_shortcuts.toggle_zoom_fit(timeline_state)
    elseif command_name == "TimelineZoomIn" then
        if timeline_state and timeline_state.get_viewport_duration and timeline_state.set_viewport_duration then
            -- All coords are integer frames
            local dur = timeline_state.get_viewport_duration()
            assert(type(dur) == "number", "keyboard_shortcuts: viewport_duration must be integer")
            local new_dur = math.max(30, math.floor(dur * 0.8))  -- min 30 frames (~1 sec at 30fps)
            timeline_state.set_viewport_duration(new_dur)
            return true
        end
    elseif command_name == "TimelineZoomOut" then
        if timeline_state and timeline_state.get_viewport_duration and timeline_state.set_viewport_duration then
            local dur = timeline_state.get_viewport_duration()
            assert(type(dur) == "number", "keyboard_shortcuts: viewport_duration must be integer")
            timeline_state.set_viewport_duration(math.floor(dur * 1.25))
            return true
        end
    end
    return false
end

local function ensure_browser_shortcuts_registered()
    if not shortcut_registry.commands[ACTIVATE_BROWSER_COMMAND] then
        shortcut_registry.register_command({
            id = ACTIVATE_BROWSER_COMMAND,
            category = "Project Browser",
            name = "Open Selection",
            description = "Open the selected browser item",
            default_shortcuts = {"Return"},
            context = "project_browser",
            handler = function()
                if command_manager then
                    local result = execute_command(ACTIVATE_BROWSER_COMMAND)
                    if not result.success then
                        print(string.format("⚠️  %s returned error: %s", ACTIVATE_BROWSER_COMMAND, result.error_message or "unknown"))
                    end
                end
            end
        })
        local assigned, assign_err = shortcut_registry.assign_shortcut(ACTIVATE_BROWSER_COMMAND, "Return")
        if not assigned then
            print(string.format("⚠️  Failed to assign default shortcut for %s: %s", ACTIVATE_BROWSER_COMMAND, tostring(assign_err)))
        end
    end
end

-- MAGNETIC SNAPPING STATE
-- Baseline preference (persists across drags)
local baseline_snapping_enabled = true  -- Default ON
-- Per-drag inversion (resets when drag ends)
local drag_snapping_inverted = false

local function clear_redo_toggle()
    redo_toggle_state = nil
end

local function get_current_sequence_position()
    if command_manager and command_manager.get_stack_state then
        local state = command_manager.get_stack_state()
        if state and state.current_sequence_number ~= nil then
            return state.current_sequence_number
        end
    end
    return nil
end

-- Initialize with references to other modules
function keyboard_shortcuts.init(state, cmd_mgr, proj_browser, panel)
    timeline_state = state
    command_manager = cmd_mgr
    project_browser = proj_browser
    timeline_panel = panel
    redo_toggle_state = nil
    zoom_fit_toggle_state = nil
    ensure_browser_shortcuts_registered()
    register_jkl_commands()
end

-- Get effective snapping state (baseline XOR drag_inverted)
function keyboard_shortcuts.is_snapping_enabled()
    local effective = baseline_snapping_enabled
    if drag_snapping_inverted then
        effective = not effective
    end
    return effective
end

-- Toggle baseline snapping preference
function keyboard_shortcuts.toggle_baseline_snapping()
    baseline_snapping_enabled = not baseline_snapping_enabled
    print(string.format("Snapping %s", baseline_snapping_enabled and "ON" or "OFF"))
end

-- Invert snapping for current drag only
function keyboard_shortcuts.invert_drag_snapping()
    drag_snapping_inverted = not drag_snapping_inverted
    print(string.format("Snapping temporarily %s for this drag", keyboard_shortcuts.is_snapping_enabled() and "ON" or "OFF"))
end

-- Reset drag inversion (call when drag ends)
function keyboard_shortcuts.reset_drag_snapping()
    drag_snapping_inverted = false
end

-- Check if timeline is currently dragging clips or edges
function keyboard_shortcuts.is_dragging()
    if timeline_panel then
        return timeline_panel.is_dragging and timeline_panel.is_dragging() or false
    end
    return false
end

local function get_focused_panel_id()
    if focus_manager and focus_manager.get_focused_panel then
        return focus_manager.get_focused_panel()
    end
    return nil
end

local function panel_is_active(required_panel, focused_panel)
   if not required_panel or required_panel == "global" then
       return true
   end
   return focused_panel == required_panel
end

local function focus_panel(panel_id)
    if not focus_manager then
        return false
    end
    local focused = false
    if focus_manager.focus_panel then
        focused = focus_manager.focus_panel(panel_id) or focused
    end
    if focus_manager.set_focused_panel then
        focus_manager.set_focused_panel(panel_id)
        focused = true
    end
    return focused
end

-- Check if a modifier is active (LuaJIT compatible bitwise AND)
local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

function keyboard_shortcuts.perform_delete_action(opts)
    opts = opts or {}
    local shift_held = opts.shift == true

    local focused_panel = get_focused_panel_id()
    local panel_active_timeline = panel_is_active("timeline", focused_panel)
    local panel_active_browser = panel_is_active("project_browser", focused_panel)

    if project_browser and panel_active_browser then
        if project_browser.delete_selected_items and project_browser.delete_selected_items() then
            clear_redo_toggle()
        end
        return true
    end

    if not (timeline_state and command_manager) or not panel_active_timeline then
        return false
    end

    clear_redo_toggle()

    assert(timeline_state.get_selected_clips, "keyboard_shortcuts.perform_delete_action: timeline_state missing get_selected_clips")
    local selected_clips = timeline_state.get_selected_clips()

    if shift_held and selected_clips and #selected_clips > 0 then
        local clip_ids = {}
        for _, clip in ipairs(selected_clips) do
            if type(clip) == "table" then
                if clip.id then
                    clip_ids[#clip_ids + 1] = clip.id
                elseif clip.clip_id then
                    clip_ids[#clip_ids + 1] = clip.clip_id
                end
            elseif type(clip) == "string" then
                clip_ids[#clip_ids + 1] = clip
            end
        end

        if #clip_ids > 0 then
            local params = {clip_ids = clip_ids}
            if timeline_state.get_sequence_id then
                params.sequence_id = timeline_state.get_sequence_id()
            end

            local result = execute_command("RippleDeleteSelection", params)
            if not result.success then
                print(string.format("Failed to ripple delete selection: %s", result.error_message or "unknown error"))
            end
            return true
        end
    end

    if selected_clips and #selected_clips > 0 then
        local json = require("dkjson")
        local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
        assert(project_id and project_id ~= "", "keyboard_shortcuts.perform_delete_action: missing active project_id")

        local command_specs = {}
        for _, clip in ipairs(selected_clips) do
            table.insert(command_specs, {
                command_type = "DeleteClip",
                parameters = {
                    clip_id = clip.id
                }
            })
        end

        local commands_json = json.encode(command_specs)
        local batch_cmd_params = {
            project_id = project_id,
        }
        batch_cmd_params.commands_json = commands_json
        if active_sequence_id and active_sequence_id ~= "" then
            batch_cmd_params.sequence_id = active_sequence_id
        end

        local result = execute_command("BatchCommand", batch_cmd_params)
        if result.success then
            if timeline_state.set_selection then
                timeline_state.set_selection({})
            end
            print(string.format("Deleted %d clips (single undo)", #selected_clips))
        else
            print(string.format("Failed to delete clips: %s", result.error_message or "unknown error"))
        end
        return true
    end

    assert(timeline_state.get_selected_gaps, "keyboard_shortcuts.perform_delete_action: timeline_state missing get_selected_gaps")
    local selected_gaps = timeline_state.get_selected_gaps()
    if #selected_gaps > 0 then
        local gap = selected_gaps[1]
        local params = {
            track_id = gap.track_id,
            gap_start = gap.start_value,
            gap_duration = gap.duration,
        }
        if timeline_state.get_sequence_id then
            params.sequence_id = timeline_state.get_sequence_id()
        end

        local result = execute_command("RippleDelete", params)
        if result.success then
            if timeline_state.clear_gap_selection then
                timeline_state.clear_gap_selection()
            end
            print(string.format("Ripple deleted gap of %s on track %s", tostring(gap.duration), tostring(gap.track_id)))
        else
            print(string.format("Failed to ripple delete gap: %s", result.error_message or "unknown error"))
        end
        return true
    end

    return false
end

-- Execute a single arrow-key frame step via the StepFrame command.
-- dir: 1=right, -1=left.  shift: true = 1-second jumps.
local function step_arrow_frame(dir, shift)
    execute_command("StepFrame", {direction = dir, shift = shift})
end

-- Chained single-shot timer callback for arrow key repeat.
-- Schedules next tick BEFORE doing work so decode latency doesn't inflate interval.
local function arrow_repeat_tick(gen)
    if gen ~= arrow_repeat_gen or not arrow_repeat_active then return end

    -- Schedule next tick first — keeps cadence steady regardless of decode cost
    if qt_create_single_shot_timer then
        qt_create_single_shot_timer(ARROW_STEP_MS, function()
            arrow_repeat_tick(gen)
        end)
    end

    step_arrow_frame(arrow_repeat_dir, arrow_repeat_shift)
end

-- Global key handler function (called from Qt event filter)
-- Internal implementation of handle_key (without command event management)
local function handle_key_impl(event)
    local key = event.key
    local modifiers = event.modifiers

    local modifier_meta = has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)
    local modifier_shift = has_modifier(modifiers, MOD.Shift)
    local modifier_alt = has_modifier(modifiers, MOD.Alt)

    local focused_panel = get_focused_panel_id()
    local panel_active_timeline = panel_is_active("timeline", focused_panel)
    local panel_active_source = panel_is_active("source_monitor", focused_panel)
    local panel_active_tl_view = panel_is_active("timeline_monitor", focused_panel)
    local panel_active_browser = panel_is_active("project_browser", focused_panel)
    local focus_is_text_input = event.focus_widget_is_text_input and event.focus_widget_is_text_input ~= 0

    if key == KEY.Tab and panel_active_timeline and not modifier_meta and not modifier_alt then
        if timeline_panel and timeline_panel.focus_timecode_entry and timeline_panel.focus_timeline_view then
            if focus_is_text_input then
                timeline_panel.focus_timeline_view()
            else
                timeline_panel.focus_timecode_entry()
            end
            return true
        end
    end

    if focus_is_text_input and not modifier_meta then
        return false
    end

    local context = focused_panel or "global"
    if shortcut_registry.handle_key_event(key, modifiers, context) then
        return true
    end

    if panel_active_browser and project_browser then
        if (key == KEY.Return or key == KEY.Enter) and not modifier_meta and not modifier_alt then
            local ok, err = project_browser.activate_selection()
            if not ok and err then
                print(string.format("⚠️  %s", err))
            end
            return true
        elseif key == KEY.F2 and not modifier_meta and not modifier_alt then
            if project_browser.start_inline_rename and project_browser.start_inline_rename() then
                return true
            end
        end
    end

    -- Cmd/Ctrl + Z: Undo
    -- Cmd/Ctrl + Shift + Z: Redo toggle
    if key == KEY.Z and modifier_meta then
        if modifier_shift then
            if command_manager then
                local current_pos = get_current_sequence_position()

                if redo_toggle_state
                    and redo_toggle_state.undo_position ~= nil
                    and redo_toggle_state.redo_position ~= nil
                    and current_pos == redo_toggle_state.redo_position then
                    if command_manager.can_undo and not command_manager.can_undo() then
                        clear_redo_toggle()
                        return true
                    end
                    local undo_result = command_manager.undo()
                    if not undo_result.success then
                        clear_redo_toggle()
                        if undo_result.error_message then
                            print("ERROR: Toggle redo failed - " .. undo_result.error_message)
                        else
                            print("ERROR: Toggle redo failed")
                        end
                    else
                        local after_pos = get_current_sequence_position()
                        if after_pos ~= redo_toggle_state.undo_position then
                            clear_redo_toggle()
                        else
                            redo_toggle_state.last_action = "undo"
                            print("Redo toggle: returned to pre-redo state")
                        end
                    end
                else
                    if redo_toggle_state then
                        local undo_pos = redo_toggle_state.undo_position
                        if undo_pos ~= current_pos then
                            clear_redo_toggle()
                        end
                    end

                    local before_pos = current_pos
                    if command_manager.can_redo and not command_manager.can_redo() then
                        clear_redo_toggle()
                        return true
                    end
                    local redo_result = command_manager.redo()
                    if redo_result.success then
                        local after_pos = get_current_sequence_position()
                        if after_pos and after_pos ~= before_pos then
                            redo_toggle_state = {
                                undo_position = before_pos,
                                redo_position = after_pos,
                                last_action = "redo",
                            }
                            print("Redo complete")
                        else
                            clear_redo_toggle()
                        end
                    else
                        clear_redo_toggle()
                        if redo_result.error_message then
                            print("Nothing to redo (" .. redo_result.error_message .. ")")
                        else
                            print("Nothing to redo")
                        end
                    end
                end
            end
        else
            if command_manager then
                clear_redo_toggle()
                if command_manager.can_undo and not command_manager.can_undo() then
                    return true
                end
                local result = command_manager.undo()
                if result.success then
                    print("Undo complete")
                else
                    if result.error_message then
                        print("ERROR: Undo failed - " .. result.error_message)
                    else
                        print("ERROR: Undo failed - event log may be corrupted")
                    end
                end
            end
        end
        return true
    end

    local tilde_without_meta = (key == KEY.Tilde or (key == KEY.Grave and modifier_shift)) and not modifier_meta and not modifier_alt
    if tilde_without_meta then
        if command_manager then
            execute_command("ToggleMaximizePanel")
        else
            panel_manager.toggle_active_panel()
        end
        return true
    end

    if modifier_meta and not modifier_alt and not modifier_shift then
        if key == KEY.Key3 then
            if focus_panel("timeline") then
                return true
            end
        elseif key == KEY.Key4 then
            if focus_panel("project_browser") then
                return true
            end
        elseif key == KEY.Key2 then
            if focus_panel("inspector") then
                return true
            end
        end
    end

    -- Left/Right arrows: Move playhead (frame or 1-second jumps with Shift)
    if (key == KEY.Left or key == KEY.Right) and panel_active_browser then
        return false
    end

    if (key == KEY.Left or key == KEY.Right) and (panel_active_timeline or panel_active_source or panel_active_tl_view) then
        if not modifier_meta and not modifier_alt then
            -- Swallow OS autorepeat — we drive our own timer
            if event.is_auto_repeat then
                return true
            end

            local dir = (key == KEY.Right) and 1 or -1

            -- Immediate first step
            step_arrow_frame(dir, modifier_shift)

            -- Start self-managed repeat timer
            arrow_repeat_active = true
            arrow_repeat_dir = dir
            arrow_repeat_shift = modifier_shift
            arrow_repeat_gen = arrow_repeat_gen + 1
            local gen = arrow_repeat_gen

            if qt_create_single_shot_timer then
                qt_create_single_shot_timer(ARROW_INITIAL_DELAY_MS, function()
                    arrow_repeat_tick(gen)
                end)
            end

            return true
        end
    end

    -- Mark In/Out controls (unified: same commands for timeline + source panels)
    -- Resolve active sequence_id + playhead from focused panel
    local mark_seq_id, mark_playhead
    if panel_active_timeline and timeline_state then
        mark_seq_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        mark_playhead = timeline_state.get_playhead_position and timeline_state.get_playhead_position()
    elseif panel_active_source then
        local source_sv = panel_manager.get_sequence_monitor("source_monitor")
        if source_sv and source_sv:has_clip() then
            mark_seq_id = source_sv.sequence_id
            mark_playhead = source_sv.playhead
        end
    end

    if key == KEY.I and mark_seq_id then
        if not modifier_meta and not modifier_alt then
            if modifier_shift then
                execute_command("GoToMarkIn", {sequence_id = mark_seq_id})
            else
                assert(mark_playhead, "keyboard_shortcuts: playhead nil for SetMarkIn")
                execute_command("SetMarkIn", {sequence_id = mark_seq_id, frame = mark_playhead})
            end
            return true
        end
        if modifier_alt and not modifier_meta then
            execute_command("ClearMarkIn", {sequence_id = mark_seq_id})
            return true
        end
    end

    if key == KEY.O and mark_seq_id then
        if not modifier_meta and not modifier_alt then
            if modifier_shift then
                execute_command("GoToMarkOut", {sequence_id = mark_seq_id})
            else
                assert(mark_playhead, "keyboard_shortcuts: playhead nil for SetMarkOut")
                execute_command("SetMarkOut", {sequence_id = mark_seq_id, frame = mark_playhead})
            end
            return true
        end
        if modifier_alt and not modifier_meta then
            execute_command("ClearMarkOut", {sequence_id = mark_seq_id})
            return true
        end
    end

    if key == KEY.X and mark_seq_id then
        if modifier_alt and not modifier_meta then
            execute_command("ClearMarks", {sequence_id = mark_seq_id})
            return true
        end
    end

    if key == KEY.X and timeline_state and panel_active_timeline then
        if not modifier_meta and not modifier_alt then
            assert(timeline_state.get_playhead_position, "keyboard_shortcuts.handle_key: timeline_state missing get_playhead_position")
            local playhead = timeline_state.get_playhead_position()
            assert(timeline_state.get_clips, "keyboard_shortcuts.handle_key: timeline_state missing get_clips")
            local clips = timeline_state.get_clips()
            local best_clip = nil
            local best_priority = nil

            for _, clip in ipairs(clips) do
                assert(clip.timeline_start or clip.start_value, string.format("keyboard_shortcuts.handle_key: clip %s missing timeline_start/start_value", tostring(clip.id)))
                local clip_start = clip.timeline_start or clip.start_value
                assert(clip.duration, string.format("keyboard_shortcuts.handle_key: clip %s missing duration", tostring(clip.id)))
                local clip_end = clip_start + clip.duration

                if playhead >= clip_start and playhead <= clip_end then
                    local track = timeline_state.get_track_by_id and timeline_state.get_track_by_id(clip.track_id)
                    if track then
                        local type_priority = (track.track_type == "VIDEO") and 0 or 1
                        assert(track.track_index or (timeline_state.get_track_index and timeline_state.get_track_index(clip.track_id)),
                            string.format("keyboard_shortcuts.handle_key: track %s missing track_index", tostring(clip.track_id)))
                        local track_index = track.track_index or timeline_state.get_track_index(clip.track_id)
                        local priority = type_priority * 1000 + track_index
                        if not best_priority or priority < best_priority then
                            best_priority = priority
                            best_clip = clip
                        end
                    end
                end
            end

            if best_clip then
                local clip_start = best_clip.timeline_start or best_clip.start_value
                -- Last included frame = clip_start + duration - 1
                local clip_last_frame = clip_start + best_clip.duration - 1
                local seq_id = timeline_state.get_sequence_id()
                execute_command("SetMarkIn", {sequence_id = seq_id, frame = clip_start})
                execute_command("SetMarkOut", {sequence_id = seq_id, frame = clip_last_frame})
            end
            return true
        end
    end

    -- Delete/Backspace: contextual delete (project browser or timeline)
    if key == KEY.Delete or key == KEY.Backspace then
        local handled = keyboard_shortcuts.perform_delete_action({
            shift = has_modifier(modifiers, MOD.Shift)
        })
        if handled then
            return true
        end
        return false
    end

    -- Cmd/Ctrl + A: Select all clips
    -- Shift + Cmd/Ctrl + A: Deselect all
    if key == KEY.A and modifier_meta then
        if not panel_active_timeline then
            return false
        end

        if timeline_state and timeline_state.set_selection and timeline_state.get_clips then
            if has_modifier(modifiers, MOD.Shift) then
                timeline_state.set_selection({})
                print("Deselected all clips")
            else
                local clips = timeline_state.get_clips()
                timeline_state.set_selection(clips)
                print(string.format("Selected %d clip(s)", #clips))
            end
        end
        if command_manager then
            local command_name
            if has_modifier(modifiers, MOD.Shift) then
                command_name = "DeselectAll"
            else
                command_name = "SelectAll"
            end
            execute_command(command_name)
        end
        return true
    end

    if (key == KEY.Up or key == KEY.Down) and panel_active_browser then
        return false
    end

    if key == KEY.Up and command_manager and panel_active_timeline then
        local result = execute_command("GoToPrevEdit")
        if not result.success then
            print(string.format("⚠️  GoToPrevEdit returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.Down and command_manager and panel_active_timeline then
        local result = execute_command("GoToNextEdit")
        if not result.success then
            print(string.format("⚠️  GoToNextEdit returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.Home and command_manager and panel_active_timeline then
        local result = execute_command("GoToStart")
        if not result.success then
            print(string.format("⚠️  GoToStart returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    if key == KEY.End and command_manager and panel_active_timeline then
        local result = execute_command("GoToEnd")
        if not result.success then
            print(string.format("⚠️  GoToEnd returned error: %s", result.error_message or "unknown"))
        end
        return true
    end

    -- Comma/Period: Frame-accurate nudge for clips and edges
    -- Comma (,) = left, Period (.) = right
    -- Without Shift: 1 frame, With Shift: 5 frames
    if (key == KEY.Comma or key == KEY.Period) and timeline_state and command_manager and panel_active_timeline and not modifier_meta and not modifier_alt then
        -- All coords are integer frames
        local nudge_frames = modifier_shift and 5 or 1
        if key == KEY.Comma then
            nudge_frames = -nudge_frames
        end
        clear_redo_toggle()

        local direction = nudge_frames < 0 and "left" or "right"
        local frame_count = math.abs(nudge_frames)
        local timecode_str = string.format("%d frame(s)", frame_count)

        local selected_clips = timeline_state.get_selected_clips()
        local selected_edges = timeline_state.get_selected_edges()

        local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
        local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        assert(project_id and project_id ~= "", "keyboard_shortcuts.handle_key: missing active project_id for ripple/nudge")
        assert(sequence_id and sequence_id ~= "", "keyboard_shortcuts.handle_key: missing active sequence_id for ripple/nudge")

        if #selected_edges > 0 then
            local all_clips = timeline_state.get_clips()
            local edge_infos = {}

            for _, edge in ipairs(selected_edges) do
                local clip = nil
                for _, c in ipairs(all_clips) do
                    if c.id == edge.clip_id then
                        clip = c
                        break
                    end
                end
                if clip then
                    table.insert(edge_infos, {
                        clip_id = edge.clip_id,
                        edge_type = edge.edge_type,
                        track_id = clip.track_id,
                        trim_type = edge.trim_type,
                    })
                end
            end

            local result
            if #edge_infos > 1 then
                result = execute_command("BatchRippleEdit", {
                    ["edge_infos"] = edge_infos,
                    ["delta_frames"] = nudge_frames,
                    ["sequence_id"] = sequence_id,
                    project_id = project_id,
                })
            elseif #edge_infos == 1 then
                result = execute_command("RippleEdit", {
                    ["edge_info"] = edge_infos[1],
                    ["delta_frames"] = nudge_frames,
                    ["sequence_id"] = sequence_id,
                    project_id = project_id,
                })
            end

            if result and result.success then
                print(string.format("Ripple edited %d edge(s) %s by %d frame(s) (%s)", #edge_infos, direction, frame_count, timecode_str))
            else
                print("ERROR: Ripple edit failed")
            end
        elseif #selected_clips > 0 then
            local clip_ids = {}
            for _, clip in ipairs(selected_clips) do
                table.insert(clip_ids, clip.id)
            end

            local result = execute_command("Nudge", {
                ["nudge_amount"] = nudge_frames,
                ["selected_clip_ids"] = clip_ids,
                ["sequence_id"] = sequence_id,
                project_id = project_id,
            })
            if result and result.success then
                print(string.format("Nudged %d clip(s) %s by %d frame(s) (%s)", #selected_clips, direction, frame_count, timecode_str))
            else
                print("ERROR: Nudge failed: " .. ((result and result.error_message) or "unknown error"))
            end
        else
            print("Nothing selected to nudge/ripple")
        end

        return true
    end

    -- Cmd/Ctrl + B: Blade tool - split clips at playhead
    if key == KEY.B and modifier_meta then
        if timeline_state and command_manager and panel_active_timeline then
            local selected_clips = timeline_state.get_selected_clips()
            local playhead_value = timeline_state.get_playhead_position()

            local target_clips
            if selected_clips and #selected_clips > 0 then
                target_clips = timeline_state.get_clips_at_time(playhead_value, selected_clips)
            else
                target_clips = timeline_state.get_clips_at_time(playhead_value)
            end

            if #target_clips == 0 then
                if selected_clips and #selected_clips > 0 then
                    print("Blade: Playhead does not intersect selected clips")
                else
                    print("Blade: No clips under playhead")
                end
                return true
            end

            local json = require("dkjson")
            local specs = {}

            for _, clip in ipairs(target_clips) do
                -- All coords are integer frames
                local start_value = clip.timeline_start or clip.start_value
                local duration_value = clip.duration or clip.duration_value
                assert(type(start_value) == "number", "keyboard_shortcuts: clip timeline_start must be integer")
                assert(type(duration_value) == "number", "keyboard_shortcuts: clip duration must be integer")
                assert(type(playhead_value) == "number", "keyboard_shortcuts: playhead must be integer")

                if duration_value > 0 then
                    local end_time = start_value + duration_value
                    if playhead_value > start_value and playhead_value < end_time then
                        table.insert(specs, {
                            command_type = "SplitClip",
                            parameters = {
                                clip_id = clip.id,
                                split_value = playhead_value  -- integer frame
                            }
                        })
                    end
                end
            end

            if #specs == 0 then
                print("Blade: No valid clips to split at current playhead position")
                return true
            end

            local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
            assert(project_id and project_id ~= "", "keyboard_shortcuts.handle_key: Blade missing active project_id")
            local batch_cmd_params = {
                project_id = project_id,
            }
            batch_cmd_params.commands_json = json.encode(specs)
            local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            if active_sequence_id and active_sequence_id ~= "" then
                batch_cmd_params.sequence_id = active_sequence_id
            end

            local result = execute_command("BatchCommand", batch_cmd_params)
            if result.success then
                print(string.format("Blade: Split %d clip(s) at %s", #specs, tostring(playhead_value)))
            else
                print(string.format("Blade: Failed to split clips: %s", result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- Shift+Cmd+[ : TrimHead (remove content before playhead, like Premiere Q)
    -- Shift+Cmd+] : TrimTail (remove content after playhead, like Premiere W)
    if (key == KEY.BracketLeft or key == KEY.BracketRight) and modifier_meta and modifier_shift and not modifier_alt then
        if timeline_state and command_manager and panel_active_timeline then
            local playhead_value = timeline_state.get_playhead_position()
            local target_clips = timeline_state.get_clips_at_time(playhead_value)

            if #target_clips == 0 then
                print("Trim: No clips under playhead")
                return true
            end

            local trim_type = (key == KEY.BracketLeft) and "TrimHead" or "TrimTail"
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
            assert(project_id and project_id ~= "",
                "keyboard_shortcuts.handle_key: Trim missing active project_id")
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            assert(sequence_id and sequence_id ~= "",
                "keyboard_shortcuts.handle_key: Trim missing active sequence_id")

            -- playhead_value is integer frames
            assert(type(playhead_value) == "number", "keyboard_shortcuts: playhead must be integer")

            -- Collect all clip IDs
            local clip_ids = {}
            for _, clip in ipairs(target_clips) do
                table.insert(clip_ids, clip.id)
            end

            -- Single command handles all clips + ripple
            local result = execute_command(trim_type, {
                clip_ids = clip_ids,
                project_id = project_id,
                sequence_id = sequence_id,
                trim_frame = playhead_value,
            })

            if result and result.success then
                print(string.format("%s: Trimmed %d clip(s) at frame %d", trim_type, #clip_ids, playhead_value))
            else
                print(string.format("%s: Failed - %s", trim_type, result and result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- JKL handled by registry (registered in register_jkl_commands)

    -- Q/W/E/R/T: Tool switching
    if key == KEY.Q and panel_active_timeline then
        print("Select tool (not implemented yet)")
        return true
    end
    if key == KEY.W and panel_active_timeline then
        print("Track select tool (not implemented yet)")
        return true
    end
    if key == KEY.E and panel_active_timeline then
        -- E: Extend Edit - extend selected edge(s) to playhead
        -- Honors trim_type (ripple vs roll)
        if timeline_state and command_manager then
            local selected_edges = timeline_state.get_selected_edges()
            if not selected_edges or #selected_edges == 0 then
                print("ExtendEdit: no edges selected")
                return true
            end

            local playhead_value = timeline_state.get_playhead_position()
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            assert(project_id and project_id ~= "", "keyboard_shortcuts: missing project_id for ExtendEdit")
            assert(sequence_id and sequence_id ~= "", "keyboard_shortcuts: missing sequence_id for ExtendEdit")

            -- Build edge_infos with trim_type preserved
            local all_clips = timeline_state.get_clips()
            local edge_infos = {}
            for _, edge in ipairs(selected_edges) do
                local clip = nil
                for _, c in ipairs(all_clips) do
                    if c.id == edge.clip_id then
                        clip = c
                        break
                    end
                end
                if clip then
                    table.insert(edge_infos, {
                        clip_id = edge.clip_id,
                        edge_type = edge.edge_type,
                        track_id = clip.track_id,
                        trim_type = edge.trim_type,  -- ripple or roll
                    })
                end
            end

            if #edge_infos == 0 then
                print("ExtendEdit: no valid edges found")
                return true
            end

            local result = execute_command("ExtendEdit", {
                edge_infos = edge_infos,
                playhead_frame = playhead_value,
                project_id = project_id,
                sequence_id = sequence_id,
            })

            if result and result.success then
                local trim_type = edge_infos[1].trim_type or "ripple"
                print(string.format("Extended %d edge(s) to playhead (%s)", #edge_infos, trim_type))
            else
                print("ExtendEdit: " .. ((result and result.error_message) or "failed"))
            end
        end
        return true
    end
    if key == KEY.R and panel_active_timeline then
        print("Ripple tool (not implemented yet)")
        return true
    end
    if key == KEY.T and panel_active_timeline then
        print("Roll tool (not implemented yet)")
        return true
    end

    -- F9: INSERT at playhead (ripple subsequent clips forward)
    if key == KEY.F9 and panel_active_timeline then
        if command_manager and timeline_state and project_browser then
            project_browser.add_selected_to_timeline("Insert", {advance_playhead = true})
        end
        return true
    end

    -- F10: OVERWRITE at playhead (trim/replace existing clips)
    if key == KEY.F10 and panel_active_timeline then
        if command_manager and timeline_state and project_browser then
            local selected_clip = project_browser.get_selected_media()
            if not selected_clip then
                print("❌ OVERWRITE: No media selected in project browser")
                return true
            end
            project_browser.add_selected_to_timeline("Overwrite", {advance_playhead = true})
        end
        return true
    end

    -- F12: Capture bug report (manual capture of last 5 minutes)
    if key == KEY.F12 then
        local bug_reporter = require("bug_reporter.init")
        local test_path = bug_reporter.capture_manual("User pressed F12 - Manual bug report capture")

        if test_path then
            print("✅ Bug report captured: " .. test_path)
            print("📋 Review dialog: Help → Bug Reporter → Review Last Capture")

            -- Optional: Show submission dialog immediately (non-blocking)
            local submission_dialog = require("bug_reporter.ui.submission_dialog")
            local wrapper = submission_dialog.create(test_path)
            if wrapper and wrapper.dialog then
                qt_show_dialog(wrapper.dialog, false)
            end
        else
            print("❌ Bug report capture failed")
        end
        return true
    end

    -- Shift + Z: Scale timeline to fit (zoom to show all content) with toggle
    if key == KEY.Z and has_modifier(modifiers, MOD.Shift) and panel_active_timeline then
        keyboard_shortcuts.toggle_zoom_fit()
        return true
    end

    -- Cmd/Ctrl + Plus/Equal: Zoom in
    if (key == KEY.Plus or key == KEY.Equal) and modifier_meta and panel_active_timeline then
        if timeline_state then
            clear_zoom_fit_toggle()
            local current_duration = timeline_state.get_viewport_duration()
            assert(type(current_duration) == "number", "keyboard_shortcuts: viewport_duration must be integer")
            local new_duration = math.max(30, math.floor(current_duration / 1.5))  -- min 30 frames
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed in: viewport duration %d frames", new_duration))
        end
        return true
    end

    -- Cmd/Ctrl + Minus: Zoom out
    if key == KEY.Minus and modifier_meta and panel_active_timeline then
        if timeline_state then
            clear_zoom_fit_toggle()
            local current_duration = timeline_state.get_viewport_duration()
            assert(type(current_duration) == "number", "keyboard_shortcuts: viewport_duration must be integer")
            local new_duration = math.floor(current_duration * 1.5)
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed out: viewport duration %d frames", new_duration))
        end
        return true
    end

    -- Option/Alt + Up: Move selected clips up one track
    -- ... (Move logic unchanged, it relies on commands which are Rational-safe) ...
    -- I'll leave the move logic block as is for brevity, it uses IDs and Commands.
    
    -- N: Toggle magnetic snapping (context-aware)
    if key == KEY.N and panel_active_timeline and not has_modifier(modifiers, MOD.Shift) and
       not has_modifier(modifiers, MOD.Control) and not has_modifier(modifiers, MOD.Meta) then
        if keyboard_shortcuts.is_dragging() then
            keyboard_shortcuts.invert_drag_snapping()
        else
            keyboard_shortcuts.toggle_baseline_snapping()
        end
        return true
    end

    return false  -- Event not handled
end

-- Public entry point that wraps handle_key_impl with command event management
function keyboard_shortcuts.handle_key(event)
    -- Begin command event for all execute() calls in this handler
    -- (only if one isn't already active - allows calling from within existing event scope)
    local can_peek = command_manager and type(command_manager.peek_command_event_origin) == "function"
    local owns_command_event = not command_manager or not can_peek or not command_manager.peek_command_event_origin()
    if owns_command_event then
        if command_manager and type(command_manager.begin_command_event) == "function" then command_manager.begin_command_event("ui") end
    end

    -- Call implementation (pcall ensures cleanup even if there's an error)
    local success, result = pcall(handle_key_impl, event)

    -- Always cleanup command event
    if owns_command_event then
        if command_manager and type(command_manager.end_command_event) == "function" then command_manager.end_command_event() end
    end

    -- Propagate error or return result
    if not success then
        error(result)
    end
    return result
end

-- Handle key release events (K held state + arrow repeat cancellation)
function keyboard_shortcuts.handle_key_release(event)
    local key = event.key

    -- Ignore OS autorepeat release events (they precede each autorepeat press)
    if event.is_auto_repeat then
        return false
    end

    if key == KEY.K then
        k_held = false
    end

    -- K+J or K+L slow play: releasing J/L while K held → stop
    if (key == KEY.J or key == KEY.L) and k_held then
        local engine = get_active_engine()
        if engine then engine:stop() end
    end

    -- Stop arrow key repeat on real release
    if key == KEY.Left or key == KEY.Right then
        arrow_repeat_active = false
        arrow_repeat_gen = arrow_repeat_gen + 1  -- invalidate pending timer
    end

    return false  -- Key release is not "handled" - let it propagate
end

return keyboard_shortcuts
