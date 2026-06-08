--- Sequence model — kind='master' (per-media canonical reference) or
--- kind='sequence' (timeline / nested). V13 Lua-first: this file IS the
--- model; there is no C++ counterpart. Cohesive sub-modules
--- (resolver, conform, point_in_time, master_builder, snapshot, streams,
--- queries) install methods onto Sequence at the bottom of this file.
local database = require("core.database")
local uuid = require("uuid")

local Sequence = {}
Sequence.__index = Sequence

local function resolve_db()
    local conn = database.get_connection()
    if not conn then
        error("Sequence: No database connection available")
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

--- Resolve a non-negative integer field from opts, falling back to a
--- caller-supplied documented default when absent. Asserts the type +
--- non-negativity + integer-ness when the field IS provided — this is
--- the validation that distinguishes a documented default from a silent
--- `or 0` fallback (rule 2.13: present-but-bad values fail loudly).
local function resolve_non_negative_int_arg(opts, key, default_value)
    local v = opts[key]
    if v == nil then return default_value end
    assert(type(v) == "number" and v >= 0 and v == math.floor(v),
        string.format("Sequence.create: %s must be a non-negative integer, "
            .. "got %s", key, tostring(v)))
    return v
end

--- Default viewport duration: 10 seconds worth of frames.
-- Single source of truth; used by Sequence.create, import commands, and zoom_to_fit_if_first_open.
function Sequence.default_viewport_duration(fps_num, fps_den)
    assert(type(fps_num) == "number" and fps_num > 0,
        "Sequence.default_viewport_duration: fps_num must be positive number")
    assert(type(fps_den) == "number" and fps_den > 0,
        "Sequence.default_viewport_duration: fps_den must be positive number")
    return math.floor(10.0 * fps_num / fps_den)
end

function Sequence.create(name, project_id, frame_rate, width, height, opts)
    assert(name and name ~= "", "Sequence.create: name is required")
    assert(project_id and project_id ~= "", "Sequence.create: project_id is required")

    local fr = validate_frame_rate(frame_rate)

    opts = opts or {}

    -- width/height are required for every sequence EXCEPT a master whose
    -- source media is audio-only (no video media_refs, no callers reading
    -- dimensions). Schema permits NULL only for that case. Rule 2.13:
    -- no silent fallback to a stub resolution.
    local w, h
    if width ~= nil or height ~= nil then
        assert(type(width) == "number" and width > 0,
            "Sequence.create: width must be a positive number when provided")
        assert(type(height) == "number" and height > 0,
            "Sequence.create: height must be a positive number when provided")
        w = math.floor(width)
        h = math.floor(height)
    else
        assert(opts.kind == "master",
            "Sequence.create: width/height are required for non-master sequences (rule 2.13)")
    end
    local now = os.time()

    -- Integer frame coordinates (fps is metadata in frame_rate). Documented
    -- defaults: start_timecode_frame = 0 (no TC origin); playhead_frame =
    -- start_timecode_frame (parked at sequence start). Invariant enforced
    -- below: `playhead_frame >= start_timecode_frame` — a playhead in the
    -- empty [0, start_tc) pre-content space is meaningless and would trip
    -- the engine's start-frame seek assert.
    local start_tc = resolve_non_negative_int_arg(opts, "start_timecode_frame", 0)
    local playhead_pos = resolve_non_negative_int_arg(opts, "playhead_frame", start_tc)
    assert(playhead_pos >= start_tc, string.format(
        "Sequence.create: playhead_frame=%d must be >= "
        .. "start_timecode_frame=%d (sequence '%s')",
        playhead_pos, start_tc, tostring(name)))

    local viewport_start = opts.view_start_frame or 0
    local viewport_dur = opts.view_duration_frames or Sequence.default_viewport_duration(fr.fps_numerator, fr.fps_denominator)

    -- Rule 2.13: kind is required, no default. Schema V9 CHECK restricts to
    -- ('master', 'sequence'); caller must pick.
    assert(opts.kind == "master" or opts.kind == "sequence",
        "Sequence.create: opts.kind must be 'master' or 'sequence' (V9 schema); got "
        .. tostring(opts.kind))
    -- 018 (FR-004): masters MUST have audio_sample_rate = NULL.
    -- Audio rate is per-media_ref. Regular sequences (kind='sequence') still
    -- carry an audio rate as their playback-monitor rate. Rule 2.13: no silent
    -- coercion — caller passes nil explicitly for masters.
    if opts.kind == "master" then
        assert(opts.audio_sample_rate == nil,
            "Sequence.create: kind='master' must have audio_sample_rate=nil "
            .. "(audio rate is per-media_ref, not per-master; FR-004)")
    else
        if opts.audio_sample_rate ~= nil then
            assert(type(opts.audio_sample_rate) == "number" and opts.audio_sample_rate > 0,
                "Sequence.create: opts.audio_sample_rate must be a positive number when provided (rule 2.13)")
        else
            assert(false,
                "Sequence.create: opts.audio_sample_rate is required for non-master sequences (rule 2.13)")
        end
    end

    local sequence = {
        id = opts.id or uuid.generate(),
        project_id = project_id,
        name = name,
        kind = opts.kind,
        frame_rate = fr,
        width = w,
        height = h,
        audio_sample_rate = opts.audio_sample_rate,

        -- V9 columns.
        default_video_layer_track_id = opts.default_video_layer_track_id,  -- nullable
        video_start_tc_frame = opts.video_start_tc_frame,                    -- nullable
        audio_start_tc_samples = opts.audio_start_tc_samples,                -- nullable
        fps_mismatch_policy = opts.fps_mismatch_policy,                      -- nullable (inherit project)

        -- Timeline start timecode (display offset only)
        start_timecode_frame = start_tc,

        -- Integer frame coordinates (fps is metadata in frame_rate)
        playhead_position = playhead_pos,
        viewport_start_time = viewport_start,
        viewport_duration = viewport_dur,
        video_scroll_offset = opts.video_scroll_offset or 0,
        audio_scroll_offset = opts.audio_scroll_offset or 0,
        video_audio_split_ratio = opts.video_audio_split_ratio or 0.5,

        mark_in = opts.mark_in_frame,   -- nil or integer
        mark_out = opts.mark_out_frame, -- nil or integer

        -- Selection state (JSON strings)
        selected_clip_ids_json = opts.selected_clip_ids_json or "[]",
        selected_edge_infos_json = opts.selected_edge_infos_json or "[]",

        created_at = opts.created_at or now,
        modified_at = opts.modified_at or now
    }

    return setmetatable(sequence, Sequence)
