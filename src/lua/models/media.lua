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

--- Public entrypoint for callers that change media ownership of a row
--- without going through set_file_path/save — e.g., commands that retarget
--- a clip's media_id and want the downstream "media_changed" listeners
--- (offline probes, viewers, peak caches) to refresh for that media too.
--- Respects the begin_batch/end_batch wrapper exactly like save does.
function M.mark_dirty(media_id)
    assert(media_id and media_id ~= "",
        "Media.mark_dirty: media_id required")
    mark_dirty(media_id)
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

--- Merge a probed_tc record into an existing metadata JSON string, returning
--- a new JSON string. probed_tc has the shape produced by
--- media_relinker.probed_tc_for_metadata: {start_tc_value, start_tc_rate,
--- start_tc_audio_samples?, start_tc_audio_rate?}. Preserves unrelated
--- metadata fields (e.g. file_original_timecode) unchanged.
--- When probed_tc lacks audio fields (e.g. video-only file, or file without
--- any audio stream), existing audio TC fields are cleared — they referred
--- to a different file and would be wrong for the newly-linked one.
function M.merge_probed_tc_into_metadata(existing_metadata_json, probed_tc)
    assert(type(probed_tc) == "table",
        "Media.merge_probed_tc_into_metadata: probed_tc table required")
    assert(probed_tc.start_tc_value and probed_tc.start_tc_rate,
        "Media.merge_probed_tc_into_metadata: probed_tc must have start_tc_value and start_tc_rate")

    local json = require("dkjson")
    local meta
    if existing_metadata_json == nil or existing_metadata_json == ""
            or existing_metadata_json == "{}" then
        meta = {}
    else
        meta = json.decode(existing_metadata_json)
        assert(type(meta) == "table", string.format(
            "Media.merge_probed_tc_into_metadata: malformed metadata JSON: %q",
            existing_metadata_json))
    end

    meta.start_tc_value = probed_tc.start_tc_value
    meta.start_tc_rate = probed_tc.start_tc_rate
    meta.start_tc_audio_samples = probed_tc.start_tc_audio_samples  -- nil clears
    meta.start_tc_audio_rate = probed_tc.start_tc_audio_rate

    return json.encode(meta)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Image codecs known to represent single-frame still media.
local STILL_IMAGE_CODECS = {
    mjpeg = true, jpeg = true, jpg = true,
    png = true, apng = true,
    tiff = true, tif = true,
    bmp = true, gif = true,
    webp = true, heic = true, heif = true,
}

--- Classify a media file as a still image.
-- Rule: codec is a known image codec, OR the media has video dimensions
-- and exactly one frame of duration. Pure function, no side effects.
-- @param codec string|nil codec name (nil/"" means unknown codec)
-- @param width number|nil pixel width (nil/0 means no video — audio-only, compound, or unknown)
-- @param duration_frames number integer frames in native timebase (must be > 0)
-- @return boolean
function M.classify_is_still(codec, width, duration_frames)
    assert(type(duration_frames) == "number" and duration_frames > 0, string.format(
        "Media.classify_is_still: duration_frames must be a positive number, got %s",
        tostring(duration_frames)))
    assert(width == nil or type(width) == "number", string.format(
        "Media.classify_is_still: width must be a number or nil, got %s", type(width)))
    if codec and codec ~= "" and STILL_IMAGE_CODECS[codec:lower()] then
        return true
    end
    if width and width > 0 and duration_frames == 1 then
        return true
    end
    return false
end

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
        is_still = params.is_still and true or false, -- NSF-OK: nil = not still (default)
        created_at = params.created_at or os.time(),
        modified_at = params.modified_at or os.time(),
        metadata = params.metadata or '{}',
    }

    setmetatable(media, media_mt)
    return media
end

-- Column list for all SELECTs that hydrate Media instances. Keep in the exact
-- order the _hydrate_row helper reads. Any caller of _hydrate_row MUST use
-- this SELECT list (or a prefix fully matching these columns).
local MEDIA_SELECT_COLUMNS = [[
        id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, rotation, audio_sample_rate, audio_channels, codec,
        created_at, modified_at, metadata, file_uuid, is_still, offline_note
]]

