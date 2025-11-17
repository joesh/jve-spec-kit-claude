-- Viewer Panel Module
-- Provides simple Source/Timeline viewer placeholder that other systems can update.

local qt_constants = require("core.qt_constants")
local frame_utils = require("core.frame_utils")
local ui_constants = require("core.ui_constants")
local selection_hub = require("ui.selection_hub")
local json = require("dkjson")
local inspectable_factory = require("inspectable")

local M = {}

local viewer_widget = nil
local title_label = nil
local content_label = nil
local content_container = nil

local DEFAULT_MESSAGE = "Double-click a clip in the Project Browser to load it here."

local function ensure_created()
    if not viewer_widget then
        error("viewer_panel: create() must be called before using viewer functions")
    end
end

local function format_resolution(media)
    if media.width and media.height and media.width > 0 and media.height > 0 then
        return string.format("%dx%d", media.width, media.height)
    end
    return nil
end

local function format_duration(media)
    if not media.duration or media.duration <= 0 then
        return nil
    end
    local frame_rate = media.frame_rate or frame_utils.default_frame_rate
    local ok, result = pcall(frame_utils.format_timecode, media.duration, frame_rate)
    if ok and result then
        return result
    end
    local fallback_ok, fallback = pcall(frame_utils.format_timecode, media.duration or 0, frame_utils.default_frame_rate)
    if fallback_ok and fallback then
        return fallback
    end
    return "00:00:00:00"
end

local function render_text(lines)
    ensure_created()
    local PROP = qt_constants.PROPERTIES
    local text = table.concat(lines, "\n")
    if PROP.SET_TEXT then
        PROP.SET_TEXT(content_label, text)
    end
end

local function soft_wrap_path(path)
    if not path or path == "" then
        return nil
    end
    -- Insert zero-width break opportunities after path separators so QLabel can wrap
    local zwsp = utf8 and utf8.char(0x200B) or "\226\128\139"  -- U+200B ZERO WIDTH SPACE
    return path:gsub("/", "/" .. zwsp)
end

local function normalize_metadata(meta)
    if not meta or meta == "" then
        return {}
    end
    if type(meta) == "table" then
        return meta
    end
    if type(meta) == "string" then
        local ok, decoded = pcall(json.decode, meta)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end
    return {}
end

function M.create()
    if viewer_widget then
        return viewer_widget
    end

    viewer_widget = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    if qt_constants.LAYOUT.SET_SPACING then
        pcall(qt_constants.LAYOUT.SET_SPACING, layout, 0)
    end
    if qt_constants.LAYOUT.SET_MARGINS then
        pcall(qt_constants.LAYOUT.SET_MARGINS, layout, 0, 0, 0, 0)
    end

    title_label = qt_constants.WIDGET.CREATE_LABEL("Source Viewer")
    qt_constants.PROPERTIES.SET_STYLE(title_label, [[
        QLabel {
            background: #3a3a3a;
            color: white;
            padding: 4px;
            font-size: 12px;
        }
    ]])
    qt_constants.LAYOUT.ADD_WIDGET(layout, title_label)

    content_container = qt_constants.WIDGET.CREATE()
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, content_container, "Expanding", "Expanding")
    end
    if qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_STYLE then
        qt_constants.PROPERTIES.SET_STYLE(content_container, [[
            QWidget {
                background: #000000;
                border: 1px solid #1f1f1f;
            }
        ]])
    end

    local content_layout = qt_constants.LAYOUT.CREATE_VBOX()
    if qt_constants.LAYOUT.SET_MARGINS then
        pcall(qt_constants.LAYOUT.SET_MARGINS, content_layout, 0, 0, 0, 0)
    end
    if qt_constants.LAYOUT.SET_SPACING then
        pcall(qt_constants.LAYOUT.SET_SPACING, content_layout, 0)
    end

    content_label = qt_constants.WIDGET.CREATE_LABEL(DEFAULT_MESSAGE)
    qt_constants.PROPERTIES.SET_STYLE(content_label, string.format([[
        QLabel {
            background: transparent;
            color: %s;
            padding: 16px;
            font-size: 13px;
        }
    ]], ui_constants.COLORS and (ui_constants.COLORS.TEXT_PRIMARY or "#d0d0d0") or "#d0d0d0"))
    if qt_constants.PROPERTIES.SET_ALIGNMENT then
        qt_constants.PROPERTIES.SET_ALIGNMENT(content_label, qt_constants.PROPERTIES.ALIGN_CENTER)
    end
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        -- Expand to fill the viewer area while keeping text centered
        pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, content_label, "Expanding", "Expanding")
    end
    if qt_constants.PROPERTIES.SET_MINIMUM_WIDTH then
        pcall(qt_constants.PROPERTIES.SET_MINIMUM_WIDTH, content_label, 0)
    end
    if qt_constants.PROPERTIES.SET_WORD_WRAP then
        qt_constants.PROPERTIES.SET_WORD_WRAP(content_label, true)
    end
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, content_label)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, content_layout, content_label, 1)
    end

    qt_constants.LAYOUT.SET_ON_WIDGET(content_container, content_layout)
    qt_constants.LAYOUT.ADD_WIDGET(layout, content_container)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, layout, content_container, 1)
    end

    qt_constants.LAYOUT.SET_ON_WIDGET(viewer_widget, layout)

    return viewer_widget