end

function Sequence.load(id)
    assert(id and id ~= "", "Sequence.load: id is required")

    local conn = resolve_db()
    if not conn then
        return nil
    end

            local stmt = conn:prepare([[
                SELECT id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
                       playhead_frame, view_start_frame,
                       view_duration_frames, mark_in_frame, mark_out_frame, audio_sample_rate,
                       selected_clip_ids, selected_edge_infos, start_timecode_frame,
                       video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
                       selected_gap_infos, created_at, modified_at, mutation_generation
                FROM sequences WHERE id = ?
            ]])
    
            assert(stmt, string.format("Sequence.load: failed to prepare query: %s", conn:last_error()))
    
            stmt:bind_value(1, id)
            if not stmt:exec() then
                local err = stmt:last_error()
                stmt:finalize()
                error(string.format("Sequence.load: query failed for %s: %s", id, tostring(err)))
            end
    
            if not stmt:next() then
                stmt:finalize()
                return nil
            end
    
            local fps_num = stmt:value(4)
            local fps_den = stmt:value(5)
            assert(fps_num and fps_den, string.format(
                "Sequence.load: id=%s missing fps metadata! kind=%s",
                tostring(id), tostring(stmt:value(3))))
            local audio_sample_rate = stmt:value(13)
            local selected_clip_ids = stmt:value(14)  -- JSON string
            local selected_edge_infos = stmt:value(15)  -- JSON string

            local fr = { fps_numerator = fps_num, fps_denominator = fps_den }

            local sequence = {
                id = stmt:value(0),
                project_id = stmt:value(1),
                name = stmt:value(2),
                kind = stmt:value(3),
                frame_rate = fr,
                audio_sample_rate = audio_sample_rate,
                width = stmt:value(6),
                height = stmt:value(7),

                -- Integer frame coordinates (fps is metadata in frame_rate)
                playhead_position = assert(stmt:value(8), "Sequence.load: playhead_frame is NULL for id=" .. tostring(id)),
                viewport_start_time = assert(stmt:value(9), "Sequence.load: view_start_frame is NULL for id=" .. tostring(id)),
                viewport_duration = assert(stmt:value(10), "Sequence.load: view_duration_frames is NULL for id=" .. tostring(id)),

                -- Selection state (JSON strings from database)
                selected_clip_ids_json = selected_clip_ids,  -- Let caller parse JSON
                selected_edge_infos_json = selected_edge_infos,

                -- These columns are NOT NULL DEFAULT in schema; nil means DB corruption
                start_timecode_frame = assert(stmt:value(16) ~= nil and stmt:value(16),
                    "Sequence.load: start_timecode_frame is NULL"),
                video_scroll_offset = assert(stmt:value(17) ~= nil and stmt:value(17),
                    "Sequence.load: video_scroll_offset is NULL"),
                audio_scroll_offset = assert(stmt:value(18) ~= nil and stmt:value(18),
                    "Sequence.load: audio_scroll_offset is NULL"),
                video_audio_split_ratio = assert(stmt:value(19) ~= nil and stmt:value(19),
                    "Sequence.load: video_audio_split_ratio is NULL"),

                created_at = assert(stmt:value(21),
                    "Sequence.load: created_at is NULL"),
                modified_at = assert(stmt:value(22),
                    "Sequence.load: modified_at is NULL"),
                mutation_generation = assert(stmt:value(23),
                    "Sequence.load: mutation_generation is NULL"),
            }

            -- Optional Marks (integer frames or nil)
            sequence.mark_in = stmt:value(11)
            sequence.mark_out = stmt:value(12)

            -- Optional gap selection (JSON string or nil)
            sequence.selected_gap_infos_json = stmt:value(20)
    stmt:finalize()

    return setmetatable(sequence, Sequence)
end

-- ============================================================================
-- Sequence:save — validation, prepared statement, parameter binding
-- ============================================================================

-- Bind one column that may be NULL on a sequences row.
local function bind_nullable(stmt, idx, val)
    if val == nil then
        if stmt.bind_null then stmt:bind_null(idx) else stmt:bind_value(idx, nil) end
    else
        stmt:bind_value(idx, val)
    end
end

-- Enforce the master-only NULL window for audio_sample_rate / width / height
-- and the kind whitelist. Throws actionable assertions on violation.
local function validate_save_invariants(self)
    assert(self.kind == "master" or self.kind == "sequence",
        "Sequence.save: kind must be 'master' or 'sequence' (V9); got " .. tostring(self.kind))

    if self.audio_sample_rate ~= nil then
        assert(type(self.audio_sample_rate) == "number" and self.audio_sample_rate > 0,
            "Sequence.save: audio_sample_rate must be a positive number when set (sequence "
            .. tostring(self.id) .. ")")
    else
        assert(self.kind == "master", string.format(
            "Sequence.save: audio_sample_rate=nil is permitted only on masters; "
            .. "sequence %s has kind='%s'", tostring(self.id), tostring(self.kind)))
    end

    if self.width ~= nil or self.height ~= nil then
        assert(type(self.width) == "number" and self.width > 0
            and type(self.height) == "number" and self.height > 0,
            "Sequence.save: width and height must both be positive numbers when set (sequence "
            .. tostring(self.id) .. ")")
    else
        assert(self.kind == "master", string.format(
            "Sequence.save: width/height=nil is permitted only on masters; "
            .. "sequence %s has kind='%s'", tostring(self.id), tostring(self.kind)))
    end

    -- Schema-NOT-NULL columns. Sequence.load asserts these are non-NULL on
    -- read, so any path that produces a sequence with these unset is a bug
    -- to surface, not paper over with a silent default.
    assert(type(self.start_timecode_frame) == "number",
        "Sequence.save: start_timecode_frame required (sequence " .. tostring(self.id) .. ")")
    assert(type(self.video_scroll_offset) == "number",
        "Sequence.save: video_scroll_offset required (sequence " .. tostring(self.id) .. ")")
    assert(type(self.audio_scroll_offset) == "number",
        "Sequence.save: audio_scroll_offset required (sequence " .. tostring(self.id) .. ")")
    assert(type(self.video_audio_split_ratio) == "number",
        "Sequence.save: video_audio_split_ratio required (sequence " .. tostring(self.id) .. ")")
    assert(type(self.created_at) == "number",
        "Sequence.save: created_at required (sequence " .. tostring(self.id) .. ")")
