--- Lua representation of timeline sequences.
-- Mirrors the behaviour of the legacy C++ model closely enough for imports and commands.
local database = require("core.database")
local uuid = require("uuid")
local log = require("core.logger").for_area("media")
-- 018: sub-frame math primitive (FR-006). Used by resolve_master_leaf to
-- convert the (master-frame, master-clock-tick) source position carried by
-- the recursion seam into a file-natural sample offset for audio media_refs.
local subframe_math = require("core.subframe_math")

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

    -- Integer frame coordinates (fps is metadata in frame_rate)
    local playhead_pos = opts.playhead_frame or 0
    local viewport_start = opts.view_start_frame or 0
    local viewport_dur = opts.view_duration_frames or Sequence.default_viewport_duration(fr.fps_numerator, fr.fps_denominator)

    local start_tc = opts.start_timecode_frame or 0
    assert(type(start_tc) == "number" and start_tc >= 0,
        string.format("Sequence.create: start_timecode_frame must be non-negative integer, got %s",
            tostring(start_tc)))
    start_tc = math.floor(start_tc)

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
            "Sequence.create: kind='master' must have audio_sample_rate=nil (INV-7; "
            .. "audio rate is per-media_ref, not per-master)")
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
    return ok
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
-- MASTERCLIP FACTORY: find-or-create masterclip sequence for a media item
-- =============================================================================

--- Ensure a masterclip sequence exists for a given media item.
-- Idempotent: returns existing masterclip sequence_id if one exists, otherwise creates one.
-- @param media_id string: Media record ID
-- @param project_id string: Project ID
-- @param opts table: Optional replay IDs for redo determinism:
--   id, video_track_id, video_clip_id, audio_track_ids, audio_clip_ids
-- @return string: masterclip sequence_id
--- V13 master-sequence creation. Replaces ensure_masterclip.
---
--- Idempotent: if a kind='master' sequence already references this media_id
--- via any of its media_refs, returns its id. Otherwise builds one:
---   * sequences row with kind='master', timebase from media.fps,
---     audio_sample_rate from media.audio_sample_rate (or opts.sample_rate).
---   * V1 track + V media_ref pointing at the file (source frames 0..duration).
---   * One A track per media.audio_channels, each with a media_ref over
---     samples 0..duration_samples.
---   * sequences.video_start_tc_frame / audio_start_tc_samples populated
---     from media TC (FR-017 default-derivation).
---   * sequences.default_video_layer_track_id = the V1 track when video
---     present (default_video_layer_track_id must be non-NULL when video tracks exist).
---
--- Args:
---   media_id     string  required
---   project_id   string  required
---   opts:
---     id                  — optional sequence id (deterministic for replay).
---     bin_id              — optional bin to add the master to.
---     sample_rate         — required when media.audio_sample_rate is missing
---                           AND the media has audio (rule 2.13: no fallback).
---     video_track_id      — optional pre-chosen V track id.
---     video_media_ref_id  — optional pre-chosen V media_ref id (replay).
---     audio_track_ids     — optional list, indexed by channel (1-based).
---     audio_media_ref_ids — optional list of media_ref ids per channel.
---
--- Returns: master sequence id (string).
function Sequence.ensure_master(media_id, project_id, opts)
    assert(media_id and media_id ~= "",
        "Sequence.ensure_master: media_id is required")
    assert(project_id and project_id ~= "",
        "Sequence.ensure_master: project_id is required")
    opts = opts or {}

    -- LOOKUP: existing master that already references this media_id.
    local existing_id = Sequence.find_master_for_media(media_id)
    if existing_id then
        if opts.bin_id then
            local tag_service = require("core.tag_service")
            tag_service.add_to_bin(project_id, {existing_id}, opts.bin_id, "master_clip")
        end
        return existing_id
    end

    local Media    = require("models.media")
    local Track    = require("models.track")
    local MediaRef = require("models.media_ref")

    -- Load + validate the source media; gather every dimension the master
    -- needs in one named struct. Pure read; no side effects.
    local function load_media_dims()
        local media = Media.load(media_id)
        assert(media, string.format(
            "Sequence.ensure_master: Media record not found for media_id=%s",
            tostring(media_id)))
        local fps_num = media.frame_rate.fps_numerator
        local fps_den = media.frame_rate.fps_denominator
        local duration_frames = media.duration
        local has_video = media.width > 0
        local has_audio = media.audio_channels > 0
        if not has_video and not has_audio then
            log.warn("ensure_master: media %s ('%s') has no video or audio dims; "
                .. "master will have no media_refs until file is probed",
                tostring(media_id), tostring(media.name))
        end

        local sample_rate = opts.sample_rate
            or (has_audio and media.audio_sample_rate or nil)
        assert(not has_audio or (sample_rate and sample_rate > 0), string.format(
            "Sequence.ensure_master: media %s has audio but no sample_rate "
            .. "(audio_channels=%s, audio_sample_rate=%s)",
            tostring(media_id), tostring(media.audio_channels),
            tostring(media.audio_sample_rate)))

        local duration_samples = 0
        if has_audio and duration_frames > 0 then
            duration_samples = math.floor(
                duration_frames * sample_rate * fps_den / fps_num + 0.5)
        end

        -- TC origins (FR-017 defaults).
        local video_tc  = has_video and media:get_start_tc()       or nil
        local audio_tc  = has_audio and media:get_audio_start_tc() or nil
        if has_video then
            assert(video_tc ~= nil, string.format(
                "Sequence.ensure_master: media %s has no video TC origin",
                tostring(media_id)))
        end
        if has_audio then
            assert(audio_tc ~= nil, string.format(
                "Sequence.ensure_master: media %s has no audio TC origin",
                tostring(media_id)))
        end
        assert(media.name and media.name ~= "", string.format(
            "Sequence.ensure_master: media has no name for media_id=%s",
            tostring(media_id)))

        return {
            media            = media,
            fps_num          = fps_num,
            fps_den          = fps_den,
            duration_frames  = duration_frames,
            duration_samples = duration_samples,
            has_video        = has_video,
            has_audio        = has_audio,
            sample_rate      = sample_rate,
            -- 018 (FR-004): masters MUST have NULL audio_sample_rate.
            -- Audio rate is per-media_ref (a master may hold heterogeneous
            -- audio rates — synced-sound camera + field recorder, etc.).
            seq_audio_rate   = nil,
            width            = has_video and media.width  or nil,
            height           = has_video and media.height or nil,
            video_tc         = video_tc,
            audio_tc         = audio_tc,
        }
    end

    local function create_master_row(dims)
        local seq = Sequence.create(dims.media.name, project_id,
            { fps_numerator = dims.fps_num, fps_denominator = dims.fps_den },
            dims.width, dims.height, {
                id                       = opts.id,
                kind                     = "master",
                audio_sample_rate               = dims.seq_audio_rate,
                start_timecode_frame     = dims.video_tc or 0,
                playhead_frame           = dims.video_tc or 0,
                video_start_tc_frame     = dims.video_tc,
                audio_start_tc_samples   = dims.audio_tc,
            })
        assert(seq:save(), string.format(
            "Sequence.ensure_master: failed to save master sequence for media_id=%s",
            tostring(media_id)))
        return seq
    end

    -- Master sequence's timebase IS absolute TC space. Each media_ref sits
    -- at sequence_start = file's TC origin and spans [tc_origin, tc_origin
    -- + file_duration]. Clips reference absolute TC into this timebase;
    -- C++ decode recovers file position via file_pos = source_in -
    -- file_tc_origin. The range [0, tc_origin) is empty (no media there).
    local function add_video_stream(seq, dims, now)
        if not dims.has_video then return end
        local vtrack = Track.create_video("Video 1", seq.id,
            { id = opts.video_track_id, index = 1 })
        assert(vtrack:save(), "Sequence.ensure_master: failed to save video track")
        MediaRef.create({
            id                   = opts.video_media_ref_id,
            project_id           = project_id,
            owner_sequence_id    = seq.id,
            track_id             = vtrack.id,
            media_id             = media_id,
            source_in_frame      = dims.video_tc,
            source_out_frame     = dims.video_tc + dims.duration_frames,
            sequence_start_frame = dims.video_tc,
            duration_frames      = dims.duration_frames,
            enabled              = true,
            volume               = 1.0,
            playhead_frame       = 0,
            created_at           = now,
            modified_at          = now,
        })
        -- default_video_layer_track_id must be non-NULL when video tracks exist.
        Sequence.update(seq.id, { default_video_layer_track_id = vtrack.id })
    end

    local function add_audio_streams(seq, dims, now)
        if not dims.has_audio then return end
        local replay_audio_track_ids     = opts.audio_track_ids     or {}
        local replay_audio_media_ref_ids = opts.audio_media_ref_ids or {}
        -- Audio MR placement (sequence_start_frame, duration_frames) is in
        -- the master sequence's frame_rate ("master.fps"). For dual-medium
        -- (V+A) masters that's video fps, so the anchor is the file's
        -- video TC origin. For audio-only masters the sequence's fps IS
        -- the audio sample_rate (see DRP importer: frame_rate ← sr for
        -- audio-only media), so "frames-at-master.fps" === samples and
        -- the anchor is the file's audio TC in samples. The selection is
        -- per-master-kind, not a fallback — both branches are required
        -- and must produce a non-nil value (the medium dictates which).
        --
        -- source_in_frame / source_out_frame stay in file-natural audio
        -- samples — the C++ TMB GetTrackAudio subtracts first_sample_tc
        -- against these to land on file-relative samples. Sub-frame BWF
        -- precision lives on the media row (start_tc_audio_samples vs
        -- start_tc_value), recovered at the decode boundary, NOT
        -- re-encoded here.
        local seq_start
        if dims.has_video then
            seq_start = dims.video_tc
        else
            seq_start = dims.audio_tc
        end
        assert(type(seq_start) == "number", string.format(
            "Sequence.ensure_master: master.fps anchor for audio MR is nil "
            .. "(has_video=%s, video_tc=%s, audio_tc=%s, media_id=%s)",
            tostring(dims.has_video), tostring(dims.video_tc),
            tostring(dims.audio_tc), tostring(media_id)))
        local seq_dur = dims.duration_frames
        assert(type(seq_dur) == "number" and seq_dur > 0, string.format(
            "Sequence.ensure_master: duration_frames must be positive integer, "
            .. "got %s (media_id=%s)", tostring(seq_dur), tostring(media_id)))
        for ch = 1, dims.media.audio_channels do
            local atrack = Track.create_audio(
                string.format("Audio %d", ch), seq.id, {
                    id    = replay_audio_track_ids[ch],
                    index = ch,
                })
            assert(atrack:save(), "Sequence.ensure_master: failed to save audio track")
            MediaRef.create({
                id                   = replay_audio_media_ref_ids[ch],
                project_id           = project_id,
                owner_sequence_id    = seq.id,
                track_id             = atrack.id,
                media_id             = media_id,
                source_in_frame      = dims.audio_tc,
                source_out_frame     = dims.audio_tc + dims.duration_samples,
                sequence_start_frame = seq_start,
                duration_frames      = seq_dur,
                -- 018 V11 / FR-004: AUDIO media_refs carry their own
                -- audio_sample_rate (denormalized from media so the
                -- resolver hot path doesn't join through media at decode).
                audio_sample_rate    = dims.sample_rate,
                enabled              = true,
                volume               = 1.0,
                playhead_frame       = 0,
                created_at           = now,
                modified_at          = now,
            })
        end
    end

    local dims = load_media_dims()
    local seq  = create_master_row(dims)
    local now  = os.time()
    add_video_stream(seq, dims, now)
    add_audio_streams(seq, dims, now)

    if opts.bin_id then
        local tag_service = require("core.tag_service")
        tag_service.add_to_bin(project_id, { seq.id }, opts.bin_id, "master_clip")
    end

    return seq.id
end

--- Find the master sequence (kind='master') whose tracks include a
--- media_ref pointing at the given media_id. Returns the sequence id, or
--- nil if no master references this media yet.
function Sequence.find_master_for_media(media_id)
    assert(media_id and media_id ~= "",
        "Sequence.find_master_for_media: media_id is required")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT s.id FROM sequences s
        JOIN media_refs mr ON mr.owner_sequence_id = s.id
        WHERE s.kind = 'master' AND mr.media_id = ?
        ORDER BY s.created_at ASC, s.id ASC
        LIMIT 1
    ]])
    assert(stmt, "Sequence.find_master_for_media: prepare failed")
    stmt:bind_value(1, media_id)
    assert(stmt:exec(), "Sequence.find_master_for_media: exec failed")
    local id
    if stmt:next() then id = stmt:value(0) end
    stmt:finalize()
    return id
