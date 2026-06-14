--- models/sequence/master_builder.lua — Sequence.ensure_master and the
--- master-lookup / start-TC batch helpers.
---
--- Extracted from models/sequence.lua (2.6: that file shrank to 2116 LOC
--- after the point-in-time split — still too big). This cluster — the
--- masterclip-factory cluster — is ~400 LOC of cohesive logic for
--- building V13 master sequences from media items.
---
--- Methods installed on Sequence via M.install(Sequence):
---   * Sequence.ensure_master(media_id, project_id, opts)
---   * Sequence.find_master_for_media(media_id)
---   * Sequence.find_masters_for_media_tc_sync(media_ids)
---   * Sequence.batch_set_master_start_tc(rows)
---   * Sequence.batch_restore_master_start_tc(rows)
---   * Sequence.get_first_media_ref(sequence_id)
---
--- ensure_master calls Sequence.create and Sequence.update — both still
--- defined in models/sequence.lua. They're reached via the Sequence arg
--- to install() (same class, same table — circular require is avoided
--- because install runs after models.sequence finishes loading).

local database = require("core.database")
local log = require("core.logger").for_area("media")

local function resolve_db()
    local conn = database.get_connection()
    assert(conn, "models.sequence.master_builder: no database connection")
    return conn
end

local M = {}

function M.install(Sequence)

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
                start_timecode_frame     = dims.video_tc,
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

    -- Create synced (external) audio tracks after the camera scratch tracks.
    -- Each external audio file gets one AUDIO track per channel, not muted.
    -- sequence_start_frame is the video-fps frame that corresponds to the
    -- external WAV's TC origin (TC-based sync: matching TC = same position).
    local function add_synced_audio_streams(seq, dims, now, synced_audio_media_ids)
        local base_index = dims.has_audio and dims.media.audio_channels or 0 -- lint-allow: R010 ternary: has_audio=false → 0 is correct; has_audio=true → audio_channels > 0 is invariant from load_media_dims
        local synced_track_offset = 0  -- cumulative; each file starts after the last channel of the previous
        for _, audio_media_id in ipairs(synced_audio_media_ids) do
            local audio_media = Media.load(audio_media_id)
            assert(audio_media, string.format(
                "Sequence.ensure_master: synced audio media not found: %s",
                tostring(audio_media_id)))
            assert(audio_media.audio_channels > 0, string.format(
                "Sequence.ensure_master: synced audio media %s has no audio channels",
                tostring(audio_media_id)))
            local sample_rate = audio_media.audio_sample_rate
            assert(sample_rate and sample_rate > 0, string.format(
                "Sequence.ensure_master: synced audio media %s has no audio_sample_rate",
                tostring(audio_media_id)))
            local audio_tc = audio_media:get_audio_start_tc()
            assert(audio_tc ~= nil, string.format(
                "Sequence.ensure_master: synced audio media %s has no audio TC origin",
                tostring(audio_media_id)))
            -- Convert audio TC origin to video-fps frame position for sequence placement.
            -- TC-based sync: the audio and video share the same wall-clock origin, so
            -- the audio's TC in samples converts cleanly to the video's TC in frames.
            local seq_start = math.floor(
                audio_tc * dims.fps_num / (dims.fps_den * sample_rate) + 0.5)
            local duration_samples = audio_media.duration
            assert(type(duration_samples) == "number" and duration_samples > 0, string.format(
                "Sequence.ensure_master: synced audio media %s has no duration",
                tostring(audio_media_id)))
            local audio_duration_frames = math.floor(
                duration_samples * dims.fps_num / (dims.fps_den * sample_rate) + 0.5)
            for ch = 1, audio_media.audio_channels do
                local track_index = base_index + synced_track_offset + ch
                local atrack = Track.create_audio(
                    string.format("Sync %d", track_index), seq.id, {
                        index       = track_index,
                        muted       = false,
                        source_kind = "sync",
                    })
                assert(atrack:save(), string.format(
                    "Sequence.ensure_master: failed to save synced audio track %d",
                    track_index))
                MediaRef.create({
                    project_id           = project_id,
                    owner_sequence_id    = seq.id,
                    track_id             = atrack.id,
                    media_id             = audio_media_id,
                    source_in_frame      = audio_tc,
                    source_out_frame     = audio_tc + duration_samples,
                    sequence_start_frame = seq_start,
                    duration_frames      = audio_duration_frames,
                    audio_sample_rate    = sample_rate,
                    enabled              = true,
                    volume               = 1.0,
                    playhead_frame       = 0,
                    created_at           = now,
                    modified_at          = now,
                })
            end
            synced_track_offset = synced_track_offset + audio_media.audio_channels
        end
    end

    local function add_audio_streams(seq, dims, now)
        if not dims.has_audio then return end
        local camera_muted = opts.synced_audio_media_ids ~= nil
            and #opts.synced_audio_media_ids > 0
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
                    id          = replay_audio_track_ids[ch],
                    index       = ch,
                    muted       = camera_muted,
                    source_kind = "camera",
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
    if opts.synced_audio_media_ids and #opts.synced_audio_media_ids > 0 then
        add_synced_audio_streams(seq, dims, now, opts.synced_audio_media_ids)
    end

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
    -- "The master FOR media X" is X's OWN source master — the one whose
    -- primary (camera/NULL) tracks hold X — NOT a master that merely borrows
    -- X as dual-system sync audio (source_kind='sync'). A field-recorder WAV
    -- is both its own pool master AND the sync audio of a camera clip's master;
    -- without the source_kind filter this returns either one nondeterministically
    -- (created_at ties to the second), which would (a) misdirect pool-mark
    -- application and (b) make ensure_master think the WAV already has a master
    -- and never create its own.
    local stmt = conn:prepare([[
        SELECT s.id FROM sequences s
        JOIN media_refs mr ON mr.owner_sequence_id = s.id
        JOIN tracks t ON t.id = mr.track_id
        WHERE s.kind = 'master' AND mr.media_id = ?
          AND (t.source_kind IS NULL OR t.source_kind <> 'sync')
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

end -- M.install

return M
