--- Import Resolve Commands - Import Resolve projects, timelines and databases
--
-- Responsibilities:
-- - ImportResolveProject: Import .drp file — creates a NEW project
-- - ImportResolveTimeline: Import .drt file — adds sequences to the CURRENT project
-- - ImportResolveDatabase: Import Resolve database — creates a NEW project
--
-- Non-goals:
-- - Direct Resolve API integration (file-based import only)
--
-- Invariants:
-- - Commands must receive file paths (or gather from dialog)
-- - Project-creating commands (Project, Database): undo deletes the created
--   project and everything it contained
-- - Timeline command: undo deletes only the imported sequences/media/etc.;
--   the host project is preserved
--
-- @file import_resolve_project.lua
local M = {}
local log = require("core.logger").for_area("media")
local subframe_math = require("core.subframe_math")
local file_browser = require("core.file_browser")

-- Schema for .drp import command
local SPEC_DRP = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },
        drp_path = {},
        -- Caller-supplied project audio rate. DRP carries no project-wide
        -- default (per Resolve format); UI prompts the user, tests pass
        -- explicitly. Importer asserts when missing — never invented.
        audio_sample_rate = { kind = "number" },
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_sequence_ids = {},
        created_track_ids = {},
        result_project_id = {},
    },
}

-- Schema for .drt timeline import command (imports into existing project)
local SPEC_TIMELINE = {
    args = {
        project_id = { required = true },  -- target project (must already exist)
        interactive = { kind = "boolean" },
        drt_path = {},
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_sequence_ids = {},
        created_track_ids = {},
        target_project_id = {},
    },
}

-- Schema for database import command
local SPEC_DB = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },
        db_path = {},
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_sequence_ids = {},
        created_track_ids = {},
        result_project_id = {},
    },
}

--- Delete entities created by an import command.
-- Shared dependency-ordered teardown: properties/links → clips → tracks → sequences → media.
-- @param command_name string: label for assert context
-- @param args table: command parameters with created_* id arrays
-- @param db: database connection
local function delete_imported_entities(command_name, args, db)
    -- Both ImportResolveProject and any caller of this helper populate the
    -- four created_*_ids arrays unconditionally on execute. No fallbacks.
    for _, clip_id in ipairs(args.created_clip_ids) do
        local prop_stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
        if prop_stmt then
            prop_stmt:bind_value(1, clip_id)
            prop_stmt:exec()
            prop_stmt:finalize()
        end
        local link_stmt = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
        if link_stmt then
            link_stmt:bind_value(1, clip_id)
            link_stmt:exec()
            link_stmt:finalize()
        end
    end

    for _, clip_id in ipairs(args.created_clip_ids) do
        local del_stmt = db:prepare("DELETE FROM clips WHERE id = ?")
        assert(del_stmt, command_name .. ": clips DELETE prepare failed")
        del_stmt:bind_value(1, clip_id)
        assert(del_stmt:exec(), command_name .. ": clips DELETE failed for " .. tostring(clip_id))
        del_stmt:finalize()
    end

    for _, track_id in ipairs(args.created_track_ids) do
        local stmt = db:prepare("DELETE FROM tracks WHERE id = ?")
        assert(stmt, command_name .. ": tracks DELETE prepare failed")
        stmt:bind_value(1, track_id)
        assert(stmt:exec(), command_name .. ": tracks DELETE failed for " .. tostring(track_id))
        stmt:finalize()
    end

    for _, seq_id in ipairs(args.created_sequence_ids) do
        local stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
        assert(stmt, command_name .. ": sequences DELETE prepare failed")
        stmt:bind_value(1, seq_id)
        assert(stmt:exec(), command_name .. ": sequences DELETE failed for " .. tostring(seq_id))
        stmt:finalize()
    end

    for _, media_id in ipairs(args.created_media_ids) do
        local stmt = db:prepare("DELETE FROM media WHERE id = ?")
        assert(stmt, command_name .. ": media DELETE prepare failed")
        stmt:bind_value(1, media_id)
        assert(stmt:exec(), command_name .. ": media DELETE failed for " .. tostring(media_id))
        stmt:finalize()
    end
end