end

--- For each media_id in `media_ids`, find masters whose video master_clip
--- track has a media_ref pointing at this media, and return the master id,
--- the master's current start_timecode_frame, and the media_ref's current
--- sequence_start_frame (= file's TC origin in master timebase). Used by
--- RelinkClips Phase 2d to sync masters whose source media TC shifted on
--- relink. Returns a list of rows; ordering is not significant.
function Sequence.find_masters_for_media_tc_sync(media_ids)
    assert(type(media_ids) == "table",
        "Sequence.find_masters_for_media_tc_sync: media_ids must be a table")
    local conn = resolve_db()
    -- Master sequence's video track is identified by
    -- default_video_layer_track_id (clips.master_layer_track_id is a
    -- per-clip override). We only want the VIDEO master_ref (so the
    -- master's TC origin matches the video timebase), so the join
    -- constrains the media_ref's track to that one.
    local stmt = conn:prepare([[
        SELECT s.id, s.start_timecode_frame, s.playhead_frame,
               mr.sequence_start_frame
          FROM media_refs mr
          JOIN sequences s ON s.id = mr.owner_sequence_id
         WHERE mr.media_id = ?
           AND s.kind = 'master'
           AND s.default_video_layer_track_id = mr.track_id
    ]])
    assert(stmt, "Sequence.find_masters_for_media_tc_sync: prepare failed")
    local rows = {}
    for mid in pairs(media_ids) do
        stmt:bind_value(1, mid)
        assert(stmt:exec(),
            "Sequence.find_masters_for_media_tc_sync: exec failed")
        while stmt:next() do
            rows[#rows + 1] = {
                sequence_id              = stmt:value(0),
                old_start_timecode_frame = stmt:value(1),
                old_playhead_frame       = stmt:value(2),
                new_sequence_start_frame = stmt:value(3),
                media_id                 = mid,
            }
        end
        stmt:reset()
    end
    stmt:finalize()
    return rows
end

--- Update sequences.start_timecode_frame for a batch of masters. When the
--- master's playhead_frame matches its old start_timecode_frame (no user
--- jog yet), the playhead is rebased to the new origin too — otherwise
--- the playhead would suddenly land before the content range begins.
--- Caller captures the pre-update rows from find_masters_for_media_tc_sync
--- for undo restoration.
function Sequence.batch_set_master_start_tc(rows)
    assert(type(rows) == "table",
        "Sequence.batch_set_master_start_tc: rows must be a table")
    if #rows == 0 then return end
    local conn = resolve_db()
    local upd_with_ph = assert(conn:prepare(
        "UPDATE sequences SET start_timecode_frame = ?, playhead_frame = ? WHERE id = ?"),
        "Sequence.batch_set_master_start_tc: prepare upd_with_ph failed")
    local upd_no_ph = assert(conn:prepare(
        "UPDATE sequences SET start_timecode_frame = ? WHERE id = ?"),
        "Sequence.batch_set_master_start_tc: prepare upd_no_ph failed")
    for _, r in ipairs(rows) do
        if r.old_playhead_frame == r.old_start_timecode_frame then
            upd_with_ph:bind_value(1, r.new_sequence_start_frame)
            upd_with_ph:bind_value(2, r.new_sequence_start_frame)
            upd_with_ph:bind_value(3, r.sequence_id)
            assert(upd_with_ph:exec(),
                "Sequence.batch_set_master_start_tc: exec upd_with_ph failed")
            upd_with_ph:reset()
        else
            upd_no_ph:bind_value(1, r.new_sequence_start_frame)
            upd_no_ph:bind_value(2, r.sequence_id)
            assert(upd_no_ph:exec(),
                "Sequence.batch_set_master_start_tc: exec upd_no_ph failed")
            upd_no_ph:reset()
        end
    end
    upd_with_ph:finalize()
    upd_no_ph:finalize()
end

--- Undo helper: restore each master's pre-relink start_timecode_frame +
--- playhead_frame from the snapshot rows captured before
--- batch_set_master_start_tc. Mirror of the forward update.
function Sequence.batch_restore_master_start_tc(rows)
    assert(type(rows) == "table",
        "Sequence.batch_restore_master_start_tc: rows must be a table")
    if #rows == 0 then return end
    local conn = resolve_db()
    local stmt = assert(conn:prepare(
        "UPDATE sequences SET start_timecode_frame = ?, playhead_frame = ? WHERE id = ?"),
        "Sequence.batch_restore_master_start_tc: prepare failed")
    for _, r in ipairs(rows) do
        stmt:bind_value(1, r.old_start_timecode_frame)
        stmt:bind_value(2, r.old_playhead_frame)
        stmt:bind_value(3, r.sequence_id)
        assert(stmt:exec(),
            "Sequence.batch_restore_master_start_tc: exec failed")
        stmt:reset()
    end
    stmt:finalize()
end

--- Return the first media_ref for this master sequence's bound media.
--- Used by clipboard_actions.copy_browser_selection to materialise a
--- DuplicateMasterClip snapshot from a project-browser entry.
--- @param sequence_id string master sequence id
--- @return string|nil media_id, integer|nil source_out_frame
function Sequence.get_first_media_ref(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "Sequence.get_first_media_ref: sequence_id is required")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT media_id, source_out_frame
          FROM media_refs WHERE owner_sequence_id = ? LIMIT 1
    ]])
    assert(stmt, "Sequence.get_first_media_ref: prepare failed")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Sequence.get_first_media_ref: exec failed")
    local mid, sout
    if stmt:next() then mid = stmt:value(0); sout = stmt:value(1) end
    stmt:finalize()
    return mid, sout
end

-- Sequence.ensure_masterclip / find_masterclip_for_media / _find_masterclip_for_media
-- were V8-only paths that wrote sequences.kind='masterclip' (banned under V13)
-- and clips with clip_kind='master'/media_id (columns dropped). Replaced by
-- Sequence.ensure_master + Sequence.find_master_for_media above. FR-018: no
-- back-compat — old callers must migrate, no shim.

-- =============================================================================
-- MASTER SEQUENCE METHODS (for kind="master")
-- =============================================================================

--- Whether this sequence is a master (V13 kind='master'). The `kind`
--- value narrowed from {timeline,masterclip,compound,multicam} to
--- {master,nested} in V13; this checks the new value.
function Sequence:is_master()
    return self.kind == "master"
end

