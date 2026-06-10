--- Shared environment for timeline RENDER tests that run against the
-- real application (no stubs, no mocks — Joe, 2026-06-09: "get rid of
-- stubs and mocks and use the real jve wherever possible").
--
-- What "real" means here:
--   * full app boot via ui_test_env.launch (blank_project → OpenProject
--     → layout.lua), real panels, real timeline views and ruler
--   * fixture media imported through the ImportMedia command (real
--     probe, real master sequence)
--   * clips placed through AddClipsToSequence / real edit commands
--   * gestures delivered to the views' real registered mouse handlers
--   * assertions read the renderer widget's REAL pending draw-command
--     queue via the timeline.get_commands binding — the same queue the
--     C++ painter consumes
--
-- Tests in this directory run inside one JVEEditor process via
-- batch_timeline_render.lua; each test isolates itself by creating and
-- opening a fresh sequence (real CreateSequence/OpenSequenceInTimeline
-- commands), so module state carries but timeline content never does.

local M = {}

local ui = require("synthetic.integration.ui_test_env")
local command_manager = require("core.command_manager")
local uuid = require("uuid")

assert(type(timeline) == "table" and timeline.get_commands,
    "render_env: requires jve --test (real timeline bindings)")

local ctx = nil

-- TC-bearing fixture (ImportMedia asserts on media without a TC
-- origin; the repo's trimmed camera proxies lost their tmcd track in
-- transcode): countdown_chirp_30s.mp4 stream-copied with a 01:00:00:00
-- timecode track at test time (cheap -c copy, host and VM both carry
-- ffmpeg). Base resolves through test_env.resolve_repo_path (repo on
-- host, repo mount inside the VM); the derived file goes to /tmp/jve
-- so the gitignored fixtures dir is never written to.
local FIXTURE_BASE = "tests/fixtures/media/countdown_chirp_30s.mp4"
local TC_FIXTURE_PATH = "/tmp/jve/render_env_chirp_30s_tc.mp4"

-- The test process PATH is stripped (no /opt/homebrew/bin) when JVE is
-- launched outside a login shell — resolve ffmpeg explicitly.
local function find_ffmpeg()
    for _, p in ipairs({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                         "/usr/bin/ffmpeg" }) do
        if io.open(p, "r") then return p end
    end
    error("render_env: ffmpeg not found in /opt/homebrew/bin, "
        .. "/usr/local/bin, or /usr/bin — brew install ffmpeg")
end

local function ensure_tc_fixture()
    if io.open(TC_FIXTURE_PATH, "r") then return TC_FIXTURE_PATH end
    local base = require("test_env").resolve_repo_path(FIXTURE_BASE)
    assert(io.open(base, "r"), "render_env: base fixture missing: " .. base)
    os.execute("mkdir -p /tmp/jve")
    local cmd = string.format(
        "%s -y -v error -i %q -c copy -timecode 01:00:00:00 %q",
        find_ffmpeg(), base, TC_FIXTURE_PATH)
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, "render_env: ffmpeg failed: " .. cmd)
    assert(io.open(TC_FIXTURE_PATH, "r"),
        "render_env: ffmpeg produced no file: " .. TC_FIXTURE_PATH)
    return TC_FIXTURE_PATH
end

--------------------------------------------------------------------------------
-- Boot (once per batch process)
--------------------------------------------------------------------------------

-- Launch the app and import the fixture media through the real command.
-- Returns the shared context table.
function M.boot()
    if ctx then return ctx end

    local _, info = ui.launch({ project_name = "Timeline Render Tests" })

    local database = require("core.database")
    local project_id = assert(info.project and info.project.id,
        "render_env: launch info has no project id")

    local media_path = ensure_tc_fixture()
    local r = command_manager.execute("ImportMedia", {
        project_id = project_id,
        file_paths = { media_path },
    })
    assert(r and r.success, "render_env: ImportMedia failed: "
        .. tostring(r and r.error_message))

    -- The master sequence the import created (kind='master', via media path).
    local db = database.get_connection()
    local stmt = db:prepare([[
        SELECT s.id, s.fps_numerator, s.fps_denominator
        FROM sequences s
        JOIN media_refs mr ON mr.owner_sequence_id = s.id
        JOIN media m ON m.id = mr.media_id
        WHERE s.kind = 'master' AND m.file_path = ?
        LIMIT 1
    ]])
    assert(stmt, "render_env: master lookup prepare failed")
    stmt:bind_value(1, media_path)
    assert(stmt:exec() and stmt:next(), "render_env: master sequence not found after import")
    local master = {
        sequence_id = stmt:value(0),
        fps_numerator = stmt:value(1),
        fps_denominator = stmt:value(2),
    }
    stmt:finalize()

    local media_stmt = db:prepare("SELECT id FROM media WHERE file_path = ? LIMIT 1")
    assert(media_stmt, "render_env: media lookup prepare failed")
    media_stmt:bind_value(1, media_path)
    assert(media_stmt:exec() and media_stmt:next(), "render_env: media row not found")
    local media_id = media_stmt:value(0)
    media_stmt:finalize()

    ctx = {
        info = info,
        project_id = project_id,
        master = master,
        media_id = media_id,
        panel = require("ui.timeline.timeline_panel"),
        state = require("ui.timeline.timeline_state"),
    }
    M.pump(300)
    return ctx
end

function M.pump(ms)
    ui.pump(ms or 100)
end

--------------------------------------------------------------------------------
-- Per-test isolation: fresh sequence, opened in the timeline
--------------------------------------------------------------------------------

