-- Keyboard Shortcuts Module
-- Centralized keyboard shortcut handling for the video editor

local keyboard_shortcuts = {}

-- Qt key constants (from Qt::Key enum)
local KEY = {
    Space = 32,
    Backspace = 16777219,
    Delete = 16777223,
    Left = 16777234,
    Right = 16777236,
    Up = 16777235,
    Down = 16777237,
    Home = 16777232,
    End = 16777233,
    A = 65,
    C = 67,
    N = 78,
    V = 86,
    X = 88,
    Z = 90,
    I = 73,
    O = 79,
    B = 66,
    J = 74,
    K = 75,
    L = 76,
    Q = 81,
    W = 87,
    E = 69,
    R = 82,
    T = 84,
    Plus = 43,       -- '+'
    Minus = 45,      -- '-'
    Equal = 61,      -- '=' (also + on US keyboards)
    Comma = 44,      -- ','
    Period = 46,     -- '.'
    F9 = 16777272,   -- 0x01000038
    F10 = 16777273,  -- 0x01000039
}

-- Qt modifier constants (from Qt::KeyboardModifier enum)
local MOD = {
    NoModifier = 0,
    Shift = 0x02000000,
    Control = 0x04000000,
    Alt = 0x08000000,
    Meta = 0x10000000,
}

-- Expose key/modifier maps for other modules that need to parse shortcuts
keyboard_shortcuts.KEY = KEY
keyboard_shortcuts.MOD = MOD

-- References to timeline state and other modules
local timeline_state = nil
local command_manager = nil
local project_browser = nil
local timeline_panel = nil

-- MAGNETIC SNAPPING STATE
-- Baseline preference (persists across drags)
local baseline_snapping_enabled = true  -- Default ON
-- Per-drag inversion (resets when drag ends)
local drag_snapping_inverted = false

-- Initialize with references to other modules
function keyboard_shortcuts.init(state, cmd_mgr, proj_browser, panel)
    timeline_state = state
    command_manager = cmd_mgr
    project_browser = proj_browser
    timeline_panel = panel
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

-- Check if a modifier is active (LuaJIT compatible bitwise AND)
local function has_modifier(modifiers, mod)
    local bit = require("bit")
    return bit.band(modifiers, mod) ~= 0
end