--- V13: enumerate the media_refs inside a kind='master' sequence as
-- "stream clips" for legacy callers. Each returned record is shaped to
-- match the V8 clip-stream contract that callers depend on:
--   .id, .track_id, .sequence_start, .duration,
--   .source_in, .source_out, .media_id,
--   .frame_rate = {fps_numerator, fps_denominator} for video streams,
--   .sample_rate = N (Hz, integer) for audio streams.
-- Source-unit semantics: video source coords are frames at frame_rate;
-- audio source coords are samples at sample_rate.
-- @return table {video_clips = {...}, audio_clips = {...}}
-- Common row-shape for one media_ref reshaped into a "stream clip". Video
-- clips carry frame_rate (sequence-level); audio clips carry sample_rate
-- (per-media_ref, non-NULL on every audio media_ref — masters have no
-- aggregate audio_sample_rate per FR-004).
local function load_master_video_streams(conn, track_id, video_frame_rate)
    local out = {}
    local stmt = conn:prepare([[
        SELECT id, track_id, media_id, source_in_frame, source_out_frame,
               sequence_start_frame, duration_frames,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame
        FROM media_refs WHERE track_id = ?
        ORDER BY sequence_start_frame ASC
    ]])
    assert(stmt, "ensure_stream_clips: video media_refs prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "ensure_stream_clips: video media_refs exec failed")
    while stmt:next() do
        out[#out + 1] = {
            id             = stmt:value(0),
            track_id       = stmt:value(1),
            media_id       = stmt:value(2),
            source_in      = stmt:value(3),
            source_out     = stmt:value(4),
            sequence_start = stmt:value(5),
            duration       = stmt:value(6),
            enabled        = stmt:value(7) == 1,
            volume         = stmt:value(8),
            mark_in        = stmt:value(9),
            mark_out       = stmt:value(10),
            playhead_frame = stmt:value(11),
            frame_rate     = video_frame_rate,
        }
    end
    stmt:finalize()
    return out
end

local function load_master_audio_streams(conn, track_id, master_seq_id)
    local out = {}
    -- 018 (FR-004): every AUDIO media_ref carries mr.audio_sample_rate at
    -- insert (denormalized from media). The per-master single-rate
    -- assumption is gone (FR-034).
    local stmt = conn:prepare([[
        SELECT id, track_id, media_id, source_in_frame, source_out_frame,
               sequence_start_frame, duration_frames,
               enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
               audio_sample_rate
        FROM media_refs WHERE track_id = ?
        ORDER BY sequence_start_frame ASC
    ]])
    assert(stmt, "ensure_stream_clips: audio media_refs prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "ensure_stream_clips: audio media_refs exec failed")
    while stmt:next() do
        local rate = stmt:value(12)
        assert(rate and rate > 0, string.format(
            "ensure_stream_clips (INV-8): audio media_ref %s on master %s "
            .. "missing audio_sample_rate",
            tostring(stmt:value(0)), tostring(master_seq_id)))
        out[#out + 1] = {
            id             = stmt:value(0),
            track_id       = stmt:value(1),
            media_id       = stmt:value(2),
            source_in      = stmt:value(3),
            source_out     = stmt:value(4),
            sequence_start = stmt:value(5),
            duration       = stmt:value(6),
            enabled        = stmt:value(7) == 1,
            volume         = stmt:value(8),
            mark_in        = stmt:value(9),
            mark_out       = stmt:value(10),
            playhead_frame = stmt:value(11),
            sample_rate    = rate,
        }
    end
    stmt:finalize()
    return out
end

local function ensure_stream_clips(self)
    assert(self.kind == "master", string.format(
        "Sequence.ensure_stream_clips: sequence %s is not a master (kind=%s)",
        tostring(self.id), tostring(self.kind)))

    if self._cached_stream_clips then
        return self._cached_stream_clips
    end

    -- Master sequences are constructed with NOT NULL fps by
    -- Sequence.ensure_master. Master.audio_sample_rate is NULL per FR-004 —
    -- per-rate is per-media_ref now. Assert frame_rate before any
    -- DB work so a malformed master row fails loud at the source.
    local video_frame_rate = self.frame_rate
    assert(video_frame_rate
        and video_frame_rate.fps_numerator
        and video_frame_rate.fps_denominator,
        string.format("ensure_stream_clips: master sequence %s missing frame_rate",
            tostring(self.id)))

    local Track = require("models.track")
    local conn = resolve_db()
    local video_tracks = Track.find_by_sequence(self.id, "VIDEO")
    local audio_tracks = Track.find_by_sequence(self.id, "AUDIO")

    local video_clips, audio_clips = {}, {}
    for _, t in ipairs(video_tracks) do
        for _, r in ipairs(load_master_video_streams(conn, t.id, video_frame_rate)) do
            video_clips[#video_clips + 1] = r
        end
    end
    for _, t in ipairs(audio_tracks) do
        for _, r in ipairs(load_master_audio_streams(conn, t.id, self.id)) do
            audio_clips[#audio_clips + 1] = r
        end
    end

    local result = { video_clips = video_clips, audio_clips = audio_clips }
    self._cached_stream_clips = result
    return result
end

--- Get the video stream from this master sequence (a media_ref reshaped
--- as a "clip" for callers that haven't been moved off the V8 stream-clip
--- shape yet). Asserts if called on a non-master sequence.
-- @return table|nil video media_ref reshaped as clip, or nil if none exists
function Sequence:video_stream()
    local streams = ensure_stream_clips(self)
    return streams.video_clips[1]
end

--- Get all audio streams from this master sequence (media_refs reshaped as
--- clips). Asserts if called on a non-master sequence.
-- @return table Array of audio media_ref-shaped clips (may be empty)
function Sequence:audio_streams()
    local streams = ensure_stream_clips(self)
    return streams.audio_clips
end

--- Get the number of audio streams
-- @return number Count of audio streams
function Sequence:num_audio_streams()
    return #self:audio_streams()
end

--- Invalidate the cached stream clips (call after modifying stream clips)
function Sequence:invalidate_stream_cache()
    self._cached_stream_clips = nil
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
-- resolve_master_leaf via subframe_math (FR-008).

-- =============================================================================
-- PLAYHEAD RESOLUTION (used by Renderer and Mixer)
-- =============================================================================

--- Internal: Calculate source frame and time for a clip at a given playhead.
-- "Frames are frames": source_frame = source_in + timeline_offset (1:1 mapping).
-- A 24fps clip on a 30fps timeline plays each source frame at 1/30s — the clip
-- runs faster. No rate conversion here; the speed conform is intended behavior.
-- @param clip Clip object (sequence_start, source_in, rate)
-- @param playhead_frame integer playhead position in timeline frames
-- @return source_time_us (integer microseconds), source_frame (integer)
local function calc_source_time_us(clip, playhead_frame)
    assert(type(playhead_frame) == "number", "Sequence: playhead must be integer")
    assert(type(clip.sequence_start) == "number", "Sequence: sequence_start must be integer")
    assert(type(clip.source_in) == "number", "Sequence: source_in must be integer")

    local offset_frames = playhead_frame - clip.sequence_start
    local source_frame = clip.source_in + offset_frames

    local clip_rate = clip.frame_rate
    assert(clip_rate and clip_rate.fps_numerator and clip_rate.fps_denominator,
        string.format("Sequence: clip %s has no frame_rate", clip.id))

    -- Convert to microseconds: frame * 1000000 * fps_den / fps_num
    local source_time_us = math.floor(
        source_frame * 1000000 * clip_rate.fps_denominator / clip_rate.fps_numerator
    )
    return source_time_us, source_frame
end

-- Master-side get_video_at / get_audio_at helper.
-- V13 master sequences hold media_refs on their tracks; render the
-- media_ref at the requested playhead and shape the result like the
-- nested-sequence path so callers don't need to branch.
local function resolve_master_at(self, tracks, playhead_frame, track_kind)
    local Media = require("models.media")
    local conn = resolve_db()
    local results = {}
    for _, track in ipairs(tracks) do
        local stmt = assert(conn:prepare([[
            SELECT id, media_id, source_in_frame, source_out_frame,
                   sequence_start_frame, duration_frames, enabled, volume
              FROM media_refs WHERE track_id = ? LIMIT 1
        ]]), "Sequence:resolve_master_at: prepare failed")
        stmt:bind_value(1, track.id)
        local row
        if stmt:exec() and stmt:next() then
            row = {
                id             = stmt:value(0),
                media_id       = stmt:value(1),
                source_in      = stmt:value(2),
                source_out     = stmt:value(3),
                sequence_start = stmt:value(4),
                duration       = stmt:value(5),
                enabled        = stmt:value(6) == 1,
                volume         = stmt:value(7),
            }
        end
        stmt:finalize()
        if row then
            local mr_end = row.sequence_start + row.duration
            if playhead_frame >= row.sequence_start and playhead_frame < mr_end then
                local media = Media.load(row.media_id)
                assert(media, string.format(
                    "Sequence:resolve_master_at: media %s not found", tostring(row.media_id)))

                -- Audio MR placement is in master.fps frames (post unify),
                -- but source_in / source_out are file-natural samples. The
                -- "frames are frames" 1:1 helper (calc_source_time_us)
                -- doesn't apply across that unit gap — convert the
                -- master.fps offset to samples for audio rows before
                -- adding to the sample-unit source_in, then express the
                -- file position in microseconds via the audio sample
                -- rate. Video rows still hit the like-unit helper.
                local source_time_us, source_frame
                if track_kind == "AUDIO" then
                    local sr = media.audio_sample_rate
                    assert(type(sr) == "number" and sr > 0, string.format(
                        "Sequence:resolve_master_at: media %s has invalid "
                        .. "audio_sample_rate=%s for AUDIO track",
                        tostring(row.media_id), tostring(sr)))
                    local fps_num = self.frame_rate.fps_numerator
                    local fps_den = self.frame_rate.fps_denominator
                    assert(type(fps_num) == "number" and fps_num > 0
                        and type(fps_den) == "number" and fps_den > 0,
                        string.format("Sequence:resolve_master_at: master %s "
                            .. "has invalid frame_rate %s/%s",
                            tostring(self.id), tostring(fps_num), tostring(fps_den)))
                    local offset_frames = playhead_frame - row.sequence_start
                    local offset_samples = math.floor(
                        offset_frames * sr * fps_den / fps_num + 0.5)
                    source_frame = row.source_in + offset_samples
                    source_time_us = math.floor(source_frame * 1000000 / sr)
                else
                    local mr_for_calc = {
                        sequence_start = row.sequence_start,
                        source_in      = row.source_in,
                        frame_rate     = self.frame_rate,
                        id             = row.id,
                    }
                    source_time_us, source_frame = calc_source_time_us(
                        mr_for_calc, playhead_frame)
                end

                local mr = {
                    id                = row.id,
                    track_id          = track.id,
                    sequence_id       = self.id,
                    sequence_start    = row.sequence_start,
                    duration          = row.duration,
                    source_in         = row.source_in,
                    source_out        = row.source_out,
                    enabled           = row.enabled,
                    volume            = row.volume,
                    frame_rate        = self.frame_rate,
                    track_type        = track_kind,
                }
                results[#results + 1] = {
                    media_path     = media.file_path,
                    source_time_us = source_time_us,
                    source_frame   = source_frame,
                    clip           = mr,
                    track          = track,
                }
            end
        end
    end
    return results
end

--- Get ALL video clips at position, ordered by track_index ascending.
-- Returns one entry per video track that has a clip at playhead.
-- Renderer iterates highest-index-first for display. Future: composite all layers.
-- @param playhead_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track} (may be empty = gap)
function Sequence:get_video_at(playhead_frame)
    assert(type(playhead_frame) == "number",
        "Sequence:get_video_at: playhead_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then
        return {}
    end

    -- V13 master sequences hold media_refs (not clips) on their tracks.
    -- Read the media_ref + its media row to materialise the same shape
    -- callers expect from a nested-sequence get_video_at result.
    if self.kind == "master" then
        return resolve_master_at(self, tracks, playhead_frame, "VIDEO")
    end

    local results = {}
    -- Tracks are sorted by track_index ASC (V1=1, V2=2, ...; highest = topmost)
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_video_at: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end

    return results
end

--- Get all audio clips at position (works for any sequence kind).
-- @param playhead_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_audio_at(playhead_frame)
    assert(type(playhead_frame) == "number",
        "Sequence:get_audio_at: playhead_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then
        return {}
    end

    if self.kind == "master" then
        return resolve_master_at(self, tracks, playhead_frame, "AUDIO")
    end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_audio_at: audio clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))

            local source_time_us, source_frame = calc_source_time_us(clip, playhead_frame)

            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                -- Media's video fps for "frames are frames" audio conform.
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end

    return results
end

--- Get next video clips (one per track) starting at or after a boundary frame.
-- Used by engine lookahead for pre-buffering. Entry format matches get_video_at.
-- @param after_frame integer: boundary frame (inclusive)
-- @return list of {media_path, source_time_us, source_frame, clip, track}
function Sequence:get_next_video(after_frame)
    assert(type(after_frame) == "number",
        "Sequence:get_next_video: after_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_next_on_track(track.id, after_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_next_video: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            -- source_frame at clip start = source_in
            local source_time_us, source_frame = calc_source_time_us(clip, clip.sequence_start)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end
    return results
end

--- Get previous video clips (one per track) ending at or before a boundary frame.
-- @param before_frame integer: boundary frame (inclusive upper bound for clip end)
-- @return list of {media_path, source_time_us, source_frame, clip, track}
function Sequence:get_prev_video(before_frame)
    assert(type(before_frame) == "number",
        "Sequence:get_prev_video: before_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "VIDEO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_prev_on_track(track.id, before_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_prev_video: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            -- Source position at clip END (last frame): reverse playback enters here
            local last_frame = clip.sequence_start + clip.duration - 1
            local source_time_us, source_frame = calc_source_time_us(clip, last_frame)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
            }
        end
    end
    return results
end

--- Get next audio clips (one per track) starting at or after a boundary frame.
-- @param after_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_next_audio(after_frame)
    assert(type(after_frame) == "number",
        "Sequence:get_next_audio: after_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_next_on_track(track.id, after_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_next_audio: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            local source_time_us, source_frame = calc_source_time_us(clip, clip.sequence_start)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end
    return results
end

--- Get previous audio clips (one per track) ending at or before a boundary frame.
-- @param before_frame integer
-- @return list of {media_path, source_time_us, source_frame, clip, track, media_fps_num, media_fps_den}
function Sequence:get_prev_audio(before_frame)
    assert(type(before_frame) == "number",
        "Sequence:get_prev_audio: before_frame must be integer")

    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local tracks = Track.find_by_sequence(self.id, "AUDIO")
    if not tracks or #tracks == 0 then return {} end

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_prev_on_track(track.id, before_frame)
        if clip then
            local media = Media.load(clip.resolved_media and clip.resolved_media.id)
            assert(media, string.format(
                "Sequence:get_prev_audio: clip %s references missing media %s",
                clip.id, tostring(clip.resolved_media and clip.resolved_media.id)))
            -- Source position at clip END (last frame): reverse playback enters here
            local last_frame = clip.sequence_start + clip.duration - 1
            local source_time_us, source_frame = calc_source_time_us(clip, last_frame)
            results[#results + 1] = {
                media_path = media.file_path,
                source_time_us = source_time_us,
                source_frame = source_frame,
                clip = clip,
                track = track,
                media_fps_num = media.frame_rate.fps_numerator,
                media_fps_den = media.frame_rate.fps_denominator,
            }
        end
    end
    return results
end

-- Public-boundary wrappers over the resolver. Returned entry is flat:
-- consumers (playback_engine, render preview, integration tests) read
-- fields directly off the entry — no entry.clip / entry.track / .media_fps_*
-- nesting. Each entry describes the OUTERMOST owner's full owner-coord
-- extent (sequence_start, duration), media-file source range (source_in,
-- source_out), and routing (track_index, track_type). The leaf media's
-- native rate rides along as fps_numerator / fps_denominator so consumers
-- can compute speed ratios without re-loading the Media row.

-- Promote a resolver internal entry to the public flat shape. Tags
-- already on the entry from resolve_nested / resolve_master_leaf:
-- owner_clip_id, owner_track_index, owner_track_type. Outer-coord
-- sequence_start / duration are already set to the outermost extent
-- because resolve_nested recurses with each clip's full source window
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
-- non-overlapping outer clips — pass it through unchanged. resolve_nested
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
    local entries = Sequence:resolve_in_range(self.id, lo, hi, {})
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
    local entries = Sequence:resolve_in_range(self.id, lo, hi, {})
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
-- Feature 013: resolve_in_range — the single Lua-side resolver
-- ===========================================================================
-- Walks the clip → nested sequence → (recurse) → media_ref → media chain for
-- a given sequence and time range. Single code path for playback + export
-- (FR-019). Dispatches on sequences.kind: 'master' iterates media_refs,
-- 'sequence' iterates clips + recurses.
--
-- Rule 2.5: top-level reads as a high-level algorithm; each piece of intent
-- is a named helper.
--
-- Coordinate spaces (read carefully — every bug in the prior implementation
-- was a unit confusion):
--   * media_refs.source_in_frame / source_out_frame  — file-native units
--     (video frames at the file's fps, or audio samples at its rate).
--   * media_refs.sequence_start_frame                 — master-timebase units.
--   * clips.source_in_frame / source_out_frame        — nested-sequence units
--     (i.e. nested.fps frames, sample units for an audio clip).
--   * clips.sequence_start_frame / duration_frames    — owner-sequence units.
--   * The fps_mismatch_policy was applied at Insert/Set time, so the ratio
--     between owner-units and source-units is exactly
--       owner_per_source = c.duration_frames / (c.source_out - c.source_in)
--     for every clip — `resample` and `passthrough` differ only in what was
--     written to c.duration_frames at Insert.
--
-- First-landing assumption: `master.fps == media.fps` for each media_ref
-- (multi-fps masters defer to a later feature). With this assumption the
-- master-timebase units coincide with file-native units 1:1, and a media_ref
-- placed at master_lo plays file frames [mr.source_in + (mr_lo - mr.sequence_start),
-- mr.source_in + (mr_hi - mr.sequence_start)).

-- Fetch a sequence's kind. Asserts it exists.
local function fetch_kind(db, seq_id)
    local stmt = db:prepare("SELECT kind FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.resolve: kind prepare failed")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec(), "Sequence.resolve: kind exec failed")
    assert(stmt:next(), string.format(
        "Sequence.resolve: sequence %s not found", tostring(seq_id)))
    local kind = stmt:value(0)
    stmt:finalize()
    return kind
end

-- Fetch a sequence's default_video_layer_track_id (may be nil).
local function fetch_default_video_layer(db, seq_id)
    local stmt = db:prepare(
        "SELECT default_video_layer_track_id FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.resolve: default-layer prepare failed")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec(), "Sequence.resolve: default-layer exec failed")
    local v
    if stmt:next() then v = stmt:value(0) end
    stmt:finalize()
    return v
end

-- Assert a track_id exists on the given sequence. Loud message with clip_id
-- and the dangling track (G-R5). Returns the track_type.
-- Validate a clip's track-selector reference. `selector_label` is
-- "master_layer_track_id" or "master_audio_track_id" — the column name
-- whose value is being asserted. Both selectors share the same shape
-- (FK to tracks(id) with ON DELETE SET NULL); the only difference is
-- the assert-message label per rule 1.14.
local function assert_track_ref_valid(db, clip_id, seq_id, track_id,
                                       selector_label)
    if track_id == nil then return nil end
    local stmt = db:prepare(
        "SELECT track_type, sequence_id FROM tracks WHERE id = ?")
    assert(stmt, "Sequence.resolve: track-ref prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "Sequence.resolve: track-ref exec failed")
    local found, ttype, tseq
    if stmt:next() then
        found = true
        ttype = stmt:value(0)
        tseq = stmt:value(1)
    end
    stmt:finalize()
    assert(found, string.format(
        "Sequence.resolve G-R5: clip %s has %s=%s that does not exist "
        .. "(dangling — FK ON DELETE SET NULL should have NULLed this; "
        .. "DB corruption?)",
        tostring(clip_id), selector_label, tostring(track_id)))
    assert(tseq == seq_id, string.format(
        "Sequence.resolve G-R5: clip %s %s=%s belongs to sequence %s, "
        .. "not the referenced sequence %s",
        tostring(clip_id), selector_label, tostring(track_id),
        tostring(tseq), tostring(seq_id)))
    return ttype
end


-- Fetch the effective channel state for a master's channel. Absent row →
-- resolver default (enabled=true, gain=0). Returns {enabled, gain_db}.
local function fetch_master_channel_state(db, master_seq_id, channel_index)
    local stmt = db:prepare([[
        SELECT enabled, default_gain_db FROM media_refs_channel_state
        WHERE owner_sequence_id = ? AND channel_index = ?
    ]])
    assert(stmt, "Sequence.resolve: master-chan-state prepare failed")
    stmt:bind_value(1, master_seq_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "Sequence.resolve: master-chan-state exec failed")
    local enabled, gain_db = true, 0.0  -- resolver default
    if stmt:next() then
        enabled = stmt:value(0) == 1
        gain_db = stmt:value(1)
    end
    stmt:finalize()
    return enabled, gain_db
end

-- Fetch per-clip channel override if present. Returns (found, enabled, gain_db).
local function fetch_clip_channel_override(db, clip_id, channel_index)
    local stmt = db:prepare([[
        SELECT enabled, gain_db FROM clip_channel_override
        WHERE clip_id = ? AND channel_index = ?
    ]])
    assert(stmt, "Sequence.resolve: clip-override prepare failed")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "Sequence.resolve: clip-override exec failed")
    local found, enabled, gain_db
    if stmt:next() then
        found = true
        enabled = stmt:value(0) == 1
        gain_db = stmt:value(1)
    end
    stmt:finalize()
    return found, enabled, gain_db
end

-- Multiply dB gains into a linear volume multiplier.
local function db_to_linear(db_gain)
    if db_gain == 0 then return 1.0 end
    return 10 ^ (db_gain / 20)
end

-- Enumerate media_refs on a master sequence, optionally filtered to a single
-- track. Each row comes back as a table.
local function list_media_refs(db, master_seq_id, only_track_id)
    -- 018 V11 / FR-004: mr.audio_sample_rate is denormalized from
    -- media.audio_sample_rate at media_ref insert. AUDIO media_refs must
    -- carry a non-NULL value (enforced at MediaRef.create — rule 2.13, no
    -- silent default). The resolver consumes it to compute file-natural
    -- sample offsets for audio entries — without it the clip-to-media-ref
    -- seam can't bridge from master.fps frames to file samples.
    local sql = [[
        SELECT mr.id, mr.track_id, mr.media_id, mr.source_in_frame, mr.source_out_frame,
               mr.sequence_start_frame, mr.duration_frames,
               mr.enabled, mr.volume,
               t.track_type, t.track_index,
               m.file_path, m.audio_channels,
               mr.audio_sample_rate
        FROM media_refs mr
        JOIN tracks t ON mr.track_id = t.id
        JOIN media m ON mr.media_id = m.id
        WHERE mr.owner_sequence_id = ?
    ]]
    if only_track_id then sql = sql .. " AND mr.track_id = ?" end
    sql = sql .. " ORDER BY t.track_type DESC, t.track_index ASC, mr.sequence_start_frame ASC"
    local stmt = db:prepare(sql)
    assert(stmt, "Sequence.resolve: list_media_refs prepare failed")
    stmt:bind_value(1, master_seq_id)
    if only_track_id then stmt:bind_value(2, only_track_id) end
    assert(stmt:exec(), "Sequence.resolve: list_media_refs exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            media_id = stmt:value(2),
            source_in = stmt:value(3),
            source_out = stmt:value(4),
            sequence_start = stmt:value(5),
            duration = stmt:value(6),
            enabled = stmt:value(7) == 1,
            volume = stmt:value(8),
            track_type = stmt:value(9),
            track_index = stmt:value(10),
            file_path = stmt:value(11),
            audio_channels = stmt:value(12) or 0,
            audio_sample_rate = stmt:value(13),
        }
    end
    stmt:finalize()
    return rows
end

-- Enumerate clips on a nested sequence that overlap [start, end) in this
-- sequence's timebase. Sorted by track_type (VIDEO before AUDIO) then track
-- index ascending, then sequence_start ascending — so the output of a sequence
-- with many clips is deterministic (G-R11).
local function list_clips_overlapping(db, seq_id, start_frame, end_frame)
    -- 018: source_in_subframe / source_out_subframe carry the residual
    -- master-clock ticks within the (frame, subframe) source position.
    -- The subframe columns are non-NULL on AUDIO clips, NULL on VIDEO (FR-013). The
    -- recursion seam in resolve_nested threads these into the next-level
    -- resolve_seq_range call so the leaf can compute file-natural samples
    -- without losing sub-frame precision.
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.sequence_id,
               c.sequence_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.source_in_subframe, c.source_out_subframe,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.volume,
               t.track_type, t.track_index
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE c.owner_sequence_id = ?
          AND c.enabled = 1
          AND (c.sequence_start_frame + c.duration_frames) > ?
          AND c.sequence_start_frame < ?
        ORDER BY t.track_type DESC, t.track_index ASC,
                 c.sequence_start_frame ASC, c.id ASC
    ]])
    assert(stmt, "Sequence.resolve: list_clips prepare failed")
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, start_frame)
    stmt:bind_value(3, end_frame)
    assert(stmt:exec(), "Sequence.resolve: list_clips exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            sequence_id = stmt:value(2),
            sequence_start = stmt:value(3),
            duration = stmt:value(4),
            source_in = stmt:value(5),
            source_out = stmt:value(6),
            source_in_subframe = stmt:value(7),
            source_out_subframe = stmt:value(8),
            master_layer_track_id = stmt:value(9),
            master_audio_track_id = stmt:value(10),
            fps_mismatch_policy = stmt:value(11),
            enabled = stmt:value(12) == 1,
            volume = stmt:value(13),
            track_type = stmt:value(14),
            track_index = stmt:value(15),
        }
    end
    stmt:finalize()
    return rows
end

-- Build an ordered provenance array from an outer chain + a leaf id. Pure.
local function build_provenance(outer_chain, leaf_id)
    local p = {}
    for i, v in ipairs(outer_chain) do p[i] = v end
    p[#p + 1] = leaf_id
    return p
end

-- Round-nearest-integer for fractional results from owner/source ratio math.
-- Matches Insert-time rounding (data-model.md "Decisions settled here").
local function round_int(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- 018: read the project's master_clock_hz (FR-028) once per master leaf and
-- cache on the resolver context. Asserts non-NULL; the bg project-open path
-- guarantees the settings JSON carries it (T007).
local function fetch_master_clock_hz(db, project_id, context)
    if context.master_clock_hz then return context.master_clock_hz end
    assert(project_id and project_id ~= "",
        "Sequence.resolve: project_id required to read master_clock_hz")
    local stmt = db:prepare(
        "SELECT json_extract(settings, '$.master_clock_hz') FROM projects WHERE id = ?")
    assert(stmt, "Sequence.resolve: master_clock_hz prepare failed")
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), "Sequence.resolve: master_clock_hz exec failed")
    local mch
    if stmt:next() then mch = stmt:value(0) end
    stmt:finalize()
    assert(mch and mch > 0, string.format(
        "Sequence.resolve: project %s has no master_clock_hz in settings "
        .. "(018 T007 must run at project open)", tostring(project_id)))
    context.master_clock_hz = mch
    return mch
end

-- 018: master sequence's fps. Cached on context per seq_id to avoid repeat
-- SQL inside the per-media_ref loop.
local function fetch_master_fps(db, seq_id, context)
    context.master_fps_cache = context.master_fps_cache or {}
    local cached = context.master_fps_cache[seq_id]
    if cached then return cached.num, cached.den, cached.project_id end
    local stmt = db:prepare(
        "SELECT fps_numerator, fps_denominator, project_id FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.resolve: master fps prepare failed")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec(), "Sequence.resolve: master fps exec failed")
    assert(stmt:next(), string.format(
        "Sequence.resolve: sequence %s not found", tostring(seq_id)))
    local num, den, proj = stmt:value(0), stmt:value(1), stmt:value(2)
    stmt:finalize()
    assert(num and num > 0 and den and den > 0, string.format(
        "Sequence.resolve: sequence %s has invalid fps %s/%s",
        tostring(seq_id), tostring(num), tostring(den)))
    context.master_fps_cache[seq_id] = { num = num, den = den, project_id = proj }
    return num, den, proj
