--- models/sequence/queries.lua — table-form class helpers for Sequence:
--- read by id, mutate by id, assert invariants by id, derive numeric
--- facts about a sequence. Stateless: returns row tables (no metatable),
--- writes via direct UPDATE.
---
--- Extracted from models/sequence.lua (2.6: ~415 LOC of cohesive
--- table-form helpers). Distinct from the legacy object-oriented
--- Sequence.create(...) + :save() flow, which still lives in the main
--- file. Installed onto Sequence via M.install(Sequence).
---
--- Methods owned by this module:
---   * Sequence.find(id) — read row
---   * Sequence.assert_default_video_layer_valid(id) — invariant guard
---   * Sequence.update(id, fields) — write row
---   * Sequence.native_duration_for_medium(id, track_type)
---   * Sequence.contained_mediums(id)
---   * Sequence.get_name(id)
---   * Sequence.delete_one(id)
---   * Sequence.set_fps_mismatch_policy(id, policy)
---   * Sequence.set_start_tc(id, medium, value)
---   * Sequence.effective_audio_sample_rate(seq)
---   * Sequence.count_master_audio_channels(master_id)
---   * Sequence.get_master_channel_state(master_id, channel_index)

local database = require("core.database")

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "models.sequence.queries: no database connection")
    return conn
end

local M = {}

function M.install(Sequence)


-- ===========================================================================
-- Feature 013: table-form class helpers (find / update / assert_default_video_layer_valid)
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
function Sequence.assert_default_video_layer_valid(id)
    local conn = resolve_db()
    local row = Sequence.find(id)
    assert(row, string.format("Sequence.assert_default_video_layer_valid: sequence %s not found", tostring(id)))

    -- Does this sequence have any VIDEO tracks?
    local ts = conn:prepare(
        "SELECT id FROM tracks WHERE sequence_id = ? AND track_type = 'VIDEO' LIMIT 1")
    assert(ts, "Sequence.assert_default_video_layer_valid: video-track prepare failed")
    ts:bind_value(1, id)
    assert(ts:exec(), "Sequence.assert_default_video_layer_valid: video-track exec failed")
    local has_video = ts:next()
    ts:finalize()

    if not has_video then
        -- No video tracks; default_video_layer_track_id must be NULL.
        assert(row.default_video_layer_track_id == nil, string.format(
            "Sequence.assert_default_video_layer (default_video_layer_track_id must reference a live VIDEO track of this sequence when video tracks exist): sequence %s has no video tracks but default_video_layer_track_id=%s "
            .. "(Sequence.assert_default_video_layer_valid)",
            id, tostring(row.default_video_layer_track_id)))
        return
    end

    -- Has video tracks → default MUST be non-NULL and reference a live V track of this sequence.
    assert(row.default_video_layer_track_id ~= nil, string.format(
        "Sequence.assert_default_video_layer (default_video_layer_track_id must reference a live VIDEO track of this sequence when video tracks exist): sequence %s has video tracks but default_video_layer_track_id is NULL "
        .. "(Sequence.assert_default_video_layer_valid)", id))

    local vs = conn:prepare(
        "SELECT track_type, sequence_id FROM tracks WHERE id = ?")
    assert(vs, "Sequence.assert_default_video_layer_valid: default-track prepare failed")
    vs:bind_value(1, row.default_video_layer_track_id)
    assert(vs:exec(), "Sequence.assert_default_video_layer_valid: default-track exec failed")
    local found, ttype, tseq
    if vs:next() then
        found = true
        ttype = vs:value(0)
        tseq = vs:value(1)
    end
    vs:finalize()
    assert(found, string.format(
        "Sequence.assert_default_video_layer (default_video_layer_track_id must reference a live VIDEO track of this sequence when video tracks exist): sequence %s default_video_layer_track_id=%s does not exist "
        .. "(Sequence.assert_default_video_layer_valid)",
        id, tostring(row.default_video_layer_track_id)))
    assert(ttype == "VIDEO", string.format(
        "Sequence.assert_default_video_layer (default_video_layer_track_id must reference a live VIDEO track of this sequence when video tracks exist): sequence %s default_video_layer_track_id=%s is track_type=%s (expected VIDEO)",
        id, tostring(row.default_video_layer_track_id), tostring(ttype)))
    assert(tseq == id, string.format(
        "Sequence.assert_default_video_layer (default_video_layer_track_id must reference a live VIDEO track of this sequence when video tracks exist): sequence %s default_video_layer_track_id=%s belongs to sequence %s (cross-sequence not allowed)",
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
    Sequence.assert_default_video_layer_valid(id)
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

end -- M.install

return M