-- Hydrate a single Media instance from the current row of a prepared statement
-- whose SELECT list is MEDIA_SELECT_COLUMNS. Does NOT advance the cursor or
-- finalize the statement. Asserts on NULL fields that the schema forbids.
local function _hydrate_row(query)
    local id = query:value(0)
    local frames = query:value(4) or 0 -- NSF-OK: 0 = still-image / unknown-duration
    local num = query:value(5)
    local den = query:value(6)
    assert(num, string.format("Media._hydrate_row: fps_numerator is NULL for media_id=%s", tostring(id)))
    assert(den, string.format("Media._hydrate_row: fps_denominator is NULL for media_id=%s", tostring(id)))

    local media = {
        id = id,
        project_id = query:value(1),
        name = query:value(2),
        _file_path = query:value(3),
        duration = frames,
        frame_rate = { fps_numerator = num, fps_denominator = den },
        width = tonumber(query:value(7)) or 0,
        height = tonumber(query:value(8)) or 0,
        rotation = tonumber(query:value(9)) or 0,
        audio_sample_rate = tonumber(query:value(10)) or 0,
        audio_channels = tonumber(query:value(11)) or 0,
        codec = query:value(12),
        created_at = query:value(13),
        modified_at = query:value(14),
        metadata = query:value(15),
        file_uuid = query:value(16),
    }
    local is_still_raw = query:value(17)
    assert(is_still_raw ~= nil, string.format(
        "Media._hydrate_row: is_still is NULL for media_id=%s (schema corruption)", tostring(id)))
    media.is_still = tonumber(is_still_raw) == 1
    -- NULL when relink succeeded (or was never run) — see schema.sql for shape.
    media.offline_note = query:value(18)

    setmetatable(media, media_mt)
    return media
end

-- Load a media item from the database
function M.load(media_id)
    assert(media_id and media_id ~= "", "Media.load: media_id must not be nil or empty")

    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.load: no database connection available")

    local query = assert(db:prepare("SELECT " .. MEDIA_SELECT_COLUMNS .. " FROM media WHERE id = ?"),
        string.format("Media.load: failed to prepare query for media_id=%s", media_id))

    query:bind_value(1, media_id)

    if not query:exec() then
        error(string.format("Media.load: query execution failed for media_id=%s: %s", media_id, query:last_error()))
    end

    if not query:next() then
        query:finalize()
        return nil -- NSF-OK: nil = "not found" (distinct from DB error, which asserts above)
    end

    local media = _hydrate_row(query)
    query:finalize()
    return media
end

