--- Media model: persistence + change notification for media file records
--
-- Responsibilities:
-- - CRUD for media table rows
-- - file_path is private (_file_path) — use get_file_path()/set_file_path()
-- - Batch change support: begin_batch()/end_batch() coalesce media_changed signal
--
-- Invariants:
-- - Direct writes to media.file_path assert (must use set_file_path)
-- - end_batch emits one "media_changed" signal with full set of changed media_ids
-- - Unbalanced begin/end asserts
--
-- @file media.lua
local uuid = require("uuid")
local log = require("core.logger").for_area("media")

local M = {}

-- ---------------------------------------------------------------------------
-- Batch change tracking
-- ---------------------------------------------------------------------------
local batch_depth = 0
local batch_changed_ids = {}  -- {[media_id] = true}

function M.begin_batch()
    batch_depth = batch_depth + 1
end

function M.end_batch()
    batch_depth = batch_depth - 1
    assert(batch_depth >= 0, "Media.end_batch: unbalanced begin/end")
    if batch_depth == 0 and next(batch_changed_ids) then
        local changed = batch_changed_ids
        batch_changed_ids = {}
        local Signals = require("core.signals")
        Signals.emit("media_changed", changed)
    end
end

local function mark_dirty(media_id)
    if batch_depth > 0 then
        batch_changed_ids[media_id] = true
    else
        local Signals = require("core.signals")
        Signals.emit("media_changed", {[media_id] = true})
    end
end

-- ---------------------------------------------------------------------------
-- Metatable: file_path access control
-- ---------------------------------------------------------------------------
-- __index: media.file_path reads return _file_path; methods come from M
-- __newindex: media.file_path = x asserts (must use set_file_path)
local media_mt = {
    __index = function(self, key)
        if key == "file_path" then
            return rawget(self, "_file_path")
        end
        return M[key]
    end,
    __newindex = function(self, key, value)
        if key == "file_path" then
            error("Media: use set_file_path() to change file_path (media_id="
                .. tostring(rawget(self, "id")) .. ")", 2)
        end
        rawset(self, key, value)
    end
}

-- ---------------------------------------------------------------------------
-- Accessors
-- ---------------------------------------------------------------------------

function M:get_file_path()
    return self._file_path
end

function M:set_file_path(path)
    assert(path and path ~= "",
        string.format("Media:set_file_path: path required (media_id=%s)", tostring(self.id)))
    self._file_path = path
    mark_dirty(self.id)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Helper to decompose float rate to num/den (simplified for migration)
local function rate_from_float(fps)
    assert(fps, "rate_from_float: fps must not be nil")
    assert(type(fps) == "number" and fps > 0, "rate_from_float: fps must be a positive number, got: " .. tostring(fps))
    -- Common NTSC values
    if math.abs(fps - 29.97) < 0.01 then return 30000, 1001 end
    if math.abs(fps - 23.976) < 0.01 then return 24000, 1001 end
    if math.abs(fps - 59.94) < 0.01 then return 60000, 1001 end
    return math.floor(fps + 0.5), 1
end

-- ---------------------------------------------------------------------------
-- Create / Load / Save
-- ---------------------------------------------------------------------------

-- Create a new media item
function M.create(file_path_or_params, file_name, duration, frame_rate, metadata)
    local params

    if type(file_path_or_params) == "table" then
        params = file_path_or_params
    else
        params = {
            file_path = file_path_or_params,
            name = file_name,
            duration = duration,
            frame_rate = frame_rate,
            metadata = metadata
        }
    end

    local file_path = params.file_path
    local name = params.name or params.file_name
    local dur_input = params.duration
    local dur_frames_input = params.duration_frames
    local fps_input = params.frame_rate

    local num, den
    if type(fps_input) == "table" and fps_input.fps_numerator then
        num, den = fps_input.fps_numerator, fps_input.fps_denominator
    elseif params.fps_numerator and params.fps_denominator then
        num, den = params.fps_numerator, params.fps_denominator
    else
        num, den = rate_from_float(tonumber(fps_input))
    end

    local dur_frames
    if dur_frames_input then
        -- If duration_frames provided, use directly (integer)
        dur_frames = assert(tonumber(dur_frames_input), "Media.create: duration_frames must be a number, got " .. tostring(dur_frames_input))
    elseif dur_input then
        -- Milliseconds -> frames (I/O boundary conversion)
        assert(type(dur_input) == "number", "Media.create: duration must be integer ms, got " .. type(dur_input))
        local dur_ms = dur_input
        local seconds = dur_ms / 1000.0
        dur_frames = math.floor(seconds * num / den + 0.5)
    else
        dur_frames = 0 -- Unknown duration (audio-only, still image)
    end

    local media = {
        id = params.id or uuid.generate(),
        project_id = params.project_id,
        _file_path = file_path,
        name = name,
        duration = dur_frames,  -- integer frames
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(params.width) or 0, -- NSF-OK: 0 = unknown dimension (audio-only media has no width)
        height = tonumber(params.height) or 0, -- NSF-OK: 0 = unknown dimension
        rotation = tonumber(params.rotation) or 0, -- NSF-OK: 0 = no rotation
        audio_channels = tonumber(params.audio_channels) or 0, -- NSF-OK: 0 = unknown/not applicable
        codec = params.codec or "", -- NSF-OK: "" = unknown codec
        created_at = params.created_at or os.time(),
        modified_at = params.modified_at or os.time(),
        metadata = params.metadata or '{}'
    }

    setmetatable(media, media_mt)
    return media
