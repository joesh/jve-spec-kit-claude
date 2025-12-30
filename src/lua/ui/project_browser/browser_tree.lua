-- ============================================================================
-- File header / module setup
-- ============================================================================

local M = {}

-- ============================================================================
-- Dependencies and shared state
-- ============================================================================

local db = require("core.database")
local frame_utils = require("core.frame_utils")
local tag_service = require("core.tag_service")

local format_duration = frame_utils.format_duration
local format_date = frame_utils.format_date
local get_fps_float = frame_utils.get_fps_float

-- ============================================================================
-- Tree widget construction
-- ============================================================================

local function build_tree(ctx)
    local qt_constants = ctx.qt_constants
    local ui_constants = ctx.ui_constants

    local tree = qt_constants.WIDGET.CREATE_TREE()
    local disclosure_closed_icon = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><path fill='%238c8c8c' d='M3 2l4 3-4 3z'/></svg>"
    local disclosure_open_icon = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><path fill='%238c8c8c' d='M2 3l3 4 3-4z'/></svg>"

    local tree_style = string.format([[
        QTreeWidget {
            background: #262626;
            color: #cccccc;
            border: none;
            font-size: %s;
            outline: none;
        }
        QTreeWidget::item {
            padding: 2px;
            padding-left: 4px;
            height: 22px;
        }
        QTreeWidget::item:selected {
            background: #4a4a4a;
            color: white;
        }
        QTreeWidget::item:hover {
            background: #333333;
        }
        QTreeView::branch {
            background: #262626;
            border: none;
            width: 12px;
        }
        QTreeView::branch:has-children {
            background: #262626;
            border: none;
        }
        QTreeView::branch:has-children:!has-siblings:closed,
        QTreeView::branch:closed:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeView::branch:has-children:!has-siblings:open,
        QTreeView::branch:open:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeView::branch:open:has-children:selected,
        QTreeView::branch:closed:has-children:selected {
            image: url("%s");
        }
        QTreeWidget::branch {
            background: #262626;
            border: none;
            width: 12px;
        }
        QTreeWidget::branch:has-children {
            background: #262626;
            border: none;
        }
        QTreeWidget::branch:has-children:!has-siblings:closed,
        QTreeWidget::branch:closed:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeWidget::branch:has-children:!has-siblings:open,
        QTreeWidget::branch:open:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeWidget::branch:open:has-children:selected,
        QTreeWidget::branch:closed:has-children:selected {
            image: url("%s");
        }
        QHeaderView::section {
            background: #2b2b2b;
            color: #888;
            padding: 4px;
            border: none;
            border-right: 1px solid #1a1a1a;
            font-size: %s;
            font-weight: normal;
        }
    ]], ui_constants.FONTS.DEFAULT_FONT_SIZE,
        disclosure_closed_icon, disclosure_open_icon, disclosure_open_icon,
        disclosure_closed_icon, disclosure_open_icon, disclosure_open_icon,
        ui_constants.FONTS.DEFAULT_FONT_SIZE)
    qt_constants.PROPERTIES.SET_STYLE(tree, tree_style)

    qt_constants.CONTROL.SET_TREE_HEADERS(tree, {"Clip Name", "Duration", "Resolution", "FPS", "Codec", "Date Modified"})
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 0, 180)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 1, 80)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 2, 80)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 3, 50)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 4, 60)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 5, 100)

    qt_constants.CONTROL.SET_TREE_INDENTATION(tree, 12)
    if qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK then
        qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK(tree, true)
    end

    if qt_constants.CONTROL.SET_TREE_SELECTION_MODE then
        qt_constants.CONTROL.SET_TREE_SELECTION_MODE(tree, "extended")
    end

    return tree
end

-- ============================================================================
-- Tree data structures & lookup tables
-- ============================================================================

local function store_tree_item(ctx, tree, tree_id, info)
    if not tree_id or not info then
        return
    end
    info.tree_id = tree_id
    local qt_constants = ctx and ctx.qt_constants
    local ok, encoded = pcall(qt_json_encode, info)
    if ok and qt_constants and qt_constants.CONTROL.SET_TREE_ITEM_DATA then
        qt_constants.CONTROL.SET_TREE_ITEM_DATA(tree, tree_id, encoded)
    end
    local project_browser = ctx and ctx.project_browser
    if project_browser then
        project_browser.item_lookup[tostring(tree_id)] = info
    end
end

local function set_restoring_flag(ctx, value)
    if ctx and ctx.set_is_restoring_selection then
        ctx.set_is_restoring_selection(value)
    end