end

-- Total master-clock ticks for a (frame, subframe) pair at a given tpf.
-- Used both for overlap comparison and as the input to ticks_to_samples.
local function pack_pos_ticks(frame, subframe, tpf)
    return frame * tpf + subframe
end

-- Whether the [mr.start, mr.end) frame extent (treated as subframe=0 at both
-- endpoints) overlaps the request's (frame, subframe) range. Comparison is in
-- packed master-clock-tick space so sub-frame range endpoints are honored.
local function mref_overlaps_request(r, lo_f, lo_s, hi_f, hi_s, tpf)
    local r_lo_ticks = pack_pos_ticks(r.sequence_start, 0, tpf)
    local r_hi_ticks = pack_pos_ticks(r.sequence_start + r.duration, 0, tpf)
    local req_lo_ticks = pack_pos_ticks(lo_f, lo_s, tpf)
    local req_hi_ticks = pack_pos_ticks(hi_f, hi_s, tpf)
    return r_hi_ticks > req_lo_ticks and r_lo_ticks < req_hi_ticks
end

-- Apply the layer / audio-track-selector filter at this level (FR-005, FR-023).
-- Returns true if this mr passes; false if a filter excludes it.
local function mref_passes_filter(r, layer_track_id, audio_track_id)
    if r.track_type == "VIDEO" and layer_track_id ~= nil then
        return r.track_id == layer_track_id
    end
    if r.track_type == "AUDIO" and audio_track_id ~= nil then
        return r.track_id == audio_track_id
    end
    return true
end

-- Clip the request range to the media_ref's [start, end) extent. When the
-- mref boundary takes over, the corresponding subframe is 0 (the request
-- entered the mref at a whole-frame boundary on the mref side).
local function clip_to_mref_extent(r, lo_f, lo_s, hi_f, hi_s)
    local r_lo, r_hi = r.sequence_start, r.sequence_start + r.duration
    local out_lo_f, out_lo_s, out_hi_f, out_hi_s
    if lo_f < r_lo then
        out_lo_f, out_lo_s = r_lo, 0
    else
        out_lo_f, out_lo_s = lo_f, lo_s
    end
    if hi_f > r_hi or (hi_f == r_hi and hi_s > 0) then
        out_hi_f, out_hi_s = r_hi, 0
    else
        out_hi_f, out_hi_s = hi_f, hi_s
    end
    return out_lo_f, out_lo_s, out_hi_f, out_hi_s
end