end

-- ON CONFLICT DO UPDATE upsert. INSERT OR REPLACE would DELETE first and
-- cascade-delete clips via foreign keys; we rely on the upsert form.
local function prepare_save_stmt(conn)
    local stmt = conn:prepare([[
        INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
         start_timecode_frame,
         playhead_frame, view_start_frame, view_duration_frames,
         video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
         mark_in_frame, mark_out_frame, audio_sample_rate,
         selected_clip_ids, selected_edge_infos, selected_gap_infos,
         default_video_layer_track_id, video_start_tc_frame,
         audio_start_tc_samples, fps_mismatch_policy,
         created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            name = excluded.name,
            kind = excluded.kind,
            fps_numerator = excluded.fps_numerator,
            fps_denominator = excluded.fps_denominator,
            width = excluded.width,
            height = excluded.height,
            start_timecode_frame = excluded.start_timecode_frame,
            playhead_frame = excluded.playhead_frame,
            view_start_frame = excluded.view_start_frame,
            view_duration_frames = excluded.view_duration_frames,
            video_scroll_offset = excluded.video_scroll_offset,
            audio_scroll_offset = excluded.audio_scroll_offset,
            video_audio_split_ratio = excluded.video_audio_split_ratio,
            mark_in_frame = excluded.mark_in_frame,
            mark_out_frame = excluded.mark_out_frame,
            audio_sample_rate = excluded.audio_sample_rate,
            selected_clip_ids = excluded.selected_clip_ids,
            selected_edge_infos = excluded.selected_edge_infos,
            selected_gap_infos = excluded.selected_gap_infos,
            default_video_layer_track_id = excluded.default_video_layer_track_id,
            video_start_tc_frame = excluded.video_start_tc_frame,
            audio_start_tc_samples = excluded.audio_start_tc_samples,
            fps_mismatch_policy = excluded.fps_mismatch_policy,
            modified_at = excluded.modified_at
    ]])
    if not stmt then
        local err = conn.last_error and conn:last_error() or "unknown error"
        error("Sequence.save: failed to prepare insert statement: " .. err)
    end
    return stmt
end

local function bind_save_params(stmt, self)
    stmt:bind_value(1,  self.id)
    stmt:bind_value(2,  self.project_id)
    stmt:bind_value(3,  self.name)
    stmt:bind_value(4,  self.kind)
    stmt:bind_value(5,  self.frame_rate.fps_numerator)
    stmt:bind_value(6,  self.frame_rate.fps_denominator)
    bind_nullable(stmt, 7, self.width)
    bind_nullable(stmt, 8, self.height)
    stmt:bind_value(9,  self.start_timecode_frame)
    stmt:bind_value(10, self.playhead_position)
    stmt:bind_value(11, self.viewport_start_time)
    stmt:bind_value(12, self.viewport_duration)
    stmt:bind_value(13, self.video_scroll_offset)
    stmt:bind_value(14, self.audio_scroll_offset)
    stmt:bind_value(15, self.video_audio_split_ratio)
    bind_nullable(stmt, 16, self.mark_in)
    bind_nullable(stmt, 17, self.mark_out)
    bind_nullable(stmt, 18, self.audio_sample_rate)
    -- Selection JSON columns: schema declares TEXT DEFAULT '[]'. Mirror it
    -- — an empty-string fallback would produce un-parseable JSON on read.
    stmt:bind_value(19, self.selected_clip_ids_json or "[]")
    stmt:bind_value(20, self.selected_edge_infos_json or "[]")
    stmt:bind_value(21, self.selected_gap_infos_json or "[]")
    bind_nullable(stmt, 22, self.default_video_layer_track_id)
    bind_nullable(stmt, 23, self.video_start_tc_frame)
    bind_nullable(stmt, 24, self.audio_start_tc_samples)
    bind_nullable(stmt, 25, self.fps_mismatch_policy)
    stmt:bind_value(26, self.created_at)
    stmt:bind_value(27, self.modified_at)
end

function Sequence:save()
    assert(self and self.id and self.id ~= "", "Sequence.save: invalid sequence or missing id")
    assert(self.project_id and self.project_id ~= "", "Sequence.save: project_id is required")
    local conn = resolve_db()
    if not conn then return false end

    self.modified_at = os.time()
    validate_save_invariants(self)
    local stmt = prepare_save_stmt(conn)
    bind_save_params(stmt, self)

    local ok = stmt:exec()
    if not ok then
        local err = stmt:last_error()
        stmt:finalize()
        error(string.format("Sequence.save: failed for %s: %s", tostring(self.id), tostring(err)))
    end
    stmt:finalize()

    -- FU-8: Notify entity watchers
    require("core.watchers").notify_sequence(self.id)

    return ok
end