--- Undoer for project-creating imports: delete entities + the project itself.
-- Used by ImportResolveProject and ImportResolveDatabase.
local function import_undoer(command_name, command, db)
    local args = command:get_all_parameters()
    assert(args.result_project_id,
        command_name .. ": missing result_project_id")

    delete_imported_entities(command_name, args, db)

    local proj_stmt = db:prepare("DELETE FROM projects WHERE id = ?")
    assert(proj_stmt, command_name .. ": projects DELETE prepare failed")
    proj_stmt:bind_value(1, args.result_project_id)
    assert(proj_stmt:exec(), command_name .. ": projects DELETE failed for " .. tostring(args.result_project_id))
    proj_stmt:finalize()

    log.event("Undo: Deleted imported project and all associated data")
    return true
end

--- Undoer for timeline-into-existing-project imports.
-- Removes imported entities but preserves the host project row.
local function import_timeline_undoer(command_name, command, db)
    local args = command:get_all_parameters()
    assert(args.target_project_id,
        command_name .. ": missing target_project_id")

    delete_imported_entities(command_name, args, db)

    log.event("Undo: Removed imported timeline entities from project %s",
        tostring(args.target_project_id))
    return true
end

--- Gather file path from user dialog if needed.
-- @return string|nil: file path, or nil if cancelled
-- @return table|nil: cancel result to return from executor
local function gather_file_path(command, args, dialog_key, dialog_title, dialog_filter, param_name, default_dir)
    local path = args[param_name]
    if args.interactive or not path or path == "" then
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if not ui_state_ok then
            return nil, { success = false, error_message = "UI state not initialized" }
        end
        local main_window = ui_state.get_main_window()
        if not main_window then
            return nil, { success = false, error_message = "Main window not initialized" }
        end

        path = file_browser.open_file(dialog_key, main_window, dialog_title, dialog_filter, default_dir)
        if not path or path == "" then
            return nil, { success = true, cancelled = true }
        end
        command:set_parameter(param_name, path)
    end
    return path, nil
end

--- Persist import results and refresh UI.
-- @param command: command being executed
-- @param project_id_key string: parameter name for storing the project id
--        ("result_project_id" for project-creating imports, "target_project_id"
--        for imports into an existing project)
-- @param project_id string: project id value
-- @param import_result table: {media_ids, sequence_ids, track_ids, clip_ids}
--- After an import lands a record sequence, focus moves to the
--- timeline panel so Space/J/K/L route there. If no sequence is
--- active (browser-only refresh, edge cases), focus stays put.
--- Exposed on M so the post-import flow can call it AND the focused
--- behavior is testable in isolation.
function M.focus_post_import(_project_id)
    local timeline_state = require("ui.timeline.timeline_state")
    local active = timeline_state.get_active_sequence_id()
    if not active or active == "" then return end
    require("ui.focus_manager").focus_panel("timeline")
end

local function persist_and_refresh(command, project_id_key, project_id, import_result)
    command:set_parameters({
        [project_id_key] = project_id,
        ["created_media_ids"] = import_result.media_ids,
        ["created_sequence_ids"] = import_result.sequence_ids,
        ["created_track_ids"] = import_result.track_ids,
        ["created_clip_ids"] = import_result.clip_ids,
    })

    local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
    if ui_state_ok then
        local project_browser = ui_state.get_project_browser()
        if project_browser and project_browser.refresh then
            project_browser.refresh()
        end
    end

    M.focus_post_import(project_id)
end

-- Industry-standard sample rate for video projects. Used for sequences
-- imported from Resolve's database when no per-sequence audio rate is
-- available — matches Resolve's own default. Hoisted here as a named
-- constant per ENGINEERING.md 1.5b.
local DEFAULT_AUDIO_SAMPLE_RATE = 48000

-- Convert a fractional frame rate (e.g. "23.976") to (numerator, denominator).
-- Snaps to the four canonical NTSC variants; everything else rounds to
-- /1.
local function fr_to_rational(fr)
    local fps = tonumber(fr)
    assert(fps, "ImportResolveDatabase: missing/invalid frame_rate")
    if math.abs(fps - 23.976) < 0.01 then return 24000, 1001
    elseif math.abs(fps - 29.97) < 0.01 then return 30000, 1001
    elseif math.abs(fps - 59.94) < 0.01 then return 60000, 1001
    end
    return math.floor(fps + 0.5), 1
