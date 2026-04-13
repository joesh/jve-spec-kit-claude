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

--- Get stored start timecode as (frames, rate).
-- If TC not in metadata and file exists on disk, extracts from file via EMP
-- and persists the result. Returns 0 for files with no TC tag (TC 00:00:00:00).
-- @return number|nil frames, number|nil rate
function M:get_start_tc()
    self:_ensure_tc_extracted()
    local meta = self:_parsed_metadata()
    -- Use ~= nil, not truthiness: start_tc_value=0 is valid (TC 00:00:00:00)
    if meta and meta.start_tc_value ~= nil then
        return meta.start_tc_value, meta.start_tc_rate
    end
    return nil, nil
end

--- Get audio TC origin in samples from metadata.
-- If TC not in metadata and file exists on disk, extracts from file via EMP.
-- @return number|nil samples, number|nil sample_rate
function M:get_audio_start_tc()
    self:_ensure_tc_extracted()
    local meta = self:_parsed_metadata()
    if meta and meta.start_tc_audio_samples ~= nil then
        return meta.start_tc_audio_samples, meta.start_tc_audio_rate
    end
    -- Derive from video TC if audio TC not stored separately
    if meta and meta.start_tc_value ~= nil and self.audio_sample_rate then
        local sr = self.audio_sample_rate
        local fps = meta.start_tc_rate
        assert(fps and fps > 0, string.format(
            "Media:get_audio_start_tc: start_tc_rate must be positive, got %s (media_id=%s)",
            tostring(fps), tostring(self.id)))
        local audio_tc = math.floor(meta.start_tc_value * sr / fps)
        -- Output bounds: audio TC can't be negative, can't exceed 24h at sample rate
        assert(audio_tc >= 0, string.format(
            "Media:get_audio_start_tc: derived audio_tc=%d is negative (video_tc=%d sr=%d fps=%d media_id=%s)",
            audio_tc, meta.start_tc_value, sr, fps, tostring(self.id)))
        local max_samples = 24 * 3600 * sr  -- 24 hours
        assert(audio_tc <= max_samples, string.format(
            "Media:get_audio_start_tc: derived audio_tc=%d exceeds 24h (%d samples) media_id=%s",
            audio_tc, max_samples, tostring(self.id)))
        return audio_tc, sr
    end
    return nil, nil
end

--- Get the file's original container TC (from DRP's TracksBA.StartTime).
-- Present only when a Set Timecode override was applied in the authoring NLE,
-- causing the displayed TC to differ from the file's container TC.
-- When absent (nil), file TC equals displayed TC (camera footage, no override).
-- @return number|nil frames at start_tc_rate, number|nil rate
function M:get_file_original_timecode()
    local meta = self:_parsed_metadata()
    if meta and meta.file_original_timecode ~= nil then
        return meta.file_original_timecode, meta.start_tc_rate
    end
    return nil, nil
end

--- Get the file's original container TC in audio samples.
-- Same semantics as get_file_original_timecode but in audio sample units.
-- @return number|nil samples at start_tc_audio_rate, number|nil rate
function M:get_file_original_timecode_audio()
    local meta = self:_parsed_metadata()
    if meta and meta.file_original_timecode_audio ~= nil then
        return meta.file_original_timecode_audio, meta.start_tc_audio_rate
    end
    return nil, nil
end

