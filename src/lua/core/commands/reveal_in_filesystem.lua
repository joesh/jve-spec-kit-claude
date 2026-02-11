--- Reveal selected media file in Finder
--
-- Opens the parent folder and selects the file in the native file browser.
-- On macOS: uses `open -R <path>`
--
-- Works with both:
-- - Project browser selection (master clips)
-- - Timeline selection (timeline clips → media)
--
-- @file reveal_in_filesystem.lua
local M = {}
local logger = require("core.logger")
local project_browser = require("ui.project_browser")
local Media = require("models.media")

local SPEC = {
    undoable = false,
    no_persist = true,  -- UI-only, no database changes
    args = {
        project_id = { required = true },
        sequence_id = {},  -- Optional: provided when called from timeline
        source = {},  -- Optional: "timeline" or "browser"
    }
}

--- Get file path from timeline selection
local function get_timeline_file_path()
    local ok, timeline_state = pcall(require, "ui.timeline.timeline_state")
    if not ok or not timeline_state then return nil end

    local selected = timeline_state.get_selected_clips and timeline_state.get_selected_clips()
    if not selected or #selected == 0 then return nil end

    -- Use first selected clip with media
    for _, clip in ipairs(selected) do
        if clip.media_id then
            local media = Media.load(clip.media_id)
            if media and media.file_path then
                return media.file_path
            end
        end
    end
    return nil
end

function M.register(command_executors, _command_undoers, _db, set_last_error)
    command_executors["RevealInFilesystem"] = function(command)
        local args = command:get_all_parameters()
        local file_path

        -- Check source hint or try both
        if args.source == "timeline" then
            file_path = get_timeline_file_path()
        elseif args.source == "browser" then
            local master_clip = project_browser.get_selected_master_clip()
            file_path = master_clip and master_clip.file_path
        else
            -- Try timeline first, then browser
            file_path = get_timeline_file_path()
            if not file_path then
                local master_clip = project_browser.get_selected_master_clip()
                file_path = master_clip and master_clip.file_path
            end
        end

        if not file_path or file_path == "" then
            set_last_error("RevealInFilesystem: No media selected or selected item has no file path")
            return false
        end

        -- Check if file exists
        local f = io.open(file_path, "r")
        if not f then
            set_last_error("RevealInFilesystem: File not found: " .. file_path)
            return false
        end
        f:close()

        -- Reveal in Finder (macOS)
        -- Shell-escape the path: wrap in single quotes, escape existing single quotes
        local escaped_path = "'" .. file_path:gsub("'", "'\\''") .. "'"
        local cmd = "open -R " .. escaped_path
        local exit_code = os.execute(cmd)

        if exit_code ~= 0 and exit_code ~= true then
            set_last_error("RevealInFilesystem: Failed to reveal file")
            return false
        end

        logger.info("reveal_in_filesystem", "Revealed: " .. file_path)
        return true
    end

    return {
        executor = command_executors["RevealInFilesystem"],
        spec = SPEC,
    }
end

return M