end

-- Phase 1 of ImportResolveDatabase: materialize every media row and build
-- the resolve_id → jve_id map. Returns (created_ids, id_map).
local function create_media_from_resolve_db(project_id, import_raw)
    local Media = require("models.media")
    local created_ids, id_map = {}, {}
    for _, item in ipairs(import_raw.media_items) do
        local media = Media.create({
            project_id        = project_id,
            name              = item.name,
            file_path         = item.file_path,
            duration_frames   = item.duration,
            frame_rate        = item.frame_rate or import_raw.project.frame_rate,
            width             = import_raw.project.width,
            height            = import_raw.project.height,
            audio_channels    = item.audio_channels or 0,
            audio_sample_rate = item.audio_sample_rate,
            codec             = item.codec,
            is_still          = Media.classify_is_still(
                item.codec, import_raw.project.width, item.duration),
        })
        if media:save() then
            table.insert(created_ids, media.id)
            if item.resolve_id then id_map[item.resolve_id] = media.id end
        else
            log.warn("Failed to import media: %s", item.name)
        end
    end
    return created_ids, id_map
end

-- Build a single track + every clip on it. Appends ids onto the
-- accumulators. Returns nothing.
local function create_track_with_clips(project_id, sequence, track_data,
                                       fps_num, fps_den, media_id_map,
                                       created_track_ids, created_clip_ids)
    local Track   = require("models.track")
    local Clip    = require("models.clip")

    local track_prefix = track_data.type == "VIDEO" and "V" or "A"
    local track_name   = string.format("%s%d", track_prefix, track_data.index)

    local track
    if track_data.type == "VIDEO" then
        track = Track.create_video(track_name, sequence.id, { index = track_data.index })
    else
        track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
    end

    if not track:save() then
        log.warn("Failed to create track: %s", track_name)
        return
    end
    table.insert(created_track_ids, track.id)

    -- Audio tracks carry a sample-rate timebase; video carries fps. Both
    -- map to fps_numerator/denominator on the clip row at this layer.
    local clip_fps_num = track_data.type == "AUDIO" and DEFAULT_AUDIO_SAMPLE_RATE or fps_num
    local clip_fps_den = track_data.type == "AUDIO" and 1                          or fps_den

    for _, c in ipairs(track_data.clips) do
        local source_out = c.source_out
        if not source_out and c.source_in and c.duration then
            source_out = c.source_in + c.duration
        end
        local clip = Clip.create(c.name or "Untitled Clip", media_id_map[c.resolve_media_id], {
            project_id        = project_id,
            owner_sequence_id = sequence.id,
            track_id          = track.id,
            sequence_start    = c.start_value,
            duration          = c.duration,
            source_in         = c.source_in,
            source_out        = source_out,
            fps_numerator     = clip_fps_num,
            fps_denominator   = clip_fps_den,
        })
        if clip:save() then
            table.insert(created_clip_ids, clip.id)
        else
            log.warn("Failed to import clip: %s", c.name)
        end
    end
end

-- Phase 2 of ImportResolveDatabase: build every sequence with its tracks
-- and clips. Appends sequence/track/clip ids onto the accumulators.
local function create_timelines_from_resolve_db(project_id, import_raw,
                                                db_settings, media_id_map,
                                                created_sequence_ids,
                                                created_track_ids,
                                                created_clip_ids)
    local Sequence = require("models.sequence")
    for _, timeline_data in ipairs(import_raw.timelines) do
        local fps_num, fps_den = fr_to_rational(
            timeline_data.frame_rate or import_raw.project.frame_rate)

        local sequence = Sequence.create(
            timeline_data.name, project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            db_settings.width, db_settings.height,
            { audio_sample_rate = DEFAULT_AUDIO_SAMPLE_RATE })

        if not sequence:save() then
            log.warn("Failed to create timeline: %s", timeline_data.name)
        else
            table.insert(created_sequence_ids, sequence.id)
            for _, track_data in ipairs(timeline_data.tracks) do
                create_track_with_clips(project_id, sequence, track_data,
                    fps_num, fps_den, media_id_map,
                    created_track_ids, created_clip_ids)
            end
        end
    end
end

