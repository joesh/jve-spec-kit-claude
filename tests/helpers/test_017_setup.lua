-- Shared setup for 017 (two-engine playback model) tests.
-- Provides stub qt_constants, a fresh DB with one project + a master and
-- a record sequence, and the loaded modules. Each test gets a clean
-- database file in /tmp/jve named after its caller.

local M = {}

--- Install a stub qt_constants module that satisfies all the C++ FFI
--- entrypoints exercised by PlaybackEngine + audio_playback during a
--- transport refactor test run. Optionally records selected calls into
--- `call_log` so tests can verify ordering invariants.
--- @param call_log table|nil  optional array; if provided, selected FFI
---   calls are appended as strings in issue order.
function M.install_qt_stub(call_log)
    local function rec(name)
        if call_log then call_log[#call_log + 1] = name end
    end
    package.loaded["core.qt_constants"] = {
        PLAYBACK = {
            CREATE = function() return "stub_pc" end,
            CLOSE  = function() end,
            SET_LOG_TAG = function(_, tag) rec("SET_LOG_TAG:" .. tostring(tag)) end,
            SET_TMB = function() end,
            SET_BOUNDS = function() end,
            SET_SURFACE = function() end,
            SET_CLIP_PROVIDER = function() end,
            SET_POSITION_CALLBACK = function() end,
            SET_CLIP_TRANSITION_CALLBACK = function() end,
            STOP = function() rec("PLAYBACK.STOP") end,
            PLAY = function() rec("PLAYBACK.PLAY") end,
            PARK = function() rec("PLAYBACK.PARK") end,
            SEEK = function() rec("PLAYBACK.SEEK") end,
            HAS_AUDIO = function() return true end,
            ACTIVATE_AUDIO = function() rec("PLAYBACK.ACTIVATE_AUDIO") end,
            DEACTIVATE_AUDIO = function() rec("PLAYBACK.DEACTIVATE_AUDIO") end,
            SET_SHUTTLE_MODE = function() end,
            PLAY_BURST = function() end,
            RELOAD_ALL_CLIPS = function() end,
        },
        EMP = {
            TMB_CREATE = function() return "stub_tmb" end,
            TMB_CLOSE = function() end,
            TMB_PARK_READERS = function() end,
            TMB_SET_SEQUENCE_RATE = function() end,
            TMB_SET_AUDIO_FORMAT = function() end,
            TMB_SET_SEQUENCE_RESOLUTION = function() end,
            TMB_SET_AUDIO_MIX_PARAMS = function() end,
            TMB_INVALIDATE_PATH = function() end,
            TMB_CLEAR_OFFLINE = function() end,
            -- engine:seek (called inside engine:load) pulls a frame from
            -- the renderer, which asserts on TMB_GET_VIDEO_FRAME's
            -- metadata table. Return a "no content here" descriptor so
            -- the renderer takes its empty-frame path; tests don't
            -- assert on pixel output.
            TMB_GET_VIDEO_FRAME = function()
                return nil, { offline = false, media_path = nil }
            end,
            TMB_GET_AUDIO_AT = function() return nil end,
            TMB_SET_AUDIO_MIX_PARAMS_FOR_CLIP = function() end,
            TMB_GET_CONTAINS_MEDIUM = function() return false end,
        },
        AOP = {
            OPEN = function() return "stub_aop" end,
            CLOSE = function() rec("AOP.CLOSE") end,
            START = function() rec("AOP.START") end,
            STOP  = function() rec("AOP.STOP") end,
            FLUSH = function() end,
            PLAYHEAD_US = function() return 0 end,
            SAMPLE_RATE = function() return 48000 end,
            CHANNELS = function() return 2 end,
            HAD_UNDERRUN = function() return false end,
            CLEAR_UNDERRUN = function() end,
        },
        SSE = {
            CREATE = function() return "stub_sse" end,
            CLOSE = function() end,
            RESET = function() end,
            SET_TARGET = function() end,
        },
    }
end

--- Open a fresh project DB, schema-loaded, with one project + a master
--- and a sequence row ready to use. Returns the project id and a list
--- of {master_id, record_id}.
function M.fresh_project_db(db_name)
    assert(type(db_name) == "string" and db_name ~= "",
        "fresh_project_db: db_name required")
    local database = require("core.database")
    local DB = "/tmp/jve/" .. db_name
    os.remove(DB); os.execute("mkdir -p /tmp/jve")
    database.init(DB)
    local db = database.get_connection()
    db:exec(require("import_schema"))
    local now = os.time()
    db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
            VALUES ('p','P','resample',%d,%d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, playhead_frame, view_start_frame,
            view_duration_frames, start_timecode_frame, created_at, modified_at)
            -- 018 FR-004: masters carry NULL audio_sample_rate (per-media_ref rate).
            VALUES ('rec','p','Rec','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d),
                   ('src','p','SrcMaster','master',24,1,NULL,1920,1080,0,0,300,0,%d,%d);
    ]], now, now, now, now, now, now))
    return { project_id = "p", master_id = "src", record_id = "rec", database = database }
end

return M
