--- project_templates: template parameter table and self-healing .jvp generation
--
-- Responsibilities:
-- - Define template presets (resolution, fps, audio rate)
-- - Generate template .jvp files on demand (self-healing)
-- - Copy template to user-specified path with new project identity
--
-- Non-goals:
-- - User-defined templates (future)
-- - Template editing UI
--
-- Invariants:
-- - Templates are complete .jvp files (schema + project + sequence + 3V+3A tracks)
-- - Missing .jvp files are regenerated from TEMPLATES parameter table
-- - create_project_from_template produces a project with unique project_id
--
-- Size: ~100 LOC
-- Volatility: low
--
-- @file project_templates.lua
local M = {}
local logger = require("core.logger")
local path_utils = require("core.path_utils")
local uuid = require("uuid")

-- Template presets: each drives both combobox display and .jvp generation
M.TEMPLATES = {
    { name = "Film 24fps",         width = 1920, height = 1080, fps_num = 24,    fps_den = 1,    audio_rate = 48000 },
    { name = "Film 23.976fps",     width = 1920, height = 1080, fps_num = 24000, fps_den = 1001, audio_rate = 48000 },
    { name = "Broadcast 29.97fps", width = 1920, height = 1080, fps_num = 30000, fps_den = 1001, audio_rate = 48000 },
    { name = "Broadcast 25fps",    width = 1920, height = 1080, fps_num = 25,    fps_den = 1,    audio_rate = 48000 },
    { name = "4K Film 24fps",      width = 3840, height = 2160, fps_num = 24,    fps_den = 1,    audio_rate = 48000 },
    { name = "YouTube HD",         width = 1920, height = 1080, fps_num = 30,    fps_den = 1,    audio_rate = 48000 },
    { name = "Instagram Square",   width = 1080, height = 1080, fps_num = 30,    fps_den = 1,    audio_rate = 48000 },
    { name = "Instagram Reels",    width = 1080, height = 1920, fps_num = 30,    fps_den = 1,    audio_rate = 48000 },
    { name = "TikTok",             width = 1080, height = 1920, fps_num = 30,    fps_den = 1,    audio_rate = 48000 },
}

local function template_filename(template)
    -- Sanitize name: lowercase, replace spaces/dots with underscores
    return template.name:lower():gsub("[%s%.]+", "_") .. ".jvp"
end

--- Get path to template .jvp, generating it if missing (self-healing).
-- @param template table: entry from M.TEMPLATES
-- @return string: absolute path to .jvp file
function M.get_template_path(template)
    assert(template and template.name, "project_templates.get_template_path: template required")

    local templates_dir = path_utils.resolve_repo_path("resources/templates")
    local path = templates_dir .. "/" .. template_filename(template)

    -- Check if already exists
    local f = io.open(path, "rb")
    if f then
        f:close()
        return path
    end

    -- Generate: open a temp database, create project + sequence + tracks, close
    logger.info("project_templates", "Generating template: " .. template.name .. " → " .. path)

    local database = require("core.database")
    local Project = require("models.project")
    local Sequence = require("models.sequence")
    local Track = require("models.track")

    -- Save and restore current database state
    local prev_path = database.get_path()

    database.set_path(path)

    local project = Project.create(template.name, { id = "template_project" })
    assert(project:save(), "project_templates: failed to save template project")

    local sequence = Sequence.create("Sequence 1", project.id,
        { fps_numerator = template.fps_num, fps_denominator = template.fps_den },
        template.width, template.height,
        { audio_rate = template.audio_rate })
    assert(sequence:save(), "project_templates: failed to save template sequence")

    for i = 1, 3 do
        local vtrack = Track.create_video("V" .. i, sequence.id, { index = i })
        assert(vtrack:save(), "project_templates: failed to save video track " .. i)
    end
    for i = 1, 3 do
        local atrack = Track.create_audio("A" .. i, sequence.id, { index = i })
        assert(atrack:save(), "project_templates: failed to save audio track " .. i)
    end

    database.shutdown()

    -- Restore previous database if one was open
    if prev_path then
        database.set_path(prev_path)
    end

    return path
end

--- Copy template .jvp to dest_path, assign new project identity.
-- @param template table: entry from M.TEMPLATES
-- @param project_name string: user-chosen project name
-- @param dest_path string: absolute path for new .jvp file
-- @return table {project_id, sequence_id}
function M.create_project_from_template(template, project_name, dest_path)
    assert(template and template.name,
        "project_templates.create_project_from_template: template required")
    assert(project_name and project_name ~= "",
        "project_templates.create_project_from_template: project_name required")
    assert(dest_path and dest_path ~= "",
        "project_templates.create_project_from_template: dest_path required")

    -- Assert dest doesn't already exist
    local check = io.open(dest_path, "rb")
    assert(not check,
        "project_templates.create_project_from_template: dest already exists: " .. dest_path)

    -- Get (or generate) template .jvp
    local src_path = M.get_template_path(template)

    -- Binary copy
    local src = assert(io.open(src_path, "rb"),
        "project_templates: failed to open template: " .. src_path)
    local data = src:read("*a")
    src:close()

    local dst = assert(io.open(dest_path, "wb"),
        "project_templates: failed to create dest: " .. dest_path)
    dst:write(data)
    dst:close()

    -- Open dest and update identity via model methods (SQL isolation compliance)
    local database = require("core.database")
    local Project = require("models.project")
    local Sequence = require("models.sequence")
    local prev_path = database.get_path()

    database.set_path(dest_path)

    local new_project_id = uuid.generate()

    -- Update project identity (begins deferred FK transaction)
    Project.update_identity("template_project", new_project_id, project_name)

    -- Update sequences within the same deferred FK transaction
    Sequence.rebind_to_project("template_project", new_project_id)

    -- Commit the identity update (FK check runs here)
    Project.commit_identity_update()

    -- Read the sequence_id
    local sequence_id = Sequence.find_first_by_project(new_project_id)
    assert(sequence_id, "project_templates: no sequence found after identity update")

    database.shutdown()

    -- Restore previous database if one was open
    if prev_path then
        database.set_path(prev_path)
    end

    logger.info("project_templates", string.format(
        "Created project '%s' from template '%s' at %s",
        project_name, template.name, dest_path))

    return { project_id = new_project_id, sequence_id = sequence_id }
end

--- Format template info for display (e.g. "1920x1080 · 24fps · 48kHz").
-- @param template table: entry from M.TEMPLATES
-- @return string
function M.format_info(template)
    local fps_str
    if template.fps_den == 1 then
        fps_str = tostring(template.fps_num) .. "fps"
    else
        fps_str = string.format("%.3gfps", template.fps_num / template.fps_den)
    end
    local audio_str = string.format("%dkHz", template.audio_rate / 1000)
    return string.format("%dx%d · %s · %s",
        template.width, template.height, fps_str, audio_str)
end

return M
