-- Lua model for timeline tracks. Supports both video and audio variants.

local database = require("core.database")
local uuid = require("uuid")

local Track = {}
Track.__index = Track

local function resolve_db(db)
    if db then
        return db
    end
    local conn = database.get_connection()
    if not conn then
        print("WARNING: Track.save: No database connection available")
    end
    return conn
end

local function determine_next_index(sequence_id, track_type, provided_index, db)
    if provided_index and provided_index > 0 then
        return provided_index
    end

    local conn = resolve_db(db)
    if not conn then
        -- Fall back to first track if we cannot query
        return 1
    end

    local stmt = conn:prepare([[
        SELECT COALESCE(MAX(track_index), 0)
        FROM tracks
        WHERE sequence_id = ? AND track_type = ?
    ]])

    if not stmt then
        return 1
    end

    stmt:bind_value(1, sequence_id)
    stmt:bind_value(2, track_type)

    local max_index = 0
    if stmt:exec() and stmt:next() then
        max_index = stmt:value(0) or 0
    end
    stmt:finalize()

    return max_index + 1
end

local function build_track(track_type, name, sequence_id, opts)
    if not name or name == "" then
        print("ERROR: Track.create: name is required")
        return nil
    end
    if not sequence_id or sequence_id == "" then
        print("ERROR: Track.create: sequence_id is required")
        return nil
    end

    opts = opts or {}
    local track = {
        id = opts.id or uuid.generate(),
        sequence_id = sequence_id,
        name = name,
        track_type = track_type,
        timebase_type = opts.timebase_type,
        timebase_rate = opts.timebase_rate,
        track_index = determine_next_index(sequence_id, track_type, opts.index, opts.db),
        enabled = opts.enabled ~= false,
        locked = opts.locked == true,
        muted = opts.muted == true,
        soloed = opts.soloed == true,
        volume = opts.volume or 1.0,
        pan = opts.pan or 0.0,
        created_at = os.time(),
        modified_at = os.time()
    }

    if not track.timebase_type or not track.timebase_rate or track.timebase_rate <= 0 then
        local conn = resolve_db(opts.db)
        local seq_frame_rate = 24
        local seq_sample_rate = 48000
        if conn then
            local seq_stmt = conn:prepare("SELECT frame_rate, audio_sample_rate FROM sequences WHERE id = ?")
            if seq_stmt then
                seq_stmt:bind_value(1, sequence_id)
                if seq_stmt:exec() and seq_stmt:next() then
                    seq_frame_rate = tonumber(seq_stmt:value(0)) or seq_frame_rate
                    seq_sample_rate = tonumber(seq_stmt:value(1)) or seq_sample_rate
                end
                seq_stmt:finalize()
            end
        end

        if track_type == "AUDIO" then
            track.timebase_type = "audio_samples"
            track.timebase_rate = seq_sample_rate
        else
            track.timebase_type = "video_frames"
            track.timebase_rate = seq_frame_rate
        end
    end

    if not track.timebase_type or not track.timebase_rate or track.timebase_rate <= 0 then
        error("Track.create: invalid timebase_type/timebase_rate")
    end

    return setmetatable(track, Track)
end

function Track.create_video(name, sequence_id, opts)
    return build_track("VIDEO", name or "Video Track", sequence_id, opts)
end

function Track.create_audio(name, sequence_id, opts)
    return build_track("AUDIO", name or "Audio Track", sequence_id, opts)
end

function Track.load(id, db)
    if not id or id == "" then
        print("ERROR: Track.load: id is required")
        return nil
    end

    local conn = resolve_db(db)
    if not conn then
        return nil
    end

    local stmt = conn:prepare([[
        SELECT id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index,
               enabled, locked, muted, soloed, volume, pan
        FROM tracks WHERE id = ?
    ]])

    if not stmt then
        print("WARNING: Track.load: failed to prepare query")
        return nil
    end

    stmt:bind_value(1, id)
    if not stmt:exec() or not stmt:next() then
        stmt:finalize()
        return nil
    end

    local track = {
        id = stmt:value(0),
        sequence_id = stmt:value(1),
        name = stmt:value(2),
        track_type = stmt:value(3),
        timebase_type = stmt:value(4),
        timebase_rate = stmt:value(5),
        track_index = stmt:value(6),
        enabled = stmt:value(7) == 1,
        locked = stmt:value(8) == 1,
        muted = stmt:value(9) == 1,
        soloed = stmt:value(10) == 1,
        volume = stmt:value(11),
        pan = stmt:value(12),
        created_at = os.time(),
        modified_at = os.time()
    }

    stmt:finalize()
    return setmetatable(track, Track)
end

function Track:save(db)
    if not self or not self.id or self.id == "" then
        print("ERROR: Track.save: invalid track or missing id")
        return false
    end
    if not self.sequence_id or self.sequence_id == "" then
        print("ERROR: Track.save: sequence_id is required")
        return false
    end
    if not self.timebase_type or not self.timebase_rate or self.timebase_rate <= 0 then
        error("Track.save: missing timebase_type/timebase_rate")
    end

    local conn = resolve_db(db)
    if not conn then
        return false
    end

    self.modified_at = os.time()

    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO tracks
        (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])

    if not stmt then
        print("WARNING: Track.save: failed to prepare insert statement")
        return false
    end

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.sequence_id)
    stmt:bind_value(3, self.name)
    stmt:bind_value(4, self.track_type)
    stmt:bind_value(5, self.timebase_type)
    stmt:bind_value(6, self.timebase_rate)
    stmt:bind_value(7, self.track_index)
    stmt:bind_value(8, self.enabled and 1 or 0)
    stmt:bind_value(9, self.locked and 1 or 0)
    stmt:bind_value(10, self.muted and 1 or 0)
    stmt:bind_value(11, self.soloed and 1 or 0)
    stmt:bind_value(12, self.volume)
    stmt:bind_value(13, self.pan)

    local ok = stmt:exec()
    if not ok then
        print(string.format("WARNING: Track.save: failed for %s", self.id))
    end

    stmt:finalize()
    return ok
end

return Track