--- Explicitly extract TC origin from the media file and store in metadata.
-- Call this at import time when the file is guaranteed to exist.
-- Asserts on failure — if you're calling this, the file MUST be readable.
function M:extract_tc_from_file()
    local path = self._file_path
    assert(path and path ~= "", string.format(
        "Media:extract_tc_from_file: file_path required (media_id=%s)", tostring(self.id)))

    local EMP = qt_constants and qt_constants.EMP
    assert(EMP and EMP.MEDIA_FILE_OPEN,
        "Media:extract_tc_from_file: EMP bindings not available")

    local media_file = EMP.MEDIA_FILE_OPEN(path)
    assert(media_file, string.format(
        "Media:extract_tc_from_file: EMP failed to open %s", path))

    local info = EMP.MEDIA_FILE_INFO(media_file)
    EMP.MEDIA_FILE_CLOSE(media_file)
    assert(info, string.format(
        "Media:extract_tc_from_file: EMP returned no info for %s", path))

    -- EMP always returns these fields; nil means a broken binding
    assert(info.first_frame_tc ~= nil, string.format(
        "Media:extract_tc_from_file: EMP info missing first_frame_tc for %s", path))
    assert(info.first_sample_tc ~= nil, string.format(
        "Media:extract_tc_from_file: EMP info missing first_sample_tc for %s", path))

    local fps_num = info.fps_num
    if not fps_num or fps_num <= 0 then
        fps_num = self.frame_rate and self.frame_rate.fps_numerator
    end
    assert(fps_num and fps_num > 0, string.format(
        "Media:extract_tc_from_file: no valid fps for %s (info.fps_num=%s, media fps=%s)",
        path, tostring(info.fps_num),
        tostring(self.frame_rate and self.frame_rate.fps_numerator)))

    local sample_rate = info.audio_sample_rate
    if not sample_rate or sample_rate <= 0 then
        sample_rate = self.audio_sample_rate
    end

    local json = require("dkjson")
    local meta = self:_parsed_metadata() or {}
    meta.start_tc_value = info.first_frame_tc
    meta.start_tc_rate = fps_num
    meta.start_tc_audio_samples = info.first_sample_tc
    meta.start_tc_audio_rate = (sample_rate and sample_rate > 0) and sample_rate or nil

    self.metadata = json.encode(meta)

    log.event("Media:extract_tc_from_file: %s → video_tc=%d audio_tc=%d",
        tostring(self.id):sub(1, 8), meta.start_tc_value, meta.start_tc_audio_samples)
end

