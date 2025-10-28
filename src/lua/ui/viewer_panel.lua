-- Viewer Panel Module
-- Provides simple Source/Timeline viewer placeholder that other systems can update.

local qt_constants = require("core.qt_constants")
local frame_utils = require("core.frame_utils")
local ui_constants = require("core.ui_constants")

local M = {}

local viewer_widget = nil
local title_label = nil
local content_label = nil

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
    return string.format("%d ms", media.duration)
end

local function render_text(lines)
    ensure_created()
    local PROP = qt_constants.PROPERTIES
    local text = table.concat(lines, "\n")
    if PROP.SET_TEXT then
        PROP.SET_TEXT(content_label, text)
    end
end

function M.create()
    if viewer_widget then
        return viewer_widget
    end

    viewer_widget = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()

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

    content_label = qt_constants.WIDGET.CREATE_LABEL(DEFAULT_MESSAGE)
    qt_constants.PROPERTIES.SET_STYLE(content_label, string.format([[
        QLabel {
            background: #000000;
            color: %s;
            padding: 16px;
            font-size: 13px;
        }
    ]], ui_constants.COLORS and (ui_constants.COLORS.TEXT_PRIMARY or "#d0d0d0") or "#d0d0d0"))
    if qt_constants.PROPERTIES.SET_ALIGNMENT then
        qt_constants.PROPERTIES.SET_ALIGNMENT(content_label, qt_constants.PROPERTIES.ALIGN_TOP)
    end
    if qt_constants.PROPERTIES.SET_WORD_WRAP then
        qt_constants.PROPERTIES.SET_WORD_WRAP(content_label, true)
    end
    qt_constants.LAYOUT.ADD_WIDGET(layout, content_label)

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

    if media.file_path and media.file_path ~= "" then
        table.insert(lines, "")
        table.insert(lines, media.file_path)
    end

    render_text(lines)
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
end

return M

