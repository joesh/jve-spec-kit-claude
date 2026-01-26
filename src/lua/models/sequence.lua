--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~193 LOC
-- Volatility: unknown
--
-- @file sequence.lua
-- Original intent (unreviewed):
-- Lua representation of timeline sequences.
-- Mirrors the behaviour of the legacy C++ model closely enough for imports and commands.
local database = require("core.database")
local uuid = require("uuid")
local Rational = require("core.rational")

local Sequence = {}
Sequence.__index = Sequence

local function resolve_db()
    local conn = database.get_connection()
    if not conn then
        print("WARNING: Sequence.save: No database connection available")
    end
    return conn
end

local function validate_frame_rate(val)
    if type(val) == "number" and val > 0 then
        return { fps_numerator = math.floor(val), fps_denominator = 1 } -- Simple integer rate
    end
    if type(val) == "table" and val.fps_numerator and val.fps_denominator then
        return val
    end
    -- FAIL FAST: No silent fallbacks - frame rate is required
    error("Sequence: frame_rate is required (got " .. type(val) .. ")")
end

function Sequence.create(name, project_id, frame_rate, width, height, opts)
    if not name or name == "" then
        print("ERROR: Sequence.create: name is required")
        return nil
    end
    if not project_id or project_id == "" then
        print("ERROR: Sequence.create: project_id is required")
        return nil
    end

    local fr = validate_frame_rate(frame_rate)
    
    -- Clamp resolution (legacy logic preserved)
    local w = 1920
    local h = 1080
    if type(width) == "number" and width > 0 then w = math.floor(width) end
    if type(height) == "number" and height > 0 then h = math.floor(height) end

    opts = opts or {}
    local now = os.time()

    -- Handle playhead from opts (frame number to Rational)
    local playhead_pos = Rational.new(0, fr.fps_numerator, fr.fps_denominator)
    if opts.playhead_frame and opts.playhead_frame > 0 then
        playhead_pos = Rational.new(opts.playhead_frame, fr.fps_numerator, fr.fps_denominator)
    end

    -- Handle viewport from opts (frame numbers to Rationals)
    local viewport_start = Rational.new(0, fr.fps_numerator, fr.fps_denominator)
    if opts.view_start_frame and opts.view_start_frame > 0 then
        viewport_start = Rational.new(opts.view_start_frame, fr.fps_numerator, fr.fps_denominator)
    end

    local viewport_dur = Rational.from_seconds(10.0, fr.fps_numerator, fr.fps_denominator)
    if opts.view_duration_frames and opts.view_duration_frames > 0 then
        viewport_dur = Rational.new(opts.view_duration_frames, fr.fps_numerator, fr.fps_denominator)
    end

    local sequence = {
        id = opts.id or uuid.generate(),
        project_id = project_id,
        name = name,
        kind = opts.kind or "timeline",
        frame_rate = fr,
        width = w,
        height = h,
        audio_sample_rate = opts.audio_rate or 48000,

        -- Rational Properties
        playhead_position = playhead_pos,
        viewport_start_time = viewport_start,
        viewport_duration = viewport_dur,

        mark_in = nil,
        mark_out = nil,

        -- Selection state (JSON strings)
        selected_clip_ids_json = opts.selected_clip_ids_json or "[]",
        selected_edge_infos_json = opts.selected_edge_infos_json or "[]",

        created_at = opts.created_at or now,
        modified_at = opts.modified_at or now
    }

    return setmetatable(sequence, Sequence)
end

function Sequence.load(id)
    if not id or id == "" then
        print("ERROR: Sequence.load: id is required")
        return nil
    end

    local conn = resolve_db()
    if not conn then
        return nil
    end

            local stmt = conn:prepare([[
                SELECT id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
                       playhead_frame, view_start_frame,
                       view_duration_frames, mark_in_frame, mark_out_frame, audio_rate,
                       selected_clip_ids, selected_edge_infos
                FROM sequences WHERE id = ?
            ]])
    
            if not stmt then
                print(string.format("WARNING: Sequence.load: failed to prepare query: %s", conn:last_error()))
                return nil
            end
    
            stmt:bind_value(1, id)
            if not stmt:exec() then
                print(string.format("WARNING: Sequence.load: query failed for %s", id))
                stmt:finalize()
                return nil
            end
    
            if not stmt:next() then
                stmt:finalize()
                return nil
            end
    
            local fps_num = stmt:value(4)
            local fps_den = stmt:value(5)
            local audio_rate = stmt:value(13)
            local selected_clip_ids = stmt:value(14)  -- JSON string
            local selected_edge_infos = stmt:value(15)  -- JSON string

            local fr = { fps_numerator = fps_num, fps_denominator = fps_den }

            local sequence = {
                id = stmt:value(0),
                project_id = stmt:value(1),
                name = stmt:value(2),
                kind = stmt:value(3),
                frame_rate = fr,
                audio_sample_rate = audio_rate,
                width = stmt:value(6),
                height = stmt:value(7),

                -- New Rational Properties (loaded from frames)
                playhead_position = Rational.new(stmt:value(8) or 0, fps_num, fps_den),
                viewport_start_time = Rational.new(stmt:value(9) or 0, fps_num, fps_den),

                -- Viewport Duration
                viewport_duration = Rational.new(stmt:value(10) or 240, fps_num, fps_den),

                -- Selection state (JSON strings from database)
                selected_clip_ids_json = selected_clip_ids,  -- Let caller parse JSON
                selected_edge_infos_json = selected_edge_infos,

                created_at = os.time(),
                modified_at = os.time()
            }

            -- Optional Marks
            local raw_mark_in = stmt:value(11)
            if raw_mark_in then
                sequence.mark_in = Rational.new(raw_mark_in, fps_num, fps_den)
            end

            local raw_mark_out = stmt:value(12)
            if raw_mark_out then
                sequence.mark_out = Rational.new(raw_mark_out, fps_num, fps_den)
            end
    stmt:finalize()
    return setmetatable(sequence, Sequence)