end

function M.get_widget()
    ensure_created()
    return viewer_widget
end

function M.get_title_widget()
    ensure_created()
    return title_label
end

function M.clear()
    ensure_created()
    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(content_label, DEFAULT_MESSAGE)
    end
    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Source Viewer")
    end
    selection_hub.update_selection("viewer", {})
end

function M.show_source_clip(media)
    ensure_created()
    if not media then
        M.clear()
        return
    end

    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Source Viewer")
    end

    local lines = {}
    table.insert(lines, string.format("Clip: %s", media.name or media.file_name or media.id or "Untitled"))

    local duration = format_duration(media)
    if duration then
        table.insert(lines, "Duration: " .. duration)
    end

    local resolution = format_resolution(media)
    if resolution then
        table.insert(lines, "Resolution: " .. resolution)
    end

    if media.frame_rate and media.frame_rate > 0 then
        table.insert(lines, string.format("Frame Rate: %.2f fps", media.frame_rate))
    end

    if media.codec and media.codec ~= "" then
        table.insert(lines, "Codec: " .. media.codec)
    end

    local wrapped_path = soft_wrap_path(media.file_path)
    if wrapped_path and wrapped_path ~= "" then
        table.insert(lines, "")
        table.insert(lines, wrapped_path)
    end

    render_text(lines)

    local inspectable = nil
    if media.clip_id or media.id then
        local ok, clip_inspectable = pcall(inspectable_factory.clip, {
            clip_id = media.clip_id or media.id,
            project_id = media.project_id,
            clip = media
        })
        if ok then
            inspectable = clip_inspectable
        end
    end

    selection_hub.update_selection("viewer", {{
        item_type = "viewer_media",
        id = media.id,
        media_id = media.id,
        name = media.name or media.file_name or media.id or "Untitled",
        duration = media.duration,
        frame_rate = media.frame_rate,
        width = media.width,
        height = media.height,
        codec = media.codec,
        file_path = media.file_path,
        metadata = normalize_metadata(media.metadata),
        project_id = media.project_id,
        inspectable = inspectable,
        schema = inspectable and inspectable:get_schema_id() or nil,
        display_name = media.name or media.file_name or media.id or "Untitled"
    }})
end

function M.show_timeline(sequence)
    ensure_created()
    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Timeline Viewer")
    end

    if not sequence then
        render_text({"No timeline loaded."})
        return
    end

    local lines = {}
    table.insert(lines, string.format("Timeline: %s", sequence.name or sequence.id or "Untitled"))

    if sequence.frame_rate and sequence.frame_rate > 0 then
        table.insert(lines, string.format("Frame Rate: %.2f fps", sequence.frame_rate))
    end

    if sequence.width and sequence.height and sequence.width > 0 and sequence.height > 0 then
        table.insert(lines, string.format("Resolution: %dx%d", sequence.width, sequence.height))
    end

    render_text(lines)

    if sequence then
        local inspectable = nil
        local ok, seq_inspectable = pcall(inspectable_factory.sequence, {
            sequence_id = sequence.id,
            project_id = sequence.project_id,
            sequence = sequence
        })
        if ok then
            inspectable = seq_inspectable
        end

        selection_hub.update_selection("viewer", {{
            item_type = "viewer_timeline",
            id = sequence.id,
            name = sequence.name or sequence.id or "Untitled",
            duration = sequence.duration,
            frame_rate = sequence.frame_rate,
            width = sequence.width,
            height = sequence.height,
            inspectable = inspectable,
            schema = inspectable and inspectable:get_schema_id() or nil,
            display_name = sequence.name or sequence.id or "Untitled",
            project_id = sequence.project_id
        }})
    else
        selection_hub.update_selection("viewer", {})
    end
end

return M