end

-- Load a media item from the database
function M.load(media_id)
    assert(media_id and media_id ~= "", "Media.load: media_id must not be nil or empty")

    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.load: no database connection available")

    local query = assert(db:prepare([[
        SELECT id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
               width, height, rotation, audio_channels, codec, created_at, modified_at, metadata
        FROM media WHERE id = ?
    ]]), string.format("Media.load: failed to prepare query for media_id=%s", media_id))

    query:bind_value(1, media_id)

    if not query:exec() then
        error(string.format("Media.load: query execution failed for media_id=%s: %s", media_id, query:last_error()))
    end

    if not query:next() then
        query:finalize()
        return nil -- NSF-OK: nil = "not found" (distinct from DB error, which asserts above)
    end

    local frames = query:value(4) or 0 -- NSF-OK: 0 frames = still-image or unknown-duration media
    local num = query:value(5)
    local den = query:value(6)
    assert(num, string.format("Media.load: fps_numerator is NULL for media_id=%s", tostring(media_id)))
    assert(den, string.format("Media.load: fps_denominator is NULL for media_id=%s", tostring(media_id)))

    local media = {
        id = query:value(0),
        project_id = query:value(1),
        name = query:value(2),
        _file_path = query:value(3),
        duration = frames,  -- integer frames
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(query:value(7)) or 0, -- NSF-OK: 0 = unknown dimension
        height = tonumber(query:value(8)) or 0, -- NSF-OK: 0 = unknown dimension
        rotation = tonumber(query:value(9)) or 0, -- NSF-OK: 0 = no rotation
        audio_channels = tonumber(query:value(10)) or 0, -- NSF-OK: 0 = unknown
        codec = query:value(11),
        created_at = query:value(12),
        modified_at = query:value(13),
        metadata = query:value(14)
    }

    query:finalize()

    setmetatable(media, media_mt)
    return media
end

-- Save a media item to the database
function M:save()
    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        log.warn("Media:save: No database connection available")
        return false
    end

    -- Duration is now an integer
    assert(type(self.duration) == "number", "Media:save: duration must be integer for media " .. tostring(self.id))
    local dur_frames = self.duration

    -- Handle Rate
    local num = (self.frame_rate and self.frame_rate.fps_numerator) or self.fps_numerator
    local den = (self.frame_rate and self.frame_rate.fps_denominator) or self.fps_denominator
    assert(den and den > 0, string.format("Media:save: Invalid fps_denominator for media %s (den=%s)", tostring(self.id), tostring(den)))

    if not num or num <= 0 then
        error(string.format("Media:save: Invalid frame rate for media %s (num=%s)", self.id, tostring(num)))
    end

    local query = db:prepare([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, rotation, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            file_path = excluded.file_path,
            duration_frames = excluded.duration_frames,
            fps_numerator = excluded.fps_numerator,
            fps_denominator = excluded.fps_denominator,
            width = excluded.width,
            height = excluded.height,
            rotation = excluded.rotation,
            audio_channels = excluded.audio_channels,
            codec = excluded.codec,
            modified_at = excluded.modified_at,
            metadata = excluded.metadata
    ]])

    if not query then
        log.warn("Media:save: Failed to prepare query")
        return false
    end

    query:bind_value(1, self.id)
    query:bind_value(2, self.project_id)
    query:bind_value(3, self.name)
    query:bind_value(4, self._file_path)
    query:bind_value(5, dur_frames)
    query:bind_value(6, num)
    query:bind_value(7, den)
    query:bind_value(8, self.width)
    query:bind_value(9, self.height)
    query:bind_value(10, self.rotation or 0)
    query:bind_value(11, self.audio_channels)
    query:bind_value(12, self.codec)
    query:bind_value(13, self.created_at)
    query:bind_value(14, self.modified_at)
    query:bind_value(15, self.metadata)

    if not query:exec() then
        log.warn("Media:save: Query execution failed: %s", query:last_error())
        query:finalize()
        return false
    end

    query:finalize()

    return true
end

return M
