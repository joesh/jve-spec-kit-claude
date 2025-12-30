--- Contextual actions for project browser (bins, sequences, timeline).
--
-- Responsibilities:
-- - Create/delete project entities via commands
-- - Provide context menu behavior for browser items
-- - Route insert/delete commands through shared helpers
-- - Encapsulate helper utilities used only by these actions
--
-- Non-goals:
-- - Selection state management
-- - Tree widget behavior
--
-- Invariants:
-- - Context passed via setup contains the runtime modules/functions referenced below
--
-- @file browser_actions.lua
local Command = require("command")
local command_manager = require("core.command_manager")
local db = require("core.database")
local logger = require("core.logger")
local uuid = require("uuid")
local insert_selected_clip_into_timeline = require("core.clip_insertion")

local M = {}
local ctx = {}

local function collect_name_lookup(map)
    local lookup = {}
    if map then
        for _, entry in pairs(map) do
            local name = entry and entry.name
            if name and name ~= "" then
                lookup[name:lower()] = true
            end
        end
    end
    return lookup
end

local function generate_sequential_label(prefix, lookup)
    local suffix = 1
    while true do
        local candidate = string.format("%s %d", prefix, suffix)
        if not lookup[candidate:lower()] then
            return candidate
        end
        suffix = suffix + 1
    end
end

local function sequence_defaults()
    local defaults = {
        frame_rate = 30.0,
        width = 1920,
        height = 1080
    }

    local timeline_panel = ctx.project_browser.timeline_panel
    local timeline_state_module = timeline_panel and timeline_panel.get_state and timeline_panel.get_state()
    local sequence_id = timeline_state_module and timeline_state_module.get_sequence_id and timeline_state_module.get_sequence_id()
    if sequence_id and sequence_id ~= "" then
        local ok, record = pcall(db.load_sequence_record, sequence_id)
        if ok and record then
            defaults.frame_rate = record.frame_rate or defaults.frame_rate
            defaults.width = record.width or defaults.width
            defaults.height = record.height or defaults.height
        end
    end

    return defaults
end

local function start_inline_rename_after(focus_fn)
    local defer = ctx.defer_to_ui
    if type(defer) ~= "function" then
        if type(focus_fn) == "function" then
            focus_fn()
        end
        if ctx.project_browser.start_inline_rename then
            ctx.project_browser.start_inline_rename()
        end
        return
    end
    defer(function()
        if type(focus_fn) == "function" then
            focus_fn()
        end
        if ctx.project_browser.start_inline_rename then
            ctx.project_browser.start_inline_rename()
        end
    end)
end

