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
local log = require("core.logger").for_area("media")
local path_utils = require("core.path_utils")
local uuid = require("uuid")

-- Template presets: each drives both combobox display and .jvp generation
M.TEMPLATES = {
    { name = "Film 24fps",         width = 1920, height = 1080, fps_num = 24,    fps_den = 1,    audio_sample_rate = 48000 },
    { name = "Film 23.976fps",     width = 1920, height = 1080, fps_num = 24000, fps_den = 1001, audio_sample_rate = 48000 },
    { name = "Broadcast 29.97fps", width = 1920, height = 1080, fps_num = 30000, fps_den = 1001, audio_sample_rate = 48000 },
    { name = "Broadcast 25fps",    width = 1920, height = 1080, fps_num = 25,    fps_den = 1,    audio_sample_rate = 48000 },
    { name = "4K Film 24fps",      width = 3840, height = 2160, fps_num = 24,    fps_den = 1,    audio_sample_rate = 48000 },
    { name = "YouTube HD",         width = 1920, height = 1080, fps_num = 30,    fps_den = 1,    audio_sample_rate = 48000 },
    { name = "Instagram Square",   width = 1080, height = 1080, fps_num = 30,    fps_den = 1,    audio_sample_rate = 48000 },
    { name = "Instagram Reels",    width = 1080, height = 1920, fps_num = 30,    fps_den = 1,    audio_sample_rate = 48000 },
    { name = "TikTok",             width = 1080, height = 1920, fps_num = 30,    fps_den = 1,    audio_sample_rate = 48000 },
}

local function template_filename(template)
    -- Sanitize name: lowercase, replace spaces/dots with underscores
    return template.name:lower():gsub("[%s%.]+", "_") .. ".jvp"
end

--- Get path to a freshly-generated template .jvp.
-- Always regenerates from the current schema.sql. Templates are cheap to
-- build (~ms for one project + sequence + 6 tracks) and are not committed
-- to the repo, so caching across runs has no benefit and creates a
-- staleness class — a cached file with the right schema_version but
-- columns added later (rule 2.15: schema changes must bump the version,
-- but a parallel branch can ship a different V10-labelled schema). Always
-- regenerating eliminates that whole class of bug.
-- @param template table: entry from M.TEMPLATES
-- @return string: absolute path to freshly-generated .jvp file
function M.get_template_path(template)
    assert(template and template.name, "project_templates.get_template_path: template required")

    -- Parallel test harnesses share the repo dir and race through this
    -- regenerate-then-set_path sequence; one process's os.remove +
    -- Project.create catches another's mid-write and sqlite returns
    -- "disk I/O error" / "no sequence found after identity update". When
    -- a runner needs isolation it sets JVE_TEMPLATE_DIR to a per-runner
    -- path; production leaves it unset and uses the repo dir.
    local override = os.getenv("JVE_TEMPLATE_DIR")
    local templates_dir
    if override and override ~= "" then
        templates_dir = override
        assert(qt_fs_mkdir_p, "project_templates: qt_fs_mkdir_p binding required "
            .. "to honor JVE_TEMPLATE_DIR (not in --test mode?)")
        local ok, mkdir_err = qt_fs_mkdir_p(templates_dir)
        assert(ok, "project_templates: failed to create JVE_TEMPLATE_DIR: "
            .. templates_dir .. ": " .. (mkdir_err or "unknown"))
    else
        templates_dir = path_utils.resolve_repo_path("resources/templates")
    end
    local path = templates_dir .. "/" .. template_filename(template)

    -- Remove any stale cached template before regenerating.
    local existing = io.open(path, "rb")
    if existing then
        existing:close()
        os.remove(path)
    end

    log.event("Generating template: %s → %s", template.name, path)

    local database = require("core.database")
    local Project = require("models.project")
    local Sequence = require("models.sequence")
    local Track = require("models.track")

    -- Save and restore current database state
    local prev_path = database.get_path()

    database.set_path(path)

    local project = Project.create(template.name, {
        id = "template_project",
        fps_mismatch_policy = "resample",
    })
    assert(project:save(), "project_templates: failed to save template project")

    -- Seed the project-level audio_sample_rate that DRP/DRT importers
    -- (importer_core.resolve_sequence_audio_rate, rule 2.13 — no silent
    -- default) require. Without this, File → New → Import DRT fails with
    -- "audio_sample_rate required" because the per-sequence rate is not
    -- the project-level fallback the importer reads.
    database.set_project_setting(project.id, "audio_sample_rate",
        template.audio_sample_rate)

    -- The user's edit timeline is kind='sequence' (it holds clips referencing
    -- other sequences). Master sequences are created later by import.
    local sequence = Sequence.create("Sequence 1", project.id,
        { fps_numerator = template.fps_num, fps_denominator = template.fps_den },
        template.width, template.height,
        { kind = "sequence", audio_sample_rate = template.audio_sample_rate })
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

    -- Prep the destination — the ONLY guarantee callers need is "after this
    -- block, dest_path is a clean slot to copy a template into". Three cases:
    --   1. .jvp exists                 → refuse (real project there).
    --   2. .jvp missing, pidlock alive → refuse (another JVE has the project
    --      open even though its .jvp was unlinked under it — extremely rare
    --      .app-unlink case but real on macOS).
    --   3. .jvp missing, no live owner → sidecars (-wal, -shm, -journal,
    --      -jve-pidlock) are orphans by definition and cannot point at any
    --      meaningful database. Delete them; otherwise sqlite3.open would
    --      replay an unrelated WAL against the freshly-copied template and
    --      we'd land at "no sequence found after identity update" below.
    -- This prep used to live in new_project.lua. Hoisted here so EVERY caller
    -- — current dialog, future scripted creates, tests — gets the same
    -- guarantee, and the dialog can't accidentally bypass it.
    local function path_exists(p)
        local f = io.open(p, "rb")
        if f then f:close(); return true end
        return false
    end
    assert(not path_exists(dest_path),
        "project_templates.create_project_from_template: project already exists at "
        .. dest_path)
    local project_open = require("core.project_open")
    assert(not project_open.another_jve_owns_project(dest_path),
        "project_templates.create_project_from_template: another JVE process has "
        .. "this project open (per pidlock at " .. dest_path .. "-jve-pidlock). "
        .. "Quit that instance first.")
    for _, suffix in ipairs({"-wal", "-shm", "-journal", "-jve-pidlock"}) do
        local p = dest_path .. suffix
        if path_exists(p) then
            local ok_rm, rm_err = os.remove(p)
            assert(ok_rm,
                "project_templates.create_project_from_template: failed to clean "
                .. "orphan sidecar " .. p .. ": " .. tostring(rm_err))
            log.event("project_templates: removed orphan sidecar %s", p)
        end
    end

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

    -- Mark the template's single sequence as the active one. Without this,
    -- Sequence.resolve_initial_for_project returns nil on first open and
    -- the project opens in the no-active-sequence state — UX bug (fresh
    -- project from File→New shows a blank timeline) AND tripwire for
    -- timeline_panel.create which assumes an active sequence's fps cache.
    -- The single template sequence IS the natural active one.
    database.set_project_setting(new_project_id, "last_open_sequence_id", sequence_id)

    database.shutdown()

    -- Restore previous database if one was open
    if prev_path then
        database.set_path(prev_path)
    end

    log.event("Created project '%s' from template '%s' at %s",
        project_name, template.name, dest_path)

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
    local audio_str = string.format("%dkHz", template.audio_sample_rate / 1000)
    return string.format("%dx%d · %s · %s",
        template.width, template.height, fps_str, audio_str)
end

return M
