-- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style

local M = {}
local db = require("core.database")
local ui_constants = require("core.ui_constants")

-- Create project browser widget
function M.create()
    -- Create container
    local container = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()

    -- Set layout spacing
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 0)

    -- Create header with project name tab
    local header = qt_constants.WIDGET.CREATE()
    local header_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.LAYOUT.SET_ON_WIDGET(header, header_layout)

    qt_constants.PROPERTIES.SET_STYLE(header, [[
        QWidget {
            background: #2b2b2b;
            border-bottom: 1px solid #1a1a1a;
        }
    ]])

    -- Project name tab (active) - shows current project or "Unsaved"
    local project_tab = qt_constants.WIDGET.CREATE_LABEL("  Unsaved  ")
    qt_constants.PROPERTIES.SET_STYLE(project_tab, [[
        QLabel {
            background: #3a3a3a;
            color: white;
            padding: 6px 12px;
            font-size: 11px;
            border-top: 2px solid #4a90e2;
        }
    ]])
    qt_constants.LAYOUT.ADD_WIDGET(header_layout, project_tab)

    qt_constants.LAYOUT.ADD_STRETCH(header_layout, 1)
    qt_constants.LAYOUT.ADD_WIDGET(layout, header)

    -- Create tree widget for media library (Resolve style)
    local tree = qt_constants.WIDGET.CREATE_TREE()
    qt_constants.PROPERTIES.SET_STYLE(tree, [[
        QTreeWidget {
            background: #262626;
            color: #cccccc;
            border: none;
            font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
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
        QTreeWidget::branch {
            background: #262626;
            border: none;
        }
        QTreeWidget::branch:has-children {
            background: #262626;
            border: none;
            image: none;
        }
        QTreeWidget::branch:selected {
            background: #262626;
        }
        QTreeWidget::branch:has-children:selected {
            background: #262626;
        }
        QHeaderView::section {
            background: #2b2b2b;
            color: #888;
            padding: 4px;
            border: none;
            border-right: 1px solid #1a1a1a;
            font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
            font-weight: normal;
        }
    ]])

    -- Set tree columns (Resolve style: Clip Name, Date Created, Date Modified)
    qt_constants.CONTROL.SET_TREE_HEADERS(tree, {"Clip Name", "Date Created", "Date Modified"})
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 0, 150)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 1, 85)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 2, 85)

    -- Set minimal indentation like Premiere (just enough for nested items)
    qt_constants.CONTROL.SET_TREE_INDENTATION(tree, 12)

    -- Load bins and media from database
    local bins = db.load_bins()
    local media_items = db.load_media()
    print("Loading " .. #bins .. " bins and " .. #media_items .. " media items into project browser")

    -- Helper to get bin tag for a media item
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

    -- Build a map of bin_id -> tree_index for hierarchy
    local bin_tree_map = {}

    -- Helper function to add bins recursively
    local function add_bin_to_tree(bin, parent_tree_idx)
        local display_name = "▶ " .. bin.name
        local tree_idx

        if parent_tree_idx then
            -- Add as child of parent bin
            tree_idx = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(tree, parent_tree_idx, {display_name, "", ""})
        else
            -- Add as root level bin
            tree_idx = qt_constants.CONTROL.ADD_TREE_ITEM(tree, {display_name, "", ""})
        end

        bin_tree_map[bin.id] = tree_idx
        return tree_idx
    end

    -- First pass: Add all root level bins
    for _, bin in ipairs(bins) do
        if not bin.parent_id then
            add_bin_to_tree(bin, nil)
        end
    end

    -- Second pass: Add nested bins
    for _, bin in ipairs(bins) do
        if bin.parent_id and bin_tree_map[bin.parent_id] then
            add_bin_to_tree(bin, bin_tree_map[bin.parent_id])
        end
    end

    -- Add root level media (not in any bin)
    for _, media in ipairs(media_items) do
        local bin_tag = get_bin_tag(media)
        if not bin_tag then
            local date_str = "Mon Aug 22"  -- TODO: Get actual file date
            qt_constants.CONTROL.ADD_TREE_ITEM(tree, {
                media.file_name,
                date_str,
                date_str
            })
        end
    end

    -- Add media to their respective bins
    for _, media in ipairs(media_items) do
        local bin_tag = get_bin_tag(media)
        if bin_tag then
            -- Find the bin with matching tag path
            for _, bin in ipairs(bins) do
                -- Match the bin's full path (reconstruct from parent chain)
                local bin_path_parts = {}
                local current_bin = bin
                while current_bin do
                    table.insert(bin_path_parts, 1, current_bin.name)
                    -- Find parent
                    local parent = nil
                    if current_bin.parent_id then
                        for _, b in ipairs(bins) do
                            if b.id == current_bin.parent_id then
                                parent = b
                                break
                            end
                        end
                    end
                    current_bin = parent
                end
                local bin_path = table.concat(bin_path_parts, "/")

                if bin_path == bin_tag and bin_tree_map[bin.id] then
                    local date_str = "Mon Aug 22"  -- TODO: Get actual file date
                    qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(tree, bin_tree_map[bin.id], {
                        media.file_name,
                        date_str,
                        date_str
                    })
                    break
                end
            end
        end
    end

    qt_constants.LAYOUT.ADD_WIDGET(layout, tree)

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    -- Store references for later access
    M.tree = tree
    M.media_items = media_items

    print("✅ Project browser created with " .. #media_items .. " media items")

    return container
end

-- Get selected media item
function M.get_selected_media()
    if not M.tree then
        return nil
    end

    local selected_index = qt_constants.CONTROL.GET_TREE_SELECTED_INDEX(M.tree)
    if selected_index >= 0 and selected_index < #M.media_items then
        return M.media_items[selected_index + 1]  -- Lua is 1-indexed
    end

    return nil
end

-- Refresh media list from database
function M.refresh()
    if not M.tree then
        return
    end

    -- Clear existing items
    qt_constants.CONTROL.CLEAR_TREE(M.tree)

    -- Reload from database
    local bins = db.load_bins()
    M.media_items = db.load_media()

    -- Helper to get bin tag for a media item
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

    -- Build a map of bin_id -> tree_index for hierarchy
    local bin_tree_map = {}

    -- Helper function to add bins recursively
    local function add_bin_to_tree(bin, parent_tree_idx)
        local display_name = "▶ " .. bin.name
        local tree_idx

        if parent_tree_idx then
            tree_idx = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, parent_tree_idx, {display_name, "", ""})
        else
            tree_idx = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {display_name, "", ""})
        end

        bin_tree_map[bin.id] = tree_idx
        return tree_idx
    end

    -- Add root level bins
    for _, bin in ipairs(bins) do
        if not bin.parent_id then
            add_bin_to_tree(bin, nil)
        end
    end

    -- Add nested bins
    for _, bin in ipairs(bins) do
        if bin.parent_id and bin_tree_map[bin.parent_id] then
            add_bin_to_tree(bin, bin_tree_map[bin.parent_id])
        end
    end

    -- Add root level media
    for _, media in ipairs(M.media_items) do
        local bin_tag = get_bin_tag(media)
        if not bin_tag then
            local date_str = "Mon Aug 22"
            qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {
                media.file_name,
                date_str,
                date_str
            })
        end
    end

    -- Add media to bins
    for _, media in ipairs(M.media_items) do
        local bin_tag = get_bin_tag(media)
        if bin_tag then
            -- Find the bin with matching tag path
            for _, bin in ipairs(bins) do
                -- Match the bin's full path (reconstruct from parent chain)
                local bin_path_parts = {}
                local current_bin = bin
                while current_bin do
                    table.insert(bin_path_parts, 1, current_bin.name)
                    -- Find parent
                    local parent = nil
                    if current_bin.parent_id then
                        for _, b in ipairs(bins) do
                            if b.id == current_bin.parent_id then
                                parent = b
                                break
                            end
                        end
                    end
                    current_bin = parent
                end
                local bin_path = table.concat(bin_path_parts, "/")

                if bin_path == bin_tag and bin_tree_map[bin.id] then
                    local date_str = "Mon Aug 22"
                    qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, bin_tree_map[bin.id], {
                        media.file_name,
                        date_str,
                        date_str
                    })
                    break
                end
            end
        end
    end

    print("✅ Project browser refreshed with " .. #bins .. " bins and " .. #M.media_items .. " media items")
end

return M