function M.create_bin_in_root()
    local project_id = ctx.current_project_id and ctx.current_project_id()
    local name_lookup = collect_name_lookup(ctx.project_browser.bin_map)
    local temp_name = generate_sequential_label("Bin", name_lookup)

    local cmd = Command.create("NewBin", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("name", temp_name)

    local result = command_manager.execute(cmd)
    if not result or not result.success then
        logger.warn("project_browser", string.format("New Bin failed: %s", result and result.error_message or "unknown error"))
        return
    end

    local bin_definition = cmd:get_parameter("bin_definition")
    local new_bin_id = bin_definition and bin_definition.id
    if not new_bin_id then
        return
    end

    ctx.project_browser.refresh()
    start_inline_rename_after(function()
        if ctx.project_browser.focus_bin then
            ctx.project_browser.focus_bin(new_bin_id, {skip_activate = true})
        end
    end)
end

function M.create_sequence_in_project()
    local project_id = ctx.current_project_id and ctx.current_project_id()
    local name_lookup = collect_name_lookup(ctx.project_browser.sequence_map)
    local temp_name = generate_sequential_label("Sequence", name_lookup)
    local defaults = sequence_defaults()

    local cmd = Command.create("CreateSequence", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("name", temp_name)
    cmd:set_parameter("frame_rate", defaults.frame_rate)
    cmd:set_parameter("width", defaults.width)
    cmd:set_parameter("height", defaults.height)

    local result = command_manager.execute(cmd)
    if not result or not result.success then
        logger.warn("project_browser", string.format("New Sequence failed: %s", result and result.error_message or "unknown error"))
        return
    end

    local sequence_id = cmd:get_parameter("sequence_id")
    if not sequence_id then
        return
    end

    ctx.project_browser.refresh()
    start_inline_rename_after(function()
        if ctx.project_browser.focus_sequence then
            ctx.project_browser.focus_sequence(sequence_id, {skip_activate = true})
        end
    end)
end

local function show_browser_background_menu(global_x, global_y)
    local tree = ctx.project_browser.tree
    if not tree or not ctx.qt_constants then
        return
    end
    if not ctx.qt_constants.MENU or not ctx.qt_constants.MENU.CREATE_MENU or not ctx.qt_constants.MENU.SHOW_POPUP then
        logger.warn("project_browser", "Context menu unavailable: Qt menu bindings missing")
        return
    end

    local actions = {
        {label = "New Bin", handler = M.create_bin_in_root},
        {label = "New Sequence", handler = M.create_sequence_in_project},
    }

    local menu = ctx.qt_constants.MENU.CREATE_MENU(tree, "ProjectBrowserBackground")
    for _, action_def in ipairs(actions) do
        local qt_action = ctx.qt_constants.MENU.CREATE_MENU_ACTION(menu, action_def.label)
        ctx.qt_constants.MENU.CONNECT_MENU_ACTION(qt_action, function()
            action_def.handler()
        end)
    end
    ctx.qt_constants.MENU.SHOW_POPUP(menu, math.floor(global_x or 0), math.floor(global_y or 0))
end

M.show_browser_background_menu = show_browser_background_menu

function M.show_browser_context_menu(event)
    local tree = ctx.project_browser.tree
    if not event or not tree or not ctx.qt_constants then
        return
    end

    if not ctx.qt_constants.MENU or not ctx.qt_constants.MENU.CREATE_MENU or not ctx.qt_constants.MENU.SHOW_POPUP then
        logger.warn("project_browser", "Context menu unavailable: Qt menu bindings missing")
        return
    end

    local local_x = math.floor(event.x or 0)
    local local_y = math.floor(event.y or 0)
    local global_x = event.global_x and math.floor(event.global_x) or nil
    local global_y = event.global_y and math.floor(event.global_y) or nil

    if (not global_x or not global_y) and ctx.qt_constants.WIDGET and ctx.qt_constants.WIDGET.MAP_TO_GLOBAL then
        global_x, global_y = ctx.qt_constants.WIDGET.MAP_TO_GLOBAL(tree, local_x, local_y)
    end

    local clicked_tree_id = nil
    if ctx.qt_constants.CONTROL.GET_TREE_ITEM_AT then
        clicked_tree_id = ctx.qt_constants.CONTROL.GET_TREE_ITEM_AT(tree, local_x, local_y)
        if not clicked_tree_id then
            show_browser_background_menu(global_x, global_y)
            return
        end
    end

    if clicked_tree_id then
        local already_selected = false
        for _, selected in ipairs(ctx.project_browser.selected_items or {}) do
            if selected.tree_id == clicked_tree_id then
                already_selected = true
                break
            end
        end

        if not already_selected then
            if ctx.qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
                ctx.qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(tree, clicked_tree_id, true, true)
            end
            local info = ctx.project_browser.item_lookup and ctx.project_browser.item_lookup[tostring(clicked_tree_id)]
            if ctx.apply_single_selection then
                ctx.apply_single_selection(info)
            end
        end
    end

    local selected_items = ctx.project_browser.selected_items or {}
    if #selected_items == 0 and ctx.project_browser.selected_item then
        selected_items = {ctx.project_browser.selected_item}
    end
    if #selected_items == 0 then
        return
    end

    local selected_master = ctx.project_browser.get_selected_master_clip and ctx.project_browser.get_selected_master_clip()
    local primary_info = selected_items[1]
    local actions = {}

    if selected_master then
        table.insert(actions, {
            label = "Insert Into Timeline",
            handler = function()
                M.insert_selected_to_timeline("Insert")
            end
        })
        table.insert(actions, {
            label = "Reveal in Filesystem",
            handler = function()
                local result = command_manager.execute("RevealInFilesystem")
                if result and not result.success then
                    logger.warn("project_browser", string.format("Reveal in Filesystem failed: %s", result.error_message or "unknown error"))
                end
            end
        })
    end

    local rename_supported = primary_info and (primary_info.type == "master_clip"
        or primary_info.type == "timeline"
        or primary_info.type == "bin")
    if rename_supported and ctx.project_browser.start_inline_rename then
        table.insert(actions, {
            label = "Rename...",
            handler = function()
                ctx.project_browser.start_inline_rename()
            end
        })
    end

    table.insert(actions, {
        label = "Delete",
        handler = function()
            if not M.delete_selected_items() then
                logger.warn("project_browser", "Delete failed: nothing selected")
            end
        end
    })

    if #actions == 0 then
        return
    end

    local menu = ctx.qt_constants.MENU.CREATE_MENU(tree, "ProjectBrowserContext")
    for _, action_def in ipairs(actions) do
        local qt_action = ctx.qt_constants.MENU.CREATE_MENU_ACTION(menu, action_def.label or "Action")
        if action_def.enabled == false then
            ctx.qt_constants.MENU.SET_ACTION_ENABLED(qt_action, false)
        else
            ctx.qt_constants.MENU.CONNECT_MENU_ACTION(qt_action, function()
                action_def.handler()
            end)
        end
    end

    ctx.qt_constants.MENU.SHOW_POPUP(menu, math.floor(global_x or 0), math.floor(global_y or 0))
end

function M.insert_selected_to_timeline(command_type, options)
    local project_browser = ctx.project_browser
    local this_func_label = "project_browser.insert_selected_to_timeline"
    assert(project_browser and project_browser.timeline_panel, this_func_label .. ": timeline panel not available")
    local clip = assert(project_browser.get_selected_master_clip and project_browser.get_selected_master_clip(), this_func_label .. ": no media item selected")
    local timeline_state_module = assert(project_browser.timeline_panel.get_state and project_browser.timeline_panel.get_state(), this_func_label .. ": timeline state not available")
    local sequence_id = assert(timeline_state_module.get_sequence_id and timeline_state_module.get_sequence_id(), this_func_label .. ": missing active sequence_id")
    local project_id = assert(timeline_state_module.get_project_id and timeline_state_module.get_project_id(), this_func_label .. ": missing active project_id")
    local insert_pos = assert(timeline_state_module.get_playhead_position and timeline_state_module.get_playhead_position(), this_func_label .. ": missing insert position")
    assert(command_type == "Insert" or command_type == "Overwrite", this_func_label .. ": unsupported command_type")

    local media = assert(clip.media or (clip.media_id and project_browser.master_clip_map and project_browser.master_clip_map[clip.media_id]), this_func_label .. ": missing media")
    local media_id = assert(clip.media_id or media.id, this_func_label .. ": missing media_id")
    local source_in = assert(clip.source_in, this_func_label .. ": missing source_in")
    local source_out = assert(clip.source_out or clip.duration or media.duration, this_func_label .. ": missing source_out")
    local duration = source_out - source_in
    assert(duration.frames and duration.frames > 0, this_func_label .. ": invalid duration")

    local payload_project_id = assert(clip.project_id or project_id, this_func_label .. ": missing clip project_id")
    local advance_playhead = options and options.advance_playhead == true

    local function clip_has_video()
        local width = assert(clip.width or media.width, this_func_label .. ": missing video width")
        local height = assert(clip.height or media.height, this_func_label .. ": missing video height")
        return width > 0 and height > 0
    end

    local function clip_audio_channel_count()
        local channels = assert(clip.audio_channels or media.audio_channels, this_func_label .. ": missing audio channel count")
        return assert(tonumber(channels), this_func_label .. ": audio channel count must be a number")
    end

    local function clip_has_audio()
        return clip_audio_channel_count() > 0
    end

    local selected_clip = {
        video = {
            role = "video",
            media_id = media_id,
            master_clip_id = clip.clip_id,
            project_id = payload_project_id,
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            clip_name = clip.name,
            advance_playhead = advance_playhead
        }
    }

    function selected_clip:has_video()
        return clip_has_video()
    end

    function selected_clip:has_audio()
        return clip_has_audio()
    end

    function selected_clip:audio_channel_count()
        return clip_audio_channel_count()
    end

    function selected_clip:audio(ch)
        assert(ch ~= nil, this_func_label .. ": missing audio channel index")
        return {
            role = "audio",
            media_id = media_id,
            master_clip_id = clip.clip_id,
            project_id = payload_project_id,
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            clip_name = clip.name,
            advance_playhead = advance_playhead,
            channel = ch
        }
    end

    local function sort_tracks(tracks)
        table.sort(tracks, function(a, b)
            local a_index = a.track_index or 0
            local b_index = b.track_index or 0
            return a_index < b_index
        end)
    end

    local function target_video_track(_, index)
        local tracks = assert(timeline_state_module.get_video_tracks and timeline_state_module.get_video_tracks(), this_func_label .. ": missing video tracks")
        sort_tracks(tracks)
        local track = tracks[index + 1]
        assert(track and track.id, string.format(this_func_label .. ": missing video track %d", index))
        return track
    end

    local function target_audio_track(_, index)
        local tracks = assert(timeline_state_module.get_audio_tracks and timeline_state_module.get_audio_tracks(), this_func_label .. ": missing audio tracks")
        sort_tracks(tracks)
        local track = tracks[index + 1]
        assert(track and track.id, string.format(this_func_label .. ": missing audio track %d", index))
        return track
    end

    local time_param = (command_type == "Overwrite") and "overwrite_time" or "insert_time"
    local function insert_clip(_, payload, track, pos)
        local clip_id = uuid.generate()
        local cmd = assert(Command.create(command_type, payload_project_id), this_func_label .. ": failed to create command")
        cmd:set_parameter("sequence_id", sequence_id)
        cmd:set_parameter("track_id", assert(track and track.id, this_func_label .. ": missing track id"))
        assert(payload.media_id or payload.master_clip_id, this_func_label .. ": missing payload media/master clip id")
        if payload.media_id then
            cmd:set_parameter("media_id", payload.media_id)
        end
        cmd:set_parameter("master_clip_id", payload.master_clip_id)
        cmd:set_parameter("duration", assert(payload.duration, this_func_label .. ": missing payload duration"))
        cmd:set_parameter("source_in", assert(payload.source_in, this_func_label .. ": missing payload source_in"))
        cmd:set_parameter("source_out", assert(payload.source_out, this_func_label .. ": missing payload source_out"))
        cmd:set_parameter(time_param, assert(pos, this_func_label .. ": missing insert position"))
        cmd:set_parameter("project_id", payload_project_id)
        cmd:set_parameter("clip_id", clip_id)
        if payload.clip_name then
            cmd:set_parameter("clip_name", payload.clip_name)
        end
        if payload.advance_playhead then
            cmd:set_parameter("advance_playhead", true)
        end

        local result = command_manager.execute(cmd)
        assert(result and result.success, string.format(this_func_label .. ": insert failed: %s", result and result.error_message or "unknown error"))
        return {id = clip_id, role = payload.role, time_offset = 0}
    end

    local sequence = {
        target_video_track = target_video_track,
        target_audio_track = target_audio_track,
        insert_clip = insert_clip
    }

    insert_selected_clip_into_timeline({
        selected_clip = selected_clip,
        sequence = sequence,
        insert_pos = insert_pos
    })

    logger.info("project_browser", string.format("Media inserted to timeline: %s", media.name or media.file_name))
    local focus_manager = ctx.focus_manager
    if focus_manager and focus_manager.focus_panel then
        focus_manager.focus_panel("timeline")
    else
        focus_manager.set_focused_panel("timeline")
    end
end

function M.delete_selected_items()
    local selection = ctx.project_browser.selected_items
    if not selection or #selection == 0 then
        return false
    end

    local deleted = 0
    local clip_failures = 0
    local sequence_failures = 0
    local bin_failures = 0
    local handled_sequences = {}

    for _, item in ipairs(selection) do
        if item.type == "master_clip" and item.clip_id then
            local clip = ctx.project_browser.master_clip_map and ctx.project_browser.master_clip_map[item.clip_id]
            if clip then
                local project_id = clip.project_id or ctx.project_browser.project_id or ctx.current_project_id and ctx.current_project_id()
                assert(project_id and project_id ~= "", "project_browser.delete_selected_items: missing project_id for DeleteMasterClip " .. tostring(item.clip_id))
                local cmd = Command.create("DeleteMasterClip", project_id)
                cmd:set_parameter("master_clip_id", clip.clip_id)
                local result = command_manager.execute(cmd)
                if result and result.success then
                    deleted = deleted + 1
                else
                    logger.warn("project_browser", string.format("Delete master clip failed: %s", result and result.error_message or "unknown error"))
                    clip_failures = clip_failures + 1
                end
            end
        elseif item.type == "timeline" and item.id then
            local sequence_id = item.id
            if not handled_sequences[sequence_id] then
                handled_sequences[sequence_id] = true
                if sequence_id == "default_sequence" then
                    sequence_failures = sequence_failures + 1
                    logger.warn("project_browser", "Delete sequence default_sequence skipped: primary timeline cannot be removed")
                    goto continue_delete_loop
                end

                local project_id = ctx.project_browser.project_id or ctx.current_project_id and ctx.current_project_id()
                assert(project_id and project_id ~= "", "project_browser.delete_selected_items: missing project_id for DeleteSequence " .. tostring(sequence_id))
                local cmd = Command.create("DeleteSequence", project_id)
                cmd:set_parameter("sequence_id", sequence_id)
                local result = command_manager.execute(cmd)
                if result and result.success then
                    deleted = deleted + 1
                else
                    sequence_failures = sequence_failures + 1
                    logger.warn("project_browser", string.format("Delete sequence %s failed: %s", tostring(sequence_id), result and result.error_message or "unknown error"))
                end
                ::continue_delete_loop::
            end
        elseif item.type == "bin" and item.id then
            local project_id = ctx.project_browser.project_id or ctx.current_project_id and ctx.current_project_id()
            assert(project_id and project_id ~= "", "project_browser.delete_selected_items: missing project_id for DeleteBin " .. tostring(item.id))
            local cmd = Command.create("DeleteBin", project_id)
            cmd:set_parameter("project_id", project_id)
            cmd:set_parameter("bin_id", item.id)
            local result = command_manager.execute(cmd)
            if result and result.success then
                deleted = deleted + 1
            else
                bin_failures = bin_failures + 1
                logger.warn("project_browser", string.format("Delete bin %s failed: %s", tostring(item.name or item.id), result and result.error_message or "unknown error"))
            end
        end
    end

    if deleted > 0 then
        ctx.project_browser.refresh()
        return true
    end

    if clip_failures > 0 or sequence_failures > 0 or bin_failures > 0 then
        return false
    end

    return false
end

function M.setup(config)
    ctx = config or {}
end

return M