--- Return a sorted, deduplicated list of edit-point frames for this
--- sequence. An edit point is any frame where timeline content changes
--- shape — a clip's start, a clip's end, or the sequence's TC origin
--- (the leftmost legal playhead). Used by Prev/Next-edit navigation.
--- Seeding with start_timecode_frame matters: a sequence whose content
--- begins at TC > 0 has no edit points below it, and navigating to
--- frame 0 would land outside the content range.
function Sequence:edit_points()
    assert(self.id and self.id ~= "",
        "Sequence:edit_points: invalid sequence (no id)")
    assert(type(self.start_timecode_frame) == "number",
        "Sequence:edit_points: start_timecode_frame must be a number")
    local conn = resolve_db()
    assert(conn, "Sequence:edit_points: no database connection")
    local points = { self.start_timecode_frame }
    local stmt = assert(conn:prepare([[
        SELECT sequence_start_frame, duration_frames
          FROM clips
         WHERE owner_sequence_id = ?
    ]]), "Sequence:edit_points: failed to prepare clips query")
    stmt:bind_value(1, self.id)
    assert(stmt:exec(), "Sequence:edit_points: clips query exec failed")
    while stmt:next() do
        local start = stmt:value(0)
        local duration = stmt:value(1)
        assert(type(start) == "number",
            "Sequence:edit_points: clip sequence_start_frame is non-numeric")
        assert(type(duration) == "number",
            "Sequence:edit_points: clip duration_frames is non-numeric")
        table.insert(points, start)
        table.insert(points, start + duration)
    end
    stmt:finalize()
    table.sort(points)
    local unique = {}
    local last = nil
    for _, p in ipairs(points) do
        if p ~= last then
            table.insert(unique, p)
            last = p
        end
    end
    return unique
end

--- Lightweight scroll offset update — avoids full save overhead.
-- Pass nil for either offset to leave it unchanged.
function Sequence.update_scroll_offsets(seq_id, video_offset, audio_offset)
    local db = require("core.database")
    local conn = assert(db.get_connection(), "Sequence.update_scroll_offsets: no database connection")
    if video_offset then
        local stmt = assert(conn:prepare("UPDATE sequences SET video_scroll_offset = ? WHERE id = ?"))
        stmt:bind_value(1, video_offset)
        stmt:bind_value(2, seq_id)
        stmt:exec()
        stmt:finalize()
    end
    if audio_offset then
        local stmt = assert(conn:prepare("UPDATE sequences SET audio_scroll_offset = ? WHERE id = ?"))
        stmt:bind_value(1, audio_offset)
        stmt:bind_value(2, seq_id)
        stmt:exec()
        stmt:finalize()
    end
end

--- Surgical playhead persist — touches only playhead_frame.
-- Does NOT re-bind project_id, default_video_layer_track_id, or any
-- other column on the sequences row. Persisting the playhead must not
-- be coupled to the validity of unrelated fields on a cached in-memory
-- sequence object — full Sequence:save() would re-bind every column
-- and fail FK if any of them happen to be stale.
function Sequence.update_playhead(seq_id, playhead_frame)
    assert(seq_id and seq_id ~= "",
        "Sequence.update_playhead: seq_id is required")
    assert(type(playhead_frame) == "number" and playhead_frame == math.floor(playhead_frame),
        "Sequence.update_playhead: playhead_frame must be an integer")
    local db = require("core.database")
    local conn = assert(db.get_connection(),
        "Sequence.update_playhead: no database connection")
    local stmt = assert(
        conn:prepare("UPDATE sequences SET playhead_frame = ?, modified_at = ? WHERE id = ?"),
        "Sequence.update_playhead: failed to prepare statement")
    stmt:bind_value(1, playhead_frame)
    stmt:bind_value(2, os.time())
    stmt:bind_value(3, seq_id)
    local ok = stmt:exec()
    local err = ok and nil or conn:last_error()
    stmt:finalize()
    assert(ok, string.format(
        "Sequence.update_playhead: UPDATE failed for %s: %s",
        tostring(seq_id), tostring(err)))

    -- FU-8: Notify entity watchers
    require("core.watchers").queue_notify("sequence:" .. seq_id, { kind = "playhead" })
end

-- Atomically increment a sequence's mutation_generation counter.
-- Called after every successful sequence-scoped mutation; cached
-- generation values held by nested-sequence references become stale
-- on the next read. O(1) single-row UPDATE, no read-modify-write.
--
-- Asserts on unknown sequence_id: a caller reaching this function with
-- an id that doesn't exist is a bug (stale sequence_id on a command,
-- or a command targeting a sequence that was deleted out from under
-- it). Silent zero-rows-affected would hide that bug.
function Sequence.increment_generation(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "Sequence.increment_generation: sequence_id is required")
    local db = require("core.database")
    local conn = assert(db.get_connection(),
        "Sequence.increment_generation: no database connection")
    local stmt = assert(
        conn:prepare("UPDATE sequences SET mutation_generation = mutation_generation + 1 WHERE id = ?"),
        "Sequence.increment_generation: failed to prepare statement")
    stmt:bind_value(1, sequence_id)
    local ok = stmt:exec()
    local err = ok and nil or conn:last_error()
    stmt:finalize()
    assert(ok, string.format(
        "Sequence.increment_generation: UPDATE failed for %s: %s",
        tostring(sequence_id), tostring(err)))
    local affected = conn:changes()
    assert(affected == 1, string.format(
        "Sequence.increment_generation: no row matched sequence_id %s (changes=%d)",
        tostring(sequence_id), tonumber(affected) or -1))
end

-- Count all sequences in the database
function Sequence.count()
    local db = require("core.database")
    local conn = assert(db.get_connection(), "Sequence.count: no database connection")
    local stmt = assert(conn:prepare("SELECT COUNT(*) FROM sequences"), "Sequence.count: failed to prepare query")
    assert(stmt:exec(), "Sequence.count: query execution failed")
    assert(stmt:next(), "Sequence.count: no result row")
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Count clips in one sequence (project-scoped via FK on tracks).
function Sequence.count_clips(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "Sequence.count_clips: sequence_id required")
    local conn = assert(database.get_connection(), "Sequence.count_clips: no database connection")
    local sql = "SELECT COUNT(*) FROM clips c JOIN tracks t ON c.track_id = t.id WHERE t.sequence_id = ?"
    return database.count(conn, sql, { sequence_id })
end