-- Compute the file-natural source position for a VIDEO media_ref. Video files
-- share the master.fps frame timebase for source positions (FR-003) — subframe
-- is irrelevant on video (video is frame-quantized).
local function compute_video_source_range(r, lo_f, hi_f)
    local file_in  = r.source_in + (lo_f - r.sequence_start)
    local file_out = r.source_in + (hi_f - r.sequence_start)
    return file_in, file_out
end

-- Compute the file-natural sample position for an AUDIO media_ref. Per
-- data-model.md "Resolution to file-natural sample":
--     file_sample = mr.source_in (file-natural samples)
--                 + ticks_to_samples(frame_delta * tpf + subframe,
--                                    mr.audio_sample_rate, master_clock_hz)
-- Composes the whole-frame contribution and the sub-frame residual into a
-- single round in the math primitive (FR-008 single-rounding-rule).
local function compute_audio_source_sample(r, master_frame, master_subframe,
                                            tpf, master_clock_hz)
    local frame_delta = master_frame - r.sequence_start
    assert(frame_delta >= 0, string.format(
        "Sequence.resolve compute_audio_source_sample: frame_delta < 0 "
        .. "(master_frame=%d, mr.sequence_start=%d, mr=%s)",
        master_frame, r.sequence_start, tostring(r.id)))
    assert(r.audio_sample_rate and r.audio_sample_rate > 0, string.format(
        "Sequence.resolve (INV-8): media_ref %s on AUDIO track lacks "
        .. "audio_sample_rate", tostring(r.id)))
    local total_ticks = subframe_math.pack(frame_delta, master_subframe, tpf)
    return r.source_in + subframe_math.ticks_to_samples(
        total_ticks, r.audio_sample_rate, master_clock_hz)
end

-- Build the entry base shared by every emission from one media_ref. The base
-- carries master-coord sequence_start/duration (resolve_nested translates to
-- outer-coord) and file-natural source_in/source_out.
--
-- Pass media_path AND user-set enabled state through unchanged regardless of
-- online/offline. Offline routing is the responsibility of downstream
-- consumers: playback_engine._build_tmb_clip queries media_status.get and
-- sets ClipInfo.offline=true on the TMB clip; timeline_view_renderer +
-- offline_frame_cache key on media_path to render the OFFLINE overlay.
local function build_mref_entry_base(r, lo_f, hi_f, file_in, file_out, outer_chain)
    return {
        media_path     = r.file_path,
        media_id       = r.media_id,
        source_in      = file_in,
        source_out     = file_out,
        sequence_start = lo_f,        -- master coords; outer translates
        duration       = hi_f - lo_f, -- master coords (integer frames)
        volume         = r.volume,
        enabled        = r.enabled,
        effects        = {},
        provenance     = build_provenance(outer_chain, r.id),
        -- Default owner-track tagging for the case where this master is the
        -- outermost sequence (e.g. source viewer playing the master directly).
        -- resolve_nested overwrites these when recursion bubbles outwards.
        owner_track_index = r.track_index,
        owner_track_type  = r.track_type,
        owner_clip_id     = r.id,
    }
end