--- Extract TC origin from media file via EMP if not already in metadata.
-- Called lazily from get_start_tc()/get_audio_start_tc().
-- Only sets TC when extraction succeeds (file exists + EMP available).
-- Does NOT fabricate TC=0 when file is missing — that would hide real TC values.
-- Callers (ensure_masterclip) assert TC is known; import paths must provide it.
function M:_ensure_tc_extracted()
    -- Already have TC? (check ~= nil because 0 is valid)
    local meta = self:_parsed_metadata()
    if meta and meta.start_tc_value ~= nil then
        return
    end

    -- File must exist on disk
    local path = self._file_path
    if not path or path == "" then return end
    local f = io.open(path, "r")
    if not f then return end
    f:close()

    -- EMP must be available
    local EMP = qt_constants and qt_constants.EMP
    if not EMP or not EMP.MEDIA_FILE_OPEN then return end

    -- Open file, extract TC origins.
    -- If EMP is available and file exists, extraction MUST succeed — assert on failure.
    local media_file = EMP.MEDIA_FILE_OPEN(path)
    assert(media_file, string.format(
        "Media:_ensure_tc_extracted: EMP failed to open %s (media_id=%s)",
        path, tostring(self.id)))

    local info = EMP.MEDIA_FILE_INFO(media_file)
    EMP.MEDIA_FILE_CLOSE(media_file)
    assert(info, string.format(
        "Media:_ensure_tc_extracted: EMP returned no info for %s (media_id=%s)",
        path, tostring(self.id)))

    assert(info.first_frame_tc ~= nil,
        "Media:_ensure_tc_extracted: EMP info missing first_frame_tc for " .. path)
    assert(info.first_sample_tc ~= nil,
        "Media:_ensure_tc_extracted: EMP info missing first_sample_tc for " .. path)

    local fps_num = info.fps_num
    if not fps_num or fps_num <= 0 then
        fps_num = self.frame_rate and self.frame_rate.fps_numerator
    end
    -- fps_num can be 0/nil for audio-only files — that's valid
    -- (audio TC is in samples, doesn't need video fps)
    if not fps_num or fps_num <= 0 then fps_num = 0 end

    local sample_rate = info.audio_sample_rate
    if not sample_rate or sample_rate <= 0 then
        sample_rate = self.audio_sample_rate
    end

    -- Merge into existing metadata
    local json = require("dkjson")
    meta = meta or {}
    meta.start_tc_value = info.first_frame_tc
    meta.start_tc_rate = fps_num
    meta.start_tc_audio_samples = info.first_sample_tc
    meta.start_tc_audio_rate = (sample_rate and sample_rate > 0) and sample_rate or nil

    -- Update in-memory + persist to DB
    self.metadata = json.encode(meta)
    self:_save_metadata()

    log.event("Media:_ensure_tc_extracted: %s → video_tc=%d audio_tc=%d",
        tostring(self.id):sub(1, 8), info.first_frame_tc, info.first_sample_tc)
end

--- Persist only the metadata column to DB (minimal write for TC extraction).
function M:_save_metadata()
    local database = require("core.database")
    local db = assert(database.get_connection(),
        string.format("Media:_save_metadata: no database connection (media_id=%s)", tostring(self.id)))

    local stmt = assert(db:prepare("UPDATE media SET metadata = ? WHERE id = ?"),
        string.format("Media:_save_metadata: failed to prepare query (media_id=%s)", tostring(self.id)))
    stmt:bind_value(1, self.metadata)
    stmt:bind_value(2, self.id)
    assert(stmt:exec(),
        string.format("Media:_save_metadata: exec failed (media_id=%s): %s",
            tostring(self.id), tostring(stmt:last_error())))
    stmt:finalize()
end

function M:_parsed_metadata()
    local meta = self.metadata
    if not meta or meta == "" or meta == "{}" then
        return nil
    end
    if type(meta) == "string" then
        local json = require("dkjson")
        meta = json.decode(meta)
    end
    return type(meta) == "table" and meta or nil
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
    local dur_frames_input = params.duration_frames
    if params.duration and not dur_frames_input then
        error("Media.create: 'duration' is removed — use 'duration_frames' (integer frames). "
            .. "Convert ms→frames at the I/O boundary before calling Media.create.")
    end
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
        dur_frames = assert(tonumber(dur_frames_input), "Media.create: duration_frames must be a number, got " .. tostring(dur_frames_input))
    else
        dur_frames = 0 -- Unknown duration (audio-only, still image)
    end

    local media = {
        id = params.id or uuid.generate(),
        project_id = params.project_id,
        _file_path = file_path,
        file_uuid = params.file_uuid,  -- DRP master clip UUID for cross-volume dedup
        name = name,
        duration = dur_frames,  -- integer frames
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(params.width) or 0, -- NSF-OK: 0 = unknown dimension (audio-only media has no width)
        height = tonumber(params.height) or 0, -- NSF-OK: 0 = unknown dimension
        rotation = tonumber(params.rotation) or 0, -- NSF-OK: 0 = no rotation
        audio_sample_rate = tonumber(params.audio_sample_rate) or 0, -- NSF-OK: 0 = no audio or unknown
        audio_channels = tonumber(params.audio_channels) or 0, -- NSF-OK: 0 = unknown/not applicable
        codec = params.codec or "", -- NSF-OK: "" = unknown codec
        created_at = params.created_at or os.time(),
        modified_at = params.modified_at or os.time(),
        metadata = params.metadata or '{}',
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
               width, height, rotation, audio_sample_rate, audio_channels, codec,
               created_at, modified_at, metadata, file_uuid
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
        audio_sample_rate = tonumber(query:value(10)) or 0, -- NSF-OK: 0 = no audio
        audio_channels = tonumber(query:value(11)) or 0, -- NSF-OK: 0 = unknown
        codec = query:value(12),
        created_at = query:value(13),
        modified_at = query:value(14),
        metadata = query:value(15),
        file_uuid = query:value(16),  -- may be nil for non-DRP media
    }

    query:finalize()

    setmetatable(media, media_mt)
    return media
end

--- Find media ID by file path.
--- @param file_path string absolute path to media file
--- @return string|nil media_id
function M.find_id_by_path(file_path)
    assert(file_path and file_path ~= "", "Media.find_id_by_path: file_path required")
    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.find_id_by_path: no database connection")
    local stmt = assert(db:prepare("SELECT id FROM media WHERE file_path = ?"),
        "Media.find_id_by_path: failed to prepare query")
    stmt:bind_value(1, file_path)
    local media_id = nil
    if stmt:exec() and stmt:next() then
        media_id = stmt:value(0)
    end
    stmt:finalize()
    return media_id
end

--- Get all audio media records for a project (id + file_path).
--- Returns records with audio_sample_rate > 0.
--- @param project_id string
--- @return table array of {id=string, file_path=string}
function M.get_audio_for_project(project_id)
    assert(project_id and project_id ~= "", "Media.get_audio_for_project: project_id required")
    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.get_audio_for_project: no database connection")
    local stmt = assert(db:prepare(
        "SELECT id, file_path FROM media WHERE audio_sample_rate > 0 AND project_id = ?"),
        "Media.get_audio_for_project: failed to prepare query")
    stmt:bind_value(1, project_id)
    assert(stmt:exec(),
        string.format("Media.get_audio_for_project: query failed for project_id=%s", project_id))
    local result = {}
    while stmt:next() do
        result[#result + 1] = { id = stmt:value(0), file_path = stmt:value(1) }
    end
    stmt:finalize()
    return result
end

--- Get the source extent (min source_in, max source_out) across all clips on this media,
--- normalized to a common rate. Each clip's source_in/source_out is in its own native
--- units (video frames at clip fps, audio samples at sample rate). This function converts
--- every clip to target_rate before computing min/max.
--- @param target_rate number Rate to normalize to (typically media_start_tc_rate)
--- @return number|nil min_source_in, number|nil max_source_out (both in target_rate units)
function M:get_source_extent(target_rate)
    assert(target_rate and target_rate > 0,
        string.format("Media:get_source_extent: target_rate must be positive, got %s (media_id=%s)",
            tostring(target_rate), tostring(self.id)))
    local database = require("core.database")
    local db = assert(database.get_connection(),
        string.format("Media:get_source_extent: no database connection (media_id=%s)", tostring(self.id)))
    local stmt = assert(db:prepare([[
        SELECT source_in_frame, source_out_frame, fps_numerator, fps_denominator
        FROM clips WHERE media_id = ? AND clip_kind != 'master'
    ]]), "Media:get_source_extent: failed to prepare query")
    stmt:bind_value(1, self.id)
    assert(stmt:exec(), string.format(
        "Media:get_source_extent: query failed for media_id=%s", tostring(self.id)))

    local min_in, max_out
    while stmt:next() do
        local src_in = stmt:value(0)
        local src_out = stmt:value(1)
        local fps_num = stmt:value(2)
        local fps_den = stmt:value(3) or 1
        if src_in and src_out and fps_num and fps_num > 0 then
            local clip_rate = fps_num / fps_den
            -- Normalize to target_rate
            if math.abs(clip_rate - target_rate) > 0.01 then
                src_in = math.floor(src_in * target_rate / clip_rate + 0.5)
                src_out = math.floor(src_out * target_rate / clip_rate + 0.5)
            end
            if not min_in or src_in < min_in then min_in = src_in end
            if not max_out or src_out > max_out then max_out = src_out end
        end
    end
    stmt:finalize()
    return min_in, max_out
end

--- Get media rows with a Set Timecode override (file_original_timecode populated).
--- Returns the data needed to build a TMB TC override map:
--- the file path plus the displayed TC (start_tc_value) that should override
--- whatever EMP probes from the file's container.
--- @param project_id string
--- @return table array of {file_path, start_tc_value, start_tc_rate, start_tc_audio_samples, start_tc_audio_rate}
function M.find_tc_override_media(project_id)
    assert(project_id and project_id ~= "", "Media.find_tc_override_media: project_id required")
    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.find_tc_override_media: no database connection")
    local json = require("dkjson")
    local stmt = assert(db:prepare(
        "SELECT file_path, metadata FROM media WHERE project_id = ? AND metadata LIKE '%file_original_timecode%'"),
        "Media.find_tc_override_media: failed to prepare query")
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), string.format(
        "Media.find_tc_override_media: query failed for project_id=%s", project_id))
    local result = {}
    while stmt:next() do
        local path = stmt:value(0)
        local meta_str = stmt:value(1)
        if path and meta_str then
            local meta = json.decode(meta_str)
            if meta and meta.file_original_timecode then
                result[#result + 1] = {
                    file_path = path,
                    start_tc_value = meta.start_tc_value,
                    start_tc_rate = meta.start_tc_rate,
                    start_tc_audio_samples = meta.start_tc_audio_samples,
                    start_tc_audio_rate = meta.start_tc_audio_rate,
                }
            end
        end
    end
    stmt:finalize()
    return result