end

function Sequence:save()
    if not self or not self.id or self.id == "" then
        print("ERROR: Sequence.save: invalid sequence or missing id")
        return false
    end
    if not self.project_id or self.project_id == "" then
        print("ERROR: Sequence.save: project_id is required")
        return false
    end

    local conn = resolve_db()
    if not conn then
        return false
    end

    self.modified_at = os.time()

    -- V5: Rational Storage
    -- We store the Rate (fps_num/den) and the Frames/Ticks directly.
    
    local db_fps_num = self.frame_rate.fps_numerator
    local db_fps_den = self.frame_rate.fps_denominator
    
    -- Removed db_timecode_start as it's not in schema
    local db_playhead = self.playhead_position.frames
    local db_view_start = self.viewport_start_time.frames
    local db_view_dur = self.viewport_duration.frames
    
    local db_mark_in = self.mark_in and self.mark_in.frames or nil
    local db_mark_out = self.mark_out and self.mark_out.frames or nil
    
    local db_audio_rate = self.audio_sample_rate or 48000

    -- CRITICAL: Use ON CONFLICT DO UPDATE instead of INSERT OR REPLACE
    -- INSERT OR REPLACE triggers DELETE first, which cascades to delete clips via foreign keys!
    local stmt = conn:prepare([[
        INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
         playhead_frame, view_start_frame, view_duration_frames, mark_in_frame, mark_out_frame, audio_rate,
         selected_clip_ids, selected_edge_infos,
         created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            kind = excluded.kind,
            fps_numerator = excluded.fps_numerator,
            fps_denominator = excluded.fps_denominator,
            width = excluded.width,
            height = excluded.height,
            playhead_frame = excluded.playhead_frame,
            view_start_frame = excluded.view_start_frame,
            view_duration_frames = excluded.view_duration_frames,
            mark_in_frame = excluded.mark_in_frame,
            mark_out_frame = excluded.mark_out_frame,
            audio_rate = excluded.audio_rate,
            selected_clip_ids = excluded.selected_clip_ids,
            selected_edge_infos = excluded.selected_edge_infos,
            modified_at = excluded.modified_at
    ]])

    if not stmt then
        local err = conn.last_error and conn:last_error() or "unknown error"
        print("WARNING: Sequence.save: failed to prepare insert statement: " .. err)
        return false
    end

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.project_id)
    stmt:bind_value(3, self.name)
    stmt:bind_value(4, self.kind or "timeline")
    stmt:bind_value(5, db_fps_num)
    stmt:bind_value(6, db_fps_den)
    stmt:bind_value(7, self.width)
    stmt:bind_value(8, self.height)
    stmt:bind_value(9, db_playhead)
    stmt:bind_value(10, db_view_start)
    stmt:bind_value(11, db_view_dur)
    
    if db_mark_in then 
        stmt:bind_value(12, db_mark_in) 
    else 
        if stmt.bind_null then
            stmt:bind_null(12) 
        else
            stmt:bind_value(12, nil)
        end
    end
    
    if db_mark_out then 
        stmt:bind_value(13, db_mark_out) 
    else 
        if stmt.bind_null then
            stmt:bind_null(13)
        else
            stmt:bind_value(13, nil)
        end
    end
    
    stmt:bind_value(14, db_audio_rate)
    stmt:bind_value(15, self.selected_clip_ids_json or "")
    stmt:bind_value(16, self.selected_edge_infos_json or "")
    stmt:bind_value(17, self.created_at or os.time())
    stmt:bind_value(18, self.modified_at)

    local ok = stmt:exec()
    if not ok then
        print(string.format("WARNING: Sequence.save: failed for %s with error: %s", self.id, stmt:last_error()))
    end

    stmt:finalize()
    return ok
end

-- Count all sequences in the database
function Sequence.count()
    local database = require("core.database")
    local conn = database.get_connection()
    if not conn then
        return 0
    end

    local stmt = conn:prepare("SELECT COUNT(*) FROM sequences")
    if not stmt then
        return 0
    end

    local count = 0
    if stmt:exec() and stmt:next() then
        count = tonumber(stmt:value(0)) or 0
    end
    stmt:finalize()
    return count
end

-- Ensure a default sequence exists for a project, creating one if needed
-- Returns the default sequence (existing or newly created)
function Sequence.ensure_default(project_id)
    project_id = project_id or "default_project"

    local existing = Sequence.load("default_sequence")
    if existing then
        return existing
    end

    -- Create default sequence with standard settings
    local frame_rate = {fps_numerator = 30, fps_denominator = 1}
    local sequence = Sequence.create("Default Sequence", project_id, frame_rate, 1920, 1080, {
        id = "default_sequence"
    })
    if sequence and sequence:save() then
        return sequence
    end
    return nil
end

return Sequence