local function emit_video_entry(entries, r, base)
    base.media_kind    = "video"
    base.track_role    = "video"
    base.channel_index = nil
    entries[#entries + 1] = base
end

-- One audio entry per channel. Channel-state stays separate from volume
-- until the final composition pass — any clip in the chain may replace it
-- via clip_channel_override without needing to divide out a stale factor.
local function emit_audio_channel_entries(entries, r, base, db, master_seq_id, outer_chain)
    -- Resolver invariant: AUDIO mrefs MUST carry audio_sample_rate (FR-004 /
    -- schema trigger). Surface at the resolver — downstream consumers (TMB
    -- feeder, audio_playback) need it and shouldn't have to re-assert.
    assert(type(r.audio_sample_rate) == "number" and r.audio_sample_rate > 0,
        string.format("emit_audio_channel_entries: mref %s missing audio_sample_rate "
            .. "(track=%s; AUDIO media_refs require it per FR-004)",
            tostring(r.id), tostring(r.track_id)))
    -- Audio media_refs MUST carry channel count (FR-004 / schema trigger).
    -- A 0 / nil here means the importer didn't populate it — fail loud.
    assert(type(r.audio_channels) == "number" and r.audio_channels > 0,
        string.format("emit_audio_channel_entries: mref %s has audio_channels=%s "
            .. "(track=%s; AUDIO media_refs require a positive channel count per FR-004)",
            tostring(r.id), tostring(r.audio_channels), tostring(r.track_id)))
    local n_ch = r.audio_channels
    for ch = 0, n_ch - 1 do
        local ms_enabled, ms_gain_db =
            fetch_master_channel_state(db, master_seq_id, ch)
        entries[#entries + 1] = {
            media_path     = base.media_path,
            media_id       = base.media_id,
            media_kind     = "audio",
            source_in      = base.source_in,
            source_out     = base.source_out,
            sequence_start = base.sequence_start,
            duration       = base.duration,
            track_role     = "audio",
            channel_index  = ch,
            volume         = base.volume,
            enabled        = base.enabled,
            effects        = {},
            provenance     = build_provenance(outer_chain, r.id),
            owner_track_index = r.track_index,
            owner_track_type  = r.track_type,
            owner_clip_id     = r.id,
            channel_state  = { enabled = ms_enabled, gain_db = ms_gain_db },
            -- 018 FR-004 / FR-008: AUDIO entries carry the mref's denormalized
            -- audio_sample_rate so the playback engine's TMB feeder can match
            -- it against source_in (file-natural samples). Without this the
            -- decoder seeks using video fps and lands far past EOF — F10 silent.
            audio_sample_rate = r.audio_sample_rate,
        }
    end
end

-- Resolve a master sequence over a request range expressed as (frame, subframe)
-- endpoints in the master's own fps timebase + project master-clock ticks.
-- Iterate media_refs that overlap; emit one ResolvedEntry per row (V) or per
-- channel (A). Video entries' file-source range stays in master.fps frames
-- (FR-003); audio entries are sample-precise via subframe_math (FR-008).
--
-- Track selectors (symmetric per FR-005 / FR-023):
--   layer_track_id    — non-nil restricts V media_refs to that track.
--   audio_track_id    — non-nil restricts A media_refs to that track
--                       (Expand/Collapse audio path). nil = composite.
local function resolve_master_leaf(db, seq_id, lo_f, lo_s, hi_f, hi_s,
                                   layer_track_id, audio_track_id,
                                   outer_chain, context)
    assert(type(context) == "table",
        "Sequence.resolve_master_leaf: context table required (018 master_clock_hz)")
    local fps_num, fps_den, project_id = fetch_master_fps(db, seq_id, context)
    local master_clock_hz = fetch_master_clock_hz(db, project_id, context)
    local tpf = subframe_math.ticks_per_frame(master_clock_hz, fps_num, fps_den)

    local entries = {}
    for _, r in ipairs(list_media_refs(db, seq_id, nil)) do
        if mref_passes_filter(r, layer_track_id, audio_track_id)
           and mref_overlaps_request(r, lo_f, lo_s, hi_f, hi_s, tpf) then
            local m_lo_f, m_lo_s, m_hi_f, m_hi_s =
                clip_to_mref_extent(r, lo_f, lo_s, hi_f, hi_s)
            local file_in, file_out
            if r.track_type == "VIDEO" then
                file_in, file_out = compute_video_source_range(r, m_lo_f, m_hi_f)
            else
                file_in = compute_audio_source_sample(
                    r, m_lo_f, m_lo_s, tpf, master_clock_hz)
                file_out = compute_audio_source_sample(
                    r, m_hi_f, m_hi_s, tpf, master_clock_hz)
            end
            local base = build_mref_entry_base(r, m_lo_f, m_hi_f,
                file_in, file_out, outer_chain)
            if r.track_type == "VIDEO" then
                emit_video_entry(entries, r, base)
            else
                emit_audio_channel_entries(entries, r, base, db, seq_id, outer_chain)
            end
        end
    end
    return entries
end

-- Forward declaration so resolve_nested can call resolve_seq_range recursively.
local resolve_seq_range

-- Translate one in-flight entry's master-coord position to outer-coord using
-- a clip's own source/owner ratio. Mutates in place and returns the entry.
local function translate_to_outer(e, c, source_lo)
    -- Owner-frames-per-source-frame ratio for this clip; defined exactly
    -- by the row regardless of fps_mismatch_policy (the policy was applied
    -- at Insert/Set time when c.duration_frames was written).
    local source_span = c.source_out - c.source_in
    local owner_per_source = c.duration / source_span
    local outer_offset_lo = (e.sequence_start - source_lo) * owner_per_source
    local outer_dur       = e.duration * owner_per_source
    e.sequence_start = c.sequence_start + round_int(outer_offset_lo
        + (source_lo - c.source_in) * owner_per_source)
    e.duration       = round_int(outer_dur)
    return e
end

-- Resolve a nested sequence over an outer-coord range [outer_lo, outer_hi).
-- For each overlapping clip:
--   * compute the master-coord (= nested-coord) sub-range to recurse into;
--   * recurse, applying any layer override at the directly-referenced level;
--   * filter inner entries by the clip's own track type (no double counting);
--   * translate each entry from master-coord positioning to outer-coord;
--   * fold clip.volume into the entry's volume; AND clip.enabled into enabled;
--   * for audio entries, replace channel_state with this clip's override row
--     when present (per-channel — sparse table; absent row = inherit).
local function resolve_nested(db, seq_id, outer_lo_f, outer_lo_s,
                              outer_hi_f, outer_hi_s, context,
                              outer_chain, layer_filter_for_v,
                              audio_filter_for_a)
    local entries = {}
    -- 018: clip overlap is still resolved on integer frame extents (the
    -- query bound). Subframe granularity at the outer endpoints can only
    -- include clips that frame-overlap; sub-frame-only overlap on this
    -- (sequence-of-sequences) layer is impossible because clip endpoints
    -- and the outer query are themselves at frame granularity for
    -- list_clips_overlapping. Subframe enters the math at the master leaf.
    local clips = list_clips_overlapping(db, seq_id, outer_lo_f, outer_hi_f)
    for _, c in ipairs(clips) do
        -- Layer filter at THIS level: filter clips whose track_type is VIDEO
        -- to the chosen V track only. Symmetrically filter AUDIO clips by
        -- the audio-track filter when one is in effect (Expand/Collapse).
        local v_filtered = (c.track_type == "VIDEO")
                       and layer_filter_for_v ~= nil
                       and c.track_id ~= layer_filter_for_v
        local a_filtered = (c.track_type == "AUDIO")
                       and audio_filter_for_a ~= nil
                       and c.track_id ~= audio_filter_for_a
        if not v_filtered and not a_filtered then
            -- G-R5 selector validation: both V layer and A audio track,
            -- if non-NULL, must point at a live track of c.sequence_id.
            if c.master_layer_track_id then
                assert_track_ref_valid(db, c.id, c.sequence_id,
                    c.master_layer_track_id, "master_layer_track_id")
            end
            if c.master_audio_track_id then
                assert_track_ref_valid(db, c.id, c.sequence_id,
                    c.master_audio_track_id, "master_audio_track_id")
            end

            -- channel_index must be < master's audio channel count.
            -- Iterate the clip's overrides (if any) and assert each is in
            -- bounds. For first-landing this checks only when the clip
            -- directly references a master (kind='master') so we have a
            -- concrete channel count; nested-of-nested defers to the
            -- master at its leaf via the recursion's downstream check
            -- on whatever clips the inner sequence holds.
            do
                local kind_stmt = db:prepare(
                    "SELECT kind FROM sequences WHERE id = ?")
                assert(kind_stmt, "Sequence.resolve (channel_index < master audio channel count): kind prepare failed")
                kind_stmt:bind_value(1, c.sequence_id)
                assert(kind_stmt:exec(), "Sequence.resolve (channel_index < master audio channel count): kind exec failed")
                local nk
                if kind_stmt:next() then nk = kind_stmt:value(0) end
                kind_stmt:finalize()
                if nk == "master" then
                    local channel_count = Sequence.count_master_audio_channels(
                        c.sequence_id)
                    local Override = require("models.clip_channel_override")
                    for _, ov in ipairs(Override.find_all(c.id)) do
                        assert(ov.channel_index < channel_count, string.format(
                            "Sequence.resolve INV-5 (channel_index must be < master's audio channel count): clip %s has "
                            .. "clip_channel_override(channel_index=%d) but "
                            .. "the referenced master sequence %s has only "
                            .. "%d audio channel(s). The master likely "
                            .. "shrank since the override was set; clear "
                            .. "or migrate the override.",
                            c.id, ov.channel_index,
                            c.sequence_id, channel_count))
                    end
                end
            end

            -- Layer to expose at the level THIS clip directly references.
            -- NULL → inherit the referenced sequence's default; explicit →
            -- this clip's per-clip override.
            local layer_for_inner = c.master_layer_track_id
            if layer_for_inner == nil then
                layer_for_inner = fetch_default_video_layer(db, c.sequence_id)
            end

            -- Audio-track selector at THIS clip's directly-referenced level.
            -- NULL = composite (today's behavior — no restriction). Non-NULL
            -- = single-track (Expand). There is no sequence-level "default
            -- audio track" symmetric to default_video_layer_track_id;
            -- composite IS the default.
            local audio_for_inner = c.master_audio_track_id

            -- Compute the source-coord (= nested-timebase) sub-range to
            -- recurse into, derived from the outer-coord intersection.
            -- Recurse over the FULL source-window the clip exposes
            -- ([c.source_in, c.source_out)), NOT intersected with the
            -- caller's playback window. The wrapper layer
            -- (get_video_in_range / get_audio_in_range) uses outer_lo /
            -- outer_hi as a clip-overlap filter; once a clip is in scope
            -- it's returned at its full owner-coord extent so consumers
            -- (TMB) get the complete clip and can play through without
            -- a re-fetch every frame. Pre-013 had this contract; the
            -- intersect-with-window form was a 013 regression that made
            -- TMB get 1-frame slices.
            local inner_chain = {}
            for i, v in ipairs(outer_chain) do inner_chain[i] = v end
            inner_chain[#inner_chain + 1] = c.id

            -- 018 (FR-013): thread sub-frame through the recursion seam.
            -- VIDEO clips have NULL subframes (no sub-frame concept on video);
            -- the explicit 0 here carries the "no sub-frame component" intent
            -- into the audio-leaf math (which ignores it for video entries).
            -- AUDIO clips MUST have non-NULL subframes; the load path asserts this.
            local c_lo_s, c_hi_s
            if c.track_type == "AUDIO" then
                assert(c.source_in_subframe ~= nil and c.source_out_subframe ~= nil,
                    string.format(
                    "Sequence.resolve (INV-3): audio clip %s has NULL subframe(s)",
                    tostring(c.id)))
                c_lo_s, c_hi_s = c.source_in_subframe, c.source_out_subframe
            else
                assert(c.source_in_subframe == nil and c.source_out_subframe == nil,
                    string.format(
                    "Sequence.resolve (INV-3): video clip %s has non-NULL subframe(s)",
                    tostring(c.id)))
                c_lo_s, c_hi_s = 0, 0
            end
            local inner = resolve_seq_range(db, c.sequence_id,
                c.source_in, c_lo_s, c.source_out, c_hi_s,
                context, inner_chain,
                layer_for_inner, audio_for_inner)

            -- No double-counting: V clips materialize only V media; A only A.
            local want_kind = (c.track_type == "VIDEO") and "video" or "audio"
            for _, e in ipairs(inner) do
                if e.media_kind == want_kind then
                    -- Translate master-coord -> outer-coord; the inner
                    -- entry's sequence_start/duration are in this clip's
                    -- nested-timebase, so we use this clip's source ratio.
                    translate_to_outer(e, c, c.source_in)

                    -- Tag entry with the outermost owning clip's track so
                    -- consumers (playback TMB routing) know which timeline
                    -- track to address. Recursion bubbles outwards — each
                    -- enclosing resolve_nested overwrites, so the topmost
                    -- (outermost) call wins.
                    e.owner_track_index = c.track_index
                    e.owner_track_type  = c.track_type
                    e.owner_clip_id     = c.id

                    -- Fold this clip's own volume + enabled into the chain.
                    e.volume  = e.volume * c.volume
                    e.enabled = e.enabled and c.enabled

                    -- Per-clip audio channel override: if this clip has a
                    -- row for the entry's channel, REPLACE the channel_state
                    -- (the override is the channel state of record at this
                    -- level — no divide-out gymnastics, no master-leaf
                    -- divisor problem at depth > 1).
                    if e.media_kind == "audio" and e.channel_index ~= nil then
                        local found, ov_enabled, ov_gain_db =
                            fetch_clip_channel_override(db, c.id, e.channel_index)
                        if found then
                            e.channel_state = {
                                enabled = ov_enabled, gain_db = ov_gain_db,
                            }
                        end
                    end

                    entries[#entries + 1] = e
                end
            end
        end
    end
    return entries
end

-- The resolver dispatch. Reads as a high-level algorithm (rule 2.5).
-- `layer_for_directly_referenced` and `audio_for_directly_referenced` are
-- the V / A track selectors that apply at the directly-referenced level
-- (master leaf or nested clip filter). NULL = composite/default for that
-- medium.
resolve_seq_range = function(db, seq_id, lo_f, lo_s, hi_f, hi_s, context,
                             outer_chain,
                             layer_for_directly_referenced,
                             audio_for_directly_referenced)
    -- Cycle guard (G-R2). Loud assert with provenance chain.
    assert(not context.recursing_into[seq_id], string.format(
        "Sequence.resolve G-R2: cycle detected in chain — sequence %s is already "
        .. "being resolved. provenance=[%s]",
        tostring(seq_id), table.concat(outer_chain, ", ")))
    context.recursing_into[seq_id] = true

    local kind = fetch_kind(db, seq_id)
    local entries
    if kind == "master" then
        entries = resolve_master_leaf(db, seq_id, lo_f, lo_s, hi_f, hi_s,
            layer_for_directly_referenced,
            audio_for_directly_referenced,
            outer_chain, context)
    else
        entries = resolve_nested(db, seq_id, lo_f, lo_s, hi_f, hi_s,
            context, outer_chain,
            layer_for_directly_referenced,
            audio_for_directly_referenced)
    end

    context.recursing_into[seq_id] = nil
    return entries
end

-- Compose channel_state into the final volume/enabled for audio entries,
-- then strip the internal field. Called once at the public boundary.
local function finalize_entries(entries)
    for _, e in ipairs(entries) do
        if e.channel_state ~= nil then
            e.volume  = e.volume * db_to_linear(e.channel_state.gain_db)
            e.enabled = e.enabled and e.channel_state.enabled
            e.channel_state = nil
        end
    end
    return entries
end

-- Public boundary: callers pass integer-frame range endpoints. The resolver
-- internally threads (frame, subframe) pairs; sub-frame at the public
-- endpoint is implicitly 0 (FR-013 — today's marks UX is frame-aligned).
-- The actual sub-frame contribution enters at every recursion seam where
-- a clip's stored source_in_subframe / source_out_subframe is consumed.
function Sequence:resolve_in_range(seq_id, start_frame, end_frame, context)
    assert(seq_id, "Sequence:resolve_in_range: seq_id required")
    assert(type(start_frame) == "number", "start_frame must be number")
    assert(type(end_frame) == "number", "end_frame must be number")
    assert(type(context) == "table", "context table required")
    context.recursing_into = context.recursing_into or {}
    local db = resolve_db()
    local entries = resolve_seq_range(db, seq_id,
        start_frame, 0, end_frame, 0,
        context, {}, nil, nil)
    return finalize_entries(entries)
end

-- ===========================================================================
-- Feature 013: table-form class helpers (find / update / assert_inv8)
-- ===========================================================================
-- These are stateless class-level helpers that return row tables (not objects
-- with metatables) and write via direct UPDATE. They're separate from the
-- legacy object-oriented Sequence.create(...) + :save() flow; both live on.

--- Read a sequence row by id. Returns a plain table (not a Sequence object)
--- with the full V9 shape, or nil if the row doesn't exist.
function Sequence.find(id)
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT id, project_id, name, kind, fps_numerator, fps_denominator,
               audio_sample_rate, width, height,
               default_video_layer_track_id, video_start_tc_frame,
               audio_start_tc_samples, fps_mismatch_policy,
               start_timecode_frame, mark_in_frame, mark_out_frame,
               playhead_frame
        FROM sequences WHERE id = ?
    ]])
    assert(stmt, "Sequence.find: prepare failed")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "Sequence.find: exec failed")
    local row
    if stmt:next() then
        row = {
            id = stmt:value(0),
            project_id = stmt:value(1),
            name = stmt:value(2),
            kind = stmt:value(3),
            fps_numerator = stmt:value(4),
            fps_denominator = stmt:value(5),
            audio_sample_rate = stmt:value(6),
            width = stmt:value(7),
            height = stmt:value(8),
            default_video_layer_track_id = stmt:value(9),
            video_start_tc_frame = stmt:value(10),
            audio_start_tc_samples = stmt:value(11),
            fps_mismatch_policy = stmt:value(12),
            start_timecode_frame = stmt:value(13),
            mark_in = stmt:value(14),
            mark_out = stmt:value(15),
            playhead_position = stmt:value(16),
        }
    end
    stmt:finalize()
    return row
end

--- Assert default_video_layer_track_id invariant on the given sequence: if the sequence has at
--- least one video track, default_video_layer_track_id must be non-NULL AND reference a live
--- video track of THIS sequence. Actionable assert message per rule 1.14.
function Sequence.assert_inv8(id)
    local conn = resolve_db()
    local row = Sequence.find(id)
    assert(row, string.format("Sequence.assert_inv8: sequence %s not found", tostring(id)))

    -- Does this sequence have any VIDEO tracks?
    local ts = conn:prepare(
        "SELECT id FROM tracks WHERE sequence_id = ? AND track_type = 'VIDEO' LIMIT 1")
    assert(ts, "Sequence.assert_inv8: video-track prepare failed")
    ts:bind_value(1, id)
    assert(ts:exec(), "Sequence.assert_inv8: video-track exec failed")
    local has_video = ts:next()
    ts:finalize()

    if not has_video then
        -- No video tracks; default_video_layer_track_id must be NULL.
        assert(row.default_video_layer_track_id == nil, string.format(
            "INV-8 (default_video_layer_track_id must be non-NULL when video tracks exist): sequence %s has no video tracks but default_video_layer_track_id=%s "
            .. "(Sequence.assert_inv8)",
            id, tostring(row.default_video_layer_track_id)))
        return
    end

    -- Has video tracks → default MUST be non-NULL and reference a live V track of this sequence.
    assert(row.default_video_layer_track_id ~= nil, string.format(
        "INV-8 (default_video_layer_track_id must be non-NULL when video tracks exist): sequence %s has video tracks but default_video_layer_track_id is NULL "
        .. "(Sequence.assert_inv8)", id))

    local vs = conn:prepare(
        "SELECT track_type, sequence_id FROM tracks WHERE id = ?")
    assert(vs, "Sequence.assert_inv8: default-track prepare failed")
    vs:bind_value(1, row.default_video_layer_track_id)
    assert(vs:exec(), "Sequence.assert_inv8: default-track exec failed")
    local found, ttype, tseq
    if vs:next() then
        found = true
        ttype = vs:value(0)
        tseq = vs:value(1)
    end
    vs:finalize()
    assert(found, string.format(
        "INV-8 (default_video_layer_track_id must be non-NULL when video tracks exist): sequence %s default_video_layer_track_id=%s does not exist "
        .. "(Sequence.assert_inv8)",
        id, tostring(row.default_video_layer_track_id)))
    assert(ttype == "VIDEO", string.format(
        "INV-8 (default_video_layer_track_id must be non-NULL when video tracks exist): sequence %s default_video_layer_track_id=%s is track_type=%s (expected VIDEO)",
        id, tostring(row.default_video_layer_track_id), tostring(ttype)))
    assert(tseq == id, string.format(
        "INV-8 (default_video_layer_track_id must be non-NULL when video tracks exist): sequence %s default_video_layer_track_id=%s belongs to sequence %s (cross-sequence not allowed)",
        id, tostring(row.default_video_layer_track_id), tostring(tseq)))
end

-- Columns update() will touch. Structural columns (id, project_id, kind,
-- fps_*, audio_sample_rate, width, height) are NOT here — changing them requires
-- dedicated commands.
local SEQUENCE_UPDATABLE = {
    name = true,
    start_timecode_frame = true, playhead_frame = true,
    view_start_frame = true, view_duration_frames = true,
    video_scroll_offset = true, audio_scroll_offset = true, video_audio_split_ratio = true,
    mark_in_frame = true, mark_out_frame = true,
    selected_clip_ids = true, selected_edge_infos = true, selected_gap_infos = true,
    default_video_layer_track_id = true,
    video_start_tc_frame = true, audio_start_tc_samples = true,
    fps_mismatch_policy = true,
    mutation_generation = true,
}

--- Update a subset of columns on a sequence. Fields not in the table are
--- untouched. Enforces default_video_layer_track_id validity after the write — the update as a unit must not
--- leave the sequence with a NULL default when video tracks exist.
function Sequence.update(id, fields)
    assert(type(fields) == "table", "Sequence.update: fields table required")
    local conn = resolve_db()

    local sets, values = {}, {}
    for k, v in pairs(fields) do
        assert(SEQUENCE_UPDATABLE[k], string.format(
            "Sequence.update: column '%s' is not updatable via this path", k))
        sets[#sets + 1] = k .. " = ?"
        values[#values + 1] = v
    end
    -- To explicitly NULL a column, pass the sentinel string "__NULL__" or use
    -- Sequence.update_nullable. Callers that need to NULL default_video_layer_track_id
    -- are rare (mainly track-delete); they use the track-delete command path.
    if #sets == 0 then return true end

    local sql = string.format("UPDATE sequences SET %s, modified_at = ? WHERE id = ?",
        table.concat(sets, ", "))
    local stmt = conn:prepare(sql)
    assert(stmt, "Sequence.update: prepare failed: " .. sql)
    for i, v in ipairs(values) do
        if v == false then
            stmt:bind_value(i, 0)
        elseif v == true then
            stmt:bind_value(i, 1)
        else
            stmt:bind_value(i, v)
        end
    end
    stmt:bind_value(#values + 1, os.time())
    stmt:bind_value(#values + 2, id)
    local ok = stmt:exec()
    local err
    if not ok then err = stmt:last_error() end
    stmt:finalize()
    assert(ok, string.format("Sequence.update: exec failed for id=%s: %s",
        id, tostring(err)))

    -- Post-condition: default_video_layer_track_id must be non-NULL when video tracks exist.
    Sequence.assert_inv8(id)
    return true
end

--- Feature 013 (T040): native-timebase duration of a sequence restricted to
--- a single medium. A master's VIDEO duration is in video frames at the
--- master's fps; its AUDIO duration is in audio samples at its audio_sample_rate —
--- the two are in different units, so the caller must specify which.
--- Computed as max(sequence_start_frame + duration_frames) across media_refs
--- (for a master) OR clips (for a nested sequence) on tracks of the given
--- type. Returns 0 if no content of that medium exists.
function Sequence.native_duration_for_medium(id, track_type)
    assert(id and id ~= "",
        "Sequence.native_duration_for_medium: id is required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Sequence.native_duration_for_medium: track_type must be VIDEO or AUDIO")
    local conn = resolve_db()
    -- Return the SPAN (length), not the absolute end frame. Master-sequence
    -- media_refs sit at sequence_start_frame = file_tc_origin (TIMECODE-IS-
    -- TRUTH memory), so MAX(start+duration) on its own equals
    -- tc_origin + actual_duration — wrong as a "how long is this content"
    -- answer. Callers (place_shared.compute_owner_duration et al.) treat
    -- the result as a duration; multiplying by a resample ratio against
    -- the end-frame produces wildly oversized clips.
    local stmt = conn:prepare([[
        SELECT COALESCE(
            MAX(r.sequence_start_frame + r.duration_frames)
              - MIN(r.sequence_start_frame),
            0)
        FROM (
            SELECT track_id, sequence_start_frame, duration_frames
              FROM media_refs WHERE owner_sequence_id = ?
            UNION ALL
            SELECT track_id, sequence_start_frame, duration_frames
              FROM clips WHERE owner_sequence_id = ?
        ) r
        JOIN tracks t ON r.track_id = t.id
        WHERE t.track_type = ?
    ]])
    assert(stmt, "Sequence.native_duration_for_medium: prepare failed")
    stmt:bind_value(1, id)
    stmt:bind_value(2, id)
    stmt:bind_value(3, track_type)
    assert(stmt:exec(), "Sequence.native_duration_for_medium: exec failed")
    assert(stmt:next(),
        "Sequence.native_duration_for_medium: query returned no rows")
    local d = stmt:value(0)
    stmt:finalize()
    return d
end

--- Feature 013 (T040): which track types does this sequence contain content on?
--- Returns a set: { VIDEO = true, AUDIO = true }. A master with a V1
--- media_ref + A1 media_ref returns both; a master with V1 only returns
--- VIDEO only. A nested sequence is introspected via its clips. Used by
--- Insert to decide how many clip rows to write.
function Sequence.contained_mediums(id)
    assert(id and id ~= "", "Sequence.contained_mediums: id is required")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT DISTINCT t.track_type FROM (
            SELECT track_id FROM media_refs WHERE owner_sequence_id = ?
            UNION ALL
            SELECT track_id FROM clips WHERE owner_sequence_id = ?
        ) r JOIN tracks t ON r.track_id = t.id
    ]])
    assert(stmt, "Sequence.contained_mediums: prepare failed")
    stmt:bind_value(1, id)
    stmt:bind_value(2, id)
    assert(stmt:exec(), "Sequence.contained_mediums: exec failed")
    local mediums = {}
    while stmt:next() do mediums[stmt:value(0)] = true end
    stmt:finalize()
    return mediums
end

--- Feature 013 (T040): read just the `name` column. Used when Insert needs a
--- default clip name and no explicit arg was passed (the clip's name column
--- is NOT NULL, so Insert must source one authoritatively).
function Sequence.get_name(id)
    assert(id and id ~= "", "Sequence.get_name: id is required")
    local conn = resolve_db()
    local stmt = conn:prepare("SELECT name FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.get_name: prepare failed")
    stmt:bind_value(1, id)
    assert(stmt:exec(), "Sequence.get_name: exec failed")
    assert(stmt:next(), string.format("Sequence.get_name: id=%s not found", id))
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

--- Capture a sequence's full row + its tracks, suitable for restore.
--- Used by Unnest.execute before orphan-deleting the nested sequence so
--- Unnest.undo can resurrect it. Returns nil if the sequence is missing.
---
--- @return table|nil { seq = {row...}, tracks = [{id,name,type,index},...] }
function Sequence.capture_full_state(id)
    assert(id and id ~= "", "Sequence.capture_full_state: id required")
    local seq = Sequence.find(id)
    if not seq then return nil end
    local Track = require("models.track")
    local tracks = {}
    for _, ttype in ipairs({ "VIDEO", "AUDIO" }) do
        local list = Track.find_by_sequence(id, ttype)
        for _, t in ipairs(list) do
            tracks[#tracks + 1] = {
                id          = t.id,
                name        = t.name,
                track_type  = ttype,
                track_index = t.track_index,
            }
        end
    end
    return { seq = seq, tracks = tracks }
end

--- Re-INSERT the sequence row + its tracks captured by
--- capture_full_state. Used by Unnest.undo when an orphan-deleted
--- nested sequence needs resurrection.
function Sequence.restore_full_state(state)
    assert(type(state) == "table" and type(state.seq) == "table",
        "Sequence.restore_full_state: state.seq table required")
    local s = state.seq
    local conn = resolve_db()
    local now = os.time()

    -- The captured default_video_layer_track_id references a track that
    -- WILL be re-INSERTed below. Defer FK checks for this transaction
    -- so the sequence INSERT lands before its tracks exist.
    conn:exec("PRAGMA defer_foreign_keys = ON;")
    conn:exec("BEGIN;")

    local function rollback(reason)
        conn:exec("ROLLBACK;")
        conn:exec("PRAGMA defer_foreign_keys = OFF;")
        error("Sequence.restore_full_state: " .. reason)
    end

    local stmt = conn:prepare([[
        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, video_start_tc_frame,
            audio_start_tc_samples, fps_mismatch_policy,
            playhead_frame, view_start_frame, view_duration_frames,
            video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
            mutation_generation, created_at, modified_at, start_timecode_frame
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                  0, 0, 240, 0, 0, 0.5, 0, ?, ?, 0)
    ]])
    if not stmt then rollback("prepare seq INSERT failed") end
    stmt:bind_value(1,  s.id)
    stmt:bind_value(2,  s.project_id)
    stmt:bind_value(3,  s.name)
    stmt:bind_value(4,  s.kind)
    stmt:bind_value(5,  s.fps_numerator)
    stmt:bind_value(6,  s.fps_denominator)
    stmt:bind_value(7,  s.audio_sample_rate)
    stmt:bind_value(8,  s.width)
    stmt:bind_value(9,  s.height)
    stmt:bind_value(10, s.default_video_layer_track_id)
    stmt:bind_value(11, s.video_start_tc_frame)
    stmt:bind_value(12, s.audio_start_tc_samples)
    stmt:bind_value(13, s.fps_mismatch_policy)
    stmt:bind_value(14, now)
    stmt:bind_value(15, now)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    if not ok then
        rollback(string.format("INSERT seq %s failed: %s", s.id, tostring(err)))
    end

    local Track = require("models.track")
    -- capture_full_state always populates state.tracks (possibly empty).
    for _, t in ipairs(state.tracks) do
        local newt
        if t.track_type == "VIDEO" then
            newt = Track.create_video(t.name, s.id,
                { id = t.id, index = t.track_index })
        else
            newt = Track.create_audio(t.name, s.id,
                { id = t.id, index = t.track_index })
        end
        if not newt:save() then
            rollback(string.format("save track %s failed", t.id))
        end
    end

    local commit_ok, commit_err = conn:exec("COMMIT;")
    conn:exec("PRAGMA defer_foreign_keys = OFF;")
    assert(commit_ok ~= false, string.format(
        "Sequence.restore_full_state: COMMIT failed: %s",
        tostring(commit_err)))
end

--- DELETE a sequence row by id. Cascades to tracks/clips/media_refs/
--- channel-state via FK ON DELETE CASCADE. Used by Nest.undo to drop
--- the sequence created by Nest.execute, and by Unnest's orphan
--- cleanup.
function Sequence.delete_one(id)
    assert(id and id ~= "", "Sequence.delete_one: id required")
    local conn = resolve_db()
    local stmt = conn:prepare("DELETE FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.delete_one: prepare failed")
    stmt:bind_value(1, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "Sequence.delete_one: exec failed for id=" .. id)
end

--- Write a sequence's fps_mismatch_policy directly. Nullable (NULL =
--- inherit project default). Lua's pairs skips nil so this dedicated
--- setter is required for the NULL-restore path on undo.
---
--- @param id string
--- @param policy string|nil  'resample' / 'passthrough' / nil
function Sequence.set_fps_mismatch_policy(id, policy)
    assert(id and id ~= "", "Sequence.set_fps_mismatch_policy: id required")
    assert(policy == nil or policy == "resample" or policy == "passthrough",
        "Sequence.set_fps_mismatch_policy: policy must be 'resample', "
        .. "'passthrough', or nil")
    local conn = resolve_db()
    local stmt = conn:prepare(
        "UPDATE sequences SET fps_mismatch_policy = ?, modified_at = ? "
        .. "WHERE id = ?")
    assert(stmt, "Sequence.set_fps_mismatch_policy: prepare failed")
    stmt:bind_value(1, policy)   -- nil → SQL NULL
    stmt:bind_value(2, os.time())
    stmt:bind_value(3, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "Sequence.set_fps_mismatch_policy: exec failed")