--- Rebind all sequences from one project_id to another.
-- Used by project_templates when stamping a new identity on a copied .jvp.
-- @param old_project_id string
-- @param new_project_id string
function Sequence.rebind_to_project(old_project_id, new_project_id)
    assert(old_project_id and old_project_id ~= "",
        "Sequence.rebind_to_project: old_project_id required")
    assert(new_project_id and new_project_id ~= "",
        "Sequence.rebind_to_project: new_project_id required")

    local conn = resolve_db()
    local stmt = assert(conn:prepare(
        "UPDATE sequences SET project_id = ? WHERE project_id = ?"),
        "Sequence.rebind_to_project: failed to prepare UPDATE")
    stmt:bind_value(1, new_project_id)
    stmt:bind_value(2, old_project_id)
    assert(stmt:exec(), "Sequence.rebind_to_project: UPDATE failed")
    stmt:finalize()
end

--- Find the first sequence belonging to a project.
-- @param project_id string
-- @return string|nil: sequence id
function Sequence.find_first_by_project(project_id)
    assert(project_id and project_id ~= "",
        "Sequence.find_first_by_project: project_id required")

    local conn = resolve_db()
    local stmt = assert(conn:prepare(
        "SELECT id FROM sequences WHERE project_id = ? LIMIT 1"),
        "Sequence.find_first_by_project: failed to prepare query")
    stmt:bind_value(1, project_id)
    if not stmt:exec() or not stmt:next() then
        stmt:finalize()
        return nil
    end
    local id = stmt:value(0)
    stmt:finalize()
    return id
end

--- Set undo cursor on all timeline sequences in a project.
-- Used by importers to initialize the undo position after populating a fresh DB.
function Sequence.set_undo_cursor_for_project(project_id, cursor_value)
    assert(project_id and project_id ~= "",
        "Sequence.set_undo_cursor_for_project: project_id required")
    assert(type(cursor_value) == "number",
        "Sequence.set_undo_cursor_for_project: cursor_value must be number")
    local conn = resolve_db()
    -- Per-sequence undo cursor was scoped to non-master sequences (the
    -- user's edit timelines). V13 narrowed `kind` from {timeline,
    -- masterclip,compound,multicam} to {master,nested}; the
    -- non-master set is now exactly kind='sequence'.
    local stmt = assert(conn:prepare([[
        UPDATE sequences SET current_sequence_number = ?
        WHERE project_id = ? AND kind = 'sequence'
    ]]), "Sequence.set_undo_cursor_for_project: failed to prepare")
    stmt:bind_value(1, cursor_value)
    stmt:bind_value(2, project_id)
    assert(stmt:exec(), "Sequence.set_undo_cursor_for_project: UPDATE failed")
    stmt:finalize()
end

-- Find the most recently modified sequence in the database
-- Returns sequence object, or nil if none exist
--- Resolve the initial active sequence for a project on open.
--- Reads the project setting `last_open_sequence_id`; if present and
--- resolves to a real sequence, returns that Sequence. Otherwise returns
--- nil (no fallback). Feature 010: the editor enters the no-active-
--- sequence state when this returns nil.
--- @param project_id string
--- @return table|nil: Sequence object or nil
function Sequence.resolve_initial_for_project(project_id)
    assert(project_id and project_id ~= "",
        "Sequence.resolve_initial_for_project: project_id is required")
    local last_seq_id = database.get_project_setting(project_id, "last_open_sequence_id")
    if not last_seq_id or last_seq_id == "" then
        return nil
    end
    -- Sequence.load returns nil if the stored id no longer resolves
    -- (deleted sequence); don't resurrect.
    return Sequence.load(last_seq_id)
end

function Sequence.find_most_recent()
    local conn = resolve_db()

    -- Filter to non-master sequences (kind='sequence'). Per V13 the
    -- "timeline" kind narrows to 'sequence'; masters are not listed in
    -- the recent-sequences UI surface this serves.
    local stmt = assert(conn:prepare([[
        SELECT id FROM sequences
        WHERE kind = 'sequence'
        ORDER BY modified_at DESC, created_at DESC, id ASC
        LIMIT 1
    ]]), "Sequence.find_most_recent: failed to prepare query")

    if not stmt:exec() or not stmt:next() then
        stmt:finalize()
        return nil
    end

    local id = stmt:value(0)
    stmt:finalize()

    if not id or id == "" then
        return nil
    end

    return Sequence.load(id)
end


-- =============================================================================
-- MASTER SEQUENCE METHODS (for kind="master")
-- =============================================================================

--- Whether this sequence is a master (V13 kind='master'). The `kind`
--- value narrowed from {timeline,masterclip,compound,multicam} to
--- {master,nested} in V13; this checks the new value.
function Sequence:is_master()
    return self.kind == "master"
end


-- =============================================================================
-- TIMEBASE CONVERSION (for master sequences)
-- =============================================================================

-- 018 (FR-016, FR-017): Sequence:frame_to_samples / Sequence:samples_to_frame
-- removed. These assumed a single "first audio stream sample rate" per master,
-- but masters now have NULL audio_sample_rate (rate is per-media_ref — a master
-- can hold media_refs at heterogeneous sample rates). Sample/tick conversion
-- goes through subframe_math with explicit per-media_ref audio_sample_rate
-- inputs.

-- =============================================================================
-- MARK METHODS (read/write sequence-level mark_in/mark_out)
-- =============================================================================
-- Marks are UI metadata stored on the sequence record (mark_in_frame,
-- mark_out_frame columns). Stream clips keep source_in=0, source_out=full
-- always — marks do NOT constrain the rendering view.

--- Set mark-in point (video frame units, absolute TC).
-- @param frame number Frame position in video timebase
function Sequence:set_in(frame)
    assert(type(frame) == "number", "Sequence:set_in: frame must be a number")
    local dur = self:content_duration()
    if dur > 0 then
        local start = self.start_timecode_frame or 0
        local end_frame = start + dur
        assert(frame >= start and frame < end_frame,
            string.format("Sequence:set_in(%s): frame %d out of [%d, %d)",
                tostring(self.id), frame, start, end_frame))
    end
    self.mark_in = frame
    self:save()
end