end

-- ============================================================================
-- Tree population & refresh logic
-- ============================================================================

function M.populate_tree(ctx)
    if not ctx then
        return
    end
    local project_browser = ctx.project_browser
    local qt_constants = ctx.qt_constants
    local browser_state = ctx.browser_state
    local tree = ctx.tree or (project_browser and project_browser.tree)
    if not project_browser or not qt_constants or not tree then
        return
    end

    local function record_previous_selection(target, item)
        if not item then
            return
        end
        if item.type == "timeline" and item.id then
            table.insert(target, {type = "timeline", id = item.id})
        elseif item.type == "master_clip" and item.clip_id then
            table.insert(target, {type = "master_clip", clip_id = item.clip_id})
        elseif item.type == "bin" and item.id then
            table.insert(target, {type = "bin", id = item.id})
        end
    end

    local previous_selection = nil
    if project_browser.selected_items and #project_browser.selected_items > 0 then
        previous_selection = {}
        for _, item in ipairs(project_browser.selected_items) do
            record_previous_selection(previous_selection, item)
        end
    elseif project_browser.selected_item then
        previous_selection = {}
        record_previous_selection(previous_selection, project_browser.selected_item)
    end

    qt_constants.CONTROL.CLEAR_TREE(tree)
    project_browser.item_lookup = {}
    project_browser.media_map = {}
    project_browser.master_clip_map = {}
    project_browser.sequence_map = {}
    project_browser.bin_map = {}
    project_browser.bin_tree_map = {}
    project_browser.bins = {}
    project_browser.selected_item = nil
    project_browser.selected_items = {}
    project_browser.pending_rename = nil
    project_browser.ignore_tree_item_change = false

    local project_id = project_browser.project_id or db.get_current_project_id()
    project_browser.project_id = project_id

    project_browser.media_bin_map = tag_service.list_master_clip_assignments(project_browser.project_id)

    local bins = tag_service.list(project_id)
    project_browser.bins = bins
    local media_items = db.load_media()
    local master_clips = db.load_master_clips(project_id)
    local sequences = db.load_sequences(project_id)

    project_browser.media_items = media_items
    project_browser.master_clips = master_clips
    for _, media in ipairs(media_items) do
        project_browser.media_map[media.id] = media
    end
    for _, clip in ipairs(master_clips) do
        if clip.media and clip.media.id and not project_browser.media_map[clip.media.id] then
            project_browser.media_map[clip.media.id] = clip.media
        elseif clip.media_id and project_browser.media_map[clip.media_id] and not clip.media then
            clip.media = project_browser.media_map[clip.media_id]
        end
        project_browser.master_clip_map[clip.clip_id] = clip
    end

    local bin_tree_map = {}
    local bin_lookup = {}
    for _, bin in ipairs(bins) do
        if bin.id then
            bin_lookup[bin.id] = bin
        end
    end

    local bin_path_cache = {}
    local function build_bin_path(bin)
        if not bin or not bin.id then
            return nil
        end
        if bin_path_cache[bin.id] then
            return bin_path_cache[bin.id]
        end

        local parent_id = bin.parent_id
        local path = bin.name
        if parent_id and parent_id ~= "" then
            local parent = bin_lookup[parent_id]
            local parent_path = parent and build_bin_path(parent) or nil
            if parent_path and parent_path ~= "" then
                path = parent_path .. "/" .. bin.name
            else
                bin.parent_id = nil
            end
        else
            bin.parent_id = nil
        end

        bin_path_cache[bin.id] = path
        return path
    end

    local bin_path_lookup = {}
    for _, bin in ipairs(bins) do
        local path = build_bin_path(bin)
        if path then
            bin_path_lookup[path] = bin.id
        end
        project_browser.bin_map[bin.id] = {
            id = bin.id,
            name = bin.name,
            parent_id = bin.parent_id
        }
    end

    local function add_bin(bin, parent_id)
        local display_name = bin.name
        local tree_id
        if parent_id then
            tree_id = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(tree, parent_id, {display_name, "", "", "", "", ""})
        else
            tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(tree, {display_name, "", "", "", "", ""})
        end
        store_tree_item(ctx, tree, tree_id, {
            type = "bin",
            id = bin.id,
            name = bin.name,
            parent_id = bin.parent_id
        })
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(tree, tree_id, "bin")
        end
        bin_tree_map[bin.id] = tree_id
        if project_browser.bin_map[bin.id] then
            project_browser.bin_map[bin.id].tree_id = tree_id
        end
        return tree_id
    end

    -- Root sequences
    for _, sequence in ipairs(sequences) do
        if not sequence.kind or sequence.kind == "timeline" then
            local duration_str = format_duration(sequence.duration, sequence.frame_rate)
            local resolution_str = (sequence.width and sequence.height and sequence.width > 0)
                and string.format("%dx%d", sequence.width, sequence.height)
                or ""

            local fps_val = get_fps_float(sequence.frame_rate)
            local fps_str = (fps_val > 0)
                and string.format("%.2f", fps_val)
                or ""

            local tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(tree, {
                sequence.name,
                duration_str,
                resolution_str,
                fps_str,
                "Timeline",
                ""
            })

            local sequence_info = {
                type = "timeline",
                id = sequence.id,
                project_id = sequence.project_id or project_id,
                name = sequence.name,
                frame_rate = sequence.frame_rate,
                width = sequence.width,
                height = sequence.height,
                duration = sequence.duration,
                tree_id = tree_id
            }

            store_tree_item(ctx, tree, tree_id, sequence_info)
            project_browser.sequence_map[sequence.id] = sequence_info
            if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
                qt_constants.CONTROL.SET_TREE_ITEM_ICON(tree, tree_id, "timeline")
            end
        end
    end

    -- Root bins
    for _, bin in ipairs(bins) do
        if not bin.parent_id then
            add_bin(bin, nil)
        end
    end

    -- Nested bins
    for _, bin in ipairs(bins) do
        if bin.parent_id and bin_tree_map[bin.parent_id] then
            add_bin(bin, bin_tree_map[bin.parent_id])
        end
    end

    local function get_bin_tag(media)
        if media.tags then
            for _, tag in ipairs(media.tags) do
                if tag.namespace == "bin" then
                    return tag.tag_path
                end
            end
        end
        return nil
    end

    local function add_master_clip_item(parent_id, clip)
        local media = clip.media or (clip.media_id and project_browser.media_map[clip.media_id]) or {}
        local duration_ms = clip.duration or media.duration
        local duration_str = format_duration(duration_ms, clip.frame_rate or (media and media.frame_rate))
        local display_width = clip.width or media.width
        local display_height = clip.height or media.height
        local display_fps = clip.frame_rate or (media and media.frame_rate)
        local resolution_str = (display_width and display_height and display_width > 0)
            and string.format("%dx%d", display_width, display_height)
            or ""

        local fps_val = get_fps_float(display_fps)
        local fps_str = (fps_val > 0)
            and string.format("%.2f", fps_val)
            or ""

        local codec_str = clip.codec or media.codec or ""
        local date_str = format_date(clip.modified_at or clip.created_at or media.modified_at or media.created_at)

        local columns = {
            clip.name or media.name or clip.clip_id,
            duration_str,
            resolution_str,
            fps_str,
            codec_str,
            date_str
        }

        local tree_id
        if parent_id then
            tree_id = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(tree, parent_id, columns)
        else
            tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(tree, columns)
        end

        store_tree_item(ctx, tree, tree_id, {
            type = "master_clip",
            clip_id = clip.clip_id,
            media_id = clip.media_id,
            sequence_id = clip.source_sequence_id,
            bin_id = clip.bin_id,
            name = clip.name or media.name or clip.clip_id,
            file_path = clip.file_path or media.file_path,
            duration = duration_ms,
            frame_rate = display_fps,
            width = display_width,
            height = display_height,
            codec = codec_str,
            metadata = media.metadata,
            offline = clip.offline
        })
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            local icon = clip.offline and "clip_offline" or "clip"
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(tree, tree_id, icon)
        end
        clip.tree_id = tree_id
    end

    -- Root master clips
    for _, clip in ipairs(master_clips) do
        local media = clip.media or (clip.media_id and project_browser.media_map[clip.media_id]) or {}
        local assigned_bin = nil
        if project_browser.media_bin_map then
            assigned_bin = project_browser.media_bin_map[clip.clip_id]
        end
        clip.bin_id = assigned_bin
        if not clip.bin_id then
            local bin_tag = get_bin_tag(media)
            if bin_tag then
                local derived_bin_id = bin_path_lookup[bin_tag]
                clip.bin_id = derived_bin_id
            end
        end
        if clip.bin_id then
            local parent_tree = bin_tree_map[clip.bin_id]
            if parent_tree then
                add_master_clip_item(parent_tree, clip)
            else
                clip.bin_id = nil
                add_master_clip_item(nil, clip)
            end
        else
            add_master_clip_item(nil, clip)
        end
    end

    local function restore_previous_selection_from_cache(previous)
        if not previous or #previous == 0 then
            if browser_state then
                browser_state.clear_selection()
            end
            return
        end

        local matches = {}
        for _, prev in ipairs(previous) do
            if prev.type == "timeline" then
                local seq = project_browser.sequence_map[prev.id]
                if seq and seq.tree_id then
                    local info = project_browser.item_lookup and project_browser.item_lookup[tostring(seq.tree_id)]
                    if info then
                        table.insert(matches, {tree_id = seq.tree_id, info = info})
                    end
                end
            elseif prev.type == "master_clip" then
                local clip = project_browser.master_clip_map[prev.clip_id]
                if clip and clip.tree_id then
                    local info = project_browser.item_lookup and project_browser.item_lookup[tostring(clip.tree_id)]
                    if info then
                        table.insert(matches, {tree_id = clip.tree_id, info = info})
                    end
                end
            elseif prev.type == "bin" then
                local bin = project_browser.bin_map[prev.id]
                if bin and bin.tree_id then
                    local info = project_browser.item_lookup and project_browser.item_lookup[tostring(bin.tree_id)]
                    if info then
                        table.insert(matches, {tree_id = bin.tree_id, info = info})
                    end
                end
            end
        end

        if #matches == 0 then
            if browser_state then
                browser_state.clear_selection()
            end
            return
        end

        if qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
            set_restoring_flag(ctx, true)
            local clear_previous = true
            for _, match in ipairs(matches) do
                qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(tree, match.tree_id, true, clear_previous)
                clear_previous = false
            end
            set_restoring_flag(ctx, false)

            if not project_browser.selected_items or #project_browser.selected_items == 0 then
                local collected = {}
                for _, match in ipairs(matches) do
                    table.insert(collected, match.info)
                end
                project_browser.selected_items = collected
                project_browser.selected_item = collected[1]
                if browser_state then
                    browser_state.update_selection(collected, {
                        master_lookup = project_browser.master_clip_map,
                        media_lookup = project_browser.media_map,
                        sequence_lookup = project_browser.sequence_map,
                        project_id = project_browser.project_id
                    })
                end
            end
        else
            local collected = {}
            for _, match in ipairs(matches) do
                table.insert(collected, match.info)
            end
            project_browser.selected_items = collected
            project_browser.selected_item = collected[1]
            if browser_state then
                browser_state.update_selection(collected, {
                    master_lookup = project_browser.master_clip_map,
                    media_lookup = project_browser.media_map,
                    sequence_lookup = project_browser.sequence_map,
                    project_id = project_browser.project_id
                })
            end
        end
    end

    restore_previous_selection_from_cache(previous_selection)

    project_browser.bin_tree_map = bin_tree_map