-- Global key handler function (called from Qt event filter)
function keyboard_shortcuts.handle_key(event)
    local key = event.key
    local modifiers = event.modifiers
    local text = event.text

    -- Cmd/Ctrl + Z: Undo
    -- Cmd/Ctrl + Shift + Z: Redo
    if key == KEY.Z and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if has_modifier(modifiers, MOD.Shift) then
            -- Redo
            if command_manager then
                local result = command_manager.redo()
                if result.success then
                    print("Redo complete")
                end
            end
        else
            -- Undo
            if command_manager then
                local result = command_manager.undo()
                if result.success then
                    print("Undo complete")
                else
                    -- Provide clear feedback on why undo failed
                    if result.error_message then
                        print("ERROR: Undo failed - " .. result.error_message)
                    else
                        print("ERROR: Undo failed - event log may be corrupted")
                    end
                end
            end
        end
        return true  -- Event handled
    end

    -- Delete/Backspace: Delete selected clips via command system
    if (key == KEY.Delete or key == KEY.Backspace) and timeline_state and command_manager then
        local selected_clips = timeline_state.get_selected_clips()
        if #selected_clips > 0 then
            local Command = require("command")
            local json = require("dkjson")

            -- Build array of delete command specs for batch operation
            local command_specs = {}
            for _, clip in ipairs(selected_clips) do
                table.insert(command_specs, {
                    command_type = "DeleteClip",
                    parameters = {
                        clip_id = clip.id
                    }
                })
            end

            -- Execute as single batch command (single undo entry)
            local commands_json = json.encode(command_specs)
            local batch_cmd = Command.create("BatchCommand", "default_project")
            batch_cmd:set_parameter("commands_json", commands_json)

            local result = command_manager.execute(batch_cmd)
            if result.success then
                timeline_state.set_selection({})
                print(string.format("Deleted %d clips (single undo)", #selected_clips))
            else
                print(string.format("Failed to delete clips: %s", result.error_message or "unknown error"))
            end
            return true
        end
    end

    -- Cmd/Ctrl + A: Select all clips
    -- Shift + Cmd/Ctrl + A: Deselect all
    if key == KEY.A and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            if has_modifier(modifiers, MOD.Shift) then
                -- Shift+Cmd+A: Clear selection
                timeline_state.set_selection({})
                timeline_state.clear_edge_selection()
                print("Cleared selection")
            else
                -- Cmd+A: Select all clips
                local all_clips = timeline_state.get_clips()
                timeline_state.set_selection(all_clips)
                print(string.format("Selected all %d clips", #all_clips))
            end
            return true
        end
    end

    -- Comma/Period: Frame-accurate nudge for clips and edges
    -- Comma (,) = left, Period (.) = right
    -- Without Shift: 1 frame, With Shift: 1 second (30 frames @ 30fps)
    if key == KEY.Comma or key == KEY.Period then
        if timeline_state and command_manager then
            -- Get frame rate from sequence (TODO: load from database, for now assume 30fps)
            local frame_rate = 30.0
            local frame_duration_ms = math.floor(1000.0 / frame_rate)  -- ~33ms per frame at 30fps

            -- Calculate nudge amount
            local nudge_frames = 1
            if has_modifier(modifiers, MOD.Shift) then
                nudge_frames = 30  -- 1 second = 30 frames
            end
            local nudge_ms = nudge_frames * frame_duration_ms
            if key == KEY.Comma then
                nudge_ms = -nudge_ms  -- Left = negative
            end

            -- Check what's selected: clips or edges
            local selected_clips = timeline_state.get_selected_clips()
            local selected_edges = timeline_state.get_selected_edges()

            local Command = require("command")

            -- Edges use RippleEdit (trim with timeline shift)
            -- Clips use Nudge (simple move)
            if #selected_edges > 0 then
                -- Gather edge info with track_id
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
                            track_id = clip.track_id
                        })
                    end
                end

                -- Use BatchRippleEdit for multiple edges (prevents cascading shifts)
                -- Use regular RippleEdit for single edge (simpler undo history)
                local result
                if #edge_infos > 1 then
                    local batch_cmd = Command.create("BatchRippleEdit", "default_project")
                    batch_cmd:set_parameter("edge_infos", edge_infos)
                    batch_cmd:set_parameter("delta_ms", nudge_ms)
                    batch_cmd:set_parameter("sequence_id", "default_sequence")
                    result = command_manager.execute(batch_cmd)
                elseif #edge_infos == 1 then
                    local ripple_cmd = Command.create("RippleEdit", "default_project")
                    ripple_cmd:set_parameter("edge_info", edge_infos[1])
                    ripple_cmd:set_parameter("delta_ms", nudge_ms)
                    ripple_cmd:set_parameter("sequence_id", "default_sequence")
                    result = command_manager.execute(ripple_cmd)
                end

                if result and result.success then
                    print(string.format("Ripple edited %d edge(s) by %d frames (%dms)", #edge_infos, nudge_frames, nudge_ms))
                else
                    print("ERROR: Ripple edit failed")
                end
            elseif #selected_clips > 0 then
                -- Nudge clips
                local clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    table.insert(clip_ids, clip.id)
                end

                local nudge_cmd = Command.create("Nudge", "default_project")
                nudge_cmd:set_parameter("nudge_amount_ms", nudge_ms)
                nudge_cmd:set_parameter("selected_clip_ids", clip_ids)

                local result = command_manager.execute(nudge_cmd)
                if result.success then
                    print(string.format("Nudged %d clips by %d frames (%dms)", #selected_clips, nudge_frames, nudge_ms))
                else
                    print("ERROR: Nudge failed: " .. (result.error_message or "unknown error"))
                end
            else
                print("Nothing selected to nudge/ripple")
            end

            return true
        end
    end

    -- Space: Play/Pause (placeholder - actual playback not implemented yet)
    if key == KEY.Space then
        print("Play/Pause (not implemented yet)")
        return true
    end

    -- I: Mark in point (placeholder)
    if key == KEY.I then
        print("Mark In (not implemented yet)")
        return true
    end

    -- O: Mark out point (placeholder)
    if key == KEY.O then
        print("Mark Out (not implemented yet)")
        return true
    end

    -- Cmd/Ctrl + B: Blade tool - split selected clip at playhead
    if key == KEY.B and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            local playhead_time = timeline_state.get_playhead_time()

            if #selected_clips == 1 then
                local clip = selected_clips[1]
                -- Check if playhead is within the clip bounds
                if playhead_time > clip.start_time and playhead_time < (clip.start_time + clip.duration) then
                    -- Create proper Command object
                    local Command = require("command")
                    local split_command = Command.create("SplitClip", "default_project")
                    split_command:set_parameter("clip_id", clip.id)
                    split_command:set_parameter("split_time", playhead_time)

                    local result = command_manager.execute(split_command)
                    if result.success then
                        print(string.format("Split clip at playhead %dms", playhead_time))
                    else
                        print(string.format("Failed to split clip: %s", result.error_message))
                    end
                else
                    print("Playhead is not within selected clip bounds")
                end
            elseif #selected_clips == 0 then
                print("No clip selected for blade tool")
            else
                print("Blade tool requires exactly one selected clip")
            end
        end
        return true
    end

    -- J/K/L: Playback controls (industry standard)
    if key == KEY.J then
        print("Reverse playback (not implemented yet)")
        return true
    end
    if key == KEY.K then
        print("Pause (not implemented yet)")
        return true
    end
    if key == KEY.L then
        print("Forward playback (not implemented yet)")
        return true
    end

    -- Q/W/E/R/T: Tool switching
    if key == KEY.Q then
        print("Select tool (not implemented yet)")
        return true
    end
    if key == KEY.W then
        print("Track select tool (not implemented yet)")
        return true
    end
    if key == KEY.E then
        print("Trim tool (not implemented yet)")
        return true
    end
    if key == KEY.R then
        print("Ripple tool (not implemented yet)")
        return true
    end
    if key == KEY.T then
        print("Roll tool (not implemented yet)")
        return true
    end

    -- F9: INSERT at playhead (ripple subsequent clips forward)
    if key == KEY.F9 then
        if command_manager and timeline_state and project_browser then
            -- Get selected media from project browser
            local selected_media = project_browser.get_selected_media()
            if not selected_media then
                print("❌ INSERT: No media selected in project browser")
                return true
            end

            local Command = require("command")
            local playhead_time = timeline_state.get_playhead_time()
            local insert_cmd = Command.create("Insert", "default_project")
            insert_cmd:set_parameter("media_id", selected_media.id)
            insert_cmd:set_parameter("track_id", "video1")
            insert_cmd:set_parameter("insert_time", playhead_time)
            insert_cmd:set_parameter("duration", selected_media.duration)
            insert_cmd:set_parameter("source_in", 0)
            insert_cmd:set_parameter("source_out", selected_media.duration)
            insert_cmd:set_parameter("advance_playhead", true)  -- Command will move playhead
            local result = command_manager.execute(insert_cmd)
            if result.success then
                print(string.format("✅ INSERT: Added %s at %dms, rippled subsequent clips", selected_media.name, playhead_time))
            else
                print("❌ INSERT failed: " .. (result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- F10: OVERWRITE at playhead (trim/replace existing clips)
    if key == KEY.F10 then
        if command_manager and timeline_state and project_browser then
            -- Get selected media from project browser
            local selected_media = project_browser.get_selected_media()
            if not selected_media then
                print("❌ OVERWRITE: No media selected in project browser")
                return true
            end

            local Command = require("command")
            local playhead_time = timeline_state.get_playhead_time()
            local overwrite_cmd = Command.create("Overwrite", "default_project")
            overwrite_cmd:set_parameter("media_id", selected_media.id)
            overwrite_cmd:set_parameter("track_id", "video1")
            overwrite_cmd:set_parameter("overwrite_time", playhead_time)
            overwrite_cmd:set_parameter("duration", selected_media.duration)
            overwrite_cmd:set_parameter("source_in", 0)
            overwrite_cmd:set_parameter("source_out", selected_media.duration)
            overwrite_cmd:set_parameter("advance_playhead", true)  -- Command will move playhead
            local result = command_manager.execute(overwrite_cmd)
            if result.success then
                print(string.format("✅ OVERWRITE: Added %s at %dms, trimmed overlapping clips", selected_media.name, playhead_time))
            else
                print("❌ OVERWRITE failed: " .. (result.error_message or "unknown error"))
            end
        end
        return true
    end

    -- Shift + Z: Scale timeline to fit (zoom to show all content)
    if key == KEY.Z and has_modifier(modifiers, MOD.Shift) then
        if timeline_state then
            -- Calculate total timeline duration needed to show all clips
            local clips = timeline_state.get_clips()
            local max_end_time = 0
            for _, clip in ipairs(clips) do
                local clip_end = clip.start_time + clip.duration
                if clip_end > max_end_time then
                    max_end_time = clip_end
                end
            end

            if max_end_time > 0 then
                -- Add 10% padding on the right side for breathing room
                local viewport_duration = math.floor(max_end_time * 1.1)
                timeline_state.set_viewport_duration(viewport_duration)
                timeline_state.set_viewport_start_time(0)
                print(string.format("Scaled to fit: showing 0 - %dms", viewport_duration))
            else
                print("No clips to scale to")
            end
        end
        return true
    end

    -- Cmd/Ctrl + Plus/Equal: Zoom in
    if (key == KEY.Plus or key == KEY.Equal) and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = math.floor(current_duration / 1.5)  -- Zoom in by 50%
            if new_duration < 100 then
                new_duration = 100  -- Minimum zoom level
            end
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed in: viewport duration %dms", new_duration))
        end
        return true
    end

    -- Cmd/Ctrl + Minus: Zoom out
    if key == KEY.Minus and (has_modifier(modifiers, MOD.Control) or has_modifier(modifiers, MOD.Meta)) then
        if timeline_state then
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = math.floor(current_duration * 1.5)  -- Zoom out by 50%
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("Zoomed out: viewport duration %dms", new_duration))
        end
        return true
    end

    -- Option/Alt + Up: Move selected clips up one track
    -- Video: up means higher track number (V1→V2→V3)
    -- Audio: up means lower track number (A3→A2→A1)
    if key == KEY.Up and has_modifier(modifiers, MOD.Alt) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            if #selected_clips > 0 then
                -- Check if all clips are on the same track
                local first_track_id = selected_clips[1].track_id
                local all_same_track = true
                print(string.format("DEBUG: Alt+Up - checking %d clips, first on track %s",
                    #selected_clips, first_track_id))
                for i, clip in ipairs(selected_clips) do
                    print(string.format("  Clip %d: %s on track %s",
                        i, clip.id:sub(1,8), clip.track_id))
                    if clip.track_id ~= first_track_id then
                        all_same_track = false
                        break
                    end
                end

                if not all_same_track then
                    print("Cannot move clips: selection spans multiple tracks")
                    return true
                end

                -- Store clip IDs before moving (clip objects will become stale)
                local clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    table.insert(clip_ids, clip.id)
                end

                local tracks = timeline_state.get_all_tracks()
                local moved_count = 0

                -- Move each clip by ID, reloading fresh data each time
                for _, clip_id in ipairs(clip_ids) do
                    -- Get fresh clip data from timeline_state
                    local all_clips = timeline_state.get_clips()
                    local clip = nil
                    for _, c in ipairs(all_clips) do
                        if c.id == clip_id then
                            clip = c
                            break
                        end
                    end

                    if not clip then
                        print(string.format("WARNING: Clip %s not found", clip_id))
                        goto continue
                    end

                    -- Find current track
                    local current_track_index = -1
                    local current_track = nil
                    for i, track in ipairs(tracks) do
                        if track.id == clip.track_id then
                            current_track_index = i
                            current_track = track
                            break
                        end
                    end

                    if current_track then
                        local target_track_index = -1

                        -- For VIDEO tracks: "up" means higher index (V1→V2→V3)
                        -- For AUDIO tracks: "up" means lower index (A3→A2→A1)
                        if current_track.track_type == "VIDEO" then
                            target_track_index = current_track_index + 1
                        else  -- AUDIO
                            target_track_index = current_track_index - 1
                        end

                        -- Validate target track exists and is same type
                        if target_track_index >= 1 and target_track_index <= #tracks then
                            local target_track = tracks[target_track_index]

                            if target_track.track_type == current_track.track_type then
                                local Command = require("command")
                                local move_cmd = Command.create("MoveClipToTrack", "default_project")
                                move_cmd:set_parameter("clip_id", clip.id)
                                move_cmd:set_parameter("target_track_id", target_track.id)

                                local result = command_manager.execute(move_cmd)
                                if result.success then
                                    moved_count = moved_count + 1
                                end
                            end
                        end
                    end

                    ::continue::
                end

                if moved_count > 0 then
                    print(string.format("Moved %d clip(s) up one track", moved_count))
                else
                    print("Cannot move clips up (at limit or type mismatch)")
                end
            else
                print("No clips selected to move")
            end
        end
        return true
    end

    -- Option/Alt + Down: Move selected clips down one track
    -- Video: down means lower track number (V3→V2→V1)
    -- Audio: down means higher track number (A1→A2→A3)
    if key == KEY.Down and has_modifier(modifiers, MOD.Alt) then
        if timeline_state and command_manager then
            local selected_clips = timeline_state.get_selected_clips()
            if #selected_clips > 0 then
                -- Check if all clips are on the same track
                local first_track_id = selected_clips[1].track_id
                local all_same_track = true
                print(string.format("DEBUG: Alt+Down - checking %d clips, first on track %s",
                    #selected_clips, first_track_id))
                for i, clip in ipairs(selected_clips) do
                    print(string.format("  Clip %d: %s on track %s",
                        i, clip.id:sub(1,8), clip.track_id))
                    if clip.track_id ~= first_track_id then
                        all_same_track = false
                        break
                    end
                end

                if not all_same_track then
                    print("Cannot move clips: selection spans multiple tracks")
                    return true
                end

                -- Store clip IDs before moving (clip objects will become stale)
                local clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    table.insert(clip_ids, clip.id)
                end

                local tracks = timeline_state.get_all_tracks()
                local moved_count = 0

                -- Move each clip by ID, reloading fresh data each time
                for _, clip_id in ipairs(clip_ids) do
                    -- Get fresh clip data from timeline_state
                    local all_clips = timeline_state.get_clips()
                    local clip = nil
                    for _, c in ipairs(all_clips) do
                        if c.id == clip_id then
                            clip = c
                            break
                        end
                    end

                    if not clip then
                        print(string.format("WARNING: Clip %s not found", clip_id))
                        goto continue
                    end

                    -- Find current track
                    local current_track_index = -1
                    local current_track = nil
                    for i, track in ipairs(tracks) do
                        if track.id == clip.track_id then
                            current_track_index = i
                            current_track = track
                            break
                        end
                    end

                    if current_track then
                        local target_track_index = -1

                        -- For VIDEO tracks: "down" means lower index (V3→V2→V1)
                        -- For AUDIO tracks: "down" means higher index (A1→A2→A3)
                        if current_track.track_type == "VIDEO" then
                            target_track_index = current_track_index - 1
                        else  -- AUDIO
                            target_track_index = current_track_index + 1
                        end

                        -- Validate target track exists and is same type
                        if target_track_index >= 1 and target_track_index <= #tracks then
                            local target_track = tracks[target_track_index]
                            if target_track.track_type == current_track.track_type then
                                local Command = require("command")
                                local move_cmd = Command.create("MoveClipToTrack", "default_project")
                                move_cmd:set_parameter("clip_id", clip.id)
                                move_cmd:set_parameter("target_track_id", target_track.id)

                                local result = command_manager.execute(move_cmd)
                                if result.success then
                                    moved_count = moved_count + 1
                                end
                            end
                        end
                    end

                    ::continue::
                end

                if moved_count > 0 then
                    print(string.format("Moved %d clip(s) down one track", moved_count))
                else
                    print("Cannot move clips down (at limit or type mismatch)")
                end
            else
                print("No clips selected to move")
            end
        end
        return true
    end

    -- N: Toggle magnetic snapping (context-aware)
    if key == KEY.N and not has_modifier(modifiers, MOD.Shift) and
       not has_modifier(modifiers, MOD.Control) and not has_modifier(modifiers, MOD.Meta) then
        if keyboard_shortcuts.is_dragging() then
            -- During drag: invert snapping for this drag only
            keyboard_shortcuts.invert_drag_snapping()
        else
            -- At rest: toggle baseline preference
            keyboard_shortcuts.toggle_baseline_snapping()
        end
        return true
    end

    return false  -- Event not handled
end

return keyboard_shortcuts