--- Set mark-out point (video frame units, absolute TC).
-- @param frame number Frame position in video timebase
function Sequence:set_out(frame)
    assert(type(frame) == "number", "Sequence:set_out: frame must be a number")
    local dur = self:content_duration()
    if dur > 0 then
        local start = self.start_timecode_frame or 0
        local end_frame = start + dur
        assert(frame >= start and frame <= end_frame,
            string.format("Sequence:set_out(%s): frame %d out of [%d, %d]",
                tostring(self.id), frame, start, end_frame))
    end
    self.mark_out = frame
    self:save()
end

--- Get mark-in point (video frame units, nil = no mark).
-- @return number|nil
function Sequence:get_in()
    return self.mark_in
end

--- Get mark-out point (video frame units, nil = no mark).
-- @return number|nil
function Sequence:get_out()
    return self.mark_out
end

--- Clear both marks.
function Sequence:clear_marks()
    self.mark_in = nil
    self.mark_out = nil
    self:save()
end

--- Check if any mark is set.
-- @return boolean
function Sequence:has_marks()
    return self.mark_in ~= nil or self.mark_out ~= nil
end

--- Get effective mark-in (0 if unset).
-- @return number
function Sequence:get_effective_in()
    return self.mark_in or 0
end

--- Get effective mark-out (total_frames if unset).
-- @param total_frames number The sequence length (exclusive end)
-- @return number
function Sequence:get_effective_out(total_frames)
    assert(type(total_frames) == "number",
        "Sequence:get_effective_out: total_frames must be a number")
    return self.mark_out or total_frames
end

-- =============================================================================
-- 018 (FR-016, FR-017): legacy dual-unit mark accessors deleted.
-- =============================================================================
-- The pre-018 Sequence:get_effective_video_in/out, get_effective_audio_in/out,
-- video_frame_to_audio_sample existed to paper over the audio-source-in-samples
-- vs. video-source-in-frames mismatch on mixed-media masters. 018 standardises
-- on master.fps frames for clip.source_in_frame across both mediums, with
-- sub-frame precision in clip.source_*_subframe (master-clock ticks). Mark
-- conversion is now frame-only via the existing get_in / get_out / set_in /
-- set_out accessors above; sample-precise file positions are derived inside
-- pick_master_leaf via subframe_math (FR-008).

-- =============================================================================
-- POINT-IN-TIME ACCESSORS (Sequence:get_video_at, get_audio_at,
-- get_next_video, get_prev_video, get_next_audio, get_prev_audio)
-- live in models/sequence/point_in_time.lua (extracted for 2.6).
-- Methods are installed onto Sequence at the bottom of this file.
-- =============================================================================

-- Public-boundary wrappers over the resolver. Returned entry is flat:
-- consumers (playback_engine, render preview, integration tests) read
-- fields directly off the entry — no entry.clip / entry.track / .media_fps_*
-- nesting. Each entry describes the OUTERMOST owner's full owner-coord
-- extent (sequence_start, duration), media-file source range (source_in,
-- source_out), and routing (track_index, track_type). The leaf media's
-- native rate rides along as fps_numerator / fps_denominator so consumers
-- can compute speed ratios without re-loading the Media row.

-- Promote a resolver internal entry to the public flat shape. Tags
-- already on the entry from pick_nested / pick_master_leaf:
-- owner_clip_id, owner_track_index, owner_track_type. Outer-coord
-- sequence_start / duration are already set to the outermost extent
-- because pick_nested recurses with each clip's full source window
-- (not intersected with the playback window), and translate_to_outer
-- maps that to the outer clip's full extent. media_cache reuses Media
-- rows across entries in one batch.
local function finalize_to_flat(e, media_cache)
    local Media = require("models.media")
    local media = media_cache[e.media_id]
    if not media then
        media = Media.load(e.media_id)
        assert(media, string.format(
            "Sequence resolver: media row missing for media_id=%s "
            .. "(kind=%s, source=[%s,%s])",
            tostring(e.media_id), tostring(e.media_kind),
            tostring(e.source_in), tostring(e.source_out)))
        media_cache[e.media_id] = media
    end
    e.fps_numerator   = media.frame_rate.fps_numerator
    e.fps_denominator = media.frame_rate.fps_denominator
    e.clip_id         = e.owner_clip_id
    e.track_index     = e.owner_track_index
    e.track_type      = e.owner_track_type
    -- Internal owner_* fields have served their purpose; strip them so
    -- consumers don't depend on resolver internals.
    e.owner_clip_id     = nil
    e.owner_track_index = nil
    e.owner_track_type  = nil
    return e
end

