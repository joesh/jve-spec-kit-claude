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
local media_cache = require("core.media.media_cache")
local playback_controller = require("core.playback.playback_controller")
local source_viewer_state = require("ui.source_viewer_state")
local source_mark_bar = require("ui.source_mark_bar")

-- Media cache context ID (Phase 3 splits into per-instance IDs)
local VIEW_CTX = "view"

local M = {}

-- DEBUG: skip video decode+display to isolate audio debugging
local SKIP_VIDEO = false

local viewer_widget = nil
local title_label = nil
local content_container = nil
local video_surface = nil      -- GPUVideoSurface for video display
-- Current display state (frame comes from media_cache, we just track index)
local current_frame_idx = 0

-- Clean up resources
local function cleanup()
    -- Shutdown audio session via controller (owns audio lifecycle)
    playback_controller.shutdown_audio_session()

    -- Unload media cache (releases all EMP resources)
    media_cache.unload(VIEW_CTX)

    current_frame_idx = 0
end

-- Load and display a video frame from file path
-- Asserts on failure - no fallbacks
local function load_video_frame(file_path)
    assert(qt_constants.EMP, "viewer_panel.load_video_frame: EMP bindings not available")
    assert(video_surface, "viewer_panel.load_video_frame: video_surface not created")

    -- Clean up previous resources
    cleanup()

    -- Activate via media_cache pool (opens dual assets, or pool-hit if cached)
    local info = media_cache.activate(file_path, VIEW_CTX)

    -- Apply rotation from media metadata (phone footage portrait/landscape)
    if qt_constants.EMP.SURFACE_SET_ROTATION then
        qt_constants.EMP.SURFACE_SET_ROTATION(video_surface, info.rotation or 0)
    end

    -- Get and display frame 0
    if not SKIP_VIDEO then
        local frame = media_cache.get_video_frame(0, VIEW_CTX)
        qt_constants.EMP.SURFACE_SET_FRAME(video_surface, frame)
    end
    current_frame_idx = 0

    logger.info("viewer_panel", string.format("Loaded video: %dx%d @ %d/%d fps",
        info.width, info.height, info.fps_num, info.fps_den))

    -- Set playback source (frame count and rational fps)
    local total_frames = math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
    playback_controller.set_source(total_frames, info.fps_num, info.fps_den)

    return info
end

-- Clear video surface
local function clear_video_surface()
    cleanup()
    if video_surface and qt_constants.EMP then
        if qt_constants.EMP.SURFACE_SET_ROTATION then
            qt_constants.EMP.SURFACE_SET_ROTATION(video_surface, 0)
        end
        if qt_constants.EMP.SURFACE_SET_FRAME then
            qt_constants.EMP.SURFACE_SET_FRAME(video_surface, nil)
        end
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

    -- Create source mark bar below video surface (ScriptableTimeline widget)
    assert(qt_constants.WIDGET.CREATE_TIMELINE,
           "viewer_panel.create: CREATE_TIMELINE not available")
    local mark_bar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    assert(mark_bar_widget, "viewer_panel.create: CREATE_TIMELINE returned nil")
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(mark_bar_widget, "Expanding", "Fixed")
    timeline.set_desired_height(mark_bar_widget, source_mark_bar.BAR_HEIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, mark_bar_widget)
    source_mark_bar.create(mark_bar_widget)
    logger.info("viewer_panel", "Source mark bar created")

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
    source_viewer_state.unload()
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

    -- Exit timeline mode so playback/stepping drives source, not timeline
    playback_controller.stop()
    playback_controller.set_timeline_mode(false)

    -- Load and display video frame (asserts on failure)
    local info = load_video_frame(media.file_path)

    -- Load per-masterclip marks/playhead from DB into source_viewer_state
    -- sequence_id is the masterclip sequence (IS-a model: masterclip IS a sequence)
    local sequence_id = media.sequence_id or media.masterclip_sequence_id or media.id
    logger.info("viewer_panel", string.format("show_source_clip: sequence_id=%s, info=%s",
        tostring(sequence_id), tostring(info ~= nil)))
    if sequence_id and info then
        local total_frames = math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
        logger.info("viewer_panel", string.format("show_source_clip: total_frames=%d", total_frames))
        if total_frames > 0 then
            source_viewer_state.load_masterclip(sequence_id, total_frames, info.fps_num, info.fps_den)
            logger.info("viewer_panel", string.format("show_source_clip: loaded, has_clip=%s",
                tostring(source_viewer_state.has_clip())))

            -- Seek to restored playhead position
            local restored_playhead = source_viewer_state.playhead
            if restored_playhead > 0 then
                playback_controller.set_position(restored_playhead)
            end
        end
    end

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
    assert(media_cache.is_loaded(VIEW_CTX), "viewer_panel.show_frame: no media loaded")
    assert(frame_idx, "viewer_panel.show_frame: frame_idx is nil")
    assert(frame_idx >= 0, string.format(
        "viewer_panel.show_frame: frame_idx must be >= 0, got %d", frame_idx))

    if not SKIP_VIDEO then
        -- Get frame from cache (cache handles decode and lifecycle)
        local frame = media_cache.get_video_frame(frame_idx, VIEW_CTX)
        qt_constants.EMP.SURFACE_SET_FRAME(video_surface, frame)
    end
    current_frame_idx = frame_idx
