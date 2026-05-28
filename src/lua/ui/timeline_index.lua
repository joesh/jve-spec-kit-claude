--- Timeline index dialog: sortable table of all clips in the active timeline.
--
-- Blocking modal showing clip data in a tree widget with filter bar.
-- Row click navigates to clip via opts.on_navigate callback.
--
-- @file timeline_index.lua

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")

local M = {}

local TEXT_OPERATORS = {"contains", "begins_with", "ends_with", "matches_exactly"}
local NUMERIC_OPERATORS = {"equals", "greater_than", "less_than"}

local function get_field_names()
    local fields = query_engine.get_searchable_fields()
    local names = {}
    for _, f in ipairs(fields) do
        names[#names + 1] = f.name
    end
    return names
end

local function get_operators_for_field(field_name)
    local fields = query_engine.get_searchable_fields()
    for _, f in ipairs(fields) do
        if f.name == field_name then
            if f.type == "numeric" or f.type == "boolean" then
                return NUMERIC_OPERATORS
            end
            return TEXT_OPERATORS
        end
    end
    return TEXT_OPERATORS
end

local function matches_filter(clip, column, operator, value)
    -- Map column to clip field
    local field_map = {
        Name = "name",
        Track = "track_id",
        Duration = "duration_frames",
    }
    local field_key = field_map[column] or "name"
    local clip_value = tostring(clip[field_key] or "")

    if operator == "contains" then
        return clip_value:lower():find(value:lower(), 1, true) ~= nil
    elseif operator == "begins_with" then
        return clip_value:lower():sub(1, #value) == value:lower()
    elseif operator == "ends_with" then
        return clip_value:lower():sub(-#value) == value:lower()
    elseif operator == "matches_exactly" then
        return clip_value:lower() == value:lower()
    elseif operator == "equals" then
        return tonumber(clip_value) == tonumber(value)
    elseif operator == "greater_than" then
        return (tonumber(clip_value) or 0) > (tonumber(value) or 0)
    elseif operator == "less_than" then
        return (tonumber(clip_value) or 0) < (tonumber(value) or 0)
    end
    return true
end

local function populate_tree(tree, clips, filter_column, filter_operator, filter_value)
    qt.CONTROL.CLEAR_TREE(tree)
    local displayed = {}
    local idx = 0
    for _, clip in ipairs(clips) do
        local show = true
        if filter_value and filter_value ~= "" then
            show = matches_filter(clip, filter_column, filter_operator, filter_value)
        end
        if show then
            idx = idx + 1
            -- All clip columns below are schema NOT NULL (see schema.sql:
            -- name, track_id, source_in_frame, source_out_frame,
            -- sequence_start_frame, duration_frames). Asserting here means
            -- a missing field is a contract violation upstream, not a 0/""
            -- that we silently render in the index dialog.
            assert(clip.name, "timeline_index: clip.name missing (NOT NULL)")
            assert(clip.track_id, "timeline_index: clip.track_id missing (NOT NULL)")
            assert(clip.source_in_frame, "timeline_index: clip.source_in_frame missing (NOT NULL)")
            assert(clip.source_out_frame, "timeline_index: clip.source_out_frame missing (NOT NULL)")
            assert(clip.sequence_start_frame, "timeline_index: clip.sequence_start_frame missing (NOT NULL)")
            assert(clip.duration_frames, "timeline_index: clip.duration_frames missing (NOT NULL)")
            qt.CONTROL.ADD_TREE_ITEM(tree, {
                tostring(idx),
                clip.name,
                clip.track_id,
                tostring(clip.source_in_frame),
                tostring(clip.source_out_frame),
                tostring(clip.sequence_start_frame),
                tostring(clip.sequence_start_frame + clip.duration_frames),
                tostring(clip.duration_frames),
            })
            displayed[idx] = clip
        end
    end
    return displayed
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Show the timeline index dialog (blocking).
-- @param opts table {clips=array_of_clip_data, on_navigate=fn(clip_id, sequence_start_frame)}
-- @return nil
function M.show(opts)
    assert(opts, "timeline_index.show: opts required")
    assert(opts.clips, "timeline_index.show: clips required")

    local clips = opts.clips
    local globals = {}

    local dialog = qt.DIALOG.CREATE("Timeline Index", 800, 500, nil)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- Filter bar
    local filter_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(filter_row, qt.WIDGET.CREATE_LABEL("Filter:"))

    local filter_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(filter_edit, "Filter value...")
    qt.LAYOUT.ADD_WIDGET(filter_row, filter_edit)

    local attr_combo = qt.WIDGET.CREATE_COMBOBOX()
    local field_names = get_field_names()
    for _, name in ipairs(field_names) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(attr_combo, name)
    end
    qt.LAYOUT.ADD_WIDGET(filter_row, attr_combo)

    local op_combo = qt.WIDGET.CREATE_COMBOBOX()
    local current_field = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
    local ops = get_operators_for_field(current_field)
    for _, op in ipairs(ops) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(op_combo, op)
    end
    qt.LAYOUT.ADD_WIDGET(filter_row, op_combo)

    local apply_btn = qt.WIDGET.CREATE_BUTTON("Apply")
    qt.LAYOUT.ADD_WIDGET(filter_row, apply_btn)

    local clear_btn = qt.WIDGET.CREATE_BUTTON("Clear")
    qt.LAYOUT.ADD_WIDGET(filter_row, clear_btn)

    qt.LAYOUT.ADD_LAYOUT(main_layout, filter_row)

    -- Tree widget
    local tree = qt.WIDGET.CREATE_TREE()
    qt.CONTROL.SET_TREE_HEADERS(tree, {"#", "Clip Name", "Track", "Source In", "Source Out", "Record In", "Record Out", "Duration"})
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 0, 40)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 1, 200)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 2, 60)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 3, 80)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 4, 80)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 5, 80)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 6, 80)
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 7, 80)
    qt.LAYOUT.ADD_WIDGET(main_layout, tree)

    -- Initial population
    local displayed = populate_tree(tree, clips, nil, nil, nil)

    -- Selection handler — navigate on row click
    local select_name = "__timeline_index_select"
    _G[select_name] = function(row_index)
        if opts.on_navigate and displayed[row_index] then
            local clip = displayed[row_index]
            opts.on_navigate(clip.id, clip.sequence_start_frame)
        end
    end
    qt.CONTROL.SET_TREE_SELECTION_HANDLER(tree, select_name)
    globals[#globals + 1] = select_name

    -- Apply filter handler
    local apply_name = "__timeline_index_apply"
    _G[apply_name] = function()
        local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
        local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(op_combo)
        local value = qt.PROPERTIES.GET_TEXT(filter_edit)
        displayed = populate_tree(tree, clips, column, operator, value)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(apply_btn, apply_name)
    globals[#globals + 1] = apply_name

    -- Clear filter handler
    local clear_name = "__timeline_index_clear"
    _G[clear_name] = function()
        qt.PROPERTIES.SET_TEXT(filter_edit, "")
        displayed = populate_tree(tree, clips, nil, nil, nil)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(clear_btn, clear_name)
    globals[#globals + 1] = clear_name

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- Close button
    local button_box = qt.CONTROL.CREATE_BUTTON_BOX()
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "Close", "reject")
    qt.LAYOUT.ADD_WIDGET(main_layout, button_box)

    local close_name = "__timeline_index_close"
    _G[close_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "rejected", close_name)
    globals[#globals + 1] = close_name

    -- Show (blocking)
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    qt.DIALOG.SHOW(dialog)

    -- Cleanup
    for _, gname in ipairs(globals) do
        _G[gname] = nil
    end

    return nil
end

return M