end

--- Write a sequence's start-TC column directly. Distinct from
--- Sequence.update because Lua's `pairs` skips nil values, and the
--- start-TC columns are nullable (FR-017 default-derivation may leave
--- them NULL when no media is present yet). Always writes the column.
---
--- @param id string
--- @param medium string  'video' or 'audio'
--- @param value number|nil  integer; nil writes SQL NULL
function Sequence.set_start_tc(id, medium, value)
    assert(id and id ~= "", "Sequence.set_start_tc: id required")
    assert(medium == "video" or medium == "audio",
        "Sequence.set_start_tc: medium must be 'video' or 'audio'")
    if value ~= nil then
        assert(type(value) == "number" and value == math.floor(value),
            "Sequence.set_start_tc: value must be integer or nil")
    end
    local conn = resolve_db()
    local field = (medium == "video")
        and "video_start_tc_frame" or "audio_start_tc_samples"
    local stmt = conn:prepare(string.format(
        "UPDATE sequences SET %s = ?, modified_at = ? WHERE id = ?", field))
    assert(stmt, "Sequence.set_start_tc: prepare failed")
    stmt:bind_value(1, value)   -- nil → SQL NULL
    stmt:bind_value(2, os.time())
    stmt:bind_value(3, id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, string.format("Sequence.set_start_tc: exec failed for id=%s", id))
end