end

-- ============================================================================
-- Tree interaction handlers (key, drop, editor, selection)
-- ============================================================================

local function register_handlers(ctx, tree)
    local qt_constants = ctx.qt_constants
    local register_handler = ctx.register_handler
    if not register_handler or not qt_constants then
        return
    end
    local resolve_tree_item = ctx.resolve_tree_item
    local browser_state = ctx.browser_state
    local focus_manager = ctx.focus_manager
    local qt_set_focus = ctx.qt_set_focus
    local command_manager = ctx.command_manager
    local ACTIVATE_COMMAND = ctx.ACTIVATE_COMMAND
    local logger = ctx.logger
    local show_browser_context_menu = ctx.show_browser_context_menu
    local project_browser = ctx.project_browser

    local selection_handler = register_handler(function(event)
        local collected = {}

        if type(event) == "table" and type(event.items) == "table" then
            for _, entry in ipairs(event.items) do
                local info = resolve_tree_item(entry)
                if info then
                    table.insert(collected, info)
                end
            end
        end

        if #collected == 0 then
            local fallback = resolve_tree_item(event)
            if fallback then
                table.insert(collected, fallback)
            end
        end

        if project_browser then
            project_browser.selected_items = collected
            project_browser.selected_item = collected[1]
        end

        if project_browser and project_browser.pending_rename and qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE then
            local rename_tree_id = project_browser.pending_rename.tree_id
            local still_selected = false
            for _, info in ipairs(collected) do
                if info.tree_id == rename_tree_id then
                    still_selected = true
                    break
                end
            end

            if not still_selected then
                qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE(tree, rename_tree_id, false)
                project_browser.pending_rename = nil
            end
        end

        if browser_state and project_browser then
            browser_state.update_selection(collected, {
                master_lookup = project_browser.master_clip_map,
                media_lookup = project_browser.media_map,
                sequence_lookup = project_browser.sequence_map,
                project_id = project_browser.project_id
            })
        end

        local restoring_selection = false
        if ctx.is_restoring_selection then
            restoring_selection = ctx.is_restoring_selection()
        end
        if project_browser and not restoring_selection then
            if focus_manager and focus_manager.focus_panel then
                focus_manager.focus_panel("project_browser")
            else
                focus_manager.set_focused_panel("project_browser")
            end
            if qt_set_focus then
                pcall(qt_set_focus, tree)
            end
        end
    end)
    if qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER then
        qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER(tree, selection_handler)
    end

    local changed_handler = register_handler(function(event)
        if ctx.handle_tree_item_changed then
            ctx.handle_tree_item_changed(event)
        end
    end)
    if qt_constants.CONTROL.SET_TREE_ITEM_CHANGED_HANDLER then
        qt_constants.CONTROL.SET_TREE_ITEM_CHANGED_HANDLER(tree, changed_handler)
    end

    local close_handler = register_handler(function(event)
        if ctx.handle_tree_editor_closed then
            ctx.handle_tree_editor_closed(event)
        end
    end)
    if qt_constants.CONTROL.SET_TREE_CLOSE_EDITOR_HANDLER then
        qt_constants.CONTROL.SET_TREE_CLOSE_EDITOR_HANDLER(tree, close_handler)
    end

    local double_click_handler = register_handler(function(event)
        if not event then
            return
        end

        local item_info = resolve_tree_item(event)
        if not item_info and type(event) == "table" and type(event.items) == "table" then
            item_info = resolve_tree_item(event.items[1])
        end

        if not item_info or type(item_info) ~= "table" then
            return
        end

        if project_browser then
            project_browser.selected_item = item_info
        end
        local result = command_manager.execute(ACTIVATE_COMMAND)
        if not result.success then
            logger.warn("project_browser", "ActivateBrowserSelection failed: " .. tostring(result.error_message or "unknown error"))
        end
    end)
    if qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER then
        qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER(tree, double_click_handler)
    end

    if qt_constants.CONTROL.SET_CONTEXT_MENU_HANDLER then
        local context_handler = register_handler(function(evt)
            if show_browser_context_menu then
                show_browser_context_menu(evt)
            end
        end)
        qt_constants.CONTROL.SET_CONTEXT_MENU_HANDLER(tree, context_handler)
    end

    if qt_constants.CONTROL.SET_TREE_DRAG_DROP_MODE then
        qt_constants.CONTROL.SET_TREE_DRAG_DROP_MODE(tree, "internal")
    end
    if qt_constants.CONTROL.SET_TREE_DROP_HANDLER then
        local drop_handler = register_handler(function(evt)
            local ok, result = xpcall(function()
                if ctx.handle_tree_drop then
                    return ctx.handle_tree_drop(evt)
                end
                return false
            end, debug.traceback)
            if not ok then
                logger.error("project_browser", "Drop handler failed: " .. tostring(result))
                return false
            end
            return result and true or false
        end)
        qt_constants.CONTROL.SET_TREE_DROP_HANDLER(tree, drop_handler)
    end
    if qt_constants.CONTROL.SET_TREE_KEY_HANDLER then
        local key_handler = register_handler(function(evt)
            local ok, handled = xpcall(function()
                if ctx.handle_tree_key_event then
                    return ctx.handle_tree_key_event(evt)
                end
                return false
            end, debug.traceback)
            if not ok then
                logger.error("project_browser", "Key handler failed: " .. tostring(handled))
                return false
            end
            return handled and true or false
        end)
        qt_constants.CONTROL.SET_TREE_KEY_HANDLER(tree, key_handler)
    end

end

function M.lookup_item_by_tree_id(ctx, tree_id)
    if not tree_id or not ctx then
        return nil
    end
    local project_browser = ctx.project_browser
    if not project_browser or not project_browser.item_lookup then
        return nil
    end
    return project_browser.item_lookup[tostring(tree_id)]
end
M.store_tree_item = store_tree_item
-- ============================================================================
-- Public module API
-- ============================================================================

function M.create_tree(ctx)
    local tree = build_tree(ctx)
    register_handlers(ctx, tree)
    return tree
end

return M