end

-- Get current asset info (for playback controller)
function M.get_asset_info()
    return media_cache.get_asset_info(VIEW_CTX)
end

-- Get total frame count of current media
-- Computed from duration_us and fps
function M.get_total_frames()
    local info = media_cache.get_asset_info(VIEW_CTX)
    if not info then return 0 end
    if not info.duration_us or info.fps_den == 0 then return 0 end
    return math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
end

-- Get fps of current media
function M.get_fps()
    local info = media_cache.get_asset_info(VIEW_CTX)
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
    return media_cache.is_loaded(VIEW_CTX)
end

function M.show_timeline(sequence)
    ensure_created()
    assert(sequence, "viewer_panel.show_timeline: sequence is nil")

    -- Save current source clip state before switching to timeline
    if source_viewer_state.has_clip() then
        source_viewer_state.save_playhead_to_db()
    end

    if qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(title_label, "Timeline Viewer")
    end

    -- Don't clear the video surface — the playhead listener in timeline_panel
    -- will resolve and display the correct frame via resolve_and_display().
    -- Clearing here would cause a black flash before the listener fires.

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

--------------------------------------------------------------------------------
-- Timeline Playback Mode Functions
--------------------------------------------------------------------------------

--- Show frame at a specific source time (microseconds)
-- Used for timeline playback to show the correct source position
-- @param source_time_us number: Source time in microseconds
function M.show_frame_at_time(source_time_us)
    assert(media_cache.is_loaded(VIEW_CTX), "viewer_panel.show_frame_at_time: no media loaded")
    assert(source_time_us ~= nil, "viewer_panel.show_frame_at_time: source_time_us is nil")
    assert(source_time_us >= 0, string.format(
        "viewer_panel.show_frame_at_time: source_time_us must be >= 0, got %d", source_time_us))

    -- Convert time to frame index using media info
    local info = media_cache.get_asset_info(VIEW_CTX)
    assert(info and info.fps_num and info.fps_den and info.fps_den > 0,
        "viewer_panel.show_frame_at_time: invalid media info")

    local frame_idx = math.floor(source_time_us * info.fps_num / info.fps_den / 1000000)

    -- Clamp to valid range
    local total_frames = math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
    frame_idx = math.max(0, math.min(frame_idx, total_frames - 1))

    -- Get and display frame
    if not SKIP_VIDEO then
        local frame = media_cache.get_video_frame(frame_idx, VIEW_CTX)
        qt_constants.EMP.SURFACE_SET_FRAME(video_surface, frame)
    end
    current_frame_idx = frame_idx
end

--- Set video surface rotation (for phone footage portrait/landscape)
-- @param degrees number Rotation in degrees (0, 90, 180, 270)
function M.set_rotation(degrees)
    ensure_created()
    if video_surface and qt_constants.EMP and qt_constants.EMP.SURFACE_SET_ROTATION then
        qt_constants.EMP.SURFACE_SET_ROTATION(video_surface, degrees or 0)
    end
end

--- Show gap (black frame) when playhead is at a gap in timeline
function M.show_gap()
    ensure_created()
    -- Clear the video surface to show black
    if video_surface and qt_constants.EMP and qt_constants.EMP.SURFACE_SET_FRAME then
        qt_constants.EMP.SURFACE_SET_FRAME(video_surface, nil)
    end
    logger.debug("viewer_panel", "Showing gap (black)")
end

return M