--- Count the audio channels exposed by a master sequence's tracks. Sum
--- of media.audio_channels across the master's A-track media_refs. Used
--- by ToggleClipChannel/SetClipChannelGain for channel_index bounds checks.
---
--- @param master_id string  must reference a kind='master' sequence
--- @return integer  total audio channel count
--- 018 (FR-004): masters carry no audio_sample_rate. For placement
--- math that needs a master's audio rate (samples-per-frame, owner-duration
--- conversion), derive from the first audio media_ref inside the master.
--- Multi-rate audio per master (Acceptance Scenario 2) requires further
--- per-stream handling; this helper preserves the single-rate common case.
--- For regular sequences, returns `audio_sample_rate` directly.
---
--- @param seq table Loaded sequence row (must have .id, .kind, .audio_sample_rate)
--- @return integer audio sample rate in Hz
function Sequence.effective_audio_sample_rate(seq)
    assert(type(seq) == "table" and seq.id,
        "Sequence.effective_audio_sample_rate: seq table with id required")
    if seq.audio_sample_rate then return seq.audio_sample_rate end
    local conn = resolve_db()
    -- 018 (FR-004): every AUDIO media_ref carries audio_sample_rate at insert.
    local stmt = conn:prepare([[
        SELECT mr.audio_sample_rate
        FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO'
          AND mr.audio_sample_rate IS NOT NULL
        LIMIT 1
    ]])
    assert(stmt, "Sequence.effective_audio_sample_rate: prepare failed")
    stmt:bind_value(1, seq.id)
    assert(stmt:exec(), "Sequence.effective_audio_sample_rate: exec failed")
    local rate
    if stmt:next() then rate = stmt:value(0) end
    stmt:finalize()
    assert(rate, string.format(
        "Sequence.effective_audio_sample_rate: master %s has no audio media_ref with audio_sample_rate",
        tostring(seq.id)))
    return rate
end

function Sequence.count_master_audio_channels(master_id)
    assert(master_id and master_id ~= "",
        "Sequence.count_master_audio_channels: master_id required")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT COALESCE(SUM(m.audio_channels), 0)
        FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        JOIN media m  ON m.id = mr.media_id
        WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO'
    ]])
    assert(stmt, "Sequence.count_master_audio_channels: prepare failed")
    stmt:bind_value(1, master_id)
    assert(stmt:exec(), "Sequence.count_master_audio_channels: exec failed")
    assert(stmt:next(),
        "Sequence.count_master_audio_channels: aggregate returned no row")
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

--- Read a master's per-channel state from media_refs_channel_state.
--- Returns (enabled_bool, gain_db_number); on absent row returns the
--- resolver-default contract (true, 0). Used by ToggleClipChannel /
--- SetClipChannelGain to materialize inherited state at first override.
---
--- @param master_id string
--- @param channel_index integer  0-based
function Sequence.get_master_channel_state(master_id, channel_index)
    assert(master_id and master_id ~= "",
        "Sequence.get_master_channel_state: master_id required")
    assert(type(channel_index) == "number",
        "Sequence.get_master_channel_state: channel_index must be integer")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT enabled, default_gain_db FROM media_refs_channel_state
        WHERE owner_sequence_id = ? AND channel_index = ?
    ]])
    assert(stmt, "Sequence.get_master_channel_state: prepare failed")
    stmt:bind_value(1, master_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "Sequence.get_master_channel_state: exec failed")
    local enabled, gain_db = true, 0.0   -- resolver default contract
    if stmt:next() then
        enabled = stmt:value(0) == 1
        gain_db = stmt:value(1)
    end
    stmt:finalize()
    return enabled, gain_db
end

--- 018 FR-035: ConformSequence's transactional rewrite. Caller passes the
--- target fps and the pre-captured row snapshots that need rescaling; this
--- function does the SAVEPOINT + conform-single-writer flag + UPDATE choreography and
--- delegates the actual scaled values to the injected rescaler.
---
--- @param sequence_id    string  — the sequence whose fps is changing
--- @param new_fps_num    integer — new fps numerator
--- @param new_fps_den    integer — new fps denominator
--- @param captured       table   — { mrefs = {{id, seq_start, dur}, ...},
---                                  inner_clips = {{id, seq_start, dur}, ...},
---                                  outer_clips = {{id, src_in, src_out}, ...} }
--- @param rescaler       fn(old) -> new — integer→integer using the FR-008
---                                         rounding rule and (new_fps_num,
---                                         old_fps_num, new_fps_den, old_fps_den)
function Sequence.conform_fps(sequence_id, new_fps_num, new_fps_den, captured, rescaler)
    assert(sequence_id and sequence_id ~= "",
        "Sequence.conform_fps: sequence_id required")
    assert(type(new_fps_num) == "number" and new_fps_num > 0,
        "Sequence.conform_fps: new_fps_num must be positive number")
    assert(type(new_fps_den) == "number" and new_fps_den > 0,
        "Sequence.conform_fps: new_fps_den must be positive number")
    assert(type(captured) == "table",
        "Sequence.conform_fps: captured table required")
    assert(type(rescaler) == "function",
        "Sequence.conform_fps: rescaler injector required")

    local SAVEPOINT = "sequence_conform_fps"
    local SESSION_FLAG = "_conform_sequence_in_progress"

    local db_mod = require("core.database")
    local conn = resolve_db()
    assert(db_mod.savepoint(SAVEPOINT),
        "Sequence.conform_fps: savepoint failed")

    local ok, result_or_err = pcall(function()
        local flag_ins = conn:prepare(
            "INSERT INTO db_session_flags (name) VALUES (?)")
        flag_ins:bind_value(1, SESSION_FLAG)
        assert(flag_ins:exec(), "ConformSequence: set conform-single-writer flag failed")
        flag_ins:finalize()

        -- Sequence fps first (with the flag in place, the fps single-writer trigger passes).
        local upd_seq = conn:prepare(
            "UPDATE sequences SET fps_numerator = ?, fps_denominator = ?, modified_at = ? WHERE id = ?")
        upd_seq:bind_value(1, new_fps_num)
        upd_seq:bind_value(2, new_fps_den)
        upd_seq:bind_value(3, os.time())
        upd_seq:bind_value(4, sequence_id)
        local seq_ok = upd_seq:exec()
        local seq_err
        if not seq_ok then seq_err = conn:last_error() end
        upd_seq:finalize()
        assert(seq_ok, "sequence fps UPDATE failed: " .. tostring(seq_err))

        -- media_refs in master: rescale (sequence_start_frame, duration_frames).
        local post_mrefs = {}
        if captured.mrefs and #captured.mrefs > 0 then
            local upd_mr = conn:prepare(
                "UPDATE media_refs SET sequence_start_frame = ?, duration_frames = ?, modified_at = ? WHERE id = ?")
            for _, m in ipairs(captured.mrefs) do
                local new_start = rescaler(m.seq_start)
                local new_dur   = rescaler(m.dur)
                upd_mr:bind_value(1, new_start)
                upd_mr:bind_value(2, new_dur)
                upd_mr:bind_value(3, os.time())
                upd_mr:bind_value(4, m.id)
                local mr_ok = upd_mr:exec()
                local mr_err
                if not mr_ok then mr_err = conn:last_error() end
                upd_mr:reset(); upd_mr:clear_bindings()
                assert(mr_ok, string.format(
                    "media_ref %s UPDATE failed: %s", tostring(m.id), tostring(mr_err)))
                post_mrefs[#post_mrefs + 1] = {
                    id = m.id, seq_start = new_start, dur = new_dur,
                }
            end
            upd_mr:finalize()
        end

        -- Contained clips (kind='sequence'): rescale (seq_start, dur).
        local post_inner = {}
        if captured.inner_clips and #captured.inner_clips > 0 then
            local upd_in = conn:prepare(
                "UPDATE clips SET sequence_start_frame = ?, duration_frames = ?, modified_at = ? WHERE id = ?")
            for _, c in ipairs(captured.inner_clips) do
                local new_start = rescaler(c.seq_start)
                local new_dur   = rescaler(c.dur)
                upd_in:bind_value(1, new_start)
                upd_in:bind_value(2, new_dur)
                upd_in:bind_value(3, os.time())
                upd_in:bind_value(4, c.id)
                local cin_ok = upd_in:exec()
                local cin_err
                if not cin_ok then cin_err = conn:last_error() end
                upd_in:reset(); upd_in:clear_bindings()
                assert(cin_ok, string.format(
                    "inner clip %s UPDATE failed: %s", tostring(c.id), tostring(cin_err)))
                post_inner[#post_inner + 1] = {
                    id = c.id, seq_start = new_start, dur = new_dur,
                }
            end
            upd_in:finalize()
        end

        -- Outer clips pointing at this sequence: rescale (src_in, src_out).
        local post_outer = {}
        if captured.outer_clips and #captured.outer_clips > 0 then
            local upd_out = conn:prepare(
                "UPDATE clips SET source_in_frame = ?, source_out_frame = ?, modified_at = ? WHERE id = ?")
            for _, c in ipairs(captured.outer_clips) do
                local new_in  = rescaler(c.src_in)
                local new_out = rescaler(c.src_out)
                upd_out:bind_value(1, new_in)
                upd_out:bind_value(2, new_out)
                upd_out:bind_value(3, os.time())
                upd_out:bind_value(4, c.id)
                local cout_ok = upd_out:exec()
                local cout_err
                if not cout_ok then cout_err = conn:last_error() end
                upd_out:reset(); upd_out:clear_bindings()
                assert(cout_ok, string.format(
                    "outer clip %s UPDATE failed: %s", tostring(c.id), tostring(cout_err)))
                post_outer[#post_outer + 1] = {
                    id = c.id, src_in = new_in, src_out = new_out,
                }
            end
            upd_out:finalize()
        end

        local flag_del = conn:prepare("DELETE FROM db_session_flags WHERE name = ?")
        flag_del:bind_value(1, SESSION_FLAG)
        assert(flag_del:exec(), "ConformSequence: clear conform-single-writer flag failed")
        flag_del:finalize()

        return { mrefs = post_mrefs, inner_clips = post_inner, outer_clips = post_outer }
    end)

    if not ok then
        db_mod.rollback_to_savepoint(SAVEPOINT)
        db_mod.release_savepoint(SAVEPOINT)
        error(result_or_err, 0)
    end
    assert(db_mod.release_savepoint(SAVEPOINT),
        "Sequence.conform_fps: release savepoint failed")
    return result_or_err
end

--- 018 FR-035 helpers — collect the row snapshots ConformSequence must
--- rewrite. Read-only; safe outside a savepoint.
function Sequence.collect_conform_captured(sequence_id)
    assert(sequence_id and sequence_id ~= "",
        "Sequence.collect_conform_captured: sequence_id required")
    local conn = resolve_db()
    local seq = Sequence.find(sequence_id)
    assert(seq, "Sequence.collect_conform_captured: sequence " .. sequence_id .. " not found")

    local mrefs, inner_clips, outer_clips = {}, {}, {}

    if seq.kind == "master" then
        local s = conn:prepare([[
            SELECT id, sequence_start_frame, duration_frames
            FROM media_refs WHERE owner_sequence_id = ? ORDER BY id ASC
        ]])
        s:bind_value(1, sequence_id)
        assert(s:exec(), "collect_conform_captured: mrefs exec failed")
        while s:next() do
            mrefs[#mrefs + 1] = {
                id = s:value(0), seq_start = s:value(1), dur = s:value(2),
            }
        end
        s:finalize()
    elseif seq.kind == "sequence" then
        local s = conn:prepare([[
            SELECT id, sequence_start_frame, duration_frames
            FROM clips WHERE owner_sequence_id = ? ORDER BY id ASC
        ]])
        s:bind_value(1, sequence_id)
        assert(s:exec(), "collect_conform_captured: inner clips exec failed")
        while s:next() do
            inner_clips[#inner_clips + 1] = {
                id = s:value(0), seq_start = s:value(1), dur = s:value(2),
            }
        end
        s:finalize()
    else
        error(string.format(
            "Sequence.collect_conform_captured: unsupported kind=%s on %s",
            tostring(seq.kind), sequence_id))
    end

    -- BOTH kinds: clips pointing AT this sequence as their source.
    local s = conn:prepare([[
        SELECT id, source_in_frame, source_out_frame
        FROM clips WHERE sequence_id = ? ORDER BY id ASC
    ]])
    s:bind_value(1, sequence_id)
    assert(s:exec(), "collect_conform_captured: outer clips exec failed")
    while s:next() do
        outer_clips[#outer_clips + 1] = {
            id = s:value(0), src_in = s:value(1), src_out = s:value(2),
        }
    end
    s:finalize()

    return seq.kind, seq.fps_numerator, seq.fps_denominator,
        { mrefs = mrefs, inner_clips = inner_clips, outer_clips = outer_clips }
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

return Sequence