-- Filter to one media kind, drop offline entries (TMB requires a non-empty
-- path; park-mode offline overlay is driven separately by media_status —
-- see todo_offline_overlay_during_playback.md), then promote to flat.
-- Also overlap-filter to the requested [from, to) since the resolver may
-- have widened the recursion window.
local function filter_and_finalize(entries, kind, from_frame, to_frame)
    local out = {}
    local cache = {}
    for _, e in ipairs(entries) do
        if e.media_kind == kind and e.media_path and e.media_path ~= "" then
            local e_lo = e.sequence_start
            local e_hi = e.sequence_start + e.duration
            if e_hi > from_frame and e_lo < to_frame then
                out[#out + 1] = finalize_to_flat(e, cache)
            end
        end
    end
    return out
end

-- Pick the resolver bounds. For a master sequence (source viewer playing
-- the master directly) we want every media_ref returned at FULL extent;
-- master_leaf clips entries to the master_lo/master_hi window, so we
-- pass a wide range and let filter_and_finalize re-narrow by overlap.
-- For a nested sequence, list_clips_overlapping uses the window to skip
-- non-overlapping outer clips — pass it through unchanged. pick_nested
-- internally recurses each in-scope clip with its full source window.
local function pick_resolve_bounds(self, from_frame, to_frame)
    if self.kind == "master" then
        return 0, math.huge
    end
    return from_frame, to_frame
end

--- Resolve video entries that overlap a frame range. Instance method.
-- @param from_frame integer: inclusive start in self's timebase
-- @param to_frame integer: exclusive end
-- @return list of flat entries, each at the OUTERMOST owner's full extent
function Sequence:get_video_in_range(from_frame, to_frame)
    assert(self and type(self.id) == "string" and self.id ~= "",
        "Sequence:get_video_in_range: must be called on a sequence instance")
    assert(type(from_frame) == "number",
        "Sequence:get_video_in_range: from_frame must be integer")
    assert(type(to_frame) == "number",
        "Sequence:get_video_in_range: to_frame must be integer")
    assert(from_frame < to_frame, string.format(
        "Sequence:get_video_in_range: from_frame %d must be < to_frame %d",
        from_frame, to_frame))
    local lo, hi = pick_resolve_bounds(self, from_frame, to_frame)
    local entries = Sequence:pick_in_range(self.id, lo, hi, {})
    return filter_and_finalize(entries, "video", from_frame, to_frame)
end

--- Resolve audio entries that overlap a frame range. Instance method.
-- @param from_frame integer: inclusive start in self's timebase
-- @param to_frame integer: exclusive end
-- @return list of flat entries, each at the OUTERMOST owner's full extent
function Sequence:get_audio_in_range(from_frame, to_frame)
    assert(self and type(self.id) == "string" and self.id ~= "",
        "Sequence:get_audio_in_range: must be called on a sequence instance")
    assert(type(from_frame) == "number",
        "Sequence:get_audio_in_range: from_frame must be integer")
    assert(type(to_frame) == "number",
        "Sequence:get_audio_in_range: to_frame must be integer")
    assert(from_frame < to_frame, string.format(
        "Sequence:get_audio_in_range: from_frame %d must be < to_frame %d",
        from_frame, to_frame))
    local lo, hi = pick_resolve_bounds(self, from_frame, to_frame)
    local entries = Sequence:pick_in_range(self.id, lo, hi, {})
    return filter_and_finalize(entries, "audio", from_frame, to_frame)
end

--- Get sorted list of track indices for a given track type.
-- @param track_type string: "VIDEO" or "AUDIO"
-- @return list of integers, sorted ascending
function Sequence:get_track_indices(track_type)
    assert(track_type == "VIDEO" or track_type == "AUDIO", string.format(
        "Sequence:get_track_indices: track_type must be 'VIDEO' or 'AUDIO', got '%s'",
        tostring(track_type)))

    local Track = require("models.track")
    local tracks = Track.find_by_sequence(self.id, track_type)
    local indices = {}
    for _, track in ipairs(tracks) do
        indices[#indices + 1] = track.track_index
    end
    table.sort(indices)
    return indices
end

--- Compute the furthest clip end frame in this sequence.
-- Returns max(sequence_start + duration) across all clips on all tracks —
-- an ABSOLUTE timeline frame, NOT a span. For master sequences this is in
-- TC space (media_refs sit at sequence_start_frame = file_tc_origin per
-- TIMECODE-IS-TRUTH), so the result equals tc_origin + content_duration.
-- Playback bounds [start_frame, total_frames) consume this directly.
-- @return integer  0 if no content
function Sequence:compute_content_end()
    -- V13: master sequences hold media_refs (not clips). Same algebra,
    -- different table. content_duration() is a SPAN (length) and not
    -- appropriate here — callers need the absolute end frame.
    if self.kind == "master" then
        -- Post-unification: VIDEO and AUDIO media_refs both store
        -- sequence_start_frame + duration_frames in master.fps frames
        -- (== video.fps for dual-medium masters; == audio sample_rate
        -- for audio-only masters where master.fps is set to sr). Either
        -- medium therefore yields a comparable absolute frame; the V/A
        -- branch below is a presence check, not a unit branch.
        local function end_for(track_type)
            local conn = resolve_db()
            local stmt = conn:prepare([[
                SELECT COALESCE(MAX(r.sequence_start_frame + r.duration_frames), 0)
                FROM media_refs r
                JOIN tracks t ON r.track_id = t.id
                WHERE t.sequence_id = ? AND t.track_type = ?
            ]])
            assert(stmt, "Sequence:compute_content_end: prepare failed (master)")
            stmt:bind_value(1, self.id)
            stmt:bind_value(2, track_type)
            assert(stmt:exec(), "Sequence:compute_content_end: exec failed (master)")
            assert(stmt:next(), "Sequence:compute_content_end: no row (master)")
            local v = stmt:value(0)
            stmt:finalize()
            return v
        end
        local v_end = end_for("VIDEO")
        if v_end > 0 then return v_end end
        return end_for("AUDIO")
    end
    local database = require("core.database") -- luacheck: ignore 431
    assert(database.has_connection(),
        "Sequence:compute_content_end: no database connection")
    local db = database.get_connection()

    local stmt = db:prepare([[
        SELECT MAX(c.sequence_start_frame + c.duration_frames)
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ?
    ]])
    assert(stmt, "Sequence:compute_content_end: failed to prepare query")
    stmt:bind_value(1, self.id)
    assert(stmt:exec(), "Sequence:compute_content_end: query exec failed")

    local max_end = 0
    if stmt:next() then
        local val = stmt:value(0)
        if val then max_end = val end
    end
    stmt:finalize()

    return max_end
end

--- Content duration in frames.
-- For master sequences (V13 kind='master'): max(sequence_start_frame +
--   duration_frames) across V media_refs. (Falls back to the audio
--   media_refs' max if no video.) Computed via the existing
--   Sequence.native_duration_for_medium helper which already returns
--   the correct value for either medium.
-- For non-master sequences (kind='sequence'): max(sequence_start +
--   duration) across track clips, computed by compute_content_end().
-- @return integer  0 if no content
function Sequence:content_duration()
    if self:is_master() then
        -- Prefer video; fall back to audio for video-less masters.
        local v_dur = Sequence.native_duration_for_medium(self.id, "VIDEO")
        if v_dur and v_dur > 0 then return v_dur end
        local a_dur = Sequence.native_duration_for_medium(self.id, "AUDIO")
        return a_dur or 0
    end
    -- Non-master: clips' sequence_start_frame is in absolute TC space
    -- (Insert/Overwrite place clips at owner.playhead_position, which is
    -- itself absolute TC). compute_content_end returns the absolute END
    -- frame, not a span — subtract the sequence's TC origin to get the
    -- length consumers (set_in/set_out/set_playhead bounds, match_frame
    -- clamps) actually expect.
    local end_frame = self:compute_content_end()
    if end_frame <= 0 then return 0 end
    local start = self.start_timecode_frame
    assert(type(start) == "number" and start >= 0, string.format(
        "Sequence:content_duration(%s): start_timecode_frame must be a "
        .. "non-negative integer, got %s",
        tostring(self.id), tostring(start)))
    return end_frame - start
end

--- Set playhead position with bounds validation.
-- Asserts frame is within [start_tc, start_tc + content_duration).
-- @param frame integer  playhead position in video frames (absolute TC)
function Sequence:set_playhead(frame)
    assert(type(frame) == "number",
        string.format("Sequence:set_playhead(%s): frame must be number, got %s",
            tostring(self.id), type(frame)))
    assert(frame == math.floor(frame),
        string.format("Sequence:set_playhead(%s): frame must be integer, got %s",
            tostring(self.id), tostring(frame)))
    local start = self.start_timecode_frame or 0
    assert(frame >= start,
        string.format("Sequence:set_playhead(%s): frame %d < start_tc %d",
            tostring(self.id), frame, start))
    local duration = self:content_duration()
    if duration > 0 then
        local end_frame = start + duration
        -- Playhead may equal end_frame (the cursor lives just past the
        -- last frame after advance_playhead from Insert/Overwrite, or
        -- after a delete that leaves it at the new tail). Reject strictly
        -- only if it goes BEYOND end.
        assert(frame <= end_frame,
            string.format("Sequence:set_playhead(%s): frame %d > end %d (start_tc=%d, dur=%d)",
                tostring(self.id), frame, end_frame, start, duration))
    end
    self.playhead_position = frame
end

-- ===========================================================================
-- Feature 013: pick_in_range — public delegate
-- ===========================================================================
-- The resolver walks the clip → nested sequence → (recurse) → media_ref →
-- media chain for a given sequence and time range. Single code path for
-- playback + export (FR-019). All ~750 LOC of helpers live in
-- models/sequence/resolver.lua (extracted from this file for 2.6); this
-- method is the thin Sequence-tier delegate so external call sites (and
-- the 018-uniform-clip-source spec, which names Sequence:pick_in_range
-- as the public entry point) continue to work unchanged.
function Sequence:pick_in_range(seq_id, start_frame, end_frame, context)
    return require("models.sequence.resolver").pick_in_range(
        resolve_db(), seq_id, start_frame, end_frame, context)
end

--- 018 FR-035: ConformSequence's transactional rewrite. Thin delegate
--- to models.sequence.conform.conform_fps (extracted for 2.6). Body
--- lives there; see that module's docstring for the per-arg contract.
function Sequence.conform_fps(sequence_id, new_fps_num, new_fps_den, captured, rescaler)
    return require("models.sequence.conform").conform_fps(
        resolve_db(), sequence_id, new_fps_num, new_fps_den, captured, rescaler)
end

--- 018 FR-035 helpers — collect the row snapshots ConformSequence must
--- rewrite. Read-only; safe outside a savepoint. Thin delegate to
--- models.sequence.conform.collect_conform_captured.
function Sequence.collect_conform_captured(sequence_id)
    return require("models.sequence.conform").collect_conform_captured(
        resolve_db(), Sequence.find, sequence_id)
end

--- 018 FR-005: pick the first (oldest-created) record sequence's
--- audio_sample_rate for a project. Used by audio_bus_rate when no
--- active record is set yet. Returns nil if the project has zero
--- record sequences with a valid rate.
function Sequence.find_first_record_audio_rate(project_id)
    assert(project_id and project_id ~= "",
        "Sequence.find_first_record_audio_rate: project_id required")
    local db = require("core.database").get_connection()
    assert(db, "Sequence.find_first_record_audio_rate: no db connection")
    local stmt = db:prepare([[
        SELECT audio_sample_rate FROM sequences
        WHERE project_id = ? AND kind = 'sequence'
              AND audio_sample_rate IS NOT NULL
              AND audio_sample_rate > 0
        ORDER BY created_at ASC
        LIMIT 1
    ]])
    assert(stmt, "Sequence.find_first_record_audio_rate: prepare failed")
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), "Sequence.find_first_record_audio_rate: exec failed")
    local rate
    if stmt:next() then rate = stmt:value(0) end
    stmt:finalize()
    return rate
end

-- Install point-in-time accessor methods (get_video_at, get_audio_at,
-- get_next/prev_video/audio). Defined in models/sequence/point_in_time.lua
-- but live on this class — extracted for 2.6 without changing the surface.
require("models.sequence.point_in_time").install(Sequence)

-- Install masterclip-factory methods (ensure_master,
-- find_master_for_media, find_masters_for_media_tc_sync,
-- batch_set/restore_master_start_tc, get_first_media_ref). Defined in
-- models/sequence/master_builder.lua; extracted for 2.6. ensure_master
-- calls Sequence.create and Sequence.update which are defined above in
-- this file — reached through the Sequence arg at install time.
require("models.sequence.master_builder").install(Sequence)

-- Install snapshot methods (capture_full_state, restore_full_state) used
-- by Unnest.execute / undo. Defined in models/sequence/snapshot.lua.
require("models.sequence.snapshot").install(Sequence)

-- Install master-stream methods (video_stream, audio_streams,
-- num_audio_streams, invalidate_stream_cache) — the legacy V8-shaped
-- contract for callers iterating a master's media_refs as "stream clips".
-- Defined in models/sequence/streams.lua.
require("models.sequence.streams").install(Sequence)

-- Install table-form class helpers (find, assert_default_video_layer_valid,
-- update, native_duration_for_medium, contained_mediums, get_name,
-- delete_one, set_fps_mismatch_policy, set_start_tc,
-- effective_audio_sample_rate, count_master_audio_channels,
-- get_master_channel_state). Stateless: returns row tables, writes via
-- direct UPDATE. Defined in models/sequence/queries.lua.
require("models.sequence.queries").install(Sequence)

return Sequence
