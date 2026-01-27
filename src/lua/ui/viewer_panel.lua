--- Viewer Panel Module
--
-- Responsibilities:
-- - Displays video frames via GPUVideoSurface
-- - Manages source clip viewing
-- - Coordinates with media_cache for frame access
--
-- Non-goals:
-- - Does not own EMP resources (delegated to media_cache)
-- - Does not handle playback timing (delegated to playback_controller)
--
-- @file viewer_panel.lua

local qt_constants = require("core.qt_constants")
local selection_hub = require("ui.selection_hub")
local json = require("dkjson")
local inspectable_factory = require("inspectable")
local logger = require("core.logger")
local media_cache = require("ui.media_cache")
local audio_playback = require("ui.audio_playback")
local playback_controller = require("ui.playback_controller")

local M = {}

local viewer_widget = nil
local title_label = nil
local content_container = nil
local video_surface = nil      -- GPUVideoSurface for video display

-- Current display state (frame comes from media_cache, we just track index)
local current_frame_idx = 0

-- Clean up resources
local function cleanup()
    -- Shutdown audio playback first
    if audio_playback.initialized then
        audio_playback.shutdown()
    end

    -- Unload media cache (releases all EMP resources)
    media_cache.unload()

    current_frame_idx = 0
end

-- Load and display a video frame from file path
-- Asserts on failure - no fallbacks
local function load_video_frame(file_path)
    assert(qt_constants.EMP, "viewer_panel.load_video_frame: EMP bindings not available")
    assert(video_surface, "viewer_panel.load_video_frame: video_surface not created")

    -- Clean up previous resources
    cleanup()

    -- Load via media_cache (opens dual assets for video/audio isolation)
    local info = media_cache.load(file_path)

    -- Get and display frame 0
    local frame = media_cache.get_video_frame(0)
    qt_constants.EMP.SURFACE_SET_FRAME(video_surface, frame)
    current_frame_idx = 0

    logger.info("viewer_panel", string.format("Loaded video: %dx%d @ %d/%d fps",
        info.width, info.height, info.fps_num, info.fps_den))

    -- Initialize audio playback if asset has audio
    if info.has_audio and qt_constants.SSE and qt_constants.AOP then
        local ok, err = audio_playback.init(media_cache)
        if ok then
            -- Wire playback_controller to audio
            playback_controller.init_audio(audio_playback)
            logger.info("viewer_panel", string.format("Audio initialized: %dHz %dch",
                info.audio_sample_rate, info.audio_channels))
        else
            logger.warn("viewer_panel", "Failed to initialize audio: " .. tostring(err))
        end
    end

    -- Set playback source (frame count and rational fps)
    local total_frames = math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
    playback_controller.set_source(total_frames, info.fps_num, info.fps_den)

    return info
end

-- Clear video surface
local function clear_video_surface()
    cleanup()
    if video_surface and qt_constants.EMP and qt_constants.EMP.SURFACE_SET_FRAME then
        qt_constants.EMP.SURFACE_SET_FRAME(video_surface, nil)
    end
end

local function ensure_created()
    if not viewer_widget then
        error("viewer_panel: create() must be called before using viewer functions")
    end
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

    -- Create GPU video surface (hw accelerated)
    -- No fallback to CPU - assert on failure during development
    assert(qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE,
           "viewer_panel.create: CREATE_GPU_VIDEO_SURFACE not available")
    video_surface = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
    assert(video_surface, "viewer_panel.create: CREATE_GPU_VIDEO_SURFACE returned nil")
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, video_surface, "Expanding", "Expanding")
    end
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, video_surface)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, content_layout, video_surface, 1)
    end
    logger.info("viewer_panel", "Video surface created for frame display")

    -- Initialize playback controller with this viewer panel
    playback_controller.init(M)

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
    clear_video_surface()
    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Source Viewer")
    end
    selection_hub.update_selection("viewer", {})
end

function M.show_source_clip(media)
    ensure_created()
    assert(media, "viewer_panel.show_source_clip: media is nil")
    assert(media.file_path, "viewer_panel.show_source_clip: media.file_path is nil")

    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Source Viewer")
    end

    -- Load and display video frame (asserts on failure)
    load_video_frame(media.file_path)

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

-- Display a specific frame by index (for playback scrubbing)
-- Frame comes from media_cache (cache owns the frame, we just display it)
function M.show_frame(frame_idx)
    assert(media_cache.is_loaded(), "viewer_panel.show_frame: no media loaded")
    assert(frame_idx, "viewer_panel.show_frame: frame_idx is nil")
    assert(frame_idx >= 0, string.format(
        "viewer_panel.show_frame: frame_idx must be >= 0, got %d", frame_idx))

    -- Get frame from cache (cache handles decode and lifecycle)
    local frame = media_cache.get_video_frame(frame_idx)

    current_frame_idx = frame_idx
    qt_constants.EMP.SURFACE_SET_FRAME(video_surface, frame)
end

-- Get current asset info (for playback controller)
function M.get_asset_info()
    return media_cache.get_asset_info()
end

-- Get total frame count of current media
-- Computed from duration_us and fps
function M.get_total_frames()
    local info = media_cache.get_asset_info()
    if not info then return 0 end
    if not info.duration_us or info.fps_den == 0 then return 0 end
    return math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
end

-- Get fps of current media
function M.get_fps()
    local info = media_cache.get_asset_info()
    if not info then return 0 end
    if info.fps_den == 0 then return 0 end
    return info.fps_num / info.fps_den
end

-- Get current frame index
function M.get_current_frame()
    return current_frame_idx
end

-- Check if media is loaded
function M.has_media()
    return media_cache.is_loaded()
end

function M.show_timeline(sequence)
    ensure_created()
    assert(sequence, "viewer_panel.show_timeline: sequence is nil")

    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Timeline Viewer")
    end

    -- TODO: Timeline viewer should decode frame at playhead from sequence clips
    -- For now, just clear the surface and update selection
    clear_video_surface()

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
