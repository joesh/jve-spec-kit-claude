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
    
    assert(type(width) == "number" and width > 0, "Sequence.create: width is required and must be positive")
    assert(type(height) == "number" and height > 0, "Sequence.create: height is required and must be positive")
    local w = math.floor(width)
    local h = math.floor(height)

    opts = opts or {}
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
    -- ('master', 'nested'); caller must pick.
    assert(opts.kind == "master" or opts.kind == "nested",
        "Sequence.create: opts.kind must be 'master' or 'nested' (V9 schema); got "
        .. tostring(opts.kind))
    assert(opts.audio_rate and opts.audio_rate > 0,
        "Sequence.create: opts.audio_rate is required (rule 2.13)")

    local sequence = {
        id = opts.id or uuid.generate(),
        project_id = project_id,
        name = name,
        kind = opts.kind,
        frame_rate = fr,
        width = w,
        height = h,
        audio_sample_rate = opts.audio_rate,

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
                       view_duration_frames, mark_in_frame, mark_out_frame, audio_rate,
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

function Sequence:save()
    assert(self and self.id and self.id ~= "", "Sequence.save: invalid sequence or missing id")
    assert(self.project_id and self.project_id ~= "", "Sequence.save: project_id is required")

    local conn = resolve_db()
    if not conn then
        return false
    end

    self.modified_at = os.time()

    -- Coordinates are now plain integers
    local db_fps_num = self.frame_rate.fps_numerator
    local db_fps_den = self.frame_rate.fps_denominator

    local db_playhead = self.playhead_position
    local db_view_start = self.viewport_start_time
    local db_view_dur = self.viewport_duration

    local db_mark_in = self.mark_in  -- nil or integer
    local db_mark_out = self.mark_out  -- nil or integer
    
    assert(self.audio_sample_rate, "Sequence.save: audio_sample_rate is required for sequence " .. tostring(self.id))
    local db_audio_rate = self.audio_sample_rate

    -- CRITICAL: Use ON CONFLICT DO UPDATE instead of INSERT OR REPLACE
    -- INSERT OR REPLACE triggers DELETE first, which cascades to delete clips via foreign keys!
    local stmt = conn:prepare([[
        INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, width, height,
         start_timecode_frame,
         playhead_frame, view_start_frame, view_duration_frames,
         video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
         mark_in_frame, mark_out_frame, audio_rate,
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
            audio_rate = excluded.audio_rate,
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

    stmt:bind_value(1, self.id)
    stmt:bind_value(2, self.project_id)
    stmt:bind_value(3, self.name)
    -- Schema V9 CHECK forbids NULL/default; caller must have set this.
    assert(self.kind == "master" or self.kind == "nested",
        "Sequence.save: kind must be 'master' or 'nested' (V9); got " .. tostring(self.kind))
    stmt:bind_value(4, self.kind)
    stmt:bind_value(5, db_fps_num)
    stmt:bind_value(6, db_fps_den)
    stmt:bind_value(7, self.width)
    stmt:bind_value(8, self.height)
    stmt:bind_value(9, self.start_timecode_frame or 0)
    stmt:bind_value(10, db_playhead)
    stmt:bind_value(11, db_view_start)
    stmt:bind_value(12, db_view_dur)
    stmt:bind_value(13, self.video_scroll_offset or 0)
    stmt:bind_value(14, self.audio_scroll_offset or 0)
    stmt:bind_value(15, self.video_audio_split_ratio or 0.5)

    if db_mark_in then
        stmt:bind_value(16, db_mark_in)
    else
        if stmt.bind_null then
            stmt:bind_null(16)
        else
            stmt:bind_value(16, nil)
        end
    end

    if db_mark_out then
        stmt:bind_value(17, db_mark_out)
    else
        if stmt.bind_null then
            stmt:bind_null(17)
        else
            stmt:bind_value(17, nil)
        end
    end

    stmt:bind_value(18, db_audio_rate)
    stmt:bind_value(19, self.selected_clip_ids_json or "")
    stmt:bind_value(20, self.selected_edge_infos_json or "")
    stmt:bind_value(21, self.selected_gap_infos_json or "[]")

    -- V9 columns. All nullable.
    local function bind_nullable(idx, val)
        if val == nil then
            if stmt.bind_null then stmt:bind_null(idx) else stmt:bind_value(idx, nil) end
        else
            stmt:bind_value(idx, val)
        end
    end
    bind_nullable(22, self.default_video_layer_track_id)
    bind_nullable(23, self.video_start_tc_frame)
    bind_nullable(24, self.audio_start_tc_samples)
    bind_nullable(25, self.fps_mismatch_policy)

    stmt:bind_value(26, self.created_at or os.time())
    stmt:bind_value(27, self.modified_at)

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
    local stmt = assert(conn:prepare([[
        UPDATE sequences SET current_sequence_number = ?
        WHERE project_id = ? AND kind = 'timeline'
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

    -- Filter out masterclip sequences - only return timeline sequences
    local stmt = assert(conn:prepare([[
        SELECT id FROM sequences
        WHERE kind IS NULL OR kind != 'masterclip'
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
---     audio_rate from media.audio_sample_rate (or opts.sample_rate).
---   * V1 track + V media_ref pointing at the file (source frames 0..duration).
---   * One A track per media.audio_channels, each with a media_ref over
---     samples 0..duration_samples.
---   * sequences.video_start_tc_frame / audio_start_tc_samples populated
---     from media TC (FR-017 default-derivation).
---   * sequences.default_video_layer_track_id = the V1 track when video
---     present (INV-8).
---
--- Per-track unit convention (matching the established CT-R5/CT-R6 fixtures
--- and pre-013 ensure_masterclip): video media_refs measure timeline_start
--- and source in master.fps frames; audio media_refs measure timeline_start
--- and source in samples at the file's audio_sample_rate. The resolver
--- compares within-track and never crosses tracks in a single arithmetic
--- expression, so the per-track unit is internally consistent.
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

    local media = Media.load(media_id)
    assert(media, string.format(
        "Sequence.ensure_master: Media record not found for media_id=%s",
        tostring(media_id)))

    local fps_num = media.frame_rate.fps_numerator
    local fps_den = media.frame_rate.fps_denominator
    local duration_frames = media.duration
    local has_video = media.width > 0
    local has_audio = media.audio_channels > 0

    local sample_rate = opts.sample_rate
    if not sample_rate and has_audio then
        sample_rate = media.audio_sample_rate
    end
    assert(not has_audio or (sample_rate and sample_rate > 0), string.format(
        "Sequence.ensure_master: media %s has audio but no sample_rate "
        .. "(audio_channels=%s, audio_sample_rate=%s)",
        tostring(media_id), tostring(media.audio_channels),
        tostring(media.audio_sample_rate)))
    -- Sequence.create requires opts.audio_rate > 0 even for video-only masters
    -- (the field is on every sequence). Use a project-conventional placeholder
    -- only when the media has no audio at all — the value is unused by the
    -- resolver since no audio media_refs will be emitted.
    local seq_audio_rate = sample_rate or 48000

    local duration_samples = 0
    if has_audio and duration_frames > 0 then
        duration_samples = math.floor(
            duration_frames * sample_rate * fps_den / fps_num + 0.5)
    end

    local width  = has_video and media.width  or 1920
    local height = has_video and media.height or 1080

    -- TC origins (FR-017 defaults).
    local video_start_tc_frame  = has_video and media:get_start_tc()       or nil
    local audio_start_tc_samples = has_audio and media:get_audio_start_tc() or nil
    if has_video then
        assert(video_start_tc_frame ~= nil, string.format(
            "Sequence.ensure_master: media %s has no video TC origin",
            tostring(media_id)))
    end
    if has_audio then
        assert(audio_start_tc_samples ~= nil, string.format(
            "Sequence.ensure_master: media %s has no audio TC origin",
            tostring(media_id)))
    end

    assert(media.name and media.name ~= "", string.format(
        "Sequence.ensure_master: media has no name for media_id=%s",
        tostring(media_id)))

    -- Build the master sequence row. default_video_layer_track_id is set
    -- AFTER the V track is created (INV-8 satisfied below).
    local seq = Sequence.create(media.name, project_id,
        {fps_numerator = fps_num, fps_denominator = fps_den},
        width, height, {
            id                       = opts.id,
            kind                     = "master",
            audio_rate               = seq_audio_rate,
            start_timecode_frame     = video_start_tc_frame or 0,
            playhead_frame           = video_start_tc_frame or 0,
            video_start_tc_frame     = video_start_tc_frame,
            audio_start_tc_samples   = audio_start_tc_samples,
        })
    assert(seq:save(), string.format(
        "Sequence.ensure_master: failed to save master sequence for media_id=%s",
        tostring(media_id)))

    local now = os.time()

    if has_video then
        local vtrack = Track.create_video("Video 1", seq.id, {
            id    = opts.video_track_id,
            index = 1,
        })
        assert(vtrack:save(), "Sequence.ensure_master: failed to save video track")

        MediaRef.create({
            id                   = opts.video_media_ref_id,
            project_id           = project_id,
            owner_sequence_id    = seq.id,
            track_id             = vtrack.id,
            media_id             = media_id,
            source_in_frame      = 0,
            source_out_frame     = duration_frames,
            timeline_start_frame = 0,
            duration_frames      = duration_frames,
            enabled              = true,
            volume               = 1.0,
            playhead_frame       = 0,
            created_at           = now,
            modified_at          = now,
        })

        -- INV-8: master with at least one V track must have a non-NULL
        -- default_video_layer_track_id.
        Sequence.update(seq.id,
            { default_video_layer_track_id = vtrack.id })
    end

    if has_audio then
        local replay_audio_track_ids    = opts.audio_track_ids     or {}
        local replay_audio_media_ref_ids = opts.audio_media_ref_ids or {}
        for ch = 1, media.audio_channels do
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
                source_in_frame      = 0,
                source_out_frame     = duration_samples,
                timeline_start_frame = 0,
                duration_frames      = duration_samples,
                enabled              = true,
                volume               = 1.0,
                playhead_frame       = 0,
                created_at           = now,
                modified_at          = now,
            })
        end
    end

    if opts.bin_id then
        local tag_service = require("core.tag_service")
        tag_service.add_to_bin(project_id, {seq.id}, opts.bin_id, "master_clip")
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

-- Sequence.ensure_masterclip / find_masterclip_for_media / _find_masterclip_for_media
-- were V8-only paths that wrote sequences.kind='masterclip' (banned under V13)
-- and clips with clip_kind='master'/media_id (columns dropped). Replaced by
-- Sequence.ensure_master + Sequence.find_master_for_media above. FR-018: no
-- back-compat — old callers must migrate, no shim.

-- =============================================================================
-- MASTERCLIP SEQUENCE METHODS (for kind="masterclip")
-- =============================================================================

--- Check if this is a masterclip sequence (appears in project browser as source)
-- @return boolean true if kind == "masterclip"
function Sequence:is_masterclip()
    return self.kind == "masterclip"
end

--- Ensure stream clips are loaded and cached for this masterclip sequence
-- Asserts if called on non-masterclip sequence
-- @return table {video_clips = {...}, audio_clips = {...}}
local function ensure_stream_clips(self)
    assert(self.kind == "masterclip", string.format(
        "Sequence.ensure_stream_clips: sequence %s is not a masterclip (kind=%s)",
        tostring(self.id), tostring(self.kind)))

    -- Check cache
    if self._cached_stream_clips then
        return self._cached_stream_clips
    end

    local Track = require("models.track")
    local Clip = require("models.clip")
    local conn = resolve_db()

    -- Get all tracks in this sequence
    local video_tracks = Track.find_by_sequence(self.id, "VIDEO")
    local audio_tracks = Track.find_by_sequence(self.id, "AUDIO")

    local video_clips = {}
    local audio_clips = {}

    -- Find clips on video tracks (for masterclip, just get all clips on track)
    for _, track in ipairs(video_tracks) do
        local stmt = conn:prepare([[
            SELECT id FROM clips
            WHERE track_id = ?
            ORDER BY timeline_start_frame ASC
        ]])
        assert(stmt, "Sequence.ensure_stream_clips: Failed to prepare video query")
        stmt:bind_value(1, track.id)
        local exec_ok = stmt:exec()
        assert(exec_ok, string.format(
            "Sequence.ensure_stream_clips: video query exec failed for track_id=%s",
            tostring(track.id)))
        while stmt:next() do
            local clip_id = stmt:value(0)
            local clip = Clip.load(clip_id)
            assert(clip, string.format(
                "Sequence.ensure_stream_clips: Failed to load video stream clip %s",
                tostring(clip_id)))
            video_clips[#video_clips + 1] = clip
        end
        stmt:finalize()
    end

    -- Find clips on audio tracks
    for _, track in ipairs(audio_tracks) do
        local stmt = conn:prepare([[
            SELECT id FROM clips
            WHERE track_id = ?
            ORDER BY timeline_start_frame ASC
        ]])
        assert(stmt, "Sequence.ensure_stream_clips: Failed to prepare audio query")
        stmt:bind_value(1, track.id)
        local exec_ok = stmt:exec()
        assert(exec_ok, string.format(
            "Sequence.ensure_stream_clips: audio query exec failed for track_id=%s",
            tostring(track.id)))
        while stmt:next() do
            local clip_id = stmt:value(0)
            local clip = Clip.load(clip_id)
            assert(clip, string.format(
                "Sequence.ensure_stream_clips: Failed to load audio stream clip %s",
                tostring(clip_id)))
            audio_clips[#audio_clips + 1] = clip
        end
        stmt:finalize()
    end

    local result = {
        video_clips = video_clips,
        audio_clips = audio_clips,
    }

    -- Cache for subsequent calls
    self._cached_stream_clips = result
    return result
end

--- Get the video stream clip from this masterclip sequence
-- Asserts if called on non-masterclip sequence
-- @return Clip|nil Video clip or nil if no video stream exists
function Sequence:video_stream()
    local streams = ensure_stream_clips(self)
    return streams.video_clips[1]
end

--- Get all audio stream clips from this masterclip sequence
-- Asserts if called on non-masterclip sequence
-- @return table Array of audio clips (may be empty)
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
-- TIMEBASE CONVERSION (for masterclip sequences)
-- =============================================================================

--- Convert video frames to audio samples using this sequence's video rate
-- and the first audio stream's sample rate
-- @param frame number Frame position in video timebase
-- @return number|nil Sample position, or nil if no audio stream
function Sequence:frame_to_samples(frame)
    assert(type(frame) == "number", "Sequence:frame_to_samples: frame must be a number")

    local audio = self:audio_streams()[1]
    if not audio then
        return nil
    end

    -- audio.rate.fps_numerator = sample_rate (e.g., 48000, 44100, 96000)
    -- audio.rate.fps_denominator = 1
    -- self.frame_rate.fps_numerator = video fps numerator
    -- self.frame_rate.fps_denominator = video fps denominator
    local sample_rate = audio.rate.fps_numerator
    local video_fps_num = self.frame_rate.fps_numerator
    local video_fps_den = self.frame_rate.fps_denominator

    -- samples = frame * (sample_rate / video_fps)
    --         = frame * sample_rate * video_fps_den / video_fps_num
    return math.floor(frame * sample_rate * video_fps_den / video_fps_num)
end

--- Convert audio samples to video frames using this sequence's video rate
-- and the first audio stream's sample rate
-- @param samples number Sample position in audio timebase
-- @return number|nil Frame position, or nil if no audio stream
function Sequence:samples_to_frame(samples)
    assert(type(samples) == "number", "Sequence:samples_to_frame: samples must be a number")

    local audio = self:audio_streams()[1]
    if not audio then
        return nil
    end

    local sample_rate = audio.rate.fps_numerator
    local video_fps_num = self.frame_rate.fps_numerator
    local video_fps_den = self.frame_rate.fps_denominator

    -- frame = samples * video_fps / sample_rate
    --       = samples * video_fps_num / (video_fps_den * sample_rate)
    return math.floor(samples * video_fps_num / (video_fps_den * sample_rate))
end

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
-- EFFECTIVE SOURCE RANGE ACCESSORS (for edit commands)
-- =============================================================================
-- These accessors return the effective source_in/source_out for each stream,
-- accounting for sequence marks when set. Marks are in video frame space;
-- audio accessors convert to sample space using coordinate-aware conversion.

--- Get effective video source_in: mark_in if set, otherwise video clip's source_in.
-- @return number Video frame position (absolute TC)
function Sequence:get_effective_video_in()
    if self.mark_in then
        return self.mark_in
    end
    local video = self:video_stream()
    assert(video, "Sequence:get_effective_video_in: no video stream")
    return video.source_in
end

--- Get effective video source_out: mark_out if set, otherwise video clip's source_out.
-- @return number Video frame position (absolute TC)
function Sequence:get_effective_video_out()
    if self.mark_out then
        return self.mark_out
    end
    local video = self:video_stream()
    assert(video, "Sequence:get_effective_video_out: no video stream")
    return video.source_out
end

--- Convert a video frame position to an audio sample position, accounting for
-- the different coordinate origins of video and audio streams.
-- @param frame number Absolute TC video frame position
-- @return number Audio sample position in the audio stream's coordinate space
function Sequence:video_frame_to_audio_sample(frame)
    assert(type(frame) == "number", "Sequence:video_frame_to_audio_sample: frame must be a number")

    local video = self:video_stream()
    assert(video, "Sequence:video_frame_to_audio_sample: no video stream")
    local audio = self:audio_streams()[1]
    assert(audio, "Sequence:video_frame_to_audio_sample: no audio stream")

    local sample_rate = audio.rate.fps_numerator
    local video_fps_num = self.frame_rate.fps_numerator
    local video_fps_den = self.frame_rate.fps_denominator

    -- Convert relative to video origin, then to samples, then add audio origin
    local relative_frame = frame - video.source_in
    local relative_samples = math.floor(relative_frame * sample_rate * video_fps_den / video_fps_num)
    return audio.source_in + relative_samples
end

--- Get effective audio source_in: converts mark_in to sample space if set,
-- otherwise returns audio clip's source_in.
-- @return number Audio sample position
function Sequence:get_effective_audio_in()
    if self.mark_in then
        return self:video_frame_to_audio_sample(self.mark_in)
    end
    local audio = self:audio_streams()[1]
    assert(audio, "Sequence:get_effective_audio_in: no audio stream")
    return audio.source_in
end

--- Get effective audio source_out: converts mark_out to sample space if set,
-- otherwise returns audio clip's source_out.
-- @return number Audio sample position
function Sequence:get_effective_audio_out()
    if self.mark_out then
        return self:video_frame_to_audio_sample(self.mark_out)
    end
    local audio = self:audio_streams()[1]
    assert(audio, "Sequence:get_effective_audio_out: no audio stream")
    return audio.source_out
end

-- =============================================================================
-- PLAYHEAD RESOLUTION (used by Renderer and Mixer)
-- =============================================================================

--- Internal: Calculate source frame and time for a clip at a given playhead.
-- "Frames are frames": source_frame = source_in + timeline_offset (1:1 mapping).
-- A 24fps clip on a 30fps timeline plays each source frame at 1/30s — the clip
-- runs faster. No rate conversion here; the speed conform is intended behavior.
-- @param clip Clip object (timeline_start, source_in, rate)
-- @param playhead_frame integer playhead position in timeline frames
-- @return source_time_us (integer microseconds), source_frame (integer)
local function calc_source_time_us(clip, playhead_frame)
    assert(type(playhead_frame) == "number", "Sequence: playhead must be integer")
    assert(type(clip.timeline_start) == "number", "Sequence: timeline_start must be integer")
    assert(type(clip.source_in) == "number", "Sequence: source_in must be integer")

    local offset_frames = playhead_frame - clip.timeline_start
    local source_frame = clip.source_in + offset_frames

    local clip_rate = clip.rate
    assert(clip_rate and clip_rate.fps_numerator and clip_rate.fps_denominator,
        string.format("Sequence: clip %s has no rate", clip.id))

    -- Convert to microseconds: frame * 1000000 * fps_den / fps_num
    local source_time_us = math.floor(
        source_frame * 1000000 * clip_rate.fps_denominator / clip_rate.fps_numerator
    )
    return source_time_us, source_frame
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

    local results = {}
    -- Tracks are sorted by track_index ASC (V1=1, V2=2, ...; highest = topmost)
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_video_at: clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))

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

    local results = {}
    for _, track in ipairs(tracks) do
        local clip = Clip.find_at_time(track.id, playhead_frame)
        if clip then
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_audio_at: audio clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))

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
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_next_video: clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))
            -- source_frame at clip start = source_in
            local source_time_us, source_frame = calc_source_time_us(clip, clip.timeline_start)
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
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_prev_video: clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))
            -- Source position at clip END (last frame): reverse playback enters here
            local last_frame = clip.timeline_start + clip.duration - 1
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
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_next_audio: clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))
            local source_time_us, source_frame = calc_source_time_us(clip, clip.timeline_start)
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
            local media = Media.load(clip.media_id)
            assert(media, string.format(
                "Sequence:get_prev_audio: clip %s references missing media %s",
                clip.id, tostring(clip.media_id)))
            -- Source position at clip END (last frame): reverse playback enters here
            local last_frame = clip.timeline_start + clip.duration - 1
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

-- T031 (013): thin wrappers over Sequence:resolve_in_range filtered by
-- media_kind. Shape: ResolvedEntry[] per contracts/resolver.md. Legacy
-- shape (entry.clip, entry.track, entry.media_fps_*) is dead under V9
-- because clips.media_id no longer exists; see wrapper-shape-audit.md.
-- Class-form (first arg is seq_id), NOT instance-form. Consumers
-- (playback_engine, test_drp_anamnesis_full) are rewritten in T093.

local function filter_by_media_kind(entries, kind)
    local out = {}
    for _, e in ipairs(entries) do
        if e.media_kind == kind then out[#out + 1] = e end
    end
    return out
end

--- Resolve video entries in a frame range.
-- @param seq_id string: sequence to resolve
-- @param from_frame integer: inclusive start in seq_id's timebase
-- @param to_frame integer: exclusive end
-- @return ResolvedEntry[] with media_kind='video'
function Sequence:get_video_in_range(seq_id, from_frame, to_frame)
    assert(type(seq_id) == "string" and seq_id ~= "",
        "Sequence:get_video_in_range: seq_id must be non-empty string")
    assert(type(from_frame) == "number",
        "Sequence:get_video_in_range: from_frame must be integer")
    assert(type(to_frame) == "number",
        "Sequence:get_video_in_range: to_frame must be integer")
    assert(from_frame < to_frame, string.format(
        "Sequence:get_video_in_range: from_frame %d must be < to_frame %d",
        from_frame, to_frame))
    local entries = Sequence:resolve_in_range(seq_id, from_frame, to_frame, {})
    return filter_by_media_kind(entries, "video")
end

--- Resolve audio entries in a frame range.
-- @param seq_id string: sequence to resolve
-- @param from_frame integer: inclusive start in seq_id's timebase
-- @param to_frame integer: exclusive end
-- @return ResolvedEntry[] with media_kind='audio'
function Sequence:get_audio_in_range(seq_id, from_frame, to_frame)
    assert(type(seq_id) == "string" and seq_id ~= "",
        "Sequence:get_audio_in_range: seq_id must be non-empty string")
    assert(type(from_frame) == "number",
        "Sequence:get_audio_in_range: from_frame must be integer")
    assert(type(to_frame) == "number",
        "Sequence:get_audio_in_range: to_frame must be integer")
    assert(from_frame < to_frame, string.format(
        "Sequence:get_audio_in_range: from_frame %d must be < to_frame %d",
        from_frame, to_frame))
    local entries = Sequence:resolve_in_range(seq_id, from_frame, to_frame, {})
    return filter_by_media_kind(entries, "audio")
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
    for _, track in ipairs(tracks or {}) do
        indices[#indices + 1] = track.track_index
    end
    table.sort(indices)
    return indices
end

--- Compute the furthest clip end frame in this sequence.
-- Returns max(timeline_start + duration) across all clips on all tracks.
-- @return integer  0 if no clips
function Sequence:compute_content_end()
    local database = require("core.database") -- luacheck: ignore 431
    assert(database.has_connection(),
        "Sequence:compute_content_end: no database connection")
    local db = database.get_connection()

    local stmt = db:prepare([[
        SELECT MAX(c.timeline_start_frame + c.duration_frames)
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
-- For timeline sequences: max(timeline_start + duration) across track clips.
-- For masterclip sequences: the stream clip's duration_frames.
-- @return integer  0 if no content
function Sequence:content_duration()
    if self:is_masterclip() then
        local db = resolve_db()
        local stmt = db:prepare([[
            SELECT duration_frames FROM clips
            WHERE owner_sequence_id = ? AND clip_kind = 'master'
            LIMIT 1
        ]])
        assert(stmt, "Sequence:content_duration: failed to prepare query")
        stmt:bind_value(1, self.id)
        assert(stmt:exec(), "Sequence:content_duration: query exec failed")
        assert(stmt:next(), string.format(
            "Sequence:content_duration(%s): masterclip has no clip_kind='master' row",
            tostring(self.id)))
        local dur = stmt:value(0)
        assert(dur and dur > 0, string.format(
            "Sequence:content_duration(%s): duration_frames is %s (expected > 0)",
            tostring(self.id), tostring(dur)))
        stmt:finalize()
        return dur
    end
    return self:compute_content_end()
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
        assert(frame < end_frame,
            string.format("Sequence:set_playhead(%s): frame %d >= end %d (start_tc=%d, dur=%d)",
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
-- 'nested' iterates clips + recurses.
--
-- Rule 2.5: orchestrator reads as a high-level algorithm; each piece of
-- intent is a named helper.
--
-- Coordinate spaces (read carefully — every bug in the prior implementation
-- was a unit confusion):
--   * media_refs.source_in_frame / source_out_frame  — file-native units
--     (video frames at the file's fps, or audio samples at its rate).
--   * media_refs.timeline_start_frame                 — master-timebase units.
--   * clips.source_in_frame / source_out_frame        — nested-sequence units
--     (i.e. nested.fps frames, sample units for an audio clip).
--   * clips.timeline_start_frame / duration_frames    — owner-sequence units.
--   * The fps_mismatch_policy was applied at Insert/Set time, so the ratio
--     between owner-units and source-units is exactly
--       owner_per_source = c.duration_frames / (c.source_out - c.source_in)
--     for every clip — `resample` and `passthrough` differ only in what was
--     written to c.duration_frames at Insert.
--
-- First-landing assumption: `master.fps == media.fps` for each media_ref
-- (multi-fps masters defer to a later feature). With this assumption the
-- master-timebase units coincide with file-native units 1:1, and a media_ref
-- placed at master_lo plays file frames [mr.source_in + (mr_lo - mr.timeline_start),
-- mr.source_in + (mr_hi - mr.timeline_start)).

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
    local sql = [[
        SELECT mr.id, mr.track_id, mr.media_id, mr.source_in_frame, mr.source_out_frame,
               mr.timeline_start_frame, mr.duration_frames,
               mr.enabled, mr.volume,
               t.track_type, t.track_index,
               m.file_path, m.audio_channels
        FROM media_refs mr
        JOIN tracks t ON mr.track_id = t.id
        JOIN media m ON mr.media_id = m.id
        WHERE mr.owner_sequence_id = ?
    ]]
    if only_track_id then sql = sql .. " AND mr.track_id = ?" end
    sql = sql .. " ORDER BY t.track_type DESC, t.track_index ASC, mr.timeline_start_frame ASC"
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
            timeline_start = stmt:value(5),
            duration = stmt:value(6),
            enabled = stmt:value(7) == 1,
            volume = stmt:value(8),
            track_type = stmt:value(9),
            track_index = stmt:value(10),
            file_path = stmt:value(11),
            audio_channels = stmt:value(12) or 0,
        }
    end
    stmt:finalize()
    return rows
end

-- Enumerate clips on a nested sequence that overlap [start, end) in this
-- sequence's timebase. Sorted by track_type (VIDEO before AUDIO) then track
-- index ascending, then timeline_start ascending — so the output of a sequence
-- with many clips is deterministic (G-R11).
local function list_clips_overlapping(db, seq_id, start_frame, end_frame)
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.nested_sequence_id,
               c.timeline_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.volume,
               t.track_type, t.track_index
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE c.owner_sequence_id = ?
          AND (c.timeline_start_frame + c.duration_frames) > ?
          AND c.timeline_start_frame < ?
        ORDER BY t.track_type DESC, t.track_index ASC,
                 c.timeline_start_frame ASC, c.id ASC
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
            nested_sequence_id = stmt:value(2),
            timeline_start = stmt:value(3),
            duration = stmt:value(4),
            source_in = stmt:value(5),
            source_out = stmt:value(6),
            master_layer_track_id = stmt:value(7),
            master_audio_track_id = stmt:value(8),
            fps_mismatch_policy = stmt:value(9),
            enabled = stmt:value(10) == 1,
            volume = stmt:value(11),
            track_type = stmt:value(12),
            track_index = stmt:value(13),
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

-- Resolve a master sequence over a master-coord range [master_lo, master_hi).
-- Iterate media_refs that overlap; emit one ResolvedEntry per row (V) or per
-- channel (A), with master-coord positioning and file-native source range.
-- Audio entries carry a per-channel `channel_state` table; the outer caller
-- composes that into volume/enabled at finalization time, allowing any clip
-- in the chain to replace the master's channel state with its override
-- without divide-by-stale-factor math.
--
-- Track selectors (symmetric per FR-005 / FR-023):
--   layer_track_id    — non-nil restricts V media_refs to that track.
--   audio_track_id    — non-nil restricts A media_refs to that track
--                       (Expand/Collapse audio path). nil = composite
--                       (every A media_ref emits, today's behavior).
local function resolve_master_leaf(db, seq_id, master_lo, master_hi,
                                   layer_track_id, audio_track_id, outer_chain)
    local entries = {}
    local all = list_media_refs(db, seq_id, nil)

    for _, r in ipairs(all) do
        local r_lo = r.timeline_start
        local r_hi = r.timeline_start + r.duration
        local include
        if r.track_type == "VIDEO" and layer_track_id ~= nil then
            include = (r.track_id == layer_track_id)
        elseif r.track_type == "AUDIO" and audio_track_id ~= nil then
            include = (r.track_id == audio_track_id)
        else
            include = true
        end
        if include and r_hi > master_lo and r_lo < master_hi then
            local lo = math.max(r_lo, master_lo)
            local hi = math.min(r_hi, master_hi)
            local file_in  = r.source_in + (lo - r.timeline_start)
            local file_out = r.source_in + (hi - r.timeline_start)
            local online   = require("core.media.media_status").is_online(r.file_path)
            local base = {
                media_path     = online and r.file_path or nil,
                media_id       = r.media_id,
                source_in      = file_in,
                source_out     = file_out,
                timeline_start = lo,            -- master coords; outer translates
                duration       = hi - lo,       -- master coords
                volume         = r.volume,      -- leaf media_ref's own volume
                enabled        = online and r.enabled,
                effects        = {},
                provenance     = build_provenance(outer_chain, r.id),
            }
            if r.track_type == "VIDEO" then
                base.media_kind   = "video"
                base.track_role   = "video"
                base.channel_index = nil
                entries[#entries + 1] = base
            else
                local n_ch = r.audio_channels
                if n_ch == 0 then n_ch = 1 end  -- mono fallback when metadata missing
                for ch = 0, n_ch - 1 do
                    local ms_enabled, ms_gain_db =
                        fetch_master_channel_state(db, seq_id, ch)
                    local e = {
                        media_path     = base.media_path,
                        media_id       = base.media_id,
                        media_kind     = "audio",
                        source_in      = base.source_in,
                        source_out     = base.source_out,
                        timeline_start = base.timeline_start,
                        duration       = base.duration,
                        track_role     = "audio",
                        channel_index  = ch,
                        volume         = base.volume,
                        enabled        = base.enabled,
                        effects        = {},
                        provenance     = build_provenance(outer_chain, r.id),
                        -- Channel state stays SEPARATE from volume until the
                        -- final composition pass — any clip in the chain may
                        -- replace it via clip_channel_override without
                        -- needing to divide out a previously-multiplied factor.
                        channel_state  = { enabled = ms_enabled, gain_db = ms_gain_db },
                    }
                    entries[#entries + 1] = e
                end
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
    local outer_offset_lo = (e.timeline_start - source_lo) * owner_per_source
    local outer_dur       = e.duration * owner_per_source
    e.timeline_start = c.timeline_start + round_int(outer_offset_lo
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
local function resolve_nested(db, seq_id, outer_lo, outer_hi, context,
                              outer_chain, layer_filter_for_v,
                              audio_filter_for_a)
    local entries = {}
    local clips = list_clips_overlapping(db, seq_id, outer_lo, outer_hi)
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
            -- if non-NULL, must point at a live track of c.nested_sequence_id.
            if c.master_layer_track_id then
                assert_track_ref_valid(db, c.id, c.nested_sequence_id,
                    c.master_layer_track_id, "master_layer_track_id")
            end
            if c.master_audio_track_id then
                assert_track_ref_valid(db, c.id, c.nested_sequence_id,
                    c.master_audio_track_id, "master_audio_track_id")
            end

            -- INV-5: clip_channel_override.channel_index must point at an
            -- existing channel in the referenced sequence's audio layout.
            -- Iterate the clip's overrides (if any) and assert each is in
            -- bounds. For first-landing this checks only when the clip
            -- directly references a master (kind='master') so we have a
            -- concrete channel count; nested-of-nested defers to the
            -- master at its leaf via the recursion's downstream INV-5
            -- check on whatever clips the inner sequence holds.
            do
                local kind_stmt = db:prepare(
                    "SELECT kind FROM sequences WHERE id = ?")
                assert(kind_stmt, "Sequence.resolve INV-5: kind prepare failed")
                kind_stmt:bind_value(1, c.nested_sequence_id)
                assert(kind_stmt:exec(), "Sequence.resolve INV-5: kind exec failed")
                local nk
                if kind_stmt:next() then nk = kind_stmt:value(0) end
                kind_stmt:finalize()
                if nk == "master" then
                    local channel_count = Sequence.count_master_audio_channels(
                        c.nested_sequence_id)
                    local Override = require("models.clip_channel_override")
                    for _, ov in ipairs(Override.find_all(c.id)) do
                        assert(ov.channel_index < channel_count, string.format(
                            "Sequence.resolve INV-5: clip %s has "
                            .. "clip_channel_override(channel_index=%d) but "
                            .. "the referenced master sequence %s has only "
                            .. "%d audio channel(s). The master likely "
                            .. "shrank since the override was set; clear "
                            .. "or migrate the override.",
                            c.id, ov.channel_index,
                            c.nested_sequence_id, channel_count))
                    end
                end
            end

            -- Layer to expose at the level THIS clip directly references.
            -- NULL → inherit the referenced sequence's default; explicit →
            -- this clip's per-clip override.
            local layer_for_inner = c.master_layer_track_id
            if layer_for_inner == nil then
                layer_for_inner = fetch_default_video_layer(db, c.nested_sequence_id)
            end

            -- Audio-track selector at THIS clip's directly-referenced level.
            -- NULL = composite (today's behavior — no restriction). Non-NULL
            -- = single-track (Expand). There is no sequence-level "default
            -- audio track" symmetric to default_video_layer_track_id;
            -- composite IS the default.
            local audio_for_inner = c.master_audio_track_id

            -- Compute the source-coord (= nested-timebase) sub-range to
            -- recurse into, derived from the outer-coord intersection.
            local source_span = c.source_out - c.source_in
            local owner_span  = c.duration
            local source_per_owner = source_span / owner_span
            local clip_outer_lo = math.max(c.timeline_start, outer_lo)
            local clip_outer_hi = math.min(c.timeline_start + owner_span, outer_hi)
            local source_lo = c.source_in
                + round_int((clip_outer_lo - c.timeline_start) * source_per_owner)
            local source_hi = c.source_in
                + round_int((clip_outer_hi - c.timeline_start) * source_per_owner)

            -- Cycle-guarded recurse.
            local inner_chain = {}
            for i, v in ipairs(outer_chain) do inner_chain[i] = v end
            inner_chain[#inner_chain + 1] = c.id

            local inner = resolve_seq_range(db, c.nested_sequence_id,
                source_lo, source_hi, context, inner_chain,
                layer_for_inner, audio_for_inner)

            -- No double-counting: V clips materialize only V media; A only A.
            local want_kind = (c.track_type == "VIDEO") and "video" or "audio"
            for _, e in ipairs(inner) do
                if e.media_kind == want_kind then
                    -- Translate master-coord -> outer-coord; the inner
                    -- entry's timeline_start/duration are in this clip's
                    -- nested-timebase, so we use this clip's source ratio.
                    translate_to_outer(e, c, c.source_in)

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
resolve_seq_range = function(db, seq_id, range_lo, range_hi, context,
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
        entries = resolve_master_leaf(db, seq_id, range_lo, range_hi,
            layer_for_directly_referenced,
            audio_for_directly_referenced,
            outer_chain)
    else
        entries = resolve_nested(db, seq_id, range_lo, range_hi,
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

function Sequence:resolve_in_range(seq_id, start_frame, end_frame, context)
    assert(seq_id, "Sequence:resolve_in_range: seq_id required")
    assert(type(start_frame) == "number", "start_frame must be number")
    assert(type(end_frame) == "number", "end_frame must be number")
    assert(type(context) == "table", "context table required")
    context.recursing_into = context.recursing_into or {}
    local db = resolve_db()
    local entries = resolve_seq_range(db, seq_id, start_frame, end_frame,
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
               audio_rate, width, height,
               default_video_layer_track_id, video_start_tc_frame,
               audio_start_tc_samples, fps_mismatch_policy
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
            audio_rate = stmt:value(6),
            width = stmt:value(7),
            height = stmt:value(8),
            default_video_layer_track_id = stmt:value(9),
            video_start_tc_frame = stmt:value(10),
            audio_start_tc_samples = stmt:value(11),
            fps_mismatch_policy = stmt:value(12),
        }
    end
    stmt:finalize()
    return row
end

--- Assert INV-8 on the given sequence: if the sequence has at least one video
--- track, default_video_layer_track_id must be non-NULL AND reference a live
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
            "INV-8: sequence %s has no video tracks but default_video_layer_track_id=%s "
            .. "(Sequence.assert_inv8)",
            id, tostring(row.default_video_layer_track_id)))
        return
    end

    -- Has video tracks → default MUST be non-NULL and reference a live V track of this sequence.
    assert(row.default_video_layer_track_id ~= nil, string.format(
        "INV-8 violation: sequence %s has video tracks but default_video_layer_track_id is NULL "
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
        "INV-8: sequence %s default_video_layer_track_id=%s does not exist "
        .. "(Sequence.assert_inv8)",
        id, tostring(row.default_video_layer_track_id)))
    assert(ttype == "VIDEO", string.format(
        "INV-8: sequence %s default_video_layer_track_id=%s is track_type=%s (expected VIDEO)",
        id, tostring(row.default_video_layer_track_id), tostring(ttype)))
    assert(tseq == id, string.format(
        "INV-8: sequence %s default_video_layer_track_id=%s belongs to sequence %s (cross-sequence not allowed)",
        id, tostring(row.default_video_layer_track_id), tostring(tseq)))
end

-- Columns update() will touch. Structural columns (id, project_id, kind,
-- fps_*, audio_rate, width, height) are NOT here — changing them requires
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
--- untouched. Enforces INV-8 after the write — the update as a unit must not
--- leave the sequence in a state that violates INV-8.
function Sequence.update(id, fields)
    assert(type(fields) == "table", "Sequence.update: fields table required")
    local conn = resolve_db()

    local sets, values = {}, {}
    -- Keep track of whether default_video_layer_track_id is being explicitly set to nil.
    local explicit_nil_default_layer = false
    for k, v in pairs(fields) do
        assert(SEQUENCE_UPDATABLE[k], string.format(
            "Sequence.update: column '%s' is not updatable via this path", k))
        sets[#sets + 1] = k .. " = ?"
        values[#values + 1] = v
    end
    -- pairs() skips nil values — handle default_video_layer_track_id=nil explicitly.
    if fields.default_video_layer_track_id == nil
            and rawget(fields, "default_video_layer_track_id") == nil then
        -- Caller used the sentinel form fields.default_video_layer_track_id = nil.
        -- (This doesn't distinguish "not set" from "explicitly nil" in Lua.)
        -- Detect via the "key present" check: use a separate marker.
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

    -- INV-8 post-condition check.
    Sequence.assert_inv8(id)
    return true
end

--- Feature 013 (T040): native-timebase duration of a sequence restricted to
--- a single medium. A master's VIDEO duration is in video frames at the
--- master's fps; its AUDIO duration is in audio samples at its audio_rate —
--- the two are in different units, so the caller must specify which.
--- Computed as max(timeline_start_frame + duration_frames) across media_refs
--- (for a master) OR clips (for a nested sequence) on tracks of the given
--- type. Returns 0 if no content of that medium exists.
function Sequence.native_duration_for_medium(id, track_type)
    assert(id and id ~= "",
        "Sequence.native_duration_for_medium: id is required")
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "Sequence.native_duration_for_medium: track_type must be VIDEO or AUDIO")
    local conn = resolve_db()
    local stmt = conn:prepare([[
        SELECT COALESCE(MAX(r.timeline_start_frame + r.duration_frames), 0)
        FROM (
            SELECT track_id, timeline_start_frame, duration_frames
              FROM media_refs WHERE owner_sequence_id = ?
            UNION ALL
            SELECT track_id, timeline_start_frame, duration_frames
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
    local d = stmt:value(0) or 0
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
        local list = Track.find_by_sequence(id, ttype) or {}
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
            fps_numerator, fps_denominator, audio_rate, width, height,
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
    stmt:bind_value(7,  s.audio_rate)
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
    for _, t in ipairs(state.tracks or {}) do
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
--- by ToggleClipChannel/SetClipChannelGain for INV-5 bounds checks.
---
--- @param master_id string  must reference a kind='master' sequence
--- @return integer  total audio channel count
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
    local n = stmt:value(0) or 0
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

return Sequence