function M.register(executors, undoers, db)

    -- =========================================================================
    -- ImportResolveProject (.drp file)
    -- =========================================================================
    executors["ImportResolveProject"] = function(command)
        local args = command:get_all_parameters()
        assert(args.project_id and args.project_id ~= "", "ImportResolveProject: Missing project_id")

        -- Empty-DB precondition (2026-05-21). ImportResolveProject creates
        -- a NEW project in the active DB; calling it against a .jvp that
        -- already carries a project produces a 2-project file JVE then
        -- refuses to reopen. First-open of a .drp must go through
        -- OpenProject → resolve_format → drp_importer.convert, which
        -- writes a fresh single-project .jvp in one shot. This command
        -- is reserved for the case where the active DB is genuinely
        -- empty (e.g. an importer-driven bootstrap flow). Loud fail per
        -- §1.14 so the misuse can't silently produce broken project
        -- files like it did during the 2026-05-21 smoke-template bring-up.
        local Project = require("models.project")
        local existing = Project.count()
        assert(existing == 0, string.format(
            "ImportResolveProject: refuses to import into a non-empty .jvp "
            .. "(active DB has %d project(s)). Use OpenProject on the .drp "
            .. "directly — its resolve_format path drives "
            .. "drp_importer.convert to write a fresh .jvp.", existing))

        local drp_path, cancel = gather_file_path(
            command, args,
            "import_resolve_drp", "Import Resolve Project (.drp)",
            "Resolve Project Files (*.drp);;All Files (*)",
            "drp_path")
        if not drp_path then return cancel end

        log.event("Importing Resolve project: %s", tostring(drp_path))

        local drp_importer = require("importers.drp_importer")
        local parse_result = drp_importer.parse_drp_file(drp_path)
        if not parse_result.success then
            return { success = false, error_message = parse_result.error }
        end

        local json = require("dkjson")

        -- Order: caller-supplied → majority vote across parsed media →
        -- 48000 Hz spec-implied default (Fairlight FieldsBlob not yet decoded;
        -- see pick_majority_audio_sample_rate TODO).
        local pick_majority = require("importers.drp_importer").pick_majority_audio_sample_rate
        local settings = {
            frame_rate = parse_result.project.settings.frame_rate,
            width = parse_result.project.settings.width,
            height = parse_result.project.settings.height,
            audio_sample_rate = args.audio_sample_rate
                or pick_majority(parse_result),
            master_clock_hz = subframe_math.MASTER_CLOCK_HZ,
            default_fps = { num = 24, den = 1 },
        }

        local project = Project.create(parse_result.project.name, {
            settings = json.encode(settings),
            fps_mismatch_policy = "resample",
        })

        if not project:save(db) then
            return { success = false, error_message = "Failed to create project" }
        end

        log.event("Created project: %s (%dx%d @ %sfps)",
            project.name, settings.width, settings.height, tostring(settings.frame_rate))

        local import_result = drp_importer.import_into_project(project.id, parse_result, {
            project_settings = settings,
        })

        persist_and_refresh(command, "result_project_id", project.id, import_result)

        return { success = true, project_id = project.id }
    end

    undoers["ImportResolveProject"] = function(command)
        return import_undoer("UndoImportResolveProject", command, db)
    end

    -- =========================================================================
    -- ImportResolveTimeline (.drt file → current project)
    -- =========================================================================
    -- A Resolve Timeline export (.drt) carries sequence(s) + referenced media
    -- without enclosing project settings. Import attaches them to the project
    -- the user is currently working in.
    executors["ImportResolveTimeline"] = function(command)
        local args = command:get_all_parameters()
        assert(args.project_id and args.project_id ~= "",
            "ImportResolveTimeline: Missing project_id (target)")

        local drt_path, cancel = gather_file_path(
            command, args,
            "import_resolve_drt", "Import Resolve Timeline (.drt)",
            "Resolve Timeline Files (*.drt);;All Files (*)",
            "drt_path")
        if not drt_path then return cancel end

        log.event("Importing Resolve timeline into project %s: %s",
            tostring(args.project_id), tostring(drt_path))

        local drp_importer = require("importers.drp_importer")
        local parse_result = drp_importer.parse_drp_file(drt_path)
        if not parse_result.success then
            return { success = false, error_message = parse_result.error }
        end

        -- Load the host project's settings so importer_core can pick up
        -- audio_sample_rate (asserts on nil — no silent default to 48000).
        local Project = require("models.project")
        local json = require("dkjson")
        local host = assert(Project.load(args.project_id),
            "ImportResolveTimeline: host project " .. args.project_id .. " not found")
        local host_settings = (host.settings and host.settings ~= "")
            and json.decode(host.settings) or {}
        local import_result = drp_importer.import_into_project(
            args.project_id, parse_result, {
                project_settings = host_settings,
            })

        persist_and_refresh(command, "target_project_id", args.project_id, import_result)

        return {
            success = true,
            project_id = args.project_id,
            sequence_ids = import_result.sequence_ids,
        }
    end

    undoers["ImportResolveTimeline"] = function(command)
        return import_timeline_undoer("UndoImportResolveTimeline", command, db)
    end

    -- =========================================================================
    -- ImportResolveDatabase (Resolve .db file)
    -- =========================================================================
    executors["ImportResolveDatabase"] = function(command)
        local args = command:get_all_parameters()
        assert(args.project_id and args.project_id ~= "", "ImportResolveDatabase: Missing project_id")

        local db_path, cancel = gather_file_path(
            command, args,
            "import_resolve_db", "Import Resolve Database",
            "Database Files (*.db *.sqlite *.resolve);;All Files (*)",
            "db_path",
            os.getenv("HOME") .. "/Movies/DaVinci Resolve")
        if not db_path then return cancel end

        log.event("Importing Resolve database: %s", tostring(db_path))

        local resolve_db_importer = require("importers.resolve_database_importer")
        local import_result_raw = resolve_db_importer.import_from_database(db_path)

        if not import_result_raw.success then
            return { success = false, error_message = import_result_raw.error }
        end

        local Project = require("models.project")
        local json = require("dkjson")

        local db_settings = {
            frame_rate = import_result_raw.project.frame_rate,
            width = import_result_raw.project.width,
            height = import_result_raw.project.height,
            master_clock_hz = subframe_math.MASTER_CLOCK_HZ,
            default_fps = { num = 24, den = 1 },
        }

        local project = Project.create(import_result_raw.project.name, {
            settings = json.encode(db_settings),
            fps_mismatch_policy = "resample",
        })

        if not project:save(db) then
            return { success = false, error_message = "Failed to create project" }
        end

        log.event("Created project from Resolve DB: %s (%dx%d @ %.2ffps)",
            project.name, db_settings.width, db_settings.height, db_settings.frame_rate)

        -- ImportResolveDatabase uses a different data format than DRP parse_result,
        -- so it cannot use import_into_project() directly. Create entities via models.
        local created_sequence_ids = {}
        local created_track_ids    = {}
        local created_clip_ids     = {}

        local created_media_ids, media_id_map = create_media_from_resolve_db(
            project.id, import_result_raw)
        create_timelines_from_resolve_db(project.id, import_result_raw,
            db_settings, media_id_map,
            created_sequence_ids, created_track_ids, created_clip_ids)

        log.event("Imported Resolve database: %d media, %d sequences, %d tracks, %d clips",
            #created_media_ids, #created_sequence_ids, #created_track_ids, #created_clip_ids)

        persist_and_refresh(command, "result_project_id", project.id, {
            media_ids = created_media_ids,
            sequence_ids = created_sequence_ids,
            track_ids = created_track_ids,
            clip_ids = created_clip_ids,
        })

        return { success = true, project_id = project.id }
    end

    undoers["ImportResolveDatabase"] = function(command)
        return import_undoer("UndoImportResolveDatabase", command, db)
    end

    return {
        ["ImportResolveProject"] = {
            executor = executors["ImportResolveProject"],
            undoer = undoers["ImportResolveProject"],
            spec = SPEC_DRP,
        },
        ["ImportResolveTimeline"] = {
            executor = executors["ImportResolveTimeline"],
            undoer = undoers["ImportResolveTimeline"],
            spec = SPEC_TIMELINE,
        },
        ["ImportResolveDatabase"] = {
            executor = executors["ImportResolveDatabase"],
            undoer = undoers["ImportResolveDatabase"],
            spec = SPEC_DB,
        },
    }
end

return M