--- Load every media row for a project in one SQL round-trip.
-- Replaces the per-row Media.load pattern used by the relinker for projects
-- with hundreds of media — one query instead of N. Caller filters proxies,
-- offline state, etc.
-- @param project_id string
-- @return table array of Media instances (may be empty)
function M.load_for_project(project_id)
    assert(project_id and project_id ~= "", "Media.load_for_project: project_id required")
    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.load_for_project: no database connection")

    local query = assert(db:prepare(
        "SELECT " .. MEDIA_SELECT_COLUMNS .. " FROM media WHERE project_id = ?"),
        "Media.load_for_project: failed to prepare query")
    query:bind_value(1, project_id)
    assert(query:exec(), string.format(
        "Media.load_for_project: query execution failed for project_id=%s: %s",
        project_id, query:last_error()))

    local results = {}
    while query:next() do
        results[#results + 1] = _hydrate_row(query)
    end
    query:finalize()
    return results
end

--- Load a set of media rows by id in one SQL round-trip.
-- Chunks into IN-clauses of up to SQLITE_MAX_VARIABLE_NUMBER (default 32766
-- on modern SQLite, but we stay conservative at 500). Asserts on duplicates
-- in the input; returns results in the order SQLite emits them (unsorted).
-- @param media_ids table array of media_id strings
-- @return table array of Media instances (may be shorter than media_ids if
--         some ids don't exist — caller can compare counts for fail-fast)
function M.load_many(media_ids)
    assert(type(media_ids) == "table", "Media.load_many: media_ids array required")
    if #media_ids == 0 then return {} end

    local database = require("core.database")
    local db = assert(database.get_connection(), "Media.load_many: no database connection")

    local results = {}
    local CHUNK = 500
    for chunk_start = 1, #media_ids, CHUNK do
        local chunk_end = math.min(chunk_start + CHUNK - 1, #media_ids)
        local n = chunk_end - chunk_start + 1

        local phs = {}
        for i = 1, n do phs[i] = "?" end
        local sql = string.format(
            "SELECT %s FROM media WHERE id IN (%s)",
            MEDIA_SELECT_COLUMNS, table.concat(phs, ","))

        local stmt = assert(db:prepare(sql), "Media.load_many: failed to prepare query")
        for i = 1, n do
            stmt:bind_value(i, media_ids[chunk_start + i - 1])
        end
        assert(stmt:exec(), "Media.load_many: query execution failed")
        while stmt:next() do
            results[#results + 1] = _hydrate_row(stmt)
        end
        stmt:finalize()
    end
    return results
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
    -- V13: clip.source_in/out are in the NESTED sequence's timebase. Walk
    -- clips → nested → master.media_refs to find clips referencing this
    -- media. fps_numerator/denominator come from the nested sequence (the
    -- clip's source-side timebase).
    local stmt = assert(db:prepare([[
        SELECT c.source_in_frame, c.source_out_frame,
               nested.fps_numerator, nested.fps_denominator
        FROM clips c
        JOIN sequences nested ON nested.id = c.nested_sequence_id
        JOIN media_refs mr ON mr.owner_sequence_id = c.nested_sequence_id
        WHERE mr.media_id = ?
    ]]), "Media:get_source_extent: failed to prepare query")
    stmt:bind_value(1, self.id)
    assert(stmt:exec(), string.format(
        "Media:get_source_extent: query failed for media_id=%s", tostring(self.id)))

    local min_in, max_out
    while stmt:next() do
        local src_in = stmt:value(0)
        local src_out = stmt:value(1)
        local fps_num = stmt:value(2)
        local fps_den = stmt:value(3)
        -- All four columns are NOT NULL with CHECK constraints in schema.sql
        -- (source_in_frame/out_frame NOT NULL; fps_num/den NOT NULL CHECK > 0).
        -- Nil/zero here means data corruption that bypassed the schema —
        -- assert with media context so the bad row is identifiable.
        assert(src_in, string.format(
            "Media:get_source_extent: clip on media %s has NULL source_in_frame", tostring(self.id)))
        assert(src_out, string.format(
            "Media:get_source_extent: clip on media %s has NULL source_out_frame", tostring(self.id)))
        assert(fps_num and fps_num > 0, string.format(
            "Media:get_source_extent: clip on media %s has invalid fps_numerator=%s",
            tostring(self.id), tostring(fps_num)))
        assert(fps_den and fps_den > 0, string.format(
            "Media:get_source_extent: clip on media %s has invalid fps_denominator=%s",
            tostring(self.id), tostring(fps_den)))

        local clip_rate = fps_num / fps_den
        -- Normalize to target_rate
        if math.abs(clip_rate - target_rate) > 0.01 then
            src_in = math.floor(src_in * target_rate / clip_rate + 0.5)
            src_out = math.floor(src_out * target_rate / clip_rate + 0.5)
        end
        if not min_in or src_in < min_in then min_in = src_in end
        if not max_out or src_out > max_out then max_out = src_out end
    end
    stmt:finalize()
    return min_in, max_out
end

-- ---------------------------------------------------------------------------
-- batch_set_file_paths helpers (rule 2.5: read-like-an-algorithm decomposition)
-- ---------------------------------------------------------------------------

--- Validate path_changes shape and collect the media_ids into an array.
local function collect_path_change_ids(path_changes)
    local ids = {}
    for mid, new_path in pairs(path_changes) do
        assert(new_path and new_path ~= "", string.format(
            "Media.batch_set_file_paths: empty path for %s", tostring(mid)))
        ids[#ids + 1] = mid
    end
    return ids
end

--- Chunked SELECT of the {file_path, metadata} for each id, returned as
--- {[media_id] = {file_path, metadata}}. Asserts every requested id exists.
local function capture_existing_file_state(db, ids)
    local CHUNK = 500
    local out = {}
    for chunk_start = 1, #ids, CHUNK do
        local chunk_end = math.min(chunk_start + CHUNK - 1, #ids)
        local n = chunk_end - chunk_start + 1
        local phs = {}
        for i = 1, n do phs[i] = "?" end
        local stmt = assert(db:prepare(string.format(
            "SELECT id, file_path, metadata FROM media WHERE id IN (%s)",
            table.concat(phs, ","))),
            "Media.batch_set_file_paths: failed to prepare read query")
        for i = 1, n do stmt:bind_value(i, ids[chunk_start + i - 1]) end
        assert(stmt:exec(),
            "Media.batch_set_file_paths: read query execution failed")
        while stmt:next() do
            out[stmt:value(0)] = {
                file_path = stmt:value(1),
                metadata = stmt:value(2),
            }
        end
        stmt:finalize()
    end
    for _, mid in ipairs(ids) do
        assert(out[mid] ~= nil, string.format(
            "Media.batch_set_file_paths: media not found: %s", tostring(mid)))
    end
    return out
end

--- Apply one path+metadata UPDATE per row. Path always changes; metadata
--- changes only for rows in tc_updates. Two prepared statements avoid
--- touching columns the row doesn't need and sidestep per-row branching in
--- SQL parse/plan cost.
local function apply_file_state_updates(db, path_changes, tc_updates, old_state)
    local upd_path = assert(db:prepare(
        "UPDATE media SET file_path = ? WHERE id = ?"),
        "Media.batch_set_file_paths: failed to prepare path-update query")
    local upd_both = assert(db:prepare(
        "UPDATE media SET file_path = ?, metadata = ? WHERE id = ?"),
        "Media.batch_set_file_paths: failed to prepare path+metadata update query")

    for mid, new_path in pairs(path_changes) do
        local probed_tc = tc_updates and tc_updates[mid]
        if probed_tc then
            local new_meta = M.merge_probed_tc_into_metadata(
                old_state[mid].metadata, probed_tc)
            upd_both:bind_value(1, new_path)
            upd_both:bind_value(2, new_meta)
            upd_both:bind_value(3, mid)
            assert(upd_both:exec(), string.format(
                "Media.batch_set_file_paths: path+metadata update exec failed for %s",
                tostring(mid)))
            upd_both:reset()
        else
            upd_path:bind_value(1, new_path)
            upd_path:bind_value(2, mid)
            assert(upd_path:exec(), string.format(
                "Media.batch_set_file_paths: path update exec failed for %s",
                tostring(mid)))
            upd_path:reset()
        end
        mark_dirty(mid)
    end
    upd_path:finalize()
    upd_both:finalize()
end

--- Atomically update each Media row's linked-file state (path and, when
--- supplied, TC metadata). Both fields describe the currently-linked file,
--- so they must move together: when relink repoints a row at a new file,
--- the TC metadata from the new file must replace the old file's TC.
---
--- tc_updates entries override only the start_tc_* fields in the existing
--- metadata JSON; unrelated fields (e.g. file_original_timecode) are kept.
--- Rows in path_changes without a matching tc_updates entry get their path
--- updated but metadata untouched (caller didn't supply a probed TC, e.g.
--- candidate had no authoritative TC source).
---
--- @param path_changes table {[media_id] = new_path}
--- @param tc_updates   table|nil {[media_id] = probed_tc}
--- @return table {[media_id] = {file_path=string, metadata=string}} old state
function M.batch_set_file_paths(path_changes, tc_updates)
    assert(type(path_changes) == "table",
        "Media.batch_set_file_paths: path_changes table required")
    assert(tc_updates == nil or type(tc_updates) == "table",
        "Media.batch_set_file_paths: tc_updates must be table or nil")

    -- tc_updates keys must be a subset of path_changes keys. A stray
    -- tc_updates entry (e.g. planner wrote TC for a media_id whose path
    -- didn't actually change) would never be applied — metadata would
    -- silently stay at the pre-relink file's TC and peak_cache would
    -- compute wrong sample positions with no error surfaced.
    if tc_updates then
        for mid in pairs(tc_updates) do
            assert(path_changes[mid] ~= nil, string.format(
                "Media.batch_set_file_paths: tc_updates contains %s but "
                .. "path_changes does not — TC would be orphaned", tostring(mid)))
        end
    end

    local database = require("core.database")
    local db = assert(database.get_connection(),
        "Media.batch_set_file_paths: no database connection")

    local ids = collect_path_change_ids(path_changes)
    if #ids == 0 then return {} end

    local old_state = capture_existing_file_state(db, ids)
    apply_file_state_updates(db, path_changes, tc_updates, old_state)
    return old_state
end

--- Undo counterpart: restore each row's {file_path, metadata} from a table
--- previously returned by batch_set_file_paths.
function M.batch_restore_file_state(old_state)
    assert(type(old_state) == "table",
        "Media.batch_restore_file_state: old_state table required")

    local ids = {}
    for mid in pairs(old_state) do ids[#ids + 1] = mid end
    if #ids == 0 then return end

    local database = require("core.database")
    local db = assert(database.get_connection(),
        "Media.batch_restore_file_state: no database connection")

    local upd = assert(db:prepare(
        "UPDATE media SET file_path = ?, metadata = ? WHERE id = ?"),
        "Media.batch_restore_file_state: failed to prepare update query")
    for mid, row in pairs(old_state) do
        assert(type(row) == "table" and row.file_path,
            string.format("Media.batch_restore_file_state: row %s missing file_path",
                tostring(mid)))
        upd:bind_value(1, row.file_path)
        upd:bind_value(2, row.metadata)
        upd:bind_value(3, mid)
        assert(upd:exec(), string.format(
            "Media.batch_restore_file_state: update exec failed for %s", tostring(mid)))
        upd:reset()
        mark_dirty(mid)
    end
    upd:finalize()
end

--- Batch-assign offline_note for a set of media rows. Same shape as
--- batch_set_file_paths: pass {[media_id] = json_string_or_nil}. Values
--- of nil clear the note (relink succeeded, no diagnostic to display).
--- Callers should wrap in Media.begin_batch / end_batch if they want
--- the consequent media_changed signal batched with other mutations.
--- @param note_changes table {[media_id] = string|nil}
--- Load every media row's {file_path, offline_note} pair. Used by
--- media_status to prime its renderer-facing cache at project open.
--- Skips rows with empty file_path (degenerate records). Order is
--- unspecified — consumers index by file_path.
--- @return table array of {file_path, offline_note}
function M.load_all_offline_notes()
    local database = require("core.database")
    local db = assert(database.get_connection(),
        "Media.load_all_offline_notes: no database connection")

    local q = assert(db:prepare(
        "SELECT file_path, offline_note FROM media WHERE file_path != ''"),
        "Media.load_all_offline_notes: prepare failed")
    local rows = {}
    if q:exec() then
        while q:next() do
            rows[#rows + 1] = {
                file_path = q:value(0),
                offline_note = q:value(1),
            }
        end
    end
    q:finalize()
    return rows
end

--- Batch-assign offline_note JSON strings to a set of media rows.
--- Only handles non-nil values — `pairs()` skips nil-valued keys, and
--- callers that need to clear notes (restore a row to "no diagnostic")
--- must route those media_ids through `batch_clear_offline_notes`
--- instead. Callers should wrap in Media.begin_batch / end_batch to
--- coalesce the consequent media_changed signal.
--- @param note_sets table {[media_id] = json_string}
function M.batch_set_offline_notes(note_sets)
    assert(type(note_sets) == "table",
        "Media.batch_set_offline_notes: note_sets table required")
    if next(note_sets) == nil then return end

    local database = require("core.database")
    local db = assert(database.get_connection(),
        "Media.batch_set_offline_notes: no database connection")

    local upd = assert(db:prepare(
        "UPDATE media SET offline_note = ? WHERE id = ?"),
        "Media.batch_set_offline_notes: failed to prepare update query")
    for mid, note in pairs(note_sets) do
        assert(type(note) == "string", string.format(
            "Media.batch_set_offline_notes: note must be string for %s, got %s",
            tostring(mid), type(note)))
        upd:bind_value(1, note)
        upd:bind_value(2, mid)
        assert(upd:exec(), string.format(
            "Media.batch_set_offline_notes: exec failed for %s", tostring(mid)))
        upd:reset()
        mark_dirty(mid)
    end
    upd:finalize()
end

--- Clear `offline_note` (write SQL NULL) for each media_id in the
--- array. Counterpart to batch_set_offline_notes for the "this row's
--- diagnostic is no longer relevant" case (successful relink wiped a
--- prior partial-coverage note, undo restoring a pre-relink nil).
--- @param media_ids table array of media_id strings
function M.batch_clear_offline_notes(media_ids)
    assert(type(media_ids) == "table",
        "Media.batch_clear_offline_notes: media_ids table required")
    if #media_ids == 0 then return end

    local database = require("core.database")
    local db = assert(database.get_connection(),
        "Media.batch_clear_offline_notes: no database connection")

    local stmt = assert(db:prepare(
        "UPDATE media SET offline_note = NULL WHERE id = ?"),
        "Media.batch_clear_offline_notes: failed to prepare clear query")
    for _, mid in ipairs(media_ids) do
        stmt:bind_value(1, mid)
        assert(stmt:exec(), string.format(
            "Media.batch_clear_offline_notes: exec failed for %s", tostring(mid)))
        stmt:reset()
        mark_dirty(mid)
    end
    stmt:finalize()
end

--- Batch version of Media:get_source_extent.
--- Returns per-stream extents — video clips and audio clips have different
--- source units (frames vs samples) so a single combined extent would mix
--- coordinate systems. The relinker compares each stream against the
--- candidate file's video TC range and audio sample range separately.
---
--- @param media_rates table {[media_id] = {video_rate=number|nil,
---                                          audio_sample_rate=number|nil}}
---     video_rate: video frames-per-second the video extent should report
---                 in (typically media's start_tc_rate; nil disables video).
---     audio_sample_rate: audio samples-per-second the audio extent should report
---                 in (typically media.audio_sample_rate; nil disables audio).
--- @return table {[media_id] = {video={min_in,max_out,rate}|nil,
---                              audio={min_in,max_out,rate}|nil}}
---     A bucket is nil when no clips of that track type reference the media.
function M.batch_get_source_extents(media_rates)
    assert(type(media_rates) == "table",
        "Media.batch_get_source_extents: media_rates table required")

    local database = require("core.database")
    local db = assert(database.get_connection(),
        "Media.batch_get_source_extents: no database connection")

    local result = {}
    local ids = {}
    for mid, rates in pairs(media_rates) do
        assert(type(rates) == "table", string.format(
            "Media.batch_get_source_extents: rates entry for %s must be a table "
            .. "{video_rate=, audio_sample_rate=}", tostring(mid)))
        if rates.video_rate ~= nil then
            assert(type(rates.video_rate) == "number" and rates.video_rate > 0,
                string.format("Media.batch_get_source_extents: invalid video_rate "
                    .. "for %s: %s", tostring(mid), tostring(rates.video_rate)))
        end
        if rates.audio_sample_rate ~= nil then
            assert(type(rates.audio_sample_rate) == "number" and rates.audio_sample_rate > 0,
                string.format("Media.batch_get_source_extents: invalid audio_sample_rate "
                    .. "for %s: %s", tostring(mid), tostring(rates.audio_sample_rate)))
        end
        ids[#ids + 1] = mid
        result[mid] = { video = nil, audio = nil }
    end
    if #ids == 0 then return result end

    local function include_in_extent(extent, src_in, src_out)
        if not extent.min_in or src_in < extent.min_in then
            extent.min_in = src_in
        end
        if not extent.max_out or src_out > extent.max_out then
            extent.max_out = src_out
        end
    end

    -- Chunked IN clause — stay under SQLITE_MAX_VARIABLE_NUMBER comfortably.
    local CHUNK = 500
    for chunk_start = 1, #ids, CHUNK do
        local chunk_end = math.min(chunk_start + CHUNK - 1, #ids)
        local n = chunk_end - chunk_start + 1
        local phs = {}
        for i = 1, n do phs[i] = "?" end
        -- V13: walk clips → nested sequence → master.media_refs to find
        -- clips referencing each media. nested fps drives video clip rate;
        -- nested.audio_sample_rate drives audio clip rate. Track type drives which
        -- bucket the row contributes to — video clips' source values are in
        -- video frames at nested.fps; audio clips' source values are in
        -- audio samples at nested.audio_sample_rate.
        local sql = string.format([[
            SELECT mr.media_id, c.source_in_frame, c.source_out_frame,
                   nested.fps_numerator, nested.fps_denominator,
                   nested.audio_sample_rate, t.track_type
            FROM clips c
            JOIN sequences nested ON nested.id = c.nested_sequence_id
            JOIN media_refs mr ON mr.owner_sequence_id = c.nested_sequence_id
            JOIN tracks t ON t.id = c.track_id
            WHERE mr.media_id IN (%s)
        ]], table.concat(phs, ","))

        local stmt = assert(db:prepare(sql),
            "Media.batch_get_source_extents: failed to prepare query")
        for i = 1, n do
            stmt:bind_value(i, ids[chunk_start + i - 1])
        end
        assert(stmt:exec(),
            "Media.batch_get_source_extents: query execution failed")

        while stmt:next() do
            local mid = stmt:value(0)
            local src_in = stmt:value(1)
            local src_out = stmt:value(2)
            local fps_num = stmt:value(3)
            local fps_den = stmt:value(4)
            local audio_sample_rate = stmt:value(5)
            local track_type = stmt:value(6)
            assert(src_in, string.format(
                "batch_get_source_extents: clip on media %s has NULL source_in_frame",
                tostring(mid)))
            assert(src_out, string.format(
                "batch_get_source_extents: clip on media %s has NULL source_out_frame",
                tostring(mid)))
            assert(fps_num and fps_num > 0, string.format(
                "batch_get_source_extents: clip on media %s has invalid fps_numerator=%s",
                tostring(mid), tostring(fps_num)))
            assert(fps_den and fps_den > 0, string.format(
                "batch_get_source_extents: clip on media %s has invalid fps_denominator=%s",
                tostring(mid), tostring(fps_den)))

            local rates = media_rates[mid]
            if track_type == "VIDEO" and rates.video_rate then
                local clip_rate = fps_num / fps_den
                local target = rates.video_rate
                if math.abs(clip_rate - target) > 0.01 then
                    src_in = math.floor(src_in * target / clip_rate + 0.5)
                    src_out = math.floor(src_out * target / clip_rate + 0.5)
                end
                local bucket = result[mid].video
                if not bucket then
                    bucket = { rate = target }
                    result[mid].video = bucket
                end
                include_in_extent(bucket, src_in, src_out)
            elseif track_type == "AUDIO" and rates.audio_sample_rate then
                assert(audio_sample_rate and audio_sample_rate > 0, string.format(
                    "batch_get_source_extents: nested sequence for media %s has "
                    .. "no audio_sample_rate; cannot scale audio clip extent",
                    tostring(mid)))
                local target = rates.audio_sample_rate
                if math.abs(audio_sample_rate - target) > 0.01 then
                    src_in = math.floor(src_in * target / audio_sample_rate + 0.5)
                    src_out = math.floor(src_out * target / audio_sample_rate + 0.5)
                end
                local bucket = result[mid].audio
                if not bucket then
                    bucket = { rate = target }
                    result[mid].audio = bucket
                end
                include_in_extent(bucket, src_in, src_out)
            end
        end
        stmt:finalize()
    end

    -- Flatten into the documented shape: {min_in, max_out, rate} per stream
    -- (the helper accumulator used min_in/max_out names for clarity).
    for _, per_media in pairs(result) do
        for _, bucket in pairs(per_media) do
            bucket[1] = bucket.min_in
            bucket[2] = bucket.max_out
            bucket.min_in = nil
            bucket.max_out = nil
        end
    end

    return result
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
            width, height, rotation, audio_sample_rate, audio_channels, codec, is_still, created_at, modified_at, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            is_still = excluded.is_still,
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
    assert(type(self.is_still) == "boolean", string.format(
        "Media:save: is_still must be boolean, got %s (media_id=%s)",
        type(self.is_still), tostring(self.id)))
    query:bind_value(15, self.is_still and 1 or 0)
    query:bind_value(16, self.created_at)
    query:bind_value(17, self.modified_at)
    query:bind_value(18, self.metadata)

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

    -- V13: clips don't carry media_id directly. The reachable clips are
    -- those whose nested_sequence_id points at a master sequence that has
    -- a media_ref to this media. Find them via media_refs.
    -- properties table has no FK cascade — must clean up explicitly.
    local clip_ids_stmt = db:prepare([[
        SELECT c.id FROM clips c
          JOIN media_refs mr ON mr.owner_sequence_id = c.nested_sequence_id
         WHERE mr.media_id = ?
    ]])
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

    -- Drop media_refs pointing at this media row first. The schema's
    -- ON DELETE SET NULL on media_refs.media_id contradicts the
    -- NOT NULL constraint on the same column, so a SET NULL would
    -- crash the DELETE FROM media. Removing the media_refs rows
    -- explicitly orphans any master-sequence shells that referenced
    -- them — the master sequence row itself remains; relink/undo
    -- callers that created the master are responsible for tearing it
    -- down separately.
    local del_refs = assert(db:prepare("DELETE FROM media_refs WHERE media_id = ?"),
        "Media:delete: failed to prepare media_refs delete")
    del_refs:bind_value(1, self.id)
    if not del_refs:exec() then
        local err = del_refs:last_error()
        del_refs:finalize()
        error(string.format("Media:delete: failed to delete media_refs for %s: %s", self.id, err))
    end
    del_refs:finalize()

    -- Now drop the media row itself.
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