end

-- Save a media item to the database
function M:save()
    local database = require("core.database")
    local db = assert(database.get_connection(),
        string.format("Media:save: no database connection (media_id=%s)", tostring(self.id)))

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
        INSERT INTO media (id, project_id, name, file_path, file_uuid, duration_frames, fps_numerator, fps_denominator,
            width, height, rotation, audio_sample_rate, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            file_path = excluded.file_path,
            file_uuid = excluded.file_uuid,
            duration_frames = excluded.duration_frames,
            fps_numerator = excluded.fps_numerator,
            fps_denominator = excluded.fps_denominator,
            width = excluded.width,
            height = excluded.height,
            rotation = excluded.rotation,
            audio_sample_rate = excluded.audio_sample_rate,
            audio_channels = excluded.audio_channels,
            codec = excluded.codec,
            modified_at = excluded.modified_at,
            metadata = excluded.metadata
    ]])

    assert(query, string.format("Media:save: failed to prepare query (media_id=%s)", tostring(self.id)))

    query:bind_value(1, self.id)
    query:bind_value(2, self.project_id)
    query:bind_value(3, self.name)
    query:bind_value(4, self._file_path)
    query:bind_value(5, self.file_uuid)  -- nullable (non-DRP media won't have one)
    query:bind_value(6, dur_frames)
    query:bind_value(7, num)
    query:bind_value(8, den)
    query:bind_value(9, self.width)
    query:bind_value(10, self.height)
    query:bind_value(11, self.rotation or 0)
    query:bind_value(12, self.audio_sample_rate or 0)
    query:bind_value(13, self.audio_channels)
    query:bind_value(14, self.codec)
    query:bind_value(15, self.created_at)
    query:bind_value(16, self.modified_at)
    query:bind_value(17, self.metadata)

    if not query:exec() then
        log.warn("Media:save: Query execution failed: %s", query:last_error())
        query:finalize()
        return false
    end

    query:finalize()

    return true
end

--- Delete this media record and all clips referencing it.
-- @return boolean success
function M:delete()
    local database = require("core.database")
    local db = assert(database.get_connection(), "Media:delete: no database connection")
    assert(self.id and self.id ~= "", "Media:delete: id required")

    -- Delete properties and clip_links for clips referencing this media
    -- (properties table has no FK cascade — must clean up explicitly)
    local clip_ids_stmt = db:prepare("SELECT id FROM clips WHERE media_id = ?")
    if clip_ids_stmt then
        clip_ids_stmt:bind_value(1, self.id)
        if clip_ids_stmt:exec() then
            while clip_ids_stmt:next() do
                local cid = clip_ids_stmt:value(0)
                local prop_stmt = db:prepare("DELETE FROM properties WHERE clip_id = ?")
                if prop_stmt then
                    prop_stmt:bind_value(1, cid)
                    prop_stmt:exec()
                    prop_stmt:finalize()
                end
                local link_stmt = db:prepare("DELETE FROM clip_links WHERE clip_id = ?")
                if link_stmt then
                    link_stmt:bind_value(1, cid)
                    link_stmt:exec()
                    link_stmt:finalize()
                end
            end
        end
        clip_ids_stmt:finalize()
    end

    -- Delete clips referencing this media (FK constraint)
    local del_clips = assert(db:prepare("DELETE FROM clips WHERE media_id = ?"),
        "Media:delete: failed to prepare clip delete")
    del_clips:bind_value(1, self.id)
    del_clips:exec()
    del_clips:finalize()

    -- Delete the media record
    local del_media = assert(db:prepare("DELETE FROM media WHERE id = ?"),
        "Media:delete: failed to prepare media delete")
    del_media:bind_value(1, self.id)
    if not del_media:exec() then
        local err = del_media:last_error()
        del_media:finalize()
        error(string.format("Media:delete: failed to delete media %s: %s", self.id, err))
    end
    del_media:finalize()

    log.event("Media:delete: deleted media %s", self.id)
    return true
end

return M