-- Create a new empty sequence and make it the displayed/active one.
-- Returns sequence_id.
function M.fresh_sequence(name)
    assert(ctx, "render_env.boot() first")
    local new_id = uuid.generate()
    local r = command_manager.execute("CreateSequence", {
        project_id        = ctx.project_id,
        sequence_id       = new_id,
        name              = name,
        frame_rate        = { fps_numerator = 24, fps_denominator = 1 },
        audio_sample_rate = 48000,
        width             = 1920,
        height            = 1080,
    })
    assert(r and r.success, "render_env: CreateSequence failed: "
        .. tostring(r and r.error_message))
    local o = command_manager.execute("OpenSequenceInTimeline", {
        project_id  = ctx.project_id,
        sequence_id = new_id,
    })
    assert(o and o.success, "render_env: OpenSequenceInTimeline failed: "
        .. tostring(o and o.error_message))
    M.pump(150)
    return new_id
end

-- Tracks of the displayed sequence, keyed by "V1"/"A1"-style labels.
function M.tracks()
    assert(ctx, "render_env.boot() first")
    local by_label = {}
    for _, t in ipairs(ctx.state.get_video_tracks()) do
        by_label["V" .. tostring(t.track_index)] = t
    end
    for _, t in ipairs(ctx.state.get_audio_tracks()) do
        by_label["A" .. tostring(t.track_index)] = t
    end
    return by_label
end

--------------------------------------------------------------------------------
-- Clip placement through the real command path
--------------------------------------------------------------------------------

-- Place clips via one AddClipsToSequence overwrite per clip spec.
-- specs: array of { track_id=, position=, duration= }.
-- Returns nothing; read resulting clips back from timeline state.
function M.place_clips(sequence_id, specs)
    assert(ctx, "render_env.boot() first")
    for _, s in ipairs(specs) do
        assert(s.track_id and s.position and s.duration,
            "render_env.place_clips: spec needs track_id/position/duration")
        local r = command_manager.execute("AddClipsToSequence", {
            project_id = ctx.project_id,
            sequence_id = sequence_id,
            position = s.position,
            edit_type = "overwrite",
            arrangement = "serial",
            groups = { {
                duration = s.duration,
                clips = { {
                    role = "video",
                    project_id = ctx.project_id,
                    media_id = ctx.media_id,
                    sequence_id = ctx.master.sequence_id,
                    fps_mismatch_policy = "resample",
                    name = string.format("clip@%d", s.position),
                    source_in = 0,
                    source_out = s.duration,
                    duration = s.duration,
                    fps_numerator = ctx.master.fps_numerator,
                    fps_denominator = ctx.master.fps_denominator,
                    target_track_id = s.track_id,
                } },
            } },
        })
        assert(r and r.success, string.format(
            "render_env.place_clips: overwrite at %d (%d frames) failed: %s",
            s.position, s.duration, tostring(r and r.error_message)))
    end
    M.pump(150)
end

-- Show frames [anchor, anchor+duration) — the same command the zoom
-- scroller dispatches.
function M.view_frames(duration_frames, anchor_frame)
    local r = command_manager.execute("ZoomTimelineViewport", {
        duration_frames = duration_frames,
        anchor_frame = anchor_frame or 0,
    })
    assert(r and r.success, "render_env: ZoomTimelineViewport failed: "
        .. tostring(r and r.error_message))
    M.pump(100)
end

--------------------------------------------------------------------------------
-- Real-gesture + draw-command helpers
--------------------------------------------------------------------------------

-- The view's registered mouse handler global (same path Qt events take).
function M.mouse_handler(widget)
    local hname = "tl_mouse_" .. tostring(widget):gsub("[^%w]", "_")
    local handler = _G[hname]
    assert(type(handler) == "function",
        "render_env: no mouse handler global " .. hname)
    return handler
end

-- Click (press+release) at view coordinates through the real handler.
function M.click(widget, x, y, opts)
    opts = opts or {}
    local h = M.mouse_handler(widget)
    h({ type = "press",   x = x, y = y, button = opts.button or 1,
        shift = opts.shift or false, alt = opts.alt or false,
        ctrl = opts.ctrl or false, command = opts.command or false })
    h({ type = "release", x = x, y = y, button = opts.button or 1,
        shift = opts.shift or false, alt = opts.alt or false,
        ctrl = opts.ctrl or false, command = opts.command or false })
    M.pump(50)
end

-- The displayed video view widget + its current width.
function M.video_widget()
    assert(ctx, "render_env.boot() first")
    local w = ctx.panel.video_widget
    assert(w, "render_env: panel has no video_widget")
    return w
end

function M.widget_width(widget)
    local w = select(1, timeline.get_dimensions(widget))
    assert(w and w > 0, "render_env: widget has no width")
    return w
end

-- Real pending draw commands of a renderer widget.
function M.draw_commands(widget)
    local cmds = timeline.get_commands(widget)
    assert(type(cmds) == "table", "render_env: get_commands returned nothing")
    return cmds
end

-- Rects from the queue, optionally filtered by color (exact "#rrggbb").
function M.rects(widget, color)
    local out = {}
    for _, c in ipairs(M.draw_commands(widget)) do
        if c.type == "rect" and (not color or c.color == color) then
            out[#out + 1] = c
        end
    end
    return out
end

-- The time→pixel map of the displayed tab at the view's real width.
function M.x_of(frame)
    assert(ctx, "render_env.boot() first")
    return ctx.state.time_to_pixel(frame, M.widget_width(M.video_widget()))
end

function M.colors()
    assert(ctx, "render_env.boot() first")
    return ctx.state.colors
end

function M.context()
    assert(ctx, "render_env.boot() first")
    return ctx
end

return M
