--- DRP Project Converter - Convert Resolve .drp archives to native .jvp projects
--
-- Responsibilities:
-- - show_conversion_dialog(): Modal dialog to choose save location for converted project
-- - convert(): Parse .drp and create new .jvp database at target path
--
-- Non-goals:
-- - Opening the converted project (caller handles that)
-- - Resolve DB peer mode (that's direct open, not conversion)
--
-- Invariants:
-- - Conversion creates a NEW .jvp file (never modifies existing)
-- - All media items use duration_frames (not duration in ms)
--
-- @file drp_project_converter.lua
local M = {}

local logger = require("core.logger")
local file_browser = require("core.file_browser")
local drp_importer = require("importers.drp_importer")
local json = require("dkjson")

-- Models (SQL isolation: all DB access goes through models)
local Project = require("models.project")
local Media = require("models.media")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")

-- ---------------------------------------------------------------------------
-- Conversion Dialog
-- ---------------------------------------------------------------------------

--- Show conversion dialog for .drp file
-- @param drp_path string: Path to source .drp file
-- @param parent widget: Parent window for dialog
-- @return string|nil: Chosen save path, or nil if cancelled
function M.show_conversion_dialog(drp_path, parent)
    assert(drp_path and drp_path ~= "", "drp_project_converter.show_conversion_dialog: drp_path required")

    -- Extract project name from .drp for default filename
    local default_name = "Converted Project.jvp"

    -- Try to parse just enough to get the project name
    local parse_result = drp_importer.parse_drp_file(drp_path)
    if parse_result.success and parse_result.project and parse_result.project.name then
        default_name = parse_result.project.name .. ".jvp"
    end

    -- Show save dialog
    local home = os.getenv("HOME") or ""
    local default_dir = home ~= "" and (home .. "/Documents/JVE Projects") or ""

    local save_path = file_browser.save_file(
        "convert_drp_project",
        parent,
        "Save Converted Project",
        "JVE Project Files (*.jvp)",
        default_dir,
        default_name
    )

    return save_path
end

-- ---------------------------------------------------------------------------
-- Helper: Infer frame rate from 1-hour timecode start position
-- ---------------------------------------------------------------------------
--
-- HEURISTIC: Professional video workflows typically use 1-hour timecode start
-- (01:00:00:00) to leave room for pre-roll, bars, slate, etc. Different frame
-- rates produce different frame counts for exactly 1 hour:
--
--   Frame Rate    │ Frames in 1 Hour │ Rational (num/den)
--   ──────────────┼──────────────────┼───────────────────
--   23.976 fps    │ ~86,314          │ 24000/1001
--   24 fps        │  86,400          │ 24/1
--   25 fps        │  90,000          │ 25/1
--   29.97 fps     │ ~107,892         │ 30000/1001
--   30 fps        │ 108,000          │ 30/1
--   50 fps        │ 180,000          │ 50/1
--   59.94 fps     │ ~215,784         │ 60000/1001
--   60 fps        │ 216,000          │ 60/1
--
-- If the earliest clip starts within ±1% of one of these values, we can
-- confidently infer the project's frame rate. This is more reliable than
-- parsing Resolve's binary FieldsBlob format.
--
-- @param min_start_frame number: The earliest timeline_start across all clips
-- @return number|nil: Inferred fps, or nil if no confident match
-- @return number|nil: fps_numerator for rational representation
-- @return number|nil: fps_denominator for rational representation
--
local function infer_fps_from_one_hour_start(min_start_frame)
    if not min_start_frame or min_start_frame <= 0 then
        return nil
    end

    -- Known frame counts for 1 hour at various frame rates
    -- Format: { frames_at_1_hour, display_fps, fps_numerator, fps_denominator }
    local one_hour_markers = {
        { 86314,  23.976, 24000, 1001 },  -- 23.976 fps (NTSC film)
        { 86400,  24,     24,    1    },  -- 24 fps (true film)
        { 90000,  25,     25,    1    },  -- 25 fps (PAL)
        { 107892, 29.97,  30000, 1001 },  -- 29.97 fps (NTSC video)
        { 108000, 30,     30,    1    },  -- 30 fps
        { 180000, 50,     50,    1    },  -- 50 fps (PAL high frame rate)
        { 215784, 59.94,  60000, 1001 },  -- 59.94 fps (NTSC high frame rate)
        { 216000, 60,     60,    1    },  -- 60 fps
    }

    -- Allow 1% tolerance for slight timecode variations
    local tolerance = 0.01

    for _, marker in ipairs(one_hour_markers) do
        local expected = marker[1]
        local lower = expected * (1 - tolerance)
        local upper = expected * (1 + tolerance)

        if min_start_frame >= lower and min_start_frame <= upper then
            logger.info("drp_project_converter",
                string.format("Inferred %.3f fps from 1-hour TC start (frame %d ≈ %d)",
                    marker[2], min_start_frame, expected))
            return marker[2], marker[3], marker[4]
        end
    end

    -- No confident match - clips don't start near a 1-hour boundary
    logger.debug("drp_project_converter",
        string.format("Could not infer fps from start frame %d (not near 1-hour TC)", min_start_frame))
    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: Frame rate to rational
-- ---------------------------------------------------------------------------

local function frame_rate_to_rational(frame_rate)
    local fps = tonumber(frame_rate)
    assert(fps and fps > 0, "drp_project_converter: invalid frame_rate: " .. tostring(frame_rate))

    -- Handle common NTSC fractional frame rates
    if math.abs(fps - 23.976) < 0.01 then
        return 24000, 1001
    elseif math.abs(fps - 29.97) < 0.01 then
        return 30000, 1001
    elseif math.abs(fps - 59.94) < 0.01 then
        return 60000, 1001
    end

    -- Integer frame rates
    return math.floor(fps + 0.5), 1
end

-- ---------------------------------------------------------------------------
-- Conversion
-- ---------------------------------------------------------------------------

--- Convert .drp file to .jvp at target path
-- @param drp_path string: Path to source .drp file
-- @param jvp_path string: Path for new .jvp file
-- @return boolean: success
-- @return string|nil: error message if failed
function M.convert(drp_path, jvp_path)
    assert(drp_path and drp_path ~= "", "drp_project_converter.convert: drp_path required")
    assert(jvp_path and jvp_path ~= "", "drp_project_converter.convert: jvp_path required")

    logger.info("drp_project_converter", string.format("Converting %s -> %s", drp_path, jvp_path))

    -- Parse .drp file
    local parse_result = drp_importer.parse_drp_file(drp_path)
    if not parse_result.success then
        return false, "Failed to parse .drp file: " .. tostring(parse_result.error)
    end

    -- Remove existing file if present (user confirmed overwrite in save dialog)
    os.remove(jvp_path)
    os.remove(jvp_path .. "-shm")
    os.remove(jvp_path .. "-wal")

    -- Create new database at target path
    local database = require("core.database")
    local ok, err = pcall(function()
        database.init(jvp_path)
    end)

    if not ok then
        return false, "Failed to create database: " .. tostring(err)
    end

    local settings = {
        frame_rate = parse_result.project.settings.frame_rate,
        width = parse_result.project.settings.width,
        height = parse_result.project.settings.height
    }

    local project = Project.create(parse_result.project.name, {
        settings = json.encode(settings)
    })

    if not project:save() then
        return false, "Failed to save project record"
    end

    logger.info("drp_project_converter", string.format("Created project: %s (%dx%d @ %.2ffps)",
        project.name, settings.width, settings.height, settings.frame_rate))

    -- Import media items
    local media_by_path = {}
    for _, media_item in ipairs(parse_result.media_items) do
        -- Skip media with zero duration (discovered paths without metadata)
        local dur = media_item.duration or 0
        if dur <= 0 then
            logger.warn("drp_project_converter", string.format("Skipping zero-duration media: %s", media_item.name))
        else
            local media = Media.create({
                project_id = project.id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration_frames = dur,  -- Use duration_frames, not duration (ms)
                frame_rate = media_item.frame_rate or parse_result.project.settings.frame_rate,
                width = parse_result.project.settings.width,
                height = parse_result.project.settings.height
            })

            if media:save() then
                media_by_path[media_item.file_path] = media
                logger.debug("drp_project_converter", string.format("  Imported media: %s", media.name))
            else
                logger.warn("drp_project_converter", string.format("Failed to import media: %s", media_item.name))
            end
        end
    end

    -- Import timelines
    local timeline_count = 0
    local track_count = 0
    local clip_count = 0

    for _, timeline_data in ipairs(parse_result.timelines) do
        -- =====================================================================
        -- STEP 1: Analyze clip positions to determine timeline extent
        -- =====================================================================
        -- We need min/max frame positions for:
        --   a) Inferring frame rate from 1-hour timecode start (see heuristic above)
        --   b) Setting viewport to "zoom to fit" all content
        --   c) Positioning playhead at first clip
        --
        local min_start_frame = nil
        local max_end_frame = 0
        for _, track_data in ipairs(timeline_data.tracks) do
            for _, clip_data in ipairs(track_data.clips) do
                local start = clip_data.start_value or 0
                local dur = clip_data.duration or 0
                if not min_start_frame or start < min_start_frame then
                    min_start_frame = start
                end
                if (start + dur) > max_end_frame then
                    max_end_frame = start + dur
                end
            end
        end

        -- =====================================================================
        -- STEP 2: Determine frame rate (prefer inference over project default)
        -- =====================================================================
        -- Resolve's .drp format stores frame rate in binary FieldsBlob, which
        -- is difficult to parse. Instead, we use a heuristic: if clips start
        -- at or near 1:00:00:00 timecode (common professional practice), we
        -- can infer the frame rate from the frame count at that 1-hour mark.
        --
        local fps_num, fps_den
        local inferred_fps, inferred_num, inferred_den = infer_fps_from_one_hour_start(min_start_frame)

        if inferred_fps then
            -- Successfully inferred from 1-hour timecode start
            fps_num, fps_den = inferred_num, inferred_den
        else
            -- Fall back to project settings (may be wrong, but it's all we have)
            fps_num, fps_den = frame_rate_to_rational(parse_result.project.settings.frame_rate)
            logger.debug("drp_project_converter",
                string.format("Using project default fps: %d/%d", fps_num, fps_den))
        end

        -- =====================================================================
        -- STEP 3: Set viewport to "zoom to fit" all timeline content
        -- =====================================================================
        -- Rather than showing a fixed 10-second window (which may miss content),
        -- we zoom to show the entire extent of clips with a small margin.
        -- This ensures the user sees all content immediately after import.
        --
        local view_start = min_start_frame or 0
        local content_duration = max_end_frame - view_start
        local view_duration

        if content_duration > 0 then
            -- Add 5% margin on each side for visual breathing room
            local margin = math.floor(content_duration * 0.05)
            view_start = math.max(0, view_start - margin)
            view_duration = content_duration + (margin * 2)
        else
            -- No clips - show first 10 seconds at default zoom
            local effective_fps = fps_num / fps_den
            view_duration = math.floor(10 * effective_fps)
        end

        -- =====================================================================
        -- STEP 4: Create the sequence with computed settings
        -- =====================================================================
        local sequence = Sequence.create(
            timeline_data.name,
            project.id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            settings.width,
            settings.height,
            {
                audio_rate = 48000,
                view_start_frame = view_start,
                view_duration_frames = view_duration,
                playhead_frame = min_start_frame or 0,  -- Playhead at first clip
            }
        )

        if not sequence:save() then
            logger.warn("drp_project_converter", string.format("Failed to create timeline: %s", timeline_data.name))
        else
            timeline_count = timeline_count + 1
            logger.info("drp_project_converter",
                string.format("  Created timeline: %s @ %d/%d fps, viewport [%d..%d]",
                    timeline_data.name, fps_num, fps_den, view_start, view_start + view_duration))

            -- Import tracks via model
            for _, track_data in ipairs(timeline_data.tracks) do
                local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                local track_name = string.format("%s%d", track_prefix, track_data.index)

                -- Use appropriate track factory based on type
                local track
                if track_data.type == "VIDEO" then
                    track = Track.create_video(track_name, sequence.id, { index = track_data.index })
                else
                    track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
                end

                if not track:save() then
                    logger.warn("drp_project_converter", string.format("Failed to create track: %s", track_name))
                else
                    track_count = track_count + 1

                    -- Import clips
                    for _, clip_data in ipairs(track_data.clips) do
                        -- Find media by file path
                        local media_id = nil
                        if clip_data.file_path and media_by_path[clip_data.file_path] then
                            media_id = media_by_path[clip_data.file_path].id
                        end

                        local source_out = clip_data.source_out
                        if not source_out and clip_data.source_in and clip_data.duration then
                            source_out = clip_data.source_in + clip_data.duration
                        end

                        local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                            track_id = track.id,
                            timeline_start = clip_data.start_value,
                            duration = clip_data.duration,
                            source_in = clip_data.source_in,
                            source_out = source_out,
                            fps_numerator = fps_num,
                            fps_denominator = fps_den,
                        })

                        if clip:save() then
                            clip_count = clip_count + 1
                        else
                            logger.warn("drp_project_converter", string.format("Failed to import clip: %s", clip_data.name))
                        end
                    end
                end
            end
        end
    end

    logger.info("drp_project_converter", string.format("Conversion complete: %d media, %d timelines, %d tracks, %d clips",
        #parse_result.media_items, timeline_count, track_count, clip_count))

    return true
end

return M
